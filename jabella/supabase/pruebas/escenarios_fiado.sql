-- Escenarios de la entrega 6 (cuenta de fiado por clienta: abono repartido de la más vieja a la más nueva).
-- Correr después de las demás baterías en la misma base.
\set QUIET 1
\pset format unaligned
\pset tuples_only on
select set_config('t.hoy', ((now() at time zone 'America/Caracas')::date)::text, false);

-- Preparación: una prenda de $100 y una clienta con tres fiados ($100, $200 y $200) y un apartado
select como('A'); set role authenticated;
select t('tasa de hoy', $q$ (select jab_actualizar_tasa(40)) $q$);
select t('prenda de $100', $q$ jab_guardar_producto('{"nombre":"Vestido prueba fiado","categoria":"Vestidos","precio":100,"costo":40,"variantes":[{"talla":"M","stock":40}]}') > 0 $q$);
select set_config('t.vc', (select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Vestido prueba fiado')::text, false);
reset role;
insert into jab_clientes (nombre, telefono) values ('Clienta con varias cuentas', '04141234567'), ('Clienta sin deuda', null);
select set_config('t.cl', (select id from jab_clientes where nombre = 'Clienta con varias cuentas')::text, false);
select set_config('t.cl2', (select id from jab_clientes where nombre = 'Clienta sin deuda')::text, false);
select como('A'); set role authenticated;
select t('fiado 1: $100', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[]'::jsonb)) > 0 $q$);
select t('fiado 2: $200', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',2)),'pagos','[]'::jsonb)) > 0 $q$);
select t('fiado 3: $200', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',2)),'pagos','[]'::jsonb)) > 0 $q$);
select t('y un apartado (no entra en el reparto)', $q$ jab_registrar_venta(jsonb_build_object('tipo','apartado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":50}]'::jsonb)) > 0 $q$);
reset role;
select set_config('t.f1', (select id from jab_ventas where cliente_id = current_setting('t.cl')::bigint and tipo = 'fiado' order by id limit 1)::text, false);
select set_config('t.f2', (select id from jab_ventas where cliente_id = current_setting('t.cl')::bigint and tipo = 'fiado' order by id offset 1 limit 1)::text, false);
select set_config('t.f3', (select id from jab_ventas where cliente_id = current_setting('t.cl')::bigint and tipo = 'fiado' order by id offset 2 limit 1)::text, false);
select set_config('t.ap', (select id from jab_ventas where cliente_id = current_setting('t.cl')::bigint and tipo = 'apartado' order by id desc limit 1)::text, false);
select t('debe $500 en tres cuentas', $q$ (select count(*) || ' cuentas $' || sum(total - pagado) from jab_ventas where cliente_id = current_setting('t.cl')::bigint and tipo = 'fiado' and estado = 'activa') $q$);

-- ===== Validaciones =====
select como('B'); set role authenticated;
select t('abono mayor que la deuda', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":501}]') $q$, 'mayor que lo que debe');
select t('abono vacío', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[]') $q$, 'monto');
select t('monto cero', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":0}]') $q$, 'mayor que cero');
select t('clienta que no debe', $q$ jab_abonar_cliente(current_setting('t.cl2')::bigint, '[{"metodo_id":1,"monto_usd":10}]') $q$, 'no debe nada');
select t('clienta que no existe', $q$ jab_abonar_cliente(-1, '[{"metodo_id":1,"monto_usd":10}]') $q$, 'no existe');
select como('C');
select t('C (inactiva) no abona', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":10}]') $q$, 'no está activo');

-- ===== Abono de $250: paga la más vieja ($100) y $150 de la segunda =====
select como('B');
select t('B abona $250 a la cuenta', $q$ (select (r->>'total') || ' antes=' || (r->>'deuda_antes') || ' despues=' || (r->>'deuda_despues') || ' cuentas=' || jsonb_array_length(r->'cuentas')
  from (select jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":250}]', '88888888-8888-8888-8888-888888888881') r) x) $q$);
select t('reintento con la misma clave no abona dos veces', $q$ (select (r->>'deuda_despues') from (select jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":250}]', '88888888-8888-8888-8888-888888888881') r) x) $q$);
reset role;
select t('la más vieja quedó pagada', $q$ (select total - pagado from jab_ventas where id = current_setting('t.f1')::bigint) $q$);
select t('la segunda debe $50', $q$ (select total - pagado from jab_ventas where id = current_setting('t.f2')::bigint) $q$);
select t('la tercera sigue en $200', $q$ (select total - pagado from jab_ventas where id = current_setting('t.f3')::bigint) $q$);
select t('el apartado no se tocó (debe $50)', $q$ (select total - pagado from jab_ventas where id = current_setting('t.ap')::bigint) $q$);
select t('dos pagos con el mismo grupo: 100 + 150', $q$ (select count(distinct grupo_abono) || ' grupo, ' || string_agg(monto_usd::text, ' + ' order by venta_id) from jab_pagos where venta_id in (current_setting('t.f1')::bigint, current_setting('t.f2')::bigint) and grupo_abono is not null) $q$);
select t('lo cobró B', $q$ (select bool_and(usuario_id = '00000000-0000-0000-0000-00000000000b') from jab_pagos where grupo_abono is not null) $q$);

-- ===== Abono en bolívares que se reparte entre dos cuentas =====
select como('B'); set role authenticated;
select t('Bs 4.000 ($100) entre la segunda y la tercera', $q$ (select string_agg((c->>'numero') || ':' || (c->>'abonado'), ' ') from (select jsonb_array_elements(jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":2,"monto_usd":100,"monto":4000,"tasa":40}]')->'cuentas') c) x) $q$);
reset role;
select t('en Bs no se pierde ni un céntimo', $q$ (select sum(monto) || ' Bs = $' || sum(monto_usd) from jab_pagos where moneda = 'VES' and venta_id in (current_setting('t.f2')::bigint, current_setting('t.f3')::bigint) and grupo_abono is not null) $q$);
select t('segunda pagada, tercera debe $150', $q$ (select string_agg((total - pagado)::text, ' ' order by id) from jab_ventas where id in (current_setting('t.f2')::bigint, current_setting('t.f3')::bigint)) $q$);

-- ===== Dos formas de pago en un abono, con foto del pago =====
reset role;
insert into storage.objects (bucket_id, name) values ('jab-comprobantes', 'c/1800000000-fiado1.jpg');
select como('B'); set role authenticated;
select t('$30 efectivo + Bs 1.200 ($30) con foto', $q$ (select (r->>'deuda_despues') from (select jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":30,"comprobante":"c/1800000000-fiado1.jpg"},{"metodo_id":2,"monto_usd":30,"monto":1200,"tasa":40}]') r) x) $q$);
reset role;
select t('la foto quedó en el pago', $q$ (select count(*) from jab_pagos where comprobante = 'c/1800000000-fiado1.jpg') $q$);
select t('foto que no existe', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":5,"comprobante":"c/1800000000-nada.jpg"}]') $q$, 'no se subió');

-- ===== Abona exacto lo que queda: todo pagado =====
select como('B'); set role authenticated;
select t('abona los $90 que quedan', $q$ (select (r->>'deuda_despues') from (select jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":90}]') r) x) $q$);
select t('ya no debe nada fiado', $q$ jab_abonar_cliente(current_setting('t.cl')::bigint, '[{"metodo_id":1,"monto_usd":1}]') $q$, 'no debe nada');

-- ===== La dueña anula un pedazo: solo esa cuenta vuelve a deber =====
select como('A');
select t('A anula el pago de $150 de la segunda', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id = current_setting('t.f2')::bigint and monto_usd = 150 and grupo_abono is not null), 'prueba', null)) $q$);
reset role;
select t('la segunda vuelve a deber $150, las demás no cambian', $q$ (select string_agg((total - pagado)::text, ' ' order by id) from jab_ventas where id in (current_setting('t.f1')::bigint, current_setting('t.f2')::bigint, current_setting('t.f3')::bigint)) $q$);

-- ===== Pagos sueltos de antes siguen igual =====
select como('B'); set role authenticated;
select t('abono a una sola venta sigue funcionando', $q$ jab_registrar_abono(current_setting('t.f2')::bigint, '[{"metodo_id":1,"monto_usd":10}]') $q$);
reset role;
select t('el pago suelto no lleva grupo', $q$ (select grupo_abono is null from jab_pagos where venta_id = current_setting('t.f2')::bigint order by id desc limit 1) $q$);
