// JABELLA — arranque: entrada, menú, navegación y cambios en vivo entre la laptop y el teléfono.
'use strict';

var VistaActual = null;
var VISTAS = {
  vender: { v: VistaVender, icono: 'vender', nombre: 'Vender' },
  inventario: { v: VistaInventario, icono: 'inventario', nombre: 'Inventario' },
  ventas: { v: VistaVentas, icono: 'ventas', nombre: 'Ventas' },
  dinero: { v: VistaDinero, icono: 'dinero', nombre: 'Dinero', soloDuena: true },
  compras: { v: VistaCompras, icono: 'entregar', nombre: 'Compras', soloDuena: true },
  reportes: { v: VistaReportes, icono: 'reportes', nombre: 'Reportes', soloDuena: true },
  clientes: { v: VistaClientes, icono: 'clientes', nombre: 'Clientas' },
  ajustes: { v: VistaAjustes, icono: 'ajustes', nombre: 'Ajustes' }
};
function vistasPermitidas() {
  return Object.keys(VISTAS).filter(function (k) { return !VISTAS[k].soloDuena || esDuena(); });
}
// En el teléfono caben 4 pestañas + "Más"
function pestanasTelefono() {
  return esDuena() ? ['vender', 'inventario', 'ventas', 'dinero'] : ['vender', 'inventario', 'ventas', 'clientes'];
}

function pintarTasa() {
  var chip = $('#chipTasa'); if (!chip || !ST.cfg) return;
  var t = ST.cfg.tasa_bs;
  var vieja = !t || !ST.cfg.tasa_actualizada_en || fechaCaracas(ST.cfg.tasa_actualizada_en) !== hoyCaracas();
  chip.textContent = t ? 'Tasa ' + fmtTasa(t) : 'Poner tasa';
  chip.classList.toggle('vieja', vieja);
  chip.title = vieja ? 'La tasa no se ha actualizado hoy' : 'Tasa del día';
}

function pintarNav() {
  var actual = location.hash.slice(1);
  $('#navLateral').innerHTML = vistasPermitidas().map(function (k) {
    return '<button type="button" data-ir="' + k + '"' + (k === actual ? ' class="activo"' : '') + '>' + icono(VISTAS[k].icono) + esc(VISTAS[k].nombre) + '</button>';
  }).join('');
  $('#pieLateral').innerHTML = '<div class="fuerte">' + esc(ST.yo.nombre) + '</div><div class="tenue">' + (esDuena() ? 'Dueña' : 'Vendedora') + '</div>' +
    '<button type="button" class="btn btn-plano btn-chico" id="btnSalirLateral" style="margin-top:6px;padding:0">' + icono('salir', 'ic-chico') + ' Salir</button>';
  $('#btnSalirLateral').onclick = salir;
  var tabs = pestanasTelefono();
  var enMas = tabs.indexOf(actual) < 0 && actual;
  $('#navTabs').innerHTML = tabs.map(function (k) {
    return '<button type="button" data-ir="' + k + '"' + (k === actual ? ' class="activo"' : '') + '>' + icono(VISTAS[k].icono) + '<span>' + esc(VISTAS[k].nombre) + '</span></button>';
  }).join('') + '<button type="button" data-mas' + (enMas ? ' class="activo"' : '') + '>' + icono('menu') + '<span>Más</span></button>';
}

function ir(nombre) {
  if (vistasPermitidas().indexOf(nombre) < 0) nombre = 'vender';
  if (location.hash.slice(1) !== nombre) { history.replaceState(null, '', '#' + nombre); }
  VistaActual = VISTAS[nombre].v;
  $('#tituloVista').textContent = VISTAS[nombre].nombre;
  document.title = VISTAS[nombre].nombre + ' · JABELLA Store';
  pintarNav();
  var cont = $('#vista');
  cont.innerHTML = '';
  window.scrollTo(0, 0);
  Promise.resolve(VistaActual.mostrar(cont)).catch(function (e) {
    console.error(e);
    cont.innerHTML = '<div class="aviso aviso-error">No se pudo abrir: ' + esc(errMsg(e)) + '</div>';
  });
}

function menuMas() {
  var tabs = pestanasTelefono();
  var resto = vistasPermitidas().filter(function (k) { return tabs.indexOf(k) < 0; });
  var h = abrirHoja({
    titulo: 'Más',
    html: '<div class="lista">' + resto.map(function (k) {
      return '<button type="button" class="item" data-ir="' + k + '">' + icono(VISTAS[k].icono) + '<div class="crece">' + esc(VISTAS[k].nombre) + '</div>' + icono('flecha', 'ic-chico') + '</button>';
    }).join('') +
    '<button type="button" class="item" data-salir>' + icono('salir') + '<div class="crece">Salir</div></button></div>' +
    '<p class="tenue" style="text-align:center;margin-top:14px">' + esc(ST.yo.nombre) + ' · ' + (esDuena() ? 'Dueña' : 'Vendedora') + '</p>'
  });
  h.cuerpo.addEventListener('click', function (e) {
    var b = e.target.closest('[data-ir]');
    if (b) { h.cerrar(); ir(b.dataset.ir); return; }
    if (e.target.closest('[data-salir]')) { h.cerrar(); salir(); }
  });
}

async function salir() {
  if (Carrito.items.length && !(await confirmar({ titulo: 'Salir', mensaje: 'Hay una venta sin cobrar. Si sales se pierde.', boton: 'Salir igual', peligro: true }))) return;
  await sb.auth.signOut();
  location.hash = '';
  location.reload();
}

/* ---------------- Entrada ---------------- */
function mostrarLogin(msg) {
  $('#app').hidden = true;
  $('#pantallaLogin').hidden = false;
  var e = $('#loginError');
  e.hidden = !msg; e.textContent = msg || '';
}

$('#formLogin').addEventListener('submit', async function (ev) {
  ev.preventDefault();
  var btn = $('#btnEntrar');
  if (btn.disabled) return;
  var u = $('#loginUsuario').value.trim().toLowerCase(), clave = $('#loginClave').value;
  if (!u || !clave) return;
  var email = u.indexOf('@') >= 0 ? u : u + '@' + JAB_CONFIG.dominio;
  btn.disabled = true; btn.textContent = 'Entrando…';
  $('#loginError').hidden = true;
  try {
    var r = await sb.auth.signInWithPassword({ email: email, password: clave });
    if (r.error) throw r.error;
    $('#loginClave').value = '';
    await entrar();
  } catch (e) {
    mostrarLogin(errMsg(e));
  } finally {
    btn.disabled = false; btn.textContent = 'Entrar';
  }
});

async function entrar() {
  var ru = await sb.auth.getUser();
  var uid = ru.data && ru.data.user && ru.data.user.id;
  if (!uid) { mostrarLogin(); return; }
  var r = await sb.from('jab_usuarios').select('*').eq('id', uid).maybeSingle();
  if (r.error) { mostrarLogin(errMsg(r.error)); return; }
  if (!r.data || !r.data.activo) {
    await sb.auth.signOut();
    mostrarLogin(r.data ? 'Tu usuario está desactivado. Habla con la dueña.' : 'Este usuario no tiene acceso a la tienda.');
    return;
  }
  ST.yo = r.data;
  $('#pantallaLogin').hidden = true;
  $('#app').hidden = false;
  $('#vista').innerHTML = '<div class="cargando">Cargando la tienda…</div>';
  try {
    await Promise.all([cargarConfig(), cargarCatalogo(), cargarClientes(), cargarMetodos(), cargarUsuarios()]);
  } catch (e) {
    $('#vista').innerHTML = '<div class="aviso aviso-error">No se pudieron cargar los datos: ' + esc(errMsg(e)) +
      '<br><button type="button" class="btn btn-sec btn-chico" onclick="location.reload()" style="margin-top:10px">Reintentar</button></div>';
    return;
  }
  ir(location.hash.slice(1) || 'vender');
  if (ST.yo.debe_cambiar_clave) await hojaCambiarClave(true);
  suscribirCambios();
}

/* ---------------- Cambios en vivo ---------------- */
var _pendiente = new Set();
var _aplicarCambios = debounce(async function () {
  var p = _pendiente; _pendiente = new Set();
  try {
    var tareas = [];
    if (p.has('catalogo')) tareas.push(cargarCatalogo());
    if (p.has('config')) tareas.push(cargarConfig());
    if (p.has('clientes')) tareas.push(cargarClientes());
    await Promise.all(tareas);
    // No repintar mientras haya una ventana abierta encima (se repinta al cerrarla o al volver)
    if (_hojas.length) window._repintarAlCerrar = true;
    else if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
  } catch (e) { console.warn('No se pudo actualizar', e); }
}, 1200);
function marcarCambio(que) { _pendiente.add(que); _aplicarCambios(); }

var _canal = null;
function suscribirCambios() {
  if (_canal) return;
  _canal = sb.channel('jabella-cambios')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'jab_variantes' }, function () { marcarCambio('catalogo'); })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'jab_productos' }, function () { marcarCambio('catalogo'); })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'jab_config' }, function () { marcarCambio('config'); })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'jab_ventas' }, function () { marcarCambio('ventas'); })
    .subscribe();
}
// Al volver a la app (el teléfono corta la conexión en segundo plano) se recarga todo
document.addEventListener('visibilitychange', function () {
  if (document.visibilityState === 'visible' && ST.yo) { marcarCambio('catalogo'); marcarCambio('config'); marcarCambio('clientes'); }
});

/* ---------------- Eventos globales ---------------- */
document.addEventListener('click', function (e) {
  var b = e.target.closest('#navLateral [data-ir], #navTabs [data-ir]');
  if (b) { ir(b.dataset.ir); return; }
  if (e.target.closest('#navTabs [data-mas]')) { menuMas(); return; }
  if (e.target.closest('#chipTasa')) hojaTasa();
});
window.addEventListener('hashchange', function () {
  if (ST.yo) { var n = location.hash.slice(1); if (VISTAS[n] && VISTAS[n].v !== VistaActual) ir(n); }
});

aplicarTema(temaActual());
if (window.matchMedia) {
  var mq = window.matchMedia('(prefers-color-scheme: dark)');
  var alCambiarModo = function () { if (temaActual() === 'auto') aplicarTema('auto'); };
  if (mq.addEventListener) mq.addEventListener('change', alCambiarModo); else if (mq.addListener) mq.addListener(alCambiarModo);
}

(async function iniciar() {
  try {
    var s = await sb.auth.getSession();
    if (s.data && s.data.session) await entrar(); else mostrarLogin();
  } catch (e) {
    mostrarLogin(errMsg(e));
  }
  sb.auth.onAuthStateChange(function (evento) {
    if (evento === 'SIGNED_OUT' && ST.yo) { ST.yo = null; mostrarLogin('Tu sesión se cerró. Vuelve a entrar.'); }
  });
})();
