-- =====================================================================================
-- Referencia. Ya aplicado en la base (migraciones est_*). No volver a correr sin revisar:
-- est_puede_ver depende de est_acceso (solo Kinan).
-- =====================================================================================
-- Estadísticas (estadisticas.html). Definición FINAL de todas las funciones est_* y de la tabla est_acceso,
-- sacada de la base con pg_get_functiondef el 2026-10-10.
-- Migraciones: est_* (primera versión), est_acceso_solo_kinan, est_v2_base, est_v2_resumen, est_v2_detal,
-- est_v2_mayorista, est_v2_proveedores_inventario.
--
-- Cómo está armado:
--  * Funciones públicas (las llama la app): SECURITY DEFINER, empiezan con PERFORM public.est_exigir_acceso();
--    ejecutables solo por authenticated (nunca por anon).
--  * Funciones de origen (auxiliares): cada regla de dinero vive en UNA sola (est_cuentas_detal, est_detal_abonos,
--    est_detal_intereses, est_may_facturas, est_may_abonos, est_prov_facturas, est_prov_abonos, est_cobranza_clientes,
--    est_puntaje_clientes). El Resumen y las secciones las usan todas, así que cuadran por construcción.
--    Sin SECURITY DEFINER y sin ejecución para anon ni authenticated.
--  * est_norm_ciudad quedó sin uso (se quitó la ciudad de la app); se deja porque no se borra nada.

-- -------------------------------------------------------------------------------------
-- Tabla de acceso (migración est_acceso_solo_kinan). Tiene una sola fila: el usuario de Kinan.
-- Sin políticas: cerrada a la API a propósito; solo la lee est_puede_ver() (SECURITY DEFINER).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.est_acceso (
  usuario_id uuid PRIMARY KEY REFERENCES public.usuarios_app(id),
  nota text,
  agregado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.est_acceso ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.est_acceso FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- Funciones auxiliares (de origen)
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.est_hoy()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT (now() AT TIME ZONE 'America/Caracas')::date;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_hoy() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_exigir_acceso()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Todo lo que llega por la API de Supabase (la app en el navegador) entra con session_user = 'authenticator'
  -- y trae request.jwt.claims: ahí siempre se exige est_puede_ver() (solo quien está en est_acceso).
  -- El conector de Supabase con el que Claude Code revisa la base (autorizado por Kinan, regla 11 de CLAUDE.md)
  -- entra directo como dueño de la base y sin JWT: a ese se le deja pasar para poder verificar los números.
  -- coalesce: si est_puede_ver() devolviera NULL, se bloquea (nunca se deja pasar por un NULL).
  IF (session_user = 'authenticator' OR coalesce(current_setting('request.jwt.claims', true), '') <> '')
     AND NOT coalesce(public.est_puede_ver(), false) THEN
    RAISE EXCEPTION 'Solo el administrador puede ver las estadísticas' USING ERRCODE = '42501';
  END IF;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_exigir_acceso() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_rango(p_desde date, p_hasta date, p_ant_desde date, p_ant_hasta date)
 RETURNS TABLE(desde date, hasta date, ant_desde date, ant_hasta date, hoy date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_hoy date := public.est_hoy();
  v_desde date := coalesce(p_desde, date '2026-01-01');
  v_hasta date := coalesce(p_hasta, v_hoy);
  v_ah date;
  v_ad date;
BEGIN
  IF v_desde > v_hasta THEN
    RAISE EXCEPTION 'La fecha inicial no puede ser mayor que la final';
  END IF;
  v_ah := coalesce(p_ant_hasta, v_desde - 1);
  v_ad := coalesce(p_ant_desde, v_ah - (v_hasta - v_desde));
  IF v_ad > v_ah THEN
    RAISE EXCEPTION 'El período de comparación no es válido';
  END IF;
  RETURN QUERY SELECT v_desde, v_hasta, v_ad, v_ah, v_hoy;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_rango(date,date,date,date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_norm_metodo(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE translate(lower(btrim(coalesce(p, ''))), 'áéíóúü', 'aeiouu')
    WHEN '' THEN 'Sin método'
    WHEN 'zelle' THEN 'Zelle'
    WHEN 'usdt' THEN 'USDT'
    WHEN 'efectivo usd' THEN 'Efectivo USD'
    WHEN 'efectivo' THEN 'Efectivo'
    WHEN 'bolivares' THEN 'Bolívares'
    WHEN 'pago movil' THEN 'Pago Móvil'
    WHEN 'pago bs' THEN 'Pago Bs'
    WHEN 'transferencia' THEN 'Transferencia'
    WHEN 'saldo a favor' THEN 'Saldo a favor'
    WHEN 'descuento/devolucion' THEN 'Descuento/devolución'
    -- Proveedores_yumana.html guarda la devolución aceptada como abono con método 'Devolución'
    WHEN 'devolucion' THEN 'Devolución'
    ELSE btrim(p)
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_norm_metodo(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_norm_texto(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT nullif(upper(translate(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'), 'áéíóúüÁÉÍÓÚÜ', 'aeiouuAEIOUU')), '');
$function$;

REVOKE EXECUTE ON FUNCTION public.est_norm_texto(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_norm_ciudad(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN public.est_norm_texto(p) IS NULL THEN 'Sin ciudad'
    WHEN public.est_norm_texto(p) LIKE 'SOCOP%' THEN 'Socopó'
    WHEN public.est_norm_texto(p) LIKE 'MIRI%' THEN 'Mirí'
    ELSE initcap(lower(public.est_norm_texto(p)))
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_norm_ciudad(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_categoria(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = '' THEN 'Sin categoría'
    WHEN position(' - ' IN p) > 0 THEN btrim(substr(p, position(' - ' IN p) + 3))
    ELSE btrim(p)
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_categoria(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_tramo_dias()
 RETURNS TABLE(indice integer, etiqueta text, hasta integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  VALUES (0, 'Hasta 30 días'::text, 30),
         (1, '31 a 60 días'::text, 60),
         (2, '61 a 90 días'::text, 90),
         (3, 'Más de 90 días'::text, NULL::int);
$function$;

REVOKE EXECUTE ON FUNCTION public.est_tramo_dias() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_tramo_dias(p_dias integer)
 RETURNS TABLE(indice integer, etiqueta text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT t.indice, t.etiqueta
  FROM public.est_tramo_dias() t
  WHERE p_dias IS NOT NULL AND (t.hasta IS NULL OR p_dias <= t.hasta)
  ORDER BY t.indice
  LIMIT 1;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_tramo_dias(int) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_cuentas_detal()
 RETURNS TABLE(tipo text, id uuid, numero integer, cliente_id uuid, fecha_inicio date, fecha_limite date, estado text, fecha_completado date, plazo_dias integer, vendedor_id uuid, total numeric, intereses numeric, subtotal numeric, pagado numeric, saldo numeric, vendible boolean, viva boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH ia AS (
    SELECT credito_id, apartado_id, sum(monto_interes) AS s
    FROM intereses_aplicados
    GROUP BY credito_id, apartado_id
  ),
  cu AS (
    SELECT 'credito'::text AS tipo, c.id, c.numero, c.cliente_id,
           coalesce(c.fecha_inicio, (c.created_at AT TIME ZONE 'UTC')::date) AS fecha_inicio,
           c.fecha_limite, c.estado, c.fecha_completado, c.plazo_dias, c.vendedor_id,
           c.monto_total, coalesce(c.monto_pagado, 0) AS pagado, coalesce(ia.s, 0) AS intereses
    FROM creditos c
    LEFT JOIN ia ON ia.credito_id = c.id AND ia.apartado_id IS NULL
    WHERE c.deleted_at IS NULL
    UNION ALL
    SELECT 'apartado', a.id, a.numero, a.cliente_id,
           coalesce(a.fecha_inicio, (a.created_at AT TIME ZONE 'UTC')::date),
           a.fecha_limite, a.estado, a.fecha_completado,
           a.fecha_limite - coalesce(a.fecha_inicio, (a.created_at AT TIME ZONE 'UTC')::date), NULL::uuid,
           a.monto_total, coalesce(a.monto_abonado, 0), coalesce(ia.s, 0)
    FROM apartados a
    LEFT JOIN ia ON ia.apartado_id = a.id AND ia.credito_id IS NULL
    WHERE a.deleted_at IS NULL
  )
  SELECT tipo, id, numero, cliente_id, fecha_inicio, fecha_limite, estado,
         CASE WHEN estado = 'completado' THEN fecha_completado END,
         plazo_dias, vendedor_id,
         round(monto_total, 2),
         round(intereses, 2),
         round(monto_total - intereses, 2),
         round(pagado, 2),
         round(monto_total - pagado, 2),
         estado NOT IN ('anulado', 'rechazado', 'pendiente_aprobacion', 'cancelado'),
         estado IN ('activo', 'vencido') AND round(monto_total - pagado, 2) > 0.01
  FROM cu;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_cuentas_detal() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_detal_abonos()
 RETURNS TABLE(id uuid, fecha date, monto numeric, metodo text, tipo text, cuenta_id uuid, registrado_por uuid, grupo_pago uuid, cuenta_destino text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT a.id, a.fecha, round(a.monto, 2), public.est_norm_metodo(a.metodo),
         CASE WHEN a.credito_id IS NOT NULL THEN 'credito' ELSE 'apartado' END,
         coalesce(a.credito_id, a.apartado_id), a.registrado_por, a.grupo_pago, a.cuenta_destino
  FROM abonos a
  WHERE a.deleted_at IS NULL AND a.fecha IS NOT NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_detal_abonos() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_detal_intereses()
 RETURNS TABLE(cuenta_id uuid, tipo text, fecha date, monto numeric, perdonado boolean, era numeric, vendible boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT cu.id, cu.tipo, i.fecha, round(i.monto_interes, 2), p.perdonado,
         CASE WHEN p.perdonado
              THEN coalesce(replace((regexp_match(i.notas, 'era \$?([0-9][0-9,]*(?:\.[0-9]+)?)'))[1], ',', '')::numeric, 0)
              ELSE 0 END,
         cu.vendible
  FROM intereses_aplicados i
  JOIN public.est_cuentas_detal() cu ON cu.id = coalesce(i.credito_id, i.apartado_id)
  CROSS JOIN LATERAL (SELECT (i.monto_interes = 0 AND coalesce(i.notas, '') ~* 'PERDONADO') AS perdonado) p;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_detal_intereses() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_may_facturas()
 RETURNS TABLE(id uuid, numero integer, cliente_id uuid, fecha date, fecha_vencimiento date, origen text, total numeric, saldo numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT f.id, f.numero, f.cliente_id, f.fecha, f.fecha_vencimiento, coalesce(f.origen, 'sin_origen'),
         round(f.monto_total, 2), round(f.monto_total - f.monto_pagado, 2)
  FROM may_facturas f
  JOIN may_clientes c ON c.id = f.cliente_id AND c.deleted_at IS NULL
  WHERE f.deleted_at IS NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_may_facturas() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_may_abonos()
 RETURNS TABLE(id uuid, cliente_id uuid, fecha date, monto numeric, metodo text, es_descuento boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT a.id, a.cliente_id, a.fecha, round(a.monto, 2), m.metodo, m.metodo = 'Descuento/devolución'
  FROM may_abonos a
  JOIN may_clientes c ON c.id = a.cliente_id AND c.deleted_at IS NULL
  CROSS JOIN LATERAL (SELECT public.est_norm_metodo(a.metodo) AS metodo) m
  WHERE a.deleted_at IS NULL AND a.fecha IS NOT NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_may_abonos() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_prov_facturas()
 RETURNS TABLE(id text, proveedor_id text, num text, llegada date, vence date, monto numeric, abonado numeric, saldo numeric, disputada boolean, motivo_disputa text, esperando_doc boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT f.id, f.proveedor_id, f.num, f.llegada, f.vence,
         round(coalesce(f.monto, 0), 2), round(coalesce(f.abonado, 0), 2),
         round(coalesce(f.monto, 0) - coalesce(f.abonado, 0), 2),
         coalesce(f.disputada, false), f.motivo_disputa, coalesce(f.esperando_doc, false)
  FROM prov_facturas f;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_prov_facturas() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_prov_abonos()
 RETURNS TABLE(id text, factura_id text, proveedor_id text, fecha date, monto numeric, metodo text, ganancia numeric, en_transito boolean, saldo_favor boolean, devolucion boolean, sale boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT a.id, a.factura_id, f.proveedor_id, a.fecha, round(coalesce(a.monto, 0), 2), m.metodo, coalesce(a.ganancia, 0),
         coalesce(a.en_transito, false),
         m.metodo = 'Saldo a favor',
         m.metodo = 'Devolución',
         NOT coalesce(a.en_transito, false) AND m.metodo NOT IN ('Saldo a favor', 'Devolución')
  FROM prov_abonos a
  JOIN prov_facturas f ON f.id = a.factura_id
  CROSS JOIN LATERAL (SELECT public.est_norm_metodo(a.metodo) AS metodo) m
  WHERE a.fecha IS NOT NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_prov_abonos() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_cobranza_clientes()
 RETURNS TABLE(cliente_id uuid, deuda numeric, vencido numeric, deuda_cr numeric, deuda_ap numeric, cuentas bigint, cuentas_vencidas bigint, inicio_viejo date, ultimo_pago date, dias_sin_pagar integer, dias_viejo integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH hoy AS (SELECT public.est_hoy() AS d),
  viva AS (SELECT * FROM public.est_cuentas_detal() WHERE viva),
  ult AS (SELECT cuenta_id, max(fecha) AS ultimo FROM public.est_detal_abonos() GROUP BY cuenta_id),
  g AS (
    SELECT v.cliente_id,
           round(sum(v.saldo), 2) AS deuda,
           round(coalesce(sum(v.saldo) FILTER (WHERE v.fecha_limite < h.d), 0), 2) AS vencido,
           round(coalesce(sum(v.saldo) FILTER (WHERE v.tipo = 'credito'), 0), 2) AS deuda_cr,
           round(coalesce(sum(v.saldo) FILTER (WHERE v.tipo = 'apartado'), 0), 2) AS deuda_ap,
           count(*) AS cuentas,
           count(*) FILTER (WHERE v.fecha_limite < h.d) AS cuentas_vencidas,
           min(v.fecha_inicio) AS inicio_viejo,
           max(u.ultimo) AS ultimo_pago,
           h.d AS hoy
    FROM viva v
    CROSS JOIN hoy h
    LEFT JOIN ult u ON u.cuenta_id = v.id
    GROUP BY v.cliente_id, h.d
  )
  SELECT cliente_id, deuda, vencido, deuda_cr, deuda_ap, cuentas, cuentas_vencidas, inicio_viejo, ultimo_pago,
         hoy - coalesce(ultimo_pago, inicio_viejo), hoy - inicio_viejo
  FROM g;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_cobranza_clientes() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_reglas_puntaje()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'gracia_dias', 5,                                   -- días después de la fecha límite que todavía cuentan como a tiempo
    'puntos_por_dia', 2,                                -- puntos que pierde la cuenta por cada día de atraso pasada la gracia
    'ritmo_puntos', jsonb_build_array(100, 50, 20, 0),  -- ritmo según el tramo de días sin pagar (est_tramo_dias: 30/60/90)
    'peso_puntualidad', 0.7,
    'peso_ritmo', 0.3,
    'corte_a', 85,                                      -- A: 85 o más
    'corte_b', 70,                                      -- B: 70 a 84
    'corte_c', 50,                                      -- C: 50 a 69; D: menos de 50
    'min_cuentas_puntuales', 2                          -- cuentas evaluadas mínimas para el top de más puntuales
  );
$function$;

REVOKE EXECUTE ON FUNCTION public.est_reglas_puntaje() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_puntaje_clientes()
 RETURNS TABLE(cliente_id uuid, evaluadas bigint, a_tiempo bigint, atraso_prom numeric, puntualidad numeric, ritmo integer, puntaje numeric, letra text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH reglas AS (
    SELECT (j->>'gracia_dias')::int AS gracia_dias,
           (j->>'puntos_por_dia')::numeric AS puntos_por_dia,
           ARRAY(SELECT x::int FROM jsonb_array_elements_text(j->'ritmo_puntos') AS x) AS ritmo_puntos,
           (j->>'peso_puntualidad')::numeric AS peso_puntualidad,
           (j->>'peso_ritmo')::numeric AS peso_ritmo,
           (j->>'corte_a')::numeric AS corte_a,
           (j->>'corte_b')::numeric AS corte_b,
           (j->>'corte_c')::numeric AS corte_c
    FROM (SELECT public.est_reglas_puntaje() AS j) r
  ),
  hoy AS (SELECT public.est_hoy() AS d),
  ev AS (
    SELECT c.cliente_id, c.evaluada, c.a_tiempo, c.dias_atraso,
           greatest(0, least(100, 100 - rg.puntos_por_dia * (c.dias_atraso - rg.gracia_dias))) AS pts
    FROM (
      SELECT cu.cliente_id,
             (cu.fecha_completado IS NOT NULL OR (cu.viva AND cu.fecha_limite < h.d)) AS evaluada,
             (cu.fecha_completado IS NOT NULL AND cu.fecha_completado <= cu.fecha_limite) AS a_tiempo,
             CASE WHEN cu.fecha_completado IS NOT NULL THEN greatest(cu.fecha_completado - cu.fecha_limite, 0)
                  WHEN cu.viva AND cu.fecha_limite < h.d THEN h.d - cu.fecha_limite
                  ELSE 0 END AS dias_atraso
      FROM public.est_cuentas_detal() cu
      CROSS JOIN hoy h
      WHERE cu.vendible
    ) c
    CROSS JOIN reglas rg
  ),
  sc AS (
    SELECT cliente_id,
           count(*) FILTER (WHERE evaluada) AS evaluadas,
           count(*) FILTER (WHERE evaluada AND a_tiempo) AS a_tiempo,
           round(avg(dias_atraso) FILTER (WHERE evaluada), 1) AS atraso_prom,
           round(avg(pts) FILTER (WHERE evaluada), 1) AS puntualidad
    FROM ev
    GROUP BY cliente_id
  ),
  pu AS (
    SELECT sc.*, rg.ritmo_puntos[coalesce(tr.indice, 0) + 1] AS ritmo,
           CASE WHEN sc.evaluadas = 0 THEN NULL
                ELSE round(rg.peso_puntualidad * sc.puntualidad + rg.peso_ritmo * rg.ritmo_puntos[coalesce(tr.indice, 0) + 1]) END AS puntaje,
           rg.corte_a, rg.corte_b, rg.corte_c
    FROM sc
    CROSS JOIN reglas rg
    LEFT JOIN public.est_cobranza_clientes() cc ON cc.cliente_id = sc.cliente_id
    LEFT JOIN LATERAL public.est_tramo_dias(cc.dias_sin_pagar) tr ON true
  )
  SELECT cliente_id, evaluadas, a_tiempo, atraso_prom, puntualidad, ritmo, puntaje,
         CASE WHEN puntaje IS NULL THEN 'Nuevo' WHEN puntaje >= corte_a THEN 'A' WHEN puntaje >= corte_b THEN 'B'
              WHEN puntaje >= corte_c THEN 'C' ELSE 'D' END
  FROM pu;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_puntaje_clientes() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_detal_lineas()
 RETURNS TABLE(tipo text, cuenta_id uuid, cliente_id uuid, fecha date, producto_id bigint, descripcion text, cantidad numeric, monto numeric, enlace text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH cat AS (
    SELECT DISTINCT ON (public.est_norm_texto(ip.descripcion)) public.est_norm_texto(ip.descripcion) AS d, ip.id
    FROM inv_productos ip
    WHERE public.est_norm_texto(ip.descripcion) IS NOT NULL
    ORDER BY public.est_norm_texto(ip.descripcion), ip.activo DESC, ip.id
  ),
  cu AS (SELECT * FROM public.est_cuentas_detal() WHERE vendible),
  cr AS (
    SELECT cu.id, cu.cliente_id, cu.fecha_inicio, btrim(x.l) AS l
    FROM cu
    JOIN creditos c ON c.id = cu.id
    CROSS JOIN LATERAL regexp_split_to_table(coalesce(c.productos_descripcion, ''), E'\n') AS x(l)
    WHERE cu.tipo = 'credito' AND btrim(x.l) <> ''
  ),
  crp AS (
    SELECT cr.id, cr.cliente_id, cr.fecha_inicio,
      btrim(regexp_replace(split_part(cr.l, ' | ', 1), '^\d+x ', '')) AS d,
      coalesce((regexp_match(cr.l, '^(\d+)x '))[1]::numeric, 1) AS q,
      coalesce(replace((regexp_match(cr.l, '\$([0-9][0-9.,]*)\s*$'))[1], ',', '')::numeric, 0) AS m
    FROM cr
  ),
  app AS (
    SELECT cu.id, cu.cliente_id, cu.fecha_inicio, p.producto_id, btrim(coalesce(p.descripcion, '')) AS d,
      coalesce(p.cantidad, 1)::numeric AS q,
      coalesce(p.subtotal, p.precio_unitario * coalesce(p.cantidad, 1), 0) AS m
    FROM productos_apartado p
    JOIN cu ON cu.tipo = 'apartado' AND cu.id = p.apartado_id
  )
  SELECT 'credito', crp.id, crp.cliente_id, crp.fecha_inicio, cat.id, crp.d, crp.q, crp.m,
         CASE WHEN cat.id IS NOT NULL THEN 'descripcion' ELSE 'sin_enlace' END
  FROM crp LEFT JOIN cat ON cat.d = public.est_norm_texto(crp.d)
  UNION ALL
  SELECT 'apartado', app.id, app.cliente_id, app.fecha_inicio, coalesce(app.producto_id, cat.id), app.d, app.q, app.m,
         CASE WHEN app.producto_id IS NOT NULL THEN 'id' WHEN cat.id IS NOT NULL THEN 'descripcion' ELSE 'sin_enlace' END
  FROM app LEFT JOIN cat ON app.producto_id IS NULL AND cat.d = public.est_norm_texto(app.d);
$function$;

REVOKE EXECUTE ON FUNCTION public.est_detal_lineas() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.est_may_lineas()
 RETURNS TABLE(factura_id uuid, cliente_id uuid, fecha date, producto_id bigint, descripcion text, cantidad numeric, monto numeric, enlace text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH cat AS (
    SELECT DISTINCT ON (public.est_norm_texto(ip.descripcion)) public.est_norm_texto(ip.descripcion) AS d, ip.id
    FROM inv_productos ip
    WHERE public.est_norm_texto(ip.descripcion) IS NOT NULL
    ORDER BY public.est_norm_texto(ip.descripcion), ip.activo DESC, ip.id
  )
  SELECT f.id, f.cliente_id, f.fecha, coalesce(i.producto_id, cat.id), btrim(coalesce(i.descripcion, '')),
         coalesce(i.cantidad, 0), coalesce(i.subtotal, i.precio_unitario * i.cantidad, 0),
         CASE WHEN i.producto_id IS NOT NULL THEN 'id' WHEN cat.id IS NOT NULL THEN 'descripcion' ELSE 'sin_enlace' END
  FROM may_factura_items i
  JOIN public.est_may_facturas() f ON f.id = i.factura_id
  LEFT JOIN cat ON i.producto_id IS NULL AND cat.d = public.est_norm_texto(i.descripcion)
  WHERE i.deleted_at IS NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.est_may_lineas() FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- Funciones públicas (las llama la app)
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.est_puede_ver()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.es_admin()
     AND EXISTS (SELECT 1 FROM public.est_acceso WHERE usuario_id = auth.uid());
$function$;

REVOKE EXECUTE ON FUNCTION public.est_puede_ver() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_puede_ver() TO authenticated;

CREATE OR REPLACE FUNCTION public.est_resumen(p_desde date, p_hasta date, p_ant_desde date DEFAULT NULL::date, p_ant_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);

  WITH
  cu AS (SELECT * FROM public.est_cuentas_detal()),
  ve AS (SELECT * FROM cu WHERE vendible),
  ia AS (SELECT * FROM public.est_detal_intereses() WHERE vendible),
  ab AS (SELECT * FROM public.est_detal_abonos()),
  mf AS (SELECT * FROM public.est_may_facturas()),
  ma AS (SELECT * FROM public.est_may_abonos()),
  pf AS (SELECT * FROM public.est_prov_facturas()),
  pa AS (SELECT * FROM public.est_prov_abonos()),
  -- Entradas: cobrado en el detal (todos los abonos vivos) y en el mayor (sin descuentos ni devoluciones)
  cob AS (
    SELECT 'detal'::text AS fuente, fecha, monto, metodo FROM ab
    UNION ALL
    SELECT 'mayor', fecha, monto, metodo FROM ma WHERE NOT es_descuento
  ),
  -- Deuda pagada a proveedores (est_prov_abonos.sale): sin tránsito, saldo a favor ni devoluciones
  pag AS (SELECT fecha, monto, ganancia FROM pa WHERE sale),
  ven AS (
    SELECT tipo, fecha_inicio AS fecha, subtotal AS monto FROM ve
    UNION ALL
    SELECT 'mayor', fecha, total FROM mf
  ),
  com AS (SELECT llegada AS fecha, monto FROM pf WHERE llegada IS NOT NULL),
  -- Movimientos que suben (+) o bajan (−) cada deuda, para reconstruir el saldo a cada fin de mes
  mov AS (
    SELECT tipo AS deuda, fecha_inicio AS fecha, subtotal AS m FROM ve
    UNION ALL SELECT tipo, fecha, monto FROM ia
    UNION ALL SELECT ab.tipo, ab.fecha, -ab.monto FROM ab JOIN ve ON ve.id = ab.cuenta_id
    UNION ALL SELECT 'mayor', fecha, total FROM mf
    UNION ALL SELECT 'mayor', fecha, -monto FROM ma
    UNION ALL SELECT 'prov', llegada, monto FROM pf WHERE llegada IS NOT NULL
    UNION ALL SELECT 'prov', fecha, -monto FROM pa WHERE NOT en_transito
  ),
  -- Primer mes con datos en cualquiera de los sistemas (para las series mes a mes)
  ini AS (
    SELECT date_trunc('month', least(
      coalesce((SELECT min(fecha_inicio) FROM cu), r.hasta),
      coalesce((SELECT min(fecha) FROM mf), r.hasta),
      coalesce((SELECT min(llegada) FROM pf), r.hasta),
      r.hasta))::date AS mes
  ),
  meses AS (
    SELECT g::date AS mes
    FROM ini, generate_series(ini.mes, date_trunc('month', r.hasta)::date, interval '1 month') AS g
  ),
  -- Sumas de cada mes, hasta la fecha final del período
  flujo AS (
    SELECT date_trunc('month', x.fecha)::date AS mes, x.k, round(sum(x.monto), 2) AS s
    FROM (
      SELECT 'cobrado_' || fuente AS k, fecha, monto FROM cob
      UNION ALL SELECT 'pagado_prov', fecha, monto FROM pag
      UNION ALL SELECT 'ventas_' || tipo, fecha, monto FROM ven
      UNION ALL SELECT 'compras_prov', fecha, monto FROM com
    ) x
    WHERE x.fecha <= r.hasta
    GROUP BY 1, 2
  ),
  -- Movimientos de deuda por mes (lo anterior al primer mes cae en el primer mes), para acumularlos
  mov_mes AS (
    SELECT greatest(date_trunc('month', fecha)::date, (SELECT mes FROM ini)) AS mes, deuda, sum(m) AS m
    FROM mov
    WHERE fecha <= r.hasta
    GROUP BY 1, 2
  ),
  serie_flujo AS (
    SELECT m.mes,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'cobrado_detal'), 0) AS cobrado_detal,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'cobrado_mayor'), 0) AS cobrado_mayor,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'pagado_prov'), 0) AS pagado_prov,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'ventas_credito'), 0) AS ventas_credito,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'ventas_apartado'), 0) AS ventas_apartado,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'ventas_mayor'), 0) AS ventas_mayor,
      coalesce(sum(f.s) FILTER (WHERE f.k = 'compras_prov'), 0) AS compras_prov
    FROM meses m LEFT JOIN flujo f ON f.mes = m.mes
    GROUP BY m.mes
  ),
  -- Saldo a fin de mes = todos los movimientos acumulados hasta ese mes (el mes en curso, hasta la fecha final)
  serie_deuda AS (
    SELECT m.mes,
      round(sum(coalesce(sum(x.m) FILTER (WHERE x.deuda = 'credito'), 0)) OVER (ORDER BY m.mes), 2) AS deben_creditos,
      round(sum(coalesce(sum(x.m) FILTER (WHERE x.deuda = 'apartado'), 0)) OVER (ORDER BY m.mes), 2) AS deben_apartados,
      round(sum(coalesce(sum(x.m) FILTER (WHERE x.deuda = 'mayor'), 0)) OVER (ORDER BY m.mes), 2) AS deben_mayor,
      round(sum(coalesce(sum(x.m) FILTER (WHERE x.deuda = 'prov'), 0)) OVER (ORDER BY m.mes), 2) AS debes_prov
    FROM meses m LEFT JOIN mov_mes x ON x.mes = m.mes
    GROUP BY m.mes
  ),
  serie AS (
    SELECT f.*, d.deben_creditos, d.deben_apartados, d.deben_mayor, d.debes_prov
    FROM serie_flujo f JOIN serie_deuda d ON d.mes = f.mes
  ),
  dias AS (SELECT d::date AS dia FROM generate_series(r.desde, r.hasta, interval '1 day') AS d)
  SELECT jsonb_build_object(
    'periodo', jsonb_build_object('desde', r.desde, 'hasta', r.hasta, 'ant_desde', r.ant_desde, 'ant_hasta', r.ant_hasta, 'hoy', r.hoy),
    -- Foto de hoy (no depende del período)
    'saldos', jsonb_build_object(
      'creditos', (SELECT jsonb_build_object('saldo', coalesce(round(sum(saldo), 2), 0), 'cuentas', count(*),
                     'vencido', coalesce(round(sum(saldo) FILTER (WHERE fecha_limite < r.hoy), 2), 0),
                     'cuentas_vencidas', count(*) FILTER (WHERE fecha_limite < r.hoy))
                   FROM cu WHERE viva AND tipo = 'credito'),
      'apartados', (SELECT jsonb_build_object('saldo', coalesce(round(sum(saldo), 2), 0), 'cuentas', count(*),
                     'vencido', coalesce(round(sum(saldo) FILTER (WHERE fecha_limite < r.hoy), 2), 0),
                     'cuentas_vencidas', count(*) FILTER (WHERE fecha_limite < r.hoy))
                   FROM cu WHERE viva AND tipo = 'apartado'),
      'mayor', (SELECT jsonb_build_object('saldo', coalesce(round(sum(saldo), 2), 0), 'cuentas', count(*),
                     'vencido', coalesce(round(sum(saldo) FILTER (WHERE fecha_vencimiento < r.hoy), 2), 0),
                     'cuentas_vencidas', count(*) FILTER (WHERE fecha_vencimiento < r.hoy))
                   FROM mf WHERE saldo > 0.01),
      'proveedores', (SELECT jsonb_build_object('saldo', coalesce(round(sum(saldo), 2), 0), 'cuentas', count(*),
                     'vencido', coalesce(round(sum(saldo) FILTER (WHERE vence < r.hoy), 2), 0),
                     'cuentas_vencidas', count(*) FILTER (WHERE vence < r.hoy))
                   FROM pf WHERE saldo > 0.01),
      'prov_saldo_favor', (SELECT coalesce(round(sum(credito_a_favor), 2), 0) FROM prov_proveedores WHERE credito_a_favor > 0),
      'prov_en_transito', (SELECT jsonb_build_object('monto', coalesce(round(sum(monto), 2), 0), 'n', count(*)) FROM pa WHERE en_transito)
    ),
    -- Indicadores del período y del período anterior
    'kpis', jsonb_build_object(
      'cobrado_detal', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                 'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM cob WHERE fuente = 'detal'),
      'cobrado_mayor', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                 'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM cob WHERE fuente = 'mayor'),
      'pagado_prov', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                               'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM pag),
      'ganancia_cambio', (SELECT jsonb_build_object('act', coalesce(round(sum(ganancia) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                   'ant', coalesce(round(sum(ganancia) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM pag),
      'ventas_credito', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                  'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM ven WHERE tipo = 'credito'),
      'ventas_apartado', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                   'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM ven WHERE tipo = 'apartado'),
      'ventas_mayor', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM ven WHERE tipo = 'mayor'),
      'compras_prov', (SELECT jsonb_build_object('act', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0),
                                                'ant', coalesce(round(sum(monto) FILTER (WHERE fecha BETWEEN r.ant_desde AND r.ant_hasta), 2), 0)) FROM com)
    ),
    -- Cobros por método: todas las fuentes juntas y por fuente
    'cobros_metodo', coalesce((
      SELECT jsonb_agg(jsonb_build_object('metodo', metodo, 'detal', detal, 'mayor', mayor, 'total', detal + mayor, 'n', n) ORDER BY detal + mayor DESC)
      FROM (SELECT metodo,
                   round(coalesce(sum(monto) FILTER (WHERE fuente = 'detal'), 0), 2) AS detal,
                   round(coalesce(sum(monto) FILTER (WHERE fuente = 'mayor'), 0), 2) AS mayor,
                   count(*) AS n
            FROM cob WHERE fecha BETWEEN r.desde AND r.hasta GROUP BY metodo) x), '[]'::jsonb),
    -- Cobros por día de la semana (1 = lunes ... 7 = domingo), con cuántos de esos días tuvo el período
    'cobros_dia_semana', (
      SELECT jsonb_agg(jsonb_build_object('dow', d.dow, 'detal', coalesce(c.detal, 0), 'mayor', coalesce(c.mayor, 0),
                                          'total', coalesce(c.detal, 0) + coalesce(c.mayor, 0), 'n', coalesce(c.n, 0), 'dias', d.dias) ORDER BY d.dow)
      FROM (SELECT g AS dow, (SELECT count(*) FROM dias WHERE extract(isodow FROM dia) = g) AS dias FROM generate_series(1, 7) AS g) d
      LEFT JOIN (SELECT extract(isodow FROM fecha)::int AS dow,
                        round(sum(monto) FILTER (WHERE fuente = 'detal'), 2) AS detal,
                        round(sum(monto) FILTER (WHERE fuente = 'mayor'), 2) AS mayor,
                        count(*) AS n
                 FROM cob WHERE fecha BETWEEN r.desde AND r.hasta GROUP BY 1) c ON c.dow = d.dow),
    'meses', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes) FROM serie s), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_resumen(date,date,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_resumen(date,date,date,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.est_detal(p_desde date, p_hasta date, p_ant_desde date DEFAULT NULL::date, p_ant_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);

  WITH
  cu AS (SELECT * FROM public.est_cuentas_detal()),
  ve AS (SELECT * FROM cu WHERE vendible),
  viva AS (SELECT * FROM cu WHERE viva),
  ab AS (SELECT * FROM public.est_detal_abonos()),
  ia AS (SELECT * FROM public.est_detal_intereses() WHERE vendible),
  cc AS (SELECT * FROM public.est_cobranza_clientes()),
  pu AS (SELECT * FROM public.est_puntaje_clientes()),
  reglas AS (SELECT public.est_reglas_puntaje() AS j),
  compras AS (
    SELECT cliente_id, count(DISTINCT fecha_inicio) AS compras, round(sum(subtotal), 2) AS comprado,
           min(fecha_inicio) AS primera,
           round(coalesce(sum(subtotal) FILTER (WHERE fecha_inicio BETWEEN r.desde AND r.hasta), 0), 2) AS comprado_periodo,
           count(*) FILTER (WHERE fecha_inicio BETWEEN r.desde AND r.hasta) AS cuentas_periodo
    FROM ve GROUP BY cliente_id
  ),
  -- Ficha de cada cliente con compras: puntaje (est_puntaje_clientes) y deuda de hoy (est_cobranza_clientes)
  fi AS (
    SELECT co.*, pu.evaluadas, pu.a_tiempo, pu.atraso_prom, pu.puntualidad, pu.ritmo, pu.puntaje, pu.letra,
           (cc.cliente_id IS NOT NULL) AS debe,
           coalesce(cc.deuda, 0) AS deuda, coalesce(cc.vencido, 0) AS vencido, cc.dias_sin_pagar,
           k.nombre, k.telefono
    FROM compras co
    JOIN pu ON pu.cliente_id = co.cliente_id
    JOIN clientes k ON k.id = co.cliente_id
    LEFT JOIN cc ON cc.cliente_id = co.cliente_id
  ),
  li AS (SELECT * FROM public.est_detal_lineas() WHERE fecha BETWEEN r.desde AND r.hasta),
  prod AS (
    SELECT coalesce('p' || li.producto_id::text, 'd' || coalesce(public.est_norm_texto(li.descripcion), '?')) AS clave,
           min(coalesce(ip.descripcion, li.descripcion)) AS producto,
           min(CASE WHEN li.producto_id IS NULL THEN 'Sin enlazar' ELSE public.est_categoria(ip.categoria) END) AS categoria,
           min(ip.codigo_valery) AS codigo,
           sum(li.cantidad) AS cantidad, round(sum(li.monto), 2) AS monto,
           count(*) FILTER (WHERE li.tipo = 'credito') AS en_creditos,
           count(*) FILTER (WHERE li.tipo = 'apartado') AS en_apartados,
           bool_or(li.producto_id IS NOT NULL) AS enlazado
    FROM li LEFT JOIN inv_productos ip ON ip.id = li.producto_id
    GROUP BY 1
  ),
  ini AS (SELECT date_trunc('month', least(coalesce((SELECT min(fecha_inicio) FROM cu), r.hasta), r.hasta))::date AS mes),
  meses AS (
    SELECT g::date AS mes FROM ini, generate_series(ini.mes, date_trunc('month', r.hasta)::date, interval '1 month') AS g
  ),
  -- Series mes a mes: una pasada agrupada por mes por cada fuente (sin una subconsulta por mes)
  s_ve AS (
    SELECT date_trunc('month', fecha_inicio)::date AS mes,
           count(*) FILTER (WHERE tipo = 'credito') AS cr_n,
           round(coalesce(sum(subtotal) FILTER (WHERE tipo = 'credito'), 0), 2) AS cr_monto,
           count(*) FILTER (WHERE tipo = 'apartado') AS ap_n,
           round(coalesce(sum(subtotal) FILTER (WHERE tipo = 'apartado'), 0), 2) AS ap_monto,
           round(avg(subtotal), 2) AS promedio,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY subtotal)::numeric, 2) AS mediana
    FROM ve WHERE fecha_inicio <= r.hasta GROUP BY 1
  ),
  s_fin AS (
    SELECT date_trunc('month', fecha_completado)::date AS mes,
           count(*) FILTER (WHERE tipo = 'credito') AS cr_terminados,
           round(avg(fecha_completado - fecha_inicio) FILTER (WHERE tipo = 'credito'), 1) AS cr_dias_terminar,
           count(*) FILTER (WHERE tipo = 'credito' AND fecha_completado <= fecha_limite) AS cr_terminados_a_tiempo,
           count(*) FILTER (WHERE tipo = 'apartado') AS ap_completados,
           round(avg(fecha_completado - fecha_inicio) FILTER (WHERE tipo = 'apartado'), 1) AS ap_dias_completar
    FROM ve WHERE fecha_completado <= r.hasta GROUP BY 1
  ),
  s_ab AS (
    SELECT date_trunc('month', fecha)::date AS mes, round(sum(monto), 2) AS cobrado, count(DISTINCT coalesce(grupo_pago, id)) AS pagos
    FROM ab WHERE fecha <= r.hasta GROUP BY 1
  ),
  s_ia AS (
    SELECT date_trunc('month', fecha)::date AS mes, round(sum(monto), 2) AS intereses,
           count(*) FILTER (WHERE NOT perdonado) AS intereses_n, count(*) FILTER (WHERE perdonado) AS perdonados_n,
           round(sum(era), 2) AS perdonado_monto
    FROM ia WHERE fecha <= r.hasta GROUP BY 1
  ),
  s_nu AS (SELECT date_trunc('month', primera)::date AS mes, count(*) AS clientes_nuevos FROM compras WHERE primera <= r.hasta GROUP BY 1),
  serie AS (
    SELECT m.mes,
           coalesce(v.cr_n, 0) AS cr_n, coalesce(v.cr_monto, 0) AS cr_monto, coalesce(v.ap_n, 0) AS ap_n, coalesce(v.ap_monto, 0) AS ap_monto,
           v.promedio, v.mediana,
           coalesce(a.cobrado, 0) AS cobrado, coalesce(a.pagos, 0) AS pagos,
           coalesce(i.intereses, 0) AS intereses, coalesce(i.intereses_n, 0) AS intereses_n,
           coalesce(i.perdonados_n, 0) AS perdonados_n, coalesce(i.perdonado_monto, 0) AS perdonado_monto,
           coalesce(f.cr_terminados, 0) AS cr_terminados, f.cr_dias_terminar, coalesce(f.cr_terminados_a_tiempo, 0) AS cr_terminados_a_tiempo,
           coalesce(f.ap_completados, 0) AS ap_completados, f.ap_dias_completar,
           coalesce(n.clientes_nuevos, 0) AS clientes_nuevos
    FROM meses m
    LEFT JOIN s_ve v ON v.mes = m.mes
    LEFT JOIN s_fin f ON f.mes = m.mes
    LEFT JOIN s_ab a ON a.mes = m.mes
    LEFT JOIN s_ia i ON i.mes = m.mes
    LEFT JOIN s_nu n ON n.mes = m.mes
  ),
  serie_metodo AS (
    SELECT date_trunc('month', fecha)::date AS mes, metodo, round(sum(monto), 2) AS monto
    FROM ab WHERE fecha <= r.hasta GROUP BY 1, 2
  ),
  -- Indicadores de un período (se calculan para el actual y el anterior)
  per AS (
    SELECT x.k, x.d, x.h FROM (VALUES ('act', r.desde, r.hasta), ('ant', r.ant_desde, r.ant_hasta)) AS x(k, d, h)
  ),
  kp AS (
    SELECT per.k, jsonb_build_object(
      'cr_n', (SELECT count(*) FROM ve WHERE tipo = 'credito' AND fecha_inicio BETWEEN per.d AND per.h),
      'cr_monto', (SELECT coalesce(round(sum(subtotal), 2), 0) FROM ve WHERE tipo = 'credito' AND fecha_inicio BETWEEN per.d AND per.h),
      'ap_n', (SELECT count(*) FROM ve WHERE tipo = 'apartado' AND fecha_inicio BETWEEN per.d AND per.h),
      'ap_monto', (SELECT coalesce(round(sum(subtotal), 2), 0) FROM ve WHERE tipo = 'apartado' AND fecha_inicio BETWEEN per.d AND per.h),
      'vendido', (SELECT coalesce(round(sum(subtotal), 2), 0) FROM ve WHERE fecha_inicio BETWEEN per.d AND per.h),
      'promedio', (SELECT round(avg(subtotal), 2) FROM ve WHERE fecha_inicio BETWEEN per.d AND per.h),
      'mediana', (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY subtotal)::numeric, 2) FROM ve WHERE fecha_inicio BETWEEN per.d AND per.h),
      'cobrado', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE fecha BETWEEN per.d AND per.h),
      'cobrado_cr', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE tipo = 'credito' AND fecha BETWEEN per.d AND per.h),
      'cobrado_ap', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE tipo = 'apartado' AND fecha BETWEEN per.d AND per.h),
      'pagos', (SELECT count(DISTINCT coalesce(grupo_pago, id)) FROM ab WHERE fecha BETWEEN per.d AND per.h),
      'intereses', (SELECT coalesce(round(sum(monto), 2), 0) FROM ia WHERE fecha BETWEEN per.d AND per.h),
      'intereses_n', (SELECT count(*) FILTER (WHERE NOT perdonado) FROM ia WHERE fecha BETWEEN per.d AND per.h),
      'perdonados_n', (SELECT count(*) FILTER (WHERE perdonado) FROM ia WHERE fecha BETWEEN per.d AND per.h),
      'perdonado_monto', (SELECT coalesce(round(sum(era), 2), 0) FROM ia WHERE fecha BETWEEN per.d AND per.h),
      'cr_terminados', (SELECT count(*) FROM ve WHERE tipo = 'credito' AND fecha_completado BETWEEN per.d AND per.h),
      'cr_dias_terminar', (SELECT round(avg(fecha_completado - fecha_inicio), 1) FROM ve WHERE tipo = 'credito' AND fecha_completado BETWEEN per.d AND per.h),
      'cr_a_tiempo_pct', (SELECT round(100.0 * count(*) FILTER (WHERE fecha_completado <= fecha_limite) / nullif(count(*), 0), 1) FROM ve WHERE tipo = 'credito' AND fecha_completado BETWEEN per.d AND per.h),
      'ap_completados', (SELECT count(*) FROM ve WHERE tipo = 'apartado' AND fecha_completado BETWEEN per.d AND per.h),
      'ap_dias_completar', (SELECT round(avg(fecha_completado - fecha_inicio), 1) FROM ve WHERE tipo = 'apartado' AND fecha_completado BETWEEN per.d AND per.h),
      'ap_completado_pct', (SELECT round(100.0 * count(*) FILTER (WHERE estado = 'completado') / nullif(count(*), 0), 1) FROM cu WHERE tipo = 'apartado' AND fecha_inicio BETWEEN per.d AND per.h),
      'clientes_nuevos', (SELECT count(*) FROM compras WHERE primera BETWEEN per.d AND per.h),
      'compradores', (SELECT count(DISTINCT cliente_id) FROM ve WHERE fecha_inicio BETWEEN per.d AND per.h),
      'cobrado_de_lo_vendido_pct', (SELECT round(100.0 * sum(total - saldo) / nullif(sum(total), 0), 1) FROM ve WHERE fecha_inicio BETWEEN per.d AND per.h)
    ) AS j
    FROM per
  ),
  -- Cartera por tramos de días (est_tramo_dias), con todos los tramos aunque estén vacíos
  tramo_viejo AS (
    SELECT tr.indice, count(*) AS n, round(sum(cc.deuda), 2) AS deuda, round(sum(cc.vencido), 2) AS vencido
    FROM cc LEFT JOIN LATERAL public.est_tramo_dias(cc.dias_viejo) tr ON true GROUP BY 1
  ),
  tramo_sin_pagar AS (
    SELECT tr.indice, count(*) AS n, round(sum(cc.deuda), 2) AS deuda, round(sum(cc.vencido), 2) AS vencido
    FROM cc LEFT JOIN LATERAL public.est_tramo_dias(cc.dias_sin_pagar) tr ON true GROUP BY 1
  )
  SELECT jsonb_build_object(
    'periodo', jsonb_build_object('desde', r.desde, 'hasta', r.hasta, 'ant_desde', r.ant_desde, 'ant_hasta', r.ant_hasta, 'hoy', r.hoy),
    'kpis', jsonb_build_object('act', (SELECT j FROM kp WHERE k = 'act'), 'ant', (SELECT j FROM kp WHERE k = 'ant')),
    'meses', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes) FROM serie s), '[]'::jsonb),
    'meses_metodo', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes, s.monto DESC) FROM serie_metodo s), '[]'::jsonb),
    -- Cobrado en el período
    'cobrado_metodo', coalesce((SELECT jsonb_agg(jsonb_build_object('metodo', metodo, 'n', n, 'monto', monto) ORDER BY monto DESC)
      FROM (SELECT metodo, count(*) AS n, round(sum(monto), 2) AS monto FROM ab WHERE fecha BETWEEN r.desde AND r.hasta GROUP BY 1) x), '[]'::jsonb),
    'cobrado_cuenta', coalesce((SELECT jsonb_agg(jsonb_build_object('cuenta', cuenta, 'n', n, 'monto', monto) ORDER BY monto DESC)
      FROM (SELECT coalesce(public.est_norm_texto(cuenta_destino), 'SIN CUENTA (EFECTIVO U OTRO)') AS cuenta, count(*) AS n, round(sum(monto), 2) AS monto
            FROM ab WHERE fecha BETWEEN r.desde AND r.hasta GROUP BY 1) x), '[]'::jsonb),
    'cobrado_usuario', coalesce((SELECT jsonb_agg(jsonb_build_object('usuario', usuario, 'n', n, 'monto', monto) ORDER BY monto DESC)
      FROM (SELECT coalesce(u.nombre, 'Sin registro') AS usuario, count(*) AS n, round(sum(ab.monto), 2) AS monto
            FROM ab LEFT JOIN usuarios_app u ON u.id = ab.registrado_por
            WHERE ab.fecha BETWEEN r.desde AND r.hasta GROUP BY 1) x), '[]'::jsonb),
    -- Cartera viva (foto de hoy)
    'cartera', jsonb_build_object(
      'deuda', (SELECT coalesce(round(sum(saldo), 2), 0) FROM viva),
      'deuda_cr', (SELECT coalesce(round(sum(saldo), 2), 0) FROM viva WHERE tipo = 'credito'),
      'deuda_ap', (SELECT coalesce(round(sum(saldo), 2), 0) FROM viva WHERE tipo = 'apartado'),
      'cuentas', (SELECT count(*) FROM viva),
      'clientes', (SELECT count(*) FROM cc),
      'vencido_cr', (SELECT coalesce(round(sum(saldo), 2), 0) FROM viva WHERE tipo = 'credito' AND fecha_limite < r.hoy),
      'vencido_cr_n', (SELECT count(*) FROM viva WHERE tipo = 'credito' AND fecha_limite < r.hoy),
      'vencido_ap', (SELECT coalesce(round(sum(saldo), 2), 0) FROM viva WHERE tipo = 'apartado' AND fecha_limite < r.hoy),
      'vencido_ap_n', (SELECT count(*) FROM viva WHERE tipo = 'apartado' AND fecha_limite < r.hoy),
      'nunca_pagaron', (SELECT count(*) FROM cc WHERE ultimo_pago IS NULL),
      'antiguedad', (SELECT jsonb_agg(jsonb_build_object('rango', t.indice, 'etiqueta', t.etiqueta, 'clientes', coalesce(x.n, 0),
                                                         'deuda', coalesce(x.deuda, 0), 'vencido', coalesce(x.vencido, 0)) ORDER BY t.indice)
                     FROM public.est_tramo_dias() t LEFT JOIN tramo_viejo x ON x.indice = t.indice),
      'sin_pagar', (SELECT jsonb_agg(jsonb_build_object('rango', t.indice, 'etiqueta', t.etiqueta, 'clientes', coalesce(x.n, 0),
                                                        'deuda', coalesce(x.deuda, 0), 'vencido', coalesce(x.vencido, 0)) ORDER BY t.indice)
                    FROM public.est_tramo_dias() t LEFT JOIN tramo_sin_pagar x ON x.indice = t.indice)
    ),
    -- Plazos
    'plazos_credito', coalesce((SELECT jsonb_agg(jsonb_build_object('dias', plazo_dias, 'n', n, 'monto', monto) ORDER BY n DESC)
      FROM (SELECT plazo_dias, count(*) AS n, round(sum(subtotal), 2) AS monto FROM ve WHERE tipo = 'credito' AND fecha_inicio BETWEEN r.desde AND r.hasta GROUP BY 1) x), '[]'::jsonb),
    'plazos_real', coalesce((SELECT jsonb_agg(jsonb_build_object('tipo', tipo, 'rango', rg, 'n', n) ORDER BY tipo, rg)
      FROM (SELECT tipo, CASE WHEN fecha_limite - fecha_inicio <= 15 THEN 0 WHEN fecha_limite - fecha_inicio <= 30 THEN 1
                              WHEN fecha_limite - fecha_inicio <= 45 THEN 2 WHEN fecha_limite - fecha_inicio <= 60 THEN 3
                              WHEN fecha_limite - fecha_inicio <= 90 THEN 4 ELSE 5 END AS rg, count(*) AS n
            FROM ve WHERE fecha_inicio BETWEEN r.desde AND r.hasta AND fecha_limite IS NOT NULL GROUP BY 1, 2) x), '[]'::jsonb),
    -- Apartados por estado (los que empezaron en el período, y todos)
    'apartados_estado', coalesce((SELECT jsonb_agg(jsonb_build_object('estado', estado, 'n', n, 'monto', monto, 'n_total', n_total, 'monto_total', monto_total) ORDER BY n_total DESC)
      FROM (SELECT estado,
                   count(*) FILTER (WHERE fecha_inicio BETWEEN r.desde AND r.hasta) AS n,
                   round(coalesce(sum(subtotal) FILTER (WHERE fecha_inicio BETWEEN r.desde AND r.hasta), 0), 2) AS monto,
                   count(*) AS n_total, round(sum(subtotal), 2) AS monto_total
            FROM cu WHERE tipo = 'apartado' GROUP BY 1) x), '[]'::jsonb),
    -- Clientes
    'clientes', jsonb_build_object(
      'con_compras', (SELECT count(*) FROM compras),
      'recurrentes', (SELECT count(*) FROM compras WHERE compras > 1),
      'registrados', (SELECT count(*) FROM clientes WHERE deleted_at IS NULL),
      'repiten_periodo', (SELECT count(*) FROM compras WHERE cuentas_periodo > 0 AND primera < r.desde),
      'letras', (SELECT jsonb_agg(jsonb_build_object('letra', letra, 'n', n, 'deuda', deuda, 'vencido', vencido) ORDER BY letra)
                 FROM (SELECT letra, count(*) AS n, round(sum(deuda), 2) AS deuda, round(sum(vencido), 2) AS vencido FROM fi GROUP BY 1) x)
    ),
    -- Reglas del puntaje (la app arma la explicación con esto) y los tramos de días que usa el ritmo
    'reglas_puntaje', (SELECT j FROM reglas) || jsonb_build_object('tramos',
      (SELECT jsonb_agg(jsonb_build_object('etiqueta', etiqueta, 'hasta', hasta) ORDER BY indice) FROM public.est_tramo_dias())),
    'top_deuda', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.deuda DESC) FROM (
      SELECT nombre, telefono, deuda, vencido, dias_sin_pagar, puntaje, letra
      FROM fi WHERE debe ORDER BY deuda DESC LIMIT 20) x), '[]'::jsonb),
    'top_compras', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.comprado_periodo DESC) FROM (
      SELECT nombre, comprado_periodo, cuentas_periodo, comprado, puntaje, letra
      FROM fi WHERE comprado_periodo > 0 ORDER BY comprado_periodo DESC LIMIT 20) x), '[]'::jsonb),
    'top_puntuales', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.puntaje DESC, x.evaluadas DESC, x.comprado DESC) FROM (
      SELECT nombre, puntaje, letra, evaluadas, a_tiempo, atraso_prom, comprado
      FROM fi WHERE evaluadas >= (SELECT (j->>'min_cuentas_puntuales')::int FROM reglas)
      ORDER BY puntaje DESC, evaluadas DESC, comprado DESC LIMIT 20) x), '[]'::jsonb),
    'top_atrasados', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.puntaje ASC, x.vencido DESC) FROM (
      SELECT nombre, telefono, puntaje, letra, atraso_prom, deuda, vencido, dias_sin_pagar
      FROM fi WHERE evaluadas >= 1 ORDER BY puntaje ASC, vencido DESC LIMIT 20) x), '[]'::jsonb),
    -- Vendedores (solo créditos: los apartados no guardan vendedor)
    'vendedores', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.vendido DESC) FROM (
      SELECT coalesce(u.nombre, 'Sin vendedor') AS vendedor, count(*) AS n, round(sum(v.subtotal), 2) AS vendido,
             round(avg(v.subtotal), 2) AS promedio,
             round(coalesce(sum(v.saldo) FILTER (WHERE v.viva), 0), 2) AS pendiente,
             round(coalesce(sum(v.saldo) FILTER (WHERE v.viva AND v.fecha_limite < r.hoy), 0), 2) AS atrasado,
             count(*) FILTER (WHERE v.viva AND v.fecha_limite < r.hoy) AS atrasados_n
      FROM ve v LEFT JOIN usuarios_app u ON u.id = v.vendedor_id
      WHERE v.tipo = 'credito' AND v.fecha_inicio BETWEEN r.desde AND r.hasta
      GROUP BY 1) x), '[]'::jsonb),
    -- Productos (período)
    'productos', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT producto, categoria, codigo, cantidad, monto, round(monto / nullif(cantidad, 0), 2) AS precio_prom, en_creditos, en_apartados, enlazado
      FROM prod) x), '[]'::jsonb),
    'categorias', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT categoria, count(*) AS productos, sum(cantidad) AS cantidad, round(sum(monto), 2) AS monto FROM prod GROUP BY 1) x), '[]'::jsonb),
    'enlace', (SELECT jsonb_build_object(
        'lineas', count(*), 'por_id', count(*) FILTER (WHERE enlace = 'id'),
        'por_descripcion', count(*) FILTER (WHERE enlace = 'descripcion'),
        'sin_enlace', count(*) FILTER (WHERE enlace = 'sin_enlace'),
        'monto_sin_enlace', coalesce(round(sum(monto) FILTER (WHERE enlace = 'sin_enlace'), 2), 0),
        'monto', coalesce(round(sum(monto), 2), 0))
      FROM li)
  ) INTO v_out;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_detal(date,date,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_detal(date,date,date,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.est_detal_puntajes()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();

  WITH
  co AS (
    SELECT cliente_id, count(DISTINCT fecha_inicio) AS compras, round(sum(subtotal), 2) AS comprado, max(fecha_inicio) AS ultima
    FROM public.est_cuentas_detal() WHERE vendible GROUP BY cliente_id
  ),
  cc AS (SELECT * FROM public.est_cobranza_clientes())
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.puntaje DESC NULLS LAST, x.comprado DESC), '[]'::jsonb) INTO v_out
  FROM (
    SELECT k.nombre, k.telefono, co.compras, co.comprado, co.ultima,
           coalesce(cc.deuda, 0) AS deuda, coalesce(cc.vencido, 0) AS vencido, cc.dias_sin_pagar,
           pu.evaluadas, pu.a_tiempo, pu.atraso_prom, pu.puntualidad, pu.ritmo, pu.puntaje, pu.letra
    FROM public.est_puntaje_clientes() pu
    JOIN co ON co.cliente_id = pu.cliente_id
    JOIN clientes k ON k.id = pu.cliente_id
    LEFT JOIN cc ON cc.cliente_id = pu.cliente_id
  ) x;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_detal_puntajes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_detal_puntajes() TO authenticated;

CREATE OR REPLACE FUNCTION public.est_mayorista(p_desde date, p_hasta date, p_ant_desde date DEFAULT NULL::date, p_ant_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);

  WITH
  cl AS (SELECT * FROM may_clientes WHERE deleted_at IS NULL),
  fa AS (SELECT * FROM public.est_may_facturas()),
  abo AS (SELECT * FROM public.est_may_abonos()),
  -- Renglones de todas las facturas: una sola llamada; el período y los KPI la filtran
  lin AS (SELECT * FROM public.est_may_lineas()),
  li AS (SELECT * FROM lin WHERE fecha BETWEEN r.desde AND r.hasta),
  -- Días en pagar cada factura: los abonos (todos, también descuentos) se aplican a lo más viejo primero,
  -- igual que may_recalcular_cliente. Una factura queda pagada el día en que lo abonado acumulado cubre
  -- todo lo facturado hasta ella.
  fac_acum AS (
    SELECT fa.*, sum(fa.total) OVER (PARTITION BY fa.cliente_id ORDER BY fa.fecha, fa.numero) AS acum
    FROM fa
  ),
  abo_dia AS (
    SELECT cliente_id, fecha, sum(sum(monto)) OVER (PARTITION BY cliente_id ORDER BY fecha) AS acum
    FROM abo GROUP BY cliente_id, fecha
  ),
  pago_fac AS (
    SELECT f.*, (SELECT min(d.fecha) FROM abo_dia d WHERE d.cliente_id = f.cliente_id AND d.acum >= f.acum - 0.01) AS fecha_pago
    FROM fac_acum f
  ),
  dias_pago AS (
    SELECT cliente_id, count(*) AS pagadas, round(avg(greatest(fecha_pago - fecha, 0)), 1) AS dias_prom,
           round(sum(greatest(fecha_pago - fecha, 0) * total) / nullif(sum(total), 0), 1) AS dias_prom_ponderado
    FROM pago_fac WHERE fecha_pago IS NOT NULL GROUP BY cliente_id
  ),
  por_cli AS (
    SELECT cl.id, cl.nombre, cl.plazo_dias, coalesce(cl.no_vender, false) AS no_vender,
           coalesce((SELECT round(sum(saldo), 2) FROM fa WHERE fa.cliente_id = cl.id AND saldo > 0.01), 0) AS deuda,
           coalesce((SELECT round(sum(saldo), 2) FROM fa WHERE fa.cliente_id = cl.id AND saldo > 0.01 AND fecha_vencimiento < r.hoy), 0) AS vencido,
           (SELECT count(*) FROM fa WHERE fa.cliente_id = cl.id) AS facturas,
           coalesce((SELECT round(sum(total), 2) FROM fa WHERE fa.cliente_id = cl.id), 0) AS comprado,
           coalesce((SELECT round(sum(total), 2) FROM fa WHERE fa.cliente_id = cl.id AND fecha BETWEEN r.desde AND r.hasta), 0) AS comprado_periodo,
           (SELECT count(*) FROM fa WHERE fa.cliente_id = cl.id AND fecha BETWEEN r.desde AND r.hasta) AS facturas_periodo,
           (SELECT min(fecha) FROM fa WHERE fa.cliente_id = cl.id) AS primera_compra,
           (SELECT max(fecha) FROM fa WHERE fa.cliente_id = cl.id) AS ultima_compra,
           (SELECT count(DISTINCT fecha) FROM fa WHERE fa.cliente_id = cl.id) AS dias_compra,
           (SELECT max(fecha) FROM abo WHERE abo.cliente_id = cl.id AND NOT es_descuento) AS ultimo_abono,
           coalesce((SELECT round(sum(monto), 2) FROM abo WHERE abo.cliente_id = cl.id AND NOT es_descuento AND fecha BETWEEN r.desde AND r.hasta), 0) AS cobrado_periodo,
           dp.dias_prom, dp.dias_prom_ponderado, dp.pagadas
    FROM cl LEFT JOIN dias_pago dp ON dp.cliente_id = cl.id
  ),
  por_cli2 AS (
    SELECT p.*,
           round(p.comprado / nullif(p.facturas, 0), 2) AS venta_prom,
           CASE WHEN p.dias_compra > 1 THEN round((p.ultima_compra - p.primera_compra)::numeric / (p.dias_compra - 1), 1) END AS cada_dias,
           CASE WHEN p.ultimo_abono IS NOT NULL THEN r.hoy - p.ultimo_abono END AS dias_sin_abonar
    FROM por_cli p
  ),
  prod AS (
    SELECT coalesce('p' || li.producto_id::text, 'd' || coalesce(public.est_norm_texto(li.descripcion), '?')) AS clave,
           min(coalesce(ip.descripcion, li.descripcion)) AS producto,
           min(CASE WHEN li.producto_id IS NULL THEN 'Sin enlazar' ELSE public.est_categoria(ip.categoria) END) AS categoria,
           min(ip.codigo_valery) AS codigo,
           sum(li.cantidad) AS cantidad, round(sum(li.monto), 2) AS monto,
           count(DISTINCT li.cliente_id) AS clientes,
           bool_or(li.producto_id IS NOT NULL) AS enlazado
    FROM li LEFT JOIN inv_productos ip ON ip.id = li.producto_id
    GROUP BY 1
  ),
  ini AS (SELECT date_trunc('month', least(coalesce((SELECT min(fecha) FROM fa), r.hasta), r.hasta))::date AS mes),
  meses AS (
    SELECT g::date AS mes FROM ini, generate_series(ini.mes, date_trunc('month', r.hasta)::date, interval '1 month') AS g
  ),
  s_fa AS (
    SELECT date_trunc('month', fecha)::date AS mes, count(*) AS facturas, round(sum(total), 2) AS facturado,
           round(coalesce(sum(total) FILTER (WHERE origen = 'migracion_cxc'), 0), 2) AS fact_migracion,
           round(coalesce(sum(total) FILTER (WHERE origen = 'carga_inicial'), 0), 2) AS fact_carga,
           round(coalesce(sum(total) FILTER (WHERE origen = 'pedido_rapido'), 0), 2) AS fact_pedido,
           round(coalesce(sum(total) FILTER (WHERE origen NOT IN ('migracion_cxc', 'carga_inicial', 'pedido_rapido')), 0), 2) AS fact_otro,
           count(DISTINCT cliente_id) AS clientes
    FROM fa WHERE fecha <= r.hasta GROUP BY 1
  ),
  s_ab AS (
    SELECT date_trunc('month', fecha)::date AS mes,
           round(coalesce(sum(monto) FILTER (WHERE NOT es_descuento), 0), 2) AS cobrado,
           round(coalesce(sum(monto) FILTER (WHERE es_descuento), 0), 2) AS descuentos
    FROM abo WHERE fecha <= r.hasta GROUP BY 1
  ),
  serie AS (
    SELECT m.mes, coalesce(f.facturas, 0) AS facturas, coalesce(f.facturado, 0) AS facturado,
           coalesce(f.fact_migracion, 0) AS fact_migracion, coalesce(f.fact_carga, 0) AS fact_carga,
           coalesce(f.fact_pedido, 0) AS fact_pedido, coalesce(f.fact_otro, 0) AS fact_otro,
           coalesce(a.cobrado, 0) AS cobrado, coalesce(a.descuentos, 0) AS descuentos, coalesce(f.clientes, 0) AS clientes
    FROM meses m LEFT JOIN s_fa f ON f.mes = m.mes LEFT JOIN s_ab a ON a.mes = m.mes
  ),
  -- Cobrado por mes y método (los descuentos y devoluciones van aparte, en serie.descuentos)
  serie_metodo AS (
    SELECT date_trunc('month', fecha)::date AS mes, metodo, round(sum(monto), 2) AS monto
    FROM abo WHERE NOT es_descuento AND fecha <= r.hasta GROUP BY 1, 2
  ),
  per AS (
    SELECT x.k, x.d, x.h FROM (VALUES ('act', r.desde, r.hasta), ('ant', r.ant_desde, r.ant_hasta)) AS x(k, d, h)
  ),
  kp AS (
    SELECT per.k, jsonb_build_object(
      'facturas', (SELECT count(*) FROM fa WHERE fecha BETWEEN per.d AND per.h),
      'facturado', (SELECT coalesce(round(sum(total), 2), 0) FROM fa WHERE fecha BETWEEN per.d AND per.h),
      'promedio', (SELECT round(avg(total), 2) FROM fa WHERE fecha BETWEEN per.d AND per.h),
      'cobrado', (SELECT coalesce(round(sum(monto), 2), 0) FROM abo WHERE NOT es_descuento AND fecha BETWEEN per.d AND per.h),
      'abonos', (SELECT count(*) FROM abo WHERE NOT es_descuento AND fecha BETWEEN per.d AND per.h),
      'descuentos', (SELECT coalesce(round(sum(monto), 2), 0) FROM abo WHERE es_descuento AND fecha BETWEEN per.d AND per.h),
      'clientes_compraron', (SELECT count(DISTINCT cliente_id) FROM fa WHERE fecha BETWEEN per.d AND per.h),
      'unidades', (SELECT coalesce(sum(l.cantidad), 0) FROM lin l WHERE l.fecha BETWEEN per.d AND per.h)
    ) AS j
    FROM per
  ),
  ranking AS (SELECT nombre, deuda, row_number() OVER (ORDER BY deuda DESC) AS pos FROM por_cli WHERE deuda > 0.01),
  -- Facturas con saldo, con sus tramos de días (est_tramo_dias): antigüedad desde la fecha y atraso desde el vencimiento
  pend AS (
    SELECT fa.saldo, ta.indice AS tramo_ant,
           CASE WHEN fa.fecha_vencimiento IS NULL OR fa.fecha_vencimiento >= r.hoy THEN 0 ELSE tv.indice + 1 END AS tramo_venc
    FROM fa
    LEFT JOIN LATERAL public.est_tramo_dias(r.hoy - fa.fecha) ta ON true
    LEFT JOIN LATERAL public.est_tramo_dias(r.hoy - fa.fecha_vencimiento) tv ON true
    WHERE fa.saldo > 0.01
  ),
  tramos_venc AS (
    SELECT 0 AS rango, 'Al día (todavía no vence)'::text AS etiqueta
    UNION ALL
    SELECT indice + 1, 'Vencida ' || lower(etiqueta) FROM public.est_tramo_dias()
  )
  SELECT jsonb_build_object(
    'periodo', jsonb_build_object('desde', r.desde, 'hasta', r.hasta, 'ant_desde', r.ant_desde, 'ant_hasta', r.ant_hasta, 'hoy', r.hoy),
    'kpis', jsonb_build_object('act', (SELECT j FROM kp WHERE k = 'act'), 'ant', (SELECT j FROM kp WHERE k = 'ant')),
    'meses', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes) FROM serie s), '[]'::jsonb),
    'meses_metodo', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes, s.monto DESC) FROM serie_metodo s), '[]'::jsonb),
    'origen', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto_total DESC) FROM (
      SELECT origen, count(*) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta) AS n,
             coalesce(round(sum(total) FILTER (WHERE fecha BETWEEN r.desde AND r.hasta), 2), 0) AS monto,
             count(*) AS n_total, round(sum(total), 2) AS monto_total, round(sum(saldo), 2) AS saldo
      FROM fa GROUP BY origen) x), '[]'::jsonb),
    'cobrado_metodo', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT metodo, es_descuento, count(*) AS n, round(sum(monto), 2) AS monto
      FROM abo WHERE fecha BETWEEN r.desde AND r.hasta GROUP BY metodo, es_descuento) x), '[]'::jsonb),
    -- Deuda (foto de hoy)
    'deuda', jsonb_build_object(
      'total', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01),
      'facturas', (SELECT count(*) FROM fa WHERE saldo > 0.01),
      'clientes', (SELECT count(*) FROM por_cli WHERE deuda > 0.01),
      'vencido', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento < r.hoy),
      'vencido_facturas', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento < r.hoy),
      'vence_7', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 7),
      'vence_15', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 15),
      'vence_30', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 30),
      'vence_7_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 7),
      'vence_15_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 15),
      'vence_30_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND fecha_vencimiento BETWEEN r.hoy AND r.hoy + 30),
      'top1_pct', (SELECT round(100.0 * sum(deuda) FILTER (WHERE pos = 1) / nullif(sum(deuda), 0), 1) FROM ranking),
      'top3_pct', (SELECT round(100.0 * sum(deuda) FILTER (WHERE pos <= 3) / nullif(sum(deuda), 0), 1) FROM ranking),
      'top3_nombres', (SELECT jsonb_agg(nombre ORDER BY pos) FROM ranking WHERE pos <= 3),
      'dias_pago_prom', (SELECT round(avg(greatest(fecha_pago - fecha, 0)), 1) FROM pago_fac WHERE fecha_pago IS NOT NULL),
      'dias_pago_ponderado', (SELECT round(sum(greatest(fecha_pago - fecha, 0) * total) / nullif(sum(total), 0), 1) FROM pago_fac WHERE fecha_pago IS NOT NULL),
      'antiguedad', (SELECT jsonb_agg(jsonb_build_object('rango', t.indice, 'etiqueta', t.etiqueta, 'facturas', coalesce(x.n, 0), 'saldo', coalesce(x.s, 0)) ORDER BY t.indice)
                     FROM public.est_tramo_dias() t
                     LEFT JOIN (SELECT tramo_ant, count(*) AS n, round(sum(saldo), 2) AS s FROM pend GROUP BY 1) x ON x.tramo_ant = t.indice),
      'vencimiento', (SELECT jsonb_agg(jsonb_build_object('rango', t.rango, 'etiqueta', t.etiqueta, 'facturas', coalesce(x.n, 0), 'saldo', coalesce(x.s, 0)) ORDER BY t.rango)
                      FROM tramos_venc t
                      LEFT JOIN (SELECT tramo_venc, count(*) AS n, round(sum(saldo), 2) AS s FROM pend GROUP BY 1) x ON x.tramo_venc = t.rango)
    ),
    'clientes', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.deuda DESC, x.comprado DESC) FROM (
      SELECT nombre, plazo_dias, no_vender, deuda, vencido, facturas, comprado, venta_prom, cada_dias, primera_compra, ultima_compra,
             ultimo_abono, dias_sin_abonar, dias_prom AS dias_pago, dias_prom_ponderado AS dias_pago_ponderado, pagadas,
             comprado_periodo, facturas_periodo, cobrado_periodo
      FROM por_cli2) x), '[]'::jsonb),
    'por_vencer', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fecha_vencimiento) FROM (
      SELECT fa.numero, cl.nombre, fa.fecha, fa.fecha_vencimiento, fa.total, fa.saldo, fa.fecha_vencimiento - r.hoy AS dias
      FROM fa JOIN cl ON cl.id = fa.cliente_id
      WHERE fa.saldo > 0.01 AND fa.fecha_vencimiento BETWEEN r.hoy AND r.hoy + 30) x), '[]'::jsonb),
    'vencidas', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fecha_vencimiento) FROM (
      SELECT fa.numero, cl.nombre, fa.fecha, fa.fecha_vencimiento, fa.total, fa.saldo, r.hoy - fa.fecha_vencimiento AS dias
      FROM fa JOIN cl ON cl.id = fa.cliente_id
      WHERE fa.saldo > 0.01 AND fa.fecha_vencimiento < r.hoy) x), '[]'::jsonb),
    'productos', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT producto, categoria, codigo, cantidad, monto, round(monto / nullif(cantidad, 0), 2) AS precio_prom, clientes, enlazado
      FROM prod) x), '[]'::jsonb),
    'categorias', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT categoria, count(*) AS productos, sum(cantidad) AS cantidad, round(sum(monto), 2) AS monto FROM prod GROUP BY 1) x), '[]'::jsonb),
    'enlace', (SELECT jsonb_build_object(
        'lineas', count(*), 'por_id', count(*) FILTER (WHERE enlace = 'id'),
        'por_descripcion', count(*) FILTER (WHERE enlace = 'descripcion'),
        'sin_enlace', count(*) FILTER (WHERE enlace = 'sin_enlace'),
        'monto_sin_enlace', coalesce(round(sum(monto) FILTER (WHERE enlace = 'sin_enlace'), 2), 0),
        'monto', coalesce(round(sum(monto), 2), 0))
      FROM li)
  ) INTO v_out;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_mayorista(date,date,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_mayorista(date,date,date,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.est_proveedores(p_desde date, p_hasta date, p_ant_desde date DEFAULT NULL::date, p_ant_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);

  WITH
  fa AS (SELECT * FROM public.est_prov_facturas()),
  ab AS (SELECT * FROM public.est_prov_abonos()),
  -- Días en pagar cada factura ya pagada: del día que llegó al último abono confirmado (como prov_stats_dias_pago)
  pagadas AS (
    SELECT fa.id, fa.proveedor_id, fa.monto, max(ab.fecha) - fa.llegada AS dias
    FROM fa JOIN ab ON ab.factura_id = fa.id AND NOT ab.en_transito
    WHERE fa.saldo <= 0.01 AND fa.llegada IS NOT NULL
    GROUP BY fa.id, fa.proveedor_id, fa.monto, fa.llegada
  ),
  por_prov AS (
    SELECT p.id, p.proveedor, coalesce(p.credito_a_favor, 0) AS saldo_favor,
      coalesce((SELECT round(sum(saldo), 2) FROM fa WHERE fa.proveedor_id = p.id AND saldo > 0.01), 0) AS deuda,
      coalesce((SELECT round(sum(saldo), 2) FROM fa WHERE fa.proveedor_id = p.id AND saldo > 0.01 AND vence < r.hoy), 0) AS vencido,
      coalesce((SELECT round(sum(saldo), 2) FROM fa WHERE fa.proveedor_id = p.id AND saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 30), 0) AS vence_30,
      (SELECT count(*) FROM fa WHERE fa.proveedor_id = p.id AND saldo > 0.01) AS pendientes,
      (SELECT min(vence) FROM fa WHERE fa.proveedor_id = p.id AND saldo > 0.01) AS proximo_vence,
      coalesce((SELECT round(sum(monto), 2) FROM fa WHERE fa.proveedor_id = p.id AND llegada BETWEEN r.desde AND r.hasta), 0) AS comprado,
      (SELECT count(*) FROM fa WHERE fa.proveedor_id = p.id AND llegada BETWEEN r.desde AND r.hasta) AS facturas,
      coalesce((SELECT round(sum(monto), 2) FROM ab WHERE ab.proveedor_id = p.id AND sale AND fecha BETWEEN r.desde AND r.hasta), 0) AS pagado,
      coalesce((SELECT round(sum(ganancia), 2) FROM ab WHERE ab.proveedor_id = p.id AND sale AND fecha BETWEEN r.desde AND r.hasta), 0) AS ganancia,
      coalesce((SELECT round(sum(monto), 2) FROM ab WHERE ab.proveedor_id = p.id AND en_transito), 0) AS en_transito,
      coalesce((SELECT round(sum(monto), 2) FROM fa WHERE fa.proveedor_id = p.id), 0) AS comprado_total,
      (SELECT max(llegada) FROM fa WHERE fa.proveedor_id = p.id) AS ultima_compra,
      (SELECT max(fecha) FROM ab WHERE ab.proveedor_id = p.id AND sale) AS ultimo_pago,
      (SELECT round(avg(dias), 1) FROM pagadas pg WHERE pg.proveedor_id = p.id AND pg.dias >= 0) AS dias_pago,
      (SELECT count(*) FROM pagadas pg WHERE pg.proveedor_id = p.id AND pg.dias >= 0) AS pagadas
    FROM prov_proveedores p
  ),
  rk AS (SELECT comprado, row_number() OVER (ORDER BY comprado DESC) AS pos FROM por_prov WHERE comprado > 0),
  ini AS (SELECT date_trunc('month', least(coalesce((SELECT min(llegada) FROM fa), r.hasta), r.hasta))::date AS mes),
  meses AS (
    SELECT g::date AS mes FROM ini, generate_series(ini.mes, date_trunc('month', r.hasta)::date, interval '1 month') AS g
  ),
  s_fa AS (
    SELECT date_trunc('month', llegada)::date AS mes, count(*) AS facturas, round(sum(monto), 2) AS comprado
    FROM fa WHERE llegada <= r.hasta GROUP BY 1
  ),
  s_ab AS (
    SELECT date_trunc('month', fecha)::date AS mes,
           round(coalesce(sum(monto) FILTER (WHERE sale), 0), 2) AS pagado,
           count(*) FILTER (WHERE sale) AS pagos,
           round(coalesce(sum(monto) FILTER (WHERE saldo_favor), 0), 2) AS saldo_favor,
           round(coalesce(sum(monto) FILTER (WHERE devolucion AND NOT en_transito), 0), 2) AS devoluciones,
           round(coalesce(sum(ganancia) FILTER (WHERE sale), 0), 2) AS ganancia
    FROM ab WHERE fecha <= r.hasta GROUP BY 1
  ),
  serie AS (
    SELECT m.mes, coalesce(f.facturas, 0) AS facturas, coalesce(f.comprado, 0) AS comprado,
           coalesce(a.pagado, 0) AS pagado, coalesce(a.pagos, 0) AS pagos, coalesce(a.saldo_favor, 0) AS saldo_favor,
           coalesce(a.devoluciones, 0) AS devoluciones, coalesce(a.ganancia, 0) AS ganancia
    FROM meses m LEFT JOIN s_fa f ON f.mes = m.mes LEFT JOIN s_ab a ON a.mes = m.mes
  ),
  serie_ganancia AS (
    SELECT date_trunc('month', fecha)::date AS mes, metodo, round(sum(ganancia), 2) AS ganancia
    FROM ab WHERE sale AND ganancia > 0 AND fecha <= r.hasta GROUP BY 1, 2
  ),
  per AS (
    SELECT x.k, x.d, x.h FROM (VALUES ('act', r.desde, r.hasta), ('ant', r.ant_desde, r.ant_hasta)) AS x(k, d, h)
  ),
  kp AS (
    SELECT per.k, jsonb_build_object(
      'facturas', (SELECT count(*) FROM fa WHERE llegada BETWEEN per.d AND per.h),
      'comprado', (SELECT coalesce(round(sum(monto), 2), 0) FROM fa WHERE llegada BETWEEN per.d AND per.h),
      'pagado', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE sale AND fecha BETWEEN per.d AND per.h),
      'pagos', (SELECT count(*) FROM ab WHERE sale AND fecha BETWEEN per.d AND per.h),
      'saldo_favor', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE saldo_favor AND fecha BETWEEN per.d AND per.h),
      'devoluciones', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE devolucion AND NOT en_transito AND fecha BETWEEN per.d AND per.h),
      'ganancia', (SELECT coalesce(round(sum(ganancia), 2), 0) FROM ab WHERE sale AND fecha BETWEEN per.d AND per.h),
      'volumen_cambio', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE sale AND ganancia > 0 AND fecha BETWEEN per.d AND per.h),
      'proveedores', (SELECT count(DISTINCT proveedor_id) FROM fa WHERE llegada BETWEEN per.d AND per.h),
      'promedio', (SELECT round(avg(monto), 2) FROM fa WHERE llegada BETWEEN per.d AND per.h)
    ) AS j
    FROM per
  )
  SELECT jsonb_build_object(
    'periodo', jsonb_build_object('desde', r.desde, 'hasta', r.hasta, 'ant_desde', r.ant_desde, 'ant_hasta', r.ant_hasta, 'hoy', r.hoy),
    'kpis', jsonb_build_object('act', (SELECT j FROM kp WHERE k = 'act'), 'ant', (SELECT j FROM kp WHERE k = 'ant')),
    'meses', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes) FROM serie s), '[]'::jsonb),
    'meses_ganancia', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.mes, s.ganancia DESC) FROM serie_ganancia s), '[]'::jsonb),
    -- Deuda (foto de hoy)
    'deuda', jsonb_build_object(
      'total', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01),
      'facturas', (SELECT count(*) FROM fa WHERE saldo > 0.01),
      'proveedores', (SELECT count(DISTINCT proveedor_id) FROM fa WHERE saldo > 0.01),
      'vencido', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND vence < r.hoy),
      'vencido_facturas', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND vence < r.hoy),
      'vence_7', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 7),
      'vence_15', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 15),
      'vence_30', (SELECT coalesce(round(sum(saldo), 2), 0) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 30),
      'vence_7_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 7),
      'vence_15_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 15),
      'vence_30_n', (SELECT count(*) FROM fa WHERE saldo > 0.01 AND vence BETWEEN r.hoy AND r.hoy + 30),
      'en_transito', (SELECT coalesce(round(sum(monto), 2), 0) FROM ab WHERE en_transito),
      'en_transito_n', (SELECT count(*) FROM ab WHERE en_transito),
      'saldo_favor', (SELECT coalesce(round(sum(credito_a_favor), 2), 0) FROM prov_proveedores WHERE credito_a_favor > 0),
      'dias_pago_prom', (SELECT round(avg(dias), 1) FROM pagadas WHERE dias >= 0),
      'dias_pago_ponderado', (SELECT round(sum(dias * monto) / nullif(sum(monto), 0), 1) FROM pagadas WHERE dias >= 0),
      'antiguedad', (SELECT jsonb_agg(jsonb_build_object('rango', t.indice, 'etiqueta', t.etiqueta, 'facturas', coalesce(x.n, 0), 'saldo', coalesce(x.s, 0)) ORDER BY t.indice)
                     FROM public.est_tramo_dias() t
                     LEFT JOIN (SELECT tr.indice, count(*) AS n, round(sum(fa.saldo), 2) AS s
                                FROM fa LEFT JOIN LATERAL public.est_tramo_dias(r.hoy - fa.llegada) tr ON true
                                WHERE fa.saldo > 0.01 GROUP BY 1) x ON x.indice = t.indice)
    ),
    'concentracion', jsonb_build_object(
      'top1_pct', (SELECT round(100.0 * sum(comprado) FILTER (WHERE pos = 1) / nullif(sum(comprado), 0), 1) FROM rk),
      'top3_pct', (SELECT round(100.0 * sum(comprado) FILTER (WHERE pos <= 3) / nullif(sum(comprado), 0), 1) FROM rk),
      'top5_pct', (SELECT round(100.0 * sum(comprado) FILTER (WHERE pos <= 5) / nullif(sum(comprado), 0), 1) FROM rk),
      'proveedores', (SELECT count(*) FROM rk)
    ),
    'proveedores', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.comprado DESC, x.deuda DESC) FROM (
      SELECT proveedor, comprado, facturas, pagado, ganancia, deuda, vencido, vence_30, pendientes, proximo_vence, saldo_favor,
             en_transito, comprado_total, ultima_compra, ultimo_pago, dias_pago, pagadas
      FROM por_prov WHERE comprado > 0 OR deuda > 0.01 OR saldo_favor > 0 OR en_transito > 0 OR comprado_total > 0) x), '[]'::jsonb),
    -- Pagos confirmados por método. no_sale: saldo a favor o devolución (bajan la deuda sin que salga dinero)
    'pagos_metodo', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC) FROM (
      SELECT metodo, count(*) AS n, round(sum(monto), 2) AS monto, round(sum(ganancia), 2) AS ganancia,
             bool_or(saldo_favor OR devolucion) AS no_sale
      FROM ab WHERE NOT en_transito AND fecha BETWEEN r.desde AND r.hasta GROUP BY metodo) x), '[]'::jsonb),
    'ganancia_metodo', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.ganancia DESC) FROM (
      SELECT metodo, count(*) AS operaciones, round(sum(monto), 2) AS volumen, round(sum(ganancia), 2) AS ganancia,
             round(100.0 * sum(ganancia) / nullif(sum(monto), 0), 2) AS pct
      FROM ab WHERE sale AND ganancia > 0 AND fecha BETWEEN r.desde AND r.hasta GROUP BY metodo) x), '[]'::jsonb),
    'por_vencer', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.vence) FROM (
      SELECT p.proveedor, fa.num, fa.llegada, fa.vence, fa.monto, fa.saldo, fa.vence - r.hoy AS dias
      FROM fa JOIN prov_proveedores p ON p.id = fa.proveedor_id
      WHERE fa.saldo > 0.01 AND fa.vence BETWEEN r.hoy AND r.hoy + 30) x), '[]'::jsonb),
    'vencidas', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.vence) FROM (
      SELECT p.proveedor, fa.num, fa.llegada, fa.vence, fa.monto, fa.saldo, r.hoy - fa.vence AS dias
      FROM fa JOIN prov_proveedores p ON p.id = fa.proveedor_id
      WHERE fa.saldo > 0.01 AND fa.vence < r.hoy) x), '[]'::jsonb),
    'disputa', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.llegada) FROM (
      SELECT p.proveedor, fa.num, fa.llegada, fa.vence, fa.monto, fa.saldo, fa.motivo_disputa
      FROM fa JOIN prov_proveedores p ON p.id = fa.proveedor_id WHERE fa.disputada) x), '[]'::jsonb),
    'esperando_doc', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.llegada) FROM (
      SELECT p.proveedor, fa.num, fa.llegada, fa.vence, fa.monto, fa.saldo
      FROM fa JOIN prov_proveedores p ON p.id = fa.proveedor_id WHERE fa.esperando_doc) x), '[]'::jsonb),
    'transito', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fecha) FROM (
      SELECT p.proveedor, fa.num, ab.fecha, ab.monto, ab.metodo
      FROM ab JOIN fa ON fa.id = ab.factura_id JOIN prov_proveedores p ON p.id = fa.proveedor_id WHERE ab.en_transito) x), '[]'::jsonb),
    'devoluciones', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fecha) FROM (
      SELECT p.proveedor, d.fecha, round(d.monto, 2) AS monto, d.desc_dev AS descripcion, d.motivo, d.estado
      FROM prov_devoluciones d JOIN fa ON fa.id = d.factura_id JOIN prov_proveedores p ON p.id = fa.proveedor_id) x), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_proveedores(date,date,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_proveedores(date,date,date,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.est_inventario()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();

  SELECT jsonb_build_object(
    'productos', (SELECT count(*) FROM inv_productos),
    'activos', (SELECT count(*) FROM inv_productos WHERE activo),
    'con_costo', (SELECT count(*) FROM inv_productos WHERE activo AND costo_usd IS NOT NULL AND costo_usd > 0),
    'con_codigo', (SELECT count(*) FROM inv_productos WHERE activo AND nullif(btrim(codigo_valery), '') IS NOT NULL),
    'con_existencia', (SELECT count(*) FROM inv_productos WHERE activo AND existencia_valery > 0),
    'unidades', (SELECT coalesce(sum(existencia_valery), 0) FROM inv_productos WHERE activo AND existencia_valery > 0),
    'valor_precio', (SELECT coalesce(round(sum(existencia_valery * precio_usd), 2), 0) FROM inv_productos WHERE activo AND existencia_valery > 0 AND precio_usd > 0),
    'existencia_negativa', (SELECT count(*) FROM inv_productos WHERE existencia_valery < 0),
    'existencia_negativa_activos', (SELECT count(*) FROM inv_productos WHERE activo AND existencia_valery < 0),
    'foto_catalogo', (SELECT max(creado_en)::date FROM inv_productos),
    'ventas_sistema', (SELECT count(*) FROM inv_ventas),
    'movimientos', (SELECT count(*) FROM inv_movimientos),
    'categorias', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.activos DESC) FROM (
      SELECT public.est_categoria(categoria) AS categoria,
             count(*) FILTER (WHERE activo) AS activos,
             count(*) FILTER (WHERE activo AND costo_usd > 0) AS con_costo,
             count(*) FILTER (WHERE activo AND existencia_valery > 0) AS con_existencia,
             coalesce(sum(existencia_valery) FILTER (WHERE activo AND existencia_valery > 0), 0) AS unidades,
             coalesce(round(sum(existencia_valery * precio_usd) FILTER (WHERE activo AND existencia_valery > 0 AND precio_usd > 0), 2), 0) AS valor_precio,
             round(avg(precio_usd) FILTER (WHERE activo AND precio_usd > 0), 2) AS precio_prom
      FROM inv_productos GROUP BY 1) x WHERE x.activos > 0), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END $function$;

REVOKE EXECUTE ON FUNCTION public.est_inventario() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_inventario() TO authenticated;
