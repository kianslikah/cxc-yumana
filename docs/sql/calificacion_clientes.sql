-- Calificación real de los clientes del detal y tope de crédito (pendiente 2 de CLAUDE.md).
-- Diseño y decisiones de Kinan: docs/plan_calificacion_clientes.md. Copia de referencia de lo que vive en la base.
-- Solo lee y califica: no cambia ningún monto.
--
-- cli_reglas_calificacion()  todas las reglas en un solo lugar (pesos, cortes, tope).
-- cli_calificacion_base()    función de origen: una fila por cliente con cuentas. La usan Créditos y Estadísticas.
-- cli_calificaciones()       lista corta para Créditos (letra, nota y tope de todos). Guardia es_staff().
-- cli_calificacion(cliente)  ficha completa de un cliente, con sus razones. Guardia es_staff().

CREATE OR REPLACE FUNCTION public.cli_reglas_calificacion()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    -- Puntualidad: cada cuenta cerrada, o abierta y vencida pasada la gracia, saca de 0 a 100
    'gracia_dias', 5,                     -- hasta 5 días después de la fecha límite todavía es "a tiempo" (100)
    'cerrada_tarde_puntos', jsonb_build_array(   -- cuenta terminada tarde SIN interés (Kinan toleró el atraso), según los días:
      jsonb_build_object('hasta', 15, 'puntos', 90),   -- nunca baja de 40, porque pagó tarde, pero pagó
      jsonb_build_object('hasta', 30, 'puntos', 75),
      jsonb_build_object('hasta', 60, 'puntos', 55),
      jsonb_build_object('hasta', NULL, 'puntos', 40)),
    'cerrada_con_interes_max', 60,        -- terminada tarde y se le cobró interés: como máximo 60 ("regular", decisión 2 de Kinan)
    'abierta_vencida_puntos', jsonb_build_array( -- cuenta que sigue debiendo y ya pasó la gracia, según los días vencida
      jsonb_build_object('hasta', 15, 'puntos', 75),
      jsonb_build_object('hasta', 30, 'puntos', 55),
      jsonb_build_object('hasta', 60, 'puntos', 30),
      jsonb_build_object('hasta', 90, 'puntos', 10),
      jsonb_build_object('hasta', NULL, 'puntos', 0)),
    -- La historia del cliente (suma 100%)
    'peso_puntualidad', 0.70,
    'peso_intereses', 0.15,
    'peso_historial', 0.15,
    'interes_resta', 50,                  -- intereses: pierde 50 por cada interés cobrado por cuenta evaluada
    'perdonado_vale', 0.4,                -- un interés perdonado pesa 0,4 de uno cobrado
    'historial_puntos', jsonb_build_array(0, 40, 60, 75, 90, 100),  -- por cuentas terminadas: 0, 1, 2, 3, 4, 5 o más
    -- Lo de hoy solo resta (así, no deber nada hoy no regala puntos)
    'vencido_resta', jsonb_build_array(   -- según los días que lleva vencida su cuenta más atrasada
      jsonb_build_object('hasta', 15, 'resta', 3),
      jsonb_build_object('hasta', 30, 'resta', 6),
      jsonb_build_object('hasta', 60, 'resta', 12),
      jsonb_build_object('hasta', 90, 'resta', 20),
      jsonb_build_object('hasta', NULL, 'resta', 30)),
    'sin_abonar_resta', jsonb_build_array(0, 5, 10, 15),  -- según los días sin abonar, por los tramos de est_tramo_dias (30/60/90)
    -- Letras
    'corte_a', 85, 'corte_b', 70, 'corte_c', 50, 'corte_d', 30,
    'letra_max_por_cerradas', jsonb_build_array('C', 'B'),  -- sin cuentas terminadas, como máximo C; con 1, como máximo B
    'nombres', jsonb_build_object('A', 'Excelente', 'B', 'Bueno', 'C', 'Regular', 'D', 'Riesgoso', 'E', 'No darle crédito', 'N', 'Nuevo'),
    -- Tope: la cuenta más grande que ya terminó de pagar (sin intereses) × multiplicador, menos lo que debe hoy
    'tope_multiplica', jsonb_build_object('A', 1.5, 'B', 1.2, 'C', 1.0, 'D', 0.5, 'E', 0)
  );
$function$;

-- Busca en una lista de tramos [{hasta, <campo>}, ...] (el último con hasta = NULL) el valor que le toca a p_dias.
CREATE OR REPLACE FUNCTION public.cli_tramo(p_tramos jsonb, p_dias integer, p_campo text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT (x->>p_campo)::numeric
  FROM jsonb_array_elements(p_tramos) WITH ORDINALITY AS t(x, o)
  WHERE p_dias IS NOT NULL AND (x->>'hasta' IS NULL OR p_dias <= (x->>'hasta')::int)
  ORDER BY o
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.cli_calificacion_base()
RETURNS TABLE(
  cliente_id uuid, letra text, nombre_letra text, puntaje integer,
  historia numeric, resta_vencido integer, resta_sin_abonar integer,
  puntualidad numeric, pts_intereses numeric, pts_historial integer,
  evaluadas integer, a_tiempo integer, tarde integer, atraso_prom numeric, atraso_prom_tarde integer,
  cerradas integer, intereses_cobrados integer, intereses_perdonados integer,
  deuda numeric, deuda_cr numeric, deuda_ap numeric, vencido numeric, dias_vencido integer, dias_sin_pagar integer,
  pagado_total numeric, mayor_terminada numeric, cliente_desde date,
  nunca_pago_vencido boolean, letra_limitada boolean, disputado boolean, disputado_motivo text,
  tope numeric, disponible numeric, razones text[])
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH rg AS (
    SELECT j,
           (j->>'gracia_dias')::int AS gracia,
           (j->>'interes_resta')::numeric AS interes_resta,
           (j->>'perdonado_vale')::numeric AS perdonado_vale
    FROM (SELECT public.cli_reglas_calificacion() AS j) r
  ),
  hoy AS (SELECT public.est_hoy() AS d),
  ia AS (
    SELECT coalesce(credito_id, apartado_id) AS cuenta_id,
           count(*) FILTER (WHERE monto_interes > 0) AS cobrados,
           count(*) FILTER (WHERE coalesce(monto_interes, 0) = 0 AND notas ~* 'PERDONADO') AS perdonados
    FROM intereses_aplicados
    GROUP BY 1
  ),
  -- Cada cuenta vendible (sin anuladas, rechazadas, canceladas ni solicitudes) con sus días de atraso
  pc AS (
    SELECT cu.*, h.d AS hoy,
           (cu.fecha_completado IS NOT NULL) AS cerrada,
           (cu.viva AND cu.fecha_limite < h.d) AS vencida_hoy,
           CASE WHEN cu.fecha_completado IS NOT NULL THEN greatest(cu.fecha_completado - cu.fecha_limite, 0)
                WHEN cu.viva AND cu.fecha_limite < h.d THEN h.d - cu.fecha_limite
                ELSE 0 END AS dias,
           coalesce(ia.cobrados, 0) AS cobrados, coalesce(ia.perdonados, 0) AS perdonados
    FROM public.est_cuentas_detal() cu
    CROSS JOIN hoy h
    LEFT JOIN ia ON ia.cuenta_id = cu.id
    WHERE cu.vendible
  ),
  -- Se evalúa la cuenta terminada, o la que sigue debiendo y ya pasó la gracia
  ev AS (
    SELECT pc.*,
           (pc.cerrada OR (pc.vencida_hoy AND pc.dias > rg.gracia)) AS evaluada,
           (pc.cerrada AND pc.dias <= rg.gracia) AS a_tiempo,
           CASE WHEN pc.cerrada AND pc.dias <= rg.gracia THEN 100
                WHEN pc.cerrada AND pc.cobrados > 0 THEN least(public.cli_tramo(rg.j->'cerrada_tarde_puntos', pc.dias, 'puntos'), (rg.j->>'cerrada_con_interes_max')::numeric)
                WHEN pc.cerrada THEN public.cli_tramo(rg.j->'cerrada_tarde_puntos', pc.dias, 'puntos')
                WHEN pc.vencida_hoy AND pc.dias > rg.gracia THEN public.cli_tramo(rg.j->'abierta_vencida_puntos', pc.dias, 'puntos')
           END AS pts
    FROM pc CROSS JOIN rg
  ),
  ag AS (
    SELECT ev.cliente_id,
           count(*) FILTER (WHERE evaluada)::int AS evaluadas,
           count(*) FILTER (WHERE evaluada AND a_tiempo)::int AS a_tiempo,
           count(*) FILTER (WHERE evaluada AND NOT a_tiempo)::int AS tarde,
           round(avg(dias) FILTER (WHERE evaluada), 1) AS atraso_prom,
           round(avg(dias) FILTER (WHERE evaluada AND NOT a_tiempo))::int AS atraso_prom_tarde,
           round(avg(pts) FILTER (WHERE evaluada), 1) AS puntualidad,
           count(*) FILTER (WHERE cerrada)::int AS cerradas,
           sum(cobrados)::int AS intereses_cobrados,
           sum(perdonados)::int AS intereses_perdonados,
           round(coalesce(sum(saldo) FILTER (WHERE viva), 0), 2) AS deuda,
           round(coalesce(sum(saldo) FILTER (WHERE viva AND tipo = 'credito'), 0), 2) AS deuda_cr,
           round(coalesce(sum(saldo) FILTER (WHERE viva AND tipo = 'apartado'), 0), 2) AS deuda_ap,
           round(coalesce(sum(saldo) FILTER (WHERE vencida_hoy), 0), 2) AS vencido,
           max(dias) FILTER (WHERE vencida_hoy) AS dias_vencido,
           round(sum(pagado), 2) AS pagado_total,
           round(max(subtotal) FILTER (WHERE cerrada), 2) AS mayor_terminada,
           min(fecha_inicio) AS cliente_desde,
           (round(sum(pagado), 2) <= 0 AND bool_or(evaluada AND NOT cerrada)) AS nunca_pago_vencido  -- vencida pasada la gracia
    FROM ev
    GROUP BY ev.cliente_id
  ),
  pu AS (
    SELECT ag.*, cc.dias_sin_pagar, k.disputado, k.disputado_motivo, rg.j,
           CASE WHEN ag.evaluadas > 0 THEN round(
             (rg.j->>'peso_puntualidad')::numeric * ag.puntualidad
             + (rg.j->>'peso_intereses')::numeric * greatest(0, 100 - rg.interes_resta * (ag.intereses_cobrados + rg.perdonado_vale * ag.intereses_perdonados) / ag.evaluadas)
             + (rg.j->>'peso_historial')::numeric * (rg.j->'historial_puntos'->>least(ag.cerradas, jsonb_array_length(rg.j->'historial_puntos') - 1))::numeric, 1) END AS historia,
           round(greatest(0, 100 - rg.interes_resta * (ag.intereses_cobrados + rg.perdonado_vale * ag.intereses_perdonados) / greatest(ag.evaluadas, 1)), 1) AS pts_intereses,
           (rg.j->'historial_puntos'->>least(ag.cerradas, jsonb_array_length(rg.j->'historial_puntos') - 1))::int AS pts_historial,
           coalesce(public.cli_tramo(rg.j->'vencido_resta', ag.dias_vencido, 'resta'), 0)::int AS resta_vencido,
           CASE WHEN ag.deuda > 0.01 THEN coalesce((rg.j->'sin_abonar_resta'->>tr.indice)::int, 0) ELSE 0 END AS resta_sin_abonar
    FROM ag
    CROSS JOIN rg
    JOIN clientes k ON k.id = ag.cliente_id
    LEFT JOIN public.est_cobranza_clientes() cc ON cc.cliente_id = ag.cliente_id
    LEFT JOIN LATERAL public.est_tramo_dias(cc.dias_sin_pagar) tr ON true
  ),
  le AS (
    SELECT pu.*,
           CASE WHEN pu.evaluadas > 0 THEN greatest(0, round(pu.historia - pu.resta_vencido - pu.resta_sin_abonar))::int END AS puntaje
    FROM pu
  ),
  le2 AS (
    SELECT le.*,
           CASE WHEN le.puntaje IS NULL THEN NULL
                WHEN le.puntaje >= (le.j->>'corte_a')::int THEN 'A'
                WHEN le.puntaje >= (le.j->>'corte_b')::int THEN 'B'
                WHEN le.puntaje >= (le.j->>'corte_c')::int THEN 'C'
                WHEN le.puntaje >= (le.j->>'corte_d')::int THEN 'D'
                ELSE 'E' END AS letra_nota,
           le.j->'letra_max_por_cerradas'->>le.cerradas AS letra_max
    FROM le
  ),
  fin AS (
    SELECT le2.*,
           CASE WHEN le2.evaluadas = 0 THEN 'N'
                WHEN le2.nunca_pago_vencido THEN 'E'
                WHEN le2.letra_max IS NOT NULL AND strpos('ABCDE', le2.letra_max) > strpos('ABCDE', le2.letra_nota) THEN le2.letra_max
                ELSE le2.letra_nota END AS letra_final
    FROM le2
  ),
  tp AS (
    SELECT fin.*,
           CASE WHEN fin.letra_final = 'E' THEN 0
                WHEN fin.letra_final = 'N' OR fin.mayor_terminada IS NULL THEN NULL
                ELSE round(fin.mayor_terminada * (fin.j->'tope_multiplica'->>fin.letra_final)::numeric) END AS tope
    FROM fin
  )
  SELECT tp.cliente_id, tp.letra_final, tp.j->'nombres'->>tp.letra_final, tp.puntaje,
         tp.historia, tp.resta_vencido, tp.resta_sin_abonar,
         tp.puntualidad, tp.pts_intereses, tp.pts_historial,
         tp.evaluadas, tp.a_tiempo, tp.tarde, tp.atraso_prom, tp.atraso_prom_tarde,
         tp.cerradas, tp.intereses_cobrados, tp.intereses_perdonados,
         tp.deuda, tp.deuda_cr, tp.deuda_ap, tp.vencido, tp.dias_vencido, tp.dias_sin_pagar,
         tp.pagado_total, tp.mayor_terminada, tp.cliente_desde,
         tp.nunca_pago_vencido,
         (tp.evaluadas > 0 AND NOT tp.nunca_pago_vencido AND tp.letra_final <> tp.letra_nota),
         coalesce(tp.disputado, false), tp.disputado_motivo,
         tp.tope,
         CASE WHEN tp.tope IS NOT NULL THEN greatest(0, round(tp.tope - tp.deuda)) END,
         -- Razones: de la más importante a la menos; la app muestra las primeras 4
         array_remove(ARRAY[
           CASE WHEN tp.disputado THEN 'Cliente en disputa' || coalesce(': ' || nullif(trim(tp.disputado_motivo), ''), '') END,
           CASE WHEN tp.nunca_pago_vencido THEN 'Nunca ha pagado nada y tiene una cuenta vencida' END,
           CASE WHEN tp.evaluadas = 0 THEN 'Cliente nuevo: todavía no tiene cuentas terminadas ni vencidas' END,
           CASE WHEN tp.evaluadas = 0 THEN NULL
                WHEN tp.tarde = 0 THEN CASE WHEN tp.evaluadas = 1 THEN 'Pagó a tiempo su cuenta' ELSE 'Pagó a tiempo sus ' || tp.evaluadas || ' cuentas' END
                WHEN tp.a_tiempo = 0 THEN CASE WHEN tp.evaluadas = 1 THEN 'No pagó a tiempo su cuenta: ' || tp.atraso_prom_tarde || ' días de atraso'
                     ELSE 'No pagó a tiempo ninguna de sus ' || tp.evaluadas || ' cuentas: ' || tp.atraso_prom_tarde || ' días de atraso en promedio' END
                ELSE 'Pagó a tiempo ' || tp.a_tiempo || ' de ' || tp.evaluadas || ' cuentas; '
                     || CASE WHEN tp.tarde = 1 THEN 'la otra, con ' || tp.atraso_prom_tarde || ' días de atraso'
                             ELSE 'las otras, con ' || tp.atraso_prom_tarde || ' días de atraso en promedio' END END,
           CASE WHEN tp.vencido > 0.01 THEN 'Tiene $' || to_char(tp.vencido, 'FM999,999,990.00') || ' vencidos hace ' || tp.dias_vencido
                     || CASE WHEN tp.dias_vencido = 1 THEN ' día' ELSE ' días' END
                WHEN tp.deuda > 0.01 THEN 'Al día: debe $' || to_char(tp.deuda, 'FM999,999,990.00') || ' y no tiene nada vencido' END,
           CASE WHEN tp.deuda > 0.01 AND tp.resta_sin_abonar > 0 THEN 'Lleva ' || tp.dias_sin_pagar || ' días sin abonar' END,
           CASE WHEN tp.intereses_cobrados > 0 THEN 'Se le cobró interés por atraso ' || tp.intereses_cobrados
                     || CASE WHEN tp.intereses_cobrados = 1 THEN ' vez' ELSE ' veces' END
                     || CASE WHEN tp.intereses_perdonados > 0 THEN ' (y se le perdonó ' || tp.intereses_perdonados || ')' ELSE '' END
                WHEN tp.intereses_perdonados > 0 THEN 'Se le perdonó interés ' || tp.intereses_perdonados
                     || CASE WHEN tp.intereses_perdonados = 1 THEN ' vez' ELSE ' veces' END END,
           CASE WHEN tp.evaluadas > 0 AND NOT tp.nunca_pago_vencido AND tp.letra_final <> tp.letra_nota THEN
                  CASE WHEN tp.cerradas = 0 THEN 'Todavía no ha terminado de pagar ninguna cuenta: como máximo ' || tp.letra_final
                       ELSE 'Solo ha terminado 1 cuenta: como máximo ' || tp.letra_final END
                WHEN tp.cerradas > 0 THEN 'Ha terminado de pagar ' || tp.cerradas || CASE WHEN tp.cerradas = 1 THEN ' cuenta' ELSE ' cuentas' END
                     || ' (la más grande, $' || to_char(tp.mayor_terminada, 'FM999,999,990.00') || ')' END
         ], NULL)
  FROM tp;
$function$;

REVOKE EXECUTE ON FUNCTION public.cli_reglas_calificacion() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cli_tramo(jsonb, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cli_calificacion_base() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Lo que llama la app de Créditos (personal activo: es_staff()). El conector de la base no pasa la guardia.

-- Lista corta de todos los clientes con cuentas: [id, letra, nota, tope, disponible] + los nombres de las letras.
CREATE OR REPLACE FUNCTION public.cli_calificaciones()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
BEGIN
  IF NOT public.es_staff() THEN RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501'; END IF;
  SELECT jsonb_build_object(
           'nombres', public.cli_reglas_calificacion()->'nombres',
           'clientes', coalesce(jsonb_agg(jsonb_build_array(c.cliente_id, c.letra, c.puntaje, c.tope, c.disponible)), '[]'::jsonb))
    INTO v
    FROM public.cli_calificacion_base() c;
  RETURN v;
END $function$;

-- Ficha completa de un cliente (nota, razones, tope, deuda). Un cliente sin cuentas sale como N.
CREATE OR REPLACE FUNCTION public.cli_calificacion(p_cliente_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
  r jsonb := public.cli_reglas_calificacion();
BEGIN
  IF NOT public.es_staff() THEN RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501'; END IF;
  SELECT to_jsonb(c) INTO v FROM public.cli_calificacion_base() c WHERE c.cliente_id = p_cliente_id;
  IF v IS NULL THEN
    v := jsonb_build_object('cliente_id', p_cliente_id, 'letra', 'N', 'nombre_letra', r->'nombres'->>'N',
           'puntaje', NULL, 'tope', NULL, 'disponible', NULL, 'deuda', 0, 'vencido', 0, 'evaluadas', 0, 'cerradas', 0,
           'razones', jsonb_build_array('Cliente nuevo: todavía no tiene créditos ni apartados'));
  END IF;
  RETURN v || jsonb_build_object('tope_multiplica', r->'tope_multiplica');
END $function$;

REVOKE ALL ON FUNCTION public.cli_calificaciones() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cli_calificacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cli_calificaciones() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cli_calificacion(uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Estadísticas usa la misma calificación desde el 2026-10-31 (antes tenía su propio puntaje: ver docs/sql/estadisticas.sql).
-- Se mantiene la forma de las columnas para no tocar est_detal ni est_detal_puntajes.
-- "ritmo" ya no es parte de la fórmula: lleva lo que resta por los días sin abonar (0 = no resta).
CREATE OR REPLACE FUNCTION public.est_puntaje_clientes()
 RETURNS TABLE(cliente_id uuid, evaluadas bigint, a_tiempo bigint, atraso_prom numeric, puntualidad numeric, ritmo integer, puntaje numeric, letra text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT cliente_id, evaluadas::bigint, a_tiempo::bigint, atraso_prom, puntualidad, resta_sin_abonar, puntaje::numeric, letra
  FROM public.cli_calificacion_base();
$function$;

CREATE OR REPLACE FUNCTION public.est_reglas_puntaje()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT public.cli_reglas_calificacion() || jsonb_build_object('min_cuentas_puntuales', 2);  -- para el top de más puntuales
$function$;

REVOKE EXECUTE ON FUNCTION public.est_puntaje_clientes() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.est_reglas_puntaje() FROM PUBLIC, anon, authenticated;
