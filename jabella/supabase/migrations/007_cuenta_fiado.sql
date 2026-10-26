-- =====================================================================
-- JABELLA Store — entrega 6: cuenta de fiado por clienta.
-- Cada fiado sigue siendo su propia venta, pero se abona a la cuenta de la clienta: el abono se
-- reparte de la cuenta más vieja a la más nueva (cada pago se parte en pedazos, uno por venta,
-- todos con el mismo grupo_abono para el recibo).
-- Base compartida con Yumana: solo objetos jab_, nunca "all ... in schema public".
-- =====================================================================

alter table public.jab_pagos add column grupo_abono uuid;
create index on public.jab_pagos (grupo_abono) where grupo_abono is not null;

-- Cada pago guarda el grupo del abono a la cuenta (null en los pagos sueltos)
create or replace function public.jab__insertar_pagos(p_venta bigint, p_cliente bigint, p_pagos jsonb)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p jsonb;
  m record;
  v_usd numeric;
  v_monto numeric;
  v_tasa numeric;
  v_total numeric := 0;
  v_pago bigint;
  v_cfg_tasa numeric;
  v_cfg_fecha timestamptz;
  v_foto text;
  v_grupo uuid;
begin
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' then
    return 0;
  end if;
  select tasa_bs, tasa_actualizada_en into v_cfg_tasa, v_cfg_fecha from public.jab_config where id = 1;

  for p in select * from jsonb_array_elements(p_pagos) loop
    select mp.*, c.moneda as cuenta_moneda, c.activa as cuenta_activa
      into m
      from public.jab_metodos_pago mp left join public.jab_cuentas c on c.id = mp.cuenta_id
     where mp.id = (p->>'metodo_id')::bigint;
    if not found or not m.activo then
      raise exception 'Método de pago no válido.';
    end if;

    v_foto := public.jab__validar_comprobante(p->>'comprobante');
    v_grupo := nullif(p->>'grupo_abono', '')::uuid;
    v_usd := round((p->>'monto_usd')::numeric, 2);
    if v_usd is null or v_usd <= 0 then
      raise exception 'Cada pago debe ser mayor que cero.';
    end if;

    if m.es_saldo_favor then
      if p_cliente is null then
        raise exception 'Para pagar con saldo a favor elige la clienta.';
      end if;
      perform 1 from public.jab_clientes where id = p_cliente for update;
      if public.jab__saldo_favor(p_cliente) + 0.004 < v_usd then
        raise exception 'La clienta solo tiene % $ a favor.', to_char(public.jab__saldo_favor(p_cliente), 'FM999990.00');
      end if;
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id, comprobante, grupo_abono)
      values (p_venta, m.id, null, 'USD', v_usd, null, v_usd, nullif(p->>'referencia',''), auth.uid(), v_foto, v_grupo)
      returning id into v_pago;
      insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id, pago_id)
      values (p_cliente, -v_usd, 'Usado en la venta ' || public.jab__num(p_venta), p_venta, v_pago);
    else
      if not m.cuenta_activa then
        raise exception 'La cuenta del método "%" está desactivada.', m.nombre;
      end if;
      if m.cuenta_moneda = 'USD' then
        v_monto := v_usd;
        v_tasa := null;
      else
        v_tasa := (p->>'tasa')::numeric;
        v_monto := round((p->>'monto')::numeric, 2);
        if v_tasa is null or v_tasa <= 0 then
          raise exception 'Falta la tasa del día para cobrar en bolívares.';
        end if;
        if v_cfg_fecha is null or (v_cfg_fecha at time zone 'America/Caracas')::date < public.jab__hoy() then
          raise exception 'La tasa no se ha puesto hoy. Actualízala antes de cobrar en bolívares.';
        end if;
        if not public.jab_es_duena() and v_tasa <> v_cfg_tasa then
          raise exception 'La tasa del día cambió a %. Vuelve a calcular el cobro.', v_cfg_tasa;
        end if;
        if v_monto is null or v_monto <= 0 then
          raise exception 'Falta el monto en bolívares.';
        end if;
        -- El monto en Bs y su equivalente en $ deben cuadrar (tolerancia: medio centavo de $)
        if abs(v_monto - v_usd * v_tasa) > greatest(v_tasa * 0.005, 0.01) then
          raise exception 'El monto en Bs no cuadra con su equivalente en $.';
        end if;
      end if;
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id, comprobante, grupo_abono)
      values (p_venta, m.id, m.cuenta_id, m.cuenta_moneda, v_monto, v_tasa, v_usd, nullif(p->>'referencia',''), auth.uid(), v_foto, v_grupo);
    end if;

    v_total := v_total + v_usd;
  end loop;
  return v_total;
end $$;

-- Abono a la cuenta de una clienta: se aplica a sus fiados de la más vieja a la más nueva.
-- p_pagos = [{metodo_id, monto_usd, monto? (Bs), tasa?, referencia?, comprobante?}]
-- Devuelve {grupo, total, deuda_antes, deuda_despues, cuentas: [{venta_id, numero, creado_en, saldo_antes, abonado, saldo_despues}]}
create function public.jab_abonar_cliente(p_cliente bigint, p_pagos jsonb, p_clave uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prev jsonb;
  v_grupo uuid := gen_random_uuid();
  v_pagos jsonb[] := '{}';
  p jsonb;
  m record;
  n int;
  i int := 1;
  v_total numeric := 0;
  v_deuda numeric := 0;
  r record;
  v_saldo numeric;
  v_need numeric;
  v_take numeric;
  v_rest_usd numeric;
  v_rest_bs numeric;
  v_es_bs boolean;
  v_bs numeric;
  v_piezas jsonb;
  v_pieza jsonb;
  v_cuentas jsonb := '[]'::jsonb;
  v_despues numeric;
  v_res jsonb;
begin
  perform public.jab__exigir_activo();
  v_prev := public.jab__idem_inicio(p_clave, 'abono_cliente');
  if v_prev is not null then
    return v_prev;
  end if;
  if not exists (select 1 from public.jab_clientes where id = p_cliente and deleted_at is null) then
    raise exception 'Esa clienta no existe.';
  end if;
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' or jsonb_array_length(p_pagos) = 0 then
    raise exception 'Escribe el monto del abono.';
  end if;
  -- Cada pago: cuánto vale en $ y, si es en bolívares, cuánto en Bs (para repartirlo sin perder céntimos)
  for p in select * from jsonb_array_elements(p_pagos) loop
    select mp.es_saldo_favor, c.moneda into m
      from public.jab_metodos_pago mp left join public.jab_cuentas c on c.id = mp.cuenta_id
     where mp.id = (p->>'metodo_id')::bigint;
    if not found then
      raise exception 'Método de pago no válido.';
    end if;
    if round((p->>'monto_usd')::numeric, 2) is null or round((p->>'monto_usd')::numeric, 2) <= 0 then
      raise exception 'Cada pago debe ser mayor que cero.';
    end if;
    v_es_bs := not coalesce(m.es_saldo_favor, false) and m.moneda = 'VES';
    if v_es_bs and (nullif(p->>'monto', '') is null or (p->>'monto')::numeric <= 0) then
      raise exception 'Falta el monto en bolívares.';
    end if;
    v_pagos := v_pagos || (p || jsonb_build_object('monto_usd', round((p->>'monto_usd')::numeric, 2), 'es_bs', v_es_bs));
    v_total := v_total + round((p->>'monto_usd')::numeric, 2);
  end loop;
  n := array_length(v_pagos, 1);

  -- Bloquear los fiados de la clienta (en orden de id, como todo lo demás) y calcular lo que debe
  perform 1 from public.jab_ventas where cliente_id = p_cliente and tipo = 'fiado' and estado = 'activa' order by id for update;
  for r in select id, total from public.jab_ventas where cliente_id = p_cliente and tipo = 'fiado' and estado = 'activa' order by id loop
    v_deuda := v_deuda + greatest(r.total - public.jab__recalcular_pagado(r.id), 0);
  end loop;
  v_deuda := round(v_deuda, 2);
  if v_deuda <= 0.004 then
    raise exception 'Esta clienta no debe nada fiado.';
  end if;
  if v_total > v_deuda + 0.004 then
    raise exception 'El abono ($%) es mayor que lo que debe ($%).', v_total, v_deuda;
  end if;

  v_rest_usd := (v_pagos[1]->>'monto_usd')::numeric;
  v_rest_bs := case when (v_pagos[1]->>'es_bs')::boolean then round((v_pagos[1]->>'monto')::numeric, 2) end;
  -- De la más vieja a la más nueva
  for r in select id, numero, creado_en, total, pagado from public.jab_ventas
            where cliente_id = p_cliente and tipo = 'fiado' and estado = 'activa' and total - pagado > 0.004
            order by creado_en, id loop
    exit when i > n;
    v_saldo := round(r.total - r.pagado, 2);
    v_need := v_saldo;
    v_piezas := '[]'::jsonb;
    while v_need > 0.004 and i <= n loop
      v_take := least(v_need, v_rest_usd);
      v_pieza := (v_pagos[i] - 'es_bs') || jsonb_build_object('monto_usd', v_take, 'grupo_abono', v_grupo);
      if (v_pagos[i]->>'es_bs')::boolean then
        -- El último pedazo se lleva lo que queda en Bs; los otros, su parte proporcional
        v_bs := case when v_take >= v_rest_usd then v_rest_bs else round(v_rest_bs * v_take / v_rest_usd, 2) end;
        v_pieza := v_pieza || jsonb_build_object('monto', v_bs);
        v_rest_bs := v_rest_bs - v_bs;
      end if;
      v_piezas := v_piezas || v_pieza;
      v_need := v_need - v_take;
      v_rest_usd := v_rest_usd - v_take;
      if v_rest_usd <= 0.004 then
        i := i + 1;
        if i <= n then
          v_rest_usd := (v_pagos[i]->>'monto_usd')::numeric;
          v_rest_bs := case when (v_pagos[i]->>'es_bs')::boolean then round((v_pagos[i]->>'monto')::numeric, 2) end;
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_piezas) > 0 then
      perform public.jab__insertar_pagos(r.id, p_cliente, v_piezas);
      v_despues := round(r.total - public.jab__recalcular_pagado(r.id), 2);
      v_cuentas := v_cuentas || jsonb_build_object('venta_id', r.id, 'numero', r.numero, 'creado_en', r.creado_en,
                                                   'saldo_antes', v_saldo, 'abonado', v_saldo - v_despues, 'saldo_despues', v_despues);
    end if;
  end loop;
  if i <= n then
    raise exception 'El abono ($%) es mayor que lo que debe ($%).', v_total, v_deuda;
  end if;

  v_res := jsonb_build_object('grupo', v_grupo, 'total', v_total, 'deuda_antes', v_deuda,
                              'deuda_despues', round(v_deuda - v_total, 2), 'cuentas', v_cuentas);
  perform public.jab__idem_fin(p_clave, v_res);
  return v_res;
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
  public.jab_foto_pago(bigint, text), public.jab_caja_hoy(),
  public.jab_abonar_cliente(bigint, jsonb, uuid)
to authenticated;
