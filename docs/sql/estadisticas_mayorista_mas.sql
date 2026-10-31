-- Estadísticas del mayor: métricas nuevas pedidas por Kinan el 2026-10-31 (pendiente 16(e) de CLAUDE.md).
-- Copia de referencia de lo que vive en la base. Solo lee. Usa las funciones de origen del mayor (est_may_facturas,
-- est_may_abonos, est_may_lineas) y las reglas de la calificación (cli_reglas_calificacion), así cuadra con lo demás.
--
-- est_mayorista_mas(período): M1 nota de cada cliente, M2 calendario de cobros, M3 quién compra menos, M4 riesgo por
-- cliente, M5 precio por cliente, M6 crecimiento por cliente, M7 pedidos de la caja.
--
-- Nota del mayor (M1): igual que la del detal (mismos tramos, gracia, cortes y letra máxima por cuentas terminadas),
-- pero sin el factor de intereses porque el mayor no cobra interés: puntualidad 80% y facturas pagadas 20%
-- (mayor_peso_puntualidad y mayor_peso_historial en cli_reglas_calificacion). Lo de hoy solo resta, como en el detal.
-- Cada factura queda pagada el día en que lo abonado acumulado (a lo más viejo primero) cubre todo lo facturado hasta ella.

CREATE OR REPLACE FUNCTION public.est_mayorista_mas(p_desde date, p_hasta date, p_ant_desde date, p_ant_hasta date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  j jsonb := public.cli_reglas_calificacion();
  g int;
  v jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);
  g := (j->>'gracia_dias')::int;

  WITH
  cl AS (SELECT * FROM may_clientes WHERE deleted_at IS NULL),
  fa AS (SELECT * FROM public.est_may_facturas()),
  abo AS (SELECT * FROM public.est_may_abonos()),
  lin AS (SELECT * FROM public.est_may_lineas()),
  -- Día en que quedó pagada cada factura (igual que est_mayorista)
  fac_acum AS (SELECT fa.*, sum(fa.total) OVER (PARTITION BY fa.cliente_id ORDER BY fa.fecha, fa.numero) AS acum FROM fa),
  abo_dia AS (SELECT cliente_id, fecha, sum(sum(monto)) OVER (PARTITION BY cliente_id ORDER BY fecha) AS acum FROM abo GROUP BY cliente_id, fecha),
  pago_fac AS (
    SELECT f.*, (SELECT min(d.fecha) FROM abo_dia d WHERE d.cliente_id = f.cliente_id AND d.acum >= f.acum - 0.01) AS fecha_pago
    FROM fac_acum f
  ),
  -- M1: cada factura, con sus días de atraso y sus puntos (los mismos tramos del detal)
  ev AS (
    SELECT p.*, (p.saldo <= 0.01) AS cerrada, (p.saldo > 0.01 AND p.fecha_vencimiento < r.hoy) AS vencida_hoy,
           CASE WHEN p.saldo <= 0.01 THEN greatest(coalesce(p.fecha_pago, p.fecha_vencimiento) - p.fecha_vencimiento, 0)
                WHEN p.fecha_vencimiento < r.hoy THEN r.hoy - p.fecha_vencimiento ELSE 0 END AS dias
    FROM pago_fac p
  ),
  ev2 AS (
    SELECT e.*, (e.cerrada OR (e.vencida_hoy AND e.dias > g)) AS evaluada, (e.cerrada AND e.dias <= g) AS a_tiempo,
           CASE WHEN e.cerrada AND e.dias <= g THEN 100
                WHEN e.cerrada THEN public.cli_tramo(j->'cerrada_tarde_puntos', e.dias, 'puntos')
                WHEN e.vencida_hoy AND e.dias > g THEN public.cli_tramo(j->'abierta_vencida_puntos', e.dias, 'puntos') END AS pts
    FROM ev e
  ),
  nota AS (
    SELECT cl.id AS cliente_id, cl.nombre, cl.telefono, coalesce(cl.no_vender, false) AS no_vender,
           count(x.id) FILTER (WHERE x.evaluada)::int AS evaluadas,
           count(x.id) FILTER (WHERE x.evaluada AND x.a_tiempo)::int AS a_tiempo,
           count(x.id) FILTER (WHERE x.cerrada)::int AS pagadas,
           round(avg(x.pts) FILTER (WHERE x.evaluada), 1) AS puntualidad,
           round(avg(x.dias) FILTER (WHERE x.evaluada AND NOT x.a_tiempo))::int AS atraso_prom_tarde,
           round(coalesce(sum(x.saldo) FILTER (WHERE x.saldo > 0.01), 0), 2) AS deuda,
           round(coalesce(sum(x.saldo) FILTER (WHERE x.vencida_hoy), 0), 2) AS vencido,
           max(x.dias) FILTER (WHERE x.vencida_hoy) AS dias_vencido,
           min(x.fecha) FILTER (WHERE x.saldo > 0.01) AS inicio_viejo,
           (SELECT max(a.fecha) FROM abo a WHERE a.cliente_id = cl.id AND NOT a.es_descuento) AS ultimo_abono,
           coalesce((SELECT sum(a.monto) FROM abo a WHERE a.cliente_id = cl.id AND NOT a.es_descuento), 0) <= 0
             AND bool_or(x.evaluada AND NOT x.cerrada) AS nunca_pago_vencido
    FROM cl LEFT JOIN ev2 x ON x.cliente_id = cl.id
    GROUP BY cl.id, cl.nombre, cl.telefono, cl.no_vender
  ),
  nota2 AS (
    SELECT n.*,
           CASE WHEN n.evaluadas > 0 THEN round((j->>'mayor_peso_puntualidad')::numeric * n.puntualidad
                + (j->>'mayor_peso_historial')::numeric * (j->'historial_puntos'->>least(n.pagadas, jsonb_array_length(j->'historial_puntos') - 1))::numeric, 1) END AS historia,
           CASE WHEN n.dias_vencido > g THEN public.cli_tramo(j->'vencido_resta', n.dias_vencido, 'resta') ELSE 0 END AS resta_vencido,
           CASE WHEN n.deuda > 0.01 THEN coalesce(public.cli_tramo(j->'sin_abonar_resta', r.hoy - coalesce(n.ultimo_abono, n.inicio_viejo), 'resta'), 0) ELSE 0 END AS resta_sin_abonar,
           CASE WHEN n.deuda > 0.01 THEN r.hoy - coalesce(n.ultimo_abono, n.inicio_viejo) END AS dias_sin_abonar
    FROM nota n
  ),
  nota3 AS (
    SELECT n.*, CASE WHEN n.evaluadas > 0 THEN greatest(0, round(n.historia - n.resta_vencido - n.resta_sin_abonar))::int END AS puntaje
    FROM nota2 n
  ),
  nota4 AS (
    SELECT n.*,
           CASE WHEN n.evaluadas = 0 THEN 'N'
                WHEN coalesce(n.nunca_pago_vencido, false) THEN j->'cortes'->-1->>'letra'
                ELSE public.cli_peor_letra(j->'cortes', j->'letra_max_por_cerradas'->>n.pagadas,
                       (SELECT x->>'letra' FROM jsonb_array_elements(j->'cortes') WITH ORDINALITY AS t(x, o)
                         WHERE n.puntaje >= (x->>'desde')::numeric ORDER BY o LIMIT 1)) END AS letra
    FROM nota3 n
  ),
  -- M3: compras del período contra el período anterior y cada cuánto compra
  compras AS (
    SELECT cl.id AS cliente_id, cl.nombre,
           round(coalesce(sum(fa.total) FILTER (WHERE fa.fecha BETWEEN r.desde AND r.hasta), 0), 2) AS comprado,
           round(coalesce(sum(fa.total) FILTER (WHERE fa.fecha BETWEEN r.ant_desde AND r.ant_hasta), 0), 2) AS comprado_ant,
           count(fa.id) FILTER (WHERE fa.fecha BETWEEN r.desde AND r.hasta) AS facturas,
           max(fa.fecha) AS ultima_compra,
           CASE WHEN count(DISTINCT fa.fecha) > 1 THEN round((max(fa.fecha) - min(fa.fecha))::numeric / (count(DISTINCT fa.fecha) - 1), 1) END AS cada_dias
    FROM cl LEFT JOIN fa ON fa.cliente_id = cl.id
    GROUP BY cl.id, cl.nombre
  ),
  -- M4: lo que debe frente a lo que paga en un mes normal (últimos 90 días)
  riesgo AS (
    SELECT n.cliente_id, n.nombre, n.deuda, n.vencido, n.letra,
           round(coalesce((SELECT sum(a.monto) FROM abo a WHERE a.cliente_id = n.cliente_id AND NOT a.es_descuento AND a.fecha > r.hoy - 90), 0) / 3, 2) AS paga_mes,
           round(coalesce((SELECT sum(f.total) FROM fa f WHERE f.cliente_id = n.cliente_id AND f.fecha > r.hoy - 90), 0) / 3, 2) AS compra_mes
    FROM nota4 n WHERE n.deuda > 0.01
  ),
  -- M5: precio de cada producto por cliente, últimos 180 días
  pl AS (
    SELECT cliente_id, coalesce(producto_id::text, lower(trim(descripcion))) AS prod, max(descripcion) AS descripcion,
           sum(cantidad) AS cant, sum(monto) AS monto
    FROM lin WHERE fecha > r.hoy - 180 AND cantidad > 0 AND monto > 0
    GROUP BY 1, 2
  ),
  prod AS (
    SELECT prod, max(descripcion) AS descripcion, sum(cant) AS cant, round(sum(monto), 2) AS monto,
           sum(monto) / sum(cant) AS precio_prom, count(DISTINCT cliente_id) AS clientes
    FROM pl GROUP BY prod HAVING count(DISTINCT cliente_id) >= 2
  ),
  precio_cli AS (
    SELECT pl.*, pl.monto / pl.cant AS precio, k.nombre FROM pl JOIN prod p ON p.prod = pl.prod JOIN cl k ON k.id = pl.cliente_id
  ),
  -- M6: facturado de cada mes de los últimos 6, por cliente
  meses6 AS (SELECT gs::date AS mes FROM generate_series(date_trunc('month', r.hoy) - interval '5 months', date_trunc('month', r.hoy), interval '1 month') AS gs),
  top_cli AS (
    SELECT fa.cliente_id, sum(fa.total) AS total FROM fa WHERE fa.fecha >= (SELECT min(mes) FROM meses6)
    GROUP BY 1 ORDER BY 2 DESC LIMIT 8
  ),
  -- M7: pedidos que anota la caja
  ped AS (SELECT p.*, k.nombre FROM may_pedidos_caja p LEFT JOIN cl k ON k.id = p.cliente_id WHERE p.deleted_at IS NULL)
  SELECT jsonb_build_object(
    'hoy', r.hoy,
    'notas', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', n.nombre, 'telefono', n.telefono, 'letra', n.letra, 'puntaje', n.puntaje,
                         'evaluadas', n.evaluadas, 'a_tiempo', n.a_tiempo, 'pagadas', n.pagadas, 'atraso_prom_tarde', n.atraso_prom_tarde,
                         'deuda', n.deuda, 'vencido', n.vencido, 'dias_vencido', n.dias_vencido, 'dias_sin_abonar', n.dias_sin_abonar, 'no_vender', n.no_vender)
                         ORDER BY strpos('ABCDEN', n.letra), n.puntaje DESC NULLS LAST, n.deuda DESC)
                       FROM nota4 n WHERE n.evaluadas > 0 OR n.deuda > 0.01), '[]'::jsonb),
    'calendario', (SELECT jsonb_agg(jsonb_build_object('etiqueta', s.etiqueta, 'desde', s.d1, 'hasta', s.d2, 'facturas', coalesce(x.n, 0), 'saldo', coalesce(x.saldo, 0),
                         'clientes', coalesce(x.clientes, 0), 'quienes', coalesce(x.quienes, '')) ORDER BY s.i)
                   FROM (SELECT -1 AS i, 'Ya vencidas' AS etiqueta, NULL::date AS d1, r.hoy - 1 AS d2
                         UNION ALL SELECT w, CASE w WHEN 0 THEN 'Esta semana' WHEN 1 THEN 'La próxima semana' ELSE 'En ' || w || ' semanas' END,
                                          r.hoy + 7 * w, r.hoy + 7 * w + 6 FROM generate_series(0, 7) AS w
                         UNION ALL SELECT 99, 'Más adelante', r.hoy + 56, NULL) s
                   LEFT JOIN LATERAL (
                     SELECT count(*) AS n, round(sum(f.saldo), 2) AS saldo, count(DISTINCT f.cliente_id) AS clientes,
                            array_to_string((array_agg(DISTINCT k.nombre))[1:4], ', ') AS quienes
                     FROM fa f JOIN cl k ON k.id = f.cliente_id
                     WHERE f.saldo > 0.01 AND (s.d1 IS NULL OR f.fecha_vencimiento >= s.d1) AND (s.d2 IS NULL OR f.fecha_vencimiento <= s.d2)) x ON true),
    'compras', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', c.nombre, 'comprado', c.comprado, 'comprado_ant', c.comprado_ant,
                           'cambio_pct', CASE WHEN c.comprado_ant > 0 THEN round(100.0 * (c.comprado - c.comprado_ant) / c.comprado_ant, 1) END,
                           'facturas', c.facturas, 'cada_dias', c.cada_dias, 'ultima_compra', c.ultima_compra, 'dias_sin_comprar', r.hoy - c.ultima_compra,
                           'atrasado', c.cada_dias IS NOT NULL AND r.hoy - c.ultima_compra > 1.5 * c.cada_dias)
                           ORDER BY (c.comprado - c.comprado_ant), c.comprado_ant DESC)
                         FROM compras c WHERE c.comprado > 0 OR c.comprado_ant > 0 OR c.ultima_compra IS NOT NULL), '[]'::jsonb),
    'riesgo', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', x.nombre, 'letra', x.letra, 'deuda', x.deuda, 'vencido', x.vencido,
                          'paga_mes', x.paga_mes, 'compra_mes', x.compra_mes,
                          'meses_saldar', CASE WHEN x.paga_mes > 0 THEN round(x.deuda / x.paga_mes, 1) END,
                          'pct_deuda', round(100.0 * x.deuda / nullif((SELECT sum(deuda) FROM riesgo), 0), 1))
                          ORDER BY (x.paga_mes > 0), CASE WHEN x.paga_mes > 0 THEN x.deuda / x.paga_mes END DESC, x.deuda DESC)
                        FROM riesgo x), '[]'::jsonb),
    'precios', coalesce((SELECT jsonb_agg(z ORDER BY (z->>'monto')::numeric DESC) FROM (
                  SELECT jsonb_build_object('producto', p.descripcion, 'clientes', p.clientes, 'unidades', p.cant, 'monto', p.monto,
                           'precio_prom', round(p.precio_prom, 2),
                           'min', (SELECT round(min(c.precio), 2) FROM precio_cli c WHERE c.prod = p.prod),
                           'min_cliente', (SELECT c.nombre FROM precio_cli c WHERE c.prod = p.prod ORDER BY c.precio, c.cant DESC LIMIT 1),
                           'max', (SELECT round(max(c.precio), 2) FROM precio_cli c WHERE c.prod = p.prod),
                           'max_cliente', (SELECT c.nombre FROM precio_cli c WHERE c.prod = p.prod ORDER BY c.precio DESC, c.cant DESC LIMIT 1)) AS z
                  FROM prod p ORDER BY p.monto DESC LIMIT 60) q), '[]'::jsonb),
    'precio_cliente', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', y.nombre, 'productos', y.productos, 'unidades', y.unidades, 'monto', y.monto,
                         'pct', y.pct) ORDER BY y.pct)
                       FROM (SELECT c.nombre, count(*) AS productos, sum(c.cant) AS unidades, round(sum(c.monto), 2) AS monto,
                                    round(100.0 * (sum(c.monto) / nullif(sum(c.cant * p.precio_prom), 0) - 1), 1) AS pct
                             FROM precio_cli c JOIN prod p ON p.prod = c.prod GROUP BY c.cliente_id, c.nombre) y), '[]'::jsonb),
    'crecimiento', jsonb_build_object(
      'meses', (SELECT jsonb_agg(mes ORDER BY mes) FROM meses6),
      'clientes', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', k.nombre, 'total', round(t.total, 2),
                     'valores', (SELECT jsonb_agg(coalesce((SELECT round(sum(f.total), 2) FROM fa f WHERE f.cliente_id = t.cliente_id
                                   AND date_trunc('month', f.fecha) = m.mes), 0) ORDER BY m.mes) FROM meses6 m)) ORDER BY t.total DESC)
                   FROM top_cli t JOIN cl k ON k.id = t.cliente_id), '[]'::jsonb)),
    'caja', jsonb_build_object(
      'pendientes', (SELECT count(*) FROM ped WHERE estado = 'pendiente'),
      'facturados', (SELECT count(*) FROM ped WHERE estado = 'facturado'),
      'descartados', (SELECT count(*) FROM ped WHERE estado = 'descartado'),
      'horas_facturar', (SELECT round(avg(extract(epoch FROM (atendido_en - creado_en)) / 3600)::numeric, 1) FROM ped WHERE estado = 'facturado' AND atendido_en IS NOT NULL),
      'en_periodo', (SELECT count(*) FROM ped WHERE (creado_en AT TIME ZONE 'America/Caracas')::date BETWEEN r.desde AND r.hasta),
      'lista_pendientes', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', nombre, 'creado', (creado_en AT TIME ZONE 'America/Caracas')::date,
                             'horas', round((extract(epoch FROM (now() - creado_en)) / 3600)::numeric, 0),
                             'renglones', jsonb_array_length(coalesce(items, '[]'::jsonb)), 'notas', notas) ORDER BY creado_en)
                           FROM ped WHERE estado = 'pendiente'), '[]'::jsonb))
  ) INTO v;

  RETURN v;
END $function$;
REVOKE ALL ON FUNCTION public.est_mayorista_mas(date, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_mayorista_mas(date, date, date, date) TO authenticated;
