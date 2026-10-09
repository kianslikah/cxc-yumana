-- Escenarios de la entrega 3 (ganancias y cierre de caja). Correr después de escenarios.sql y escenarios_compras.sql.
\set QUIET 1
\pset format unaligned
\pset tuples_only on
select como('A'); set role authenticated;
select set_config('t.hoy', ((now() at time zone 'America/Caracas')::date)::text, false);
select t('reporte de hoy', $q$ (select (r->>'ventas_n') || ' ventas, total ' || (r->>'ventas') || ', con costo ' || (r->>'ventas_con_costo') || ', costo ' || (r->>'costo') || ', sin costo ' || (r->>'piezas_sin_costo') || ' piezas' from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r) x) $q$);
select t('ventas del reporte = suma de ventas activas de hoy', $q$ (select (jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->>'ventas')::numeric = (select sum(total) from jab_ventas where estado = 'activa')) $q$);
select t('costo = suma de cantidad × costo guardado', $q$ (select (jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->>'costo')::numeric = (select round(sum(vi.cantidad * vc.costo), 2) from jab_venta_items vi join jab_ventas v on v.id = vi.venta_id join jab_venta_item_costos vc on vc.venta_item_id = vi.id where v.estado = 'activa' and vc.costo is not null)) $q$);
select t('gastos del local = 10 (bolsas); mercancía y flete aparte', $q$ (select (r->>'gastos') || ' | invertido ' || (r->>'invertido') || ' | abonos retenidos ' || (r->>'abonos_retenidos') from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r) x) $q$);
select t('ganancia por día suma la bruta', $q$ (select (select sum((d->>'ganancia')::numeric) from jsonb_array_elements(r->'por_dia') d) = round((r->>'ventas_con_costo')::numeric - (r->>'costo')::numeric, 2) from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r) x) $q$);
select t('lo más vendido', $q$ (select string_agg((x->>'nombre') || ':' || (x->>'unidades'), ', ') from jsonb_array_elements(jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->'top') x) $q$);
select t('fechas al revés', $q$ jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date - 1) $q$, 'Revisa las fechas');
select t('sin movimiento (0 días)', $q$ jsonb_array_length(jab_sin_movimiento(0)) > 0 $q$);
select set_config('t.ef', (select saldo from jab_saldos_cuentas() where cuenta_id = 1)::text, false);
reset role;
select 'saldo efectivo $ antes del cierre: ' || current_setting('t.ef');
select como('B'); set role authenticated;
select t('B no ve reportes', $q$ jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) $q$, 'dueña');
select t('B cierra sin contar el Bs', $q$ jab_registrar_cierre('{"conteos":[{"cuenta_id":1,"contado":10}]}') $q$, 'Efectivo Bs');
select t('B cierra caja (faltan $3 en efectivo)', $q$ jab_registrar_cierre(jsonb_build_object('clave','66666666-6666-6666-6666-666666666666','nota','fin del día','conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado', current_setting('t.ef')::numeric - 3), jsonb_build_object('cuenta_id',2,'contado',200)))) $q$);
select t('reintento del cierre no duplica', $q$ jab_registrar_cierre(jsonb_build_object('clave','66666666-6666-6666-6666-666666666666','conteos','[]'::jsonb)) is not null $q$);
select t('B no ve lo esperado', $q$ (select count(*) from jab_cierres) $q$);
reset role;
select como('A'); set role authenticated;
select t('A ve el cierre con diferencia −3', $q$ (select numero || ' dif=' || diferencia_usd || ' ' || (detalle->0->>'nombre') || ' esperado=' || (detalle->0->>'esperado') || ' contado=' || (detalle->0->>'contado') from jab_cierres order by id desc limit 1) $q$);
select t('A cuadra con lo contado', $q$ (select jab_revisar_cierre((select max(id) from jab_cierres), true)) $q$);
select t('efectivo quedó igual a lo contado', $q$ (select jab_saldos_cuentas.saldo = current_setting('t.ef')::numeric - 3 from jab_saldos_cuentas() where cuenta_id = 1) $q$);
select t('revisar dos veces', $q$ (select jab_revisar_cierre((select max(id) from jab_cierres), true)) $q$, 'ya fue revisado');
select t('ajuste del cierre fuera de los gastos', $q$ (select (jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->>'gastos')::numeric = 10) $q$);
select set_config('t.ef2', (select saldo from jab_saldos_cuentas() where cuenta_id = 1)::text, false);
select set_config('t.bs2', (select saldo from jab_saldos_cuentas() where cuenta_id = 2)::text, false);
reset role;

-- Revisión: dos cierres con la misma diferencia no se cuadran dos veces
select como('B'); set role authenticated;
select t('B cierra con $10 menos', $q$ jab_registrar_cierre(jsonb_build_object('conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado', current_setting('t.ef2')::numeric - 10), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs2')::numeric)))) $q$);
select t('B vuelve a cerrar (se le cerró la hoja)', $q$ jab_registrar_cierre(jsonb_build_object('conteos', jsonb_build_array(jsonb_build_object('cuenta_id',1,'contado', current_setting('t.ef2')::numeric - 10), jsonb_build_object('cuenta_id',2,'contado', current_setting('t.bs2')::numeric)))) $q$);
select t('B no ve lo cobrado por método (cierre a ciegas)', $q$ (select coalesce(r->>'cobrado_usd', 'null') || ' ' || (r->'por_metodo')::text from (select jab_resumen_dia(current_setting('t.hoy')::date) r) x) $q$);
reset role;
select set_config('t.ci1', (select id from jab_cierres order by id desc offset 1 limit 1)::text, false);
select como('A'); set role authenticated;
select t('A cuadra el cierre viejo', $q$ (select jab_revisar_cierre(current_setting('t.ci1')::bigint, true)) $q$, 'más nuevo');
select t('A cuadra el más reciente', $q$ (select jab_revisar_cierre((select max(id) from jab_cierres), true)) $q$);
select t('efectivo bajó $10 una sola vez', $q$ (select saldo - current_setting('t.ef2')::numeric from jab_saldos_cuentas() where cuenta_id = 1) $q$);
select t('el viejo quedó incluido', $q$ (select nota_revision from jab_cierres where id = current_setting('t.ci1')::bigint) $q$);
select t('lo aplicado quedó anotado', $q$ (select ajuste::text from jab_cierres order by id desc limit 1) $q$);
select t('descuadres del día en el reporte = ajustes de cierre', $q$ (select (jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)->>'descuadres')::numeric
  = (select round(sum(monto_usd), 2) from jab_movimientos_dinero where categoria = 'Cierre de caja' and anulado_en is null)) $q$);
select t('A sí ve lo cobrado por método', $q$ (select (r->>'cobrado_usd') is not null and jsonb_array_length(r->'por_metodo') > 0 from (select jab_resumen_dia(current_setting('t.hoy')::date) r) x) $q$);

-- Revisión: cambio de una prenda vendida sin costo (y que después se le cargó)
select t('prenda sin costo', $q$ jab_guardar_producto('{"nombre":"Prueba sin costo","precio":20,"variantes":[{"talla":"U","stock":2}]}') $q$);
select set_config('t.vsc', (select v.id from jab_variantes v join jab_productos p on p.id = v.producto_id where p.nombre = 'Prueba sin costo')::text, false);
select t('se vende sin costo', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vsc')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$);
select set_config('t.vvsc', (select max(id) from jab_ventas)::text, false);
select set_config('t.r0', jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date)::text, false);
reset role;
insert into jab_producto_costos (producto_id, costo) select producto_id, 5 from jab_variantes where id = current_setting('t.vsc')::bigint
  on conflict (producto_id) do update set costo = excluded.costo;
select como('A'); set role authenticated;
select t('cambio por la misma prenda (ya con costo $5)', $q$ jab_registrar_cambio(jsonb_build_object('venta_origen_id', current_setting('t.vvsc')::bigint, 'cliente_id', 1,
  'devueltos', jsonb_build_array(jsonb_build_object('venta_item_id',(select id from jab_venta_items where venta_id = current_setting('t.vvsc')::bigint),'cantidad',1)),
  'entregados', jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vsc')::bigint,'cantidad',1)))) $q$);
select t('ganancia sube $15 y sale de "sin costo"', $q$ (select 'bruta +' || (((r->>'ventas_con_costo')::numeric - (r->>'costo')::numeric) - ((r0->>'ventas_con_costo')::numeric - (r0->>'costo')::numeric))
  || ', sin costo ' || ((r->>'piezas_sin_costo')::int - (r0->>'piezas_sin_costo')::int)
  from (select jab_reporte(current_setting('t.hoy')::date, current_setting('t.hoy')::date) r, current_setting('t.r0')::jsonb r0) x) $q$);
reset role;
select 'funciones jab_ abiertas a anon: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_%' and has_function_privilege('anon', oid, 'execute');
select 'internas abiertas a authenticated: ' || count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'jab\_\_%' and has_function_privilege('authenticated', oid, 'execute');
