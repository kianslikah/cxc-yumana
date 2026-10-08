# JABELLA Store

Contexto para Claude Code. Leer completo antes de tocar cualquier archivo.

## Qué es esto

Sistema de **JABELLA Store** (@jabella.store), tienda de ropa al detal de **Albany** en Socopó, Barinas, Venezuela. Lo administra Kinan Slikah (su pareja). **Es un negocio aparte de Mercantil Yumana.**

**Dónde vive (decisión de Kinan, 2026-10-08):** por ahora se monta sobre la infraestructura de Yumana para no crear cuentas nuevas, pero **aislado**:
- Web: carpeta `jabella/` del repo `kianslikah/cxc-yumana` → **https://app.mercantilyumana.com/jabella/**
- Base: el mismo proyecto Supabase de Yumana (`tkkiuxaamdyfbildcvtp`), pero **todo con prefijo `jab_`** (tablas, funciones, bucket `jab-fotos`, Edge Function `jab-usuarios`). Las cuentas de Jabella no ven nada de Yumana y las de Yumana no ven nada de Jabella (RLS con `jab_es_activo()` / `jab_es_duena()`).
- **Regla de oro: nada de Jabella toca a Yumana.** Nunca `... all tables/functions in schema public`, nunca tocar tablas sin `jab_`, nunca cambiar `default privileges`. Respaldo de Yumana antes de cada tanda de cambios (regla de Yumana).
- **Plan futuro: separarlo** a su propio proyecto y repo. Como todo lleva `jab_`, se copian esas tablas, la carpeta `jabella/` y la función, y se cambia `js/config.js`.

Albany compra la ropa en **SHEIN Estados Unidos**, la manda a su casillero en Miami (envío expreso), pide reempaque cuando llegan todos los paquetes y la trae por avión a **$6,99 la libra** (se cobra el mayor entre peso real y volumétrico; ese precio ya incluye todo hasta Socopó). **El flete de una caja se reparte en partes iguales entre todas las piezas** y se suma al precio de SHEIN de cada una = costo real. El precio de venta lo decide ella prenda por prenda.

**ES PRODUCCIÓN CON DINERO REAL.** No hay ambiente de pruebas.

## Cómo trabajar con Kinan

- Español siempre. Pasos exactos, sin teoría. Kinan no es programador y trabaja desde iPhone/iPad.
- Agrupar cambios en una entrega; diagnosticar en el código y los datos antes de proponer.
- Validar antes de entregar: `node --check` a cada JS, pruebas de la base en Postgres local y prueba visual con Playwright cuando se pueda.
- Publicación directa a `main` (GitHub Pages), un commit claro por entrega para poder revertir.
- El repo es **público**: nunca escribir claves secretas. Solo la key publishable de Supabase va en `js/config.js`.

## Stack

- HTML/CSS/JS puro, sin build. `index.html` + `css/app.css` + `js/*.js` (un archivo por sección).
- Hosting: GitHub Pages del repo de Yumana (carpeta `jabella/`, rama `main`). Versionar los `?v=N` en `index.html` en cada entrega (Safari cachea fuerte).
- Backend: Supabase de Yumana, objetos `jab_` (plan Pro, respaldo diario). URL y key en `js/config.js`.
- Sesión propia: el cliente usa `storageKey: 'jabella-sesion'`, así la sesión de Jabella no se mezcla con la de las apps de Yumana en el mismo dominio.
- Se instala en el iPhone como app (Compartir → Agregar a inicio). `manifest.webmanifest` + íconos en `img/`.

## Diseño

Colores del logo: lila `#e6b8dd`, ciruela `#8e4f84` (acciones), fondo `#fbf7fa`. Letras: **Bodoni Moda** (títulos) + **Jost** (texto). Íconos SVG de un color, cero emojis. Inputs de 16 px mínimo (iOS), selectores a pantalla completa en vez de menús flotantes.

## Usuarios y roles

- Entran con **usuario** (no correo): por dentro es `usuario@jabella.app` (nunca se envían correos).
- `duena`: todo. `vendedora`: vende, abona, entrega apartados, hace cambios (con la venta original), ve existencia; **no** ve costos, ganancias, dinero ni auditoría; no cambia precios, no anula, no fía (salvo `config.vendedora_fia`).
- Usuarios se crean con la Edge Function `jab-usuarios` (llave de servicio solo en el servidor; solo toca usuarios que estén en `jab_usuarios`, nunca cuentas de Yumana). Acciones: `bootstrap` (primera dueña; ya usada, quedó cerrada), `crear`, `clave`. Al entrar por primera vez se obliga a cambiar la clave.
- Usuario de Albany: `albany` (dueña), creado el 2026-10-08.
- Si Albany olvida su clave: otra dueña se la cambia desde Ajustes; si no hay otra, Claude la puede cambiar por SQL (`auth.users.encrypted_password = crypt(..., gen_salt('bf'))` solo para su id de `jab_usuarios`) y marcar `debe_cambiar_clave = true`.

## Base de datos (ver `supabase/migrations/`; todos los nombres llevan `jab_` delante)

- `usuarios`, `config` (fila única: tasa, días de apartado, % abono mínimo, vendedora_fia, tarifa_libra), `tasas` (historial).
- `cuentas` (dónde está el dinero, USD o VES) y `metodos_pago` (cada método va a una cuenta; "Saldo a favor" es especial).
- `clientes` (borrado suave `deleted_at`), `saldo_favor_mov` (saldo = suma).
- `productos` (código JB-0001 automático), `variantes` (talla/color/stock), `producto_costos` (solo dueña), `movimientos_inventario` (todo cambio de existencia queda aquí).
- `ventas` (`numero` corrido sin huecos vía `contadores`; tipo contado/apartado/fiado/cambio; estado activa/cancelada/anulada), `venta_items` (cantidad negativa = devuelta en un cambio, `item_origen_id`), `venta_item_costos` (costo al momento, solo dueña), `pagos` (en $ y Bs con tasa), `movimientos_dinero` (gastos, retiros, transferencias, ajustes), `auditoria`.

## REGLAS (no romper)

1. **Toda escritura de dinero o existencia va por una función RPC** (`jab_registrar_venta`, `jab_registrar_abono`, `jab_registrar_cambio`, `jab_anular_venta`, `jab_anular_pago`, `jab_cancelar_apartado`, `jab_entregar_apartado`, `jab_extender_apartado`, `jab_guardar_producto`, `jab_ajustar_stock`, `jab_registrar_movimiento`…). Ventas, abonos, cambios, gastos y prendas nuevas llevan una `clave` única (anti-repetición si se cae el internet). Las RPC validan rol, bloquean filas (`FOR UPDATE`, variantes en orden de id) y recalculan `pagado` desde los pagos vivos. Nunca escribir directo desde el JS en esas tablas.
2. **RLS en toda tabla nueva**, solo personal activo (`jab_es_activo()`) o solo dueña (`jab_es_duena()`). Nunca `USING (true)`. Funciones internas `jab__x` sin EXECUTE para nadie; las RPC solo para `authenticated`. **Supabase da EXECUTE a todos por defecto en funciones nuevas**: cada entrega debe revocar explícitamente en sus funciones `jab_` (ver el bloque al final de la migración).
3. **Límite de 1000 filas**: siempre `traerTodo()` en el JS.
4. **Anti-doble-clic**: todo botón de guardar usa `protegerBoton()`.
5. **Tasa**: el cobro en Bs manda `monto` (Bs), `tasa` y `monto_usd`; el servidor valida que cuadren (medio centavo), que la tasa sea la del día y que se haya puesto **hoy**. La vendedora solo la confirma o ajusta hasta 5 %; todo cambio queda en `jab_auditoria`.
6. Correcciones de dinero dejan rastro en `auditoria` (antes y después). Nada se borra: se anula.
7. Venezuela es UTC−4 fijo; "hoy" se calcula con `America/Caracas`.

## Pruebas

- `supabase/pruebas/escenarios.sql`: 111 escenarios de negocio para correr en un Postgres local con los stubs de `supabase/pruebas/stubs.sql` (simulan `auth.uid()`, roles y storage). Todo debe dar `ok`.
- El conector de Supabase se cuelga con `DELETE` (regla de Yumana): en la base real probar dentro de un bloque `do $$ … raise exception … $$` para que todo se deshaga.

## Entregas

Ver `docs/HISTORIAL.md`. Pendiente: entrega 2 (compras SHEIN, paquetes, reempaque, embarque, aduana, recepción y costo real con flete repartido por pieza) y entrega 3 (reportes de ganancia, cierre de caja de la vendedora, gastos del mes).
