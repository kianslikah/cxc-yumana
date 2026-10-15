-- =====================================================================
-- JABELLA Store — entrega 4: perfiles con correo y permisos por usuaria,
-- comisión de la vendedora, prendas por llegar, límite de fiado por clienta,
-- foto del comprobante de cada pago y renombrar categorías.
-- Base compartida con Yumana: solo objetos jab_, nunca "all ... in schema public".
-- =====================================================================

-- ---------------------------------------------------------------------
-- Usuarias: correo para entrar, permisos por persona y % de comisión
-- ---------------------------------------------------------------------
alter table public.jab_usuarios
  add column correo text unique,
  add column permisos jsonb not null default '{}'::jsonb,
  add column comision_pct numeric(5,2) not null default 0 check (comision_pct between 0 and 50);
update public.jab_usuarios u set correo = lower(a.email) from auth.users a where a.id = u.id and u.correo is null;

-- Lo que puede hacer quien está conectada. La dueña puede todo; la vendedora, lo que la dueña le marque.
-- Si no se le marcó nada: aparta y hace cambios, no cambia precios, y fía según la regla general de la tienda.
create function public.jab__puede(p_permiso text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case when u.rol = 'duena' then true
                else coalesce((u.permisos->>p_permiso)::boolean,
                              case p_permiso when 'apartar' then true
                                             when 'cambios' then true
                                             when 'fiar' then (select vendedora_fia from public.jab_config where id = 1)
                                             else false end) end
      from public.jab_usuarios u where u.id = auth.uid() and u.activo), false)
$$;

-- p = {permisos: {apartar?, fiar?, cambios?, descuentos?}, comision_pct?}
create function public.jab_guardar_permisos(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_antes jsonb;
  k text;
  v_perm jsonb := '{}'::jsonb;
  v_pct numeric;
begin
  perform public.jab__exigir_duena();
  select to_jsonb(u) into v_antes from public.jab_usuarios u where id = p_id for update;
  if v_antes is null then
    raise exception 'Ese usuario no existe.';
  end if;
  foreach k in array array['apartar', 'fiar', 'cambios', 'descuentos'] loop
    if coalesce(p->'permisos', '{}'::jsonb) ? k then
      if jsonb_typeof(p->'permisos'->k) <> 'boolean' then
        raise exception 'Permiso no válido: %.', k;
      end if;
      v_perm := v_perm || jsonb_build_object(k, p->'permisos'->k);
    end if;
  end loop;
  v_pct := coalesce(round(nullif(p->>'comision_pct', '')::numeric, 2), (v_antes->>'comision_pct')::numeric);
  if v_pct < 0 or v_pct > 50 then
    raise exception 'La comisión debe estar entre 0 y 50 por ciento.';
  end if;
  update public.jab_usuarios set permisos = permisos || v_perm, comision_pct = v_pct where id = p_id;
  perform public.jab__auditar('usuarios', p_id::text, 'permisos',
    jsonb_build_object('permisos', v_antes->'permisos', 'comision_pct', v_antes->'comision_pct'),
    (select jsonb_build_object('permisos', permisos, 'comision_pct', comision_pct) from public.jab_usuarios where id = p_id));
end $$;

-- ---------------------------------------------------------------------
-- Quién vendió y su comisión (fija al momento de la venta)
-- ---------------------------------------------------------------------
alter table public.jab_ventas
  add column vendedora_id uuid references public.jab_usuarios(id),
  add column comision_pct numeric(5,2) not null default 0 check (comision_pct between 0 and 50);
update public.jab_ventas set vendedora_id = usuario_id where vendedora_id is null;
create index on public.jab_ventas (vendedora_id);

-- Toda venta queda a nombre de quién la vendió (si no se dice, quien la registró; cambios incluidos)
create function public.jab__trg_venta_vendedora() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.vendedora_id := coalesce(new.vendedora_id, new.usuario_id);
  return new;
end $$;
create trigger trg_jab_venta_vendedora before insert on public.jab_ventas
  for each row execute function public.jab__trg_venta_vendedora();

-- El pago de una comisión sale de una cuenta y queda ligado a la vendedora (si se anula en Dinero, vuelve a deberse)
alter table public.jab_movimientos_dinero add column comision_usuario_id uuid references public.jab_usuarios(id);

-- Lo ganado: ventas de contado activas a su nombre, con el % que tenía ese día
create function public.jab__comision(p_usuario uuid, p_desde date, p_hasta date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('ventas_n', count(*), 'vendido', coalesce(sum(total), 0),
                            'comision', coalesce(sum(round(total * comision_pct / 100, 2)), 0))
    from public.jab_ventas
   where vendedora_id = p_usuario and tipo = 'contado' and estado = 'activa'
     and (p_desde is null or (creado_en at time zone 'America/Caracas')::date >= p_desde)
     and (p_hasta is null or (creado_en at time zone 'America/Caracas')::date <= p_hasta)
$$;

create function public.jab__comision_pagada(p_usuario uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(-sum(monto_usd), 0) from public.jab_movimientos_dinero
   where comision_usuario_id = p_usuario and anulado_en is null
$$;

-- Comisiones de un período (solo la dueña), con lo ganado y pagado desde siempre
create function public.jab_comisiones(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  perform public.jab__exigir_duena();
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'Revisa las fechas del período.';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'usuario_id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'activo', u.activo, 'pct', u.comision_pct,
      'periodo', public.jab__comision(u.id, p_desde, p_hasta),
      'ganada', (public.jab__comision(u.id, null, null)->>'comision')::numeric,
      'pagada', public.jab__comision_pagada(u.id),
      'ventas', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'numero', v.numero, 'creado_en', v.creado_en,
                                   'total', v.total, 'pct', v.comision_pct, 'comision', round(v.total * v.comision_pct / 100, 2))
                                   order by v.creado_en desc)
                            from public.jab_ventas v
                           where v.vendedora_id = u.id and v.tipo = 'contado' and v.estado = 'activa'
                             and (v.creado_en at time zone 'America/Caracas')::date between p_desde and p_hasta), '[]'::jsonb))
      order by u.nombre), '[]'::jsonb) into r
    from public.jab_usuarios u
   where u.comision_pct > 0
      or exists (select 1 from public.jab_ventas v where v.vendedora_id = u.id and v.comision_pct > 0)
      or exists (select 1 from public.jab_movimientos_dinero m where m.comision_usuario_id = u.id);
  return r;
end $$;

-- La dueña paga comisión: sale de una cuenta como gasto "Comisiones". Nunca más de lo que se debe.
create function public.jab_pagar_comision(p_usuario uuid, p_cuenta bigint, p_monto numeric, p_tasa numeric default null, p_clave uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u public.jab_usuarios;
  c public.jab_cuentas;
  v_prev jsonb;
  v_grupo uuid := gen_random_uuid();
  v_monto numeric := round(p_monto, 2);
  v_tasa numeric := p_tasa;
  v_usd numeric;
  v_debe numeric;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(p_clave, 'pago_comision');
  if v_prev is not null then
    return (v_prev->>'grupo')::uuid;
  end if;
  -- Bloquear a la vendedora: dos pagos a la vez no pasan del total que se le debe
  select * into u from public.jab_usuarios where id = p_usuario for update;
  if not found then
    raise exception 'Esa vendedora no existe.';
  end if;
  select * into c from public.jab_cuentas where id = p_cuenta;
  if not found then
    raise exception 'Elige la cuenta.';
  end if;
  if not c.activa then
    raise exception 'Esa cuenta está desactivada.';
  end if;
  if v_monto is null or v_monto <= 0 then
    raise exception 'Escribe un monto válido.';
  end if;
  if c.moneda = 'VES' then
    if v_tasa is null then
      select nullif(tasa_bs, 0) into v_tasa from public.jab_config
       where id = 1 and (tasa_actualizada_en at time zone 'America/Caracas')::date = public.jab__hoy();
    end if;
    if v_tasa is null or v_tasa <= 0 then
      raise exception 'Falta la tasa del día.';
    end if;
    v_usd := round(v_monto / v_tasa, 2);
  else
    v_tasa := null;
    v_usd := v_monto;
  end if;
  v_debe := (public.jab__comision(u.id, null, null)->>'comision')::numeric - public.jab__comision_pagada(u.id);
  if v_usd > v_debe + 0.01 then
    raise exception 'A % se le deben $% de comisión.', u.nombre, round(greatest(v_debe, 0), 2);
  end if;
  insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo, comision_usuario_id)
  values ('gasto', c.id, -v_monto, v_tasa, -v_usd, 'Comisiones', 'Comisión de ' || u.nombre, v_grupo, u.id);
  perform public.jab__auditar('comisiones', u.id::text, 'pagar', jsonb_build_object('debia', round(v_debe, 2)),
    jsonb_build_object('pagado_usd', v_usd, 'cuenta', c.nombre, 'grupo', v_grupo));
  perform public.jab__idem_fin(p_clave, jsonb_build_object('grupo', v_grupo));
  return v_grupo;
end $$;

-- Cada usuaria ve su propia comisión: hoy, esta semana, este mes y lo que se le debe
create function public.jab_mi_comision() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_hoy date := public.jab__hoy();
  u public.jab_usuarios;
begin
  perform public.jab__exigir_activo();
  select * into u from public.jab_usuarios where id = auth.uid();
  return jsonb_build_object(
    'pct', u.comision_pct,
    'hoy', public.jab__comision(u.id, v_hoy, v_hoy),
    'semana', public.jab__comision(u.id, v_hoy - (extract(isodow from v_hoy)::int - 1), v_hoy),
    'mes', public.jab__comision(u.id, date_trunc('month', v_hoy)::date, v_hoy),
    'ganada', (public.jab__comision(u.id, null, null)->>'comision')::numeric,
    'pagada', public.jab__comision_pagada(u.id));
end $$;

-- ---------------------------------------------------------------------
-- Prendas que todavía no llegan a la tienda: solo se apartan
-- ---------------------------------------------------------------------
alter table public.jab_productos add column por_llegar boolean not null default false;
create index on public.jab_productos (por_llegar) where por_llegar;
update public.jab_productos set por_llegar = true where lower(trim(categoria)) = 'pendiente por llegar' and not por_llegar;

-- La prenda llegó: se puede vender y entregar. Si estaba en la categoría "pendiente por llegar", se le pone la real.
create function public.jab_marcar_llegada(p_producto bigint, p_categoria text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pr public.jab_productos;
  v_cat text := nullif(trim(p_categoria), '');
begin
  perform public.jab__exigir_duena();
  select * into pr from public.jab_productos where id = p_producto for update;
  if not found then
    raise exception 'Esa prenda no existe.';
  end if;
  if v_cat is null and lower(trim(pr.categoria)) = 'pendiente por llegar' then
    raise exception 'Elige la categoría de "%".', pr.nombre;
  end if;
  update public.jab_productos set por_llegar = false, categoria = coalesce(v_cat, categoria), actualizado_en = now()
   where id = p_producto;
  perform public.jab__auditar('productos', p_producto::text, 'llego',
    jsonb_build_object('por_llegar', pr.por_llegar, 'categoria', pr.categoria),
    jsonb_build_object('por_llegar', false, 'categoria', coalesce(v_cat, pr.categoria)));
end $$;

-- Renombrar o unir categorías (todas las prendas de una pasan a la otra)
create function public.jab_renombrar_categoria(p_de text, p_a text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_a text := nullif(trim(p_a), '');
  n int;
begin
  perform public.jab__exigir_duena();
  if v_a is null then
    raise exception 'Escribe el nombre nuevo de la categoría.';
  end if;
  update public.jab_productos set categoria = v_a, actualizado_en = now() where categoria = p_de;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'No hay prendas en la categoría "%".', p_de;
  end if;
  perform public.jab__auditar('productos', 'categoria', 'renombrar_categoria',
    jsonb_build_object('categoria', p_de, 'prendas', n), jsonb_build_object('categoria', v_a));
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Límite de fiado por clienta (lo pone la dueña; aplica a la vendedora)
-- ---------------------------------------------------------------------
alter table public.jab_clientes add column limite_fiado numeric(12,2) check (limite_fiado >= 0);

create or replace function public.jab__proteger_cliente() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.limite_fiado is not null and not public.jab_es_duena() then
      raise exception 'Solo la dueña pone el límite de fiado.';
    end if;
    return new;
  end if;
  if new.deleted_at is distinct from old.deleted_at and not public.jab_es_duena() then
    raise exception 'Solo la dueña puede borrar una clienta.';
  end if;
  if new.limite_fiado is distinct from old.limite_fiado and not public.jab_es_duena() then
    raise exception 'Solo la dueña puede cambiar el límite de fiado.';
  end if;
  return new;
end $$;
create trigger trg_proteger_cliente_nueva before insert on public.jab_clientes
  for each row execute function public.jab__proteger_cliente();

-- Después de dejar algo fiado: si la clienta pasa su límite, la vendedora no puede (la dueña sí)
create function public.jab__revisar_limite(p_cliente bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_lim numeric;
  v_nombre text;
  v_deuda numeric;
begin
  if p_cliente is null or public.jab_es_duena() then
    return;
  end if;
  select limite_fiado, nombre into v_lim, v_nombre from public.jab_clientes where id = p_cliente for update;
  if v_lim is null then
    return;
  end if;
  select coalesce(sum(total - pagado), 0) into v_deuda from public.jab_ventas
   where cliente_id = p_cliente and estado = 'activa' and tipo = 'fiado' and total - pagado > 0.004;
  if v_deuda > v_lim + 0.004 then
    raise exception 'Con esto % debería $% y su límite de fiado es $%. Pídele a la dueña que lo autorice.',
      v_nombre, round(v_deuda, 2), v_lim;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Foto del comprobante de cada pago (billetes, captura del pago móvil o Zelle)
-- Bucket privado: solo el personal activo sube y ve; nadie borra.
-- ---------------------------------------------------------------------
alter table public.jab_pagos add column comprobante text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('jab-comprobantes', 'jab-comprobantes', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "jabella_comprobantes_subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'jab-comprobantes' and public.jab_es_activo());
create policy "jabella_comprobantes_ver" on storage.objects for select to authenticated
  using (bucket_id = 'jab-comprobantes' and public.jab_es_activo());

create function public.jab__validar_comprobante(p_ruta text) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if nullif(p_ruta, '') is null then
    return null;
  end if;
  if p_ruta !~ '^c/[0-9]+-[a-z0-9]+\.jpg$' then
    raise exception 'Foto del pago no válida.';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'jab-comprobantes' and name = p_ruta) then
    raise exception 'La foto del pago no se subió. Vuelve a tomarla.';
  end if;
  return p_ruta;
end $$;

-- Agregar la foto después (si no se tomó al cobrar). Cambiarla, solo la dueña.
create function public.jab_foto_pago(p_pago bigint, p_ruta text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pg public.jab_pagos;
  v_ruta text;
begin
  perform public.jab__exigir_activo();
  v_ruta := public.jab__validar_comprobante(p_ruta);
  if v_ruta is null then
    raise exception 'Toma la foto del pago.';
  end if;
  select * into pg from public.jab_pagos where id = p_pago for update;
  if not found then
    raise exception 'Ese pago no existe.';
  end if;
  if pg.comprobante is not null and not public.jab_es_duena() then
    raise exception 'Ese pago ya tiene foto. Solo la dueña puede cambiarla.';
  end if;
  update public.jab_pagos set comprobante = v_ruta where id = p_pago;
  perform public.jab__auditar('pagos', p_pago::text, 'foto_comprobante',
    jsonb_build_object('comprobante', pg.comprobante), jsonb_build_object('comprobante', v_ruta));
end $$;

-- ---------------------------------------------------------------------
-- Funciones existentes con los cambios de esta entrega
-- ---------------------------------------------------------------------
create or replace function public.jab__agregar_item(p_venta bigint, p_variante bigint, p_cantidad int, p_precio numeric,
                                     p_tipo_mov text, p_item_origen bigint, p_costo numeric)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v record;
  v_precio numeric;
  v_item bigint;
  v_desc text;
  v_costo numeric;
begin
  select va.id, va.talla, va.color, va.producto_id, va.activo as var_activa, pr.nombre, pr.precio, pr.activo as prod_activo, pr.por_llegar
    into v
    from public.jab_variantes va join public.jab_productos pr on pr.id = va.producto_id
   where va.id = p_variante;
  if not found then
    raise exception 'La prenda no existe.';
  end if;

  if p_cantidad > 0 and (not v.var_activa or not v.prod_activo) then
    raise exception 'La prenda "%" está archivada. Actívala en Inventario para venderla.', v.nombre;
  end if;
  -- Lo que todavía no ha llegado a la tienda solo se aparta (no se entrega ni se cambia)
  if p_cantidad > 0 and v.por_llegar and p_tipo_mov <> 'apartado' then
    raise exception 'Todavía no llegó "%": solo se puede apartar.', v.nombre;
  end if;

  v_precio := round(coalesce(p_precio, v.precio), 2);
  if v_precio < 0 then
    raise exception 'El precio no puede ser negativo.';
  end if;
  if p_item_origen is null and v_precio <> v.precio and not public.jab__puede('descuentos') then
    raise exception 'No tienes permiso para cambiar el precio de %. Pídeselo a la dueña.', v.nombre;
  end if;

  v_desc := v.nombre
         || case when v.talla <> '' then ' · ' || v.talla else '' end
         || case when v.color <> '' then ' · ' || v.color else '' end;

  insert into public.jab_venta_items (venta_id, variante_id, producto_id, descripcion, cantidad, precio, precio_lista, item_origen_id)
  values (p_venta, v.id, v.producto_id, v_desc, p_cantidad, v_precio, v.precio, p_item_origen)
  returning id into v_item;

  v_costo := coalesce(p_costo, (select costo from public.jab_producto_costos where producto_id = v.producto_id));
  insert into public.jab_venta_item_costos (venta_item_id, costo) values (v_item, v_costo);

  perform public.jab__mover_stock(v.id, -p_cantidad, p_tipo_mov, p_venta, null);
  return round(p_cantidad * v_precio, 2);
end $$;

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
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id, comprobante)
      values (p_venta, m.id, null, 'USD', v_usd, null, v_usd, nullif(p->>'referencia',''), auth.uid(), v_foto)
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
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id, comprobante)
      values (p_venta, m.id, m.cuenta_id, m.cuenta_moneda, v_monto, v_tasa, v_usd, nullif(p->>'referencia',''), auth.uid(), v_foto);
    end if;

    v_total := v_total + v_usd;
  end loop;
  return v_total;
end $$;

create or replace function public.jab_guardar_producto(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_antes jsonb;
  v jsonb;
  v_var bigint;
  v_stock int;
  v_costo_antes numeric;
  v_prev jsonb;
  v_clave uuid := case when nullif(p->>'id', '') is null then nullif(p->>'clave', '')::uuid end;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(v_clave, 'producto');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  if coalesce(trim(p->>'nombre'), '') = '' then
    raise exception 'Escribe el nombre de la prenda.';
  end if;
  if (p->>'precio') is null or (p->>'precio')::numeric < 0 then
    raise exception 'Escribe el precio de venta.';
  end if;

  if v_id is null then
    insert into public.jab_productos (nombre, categoria, precio, foto, foto_mini, notas, activo, por_llegar)
    values (trim(p->>'nombre'), coalesce(nullif(trim(p->>'categoria'), ''), 'Otros'),
            round((p->>'precio')::numeric, 2), nullif(p->>'foto', ''), nullif(p->>'foto_mini', ''),
            nullif(trim(p->>'notas'), ''), coalesce((p->>'activo')::boolean, true),
            coalesce((p->>'por_llegar')::boolean, false) or coalesce(lower(trim(p->>'categoria')) = 'pendiente por llegar', false))
    returning id into v_id;
  else
    select to_jsonb(pr) into v_antes from public.jab_productos pr where id = v_id for update;
    if v_antes is null then
      raise exception 'Esa prenda no existe.';
    end if;
    update public.jab_productos set
      nombre = trim(p->>'nombre'),
      categoria = coalesce(nullif(trim(p->>'categoria'), ''), 'Otros'),
      precio = round((p->>'precio')::numeric, 2),
      foto = case when p ? 'foto' then nullif(p->>'foto', '') else foto end,
      foto_mini = case when p ? 'foto_mini' then nullif(p->>'foto_mini', '') else foto_mini end,
      notas = nullif(trim(p->>'notas'), ''),
      activo = coalesce((p->>'activo')::boolean, activo),
      -- La categoría "pendiente por llegar" siempre marca la prenda como por llegar
      por_llegar = coalesce((p->>'por_llegar')::boolean, por_llegar) or coalesce(lower(trim(p->>'categoria')) = 'pendiente por llegar', false),
      actualizado_en = now()
    where id = v_id;
    if (v_antes->>'precio')::numeric <> round((p->>'precio')::numeric, 2) then
      perform public.jab__auditar('productos', v_id::text, 'cambio_precio',
        jsonb_build_object('precio', v_antes->'precio'), jsonb_build_object('precio', round((p->>'precio')::numeric, 2)));
    end if;
  end if;

  -- Costo (opcional)
  if p ? 'costo' and nullif(p->>'costo', '') is not null then
    if (p->>'costo')::numeric < 0 then
      raise exception 'El costo no puede ser negativo.';
    end if;
    select costo into v_costo_antes from public.jab_producto_costos where producto_id = v_id;
    if v_costo_antes is distinct from round((p->>'costo')::numeric, 4) then
      insert into public.jab_producto_costos (producto_id, costo) values (v_id, round((p->>'costo')::numeric, 4))
      on conflict (producto_id) do update set costo = excluded.costo, actualizado_en = now();
      perform public.jab__auditar('producto_costos', v_id::text, 'costo',
        jsonb_build_object('costo', v_costo_antes), jsonb_build_object('costo', round((p->>'costo')::numeric, 4)));
    end if;
  end if;

  -- Tallas / colores
  for v in select * from jsonb_array_elements(coalesce(p->'variantes', '[]'::jsonb)) loop
    v_var := nullif(v->>'id', '')::bigint;
    if v_var is null then
      insert into public.jab_variantes (producto_id, talla, color, activo)
      values (v_id, coalesce(trim(v->>'talla'), ''), coalesce(trim(v->>'color'), ''), coalesce((v->>'activo')::boolean, true))
      returning id into v_var;
      v_stock := coalesce((v->>'stock')::int, 0);
      if v_stock < 0 then
        raise exception 'La existencia no puede ser negativa.';
      end if;
      if v_stock > 0 then
        perform public.jab__mover_stock(v_var, v_stock, 'inicial', null, null);
      end if;
    else
      update public.jab_variantes set
        talla = coalesce(trim(v->>'talla'), ''),
        color = coalesce(trim(v->>'color'), ''),
        activo = coalesce((v->>'activo')::boolean, activo)
      where id = v_var and producto_id = v_id;
      if not found then
        raise exception 'Talla/color no pertenece a esta prenda.';
      end if;
    end if;
  end loop;

  if not exists (select 1 from public.jab_variantes where producto_id = v_id) then
    raise exception 'Agrega al menos una talla (o "Única").';
  end if;
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_id));
  return v_id;
exception
  when unique_violation then
    raise exception 'Hay una talla/color repetida en esta prenda.';
end $$;

create or replace function public.jab_registrar_venta(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_tipo text := p->>'tipo';
  v_cliente bigint := nullif(p->>'cliente_id', '')::bigint;
  v_cfg public.jab_config;
  v_venta bigint;
  it jsonb;
  v_total numeric := 0;
  v_pagado numeric;
  v_cant int;
  v_minimo numeric;
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_prev jsonb;
  v_vend uuid := coalesce(nullif(p->>'vendedora_id', '')::uuid, auth.uid());
begin
  perform public.jab__exigir_activo();
  v_prev := public.jab__idem_inicio(v_clave, 'venta');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  if v_tipo is null or v_tipo not in ('contado','apartado','fiado') then
    raise exception 'Tipo de venta no válido.';
  end if;
  if v_tipo in ('apartado','fiado') and v_cliente is null then
    raise exception 'Elige la clienta para el %.', v_tipo;
  end if;
  if v_cliente is not null and not exists (select 1 from public.jab_clientes where id = v_cliente and deleted_at is null) then
    raise exception 'Esa clienta no existe.';
  end if;
  select * into v_cfg from public.jab_config where id = 1;
  if v_tipo = 'apartado' and not public.jab__puede('apartar') then
    raise exception 'No tienes permiso para apartar. Pídeselo a la dueña.';
  end if;
  if v_tipo = 'fiado' and not public.jab__puede('fiar') then
    raise exception 'No tienes permiso para vender fiado. Pídeselo a la dueña.';
  end if;
  -- Quién vendió (para la comisión): la propia usuaria, o la que elija la dueña
  if v_vend <> auth.uid() then
    if not public.jab_es_duena() then
      raise exception 'Solo la dueña puede anotar una venta a nombre de otra persona.';
    end if;
    if not exists (select 1 from public.jab_usuarios where id = v_vend and activo) then
      raise exception 'Esa vendedora no existe o no está activa.';
    end if;
  end if;
  if coalesce(jsonb_typeof(p->'items'), '') <> 'array' or jsonb_array_length(p->'items') = 0 then
    raise exception 'La venta no tiene prendas.';
  end if;

  insert into public.jab_ventas (numero, tipo, cliente_id, entregada, entregada_en, vence_en, era_apartado, nota, usuario_id,
                                 vendedora_id, comision_pct)
  values (public.jab__siguiente('venta'), v_tipo, v_cliente, v_tipo <> 'apartado', case when v_tipo <> 'apartado' then now() end,
          case when v_tipo = 'apartado' then public.jab__hoy() + v_cfg.dias_apartado end,
          v_tipo = 'apartado', nullif(trim(p->>'nota'), ''), auth.uid(), v_vend,
          -- La comisión es solo de lo cobrado completo en el momento (contado); el % queda fijo en la venta
          case when v_tipo = 'contado' then (select comision_pct from public.jab_usuarios where id = v_vend) else 0 end)
  returning id into v_venta;

  perform public.jab__bloquear_variantes(array(select (x->>'variante_id')::bigint from jsonb_array_elements(p->'items') x));

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cant := (it->>'cantidad')::int;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad no válida.';
    end if;
    v_total := v_total + public.jab__agregar_item(v_venta, (it->>'variante_id')::bigint, v_cant,
                 nullif(it->>'precio', '')::numeric,
                 case when v_tipo = 'apartado' then 'apartado' else 'venta' end, null, null);
  end loop;

  update public.jab_ventas set total = v_total where id = v_venta;

  v_pagado := public.jab__insertar_pagos(v_venta, v_cliente, p->'pagos');
  if v_pagado > v_total + 0.004 then
    raise exception 'Lo cobrado ($%) es mayor que el total ($%).', v_pagado, v_total;
  end if;

  if v_tipo = 'contado' and abs(v_pagado - v_total) > 0.004 then
    raise exception 'Falta cobrar $%.', round(v_total - v_pagado, 2);
  end if;
  if v_tipo = 'apartado' then
    v_minimo := round(v_total * v_cfg.abono_minimo_pct / 100, 2);
    if v_pagado + 0.004 < v_minimo and not public.jab_es_duena() then
      raise exception 'El abono mínimo para apartar es $%.', v_minimo;
    end if;
  end if;

  perform public.jab__recalcular_pagado(v_venta);
  if v_tipo = 'fiado' then
    perform public.jab__revisar_limite(v_cliente);
  end if;
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_venta));
  return v_venta;
end $$;

create or replace function public.jab_entregar_apartado(p_venta bigint, p_dejar_fiado boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.jab_ventas;
  v_saldo numeric;
  v_falta text;
begin
  perform public.jab__exigir_activo();
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found or v.tipo <> 'apartado' or v.estado <> 'activa' or v.entregada then
    raise exception 'Este apartado no se puede entregar.';
  end if;
  select string_agg(distinct pr.nombre, ', ') into v_falta
    from public.jab_venta_items vi join public.jab_productos pr on pr.id = vi.producto_id
   where vi.venta_id = p_venta and pr.por_llegar;
  if v_falta is not null then
    raise exception 'Todavía no llegó: %. Márcalo como llegado en Inventario antes de entregar.', v_falta;
  end if;
  v_saldo := v.total - public.jab__recalcular_pagado(p_venta);
  if v_saldo > 0.004 then
    if not coalesce(p_dejar_fiado, false) then
      raise exception 'Falta pagar $% para entregar el apartado.', round(v_saldo, 2);
    end if;
    if not public.jab__puede('fiar') then
      raise exception 'No tienes permiso para entregar dejando deuda. Pídeselo a la dueña.';
    end if;
    update public.jab_ventas set tipo = 'fiado' where id = p_venta;
    perform public.jab__revisar_limite(v.cliente_id);
  end if;
  update public.jab_ventas set entregada = true, entregada_en = now() where id = p_venta;
  perform public.jab__auditar('ventas', p_venta::text, 'entregar_apartado',
    jsonb_build_object('saldo', v_saldo), jsonb_build_object('dejo_fiado', v_saldo > 0.004));
end $$;

create or replace function public.jab_registrar_cambio(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_origen public.jab_ventas;
  v_origen_id bigint := nullif(p->>'venta_origen_id', '')::bigint;
  v_cliente bigint := nullif(p->>'cliente_id', '')::bigint;
  v_venta bigint;
  d jsonb;
  e jsonb;
  oi record;
  v_cant int;
  v_ya int;
  v_total numeric := 0;
  v_pagado numeric;
  v_costo numeric;
  v_ids bigint[];
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_prev jsonb;
  v_deuda numeric;
  v_aplicar numeric;
  v_pago bigint;
begin
  perform public.jab__exigir_activo();
  if not public.jab__puede('cambios') then
    raise exception 'No tienes permiso para hacer cambios. Pídeselo a la dueña.';
  end if;
  v_prev := public.jab__idem_inicio(v_clave, 'cambio');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  if coalesce(jsonb_typeof(p->'devueltos'), '') <> 'array' or jsonb_array_length(p->'devueltos') = 0 then
    raise exception 'Elige la prenda que devuelve.';
  end if;

  if v_origen_id is null then
    if not public.jab_es_duena() then
      raise exception 'Para hacer un cambio busca la venta original.';
    end if;
  else
    select * into v_origen from public.jab_ventas where id = v_origen_id for update;
    if not found or v_origen.estado <> 'activa' then
      raise exception 'La venta original no está activa.';
    end if;
    if not v_origen.entregada then
      raise exception 'Ese apartado todavía no se ha entregado.';
    end if;
    -- El saldo a favor y los pagos con saldo a favor son siempre de la clienta de la venta original
    if v_origen.cliente_id is not null then
      if v_cliente is not null and v_cliente <> v_origen.cliente_id then
        raise exception 'La clienta del cambio debe ser la de la venta original.';
      end if;
      v_cliente := v_origen.cliente_id;
    end if;
  end if;
  if v_cliente is not null and not exists (select 1 from public.jab_clientes where id = v_cliente and deleted_at is null) then
    raise exception 'Esa clienta no existe.';
  end if;

  insert into public.jab_ventas (numero, tipo, cliente_id, venta_origen_id, entregada, entregada_en, nota, usuario_id)
  values (public.jab__siguiente('venta'), 'cambio', v_cliente, v_origen_id, true, now(), nullif(trim(p->>'nota'), ''), auth.uid())
  returning id into v_venta;

  -- Bloquear todas las variantes que se tocan
  select array_agg(x) into v_ids from (
    select coalesce((d2->>'variante_id')::bigint, (select variante_id from public.jab_venta_items where id = (d2->>'venta_item_id')::bigint)) x
      from jsonb_array_elements(p->'devueltos') d2
    union all
    select (e2->>'variante_id')::bigint from jsonb_array_elements(coalesce(p->'entregados', '[]'::jsonb)) e2
  ) s;
  perform public.jab__bloquear_variantes(v_ids);

  -- Prendas que vuelven a la tienda
  for d in select * from jsonb_array_elements(p->'devueltos') loop
    v_cant := (d->>'cantidad')::int;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad devuelta no válida.';
    end if;
    if v_origen_id is not null then
      select vi.*, vc.costo into oi
        from public.jab_venta_items vi left join public.jab_venta_item_costos vc on vc.venta_item_id = vi.id
       where vi.id = (d->>'venta_item_id')::bigint and vi.venta_id = v_origen_id and vi.cantidad > 0;
      if not found then
        raise exception 'Esa prenda no es de la venta %.', public.jab__num(v_origen_id);
      end if;
      select coalesce(sum(-vi.cantidad), 0) into v_ya
        from public.jab_venta_items vi join public.jab_ventas ve on ve.id = vi.venta_id
       where vi.item_origen_id = oi.id and ve.estado = 'activa';
      if v_cant > oi.cantidad - v_ya then
        raise exception 'De "%" solo quedan % por cambiar.', oi.descripcion, oi.cantidad - v_ya;
      end if;
      v_total := v_total + public.jab__agregar_item(v_venta, oi.variante_id, -v_cant, oi.precio,
                                                 'cambio_devuelto', oi.id, oi.costo);
    else
      v_total := v_total + public.jab__agregar_item(v_venta, (d->>'variante_id')::bigint, -v_cant,
                                                 nullif(d->>'precio', '')::numeric, 'cambio_devuelto', null, null);
    end if;
  end loop;

  -- Prendas que se lleva
  for e in select * from jsonb_array_elements(coalesce(p->'entregados', '[]'::jsonb)) loop
    v_cant := (e->>'cantidad')::int;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad no válida.';
    end if;
    v_total := v_total + public.jab__agregar_item(v_venta, (e->>'variante_id')::bigint, v_cant,
                                               nullif(e->>'precio', '')::numeric, 'cambio_entregado', null, null);
  end loop;

  update public.jab_ventas set total = v_total where id = v_venta;

  if v_total > 0.004 then
    v_pagado := public.jab__insertar_pagos(v_venta, v_cliente, p->'pagos');
    if abs(v_pagado - v_total) > 0.004 then
      raise exception 'La diferencia a pagar es $% y se cobró $%.', v_total, v_pagado;
    end if;
  else
    if jsonb_typeof(p->'pagos') = 'array' and jsonb_array_length(p->'pagos') > 0 then
      raise exception 'En este cambio no hay diferencia que cobrar.';
    end if;
    if v_total < -0.004 then
      if v_cliente is null then
        raise exception 'Elige la clienta para dejarle el saldo a favor.';
      end if;
      insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id)
      values (v_cliente, -v_total, 'Saldo a favor por el cambio ' || public.jab__num(v_venta), v_venta);
      -- Si la venta original todavía se debe, ese saldo a favor se abona primero a la deuda
      if v_origen_id is not null and v_origen.tipo in ('fiado','apartado') then
        v_deuda := v_origen.total - public.jab__recalcular_pagado(v_origen_id);
        if v_deuda > 0.004 then
          v_aplicar := least(-v_total, v_deuda);
          insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id)
          values (v_origen_id, (select id from public.jab_metodos_pago where es_saldo_favor order by id limit 1),
                  null, 'USD', v_aplicar, null, v_aplicar, 'Cambio ' || public.jab__num(v_venta), auth.uid())
          returning id into v_pago;
          insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id, pago_id)
          values (v_cliente, -v_aplicar, 'Abonado a la venta ' || public.jab__num(v_origen_id) || ' por el cambio ' || public.jab__num(v_venta), v_origen_id, v_pago);
          perform public.jab__recalcular_pagado(v_origen_id);
        end if;
      end if;
    end if;
  end if;

  perform public.jab__recalcular_pagado(v_venta);
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_venta));
  return v_venta;
end $$;

create or replace function public.jab_reporte(p_desde date, p_hasta date) returns jsonb
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
                       from (select vendedora_id, count(*) filter (where tipo <> 'cambio') as n, sum(total) as total from v group by vendedora_id) s
                       left join public.jab_usuarios u on u.id = s.vendedora_id), '[]'::jsonb),
    'por_cobrar', (select coalesce(sum(total - pagado), 0) from public.jab_ventas
                    where estado = 'activa' and tipo in ('apartado','fiado') and total - pagado > 0)
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
  public.jab_reporte(date, date), public.jab_sin_movimiento(int),
  public.jab_guardar_permisos(uuid, jsonb), public.jab_comisiones(date, date),
  public.jab_pagar_comision(uuid, bigint, numeric, numeric, uuid), public.jab_mi_comision(),
  public.jab_marcar_llegada(bigint, text), public.jab_renombrar_categoria(text, text),
  public.jab_foto_pago(bigint, text)
to authenticated;
