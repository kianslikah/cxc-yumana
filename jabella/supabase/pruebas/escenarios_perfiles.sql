-- Escenarios de la entrega 4 (perfiles, permisos, comisión, por llegar, límite de fiado, foto del pago).
-- Correr después de escenarios.sql, escenarios_compras.sql y escenarios_reportes.sql en la misma base.
\set QUIET 1
\pset format unaligned
\pset tuples_only on
select set_config('t.hoy', ((now() at time zone 'America/Caracas')::date)::text, false);

-- Preparación (como dueña): dos prendas nuevas, una por llegar, y una clienta con límite
select como('A'); set role authenticated;
select t('prenda para vender', $q$ jab_guardar_producto('{"nombre":"Vestido prueba comisión","categoria":"Vestidos","precio":20,"costo":8,"variantes":[{"talla":"M","stock":10}]}') $q$);
select set_config('t.vc', (select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Vestido prueba comisión')::text, false);
select t('prenda en la categoría pendiente por llegar', $q$ jab_guardar_producto('{"nombre":"Blusa que viene en camino","categoria":"pendiente por llegar","precio":30,"costo":12,"variantes":[{"talla":"S","stock":2}]}') > 0 $q$);
select t('quedó marcada por llegar', $q$ (select por_llegar from jab_productos where nombre = 'Blusa que viene en camino') $q$);
select set_config('t.vl', (select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Blusa que viene en camino')::text, false);
select set_config('t.pl', (select producto_id from jab_variantes where id = current_setting('t.vl')::bigint)::text, false);
reset role;
insert into jab_clientes (nombre, telefono) values ('Clienta con límite', '04140000000');
select set_config('t.cl', (select max(id) from jab_clientes)::text, false);
insert into storage.objects (bucket_id, name) values ('jab-comprobantes', 'c/1700000000-abc123.jpg'), ('jab-comprobantes', 'c/1700000001-def456.jpg');

-- ===== Permisos =====
select como('B'); set role authenticated;
select t('B no maneja permisos', $q$ (select jab_guardar_permisos('00000000-0000-0000-0000-00000000000b', '{"permisos":{"fiar":true}}')) $q$, 'dueña');
select t('B aparta (permitido por defecto)', $q$ jab_registrar_venta(jsonb_build_object('tipo','apartado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":10}]'::jsonb)) > 0 $q$);
select t('B no cambia precios (sin permiso)', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1,'precio',15)),'pagos','[{"metodo_id":1,"monto_usd":15}]'::jsonb)) $q$, 'permiso para cambiar el precio');
reset role;
select como('A'); set role authenticated;
select t('permiso con valor raro', $q$ (select jab_guardar_permisos('00000000-0000-0000-0000-00000000000b', '{"permisos":{"fiar":"si"}}')) $q$, 'Permiso no válido');
select t('comisión fuera de rango', $q$ (select jab_guardar_permisos('00000000-0000-0000-0000-00000000000b', '{"comision_pct":80}')) $q$, 'entre 0 y 50');
select t('A: B no aparta, no fía, sí descuentos; comisión 5 %', $q$ (select jab_guardar_permisos('00000000-0000-0000-0000-00000000000b', '{"permisos":{"apartar":false,"fiar":false,"descuentos":true,"cambios":false},"comision_pct":5}')) $q$);
select t('quedó guardado', $q$ (select permisos::text || ' ' || comision_pct from jab_usuarios where id = '00000000-0000-0000-0000-00000000000b') $q$);
reset role;
select como('B'); set role authenticated;
select t('B ya no aparta', $q$ jab_registrar_venta(jsonb_build_object('tipo','apartado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":10}]'::jsonb)) $q$, 'permiso para apartar');
select t('B no fía (aunque la regla general lo permita)', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)))) $q$, 'permiso para vender fiado');
select t('B no hace cambios', $q$ jab_registrar_cambio('{"venta_origen_id":1,"devueltos":[{"venta_item_id":1,"cantidad":1}]}') $q$, 'permiso para hacer cambios');

-- ===== Comisión =====
select t('B vende de contado con descuento ($18)', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1,'precio',18)),'pagos','[{"metodo_id":1,"monto_usd":18}]'::jsonb)) > 0 $q$);
select set_config('t.vb1', (select max(id) from jab_ventas)::text, false);
select t('B vende 2 de contado ($40)', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',2)),'pagos','[{"metodo_id":1,"monto_usd":40}]'::jsonb)) > 0 $q$);
select set_config('t.vb2', (select max(id) from jab_ventas)::text, false);
select t('B no anota ventas a nombre de otra', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','vendedora_id','00000000-0000-0000-0000-00000000000a','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$, 'Solo la dueña');
select t('mi comisión de hoy: 5 % de 58 = 2,90', $q$ (select (r->'hoy'->>'ventas_n') || ' ventas, $' || (r->'hoy'->>'vendido') || ', comisión ' || (r->'hoy'->>'comision') || ', debe ' || ((r->>'ganada')::numeric - (r->>'pagada')::numeric) from (select jab_mi_comision() r) x) $q$);
select t('B no ve las comisiones de todas', $q$ jab_comisiones(current_setting('t.hoy')::date, current_setting('t.hoy')::date) $q$, 'dueña');
select t('B no paga comisiones', $q$ jab_pagar_comision('00000000-0000-0000-0000-00000000000b', 1, 1) $q$, 'dueña');
reset role;
select como('A'); set role authenticated;
select t('A vende y se la anota a B ($20)', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','vendedora_id','00000000-0000-0000-0000-00000000000b','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) > 0 $q$);
select t('esa venta: registró A, vendió B, 5 %', $q$ (select (usuario_id = '00000000-0000-0000-0000-00000000000a') || ' ' || (vendedora_id = '00000000-0000-0000-0000-00000000000b') || ' ' || comision_pct from jab_ventas where id = (select max(id) from jab_ventas)) $q$);
select t('A fía a nombre de B', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'vendedora_id','00000000-0000-0000-0000-00000000000b','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)))) > 0 $q$);
select t('el fiado no lleva comisión', $q$ (select tipo || ' ' || comision_pct from jab_ventas where id = (select max(id) from jab_ventas)) $q$);
select t('vendedora inactiva', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','vendedora_id','00000000-0000-0000-0000-00000000000c','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$, 'no está activa');
select t('comisiones de hoy: B 3 ventas, $78, $3,90', $q$ (select (x->>'nombre') || ': ' || (x->'periodo'->>'ventas_n') || ' ventas, $' || (x->'periodo'->>'vendido') || ', comisión ' || (x->'periodo'->>'comision') || ', ganada ' || (x->>'ganada') || ', pagada ' || (x->>'pagada') || ', detalle ' || jsonb_array_length(x->'ventas') from jsonb_array_elements(jab_comisiones(current_setting('t.hoy')::date, current_setting('t.hoy')::date)) x) $q$);
select t('A anula la venta de $18 de B', $q$ (select jab_anular_venta(current_setting('t.vb1')::bigint, 'prueba')) $q$);
select t('B ya no gana esa comisión: 3,00', $q$ (select (x->>'ganada')::numeric from jsonb_array_elements(jab_comisiones(current_setting('t.hoy')::date, current_setting('t.hoy')::date)) x) $q$);
select t('pagar más de lo que se debe', $q$ jab_pagar_comision('00000000-0000-0000-0000-00000000000b', 1, 5) $q$, 'se le deben $3.00');
select t('A paga $2 de comisión en efectivo', $q$ jab_pagar_comision('00000000-0000-0000-0000-00000000000b', 1, 2, null, '77777777-7777-7777-7777-777777777777') is not null $q$);
select t('reintento del pago no repite', $q$ (select count(*) from jab_movimientos_dinero where comision_usuario_id = '00000000-0000-0000-0000-00000000000b' and anulado_en is null)
  || ' ' || (jab_pagar_comision('00000000-0000-0000-0000-00000000000b', 1, 2, null, '77777777-7777-7777-7777-777777777777') is not null)
  || ' ' || (select count(*) from jab_movimientos_dinero where comision_usuario_id = '00000000-0000-0000-0000-00000000000b' and anulado_en is null) $q$);
select t('pagada 2, se debe 1', $q$ (select (x->>'pagada') || ' / ' || ((x->>'ganada')::numeric - (x->>'pagada')::numeric) from jsonb_array_elements(jab_comisiones(current_setting('t.hoy')::date, current_setting('t.hoy')::date)) x) $q$);
select t('la comisión pagada es gasto del local en el reporte', $q$ (select (r->'gastos_por_categoria') @> '[{"categoria":"Comisiones","total":2.00}]' from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r) x) $q$);
select t('por quien vendió: B aparece con sus ventas', $q$ (select string_agg((x->>'nombre') || ' ' || (x->>'ventas_n'), ', ' order by x->>'nombre') from jsonb_array_elements(jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->'por_vendedora') x where x->>'nombre' = 'María') $q$);
select t('A anula el pago de comisión en Dinero', $q$ (select jab_anular_movimiento((select grupo from jab_movimientos_dinero where comision_usuario_id = '00000000-0000-0000-0000-00000000000b' and anulado_en is null))) $q$);
select t('vuelve a deberse todo: pagada 0', $q$ (select (x->>'pagada')::numeric from jsonb_array_elements(jab_comisiones(current_setting('t.hoy')::date, current_setting('t.hoy')::date)) x) $q$);

-- ===== Por llegar =====
reset role;
select como('B'); set role authenticated;
select t('B no vende de contado lo que no ha llegado', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vl')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":30}]'::jsonb)) $q$, 'Todavía no llegó');
reset role;
select como('A'); set role authenticated;
select t('A tampoco lo fía', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vl')::bigint,'cantidad',1)))) $q$, 'Todavía no llegó');
select t('sí se puede apartar (pagado completo)', $q$ jab_registrar_venta(jsonb_build_object('tipo','apartado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vl')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":30}]'::jsonb)) > 0 $q$);
select set_config('t.apl', (select max(id) from jab_ventas)::text, false);
select t('no se entrega hasta que llegue', $q$ (select jab_entregar_apartado(current_setting('t.apl')::bigint)) $q$, 'Todavía no llegó');
select t('marcar llegada sin categoría (estaba en pendiente por llegar)', $q$ (select jab_marcar_llegada(current_setting('t.pl')::bigint, '')) $q$, 'Elige la categoría');
select t('llegó: categoría Blusas', $q$ (select jab_marcar_llegada(current_setting('t.pl')::bigint, 'Blusas')) $q$);
select t('ya no está por llegar y es Blusas', $q$ (select (not por_llegar) || ' ' || categoria from jab_productos where id = current_setting('t.pl')::bigint) $q$);
select t('ahora sí se entrega', $q$ (select jab_entregar_apartado(current_setting('t.apl')::bigint)) $q$);
select t('quedó entregado', $q$ (select entregada from jab_ventas where id = current_setting('t.apl')::bigint) $q$);
reset role;
select como('B'); set role authenticated;
select t('B no marca llegadas', $q$ (select jab_marcar_llegada(current_setting('t.pl')::bigint, 'Blusas')) $q$, 'dueña');
select t('B no renombra categorías', $q$ jab_renombrar_categoria('Blusas', 'Tops') $q$, 'dueña');
reset role;

-- ===== Categorías =====
select como('A'); set role authenticated;
select t('renombrar categoría que no existe', $q$ jab_renombrar_categoria('No existe', 'Algo') $q$, 'No hay prendas');
select t('unir Vestidos en Vestidos largos (prendas movidas)', $q$ jab_renombrar_categoria('Vestidos', 'Vestidos largos') $q$);
select t('ya no queda la categoría Vestidos', $q$ (select count(*) from jab_productos where categoria = 'Vestidos') $q$);

-- ===== Límite de fiado =====
select como('A');
set role authenticated;
update jab_clientes set limite_fiado = 25 where id = current_setting('t.cl')::bigint;
reset role;
select como('B'); set role authenticated;
do $$ begin update jab_clientes set limite_fiado = 999 where id = current_setting('t.cl')::bigint; raise notice '!!! B cambió el límite de fiado'; exception when others then raise notice 'ok  B no cambia el límite → (error esperado) %', sqlerrm; end $$;
reset role;
select como('A'); set role authenticated;
select t('B puede fiar otra vez', $q$ (select jab_guardar_permisos('00000000-0000-0000-0000-00000000000b', '{"permisos":{"fiar":true}}')) $q$);
select t('deuda actual de la clienta: $20 (el fiado de antes)', $q$ (select sum(total - pagado) from jab_ventas where cliente_id = current_setting('t.cl')::bigint and estado = 'activa' and tipo = 'fiado') $q$);
reset role;
select como('B'); set role authenticated;
select t('B fía $20 más: pasa el límite de $25', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)))) $q$, 'límite de fiado es $25');
select t('B fía $20 dejando $15: queda en $25, sí pasa', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":15}]'::jsonb)) > 0 $q$);
reset role;
select como('A'); set role authenticated;
select t('la dueña sí puede pasar el límite', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',current_setting('t.cl')::bigint,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)))) > 0 $q$);
reset role;

-- ===== Foto del pago =====
select como('B'); set role authenticated;
select t('venta con foto del pago', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20,"comprobante":"c/1700000000-abc123.jpg"}]'::jsonb)) > 0 $q$);
select t('el pago guardó su foto', $q$ (select comprobante from jab_pagos where venta_id = (select max(id) from jab_ventas)) $q$);
select t('foto con nombre raro', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20,"comprobante":"../p/otra.jpg"}]'::jsonb)) $q$, 'no válida');
select t('foto que no se subió', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20,"comprobante":"c/1799999999-zzz.jpg"}]'::jsonb)) $q$, 'no se subió');
select set_config('t.pg', (select max(id) from jab_pagos where comprobante is null)::text, false);
select t('B agrega la foto después', $q$ (select jab_foto_pago(current_setting('t.pg')::bigint, 'c/1700000001-def456.jpg')) $q$);
select t('B no la cambia', $q$ (select jab_foto_pago(current_setting('t.pg')::bigint, 'c/1700000000-abc123.jpg')) $q$, 'Solo la dueña');
reset role;
select como('A'); set role authenticated;
select t('la dueña sí la cambia', $q$ (select jab_foto_pago(current_setting('t.pg')::bigint, 'c/1700000000-abc123.jpg')) $q$);
select t('foto final del pago', $q$ (select comprobante from jab_pagos where id = current_setting('t.pg')::bigint) $q$);
reset role;
select como('C'); set role authenticated;
select t('una usuaria inactiva no ve fotos de pagos', $q$ (select count(*) from storage.objects where bucket_id = 'jab-comprobantes') $q$);
reset role;

select 'existencia = suma de movimientos: ' || bool_and(v.stock = coalesce((select sum(cantidad) from jab_movimientos_inventario m where m.variante_id = v.id), 0)) from jab_variantes v;
select 'funciones jab_ abiertas a anon: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_%' and has_function_privilege('anon', oid, 'execute');
select 'internas abiertas a authenticated: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_\_%' and has_function_privilege('authenticated', oid, 'execute');
