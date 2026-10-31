-- Estadísticas del mayor: métricas nuevas pedidas por Kinan el 2026-10-31 (pendiente 16(e) de CLAUDE.md).
-- Copia de referencia de lo que vive en la base. Solo lee. Usa las funciones de origen del mayor (est_may_facturas,
-- est_may_abonos, est_may_lineas), las reglas de la calificación (cli_reglas_calificacion) y los parámetros de
-- est_parametros (en docs/sql/estadisticas_creditos_mas.sql), así cuadra con lo demás.
--
-- est_may_facturas_pagadas()  origen: cada factura con el día en que quedó pagada (abonos a lo más viejo primero).
-- est_mayorista_mas(período)  M1 nota de cada cliente, M2 calendario de cobros, M3 quién compra menos, M4 riesgo por
--                             cliente, M5 precio por cliente, M6 crecimiento por cliente, M7 pedidos de la caja.
--
-- Nota del mayor (M1): igual que la del detal (mismos tramos, gracia, cortes y letra máxima por cuentas terminadas),
-- sin el factor de intereses porque el mayor no cobra interés: puntualidad y facturas pagadas (mayor_peso_puntualidad
-- y mayor_peso_historial en cli_reglas_calificacion). Lo de hoy solo resta, como en el detal.
-- Pendiente (revisión del 2026-10-31): el algoritmo de la nota está escrito aquí y en cli_calificacion_base; pasarlo a
-- funciones compartidas, y que est_mayorista también use est_may_facturas_pagadas.

-- Origen: cada factura del mayor con el día en que quedó pagada. Los abonos (todos, también descuentos) se aplican a lo
-- más viejo primero, como may_recalcular_cliente: una factura queda pagada el día en que lo abonado acumulado cubre todo
-- lo facturado hasta ella. fecha_pago NULL = todavía no se cubre. (La misma regla está hoy en est_mayorista.)
CREATE OR REPLACE FUNCTION public.est_may_facturas_pagadas()
RETURNS TABLE(id uuid, numero integer, cliente_id uuid, fecha date, fecha_vencimiento date, origen text, total numeric, saldo numeric, fecha_pago date)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH fa AS (SELECT * FROM public.est_may_facturas()),
  fac_acum AS (SELECT fa.*, sum(fa.total) OVER (PARTITION BY fa.cliente_id ORDER BY fa.fecha, fa.numero) AS acum FROM fa),
  abo_dia AS (SELECT cliente_id, fecha, sum(sum(monto)) OVER (PARTITION BY cliente_id ORDER BY fecha) AS acum
              FROM public.est_may_abonos() GROUP BY cliente_id, fecha)
  SELECT f.id, f.numero, f.cliente_id, f.fecha, f.fecha_vencimiento, f.origen, f.total, f.saldo,
         (SELECT min(d.fecha) FROM abo_dia d WHERE d.cliente_id = f.cliente_id AND d.acum >= f.acum - 0.01)
  FROM fac_acum f;
$function$;
REVOKE EXECUTE ON FUNCTION public.est_may_facturas_pagadas() FROM PUBLIC, anon, authenticated;

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
  pa jsonb := public.est_parametros();
  g int;
  v jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);
  g := (j->>'gracia_dias')::int;

  WITH
  cl AS (SELECT * FROM may_clientes WHERE deleted_at IS NULL),
  fa AS (SELECT * FROM public.est_may_facturas_pagadas()),
  abo AS (SELECT * FROM public.est_may_abonos()),
  lin AS (SELECT * FROM public.est_may_lineas()),
  -- M1: cada factura con sus días de atraso y sus puntos (los mismos tramos del detal). Pagada = saldo en cero y con
  -- fecha de pago; si la base la da por pagada pero el reparto no la cubre, no se evalúa (como en est_mayorista).
  factura AS (
    SELECT f.*, (f.saldo <= 0.01) AS cerrada, (f.saldo > 0.01 AND f.fecha_vencimiento < r.hoy) AS vencida_hoy,
           CASE WHEN f.saldo <= 0.01 AND f.fecha_pago IS NOT NULL THEN greatest(f.fecha_pago - f.fecha_vencimiento, 0)
                WHEN f.saldo > 0.01 AND f.fecha_vencimiento < r.hoy THEN r.hoy - f.fecha_vencimiento ELSE 0 END AS dias
    FROM fa f
  ),
  factura_pts AS (
    SELECT e.*, ((e.cerrada AND e.fecha_pago IS NOT NULL) OR (e.vencida_hoy AND e.dias > g)) AS evaluada,
           (e.cerrada AND e.fecha_pago IS NOT NULL AND e.dias <= g) AS a_tiempo,
           CASE WHEN e.cerrada AND e.fecha_pago IS NOT NULL AND e.dias <= g THEN 100
                WHEN e.cerrada AND e.fecha_pago IS NOT NULL THEN public.cli_tramo(j->'cerrada_tarde_puntos', e.dias, 'puntos')
                WHEN e.vencida_hoy AND e.dias > g THEN public.cli_tramo(j->'abierta_vencida_puntos', e.dias, 'puntos') END AS pts
    FROM factura e
  ),
  por_cliente AS (
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
    FROM cl LEFT JOIN factura_pts x ON x.cliente_id = cl.id
    GROUP BY cl.id, cl.nombre, cl.telefono, cl.no_vender
  ),
  -- Días sin abonar como en el detal: desde el último abono o desde la factura viva más vieja, lo más reciente
  -- (quien pagó todo y vuelve a comprar arranca de cero)
  nota_historia AS (
    SELECT n.*,
           CASE WHEN n.deuda > 0.01 THEN r.hoy - greatest(n.ultimo_abono, n.inicio_viejo) END AS dias_sin_abonar,
           CASE WHEN n.evaluadas > 0 THEN round((j->>'mayor_peso_puntualidad')::numeric * n.puntualidad
                + (j->>'mayor_peso_historial')::numeric * (j->'historial_puntos'->>least(n.pagadas, jsonb_array_length(j->'historial_puntos') - 1))::numeric, 1) END AS historia,
           CASE WHEN n.dias_vencido > g THEN public.cli_tramo(j->'vencido_resta', n.dias_vencido, 'resta') ELSE 0 END AS resta_vencido
    FROM por_cliente n
  ),
  nota_puntaje AS (
    SELECT n.*,
           CASE WHEN n.evaluadas > 0 THEN greatest(0, round(n.historia - n.resta_vencido
                  - CASE WHEN n.deuda > 0.01 THEN coalesce(public.cli_tramo(j->'sin_abonar_resta', n.dias_sin_abonar, 'resta'), 0) ELSE 0 END))::int END AS puntaje
    FROM nota_historia n
  ),
  nota_letra AS (
    SELECT n.*,
           CASE WHEN n.evaluadas = 0 THEN 'N'
                WHEN coalesce(n.nunca_pago_vencido, false) THEN j->'cortes'->-1->>'letra'
                ELSE public.cli_peor_letra(j->'cortes', j->'letra_max_por_cerradas'->>n.pagadas,
                       (SELECT x->>'letra' FROM jsonb_array_elements(j->'cortes') WITH ORDINALITY AS t(x, o)
                         WHERE n.puntaje >= (x->>'desde')::numeric ORDER BY o LIMIT 1)) END AS letra
    FROM nota_puntaje n
  ),
  -- Orden de las letras según los cortes (N al final)
  orden_letra AS (SELECT x->>'letra' AS letra, o FROM jsonb_array_elements(j->'cortes') WITH ORDINALITY AS t(x, o)),
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
  -- M4: lo que debe frente a lo que paga en un mes normal (abonos de los últimos riesgo_dias)
  riesgo AS (
    SELECT n.cliente_id, n.nombre, n.deuda, n.vencido, n.letra,
           round(coalesce((SELECT sum(a.monto) FROM abo a WHERE a.cliente_id = n.cliente_id AND NOT a.es_descuento
                           AND a.fecha > r.hoy - (pa->>'riesgo_dias')::int), 0) / ((pa->>'riesgo_dias')::numeric / 30), 2) AS paga_mes,
           round(coalesce((SELECT sum(f.total) FROM fa f WHERE f.cliente_id = n.cliente_id
                           AND f.fecha > r.hoy - (pa->>'riesgo_dias')::int), 0) / ((pa->>'riesgo_dias')::numeric / 30), 2) AS compra_mes
    FROM nota_letra n WHERE n.deuda > 0.01
  ),
  -- M5: precio de cada producto del catálogo por cliente
  pl AS (
    SELECT cliente_id, 'p' || producto_id::text AS prod, max(descripcion) AS descripcion,
           sum(cantidad) AS cant, sum(monto) AS monto
    FROM lin
    WHERE fecha > r.hoy - (pa->>'precios_dias')::int AND cantidad > 0 AND monto > 0
      AND producto_id IS NOT NULL  -- solo productos del catálogo: los renglones sueltos (ej. "Saldo pendiente" de una carga inicial) no son precios
    GROUP BY 1, 2
  ),
  prod AS (
    SELECT prod, max(descripcion) AS descripcion, sum(cant) AS cant, round(sum(monto), 2) AS monto,
           sum(monto) / sum(cant) AS precio_prom, count(DISTINCT cliente_id) AS clientes
    FROM pl GROUP BY prod HAVING count(DISTINCT cliente_id) >= (pa->>'precios_min_clientes')::int
  ),
  precio_cli AS (
    SELECT pl.*, pl.monto / pl.cant AS precio, k.nombre,
           row_number() OVER (PARTITION BY pl.prod ORDER BY pl.monto / pl.cant, pl.cant DESC) AS n_barato,
           row_number() OVER (PARTITION BY pl.prod ORDER BY pl.monto / pl.cant DESC, pl.cant DESC) AS n_caro
    FROM pl JOIN prod p ON p.prod = pl.prod JOIN cl k ON k.id = pl.cliente_id
  ),
  -- M6: facturado de cada mes de los últimos crecimiento_meses, de los que más compraron
  meses_crec AS (
    SELECT gs::date AS mes FROM generate_series(date_trunc('month', r.hoy) - make_interval(months => (pa->>'crecimiento_meses')::int - 1),
                                                date_trunc('month', r.hoy), interval '1 month') AS gs
  ),
  top_cli AS (
    SELECT fa.cliente_id, sum(fa.total) AS total FROM fa WHERE fa.fecha >= (SELECT min(mes) FROM meses_crec)
    GROUP BY 1 ORDER BY 2 DESC LIMIT (pa->>'crecimiento_top')::int
  ),
  crec_mes AS (
    SELECT t.cliente_id, m.mes, coalesce(round(sum(f.total), 2), 0) AS total
    FROM top_cli t CROSS JOIN meses_crec m
    LEFT JOIN fa f ON f.cliente_id = t.cliente_id AND date_trunc('month', f.fecha) = m.mes
    GROUP BY 1, 2
  ),
  -- M2: semanas de vencimiento contando desde hoy (8 semanas, más lo ya vencido y lo de más adelante)
  semanas AS (
    SELECT -1 AS i, 'Ya vencidas'::text AS etiqueta, NULL::date AS d1, r.hoy - 1 AS d2
    UNION ALL SELECT w, CASE w WHEN 0 THEN 'Esta semana' WHEN 1 THEN 'La próxima semana' ELSE 'En ' || w || ' semanas' END,
                     r.hoy + 7 * w, r.hoy + 7 * w + 6 FROM generate_series(0, 7) AS w
    UNION ALL SELECT 99, 'Más adelante', r.hoy + 7 * 8, NULL
  ),
  -- M7: pedidos que anota la caja
  ped AS (SELECT p.*, k.nombre FROM may_pedidos_caja p LEFT JOIN cl k ON k.id = p.cliente_id WHERE p.deleted_at IS NULL)
  SELECT jsonb_build_object(
    'hoy', r.hoy,
    'parametros', pa,
    'reglas', jsonb_build_object('gracia_dias', g, 'peso_puntualidad', j->'mayor_peso_puntualidad', 'peso_historial', j->'mayor_peso_historial',
                                 'cortes', j->'cortes', 'nombres', j->'nombres'),
    'notas', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', n.nombre, 'telefono', n.telefono, 'letra', n.letra, 'puntaje', n.puntaje,
                         'evaluadas', n.evaluadas, 'a_tiempo', n.a_tiempo, 'pagadas', n.pagadas, 'atraso_prom_tarde', n.atraso_prom_tarde,
                         'deuda', n.deuda, 'vencido', n.vencido, 'dias_vencido', n.dias_vencido, 'dias_sin_abonar', n.dias_sin_abonar, 'no_vender', n.no_vender)
                         ORDER BY coalesce(ol.o, 99), n.puntaje DESC NULLS LAST, n.deuda DESC)
                       FROM nota_letra n LEFT JOIN orden_letra ol ON ol.letra = n.letra
                       WHERE n.evaluadas > 0 OR n.deuda > 0.01), '[]'::jsonb),
    'calendario', (SELECT jsonb_agg(jsonb_build_object('etiqueta', s.etiqueta, 'desde', s.d1, 'hasta', s.d2, 'facturas', coalesce(x.n, 0), 'saldo', coalesce(x.saldo, 0),
                         'clientes', coalesce(x.clientes, 0), 'quienes', coalesce(x.quienes, '')) ORDER BY s.i)
                   FROM semanas s
                   LEFT JOIN LATERAL (
                     SELECT sum(c.n)::int AS n, round(sum(c.saldo), 2) AS saldo, count(*) AS clientes,
                            (SELECT string_agg(z.nombre, ', ' ORDER BY z.saldo DESC) FROM (SELECT * FROM (SELECT k2.nombre, sum(f2.saldo) AS saldo
                               FROM fa f2 JOIN cl k2 ON k2.id = f2.cliente_id
                               WHERE f2.saldo > 0.01 AND (s.d1 IS NULL OR f2.fecha_vencimiento >= s.d1) AND (s.d2 IS NULL OR f2.fecha_vencimiento <= s.d2)
                               GROUP BY k2.nombre) q ORDER BY q.saldo DESC LIMIT 4) z) AS quienes
                     FROM (SELECT f.cliente_id, count(*) AS n, sum(f.saldo) AS saldo
                           FROM fa f JOIN cl k ON k.id = f.cliente_id
                           WHERE f.saldo > 0.01 AND (s.d1 IS NULL OR f.fecha_vencimiento >= s.d1) AND (s.d2 IS NULL OR f.fecha_vencimiento <= s.d2)
                           GROUP BY f.cliente_id) c) x ON true),
    'compras', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', c.nombre, 'comprado', c.comprado, 'comprado_ant', c.comprado_ant,
                           'cambio_pct', CASE WHEN c.comprado_ant > 0 THEN round(100.0 * (c.comprado - c.comprado_ant) / c.comprado_ant, 1) END,
                           'facturas', c.facturas, 'cada_dias', c.cada_dias, 'ultima_compra', c.ultima_compra, 'dias_sin_comprar', r.hoy - c.ultima_compra,
                           'atrasado', c.cada_dias IS NOT NULL AND r.hoy - c.ultima_compra > (pa->>'tarda_factor')::numeric * c.cada_dias)
                           ORDER BY (c.comprado - c.comprado_ant), c.comprado_ant DESC)
                         FROM compras c WHERE c.comprado > 0 OR c.comprado_ant > 0 OR c.ultima_compra IS NOT NULL), '[]'::jsonb),
    'riesgo', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', x.nombre, 'letra', x.letra, 'deuda', x.deuda, 'vencido', x.vencido,
                          'paga_mes', x.paga_mes, 'compra_mes', x.compra_mes,
                          'meses_saldar', CASE WHEN x.paga_mes > 0 THEN round(x.deuda / x.paga_mes, 1) END,
                          'pct_deuda', round(100.0 * x.deuda / nullif((SELECT sum(deuda) FROM riesgo), 0), 1))
                          ORDER BY (x.paga_mes > 0), CASE WHEN x.paga_mes > 0 THEN x.deuda / x.paga_mes END DESC, x.deuda DESC)
                        FROM riesgo x), '[]'::jsonb),
    'precios', coalesce((SELECT jsonb_agg(jsonb_build_object('producto', p.descripcion, 'clientes', p.clientes, 'unidades', p.cant, 'monto', p.monto,
                           'precio_prom', round(p.precio_prom, 2),
                           'min', round(b.precio, 2), 'min_cliente', b.nombre, 'max', round(c.precio, 2), 'max_cliente', c.nombre) ORDER BY p.monto DESC)
                         FROM (SELECT * FROM prod ORDER BY monto DESC LIMIT (pa->>'precios_top')::int) p
                         JOIN precio_cli b ON b.prod = p.prod AND b.n_barato = 1
                         JOIN precio_cli c ON c.prod = p.prod AND c.n_caro = 1), '[]'::jsonb),
    'precio_cliente', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', y.nombre, 'productos', y.productos, 'unidades', y.unidades, 'monto', y.monto,
                         'pct', y.pct) ORDER BY y.pct)
                       FROM (SELECT c.nombre, count(*) AS productos, sum(c.cant) AS unidades, round(sum(c.monto), 2) AS monto,
                                    round(100.0 * (sum(c.monto) / nullif(sum(c.cant * p.precio_prom), 0) - 1), 1) AS pct
                             FROM precio_cli c JOIN prod p ON p.prod = c.prod GROUP BY c.cliente_id, c.nombre) y), '[]'::jsonb),
    'crecimiento', jsonb_build_object(
      'meses', (SELECT jsonb_agg(mes ORDER BY mes) FROM meses_crec),
      'clientes', coalesce((SELECT jsonb_agg(jsonb_build_object('nombre', k.nombre, 'total', round(t.total, 2),
                     'valores', (SELECT jsonb_agg(cm.total ORDER BY cm.mes) FROM crec_mes cm WHERE cm.cliente_id = t.cliente_id)) ORDER BY t.total DESC)
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
