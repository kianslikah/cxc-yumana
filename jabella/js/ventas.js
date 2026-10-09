// JABELLA — ventas del día, apartados, fiados, detalle de una venta, abonos, cambios y anulaciones.
'use strict';

function saldoVenta(v) { return redondear2(Number(v.total) - Number(v.pagado)); }

function etiquetaVenta(v) {
  if (v.estado === 'anulada') return '<span class="etq etq-error">Anulada</span>';
  if (v.estado === 'cancelada') return '<span class="etq">Apartado cancelado</span>';
  if (v.tipo === 'apartado' && !v.entregada) {
    return v.vence_en < hoyCaracas() ? '<span class="etq etq-error">Apartado vencido</span>' : '<span class="etq etq-aviso">Apartado</span>';
  }
  if (v.tipo === 'fiado') return saldoVenta(v) > 0.004 ? '<span class="etq etq-aviso">Fiado</span>' : '<span class="etq etq-ok">Fiado pagado</span>';
  if (v.tipo === 'cambio') return '<span class="etq etq-lila">Cambio</span>';
  if (v.era_apartado) return '<span class="etq etq-ok">Apartado entregado</span>';
  return '<span class="etq etq-ok">Contado</span>';
}

function filaVentaHtml(v) {
  var cli = v.cliente_id ? ST.cliPorId.get(v.cliente_id) : null;
  var s = saldoVenta(v);
  var debe = v.estado === 'activa' && (v.tipo === 'apartado' || v.tipo === 'fiado') && s > 0.004;
  return '<button type="button" class="item" data-venta="' + v.id + '">' +
    '<div class="crece"><div class="titulo fila" style="gap:8px">#' + v.numero + ' ' + etiquetaVenta(v) + '</div>' +
      '<div class="sub corta">' + fmtFechaHora(v.creado_en) + (cli ? ' · ' + esc(cli.nombre) : '') + '</div></div>' +
    '<div class="derecha"><div class="num fuerte' + (v.estado !== 'activa' ? ' tachado' : '') + '">' + fmtUSD(v.total) + '</div>' +
      (debe ? '<div class="sub aviso-txt num">Debe ' + fmtUSD(s) + '</div>' : '') + '</div></button>';
}

/* ---------------- Vista Ventas ---------------- */
var VistaVentas = {
  titulo: 'Ventas',
  pestana: 'hoy',
  fecha: null,
  mostrar(cont) {
    this.fecha = this.fecha || hoyCaracas();
    cont.innerHTML =
      '<div class="seg" id="vtPestanas" style="margin-bottom:14px">' +
        '<button type="button" data-p="hoy">Por día</button>' +
        '<button type="button" data-p="apartados">Apartados</button>' +
        '<button type="button" data-p="fiados">Fiados</button></div>' +
      '<div id="vtCuerpo"></div>';
    var self = this;
    $('#vtPestanas').addEventListener('click', function (e) {
      var b = e.target.closest('[data-p]'); if (!b) return;
      self.pestana = b.dataset.p; self.pintar();
    });
    $('#vtCuerpo').addEventListener('click', function (e) {
      var b = e.target.closest('[data-venta]'); if (b) verVenta(Number(b.dataset.venta));
    });
    this.pintar();
  },
  refrescar() { if ($('#vtCuerpo')) this.pintar(); },
  pintar() {
    var self = this;
    $$('#vtPestanas button').forEach(function (b) { b.classList.toggle('activo', b.dataset.p === self.pestana); });
    var c = $('#vtCuerpo');
    c.innerHTML = '<div class="cargando">Cargando…</div>';
    var f = { hoy: this.pintarDia, apartados: this.pintarApartados, fiados: this.pintarFiados }[this.pestana];
    f.call(this, c).catch(function (e) {
      c.innerHTML = '<div class="aviso aviso-error">No se pudo cargar: ' + esc(errMsg(e)) + '</div>';
    });
  },
  async pintarDia(c) {
    var self = this, rango = rangoDia(this.fecha);
    var res = await Promise.all([
      rpc('jab_resumen_dia', { p_fecha: this.fecha }),
      traerTodo('jab_ventas', '*', function (q) { return q.gte('creado_en', rango[0]).lt('creado_en', rango[1]); })
    ]);
    var r = res[0], ventas = res[1].sort(function (a, b) { return b.id - a.id; });
    var esHoy = this.fecha === hoyCaracas();
    c.innerHTML =
      '<div class="fila" style="margin-bottom:12px;flex-wrap:wrap">' +
        '<label class="campo crece" style="min-width:170px"><span>Día</span><input type="date" id="vtFecha" value="' + this.fecha + '" max="' + hoyCaracas() + '"></label>' +
        (esDuena() ? '<button type="button" class="btn btn-sec" id="vtCambioLibre" style="align-self:flex-end">' + icono('cambio', 'ic-chico') + ' Cambio sin venta</button>' : '') +
        (esHoy ? '<button type="button" class="btn btn-sec" id="vtCierre" style="align-self:flex-end">' + icono('dinero', 'ic-chico') + ' Cerrar caja</button>' : '') +
      '</div>' +
      '<div class="tenue" style="margin-bottom:8px">' + esc(esHoy ? 'Hoy, ' + fmtFechaLarga(this.fecha) : fmtFechaLarga(this.fecha)) + '</div>' +
      '<div class="tarjetas-kpi">' +
        '<div class="kpi"><div class="t">Vendido</div><div class="v">' + fmtUSD(r.vendido) + '</div><div class="s">' + r.ventas + ' venta' + (r.ventas === 1 ? '' : 's') + ' · ' + r.prendas + ' prenda' + (r.prendas === 1 ? '' : 's') + '</div></div>' +
        (r.cobrado_usd != null ? '<div class="kpi"><div class="t">Entró en dinero</div><div class="v">' + fmtUSD(r.cobrado_usd) + '</div><div class="s">contando abonos</div></div>' : '') +
      '</div>' +
      (r.por_metodo.length ? '<div class="lista" style="margin-top:10px">' + r.por_metodo.map(function (m) {
        return '<div class="item"><div class="crece">' + esc(m.metodo) + ' <span class="tenue">(' + m.n + ')</span></div>' +
          '<div class="derecha num"><div class="fuerte">' + fmtMonto(m.monto, m.moneda) + '</div>' +
          (m.moneda === 'VES' ? '<div class="sub">≈ ' + fmtUSD(m.monto_usd) + '</div>' : '') + '</div></div>';
      }).join('') + '</div>' : '') +
      '<h3 style="margin:18px 0 8px">Ventas del día</h3>' +
      (ventas.length ? '<div class="lista" id="vtLista"></div>' : '<div class="vacio">No hay ventas este día.</div>');
    if (ventas.length) dibujarPorPartes($('#vtLista'), ventas, filaVentaHtml, 80);
    $('#vtFecha').addEventListener('change', function (e) { if (e.target.value) { self.fecha = e.target.value; self.pintar(); } });
    var cl = $('#vtCambioLibre');
    if (cl) cl.onclick = function () { hojaCambio(null, []); };
    var ci = $('#vtCierre');
    if (ci) ci.onclick = hojaCierre;
  },
  async pintarApartados(c) {
    var lista = await traerTodo('jab_ventas', '*', function (q) { return q.eq('tipo', 'apartado').eq('estado', 'activa').eq('entregada', false); });
    lista.sort(function (a, b) { return a.vence_en < b.vence_en ? -1 : a.vence_en > b.vence_en ? 1 : a.id - b.id; });
    var hoy = hoyCaracas();
    var porCobrar = lista.reduce(function (s, v) { return s + saldoVenta(v); }, 0);
    var vencidos = lista.filter(function (v) { return v.vence_en < hoy; }).length;
    c.innerHTML =
      '<div class="tarjetas-kpi">' +
        '<div class="kpi"><div class="t">Apartados</div><div class="v">' + lista.length + '</div></div>' +
        '<div class="kpi"><div class="t">Por cobrar</div><div class="v">' + fmtUSD(porCobrar) + '</div></div>' +
        '<div class="kpi"><div class="t">Vencidos</div><div class="v ' + (vencidos ? 'error-txt' : '') + '">' + vencidos + '</div></div>' +
      '</div>' +
      (lista.length ? '<div class="lista" style="margin-top:12px">' + lista.map(function (v) {
        var cli = ST.cliPorId.get(v.cliente_id), d = diasEntre(hoy, v.vence_en);
        var cuando = d < 0 ? '<span class="error-txt">Venció hace ' + (-d) + ' día' + (d === -1 ? '' : 's') + '</span>'
          : d === 0 ? '<span class="aviso-txt">Vence hoy</span>' : 'Vence en ' + d + ' día' + (d === 1 ? '' : 's') + ' (' + fmtFecha(v.vence_en) + ')';
        return '<button type="button" class="item" data-venta="' + v.id + '"><div class="crece">' +
          '<div class="titulo corta">' + esc(cli ? cli.nombre : 'Sin clienta') + ' <span class="tenue">#' + v.numero + '</span></div>' +
          '<div class="sub">' + cuando + '</div></div>' +
          '<div class="derecha num"><div class="fuerte">' + (saldoVenta(v) > 0.004 ? 'Debe ' + fmtUSD(saldoVenta(v)) : '<span class="ok-txt">Pagado</span>') + '</div>' +
          '<div class="sub">de ' + fmtUSD(v.total) + '</div></div></button>';
      }).join('') + '</div>' : '<div class="vacio"><h3>No hay apartados pendientes</h3>Cuando una clienta aparte una prenda aparecerá aquí con su fecha límite.</div>');
  },
  async pintarFiados(c) {
    var lista = (await traerTodo('jab_ventas', '*', function (q) { return q.eq('tipo', 'fiado').eq('estado', 'activa'); }))
      .filter(function (v) { return saldoVenta(v) > 0.004; });
    lista.sort(function (a, b) { return a.id - b.id; });
    var hoy = hoyCaracas();
    var porCobrar = lista.reduce(function (s, v) { return s + saldoVenta(v); }, 0);
    c.innerHTML =
      '<div class="tarjetas-kpi">' +
        '<div class="kpi"><div class="t">Fiados pendientes</div><div class="v">' + lista.length + '</div></div>' +
        '<div class="kpi"><div class="t">Por cobrar</div><div class="v">' + fmtUSD(porCobrar) + '</div></div>' +
      '</div>' +
      (lista.length ? '<div class="lista" style="margin-top:12px">' + lista.map(function (v) {
        var cli = ST.cliPorId.get(v.cliente_id), d = diasEntre(fechaCaracas(v.creado_en), hoy);
        return '<button type="button" class="item" data-venta="' + v.id + '"><div class="crece">' +
          '<div class="titulo corta">' + esc(cli ? cli.nombre : 'Sin clienta') + ' <span class="tenue">#' + v.numero + '</span></div>' +
          '<div class="sub' + (d > 30 ? ' error-txt' : d > 15 ? ' aviso-txt' : '') + '">' + (d === 0 ? 'Desde hoy' : 'Hace ' + d + ' día' + (d === 1 ? '' : 's')) + '</div></div>' +
          '<div class="derecha num"><div class="fuerte">Debe ' + fmtUSD(saldoVenta(v)) + '</div><div class="sub">de ' + fmtUSD(v.total) + '</div></div></button>';
      }).join('') + '</div>' : '<div class="vacio"><h3>Nadie debe</h3>Los fiados con saldo pendiente aparecen aquí, del más viejo al más nuevo.</div>');
  }
};

/* ---------------- Detalle de una venta ---------------- */
async function datosVenta(id) {
  var res = await Promise.all([
    sb.from('jab_ventas').select('*').eq('id', id).single(),
    sb.from('jab_venta_items').select('*').eq('venta_id', id).order('id'),
    sb.from('jab_pagos').select('*').eq('venta_id', id).order('id'),
    sb.from('jab_ventas').select('id, numero, estado').eq('venta_origen_id', id).order('id')
  ]);
  res.forEach(function (r) { if (r.error) throw r.error; });
  var d = { venta: res[0].data, items: res[1].data, pagos: res[2].data, cambios: res[3].data, origen: null };
  if (d.venta.venta_origen_id) {
    var o = await sb.from('jab_ventas').select('id, numero').eq('id', d.venta.venta_origen_id).single();
    if (!o.error) d.origen = o.data;
  }
  return d;
}

function nombreMetodo(id) { var m = ST.metodos.find(function (x) { return x.id === id; }); return m ? m.nombre : '—'; }

function textoRecibo(d) {
  var v = d.venta, cli = v.cliente_id ? ST.cliPorId.get(v.cliente_id) : null;
  var t = ['JABELLA Store', (v.tipo === 'cambio' ? 'Cambio' : v.tipo === 'apartado' && !v.entregada ? 'Apartado' : 'Venta') + ' #' + v.numero + ' · ' + fmtFechaHora(v.creado_en)];
  if (cli) t.push('Clienta: ' + cli.nombre);
  t.push('');
  d.items.forEach(function (i) {
    t.push((i.cantidad < 0 ? 'Devuelve ' + (-i.cantidad) : i.cantidad) + ' × ' + i.descripcion + '  ' + fmtUSD(Math.abs(i.cantidad) * i.precio));
  });
  t.push('');
  t.push('Total: ' + fmtUSD(v.total));
  var vivos = d.pagos.filter(function (p) { return !p.anulado_en; });
  if (vivos.length) t.push('Pagado: ' + fmtUSD(v.pagado) + ' (' + vivos.map(function (p) {
    return nombreMetodo(p.metodo_id) + (p.moneda === 'VES' ? ' ' + fmtBs(p.monto) : ' ' + fmtUSD(p.monto_usd));
  }).join(', ') + ')');
  var s = saldoVenta(v);
  if (v.estado === 'activa' && s > 0.004) t.push('Pendiente: ' + fmtUSD(s));
  if (v.tipo === 'cambio' && v.total < 0) t.push('Queda a tu favor: ' + fmtUSD(-v.total));
  if (v.tipo === 'apartado' && !v.entregada && v.estado === 'activa') t.push('Apartado hasta el ' + fmtFecha(v.vence_en));
  t.push('');
  t.push('¡Gracias por tu compra! · @jabella.store');
  return t.join('\n');
}

async function verVenta(id, opts) {
  opts = opts || {};
  var h = abrirHoja({ titulo: 'Venta', clase: 'completa', html: '<div class="cargando">Cargando…</div>' });
  var d;
  try { d = await datosVenta(id); } catch (e) { h.cuerpo.innerHTML = '<div class="aviso aviso-error">' + esc(errMsg(e)) + '</div>'; return; }
  var v = d.venta, s = saldoVenta(v);
  var cli = v.cliente_id ? ST.cliPorId.get(v.cliente_id) : null;
  var vendedora = ST.usrPorId.get(v.usuario_id);
  var activa = v.estado === 'activa';
  var esApartadoPend = activa && v.tipo === 'apartado' && !v.entregada;
  h.el.querySelector('.hoja-cab h2').textContent = (v.tipo === 'cambio' ? 'Cambio' : 'Venta') + ' #' + v.numero;

  var acciones = [];
  if (activa && (v.tipo === 'apartado' || v.tipo === 'fiado') && s > 0.004) acciones.push('<button type="button" class="btn" data-acc="abonar">Registrar abono</button>');
  if (esApartadoPend) acciones.push('<button type="button" class="btn btn-sec" data-acc="entregar">' + icono('entregar', 'ic-chico') + ' Entregar</button>');
  if (activa && v.entregada) acciones.push('<button type="button" class="btn btn-sec" data-acc="cambio">' + icono('cambio', 'ic-chico') + ' Cambio</button>');
  acciones.push('<button type="button" class="btn btn-sec" data-acc="recibo">' + icono('enviar', 'ic-chico') + ' Enviar recibo</button>');
  var accDuena = [];
  if (esDuena() && esApartadoPend) {
    accDuena.push('<button type="button" class="btn btn-sec btn-chico" data-acc="extender">' + icono('calendario', 'ic-chico') + ' Dar más días</button>');
    accDuena.push('<button type="button" class="btn btn-peligro btn-chico" data-acc="cancelar">Cancelar apartado</button>');
  }
  if (esDuena() && activa) accDuena.push('<button type="button" class="btn btn-peligro btn-chico" data-acc="anular">Anular</button>');

  var html =
    (opts.recien ? '<div class="aviso aviso-ok fila" style="margin-bottom:12px">' + icono('check', 'ic-chico') + ' Listo. Puedes enviarle el recibo a la clienta.</div>' : '') +
    '<div class="fila-entre" style="margin-bottom:10px"><div>' + etiquetaVenta(v) + '</div><div class="tenue">' + fmtFechaHora(v.creado_en) + '</div></div>' +
    '<div class="tarjeta" style="padding:12px 14px">' +
      '<div class="fila-entre"><span class="tenue">Clienta</span>' +
        (cli ? '<button type="button" class="btn btn-plano btn-chico" data-acc="cliente">' + esc(cli.nombre) + '</button>' : '<span>Sin clienta</span>') + '</div>' +
      (vendedora ? '<div class="fila-entre"><span class="tenue">Atendió</span><span>' + esc(vendedora.nombre) + '</span></div>' : '') +
      (esApartadoPend ? '<div class="fila-entre"><span class="tenue">Apartado hasta</span><span class="' + (v.vence_en < hoyCaracas() ? 'error-txt' : '') + '">' + fmtFechaLarga(v.vence_en) + '</span></div>' : '') +
      (d.origen ? '<div class="fila-entre"><span class="tenue">Cambio de</span><button type="button" class="btn btn-plano btn-chico" data-ir="' + d.origen.id + '">Venta #' + d.origen.numero + '</button></div>' : '') +
      (d.cambios.length ? '<div class="fila-entre"><span class="tenue">Cambios</span><span>' + d.cambios.map(function (x) {
        return '<button type="button" class="btn btn-plano btn-chico" data-ir="' + x.id + '">#' + x.numero + (x.estado !== 'activa' ? ' (anulado)' : '') + '</button>';
      }).join('') + '</span></div>' : '') +
      (v.nota ? '<div style="margin-top:6px"><span class="tenue">Nota:</span> ' + esc(v.nota) + '</div>' : '') +
      (v.estado === 'anulada' ? '<div class="aviso aviso-error" style="margin-top:8px">Anulada: ' + esc(v.motivo_anulacion || '') + '</div>' : '') +
      (v.estado === 'cancelada' ? '<div class="aviso" style="margin-top:8px">Apartado cancelado. ' +
        (v.abono_retenido > 0 ? 'La tienda se quedó el abono de ' + fmtUSD(v.abono_retenido) + '.' : 'El abono quedó como saldo a favor de la clienta.') + '</div>' : '') +
    '</div>' +
    '<h3 style="margin:16px 0 6px">Prendas</h3><div class="tarjeta" style="padding:4px 14px">' + d.items.map(function (i) {
      var p = ST.prodPorId.get(i.producto_id);
      return '<div class="linea">' + (p ? imgProducto(p, 'miniatura') : '') +
        '<div class="crece"><div>' + (i.cantidad < 0 ? '<span class="etq etq-lila">Devuelve</span> ' : '') + esc(i.descripcion) + '</div>' +
        '<div class="sub tenue">' + Math.abs(i.cantidad) + ' × ' + fmtUSD(i.precio) + (Number(i.precio) !== Number(i.precio_lista) ? ' (lista ' + fmtUSD(i.precio_lista) + ')' : '') + '</div></div>' +
        '<div class="num">' + fmtUSD(i.cantidad * i.precio) + '</div></div>';
    }).join('') + '</div>' +
    '<div class="totales" style="margin-top:12px">' +
      '<div class="fila-entre"><span>Total</span><span class="num grande">' + fmtUSD(v.total) + '</span></div>' +
      (v.tipo !== 'cambio' || v.total > 0 ? '<div class="fila-entre"><span>Pagado</span><span class="num">' + fmtUSD(v.pagado) + '</span></div>' : '') +
      (activa && s > 0.004 ? '<div class="fila-entre aviso-txt"><span>Debe</span><span class="num fuerte">' + fmtUSD(s) + '</span></div>' : '') +
      (v.tipo === 'cambio' && v.total < 0 ? '<div class="fila-entre ok-txt"><span>Quedó a favor de la clienta</span><span class="num fuerte">' + fmtUSD(-v.total) + '</span></div>' : '') +
    '</div>' +
    (d.pagos.length ? '<h3 style="margin:16px 0 6px">Pagos</h3><div class="lista">' + d.pagos.map(function (p) {
      var puedeAnular = esDuena() && !p.anulado_en && activa && v.tipo !== 'cambio';
      return '<div class="item"><div class="crece"><div class="' + (p.anulado_en ? 'tachado' : '') + '">' + esc(nombreMetodo(p.metodo_id)) +
        (p.referencia ? ' <span class="tenue">ref. ' + esc(p.referencia) + '</span>' : '') + '</div>' +
        '<div class="sub">' + fmtFechaHora(p.creado_en) + (p.anulado_en ? ' · anulado: ' + esc(p.motivo_anulacion || '') : '') + '</div></div>' +
        '<div class="derecha num"><div class="' + (p.anulado_en ? 'tachado' : 'fuerte') + '">' + fmtMonto(p.monto, p.moneda) + '</div>' +
        (p.moneda === 'VES' ? '<div class="sub">≈ ' + fmtUSD(p.monto_usd) + ' a ' + fmtTasa(p.tasa) + '</div>' : '') + '</div>' +
        (puedeAnular ? '<button type="button" class="btn btn-plano btn-icono" data-anular-pago="' + p.id + '" aria-label="Anular abono">' + icono('basura', 'ic-chico') + '</button>' : '') +
      '</div>';
    }).join('') + '</div>' : '') +
    '<div class="botonera" style="margin-top:18px">' + acciones.join('') + '</div>' +
    (accDuena.length ? '<div class="botonera" style="margin-top:10px">' + accDuena.join('') + '</div>' : '');
  h.cuerpo.innerHTML = html;

  async function trasCambio(msg) {
    toast(msg, 'ok');
    h.cerrar();
    await Promise.all([cargarCatalogo(), cargarClientes()]);
    if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
    verVenta(id);
  }

  // Una acción a la vez: un segundo toque mientras la primera corre no hace nada
  var ocupado = false;
  h.cuerpo.addEventListener('click', async function (e) {
    var ir = e.target.closest('[data-ir]');
    if (ir) { h.cerrar(); verVenta(Number(ir.dataset.ir)); return; }
    if (ocupado) return;
    var ap = e.target.closest('[data-anular-pago]');
    var b = e.target.closest('[data-acc]');
    if (!ap && !b) return;
    ocupado = true;
    try {
      if (ap) await anularPagoDesdeVenta(v, Number(ap.dataset.anularPago), trasCambio);
      else await accion(b.dataset.acc);
    } finally { ocupado = false; }
  });

  async function accion(acc) {
    try {
      if (acc === 'cliente') { verCliente(v.cliente_id); return; }
      if (acc === 'recibo') { compartirTexto(textoRecibo(d), cli && cli.telefono); return; }
      if (acc === 'abonar') { if (await hojaAbono(v)) await trasCambio('Abono registrado'); return; }
      if (acc === 'cambio') { h.cerrar(); hojaCambio(v, d.items); return; }
      if (acc === 'entregar') {
        if (s > 0.004) {
          if (!esDuena() && !ST.cfg.vendedora_fia) { toast('Falta pagar ' + fmtUSD(s) + ' para entregar.', 'error'); return; }
          if (!(await confirmar({ titulo: 'Entregar con deuda', mensaje: 'Falta pagar ' + fmtUSD(s) + '. ¿Se lo lleva y queda como fiado?', boton: 'Entregar y dejar fiado' }))) return;
          await rpc('jab_entregar_apartado', { p_venta: id, p_dejar_fiado: true });
        } else {
          if (!(await confirmar({ titulo: 'Entregar apartado', mensaje: '¿La clienta ya se llevó las prendas?', boton: 'Sí, entregar' }))) return;
          await rpc('jab_entregar_apartado', { p_venta: id, p_dejar_fiado: false });
        }
        await trasCambio('Apartado entregado'); return;
      }
      if (acc === 'extender') {
        var dias = await confirmar({ titulo: 'Dar más días', mensaje: 'Vence el ' + fmtFechaLarga(v.vence_en) + '.', pedir: 'Días adicionales', tipo: 'numero', valor: '7', boton: 'Extender' });
        if (!dias) return;
        var n = parseInt(dias, 10);
        if (!(n > 0)) { toast('Escribe un número de días', 'error'); return; }
        var nueva = await rpc('jab_extender_apartado', { p_venta: id, p_dias: n });
        await trasCambio('Ahora vence el ' + fmtFecha(nueva)); return;
      }
      if (acc === 'cancelar') { if (await hojaCancelarApartado(v)) await trasCambio('Apartado cancelado'); return; }
      if (acc === 'anular') {
        var mot = await confirmar({
          titulo: 'Anular venta #' + v.numero,
          mensajeHtml: 'Las prendas vuelven al inventario y los pagos se anulan.<br><b>Úsalo solo para corregir un error.</b>',
          pedir: 'Motivo', boton: 'Anular venta', peligro: true
        });
        if (!mot) return;
        await rpc('jab_anular_venta', { p_venta: id, p_motivo: mot });
        await trasCambio('Venta anulada'); return;
      }
    } catch (err) { toast(errMsg(err), 'error'); }
  }
}

// Anular un pago (ej.: pago móvil que nunca llegó). Si las prendas ya se entregaron, queda como fiado.
async function anularPagoDesdeVenta(v, pagoId, trasCambio) {
  var entregada = v.entregada;
  var mensaje = entregada
    ? 'Ese dinero no entró. Como las prendas ya se entregaron, la venta queda como fiado y la clienta debe ese monto.'
    : 'El abono se marca como anulado y la deuda del apartado vuelve a subir.';
  var motivo = await confirmar({ titulo: 'Anular pago', mensaje: mensaje, pedir: 'Motivo (ej.: el pago móvil no llegó)', boton: 'Anular pago', peligro: true });
  if (!motivo) return;
  var cliente = null;
  if (entregada && !v.cliente_id) {
    toast('Elige a qué clienta se le anota la deuda');
    var c = await elegirCliente();
    if (!c) return;
    cliente = c.id;
  }
  try {
    await rpc('jab_anular_pago', { p_pago: pagoId, p_motivo: motivo, p_cliente: cliente });
    await trasCambio('Pago anulado');
  } catch (err) { toast(errMsg(err), 'error'); }
}

function hojaAbono(v) {
  return new Promise(function (resolver) {
    var listo = false, saldoFav = 0, clave = nuevaClave();
    var s = saldoVenta(v), cli = ST.cliPorId.get(v.cliente_id);
    var h = abrirHoja({
      titulo: 'Abono · #' + v.numero,
      cerrarFuera: false,
      html: '<p class="suave" style="margin:0 0 12px">' + esc(cli ? cli.nombre : '') + ' debe ' + fmtUSD(s) + '.</p><div id="abPagos"></div>',
      pie: '<button type="button" class="btn btn-ancho" id="abOk">Registrar abono</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    var editor = editorPagos(h.$('#abPagos'), {
      total: s, cliente: function () { return v.cliente_id; }, saldoFavor: function () { return saldoFav; }
    });
    saldoFavorCliente(v.cliente_id).then(function (x) { saldoFav = x; if (x > 0.004) editor.refrescar(); }).catch(function () {});
    protegerBoton(h.$('#abOk'), async function () {
      if (editor.errores()) throw new Error('Revisa los montos: hay uno que no es un número.');
      await cargarConfig();
      if (editor.tasaCambio()) throw new Error('La tasa cambió. Revisa y vuelve a tocar el botón.');
      var c = editor.cobrado();
      if (c <= 0) throw new Error('Escribe el monto del abono.');
      if (c > s + 0.004) throw new Error('El abono es mayor que lo que debe (' + fmtUSD(s) + ').');
      await rpc('jab_registrar_abono', { p_venta: v.id, p_pagos: editor.pagos(), p_clave: clave });
      listo = true; h.cerrar(); resolver(true);
    }, 'Registrando…');
  });
}

function hojaCancelarApartado(v) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: 'Cancelar apartado #' + v.numero,
      html: '<p style="margin-top:0">Las prendas vuelven al inventario. La clienta abonó <b>' + fmtUSD(v.pagado) + '</b>. ¿Qué pasa con ese dinero?</p>' +
        '<div class="pila">' +
          '<button type="button" class="btn btn-sec btn-ancho" data-d="saldo_favor" style="justify-content:flex-start;text-align:left;min-height:64px">Queda como saldo a favor de la clienta<br><span class="tenue">Lo usa en otra compra</span></button>' +
          '<button type="button" class="btn btn-sec btn-ancho" data-d="tienda" style="justify-content:flex-start;text-align:left;min-height:64px">La tienda se queda el abono<br><span class="tenue">Por no retirar a tiempo</span></button>' +
        '</div>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    h.cuerpo.addEventListener('click', async function (e) {
      var b = e.target.closest('[data-d]'); if (!b || b.disabled) return;
      $$('[data-d]', h.el).forEach(function (x) { x.disabled = true; });
      try {
        await rpc('jab_cancelar_apartado', { p_venta: v.id, p_destino: b.dataset.d });
        listo = true; h.cerrar(); resolver(true);
      } catch (err) {
        toast(errMsg(err), 'error');
        $$('[data-d]', h.el).forEach(function (x) { x.disabled = false; });
      }
    });
  });
}

/* ---------------- Buscar una prenda (para cambios) ---------------- */
function buscarPrenda(titulo) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: titulo || 'Elegir prenda', clase: 'completa',
      html: '<div class="buscador" style="margin-bottom:12px">' + icono('buscar', 'ic-chico') +
        '<input class="entrada" id="bpBuscar" placeholder="Nombre o código" autocomplete="off"></div><div id="bpLista"></div>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    function pintar() {
      var q = normalizar(h.$('#bpBuscar').value.trim());
      var lista = ST.productos.filter(function (p) {
        return p.activo && (!q || normalizar(p.nombre).indexOf(q) >= 0 || normalizar(p.codigo).indexOf(q) >= 0);
      }).sort(function (a, b) { return b.id - a.id; });
      var cont = h.$('#bpLista');
      if (!lista.length) { cont.innerHTML = '<div class="vacio">No hay prendas que coincidan.</div>'; return; }
      cont.innerHTML = '<div class="lista"></div>';
      dibujarPorPartes(cont, lista, function (p) {
        return '<button type="button" class="item" data-p="' + p.id + '">' + imgProducto(p, 'miniatura') +
          '<div class="crece"><div class="titulo corta">' + esc(p.nombre) + '</div><div class="sub">' + esc(p.codigo) + ' · ' + stockProducto(p.id) + ' disp.</div></div>' +
          '<div class="num">' + fmtUSD(p.precio) + '</div></button>';
      }, 60, '.lista');
    }
    h.$('#bpBuscar').addEventListener('input', debounce(pintar, 200));
    h.$('#bpLista').addEventListener('click', function (e) {
      var b = e.target.closest('[data-p]'); if (!b) return;
      listo = true; h.cerrar(); resolver(ST.prodPorId.get(Number(b.dataset.p)));
    });
    pintar();
  });
}

/* ---------------- Cambio de prendas ---------------- */
// venta = venta original (o null para un cambio sin venta registrada, solo la dueña)
async function hojaCambio(venta, items) {
  var devueltos = []; // {item (venta_item) | null, variante_id, cantidad, precio, desc, max}
  var entregados = []; // {variante_id, cantidad, precio (null = lista)}
  var cliente = venta && venta.cliente_id ? ST.cliPorId.get(venta.cliente_id) : null;
  var saldoFav = 0, editor = null, clave = nuevaClave();
  if (cliente) { try { saldoFav = await saldoFavorCliente(cliente.id); } catch (e) { saldoFav = 0; } }

  if (venta) {
    var vendidos = items.filter(function (i) { return i.cantidad > 0; });
    var ids = vendidos.map(function (i) { return i.id; });
    var ya = {};
    if (ids.length) {
      var r = await sb.from('jab_venta_items').select('item_origen_id, cantidad, jab_ventas!inner(estado)').in('item_origen_id', ids).eq('jab_ventas.estado', 'activa');
      if (r.error) { toast(errMsg(r.error), 'error'); return; }
      r.data.forEach(function (x) { ya[x.item_origen_id] = (ya[x.item_origen_id] || 0) - x.cantidad; });
    }
    devueltos = vendidos.map(function (i) {
      return { item: i, variante_id: i.variante_id, cantidad: 0, precio: Number(i.precio), desc: i.descripcion, max: i.cantidad - (ya[i.id] || 0) };
    });
  }

  var h = abrirHoja({
    titulo: venta ? 'Cambio de la venta #' + venta.numero : 'Cambio sin venta registrada',
    clase: 'completa ancha', cerrarFuera: false,
    html:
      (venta ? '' : '<div class="aviso" style="margin-bottom:12px">Úsalo para prendas vendidas antes de usar el sistema. Elige la prenda que devuelve y el precio al que se vendió.</div>') +
      '<h3 style="margin:0 0 8px">1. Lo que devuelve</h3><div id="cmDev"></div>' +
      '<h3 style="margin:18px 0 8px">2. Lo que se lleva</h3><div id="cmEnt"></div>' +
      '<button type="button" class="btn btn-sec btn-chico" id="cmAgregar" style="margin-top:8px">' + icono('mas', 'ic-chico') + ' Agregar prenda</button>' +
      '<h3 style="margin:18px 0 8px">3. Diferencia</h3>' +
      '<div class="tarjeta" style="padding:12px 14px;margin-bottom:10px"><div class="fila-entre">' +
        '<div class="crece"><div class="tenue">Clienta</div><div id="cmCliente">' + esc(cliente ? cliente.nombre : 'Sin clienta') + '</div></div>' +
        (venta && venta.cliente_id ? '' : '<button type="button" class="btn btn-sec btn-chico" id="cmElegir">Elegir</button>') + '</div></div>' +
      '<div id="cmDif"></div><div id="cmPagos"></div>',
    pie: '<button type="button" class="btn btn-ancho" id="cmOk">Registrar cambio</button>'
  });

  function totalDev() { return redondear2(devueltos.reduce(function (s, d) { return s + d.cantidad * d.precio; }, 0)); }
  function totalEnt() {
    return redondear2(entregados.reduce(function (s, e) {
      var p = ST.prodPorId.get(ST.varPorId.get(e.variante_id).producto_id);
      return s + e.cantidad * (e.precio != null ? e.precio : Number(p.precio));
    }, 0));
  }
  function dif() { return redondear2(totalEnt() - totalDev()); }

  function pintarDev() {
    var c = h.$('#cmDev');
    if (venta) {
      c.innerHTML = '<div class="tarjeta" style="padding:4px 14px">' + devueltos.map(function (d, i) {
        return '<div class="linea"><div class="crece"><div class="corta">' + esc(d.desc) + '</div>' +
          '<div class="sub tenue">' + fmtUSD(d.precio) + ' · ' + (d.max > 0 ? 'puede devolver ' + d.max : 'ya se cambió') + '</div></div>' +
          '<div class="contador"><button type="button" data-dm="' + i + '" aria-label="Menos">−</button><span>' + d.cantidad + '</span>' +
          '<button type="button" data-dp="' + i + '" aria-label="Más"' + (d.max <= 0 ? ' disabled' : '') + '>+</button></div></div>';
      }).join('') + '</div>';
    } else {
      c.innerHTML = (devueltos.length ? '<div class="tarjeta" style="padding:4px 14px">' + devueltos.map(function (d, i) {
        return '<div class="linea"><div class="crece"><div class="corta">' + esc(d.desc) + '</div><div class="sub tenue">' + d.cantidad + ' × ' + fmtUSD(d.precio) + '</div></div>' +
          '<button type="button" class="btn btn-plano btn-icono" data-dq="' + i + '" aria-label="Quitar">' + icono('cerrar', 'ic-chico') + '</button></div>';
      }).join('') + '</div>' : '') +
      '<button type="button" class="btn btn-sec btn-chico" id="cmAgregarDev" style="margin-top:8px">' + icono('mas', 'ic-chico') + ' Prenda que devuelve</button>';
    }
  }
  function pintarEnt() {
    h.$('#cmEnt').innerHTML = entregados.length ? '<div class="tarjeta" style="padding:4px 14px">' + entregados.map(function (e, i) {
      var v = ST.varPorId.get(e.variante_id), p = ST.prodPorId.get(v.producto_id);
      return '<div class="linea">' + imgProducto(p, 'miniatura') + '<div class="crece"><div class="corta">' + esc(p.nombre) + '</div>' +
        '<div class="sub tenue">' + esc(descVariante(v)) + ' · ' + e.cantidad + ' × ' + fmtUSD(e.precio != null ? e.precio : p.precio) + '</div></div>' +
        '<button type="button" class="btn btn-plano btn-icono" data-eq="' + i + '" aria-label="Quitar">' + icono('cerrar', 'ic-chico') + '</button></div>';
    }).join('') + '</div>' : '<div class="tenue">Si solo devuelve y no se lleva nada, le queda saldo a favor.</div>';
  }
  function pintarDif() {
    var x = dif(), c = h.$('#cmDif'), pg = h.$('#cmPagos');
    var hayDev = devueltos.some(function (d) { return d.cantidad > 0; });
    if (!hayDev) { c.innerHTML = '<div class="tenue">Elige primero lo que devuelve.</div>'; pg.innerHTML = ''; editor = null; return; }
    if (x > 0.004) {
      c.innerHTML = '<div class="aviso" style="margin-bottom:10px">Debe pagar la diferencia: <b>' + fmtUSD(x) + '</b></div>';
      if (!editor) editor = editorPagos(pg, { total: x, cliente: function () { return cliente && cliente.id; }, saldoFavor: function () { return saldoFav; } });
      else editor.setTotal(x, null, null);
    } else {
      editor = null; pg.innerHTML = '';
      c.innerHTML = x < -0.004
        ? '<div class="aviso aviso-ok">Le queda <b>' + fmtUSD(-x) + '</b> a favor para otra compra.' + (cliente ? '' : ' Elige la clienta.') + '</div>'
        : '<div class="aviso aviso-ok">Cambio parejo: no hay diferencia.</div>';
    }
  }
  function todo() { pintarDev(); pintarEnt(); pintarDif(); }

  h.cuerpo.addEventListener('click', async function (e) {
    var t;
    if ((t = e.target.closest('[data-dm]'))) { var d = devueltos[Number(t.dataset.dm)]; if (d.cantidad > 0) d.cantidad--; todo(); return; }
    if ((t = e.target.closest('[data-dp]'))) { var d2 = devueltos[Number(t.dataset.dp)]; if (d2.cantidad < d2.max) d2.cantidad++; todo(); return; }
    if ((t = e.target.closest('[data-dq]'))) { devueltos.splice(Number(t.dataset.dq), 1); todo(); return; }
    if ((t = e.target.closest('[data-eq]'))) { entregados.splice(Number(t.dataset.eq), 1); todo(); return; }
    if (e.target.closest('#cmAgregarDev')) {
      var pd = await buscarPrenda('¿Qué prenda devuelve?'); if (!pd) return;
      var sd = await elegirVariante(pd, { boton: 'Devuelve esta', cualquiera: true, precioEditable: true }); if (!sd) return;
      var vv = ST.varPorId.get(sd.variante_id);
      devueltos.push({ item: null, variante_id: sd.variante_id, cantidad: sd.cantidad, precio: sd.precio != null ? sd.precio : Number(pd.precio), desc: pd.nombre + ' · ' + descVariante(vv) });
      todo(); return;
    }
    if (e.target.closest('#cmAgregar')) {
      var pe = await buscarPrenda('¿Qué se lleva?'); if (!pe) return;
      var se = await elegirVariante(pe, { boton: 'Se lleva esta', sinCarrito: true }); if (!se) return;
      var usadas = entregados.filter(function (x) { return x.variante_id === se.variante_id; }).reduce(function (s, x) { return s + x.cantidad; }, 0);
      if (usadas + se.cantidad > ST.varPorId.get(se.variante_id).stock) { toast('No hay tantas de esa talla', 'error'); return; }
      entregados.push(se); todo(); return;
    }
    if (e.target.closest('#cmElegir')) {
      var c = await elegirCliente(); if (!c) return;
      cliente = c; h.$('#cmCliente').textContent = c.nombre;
      try { saldoFav = await saldoFavorCliente(c.id); } catch (er) { saldoFav = 0; }
      if (editor) editor.refrescar();
      pintarDif();
    }
  });

  protegerBoton(h.$('#cmOk'), async function () {
    var dev = devueltos.filter(function (d) { return d.cantidad > 0; });
    if (!dev.length) throw new Error('Elige lo que devuelve.');
    var x = dif();
    if (x < -0.004 && !cliente) throw new Error('Elige la clienta para dejarle el saldo a favor.');
    var pagos = [];
    if (x > 0.004) {
      if (editor.errores()) throw new Error('Revisa los montos del pago.');
      await cargarConfig();
      if (editor.tasaCambio()) throw new Error('La tasa cambió. Revisa y vuelve a tocar el botón.');
      if (Math.abs(editor.cobrado() - x) > 0.004) throw new Error('Cobra exactamente la diferencia: ' + fmtUSD(x) + '.');
      pagos = editor.pagos();
    }
    var id = await rpc('jab_registrar_cambio', { p: {
      clave: clave,
      venta_origen_id: venta ? venta.id : null,
      cliente_id: cliente ? cliente.id : null,
      devueltos: dev.map(function (d) {
        return d.item ? { venta_item_id: d.item.id, cantidad: d.cantidad } : { variante_id: d.variante_id, cantidad: d.cantidad, precio: d.precio };
      }),
      entregados: entregados.map(function (e) { var o = { variante_id: e.variante_id, cantidad: e.cantidad }; if (e.precio != null) o.precio = e.precio; return o; }),
      pagos: pagos
    } });
    h.cerrar();
    toast('Cambio registrado', 'ok');
    await cargarCatalogo();
    if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
    verVenta(id, { recien: true });
  }, 'Registrando…');

  todo();
}
