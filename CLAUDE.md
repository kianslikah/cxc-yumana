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

⚠️ **CUIDADO CON ARCHIVOS DUPLICADOS.** En el repo hay versiones viejas con nombres parecidos (`CxC_Yumana_App.html`, `Proveedores_Yumana_App.html`). **Antes de editar, confirmar con Kinan cuál es el archivo vivo.** Editar el equivocado = trabajo perdido y confusión.

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
11. **SQL:** Claude Code no toca la base. Entregar el SQL en texto para que Kinan lo corra en el SQL Editor de Supabase.

## Lo que ya está hecho (no rehacer)

- **Mayorista completo:** panel de control con KPIs, clientes con plazos 30/60 días, facturas con vencimiento automático, abonos repartidos a lo más viejo, saldo a favor automático, precios pactados por cliente, nota de entrega y estado de cuenta en PDF corporativo, envío directo por WhatsApp, estadísticas con Chart.js, exportar CSV, editar/anular con recálculo, drawer móvil. Integrado al portal.
- **Créditos (Apartados):** cuenta consolidada por cliente (varios créditos = una tarjeta con la suma), "pago a la cuenta" que reparte entre créditos con vista previa, mensaje de confirmación y resumen de cuenta por WhatsApp con lista completa de productos, navegación que vuelve a donde empezaste, eliminación de intereses idempotente.

## Pendientes conocidos

1. **Verificador de cuadre** (lo más urgente): un botón que revise todos los créditos y marque los que no cuadren con su historial de intereses y pagos. Hoy los descuadres se descubren de casualidad.
2. **Tope de crédito por cliente** según su score, con aviso al crear uno nuevo.
3. **Cartera por antigüedad:** cuánto al día / 1-30 / 31-60 / +60 días vencido.
4. **Migrar login de `Inventario_Yumana_App.html`** a Supabase Auth (hoy usa tabla propia con contraseña en texto plano). Riesgo medio, no hacerlo en horario de venta.
5. **Seguridad:** hay una API key de Google expuesta en el código de CxC y la key de Supabase sin restricción de dominio.
6. **Limpiar archivos duplicados del repo** (ver advertencia arriba).
7. Etapa 2 mayorista: descuento de stock real del inventario al facturar.
8. Modo offline/PWA para los cortes de internet.
