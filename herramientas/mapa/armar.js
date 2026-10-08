// Arma el mapa SIN cifrar en un solo HTML para mirarlo en local (pruebas). Nunca dentro del repo: el repo es público.
// Uso: node herramientas/mapa/armar.js [salida]   (por defecto: carpeta temporal del sistema)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const BUILD = path.join(__dirname, 'build');
const REPO = path.resolve(__dirname, '..', '..');
const SALIDA = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'mapa_yumana_plano.html'));
if (SALIDA.startsWith(REPO + path.sep)) throw new Error('La versión sin cifrar no puede ir dentro del repo');
const LOCALES = ['layout.js', 'contenido.js', 'graficos.js', 'escena.js', 'ui.js'];

let html = fs.readFileSync(path.join(__dirname, 'shell.html'), 'utf8');
for (const nombre of LOCALES) {
  const re = new RegExp(`<script\\s+src=["']${nombre.replace('.', '\\.')}["']\\s*>\\s*</script>`);
  if (!re.test(html)) throw new Error(`shell.html no carga ${nombre}`);
  const codigo = fs.readFileSync(path.join(BUILD, nombre), 'utf8');
  if (/<\/script/i.test(codigo)) throw new Error(`${nombre} contiene un cierre de script literal`);
  execFileSync('node', ['--check', path.join(BUILD, nombre)]);
  html = html.replace(re, () => `<script>/* ${nombre} */\n${codigo}\n</script>`);
}
if (/<script\s+src=["'](?!https:)/.test(html)) throw new Error('quedó un script local sin meter en línea');

// Validación final (regla del CLAUDE.md): extraer cada <script> en línea y correr node --check.
const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'mapa-'));
const bloques = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
bloques.forEach((b, i) => {
  const f = path.join(tmp, `bloque_${i}.js`);
  fs.writeFileSync(f, b);
  execFileSync('node', ['--check', f]);
});
if (/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(html)) console.warn('AVISO: hay emojis en el HTML');
fs.writeFileSync(SALIDA, html);
console.log(`OK ${SALIDA} · ${(Buffer.byteLength(html) / 1024).toFixed(0)} KB · ${bloques.length} scripts validados con node --check`);
