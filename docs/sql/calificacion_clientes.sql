-- Calificación real de los clientes del detal y tope de crédito (pendiente 2 de CLAUDE.md).
-- Diseño y decisiones de Kinan: docs/plan_calificacion_clientes.md. Copia de referencia de lo que vive en la base.
-- Solo lee y califica: no cambia ningún monto.
--
-- cli_reglas_calificacion()  todas las reglas en un solo lugar (pesos, tramos, letras, tope).
-- cli_tramo(), cli_peor_letra()  ayudantes para leer las reglas.
-- cli_calificacion_base()    función de origen: una fila por cliente activo (sin cuentas = N). La usan Créditos y Estadísticas.
-- cli_calificaciones()       lista corta para Créditos (letra, nota, tope, puede sacar, deuda y vencido de todos). Guardia es_staff().
-- cli_calificacion(cliente)  ficha completa de un cliente, con sus razones. Guardia es_staff().

CREATE OR REPLACE FUNCTION public.cli_reglas_calificacion()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  -- Todas las reglas de la calificación. Para ajustar una nota se cambia aquí (y la copia en docs/sql), sin tocar las apps.
  -- Los tramos son listas [{hasta, valor}] por días; el último lleva hasta = NULL. Se leen con cli_tramo().
  SELECT jsonb_build_object(
    -- Puntualidad: cada cuenta terminada, o viva y vencida pasada la gracia, saca de 0 a 100
    'gracia_dias', 5,                                -- hasta 5 días después de la fecha límite todavía es "a tiempo" (100)
    'cerrada_tarde_puntos', jsonb_build_array(       -- terminada tarde SIN interés (Kinan toleró el atraso): nunca baja de 40,
      jsonb_build_object('hasta', 15, 'puntos', 90), -- porque pagó tarde, pero pagó
      jsonb_build_object('hasta', 30, 'puntos', 75),
      jsonb_build_object('hasta', 60, 'puntos', 55),
      jsonb_build_object('hasta', NULL, 'puntos', 40)),
    'cerrada_con_interes_max', 60,                   -- terminada tarde y se le cobró interés: como máximo 60 ("tarde con interés = regular")
    'abierta_vencida_puntos', jsonb_build_array(     -- sigue debiendo y ya pasó la gracia
      jsonb_build_object('hasta', 15, 'puntos', 75),
      jsonb_build_object('hasta', 30, 'puntos', 55),
      jsonb_build_object('hasta', 60, 'puntos', 30),
      jsonb_build_object('hasta', 90, 'puntos', 10),
      jsonb_build_object('hasta', NULL, 'puntos', 0)),
    -- La historia del cliente (suma 100%)
    'peso_puntualidad', 0.70,
    'peso_intereses', 0.15,
    'peso_historial', 0.15,
    'interes_resta', 50,                             -- intereses: pierde 50 por cada interés cobrado por cuenta evaluada
    'perdonado_vale', 0.4,                           -- un interés perdonado pesa 0,4 de uno cobrado
    'historial_puntos', jsonb_build_array(0, 40, 60, 75, 90, 100),  -- por cuentas terminadas: 0, 1, 2, 3, 4, 5 o más
    -- Lo de hoy solo resta (así, no deber nada hoy no regala puntos)
    'vencido_resta', jsonb_build_array(              -- días que lleva vencida su cuenta más atrasada, pasada la gracia
      jsonb_build_object('hasta', 15, 'resta', 3),
      jsonb_build_object('hasta', 30, 'resta', 6),
      jsonb_build_object('hasta', 60, 'resta', 12),
      jsonb_build_object('hasta', 90, 'resta', 20),
      jsonb_build_object('hasta', NULL, 'resta', 30)),
    'sin_abonar_resta', jsonb_build_array(           -- días sin abonar, si debe algo
      jsonb_build_object('hasta', 30, 'resta', 0),
      jsonb_build_object('hasta', 60, 'resta', 5),
      jsonb_build_object('hasta', 90, 'resta', 10),
      jsonb_build_object('hasta', NULL, 'resta', 15)),
    -- Letras, de la mejor a la peor: la nota toma la primera cuyo "desde" alcanza. La última es la de "nunca pagó".
    'cortes', jsonb_build_array(
      jsonb_build_object('letra', 'A', 'desde', 85),
      jsonb_build_object('letra', 'B', 'desde', 70),
      jsonb_build_object('letra', 'C', 'desde', 50),
      jsonb_build_object('letra', 'D', 'desde', 30),
      jsonb_build_object('letra', 'E', 'desde', 0)),
    'letra_max_por_cerradas', jsonb_build_array('C', 'B'),  -- letra máxima con 0 cuentas terminadas, con 1, ...
    'nombres', jsonb_build_object('A', 'Excelente', 'B', 'Bueno', 'C', 'Regular', 'D', 'Riesgoso', 'E', 'No darle crédito', 'N', 'Nuevo'),
    -- Tope: la cuenta más grande que ya terminó de pagar (sin intereses) × multiplicador, menos lo que debe hoy.
    -- Multiplicador 0 = tope 0 aunque no haya terminado ninguna. N, o sin cuentas terminadas: sin tope (decide el admin).
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

-- La peor de dos letras según el orden de los cortes (una NULL no cuenta).
CREATE OR REPLACE FUNCTION public.cli_peor_letra(p_cortes jsonb, p_a text, p_b text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT x->>'letra'
  FROM jsonb_array_elements(p_cortes) WITH ORDINALITY AS t(x, o)
  WHERE x->>'letra' IN (p_a, p_b)
  ORDER BY o DESC
  LIMIT 1;
$function$;

-- Función de origen: una fila por cliente activo (sin cuentas = N). La usan Créditos y Estadísticas.
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
    SELECT (j->>'gracia_dias')::int AS gracia,
           j->'cerrada_tarde_puntos' AS cerrada_tarde_puntos,
           (j->>'cerrada_con_interes_max')::numeric AS con_interes_max,
           j->'abierta_vencida_puntos' AS abierta_vencida_puntos,
           (j->>'peso_puntualidad')::numeric AS peso_puntualidad,
           (j->>'peso_intereses')::numeric AS peso_intereses,
           (j->>'peso_historial')::numeric AS peso_historial,
           (j->>'interes_resta')::numeric AS interes_resta,
           (j->>'perdonado_vale')::numeric AS perdonado_vale,
           j->'historial_puntos' AS historial_puntos,
           j->'vencido_resta' AS vencido_resta,
           j->'sin_abonar_resta' AS sin_abonar_resta,
           j->'cortes' AS cortes,
           j->'letra_max_por_cerradas' AS letra_max_por_cerradas,
           j->'nombres' AS nombres,
           j->'tope_multiplica' AS tope_multiplica
    FROM (SELECT public.cli_reglas_calificacion() AS j) r
  ),
  hoy AS (SELECT public.est_hoy() AS d),
  -- Intereses por cuenta, con la misma regla de "perdonado" que Estadísticas (est_detal_intereses)
  intereses AS (
    SELECT cuenta_id, count(*) FILTER (WHERE monto > 0) AS cobrados, count(*) FILTER (WHERE perdonado) AS perdonados
    FROM public.est_detal_intereses()
    GROUP BY cuenta_id
  ),
  -- Cada cuenta vendible (sin anuladas, rechazadas, canceladas ni solicitudes) con sus días de atraso:
  -- la terminada, hasta el día en que terminó; la viva y vencida, hasta hoy
  cuenta AS (
    SELECT cu.cliente_id, cu.tipo, cu.saldo, cu.pagado, cu.subtotal, cu.fecha_inicio, cu.viva,
           (cu.fecha_completado IS NOT NULL) AS cerrada,
           (cu.viva AND cu.fecha_limite < h.d) AS vencida_hoy,
           CASE WHEN cu.fecha_completado IS NOT NULL THEN greatest(cu.fecha_completado - cu.fecha_limite, 0)
                WHEN cu.viva AND cu.fecha_limite < h.d THEN h.d - cu.fecha_limite
                ELSE 0 END AS dias,
           coalesce(i.cobrados, 0) AS cobrados, coalesce(i.perdonados, 0) AS perdonados
    FROM public.est_cuentas_detal() cu
    CROSS JOIN hoy h
    LEFT JOIN intereses i ON i.cuenta_id = cu.id
    WHERE cu.vendible
  ),
  -- Se evalúa la cuenta terminada, o la que sigue debiendo y ya pasó la gracia
  evaluada AS (
    SELECT c.*,
           (c.cerrada OR (c.vencida_hoy AND c.dias > rg.gracia)) AS evaluada,
           (c.cerrada AND c.dias <= rg.gracia) AS a_tiempo,
           CASE WHEN c.cerrada AND c.dias <= rg.gracia THEN 100
                WHEN c.cerrada AND c.cobrados > 0 THEN least(public.cli_tramo(rg.cerrada_tarde_puntos, c.dias, 'puntos'), rg.con_interes_max)
                WHEN c.cerrada THEN public.cli_tramo(rg.cerrada_tarde_puntos, c.dias, 'puntos')
                WHEN c.vencida_hoy AND c.dias > rg.gracia THEN public.cli_tramo(rg.abierta_vencida_puntos, c.dias, 'puntos')
           END AS pts
    FROM cuenta c CROSS JOIN rg
  ),
  por_cliente AS (
    SELECT e.cliente_id,
           count(*)::int AS cuentas,
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
           (round(sum(pagado), 2) <= 0 AND bool_or(evaluada AND NOT cerrada)) AS nunca_pago_vencido
    FROM evaluada e
    GROUP BY e.cliente_id
  ),
  -- Todos los clientes activos; el que no tiene cuentas queda en ceros (y sale N)
  partes AS (
    SELECT k.id AS cliente_id, coalesce(k.disputado, false) AS disputado, k.disputado_motivo,
           coalesce(pc.cuentas, 0) AS cuentas, coalesce(pc.evaluadas, 0) AS evaluadas,
           coalesce(pc.a_tiempo, 0) AS a_tiempo, coalesce(pc.tarde, 0) AS tarde,
           pc.atraso_prom, pc.atraso_prom_tarde, pc.puntualidad,
           coalesce(pc.cerradas, 0) AS cerradas,
           coalesce(pc.intereses_cobrados, 0) AS intereses_cobrados, coalesce(pc.intereses_perdonados, 0) AS intereses_perdonados,
           coalesce(pc.deuda, 0) AS deuda, coalesce(pc.deuda_cr, 0) AS deuda_cr, coalesce(pc.deuda_ap, 0) AS deuda_ap,
           coalesce(pc.vencido, 0) AS vencido, pc.dias_vencido, cc.dias_sin_pagar,
           coalesce(pc.pagado_total, 0) AS pagado_total, pc.mayor_terminada, pc.cliente_desde,
           coalesce(pc.nunca_pago_vencido, false) AS nunca_pago_vencido,
           round(greatest(0, 100 - rg.interes_resta * (coalesce(pc.intereses_cobrados, 0) + rg.perdonado_vale * coalesce(pc.intereses_perdonados, 0))
                                   / greatest(coalesce(pc.evaluadas, 0), 1)), 1) AS pts_intereses,
           (rg.historial_puntos->>least(coalesce(pc.cerradas, 0), jsonb_array_length(rg.historial_puntos) - 1))::int AS pts_historial,
           CASE WHEN pc.dias_vencido > rg.gracia THEN public.cli_tramo(rg.vencido_resta, pc.dias_vencido, 'resta') ELSE 0 END::int AS resta_vencido,
           CASE WHEN coalesce(pc.deuda, 0) > 0.01 THEN coalesce(public.cli_tramo(rg.sin_abonar_resta, cc.dias_sin_pagar, 'resta'), 0) ELSE 0 END::int AS resta_sin_abonar
    FROM clientes k
    CROSS JOIN rg
    LEFT JOIN por_cliente pc ON pc.cliente_id = k.id
    LEFT JOIN public.est_cobranza_clientes() cc ON cc.cliente_id = k.id
    WHERE k.deleted_at IS NULL
  ),
  nota AS (
    SELECT p.*, h.historia,
           CASE WHEN p.evaluadas > 0 THEN greatest(0, round(h.historia - p.resta_vencido - p.resta_sin_abonar))::int END AS puntaje
    FROM partes p
    CROSS JOIN rg
    CROSS JOIN LATERAL (SELECT CASE WHEN p.evaluadas > 0 THEN round(rg.peso_puntualidad * p.puntualidad + rg.peso_intereses * p.pts_intereses
                                                                   + rg.peso_historial * p.pts_historial, 1) END AS historia) h
  ),
  letra_nota AS (
    SELECT n.*,
           (SELECT x->>'letra' FROM jsonb_array_elements(rg.cortes) WITH ORDINALITY AS t(x, o)
             WHERE n.puntaje >= (x->>'desde')::numeric ORDER BY o LIMIT 1) AS letra_nota,
           rg.letra_max_por_cerradas->>n.cerradas AS letra_max,
           rg.cortes->-1->>'letra' AS letra_peor
    FROM nota n CROSS JOIN rg
  ),
  letra_final AS (
    SELECT l.*,
           CASE WHEN l.evaluadas = 0 THEN 'N'
                WHEN l.nunca_pago_vencido THEN l.letra_peor
                ELSE public.cli_peor_letra(rg.cortes, l.letra_max, l.letra_nota) END AS letra
    FROM letra_nota l CROSS JOIN rg
  ),
  con_tope AS (
    SELECT f.*, (rg.tope_multiplica->>f.letra)::numeric AS multiplica, rg.nombres->>f.letra AS nombre_letra, rg.gracia,
           CASE WHEN f.letra = 'N' THEN NULL
                WHEN (rg.tope_multiplica->>f.letra)::numeric = 0 THEN 0
                WHEN f.mayor_terminada IS NULL THEN NULL
                ELSE round(f.mayor_terminada * (rg.tope_multiplica->>f.letra)::numeric, 2) END AS tope
    FROM letra_final f CROSS JOIN rg
  )
  SELECT t.cliente_id, t.letra, t.nombre_letra, t.puntaje,
         t.historia, t.resta_vencido, t.resta_sin_abonar,
         t.puntualidad, t.pts_intereses, t.pts_historial,
         t.evaluadas, t.a_tiempo, t.tarde, t.atraso_prom, t.atraso_prom_tarde,
         t.cerradas, t.intereses_cobrados, t.intereses_perdonados,
         t.deuda, t.deuda_cr, t.deuda_ap, t.vencido, t.dias_vencido, t.dias_sin_pagar,
         t.pagado_total, t.mayor_terminada, t.cliente_desde,
         t.nunca_pago_vencido,
         (t.evaluadas > 0 AND NOT t.nunca_pago_vencido AND t.letra <> t.letra_nota),
         t.disputado, t.disputado_motivo,
         t.tope,
         CASE WHEN t.tope IS NOT NULL THEN greatest(0, round(t.tope - t.deuda, 2)) END,
         -- Razones, de la más importante a la menos; la app muestra las primeras 4.
         -- La disputa no va aquí: las pantallas ya la muestran en su propio recuadro rojo.
         array_remove(ARRAY[
           CASE WHEN t.nunca_pago_vencido THEN 'Nunca ha pagado nada y tiene una cuenta vencida' END,
           CASE WHEN t.evaluadas = 0 AND t.cuentas = 0 THEN 'Cliente nuevo: no tiene otras cuentas con la tienda'
                WHEN t.evaluadas = 0 THEN 'Cliente nuevo: todavía no ha terminado de pagar ninguna cuenta ni tiene atrasos de más de ' || t.gracia || ' días' END,
           CASE WHEN t.evaluadas = 0 THEN NULL
                WHEN t.tarde = 0 THEN CASE WHEN t.evaluadas = 1 THEN 'Pagó a tiempo su cuenta' ELSE 'Pagó a tiempo sus ' || t.evaluadas || ' cuentas' END
                WHEN t.a_tiempo = 0 THEN CASE WHEN t.evaluadas = 1 THEN 'No pagó a tiempo su cuenta: ' || t.atraso_prom_tarde || ' días de atraso'
                     ELSE 'No pagó a tiempo ninguna de sus ' || t.evaluadas || ' cuentas: ' || t.atraso_prom_tarde || ' días de atraso en promedio' END
                ELSE 'Pagó a tiempo ' || t.a_tiempo || ' de ' || t.evaluadas || ' cuentas; '
                     || CASE WHEN t.tarde = 1 THEN 'la otra, con ' || t.atraso_prom_tarde || ' días de atraso'
                             ELSE 'las otras, con ' || t.atraso_prom_tarde || ' días de atraso en promedio' END END,
           CASE WHEN t.vencido > 0.01 THEN 'Tiene $' || to_char(t.vencido, 'FM999,999,990.00') || ' vencidos hace ' || t.dias_vencido
                     || CASE WHEN t.dias_vencido = 1 THEN ' día' ELSE ' días' END
                WHEN t.deuda > 0.01 THEN 'Al día: debe $' || to_char(t.deuda, 'FM999,999,990.00') || ' y no tiene nada vencido' END,
           CASE WHEN t.resta_sin_abonar > 0 THEN 'Lleva ' || t.dias_sin_pagar || ' días sin abonar' END,
           CASE WHEN t.intereses_cobrados > 0 THEN 'Se le cobró interés por atraso ' || t.intereses_cobrados
                     || CASE WHEN t.intereses_cobrados = 1 THEN ' vez' ELSE ' veces' END
                     || CASE WHEN t.intereses_perdonados > 0 THEN ' (y se le perdonó ' || t.intereses_perdonados || ')' ELSE '' END
                WHEN t.intereses_perdonados > 0 THEN 'Se le perdonó interés ' || t.intereses_perdonados
                     || CASE WHEN t.intereses_perdonados = 1 THEN ' vez' ELSE ' veces' END END,
           CASE WHEN t.evaluadas > 0 AND NOT t.nunca_pago_vencido AND t.letra <> t.letra_nota THEN
                  CASE WHEN t.cerradas = 0 THEN 'Todavía no ha terminado de pagar ninguna cuenta: como máximo ' || t.letra
                       ELSE 'Solo ha terminado de pagar ' || t.cerradas || CASE WHEN t.cerradas = 1 THEN ' cuenta' ELSE ' cuentas' END
                            || ': como máximo ' || t.letra END
                WHEN t.cerradas > 0 THEN 'Ha terminado de pagar ' || t.cerradas || CASE WHEN t.cerradas = 1 THEN ' cuenta' ELSE ' cuentas' END
                     || ' (la más grande, $' || to_char(t.mayor_terminada, 'FM999,999,990.00') || ')'
                WHEN t.evaluadas > 0 THEN 'Todavía no ha terminado de pagar ninguna cuenta: no tiene tope automático' END
         ], NULL)
  FROM con_tope t;
$function$;

REVOKE EXECUTE ON FUNCTION public.cli_reglas_calificacion() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cli_tramo(jsonb, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cli_peor_letra(jsonb, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cli_calificacion_base() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Lo que llama la app de Créditos (personal activo). El conector de la base no pasa la guardia.

-- Lista corta de todos los clientes activos: [id, letra, nota, tope, puede sacar, deuda, vencido] + los nombres de las letras.
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
  IF NOT coalesce(public.es_staff(), false) THEN RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501'; END IF;
  SELECT jsonb_build_object(
           'nombres', public.cli_reglas_calificacion()->'nombres',
           'clientes', coalesce(jsonb_agg(jsonb_build_array(c.cliente_id, c.letra, c.puntaje, c.tope, c.disponible, c.deuda, c.vencido)), '[]'::jsonb))
    INTO v
    FROM public.cli_calificacion_base() c;
  RETURN v;
END $function$;

-- Ficha completa de un cliente (nota, razones, tope, deuda). NULL si el cliente no existe o está eliminado.
CREATE OR REPLACE FUNCTION public.cli_calificacion(p_cliente_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
BEGIN
  IF NOT coalesce(public.es_staff(), false) THEN RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501'; END IF;
  SELECT to_jsonb(c) INTO v FROM public.cli_calificacion_base() c WHERE c.cliente_id = p_cliente_id;
  RETURN v;
END $function$;

REVOKE ALL ON FUNCTION public.cli_calificaciones() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cli_calificacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cli_calificaciones() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cli_calificacion(uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Estadísticas usa la misma calificación desde el 2026-10-31. Estas dos funciones quedan como paso directo
-- (misma forma de columnas para no rehacer est_detal ni est_detal_puntajes); quitarlas después es un DROP: con el "dale" de Kinan.
-- "ritmo" ya no existe en la fórmula: va en NULL.
CREATE OR REPLACE FUNCTION public.est_puntaje_clientes()
 RETURNS TABLE(cliente_id uuid, evaluadas bigint, a_tiempo bigint, atraso_prom numeric, puntualidad numeric, ritmo integer, puntaje numeric, letra text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT cliente_id, evaluadas::bigint, a_tiempo::bigint, atraso_prom, puntualidad, NULL::int, puntaje::numeric, letra
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
