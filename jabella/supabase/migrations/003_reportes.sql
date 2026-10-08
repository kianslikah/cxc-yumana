-- =====================================================================
-- JABELLA Store — entrega 3: ganancias, cierre de caja y gastos del local
-- Ganancia bruta = ventas − costo de lo vendido (costo guardado al momento de cada venta).
-- Ganancia neta = bruta − gastos del local (sin mercancía ni flete, que ya están en el costo)
--                 + abonos que la tienda se quedó por apartados cancelados
--                 ± faltantes o sobrantes de caja que la dueña cuadró.
-- Base compartida con Yumana: solo objetos jab_, nunca "all ... in schema public".
-- =====================================================================

-- Qué cuentas se cuentan a mano al cerrar la caja (el efectivo)
alter table public.jab_cuentas add column cuenta_en_cierre boolean not null default false;
update public.jab_cuentas set cuenta_en_cierre = true where nombre in ('Efectivo $', 'Efectivo Bs');

insert into public.jab_contadores (nombre, valor) values ('cierre', 0);

create table public.jab_cierres (
  id bigint generated always as identity primary key,
  numero bigint not null unique,
  fecha date not null default ((now() at time zone 'America/Caracas')::date),
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now(),
  nota text,
  detalle jsonb not null,               -- [{cuenta_id, nombre, moneda, esperado, contado, diferencia}]
  diferencia_usd numeric(12,2) not null default 0,
  tasa numeric(14,4),                   -- tasa del día al cerrar (para pasar la diferencia en Bs a $)
  revisado_en timestamptz,
  revisado_por uuid,
  ajustado boolean not null default false,
  ajuste jsonb,                         -- correcciones aplicadas al cuadrar [{cuenta_id, nombre, moneda, monto}]
  nota_revision text
);
create index on public.jab_cierres (fecha);

alter table public.jab_cierres enable row level security;
-- Solo la dueña ve los cierres (traen lo que "debería haber"; la vendedora cuenta sin verlo)
create policy "solo_duena" on public.jab_cierres for select to authenticated using (public.jab_es_duena());

-- Saldo de una cuenta (pagos + movimientos vivos), en su moneda; con p_hasta, el que tenía en ese momento
create function public.jab__saldo_cuenta(p_cuenta bigint, p_hasta timestamptz default null) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(monto) from public.jab_pagos where cuenta_id = p_cuenta and anulado_en is null
                     and (p_hasta is null or creado_en <= p_hasta)), 0)
       + coalesce((select sum(monto) from public.jab_movimientos_dinero where cuenta_id = p_cuenta and anulado_en is null
                     and (p_hasta is null or creado_en <= p_hasta)), 0)
$$;

-- ---------------------------------------------------------------------
-- Cierre de caja: se cuenta el efectivo sin ver lo esperado
-- ---------------------------------------------------------------------
-- p = {clave?, nota?, conteos: [{cuenta_id, contado}]}
create function public.jab_registrar_cierre(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_prev jsonb;
  c public.jab_cuentas;
  v_contado numeric;
  v_esperado numeric;
  v_det jsonb := '[]'::jsonb;
  v_dif_usd numeric := 0;
  v_tasa numeric;
  v_id bigint;
begin
  perform public.jab__exigir_activo();
  v_prev := public.jab__idem_inicio(v_clave, 'cierre');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  select nullif(tasa_bs, 0) into v_tasa from public.jab_config where id = 1;
  if v_tasa is null and exists (select 1 from public.jab_cuentas where cuenta_en_cierre and activa and moneda = 'VES') then
    raise exception 'Primero pon la tasa del día.';
  end if;
  -- Bloquear las cuentas a contar para que el esperado no cambie mientras se registra
  perform 1 from public.jab_cuentas where cuenta_en_cierre and activa order by id for update;
  for c in select * from public.jab_cuentas where cuenta_en_cierre and activa order by orden, id loop
    select round((x->>'contado')::numeric, 2) into v_contado
      from jsonb_array_elements(coalesce(p->'conteos', '[]'::jsonb)) x where (x->>'cuenta_id')::bigint = c.id;
    if v_contado is null or v_contado < 0 then
      raise exception 'Escribe cuánto hay en %.', c.nombre;
    end if;
    v_esperado := round(public.jab__saldo_cuenta(c.id), 2);
    v_det := v_det || jsonb_build_object('cuenta_id', c.id, 'nombre', c.nombre, 'moneda', c.moneda,
                                         'esperado', v_esperado, 'contado', v_contado, 'diferencia', v_contado - v_esperado);
    v_dif_usd := v_dif_usd + case when c.moneda = 'VES' then (v_contado - v_esperado) / v_tasa else v_contado - v_esperado end;
  end loop;
  if jsonb_array_length(v_det) = 0 then
    raise exception 'No hay cuentas de efectivo marcadas para el cierre (Ajustes → Cuentas de dinero).';
  end if;
  insert into public.jab_cierres (numero, nota, detalle, diferencia_usd, tasa)
  values (public.jab__siguiente('cierre'), nullif(trim(p->>'nota'), ''), v_det, round(v_dif_usd, 2), v_tasa)
  returning id into v_id;
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_id));
  return v_id;
end $$;

-- La dueña revisa un cierre. Con p_ajustar = true, cada cuenta se corrige para que su saldo AL MOMENTO
-- DEL CIERRE quede igual a lo contado (recalculado desde los pagos y movimientos vivos, no desde la
-- diferencia guardada). Solo se cuadra el cierre más reciente: el saldo es acumulado, así que una
-- diferencia sin cuadrar se repite en los cierres siguientes; los anteriores pendientes quedan incluidos.
create function public.jab_revisar_cierre(p_cierre bigint, p_ajustar boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ci public.jab_cierres;
  d jsonb;
  v_tasa numeric;
  v_dif numeric;
  v_aj jsonb := '[]'::jsonb;
  v_nuevo bigint;
begin
  perform public.jab__exigir_duena();
  -- Mismo orden de bloqueo que jab_registrar_cierre: nadie cierra mientras se cuadra
  perform 1 from public.jab_cuentas where cuenta_en_cierre and activa order by id for update;
  select * into ci from public.jab_cierres where id = p_cierre for update;
  if not found then
    raise exception 'Ese cierre no existe.';
  end if;
  if ci.revisado_en is not null then
    raise exception 'Ese cierre ya fue revisado.';
  end if;
  if coalesce(p_ajustar, false) then
    select numero into v_nuevo from public.jab_cierres where id > ci.id order by id desc limit 1;
    if found then
      raise exception 'Hay un cierre más nuevo (#%): cuadra ese, que ya incluye esta diferencia.', v_nuevo;
    end if;
    select coalesce(ci.tasa, nullif(tasa_bs, 0)) into v_tasa from public.jab_config where id = 1;
    for d in select * from jsonb_array_elements(ci.detalle) loop
      v_dif := round((d->>'contado')::numeric - public.jab__saldo_cuenta((d->>'cuenta_id')::bigint, ci.creado_en), 2);
      if v_dif <> 0 then
        if d->>'moneda' = 'VES' and v_tasa is null then
          raise exception 'Falta la tasa para ajustar los bolívares.';
        end if;
        insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo)
        values ('ajuste', (d->>'cuenta_id')::bigint, v_dif, case when d->>'moneda' = 'VES' then v_tasa end,
                round(case when d->>'moneda' = 'VES' then v_dif / v_tasa else v_dif end, 2),
                'Cierre de caja', 'Diferencia del cierre #' || ci.numero, gen_random_uuid());
        v_aj := v_aj || jsonb_build_object('cuenta_id', d->'cuenta_id', 'nombre', d->'nombre', 'moneda', d->'moneda', 'monto', v_dif);
      end if;
    end loop;
    -- Los cierres anteriores sin revisar quedan cubiertos por este cuadre
    update public.jab_cierres set revisado_en = now(), revisado_por = auth.uid(),
           nota_revision = 'Incluido en el cuadre del cierre #' || ci.numero
     where id < ci.id and revisado_en is null;
  end if;
  update public.jab_cierres set revisado_en = now(), revisado_por = auth.uid(), ajustado = coalesce(p_ajustar, false),
         ajuste = case when coalesce(p_ajustar, false) then v_aj end
   where id = p_cierre;
  perform public.jab__auditar('cierres', p_cierre::text, 'revisar', to_jsonb(ci),
    jsonb_build_object('ajustado', coalesce(p_ajustar, false), 'ajuste', v_aj));
end $$;

-- ---------------------------------------------------------------------
-- Reporte de un período (solo la dueña: trae costos y ganancias)
-- ---------------------------------------------------------------------
create function public.jab_reporte(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  perform public.jab__exigir_duena();
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'Revisa las fechas del período.';
  end if;
  if p_hasta - p_desde > 400 then
    raise exception 'El período es muy largo (máximo un año).';
  end if;

  with v as (
    select * from public.jab_ventas
     where estado = 'activa' and (creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta
  ), li as (
    select vi.*, vc.costo, (v.creado_en at time zone 'America/Caracas')::date as dia, v.usuario_id
      from public.jab_venta_items vi
      join v on v.id = vi.venta_id
      -- Lo devuelto en un cambio vale lo que costó en su venta original (aunque entonces no tuviera costo)
      left join public.jab_venta_item_costos vc on vc.venta_item_id = coalesce(vi.item_origen_id, vi.id)
  ), dias as (
    select d::date as dia from generate_series(p_desde, p_hasta, interval '1 day') d
  ), gastos as (
    select coalesce(categoria, 'Otros') as categoria, -sum(monto_usd) as total
      from public.jab_movimientos_dinero
     where tipo = 'gasto' and not es_inversion and anulado_en is null
       and (creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta
     group by 1
  )
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'ventas_n', (select count(*) from v where tipo <> 'cambio'),
    'prendas', (select coalesce(sum(cantidad), 0) from li),
    'ventas', (select coalesce(sum(total), 0) from v),
    'ventas_con_costo', (select coalesce(round(sum(cantidad * precio), 2), 0) from li where costo is not null),
    'costo', (select coalesce(round(sum(cantidad * costo), 2), 0) from li where costo is not null),
    'piezas_sin_costo', (select coalesce(sum(cantidad), 0) from li where costo is null),
    'ventas_sin_costo', (select coalesce(round(sum(cantidad * precio), 2), 0) from li where costo is null),
    'gastos', coalesce((select round(sum(total), 2) from gastos), 0),
    'gastos_por_categoria', coalesce((select jsonb_agg(jsonb_build_object('categoria', categoria, 'total', round(total, 2)) order by total desc) from gastos), '[]'::jsonb),
    'abonos_retenidos', (select coalesce(sum(abono_retenido), 0) from public.jab_ventas
                          where estado = 'cancelada' and (cancelada_en at time zone 'America/Caracas')::date between p_desde and p_hasta),
    'invertido', (select coalesce(round(-sum(monto_usd), 2), 0) from public.jab_movimientos_dinero
                   where es_inversion and tipo in ('gasto', 'ingreso') and anulado_en is null
                     and (creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta),
    'descuadres', (select coalesce(round(sum(monto_usd), 2), 0) from public.jab_movimientos_dinero
                    where tipo = 'ajuste' and categoria = 'Cierre de caja' and anulado_en is null
                      and (creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta),
    'cobrado', (select coalesce(sum(monto_usd), 0) from public.jab_pagos
                 where anulado_en is null and cuenta_id is not null
                   and (creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta),
    'por_dia', (select jsonb_agg(jsonb_build_object(
                   'dia', d.dia,
                   'ventas', coalesce((select sum(total) from v where (v.creado_en at time zone 'America/Caracas')::date = d.dia), 0),
                   'ganancia', coalesce((select round(sum(cantidad * (precio - costo)), 2) from li where li.dia = d.dia and costo is not null), 0))
                 order by d.dia) from dias d),
    'top', coalesce((select jsonb_agg(x order by (x->>'unidades')::int desc, (x->>'ventas')::numeric desc) from (
              select jsonb_build_object('producto_id', li.producto_id, 'nombre', pr.nombre,
                       'unidades', sum(li.cantidad), 'ventas', round(sum(li.cantidad * li.precio), 2),
                       'ganancia', round(sum(case when li.costo is not null then li.cantidad * (li.precio - li.costo) end), 2)) x
                from li join public.jab_productos pr on pr.id = li.producto_id
               group by li.producto_id, pr.nombre
              having sum(li.cantidad) > 0
               order by sum(li.cantidad) desc, sum(li.cantidad * li.precio) desc
               limit 15) t), '[]'::jsonb),
    'por_vendedora', coalesce((select jsonb_agg(jsonb_build_object('nombre', coalesce(u.nombre, '—'), 'ventas_n', s.n, 'total', s.total) order by s.total desc)
                       from (select usuario_id, count(*) filter (where tipo <> 'cambio') as n, sum(total) as total from v group by usuario_id) s
                       left join public.jab_usuarios u on u.id = s.usuario_id), '[]'::jsonb),
    'por_cobrar', (select coalesce(sum(total - pagado), 0) from public.jab_ventas
                    where estado = 'activa' and tipo in ('apartado','fiado') and total - pagado > 0)
  ) into r;
  return r;
end $$;

-- Prendas con existencia que no se venden hace tiempo: días desde su última venta o desde que entró
-- mercancía (carga inicial o compra), lo que sea más reciente. Devuelve jsonb (sin el corte de 1000 filas).
create function public.jab_sin_movimiento(p_dias int) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  perform public.jab__exigir_duena();
  select coalesce(jsonb_agg(to_jsonb(x) order by x.dias desc, x.stock desc), '[]'::jsonb) into r from (
    select pr.id as producto_id, pr.nombre, pr.codigo, pr.categoria, s.stock, pr.precio, pc.costo, u.ultima as ultima_venta,
           (public.jab__hoy() - greatest(coalesce(u.ultima, (pr.creado_en at time zone 'America/Caracas')::date),
                                         coalesce(en.ultima, (pr.creado_en at time zone 'America/Caracas')::date)))::int as dias
      from public.jab_productos pr
      join lateral (select sum(va.stock) as stock from public.jab_variantes va where va.producto_id = pr.id and va.activo) s on true
      left join public.jab_producto_costos pc on pc.producto_id = pr.id
      left join lateral (select max((ve.creado_en at time zone 'America/Caracas')::date) as ultima
                           from public.jab_venta_items vi join public.jab_ventas ve on ve.id = vi.venta_id
                          where vi.producto_id = pr.id and vi.cantidad > 0 and ve.estado = 'activa') u on true
      left join lateral (select max((mi.creado_en at time zone 'America/Caracas')::date) as ultima
                           from public.jab_movimientos_inventario mi join public.jab_variantes va on va.id = mi.variante_id
                          where va.producto_id = pr.id and mi.tipo in ('inicial', 'compra') and mi.cantidad > 0) en on true
     where pr.activo and s.stock > 0
  ) x
  where x.dias >= coalesce(p_dias, 30);
  return r;
end $$;

-- Resumen del día: lo cobrado por método solo lo ve la dueña (así el cierre de la vendedora es a ciegas)
create or replace function public.jab_resumen_dia(p_fecha date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb; v_duena boolean;
begin
  perform public.jab__exigir_activo();
  v_duena := public.jab_es_duena();
  select jsonb_build_object(
    'ventas', (select count(*) from public.jab_ventas
                where (creado_en at time zone 'America/Caracas')::date = p_fecha
                  and estado = 'activa' and tipo <> 'cambio'),
    'vendido', (select coalesce(sum(total), 0) from public.jab_ventas
                where (creado_en at time zone 'America/Caracas')::date = p_fecha
                  and estado = 'activa'),
    'prendas', (select coalesce(sum(vi.cantidad), 0) from public.jab_venta_items vi join public.jab_ventas v on v.id = vi.venta_id
                where (v.creado_en at time zone 'America/Caracas')::date = p_fecha and v.estado = 'activa'),
    'cobrado_usd', case when v_duena then (select coalesce(sum(monto_usd), 0) from public.jab_pagos
                where (creado_en at time zone 'America/Caracas')::date = p_fecha and anulado_en is null and cuenta_id is not null) end,
    'por_metodo', case when v_duena then coalesce((select jsonb_agg(x order by x->>'metodo') from (
                  select jsonb_build_object('metodo', mp.nombre, 'moneda', pg.moneda,
                         'monto', sum(pg.monto), 'monto_usd', sum(pg.monto_usd), 'n', count(*)) x
                    from public.jab_pagos pg join public.jab_metodos_pago mp on mp.id = pg.metodo_id
                   where (pg.creado_en at time zone 'America/Caracas')::date = p_fecha and pg.anulado_en is null
                   group by mp.nombre, pg.moneda) s), '[]'::jsonb) else '[]'::jsonb end
  ) into r;
  return r;
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
  public.jab_reporte(date, date), public.jab_sin_movimiento(int)
to authenticated;
