// Arma mapa_yumana.html CIFRADO para publicar en el repo público.
// Las 5 piezas locales (plano, contenido, gráficos, escena, interfaz) van cifradas con AES-256-GCM;
// la llave sale de la clave con PBKDF2-SHA256 (600.000 vueltas). En el archivo publicado solo queda
// la carcasa (estilos y marcado vacío), el candado y el texto cifrado: sin la clave no se lee nada.
// Uso: MAPA_CLAVE='xxxx-xxxx-xxxx-xxxx' node herramientas/mapa/cifrar.js [salida]   (ver LEEME.md)
// La clave NUNCA se escribe en el repo ni en este archivo.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const clave = (process.env.MAPA_CLAVE || '').trim();
if (clave.length < 16) throw new Error('Falta MAPA_CLAVE (mínimo 16 caracteres)');
const BUILD = path.join(__dirname, 'build');          // piezas sin cifrar (carpeta ignorada por git)
const SHELL = path.join(__dirname, 'shell.html');
const SALIDA = process.argv[2] || path.join(__dirname, '..', '..', 'mapa_yumana.html');
const PIEZAS = ['layout.js', 'contenido.js', 'graficos.js', 'escena.js', 'ui.js'];
const VUELTAS = 600000;

let html = fs.readFileSync(SHELL, 'utf8');
const piezas = [];
for (const nombre of PIEZAS) {
  const re = new RegExp(`\\s*<script\\s+src=["']${nombre.replace('.', '\\.')}["']\\s*>\\s*</script>`);
  if (!re.test(html)) throw new Error(`shell.html no carga ${nombre}`);
  execFileSync('node', ['--check', path.join(BUILD, nombre)]);
  piezas.push({ nombre, codigo: fs.readFileSync(path.join(BUILD, nombre), 'utf8') });
  html = html.replace(re, '');
}

// Cifrado
const sal = crypto.randomBytes(16), iv = crypto.randomBytes(12);
const llave = crypto.pbkdf2Sync(clave.toLowerCase(), sal, VUELTAS, 32, 'sha256');
const c = crypto.createCipheriv('aes-256-gcm', llave, iv);
const cifrado = Buffer.concat([c.update(JSON.stringify(piezas), 'utf8'), c.final(), c.getAuthTag()]);
const paquete = { v: 1, it: VUELTAS, sal: sal.toString('base64'), iv: iv.toString('base64'), datos: cifrado.toString('base64') };

// Mientras no se abra, solo se ve el candado (sin parpadeo del resto)
const estiloCandado = `<style>
  html:not(.abierto) body > *:not(#candado){visibility:hidden !important;}
  #candado{position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:24px;background:
    radial-gradient(1200px 600px at 80% -10%, rgba(212,162,78,0.07), transparent 60%), var(--bg, #0d0f14);}
  #candado .cd-tarjeta{width:100%;max-width:420px;background:linear-gradient(180deg,var(--surface,#1a1f2b),var(--bg-2,#141821));border:1px solid var(--border,#2a3344);border-radius:24px;padding:40px 32px;box-shadow:0 18px 50px rgba(0,0,0,0.45);position:relative;overflow:hidden;}
  #candado .cd-tarjeta::before{content:'';position:absolute;top:0;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,var(--gold,#d4a24e),transparent);}
  #candado .cd-marca{display:flex;align-items:center;gap:12px;}
  #candado .cd-emblema{width:46px;height:46px;border-radius:13px;background:linear-gradient(135deg,#d4a24e,#9c7330);display:flex;align-items:center;justify-content:center;font-family:'Fraunces',Georgia,serif;font-weight:700;font-size:26px;color:#1a1206;}
  #candado .cd-nombre{font-family:'Fraunces',Georgia,serif;font-size:22px;font-weight:600;color:var(--text,#eef2f8);line-height:1.1;}
  #candado .cd-sub{font-size:12px;color:var(--gold-soft,#e8c583);letter-spacing:3px;text-transform:uppercase;margin-top:3px;font-weight:500;}
  #candado h1{font-family:'Fraunces',Georgia,serif;font-size:26px;font-weight:500;color:var(--text,#eef2f8);margin:30px 0 6px;}
  #candado p{color:var(--text-2,#9aa6b8);font-size:14px;line-height:1.5;margin:0 0 22px;}
  #candado label.cd-et{display:block;font-size:12px;color:var(--text-2,#9aa6b8);text-transform:uppercase;letter-spacing:1px;margin-bottom:8px;font-weight:600;}
  #candado input[type=password]{width:100%;box-sizing:border-box;background:var(--bg,#0d0f14);border:1px solid var(--border,#2a3344);border-radius:13px;padding:15px 16px;color:var(--text,#eef2f8);font-size:16px;font-family:inherit;outline:none;letter-spacing:1px;}
  #candado input[type=password]:focus{border-color:var(--gold,#d4a24e);box-shadow:0 0 0 3px rgba(212,162,78,0.18);}
  #candado .cd-rec{display:flex;align-items:center;gap:10px;margin:16px 0 4px;color:var(--text-2,#9aa6b8);font-size:14px;min-height:44px;}
  #candado .cd-rec input{width:20px;height:20px;accent-color:#d4a24e;}
  #candado button{width:100%;margin-top:10px;background:linear-gradient(135deg,#d4a24e,#9c7330);color:#1a1206;border:none;border-radius:13px;padding:16px;font-size:16px;font-weight:700;font-family:inherit;cursor:pointer;min-height:48px;}
  #candado button:disabled{opacity:0.6;cursor:wait;}
  #candado button:focus-visible{outline:2px solid #e8c583;outline-offset:3px;}
  #candado .cd-msg{margin-top:14px;font-size:14px;min-height:20px;color:#e8755c;text-align:center;}
  #candado .cd-nota{margin-top:18px;font-size:12px;color:var(--muted,#5f6b80);text-align:center;}
</style>`;
html = html.replace('</head>', estiloCandado + '\n</head>');

const candado = `
<div id="candado" role="dialog" aria-modal="true" aria-labelledby="cdTitulo">
  <form class="cd-tarjeta" id="candadoForm" autocomplete="on">
    <div class="cd-marca"><div class="cd-emblema" aria-hidden="true">Y</div><div><div class="cd-nombre">Mercantil Yumana</div><div class="cd-sub">Mapa de operaciones</div></div></div>
    <h1 id="cdTitulo">Mapa protegido</h1>
    <p>Tiene cifras del negocio y nombres del personal. Escribe la clave para abrirlo.</p>
    <input type="text" name="usuario" value="mapa-yumana" autocomplete="username" hidden>
    <label class="cd-et" for="candadoClave">Clave</label>
    <input type="password" id="candadoClave" name="clave" autocomplete="current-password" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="xxxx-xxxx-xxxx-xxxx" required>
    <label class="cd-rec"><input type="checkbox" id="candadoRecordar" checked> Recordar en este equipo</label>
    <button type="submit" id="candadoBtn">Abrir mapa</button>
    <div class="cd-msg" id="candadoMsg" role="status" aria-live="polite"></div>
    <div class="cd-nota">Solo para administración de Mercantil Yumana</div>
  </form>
</div>
<script id="mapa-cifrado" type="application/json">${JSON.stringify(paquete)}</script>
<script>
(function () {
  'use strict';
  var D = document, cand = D.getElementById('candado'), form = D.getElementById('candadoForm'),
      inp = D.getElementById('candadoClave'), rec = D.getElementById('candadoRecordar'),
      msg = D.getElementById('candadoMsg'), btn = D.getElementById('candadoBtn');
  var paq = JSON.parse(D.getElementById('mapa-cifrado').textContent);
  var LS = 'yumana_mapa_clave';
  function bytes(b64) { var s = atob(b64), u = new Uint8Array(s.length); for (var i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return u; }
  function leer() { try { return localStorage.getItem(LS); } catch (e) { return null; } }
  function guardar(c) { try { localStorage.setItem(LS, c); } catch (e) { /* sin almacenamiento: se pedirá de nuevo */ } }
  function olvidar() { try { localStorage.removeItem(LS); } catch (e) { /* nada */ } }
  async function descifrar(clave) {
    if (!window.crypto || !crypto.subtle) throw new Error('sin-crypto');
    var base = await crypto.subtle.importKey('raw', new TextEncoder().encode(clave.trim().toLowerCase()), 'PBKDF2', false, ['deriveKey']);
    var llave = await crypto.subtle.deriveKey({ name: 'PBKDF2', salt: bytes(paq.sal), iterations: paq.it, hash: 'SHA-256' }, base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    var plano = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes(paq.iv) }, llave, bytes(paq.datos));
    return JSON.parse(new TextDecoder().decode(plano));
  }
  function ejecutar(piezas) {
    piezas.forEach(function (p) { var s = D.createElement('script'); s.textContent = p.codigo + '\\n//# sourceURL=' + p.nombre; D.body.appendChild(s); });
  }
  async function abrir(clave, recordar, automatico) {
    btn.disabled = true; msg.style.color = '#9aa6b8'; msg.textContent = automatico ? 'Abriendo…' : 'Comprobando la clave…';
    var piezas;
    try { piezas = await descifrar(clave); }
    catch (e) {
      btn.disabled = false; msg.style.color = '#e8755c';
      if (automatico) { olvidar(); msg.textContent = ''; inp.focus(); return; }
      msg.textContent = e && e.message === 'sin-crypto' ? 'Este navegador no puede abrir el mapa. Ábrelo en Safari o Chrome actualizados.' : 'Clave incorrecta. Revisa las letras, los números y los guiones.';
      inp.select(); return;
    }
    if (recordar) guardar(clave.trim().toLowerCase()); else olvidar();
    D.documentElement.classList.add('abierto');
    cand.parentNode.removeChild(cand);
    ejecutar(piezas);
  }
  form.addEventListener('submit', function (e) { e.preventDefault(); if (inp.value.trim()) abrir(inp.value, rec.checked, false); });
  var guardada = leer();
  if (guardada) abrir(guardada, true, true); else inp.focus();
})();
</script>
`;
const fin = html.lastIndexOf('</body>');
if (fin < 0) throw new Error('shell.html sin </body>');
html = html.slice(0, fin) + candado + html.slice(fin);
if (/<script\s+src=["'](?!https:)/.test(html)) throw new Error('quedó un script local sin cifrar');

// Validación: los scripts en línea que quedan (candado) pasan node --check
const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'mapa-c-'));
[...html.matchAll(/<script(?![^>]*\b(src|type)=)[^>]*>([\s\S]*?)<\/script>/g)].forEach((m, i) => {
  const f = path.join(tmp, `b${i}.js`); fs.writeFileSync(f, m[2]); execFileSync('node', ['--check', f]);
});
fs.writeFileSync(SALIDA, html);
console.log(`OK ${SALIDA} · ${(Buffer.byteLength(html) / 1024).toFixed(0)} KB · ${piezas.length} piezas cifradas (AES-256-GCM, PBKDF2 ${VUELTAS})`);
