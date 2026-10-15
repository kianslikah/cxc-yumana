-- Escenarios de la entrega 5 (apertura y cierre de caja con entrega a la dueña, WhatsApp de la dueña).
-- Correr después de escenarios.sql, escenarios_compras.sql, escenarios_reportes.sql y escenarios_perfiles.sql.
\set QUIET 1
\pset format unaligned
\pset tuples_only on
select set_config('t.hoy', ((now() at time zone 'America/Caracas')::date)::text, false);

-- Preparación: una prenda para vender de contado
select como('A'); set role authenticated;
select t('prenda para la caja', $q$ jab_guardar_producto('{"nombre":"Blusa prueba caja","categoria":"Blusas","precio":20,"costo":8,"variantes":[{"talla":"M","stock":30}]}') > 0 $q$);
select set_config('t.vc', (select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Blusa prueba caja')::text, false);
reset role;
select set_config('t.ef', round(jab__saldo_cuenta(1), 2)::text, false);
select set_config('t.bs', round(jab__saldo_cuenta(2), 2)::text, false);

-- ===== WhatsApp de la dueña =====
select como('B'); set role authenticated;
select t('B no cambia el WhatsApp de la dueña', $q$ (select jab_actualizar_config('{"whatsapp_duena":"04141112233"}')) $q$, 'dueña');
select como('A');
select t('A pone su WhatsApp', $q$ (select jab_actualizar_config('{"whatsapp_duena":"0414-111 2233"}')) $q$);
select t('número no válido', $q$ (select jab_actualizar_config('{"whatsapp_duena":"llámame"}')) $q$, 'check');
select t('las otras reglas no se tocan', $q$ (select whatsapp_duena || ' dias=' || dias_apartado from jab_config) $q$);
select como('B');
select t('B lee el WhatsApp de la dueña', $q$ (select whatsapp_duena from jab_config) $q$);

-- ===== Cuentas "guardado" =====
reset role;
select t('cada efectivo tiene su guardado', $q$ (select string_agg(g.nombre || '<-' || c.nombre, ', ' order by c.id) from jab_cuentas g join jab_cuentas c on c.id = g.recibe_entrega_de) $q$);
select t('el guardado no entra al cierre', $q$ (select bool_and(not cuenta_en_cierre) from jab_cuentas where recibe_entrega_de is not null) $q$);

-- ===== Apertura =====
select como('B'); set role authenticated;
select t('caja de hoy antes de abrir', $q$ (select (r->>'abierta') || ' apertura=' || coalesce(r->>'apertura', 'null') from (select jab_caja_hoy() r) x) $q$);
select t('al abrir no se entrega dinero', $q$ jab_registrar_cierre(jsonb_build_object('tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',20,'entregado',5), jsonb_build_object('cuenta_id',2,'contado',0)))) $q$, 'no se entrega');
select t('tipo raro', $q$ jab_registrar_cierre(jsonb_build_object('tipo','arqueo','conteos','[]'::jsonb)) $q$, 'no válido');
select t('B abre la caja (cuenta lo que hay)', $q$ jab_registrar_cierre(jsonb_build_object('clave','77777777-7777-7777-7777-777777777771','tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado', current_setting('t.ef')::numeric), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric)))) > 0 $q$);
select t('reintento de la apertura no duplica', $q$ jab_registrar_cierre(jsonb_build_object('clave','77777777-7777-7777-7777-777777777771','tipo','apertura','conteos','[]'::jsonb)) > 0 $q$);
select t('no se abre dos veces', $q$ jab_registrar_cierre(jsonb_build_object('tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',1), jsonb_build_object('cuenta_id',2,'contado',0)))) $q$, 'ya se abrió');
select t('caja de hoy: abierta, con lo contado y sin lo esperado', $q$ (select (r->>'abierta') || ' ' || (r->'apertura'->'conteos'->0->>'contado') || ' esperado=' || coalesce(r->'apertura'->'conteos'->0->>'esperado', 'oculto') from (select jab_caja_hoy() r) x) $q$);
select t('fondo sugerido = lo contado al abrir', $q$ (select (r->'fondo'->0->>'monto')::numeric = current_setting('t.ef')::numeric from (select jab_caja_hoy() r) x) $q$);
select t('B sigue sin ver los conteos de la tabla', $q$ (select count(*) from jab_cierres) $q$);
select como('C');
select t('C (inactiva) no ve la caja', $q$ jab_caja_hoy() $q$, 'no está activo');
select como('A');
select t('la apertura cuadra', $q$ (select tipo || ' dif=' || diferencia_usd from jab_cierres order by id desc limit 1) $q$);

-- ===== Día: ventas en efectivo =====
select como('B');
select t('B vende $40 en efectivo', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',2)),'pagos','[{"metodo_id":1,"monto_usd":40}]'::jsonb)) > 0 $q$);

-- ===== Cierre con entrega =====
select t('no se entrega más de lo contado', $q$ jab_registrar_cierre(jsonb_build_object('conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',10,'entregado',11), jsonb_build_object('cuenta_id',2,'contado',0)))) $q$, 'más de lo que hay');
select t('ni negativo', $q$ jab_registrar_cierre(jsonb_build_object('conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',10,'entregado',-1), jsonb_build_object('cuenta_id',2,'contado',0)))) $q$, 'más de lo que hay');
select t('B cierra: cuenta todo, deja $5 y entrega el resto', $q$ jab_registrar_cierre(jsonb_build_object('clave','77777777-7777-7777-7777-777777777772','tipo','cierre','conteos', jsonb_build_array(
    jsonb_build_object('cuenta_id',1,'contado', current_setting('t.ef')::numeric + 40, 'entregado', current_setting('t.ef')::numeric + 35),
    jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric, 'entregado', 0)))) > 0 $q$);
select t('reintento del cierre no entrega dos veces', $q$ jab_registrar_cierre(jsonb_build_object('clave','77777777-7777-7777-7777-777777777772','conteos','[]'::jsonb)) > 0 $q$);
select t('caja de hoy: cerrada, quedan $5', $q$ (select (r->>'abierta') || ' queda=' || (r->'cierre'->'conteos'->0->>'queda') || ' entregado=' || (r->'cierre'->'conteos'->0->>'entregado') from (select jab_caja_hoy() r) x) $q$);
reset role;
select t('el cierre cuadra y guarda la entrega', $q$ (select tipo || ' dif=' || diferencia_usd || ' grupo=' || (grupo_entrega is not null) from jab_cierres order by id desc limit 1) $q$);
select t('en la caja quedan $5', $q$ round(jab__saldo_cuenta(1), 2) $q$);
select t('lo entregado está en Efectivo guardado $ (no es gasto)', $q$ (select round(jab__saldo_cuenta(id), 2) = current_setting('t.ef')::numeric + 35 from jab_cuentas where recibe_entrega_de = 1) $q$);
select t('dos movimientos de transferencia, uno por lado', $q$ (select count(*) || ' ' || sum(monto) || ' ' || string_agg(distinct tipo, ',') || ' ' || string_agg(distinct categoria, ',') from jab_movimientos_dinero where grupo = (select grupo_entrega from jab_cierres order by id desc limit 1)) $q$);
select t('Bs sin entrega: sin movimiento en Bs', $q$ (select count(*) from jab_movimientos_dinero where grupo = (select grupo_entrega from jab_cierres order by id desc limit 1) and cuenta_id = 2) $q$);
select como('A'); set role authenticated;
select t('la entrega no cuenta como gasto en el reporte', $q$ (select (r->>'gastos') || ' descuadres=' || (r->>'descuadres') from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r) x) $q$);

-- ===== Otra vuelta: abre con lo que quedó, falta $1 al cerrar y entrega =====
select como('B');
select t('se puede volver a abrir después de cerrar', $q$ jab_registrar_cierre(jsonb_build_object('tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',5), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric)))) > 0 $q$);
select como('A');
select t('la apertura con el fondo cuadra', $q$ (select tipo || ' dif=' || diferencia_usd from jab_cierres order by id desc limit 1) $q$);
select como('B');
select t('B vende $20', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) > 0 $q$);
select t('B cierra: cuenta $24 (falta $1) y entrega $19', $q$ jab_registrar_cierre(jsonb_build_object('tipo','cierre','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',24,'entregado',19), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric)))) > 0 $q$);
select como('A');
select t('A ve que faltó $1', $q$ (select tipo || ' dif=' || diferencia_usd || ' esperado=' || (detalle->0->>'esperado') || ' queda=' || (detalle->0->>'queda') from jab_cierres order by id desc limit 1) $q$);
select t('A cuadra con lo contado', $q$ (select jab_revisar_cierre((select max(id) from jab_cierres), true)) $q$);
reset role;
select t('el ajuste es de −1 (no de −20)', $q$ (select ajuste->0->>'monto' from jab_cierres order by id desc limit 1) $q$);
select t('en la caja quedan los $5 que de verdad hay', $q$ round(jab__saldo_cuenta(1), 2) $q$);

-- ===== Si la dueña anula la entrega (no se la llevó), el cuadre usa todo lo contado =====
select como('B'); set role authenticated;
select t('B abre con $5', $q$ jab_registrar_cierre(jsonb_build_object('tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',5), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric)))) > 0 $q$);
select t('B cierra con $5 y entrega $3', $q$ jab_registrar_cierre(jsonb_build_object('tipo','cierre','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',5,'entregado',3), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric)))) > 0 $q$);
select como('A');
select t('A anula la entrega en Dinero', $q$ (select jab_anular_movimiento((select grupo_entrega from jab_cierres order by id desc limit 1))) $q$);
select t('cuadrar no inventa diferencia', $q$ (select jab_revisar_cierre((select max(id) from jab_cierres), true)) $q$);
reset role;
select t('sin ajuste y la caja vuelve a $5', $q$ (select coalesce(jsonb_array_length(ajuste), 0) || ' saldo=' || round(jab__saldo_cuenta(1), 2) from jab_cierres order by id desc limit 1) $q$);

-- ===== Una cuenta de efectivo nueva crea su guardado sola al entregar =====
insert into jab_cuentas (nombre, moneda, orden, cuenta_en_cierre) values ('Caja chica', 'USD', 50, true);
select set_config('t.cc', (select id from jab_cuentas where nombre = 'Caja chica')::text, false);
select como('B'); set role authenticated;
select t('B abre con la caja chica', $q$ jab_registrar_cierre(jsonb_build_object('tipo','apertura','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',5), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric), jsonb_build_object('cuenta_id',current_setting('t.cc')::bigint,'contado',0)))) > 0 $q$);
select t('B cierra entregando de la caja chica', $q$ jab_registrar_cierre(jsonb_build_object('tipo','cierre','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado',5), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs')::numeric), jsonb_build_object('cuenta_id',current_setting('t.cc')::bigint,'contado',2,'entregado',2)))) > 0 $q$);
reset role;
select t('caja chica: guardado creado', $q$ (select nombre from jab_cuentas where recibe_entrega_de = current_setting('t.cc')::bigint) $q$);
select t('conteos quedan numerados seguidos', $q$ (select max(numero) - min(numero) + 1 = count(*) from jab_cierres) $q$);
