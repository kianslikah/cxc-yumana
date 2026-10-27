-- PENDIENTE DE CREAR EN LA BASE (pendiente 18 de CLAUDE.md).
-- Versión atómica del botón "Deshacer pago" de Proveedores. Hoy el botón hace estos mismos pasos desde el
-- navegador (deshacerPago/planDeshacerPago en Proveedores_yumana.html). Cuando esta función exista, el botón
-- debe llamarla: primero con p_aplicar = false (resumen para la confirmación) y después con p_aplicar = true.
-- No se pudo crear el 2026-10-27 porque el conector de Supabase pidió un permiso que desde el iPad no aparece.
--
-- Deshace un pago COMPLETO de Proveedores (todas sus partes en cascada y el saldo a favor que dejó o usó).
-- p_aplicar = false: solo devuelve el resumen para la confirmación (no cambia nada).
-- p_aplicar = true : copia todo a prov_auditoria y lo deshace en UNA transacción.
CREATE OR REPLACE FUNCTION public.prov_deshacer_pago(p_operacion_id text, p_aplicar boolean DEFAULT false, p_usuario text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_total numeric; v_hay_dev boolean; v_prov_id text; v_provs int;
  v_partes jsonb; v_copia jsonb; v_fecha date; v_metodo text;
  v_prov record; v_hist record; v_hay_hist boolean := false;
  v_generado numeric := 0; v_devuelto numeric := 0;
  v_credito_antes numeric; v_credito_despues numeric;
BEGIN
  IF NOT public.es_staff() THEN RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501'; END IF;
  IF p_operacion_id IS NULL OR p_operacion_id = '' THEN RAISE EXCEPTION 'Falta el pago'; END IF;

  -- Bloqueo en el mismo orden que prov_registrar_abono: abonos y facturas, después el proveedor
  PERFORM 1 FROM prov_abonos WHERE operacion_id = p_operacion_id FOR UPDATE;
  PERFORM 1 FROM prov_facturas WHERE id IN (SELECT factura_id FROM prov_abonos WHERE operacion_id = p_operacion_id) ORDER BY id FOR UPDATE;

  SELECT count(*), round(COALESCE(sum(a.monto), 0), 2), bool_or(a.metodo = 'Devolución'),
         count(DISTINCT f.proveedor_id), min(f.proveedor_id), min(a.fecha), min(a.metodo),
         jsonb_agg(jsonb_build_object('num', COALESCE(NULLIF(f.num, ''), '(s/n)'), 'monto', a.monto) ORDER BY a.cascada_origen_fac NULLS FIRST, a.id),
         jsonb_agg(to_jsonb(a) ORDER BY a.id)
    INTO v_n, v_total, v_hay_dev, v_provs, v_prov_id, v_fecha, v_metodo, v_partes, v_copia
    FROM prov_abonos a JOIN prov_facturas f ON f.id = a.factura_id
   WHERE a.operacion_id = p_operacion_id;

  IF v_n = 0 THEN RAISE EXCEPTION 'Ese pago ya no existe (puede que ya se haya deshecho)'; END IF;
  IF v_provs <> 1 THEN RAISE EXCEPTION 'El pago toca facturas de varios proveedores: no se puede deshacer solo'; END IF;
  IF v_hay_dev THEN RAISE EXCEPTION 'Este abono es una devolución: se corrige desde la devolución, no se deshace como pago'; END IF;

  SELECT * INTO v_prov FROM prov_proveedores WHERE id = v_prov_id FOR UPDATE;
  v_credito_antes := round(COALESCE(v_prov.credito_a_favor, 0), 2);
  v_credito_despues := v_credito_antes;

  SELECT * INTO v_hist FROM prov_historial_creditos WHERE id = v_prov_id || '__' || p_operacion_id || '_h';
  v_hay_hist := FOUND;
  IF v_hay_hist AND v_hist.tipo = 'generado' THEN
    v_generado := round(v_hist.monto, 2);
    IF v_credito_antes < v_generado - 0.01 THEN
      RAISE EXCEPTION 'Este pago dejó % de saldo a favor, pero al proveedor solo le quedan %: una parte ya se usó en otra factura. Deshaz primero ese "Saldo a favor".',
        to_char(v_generado, 'FM999G999G990D00'), to_char(v_credito_antes, 'FM999G999G990D00');
    END IF;
    v_credito_despues := greatest(round(v_credito_antes - v_generado, 2), 0);
  ELSIF v_hay_hist AND v_hist.tipo = 'aplicado' THEN
    v_devuelto := v_total;  -- el saldo a favor que este pago consumió vuelve al proveedor
    v_credito_despues := round(v_credito_antes + v_devuelto, 2);
  END IF;

  IF p_aplicar THEN
    INSERT INTO prov_auditoria (fecha, usuario, accion, detalle)
    VALUES (now(), COALESCE(NULLIF(p_usuario, ''), 'app'), 'deshacer_pago',
      'Deshizo el pago ' || p_operacion_id || ' a ' || v_prov.proveedor || ' del ' || v_fecha || ' (' || v_metodo || '): $' || v_total
      || ' en ' || v_n || ' parte(s)' || CASE WHEN v_generado > 0 THEN ' + $' || v_generado || ' que había quedado a favor' ELSE '' END
      || '. Saldo a favor antes $' || v_credito_antes || ', después $' || v_credito_despues
      || '. Copia: ' || jsonb_build_object('abonos', v_copia, 'historial', CASE WHEN v_hay_hist THEN to_jsonb(v_hist) END)::text);

    DELETE FROM prov_abonos WHERE operacion_id = p_operacion_id;  -- trg_recalc_abonado recalcula cada factura
    IF v_hay_hist THEN DELETE FROM prov_historial_creditos WHERE id = v_hist.id; END IF;
    IF v_credito_despues <> v_credito_antes THEN
      UPDATE prov_proveedores SET credito_a_favor = v_credito_despues WHERE id = v_prov_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'aplicado', p_aplicar, 'proveedor', v_prov.proveedor, 'fecha', v_fecha, 'metodo', v_metodo,
    'total_pago', round(v_total + v_generado, 2), 'total_abonado', v_total, 'partes', v_partes,
    'credito_generado', v_generado, 'credito_devuelto', v_devuelto,
    'credito_antes', v_credito_antes, 'credito_despues', v_credito_despues);
END;
$function$;

REVOKE ALL ON FUNCTION public.prov_deshacer_pago(text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prov_deshacer_pago(text, boolean, text) TO authenticated;
