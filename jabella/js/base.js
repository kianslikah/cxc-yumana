// JABELLA — utilidades comunes: conexión, formato, avisos, ventanas y datos en memoria.
'use strict';

var sb = window.supabase.createClient(JAB_CONFIG.url, JAB_CONFIG.key, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'jabella-sesion' }
});

// Estado compartido en memoria (se recarga desde la base, nunca se usa para restar dinero)
var ST = {
  yo: null, cfg: null,
  productos: [], variantes: [], prodPorId: new Map(), varPorId: new Map(), varPorProducto: new Map(),
  costos: new Map(),
  clientes: [], cliPorId: new Map(),
  cuentas: [], metodos: [], usuarios: [], usrPorId: new Map()
};

/* ---------------- DOM y texto ---------------- */
function $(sel, root) { return (root || document).querySelector(sel); }
function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
function iniciales(nombre) {
  var p = String(nombre || '').trim().split(/\s+/);
  return ((p[0] || '')[0] || '') + ((p[1] || '')[0] || '');
}
function debounce(fn, ms) {
  var t; return function () { var a = arguments, self = this; clearTimeout(t); t = setTimeout(function () { fn.apply(self, a); }, ms || 250); };
}
function normalizar(s) {
  return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}

/* ---------------- Números y dinero ---------------- */
function redondear2(n) { return Math.round((Number(n) + Number.EPSILON) * 100) / 100; }
var _fmt2 = new Intl.NumberFormat('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
var _fmtTasa = new Intl.NumberFormat('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 });
function fmtUSD(n) { n = Number(n) || 0; return (n < -0.004 ? '−' : '') + '$' + _fmt2.format(Math.abs(n)); }
function fmtBs(n) { n = Number(n) || 0; return (n < -0.004 ? '−' : '') + 'Bs ' + _fmt2.format(Math.abs(n)); }
function fmtMonto(n, moneda) { return moneda === 'VES' ? fmtBs(n) : fmtUSD(n); }
function fmtTasa(n) { return _fmtTasa.format(Number(n) || 0); }
function fmtNum(n) { return _fmt2.format(Number(n) || 0); }

// Acepta "1.234,56", "1234.56", "12,5", "1.500" (= mil quinientos). Devuelve NaN si no es número.
function parseNum(txt) {
  if (typeof txt === 'number') return txt;
  var s = String(txt == null ? '' : txt).trim().replace(/\s|\$|bs\.?/gi, '');
  if (!s) return NaN;
  var nc = (s.match(/,/g) || []).length, np = (s.match(/\./g) || []).length;
  if (nc && np) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) s = s.replace(/\./g, '').replace(',', '.');
    else s = s.replace(/,/g, '');
  } else if (nc) {
    s = nc > 1 ? s.replace(/,/g, '') : s.replace(',', '.');
  } else if (np > 1 || /^\d{1,3}\.\d{3}$/.test(s)) {
    s = s.replace(/\./g, '');
  }
  if (!/^-?(\d+\.?\d*|\.\d+)$/.test(s)) return NaN;
  return parseFloat(s);
}

/* ---------------- Fechas (hora de Venezuela) ---------------- */
var TZ = 'America/Caracas';
function hoyCaracas() { return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date()); }
function fechaCaracas(ts) { return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date(ts)); }
function sumarDias(fecha, n) {
  var d = new Date(fecha + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}
function diasEntre(desde, hasta) {
  return Math.round((new Date(hasta + 'T12:00:00Z') - new Date(desde + 'T12:00:00Z')) / 86400000);
}
// Venezuela es UTC−4 todo el año
function rangoDia(fecha) { return [fecha + 'T00:00:00-04:00', sumarDias(fecha, 1) + 'T00:00:00-04:00']; }
function fmtFecha(f) {
  var d = /^\d{4}-\d{2}-\d{2}$/.test(f) ? new Date(f + 'T12:00:00-04:00') : new Date(f);
  return new Intl.DateTimeFormat('es-VE', { timeZone: TZ, day: 'numeric', month: 'short' }).format(d).replace('.', '');
}
function fmtFechaLarga(f) {
  var d = /^\d{4}-\d{2}-\d{2}$/.test(f) ? new Date(f + 'T12:00:00-04:00') : new Date(f);
  return new Intl.DateTimeFormat('es-VE', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' }).format(d);
}
function fmtHora(ts) {
  return new Intl.DateTimeFormat('es-VE', { timeZone: TZ, hour: 'numeric', minute: '2-digit' }).format(new Date(ts));
}
function fmtFechaHora(ts) { return fmtFecha(ts) + ', ' + fmtHora(ts); }

/* ---------------- Íconos (SVG de un solo color) ---------------- */
var ICONOS = {
  vender: '<path d="M5.5 8h13l-1.1 12H6.6L5.5 8z"/><path d="M9 8V6.5a3 3 0 0 1 6 0V8"/>',
  inventario: '<path d="M12 8.5c0-1 .6-1.4 1.2-1.9.6-.5 1-1 .8-1.9a2 2 0 0 0-3.9.3"/><path d="M12 8.5 3.4 15c-.9.7-.4 2 .7 2h15.8c1.1 0 1.6-1.3.7-2L12 8.5z"/>',
  ventas: '<path d="M7 3.5h10v17l-2.5-1.6-2.5 1.6-2.5-1.6L7 20.5v-17z"/><path d="M10 8.5h4M10 12h4"/>',
  clientes: '<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19.5c.6-3 2.8-4.7 5.5-4.7s4.9 1.7 5.5 4.7"/><circle cx="17" cy="9.5" r="2.4"/><path d="M16.2 14.8c2.3 0 3.8 1.4 4.3 3.9"/>',
  dinero: '<rect x="3" y="6.5" width="18" height="12.5" rx="2.2"/><path d="M3 10h18"/><path d="M15.5 15h2.5"/>',
  ajustes: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
  buscar: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  mas: '<path d="M12 5v14M5 12h14"/>',
  menos: '<path d="M5 12h14"/>',
  cerrar: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  camara: '<path d="M4 8.5h3.2l1.8-2.5h6l1.8 2.5H20V19H4z"/><circle cx="12" cy="13.5" r="3.3"/>',
  editar: '<path d="M4.5 19.5h4l10-10-4-4-10 10v4z"/><path d="m13 7 4 4"/>',
  enviar: '<path d="M20.5 3.5 3.5 10.5l7 2.5 2.5 7 7.5-16.5z"/><path d="m10.5 13 4-4"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  alerta: '<path d="M12 4.5 3 19.5h18L12 4.5z"/><path d="M12 10v4.2M12 16.8v.4"/>',
  basura: '<path d="M5 7h14M10 7V4.5h4V7M7 7l1 13h8l1-13"/>',
  salir: '<path d="M14 4.5h5v15h-5"/><path d="m10 8-4 4 4 4M6 12h10"/>',
  cambio: '<path d="M4.5 8.5h14l-3.2-3.2M19.5 15.5h-14l3.2 3.2"/>',
  calendario: '<rect x="4" y="5.5" width="16" height="14.5" rx="2"/><path d="M4 10h16M9 3.5v4M15 3.5v4"/>',
  flecha: '<path d="m9.5 6 6 6-6 6"/>',
  menu: '<circle cx="5.5" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="18.5" cy="12" r="1.2"/>',
  usuario: '<circle cx="12" cy="8.5" r="3.5"/><path d="M5 20c.8-3.6 3.6-5.5 7-5.5s6.2 1.9 7 5.5"/>',
  candado: '<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
  reloj: '<circle cx="12" cy="12" r="8"/><path d="M12 7.5V12l3 2"/>',
  reportes: '<path d="M4 20h16"/><path d="M7 16.5v-5M12 16.5V7M17 16.5v-8"/>',
  entregar: '<path d="M4 8.5 12 4l8 4.5v7L12 20l-8-4.5v-7z"/><path d="m4 8.5 8 4.5 8-4.5M12 13v7"/>'
};
function icono(n, clase) {
  return '<svg class="ic ' + (clase || '') + '" viewBox="0 0 24 24" aria-hidden="true">' + (ICONOS[n] || '') + '</svg>';
}

/* ---------------- Avisos ---------------- */
function toast(msg, tipo, ms) {
  var cont = $('#toasts');
  var el = document.createElement('div');
  el.className = 'toast ' + (tipo || '');
  el.textContent = msg;
  cont.appendChild(el);
  setTimeout(function () { el.remove(); }, ms || (tipo === 'error' ? 6000 : 3000));
}

// Convierte errores técnicos en mensajes que se entienden
function errMsg(e) {
  var m = (e && (e.message || e.error_description || e.error)) || String(e || 'Error');
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(m)) return 'Sin conexión. Revisa el internet y vuelve a intentar.';
  if (/jwt expired|invalid jwt|refresh token/i.test(m)) return 'Tu sesión venció. Vuelve a entrar.';
  if (/invalid login credentials/i.test(m)) return 'Usuario o clave incorrectos.';
  if (/row-level security|permission denied/i.test(m)) return 'No tienes permiso para hacer esto.';
  if (/duplicate key/i.test(m)) return 'Ese dato ya existe.';
  return m;
}

/* ---------------- Botones a prueba de doble toque ---------------- */
function protegerBoton(btn, fn, textoOcupado) {
  if (!btn) return;
  btn.addEventListener('click', async function (ev) {
    ev.preventDefault();
    if (btn.dataset.ocupado === '1') return;
    btn.dataset.ocupado = '1';
    btn.disabled = true;
    var original = btn.innerHTML;
    btn.textContent = textoOcupado || 'Guardando…';
    try {
      await fn(ev);
    } catch (e) {
      console.error(e);
      toast(errMsg(e), 'error');
    } finally {
      btn.dataset.ocupado = '0';
      if (btn.isConnected) { btn.disabled = false; btn.innerHTML = original; }
    }
  });
}

/* ---------------- Base de datos ---------------- */
async function rpc(nombre, args) {
  var r = await sb.rpc(nombre, args || {});
  if (r.error) throw r.error;
  return r.data;
}

// Supabase corta en 1000 filas sin avisar: siempre paginar
async function traerTodo(tabla, select, preparar, orden) {
  var todos = [], desde = 0, tam = 1000;
  while (true) {
    var q = sb.from(tabla).select(select || '*');
    if (preparar) q = preparar(q);
    q = q.order(orden || 'id', { ascending: true });
    var r = await q.range(desde, desde + tam - 1);
    if (r.error) throw r.error;
    var lote = r.data || [];
    todos = todos.concat(lote);
    if (lote.length < tam) break;
    desde += tam;
  }
  return todos;
}

// Código único por operación: si se cae el internet y se reintenta, la base no la repite
function nuevaClave() {
  if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
  var b = new Uint8Array(16); window.crypto.getRandomValues(b);
  b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
  var h = Array.prototype.map.call(b, function (x) { return (x + 256).toString(16).slice(1); }).join('');
  return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
}

// La tasa solo vale para cobrar si se puso hoy
function tasaDeHoy() {
  return !!(ST.cfg && ST.cfg.tasa_bs && ST.cfg.tasa_actualizada_en && fechaCaracas(ST.cfg.tasa_actualizada_en) === hoyCaracas());
}
function tasaVigente() { return tasaDeHoy() ? ST.cfg.tasa_bs : 0; }

// Apariencia: 'auto' (sigue al teléfono), 'claro' o 'noche'. Se guarda en este equipo.
function temaActual() { try { return localStorage.getItem('jabella-tema') || 'auto'; } catch (e) { return 'auto'; } }
function aplicarTema(t) {
  try { localStorage.setItem('jabella-tema', t); } catch (e) { /* modo privado */ }
  document.documentElement.setAttribute('data-tema', t);
  var oscuro = t === 'noche' || (t === 'auto' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', oscuro ? '#141016' : '#fbf7fa');
}

function esDuena() { return !!(ST.yo && ST.yo.rol === 'duena' && ST.yo.activo); }

async function cargarConfig() {
  var r = await sb.from('jab_config').select('*').eq('id', 1).single();
  if (r.error) throw r.error;
  ST.cfg = r.data;
  ST.cfg.tasa_bs = Number(ST.cfg.tasa_bs) || 0;
  if (typeof pintarTasa === 'function') pintarTasa();
  return ST.cfg;
}

async function cargarCatalogo() {
  var res = await Promise.all([traerTodo('jab_productos'), traerTodo('jab_variantes')]);
  ST.productos = res[0];
  ST.variantes = res[1];
  ST.prodPorId = new Map(ST.productos.map(function (p) { return [p.id, p]; }));
  ST.varPorId = new Map(ST.variantes.map(function (v) { return [v.id, v]; }));
  ST.varPorProducto = new Map();
  ST.variantes.forEach(function (v) {
    if (!ST.varPorProducto.has(v.producto_id)) ST.varPorProducto.set(v.producto_id, []);
    ST.varPorProducto.get(v.producto_id).push(v);
  });
  ST.varPorProducto.forEach(function (lista) { lista.sort(ordenVariantes); });
  if (esDuena()) {
    var costos = await traerTodo('jab_producto_costos', '*', null, 'producto_id');
    ST.costos = new Map(costos.map(function (c) { return [c.producto_id, Number(c.costo)]; }));
  }
}

async function cargarClientes() {
  var todas = await traerTodo('jab_clientes');
  // El mapa incluye las borradas para poder mostrar su nombre en ventas viejas
  ST.cliPorId = new Map(todas.map(function (c) { return [c.id, c]; }));
  ST.clientes = todas.filter(function (c) { return !c.deleted_at; });
  ST.clientes.sort(function (a, b) { return a.nombre.localeCompare(b.nombre, 'es'); });
}

async function cargarMetodos() {
  var res = await Promise.all([traerTodo('jab_cuentas', '*', null, 'orden'), traerTodo('jab_metodos_pago', '*', null, 'orden')]);
  ST.cuentas = res[0];
  ST.metodos = res[1];
}

async function cargarUsuarios() {
  ST.usuarios = await traerTodo('jab_usuarios', '*', null, 'nombre');
  ST.usrPorId = new Map(ST.usuarios.map(function (u) { return [u.id, u]; }));
}

function cuentaDe(metodo) { return ST.cuentas.find(function (c) { return c.id === metodo.cuenta_id; }); }
function monedaMetodo(m) { if (m.es_saldo_favor) return 'USD'; var c = cuentaDe(m); return c ? c.moneda : 'USD'; }

/* ---------------- Productos ---------------- */
var ORDEN_TALLAS = ['XXS', 'XS', 'S', 'M', 'L', 'XL', 'XXL', '2XL', '3XL', '4XL', 'ÚNICA', 'UNICA'];
function ordenVariantes(a, b) {
  var ia = ORDEN_TALLAS.indexOf(String(a.talla).toUpperCase()), ib = ORDEN_TALLAS.indexOf(String(b.talla).toUpperCase());
  if (ia !== ib) {
    if (ia < 0 && ib < 0) {
      var na = parseFloat(a.talla), nb = parseFloat(b.talla);
      if (!isNaN(na) && !isNaN(nb) && na !== nb) return na - nb;
      return String(a.talla).localeCompare(String(b.talla), 'es');
    }
    if (ia < 0) return 1;
    if (ib < 0) return -1;
    return ia - ib;
  }
  return String(a.color).localeCompare(String(b.color), 'es');
}
function descVariante(v) { return [v.talla, v.color].filter(Boolean).join(' · ') || 'Única'; }
function variantesActivas(pid) { return (ST.varPorProducto.get(pid) || []).filter(function (v) { return v.activo; }); }
function stockProducto(pid) { return variantesActivas(pid).reduce(function (s, v) { return s + v.stock; }, 0); }
function fotoUrl(path) { return path ? sb.storage.from('jab-fotos').getPublicUrl(path).data.publicUrl : ''; }
function imgProducto(p, clase, grande) {
  var path = grande ? (p.foto || p.foto_mini) : (p.foto_mini || p.foto);
  if (path) return '<img class="' + clase + '" src="' + esc(fotoUrl(path)) + '" alt="" loading="lazy">';
  return '<div class="' + clase + ' sin-foto">' + esc(iniciales(p.nombre).toUpperCase()) + '</div>';
}
function categorias() {
  var set = new Set(ST.productos.filter(function (p) { return p.activo; }).map(function (p) { return p.categoria; }));
  return Array.from(set).sort(function (a, b) { return a.localeCompare(b, 'es'); });
}
var CATEGORIAS_BASE = ['Blusas', 'Bodys', 'Vestidos', 'Faldas', 'Pantalones', 'Jeans', 'Shorts', 'Conjuntos', 'Chaquetas', 'Suéteres', 'Trajes de baño', 'Ropa deportiva', 'Pijamas', 'Lencería', 'Calzado', 'Carteras', 'Accesorios'];

/* ---------------- Fotos ---------------- */
function comprimirImagen(file, maxLado, calidad) {
  return new Promise(function (res, rej) {
    var url = URL.createObjectURL(file), img = new Image();
    img.onload = function () {
      var s = Math.min(1, maxLado / Math.max(img.naturalWidth, img.naturalHeight));
      var w = Math.round(img.naturalWidth * s), h = Math.round(img.naturalHeight * s);
      var c = document.createElement('canvas'); c.width = w; c.height = h;
      var ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h); ctx.drawImage(img, 0, 0, w, h);
      URL.revokeObjectURL(url);
      c.toBlob(function (b) { b ? res(b) : rej(new Error('No se pudo procesar la foto.')); }, 'image/jpeg', calidad);
    };
    img.onerror = function () { URL.revokeObjectURL(url); rej(new Error('No se pudo leer la foto.')); };
    img.src = url;
  });
}
async function subirFoto(file) {
  var grande = await comprimirImagen(file, 1100, 0.82);
  var mini = await comprimirImagen(file, 360, 0.78);
  var base = 'p/' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
  var opts = { contentType: 'image/jpeg', cacheControl: '31536000', upsert: false };
  var r1 = await sb.storage.from('jab-fotos').upload(base + '.jpg', grande, opts);
  if (r1.error) throw r1.error;
  var r2 = await sb.storage.from('jab-fotos').upload(base + '-m.jpg', mini, opts);
  if (r2.error) throw r2.error;
  return { foto: base + '.jpg', foto_mini: base + '-m.jpg' };
}

/* ---------------- Ventanas (hojas) ---------------- */
var _hojas = [];
// o = {titulo, html, pie, clase, cerrarFuera (true por defecto), alCerrar}
function abrirHoja(o) {
  var velo = document.createElement('div');
  velo.className = 'velo';
  velo.innerHTML =
    '<div class="hoja ' + (o.clase || '') + '" role="dialog" aria-modal="true" aria-label="' + esc(o.titulo) + '">' +
      '<div class="hoja-cab"><h2>' + esc(o.titulo) + '</h2>' +
        '<button type="button" class="btn btn-plano btn-icono" data-cerrar aria-label="Cerrar">' + icono('cerrar') + '</button></div>' +
      '<div class="hoja-cuerpo">' + (o.html || '') + '</div>' +
      (o.pie ? '<div class="hoja-pie">' + o.pie + '</div>' : '') +
    '</div>';
  document.body.appendChild(velo);
  document.body.style.overflow = 'hidden';
  var h = {
    velo: velo, el: velo.querySelector('.hoja'), cuerpo: velo.querySelector('.hoja-cuerpo'), pie: velo.querySelector('.hoja-pie'),
    $: function (sel) { return velo.querySelector(sel); },
    cerrado: false,
    cerrar: function () {
      if (h.cerrado) return;
      h.cerrado = true;
      velo.remove();
      _hojas = _hojas.filter(function (x) { return x !== h; });
      if (o.alCerrar) o.alCerrar();
      if (!_hojas.length) {
        document.body.style.overflow = '';
        // Si llegaron cambios de otro equipo mientras la ventana estaba abierta, repintar ahora
        if (window._repintarAlCerrar && VistaActual && VistaActual.refrescar) { window._repintarAlCerrar = false; VistaActual.refrescar(); }
      }
    }
  };
  velo.addEventListener('click', function (e) { if (e.target === velo && o.cerrarFuera !== false) h.cerrar(); });
  velo.querySelector('[data-cerrar]').addEventListener('click', function () { h.cerrar(); });
  _hojas.push(h);
  return h;
}
document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape' && _hojas.length) _hojas[_hojas.length - 1].cerrar();
});

// Pregunta de sí/no, opcionalmente con un texto (motivo) o número
function confirmar(o) {
  return new Promise(function (resolver) {
    var campo = '';
    if (o.pedir) {
      campo = '<label class="campo" style="margin-top:14px"><span>' + esc(o.pedir) + '</span>' +
        (o.tipo === 'texto-largo' ? '<textarea id="cfValor"></textarea>' :
          '<input id="cfValor" ' + (o.tipo === 'numero' ? 'inputmode="decimal"' : '') + ' value="' + esc(o.valor || '') + '">') + '</label>';
    }
    var listo = false;
    var h = abrirHoja({
      titulo: o.titulo || 'Confirmar',
      html: '<p style="margin:0">' + (o.mensajeHtml || esc(o.mensaje || '')) + '</p>' + campo,
      pie: '<div class="botonera"><button type="button" class="btn btn-sec" id="cfNo">Cancelar</button>' +
           '<button type="button" class="btn ' + (o.peligro ? 'btn-peligro' : '') + '" id="cfSi">' + esc(o.boton || 'Confirmar') + '</button></div>',
      cerrarFuera: !o.pedir,
      alCerrar: function () { if (!listo) resolver(o.pedir ? null : false); }
    });
    var inp = h.$('#cfValor');
    if (inp) setTimeout(function () { inp.focus(); }, 60);
    h.$('#cfNo').onclick = function () { h.cerrar(); };
    h.$('#cfSi').onclick = function () {
      var val = true;
      if (o.pedir) {
        val = inp.value.trim();
        if (o.obligatorio !== false && !val) { inp.focus(); toast('Este dato es obligatorio', 'error'); return; }
      }
      listo = true; h.cerrar(); resolver(val);
    };
  });
}

/* ---------------- Listas largas: se dibujan por partes ---------------- */
function dibujarPorPartes(cont, items, render, tam, envolver) {
  tam = tam || 60;
  var mostrados = 0;
  function mas() {
    var trozo = items.slice(mostrados, mostrados + tam);
    mostrados += trozo.length;
    var btnViejo = cont.querySelector(':scope > .mas');
    if (btnViejo) btnViejo.remove();
    var destino = envolver ? cont.querySelector(envolver) : cont;
    destino.insertAdjacentHTML('beforeend', trozo.map(render).join(''));
    if (mostrados < items.length) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn btn-sec mas';
      b.textContent = 'Mostrar más (' + (items.length - mostrados) + ')';
      b.onclick = mas;
      cont.appendChild(b);
    }
  }
  mas();
}

/* ---------------- WhatsApp y compartir ---------------- */
function telefonoWa(tel) {
  var d = String(tel || '').replace(/\D/g, '');
  if (!d) return '';
  if (d.indexOf('58') === 0 && d.length >= 12) return d;
  if (d[0] === '0') return '58' + d.slice(1);
  if (d.length === 10) return '58' + d;
  return d;
}
function compartirTexto(texto, telefono) {
  var num = telefonoWa(telefono);
  if (num) { window.open('https://wa.me/' + num + '?text=' + encodeURIComponent(texto), '_blank'); return; }
  if (navigator.share) { navigator.share({ text: texto }).catch(function () {}); return; }
  if (navigator.clipboard) navigator.clipboard.writeText(texto).then(function () { toast('Texto copiado', 'ok'); });
}
