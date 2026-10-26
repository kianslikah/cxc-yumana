// JABELLA — cuenta de fiado de una clienta: todos sus fiados juntos, abono repartido de la cuenta más vieja
// a la más nueva (lo hace la base: jab_abonar_cliente), estado de cuenta y recibo por WhatsApp.
'use strict';

function porVenta(lista) {
  var m = new Map();
  lista.forEach(function (x) { if (!m.has(x.venta_id)) m.set(x.venta_id, []); m.get(x.venta_id).push(x); });
  return m;
}
function ordenViejo(a, b) { return a.creado_en < b.creado_en ? -1 : a.creado_en > b.creado_en ? 1 : a.id - b.id; }

// Fiados con deuda y apartados pendientes de una clienta, con sus prendas y pagos
async function datosCuentaCliente(cliId) {
  var ventas = await traerTodo('jab_ventas', '*', function (q) { return q.eq('cliente_id', cliId).eq('estado', 'activa').in('tipo', ['fiado', 'apartado']); });
  var fiados = ventas.filter(function (v) { return v.tipo === 'fiado' && saldoVenta(v) > 0.004; }).sort(ordenViejo);
  var apartados = ventas.filter(function (v) { return v.tipo === 'apartado' && !v.entregada; }).sort(ordenViejo);
  var ids = fiados.concat(apartados).map(function (v) { return v.id; });
  var res = ids.length ? await Promise.all([
    traerTodo('jab_venta_items', '*', function (q) { return q.in('venta_id', ids); }),
    traerTodo('jab_pagos', '*', function (q) { return q.in('venta_id', ids); })
  ]) : [[], []];
  return {
    cliente: ST.cliPorId.get(cliId), fiados: fiados, apartados: apartados,
    items: porVenta(res[0].sort(function (a, b) { return a.id - b.id; })),
    pagos: porVenta(res[1].filter(function (p) { return !p.anulado_en; }).sort(function (a, b) { return a.id - b.id; })),
    deuda: redondear2(fiados.reduce(function (s, v) { return s + saldoVenta(v); }, 0))
  };
}

function lineaPago(p) { return nombreMetodo(p.metodo_id) + ' ' + (p.moneda === 'VES' ? fmtBs(p.monto) : fmtUSD(p.monto_usd)); }

// Estado de cuenta detallado para la clienta (todas sus cuentas de fiado)
function textoEstadoCuenta(d) {
  var c = d.cliente, t = ['JABELLA Store · Estado de cuenta', 'Hola ' + c.nombre.split(' ')[0] + ', este es tu resumen al ' + fmtFecha(new Date().toISOString()) + ':', ''];
  d.fiados.forEach(function (v) {
    t.push('Compra #' + v.numero + ' del ' + fmtFecha(v.creado_en));
    (d.items.get(v.id) || []).forEach(function (i) {
      t.push('  ' + (i.cantidad < 0 ? 'Devuelve ' + (-i.cantidad) : i.cantidad) + ' × ' + i.descripcion + ' — ' + fmtUSD(Math.abs(i.cantidad) * i.precio));
    });
    var abonos = d.pagos.get(v.id) || [];
    if (abonos.length) t.push('  Abonos: ' + abonos.map(function (p) { return fmtFecha(p.creado_en) + ' ' + fmtUSD(p.monto_usd); }).join(', '));
    t.push('  Total ' + fmtUSD(v.total) + ' · abonado ' + fmtUSD(v.pagado) + ' · debe ' + fmtUSD(saldoVenta(v)));
    t.push('');
  });
  t.push('Total que debes: ' + fmtUSD(d.deuda));
  if (d.apartados.length) {
    t.push('');
    d.apartados.forEach(function (v) {
      t.push('Apartado #' + v.numero + ': ' + (saldoVenta(v) > 0.004 ? 'falta ' + fmtUSD(saldoVenta(v)) + ', ' : 'pagado, ') + 'hasta el ' + fmtFecha(v.vence_en));
    });
  }
  t.push('');
  t.push('¡Gracias por tu compra! · @jabella.store');
  return t.join('\n');
}

// Recibo de un abono a la cuenta (sale de lo que devolvió la base: cómo se repartió)
function textoReciboAbono(cli, r, pagosTxt, cuentas) {
  var num = new Map(cuentas.map(function (v) { return [v.id, v]; }));
  var t = ['JABELLA Store · Recibo de abono', 'Clienta: ' + cli.nombre, fmtFechaHora(new Date().toISOString()),
    'Abonó: ' + fmtUSD(r.total) + (pagosTxt ? ' (' + pagosTxt + ')' : ''), '', 'Se aplicó a:'];
  r.cuentas.forEach(function (c) {
    var v = num.get(Number(c.venta_id));
    t.push('• Compra #' + c.numero + (v ? ' del ' + fmtFecha(v.creado_en) : '') + ': ' + fmtUSD(c.abonado) +
      (Number(c.saldo_despues) > 0.004 ? ' → queda ' + fmtUSD(c.saldo_despues) : ' → pagada'));
  });
  t.push('');
  t.push(Number(r.deuda_despues) > 0.004 ? 'Total que debe ahora: ' + fmtUSD(r.deuda_despues) : 'Ya no debe nada. ¡Gracias!');
  t.push('Recibió: ' + ST.yo.nombre);
  t.push('@jabella.store');
  return t.join('\n');
}

/* ---------------- La cuenta de una clienta ---------------- */
async function hojaCuentaCliente(cliId) {
  var cli = ST.cliPorId.get(cliId);
  if (!cli) return;
  var h = abrirHoja({ titulo: cli.nombre, clase: 'completa', html: '<div class="cargando">Cargando la cuenta…</div>' });
  var d;
  try { d = await datosCuentaCliente(cliId); } catch (e) { h.cuerpo.innerHTML = '<div class="aviso aviso-error">' + esc(errMsg(e)) + '</div>'; return; }
  var hoy = hoyCaracas(), vieja = d.fiados[0], dias = vieja ? diasEntre(fechaCaracas(vieja.creado_en), hoy) : 0;
  h.cuerpo.innerHTML =
    '<div class="tarjetas-kpi">' +
      '<div class="kpi"><div class="t">Debe fiado</div><div class="v ' + (d.deuda > 0.004 ? 'aviso-txt' : 'ok-txt') + '">' + fmtUSD(d.deuda) + '</div>' +
        '<div class="s">' + d.fiados.length + ' cuenta' + (d.fiados.length === 1 ? '' : 's') + '</div></div>' +
      (vieja ? '<div class="kpi"><div class="t">La más vieja</div><div class="v">' + fmtFecha(vieja.creado_en) + '</div>' +
        '<div class="s ' + (dias > 30 ? 'error-txt' : dias > 15 ? 'aviso-txt' : '') + '">' + (dias === 0 ? 'de hoy' : 'hace ' + dias + ' día' + (dias === 1 ? '' : 's')) + '</div></div>' : '') +
    '</div>' +
    '<div class="botonera" style="margin:12px 0 4px">' +
      (d.deuda > 0.004 ? '<button type="button" class="btn" data-cc="abonar">' + icono('dinero', 'ic-chico') + ' Abonar a la cuenta</button>' : '') +
      (d.fiados.length || d.apartados.length ? '<button type="button" class="btn btn-sec" data-cc="estado">' + icono('enviar', 'ic-chico') + ' Enviar estado de cuenta</button>' : '') +
      '<button type="button" class="btn btn-plano btn-chico" data-cc="ficha">Ver ficha</button></div>' +
    (d.fiados.length > 1 ? '<p class="ayuda" style="margin:4px 0 0">Cada compra fiada es una cuenta aparte. Un abono a la cuenta se aplica primero a la más vieja.</p>' : '') +
    (d.fiados.length ? '<h3 style="margin:16px 0 8px">Fiados</h3>' + d.fiados.map(function (v) {
      var its = d.items.get(v.id) || [], pg = d.pagos.get(v.id) || [];
      return '<div class="tarjeta cuenta-fiado" style="margin-bottom:10px;padding:12px 14px">' +
        '<div class="fila-entre"><div class="fuerte">#' + v.numero + ' · ' + fmtFecha(v.creado_en) + '</div><div class="num fuerte aviso-txt">Debe ' + fmtUSD(saldoVenta(v)) + '</div></div>' +
        its.map(function (i) {
          return '<div class="fila-entre sub" style="gap:8px"><span class="corta">' + (i.cantidad < 0 ? 'Devuelve ' + (-i.cantidad) : i.cantidad) + ' × ' + esc(i.descripcion) + '</span>' +
            '<span class="num" style="flex:none">' + fmtUSD(Math.abs(i.cantidad) * i.precio) + '</span></div>';
        }).join('') +
        '<div class="sub" style="margin-top:4px">Total ' + fmtUSD(v.total) + ' · abonado ' + fmtUSD(v.pagado) + '</div>' +
        (pg.length ? '<div class="sub tenue">Abonos: ' + pg.map(function (p) { return fmtFecha(p.creado_en) + ' ' + esc(lineaPago(p)); }).join(' · ') + '</div>' : '') +
        '<button type="button" class="btn btn-plano btn-chico" data-venta="' + v.id + '" style="padding-left:0;margin-top:4px">Ver la venta ' + icono('flecha', 'ic-chico') + '</button></div>';
    }).join('') : '<div class="vacio" style="margin-top:12px">No debe nada fiado.</div>') +
    (d.apartados.length ? '<h3 style="margin:16px 0 8px">Apartados</h3><div class="lista">' + d.apartados.map(function (v) {
      var s = saldoVenta(v);
      return '<button type="button" class="item" data-venta="' + v.id + '"><div class="crece"><div class="titulo">#' + v.numero + ' · hasta el ' + fmtFecha(v.vence_en) + '</div>' +
        '<div class="sub">' + (d.items.get(v.id) || []).map(function (i) { return esc(i.descripcion); }).join(', ') + '</div></div>' +
        '<div class="derecha num fuerte">' + (s > 0.004 ? 'Falta ' + fmtUSD(s) : '<span class="ok-txt">Pagado</span>') + '</div></button>';
    }).join('') + '</div><p class="ayuda">Los apartados se abonan aparte, desde cada apartado.</p>' : '');

  h.cuerpo.addEventListener('click', async function (e) {
    var vb = e.target.closest('[data-venta]');
    if (vb) { verVenta(Number(vb.dataset.venta)); return; }
    var b = e.target.closest('[data-cc]'); if (!b) return;
    if (b.dataset.cc === 'ficha') { h.cerrar(); verCliente(cliId); return; }
    if (b.dataset.cc === 'estado') {
      if (!cli.telefono) toast('La clienta no tiene teléfono: se copia el mensaje para que lo envíes.');
      compartirTexto(textoEstadoCuenta(d), cli.telefono);
      return;
    }
    if (b.dataset.cc === 'abonar') {
      var r = await hojaAbonoCuenta(d);
      if (!r) return;
      h.cerrar();
      await cargarClientes();
      if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
      var texto = textoReciboAbono(cli, r.resultado, r.pagosTxt, d.fiados);
      hojaReciboAbono(cli, r.resultado, texto);
      avisarDuena('Avísale a ' + nombreDuena(), texto);
    }
  });
}

/* ---------------- Abonar a la cuenta (se reparte de la más vieja a la más nueva) ---------------- */
function hojaAbonoCuenta(d) {
  return new Promise(function (resolver) {
    var listo = false, saldoFav = 0, clave = nuevaClave(), editor = null, cli = d.cliente;
    var h = abrirHoja({
      titulo: 'Abono · ' + cli.nombre, cerrarFuera: false,
      html: '<p class="suave" style="margin:0 0 12px">Debe <b>' + fmtUSD(d.deuda) + '</b> en ' + d.fiados.length + ' cuenta' + (d.fiados.length === 1 ? '' : 's') +
        '. El abono se aplica primero a la más vieja.</p>' +
        '<div id="acPagos"></div><h3 style="margin:16px 0 8px">Así se reparte</h3><div id="acReparto" class="lista"></div>',
      pie: '<button type="button" class="btn btn-ancho" id="acOk">Registrar abono</button>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    // Vista previa del reparto (el reparto de verdad lo hace la base con los saldos frescos)
    function pintarReparto() {
      if (!editor) return;
      var resto = editor.cobrado();
      h.$('#acReparto').innerHTML = d.fiados.map(function (v) {
        var s = saldoVenta(v), a = redondear2(Math.min(s, Math.max(resto, 0)));
        resto = redondear2(resto - a);
        return '<div class="item"><div class="crece">#' + v.numero + ' · ' + fmtFecha(v.creado_en) + '<div class="sub">debe ' + fmtUSD(s) + '</div></div>' +
          '<div class="derecha num">' + (a > 0.004 ? '<div class="fuerte">' + fmtUSD(a) + '</div><div class="sub ' + (s - a > 0.004 ? '' : 'ok-txt') + '">' +
            (s - a > 0.004 ? 'queda ' + fmtUSD(s - a) : 'pagada') + '</div>' : '<span class="tenue">—</span>') + '</div></div>';
      }).join('');
      h.$('#acOk').textContent = editor.cobrado() > 0.004 ? 'Registrar abono de ' + fmtUSD(editor.cobrado()) : 'Registrar abono';
    }
    editor = editorPagos(h.$('#acPagos'), {
      total: d.deuda, cliente: function () { return cli.id; }, saldoFavor: function () { return saldoFav; }, alCambiar: pintarReparto
    });
    pintarReparto();
    saldoFavorCliente(cli.id).then(function (x) { saldoFav = x; if (x > 0.004) editor.refrescar(); }).catch(function () {});
    protegerBoton(h.$('#acOk'), async function () {
      if (editor.errores()) throw new Error('Revisa los montos: hay uno que no es un número.');
      await cargarConfig();
      if (editor.tasaCambio()) throw new Error('La tasa cambió. Revisa y vuelve a tocar el botón.');
      var c = editor.cobrado();
      if (c <= 0) throw new Error('Escribe el monto del abono.');
      if (c > d.deuda + 0.004) throw new Error('El abono es mayor que lo que debe (' + fmtUSD(d.deuda) + ').');
      var pagos = editor.pagos(), pagosTxt = editor.resumenTexto();
      var r = await rpc('jab_abonar_cliente', { p_cliente: cli.id, p_pagos: pagos, p_clave: clave });
      listo = true; h.cerrar(); resolver({ resultado: r, pagosTxt: pagosTxt });
    }, 'Registrando…');
  });
}

// Comprobante en pantalla y botón para mandárselo a la clienta
function hojaReciboAbono(cli, r, texto) {
  var h = abrirHoja({
    titulo: 'Abono registrado',
    html: '<div class="aviso aviso-ok fila" style="margin-bottom:12px">' + icono('check', 'ic-chico') + ' Abono de ' + fmtUSD(r.total) + ' registrado.</div>' +
      '<pre class="mensaje-wa">' + esc(texto) + '</pre>',
    pie: '<div class="botonera"><button type="button" class="btn" id="raEnviar">' + icono('enviar', 'ic-chico') + ' Enviar recibo a la clienta</button>' +
      '<button type="button" class="btn btn-sec" id="raCuenta">Ver la cuenta</button></div>'
  });
  h.$('#raEnviar').onclick = function () {
    if (!cli.telefono) toast('La clienta no tiene teléfono: se copia el recibo para que lo envíes.');
    compartirTexto(texto, cli.telefono);
  };
  h.$('#raCuenta').onclick = function () { h.cerrar(); hojaCuentaCliente(cli.id); };
}
