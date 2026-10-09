-- Escenarios de la entrega 2 (compras SHEIN). Correr DESPUÉS de escenarios.sql en la misma base.
\set QUIET 1
\pset format unaligned
\pset tuples_only on
select como('A'); set role authenticated;
select set_config('t.zelle_antes', (select saldo::text from jab_saldos_cuentas() where nombre = 'Zelle'), false);
select t('A crea pedido SHEIN', $q$ jab_guardar_compra('{"pedido_ref":"GSU123","total_pagado":27.50,"items":[{"descripcion":"Top negro","talla":"M","color":"Negro","cantidad":2,"precio":5},{"descripcion":"Vestido flores","talla":"S","cantidad":1,"precio":12},{"descripcion":"Jean recto","talla":"8","color":"Azul","cantidad":1,"precio":6}],"paquetes":[{"tracking":"T1"},{"tracking":"T2"}]}') $q$);
select set_config('t.c1', (select max(id) from jab_compras)::text, false);
select t('pedido #1 con 3 artículos y 2 paquetes', $q$ (select numero || ' items=' || (select count(*) from jab_compra_items where compra_id = c.id) || ' paq=' || (select count(*) from jab_paquetes where compra_id = c.id) from jab_compras c where id = current_setting('t.c1')::bigint) $q$);
select t('A paga el pedido por Zelle', $q$ jab_pagar_compra(current_setting('t.c1')::bigint, 4, 27.50) is not null $q$);
reset role;
select como('B'); set role authenticated;
select t('B no crea pedidos', $q$ jab_guardar_compra('{"items":[{"descripcion":"x","cantidad":1,"precio":1}]}') $q$, 'dueña');
select t('B no ve pedidos', $q$ (select count(*) from jab_compras) $q$);
reset role;
select como('A'); set role authenticated;
select t('caja con paquete en camino', $q$ jab_guardar_envio(jsonb_build_object('paquetes', jsonb_build_array((select min(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint)))) $q$, 'casillero');
select t('T1 llegó al casillero', $q$ (select jab_paquete_estado((select min(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint), 'casillero')) $q$);
select t('T2 llegó al casillero', $q$ (select jab_paquete_estado((select max(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint), 'casillero')) $q$);
select t('A pide reempaque (2,1 lb y 1,5 vol)', $q$ jab_guardar_envio(jsonb_build_object('clave','33333333-3333-3333-3333-333333333333','peso_lb',2.1,'vol_lb',1.5,'paquetes',(select jsonb_agg(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint))) $q$);
select set_config('t.e1', (select max(id) from jab_envios)::text, false);
select t('reintento de la misma caja no duplica', $q$ jab_guardar_envio(jsonb_build_object('clave','33333333-3333-3333-3333-333333333333','peso_lb',2.1,'vol_lb',1.5,'paquetes',(select jsonb_agg(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint))) = current_setting('t.e1')::bigint $q$);
select t('flete = mayor peso × 6,99 = 14,68', $q$ (select flete from jab_envios where id = current_setting('t.e1')::bigint) $q$);
select t('paquete en dos cajas', $q$ jab_guardar_envio(jsonb_build_object('paquetes',(select jsonb_agg(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint))) $q$, 'otro envío');
select t('caja pasa a aduana', $q$ jab_guardar_envio(jsonb_build_object('id', current_setting('t.e1')::bigint, 'estado','aduana','peso_lb',2.1,'vol_lb',1.5,'paquetes',(select jsonb_agg(id) from jab_paquetes where compra_id = current_setting('t.c1')::bigint))) $q$);
select t('fechas de salida y aduana puestas', $q$ (select estado || ' salida=' || (fecha_salida is not null) || ' aduana=' || (fecha_aduana is not null) || ' flete=' || flete from jab_envios where id = current_setting('t.e1')::bigint) $q$);
select t('A paga el flete', $q$ jab_pagar_flete(current_setting('t.e1')::bigint, 4, 14.68) is not null $q$);
select t('anular pedido con paquetes en caja', $q$ (select jab_anular_compra(current_setting('t.c1')::bigint, 'x')) $q$, 'en un envío');
select t('recibir pidiendo de más', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e1')::bigint, 'lineas', jsonb_build_array(
  jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Top negro'),'recibidas',3,'nueva',jsonb_build_object('nombre','Top básico negro','precio',10))))) $q$, 'solo quedan 2');
select t('recibir sin precio de prenda nueva', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e1')::bigint, 'lineas', jsonb_build_array(
  jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Top negro'),'recibidas',2,'nueva',jsonb_build_object('nombre','Top básico negro'))))) $q$, 'precio de venta');
select t('A recibe la caja', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e1')::bigint, 'clave','44444444-4444-4444-4444-444444444444', 'lineas', jsonb_build_array(
  jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Top negro'),'recibidas',2,'nueva',jsonb_build_object('nombre','Top básico negro','categoria','Blusas','precio',10)),
  jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Vestido flores'),'recibidas',0,'faltantes',1),
  jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Jean recto'),'recibidas',1,'producto_id',1)))) $q$);
select t('reintento de la recepción no repite', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e1')::bigint, 'clave','44444444-4444-4444-4444-444444444444', 'lineas', '[]'::jsonb)) = current_setting('t.e1')::bigint $q$);
select t('caja recibida: 3 piezas, flete por pieza 4,8933', $q$ (select estado || ' piezas=' || piezas_recibidas || ' fpp=' || flete_por_pieza from jab_envios where id = current_setting('t.e1')::bigint) $q$);
select t('costo real del top = 5×27,5/28 + 4,8933 = 9,8040', $q$ (select costo_real from jab_compra_items where descripcion='Top negro') $q$);
select t('prenda nueva con 2 en existencia y su costo', $q$ (select p.codigo || ' stock=' || (select sum(stock) from jab_variantes where producto_id = p.id) || ' costo=' || (select costo from jab_producto_costos where producto_id = p.id) || ' foto/notas=' || coalesce(p.notas,'') from jab_productos p where nombre = 'Top básico negro') $q$);
select t('jean sumado a la prenda 1 (talla 8 nueva), costo promedio (3×5 + 10,7862)/4', $q$ (select (select stock from jab_variantes where producto_id = 1 and talla = '8') || ' costo=' || (select costo from jab_producto_costos where producto_id = 1)) $q$);
select t('vestido quedó faltante', $q$ (select recibidas || '/' || faltantes from jab_compra_items where descripcion='Vestido flores') $q$);
select t('recibir otra vez', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e1')::bigint, 'lineas', jsonb_build_array(jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Jean recto'),'recibidas',0,'faltantes',0)))) $q$, 'ya se recibió');
select t('reembolso de lo que no llegó', $q$ jab_reembolso_item((select id from jab_compra_items where descripcion='Vestido flores'), 4, 11.79) is not null $q$);
select t('reembolso de algo que sí llegó', $q$ jab_reembolso_item((select id from jab_compra_items where descripcion='Top negro'), 4, 5) $q$, 'faltantes');
select t('Zelle = antes − 27,50 − 14,68 + 11,79', $q$ (select (saldo - current_setting('t.zelle_antes')::numeric)::text from jab_saldos_cuentas() where nombre = 'Zelle') $q$);
select t('compras y flete marcados como inversión', $q$ (select count(*) from jab_movimientos_dinero where es_inversion and anulado_en is null) $q$);
select t('anular pedido ya recibido', $q$ (select jab_anular_compra(current_setting('t.c1')::bigint, 'x')) $q$, 'ya se recibió');
select t('cambiar precio de algo recibido', $q$ jab_guardar_compra(jsonb_build_object('id', current_setting('t.c1')::bigint, 'total_pagado', 27.50, 'items', jsonb_build_array(jsonb_build_object('id',(select id from jab_compra_items where descripcion='Top negro'),'descripcion','Top negro','cantidad',2,'precio',7)))) $q$, 'no se puede cambiar');
select t('pedido 2 con clave', $q$ jab_guardar_compra('{"clave":"55555555-5555-5555-5555-555555555555","items":[{"clave":"55555555-0000-0000-0000-000000000001","descripcion":"Falda","cantidad":1,"precio":8},{"clave":"55555555-0000-0000-0000-000000000002","descripcion":"Bolso","cantidad":1,"precio":9}],"paquetes":[{"clave":"55555555-0000-0000-0000-0000000000a1","tracking":"P2"}]}') $q$);
select set_config('t.c2', (select max(id) from jab_compras)::text, false);
select t('reintento del pedido 2 no duplica', $q$ jab_guardar_compra('{"clave":"55555555-5555-5555-5555-555555555555","items":[{"clave":"55555555-0000-0000-0000-000000000001","descripcion":"Falda","cantidad":1,"precio":8},{"clave":"55555555-0000-0000-0000-000000000002","descripcion":"Bolso","cantidad":1,"precio":9}],"paquetes":[{"clave":"55555555-0000-0000-0000-0000000000a1","tracking":"P2"}]}') = current_setting('t.c2')::bigint $q$);
select t('reintento con un cambio lo aplica (falda a $8,50) sin duplicar', $q$ jab_guardar_compra('{"clave":"55555555-5555-5555-5555-555555555555","items":[{"clave":"55555555-0000-0000-0000-000000000001","descripcion":"Falda","cantidad":1,"precio":8.5},{"clave":"55555555-0000-0000-0000-000000000002","descripcion":"Bolso","cantidad":1,"precio":9}],"paquetes":[{"clave":"55555555-0000-0000-0000-0000000000a1","tracking":"P2"}]}') = current_setting('t.c2')::bigint $q$);
select t('pedido 2: 2 artículos, 1 paquete, falda 8,50', $q$ (select count(*) || ' art, ' || (select count(*) from jab_paquetes where compra_id = current_setting('t.c2')::bigint) || ' paq, falda ' || (select precio from jab_compra_items where descripcion = 'Falda') from jab_compra_items where compra_id = current_setting('t.c2')::bigint) $q$);
select t('editar agregando artículo nuevo dos veces (se cayó el internet)', $q$ (select jab_guardar_compra(jsonb_build_object('id', current_setting('t.c2')::bigint, 'clave', 'aaaaaaaa-0000-0000-0000-000000000000', 'items', '[{"clave":"55555555-0000-0000-0000-000000000003","descripcion":"Cinturón","cantidad":1,"precio":3}]'::jsonb))
  + jab_guardar_compra(jsonb_build_object('id', current_setting('t.c2')::bigint, 'clave', 'aaaaaaaa-0000-0000-0000-000000000000', 'items', '[{"clave":"55555555-0000-0000-0000-000000000003","descripcion":"Cinturón","cantidad":1,"precio":3}]'::jsonb))) $q$);
select t('un solo cinturón', $q$ (select count(*) from jab_compra_items where descripcion = 'Cinturón') $q$);
select t('pedido 2 tiene 1 paquete automático', $q$ (select count(*) from jab_paquetes where compra_id = current_setting('t.c2')::bigint) $q$);
select t('quitar el bolso (cantidad 0)', $q$ jab_guardar_compra(jsonb_build_object('id', current_setting('t.c2')::bigint, 'items', jsonb_build_array(jsonb_build_object('id',(select id from jab_compra_items where descripcion='Bolso'),'descripcion','Bolso','cantidad',0,'precio',9)))) $q$);
select t('bolso quitado (borrado suave)', $q$ (select quitado_en is not null from jab_compra_items where descripcion='Bolso') $q$);
select t('pago del pedido 2', $q$ jab_pagar_compra(current_setting('t.c2')::bigint, 1, 8) is not null $q$);
select t('anular pedido 2', $q$ (select jab_anular_compra(current_setting('t.c2')::bigint, 'lo cancelé en SHEIN')) $q$);
select t('su pago quedó anulado', $q$ (select count(*) from jab_movimientos_dinero where compra_id = current_setting('t.c2')::bigint and anulado_en is null) $q$);

-- Revisión: reembolso en Bs, anularlo desde Dinero, faltantes sin caja, caja sin piezas, etapa sola, recepción bloqueada
select t('reembolso en Bs (410 Bs a 41) del vestido', $q$ jab_reembolso_item((select id from jab_compra_items where descripcion='Vestido flores'), 3, 410, 41) is not null $q$);
select t('reembolsado del vestido en $ = 11,79 + 10', $q$ (select reembolsado from jab_compra_items where descripcion='Vestido flores') $q$);
select t('anular desde Dinero el reembolso en Bs', $q$ (select jab_anular_movimiento((select grupo from jab_movimientos_dinero where compra_item_id = (select id from jab_compra_items where descripcion='Vestido flores') and monto = 410))) $q$);
select t('reembolsado bajó a 11,79', $q$ (select reembolsado from jab_compra_items where descripcion='Vestido flores') $q$);
select t('gasto "Mercancía (SHEIN y flete)" desde Dinero', $q$ jab_registrar_movimiento('{"tipo":"gasto","cuenta_id":1,"monto":2,"categoria":"Mercancía (SHEIN y flete)"}'::jsonb) $q$);
select t('quedó como inversión (no gasto del local)', $q$ (select es_inversion from jab_movimientos_dinero where categoria = 'Mercancía (SHEIN y flete)' order by id desc limit 1) $q$);
select t('pedido 4: 3 blusas', $q$ jab_guardar_compra('{"total_pagado":30,"items":[{"descripcion":"Blusa rayas","cantidad":3,"precio":10}],"paquetes":[{"tracking":"X1"},{"tracking":"X2"}]}') $q$);
select set_config('t.c4', (select max(id) from jab_compras)::text, false);
select t('marcar 4 faltantes (hay 3)', $q$ (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), 4)) $q$, 'solo quedan 3');
select t('marcar 1 faltante sin caja', $q$ (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), 1, 'bbbbbbbb-0000-0000-0000-000000000001')) $q$);
select t('reintento no marca otra', $q$ (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), 1, 'bbbbbbbb-0000-0000-0000-000000000001')) $q$);
select t('blusa: 1 faltante', $q$ (select faltantes from jab_compra_items where descripcion='Blusa rayas') $q$);
select t('quitar un artículo de un pedido con faltantes', $q$ jab_guardar_compra(jsonb_build_object('id', current_setting('t.c4')::bigint, 'total_pagado', 30, 'items', jsonb_build_array(jsonb_build_object('id',(select id from jab_compra_items where descripcion='Blusa rayas'),'descripcion','Blusa rayas','cantidad',0,'precio',10)))) $q$, 'no se puede');
select t('agregar artículo a pedido con algo recibido', $q$ jab_guardar_compra(jsonb_build_object('id', current_setting('t.c4')::bigint, 'total_pagado', 30, 'items', '[{"descripcion":"Otra","cantidad":1,"precio":1}]'::jsonb)) $q$, 'no se le pueden agregar');
select t('X1 al casillero', $q$ (select jab_paquete_estado((select min(id) from jab_paquetes where compra_id = current_setting('t.c4')::bigint), 'casillero')) $q$);
select t('caja 3 solo con X1', $q$ jab_guardar_envio(jsonb_build_object('peso_lb',1,'paquetes',jsonb_build_array((select min(id) from jab_paquetes where compra_id = current_setting('t.c4')::bigint)))) $q$);
select set_config('t.e3', (select max(id) from jab_envios)::text, false);
select t('flete pagado de la caja 3', $q$ jab_pagar_flete(current_setting('t.e3')::bigint, 4, 6.99) is not null $q$);
select t('etapa sola: tránsito', $q$ (select jab_envio_estado(current_setting('t.e3')::bigint, 'transito')) $q$);
select t('la etapa no tocó el flete', $q$ (select estado || ' flete=' || flete || ' salida=' || (fecha_salida is not null) from jab_envios where id = current_setting('t.e3')::bigint) $q$);
select t('recibir la caja sin nada marcado', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e3')::bigint, 'lineas', '[]'::jsonb)) $q$, 'Marca lo que llegó');
select t('caja 3 llega vacía: 0 recibidas, 1 faltante', $q$ jab_recibir_envio(jsonb_build_object('envio_id', current_setting('t.e3')::bigint, 'lineas', jsonb_build_array(jsonb_build_object('item_id',(select id from jab_compra_items where descripcion='Blusa rayas'),'recibidas',0,'faltantes',1)))) $q$);
select t('caja 3 recibida sin piezas, flete por pieza vacío', $q$ (select estado || ' piezas=' || piezas_recibidas || ' fpp=' || coalesce(flete_por_pieza::text, 'null') from jab_envios where id = current_setting('t.e3')::bigint) $q$);
select t('deshacer 3 faltantes (hay 2)', $q$ (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), -3)) $q$, 'solo hay 2');
select t('deshacer 1 faltante', $q$ (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), -1)) $q$);
select t('X2 al casillero', $q$ (select jab_paquete_estado((select max(id) from jab_paquetes where compra_id = current_setting('t.c4')::bigint), 'casillero')) $q$);
select t('caja 4 con X2', $q$ jab_guardar_envio(jsonb_build_object('peso_lb',1,'paquetes',jsonb_build_array((select max(id) from jab_paquetes where compra_id = current_setting('t.c4')::bigint)))) $q$);
select set_config('t.e4', (select max(id) from jab_envios)::text, false);
select t('flete de la caja 4 pagado', $q$ jab_pagar_flete(current_setting('t.e4')::bigint, 4, 6.99) is not null $q$);
select t('anular caja 4 sin devolución de flete', $q$ (select jab_anular_envio(current_setting('t.e4')::bigint, 'se perdió')) $q$);
select t('el flete pagado sigue vivo (salió de verdad)', $q$ (select count(*) from jab_movimientos_dinero where envio_id = current_setting('t.e4')::bigint and anulado_en is null) $q$);
select t('pedido 5 pagado y anulado sin devolución', $q$ (select jab_pagar_compra(jab_guardar_compra('{"items":[{"descripcion":"Gorra","cantidad":1,"precio":4}]}'), 4, 4) is not null) $q$);
select t('anular pedido 5 sin devolución', $q$ (select jab_anular_compra((select max(id) from jab_compras), 'SHEIN no devolvió', false)) $q$);
select t('su pago sigue vivo', $q$ (select count(*) from jab_movimientos_dinero where compra_id = (select max(id) from jab_compras) and anulado_en is null) $q$);
select t('reembolso de la blusa faltante', $q$ jab_reembolso_item((select id from jab_compra_items where descripcion='Blusa rayas'), 4, 9.5) is not null $q$);
select t('blusa reembolsada 9,50 y no se puede deshacer su último faltante', $q$ (select reembolsado from jab_compra_items where descripcion='Blusa rayas')::text || (select jab_marcar_faltante((select id from jab_compra_items where descripcion='Blusa rayas'), -1))::text $q$, 'reembolso registrado');
reset role;
select como('B'); set role authenticated;
select t('B vende el top recibido', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',(select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Top básico negro'),'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":10}]'::jsonb)) $q$);
select t('B no ve costos de compras', $q$ (select count(*) from jab_compra_items) $q$);
reset role;
select como('A'); set role authenticated;
select t('la venta guardó el costo real (9,8040)', $q$ (select costo from jab_venta_item_costos where venta_item_id = (select max(id) from jab_venta_items)) $q$);
reset role;

-- Mismo modelo en dos tallas = una sola prenda nueva con dos tallas
select como('A'); set role authenticated;
select t('pedido 3: mismo vestido en S y M', $q$ jab_guardar_compra('{"total_pagado":20,"items":[{"descripcion":"Vestido lino","talla":"S","cantidad":1,"precio":10},{"descripcion":"Vestido lino","talla":"M","cantidad":1,"precio":10}]}') $q$);
select set_config('t.c3', (select max(id) from jab_compras)::text, false);
select t('su paquete llegó', $q$ (select jab_paquete_estado((select id from jab_paquetes where compra_id = current_setting('t.c3')::bigint), 'casillero')) $q$);
select t('caja 2 con flete 0', $q$ jab_guardar_envio(jsonb_build_object('flete',0,'estado','llegada','paquetes',(select jsonb_agg(id) from jab_paquetes where compra_id = current_setting('t.c3')::bigint))) $q$);
select t('recibe las dos tallas con el mismo nombre', $q$ jab_recibir_envio(jsonb_build_object('envio_id',(select max(id) from jab_envios),'lineas',(select jsonb_agg(jsonb_build_object('item_id',id,'recibidas',1,'nueva',jsonb_build_object('nombre','Vestido de lino','precio',25))) from jab_compra_items where compra_id = current_setting('t.c3')::bigint))) $q$);
select t('una prenda con tallas M y S', $q$ (select count(distinct p.id) || ' prenda, tallas ' || string_agg(v.talla, ',' order by v.talla) from jab_productos p join jab_variantes v on v.producto_id = p.id where p.nombre = 'Vestido de lino') $q$);
reset role;
select 'existencia = suma de movimientos: ' || bool_and(v.stock = coalesce((select sum(cantidad) from jab_movimientos_inventario m where m.variante_id = v.id), 0)) from jab_variantes v;
select 'funciones jab_ abiertas a anon: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_%' and has_function_privilege('anon', oid, 'execute');
select 'internas abiertas a authenticated: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_\_%' and has_function_privilege('authenticated', oid, 'execute');
