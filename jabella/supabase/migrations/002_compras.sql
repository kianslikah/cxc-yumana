-- =====================================================================
-- JABELLA Store — entrega 2: compras SHEIN
-- Pedido (compra) → paquetes que SHEIN manda al casillero de Miami →
-- caja de reempaque (envío) que viaja: tránsito, aduana, llegada →
-- recepción en la tienda: lo que llegó entra al inventario con su costo real
-- (precio SHEIN prorrateado con lo realmente pagado + flete de la caja
-- repartido en partes iguales entre las piezas recibidas).
-- Base compartida con Yumana: solo objetos jab_, nunca "all ... in schema public".
-- =====================================================================

-- Pagos de mercancía y flete: salen de una cuenta, pero son inversión (no gasto del local)
alter table public.jab_movimientos_dinero
  add column compra_id bigint,
  add column envio_id bigint,
  add column compra_item_id bigint,                    -- reembolso de SHEIN por un artículo faltante
  add column es_inversion boolean not null default false;

insert into public.jab_contadores (nombre, valor) values ('compra', 0), ('envio', 0);

create table public.jab_compras (
  id bigint generated always as identity primary key,
  numero bigint not null unique,
  tienda text not null default 'SHEIN',
  pedido_ref text,                                   -- número de pedido en SHEIN
  fecha date not null default ((now() at time zone 'America/Caracas')::date),
  total_pagado numeric(12,2) check (total_pagado >= 0),  -- lo que costó el pedido completo (impuestos y descuentos incluidos)
  notas text,
  anulada_en timestamptz,
  anulada_por uuid,
  motivo_anulacion text,
  creado_en timestamptz not null default now(),
  usuario_id uuid default auth.uid()
);

create table public.jab_compra_items (
  id bigint generated always as identity primary key,
  compra_id bigint not null references public.jab_compras(id),
  descripcion text not null check (length(trim(descripcion)) > 0),
  talla text not null default '',
  color text not null default '',
  cantidad int not null check (cantidad > 0),
  precio numeric(12,2) not null check (precio >= 0),  -- precio unitario en SHEIN
  foto text,
  foto_mini text,
  producto_id bigint references public.jab_productos(id),   -- prenda a la que se suma (se puede decidir al recibir)
  variante_id bigint references public.jab_variantes(id),
  recibidas int not null default 0 check (recibidas >= 0),
  faltantes int not null default 0 check (faltantes >= 0),
  costo_real numeric(12,4),                           -- costo por pieza calculado al recibir
  reembolsado numeric(12,2) not null default 0 check (reembolsado >= 0),
  quitado_en timestamptz,                             -- borrado suave (se quitó del pedido antes de recibir)
  clave uuid unique,                                  -- clave del teléfono: reintentar un guardado no duplica el artículo
  check (recibidas + faltantes <= cantidad)
);
create index on public.jab_compra_items (compra_id);

create table public.jab_envios (
  id bigint generated always as identity primary key,
  numero bigint not null unique,
  estado text not null default 'reempaque' check (estado in ('reempaque','transito','aduana','llegada','recibido')),
  courier text,
  guia text,
  peso_lb numeric(8,2) check (peso_lb >= 0),
  vol_lb numeric(8,2) check (vol_lb >= 0),
  tarifa numeric(10,2) not null check (tarifa >= 0),
  flete numeric(12,2) check (flete >= 0),             -- flete final de la caja (lo que cobró el courier)
  fecha_solicitud date not null default ((now() at time zone 'America/Caracas')::date),
  fecha_salida date,
  fecha_aduana date,
  fecha_llegada date,
  recibido_en timestamptz,
  piezas_recibidas int,
  flete_por_pieza numeric(12,4),
  notas text,
  anulado_en timestamptz,
  creado_en timestamptz not null default now(),
  usuario_id uuid default auth.uid()
);

create table public.jab_paquetes (
  id bigint generated always as identity primary key,
  compra_id bigint not null references public.jab_compras(id),
  tracking text,
  estado text not null default 'camino' check (estado in ('camino','casillero')),
  fecha_casillero date,
  envio_id bigint references public.jab_envios(id),
  quitado_en timestamptz,
  clave uuid unique,
  creado_en timestamptz not null default now()
);
create index on public.jab_paquetes (compra_id);
create index on public.jab_paquetes (envio_id);

alter table public.jab_compras      enable row level security;
alter table public.jab_compra_items enable row level security;
alter table public.jab_envios       enable row level security;
alter table public.jab_paquetes     enable row level security;

create policy "solo_duena" on public.jab_compras      for select to authenticated using (public.jab_es_duena());
create policy "solo_duena" on public.jab_compra_items for select to authenticated using (public.jab_es_duena());
create policy "solo_duena" on public.jab_envios       for select to authenticated using (public.jab_es_duena());
create policy "solo_duena" on public.jab_paquetes     for select to authenticated using (public.jab_es_duena());

-- ---------------------------------------------------------------------
-- Internas
-- ---------------------------------------------------------------------

-- Lo que se anota en Dinero como "Mercancía (SHEIN y flete)" es inversión, no gasto del local
create function public.jab__trg_mov_inversion() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.categoria = 'Mercancía (SHEIN y flete)' then
    new.es_inversion := true;
  end if;
  return new;
end $$;
create trigger trg_jab_mov_inversion before insert on public.jab_movimientos_dinero
  for each row execute function public.jab__trg_mov_inversion();
update public.jab_movimientos_dinero set es_inversion = true
 where categoria = 'Mercancía (SHEIN y flete)' and not es_inversion;

-- Lo reembolsado de un artículo sale siempre de sus movimientos vivos (si se anula uno en Dinero, baja solo)
create function public.jab__trg_recalc_reembolsado() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_item bigint := coalesce(new.compra_item_id, old.compra_item_id);
begin
  if v_item is not null then
    update public.jab_compra_items
       set reembolsado = coalesce((select round(sum(monto_usd), 2) from public.jab_movimientos_dinero
                                    where compra_item_id = v_item and anulado_en is null), 0)
     where id = v_item;
  end if;
  return null;
end $$;
create trigger trg_jab_recalc_reembolsado after insert or update of anulado_en, compra_item_id on public.jab_movimientos_dinero
  for each row execute function public.jab__trg_recalc_reembolsado();

-- Sale dinero de una cuenta por mercancía o flete (inversión, no gasto del local)
create function public.jab__pago_inversion(p_cuenta bigint, p_monto numeric, p_tasa numeric, p_categoria text,
                                           p_descripcion text, p_compra bigint, p_envio bigint, p_signo int)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.jab_cuentas; v_tasa numeric := p_tasa; v_grupo uuid := gen_random_uuid(); v_monto numeric := round(p_monto, 2);
begin
  select * into c from public.jab_cuentas where id = p_cuenta;
  if not found then
    raise exception 'Elige la cuenta.';
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
  end if;
  insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo, compra_id, envio_id, es_inversion)
  values (case when p_signo < 0 then 'gasto' else 'ingreso' end, c.id, p_signo * v_monto,
          case when c.moneda = 'VES' then v_tasa end,
          round(p_signo * case when c.moneda = 'VES' then v_monto / v_tasa else v_monto end, 2),
          p_categoria, nullif(trim(p_descripcion), ''), v_grupo, p_compra, p_envio, true);
  return v_grupo;
end $$;

-- Factor para repartir impuestos y descuentos de SHEIN: lo pagado / suma de precios
create function public.jab__factor_compra(p_compra bigint) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when c.total_pagado is not null and s.sub > 0 then c.total_pagado / s.sub else 1 end
    from public.jab_compras c,
         lateral (select coalesce(sum(cantidad * precio), 0) as sub from public.jab_compra_items
                   where compra_id = c.id and quitado_en is null) s
   where c.id = p_compra
$$;

-- ---------------------------------------------------------------------
-- Pedidos
-- ---------------------------------------------------------------------
-- p = {id?, clave?, tienda?, pedido_ref?, fecha?, total_pagado?, notas?,
--      items: [{id? | clave?, descripcion, talla?, color?, cantidad (0 = quitar), precio, foto?, foto_mini?, producto_id?}],
--      paquetes: [{id? | clave?, tracking?, quitar?}]}
-- Reintentos sin duplicar: el pedido nuevo usa la clave de la hoja (si ya se creó, se sigue como edición)
-- y cada artículo o paquete nuevo trae su propia clave.
create function public.jab_guardar_compra(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_clave uuid := case when nullif(p->>'id', '') is null then nullif(p->>'clave', '')::uuid end;
  v_prev jsonb;
  c public.jab_compras;
  it jsonb;
  pq jsonb;
  v_item public.jab_compra_items;
  v_paq public.jab_paquetes;
  v_cant int;
  v_precio numeric;
  v_total numeric := round(nullif(p->>'total_pagado', '')::numeric, 2);
  v_recibido boolean := false;   -- ya entró (o se dio por faltante) algo de este pedido: el reparto del costo queda fijo
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(v_clave, 'compra');
  if v_prev is not null then
    v_id := (v_prev->>'id')::bigint;    -- el primer intento sí se guardó: se aplica como edición
  end if;
  if v_total < 0 then
    raise exception 'El total pagado no puede ser negativo.';
  end if;

  if v_id is null then
    insert into public.jab_compras (numero, tienda, pedido_ref, fecha, total_pagado, notas)
    values (public.jab__siguiente('compra'), coalesce(nullif(trim(p->>'tienda'), ''), 'SHEIN'), nullif(trim(p->>'pedido_ref'), ''),
            coalesce(nullif(p->>'fecha', '')::date, public.jab__hoy()), v_total, nullif(trim(p->>'notas'), ''))
    returning id into v_id;
  else
    select * into c from public.jab_compras where id = v_id for update;
    if not found or c.anulada_en is not null then
      raise exception 'Ese pedido no existe o está anulado.';
    end if;
    v_recibido := exists (select 1 from public.jab_compra_items where compra_id = v_id and quitado_en is null and (recibidas > 0 or faltantes > 0));
    if c.total_pagado is distinct from v_total and v_recibido then
      raise exception 'Ya se recibió mercancía de este pedido: el total pagado no se puede cambiar.';
    end if;
    update public.jab_compras set
      tienda = coalesce(nullif(trim(p->>'tienda'), ''), tienda),
      pedido_ref = nullif(trim(p->>'pedido_ref'), ''),
      fecha = coalesce(nullif(p->>'fecha', '')::date, fecha),
      total_pagado = v_total,
      notas = nullif(trim(p->>'notas'), '')
    where id = v_id;
  end if;

  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    v_cant := (it->>'cantidad')::int;
    v_precio := round((it->>'precio')::numeric, 2);
    if coalesce(trim(it->>'descripcion'), '') = '' then
      raise exception 'Cada artículo necesita una descripción.';
    end if;
    if v_cant is null or v_cant < 0 then
      raise exception 'Cantidad no válida en "%".', it->>'descripcion';
    end if;
    if v_precio is null or v_precio < 0 then
      raise exception 'Precio no válido en "%".', it->>'descripcion';
    end if;
    if nullif(it->>'producto_id', '') is not null
       and not exists (select 1 from public.jab_productos where id = (it->>'producto_id')::bigint) then
      raise exception 'La prenda vinculada no existe.';
    end if;

    v_item := null;
    if nullif(it->>'id', '') is not null then
      select * into v_item from public.jab_compra_items
       where id = (it->>'id')::bigint and compra_id = v_id and quitado_en is null for update;
      if not found then
        raise exception 'Ese artículo no es de este pedido.';
      end if;
    elsif nullif(it->>'clave', '') is not null then
      select * into v_item from public.jab_compra_items where clave = (it->>'clave')::uuid for update;
      if found and (v_item.compra_id <> v_id) then
        raise exception 'Clave de artículo repetida.';
      end if;
      if found and v_item.quitado_en is not null then
        continue;      -- ya se había guardado y luego se quitó
      end if;
    end if;

    if v_item.id is null then
      if v_cant > 0 then
        if v_recibido then
          raise exception 'Ya se recibió mercancía de este pedido: no se le pueden agregar artículos (anótalos en un pedido aparte).';
        end if;
        insert into public.jab_compra_items (compra_id, descripcion, talla, color, cantidad, precio, foto, foto_mini, producto_id, clave)
        values (v_id, trim(it->>'descripcion'), coalesce(trim(it->>'talla'), ''), coalesce(trim(it->>'color'), ''),
                v_cant, v_precio, nullif(it->>'foto', ''), nullif(it->>'foto_mini', ''),
                nullif(it->>'producto_id', '')::bigint, nullif(it->>'clave', '')::uuid);
      end if;
    elsif v_item.recibidas > 0 or v_item.faltantes > 0 then
      -- Ya recibido (todo o en parte): solo se puede corregir la descripción
      if v_cant <> v_item.cantidad or v_precio <> v_item.precio then
        raise exception 'De "%" ya se recibió mercancía: no se puede cambiar la cantidad ni el precio.', v_item.descripcion;
      end if;
      update public.jab_compra_items set descripcion = trim(it->>'descripcion') where id = v_item.id;
    elsif v_cant = 0 then
      if v_recibido then
        raise exception 'Ya se recibió mercancía de este pedido: "%" no se puede quitar. Si no va a llegar, márcalo como faltante.', v_item.descripcion;
      end if;
      update public.jab_compra_items set quitado_en = now() where id = v_item.id;
      perform public.jab__auditar('compra_items', v_item.id::text, 'quitar', to_jsonb(v_item), null);
    else
      if v_recibido and (v_cant <> v_item.cantidad or v_precio <> v_item.precio) then
        raise exception 'Ya se recibió mercancía de este pedido: no se puede cambiar la cantidad ni el precio de "%" (cambiaría el costo de lo ya recibido).', v_item.descripcion;
      end if;
      update public.jab_compra_items set
        descripcion = trim(it->>'descripcion'), talla = coalesce(trim(it->>'talla'), ''), color = coalesce(trim(it->>'color'), ''),
        cantidad = v_cant, precio = v_precio,
        foto = case when it ? 'foto' then nullif(it->>'foto', '') else foto end,
        foto_mini = case when it ? 'foto_mini' then nullif(it->>'foto_mini', '') else foto_mini end,
        producto_id = nullif(it->>'producto_id', '')::bigint
      where id = v_item.id;
    end if;
  end loop;

  for pq in select * from jsonb_array_elements(coalesce(p->'paquetes', '[]'::jsonb)) loop
    v_paq := null;
    if nullif(pq->>'id', '') is not null then
      select * into v_paq from public.jab_paquetes
       where id = (pq->>'id')::bigint and compra_id = v_id and quitado_en is null for update;
      if not found then
        raise exception 'Ese paquete no es de este pedido.';
      end if;
    elsif nullif(pq->>'clave', '') is not null then
      select * into v_paq from public.jab_paquetes where clave = (pq->>'clave')::uuid for update;
      if found and (v_paq.compra_id <> v_id) then
        raise exception 'Clave de paquete repetida.';
      end if;
      if found and v_paq.quitado_en is not null then
        continue;
      end if;
    end if;

    if v_paq.id is null then
      if not coalesce((pq->>'quitar')::boolean, false) then
        insert into public.jab_paquetes (compra_id, tracking, clave)
        values (v_id, nullif(trim(pq->>'tracking'), ''), nullif(pq->>'clave', '')::uuid);
      end if;
    elsif coalesce((pq->>'quitar')::boolean, false) then
      if v_paq.envio_id is not null then
        raise exception 'Ese paquete ya va en la caja de un envío: sácalo del envío primero.';
      end if;
      update public.jab_paquetes set quitado_en = now() where id = v_paq.id;
    else
      update public.jab_paquetes set tracking = nullif(trim(pq->>'tracking'), '') where id = v_paq.id;
    end if;
  end loop;

  if not exists (select 1 from public.jab_compra_items where compra_id = v_id and quitado_en is null) then
    raise exception 'Agrega al menos un artículo al pedido.';
  end if;
  if not exists (select 1 from public.jab_paquetes where compra_id = v_id and quitado_en is null) then
    insert into public.jab_paquetes (compra_id) values (v_id);   -- todo pedido tiene al menos un paquete
  end if;

  if v_prev is null then
    perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_id));
  end if;
  return v_id;
end $$;

-- Pago del pedido (sale de una cuenta). Puede haber más de uno.
create function public.jab_pagar_compra(p_compra bigint, p_cuenta bigint, p_monto numeric, p_tasa numeric default null, p_clave uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.jab_compras; v_prev jsonb; v_grupo uuid;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(p_clave, 'pago_compra');
  if v_prev is not null then
    return (v_prev->>'grupo')::uuid;
  end if;
  select * into c from public.jab_compras where id = p_compra for update;
  if not found or c.anulada_en is not null then
    raise exception 'Ese pedido no existe o está anulado.';
  end if;
  v_grupo := public.jab__pago_inversion(p_cuenta, p_monto, p_tasa, 'Mercancía (SHEIN)',
               'Pedido #' || c.numero || coalesce(' · ' || c.pedido_ref, ''), c.id, null, -1);
  perform public.jab__idem_fin(p_clave, jsonb_build_object('grupo', v_grupo));
  return v_grupo;
end $$;

-- Un paquete llegó al casillero de Miami (o se corrige a "en camino")
create function public.jab_paquete_estado(p_paquete bigint, p_estado text, p_fecha date default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.jab_paquetes;
begin
  perform public.jab__exigir_duena();
  if p_estado not in ('camino','casillero') then
    raise exception 'Estado no válido.';
  end if;
  select * into v from public.jab_paquetes where id = p_paquete and quitado_en is null for update;
  if not found then
    raise exception 'Ese paquete no existe.';
  end if;
  if v.envio_id is not null then
    raise exception 'Ese paquete ya va en un envío.';
  end if;
  update public.jab_paquetes
     set estado = p_estado, fecha_casillero = case when p_estado = 'casillero' then coalesce(p_fecha, public.jab__hoy()) end
   where id = p_paquete;
end $$;

-- p_devolver_pagos: SHEIN devolvió el dinero a la misma cuenta (sus pagos se anulan); si no, el dinero queda gastado
create function public.jab_anular_compra(p_compra bigint, p_motivo text, p_devolver_pagos boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.jab_compras;
begin
  perform public.jab__exigir_duena();
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo.';
  end if;
  select * into c from public.jab_compras where id = p_compra for update;
  if not found or c.anulada_en is not null then
    raise exception 'Ese pedido no existe o ya está anulado.';
  end if;
  if exists (select 1 from public.jab_compra_items where compra_id = p_compra and (recibidas > 0 or faltantes > 0)) then
    raise exception 'De este pedido ya se recibió mercancía: no se puede anular.';
  end if;
  if exists (select 1 from public.jab_paquetes pq join public.jab_envios e on e.id = pq.envio_id
              where pq.compra_id = p_compra and pq.quitado_en is null and e.anulado_en is null) then
    raise exception 'Este pedido tiene paquetes en un envío: sácalos del envío primero.';
  end if;
  update public.jab_compras set anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo) where id = p_compra;
  if coalesce(p_devolver_pagos, true) then
    update public.jab_movimientos_dinero set anulado_en = now(), anulado_por = auth.uid()
     where compra_id = p_compra and anulado_en is null;
  end if;
  perform public.jab__auditar('compras', p_compra::text, 'anular', to_jsonb(c),
    jsonb_build_object('motivo', p_motivo, 'devolvio_pagos', coalesce(p_devolver_pagos, true)));
end $$;

-- ---------------------------------------------------------------------
-- Envíos (cajas de reempaque)
-- ---------------------------------------------------------------------
-- p = {id?, clave?, paquetes: [ids] (la lista completa de paquetes de la caja), courier?, guia?,
--      peso_lb?, vol_lb?, tarifa?, flete?, estado?, fecha_salida?, fecha_aduana?, fecha_llegada?, notas?}
create function public.jab_guardar_envio(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_clave uuid := case when nullif(p->>'id', '') is null then nullif(p->>'clave', '')::uuid end;
  v_prev jsonb;
  e public.jab_envios;
  v_ids bigint[];
  v_tarifa numeric;
  v_peso numeric := round(nullif(p->>'peso_lb', '')::numeric, 2);
  v_vol numeric := round(nullif(p->>'vol_lb', '')::numeric, 2);
  v_flete numeric := round(nullif(p->>'flete', '')::numeric, 2);
  v_estado text := coalesce(nullif(p->>'estado', ''), 'reempaque');
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(v_clave, 'envio');
  if v_prev is not null then
    v_id := (v_prev->>'id')::bigint;    -- el primer intento sí se guardó: se aplica como edición
  end if;
  if v_estado not in ('reempaque','transito','aduana','llegada') then
    raise exception 'Estado no válido (para recibir usa "Recibir mercancía").';
  end if;
  select tarifa_libra into v_tarifa from public.jab_config where id = 1;
  v_tarifa := coalesce(round(nullif(p->>'tarifa', '')::numeric, 2), v_tarifa);
  if v_tarifa < 0 or v_peso < 0 or v_vol < 0 or v_flete < 0 then
    raise exception 'Revisa el peso, la tarifa y el flete.';
  end if;
  -- Se cobra el mayor entre el peso real y el volumétrico
  if v_flete is null and coalesce(v_peso, v_vol) is not null then
    v_flete := round(greatest(coalesce(v_peso, 0), coalesce(v_vol, 0)) * v_tarifa, 2);
  end if;

  select array_agg(distinct (x #>> '{}')::bigint) into v_ids from jsonb_array_elements(coalesce(p->'paquetes', '[]'::jsonb)) x;
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'Elige los paquetes que van en la caja.';
  end if;

  if v_id is null then
    insert into public.jab_envios (numero, estado, courier, guia, peso_lb, vol_lb, tarifa, flete, notas)
    values (public.jab__siguiente('envio'), v_estado, nullif(trim(p->>'courier'), ''), nullif(trim(p->>'guia'), ''),
            v_peso, v_vol, v_tarifa, v_flete, nullif(trim(p->>'notas'), ''))
    returning id into v_id;
  else
    select * into e from public.jab_envios where id = v_id for update;
    if not found or e.anulado_en is not null or e.estado = 'recibido' then
      raise exception 'Este envío ya se recibió o está anulado.';
    end if;
    update public.jab_envios set
      estado = v_estado, courier = nullif(trim(p->>'courier'), ''), guia = nullif(trim(p->>'guia'), ''),
      peso_lb = v_peso, vol_lb = v_vol, tarifa = v_tarifa, flete = v_flete, notas = nullif(trim(p->>'notas'), '')
    where id = v_id;
    -- Paquetes que salieron de la caja
    update public.jab_paquetes set envio_id = null where envio_id = v_id and not (id = any(v_ids));
  end if;

  -- Fechas de cada etapa (la de hoy si no se indica y se llegó a esa etapa)
  update public.jab_envios set
    fecha_salida  = case when v_estado in ('transito','aduana','llegada') then coalesce(nullif(p->>'fecha_salida', '')::date, fecha_salida, public.jab__hoy()) end,
    fecha_aduana  = case when v_estado in ('aduana','llegada') then coalesce(nullif(p->>'fecha_aduana', '')::date, fecha_aduana, public.jab__hoy()) end,
    fecha_llegada = case when v_estado = 'llegada' then coalesce(nullif(p->>'fecha_llegada', '')::date, fecha_llegada, public.jab__hoy()) end
  where id = v_id;

  -- Paquetes que entran: deben estar en el casillero y sin otra caja
  perform 1 from public.jab_paquetes where id = any(v_ids) order by id for update;
  if exists (select 1 from public.jab_paquetes pq join public.jab_compras c on c.id = pq.compra_id
              where pq.id = any(v_ids) and (pq.quitado_en is not null or c.anulada_en is not null
                    or pq.estado <> 'casillero' or (pq.envio_id is not null and pq.envio_id <> v_id))) then
    raise exception 'Solo van en la caja paquetes que ya están en el casillero y no están en otro envío.';
  end if;
  update public.jab_paquetes set envio_id = v_id where id = any(v_ids);

  if v_prev is null then
    perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_id));
  end if;
  return v_id;
end $$;

-- Solo la etapa de la caja (y la fecha de esa etapa). Sirve también para corregir hacia atrás.
create function public.jab_envio_estado(p_envio bigint, p_estado text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.jab_envios;
begin
  perform public.jab__exigir_duena();
  if p_estado not in ('reempaque','transito','aduana','llegada') then
    raise exception 'Estado no válido (para recibir usa "Recibir mercancía").';
  end if;
  select * into e from public.jab_envios where id = p_envio for update;
  if not found or e.anulado_en is not null or e.estado = 'recibido' then
    raise exception 'Este envío ya se recibió o está anulado.';
  end if;
  update public.jab_envios set
    estado = p_estado,
    fecha_salida  = case when p_estado in ('transito','aduana','llegada') then coalesce(fecha_salida, public.jab__hoy()) end,
    fecha_aduana  = case when p_estado in ('aduana','llegada') then coalesce(fecha_aduana, public.jab__hoy()) end,
    fecha_llegada = case when p_estado = 'llegada' then coalesce(fecha_llegada, public.jab__hoy()) end
  where id = p_envio;
end $$;

create function public.jab_pagar_flete(p_envio bigint, p_cuenta bigint, p_monto numeric, p_tasa numeric default null, p_clave uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.jab_envios; v_prev jsonb; v_grupo uuid;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(p_clave, 'pago_flete');
  if v_prev is not null then
    return (v_prev->>'grupo')::uuid;
  end if;
  select * into e from public.jab_envios where id = p_envio for update;
  if not found or e.anulado_en is not null then
    raise exception 'Ese envío no existe o está anulado.';
  end if;
  v_grupo := public.jab__pago_inversion(p_cuenta, p_monto, p_tasa, 'Flete', 'Envío #' || e.numero, null, e.id, -1);
  perform public.jab__idem_fin(p_clave, jsonb_build_object('grupo', v_grupo));
  return v_grupo;
end $$;

-- p_devolver_flete: el courier devolvió el flete (sus pagos se anulan); si no, el dinero queda gastado
create function public.jab_anular_envio(p_envio bigint, p_motivo text, p_devolver_flete boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.jab_envios;
begin
  perform public.jab__exigir_duena();
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo.';
  end if;
  select * into e from public.jab_envios where id = p_envio for update;
  if not found or e.anulado_en is not null then
    raise exception 'Ese envío no existe o ya está anulado.';
  end if;
  if e.estado = 'recibido' then
    raise exception 'Este envío ya se recibió: no se puede anular.';
  end if;
  update public.jab_paquetes set envio_id = null where envio_id = p_envio;
  update public.jab_envios set anulado_en = now(), notas = coalesce(notas || ' · ', '') || 'Anulado: ' || trim(p_motivo) where id = p_envio;
  if coalesce(p_devolver_flete, false) then
    update public.jab_movimientos_dinero set anulado_en = now(), anulado_por = auth.uid()
     where envio_id = p_envio and anulado_en is null;
  end if;
  perform public.jab__auditar('envios', p_envio::text, 'anular', to_jsonb(e),
    jsonb_build_object('motivo', p_motivo, 'devolvio_flete', coalesce(p_devolver_flete, false)));
end $$;

-- ---------------------------------------------------------------------
-- Recepción: lo que llegó entra al inventario con su costo real
-- ---------------------------------------------------------------------
-- p = {envio_id, clave?, lineas: [{item_id, recibidas, faltantes?,
--        variante_id? | producto_id? (talla/color de la línea o del artículo) |
--        nueva: {nombre, categoria?, precio}  (crea la prenda con la foto del artículo)}]}
create function public.jab_recibir_envio(p jsonb) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_envio bigint := (p->>'envio_id')::bigint;
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_prev jsonb;
  e public.jab_envios;
  l jsonb;
  it public.jab_compra_items;
  v_rec int;
  v_falt int;
  v_piezas int := 0;
  v_fpp numeric;
  v_costo numeric;
  v_prod bigint;
  v_var bigint;
  v_talla text;
  v_color text;
  v_stock int;
  v_costo_ant numeric;
  v_num_compra bigint;
  v_ids bigint[];
  v_creados jsonb := '{}'::jsonb;   -- prendas nuevas de esta recepción por nombre (mismo modelo en varias tallas = una prenda)
  v_llave text;
  v_falt_total int;
  v_costo_nuevo numeric;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(v_clave, 'recepcion');
  if v_prev is not null then
    return (v_prev->>'id')::bigint;
  end if;
  select * into e from public.jab_envios where id = v_envio for update;
  if not found or e.anulado_en is not null then
    raise exception 'Ese envío no existe o está anulado.';
  end if;
  if e.estado = 'recibido' then
    raise exception 'Este envío ya se recibió.';
  end if;
  if e.flete is null then
    raise exception 'Primero anota el flete de la caja (o 0 si no se cobró).';
  end if;
  if coalesce(jsonb_typeof(p->'lineas'), '') <> 'array' then
    raise exception 'No hay artículos para recibir.';
  end if;

  select coalesce(sum(greatest(coalesce((x->>'recibidas')::int, 0), 0)), 0),
         coalesce(sum(greatest(coalesce((x->>'faltantes')::int, 0), 0)), 0)
    into v_piezas, v_falt_total from jsonb_array_elements(p->'lineas') x;
  if v_piezas <= 0 and v_falt_total <= 0 then
    raise exception 'Marca lo que llegó o lo que faltó.';
  end if;
  -- Si no llegó ninguna pieza, el flete queda como pérdida (no hay a quién repartirlo)
  v_fpp := case when v_piezas > 0 then round(e.flete / v_piezas, 4) end;

  -- Bloquear los pedidos de la caja (nadie cambia su total ni los anula mientras tanto) y luego los artículos, en orden
  perform 1 from public.jab_compras
   where id in (select compra_id from public.jab_paquetes where envio_id = v_envio and quitado_en is null)
   order by id for update;
  if exists (select 1 from public.jab_compras c join public.jab_paquetes pq on pq.compra_id = c.id
              where pq.envio_id = v_envio and pq.quitado_en is null and c.anulada_en is not null) then
    raise exception 'Un pedido de esta caja está anulado: sácalo de la caja primero.';
  end if;
  select array_agg((x->>'item_id')::bigint order by (x->>'item_id')::bigint) into v_ids from jsonb_array_elements(p->'lineas') x;
  perform 1 from public.jab_compra_items where id = any(v_ids) order by id for update;

  for l in select * from jsonb_array_elements(p->'lineas') loop
    select * into it from public.jab_compra_items where id = (l->>'item_id')::bigint and quitado_en is null;
    if not found then
      raise exception 'Artículo no válido.';
    end if;
    if not exists (select 1 from public.jab_paquetes where compra_id = it.compra_id and envio_id = v_envio and quitado_en is null) then
      raise exception '"%" no es de un pedido que venga en esta caja.', it.descripcion;
    end if;
    v_rec := coalesce((l->>'recibidas')::int, 0);
    v_falt := coalesce((l->>'faltantes')::int, 0);
    if v_rec < 0 or v_falt < 0 then
      raise exception 'Cantidades no válidas en "%".', it.descripcion;
    end if;
    if v_rec + v_falt > it.cantidad - it.recibidas - it.faltantes then
      raise exception 'De "%" solo quedan % por recibir.', it.descripcion, it.cantidad - it.recibidas - it.faltantes;
    end if;
    select numero into v_num_compra from public.jab_compras where id = it.compra_id;

    if v_rec > 0 then
      v_costo := round(it.precio * public.jab__factor_compra(it.compra_id) + v_fpp, 4);
      v_talla := coalesce(nullif(trim(l->>'talla'), ''), it.talla);
      v_color := coalesce(nullif(trim(l->>'color'), ''), it.color);
      v_var := nullif(l->>'variante_id', '')::bigint;

      if v_var is not null then
        select producto_id into v_prod from public.jab_variantes where id = v_var;
        if not found then
          raise exception 'La talla elegida para "%" no existe.', it.descripcion;
        end if;
      else
        v_prod := coalesce(nullif(l->>'producto_id', '')::bigint, case when l ? 'nueva' then null else it.producto_id end);
        if v_prod is null then
          if coalesce(trim(l#>>'{nueva,nombre}'), '') = '' or nullif(l#>>'{nueva,precio}', '') is null
             or (l#>>'{nueva,precio}')::numeric < 0 then
            raise exception 'Para "%" elige una prenda del inventario o escribe nombre y precio de venta de la prenda nueva.', it.descripcion;
          end if;
          v_llave := lower(trim(l#>>'{nueva,nombre}'));
          if v_creados ? v_llave then
            v_prod := (v_creados->>v_llave)::bigint;
          else
            insert into public.jab_productos (nombre, categoria, precio, foto, foto_mini, notas)
            values (trim(l#>>'{nueva,nombre}'), coalesce(nullif(trim(l#>>'{nueva,categoria}'), ''), 'Otros'),
                    round((l#>>'{nueva,precio}')::numeric, 2), it.foto, it.foto_mini, 'Pedido #' || v_num_compra)
            returning id into v_prod;
            v_creados := v_creados || jsonb_build_object(v_llave, v_prod);
          end if;
        elsif not exists (select 1 from public.jab_productos where id = v_prod) then
          raise exception 'La prenda elegida para "%" no existe.', it.descripcion;
        end if;
        select id into v_var from public.jab_variantes where producto_id = v_prod and talla = v_talla and color = v_color;
        if v_var is null then
          insert into public.jab_variantes (producto_id, talla, color) values (v_prod, v_talla, v_color) returning id into v_var;
        end if;
      end if;

      -- Costo promedio de la prenda (lo que había a su costo + lo que llega a su costo real)
      perform 1 from public.jab_productos where id = v_prod for update;
      select coalesce(sum(stock), 0) into v_stock from public.jab_variantes where producto_id = v_prod;
      select costo into v_costo_ant from public.jab_producto_costos where producto_id = v_prod;
      v_costo_nuevo := case when v_costo_ant is null or v_stock <= 0 then v_costo
                            else round((v_stock * v_costo_ant + v_rec * v_costo) / (v_stock + v_rec), 4) end;
      insert into public.jab_producto_costos (producto_id, costo) values (v_prod, v_costo_nuevo)
      on conflict (producto_id) do update set costo = excluded.costo, actualizado_en = now();
      perform public.jab__auditar('producto_costos', v_prod::text, 'costo_por_compra',
        jsonb_build_object('costo', v_costo_ant, 'stock', v_stock),
        jsonb_build_object('costo', v_costo_nuevo, 'costo_llegada', v_costo, 'piezas', v_rec, 'envio', e.numero, 'pedido', v_num_compra));
      update public.jab_variantes set activo = true where id = v_var;
      update public.jab_productos set activo = true where id = v_prod;

      perform public.jab__mover_stock(v_var, v_rec, 'compra', null, 'Envío #' || e.numero || ' · Pedido #' || v_num_compra);
      -- costo_real = promedio de todas las llegadas del artículo (cada caja trae su flete)
      update public.jab_compra_items
         set costo_real = case when recibidas > 0 and costo_real is not null
                               then round((recibidas * costo_real + v_rec * v_costo) / (recibidas + v_rec), 4) else v_costo end,
             recibidas = recibidas + v_rec, variante_id = v_var, producto_id = v_prod
       where id = it.id;
    end if;
    if v_falt > 0 then
      update public.jab_compra_items set faltantes = faltantes + v_falt where id = it.id;
    end if;
  end loop;

  update public.jab_envios set
    estado = 'recibido', recibido_en = now(), piezas_recibidas = v_piezas, flete_por_pieza = v_fpp,
    fecha_salida = coalesce(fecha_salida, public.jab__hoy()), fecha_llegada = coalesce(fecha_llegada, public.jab__hoy())
  where id = v_envio;
  perform public.jab__auditar('envios', v_envio::text, 'recibir', null,
    jsonb_build_object('piezas', v_piezas, 'flete', e.flete, 'flete_por_pieza', v_fpp));
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_envio));
  return v_envio;
end $$;

-- Reembolso de SHEIN por un artículo que no llegó (entra dinero a una cuenta)
create function public.jab_reembolso_item(p_item bigint, p_cuenta bigint, p_monto numeric, p_tasa numeric default null, p_clave uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare it public.jab_compra_items; v_prev jsonb; v_grupo uuid; v_num bigint;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(p_clave, 'reembolso');
  if v_prev is not null then
    return (v_prev->>'grupo')::uuid;
  end if;
  select * into it from public.jab_compra_items where id = p_item and quitado_en is null for update;
  if not found then
    raise exception 'Ese artículo no existe.';
  end if;
  if it.faltantes <= 0 then
    raise exception 'Solo se registran reembolsos de artículos marcados como faltantes.';
  end if;
  select numero into v_num from public.jab_compras where id = it.compra_id and anulada_en is null;
  if not found then
    raise exception 'Ese pedido está anulado.';
  end if;
  v_grupo := public.jab__pago_inversion(p_cuenta, p_monto, p_tasa, 'Reembolso SHEIN',
               'Pedido #' || v_num || ' · ' || it.descripcion, it.compra_id, null, 1);
  update public.jab_movimientos_dinero set compra_item_id = p_item where grupo = v_grupo;
  perform public.jab__idem_fin(p_clave, jsonb_build_object('grupo', v_grupo));
  return v_grupo;
end $$;

-- Lo que nunca va a llegar (o deshacer esa marca con cantidad negativa), sin pasar por una caja
create function public.jab_marcar_faltante(p_item bigint, p_cantidad int, p_clave uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare it public.jab_compra_items; v_prev jsonb;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(p_clave, 'faltante');
  if v_prev is not null then
    return;
  end if;
  if p_cantidad is null or p_cantidad = 0 then
    raise exception 'Cantidad no válida.';
  end if;
  select * into it from public.jab_compra_items where id = p_item and quitado_en is null;
  if not found then
    raise exception 'Ese artículo no existe.';
  end if;
  perform 1 from public.jab_compras where id = it.compra_id and anulada_en is null for update;
  if not found then
    raise exception 'Ese pedido está anulado.';
  end if;
  select * into it from public.jab_compra_items where id = p_item for update;
  if p_cantidad > 0 and p_cantidad > it.cantidad - it.recibidas - it.faltantes then
    raise exception 'De "%" solo quedan % por llegar.', it.descripcion, it.cantidad - it.recibidas - it.faltantes;
  end if;
  if p_cantidad < 0 and -p_cantidad > it.faltantes then
    raise exception 'De "%" solo hay % marcadas como faltantes.', it.descripcion, it.faltantes;
  end if;
  if p_cantidad < 0 and it.faltantes + p_cantidad = 0 and it.reembolsado > 0 then
    raise exception 'De "%" ya hay un reembolso registrado: anúlalo primero en Dinero.', it.descripcion;
  end if;
  update public.jab_compra_items set faltantes = faltantes + p_cantidad where id = p_item;
  perform public.jab__auditar('compra_items', p_item::text, 'faltante',
    jsonb_build_object('faltantes', it.faltantes), jsonb_build_object('faltantes', it.faltantes + p_cantidad));
  perform public.jab__idem_fin(p_clave, '{}'::jsonb);
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
  public.jab_guardar_envio(jsonb), public.jab_envio_estado(bigint, text), public.jab_pagar_flete(bigint, bigint, numeric, numeric, uuid),
  public.jab_anular_envio(bigint, text, boolean), public.jab_recibir_envio(jsonb),
  public.jab_reembolso_item(bigint, bigint, numeric, numeric, uuid), public.jab_marcar_faltante(bigint, int, uuid)
to authenticated;
