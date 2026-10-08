-- =====================================================================
-- JABELLA Store — estructura base (entrega 1)
-- Vive DENTRO de la base de Mercantil Yumana, totalmente aislada: todo lleva prefijo jab_
-- y sus permisos solo dejan entrar a usuarios de jab_usuarios. Nada de Yumana se toca.
-- Inventario, ventas (contado, apartado, fiado, cambios), clientas,
-- dinero por cuenta y usuarios con rol (dueña / vendedora).
--
-- Regla de oro: toda escritura de dinero o de existencia pasa por una
-- función (RPC) que valida el rol, bloquea las filas que toca y recalcula
-- desde la fuente de verdad (nunca resta sobre datos en memoria).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Usuarios
-- ---------------------------------------------------------------------
create table public.jab_usuarios (
  id uuid primary key references auth.users(id),
  usuario text not null unique check (usuario ~ '^[a-z0-9._-]{3,30}$'),
  nombre text not null check (length(trim(nombre)) > 0),
  rol text not null check (rol in ('duena','vendedora')),
  activo boolean not null default true,
  debe_cambiar_clave boolean not null default true,
  creado_en timestamptz not null default now()
);

create function public.jab_es_activo() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.jab_usuarios where id = auth.uid() and activo)
$$;

create function public.jab_es_duena() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.jab_usuarios where id = auth.uid() and activo and rol = 'duena')
$$;

-- ---------------------------------------------------------------------
-- Configuración y tasa del día
-- ---------------------------------------------------------------------
create table public.jab_config (
  id smallint primary key default 1 check (id = 1),
  tasa_bs numeric(14,4) not null default 0 check (tasa_bs >= 0),
  tasa_actualizada_en timestamptz,
  tasa_actualizada_por uuid references public.jab_usuarios(id),
  dias_apartado int not null default 15 check (dias_apartado between 1 and 120),
  abono_minimo_pct numeric(5,2) not null default 50 check (abono_minimo_pct between 0 and 100),
  vendedora_fia boolean not null default false,
  tarifa_libra numeric(10,2) not null default 6.99 check (tarifa_libra >= 0)
);
insert into public.jab_config default values;

create table public.jab_tasas (
  id bigint generated always as identity primary key,
  tasa numeric(14,4) not null check (tasa > 0),
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Dónde está el dinero: cuentas y métodos de pago
-- ---------------------------------------------------------------------
create table public.jab_cuentas (
  id bigint generated always as identity primary key,
  nombre text not null unique check (length(trim(nombre)) > 0),
  moneda text not null check (moneda in ('USD','VES')),
  activa boolean not null default true,
  orden int not null default 0
);

create table public.jab_metodos_pago (
  id bigint generated always as identity primary key,
  nombre text not null unique check (length(trim(nombre)) > 0),
  cuenta_id bigint references public.jab_cuentas(id),
  es_saldo_favor boolean not null default false,
  activo boolean not null default true,
  orden int not null default 0,
  check ((es_saldo_favor and cuenta_id is null) or (not es_saldo_favor and cuenta_id is not null))
);

-- ---------------------------------------------------------------------
-- Clientas y saldo a favor
-- ---------------------------------------------------------------------
create table public.jab_clientes (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) > 0),
  telefono text,
  cedula text,
  notas text,
  creado_en timestamptz not null default now(),
  creado_por uuid default auth.uid(),
  deleted_at timestamptz
);

create table public.jab_saldo_favor_mov (
  id bigint generated always as identity primary key,
  cliente_id bigint not null references public.jab_clientes(id),
  monto numeric(12,2) not null check (monto <> 0),   -- + a favor de la clienta, − usado
  motivo text not null,
  venta_id bigint,
  pago_id bigint,
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now()
);
create index on public.jab_saldo_favor_mov (cliente_id);

-- ---------------------------------------------------------------------
-- Productos, tallas/colores y existencia
-- ---------------------------------------------------------------------
create table public.jab_productos (
  id bigint generated always as identity primary key,
  codigo text unique,
  nombre text not null check (length(trim(nombre)) > 0),
  categoria text not null default 'Otros',
  precio numeric(12,2) not null check (precio >= 0),
  foto text,
  foto_mini text,
  notas text,
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  creado_por uuid default auth.uid()
);

create function public.jab__codigo_producto() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.codigo is null or new.codigo = '' then
    new.codigo := 'JB-' || case when new.id < 10000 then lpad(new.id::text, 4, '0') else new.id::text end;
  end if;
  return new;
end $$;
create trigger trg_codigo_producto before insert on public.jab_productos
  for each row execute function public.jab__codigo_producto();

-- Costo real por prenda (solo la dueña lo ve)
create table public.jab_producto_costos (
  producto_id bigint primary key references public.jab_productos(id),
  costo numeric(12,4) not null check (costo >= 0),
  actualizado_en timestamptz not null default now()
);

create table public.jab_variantes (
  id bigint generated always as identity primary key,
  producto_id bigint not null references public.jab_productos(id),
  talla text not null default '',
  color text not null default '',
  stock int not null default 0 check (stock >= 0),
  activo boolean not null default true,
  unique (producto_id, talla, color)
);
create index on public.jab_variantes (producto_id);

create table public.jab_movimientos_inventario (
  id bigint generated always as identity primary key,
  variante_id bigint not null references public.jab_variantes(id),
  cantidad int not null check (cantidad <> 0),        -- + entra, − sale
  stock_resultante int not null,
  tipo text not null check (tipo in ('inicial','ajuste','venta','apartado','anulacion',
                                     'cambio_devuelto','cambio_entregado','apartado_cancelado','compra')),
  venta_id bigint,
  nota text,
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now()
);
create index on public.jab_movimientos_inventario (variante_id);

-- ---------------------------------------------------------------------
-- Ventas
-- ---------------------------------------------------------------------
create table public.jab_contadores (
  nombre text primary key,
  valor bigint not null default 0
);
insert into public.jab_contadores (nombre, valor) values ('venta', 0);

create table public.jab_ventas (
  id bigint generated always as identity primary key,
  numero bigint not null unique,          -- número corrido sin huecos (el que ve la clienta)
  tipo text not null check (tipo in ('contado','apartado','fiado','cambio')),
  estado text not null default 'activa' check (estado in ('activa','cancelada','anulada')),
  cliente_id bigint references public.jab_clientes(id),
  venta_origen_id bigint references public.jab_ventas(id),
  total numeric(12,2) not null default 0,
  pagado numeric(12,2) not null default 0,
  entregada boolean not null default true,
  entregada_en timestamptz,
  vence_en date,
  era_apartado boolean not null default false,
  abono_retenido numeric(12,2) not null default 0,
  nota text,
  creado_en timestamptz not null default now(),
  usuario_id uuid references public.jab_usuarios(id),
  anulada_en timestamptz,
  anulada_por uuid,
  motivo_anulacion text,
  cancelada_en timestamptz,
  cancelada_por uuid
);
create index on public.jab_ventas (creado_en);
create index on public.jab_ventas (cliente_id);
create index on public.jab_ventas (venta_origen_id);

create table public.jab_venta_items (
  id bigint generated always as identity primary key,
  venta_id bigint not null references public.jab_ventas(id),
  variante_id bigint not null references public.jab_variantes(id),
  producto_id bigint not null references public.jab_productos(id),
  descripcion text not null,
  cantidad int not null check (cantidad <> 0),          -- negativa = prenda devuelta en un cambio
  precio numeric(12,2) not null check (precio >= 0),     -- precio cobrado por unidad
  precio_lista numeric(12,2) not null check (precio_lista >= 0),
  item_origen_id bigint references public.jab_venta_items(id)
);
create index on public.jab_venta_items (venta_id);
create index on public.jab_venta_items (item_origen_id);

-- Costo de cada prenda vendida al momento de la venta (solo la dueña lo ve)
create table public.jab_venta_item_costos (
  venta_item_id bigint primary key references public.jab_venta_items(id),
  costo numeric(12,4)
);

create table public.jab_pagos (
  id bigint generated always as identity primary key,
  venta_id bigint not null references public.jab_ventas(id),
  metodo_id bigint not null references public.jab_metodos_pago(id),
  cuenta_id bigint references public.jab_cuentas(id),       -- null = pagado con saldo a favor
  moneda text not null check (moneda in ('USD','VES')),
  monto numeric(14,2) not null check (monto > 0),         -- en la moneda del método
  tasa numeric(14,4),
  monto_usd numeric(12,2) not null check (monto_usd > 0),
  referencia text,
  creado_en timestamptz not null default now(),
  usuario_id uuid references public.jab_usuarios(id),
  anulado_en timestamptz,
  anulado_por uuid,
  motivo_anulacion text
);
create index on public.jab_pagos (venta_id);
create index on public.jab_pagos (creado_en);

-- ---------------------------------------------------------------------
-- Movimientos de dinero que no son ventas (gastos, retiros, cambios de moneda)
-- ---------------------------------------------------------------------
create table public.jab_movimientos_dinero (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('gasto','retiro','ingreso','transferencia','ajuste')),
  cuenta_id bigint not null references public.jab_cuentas(id),
  monto numeric(14,2) not null check (monto <> 0),        -- con signo, en la moneda de la cuenta
  tasa numeric(14,4),
  monto_usd numeric(12,2) not null,
  categoria text,
  descripcion text,
  grupo uuid,
  creado_en timestamptz not null default now(),
  usuario_id uuid default auth.uid(),
  anulado_en timestamptz,
  anulado_por uuid
);
create index on public.jab_movimientos_dinero (cuenta_id);
create index on public.jab_movimientos_dinero (creado_en);

-- ---------------------------------------------------------------------
-- Operaciones ya procesadas: si el teléfono reintenta (se cayó el internet
-- después de guardar), la base devuelve el resultado anterior sin repetir nada.
-- ---------------------------------------------------------------------
create table public.jab_operaciones (
  clave uuid primary key,
  tipo text not null,
  resultado jsonb,
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Auditoría: antes y después de toda corrección
-- ---------------------------------------------------------------------
create table public.jab_auditoria (
  id bigint generated always as identity primary key,
  tabla text not null,
  registro_id text not null,
  accion text not null,
  antes jsonb,
  despues jsonb,
  usuario_id uuid default auth.uid(),
  creado_en timestamptz not null default now()
);

create function public.jab__auditar(p_tabla text, p_id text, p_accion text, p_antes jsonb, p_despues jsonb)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.jab_auditoria (tabla, registro_id, accion, antes, despues, usuario_id)
  values (p_tabla, p_id, p_accion, p_antes, p_despues, auth.uid());
$$;

-- =====================================================================
-- Funciones internas (no se exponen a la app)
-- =====================================================================

-- Siguiente número corrido. Si la transacción falla, el número se devuelve (no deja huecos).
create function public.jab__siguiente(p_nombre text) returns bigint
language sql security definer set search_path = public, pg_temp as $$
  update public.jab_contadores set valor = valor + 1 where nombre = p_nombre returning valor
$$;

create function public.jab__num(p_venta bigint) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select '#' || numero from public.jab_ventas where id = p_venta
$$;

-- Reserva la clave de una operación. Si ya se procesó, devuelve su resultado.
-- Si otra transacción la está procesando en este momento, espera a que termine.
create function public.jab__idem_inicio(p_clave uuid, p_tipo text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; n int;
begin
  if p_clave is null then return null; end if;
  insert into public.jab_operaciones (clave, tipo) values (p_clave, p_tipo) on conflict (clave) do nothing;
  get diagnostics n = row_count;
  if n = 1 then return null; end if;
  select resultado into r from public.jab_operaciones where clave = p_clave;
  if r is null then
    raise exception 'Esta operación ya se registró. Revisa antes de repetirla.';
  end if;
  return r;
end $$;

create function public.jab__idem_fin(p_clave uuid, p_resultado jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.jab_operaciones set resultado = p_resultado where clave = p_clave;
$$;

create function public.jab__hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Caracas')::date
$$;

create function public.jab__exigir_activo() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.jab_es_activo() then
    raise exception 'Tu usuario no está activo. Pídele acceso a la dueña.';
  end if;
end $$;

create function public.jab__exigir_duena() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.jab_es_duena() then
    raise exception 'Solo la dueña puede hacer esto.';
  end if;
end $$;

-- Recalcula lo pagado de una venta desde los pagos vivos (idempotente)
create function public.jab__recalcular_pagado(p_venta bigint) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric;
begin
  select coalesce(sum(monto_usd), 0) into v from public.jab_pagos
   where venta_id = p_venta and anulado_en is null;
  update public.jab_ventas set pagado = v where id = p_venta;
  return v;
end $$;

create function public.jab__saldo_favor(p_cliente bigint) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(monto), 0) from public.jab_saldo_favor_mov where cliente_id = p_cliente
$$;

-- Inserta los pagos de una venta. Devuelve el total en $.
-- Cada pago: {metodo_id, monto_usd, monto (en Bs si el método es en Bs), tasa, referencia}
create function public.jab__insertar_pagos(p_venta bigint, p_cliente bigint, p_pagos jsonb)
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
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id)
      values (p_venta, m.id, null, 'USD', v_usd, null, v_usd, nullif(p->>'referencia',''), auth.uid())
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
      insert into public.jab_pagos (venta_id, metodo_id, cuenta_id, moneda, monto, tasa, monto_usd, referencia, usuario_id)
      values (p_venta, m.id, m.cuenta_id, m.cuenta_moneda, v_monto, v_tasa, v_usd, nullif(p->>'referencia',''), auth.uid());
    end if;

    v_total := v_total + v_usd;
  end loop;
  return v_total;
end $$;

-- Mueve la existencia de una variante (ya bloqueada) y deja el movimiento
create function public.jab__mover_stock(p_variante bigint, p_cantidad int, p_tipo text, p_venta bigint, p_nota text)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actual int; v_nuevo int; v_desc text;
begin
  select stock into v_actual from public.jab_variantes where id = p_variante for update;
  if not found then
    raise exception 'La prenda no existe.';
  end if;
  v_nuevo := v_actual + p_cantidad;
  if v_nuevo < 0 then
    select pr.nombre
           || case when v.talla <> '' then ' · ' || v.talla else '' end
           || case when v.color <> '' then ' · ' || v.color else '' end
      into v_desc
      from public.jab_variantes v join public.jab_productos pr on pr.id = v.producto_id where v.id = p_variante;
    if p_cantidad < 0 and v_actual > 0 then
      raise exception 'De % solo quedan %.', v_desc, v_actual;
    end if;
    raise exception 'No hay existencia de %.', v_desc;
  end if;
  update public.jab_variantes set stock = v_nuevo where id = p_variante;
  insert into public.jab_movimientos_inventario (variante_id, cantidad, stock_resultante, tipo, venta_id, nota)
  values (p_variante, p_cantidad, v_nuevo, p_tipo, p_venta, p_nota);
  return v_nuevo;
end $$;

-- Bloquea en orden fijo las variantes de una lista de items (evita bloqueos cruzados)
create function public.jab__bloquear_variantes(p_ids bigint[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform 1 from public.jab_variantes where id = any(p_ids) order by id for update;
end $$;

-- Agrega una línea a una venta (positiva = sale de la tienda, negativa = vuelve)
create function public.jab__agregar_item(p_venta bigint, p_variante bigint, p_cantidad int, p_precio numeric,
                                     p_tipo_mov text, p_item_origen bigint, p_costo numeric)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v record;
  v_precio numeric;
  v_item bigint;
  v_desc text;
  v_costo numeric;
begin
  select va.id, va.talla, va.color, va.producto_id, va.activo as var_activa, pr.nombre, pr.precio, pr.activo as prod_activo
    into v
    from public.jab_variantes va join public.jab_productos pr on pr.id = va.producto_id
   where va.id = p_variante;
  if not found then
    raise exception 'La prenda no existe.';
  end if;

  if p_cantidad > 0 and (not v.var_activa or not v.prod_activo) then
    raise exception 'La prenda "%" está archivada. Actívala en Inventario para venderla.', v.nombre;
  end if;

  v_precio := round(coalesce(p_precio, v.precio), 2);
  if v_precio < 0 then
    raise exception 'El precio no puede ser negativo.';
  end if;
  if p_item_origen is null and v_precio <> v.precio and not public.jab_es_duena() then
    raise exception 'Solo la dueña puede cambiar el precio de %.', v.nombre;
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

-- =====================================================================
-- Funciones que usa la app (RPC)
-- =====================================================================

-- ---------- Usuarios ----------
create function public.jab_marcar_clave_cambiada() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.jab__exigir_activo();
  update public.jab_usuarios set debe_cambiar_clave = false where id = auth.uid();
end $$;

create function public.jab_actualizar_usuario(p_id uuid, p_nombre text, p_rol text, p_activo boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_antes jsonb;
begin
  perform public.jab__exigir_duena();
  if p_rol not in ('duena','vendedora') then
    raise exception 'Rol no válido.';
  end if;
  perform 1 from public.jab_usuarios where rol = 'duena' and activo order by id for update;
  select to_jsonb(u) into v_antes from public.jab_usuarios u where id = p_id for update;
  if v_antes is null then
    raise exception 'Ese usuario no existe.';
  end if;
  update public.jab_usuarios
     set nombre = coalesce(nullif(trim(p_nombre), ''), nombre), rol = p_rol, activo = p_activo
   where id = p_id;
  if not exists (select 1 from public.jab_usuarios where rol = 'duena' and activo) then
    raise exception 'Debe quedar al menos una dueña activa.';
  end if;
  perform public.jab__auditar('usuarios', p_id::text, 'editar', v_antes,
    (select to_jsonb(u) from public.jab_usuarios u where id = p_id));
end $$;

-- ---------- Configuración ----------
create function public.jab_actualizar_tasa(p_tasa numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_antes numeric;
begin
  perform public.jab__exigir_activo();
  if p_tasa is null or p_tasa <= 0 or p_tasa > 1000000 then
    raise exception 'Escribe una tasa válida.';
  end if;
  select tasa_bs into v_antes from public.jab_config where id = 1 for update;
  -- La vendedora solo confirma o ajusta poco la tasa; los cambios grandes los hace la dueña
  if not public.jab_es_duena() then
    if coalesce(v_antes, 0) <= 0 then
      raise exception 'La primera tasa la pone la dueña.';
    end if;
    if abs(p_tasa / v_antes - 1) > 0.05 then
      raise exception 'La tasa cambia más de 5 por ciento. Pídele a la dueña que la ponga.';
    end if;
  end if;
  perform public.jab__auditar('config', 'tasa', 'cambio_tasa', jsonb_build_object('tasa', v_antes), jsonb_build_object('tasa', round(p_tasa, 4)));
  update public.jab_config
     set tasa_bs = round(p_tasa, 4), tasa_actualizada_en = now(), tasa_actualizada_por = auth.uid()
   where id = 1;
  insert into public.jab_tasas (tasa) values (round(p_tasa, 4));
end $$;

create function public.jab_actualizar_config(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_antes jsonb;
begin
  perform public.jab__exigir_duena();
  select to_jsonb(c) into v_antes from public.jab_config c where id = 1;
  update public.jab_config set
    dias_apartado    = coalesce((p->>'dias_apartado')::int, dias_apartado),
    abono_minimo_pct = coalesce((p->>'abono_minimo_pct')::numeric, abono_minimo_pct),
    vendedora_fia    = coalesce((p->>'vendedora_fia')::boolean, vendedora_fia),
    tarifa_libra     = coalesce((p->>'tarifa_libra')::numeric, tarifa_libra)
  where id = 1;
  perform public.jab__auditar('config', '1', 'editar', v_antes, (select to_jsonb(c) from public.jab_config c where id = 1));
end $$;

-- ---------- Productos ----------
-- p = {id?, nombre, categoria, precio, foto?, foto_mini?, notas?, activo?, costo?,
--      variantes: [{id?, talla, color, stock? (solo nuevas), activo?}]}
create function public.jab_guardar_producto(p jsonb) returns bigint
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
    insert into public.jab_productos (nombre, categoria, precio, foto, foto_mini, notas, activo)
    values (trim(p->>'nombre'), coalesce(nullif(trim(p->>'categoria'), ''), 'Otros'),
            round((p->>'precio')::numeric, 2), nullif(p->>'foto', ''), nullif(p->>'foto_mini', ''),
            nullif(trim(p->>'notas'), ''), coalesce((p->>'activo')::boolean, true))
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

create function public.jab_ajustar_stock(p_variante bigint, p_nuevo int, p_nota text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actual int;
begin
  perform public.jab__exigir_duena();
  if p_nuevo is null or p_nuevo < 0 then
    raise exception 'La existencia no puede ser negativa.';
  end if;
  select stock into v_actual from public.jab_variantes where id = p_variante for update;
  if not found then
    raise exception 'La prenda no existe.';
  end if;
  if p_nuevo <> v_actual then
    perform public.jab__mover_stock(p_variante, p_nuevo - v_actual, 'ajuste', null, nullif(trim(p_nota), ''));
  end if;
end $$;

-- ---------- Ventas ----------
-- p = {tipo: contado|apartado|fiado, cliente_id?, nota?,
--      items: [{variante_id, cantidad, precio?}], pagos: [...]}
create function public.jab_registrar_venta(p jsonb) returns bigint
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
  if v_tipo = 'fiado' and not public.jab_es_duena() and not v_cfg.vendedora_fia then
    raise exception 'Solo la dueña puede vender fiado.';
  end if;
  if coalesce(jsonb_typeof(p->'items'), '') <> 'array' or jsonb_array_length(p->'items') = 0 then
    raise exception 'La venta no tiene prendas.';
  end if;

  insert into public.jab_ventas (numero, tipo, cliente_id, entregada, entregada_en, vence_en, era_apartado, nota, usuario_id)
  values (public.jab__siguiente('venta'), v_tipo, v_cliente, v_tipo <> 'apartado', case when v_tipo <> 'apartado' then now() end,
          case when v_tipo = 'apartado' then public.jab__hoy() + v_cfg.dias_apartado end,
          v_tipo = 'apartado', nullif(trim(p->>'nota'), ''), auth.uid())
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
  perform public.jab__idem_fin(v_clave, jsonb_build_object('id', v_venta));
  return v_venta;
end $$;

create function public.jab_registrar_abono(p_venta bigint, p_pagos jsonb, p_clave uuid default null) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.jab_ventas;
  v_saldo numeric;
  v_abono numeric;
  v_prev jsonb;
begin
  perform public.jab__exigir_activo();
  v_prev := public.jab__idem_inicio(p_clave, 'abono');
  if v_prev is not null then
    return (v_prev->>'saldo')::numeric;
  end if;
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found then
    raise exception 'Esa venta no existe.';
  end if;
  if v.estado <> 'activa' or v.tipo not in ('apartado','fiado') then
    raise exception 'A esta venta no se le pueden hacer abonos.';
  end if;
  v_saldo := public.jab__recalcular_pagado(p_venta);
  v_saldo := v.total - v_saldo;
  if v_saldo <= 0.004 then
    raise exception 'Esta venta ya está pagada.';
  end if;
  v_abono := public.jab__insertar_pagos(p_venta, v.cliente_id, p_pagos);
  if v_abono <= 0 then
    raise exception 'Escribe el monto del abono.';
  end if;
  if v_abono > v_saldo + 0.004 then
    raise exception 'El abono ($%) es mayor que lo que debe ($%).', v_abono, v_saldo;
  end if;
  v_saldo := v.total - public.jab__recalcular_pagado(p_venta);
  perform public.jab__idem_fin(p_clave, jsonb_build_object('saldo', v_saldo));
  return v_saldo;
end $$;

create function public.jab_entregar_apartado(p_venta bigint, p_dejar_fiado boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.jab_ventas;
  v_saldo numeric;
  v_fia boolean;
begin
  perform public.jab__exigir_activo();
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found or v.tipo <> 'apartado' or v.estado <> 'activa' or v.entregada then
    raise exception 'Este apartado no se puede entregar.';
  end if;
  v_saldo := v.total - public.jab__recalcular_pagado(p_venta);
  if v_saldo > 0.004 then
    if not coalesce(p_dejar_fiado, false) then
      raise exception 'Falta pagar $% para entregar el apartado.', round(v_saldo, 2);
    end if;
    select vendedora_fia into v_fia from public.jab_config where id = 1;
    if not public.jab_es_duena() and not v_fia then
      raise exception 'Solo la dueña puede entregar dejando deuda.';
    end if;
    update public.jab_ventas set tipo = 'fiado' where id = p_venta;
  end if;
  update public.jab_ventas set entregada = true, entregada_en = now() where id = p_venta;
  perform public.jab__auditar('ventas', p_venta::text, 'entregar_apartado',
    jsonb_build_object('saldo', v_saldo), jsonb_build_object('dejo_fiado', v_saldo > 0.004));
end $$;

create function public.jab_extender_apartado(p_venta bigint, p_dias int) returns date
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.jab_ventas; v_nueva date;
begin
  perform public.jab__exigir_duena();
  if p_dias is null or p_dias < 1 or p_dias > 120 then
    raise exception 'Días no válidos.';
  end if;
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found or v.tipo <> 'apartado' or v.estado <> 'activa' or v.entregada then
    raise exception 'Este apartado no se puede extender.';
  end if;
  v_nueva := greatest(v.vence_en, public.jab__hoy()) + p_dias;
  update public.jab_ventas set vence_en = v_nueva where id = p_venta;
  perform public.jab__auditar('ventas', p_venta::text, 'extender_apartado',
    jsonb_build_object('vence_en', v.vence_en), jsonb_build_object('vence_en', v_nueva));
  return v_nueva;
end $$;

-- p_destino: 'saldo_favor' (el abono queda a favor de la clienta) o 'tienda' (la tienda se queda el abono)
create function public.jab_cancelar_apartado(p_venta bigint, p_destino text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.jab_ventas;
  it record;
  v_pagado numeric;
begin
  perform public.jab__exigir_duena();
  if p_destino is null or p_destino not in ('saldo_favor','tienda') then
    raise exception 'Elige qué pasa con el abono.';
  end if;
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found or v.tipo <> 'apartado' or v.estado <> 'activa' or v.entregada then
    raise exception 'Este apartado no se puede cancelar.';
  end if;

  perform public.jab__bloquear_variantes(array(select variante_id from public.jab_venta_items where venta_id = p_venta));
  for it in select * from public.jab_venta_items where venta_id = p_venta loop
    perform public.jab__mover_stock(it.variante_id, it.cantidad, 'apartado_cancelado', p_venta, null);
  end loop;

  v_pagado := public.jab__recalcular_pagado(p_venta);
  if v_pagado > 0 then
    if p_destino = 'saldo_favor' then
      insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id)
      values (v.cliente_id, v_pagado, 'Abono del apartado cancelado ' || public.jab__num(p_venta), p_venta);
    else
      update public.jab_ventas set abono_retenido = v_pagado where id = p_venta;
    end if;
  end if;

  update public.jab_ventas set estado = 'cancelada', cancelada_en = now(), cancelada_por = auth.uid() where id = p_venta;
  perform public.jab__auditar('ventas', p_venta::text, 'cancelar_apartado',
    jsonb_build_object('pagado', v_pagado), jsonb_build_object('destino', p_destino));
end $$;

-- p = {venta_origen_id?, cliente_id?, nota?,
--      devueltos: [{venta_item_id?, variante_id?, cantidad, precio?}],
--      entregados: [{variante_id, cantidad, precio?}], pagos: [...]}
create function public.jab_registrar_cambio(p jsonb) returns bigint
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

create function public.jab_anular_venta(p_venta bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.jab_ventas;
  it record;
  sf record;
  v_dep bigint;
  v_antes jsonb;
begin
  perform public.jab__exigir_duena();
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo de la anulación.';
  end if;
  select * into v from public.jab_ventas where id = p_venta for update;
  if not found or v.estado <> 'activa' then
    raise exception 'Esta venta no se puede anular.';
  end if;
  select ve.numero into v_dep from public.jab_ventas ve
   where ve.venta_origen_id = p_venta and ve.estado = 'activa' limit 1;
  if v_dep is not null then
    raise exception 'Primero anula el cambio #% que salió de esta venta.', v_dep;
  end if;
  v_antes := to_jsonb(v);

  -- Devolver la existencia (las prendas devueltas en un cambio vuelven a salir)
  perform public.jab__bloquear_variantes(array(select variante_id from public.jab_venta_items where venta_id = p_venta));
  for it in select * from public.jab_venta_items where venta_id = p_venta loop
    perform public.jab__mover_stock(it.variante_id, it.cantidad, 'anulacion', p_venta, p_motivo);
  end loop;

  -- Revertir el saldo a favor que esta venta usó o generó
  if v.cliente_id is not null then
    perform 1 from public.jab_clientes where id = v.cliente_id for update;
  end if;
  for sf in select cliente_id, sum(monto) as monto from public.jab_saldo_favor_mov where venta_id = p_venta group by cliente_id loop
    if sf.monto <> 0 then
      insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id)
      values (sf.cliente_id, -sf.monto, 'Anulación de la venta ' || public.jab__num(p_venta), p_venta);
      if public.jab__saldo_favor(sf.cliente_id) < -0.004 then
        raise exception 'La clienta ya usó el saldo a favor de esta venta. Anula primero el pago o la venta donde lo usó.';
      end if;
    end if;
  end loop;

  update public.jab_pagos set anulado_en = now(), anulado_por = auth.uid(), motivo_anulacion = p_motivo
   where venta_id = p_venta and anulado_en is null;
  perform public.jab__recalcular_pagado(p_venta);
  update public.jab_ventas set estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(), motivo_anulacion = trim(p_motivo)
   where id = p_venta;
  perform public.jab__auditar('ventas', p_venta::text, 'anular', v_antes,
    (select to_jsonb(x) from public.jab_ventas x where id = p_venta));
end $$;

-- Anula un pago (ej.: pago móvil que nunca llegó). La deuda queda anotada:
-- si las prendas ya se entregaron, la venta pasa a fiado (sin mover existencia).
create function public.jab_anular_pago(p_pago bigint, p_motivo text, p_cliente bigint default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pg public.jab_pagos;
  v public.jab_ventas;
  v_venta bigint;
  v_saldo numeric;
begin
  perform public.jab__exigir_duena();
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo.';
  end if;
  select venta_id into v_venta from public.jab_pagos where id = p_pago;
  if not found then
    raise exception 'Ese pago no existe.';
  end if;
  -- Primero la venta y después el pago, ambos bloqueados; la revisión va después del bloqueo
  select * into v from public.jab_ventas where id = v_venta for update;
  select * into pg from public.jab_pagos where id = p_pago for update;
  if pg.anulado_en is not null then
    raise exception 'Ese pago ya está anulado.';
  end if;
  if v.estado <> 'activa' then
    raise exception 'Esta venta no está activa.';
  end if;
  if v.tipo = 'cambio' then
    raise exception 'En un cambio no se anula un pago suelto: anula el cambio completo.';
  end if;
  if v.entregada and v.cliente_id is null then
    if p_cliente is null then
      raise exception 'Esta venta no tiene clienta. Elige a quién se le anota la deuda.';
    end if;
    if not exists (select 1 from public.jab_clientes where id = p_cliente and deleted_at is null) then
      raise exception 'Esa clienta no existe.';
    end if;
    update public.jab_ventas set cliente_id = p_cliente where id = v.id;
    v.cliente_id := p_cliente;
  end if;

  update public.jab_pagos set anulado_en = now(), anulado_por = auth.uid(), motivo_anulacion = trim(p_motivo)
   where id = p_pago;
  if pg.cuenta_id is null then
    insert into public.jab_saldo_favor_mov (cliente_id, monto, motivo, venta_id, pago_id)
    values (v.cliente_id, pg.monto_usd, 'Pago anulado de la venta #' || v.numero, v.id, pg.id);
  end if;
  v_saldo := v.total - public.jab__recalcular_pagado(v.id);
  if v.entregada and v.tipo in ('contado','apartado') and v_saldo > 0.004 then
    update public.jab_ventas set tipo = 'fiado' where id = v.id;
  end if;
  perform public.jab__auditar('pagos', p_pago::text, 'anular', to_jsonb(pg),
    jsonb_build_object('motivo', p_motivo, 'tipo_venta_antes', v.tipo, 'saldo', v_saldo));
end $$;

-- ---------- Dinero ----------
-- p = {tipo: gasto|retiro|ingreso|ajuste|transferencia, cuenta_id, monto, tasa?, categoria?, descripcion?,
--      cuenta_destino_id?, monto_destino?}   (monto siempre positivo; en ajuste puede ser negativo)
create function public.jab_registrar_movimiento(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_tipo text := p->>'tipo';
  c1 public.jab_cuentas;
  c2 public.jab_cuentas;
  v_monto numeric := round((p->>'monto')::numeric, 2);
  v_monto2 numeric := round(nullif(p->>'monto_destino', '')::numeric, 2);
  v_tasa numeric := nullif(p->>'tasa', '')::numeric;
  v_grupo uuid := gen_random_uuid();
  v_signo int;
  v_clave uuid := nullif(p->>'clave', '')::uuid;
  v_prev jsonb;
begin
  perform public.jab__exigir_duena();
  v_prev := public.jab__idem_inicio(v_clave, 'movimiento');
  if v_prev is not null then
    return (v_prev->>'grupo')::uuid;
  end if;
  if v_tipo not in ('gasto','retiro','ingreso','ajuste','transferencia') then
    raise exception 'Tipo de movimiento no válido.';
  end if;
  select * into c1 from public.jab_cuentas where id = (p->>'cuenta_id')::bigint;
  if not found then
    raise exception 'Elige la cuenta.';
  end if;
  if v_monto is null or v_monto = 0 or (v_tipo <> 'ajuste' and v_monto < 0) then
    raise exception 'Escribe un monto válido.';
  end if;
  if v_tasa is null then
    select nullif(tasa_bs, 0) into v_tasa from public.jab_config where id = 1;
  end if;
  -- En un cambio de moneda, la tasa es la del cambio real (lo que salió entre lo que llegó)
  if v_tipo = 'transferencia' and v_monto2 is not null and v_monto2 > 0 and v_monto > 0 then
    select * into c2 from public.jab_cuentas where id = (p->>'cuenta_destino_id')::bigint;
    if found and c2.moneda <> c1.moneda then
      v_tasa := round(case when c1.moneda = 'VES' then v_monto / v_monto2 else v_monto2 / v_monto end, 4);
    end if;
  end if;

  v_signo := case when v_tipo in ('gasto','retiro','transferencia') then -1 else 1 end;
  if c1.moneda = 'VES' and v_tasa is null then
    raise exception 'Falta la tasa del día.';
  end if;

  insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo)
  values (v_tipo, c1.id, v_signo * v_monto, case when c1.moneda = 'VES' then v_tasa end,
          round(v_signo * case when c1.moneda = 'VES' then v_monto / v_tasa else v_monto end, 2),
          nullif(trim(p->>'categoria'), ''), nullif(trim(p->>'descripcion'), ''), v_grupo);

  if v_tipo = 'transferencia' then
    select * into c2 from public.jab_cuentas where id = (p->>'cuenta_destino_id')::bigint;
    if not found or c2.id = c1.id then
      raise exception 'Elige la cuenta de destino.';
    end if;
    if c2.moneda = c1.moneda then
      v_monto2 := coalesce(v_monto2, v_monto);
    end if;
    if v_monto2 is null or v_monto2 <= 0 then
      raise exception 'Escribe cuánto llega a la cuenta de destino.';
    end if;
    if c2.moneda = 'VES' and v_tasa is null then
      raise exception 'Falta la tasa del día.';
    end if;
    insert into public.jab_movimientos_dinero (tipo, cuenta_id, monto, tasa, monto_usd, categoria, descripcion, grupo)
    values ('transferencia', c2.id, v_monto2, case when c2.moneda = 'VES' then v_tasa end,
            round(case when c2.moneda = 'VES' then v_monto2 / v_tasa else v_monto2 end, 2),
            nullif(trim(p->>'categoria'), ''), nullif(trim(p->>'descripcion'), ''), v_grupo);
  end if;
  perform public.jab__idem_fin(v_clave, jsonb_build_object('grupo', v_grupo));
  return v_grupo;
end $$;

create function public.jab_anular_movimiento(p_grupo uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_antes jsonb;
begin
  perform public.jab__exigir_duena();
  select jsonb_agg(to_jsonb(m)) into v_antes from public.jab_movimientos_dinero m where grupo = p_grupo and anulado_en is null;
  if v_antes is null then
    raise exception 'Ese movimiento no existe o ya está anulado.';
  end if;
  update public.jab_movimientos_dinero set anulado_en = now(), anulado_por = auth.uid()
   where grupo = p_grupo and anulado_en is null;
  perform public.jab__auditar('movimientos_dinero', p_grupo::text, 'anular', v_antes, null);
end $$;

create function public.jab_saldos_cuentas()
returns table (cuenta_id bigint, nombre text, moneda text, activa boolean, saldo numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.jab__exigir_duena();
  return query
  select c.id, c.nombre, c.moneda, c.activa,
         coalesce((select sum(pg.monto) from public.jab_pagos pg where pg.cuenta_id = c.id and pg.anulado_en is null), 0)
       + coalesce((select sum(md.monto) from public.jab_movimientos_dinero md where md.cuenta_id = c.id and md.anulado_en is null), 0)
    from public.jab_cuentas c
   order by c.orden, c.id;
end $$;

-- Resumen de un día: lo vendido y lo cobrado por método
create function public.jab_resumen_dia(p_fecha date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  perform public.jab__exigir_activo();
  select jsonb_build_object(
    'ventas', (select count(*) from public.jab_ventas
                where (creado_en at time zone 'America/Caracas')::date = p_fecha
                  and estado = 'activa' and tipo <> 'cambio'),
    'vendido', (select coalesce(sum(total), 0) from public.jab_ventas
                where (creado_en at time zone 'America/Caracas')::date = p_fecha
                  and estado = 'activa'),
    'prendas', (select coalesce(sum(vi.cantidad), 0) from public.jab_venta_items vi join public.jab_ventas v on v.id = vi.venta_id
                where (v.creado_en at time zone 'America/Caracas')::date = p_fecha and v.estado = 'activa'),
    'cobrado_usd', (select coalesce(sum(monto_usd), 0) from public.jab_pagos
                where (creado_en at time zone 'America/Caracas')::date = p_fecha and anulado_en is null and cuenta_id is not null),
    'por_metodo', coalesce((select jsonb_agg(x order by x->>'metodo') from (
                  select jsonb_build_object('metodo', mp.nombre, 'moneda', pg.moneda,
                         'monto', sum(pg.monto), 'monto_usd', sum(pg.monto_usd), 'n', count(*)) x
                    from public.jab_pagos pg join public.jab_metodos_pago mp on mp.id = pg.metodo_id
                   where (pg.creado_en at time zone 'America/Caracas')::date = p_fecha and pg.anulado_en is null
                   group by mp.nombre, pg.moneda) s), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- =====================================================================
-- Protecciones extra
-- =====================================================================

-- La moneda de una cuenta no cambia si ya tiene dinero registrado
create function public.jab__proteger_cuenta() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.moneda <> old.moneda and (
       exists (select 1 from public.jab_pagos where cuenta_id = old.id)
    or exists (select 1 from public.jab_movimientos_dinero where cuenta_id = old.id)) then
    raise exception 'No se puede cambiar la moneda de una cuenta que ya tiene movimientos.';
  end if;
  return new;
end $$;
create trigger trg_proteger_cuenta before update on public.jab_cuentas
  for each row execute function public.jab__proteger_cuenta();

-- Solo la dueña puede borrar (ocultar) una clienta
create function public.jab__proteger_cliente() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.deleted_at is distinct from old.deleted_at and not public.jab_es_duena() then
    raise exception 'Solo la dueña puede borrar una clienta.';
  end if;
  return new;
end $$;
create trigger trg_proteger_cliente before update on public.jab_clientes
  for each row execute function public.jab__proteger_cliente();

-- =====================================================================
-- Seguridad (RLS). Todo nace cerrado; solo personal activo lee.
-- Las escrituras de dinero y existencia van por las funciones de arriba.
-- =====================================================================
alter table public.jab_usuarios            enable row level security;
alter table public.jab_config              enable row level security;
alter table public.jab_tasas               enable row level security;
alter table public.jab_cuentas             enable row level security;
alter table public.jab_metodos_pago        enable row level security;
alter table public.jab_clientes            enable row level security;
alter table public.jab_saldo_favor_mov     enable row level security;
alter table public.jab_productos           enable row level security;
alter table public.jab_producto_costos     enable row level security;
alter table public.jab_variantes           enable row level security;
alter table public.jab_movimientos_inventario enable row level security;
alter table public.jab_ventas              enable row level security;
alter table public.jab_venta_items         enable row level security;
alter table public.jab_venta_item_costos   enable row level security;
alter table public.jab_pagos               enable row level security;
alter table public.jab_movimientos_dinero  enable row level security;
alter table public.jab_auditoria           enable row level security;
alter table public.jab_contadores          enable row level security;
alter table public.jab_operaciones         enable row level security;

create policy "leer_personal" on public.jab_usuarios        for select to authenticated using (public.jab_es_activo() or id = auth.uid());
create policy "leer_personal" on public.jab_config          for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_tasas           for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_cuentas         for select to authenticated using (public.jab_es_activo());
create policy "duena_crea"    on public.jab_cuentas         for insert to authenticated with check (public.jab_es_duena());
create policy "duena_edita"   on public.jab_cuentas         for update to authenticated using (public.jab_es_duena()) with check (public.jab_es_duena());
create policy "leer_personal" on public.jab_metodos_pago    for select to authenticated using (public.jab_es_activo());
create policy "duena_crea"    on public.jab_metodos_pago    for insert to authenticated with check (public.jab_es_duena());
create policy "duena_edita"   on public.jab_metodos_pago    for update to authenticated using (public.jab_es_duena()) with check (public.jab_es_duena());
create policy "leer_personal" on public.jab_clientes        for select to authenticated using (public.jab_es_activo());
create policy "personal_crea" on public.jab_clientes        for insert to authenticated with check (public.jab_es_activo());
create policy "personal_edita" on public.jab_clientes       for update to authenticated using (public.jab_es_activo()) with check (public.jab_es_activo());
create policy "leer_personal" on public.jab_saldo_favor_mov for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_productos       for select to authenticated using (public.jab_es_activo());
create policy "solo_duena"    on public.jab_producto_costos for select to authenticated using (public.jab_es_duena());
create policy "leer_personal" on public.jab_variantes       for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_movimientos_inventario for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_ventas          for select to authenticated using (public.jab_es_activo());
create policy "leer_personal" on public.jab_venta_items     for select to authenticated using (public.jab_es_activo());
create policy "solo_duena"    on public.jab_venta_item_costos for select to authenticated using (public.jab_es_duena());
create policy "leer_personal" on public.jab_pagos           for select to authenticated using (public.jab_es_activo());
create policy "solo_duena"    on public.jab_movimientos_dinero for select to authenticated using (public.jab_es_duena());
create policy "solo_duena"    on public.jab_auditoria       for select to authenticated using (public.jab_es_duena());

-- Nadie anónimo toca nada de Jabella, y ninguna función jab_ queda abierta.
-- OJO: esta base es compartida con Yumana. Solo se tocan objetos jab_ (nunca "all ... in schema public").
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
-- Las funciones jab_ nuevas de entregas futuras deben repetir este bloque (Supabase les da permiso a todos por defecto).
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
  public.jab_saldos_cuentas(), public.jab_resumen_dia(date)
to authenticated;

-- =====================================================================
-- Fotos de las prendas (bucket público de solo lectura; sube solo la dueña)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('jab-fotos', 'jab-fotos', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "jabella_fotos_subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'jab-fotos' and public.jab_es_duena());
create policy "jabella_fotos_editar" on storage.objects for update to authenticated
  using (bucket_id = 'jab-fotos' and public.jab_es_duena());

-- =====================================================================
-- Datos iniciales: cuentas y métodos de pago (la dueña los puede editar)
-- =====================================================================
insert into public.jab_cuentas (nombre, moneda, orden) values
  ('Efectivo $', 'USD', 1),
  ('Efectivo Bs', 'VES', 2),
  ('Banco Bs', 'VES', 3),
  ('Zelle', 'USD', 4),
  ('Binance', 'USD', 5);

insert into public.jab_metodos_pago (nombre, cuenta_id, orden) values
  ('Efectivo $',     (select id from public.jab_cuentas where nombre = 'Efectivo $'), 1),
  ('Efectivo Bs',    (select id from public.jab_cuentas where nombre = 'Efectivo Bs'), 2),
  ('Pago móvil',     (select id from public.jab_cuentas where nombre = 'Banco Bs'), 3),
  ('Punto de venta', (select id from public.jab_cuentas where nombre = 'Banco Bs'), 4),
  ('Transferencia',  (select id from public.jab_cuentas where nombre = 'Banco Bs'), 5),
  ('Zelle',          (select id from public.jab_cuentas where nombre = 'Zelle'), 6),
  ('Binance',        (select id from public.jab_cuentas where nombre = 'Binance'), 7);
insert into public.jab_metodos_pago (nombre, es_saldo_favor, orden) values ('Saldo a favor', true, 99);

-- Cambios en vivo entre la laptop y el teléfono
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.jab_variantes, public.jab_productos, public.jab_ventas, public.jab_config;
  end if;
end $$;
