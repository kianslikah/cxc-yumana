-- Cómo correr: crear una base vacía en un Postgres local, aplicar stubs.sql, luego las migraciones,
-- y después: psql -f escenarios.sql. Cada línea debe empezar con "ok" (los "!!!" son fallas).
\set QUIET 1
\pset format unaligned
\pset tuples_only on
create function public.t(label text, q text, expect_err text default null) returns void language plpgsql as $$
declare r text;
begin
  execute 'select (' || q || ')::text' into r;
  if expect_err is not null then raise notice '!!! % → esperaba error (%) pero dio: %', label, expect_err, r;
  else raise notice 'ok  % → %', label, r; end if;
exception when others then
  if expect_err is null then raise notice '!!! % → ERROR: %', label, sqlerrm;
  elsif position(lower(expect_err) in lower(sqlerrm)) = 0 then raise notice '!!! % → error distinto: %', label, sqlerrm;
  else raise notice 'ok  % → (error esperado) %', label, sqlerrm; end if;
end $$;
grant execute on function public.t to authenticated;
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-00000000000a','albany@x'),('00000000-0000-0000-0000-00000000000b','vende@x'),('00000000-0000-0000-0000-00000000000c','inactiva@x');
insert into public.jab_usuarios (id, usuario, nombre, rol, activo) values
 ('00000000-0000-0000-0000-00000000000a','albany','Albany','duena',true),
 ('00000000-0000-0000-0000-00000000000b','maria','María','vendedora',true),
 ('00000000-0000-0000-0000-00000000000c','exvend','Ex','vendedora',false);
create or replace function public.como(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', case u when 'A' then '00000000-0000-0000-0000-00000000000a' when 'B' then '00000000-0000-0000-0000-00000000000b' else '00000000-0000-0000-0000-00000000000c' end, 'role','authenticated')::text, false)
$$;

-- ===== DUEÑA =====
select como('A'); set role authenticated;
select t('tasa 40', $q$ (select jab_actualizar_tasa(40)) $q$);
select t('producto blusa', $q$ jab_guardar_producto('{"nombre":"Blusa lino","categoria":"Blusas","precio":15,"costo":5,"variantes":[{"talla":"M","color":"Negro","stock":3},{"talla":"L","color":"Negro","stock":1}]}') $q$);
select t('producto sin talla', $q$ jab_guardar_producto('{"nombre":"X","precio":5,"variantes":[]}') $q$, 'al menos una talla');
select t('producto talla repetida', $q$ jab_guardar_producto('{"nombre":"Y","precio":5,"variantes":[{"talla":"S"},{"talla":"S"}]}') $q$, 'repetida');
select t('codigo', $q$ (select codigo from jab_productos where id=1) $q$);
reset role;

-- ===== VENDEDORA =====
select como('B'); set role authenticated;
select t('B no ve costos', $q$ (select count(*) from jab_producto_costos) $q$);
select t('B no crea producto', $q$ jab_guardar_producto('{"nombre":"Z","precio":5,"variantes":[{"talla":"S"}]}') $q$, 'dueña');
select t('B venta contado M $', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":15}]}') $q$);
select set_config('t.v1', (select max(id) from jab_ventas)::text, false);
select t('stock M=2', $q$ (select stock from jab_variantes where id=1) $q$);
select t('B cambia precio', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1,"precio":10}],"pagos":[{"metodo_id":1,"monto_usd":10}]}') $q$, 'Solo la dueña puede cambiar');
select t('B cobra de menos', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":10}]}') $q$, 'Falta cobrar');
select t('B cobra de más', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":20}]}') $q$, 'mayor que el total');
select t('B tasa vieja', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":2,"cantidad":1}],"pagos":[{"metodo_id":3,"monto_usd":15,"monto":525,"tasa":35}]}') $q$, 'tasa del día cambió');
select t('B Bs no cuadra', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":2,"cantidad":1}],"pagos":[{"metodo_id":3,"monto_usd":15,"monto":500,"tasa":40}]}') $q$, 'no cuadra');
select t('B venta L en Bs', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":2,"cantidad":1}],"pagos":[{"metodo_id":3,"monto_usd":15,"monto":600,"tasa":40}]}') $q$);
select set_config('t.v2', (select max(id) from jab_ventas)::text, false);
select t('B L agotada', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":2,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":15}]}') $q$, 'No hay existencia');
select t('stock L=0 tras fallo', $q$ (select stock from jab_variantes where id=2) $q$);
insert into jab_clientes (nombre, telefono) values ('Carla Pérez','04141234567'); select t('B creó clienta', $q$ (select count(*) from jab_clientes) $q$);
select t('B apartado sin clienta', $q$ jab_registrar_venta('{"tipo":"apartado","items":[{"variante_id":1,"cantidad":2}],"pagos":[{"metodo_id":1,"monto_usd":15}]}') $q$, 'Elige la clienta');
select t('B apartado abono bajo', $q$ jab_registrar_venta('{"tipo":"apartado","cliente_id":1,"items":[{"variante_id":1,"cantidad":2}],"pagos":[{"metodo_id":1,"monto_usd":10}]}') $q$, 'abono mínimo');
select t('B apartado ok (#3)', $q$ jab_registrar_venta('{"tipo":"apartado","cliente_id":1,"items":[{"variante_id":1,"cantidad":2}],"pagos":[{"metodo_id":1,"monto_usd":15}]}') $q$);
select set_config('t.ap', (select max(id) from jab_ventas)::text, false);
select t('apartado vence en días', $q$ (select vence_en - (now() at time zone 'America/Caracas')::date from jab_ventas where id=current_setting('t.ap')::bigint) $q$);
select t('apartado datos', $q$ (select tipo||' entregada='||entregada||' pagado='||pagado||' total='||total from jab_ventas where id=current_setting('t.ap')::bigint) $q$);
select t('stock M=0 reservado', $q$ (select stock from jab_variantes where id=1) $q$);
select t('B entrega sin pagar', $q$ (select jab_entregar_apartado(current_setting('t.ap')::bigint)) $q$, 'Falta pagar');
select t('B abono de más', $q$ jab_registrar_abono(current_setting('t.ap')::bigint, '[{"metodo_id":1,"monto_usd":20}]') $q$, 'mayor que lo que debe');
select t('B abono 15', $q$ jab_registrar_abono(current_setting('t.ap')::bigint, '[{"metodo_id":6,"monto_usd":15}]') $q$);
select t('B entrega', $q$ (select jab_entregar_apartado(current_setting('t.ap')::bigint)) $q$);
select t('B abono a pagada', $q$ jab_registrar_abono(current_setting('t.ap')::bigint, '[{"metodo_id":1,"monto_usd":1}]') $q$, 'ya está pagada');
select t('B fiado', $q$ jab_registrar_venta('{"tipo":"fiado","cliente_id":1,"items":[{"variante_id":1,"cantidad":1}]}') $q$, 'Solo la dueña puede vender fiado');
select t('B ajusta stock', $q$ (select jab_ajustar_stock(1, 5, 'conteo')) $q$, 'dueña');
select t('B no ve dinero', $q$ (select count(*) from jab_movimientos_dinero) $q$);
select t('B saldos', $q$ (select count(*) from jab_saldos_cuentas()) $q$, 'dueña');
select t('B anula', $q$ (select jab_anular_venta(current_setting('t.v1')::bigint, 'x')) $q$, 'dueña');
do $$ begin insert into jab_ventas (tipo,total) values ('contado',1); raise notice '!!! B insertó venta directo'; exception when others then raise notice 'ok  B no inserta venta directo → %', sqlerrm; end $$;
do $$ declare n int; begin update jab_variantes set stock = 99 where id = 1; get diagnostics n = row_count; raise notice 'B edita stock directo: filas=%', n; exception when others then raise notice 'ok  B no edita stock → %', sqlerrm; end $$;
reset role;
select 'stock M sin cambios: ' || stock from jab_variantes where id = 1;

-- ===== DUEÑA otra vez =====
select como('A'); set role authenticated;
select t('A ajusta M=5', $q$ (select jab_ajustar_stock(1, 5, 'conteo')) $q$);
select t('A fiado (#4)', $q$ jab_registrar_venta('{"tipo":"fiado","cliente_id":1,"items":[{"variante_id":1,"cantidad":1}]}') $q$);
select set_config('t.fi', (select max(id) from jab_ventas)::text, false);
select t('A precio especial (#5)', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1,"precio":12}],"pagos":[{"metodo_id":1,"monto_usd":12}]}') $q$);
select set_config('t.pe', (select max(id) from jab_ventas)::text, false);
reset role;

-- ===== CAMBIOS =====
select como('B'); set role authenticated;
select t('B cambio sin venta', $q$ jab_registrar_cambio('{"devueltos":[{"variante_id":1,"cantidad":1}]}') $q$, 'busca la venta original');
select t('B cambio sin clienta (venta 1)', $q$ jab_registrar_cambio('{"venta_origen_id":1,"devueltos":[{"venta_item_id":1,"cantidad":1}]}') $q$, 'Elige la clienta');
select t('B cambio de más', $q$ jab_registrar_cambio('{"venta_origen_id":1,"cliente_id":1,"devueltos":[{"venta_item_id":1,"cantidad":2}]}') $q$, 'solo quedan 1');
select t('B cambio item ajeno', $q$ jab_registrar_cambio('{"venta_origen_id":1,"cliente_id":1,"devueltos":[{"venta_item_id":2,"cantidad":1}]}') $q$, 'no es de la venta');
select t('B cambio → saldo favor (#6)', $q$ jab_registrar_cambio('{"venta_origen_id":1,"cliente_id":1,"devueltos":[{"venta_item_id":1,"cantidad":1}]}') $q$);
select set_config('t.ca', (select max(id) from jab_ventas)::text, false);
select t('saldo favor clienta', $q$ (select sum(monto) from jab_saldo_favor_mov where cliente_id=1) $q$);
select t('B cambio repetido', $q$ jab_registrar_cambio('{"venta_origen_id":1,"cliente_id":1,"devueltos":[{"venta_item_id":1,"cantidad":1}]}') $q$, 'solo quedan 0');
select t('B paga fiado con saldo favor', $q$ jab_registrar_abono(current_setting('t.fi')::bigint, '[{"metodo_id":8,"monto_usd":15}]') $q$);
select t('B saldo favor agotado', $q$ jab_registrar_abono(current_setting('t.fi')::bigint, '[{"metodo_id":8,"monto_usd":1}]') $q$, 'ya está pagada');
select t('B cambio con diferencia (#7)', $q$ jab_registrar_cambio(jsonb_build_object('venta_origen_id', current_setting('t.v2')::bigint, 'devueltos', jsonb_build_array(jsonb_build_object('venta_item_id',(select id from jab_venta_items where venta_id=current_setting('t.v2')::bigint),'cantidad',1)), 'entregados', '[{"variante_id":1,"cantidad":2}]'::jsonb, 'pagos','[{"metodo_id":1,"monto_usd":15}]'::jsonb)) $q$);
reset role;

-- ===== ANULACIONES =====
select como('A'); set role authenticated;
select t('A anula venta con cambio', $q$ (select jab_anular_venta(current_setting('t.v1')::bigint, 'error')) $q$, 'Primero anula el cambio');
select t('A anula cambio cuyo saldo se usó', $q$ (select jab_anular_venta(current_setting('t.ca')::bigint, 'error')) $q$, 'ya usó el saldo');
select t('A anula pago con saldo favor', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id=current_setting('t.fi')::bigint and cuenta_id is null), 'prueba')) $q$);
select t('saldo favor devuelto', $q$ (select sum(monto) from jab_saldo_favor_mov where cliente_id=1) $q$);
select t('A anula cambio', $q$ (select jab_anular_venta(current_setting('t.ca')::bigint, 'error')) $q$);
select t('saldo favor tras anular cambio', $q$ (select sum(monto) from jab_saldo_favor_mov where cliente_id=1) $q$);
select t('A anula venta 1', $q$ (select jab_anular_venta(current_setting('t.v1')::bigint, 'error')) $q$);
select t('A anula contado sin motivo', $q$ (select jab_anular_venta(current_setting('t.pe')::bigint, '')) $q$, 'motivo');
select t('A anula pago de contado sin clienta', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id=current_setting('t.pe')::bigint), 'x')) $q$, 'no tiene clienta');
select t('A apartado para cancelar (#8)', $q$ jab_registrar_venta('{"tipo":"apartado","cliente_id":1,"items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":8}]}') $q$);
select set_config('t.ap2', (select max(id) from jab_ventas)::text, false);
select t('A extiende', $q$ jab_extender_apartado(current_setting('t.ap2')::bigint, 5) $q$);
select t('A cancela (tienda)', $q$ (select jab_cancelar_apartado(current_setting('t.ap2')::bigint, 'tienda')) $q$);
select t('apartado cancelado', $q$ (select estado||' retenido='||abono_retenido from jab_ventas where id=current_setting('t.ap2')::bigint) $q$);
select t('A apartado (#9)', $q$ jab_registrar_venta('{"tipo":"apartado","cliente_id":1,"items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":10}]}') $q$);
select set_config('t.ap3', (select max(id) from jab_ventas)::text, false);
select t('A cancela (saldo favor)', $q$ (select jab_cancelar_apartado(current_setting('t.ap3')::bigint, 'saldo_favor')) $q$);
select t('saldo favor', $q$ (select sum(monto) from jab_saldo_favor_mov where cliente_id=1) $q$);
select t('A gasto', $q$ jab_registrar_movimiento('{"tipo":"gasto","cuenta_id":1,"monto":10,"categoria":"Bolsas"}') $q$);
select t('A cambio $→Bs', $q$ jab_registrar_movimiento('{"tipo":"transferencia","cuenta_id":1,"monto":5,"cuenta_destino_id":2,"monto_destino":200}') $q$);
select t('A saldo inicial Zelle', $q$ jab_registrar_movimiento('{"tipo":"ajuste","cuenta_id":4,"monto":100,"descripcion":"Saldo inicial"}') $q$);
select t('saldos', $q$ (select string_agg(nombre||'='||saldo, ', ') from jab_saldos_cuentas()) $q$);
select t('resumen hoy', $q$ jab_resumen_dia(jab__hoy()) $q$, 'permission denied');
select t('resumen hoy', $q$ jab_resumen_dia((now() at time zone 'America/Caracas')::date) $q$);
select t('A config', $q$ (select jab_actualizar_config('{"dias_apartado":20,"vendedora_fia":true}')) $q$);
select t('A se quita dueña', $q$ (select jab_actualizar_usuario('00000000-0000-0000-0000-00000000000a','Albany','vendedora',true)) $q$, 'al menos una dueña');
reset role;

-- ===== INACTIVA =====
select como('C'); set role authenticated;
select t('C no ve productos', $q$ (select count(*) from jab_productos) $q$);
select t('C ve su usuario', $q$ (select activo from jab_usuarios where id = auth.uid()) $q$);
select t('C no vende', $q$ jab_registrar_venta('{"tipo":"contado","items":[{"variante_id":1,"cantidad":1}],"pagos":[{"metodo_id":1,"monto_usd":15}]}') $q$, 'no está activo');
reset role;
-- anon
set role anon;
select t('anon no lee', $q$ (select count(*) from jab_productos) $q$, 'permission denied');
reset role;


-- ===== CORRECCIONES DE LA REVISIÓN =====
select como('A'); set role authenticated;
select t('A crea falda', $q$ jab_guardar_producto('{"nombre":"Falda plisada","categoria":"Faldas","precio":20,"costo":8,"variantes":[{"talla":"S","stock":10}]}') $q$);
select set_config('t.pf', (select max(id) from jab_productos)::text, false);
select set_config('t.vf', (select max(id) from jab_variantes)::text, false);
-- Anti-repetición (se cayó el internet y reintenta)
select t('venta con clave', $q$ jab_registrar_venta(jsonb_build_object('clave','11111111-1111-1111-1111-111111111111','tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$);
select set_config('t.idem', (select max(id) from jab_ventas)::text, false);
select t('reintento con la misma clave = misma venta', $q$ jab_registrar_venta(jsonb_build_object('clave','11111111-1111-1111-1111-111111111111','tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) = current_setting('t.idem')::bigint $q$);
select t('falda descontada una sola vez (9)', $q$ (select stock from jab_variantes where id = current_setting('t.vf')::bigint) $q$);
select t('fiado falda', $q$ jab_registrar_venta(jsonb_build_object('tipo','fiado','cliente_id',1,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)))) $q$);
select set_config('t.fi2', (select max(id) from jab_ventas)::text, false);
select t('abono con clave', $q$ jab_registrar_abono(current_setting('t.fi2')::bigint, '[{"metodo_id":1,"monto_usd":5}]', '22222222-2222-2222-2222-222222222222') $q$);
select t('reintento del abono no repite', $q$ jab_registrar_abono(current_setting('t.fi2')::bigint, '[{"metodo_id":1,"monto_usd":5}]', '22222222-2222-2222-2222-222222222222') $q$);
select t('pagado del fiado = 5', $q$ (select pagado from jab_ventas where id = current_setting('t.fi2')::bigint) $q$);
-- Anular el mismo pago dos veces
select t('anula abono', $q$ (select jab_anular_pago((select max(id) from jab_pagos where venta_id = current_setting('t.fi2')::bigint), 'prueba')) $q$);
select t('anula el mismo abono otra vez', $q$ (select jab_anular_pago((select max(id) from jab_pagos where venta_id = current_setting('t.fi2')::bigint), 'prueba')) $q$, 'ya está anulado');
-- Apartado entregado y su pago anulado -> pasa a fiado
select t('apartado falda pagado', $q$ jab_registrar_venta(jsonb_build_object('tipo','apartado','cliente_id',1,'items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":6,"monto_usd":20}]'::jsonb)) $q$);
select set_config('t.ap4', (select max(id) from jab_ventas)::text, false);
select t('entrega', $q$ (select jab_entregar_apartado(current_setting('t.ap4')::bigint)) $q$);
select t('pago móvil falso: anula pago', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id = current_setting('t.ap4')::bigint), 'no llegó')) $q$);
select t('quedó como fiado debiendo 20', $q$ (select tipo || ' ' || (total - pagado) from jab_ventas where id = current_setting('t.ap4')::bigint) $q$);
-- Contado sin clienta con pago anulado
select t('contado falda', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$);
select set_config('t.c5', (select max(id) from jab_ventas)::text, false);
select t('anular pago sin clienta', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id = current_setting('t.c5')::bigint), 'billete falso')) $q$, 'no tiene clienta');
select t('anular pago anotando a la clienta', $q$ (select jab_anular_pago((select id from jab_pagos where venta_id = current_setting('t.c5')::bigint), 'billete falso', 1)) $q$);
select t('contado pasó a fiado', $q$ (select tipo || ' cliente=' || cliente_id || ' debe=' || (total - pagado) from jab_ventas where id = current_setting('t.c5')::bigint) $q$);
select t('stock no volvió (falda=6)', $q$ (select stock from jab_variantes where id = current_setting('t.vf')::bigint) $q$);
reset role;
select como('B'); set role authenticated;
select t('B saldo a favor a otra clienta', $q$ jab_registrar_cambio(jsonb_build_object('venta_origen_id', current_setting('t.ap4')::bigint, 'cliente_id', 99, 'devueltos', jsonb_build_array(jsonb_build_object('venta_item_id',(select id from jab_venta_items where venta_id=current_setting('t.ap4')::bigint),'cantidad',1)))) $q$, 'venta original');
select set_config('t.sf_antes', (select coalesce(sum(monto),0) from jab_saldo_favor_mov where cliente_id=1)::text, false);
select t('B cambio sobre fiado: abona la deuda', $q$ jab_registrar_cambio(jsonb_build_object('venta_origen_id', current_setting('t.ap4')::bigint, 'devueltos', jsonb_build_array(jsonb_build_object('venta_item_id',(select id from jab_venta_items where venta_id=current_setting('t.ap4')::bigint),'cantidad',1)))) $q$);
select t('fiado quedó en 0', $q$ (select total - pagado from jab_ventas where id = current_setting('t.ap4')::bigint) $q$);
select t('saldo a favor sin cambio', $q$ (select coalesce(sum(monto),0) = current_setting('t.sf_antes')::numeric from jab_saldo_favor_mov where cliente_id=1) $q$);
select t('B tasa +2,5 por ciento', $q$ (select jab_actualizar_tasa(41)) $q$);
select t('B tasa +25 por ciento', $q$ (select jab_actualizar_tasa(50)) $q$, '5 por ciento');
select t('B venta vacía', $q$ jab_registrar_venta('{"tipo":"contado"}') $q$, 'no tiene prendas');
select t('B cambio vacío', $q$ jab_registrar_cambio(jsonb_build_object('venta_origen_id', current_setting('t.c5')::bigint)) $q$, 'Elige la prenda');
reset role;
update public.jab_config set tasa_actualizada_en = now() - interval '2 days';
select como('B'); set role authenticated;
select t('B cobra en Bs con tasa de otro día', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":3,"monto_usd":20,"monto":820,"tasa":41}]'::jsonb)) $q$, 'no se ha puesto hoy');
select t('B confirma la misma tasa', $q$ (select jab_actualizar_tasa(41)) $q$);
select t('B ya puede cobrar en Bs', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":3,"monto_usd":20,"monto":820,"tasa":41}]'::jsonb)) $q$);
reset role;
select como('A'); set role authenticated;
select t('A ve cambios de tasa en auditoría', $q$ (select count(*) >= 3 from jab_auditoria where accion = 'cambio_tasa') $q$);
select t('A archiva la falda', $q$ jab_guardar_producto(jsonb_build_object('id', current_setting('t.pf')::bigint, 'nombre','Falda plisada','precio',20,'activo',false)) $q$);
select t('no se vende archivada', $q$ jab_registrar_venta(jsonb_build_object('tipo','contado','items',jsonb_build_array(jsonb_build_object('variante_id',current_setting('t.vf')::bigint,'cantidad',1)),'pagos','[{"metodo_id":1,"monto_usd":20}]'::jsonb)) $q$, 'archivada');
select t('cancelar apartado sin destino', $q$ (select jab_cancelar_apartado(1, null)) $q$, 'Elige qué pasa');
select t('función interna cerrada', $q$ (select jab__idem_inicio(null, 'x')) $q$, 'permission denied');
reset role;
insert into public.jab_productos (id, nombre, precio) overriding system value values (10000, 'Prueba código', 1);
select 'código 10000: ' || codigo from public.jab_productos where id = 10000;

-- ===== CUADRE FINAL =====
select 'stock M=' || (select stock from jab_variantes where id=1) || ' L=' || (select stock from jab_variantes where id=2);
select 'existencia = suma de movimientos en todas las tallas: ' || bool_and(v.stock = coalesce((select sum(cantidad) from jab_movimientos_inventario m where m.variante_id = v.id), 0)) from jab_variantes v;
select 'ventas: ' || string_agg(numero||':'||tipo||'/'||estado||' total='||total||' pagado='||pagado, ' | ' order by id) from jab_ventas;
select 'pagado cuadra: ' || bool_and(v.pagado = coalesce((select sum(monto_usd) from jab_pagos p where p.venta_id=v.id and anulado_en is null),0)) from jab_ventas v;
