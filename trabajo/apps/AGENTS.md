# Apps del ecosistema (cambiar, crear y publicar)

Las apps son HTML, CSS y JavaScript puro: un archivo por app, sin frameworks y sin compilar.
Se publican en GitHub Pages: subir a `main` = en vivo en `app.mercantilyumana.com` en ~1 minuto.

La lista de apps vivas (y de los archivos muertos que **nunca** se editan) está en el `CLAUDE.md` de la raíz.

## Estándar visual (no negociable: idéntico, no parecido)

- Letras: Fraunces (marca y login) + Outfit (todo lo demás).
- Colores: fondo `#0d0f14`, dorado `#d4a24e`, dorado claro `#e8c583`, dorado oscuro `#9c7330`, superficies `#1a1f2b` y `#212838`, bordes `#2a3344`, texto sobre dorado `#1a1206`.
- Íconos SVG de un solo color. **Cero emojis.**
- Estilo iPhone (desde `estadisticas.html`): títulos grandes, celdas planas muy redondeadas, control segmentado, en el teléfono barra abajo y tablas como listas.
- PDFs: dorado `#9c7330`, crema `#f5ead2`. Columnas: Cantidad → Producto → Precio (en negrita) → Subtotal.

## Reglas técnicas

- iPhone/iPad: inputs de 16 px mínimo; `input[type=date]` con `-webkit-appearance:none; width:100% !important`; buscadores a pantalla completa en vez de menús flotantes.
- Buscadores con `debounce`; listas de 80 en 80 con "Mostrar más".
- Paginar toda consulta (Supabase corta en 1.000 filas sin avisar).
- Botones de guardar con `protegerBoton()`.
- Fecha de hoy con `hoyLocal()`, nunca UTC.
- Solo la key pública de Supabase puede ir en el HTML. Ninguna otra clave.

## Pasos de una entrega

1. Diagnosticar en el código y en los datos antes de cambiar. Leer por partes, no el archivo completo.
2. Agrupar todos los cambios pedidos.
3. Validar: extraer los `<script>` y correr `node --check`.
4. Probar en pantalla (Playwright, tamaño iPhone 390 px y PC) cuando se pueda.
5. Revisar con las skills (ver `.claude/skills/LEEME.md`):
   - Entrega grande o que toca dinero: `/thermos` y corregir lo que marque.
   - Vista nueva o rediseñada: `/anti-slop-audit <archivo>` y después `/anti-slop-fix`.
   - Cambios chicos: no hace falta. Las skills gastan tokens: no repetir la revisión de una app ya revisada.
6. Subir el número de versión (`?v=...`) de la app en el portal, porque Safari guarda copias viejas.
7. Anotar la entrega en `docs/HISTORIAL.md`.
8. Un commit claro por entrega y subir directo a `main` (Kinan lo autorizó). Así, si dice "deshaz lo último", se hace con `git revert`.
9. Decirle a Kinan qué cambió, en palabras simples.

## Casos especiales

- `mapa_yumana.html` va cifrado. Se edita solo con `herramientas/mapa/` (ver su `LEEME.md`). Nunca subir las piezas sin cifrar.
- `estadisticas.html`: los cálculos viven en las funciones `est_*` de la base, no en la app.
