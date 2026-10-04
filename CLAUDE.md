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

1. **RLS de Supabase:** toda tabla nueva nace bloqueada. Si una app no lee datos o falla el login en tablas nuevas, es esto. Siempre incluir: `ALTER TABLE x ENABLE ROW LEVEL SECURITY;` + `CREATE POLICY "..." ON x FOR ALL USING (true) WITH CHECK (true);`
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
    - Respaldos hechos: `respaldo_20261004`, `respaldo_20261004b`, `respaldo_20261004c`.

## Lo que ya está hecho (no rehacer)

- **Mayorista completo:** panel de control con KPIs, clientes con plazos 30/60 días, facturas con vencimiento automático, abonos repartidos a lo más viejo, saldo a favor automático, precios pactados por cliente, nota de entrega y estado de cuenta en PDF corporativo, envío directo por WhatsApp, estadísticas con Chart.js, exportar CSV, editar/anular con recálculo, drawer móvil. Integrado al portal.
- **Créditos (Apartados):** cuenta consolidada por cliente (varios créditos = una tarjeta con la suma), "pago a la cuenta" que reparte entre créditos con vista previa, mensaje de confirmación y resumen de cuenta por WhatsApp con lista completa de productos, navegación que vuelve a donde empezaste, eliminación de intereses idempotente.
- **Pedido rápido en mayorista (2026-10-04):** botón "Pedido rápido" (vista Facturas) y "Pegar pedido de Notas" (modal factura). Pega el texto de Notas (`Pedido PEDRAZA 30.09` + `2 - Congelador Mystic 200lt 215×2 =430`), lo interpreta (`prParsearPedido`), enlaza al catálogo activo (`prBuscarCandidatos`: núcleo + marca obligatoria + números exactos; litros/kg ±10% y color distinto solo se proponen en amarillo), vista previa con 4 estados (verde/amarillo/gris + "Agregar al catálogo"/rojo sin precio), detecta cliente (ofrece crearlo) y fecha, compara con el `Total` de la nota, y pasa a `NF_ITEMS`. El precio de la nota siempre manda. Columnas nuevas: `may_facturas.origen` ('manual'|'pedido_rapido'), `may_facturas.texto_pedido`, `may_factura_items.costo_unitario` (costo al vender; hoy null porque el catálogo no tiene costos). Al guardar una factura nueva se ofrece enviar por WhatsApp la factura + saldo total del cliente (`mensajeFacturaConSaldo`). El tramo puro está entre `// PR-PURO-INICIO` / `// PR-PURO-FIN` y se prueba en Node con los pedidos reales.
- **Verificador de cuadre (2026-10-04):** botón "Verificar cuadre" en Estadísticas (solo admin, función `verificarCuadre()`). Solo lee. Compara cada crédito/apartado con abonos, intereses y productos reales, y detecta posibles abonos repetidos. Para créditos, el total de productos se lee del texto `productos_descripcion` (último `$monto` de cada línea). Helpers nuevos: `traerTodoBD()`, `sumaInteresesVivos()`, `redondear2()`, `confirmarSiPagoRepetido()`.
- **Arreglos del 2026-10-04:** editar un crédito/apartado ya conserva los intereses (antes los borraba del total: causó #158, #182, #198, #232, #416); aplicar interés reconstruye el total desde la base (antes sumaba sobre memoria: #97); aviso de pago repetido antes de guardar un abono (15 min, misma fecha y monto). Los 6 créditos se corrigieron en la base con rastro en `historial_auditoria` (`usuario_nombre = 'Claude Code (autorizado por Kinan)'`). Intereses perdonados de #182 quedaron en $0 con nota "PERDONADO".

## Pendientes conocidos

1. ~~Verificador de cuadre~~ **HECHO el 2026-10-04.** Pendiente menor: crédito #62 PASCUAL RODRÍGUEZ tiene dos abonos de $20 el 2026-06-14 con 1 s de diferencia; Kinan debe confirmar con Fayssal si fue uno solo. Hay 1 interés huérfano en el crédito eliminado #309 (inofensivo).
2. **Tope de crédito por cliente** según su score, con aviso al crear uno nuevo.
3. **Cartera por antigüedad:** cuánto al día / 1-30 / 31-60 / +60 días vencido.
4. **Migrar login de `Inventario_Yumana_App.html`** a Supabase Auth (hoy usa tabla propia con contraseña en texto plano). Riesgo medio, no hacerlo en horario de venta.
5. **Seguridad:** hay una API key de Google expuesta en el código de CxC y la key de Supabase sin restricción de dominio.
6. **Limpiar archivos muertos del repo** (ver tabla arriba). Borrarlos requiere confirmación de Kinan.
7. **`gestion.html` no existe pero el portal lo muestra:** la tabla `portal_apps` tiene la fila `gestion` (orden 7) apuntando a `gestion.html`, archivo que no está en el repo — esa tarjeta da error 404. La gestión de permisos vive dentro de `control.html`. Desactivar esa fila.
8. Etapa 2 mayorista: descuento de stock real del inventario al facturar.
10. **Import de catálogo desde Valery (CSV/Excel)** con precio, **costo** y existencia: empareja por `codigo_valery`, agrega lo nuevo, actualiza, no borra. El catálogo actual es una foto del 2026-06-08 y **ningún producto tiene costo** → sin esto no hay ganancia. Kinan puede exportar de Valery.
11. **Ciclo completo del producto con ganancia** (visión de Kinan, remodelación en 2-3 meses): estados en tienda → apartado → crédito → vendido sin salir → por entregar → en delivery → entregado y verificado, usando `inv_ventas`, `inv_venta_items.estado_item`, `inv_movimientos`, `inv_solicitudes_deposito`; panel de ganancia (venta − costo); login único con roles para delegar. Valery queda solo para la factura legal.
9. Modo offline/PWA para los cortes de internet.
