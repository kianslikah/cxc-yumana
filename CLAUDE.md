# Ecosistema Mercantil Yumana

Contexto para Claude Code. Leer COMPLETO antes de tocar cualquier archivo.

## Qué es esto

Ecosistema de apps web internas de **Mercantil Yumana**: tienda de electrodomésticos, muebles y colchones en Socopó, Barinas, Venezuela. Dueño: Kinan Slikah, junto a su padre Fayssal. Las apps manejan la operación real: créditos, apartados, proveedores, inventario, ventas y mayoreo.

**TODO ESTO ES PRODUCCIÓN CON DINERO REAL.** Un error de saldo es plata perdida o un cliente reclamando. No hay ambiente de pruebas.

## Cómo trabajar con Kinan

- **Español siempre**, en respuestas y comentarios de código.
- Pasos exactos y concretos. Sin rodeos, sin teoría.
- Estilo directo: cuestionar lo que no cuadre, no aprobar todo.
- **Agrupar varios cambios en una entrega.** Odia el ciclo de probar-subir-probar por cada cambio chico.
- **Diagnosticar antes de proponer.** Si algo falla, ir al código y a los datos — no mandarlo a probar a ciegas.
- Kinan no es programador y trabaja desde iPad/iPhone. Entregar cosas funcionando, no explicaciones técnicas.
- **Validar antes de entregar**: extraer los `<script>` y correr `node --check`. Probar visualmente cuando se pueda.
- Decir claramente cuándo una tarea terminó y cuándo empieza otra.
- - **Publicación directa (autorizado por Kinan):** después de validar (`node --check` + prueba visual cuando se pueda), Claude Code sube los cambios directo a `main` sin pedir confirmación en cada entrega. Una entrega = un commit claro, para poder deshacerla con `git revert` si Kinan dice "deshaz lo último".
- **Revisión antes de publicar (skills en `.claude/skills/`, ver `LEEME.md`):** en una entrega grande o que toque dinero, correr `/thermos` sobre el diff y corregir lo que marque antes de subir; en una vista nueva o rediseñada, correr `/anti-slop-audit <archivo>` y `/anti-slop-fix`. Para cambios chicos no hace falta. **Cuidar los tokens:** son caros (cada uno lanza 2 agentes); no re-auditar apps ya revisadas.
- **Una sesión por tarea:** Kinan paga por uso. Preferir sesiones cortas y no leer archivos completos de miles de líneas (usar Grep y lecturas por tramos).
- **Claves y API keys:** el repo es PÚBLICO. Nunca escribir claves secretas en el código ni en commits; solo la key pública de Supabase puede ir en los HTML.


## Stack

- **Frontend:** HTML/CSS/JavaScript puro. Un archivo por app. Sin frameworks, sin build.
- **Hosting:** GitHub Pages — este repo (`kianslikah/cxc-yumana`, rama `main`, raíz). Push a `main` = publicado en vivo en ~1 minuto.
- **Dominio:** `app.mercantilyumana.com`. (`mercantilyumana.com` sin el `app.` está reservado para la web pública futura.)
- **Backend:** Supabase (PostgreSQL + Auth).
  - URL: `https://tkkiuxaamdyfbildcvtp.supabase.co`
  - Key pública: `sb_publishable_oOCXiFi1MaOChwvqiLNSdg_IVfega0X`
- **Gráficos:** Chart.js 4.4.1 (cdnjs).

## Estándar visual (decisión firme, no negociable)

El diseño del Portal es el estándar de TODO el ecosistema. Kinan exige **idéntico, no parecido**.

- Tipografías: **Fraunces** (títulos) + **Outfit** (cuerpo).
- Paleta exacta: fondo `#0d0f14`, dorado `#d4a24e`, dorado claro `#e8c583`, dorado oscuro `#9c7330`, superficies `#1a1f2b` y `#212838`, bordes `#2a3344`, texto sobre dorado `#1a1206`.
- Íconos SVG monocromáticos. **Cero emojis en interfaces.**
- Layout de referencia: sidebar izquierdo de `mayorista.html` y `Proveedores_yumana.html`.
- PDFs corporativos: dorado `#9c7330`, crema `#f5ead2`. Columnas de productos en orden **Cantidad → Producto → Precio → Subtotal**, con precio en negrita.

## Apps (nombres EXACTOS, respetar mayúsculas)

| Archivo | Qué es | Login |
|---|---|---|
| `portal.html` | Entrada al ecosistema, tarjetas por rol (tablas `portal_apps` + `portal_permisos`) | Supabase Auth |
| `control.html` | Panel del dueño (solo admin): resumen, permisos, usuarios | Supabase Auth |
| `Apartados_Yumana_App.html` | **Créditos y apartados del detal. La app más grande (~9.800 líneas) y la más crítica.** | Supabase Auth |
| `Proveedores_yumana.html` | Facturas y pagos a proveedores. Trigger `trg_recalc_abonado` recalcula saldos | Supabase Auth |
| `mayorista.html` | Ventas al mayor (~1.900 líneas). Completo | Login propio, tabla `may_usuarios` |
| `Inventario_Yumana_App.html` | Catálogo de productos | **Login propio viejo (pendiente migrar)** |
| `Venta_prueba.html`, `zona_prueba.html` | Ventas/caja y zona de entrega | Supabase Auth |
| `mapa_yumana.html` | Mapa 3D de operaciones, análisis y protocolos. **Va cifrado:** se edita con `herramientas/mapa/` (ver su `LEEME.md`); nunca subir las piezas sin cifrar | Clave propia (candado) + tarjeta solo admin |

**JABELLA Store (negocio aparte, solo alojado aquí):** la carpeta `jabella/` es el sistema de la tienda de ropa de Albany (app.mercantilyumana.com/jabella/). Usa este mismo Supabase pero **aislado con prefijo `jab_`** (tablas, funciones, bucket `jab-fotos`, Edge Function `jab-usuarios`) y sus propios usuarios. No es parte de Yumana: no mezclar datos, no tocar objetos `jab_` desde las apps de Yumana ni objetos de Yumana desde Jabella. Su contexto está en `jabella/CLAUDE.md`. Plan futuro: mudarlo a su propio proyecto.

⚠️ **ARCHIVOS VIEJOS EN EL REPO — NO EDITARLOS NUNCA.** Quedaron versiones anteriores con nombres parecidos. Los vivos son los de la tabla de arriba. Estos están muertos:

| Archivo muerto | Por qué | Reemplazado por |
|---|---|---|
| `CxC_Yumana_App.html` | versión vieja de créditos | `Apartados_Yumana_App.html` |
| `Apartados_Yumana.html`, `Apartados_v2.html` | borradores viejos de créditos | `Apartados_Yumana_App.html` |
| `Proveedores_Yumana_App.html` | versión pre-migración, todavía usa `localStorage` | `Proveedores_yumana.html` (minúscula en "yumana", usa Supabase) |
| `Diagnostico.html`, `TestLogin.html` | archivos de prueba | — |
| `Cargador.html`, `subir fotos.html` | utilidades de carga puntuales | — |

Si una tarea menciona "créditos" o "proveedores" sin dar el nombre de archivo, usar el vivo de la tabla, nunca el muerto.

## Base de datos

- **Créditos/Apartados:** `creditos`, `apartados`, `clientes`, `abonos`, `intereses_aplicados`, `productos_apartado`, `usuarios_app`, `historial_auditoria`, `portal_apps`, `portal_permisos`
- **Catálogo compartido:** `inv_productos` — **su `id` es `bigint`, NO uuid**
- **Mayorista:** `may_clientes`, `may_facturas`, `may_factura_items` (`producto_id` bigint), `may_abonos`, `may_usuarios`, `may_precios_cliente` (UNIQUE cliente_id+producto_id)
- Borrado suave en casi todo: `deleted_at IS NULL` = activo.
- Roles del portal: `admin`, `cajera`, `lectura`, `logistica`.

## REGLAS CRÍTICAS (aprendidas a los golpes — romper una cuesta plata)

1. **RLS de Supabase:** toda tabla nueva nace bloqueada. Si una app no lee datos o falla el login en tablas nuevas, es esto. Siempre incluir: `ALTER TABLE x ENABLE ROW LEVEL SECURITY;` + `CREATE POLICY "solo_personal_activo" ON x FOR ALL TO authenticated USING (public.es_staff()) WITH CHECK (public.es_staff());`. **Nunca `USING (true)`**: deja la tabla abierta a cualquiera con la key pública (que está en el HTML de un repo público). Única excepción hoy: las tablas `may_*` mientras mayorista siga con login propio.
2. **Límite de 1000 filas:** Supabase corta las consultas en 1000 registros EN SILENCIO. Siempre paginar con `.range()` en bucle (helper `traerTodo()`). Ya causó "pérdida" visual de abonos.
3. **`monto_total` YA incluye el interés** en créditos/apartados. Saldo = `monto_total − pagado`. Nunca sumar el interés aparte.
4. **Interés:** columna `monto_interes` en `intereses_aplicados`. 10% compuesto sobre el saldo. Fecha = fecha del crédito + N meses (N = intereses previos + 1).
5. **Nunca restar sobre datos en memoria.** Al eliminar o ajustar montos, leer el registro FRESCO de la base. Mejor aún: **reconstruir desde la fuente de verdad** (subtotal + suma real de intereses vivos) para que la operación sea idempotente. Dos créditos se descuadraron por esto (#124 y #111).
6. **Anti-doble-clic obligatorio:** todo botón de guardar usa `protegerBoton()` — se deshabilita al primer clic. Un doble toque creó un descuadre de $17.
7. **Reparto de pagos:** en mayorista y en "pago a la cuenta" de créditos, se aplica a lo **más viejo primero**. Al anular o editar, recalcular TODO el cliente desde cero.
8. **iOS Safari:** `input[type=date]` se desborda → `-webkit-appearance:none; width:100% !important`. Inputs mínimo 16px para evitar auto-zoom. Dropdowns flotantes fallan con el teclado → usar buscador a pantalla completa.
9. **Caché agresiva en Safari/iPad:** versionar las URLs del portal (`?v=XX`) en cada entrega.
10. **Rendimiento:** los buscadores usan `debounce` y las listas se dibujan por partes (80 + "Mostrar más"). Sin eso, la PC se traba.
11. **Base de datos (autorizado por Kinan el 2026-10-04):** Claude Code trabaja la base directo con el conector de Supabase (proyecto `tkkiuxaamdyfbildcvtp`, plan Pro con backup diario automático). Reglas:
    - **Respaldo antes de cambiar:** antes de una tanda de cambios, copiar todas las tablas de `public` a un esquema `respaldo_AAAAMMDD` (`CREATE TABLE respaldo_x.t AS TABLE public.t`) y verificar que los conteos de filas coincidan. Revocar el acceso de `anon`/`authenticated` a ese esquema. Primer respaldo: `respaldo_20261004`. **Nunca borrar un esquema de respaldo sin permiso de Kinan.**
    - **Leer es libre:** las consultas de diagnóstico (SELECT) se hacen sin preguntar.
    - **Agregar sí, destruir no:** se pueden crear tablas, columnas, índices, funciones y políticas sin borrar nada de lo que ya existe.
    - **Lo peligroso se consulta:** antes de borrar datos, hacer DROP o TRUNCATE, o cambiar montos de créditos, abonos, facturas o saldos, explicarle a Kinan en palabras simples qué se va a hacer y a cuántos registros afecta, y esperar su "dale".
    - **Correcciones de dinero con rastro:** toda corrección de montos deja el valor de antes y el de después en `historial_auditoria`.
    - Usar `apply_migration` para cambios de estructura, para que queden registrados.
    - **El conector se cuelga con `DELETE`** (se queda esperando una confirmación que nunca llega y la transacción se deshace sola). Para quitar algo: borrado suave (`deleted_at`) o dejar la fila en $0 con nota explicativa (ej. intereses perdonados). Nunca `DELETE` desde el conector.
    - Respaldos hechos: `respaldo_20261004`, `respaldo_20261004b`, `respaldo_20261004c`, `respaldo_20261004d`, `respaldo_20261004e`, `respaldo_20261006`, `respaldo_20261007`, `respaldo_20261008` (trae además `funciones_antes_seguridad`, `vistas_antes_seguridad` y `politicas_antes_seguridad`), `respaldo_20261008b` (antes de crear lo de JABELLA), `respaldo_20261008c` (antes de las entregas 2 y 3 de JABELLA), `respaldo_20261009` (antes de traer el resto del sistema de cobros al mayorista).
    - **Usuarios (desde 2026-10-08):** una cuenta creada desde Créditos nace **inactiva y de solo lectura**; un admin la activa y le da su rol en Usuarios. Nadie que no sea admin puede cambiarse el rol ni activarse (trigger `trg_usuarios_app_proteger_rol`).

## Lo que ya está hecho (no rehacer)

El detalle completo de cada entrega (funciones, columnas, decisiones) está en **`docs/HISTORIAL.md`**. Leerlo antes de tocar una parte que ya se trabajó. Resumen:

- **Créditos:** cuenta consolidada, pago a la cuenta con `grupo_pago`, cobranza por días sin pagar, intereses perdonables, verificador de cuadre, operaciones que se deshacen si fallan a mitad. Helpers clave: `traerTodoBD`, `redondear2`, `saldoFrescoCuenta`, `reconstruirTotalCuenta`, `recalcularSaldoCuenta`/`recalcularOAvisar`, `esDeudaViva`, `marcarPartesGrupo`, `toast` en cola, `confirmAction(..., opts)`.
- **Mayorista:** completo + pedido rápido desde Notas. Abono/factura/anular por RPC atómicos (`may_registrar_abono`, `may_guardar_factura`, `may_anular_*`, `may_recalcular_cliente`).
- **Proveedores:** `prov_registrar_abono` y `prov_aplicar_saldo_favor` (RPC), devoluciones como abono, rastro en `prov_auditoria`.
- **Inventario, Portal, Control:** errores de guardado visibles, paginación con orden fijo, estados de carga.
- **Skills de revisión:** `.claude/skills/` (`/thermos`, `/anti-slop-audit`, `/anti-slop-fix`).

## Pendientes conocidos

1. ~~Verificador de cuadre~~ **HECHO el 2026-10-04.** Pendiente menor: crédito #62 PASCUAL RODRÍGUEZ tiene dos abonos de $20 el 2026-06-14 con 1 s de diferencia; Kinan debe confirmar con Fayssal si fue uno solo. Hay 1 interés huérfano en el crédito eliminado #309 (inofensivo).
2. **Tope de crédito por cliente** según su score, con aviso al crear uno nuevo.
3. ~~Cartera por antigüedad~~ **HECHO el 2026-10-04** (KPIs en Cobranza).
4. ~~Migrar login de Inventario~~ **Ya usa Supabase Auth.** Queda la tabla vieja `inv_usuarios` (1 fila, contraseña en texto plano): Kinan debe decidir si se desactiva. Desde el 2026-10-08 la base exige personal activo en Inventario, pero los permisos por rol (cajera vs admin) de Inventario y Control siguen solo en el navegador: endurecer con RLS por rol cuando se haga el login único.
5. **Seguridad (tanda del 2026-10-08 hecha, ver `docs/HISTORIAL.md`).** Falta: (a) pasar el login de mayorista a Supabase Auth y cerrar las tablas `may_*` (siguen abiertas con la key pública, y las claves de `may_usuarios` están en texto plano: cambiarlas después); (b) crear usuarios con una función del servidor y apagar el registro público en Supabase; (c) Kinan: activar "leaked password protection" en Supabase Auth. La key de Google que se mencionaba no aparece en el código ni en el historial de git. La key pública de Supabase no se puede restringir por dominio: la protección real son las políticas RLS.
6. **Limpiar archivos muertos del repo** (ver tabla arriba). Borrarlos requiere confirmación de Kinan.
7. ~~Tarjeta `gestion.html` 404~~ **HECHO el 2026-10-06** (`activa=false`).
14. **Clientes del mayor:** solo DANIEL Y FRAN (Socopó y Pedraza) vienen del sistema de cobros anterior. Los otros 9 del documento se cargaron y se retiraron el 2026-10-09 a pedido de Kinan: él pasará cada cliente detallado (nombre, teléfono, grupo de WhatsApp, plazo, deuda). NO volver a cargarlos desde el respaldo. PEDRAZA tiene 2 abonos USDT de $13 el 2026-06-02 con 4 s de diferencia: confirmar si fue uno solo.
12. **Devoluciones de proveedores perdidas (confirmar con Fayssal):** las devoluciones aceptadas Salcar $200,17 (jun) y Gtronic $905 (may) se sumaron al abonado a mano y el trigger las borró; sus facturas figuran pagadas solo con abonos. Si esos montos no se cobraron de otra forma, son saldo a favor que falta registrar.
13. **Venta y Zona** (`Venta_prueba.html`, `zona_prueba.html`) no se usan todavía. Antes de estrenarlas: conectar `inv_registrar_venta`, revisar errores ignorados en Zona (lista pendientes, búsqueda `.or()`, revertir entrega sin confirmación), emojis e inputs.
8. Etapa 2 mayorista: descuento de stock real del inventario al facturar.
10. **Import de catálogo desde Valery (CSV/Excel)** con precio, **costo** y existencia: empareja por `codigo_valery`, agrega lo nuevo, actualiza, no borra. El catálogo actual es una foto del 2026-06-08 y **ningún producto tiene costo** → sin esto no hay ganancia. Kinan puede exportar de Valery.
11. **Ciclo completo del producto con ganancia** (visión de Kinan, remodelación en 2-3 meses): estados en tienda → apartado → crédito → vendido sin salir → por entregar → en delivery → entregado y verificado, usando `inv_ventas`, `inv_venta_items.estado_item`, `inv_movimientos`, `inv_solicitudes_deposito`; panel de ganancia (venta − costo); login único con roles para delegar. Valery queda solo para la factura legal.
9. Modo offline/PWA para los cortes de internet.
