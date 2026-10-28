-- =====================================================================
-- App Personal (personal.html): vales, deudas de empleados y pago del sábado
-- Copia de referencia de lo que está en la base (migración personal_vales_v1, 2026-10-28).
-- Respaldo previo: respaldo_20261028 (63 tablas, 17.527 filas).
--
-- Reglas:
--   * Solo admin activo (es_admin()). Las tablas de dinero (movimientos y pagos) solo se LEEN
--     desde la app; se escriben únicamente con las funciones emp_* de abajo.
--   * Lo que debe un empleado = deudas + vales + ajustes − descuentos.
--   * Al cerrar un pago, los vales quedan amarrados al pago (pago_id) y se crea un "descuento"
--     por el mismo monto; la cuota de deuda también queda como "descuento". Así la cuenta cuadra sola.
--   * Nada se borra: se anula con rastro (deleted_at, quién y por qué).
--   * Los datos personales de los empleados (nombres, teléfonos, sueldos) van solo en la base,
--     nunca en este archivo: el repo es público.
-- =====================================================================

-- Guardia: desde la app (pasa por la API con un token) solo entra el admin activo.
-- El conector de Supabase entra directo a la base, sin token: queda afuera para poder cargar datos.
CREATE OR REPLACE FUNCTION public.emp_exigir_admin()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF (session_user = 'authenticator' OR coalesce(current_setting('request.jwt.claims', true), '') <> '')
     AND NOT coalesce(public.es_admin(), false) THEN
    RAISE EXCEPTION 'Solo un administrador puede manejar el personal' USING ERRCODE = '42501';
  END IF;
END $$;

-- Nombre de quien está operando (para "Bassma le dio $10 a Javier")
CREATE OR REPLACE FUNCTION public.emp_nombre_usuario()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce((SELECT nombre FROM usuarios_app WHERE id = auth.uid()), 'Claude (conector)');
$$;

-- Hoy en Venezuela
CREATE OR REPLACE FUNCTION public.emp_hoy()
RETURNS date LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'America/Caracas')::date $$;

-- ---------- Tablas ----------
CREATE TABLE public.emp_config (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  periodo text NOT NULL DEFAULT 'semana' CHECK (periodo IN ('semana','quincena')),
  dias_periodo int NOT NULL DEFAULT 6 CHECK (dias_periodo BETWEEN 1 AND 31)  -- divisor del día que no fue
);
INSERT INTO public.emp_config DEFAULT VALUES;

CREATE TABLE public.emp_empleados (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre text NOT NULL CHECK (btrim(nombre) <> ''),
  cargo text,
  telefono text,
  sueldo numeric(12,2) NOT NULL DEFAULT 0 CHECK (sueldo >= 0),               -- sueldo del período
  extra_domingo numeric(12,2) NOT NULL DEFAULT 0 CHECK (extra_domingo >= 0), -- 0 = cobra lo mismo trabaje o no el domingo
  comision_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (comision_pct BETWEEN 0 AND 100),
  cuota_deuda numeric(12,2) NOT NULL DEFAULT 0 CHECK (cuota_deuda >= 0),     -- lo que se le descuenta de la deuda en cada pago
  reglas text,                                                                -- su regla especial, en palabras
  activo boolean NOT NULL DEFAULT true,
  orden int NOT NULL DEFAULT 0,
  creado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emp_pagos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id bigint NOT NULL REFERENCES public.emp_empleados(id),
  periodo text NOT NULL CHECK (periodo IN ('semana','quincena')),
  desde date NOT NULL,
  hasta date NOT NULL,
  sueldo numeric(12,2) NOT NULL,
  domingos int NOT NULL DEFAULT 0 CHECK (domingos >= 0),
  extra_domingos numeric(12,2) NOT NULL DEFAULT 0,
  dias_falta numeric(5,2) NOT NULL DEFAULT 0 CHECK (dias_falta >= 0),
  descuento_dias numeric(12,2) NOT NULL DEFAULT 0,
  comision_base numeric(12,2) NOT NULL DEFAULT 0,  -- venta online cobrada sobre la que se calcula la comisión
  comision numeric(12,2) NOT NULL DEFAULT 0 CHECK (comision >= 0),
  vales numeric(12,2) NOT NULL DEFAULT 0,
  cuota numeric(12,2) NOT NULL DEFAULT 0,
  total numeric(12,2) NOT NULL CHECK (total >= 0),
  debe_despues numeric(12,2) NOT NULL DEFAULT 0,   -- lo que quedó debiendo al cerrar (para el recibo)
  nota text,
  pagado_por uuid DEFAULT auth.uid(),
  pagado_nombre text,
  creado_en timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  anulado_por uuid,
  anulado_nombre text,
  motivo_anulacion text,
  CHECK (desde <= hasta)
);
CREATE UNIQUE INDEX emp_pagos_uno_por_fecha ON public.emp_pagos (empleado_id, hasta) WHERE deleted_at IS NULL;

CREATE TABLE public.emp_movimientos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id bigint NOT NULL REFERENCES public.emp_empleados(id),
  tipo text NOT NULL CHECK (tipo IN ('vale','deuda','descuento','ajuste')),
  monto numeric(12,2) NOT NULL CHECK (monto <> 0 AND (tipo = 'ajuste' OR monto > 0)),
  fecha date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Caracas')::date),
  nota text,
  pago_id bigint REFERENCES public.emp_pagos(id),
  clave uuid UNIQUE,                 -- una por intento desde la app: un reintento nunca duplica
  registrado_por uuid DEFAULT auth.uid(),
  registrado_nombre text,
  creado_en timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  anulado_por uuid,
  anulado_nombre text,
  motivo_anulacion text
);
CREATE INDEX emp_movimientos_empleado ON public.emp_movimientos (empleado_id) WHERE deleted_at IS NULL;
CREATE INDEX emp_movimientos_pago ON public.emp_movimientos (pago_id);

-- ---------- Seguridad ----------
ALTER TABLE public.emp_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emp_empleados ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emp_pagos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emp_movimientos ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_admin ON public.emp_config FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY solo_admin ON public.emp_empleados FOR ALL TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY solo_admin_lee ON public.emp_pagos FOR SELECT TO authenticated USING (public.es_admin());
CREATE POLICY solo_admin_lee ON public.emp_movimientos FOR SELECT TO authenticated USING (public.es_admin());

REVOKE ALL ON public.emp_config, public.emp_empleados, public.emp_pagos, public.emp_movimientos FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.emp_pagos, public.emp_movimientos FROM authenticated;
REVOKE DELETE, TRUNCATE ON public.emp_config, public.emp_empleados FROM authenticated;

-- ---------- Cuenta de cada empleado (una sola regla, la usan la app y las funciones) ----------
-- debe            = deudas + vales + ajustes − descuentos
-- vales_pend      = vales que todavía no entraron en un pago
-- deuda_pend      = debe − vales_pend  (lo que se va bajando con la cuota)
CREATE OR REPLACE FUNCTION public.emp_cuentas()
RETURNS TABLE (empleado_id bigint, deudas numeric, vales numeric, ajustes numeric, descuentos numeric,
               vales_pend numeric, debe numeric, deuda_pend numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public' AS $$
  SELECT e.id,
         coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'deuda'), 0),
         coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'vale'), 0),
         coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'ajuste'), 0),
         coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'descuento'), 0),
         coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'vale' AND m.pago_id IS NULL), 0),
         coalesce(sum(CASE WHEN m.tipo = 'descuento' THEN -m.monto ELSE m.monto END), 0),
         coalesce(sum(CASE WHEN m.tipo = 'descuento' THEN -m.monto ELSE m.monto END), 0)
           - coalesce(sum(m.monto) FILTER (WHERE m.tipo = 'vale' AND m.pago_id IS NULL), 0)
  FROM emp_empleados e
  LEFT JOIN emp_movimientos m ON m.empleado_id = e.id AND m.deleted_at IS NULL
  GROUP BY e.id;
$$;

-- ---------- Anotar vale, deuda, abono (descuento a mano) o ajuste ----------
-- Las reglas viven aquí, no en la app: el vale de más de $500 va como deuda, el abono no pasa de la deuda,
-- y deuda, abono y ajuste llevan nota. La clave es una por toque: un reintento devuelve lo ya guardado,
-- y si la clave llega con otro empleado, tipo o monto, avisa en vez de anunciar algo que no se guardó.
CREATE OR REPLACE FUNCTION public.emp_registrar_movimiento(
  p_empleado_id bigint, p_tipo text, p_monto numeric, p_fecha date DEFAULT NULL,
  p_nota text DEFAULT NULL, p_clave uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_emp emp_empleados%ROWTYPE;
  v_mov emp_movimientos%ROWTYPE;
  v_fecha date;
  v_monto numeric := round(coalesce(p_monto, 0), 2);
  v_deuda numeric;
BEGIN
  PERFORM emp_exigir_admin();
  IF p_clave IS NOT NULL THEN
    SELECT * INTO v_mov FROM emp_movimientos WHERE clave = p_clave;
    IF FOUND THEN
      SELECT * INTO v_emp FROM emp_empleados WHERE id = v_mov.empleado_id;
      IF v_mov.empleado_id <> p_empleado_id OR v_mov.tipo <> p_tipo OR v_mov.monto <> v_monto THEN
        RAISE EXCEPTION 'Ya había quedado anotado: % de $% a %. Revisa la cuenta antes de anotar otro.',
          lower(CASE WHEN v_mov.tipo = 'descuento' THEN 'abono' ELSE v_mov.tipo END), v_mov.monto, v_emp.nombre;
      END IF;
      RETURN to_jsonb(v_mov) || jsonb_build_object('empleado', v_emp.nombre, 'repetido', true);
    END IF;
  END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('vale','deuda','descuento','ajuste') THEN
    RAISE EXCEPTION 'Tipo de movimiento no válido: %', p_tipo;
  END IF;
  SELECT * INTO v_emp FROM emp_empleados WHERE id = p_empleado_id FOR UPDATE;   -- en fila con cerrar pago
  IF NOT FOUND THEN RAISE EXCEPTION 'El empleado no existe'; END IF;
  IF p_tipo = 'vale' AND NOT v_emp.activo THEN RAISE EXCEPTION '% está inactivo', v_emp.nombre; END IF;
  IF v_monto = 0 OR (p_tipo <> 'ajuste' AND v_monto < 0) THEN RAISE EXCEPTION 'El monto tiene que ser mayor que cero'; END IF;
  IF abs(v_monto) > 100000 THEN RAISE EXCEPTION 'Monto fuera de rango'; END IF;
  IF p_tipo = 'vale' AND v_monto > 500 THEN
    RAISE EXCEPTION 'Un vale de más de $500 no se anota como vale: anótalo como deuda en su cuenta';
  END IF;
  IF p_tipo <> 'vale' AND coalesce(btrim(p_nota), '') = '' THEN
    RAISE EXCEPTION 'Escribe %', CASE WHEN p_tipo = 'deuda' THEN 'qué es la deuda' ELSE 'el motivo' END;
  END IF;
  IF p_tipo = 'descuento' THEN
    SELECT c.deuda_pend INTO v_deuda FROM emp_cuentas() c WHERE c.empleado_id = v_emp.id;
    IF v_monto > greatest(coalesce(v_deuda, 0), 0) + 0.005 THEN
      RAISE EXCEPTION 'El abono ($%) es mayor que la deuda de % ($%)', v_monto, v_emp.nombre, round(greatest(coalesce(v_deuda, 0), 0), 2);
    END IF;
  END IF;
  -- El vale siempre lleva la fecha de hoy en Venezuela; lo demás puede ser de antes, nunca de mañana
  v_fecha := CASE WHEN p_tipo = 'vale' THEN emp_hoy() ELSE coalesce(p_fecha, emp_hoy()) END;
  IF v_fecha > emp_hoy() THEN RAISE EXCEPTION 'La fecha no puede ser futura'; END IF;

  INSERT INTO emp_movimientos (empleado_id, tipo, monto, fecha, nota, clave, registrado_por, registrado_nombre)
  VALUES (v_emp.id, p_tipo, v_monto, v_fecha, nullif(btrim(p_nota), ''), p_clave, auth.uid(), emp_nombre_usuario())
  RETURNING * INTO v_mov;
  RETURN to_jsonb(v_mov) || jsonb_build_object('empleado', v_emp.nombre, 'repetido', false);
END $$;

-- ---------- Anular un movimiento (con rastro) ----------
-- Bloquea primero al empleado, igual que cerrar pago: así un vale no se anula a mitad de un cierre.
CREATE OR REPLACE FUNCTION public.emp_anular_movimiento(p_id bigint, p_motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mov emp_movimientos%ROWTYPE;
BEGIN
  PERFORM emp_exigir_admin();
  IF coalesce(btrim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Escribe por qué se anula'; END IF;
  PERFORM 1 FROM emp_empleados WHERE id = (SELECT empleado_id FROM emp_movimientos WHERE id = p_id) FOR UPDATE;
  SELECT * INTO v_mov FROM emp_movimientos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El movimiento no existe'; END IF;
  IF v_mov.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Ese movimiento ya estaba anulado'; END IF;
  IF v_mov.pago_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ese movimiento ya entró en el pago #%. Anula el pago primero.', v_mov.pago_id;
  END IF;
  UPDATE emp_movimientos
     SET deleted_at = now(), anulado_por = auth.uid(), anulado_nombre = emp_nombre_usuario(),
         motivo_anulacion = btrim(p_motivo)
   WHERE id = p_id;
END $$;

-- ---------- Cerrar el pago de un empleado (todo o nada) ----------
-- La base recalcula todo con datos frescos. Si el total no es el que vio quien paga
-- (por ejemplo, alguien anotó un vale mientras tanto), no guarda nada y pide volver a abrir.
-- Nunca dos pagos que se crucen: si ya cobró algún día de ese período (aunque sea con otra fecha), se rechaza.
CREATE OR REPLACE FUNCTION public.emp_cerrar_pago(
  p_empleado_id bigint, p_desde date, p_hasta date, p_domingos int, p_dias_falta numeric,
  p_comision_base numeric, p_cuota numeric, p_total_esperado numeric, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_emp emp_empleados%ROWTYPE;
  v_cfg emp_config%ROWTYPE;
  v_pago emp_pagos%ROWTYPE;
  v_previo emp_pagos%ROWTYPE;
  v_falta numeric := round(coalesce(p_dias_falta, 0), 2);
  v_base numeric := round(coalesce(p_comision_base, 0), 2);
  v_extra numeric; v_desc_dias numeric; v_comision numeric; v_vales numeric; v_cuota numeric;
  v_ids bigint[]; v_deuda_pend numeric; v_total numeric;
BEGIN
  PERFORM emp_exigir_admin();
  SELECT * INTO v_emp FROM emp_empleados WHERE id = p_empleado_id FOR UPDATE;  -- un pago a la vez por empleado
  IF NOT FOUND THEN RAISE EXCEPTION 'El empleado no existe'; END IF;
  SELECT * INTO v_cfg FROM emp_config WHERE id = 1;
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN RAISE EXCEPTION 'Revisa las fechas del período'; END IF;
  IF p_hasta > emp_hoy() THEN RAISE EXCEPTION 'No se puede cerrar un pago con fecha futura'; END IF;
  IF coalesce(p_domingos, 0) < 0 OR v_falta < 0 OR v_base < 0 OR coalesce(p_cuota, 0) < 0 THEN
    RAISE EXCEPTION 'Ningún número puede ser negativo';
  END IF;
  IF v_falta > v_cfg.dias_periodo THEN RAISE EXCEPTION 'Más días sin venir que días del período'; END IF;
  SELECT * INTO v_previo FROM emp_pagos
   WHERE empleado_id = v_emp.id AND deleted_at IS NULL AND desde <= p_hasta AND hasta >= p_desde
   ORDER BY hasta DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% ya cobró ese período: pago #% del % al %', v_emp.nombre, v_previo.id,
      to_char(v_previo.desde, 'DD/MM/YYYY'), to_char(v_previo.hasta, 'DD/MM/YYYY');
  END IF;

  -- Se multiplica antes de dividir, igual que la app: así los dos redondean el mismo número
  v_extra     := round(coalesce(p_domingos, 0) * v_emp.extra_domingo, 2);
  v_desc_dias := round(v_emp.sueldo * v_falta / v_cfg.dias_periodo, 2);
  v_comision  := round(v_base * v_emp.comision_pct / 100, 2);
  SELECT coalesce(array_agg(id), '{}'), coalesce(sum(monto), 0) INTO v_ids, v_vales FROM emp_movimientos
   WHERE empleado_id = v_emp.id AND tipo = 'vale' AND pago_id IS NULL AND deleted_at IS NULL AND fecha <= p_hasta;
  SELECT c.deuda_pend INTO v_deuda_pend FROM emp_cuentas() c WHERE c.empleado_id = v_emp.id;
  v_cuota := round(coalesce(p_cuota, 0), 2);
  IF v_cuota > greatest(coalesce(v_deuda_pend, 0), 0) + 0.005 THEN
    RAISE EXCEPTION 'La cuota ($%) es mayor que la deuda ($%)', v_cuota, round(greatest(coalesce(v_deuda_pend, 0), 0), 2);
  END IF;
  IF v_emp.sueldo + v_extra - v_desc_dias + v_comision - v_vales < 0 THEN
    RAISE EXCEPTION 'Los vales de % ($%) son más de lo que cobra en este pago ($%). Anula los vales que sobran y anótalos como deuda en su cuenta.',
      v_emp.nombre, v_vales, v_emp.sueldo + v_extra - v_desc_dias + v_comision;
  END IF;
  v_total := round(v_emp.sueldo + v_extra - v_desc_dias + v_comision - v_vales - v_cuota, 2);
  IF v_total < 0 THEN
    RAISE EXCEPTION 'El pago de % queda en negativo ($%). Baja la cuota de la deuda.', v_emp.nombre, v_total;
  END IF;
  IF p_total_esperado IS NULL OR abs(v_total - p_total_esperado) > 0.005 THEN
    RAISE EXCEPTION 'Los números de % cambiaron (total real $%). Vuelve a abrir el pago para verlos.', v_emp.nombre, v_total;
  END IF;

  INSERT INTO emp_pagos (empleado_id, periodo, desde, hasta, sueldo, domingos, extra_domingos, dias_falta, descuento_dias,
                         comision_base, comision, vales, cuota, total, nota, pagado_por, pagado_nombre)
  VALUES (v_emp.id, v_cfg.periodo, p_desde, p_hasta, v_emp.sueldo, coalesce(p_domingos, 0), v_extra, v_falta,
          v_desc_dias, v_base, v_comision, v_vales, v_cuota, v_total,
          nullif(btrim(p_nota), ''), auth.uid(), emp_nombre_usuario())
  RETURNING * INTO v_pago;

  -- Se amarran exactamente los vales que se sumaron
  UPDATE emp_movimientos SET pago_id = v_pago.id WHERE id = ANY(v_ids);
  IF v_vales > 0 THEN
    INSERT INTO emp_movimientos (empleado_id, tipo, monto, fecha, nota, pago_id, registrado_por, registrado_nombre)
    VALUES (v_emp.id, 'descuento', v_vales, p_hasta, 'Vales descontados en el pago #' || v_pago.id, v_pago.id, auth.uid(), emp_nombre_usuario());
  END IF;
  IF v_cuota > 0 THEN
    INSERT INTO emp_movimientos (empleado_id, tipo, monto, fecha, nota, pago_id, registrado_por, registrado_nombre)
    VALUES (v_emp.id, 'descuento', v_cuota, p_hasta, 'Cuota de deuda en el pago #' || v_pago.id, v_pago.id, auth.uid(), emp_nombre_usuario());
  END IF;

  UPDATE emp_pagos SET debe_despues = coalesce((SELECT c.debe FROM emp_cuentas() c WHERE c.empleado_id = v_emp.id), 0)
   WHERE id = v_pago.id RETURNING * INTO v_pago;
  RETURN to_jsonb(v_pago) || jsonb_build_object('empleado', v_emp.nombre);
END $$;

-- ---------- Anular un pago: los vales vuelven a quedar pendientes y los descuentos se anulan ----------
CREATE OR REPLACE FUNCTION public.emp_anular_pago(p_pago_id bigint, p_motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_pago emp_pagos%ROWTYPE;
BEGIN
  PERFORM emp_exigir_admin();
  IF coalesce(btrim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Escribe por qué se anula'; END IF;
  SELECT * INTO v_pago FROM emp_pagos WHERE id = p_pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El pago no existe'; END IF;
  IF v_pago.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Ese pago ya estaba anulado'; END IF;
  PERFORM 1 FROM emp_empleados WHERE id = v_pago.empleado_id FOR UPDATE;
  UPDATE emp_pagos SET deleted_at = now(), anulado_por = auth.uid(), anulado_nombre = emp_nombre_usuario(),
         motivo_anulacion = btrim(p_motivo)
   WHERE id = p_pago_id;
  UPDATE emp_movimientos SET deleted_at = now(), anulado_por = auth.uid(), anulado_nombre = emp_nombre_usuario(),
         motivo_anulacion = 'Pago #' || p_pago_id || ' anulado: ' || btrim(p_motivo)
   WHERE pago_id = p_pago_id AND tipo = 'descuento' AND deleted_at IS NULL;
  UPDATE emp_movimientos SET pago_id = NULL WHERE pago_id = p_pago_id AND tipo = 'vale';
END $$;

-- Nadie fuera del personal ejecuta estas funciones
REVOKE ALL ON FUNCTION public.emp_exigir_admin(), public.emp_nombre_usuario(), public.emp_cuentas(),
  public.emp_registrar_movimiento(bigint, text, numeric, date, text, uuid), public.emp_anular_movimiento(bigint, text),
  public.emp_cerrar_pago(bigint, date, date, int, numeric, numeric, numeric, numeric, text),
  public.emp_anular_pago(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emp_cuentas(),
  public.emp_registrar_movimiento(bigint, text, numeric, date, text, uuid), public.emp_anular_movimiento(bigint, text),
  public.emp_cerrar_pago(bigint, date, date, int, numeric, numeric, numeric, numeric, text),
  public.emp_anular_pago(bigint, text) TO authenticated;

-- Tarjeta en el portal (solo admin)
INSERT INTO public.portal_apps (id, nombre, descripcion, url, icono, orden, activa)
VALUES ('personal', 'Personal', 'Vales, deudas y pago del sábado', 'personal.html?v=1', 'users', 11, true);
INSERT INTO public.portal_permisos (rol, app_id, nivel) VALUES ('admin', 'personal', 'completo');

-- =====================================================================
-- Avisos de vales al teléfono (migración personal_avisos_v1, 2026-10-28)
-- Flujo: la app anota el vale → llama a la función del servidor emp-avisos (supabase/functions/emp-avisos)
-- → la función manda una notificación web push a los teléfonos de los admin que activaron los avisos.
-- Las claves VAPID las genera la propia función la primera vez y las guarda en emp_push_claves:
-- la privada nunca sale de la base ni pasa por el repo (que es público).
-- =====================================================================
CREATE TABLE public.emp_push_claves (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  vapid jsonb NOT NULL,      -- {publicKey, privateKey} en formato JWK
  publica text NOT NULL,     -- la clave pública que usa el teléfono para suscribirse
  creado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.emp_push_claves ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo la función (llave de servicio)
REVOKE ALL ON public.emp_push_claves FROM anon, authenticated;

CREATE TABLE public.emp_push_suscripciones (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  usuario_id uuid NOT NULL,
  usuario_nombre text,
  endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL,
  auth text NOT NULL,
  aparato text,
  creado_en timestamptz NOT NULL DEFAULT now(),
  ultimo_ok timestamptz,
  deleted_at timestamptz
);
ALTER TABLE public.emp_push_suscripciones ENABLE ROW LEVEL SECURITY;
CREATE POLICY propias ON public.emp_push_suscripciones FOR SELECT TO authenticated
  USING (usuario_id = auth.uid() AND public.es_admin());
REVOKE ALL ON public.emp_push_suscripciones FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.emp_push_suscripciones FROM authenticated;

-- Cuándo se avisó cada vale (la función lo marca antes de mandar: nunca se avisa dos veces)
ALTER TABLE public.emp_movimientos ADD COLUMN aviso_en timestamptz;

CREATE OR REPLACE FUNCTION public.emp_guardar_suscripcion(p_endpoint text, p_p256dh text, p_auth text, p_aparato text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM emp_exigir_admin();
  IF coalesce(p_endpoint, '') !~ '^https://' OR coalesce(p_p256dh, '') = '' OR coalesce(p_auth, '') = '' THEN
    RAISE EXCEPTION 'Suscripción no válida';
  END IF;
  INSERT INTO emp_push_suscripciones (usuario_id, usuario_nombre, endpoint, p256dh, auth, aparato)
  VALUES (auth.uid(), emp_nombre_usuario(), p_endpoint, p_p256dh, p_auth, left(p_aparato, 200))
  ON CONFLICT (endpoint) DO UPDATE
    SET usuario_id = EXCLUDED.usuario_id, usuario_nombre = EXCLUDED.usuario_nombre, p256dh = EXCLUDED.p256dh,
        auth = EXCLUDED.auth, aparato = EXCLUDED.aparato, deleted_at = NULL;
END $$;

CREATE OR REPLACE FUNCTION public.emp_quitar_suscripcion(p_endpoint text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM emp_exigir_admin();
  UPDATE emp_push_suscripciones SET deleted_at = now()
   WHERE endpoint = p_endpoint AND usuario_id = auth.uid() AND deleted_at IS NULL;
END $$;

REVOKE ALL ON FUNCTION public.emp_guardar_suscripcion(text, text, text, text), public.emp_quitar_suscripcion(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emp_guardar_suscripcion(text, text, text, text), public.emp_quitar_suscripcion(text) TO authenticated;

-- =====================================================================
-- Revisión del 2026-10-28 (migración personal_v2)
-- =====================================================================
-- Las guardias tampoco las ejecuta un usuario con sesión: solo las llaman las funciones emp_* (igual que el mayor)
REVOKE ALL ON FUNCTION public.emp_exigir_admin(), public.emp_nombre_usuario() FROM authenticated;

-- Rastro de los cambios a la ficha (sueldo, extra, comisión, cuota...): valor de antes y de después, quién y cuándo
CREATE TABLE public.emp_cambios_ficha (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id bigint NOT NULL REFERENCES public.emp_empleados(id),
  antes jsonb,
  despues jsonb,
  usuario_id uuid,
  usuario_nombre text,
  creado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.emp_cambios_ficha ENABLE ROW LEVEL SECURITY;
CREATE POLICY solo_admin_lee ON public.emp_cambios_ficha FOR SELECT TO authenticated USING (public.es_admin());
REVOKE ALL ON public.emp_cambios_ficha FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.emp_cambios_ficha FROM authenticated;

CREATE OR REPLACE FUNCTION public.emp_rastro_ficha()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF to_jsonb(OLD) IS DISTINCT FROM to_jsonb(NEW) THEN
    INSERT INTO emp_cambios_ficha (empleado_id, antes, despues, usuario_id, usuario_nombre)
    VALUES (NEW.id, to_jsonb(OLD), to_jsonb(NEW), auth.uid(), emp_nombre_usuario());
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.emp_rastro_ficha() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_emp_rastro_ficha AFTER UPDATE ON public.emp_empleados
  FOR EACH ROW EXECUTE FUNCTION public.emp_rastro_ficha();
