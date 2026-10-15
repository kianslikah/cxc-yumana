// JABELLA — caja del día: apertura (fondo para vueltos), cierre con entrega a la dueña y avisos por WhatsApp.
// Se cuenta a ciegas: lo que debería haber solo lo ve la dueña en Reportes → Cierres de caja.
'use strict';

/* ---------------- Aviso a la dueña por WhatsApp ---------------- */
function nombreDuena() {
  var d = ST.usuarios.find(function (u) { return u.rol === 'duena' && u.activo; });
  return d ? d.nombre.split(' ')[0] : 'la dueña';
}
// La vendedora le avisa a la dueña lo que hizo. Si la dueña dejó su WhatsApp en Ajustes, es obligatorio.
function debeAvisar() { return !esDuena() && !!(ST.cfg && ST.cfg.whatsapp_duena); }
function avisarDuena(titulo, texto) {
  if (!debeAvisar()) return Promise.resolve(false);
  return new Promise(function (resolver) {
    var nombre = nombreDuena();
    var h = abrirHoja({
      titulo: titulo, cerrarFuera: false, fija: true,
      html: '<p class="suave" style="margin-top:0">Envíale este mensaje a ' + esc(nombre) + ' para que sepa al momento.</p>' +
        '<pre class="mensaje-wa">' + esc(texto) + '</pre>',
      pie: '<div class="pila"><button type="button" class="btn btn-ancho" id="awEnviar">' + icono('chat', 'ic-chico') + ' Enviar a ' + esc(nombre) + ' por WhatsApp</button>' +
        '<button type="button" class="btn btn-plano btn-chico" id="awCopiar" style="align-self:center">Copiar el mensaje (lo envío desde mi teléfono)</button></div>'
    });
    function listo() { h.cerrar(); resolver(true); }
    h.$('#awEnviar').onclick = function () {
      window.open('https://wa.me/' + telefonoWa(ST.cfg.whatsapp_duena) + '?text=' + encodeURIComponent(texto), '_blank');
      listo();
    };
    h.$('#awCopiar').onclick = function () {
      var ok = function () { toast('Mensaje copiado. Pégalo en el chat de ' + nombre + '.', 'ok', 5000); listo(); };
      if (navigator.clipboard) navigator.clipboard.writeText(texto).then(ok, function () { toast('No se pudo copiar. Toca Enviar.', 'error'); });
      else toast('No se pudo copiar. Toca Enviar.', 'error');
    };
  });
}

// Texto del aviso de una venta (apartado o fiado incluidos)
function textoAvisoVenta(d) {
  var v = d.venta, cli = v.cliente_id ? ST.cliPorId.get(v.cliente_id) : null, s = saldoVenta(v);
  var tipo = { contado: 'contado', apartado: 'apartado', fiado: 'fiado', cambio: 'cambio' }[v.tipo];
  var t = ['JABELLA · ' + (v.tipo === 'cambio' ? 'Cambio' : 'Venta') + ' #' + v.numero + ' (' + tipo + ')'];
  d.items.forEach(function (i) {
    t.push((i.cantidad < 0 ? 'Devuelve ' + (-i.cantidad) : i.cantidad) + ' × ' + i.descripcion + ' — ' + fmtUSD(Math.abs(i.cantidad) * i.precio));
  });
  t.push('Total: ' + fmtUSD(v.total));
  var vivos = d.pagos.filter(function (p) { return !p.anulado_en; });
  if (vivos.length) t.push('Pagó: ' + vivos.map(function (p) {
    return nombreMetodo(p.metodo_id) + ' ' + (p.moneda === 'VES' ? fmtBs(p.monto) : fmtUSD(p.monto_usd)) + (p.comprobante ? ' (con foto)' : '');
  }).join(' + '));
  if (v.estado === 'activa' && s > 0.004) t.push('Queda debiendo: ' + fmtUSD(s) + (v.tipo === 'apartado' && !v.entregada ? ' · apartado hasta el ' + fmtFecha(v.vence_en) : ''));
  if (cli) t.push('Clienta: ' + cli.nombre);
  if (v.nota) t.push('Nota: ' + v.nota);
  t.push('Vendió: ' + ST.yo.nombre + ' · ' + fmtHora(v.creado_en));
  return t.join('\n');
}

/* ---------------- Estado de la caja de hoy ---------------- */
async function cargarCaja() {
  try { ST.caja = await rpc('jab_caja_hoy'); } catch (e) { ST.caja = null; }
  return ST.caja;
}
function cajaDeHoy() { return ST.caja && ST.caja.fecha === hoyCaracas() ? ST.caja : null; }
function montoCuenta(c, monto) { return fmtMonto(monto, c.moneda); }

// Tarjeta para Ventas → Por día (solo hoy)
function tarjetaCaja() {
  var k = cajaDeHoy();
  if (!k) return '';
  var u = function (x) { var p = ST.usrPorId.get(x.usuario_id); return p ? p.nombre : '—'; };
  var conteos = function (lista, campo) { return (lista || []).map(function (c) { return esc(c.nombre) + ': ' + montoCuenta(c, c[campo]); }).join(' · '); };
  var html;
  if (k.abierta) {
    html = '<div class="fila-entre" style="gap:10px;flex-wrap:wrap"><div class="crece"><div class="fila" style="gap:8px"><h3>Caja de hoy</h3><span class="etq etq-ok">Abierta</span></div>' +
      '<div class="sub">' + fmtHora(k.apertura.creado_en) + ' · ' + esc(u(k.apertura)) + ' · ' + conteos(k.apertura.conteos, 'contado') + '</div></div>' +
      '<button type="button" class="btn" data-caja="cerrar">' + icono('candado', 'ic-chico') + ' Cerrar caja</button></div>';
  } else if (k.cierre) {
    var ent = (k.cierre.conteos || []).filter(function (c) { return Number(c.entregado) > 0; });
    html = '<div class="fila-entre" style="gap:10px;flex-wrap:wrap"><div class="crece"><div class="fila" style="gap:8px"><h3>Caja de hoy</h3><span class="etq">Cerrada</span></div>' +
      '<div class="sub">' + fmtHora(k.cierre.creado_en) + ' · ' + esc(u(k.cierre)) + ' · quedó ' + conteos(k.cierre.conteos, 'queda') + '</div>' +
      (ent.length ? '<div class="sub">Entregado a ' + esc(nombreDuena()) + ': ' + conteos(ent, 'entregado') + '</div>' : '') + '</div>' +
      '<button type="button" class="btn btn-sec btn-chico" data-caja="abrir">Abrir de nuevo</button></div>';
  } else {
    html = '<div class="fila-entre" style="gap:10px;flex-wrap:wrap"><div class="crece"><div class="fila" style="gap:8px"><h3>Caja de hoy</h3><span class="etq etq-aviso">Sin abrir</span></div>' +
      '<div class="sub">Al llegar, cuenta el efectivo que hay para dar vueltos.</div></div>' +
      '<button type="button" class="btn" data-caja="abrir">' + icono('dinero', 'ic-chico') + ' Abrir caja</button></div>';
  }
  return '<div class="tarjeta" id="tarjetaCaja" style="margin-bottom:14px">' + html + '</div>';
}
// Aviso arriba de Vender cuando la caja no está abierta
function avisoCajaVender() {
  var k = cajaDeHoy();
  if (!k || k.abierta) return '';
  return '<div class="aviso fila-entre" style="margin-bottom:12px;gap:8px;flex-wrap:wrap"><span class="crece">' +
    (k.cierre ? 'La caja de hoy ya se cerró. Si vas a seguir vendiendo, ábrela de nuevo.' : 'La caja no se ha abierto hoy. Cuenta el efectivo para vueltos antes de vender.') + '</span>' +
    '<button type="button" class="btn btn-chico" data-caja="abrir">Abrir caja</button></div>';
}
document.addEventListener('click', function (e) {
  var b = e.target.closest('[data-caja]'); if (!b) return;
  if (b.dataset.caja === 'abrir') hojaContarCaja('apertura');
  else hojaContarCaja('cierre');
});

/* ---------------- Contar la caja: apertura o cierre ---------------- */
var _contandoCaja = false;
async function hojaContarCaja(tipo) {
  if (_contandoCaja) return;
  _contandoCaja = true;
  try { await Promise.all([cargarMetodos(), cargarConfig(), cargarCaja()]); } catch (e) { _contandoCaja = false; toast(errMsg(e), 'error'); return; }
  var cuentas = ST.cuentas.filter(function (c) { return c.activa && c.cuenta_en_cierre; });
  if (!cuentas.length) { _contandoCaja = false; toast('No hay cuentas de efectivo marcadas para el cierre (Ajustes → Cuentas de dinero).', 'error', 6000); return; }
  var k = cajaDeHoy() || { fondo: [] };
  if (tipo === 'apertura' && k.abierta) { _contandoCaja = false; toast('La caja ya está abierta desde las ' + fmtHora(k.apertura.creado_en) + '.'); return; }
  var abrir = tipo === 'apertura', clave = nuevaClave(), duena = nombreDuena();
  var fondo = function (id) { var f = (k.fondo || []).find(function (x) { return Number(x.cuenta_id) === id; }); return f ? Number(f.monto) : 0; };
  var simbolo = function (c) { return c.moneda === 'VES' ? 'Bs' : '$'; };
  var h = abrirHoja({
    titulo: abrir ? 'Abrir caja' : 'Cerrar caja', cerrarFuera: false, alCerrar: function () { _contandoCaja = false; },
    html: '<p class="suave" style="margin-top:0">' + (abrir
        ? 'Cuenta el efectivo que hay en la caja para dar vueltos y escríbelo.'
        : 'Cuenta todo el efectivo que hay ahora. No hace falta saber cuánto debería haber: el sistema lo compara y ' + esc(duena) + ' ve el resultado. Luego di cuánto dejas para los vueltos de mañana: el resto se le entrega a ' + esc(duena) + '.') + '</p>' +
      '<div class="pila">' + cuentas.map(function (c) {
        return '<div class="tarjeta pila" style="padding:12px 14px"><h3>' + esc(c.nombre) + '</h3>' +
          '<label class="campo"><span>' + (abrir ? '¿Cuánto hay para vueltos?' : '¿Cuánto hay en total?') + ' (' + simbolo(c) + ')</span><input data-contado="' + c.id + '" inputmode="decimal" placeholder="0,00"></label>' +
          (abrir ? '' : '<label class="campo"><span>Dejo en la caja para mañana (' + simbolo(c) + ')</span><input data-deja="' + c.id + '" inputmode="decimal" value="' + esc(fmtNum(fondo(c.id))) + '"></label>' +
            '<div class="ayuda" data-entrega="' + c.id + '"></div>') + '</div>';
      }).join('') +
      '<label class="campo"><span>Nota (opcional)</span><input id="ccNota" placeholder="' + (abrir ? 'Ej.: faltaban billetes de $1' : 'Ej.: saqué $5 para el delivery') + '"></label></div>',
    pie: '<button type="button" class="btn btn-ancho" id="ccOk">' + (abrir ? 'Abrir caja' : 'Cerrar caja') + '</button>'
  });
  function leer(c) {
    var n = parseNum(h.$('[data-contado="' + c.id + '"]').value), dj = abrir ? n : parseNum(h.$('[data-deja="' + c.id + '"]').value || '0');
    return { contado: n, deja: dj };
  }
  function pintarEntregas() {
    if (abrir) return;
    cuentas.forEach(function (c) {
      var x = leer(c), el = h.$('[data-entrega="' + c.id + '"]');
      if (isNaN(x.contado)) { el.textContent = ''; return; }
      if (isNaN(x.deja) || x.deja < 0) { el.innerHTML = '<span class="error-txt">Revisa cuánto dejas.</span>'; return; }
      var ent = redondear2(x.contado - x.deja);
      el.innerHTML = ent < -0.004 ? '<span class="error-txt">Dejas más de lo que hay.</span>'
        : 'Le entregas a ' + esc(duena) + ': <b>' + montoCuenta(c, ent) + '</b>';
    });
  }
  h.cuerpo.addEventListener('input', pintarEntregas);
  setTimeout(function () { var i = h.$('[data-contado]'); if (i) i.focus(); }, 80);
  protegerBoton(h.$('#ccOk'), async function () {
    var conteos = cuentas.map(function (c) {
      var x = leer(c);
      if (isNaN(x.contado) || x.contado < 0) throw new Error('Escribe cuánto hay en ' + c.nombre + ' (0 si no hay nada).');
      var item = { cuenta_id: c.id, contado: redondear2(x.contado) };
      if (!abrir) {
        if (isNaN(x.deja) || x.deja < 0) throw new Error('Revisa cuánto dejas en ' + c.nombre + '.');
        if (x.deja > x.contado + 0.004) throw new Error('En ' + c.nombre + ' dejas más de lo que hay.');
        item.entregado = redondear2(x.contado - x.deja);
      }
      return item;
    });
    var nota = h.$('#ccNota').value.trim();
    var id = await rpc('jab_registrar_cierre', { p: { clave: clave, tipo: tipo, nota: nota, conteos: conteos } });
    h.cerrar();
    toast(abrir ? 'Caja abierta. ¡Buenas ventas!' : 'Caja cerrada. ¡Buen trabajo!', 'ok');
    await Promise.all([cargarCaja(), cargarMetodos()]);
    if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
    if (debeAvisar()) {
      var t = ['JABELLA · ' + (abrir ? 'Abrí la caja' : 'Cerré la caja') + ' · ' + fmtHora(new Date().toISOString())];
      cuentas.forEach(function (c, i) {
        var x = conteos[i];
        t.push(c.nombre + ': ' + (abrir ? 'hay ' + montoCuenta(c, x.contado)
          : x.entregado > 0 ? 'conté ' + montoCuenta(c, x.contado) + ' · dejo ' + montoCuenta(c, x.contado - x.entregado) + ' · te entrego ' + montoCuenta(c, x.entregado)
          : 'conté ' + montoCuenta(c, x.contado) + ' (queda en la caja)'));
      });
      if (!abrir) {
        try {
          var r = await rpc('jab_resumen_dia', { p_fecha: hoyCaracas() });
          t.push('Ventas de hoy: ' + r.ventas + ' · ' + fmtUSD(r.vendido) + ' · ' + r.prendas + ' prenda' + (r.prendas === 1 ? '' : 's'));
        } catch (e) { /* el aviso sale igual */ }
      }
      if (nota) t.push('Nota: ' + nota);
      t.push(ST.yo.nombre);
      await avisarDuena(abrir ? 'Avísale que abriste' : 'Avísale que cerraste', t.join('\n'));
    } else if (esDuena()) verCierre(id);
  }, abrir ? 'Abriendo…' : 'Cerrando…');
  pintarEntregas();
}
