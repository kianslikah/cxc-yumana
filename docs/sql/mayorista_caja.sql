-- =====================================================================================================
-- Referencia. Ya aplicado. No volver a correr sin revisar.
-- =====================================================================================================
-- MODO CAJA DEL MAYORISTA (2026-10-19). Copia de lo que quedó en la base (proyecto tkkiuxaamdyfbildcvtp),
-- sacada con pg_get_functiondef después de aplicar estas migraciones:
--   modo_caja_acceso_y_solo_admin, modo_caja_pedidos, modo_caja_funciones, modo_caja_permiso_portal,
--   modo_caja_v2_origen_y_pedidos_pendientes
-- Respaldo previo: respaldo_20261019 (tablas + funciones_antes_modo_caja + politicas_antes_modo_caja).
-- Sin datos de clientes. Para cambiar algo: CREATE OR REPLACE con la MISMA firma, nunca DROP.
--
-- Quién usa qué:
--   · La cajera de la lista may_acceso_caja (hoy, Lixney) entra al mayorista en "modo caja" (nivel 'consulta'
--     en portal_permisos + may_es_caja()). Solo llama a las funciones may_caja_*; no lee las tablas del mayor.
--   · El administrador lee las tablas (políticas solo_admin) y usa las operaciones may_* de siempre.
--   · El conector de Supabase (sin token) pasa todas las guardias, para cargar clientes desde Claude Code.
-- Espejos en mayorista.html (si cambia una regla, cambiar las dos):
--   · "debe" y "pendiente" de may_caja_cuenta / may_caja_registrar_abono  <->  totalesCliente() y saldoFactura().
--   · Límites y formas de pago de may_caja_*  <->  CAJA_LIMITES y METODOS_PAGO.
-- =====================================================================================================


-- =====================================================================================================
-- TABLAS Y COLUMNAS (resumen)
-- =====================================================================================================

-- Lista de quién puede usar la caja. Mismo patrón que est_acceso: RLS activado y SIN políticas, y sin
-- permisos para PUBLIC, anon ni authenticated. Se maneja solo desde el conector.
--   CREATE TABLE public.may_acceso_caja (
--     usuario_id  uuid PRIMARY KEY REFERENCES public.usuarios_app(id),
--     nota        text,
--     agregado_en timestamptz NOT NULL DEFAULT now()
--   );
--   ALTER TABLE public.may_acceso_caja ENABLE ROW LEVEL SECURITY;
--   REVOKE ALL ON TABLE public.may_acceso_caja FROM PUBLIC, anon, authenticated;
-- Para dar o quitar acceso: INSERT de la fila del usuario (o borrarla, con permiso de Kinan).

-- Pedidos que anota la caja SIN precio. No tocan la deuda hasta que el administrador los factura.
--   CREATE TABLE public.may_pedidos_caja (
--     id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--     cliente_id       uuid NOT NULL REFERENCES public.may_clientes(id),
--     items            jsonb NOT NULL,   -- [{producto_id bigint|null, descripcion, cantidad}] en el orden anotado
--     notas            text,
--     estado           text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','facturado','descartado')),
--     registrado_por   uuid,
--     creado_en        timestamptz NOT NULL DEFAULT now(),
--     atendido_por     uuid,
--     atendido_en      timestamptz,
--     factura_id       uuid REFERENCES public.may_facturas(id),
--     motivo_descarte  text,
--     deleted_at       timestamptz
--   );
--   RLS activado; política permisiva solo_admin FOR ALL TO authenticated USING (es_admin()) WITH CHECK (es_admin());
--   REVOKE ALL ON TABLE public.may_pedidos_caja FROM PUBLIC, anon;
--   Índices: may_pedidos_caja_pendientes_idx (creado_en) WHERE estado = 'pendiente' AND deleted_at IS NULL;
--            may_pedidos_caja_quien_idx (registrado_por, creado_en); may_pedidos_caja_cliente_idx (cliente_id, creado_en).

-- De dónde vino cada abono:
--   ALTER TABLE public.may_abonos ADD COLUMN origen text;   -- NULL = normal; 'caja' = lo registró la caja
--   Índice: may_abonos_registrado_idx (registrado_por, creado_en).

-- Las tablas del mayor quedan solo para el administrador por la API (restrictiva: se suma a solo_personal_activo):
--   CREATE POLICY solo_admin ON public.may_clientes        AS RESTRICTIVE FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
--   CREATE POLICY solo_admin ON public.may_facturas        AS RESTRICTIVE FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
--   CREATE POLICY solo_admin ON public.may_factura_items   AS RESTRICTIVE FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
--   CREATE POLICY solo_admin ON public.may_abonos          AS RESTRICTIVE FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
--   CREATE POLICY solo_admin ON public.may_precios_cliente AS RESTRICTIVE FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());

-- Portal: para el mayorista, nivel 'consulta' = modo caja.
--   INSERT INTO public.portal_permisos (rol, app_id, nivel) VALUES ('cajera', 'mayoristas', 'consulta')
--   ON CONFLICT (rol, app_id) DO UPDATE SET nivel = EXCLUDED.nivel;

-- Permisos de las funciones:
--   may_es_caja, may_caja_clientes, may_caja_cuenta, may_caja_registrar_abono, may_caja_anotar_pedido,
--   may_caja_mis_registros, may_facturar_pedido, may_descartar_pedido:
--     REVOKE EXECUTE ... FROM PUBLIC, anon;  GRANT EXECUTE ... TO authenticated;
--   Guardias internas may_exigir_personal, may_exigir_admin, may_caja_exigir: sin EXECUTE para PUBLIC, anon ni
--   authenticated (las llaman las funciones SECURITY DEFINER, que corren como su dueño).


-- =====================================================================================================
-- FUNCIONES (definición final)
-- =====================================================================================================

CREATE OR REPLACE FUNCTION public.may_es_caja()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(public.es_staff(), false)
     AND EXISTS (SELECT 1 FROM public.may_acceso_caja WHERE usuario_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.may_exigir_personal()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Desde la app (pasa por la API con un token) solo opera el administrador.
  -- Única excepción: las funciones de la caja (may_caja_*) marcan la transacción con
  -- set_config('yumana.caja', '1', true) justo antes de llamar a may_registrar_abono, y aquí se exige
  -- ADEMÁS que quien llama esté en la lista de la caja (may_es_caja()). La marca sola no abre nada.
  --
  -- Por qué la marca no se puede falsificar desde el navegador:
  --   * La API de Supabase (PostgREST) solo expone el esquema public. Verificado el 2026-10-19: el rol
  --     authenticator no trae pgrst.db_schemas propio (usa el del proyecto) y la caché de la API carga
  --     76 relaciones y 112 funciones, que son exactamente las de public (sin las de trigger).
  --   * set_config vive en pg_catalog, que no está expuesto; y ninguna función de public llama a
  --     set_config con un nombre que venga de afuera ni ejecuta SQL dinámico.
  --   * Cada pedido HTTP es su propia transacción y la marca es local (tercer argumento true): muere al
  --     terminar ese pedido. Además, la función de caja la borra apenas registra el pago.
  --
  -- El conector de Supabase entra directo a la base, sin token: queda afuera para poder cargar clientes.
  IF (session_user = 'authenticator' OR coalesce(current_setting('request.jwt.claims', true), '') <> '') THEN
    IF coalesce(public.es_admin(), false) THEN
      RETURN;
    END IF;
    IF coalesce(current_setting('yumana.caja', true), '') = '1' AND coalesce(public.may_es_caja(), false) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Solo el administrador puede operar el mayor' USING ERRCODE = '42501';
  END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.may_exigir_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (session_user = 'authenticator' OR coalesce(current_setting('request.jwt.claims', true), '') <> '')
     AND NOT coalesce(public.es_admin(), false) THEN
    RAISE EXCEPTION 'Solo el administrador puede operar el mayor' USING ERRCODE = '42501';
  END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.may_caja_exigir()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (session_user = 'authenticator' OR coalesce(current_setting('request.jwt.claims', true), '') <> '')
     AND NOT (coalesce(public.may_es_caja(), false) OR coalesce(public.es_admin(), false)) THEN
    RAISE EXCEPTION 'No tienes acceso a la caja del mayor' USING ERRCODE = '42501';
  END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.may_caja_clientes()
 RETURNS TABLE(id uuid, nombre text, telefono text, whatsapp_grupo text, no_vender boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.may_caja_exigir();
  RETURN QUERY
    SELECT c.id, c.nombre, c.telefono, c.whatsapp_grupo, c.no_vender
    FROM may_clientes c
    WHERE c.deleted_at IS NULL
    ORDER BY c.nombre, c.id;
END $function$
;

CREATE OR REPLACE FUNCTION public.may_caja_cuenta(p_cliente_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_c record; v_comprado numeric; v_pagado numeric; v_nab int; v_fac jsonb; v_abo jsonb; v_ped jsonb;
BEGIN
  PERFORM public.may_caja_exigir();
  SELECT c.id, c.nombre, c.rif_cedula, c.telefono, c.whatsapp_grupo, c.no_vender INTO v_c
  FROM may_clientes c WHERE c.id = p_cliente_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe o ya no está activo'; END IF;

  -- "debe" igual que totalesCliente() de mayorista.html: lo comprado (facturas vivas) menos lo abonado
  -- (abonos vivos, incluidos los "Descuento/devolución"). Negativo = saldo a favor.
  SELECT coalesce(sum(f.monto_total), 0) INTO v_comprado
  FROM may_facturas f WHERE f.cliente_id = p_cliente_id AND f.deleted_at IS NULL;
  SELECT coalesce(sum(a.monto), 0), count(*) INTO v_pagado, v_nab
  FROM may_abonos a WHERE a.cliente_id = p_cliente_id AND a.deleted_at IS NULL;

  -- Pendientes igual que saldoFactura(): monto_total − monto_pagado > 0,01; de la más vieja a la más nueva
  -- (mismo orden con que may_recalcular_cliente reparte los abonos).
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'numero', f.numero, 'fecha', f.fecha, 'vence', f.fecha_vencimiento,
           'monto_total', round(f.monto_total, 2), 'pendiente', round(f.monto_total - f.monto_pagado, 2))
         ORDER BY f.fecha, f.numero), '[]'::jsonb) INTO v_fac
  FROM may_facturas f
  WHERE f.cliente_id = p_cliente_id AND f.deleted_at IS NULL AND f.monto_total - f.monto_pagado > 0.01;

  -- Los 10 abonos más recientes, en el mismo orden que el historial de la app (fecha, y luego id)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'fecha', x.fecha, 'metodo', x.metodo, 'monto', round(x.monto, 2),
           'es_dinero', x.metodo IS DISTINCT FROM 'Descuento/devolución')
         ORDER BY x.fecha DESC, x.id), '[]'::jsonb) INTO v_abo
  FROM (SELECT a.id, a.fecha, a.metodo, a.monto FROM may_abonos a
        WHERE a.cliente_id = p_cliente_id AND a.deleted_at IS NULL
        ORDER BY a.fecha DESC, a.id LIMIT 10) x;

  -- Pedidos de la caja que faltan facturar (para no anotar dos veces lo mismo). Sin precios.
  SELECT coalesce(jsonb_agg(jsonb_build_object('creado_en', p.creado_en, 'items', p.items, 'notas', p.notas)
         ORDER BY p.creado_en), '[]'::jsonb) INTO v_ped
  FROM may_pedidos_caja p
  WHERE p.cliente_id = p_cliente_id AND p.estado = 'pendiente' AND p.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'cliente', jsonb_build_object('id', v_c.id, 'nombre', v_c.nombre, 'rif_cedula', v_c.rif_cedula,
                                  'telefono', v_c.telefono, 'whatsapp_grupo', v_c.whatsapp_grupo,
                                  'no_vender', v_c.no_vender),
    'debe', round(v_comprado - v_pagado, 2),
    'facturas', v_fac,
    'abonos', v_abo,
    'abonos_total', v_nab,
    'pedidos_pendientes', v_ped,
    'al', (now() AT TIME ZONE 'America/Caracas')::date);
END $function$
;
COMMENT ON FUNCTION public.may_caja_cuenta(uuid) IS
  'Cuenta de UN cliente para el modo caja. "debe" y "pendiente" son espejo de totalesCliente() y saldoFactura() de mayorista.html: si cambia una regla, cambiar las dos.';

CREATE OR REPLACE FUNCTION public.may_caja_registrar_abono(p_cliente_id uuid, p_monto numeric, p_metodo text, p_fecha date, p_notas text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Caracas')::date;
  v_uid uuid := auth.uid();
  v_monto numeric; v_notas text; v_r jsonb; v_id uuid; v_comprado numeric; v_pagado numeric;
BEGIN
  PERFORM public.may_caja_exigir();
  -- Se bloquea la fila del cliente: dos pagos al mismo cliente a la vez se ponen en fila,
  -- así el anti-repetido de abajo ve el primero.
  PERFORM 1 FROM may_clientes WHERE id = p_cliente_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe o ya no está activo'; END IF;

  -- Límites: espejo de CAJA_LIMITES y METODOS_PAGO en mayorista.html
  v_monto := round(p_monto, 2);
  IF v_monto IS NULL OR v_monto <= 0 OR v_monto > 100000 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor que 0 y hasta 100.000';
  END IF;
  -- Los botones de método de la app, sin "Descuento/devolución" (ese no es dinero y solo lo pone el administrador)
  IF p_metodo IS NULL OR p_metodo NOT IN ('Efectivo USD', 'Zelle', 'USDT', 'Bolívares', 'Pago Móvil') THEN
    RAISE EXCEPTION 'Método de pago no permitido en la caja';
  END IF;
  IF p_fecha IS NULL OR p_fecha > v_hoy OR p_fecha < v_hoy - 7 THEN
    RAISE EXCEPTION 'La fecha del pago tiene que estar entre el % y hoy (%)', to_char(v_hoy - 7, 'DD/MM/YYYY'), to_char(v_hoy, 'DD/MM/YYYY');
  END IF;
  v_notas := nullif(btrim(coalesce(p_notas, '')), '');
  IF length(v_notas) > 500 THEN RAISE EXCEPTION 'La nota es muy larga (máximo 500 letras)'; END IF;

  -- Anti-repetido: mismo cliente, monto, forma de pago y persona en los últimos 3 minutos
  IF EXISTS (SELECT 1 FROM may_abonos a
             WHERE a.cliente_id = p_cliente_id AND a.deleted_at IS NULL
               AND round(a.monto, 2) = v_monto
               AND a.metodo IS NOT DISTINCT FROM p_metodo
               AND a.registrado_por IS NOT DISTINCT FROM v_uid
               AND a.creado_en > now() - interval '3 minutes') THEN
    RAISE EXCEPTION 'Este pago parece repetido (mismo cliente, monto y forma de pago en los últimos 3 minutos). Si de verdad es otro pago, espera 3 minutos.';
  END IF;

  -- Marca de caja: may_exigir_personal (dentro de may_registrar_abono y may_recalcular_cliente) deja pasar
  -- a quien está en may_acceso_caja solo mientras dura esta marca. Se borra apenas termina.
  PERFORM set_config('yumana.caja', '1', true);
  v_r := public.may_registrar_abono(p_cliente_id, v_monto, p_fecha, p_metodo, v_notas, v_uid);
  PERFORM set_config('yumana.caja', '', true);
  v_id := (v_r->>'abono_id')::uuid;
  UPDATE may_abonos SET origen = 'caja' WHERE id = v_id;

  -- "debe" igual que totalesCliente() de mayorista.html (comprado − abonado; negativo = a favor)
  SELECT coalesce(sum(monto_total), 0) INTO v_comprado FROM may_facturas WHERE cliente_id = p_cliente_id AND deleted_at IS NULL;
  SELECT coalesce(sum(monto), 0) INTO v_pagado FROM may_abonos WHERE cliente_id = p_cliente_id AND deleted_at IS NULL;
  -- Solo lo de ESTE cliente (no se devuelve el resultado completo de may_recalcular_cliente)
  RETURN jsonb_build_object('abono_id', v_id, 'debe_cliente', round(v_comprado - v_pagado, 2));
END $function$
;
COMMENT ON FUNCTION public.may_caja_registrar_abono(uuid, numeric, text, date, text) IS
  'Pago desde el modo caja. Límites y métodos: espejo de CAJA_LIMITES y METODOS_PAGO de mayorista.html. "debe_cliente" es espejo de totalesCliente().';

CREATE OR REPLACE FUNCTION public.may_caja_anotar_pedido(p_cliente_id uuid, p_items jsonb, p_notas text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_no_vender boolean; v_n int; it record; v_desc text; v_cant numeric; v_pid bigint; v_txt text;
  v_items jsonb := '[]'::jsonb; v_notas text; v_id uuid;
BEGIN
  PERFORM public.may_caja_exigir();
  SELECT c.no_vender INTO v_no_vender FROM may_clientes c WHERE c.id = p_cliente_id AND c.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe o ya no está activo'; END IF;
  IF v_no_vender THEN RAISE EXCEPTION 'Este cliente tiene la marca No venderle: consulta con Kinan'; END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'El pedido no tiene renglones'; END IF;
  v_n := jsonb_array_length(p_items);
  IF v_n < 1 OR v_n > 60 THEN RAISE EXCEPTION 'El pedido tiene que tener entre 1 y 60 renglones'; END IF;

  FOR it IN SELECT x.e, x.n FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n) ORDER BY x.n LOOP
    IF jsonb_typeof(it.e) <> 'object' THEN RAISE EXCEPTION 'El renglón % no es válido', it.n; END IF;
    v_desc := nullif(btrim(coalesce(it.e->>'descripcion', '')), '');
    IF v_desc IS NULL THEN RAISE EXCEPTION 'El renglón % no tiene descripción', it.n; END IF;
    IF length(v_desc) > 300 THEN RAISE EXCEPTION 'La descripción del renglón % es muy larga', it.n; END IF;
    v_txt := btrim(coalesce(it.e->>'cantidad', ''));
    IF v_txt !~ '^[0-9]+(\.[0-9]+)?$' THEN RAISE EXCEPTION 'La cantidad del renglón % tiene que ser mayor que 0', it.n; END IF;
    v_cant := v_txt::numeric;
    IF v_cant <= 0 OR v_cant > 10000 THEN RAISE EXCEPTION 'La cantidad del renglón % tiene que ser mayor que 0', it.n; END IF;
    v_txt := btrim(coalesce(it.e->>'producto_id', ''));
    IF v_txt = '' THEN
      v_pid := NULL;
    ELSIF v_txt ~ '^[0-9]{1,18}$' THEN
      v_pid := v_txt::bigint;
      IF NOT EXISTS (SELECT 1 FROM inv_productos WHERE id = v_pid) THEN
        RAISE EXCEPTION 'El producto del renglón % no existe en el catálogo', it.n;
      END IF;
    ELSE
      RAISE EXCEPTION 'El producto del renglón % no es válido', it.n;
    END IF;
    v_items := v_items || jsonb_build_array(jsonb_build_object('producto_id', v_pid, 'descripcion', v_desc, 'cantidad', v_cant));
  END LOOP;

  v_notas := nullif(btrim(coalesce(p_notas, '')), '');
  IF length(v_notas) > 1000 THEN RAISE EXCEPTION 'La nota es muy larga (máximo 1000 letras)'; END IF;

  -- Anti-repetido: mismo cliente y mismos renglones en los últimos 3 minutos
  IF EXISTS (SELECT 1 FROM may_pedidos_caja p
             WHERE p.cliente_id = p_cliente_id AND p.deleted_at IS NULL
               AND p.items = v_items AND p.creado_en > now() - interval '3 minutes') THEN
    RAISE EXCEPTION 'Este pedido parece repetido: revisa antes de anotarlo de nuevo';
  END IF;

  INSERT INTO may_pedidos_caja (cliente_id, items, notas, registrado_por)
  VALUES (p_cliente_id, v_items, v_notas, auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('pedido_id', v_id);
END $function$
;

CREATE OR REPLACE FUNCTION public.may_caja_mis_registros()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_pagos jsonb; v_pedidos jsonb;
BEGIN
  PERFORM public.may_caja_exigir();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'abono_id', a.id, 'fecha', a.fecha, 'cliente_id', a.cliente_id, 'cliente', c.nombre,
           'metodo', a.metodo, 'monto', round(a.monto, 2), 'notas', a.notas, 'creado_en', a.creado_en,
           'anulado', a.deleted_at IS NOT NULL)
         ORDER BY a.creado_en DESC), '[]'::jsonb) INTO v_pagos
  FROM may_abonos a JOIN may_clientes c ON c.id = a.cliente_id
  WHERE v_uid IS NOT NULL AND a.registrado_por = v_uid AND a.creado_en >= now() - interval '7 days';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'pedido_id', p.id, 'creado_en', p.creado_en, 'cliente_id', p.cliente_id, 'cliente', c.nombre,
           'items', p.items, 'notas', p.notas, 'estado', p.estado, 'motivo_descarte', p.motivo_descarte)
         ORDER BY p.creado_en DESC), '[]'::jsonb) INTO v_pedidos
  FROM may_pedidos_caja p JOIN may_clientes c ON c.id = p.cliente_id
  WHERE v_uid IS NOT NULL AND p.registrado_por = v_uid AND p.deleted_at IS NULL
    AND p.creado_en >= now() - interval '7 days';

  RETURN jsonb_build_object('pagos', v_pagos, 'pedidos', v_pedidos);
END $function$
;

CREATE OR REPLACE FUNCTION public.may_facturar_pedido(p_pedido_id uuid, p_factura jsonb, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_p record; v_cli uuid; v_f jsonb; v_r jsonb;
BEGIN
  PERFORM public.may_exigir_admin();
  SELECT id, cliente_id, estado INTO v_p FROM may_pedidos_caja WHERE id = p_pedido_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El pedido no existe'; END IF;
  IF v_p.estado <> 'pendiente' THEN RAISE EXCEPTION 'Este pedido ya fue %', v_p.estado; END IF;
  v_cli := nullif(p_factura->>'cliente_id', '')::uuid;
  IF v_cli IS DISTINCT FROM v_p.cliente_id THEN
    RAISE EXCEPTION 'La factura tiene que ser para el mismo cliente del pedido';
  END IF;
  -- Siempre factura NUEVA (sin id), con origen 'caja' y creada por quien factura. Las notas son las que vengan.
  v_f := (coalesce(p_factura, '{}'::jsonb) - 'id' - 'origen' - 'creado_por')
         || jsonb_build_object('origen', 'caja', 'creado_por', auth.uid());
  v_r := public.may_guardar_factura(v_f, p_items);
  UPDATE may_pedidos_caja
     SET estado = 'facturado', factura_id = (v_r->>'factura_id')::uuid,
         atendido_por = auth.uid(), atendido_en = now()
   WHERE id = p_pedido_id;
  RETURN v_r || jsonb_build_object('pedido_id', p_pedido_id);
END $function$
;

CREATE OR REPLACE FUNCTION public.may_descartar_pedido(p_pedido_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_estado text; v_m text := nullif(btrim(coalesce(p_motivo, '')), '');
BEGIN
  PERFORM public.may_exigir_admin();
  IF v_m IS NULL THEN RAISE EXCEPTION 'Escribe el motivo para descartar el pedido'; END IF;
  IF length(v_m) > 500 THEN RAISE EXCEPTION 'El motivo es muy largo (máximo 500 letras)'; END IF;
  SELECT estado INTO v_estado FROM may_pedidos_caja WHERE id = p_pedido_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El pedido no existe'; END IF;
  IF v_estado <> 'pendiente' THEN RAISE EXCEPTION 'Este pedido ya fue %', v_estado; END IF;
  UPDATE may_pedidos_caja
     SET estado = 'descartado', motivo_descarte = v_m, atendido_por = auth.uid(), atendido_en = now()
   WHERE id = p_pedido_id;
  RETURN jsonb_build_object('ok', true, 'pedido_id', p_pedido_id);
END $function$
;
