// Saca las 5 piezas del mapa cifrado (mapa_yumana.html) a herramientas/mapa/build/ para editarlas.
// Esa carpeta está en .gitignore: lo que hay ahí va SIN cifrar y nunca se sube.
// Uso: MAPA_CLAVE='xxxx-xxxx-xxxx-xxxx' node herramientas/mapa/descifrar.js [archivo_cifrado]
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const clave = (process.env.MAPA_CLAVE || '').trim();
if (!clave) throw new Error('Falta MAPA_CLAVE');
const ORIGEN = process.argv[2] || path.join(__dirname, '..', '..', 'mapa_yumana.html');
const m = fs.readFileSync(ORIGEN, 'utf8').match(/<script id="mapa-cifrado" type="application\/json">([^<]*)<\/script>/);
if (!m) throw new Error(`${ORIGEN} no trae el paquete cifrado`);
const paq = JSON.parse(m[1]);
const llave = crypto.pbkdf2Sync(clave.toLowerCase(), Buffer.from(paq.sal, 'base64'), paq.it, 32, 'sha256');
const datos = Buffer.from(paq.datos, 'base64');
const d = crypto.createDecipheriv('aes-256-gcm', llave, Buffer.from(paq.iv, 'base64'));
d.setAuthTag(datos.subarray(datos.length - 16));
let plano;
try { plano = Buffer.concat([d.update(datos.subarray(0, datos.length - 16)), d.final()]).toString('utf8'); }
catch (e) { throw new Error('Clave incorrecta'); }
const BUILD = path.join(__dirname, 'build');
fs.mkdirSync(BUILD, { recursive: true });
for (const pieza of JSON.parse(plano)) {
  fs.writeFileSync(path.join(BUILD, pieza.nombre), pieza.codigo);
  console.log('OK', pieza.nombre, (Buffer.byteLength(pieza.codigo) / 1024).toFixed(0) + ' KB');
}
