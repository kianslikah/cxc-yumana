-- Estadísticas de Créditos y apartados: métricas nuevas pedidas por Kinan el 2026-10-31 (pendiente 16(e) de CLAUDE.md).
-- Copia de referencia de lo que vive en la base. Solo leen, salvo est_guardar_meta (escribe en est_metas).
-- Usan las mismas funciones de origen que el resto de Estadísticas (est_cuentas_detal, est_detal_abonos,
-- est_detal_intereses, cli_calificacion_base), así los números cuadran con las demás secciones.
--
-- est_detal_mas(período)     C1 lo que viene, C2 cumplimiento del período, C3 morosidad mes a mes, C4 cómo pagó cada mes
--                            de venta, C5 vendedores, C6 y C7 (resumen), C8 cobrado según el atraso, C9 metas del mes.
-- est_detal_volver()         C6 lista: a quién volver a venderle (A y B sin nada vencido, con lo que pueden sacar).
-- est_detal_no_volvieron()   C7 lista: terminaron de pagar hace más de 60 días y no han vuelto a comprar.
-- est_metas + est_guardar_meta(mes, venta, cobro): C9 metas que pone Kinan.

-- ---------------------------------------------------------------------------------------------------------------
-- C9: metas del mes. Se escriben solo con est_guardar_meta; se leen desde est_detal_mas.
CREATE TABLE IF NOT EXISTS public.est_metas (
  mes date PRIMARY KEY CHECK (mes = date_trunc('month', mes)::date),
  meta_venta numeric(12,2) CHECK (meta_venta IS NULL OR meta_venta >= 0),
  meta_cobro numeric(12,2) CHECK (meta_cobro IS NULL OR meta_cobro >= 0),
  actualizado_por uuid,
  actualizado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.est_metas ENABLE ROW LEVEL SECURITY;
CREATE POLICY solo_estadisticas ON public.est_metas FOR SELECT TO authenticated USING (public.est_puede_ver());
REVOKE ALL ON public.est_metas FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.est_metas FROM authenticated;
GRANT SELECT ON public.est_metas TO authenticated;

CREATE OR REPLACE FUNCTION public.est_guardar_meta(p_mes date, p_venta numeric, p_cobro numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_mes date;
  v jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  IF p_mes IS NULL THEN RAISE EXCEPTION 'Falta el mes de la meta'; END IF;
  IF coalesce(p_venta, 0) < 0 OR coalesce(p_cobro, 0) < 0 THEN RAISE EXCEPTION 'La meta no puede ser negativa'; END IF;
  v_mes := date_trunc('month', p_mes)::date;
  INSERT INTO est_metas (mes, meta_venta, meta_cobro, actualizado_por, actualizado_en)
  VALUES (v_mes, round(p_venta, 2), round(p_cobro, 2), auth.uid(), now())
  ON CONFLICT (mes) DO UPDATE SET meta_venta = excluded.meta_venta, meta_cobro = excluded.meta_cobro,
                                  actualizado_por = excluded.actualizado_por, actualizado_en = excluded.actualizado_en
  RETURNING to_jsonb(est_metas.*) INTO v;
  RETURN v;
END $function$;
REVOKE ALL ON FUNCTION public.est_guardar_meta(date, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_guardar_meta(date, numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.est_detal_mas(p_desde date, p_hasta date, p_ant_desde date, p_ant_hasta date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  g int := (public.cli_reglas_calificacion()->>'gracia_dias')::int;  -- la misma gracia de la calificación
  v jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT * INTO r FROM public.est_rango(p_desde, p_hasta, p_ant_desde, p_ant_hasta);

  WITH
  cu AS (SELECT * FROM public.est_cuentas_detal() WHERE vendible),
  ab AS (SELECT * FROM public.est_detal_abonos()),
  ia AS (SELECT * FROM public.est_detal_intereses() WHERE vendible),
  cal AS (SELECT * FROM public.cli_calificacion_base()),
  -- C2: cuentas cuya fecha límite cayó en un rango (hasta hoy): cuántas se pagaron a tiempo, tarde o siguen debiendo
  cumpl AS (
    SELECT x.cual,
           count(*) AS n, round(coalesce(sum(cu.total), 0), 2) AS monto,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado <= cu.fecha_limite + g) AS a_tiempo,
           round(coalesce(sum(cu.total) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado <= cu.fecha_limite + g), 0), 2) AS a_tiempo_monto,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado > cu.fecha_limite + g) AS tarde,
           count(*) FILTER (WHERE cu.viva) AS deben,
           round(coalesce(sum(cu.saldo) FILTER (WHERE cu.viva), 0), 2) AS deben_saldo
    FROM (VALUES ('act', r.desde, least(r.hasta, r.hoy)), ('ant', r.ant_desde, least(r.ant_hasta, r.hoy))) AS x(cual, d, h)
    JOIN cu ON cu.fecha_limite BETWEEN x.d AND x.h
    GROUP BY x.cual
  ),
  -- C3: saldo de cada cuenta al cierre de cada mes (suben la venta y los intereses, bajan los abonos)
  meses AS (
    SELECT gs::date AS mes, least((gs + interval '1 month - 1 day')::date, r.hoy) AS fin
    FROM generate_series(greatest(date_trunc('month', (SELECT min(fecha_inicio) FROM cu)), date_trunc('month', r.hoy) - interval '11 months'),
                         date_trunc('month', r.hoy), interval '1 month') AS gs
  ),
  -- Cada movimiento cae en el mes de su fecha (nunca antes del mes en que empezó la cuenta ni antes del primer mes de la serie;
  -- un interés o abono con fecha futura cae en el mes en curso, así el último mes cuadra con la cartera de hoy)
  mov AS (
    SELECT cu.id AS cuenta, cu.fecha_inicio AS inicio, cu.fecha_inicio AS fecha, cu.subtotal AS m FROM cu
    UNION ALL SELECT ia.cuenta_id, cu.fecha_inicio, ia.fecha, ia.monto FROM ia JOIN cu ON cu.id = ia.cuenta_id
    UNION ALL SELECT ab.cuenta_id, cu.fecha_inicio, ab.fecha, -ab.monto FROM ab JOIN cu ON cu.id = ab.cuenta_id
  ),
  mov_mes AS (
    SELECT mv.cuenta, least(greatest(date_trunc('month', mv.fecha), date_trunc('month', mv.inicio), (SELECT min(mes) FROM meses)),
                            (SELECT max(mes) FROM meses))::date AS mes, sum(mv.m) AS m  -- lo fechado en el futuro cuenta en el mes en curso
    FROM mov mv
    GROUP BY 1, 2
  ),
  -- Saldo de cada cuenta al cierre de cada mes = sus movimientos acumulados hasta ese mes
  saldo_mes AS (
    SELECT mm.mes, mm.fin, cu.fecha_limite, cu.tipo,
           sum(coalesce(x.m, 0)) OVER (PARTITION BY cu.id ORDER BY mm.mes) AS saldo
    FROM meses mm
    JOIN cu ON greatest(date_trunc('month', cu.fecha_inicio), (SELECT min(mes) FROM meses)) <= mm.mes
    LEFT JOIN mov_mes x ON x.cuenta = cu.id AND x.mes = mm.mes
  ),
  morosidad AS (
    SELECT mes, fin,
           round(coalesce(sum(saldo) FILTER (WHERE saldo > 0.01), 0), 2) AS deuda,
           round(coalesce(sum(saldo) FILTER (WHERE saldo > 0.01 AND fecha_limite < fin), 0), 2) AS vencido,
           round(coalesce(sum(saldo) FILTER (WHERE saldo > 0.01 AND fecha_limite < fin - 60), 0), 2) AS vencido_60,
           round(coalesce(sum(saldo) FILTER (WHERE saldo > 0.01 AND tipo = 'credito' AND fecha_limite < fin), 0), 2) AS vencido_cr
    FROM saldo_mes
    GROUP BY mes, fin
  ),
  -- C4: créditos agrupados por el mes en que se vendieron
  cosecha AS (
    SELECT date_trunc('month', cu.fecha_inicio)::date AS mes,
           count(*) AS n, round(sum(cu.subtotal), 2) AS vendido,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado <= cu.fecha_limite + g) AS a_tiempo,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado > cu.fecha_limite + g) AS tarde,
           count(*) FILTER (WHERE cu.viva AND cu.fecha_limite + g >= r.hoy) AS al_dia,
           count(*) FILTER (WHERE cu.viva AND cu.fecha_limite + g < r.hoy) AS vencidas,
           round(coalesce(sum(cu.saldo) FILTER (WHERE cu.viva), 0), 2) AS debe,
           round(coalesce(sum(cu.saldo) FILTER (WHERE cu.viva AND cu.fecha_limite + g < r.hoy), 0), 2) AS debe_vencido,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM ia WHERE ia.cuenta_id = cu.id AND ia.monto > 0)) AS con_interes
    FROM cu
    WHERE cu.tipo = 'credito'
    GROUP BY 1
  ),
  -- C5: cada vendedor (los créditos llevan vendedor; los apartados no)
  vend AS (
    SELECT cu.vendedor_id,
           count(*) FILTER (WHERE cu.fecha_inicio BETWEEN r.desde AND r.hasta) AS creditos_periodo,
           round(coalesce(sum(cu.subtotal) FILTER (WHERE cu.fecha_inicio BETWEEN r.desde AND r.hasta), 0), 2) AS vendido_periodo,
           round(coalesce(sum(cu.saldo) FILTER (WHERE cu.viva), 0), 2) AS cartera,
           round(coalesce(sum(cu.saldo) FILTER (WHERE cu.viva AND cu.fecha_limite < r.hoy), 0), 2) AS vencido,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL) AS terminados,
           count(*) FILTER (WHERE cu.fecha_completado IS NOT NULL AND cu.fecha_completado <= cu.fecha_limite + g) AS a_tiempo,
           count(DISTINCT cu.cliente_id) AS clientes
    FROM cu
    WHERE cu.tipo = 'credito'
    GROUP BY cu.vendedor_id
  ),
  vend_letras AS (
    SELECT x.vendedor_id, jsonb_object_agg(x.letra, x.n) AS letras
    FROM (SELECT v.vendedor_id, c.letra, count(*) AS n
          FROM (SELECT DISTINCT vendedor_id, cliente_id FROM cu WHERE tipo = 'credito') v
          JOIN cal c ON c.cliente_id = v.cliente_id
          GROUP BY 1, 2) x
    GROUP BY x.vendedor_id
  ),
  -- C8: lo cobrado en el período según cuánto atraso tenía la cuenta el día del pago
  atraso_pago AS (
    SELECT CASE WHEN ab.fecha <= cu.fecha_limite THEN 0
                WHEN ab.fecha - cu.fecha_limite <= 30 THEN 1
                WHEN ab.fecha - cu.fecha_limite <= 60 THEN 2
                WHEN ab.fecha - cu.fecha_limite <= 90 THEN 3
                ELSE 4 END AS tramo,
           ab.monto, coalesce(ab.grupo_pago, ab.id) AS pago, cu.cliente_id
    FROM ab JOIN cu ON cu.id = ab.cuenta_id
    WHERE ab.fecha BETWEEN r.desde AND r.hasta
  ),
  -- C9: el mes en curso
  mes_hoy AS (SELECT date_trunc('month', r.hoy)::date AS m)
  SELECT jsonb_build_object(
    'hoy', r.hoy,
    -- C1
    'viene', jsonb_build_object(
      'vencido', (SELECT round(coalesce(sum(saldo), 0), 2) FROM cu WHERE viva AND fecha_limite < r.hoy),
      'vencido_n', (SELECT count(*) FROM cu WHERE viva AND fecha_limite < r.hoy),
      'tramos', (SELECT jsonb_agg(jsonb_build_object('etiqueta', t.etiqueta, 'n', coalesce(x.n, 0), 'saldo', coalesce(x.saldo, 0)) ORDER BY t.i)
                 FROM (VALUES (0, 'Vence en 7 días', 0, 7), (1, 'De 8 a 15 días', 8, 15), (2, 'De 16 a 30 días', 16, 30), (3, 'Más adelante', 31, 100000)) AS t(i, etiqueta, d1, d2)
                 LEFT JOIN LATERAL (SELECT count(*) AS n, round(sum(saldo), 2) AS saldo FROM cu
                                    WHERE viva AND fecha_limite - r.hoy BETWEEN t.d1 AND t.d2) x ON true),
      'lista', coalesce((SELECT jsonb_agg(to_jsonb(y) ORDER BY y.vence, y.saldo DESC) FROM (
                 SELECT k.nombre, k.telefono, cu.tipo, cu.numero, cu.fecha_limite AS vence, cu.fecha_limite - r.hoy AS faltan,
                        cu.saldo, c.letra
                 FROM cu JOIN clientes k ON k.id = cu.cliente_id LEFT JOIN cal c ON c.cliente_id = cu.cliente_id
                 WHERE cu.viva AND cu.fecha_limite BETWEEN r.hoy AND r.hoy + 30) y), '[]'::jsonb)),
    -- C2
    'cumplimiento', jsonb_build_object(
      'act', (SELECT to_jsonb(c) - 'cual' FROM cumpl c WHERE cual = 'act'),
      'ant', (SELECT to_jsonb(c) - 'cual' FROM cumpl c WHERE cual = 'ant'),
      'gracia', g),
    -- C3
    'morosidad', coalesce((SELECT jsonb_agg(jsonb_build_object('mes', mes, 'deuda', deuda, 'vencido', vencido, 'vencido_60', vencido_60,
                                  'vencido_cr', vencido_cr, 'pct', round(100.0 * vencido / nullif(deuda, 0), 1)) ORDER BY mes) FROM morosidad), '[]'::jsonb),
    -- C4
    'cosecha', coalesce((SELECT jsonb_agg(to_jsonb(c) || jsonb_build_object('pct_a_tiempo',
                         round(100.0 * c.a_tiempo / nullif(c.a_tiempo + c.tarde + c.vencidas, 0), 1)) ORDER BY c.mes) FROM cosecha c), '[]'::jsonb),
    -- C5
    'vendedores', coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'vendedor', coalesce(u.nombre, 'Sin vendedor'), 'creditos_periodo', v.creditos_periodo, 'vendido_periodo', v.vendido_periodo,
                     'cartera', v.cartera, 'vencido', v.vencido, 'pct_vencido', round(100.0 * v.vencido / nullif(v.cartera, 0), 1),
                     'terminados', v.terminados, 'pct_a_tiempo', round(100.0 * v.a_tiempo / nullif(v.terminados, 0), 1),
                     'clientes', v.clientes, 'letras', coalesce(vl.letras, '{}'::jsonb)) ORDER BY v.cartera DESC)
                   FROM vend v LEFT JOIN usuarios_app u ON u.id = v.vendedor_id LEFT JOIN vend_letras vl ON vl.vendedor_id IS NOT DISTINCT FROM v.vendedor_id), '[]'::jsonb),
    -- C6 y C7 (resumen; las listas completas salen de est_detal_volver y est_detal_no_volvieron)
    'volver', (SELECT jsonb_build_object('n', count(*), 'puede_sacar', round(coalesce(sum(disponible), 0), 2))
               FROM cal WHERE letra IN ('A', 'B') AND vencido <= 0.01 AND disponible > 0),
    'no_volvieron', (SELECT jsonb_build_object('n', count(*), 'comprado', round(coalesce(sum(x.comprado), 0), 2))
                     FROM (SELECT cu.cliente_id, sum(cu.subtotal) AS comprado FROM cu GROUP BY cu.cliente_id
                           HAVING bool_and(NOT cu.viva) AND max(cu.fecha_completado) <= r.hoy - 60
                              AND max(cu.fecha_inicio) <= max(cu.fecha_completado)) x),
    -- C8
    'cobrado_atraso', jsonb_build_object(
      'total', (SELECT round(coalesce(sum(monto), 0), 2) FROM atraso_pago),
      'tramos', (SELECT jsonb_agg(jsonb_build_object('etiqueta', t.etiqueta, 'monto', coalesce(x.monto, 0), 'pagos', coalesce(x.pagos, 0), 'clientes', coalesce(x.clientes, 0)) ORDER BY t.i)
                 FROM (VALUES (0, 'Antes de vencer'), (1, 'Vencida hasta 30 días'), (2, 'Vencida 31 a 60 días'), (3, 'Vencida 61 a 90 días'), (4, 'Vencida más de 90 días')) AS t(i, etiqueta)
                 LEFT JOIN (SELECT tramo, round(sum(monto), 2) AS monto, count(DISTINCT pago) AS pagos, count(DISTINCT cliente_id) AS clientes
                            FROM atraso_pago GROUP BY tramo) x ON x.tramo = t.i)),
    -- C9
    'metas', (SELECT jsonb_build_object(
                'mes', mh.m, 'dias_mes', extract(day FROM (mh.m + interval '1 month - 1 day'))::int, 'dia', extract(day FROM r.hoy)::int,
                'meta_venta', em.meta_venta, 'meta_cobro', em.meta_cobro,
                'vendido', (SELECT round(coalesce(sum(subtotal), 0), 2) FROM cu WHERE fecha_inicio BETWEEN mh.m AND r.hoy),
                'cobrado', (SELECT round(coalesce(sum(monto), 0), 2) FROM ab WHERE fecha BETWEEN mh.m AND r.hoy))
              FROM mes_hoy mh LEFT JOIN est_metas em ON em.mes = mh.m)
  ) INTO v;

  RETURN v;
END $function$;
REVOKE ALL ON FUNCTION public.est_detal_mas(date, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_detal_mas(date, date, date, date) TO authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- C6: a quién volver a venderle. A y B, sin nada vencido y con algo que puede sacar. Del que más puede sacar al que menos.
CREATE OR REPLACE FUNCTION public.est_detal_volver()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.disponible DESC, x.puntaje DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT k.nombre, k.telefono, c.letra, c.puntaje, c.disponible, c.tope, c.deuda, c.cerradas,
           u.ultima_compra, public.est_hoy() - u.ultima_compra AS dias_sin_comprar
    FROM public.cli_calificacion_base() c
    JOIN clientes k ON k.id = c.cliente_id
    LEFT JOIN (SELECT cliente_id, max(fecha_inicio) AS ultima_compra FROM public.est_cuentas_detal() WHERE vendible GROUP BY cliente_id) u
           ON u.cliente_id = c.cliente_id
    WHERE c.letra IN ('A', 'B') AND c.vencido <= 0.01 AND c.disponible > 0
  ) x;
  RETURN v;
END $function$;
REVOKE ALL ON FUNCTION public.est_detal_volver() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_detal_volver() TO authenticated;

-- C7: terminaron de pagar todo hace más de 60 días y no han vuelto a comprar. Los que más compraron primero.
CREATE OR REPLACE FUNCTION public.est_detal_no_volvieron()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
  v_hoy date := public.est_hoy();
BEGIN
  PERFORM public.est_exigir_acceso();
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.comprado DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT k.nombre, k.telefono, c.letra, y.compras, y.comprado, y.ultima_compra, y.termino, v_hoy - y.termino AS dias_sin_volver
    FROM (SELECT cliente_id, count(*) AS compras, round(sum(subtotal), 2) AS comprado,
                 max(fecha_inicio) AS ultima_compra, max(fecha_completado) AS termino
          FROM public.est_cuentas_detal() WHERE vendible
          GROUP BY cliente_id
          HAVING bool_and(NOT viva) AND max(fecha_completado) <= v_hoy - 60 AND max(fecha_inicio) <= max(fecha_completado)) y
    JOIN clientes k ON k.id = y.cliente_id AND k.deleted_at IS NULL
    LEFT JOIN public.cli_calificacion_base() c ON c.cliente_id = y.cliente_id
  ) x;
  RETURN v;
END $function$;
REVOKE ALL ON FUNCTION public.est_detal_no_volvieron() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_detal_no_volvieron() TO authenticated;
