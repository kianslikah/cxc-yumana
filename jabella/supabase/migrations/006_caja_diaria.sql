-- =====================================================================
-- JABELLA Store — entrega 5: caja del día y avisos a la dueña.
-- Apertura en la mañana (se cuenta el fondo para vueltos), cierre en la noche (se cuenta todo,
-- se deja el fondo para mañana y el resto se le entrega a la dueña: pasa a "Efectivo guardado").
-- Número de WhatsApp de la dueña para los avisos de ventas, apertura y cierre.
-- Base compartida con Yumana: solo objetos jab_, nunca "all ... in schema public".
-- =====================================================================

-- WhatsApp donde la dueña recibe los avisos (lo ve todo el personal activo, como el resto de la configuración)
alter table public.jab_config add column whatsapp_duena text
  check (whatsapp_duena is null or whatsapp_duena ~ '^[0-9+() -]{7,20}$');

create or replace function public.jab_actualizar_config(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_antes jsonb;
begin
  perform public.jab__exigir_duena();
  select to_jsonb(c) into v_antes from public.jab_config c where id = 1;
  update public.jab_config set
    dias_apartado    = coalesce((p->>'dias_apartado')::int, dias_apartado),
    abono_minimo_pct = coalesce((p->>'abono_minimo_pct')::numeric, abono_minimo_pct),
    vendedora_fia    = coalesce((p->>'vendedora_fia')::boolean, vendedora_fia),
    tarifa_libra     = coalesce((p->>'tarifa_libra')::numeric, tarifa_libra),
    whatsapp_duena   = case when p ? 'whatsapp_duena' then nullif(trim(p->>'whatsapp_duena'), '') else whatsapp_duena end
  where id = 1;
  perform public.jab__auditar('config', '1', 'editar', v_antes, (select to_jsonb(c) from public.jab_config c where id = 1));
end $$;

-- ---------------------------------------------------------------------
-- Apertura y cierre comparten la tabla y el número corrido
-- ---------------------------------------------------------------------
alter table public.jab_cierres
  add column tipo text not null default 'cierre' check (tipo in ('apertura', 'cierre')),
  add column grupo_entrega uuid;   -- movimientos con los que se pasó a "Efectivo guardado" lo entregado a la dueña

-- Cada cuenta de efectivo tiene su cuenta "guardado": ahí va lo que se le entrega a la dueña al cerrar
alter table public.jab_cuentas add column recibe_entrega_de bigint references public.jab_cuentas(id);
create unique index on public.jab_cuentas (recibe_entrega_de) where recibe_entrega_de is not null;

create function public.jab__cuenta_guardado(p_cuenta bigint) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c public.jab_cuentas;
  v_id bigint;
  v_nombre text;
begin
  select id into v_id from public.jab_cuentas where recibe_entrega_de = p_cuenta;
  if v_id is not null then
    return v_id;
  end if;
  select * into c from public.jab_cuentas where id = p_cuenta;
  v_nombre := case when c.nombre ~* 'efectivo' then regexp_replace(c.nombre, 'efectivo', 'Efectivo guardado', 'i')
                   else c.nombre || ' (guardado)' end;
  if exists (select 1 from public.jab_cuentas where nombre = v_nombre) then
    v_nombre := v_nombre || ' ' || c.id;
  end if;
  insert into public.jab_cuentas (nombre, moneda, orden, cuenta_en_cierre, recibe_entrega_de)
  values (v_nombre, c.moneda, coalesce((select max(orden) from public.jab_cuentas), 0) + 1, false, c.id)
  returning id into v_id;
  return v_id;
end $$;

-- Las cuentas de efectivo de hoy ya quedan con su "guardado"
do $$
declare r record;
begin
  for r in select id from public.jab_cuentas where cuenta_en_cierre and activa order by orden, id loop
    perform public.jab__cuenta_guardado(r.id);
  end loop;
end $$;

-- p = {clave?, tipo: 'apertura'|'cierre', nota?, conteos: [{cuenta_id, contado, entregado? (solo cierre)}]}
-- Se cuenta a ciegas: lo esperado solo lo ve la dueña. En el cierre, lo entregado sale de la caja
-- hacia su "Efectivo guardado" (transferencia, no es gasto) y queda el resto como fondo para mañana.
create or replace function public.jab_registrar_cierre(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_tipo text := coalesce(nullif(p->>'tipo', ''), 'cierre');
  v_prev jsonb;
  c public.jab_cuentas;
  x jsonb;
  v_contado numeric;
  v_entregado numeric;
  v_esperado numeric;
  v_det jsonb := '[]'::jsonb;
  v_dif_usd numeric := 0;
  v_tasa numeric;
  v_id bigint;
  v_num bigint;
  v_ult public.jab_cierres;
  v_grupo uuid;
  v_dest bigint;
begin
  perform public.jab__exigir_activo();
  v_prev := public.jab__idem_inicio(v_clave, 'cierre');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  if v_tipo not in ('apertura', 'cierre') then
    raise exception 'Tipo de conteo no válido.';
  end if;
  select nullif(tasa_bs, 0) into v_tasa from public.jab_config where id = 1;
  if v_tasa is null and exists (select 1 from public.jab_cuentas where cuenta_en_cierre and activa and moneda = 'VES') then
    raise exception 'Primero pon la tasa del día.';
  end if;
  -- Bloquear las cuentas a contar para que el esperado no cambie mientras se registra
  perform 1 from public.jab_cuentas where cuenta_en_cierre and activa order by id for update;
  if v_tipo = 'apertura' then
    select * into v_ult from public.jab_cierres where fecha = public.jab__hoy() order by id desc limit 1;
    if found and v_ult.tipo = 'apertura' then
      raise exception 'La caja ya se abrió hoy a las %.', to_char(v_ult.creado_en at time zone 'America/Caracas', 'HH12:MI am');
    end if;
  end if;
  v_num := public.jab__siguiente('cierre');
  for c in select * from public.jab_cuentas where cuenta_en_cierre and activa order by orden, id loop
    select e into x from jsonb_array_elements(coalesce(p->'conteos', '[]'::jsonb)) e where (e->>'cuenta_id')::bigint = c.id;
    v_contado := round((x->>'contado')::numeric, 2);
    if v_contado is null or v_contado < 0 then
      raise exception 'Escribe cuánto hay en %.', c.nombre;
    end if;
    v_entregado := coalesce(round(nullif(x->>'entregado', '')::numeric, 2), 0);
    if v_tipo = 'apertura' and v_entregado <> 0 then
      raise exception 'Al abrir la caja no se entrega dinero.';
    end if;
    if v_entregado < 0 or v_entregado > v_contado then
      raise exception 'En % no se puede entregar más de lo que hay.', c.nombre;
    end if;
    v_esperado := round(public.jab__saldo_cuenta(c.id), 2);
    v_det := v_det || jsonb_build_object('cuenta_id', c.id, 'nombre', c.nombre, 'moneda', c.moneda,
                                         'esperado', v_esperado, 'contado', v_contado, 'diferencia', v_contado - v_esperado,
                                         'entregado', v_entregado, 'queda', v_contado - v_entregado);
    v_dif_usd := v_dif_usd + case when c.moneda = 'VES' then (v_contado - v_esperado) / v_tasa else v_contado - v_esperado end;
    -- Lo que se entrega a la dueña pasa a su "Efectivo guardado" (sigue siendo plata de la tienda)
    if v_entregado > 0 then
      v_grupo := coalesce(v_grupo, gen_random_uuid());
      v_dest := public.jab__cuenta_guardado(c.id);
      insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo)
      values ('transferencia', c.id, -v_entregado, case when c.moneda = 'VES' then v_tasa end,
              -round(case when c.moneda = 'VES' then v_entregado / v_tasa else v_entregado end, 2),
              'Entrega de caja', 'Cierre #' || v_num || ': entregado a la dueña', v_grupo),
             ('transferencia', v_dest, v_entregado, case when c.moneda = 'VES' then v_tasa end,
              round(case when c.moneda = 'VES' then v_entregado / v_tasa else v_entregado end, 2),
              'Entrega de caja', 'Cierre #' || v_num || ': entregado a la dueña', v_grupo);
    end if;
  end loop;
  if jsonb_array_length(v_det) = 0 then
    raise exception 'No hay cuentas de efectivo marcadas para el cierre (Ajustes → Cuentas de dinero).';
  end if;
  insert into public.jab_cierres (numero, tipo, nota, detalle, diferencia_usd, tasa, grupo_entrega)
  values (v_num, v_tipo, nullif(trim(p->>'nota'), ''), v_det, round(v_dif_usd, 2), v_tasa, v_grupo)
  returning id into v_id;
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_id));
  return v_id;
end $$;

-- La dueña revisa un conteo. Al cuadrar, el saldo AL MOMENTO DEL CONTEO queda igual a lo que quedó en
-- la caja (lo contado menos lo entregado, si esa entrega sigue viva); la entrega es del mismo momento.
create or replace function public.jab_revisar_cierre(p_cierre bigint, p_ajustar boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ci public.jab_cierres;
  d jsonb;
  v_tasa numeric;
  v_dif numeric;
  v_ent numeric;
  v_aj jsonb := '[]'::jsonb;
  v_nuevo bigint;
begin
  perform public.jab__exigir_duena();
  -- Mismo orden de bloqueo que jab_registrar_cierre: nadie cierra mientras se cuadra
  perform 1 from public.jab_cuentas where cuenta_en_cierre and activa order by id for update;
  select * into ci from public.jab_cierres where id = p_cierre for update;
  if not found then
    raise exception 'Ese conteo no existe.';
  end if;
  if ci.revisado_en is not null then
    raise exception 'Ese conteo ya fue revisado.';
  end if;
  if coalesce(p_ajustar, false) then
    select numero into v_nuevo from public.jab_cierres where id > ci.id order by id desc limit 1;
    if found then
      raise exception 'Hay un conteo más nuevo (#%): cuadra ese, que ya incluye esta diferencia.', v_nuevo;
    end if;
    select coalesce(ci.tasa, nullif(tasa_bs, 0)) into v_tasa from public.jab_config where id = 1;
    for d in select * from jsonb_array_elements(ci.detalle) loop
      v_ent := case when ci.grupo_entrega is not null and exists (
                       select 1 from public.jab_movimientos_dinero
                        where grupo = ci.grupo_entrega and cuenta_id = (d->>'cuenta_id')::bigint and anulado_en is null)
                    then coalesce((d->>'entregado')::numeric, 0) else 0 end;
      v_dif := round((d->>'contado')::numeric - v_ent - public.jab__saldo_cuenta((d->>'cuenta_id')::bigint, ci.creado_en), 2);
      if v_dif <> 0 then
        if d->>'moneda' = 'VES' and v_tasa is null then
          raise exception 'Falta la tasa para ajustar los bolívares.';
        end if;
        insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo)
        values ('ajuste', (d->>'cuenta_id')::bigint, v_dif, case when d->>'moneda' = 'VES' then v_tasa end,
                round(case when d->>'moneda' = 'VES' then v_dif / v_tasa else v_dif end, 2),
                'Cierre de caja', 'Diferencia del ' || case when ci.tipo = 'apertura' then 'conteo de apertura' else 'cierre' end || ' #' || ci.numero,
                gen_random_uuid());
        v_aj := v_aj || jsonb_build_object('cuenta_id', d->'cuenta_id', 'nombre', d->'nombre', 'moneda', d->'moneda', 'monto', v_dif);
      end if;
    end loop;
    -- Los conteos anteriores sin revisar quedan cubiertos por este cuadre
    update public.jab_cierres set revisado_en = now(), revisado_por = auth.uid(),
           nota_revision = 'Incluido en el cuadre del #' || ci.numero
     where id < ci.id and revisado_en is null;
  end if;
  update public.jab_cierres set revisado_en = now(), revisado_por = auth.uid(), ajustado = coalesce(p_ajustar, false),
         ajuste = case when coalesce(p_ajustar, false) then v_aj end
   where id = p_cierre;
  perform public.jab__auditar('cierres', p_cierre::text, 'revisar', to_jsonb(ci),
    jsonb_build_object('ajustado', coalesce(p_ajustar, false), 'ajuste', v_aj));
end $$;

-- Estado de la caja de hoy para cualquier usuaria activa: si se abrió, si se cerró y qué fondo dejar.
-- No trae lo esperado (eso solo lo ve la dueña en el detalle del conteo).
create function public.jab_caja_hoy() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_hoy date := public.jab__hoy();
  a public.jab_cierres;
  ci public.jab_cierres;
  u public.jab_cierres;
  v_fondo jsonb;
begin
  perform public.jab__exigir_activo();
  select * into a from public.jab_cierres where fecha = v_hoy and tipo = 'apertura' order by id desc limit 1;
  select * into ci from public.jab_cierres where fecha = v_hoy and tipo = 'cierre' and (a.id is null or id > a.id) order by id desc limit 1;
  select * into u from public.jab_cierres order by id desc limit 1;
  -- Fondo sugerido para dejar al cerrar: lo que se contó al abrir hoy; si no se abrió, lo que quedó la última vez
  select coalesce(jsonb_agg(jsonb_build_object('cuenta_id', d->'cuenta_id',
           'monto', case when a.id is not null then d->'contado' else coalesce(d->'queda', d->'contado') end)), '[]'::jsonb)
    into v_fondo
    from jsonb_array_elements(coalesce(case when a.id is not null then a.detalle else u.detalle end, '[]'::jsonb)) d;
  return jsonb_build_object(
    'fecha', v_hoy,
    'abierta', a.id is not null and ci.id is null,
    'apertura', case when a.id is null then null else jsonb_build_object('numero', a.numero, 'creado_en', a.creado_en, 'usuario_id', a.usuario_id,
       'conteos', (select jsonb_agg(jsonb_build_object('cuenta_id', d->'cuenta_id', 'nombre', d->'nombre', 'moneda', d->'moneda', 'contado', d->'contado'))
                     from jsonb_array_elements(a.detalle) d)) end,
    'cierre', case when ci.id is null then null else jsonb_build_object('numero', ci.numero, 'creado_en', ci.creado_en, 'usuario_id', ci.usuario_id,
       'conteos', (select jsonb_agg(jsonb_build_object('cuenta_id', d->'cuenta_id', 'nombre', d->'nombre', 'moneda', d->'moneda',
                                                        'contado', d->'contado', 'entregado', coalesce(d->'entregado', '0'::jsonb),
                                                        'queda', coalesce(d->'queda', d->'contado')))
                     from jsonb_array_elements(ci.detalle) d)) end,
    'fondo', v_fondo);
end $$;

-- ---------------------------------------------------------------------
-- Permisos: solo objetos jab_ (base compartida con Yumana)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select c.oid::regclass as obj, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname like 'jab\_%' and c.relkind in ('r', 'S') loop
    if r.relkind = 'r' then execute format('revoke all on table %s from anon', r.obj);
    else execute format('revoke all on sequence %s from anon', r.obj); end if;
  end loop;
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'jab\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.f);
  end loop;
end $$;
grant execute on function
  public.jab_es_activo(), public.jab_es_duena(),
  public.jab_marcar_clave_cambiada(), public.jab_actualizar_usuario(uuid, text, text, boolean),
  public.jab_actualizar_tasa(numeric), public.jab_actualizar_config(jsonb),
  public.jab_guardar_producto(jsonb), public.jab_ajustar_stock(bigint, int, text),
  public.jab_registrar_venta(jsonb), public.jab_registrar_abono(bigint, jsonb, uuid),
  public.jab_entregar_apartado(bigint, boolean), public.jab_extender_apartado(bigint, int),
  public.jab_cancelar_apartado(bigint, text), public.jab_registrar_cambio(jsonb),
  public.jab_anular_venta(bigint, text), public.jab_anular_pago(bigint, text, bigint),
  public.jab_registrar_movimiento(jsonb), public.jab_anular_movimiento(uuid),
  public.jab_saldos_cuentas(), public.jab_resumen_dia(date),
  public.jab_guardar_compra(jsonb), public.jab_pagar_compra(bigint, bigint, numeric, numeric, uuid),
  public.jab_paquete_estado(bigint, text, date), public.jab_anular_compra(bigint, text, boolean),
  public.jab_guardar_envio(jsonb), public.jab_pagar_flete(bigint, bigint, numeric, numeric, uuid),
  public.jab_anular_envio(bigint, text, boolean), public.jab_recibir_envio(jsonb),
  public.jab_reembolso_item(bigint, bigint, numeric, numeric, uuid),
  public.jab_envio_estado(bigint, text), public.jab_marcar_faltante(bigint, int, uuid),
  public.jab_registrar_cierre(jsonb), public.jab_revisar_cierre(bigint, boolean),
  public.jab_reporte(date, date), public.jab_sin_movimiento(int),
  public.jab_guardar_permisos(uuid, jsonb), public.jab_comisiones(date, date),
  public.jab_pagar_comision(uuid, bigint, numeric, numeric, uuid), public.jab_mi_comision(),
  public.jab_marcar_llegada(bigint, text), public.jab_renombrar_categoria(text, text),
  public.jab_foto_pago(bigint, text), public.jab_caja_hoy()
to authenticated;
