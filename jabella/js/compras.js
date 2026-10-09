// JABELLA — compras SHEIN (solo la dueña): pedidos, paquetes en el casillero, cajas de reempaque
// que viajan (tránsito, aduana, llegada) y recepción: lo que llega entra al inventario con su costo real.
'use strict';

var CP = { compras: [], items: [], paquetes: [], envios: [], movs: [] };
var ETAPAS = ['camino', 'casillero', 'reempaque', 'transito', 'aduana', 'llegada'];
var NOMBRE_ETAPA = {
  camino: 'En camino al casillero', casillero: 'En el casillero de Miami', reempaque: 'En caja, esperando salir',
  transito: 'Viajando a Venezuela', aduana: 'En aduana', llegada: 'Llegó, falta recibir', revisar: 'Por revisar'
};
var ESTADOS_ENVIO = ['reempaque', 'transito', 'aduana', 'llegada', 'recibido'];
var NOMBRE_ENVIO = { reempaque: 'Reempaque', transito: 'En tránsito', aduana: 'En aduana', llegada: 'Llegó', recibido: 'Recibida' };

async function cargarCompras() {
  var r = await Promise.all([
    traerTodo('jab_compras'),
    traerTodo('jab_compra_items', '*', function (q) { return q.is('quitado_en', null); }),
    traerTodo('jab_paquetes', '*', function (q) { return q.is('quitado_en', null); }),
    traerTodo('jab_envios'),
    traerTodo('jab_movimientos_dinero', '*', function (q) { return q.eq('es_inversion', true); })
  ]);
  CP.compras = r[0]; CP.items = r[1]; CP.paquetes = r[2]; CP.envios = r[3]; CP.movs = r[4];
}
function compraPorId(id) { return CP.compras.find(function (c) { return c.id === id; }); }
function envioPorId(id) { return CP.envios.find(function (e) { return e.id === id; }); }
function itemsDe(cid) { return CP.items.filter(function (i) { return i.compra_id === cid; }); }
function paquetesDe(cid) { return CP.paquetes.filter(function (p) { return p.compra_id === cid; }); }
function pendiente(i) { return i.cantidad - i.recibidas - i.faltantes; }
function piezasPendientes(cid) { return itemsDe(cid).reduce(function (s, i) { return s + pendiente(i); }, 0); }
function subtotalCompra(cid) { return redondear2(itemsDe(cid).reduce(function (s, i) { return s + i.cantidad * Number(i.precio); }, 0)); }
function factorCompra(c) {
  var s = subtotalCompra(c.id);
  return c.total_pagado != null && s > 0 ? Number(c.total_pagado) / s : 1;
}
function pagosCompra(cid) {
  return CP.movs.filter(function (m) { return m.compra_id === cid && !m.anulado_en && Number(m.monto) < 0; });
}
function pagadoCompraUsd(cid) { return redondear2(pagosCompra(cid).reduce(function (s, m) { return s - Number(m.monto_usd); }, 0)); }
function etapaPaquete(p) {
  if (p.envio_id) { var e = envioPorId(p.envio_id); if (e && !e.anulado_en) return e.estado; }
  return p.estado;
}
// Etapa de un pedido = la del paquete más atrasado que todavía no se ha recibido
function etapaCompra(c) {
  if (c.anulada_en) return 'anulada';
  if (piezasPendientes(c.id) === 0) return itemsDe(c.id).some(function (i) { return i.faltantes > 0; }) ? 'cerrada' : 'recibida';
  var etapas = paquetesDe(c.id).map(etapaPaquete).filter(function (e) { return e !== 'recibido'; });
  if (!etapas.length) return 'revisar';
  return etapas.reduce(function (m, e) { return ETAPAS.indexOf(e) < ETAPAS.indexOf(m) ? e : m; });
}
function etiquetaCompra(c) {
  var e = etapaCompra(c);
  if (e === 'anulada') return '<span class="etq etq-error">Anulado</span>';
  if (e === 'recibida') return '<span class="etq etq-ok">Recibido completo</span>';
  if (e === 'cerrada') return '<span class="etq etq-aviso">Recibido con faltantes</span>';
  if (e === 'revisar') return '<span class="etq etq-aviso">Por revisar</span>';
  return '<span class="etq etq-lila">' + esc(NOMBRE_ETAPA[e]) + '</span>';
}
function etiquetaEnvio(e) {
  if (e.anulado_en) return '<span class="etq etq-error">Anulada</span>';
  return '<span class="etq ' + (e.estado === 'recibido' ? 'etq-ok' : 'etq-lila') + '">' + esc(NOMBRE_ENVIO[e.estado]) + '</span>';
}
function barraEtapas(estado) {
  var n = ESTADOS_ENVIO.indexOf(estado);
  return '<div class="etapas" aria-hidden="true">' + ESTADOS_ENVIO.map(function (_, i) { return '<span' + (i <= n ? ' class="hecha"' : '') + '></span>'; }).join('') + '</div>';
}
function descItem(i) { return i.descripcion + (i.talla ? ' · ' + i.talla : '') + (i.color ? ' · ' + i.color : ''); }
function imgItem(i, clase) {
  if (i.foto_mini || i.foto) return '<img class="' + clase + '" src="' + esc(fotoUrl(i.foto_mini || i.foto)) + '" alt="" loading="lazy">';
  return '<div class="' + clase + ' sin-foto">' + esc(iniciales(i.descripcion).toUpperCase()) + '</div>';
}

/* ---------------- Vista ---------------- */
var VistaCompras = {
  titulo: 'Compras',
  pestana: 'llegar',
  async mostrar(cont) {
    if (!esDuena()) { cont.innerHTML = '<div class="vacio">Solo la dueña ve esta sección.</div>'; return; }
    cont.innerHTML = '<div id="cpRaiz">' +
      '<div class="encabezado"><h2>Compras SHEIN</h2><div class="botonera">' +
        '<button type="button" class="btn btn-sec btn-chico" data-a="caja">' + icono('entregar', 'ic-chico') + ' Armar caja</button>' +
        '<button type="button" class="btn btn-chico" data-a="pedido">' + icono('mas', 'ic-chico') + ' Nuevo pedido</button></div></div>' +
      '<div id="cpKpi" style="margin-bottom:14px"></div>' +
      '<div class="seg" id="cpPestanas" style="margin-bottom:14px">' +
        '<button type="button" data-p="llegar">Por llegar</button><button type="button" data-p="pedidos">Pedidos</button>' +
        '<button type="button" data-p="cajas">Cajas</button><button type="button" data-p="faltantes">Faltantes</button></div>' +
      '<div id="cpCuerpo"><div class="cargando">Cargando compras…</div></div></div>';
    var self = this;
    $('#cpRaiz').addEventListener('click', function (e) {
      var b;
      if ((b = e.target.closest('[data-p]'))) { self.pestana = b.dataset.p; self.pintar(); return; }
      if ((b = e.target.closest('[data-a="pedido"]'))) { hojaCompra(null); return; }
      if ((b = e.target.closest('[data-a="caja"]'))) { hojaEnvio(null); return; }
      if ((b = e.target.closest('[data-compra]'))) { verCompra(Number(b.dataset.compra)); return; }
      if ((b = e.target.closest('[data-envio]'))) { verEnvio(Number(b.dataset.envio)); return; }
      if ((b = e.target.closest('[data-reembolso]'))) { hojaReembolso(Number(b.dataset.reembolso)); }
    });
    await this.refrescar();
  },
  async refrescar() {
    if (!$('#cpRaiz')) return;
    try { await cargarCompras(); this.pintar(); }
    catch (e) { $('#cpCuerpo').innerHTML = '<div class="aviso aviso-error">No se pudo cargar: ' + esc(errMsg(e)) + '</div>'; }
  },
  pintar() {
    var self = this;
    $$('#cpPestanas button').forEach(function (b) { b.classList.toggle('activo', b.dataset.p === self.pestana); });
    var vivas = CP.compras.filter(function (c) { return !c.anulada_en; });
    var piezas = 0, plata = 0;
    vivas.forEach(function (c) {
      var f = factorCompra(c);
      itemsDe(c.id).forEach(function (i) { piezas += pendiente(i); plata += pendiente(i) * Number(i.precio) * f; });
    });
    var enCasillero = CP.paquetes.filter(function (p) { var c = compraPorId(p.compra_id); return c && !c.anulada_en && p.estado === 'casillero' && !p.envio_id && piezasPendientes(c.id) > 0; }).length;
    var viajando = CP.envios.filter(function (e) { return !e.anulado_en && e.estado !== 'recibido'; }).length;
    $('#cpKpi').innerHTML = '<div class="tarjetas-kpi">' +
      '<div class="kpi"><div class="t">Piezas por llegar</div><div class="v">' + piezas + '</div></div>' +
      '<div class="kpi"><div class="t">Invertido en camino</div><div class="v">' + fmtUSD(plata) + '</div><div class="s">sin contar flete</div></div>' +
      '<div class="kpi"><div class="t">Paquetes en el casillero</div><div class="v">' + enCasillero + '</div><div class="s">sin caja todavía</div></div>' +
      '<div class="kpi"><div class="t">Cajas viajando</div><div class="v">' + viajando + '</div></div></div>';
    var c = $('#cpCuerpo');
    ({ llegar: this.pintarPorLlegar, pedidos: this.pintarPedidos, cajas: this.pintarCajas, faltantes: this.pintarFaltantes })[this.pestana].call(this, c);
  },
  pintarPorLlegar(c) {
    var grupos = {};
    CP.compras.forEach(function (cp) {
      var e = etapaCompra(cp);
      if (ETAPAS.indexOf(e) >= 0 || e === 'revisar') (grupos[e] = grupos[e] || []).push(cp);
    });
    var orden = ETAPAS.concat(['revisar']);
    var html = orden.filter(function (e) { return grupos[e]; }).map(function (e) {
      var lista = grupos[e].sort(function (a, b) { return a.id - b.id; });
      return '<div class="etapa-titulo">' + esc(NOMBRE_ETAPA[e]) + ' <span class="etq">' + lista.length + '</span></div>' +
        (e === 'revisar' ? '<p class="ayuda" style="margin-top:-4px">Sus paquetes ya se recibieron pero quedan piezas sin marcar: ábrelo y revisa qué falta.</p>' : '') +
        '<div class="lista">' + lista.map(filaCompraPorLlegar).join('') + '</div>';
    }).join('');
    c.innerHTML = html || '<div class="vacio"><h3>No hay nada en camino</h3>Cuando registres un pedido de SHEIN lo verás aquí, en la etapa en que va.' +
      '<br><button type="button" class="btn" data-a="pedido">' + icono('mas', 'ic-chico') + ' Registrar un pedido</button></div>';
  },
  pintarPedidos(c) {
    var lista = CP.compras.slice().sort(function (a, b) { return b.id - a.id; });
    if (!lista.length) { c.innerHTML = '<div class="vacio">Todavía no hay pedidos.</div>'; return; }
    c.innerHTML = '<div class="lista"></div>';
    dibujarPorPartes(c, lista, function (cp) {
      var its = itemsDe(cp.id), piezas = its.reduce(function (s, i) { return s + i.cantidad; }, 0);
      return '<button type="button" class="item" data-compra="' + cp.id + '"><div class="crece">' +
        '<div class="titulo fila" style="gap:8px">Pedido #' + cp.numero + ' ' + etiquetaCompra(cp) + '</div>' +
        '<div class="sub">' + esc(cp.tienda) + (cp.pedido_ref ? ' ' + esc(cp.pedido_ref) : '') + ' · ' + fmtFecha(cp.fecha) + ' · ' + piezas + ' pieza' + (piezas === 1 ? '' : 's') + '</div></div>' +
        '<div class="derecha"><div class="num fuerte">' + (cp.total_pagado != null ? fmtUSD(cp.total_pagado) : fmtUSD(subtotalCompra(cp.id))) + '</div></div></button>';
    }, 60, '.lista');
  },
  pintarCajas(c) {
    var lista = CP.envios.slice().sort(function (a, b) { return b.id - a.id; });
    if (!lista.length) {
      c.innerHTML = '<div class="vacio"><h3>No hay cajas</h3>Cuando todos los paquetes de un pedido estén en el casillero, arma la caja para el reempaque.</div>';
      return;
    }
    c.innerHTML = '<div class="lista">' + lista.map(function (e) {
      var paq = CP.paquetes.filter(function (p) { return p.envio_id === e.id; }).length;
      return '<button type="button" class="item" data-envio="' + e.id + '"><div class="crece">' +
        '<div class="titulo fila" style="gap:8px">Caja #' + e.numero + ' ' + etiquetaEnvio(e) + '</div>' +
        (e.anulado_en ? '' : barraEtapas(e.estado)) +
        '<div class="sub">' + paq + ' paquete' + (paq === 1 ? '' : 's') + (e.guia ? ' · guía ' + esc(e.guia) : '') + ' · desde ' + fmtFecha(e.fecha_solicitud) + '</div></div>' +
        '<div class="derecha"><div class="num">' + (e.flete != null ? fmtUSD(e.flete) : '<span class="tenue">flete —</span>') + '</div>' +
        (e.piezas_recibidas ? '<div class="sub">' + e.piezas_recibidas + ' piezas</div>' : '') + '</div></button>';
    }).join('') + '</div>';
  },
  pintarFaltantes(c) {
    var lista = CP.items.filter(function (i) { var cp = compraPorId(i.compra_id); return i.faltantes > 0 && cp && !cp.anulada_en; });
    if (!lista.length) { c.innerHTML = '<div class="vacio"><h3>Sin faltantes</h3>Si al recibir una caja falta algo, márcalo como faltante y aparecerá aquí para reclamarlo a SHEIN.</div>'; return; }
    c.innerHTML = '<div class="lista">' + lista.map(function (i) {
      var cp = compraPorId(i.compra_id), valor = redondear2(i.faltantes * Number(i.precio) * factorCompra(cp));
      return '<div class="item">' + imgItem(i, 'miniatura') + '<div class="crece"><div class="titulo">' + esc(descItem(i)) + '</div>' +
        '<div class="sub">Pedido #' + cp.numero + ' · faltan ' + i.faltantes + ' · valen ' + fmtUSD(valor) +
        (Number(i.reembolsado) > 0 ? ' · <span class="ok-txt">reembolsado ' + fmtUSD(i.reembolsado) + '</span>' : '') + '</div></div>' +
        '<button type="button" class="btn btn-sec btn-chico" data-reembolso="' + i.id + '">Reembolso</button></div>';
    }).join('') + '</div>';
  }
};

function filaCompraPorLlegar(cp) {
  var its = itemsDe(cp.id).filter(function (i) { return pendiente(i) > 0; });
  var paq = paquetesDe(cp.id), enCas = paq.filter(function (p) { return etapaPaquete(p) !== 'camino'; }).length;
  var piezas = its.reduce(function (s, i) { return s + pendiente(i); }, 0);
  return '<button type="button" class="item" data-compra="' + cp.id + '" style="align-items:flex-start"><div class="crece">' +
    '<div class="titulo">Pedido #' + cp.numero + (cp.pedido_ref ? ' <span class="tenue">' + esc(cp.pedido_ref) + '</span>' : '') + '</div>' +
    '<div class="sub">' + its.slice(0, 4).map(function (i) { return esc(descItem(i)) + ' ×' + pendiente(i); }).join(' · ') + (its.length > 4 ? ' · y ' + (its.length - 4) + ' más' : '') + '</div>' +
    (paq.length > 1 ? '<div class="sub">' + enCas + ' de ' + paq.length + ' paquetes ya en el casillero o más adelante</div>' : '') + '</div>' +
    '<div class="derecha"><div class="num fuerte">' + piezas + '</div><div class="sub">pieza' + (piezas === 1 ? '' : 's') + '</div></div></button>';
}

async function refrescarCompras() {
  await cargarCompras();
  if (VistaActual === VistaCompras) VistaCompras.pintar();
}

/* ---------------- Pago o reembolso (mercancía, flete) ---------------- */
// o = {titulo, texto, monto ($ sugerido), boton, enviar: async (cuenta_id, monto, tasa) }
function hojaMovimientoInversion(o) {
  return new Promise(function (resolver) {
    var listo = false;
    var cuentas = ST.cuentas.filter(function (c) { return c.activa; });
    var zelle = cuentas.find(function (c) { return /zelle/i.test(c.nombre); }) || cuentas[0];
    var h = abrirHoja({
      titulo: o.titulo, cerrarFuera: false,
      html: (o.texto ? '<p class="suave" style="margin-top:0">' + esc(o.texto) + '</p>' : '') + '<div class="pila">' +
        '<label class="campo"><span>Cuenta</span><select id="piCuenta">' + cuentas.map(function (c) {
          return '<option value="' + c.id + '"' + (c === zelle ? ' selected' : '') + '>' + esc(c.nombre) + (c.moneda === 'VES' ? ' (Bs)' : ' ($)') + '</option>';
        }).join('') + '</select></label>' +
        '<label class="campo"><span id="piEtq">Monto</span><input id="piMonto" inputmode="decimal"></label><div class="ayuda" id="piEq"></div></div>',
      pie: '<button type="button" class="btn btn-ancho" id="piOk">' + esc(o.boton || 'Guardar') + '</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    function cuenta() { return ST.cuentas.find(function (c) { return c.id === Number(h.$('#piCuenta').value); }); }
    function sugerir() {
      var c = cuenta(), t = ST.cfg.tasa_bs;
      h.$('#piEtq').textContent = 'Monto en ' + (c.moneda === 'VES' ? 'bolívares' : 'dólares');
      if (o.monto) h.$('#piMonto').value = fmtNum(c.moneda === 'VES' ? (t ? o.monto * t : '') : o.monto);
      eq();
    }
    function eq() {
      var c = cuenta(), n = parseNum(h.$('#piMonto').value);
      h.$('#piEq').textContent = c.moneda === 'VES' && !isNaN(n) && ST.cfg.tasa_bs ? '≈ ' + fmtUSD(n / ST.cfg.tasa_bs) + ' a la tasa de hoy' : '';
    }
    h.$('#piCuenta').addEventListener('change', sugerir);
    h.$('#piMonto').addEventListener('input', eq);
    sugerir();
    protegerBoton(h.$('#piOk'), async function () {
      var n = parseNum(h.$('#piMonto').value), c = cuenta();
      if (isNaN(n) || n <= 0) throw new Error('Escribe un monto válido.');
      if (c.moneda === 'VES' && !ST.cfg.tasa_bs) throw new Error('Primero pon la tasa del día.');
      await o.enviar(c.id, redondear2(n), c.moneda === 'VES' ? ST.cfg.tasa_bs : null);
      listo = true; h.cerrar(); resolver(true);
    });
  });
}

/* ---------------- Pedido: crear / editar ---------------- */
function hojaItemCompra(item, opcionesOtro) {
  return new Promise(function (resolver) {
    var it = Object.assign({ descripcion: '', talla: '', color: '', cantidad: 1, precio: '', foto: null, foto_mini: null, producto_id: null }, item || {});
    var archivo = null, listo = false;
    var h = abrirHoja({
      titulo: item ? 'Editar artículo' : 'Agregar artículo', cerrarFuera: false,
      html: '<div class="foto-editor"><div id="aiFoto">' + imgItem(it, '') + '</div><div class="pila">' +
          '<label class="btn btn-sec btn-chico" style="position:relative;overflow:hidden">' + icono('camara', 'ic-chico') + ' Foto (opcional)' +
          '<input type="file" id="aiArchivo" accept="image/*" style="position:absolute;inset:0;opacity:0"></label>' +
          '<div class="ayuda">La foto pasa a la prenda cuando la recibas.</div></div></div>' +
        '<div class="pila" style="margin-top:12px">' +
          '<label class="campo"><span>Descripción</span><input id="aiDesc" value="' + esc(it.descripcion) + '" placeholder="Ej.: Vestido midi floral"></label>' +
          '<div class="mini-campos"><label class="campo"><span>Talla</span><input id="aiTalla" value="' + esc(it.talla) + '" placeholder="M"></label>' +
            '<label class="campo"><span>Color</span><input id="aiColor" value="' + esc(it.color) + '"></label>' +
            '<label class="campo"><span>Cantidad</span><input id="aiCant" inputmode="numeric" value="' + esc(it.cantidad) + '"></label></div>' +
          '<label class="campo"><span>Precio en SHEIN por unidad ($)</span><input id="aiPrecio" inputmode="decimal" value="' + esc(it.precio === '' ? '' : fmtNum(it.precio)) + '"></label>' +
          '<div class="tarjeta" style="padding:10px 12px"><div class="fila-entre"><div class="crece"><div class="tenue">¿Es reposición de una prenda que ya tienes?</div>' +
            '<div id="aiProd">' + (it.producto_id && ST.prodPorId.get(it.producto_id) ? esc(ST.prodPorId.get(it.producto_id).nombre) : 'No, es nueva') + '</div></div>' +
            '<button type="button" class="btn btn-sec btn-chico" id="aiElegir">Elegir</button></div></div>' +
        '</div>',
      pie: '<div class="botonera">' + (opcionesOtro ? '<button type="button" class="btn btn-sec" id="aiOtro">Listo y otro</button>' : '') +
        '<button type="button" class="btn" id="aiOk">Listo</button></div>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    if (!item) setTimeout(function () { h.$('#aiDesc').focus(); }, 80);
    h.$('#aiArchivo').addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0]; if (!f) return;
      archivo = f; h.$('#aiFoto').innerHTML = '<img src="' + URL.createObjectURL(f) + '" alt="">';
    });
    h.$('#aiElegir').onclick = async function () {
      if (it.producto_id) { it.producto_id = null; h.$('#aiProd').textContent = 'No, es nueva'; h.$('#aiElegir').textContent = 'Elegir'; return; }
      var p = await buscarPrenda('¿A qué prenda se suma?');
      if (!p) return;
      it.producto_id = p.id; h.$('#aiProd').textContent = p.nombre; h.$('#aiElegir').textContent = 'Quitar';
      if (!h.$('#aiDesc').value.trim()) h.$('#aiDesc').value = p.nombre;
    };
    if (it.producto_id) h.$('#aiElegir').textContent = 'Quitar';
    async function leer() {
      var d = h.$('#aiDesc').value.trim(), cant = Number(h.$('#aiCant').value.trim()), precio = parseNum(h.$('#aiPrecio').value);
      if (!d) throw new Error('Escribe la descripción.');
      if (!Number.isInteger(cant) || cant <= 0) throw new Error('La cantidad debe ser un número entero mayor que 0.');
      if (isNaN(precio) || precio < 0) throw new Error('Revisa el precio.');
      if (archivo) { var f = await subirFoto(archivo); it.foto = f.foto; it.foto_mini = f.foto_mini; archivo = null; }
      return Object.assign(it, { descripcion: d, talla: h.$('#aiTalla').value.trim(), color: h.$('#aiColor').value.trim(), cantidad: cant, precio: redondear2(precio) });
    }
    protegerBoton(h.$('#aiOk'), async function () { var r = await leer(); listo = true; h.cerrar(); resolver({ item: r, otro: false }); }, 'Guardando…');
    var otro = h.$('#aiOtro');
    if (otro) protegerBoton(otro, async function () { var r = await leer(); listo = true; h.cerrar(); resolver({ item: r, otro: true }); }, 'Guardando…');
  });
}

async function hojaCompra(c) {
  var nueva = !c;
  var items = nueva ? [] : itemsDe(c.id).map(function (i) { return Object.assign({}, i); });
  var paquetes = nueva ? [{ tracking: '', clave: nuevaClave() }] : paquetesDe(c.id).map(function (p) { return Object.assign({}, p); });
  var clave = nuevaClave(), clavePago = nuevaClave();
  var cuentas = ST.cuentas.filter(function (x) { return x.activa; });
  var zelle = cuentas.find(function (x) { return /zelle/i.test(x.nombre); }) || cuentas[0];
  var montoTocado = false;

  var h = abrirHoja({
    titulo: nueva ? 'Nuevo pedido' : 'Editar pedido #' + c.numero, clase: 'completa ancha', cerrarFuera: false,
    html: '<div class="pila">' +
      '<div class="campos-2"><label class="campo"><span>Tienda</span><input id="cpTienda" value="' + esc(c ? c.tienda : 'SHEIN') + '"></label>' +
        '<label class="campo"><span>N.º de pedido en SHEIN</span><input id="cpRef" value="' + esc(c ? c.pedido_ref || '' : '') + '" autocapitalize="characters"></label></div>' +
      '<div class="campos-2"><label class="campo"><span>Fecha</span><input type="date" id="cpFecha" value="' + esc(c ? c.fecha : hoyCaracas()) + '"></label>' +
        '<label class="campo"><span>Total que pagaste ($)</span><input id="cpTotal" inputmode="decimal" value="' + esc(c && c.total_pagado != null ? fmtNum(c.total_pagado) : '') + '"></label></div>' +
      '<div class="ayuda" id="cpFactor">El total con impuestos y descuentos. Sirve para que el costo de cada prenda sea el real.</div></div>' +
      '<h3 style="margin:18px 0 8px">Artículos</h3><div id="cpItems"></div>' +
      '<button type="button" class="btn btn-sec btn-chico" id="cpMasItem" style="margin-top:8px">' + icono('mas', 'ic-chico') + ' Agregar artículo</button>' +
      '<h3 style="margin:18px 0 4px">Paquetes</h3><p class="ayuda" style="margin-top:0">Si SHEIN dividió el pedido, agrega un paquete por cada envío (con su número de rastreo si lo tienes).</p>' +
      '<div id="cpPaq"></div><button type="button" class="btn btn-sec btn-chico" id="cpMasPaq" style="margin-top:8px">' + icono('mas', 'ic-chico') + ' Agregar paquete</button>' +
      (nueva ? '<h3 style="margin:18px 0 8px">Pago</h3><label class="fila"><input type="checkbox" class="casilla" id="cpPagar" checked> Ya lo pagué (sale de una cuenta)</label>' +
        '<div class="campos-2" id="cpPagoCampos" style="margin-top:8px"><label class="campo"><span>Cuenta</span><select id="cpCuenta">' + cuentas.map(function (x) {
          return '<option value="' + x.id + '"' + (x === zelle ? ' selected' : '') + '>' + esc(x.nombre) + (x.moneda === 'VES' ? ' (Bs)' : ' ($)') + '</option>';
        }).join('') + '</select></label><label class="campo"><span id="cpMontoEtq">Monto</span><input id="cpMonto" inputmode="decimal"></label></div>' : '') +
      '<label class="campo" style="margin-top:14px"><span>Notas (opcional)</span><input id="cpNotas" value="' + esc(c ? c.notas || '' : '') + '"></label>',
    pie: '<button type="button" class="btn btn-ancho" id="cpOk">Guardar pedido</button>'
  });

  function vivos() { return items.filter(function (i) { return i.cantidad > 0; }); }
  function subtotal() { return redondear2(vivos().reduce(function (s, i) { return s + i.cantidad * Number(i.precio); }, 0)); }
  function pintarItems() {
    var v = vivos();
    h.$('#cpItems').innerHTML = v.length ? '<div class="tarjeta" style="padding:4px 14px">' + items.map(function (i, idx) {
      if (i.cantidad <= 0) return '';
      var bloqueado = i.recibidas > 0 || i.faltantes > 0;
      return '<div class="linea">' + imgItem(i, 'miniatura') + '<div class="crece"><div>' + esc(descItem(i)) + '</div>' +
        '<div class="sub tenue">' + i.cantidad + ' × ' + fmtUSD(i.precio) + (i.producto_id && ST.prodPorId.get(i.producto_id) ? ' · se suma a ' + esc(ST.prodPorId.get(i.producto_id).nombre) : '') +
        (bloqueado ? ' · ya recibido' : '') + '</div></div>' +
        (bloqueado ? '' : '<button type="button" class="btn btn-plano btn-icono" data-editar="' + idx + '" aria-label="Editar">' + icono('editar', 'ic-chico') + '</button>' +
          '<button type="button" class="btn btn-plano btn-icono" data-quitar="' + idx + '" aria-label="Quitar">' + icono('cerrar', 'ic-chico') + '</button>') + '</div>';
    }).join('') + '<div class="fila-entre" style="padding:10px 0"><span class="suave">' + v.reduce(function (s, i) { return s + i.cantidad; }, 0) + ' piezas · suma de precios</span><span class="num fuerte">' + fmtUSD(subtotal()) + '</span></div></div>'
      : '<div class="tenue">Agrega cada artículo del pedido (descripción, talla, cantidad y precio).</div>';
    pintarFactor();
  }
  function pintarFactor() {
    var t = parseNum(h.$('#cpTotal').value), s = subtotal();
    h.$('#cpFactor').textContent = !isNaN(t) && s > 0 && Math.abs(t - s) > 0.004
      ? 'Pagaste ' + fmtUSD(t) + ' por ' + fmtUSD(s) + ' en precios: el costo de cada prenda se ajusta ' + (t > s ? '+' : '') + fmtNum((t / s - 1) * 100).replace(/,00$/, '') + ' % (impuestos o descuentos).'
      : 'El total con impuestos y descuentos. Sirve para que el costo de cada prenda sea el real.';
    if (nueva && !montoTocado) sugerirMonto();
  }
  function cuentaPago() { return ST.cuentas.find(function (x) { return x.id === Number(h.$('#cpCuenta').value); }); }
  function sugerirMonto() {
    var cu = cuentaPago(), t = parseNum(h.$('#cpTotal').value);
    if (isNaN(t)) t = subtotal();
    h.$('#cpMontoEtq').textContent = 'Monto en ' + (cu.moneda === 'VES' ? 'bolívares' : 'dólares');
    h.$('#cpMonto').value = t > 0 ? fmtNum(cu.moneda === 'VES' ? t * (ST.cfg.tasa_bs || 0) : t) : '';
  }
  function pintarPaquetes() {
    h.$('#cpPaq').innerHTML = paquetes.map(function (p, idx) {
      if (p.quitar) return '';
      var bloqueado = !!p.envio_id;
      return '<div class="fila" style="margin-bottom:6px"><span class="tenue" style="width:74px">Paquete ' + (idx + 1) + '</span>' +
        '<input class="entrada crece" data-track="' + idx + '" value="' + esc(p.tracking || '') + '" placeholder="Rastreo (opcional)">' +
        (bloqueado ? '<span class="etq">en caja</span>' : (paquetes.filter(function (x) { return !x.quitar; }).length > 1 ? '<button type="button" class="btn btn-plano btn-icono" data-qpaq="' + idx + '" aria-label="Quitar paquete">' + icono('cerrar', 'ic-chico') + '</button>' : '')) + '</div>';
    }).join('');
  }
  async function agregarItems(base) {
    var r = await hojaItemCompra(base, !base);
    while (r) {
      if (!base) { r.item.clave = nuevaClave(); items.push(r.item); }
      pintarItems();
      if (!r.otro) break;
      r = await hojaItemCompra(null, true);
    }
    pintarItems();
  }
  h.$('#cpMasItem').onclick = function () { agregarItems(null); };
  h.$('#cpItems').addEventListener('click', async function (e) {
    var t;
    if ((t = e.target.closest('[data-editar]'))) {
      var it = items[Number(t.dataset.editar)];
      var r = await hojaItemCompra(Object.assign({}, it), false);
      if (r) { Object.assign(it, r.item); pintarItems(); }
    } else if ((t = e.target.closest('[data-quitar]'))) {
      var q = items[Number(t.dataset.quitar)];
      if (q.id) q.cantidad = 0; else items.splice(Number(t.dataset.quitar), 1);
      pintarItems();
    }
  });
  h.$('#cpMasPaq').onclick = function () { paquetes.push({ tracking: '', clave: nuevaClave() }); pintarPaquetes(); };
  h.$('#cpPaq').addEventListener('input', function (e) { var i = e.target.dataset.track; if (i != null) paquetes[Number(i)].tracking = e.target.value; });
  h.$('#cpPaq').addEventListener('click', function (e) {
    var t = e.target.closest('[data-qpaq]'); if (!t) return;
    var p = paquetes[Number(t.dataset.qpaq)];
    if (p.id) p.quitar = true; else paquetes.splice(Number(t.dataset.qpaq), 1);
    pintarPaquetes();
  });
  h.$('#cpTotal').addEventListener('input', pintarFactor);
  if (nueva) {
    h.$('#cpCuenta').addEventListener('change', function () { montoTocado = false; sugerirMonto(); });
    h.$('#cpMonto').addEventListener('input', function () { montoTocado = true; });
    h.$('#cpPagar').addEventListener('change', function (e) { h.$('#cpPagoCampos').hidden = !e.target.checked; });
  }

  protegerBoton(h.$('#cpOk'), async function () {
    if (!vivos().length) throw new Error('Agrega al menos un artículo.');
    var total = h.$('#cpTotal').value.trim() ? parseNum(h.$('#cpTotal').value) : null;
    if (total !== null && (isNaN(total) || total < 0)) throw new Error('Revisa el total que pagaste.');
    var pagar = nueva && h.$('#cpPagar').checked, montoPago = null, cuentaP = null;
    if (pagar) {
      cuentaP = cuentaPago();
      montoPago = parseNum(h.$('#cpMonto').value);
      if (isNaN(montoPago) || montoPago <= 0) throw new Error('Escribe cuánto pagaste o desmarca "Ya lo pagué".');
      if (cuentaP.moneda === 'VES' && !ST.cfg.tasa_bs) throw new Error('Primero pon la tasa del día.');
    }
    var datos = {
      id: c ? c.id : null, clave: clave, tienda: h.$('#cpTienda').value.trim(), pedido_ref: h.$('#cpRef').value.trim(),
      fecha: h.$('#cpFecha').value, total_pagado: total === null ? null : redondear2(total), notas: h.$('#cpNotas').value.trim(),
      items: items.filter(function (i) { return i.id || i.cantidad > 0; }).map(function (i) {
        return { id: i.id || null, clave: i.id ? null : i.clave, descripcion: i.descripcion, talla: i.talla, color: i.color, cantidad: i.cantidad, precio: i.precio,
          foto: i.foto || '', foto_mini: i.foto_mini || '', producto_id: i.producto_id || null };
      }),
      paquetes: paquetes.map(function (p) { return { id: p.id || null, clave: p.id ? null : p.clave, tracking: p.tracking || '', quitar: !!p.quitar }; })
    };
    var id = await rpc('jab_guardar_compra', { p: datos });
    if (pagar) {
      var argsPago = { p_compra: id, p_cuenta: cuentaP.id, p_monto: redondear2(montoPago), p_tasa: cuentaP.moneda === 'VES' ? ST.cfg.tasa_bs : null, p_clave: clavePago };
      try { await rpc('jab_pagar_compra', argsPago); }
      catch (e1) {
        // Misma clave: si el primer intento sí llegó, no se repite
        try { await rpc('jab_pagar_compra', argsPago); }
        catch (e) { toast('El pedido se guardó, pero el pago dio error: ' + errMsg(e) + ' Revisa en el pedido si el pago aparece antes de registrarlo otra vez.', 'error', 9000); }
      }
    }
    toast(nueva ? 'Pedido guardado' : 'Cambios guardados', 'ok');
    h.cerrar();
    await refrescarCompras();
    verCompra(id);
  });

  pintarItems();
  pintarPaquetes();
  if (nueva) setTimeout(function () { h.$('#cpRef').focus(); }, 80);
}

/* ---------------- Pedido: detalle ---------------- */
async function verCompra(id) {
  if (!compraPorId(id)) await cargarCompras();
  var c = compraPorId(id); if (!c) return;
  var its = itemsDe(id), paq = paquetesDe(id), pagos = pagosCompra(id), f = factorCompra(c);
  var pagado = pagadoCompraUsd(id), total = c.total_pagado != null ? Number(c.total_pagado) : subtotalCompra(id);
  var recibido = its.some(function (i) { return i.recibidas > 0 || i.faltantes > 0; });
  var h = abrirHoja({
    titulo: 'Pedido #' + c.numero, clase: 'completa ancha',
    html:
      '<div class="fila-entre" style="margin-bottom:10px">' + etiquetaCompra(c) + '<span class="tenue">' + fmtFechaLarga(c.fecha) + '</span></div>' +
      '<div class="tarjeta" style="padding:12px 14px">' +
        '<div class="fila-entre"><span class="tenue">Tienda</span><span>' + esc(c.tienda) + (c.pedido_ref ? ' · ' + esc(c.pedido_ref) : '') + '</span></div>' +
        '<div class="fila-entre"><span class="tenue">Suma de precios</span><span class="num">' + fmtUSD(subtotalCompra(id)) + '</span></div>' +
        '<div class="fila-entre"><span class="tenue">Total del pedido</span><span class="num fuerte">' + fmtUSD(total) + '</span></div>' +
        '<div class="fila-entre"><span class="tenue">Pagado</span><span class="num ' + (pagado + 0.004 < total ? 'aviso-txt' : 'ok-txt') + '">' + fmtUSD(pagado) + '</span></div>' +
        (c.notas ? '<div style="margin-top:6px"><span class="tenue">Notas:</span> ' + esc(c.notas) + '</div>' : '') +
        (c.anulada_en ? '<div class="aviso aviso-error" style="margin-top:8px">Anulado: ' + esc(c.motivo_anulacion || '') + '</div>' : '') +
      '</div>' +
      '<h3 style="margin:16px 0 6px">Artículos</h3><div class="tarjeta" style="padding:4px 14px">' + its.map(function (i) {
        var pend = pendiente(i);
        return '<div class="linea">' + imgItem(i, 'miniatura') + '<div class="crece"><div>' + esc(descItem(i)) + '</div>' +
          '<div class="sub tenue">' + i.cantidad + ' × ' + fmtUSD(i.precio) + ' (costo ajustado ' + fmtUSD(Number(i.precio) * f) + ')' +
          (i.recibidas ? ' · <span class="ok-txt">llegaron ' + i.recibidas + '</span>' : '') +
          (i.faltantes ? ' · <span class="error-txt">faltan ' + i.faltantes + '</span>' : '') +
          (pend && (i.recibidas || i.faltantes) ? ' · por llegar ' + pend : '') +
          (i.costo_real != null ? ' · costo real ' + fmtUSD(i.costo_real) : '') + '</div>' +
          (c.anulada_en ? '' : '<div class="fila" style="gap:4px;margin-top:2px">' +
            (pend ? '<button type="button" class="btn btn-plano btn-chico" data-falta="' + i.id + '" style="padding-left:0">No va a llegar</button>' : '') +
            (i.faltantes && !(Number(i.reembolsado) > 0) ? '<button type="button" class="btn btn-plano btn-chico" data-nofalta="' + i.id + '" style="padding-left:0">Quitar faltante</button>' : '') + '</div>') +
          '</div></div>';
      }).join('') + '</div>' +
      '<h3 style="margin:16px 0 6px">Paquetes</h3><div class="lista">' + paq.map(function (p, idx) {
        var et = etapaPaquete(p), e = p.envio_id ? envioPorId(p.envio_id) : null;
        var accion = c.anulada_en || p.envio_id ? '' : (p.estado === 'camino'
          ? '<button type="button" class="btn btn-sec btn-chico" data-paq="' + p.id + '" data-est="casillero">Llegó al casillero</button>'
          : '<button type="button" class="btn btn-plano btn-chico" data-paq="' + p.id + '" data-est="camino">Marcar en camino</button>');
        return '<div class="item"><div class="crece"><div>Paquete ' + (idx + 1) + (p.tracking ? ' · <span class="tenue">' + esc(p.tracking) + '</span>' : '') + '</div>' +
          '<div class="sub">' + (et === 'recibido' ? 'Recibido' : esc(NOMBRE_ETAPA[et] || et)) + (p.fecha_casillero ? ' · en casillero desde ' + fmtFecha(p.fecha_casillero) : '') +
          (e ? ' · <button type="button" class="btn btn-plano btn-chico" data-ir-envio="' + e.id + '" style="min-height:auto;padding:0">Caja #' + e.numero + '</button>' : '') + '</div></div>' + accion + '</div>';
      }).join('') + '</div>' +
      (pagos.length ? '<h3 style="margin:16px 0 6px">Pagos</h3><div class="lista">' + pagos.map(function (m) {
        var cu = ST.cuentas.find(function (x) { return x.id === m.cuenta_id; }) || {};
        return '<div class="item"><div class="crece">' + esc(cu.nombre || '') + '<div class="sub">' + fmtFechaHora(m.creado_en) + '</div></div>' +
          '<span class="num fuerte">' + fmtMonto(-m.monto, cu.moneda) + '</span></div>';
      }).join('') + '</div>' : '') +
      (c.anulada_en ? '' : '<div class="botonera" style="margin-top:18px">' +
        '<button type="button" class="btn btn-sec" data-acc="editar">' + icono('editar', 'ic-chico') + ' Editar</button>' +
        '<button type="button" class="btn btn-sec" data-acc="pagar">Registrar pago</button>' +
        (recibido ? '' : '<button type="button" class="btn btn-peligro" data-acc="anular">Anular</button>') + '</div>')
  });
  h.cuerpo.addEventListener('click', async function (e) {
    var b;
    try {
      if ((b = e.target.closest('[data-paq]'))) {
        b.disabled = true;
        await rpc('jab_paquete_estado', { p_paquete: Number(b.dataset.paq), p_estado: b.dataset.est });
        toast(b.dataset.est === 'casillero' ? 'Paquete en el casillero' : 'Paquete en camino', 'ok');
        h.cerrar(); await refrescarCompras(); verCompra(id); return;
      }
      if ((b = e.target.closest('[data-ir-envio]'))) { h.cerrar(); verEnvio(Number(b.dataset.irEnvio)); return; }
      if ((b = e.target.closest('[data-falta]')) || (b = e.target.closest('[data-nofalta]'))) {
        var quitar = b.dataset.nofalta != null, it = CP.items.find(function (x) { return x.id === Number(b.dataset.falta || b.dataset.nofalta); });
        var max = quitar ? it.faltantes : pendiente(it), n = 1;
        if (max > 1) {
          var v = await confirmar({ titulo: quitar ? 'Quitar faltante' : 'No va a llegar', mensaje: descItem(it) + (quitar ? ': ¿cuántas sí van a llegar?' : ': ¿cuántas piezas no van a llegar? Quedan como faltantes para reclamar el reembolso a SHEIN.'),
            pedir: 'Cuántas (máximo ' + max + ')', tipo: 'numero', valor: String(max), boton: 'Listo' });
          if (!v) return;
          n = Number(v);
          if (!Number.isInteger(n) || n < 1 || n > max) { toast('Escribe un número entre 1 y ' + max + '.', 'error'); return; }
        } else if (!(await confirmar({ titulo: quitar ? 'Quitar faltante' : 'No va a llegar', mensaje: descItem(it) + (quitar ? ': vuelve a quedar por llegar.' : ': queda como faltante para reclamar el reembolso a SHEIN.'), boton: 'Sí' }))) return;
        b.disabled = true;
        await rpc('jab_marcar_faltante', { p_item: it.id, p_cantidad: quitar ? -n : n, p_clave: nuevaClave() });
        toast(quitar ? 'Listo: vuelve a quedar por llegar' : 'Marcado como faltante', 'ok');
        h.cerrar(); await refrescarCompras(); verCompra(id); return;
      }
      if (!(b = e.target.closest('[data-acc]'))) return;
      if (b.dataset.acc === 'editar') { b.disabled = true; await cargarCompras(); h.cerrar(); hojaCompra(compraPorId(id)); return; }
      if (b.dataset.acc === 'pagar') {
        var clave = nuevaClave();
        var ok = await hojaMovimientoInversion({
          titulo: 'Pago del pedido #' + c.numero, texto: 'Falta pagar ' + fmtUSD(Math.max(0, total - pagado)) + '.', monto: Math.max(0, redondear2(total - pagado)), boton: 'Registrar pago',
          enviar: function (cuenta, monto, tasa) { return rpc('jab_pagar_compra', { p_compra: id, p_cuenta: cuenta, p_monto: monto, p_tasa: tasa, p_clave: clave }); }
        });
        if (ok) { toast('Pago registrado', 'ok'); h.cerrar(); await refrescarCompras(); verCompra(id); }
        return;
      }
      if (b.dataset.acc === 'anular') {
        var an = await hojaAnular({ titulo: 'Anular pedido #' + c.numero, casilla: pagos.length ? 'SHEIN me devolvió el dinero a la misma cuenta (sus pagos se anulan)' : null, marcada: true,
          ayuda: pagos.length ? 'Si no te lo devolvió, el pago queda como dinero gastado.' : '' });
        if (!an) return;
        await rpc('jab_anular_compra', { p_compra: id, p_motivo: an.motivo, p_devolver_pagos: an.casilla });
        toast('Pedido anulado', 'ok'); h.cerrar(); await refrescarCompras();
      }
    } catch (err) { toast(errMsg(err), 'error'); if (b) b.disabled = false; }
  });
}

// Motivo + (opcional) si devolvieron el dinero. Devuelve {motivo, casilla} o null.
function hojaAnular(o) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: o.titulo, cerrarFuera: false,
      html: '<div class="pila"><label class="campo"><span>Motivo</span><input id="anMotivo"></label>' +
        (o.casilla ? '<label class="fila"><input type="checkbox" id="anCasilla"' + (o.marcada ? ' checked' : '') + ' style="width:20px;height:20px;flex:none"> ' + esc(o.casilla) + '</label>' : '') +
        (o.ayuda ? '<p class="ayuda" style="margin:0">' + esc(o.ayuda) + '</p>' : '') + '</div>',
      pie: '<div class="botonera"><button type="button" class="btn btn-sec" id="anNo">Cancelar</button><button type="button" class="btn btn-peligro" id="anSi">Anular</button></div>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    setTimeout(function () { h.$('#anMotivo').focus(); }, 60);
    h.$('#anNo').onclick = function () { h.cerrar(); };
    h.$('#anSi').onclick = function () {
      var m = h.$('#anMotivo').value.trim();
      if (!m) { toast('Escribe el motivo', 'error'); h.$('#anMotivo').focus(); return; }
      listo = true; var cb = h.$('#anCasilla'); h.cerrar(); resolver({ motivo: m, casilla: cb ? cb.checked : false });
    };
  });
}

/* ---------------- Cajas (envíos) ---------------- */
async function hojaEnvio(e) {
  if (!CP.compras.length && !CP.paquetes.length) await cargarCompras();
  var nuevo = !e, clave = nuevaClave();
  var disponibles = CP.paquetes.filter(function (p) {
    var c = compraPorId(p.compra_id);
    return c && !c.anulada_en && ((p.estado === 'casillero' && !p.envio_id && piezasPendientes(c.id) > 0) || (e && p.envio_id === e.id));
  });
  if (!disponibles.length) {
    toast(nuevo ? 'No hay paquetes en el casillero. Marca primero los que ya llegaron (en cada pedido).' : 'Esta caja no tiene paquetes.', 'error', 6000);
    return;
  }
  var elegidos = new Set(e ? CP.paquetes.filter(function (p) { return p.envio_id === e.id; }).map(function (p) { return p.id; }) : disponibles.map(function (p) { return p.id; }));
  var fleteTocado = !!(e && e.flete != null && e.peso_lb == null && e.vol_lb == null);
  var h = abrirHoja({
    titulo: nuevo ? 'Armar caja (reempaque)' : 'Editar caja #' + e.numero, clase: 'completa', cerrarFuera: false,
    html: '<h3 style="margin:0 0 8px">Paquetes que van en la caja</h3><div class="lista">' + disponibles.map(function (p) {
        var c = compraPorId(p.compra_id), idx = paquetesDe(c.id).indexOf(p) + 1;
        var pz = piezasPendientes(c.id);
        return '<label class="item"><input type="checkbox" class="casilla" data-p="' + p.id + '"' + (elegidos.has(p.id) ? ' checked' : '') + '>' +
          '<div class="crece"><div>Pedido #' + c.numero + ' · paquete ' + idx + (p.tracking ? ' <span class="tenue">' + esc(p.tracking) + '</span>' : '') + '</div>' +
          '<div class="sub">' + pz + ' piezas por llegar del pedido</div></div></label>';
      }).join('') + '</div>' +
      '<div class="pila" style="margin-top:16px">' +
        (nuevo ? '' : '<label class="campo"><span>Dónde va</span><select id="evEstado">' + ESTADOS_ENVIO.slice(0, 4).map(function (s) {
          return '<option value="' + s + '"' + (e.estado === s ? ' selected' : '') + '>' + esc(NOMBRE_ENVIO[s]) + '</option>'; }).join('') + '</select></label>') +
        '<div class="campos-2"><label class="campo"><span>Courier</span><input id="evCourier" value="' + esc(e ? e.courier || '' : '') + '"></label>' +
          '<label class="campo"><span>N.º de guía</span><input id="evGuia" value="' + esc(e ? e.guia || '' : '') + '"></label></div>' +
        '<div class="mini-campos"><label class="campo"><span>Peso (lb)</span><input id="evPeso" inputmode="decimal" value="' + esc(e && e.peso_lb != null ? fmtNum(e.peso_lb) : '') + '"></label>' +
          '<label class="campo"><span>Volumétrico (lb)</span><input id="evVol" inputmode="decimal" value="' + esc(e && e.vol_lb != null ? fmtNum(e.vol_lb) : '') + '"></label>' +
          '<label class="campo"><span>$ por libra</span><input id="evTarifa" inputmode="decimal" value="' + esc(fmtNum(e ? e.tarifa : ST.cfg.tarifa_libra)) + '"></label></div>' +
        '<label class="campo"><span>Flete de la caja ($)</span><input id="evFlete" inputmode="decimal" value="' + esc(e && e.flete != null ? fmtNum(e.flete) : '') + '"></label>' +
        '<div class="ayuda" id="evAyuda">Se cobra el mayor entre el peso y el volumétrico. Si el courier cobró otro monto, escríbelo aquí.</div>' +
        '<label class="campo"><span>Notas (opcional)</span><input id="evNotas" value="' + esc(e ? e.notas || '' : '') + '"></label></div>',
    pie: '<button type="button" class="btn btn-ancho" id="evOk">' + (nuevo ? 'Pedir reempaque' : 'Guardar') + '</button>'
  });
  function calcular() {
    if (fleteTocado) return;
    var p = parseNum(h.$('#evPeso').value), v = parseNum(h.$('#evVol').value), t = parseNum(h.$('#evTarifa').value);
    var lb = Math.max(isNaN(p) ? 0 : p, isNaN(v) ? 0 : v);
    h.$('#evFlete').value = lb > 0 && !isNaN(t) ? fmtNum(redondear2(lb * t)) : '';
  }
  ['#evPeso', '#evVol', '#evTarifa'].forEach(function (s) { h.$(s).addEventListener('input', calcular); });
  h.$('#evFlete').addEventListener('input', function () { fleteTocado = true; });
  h.cuerpo.addEventListener('change', function (ev) {
    var x = ev.target.closest('[data-p]'); if (!x) return;
    if (x.checked) elegidos.add(Number(x.dataset.p)); else elegidos.delete(Number(x.dataset.p));
  });
  protegerBoton(h.$('#evOk'), async function () {
    if (!elegidos.size) throw new Error('Marca al menos un paquete.');
    function num(sel) { var t = h.$(sel).value.trim(); if (!t) return null; var n = parseNum(t); if (isNaN(n) || n < 0) throw new Error('Revisa los números de peso, tarifa y flete.'); return redondear2(n); }
    var datos = {
      id: e ? e.id : null, clave: clave, paquetes: Array.from(elegidos), courier: h.$('#evCourier').value.trim(), guia: h.$('#evGuia').value.trim(),
      peso_lb: num('#evPeso'), vol_lb: num('#evVol'), tarifa: num('#evTarifa'), flete: num('#evFlete'),
      estado: e ? h.$('#evEstado').value : 'reempaque', notas: h.$('#evNotas').value.trim()
    };
    var id = await rpc('jab_guardar_envio', { p: datos });
    toast(nuevo ? 'Caja armada: pide el reempaque al courier' : 'Caja actualizada', 'ok');
    h.cerrar(); await refrescarCompras(); verEnvio(id);
  });
}

async function verEnvio(id) {
  if (!envioPorId(id)) await cargarCompras();
  var e = envioPorId(id); if (!e) return;
  var paq = CP.paquetes.filter(function (p) { return p.envio_id === id; });
  var compras = Array.from(new Set(paq.map(function (p) { return p.compra_id; }))).map(compraPorId);
  var pagosFlete = CP.movs.filter(function (m) { return m.envio_id === id && !m.anulado_en; });
  var pagadoFlete = redondear2(pagosFlete.reduce(function (s, m) { return s - Number(m.monto_usd); }, 0));
  var activo = !e.anulado_en && e.estado !== 'recibido';
  var siguiente = activo ? ESTADOS_ENVIO[ESTADOS_ENVIO.indexOf(e.estado) + 1] : null;
  var fechas = [['Pedido el reempaque', e.fecha_solicitud], ['Salió', e.fecha_salida], ['Aduana', e.fecha_aduana], ['Llegó', e.fecha_llegada], ['Recibida', e.recibido_en]]
    .filter(function (x) { return x[1]; });
  var h = abrirHoja({
    titulo: 'Caja #' + e.numero, clase: 'completa',
    html:
      '<div class="fila-entre">' + etiquetaEnvio(e) + '<span class="tenue">' + (e.guia ? 'Guía ' + esc(e.guia) : '') + '</span></div>' +
      (e.anulado_en ? '' : barraEtapas(e.estado)) +
      '<div class="tarjeta" style="padding:12px 14px;margin-top:10px">' +
        fechas.map(function (x) { return '<div class="fila-entre"><span class="tenue">' + x[0] + '</span><span>' + fmtFecha(x[1]) + '</span></div>'; }).join('') +
        (e.courier ? '<div class="fila-entre"><span class="tenue">Courier</span><span>' + esc(e.courier) + '</span></div>' : '') +
        '<div class="fila-entre"><span class="tenue">Peso / volumétrico</span><span>' + (e.peso_lb != null ? fmtNum(e.peso_lb) : '—') + ' / ' + (e.vol_lb != null ? fmtNum(e.vol_lb) : '—') + ' lb a ' + fmtUSD(e.tarifa) + '</span></div>' +
        '<div class="fila-entre"><span class="tenue">Flete</span><span class="num fuerte">' + (e.flete != null ? fmtUSD(e.flete) : 'sin anotar') + '</span></div>' +
        '<div class="fila-entre"><span class="tenue">Flete pagado</span><span class="num ' + (e.flete != null && pagadoFlete + 0.004 < Number(e.flete) ? 'aviso-txt' : 'ok-txt') + '">' + fmtUSD(pagadoFlete) + '</span></div>' +
        (e.flete_por_pieza != null ? '<div class="fila-entre"><span class="tenue">Flete por pieza</span><span class="num">' + fmtUSD(e.flete_por_pieza) + ' (' + e.piezas_recibidas + ' piezas)</span></div>' : '') +
        (e.notas ? '<div style="margin-top:6px"><span class="tenue">Notas:</span> ' + esc(e.notas) + '</div>' : '') +
      '</div>' +
      '<h3 style="margin:16px 0 6px">Pedidos en esta caja</h3><div class="lista">' + compras.map(function (c) {
        var n = paq.filter(function (p) { return p.compra_id === c.id; }).length;
        return '<button type="button" class="item" data-ir-compra="' + c.id + '"><div class="crece"><div>Pedido #' + c.numero + (c.pedido_ref ? ' <span class="tenue">' + esc(c.pedido_ref) + '</span>' : '') + '</div>' +
          '<div class="sub">' + n + ' paquete' + (n === 1 ? '' : 's') + ' · ' + piezasPendientes(c.id) + ' piezas por recibir</div></div>' + icono('flecha', 'ic-chico') + '</button>';
      }).join('') + '</div>' +
      (activo ? '<div class="pila" style="margin-top:18px">' +
        (siguiente && siguiente !== 'recibido' ? '<button type="button" class="btn btn-ancho" data-acc="avanzar">Marcar: ' + esc(NOMBRE_ENVIO[siguiente]) + '</button>' : '') +
        '<button type="button" class="btn ' + (e.estado === 'llegada' ? '' : 'btn-sec') + ' btn-ancho" data-acc="recibir">' + icono('entregar', 'ic-chico') + ' Recibir mercancía en la tienda</button>' +
        '<div class="botonera"><button type="button" class="btn btn-sec btn-chico" data-acc="editar">' + icono('editar', 'ic-chico') + ' Editar caja y flete</button>' +
        '<button type="button" class="btn btn-sec btn-chico" data-acc="flete">Pagar flete</button>' +
        '<button type="button" class="btn btn-peligro btn-chico" data-acc="anular">Anular caja</button></div></div>'
        : (e.estado === 'recibido' && pagadoFlete + 0.004 < Number(e.flete || 0) ? '<button type="button" class="btn btn-sec" data-acc="flete" style="margin-top:16px">Pagar flete</button>' : ''))
  });
  var ocupado = false;
  h.cuerpo.addEventListener('click', async function (ev) {
    var b = ev.target.closest('[data-ir-compra]');
    if (b) { h.cerrar(); verCompra(Number(b.dataset.irCompra)); return; }
    if (!(b = ev.target.closest('[data-acc]')) || ocupado) return;
    ocupado = true;
    try {
      var acc = b.dataset.acc;
      if (acc === 'avanzar') {
        await rpc('jab_envio_estado', { p_envio: id, p_estado: siguiente });
        toast('Caja #' + e.numero + ': ' + NOMBRE_ENVIO[siguiente], 'ok');
        h.cerrar(); await refrescarCompras(); verEnvio(id);
      } else if (acc === 'editar') { await cargarCompras(); h.cerrar(); hojaEnvio(envioPorId(id)); }
      else if (acc === 'recibir') { h.cerrar(); hojaRecepcion(e); }
      else if (acc === 'flete') {
        var clave = nuevaClave();
        var falta = Math.max(0, redondear2(Number(e.flete || 0) - pagadoFlete));
        var ok = await hojaMovimientoInversion({
          titulo: 'Pago del flete · caja #' + e.numero, texto: e.flete != null ? 'Flete de ' + fmtUSD(e.flete) + ', pagado ' + fmtUSD(pagadoFlete) + '.' : '', monto: falta, boton: 'Registrar pago',
          enviar: function (cuenta, monto, tasa) { return rpc('jab_pagar_flete', { p_envio: id, p_cuenta: cuenta, p_monto: monto, p_tasa: tasa, p_clave: clave }); }
        });
        if (ok) { toast('Pago del flete registrado', 'ok'); h.cerrar(); await refrescarCompras(); verEnvio(id); }
      } else if (acc === 'anular') {
        var an = await hojaAnular({ titulo: 'Anular caja #' + e.numero, casilla: pagosFlete.length ? 'El courier me devolvió el flete (sus pagos se anulan)' : null, marcada: false,
          ayuda: 'Los paquetes vuelven al casillero.' + (pagosFlete.length ? ' Si no te devolvieron el flete, queda como dinero gastado.' : '') });
        if (an) { await rpc('jab_anular_envio', { p_envio: id, p_motivo: an.motivo, p_devolver_flete: an.casilla }); toast('Caja anulada', 'ok'); h.cerrar(); await refrescarCompras(); }
      }
    } catch (err) { toast(errMsg(err), 'error'); }
    finally { ocupado = false; }
  });
}

/* ---------------- Recepción ---------------- */
async function hojaRecepcion(e) {
  await Promise.all([cargarCompras(), cargarCatalogo()]);
  e = envioPorId(e.id);
  if (e.flete == null) { toast('Primero anota el flete de la caja (Editar caja y flete). Si no se cobró, pon 0.', 'error', 7000); verEnvio(e.id); return; }
  var compras = Array.from(new Set(CP.paquetes.filter(function (p) { return p.envio_id === e.id; }).map(function (p) { return p.compra_id; })));
  // Pedidos con paquetes que no vienen en esta caja (en otra, o sin enviar): no se asume que llegó todo
  function partido(cid) {
    return paquetesDe(cid).some(function (p) {
      if (p.envio_id === e.id) return false;
      var otra = p.envio_id ? envioPorId(p.envio_id) : null;
      return !(otra && otra.estado === 'recibido' && !otra.anulado_en);
    });
  }
  var lineas = CP.items.filter(function (i) { return compras.indexOf(i.compra_id) >= 0 && pendiente(i) > 0; }).map(function (i) {
    var prod = i.producto_id ? ST.prodPorId.get(i.producto_id) : null, parte = partido(i.compra_id);
    return { item: i, compra: compraPorId(i.compra_id), recibidas: parte ? 0 : pendiente(i), faltantes: 0, partido: parte,
      destino: prod ? { tipo: 'existente', producto: prod } : { tipo: 'nueva', nombre: i.descripcion, categoria: '', precio: '' } };
  });
  if (!lineas.length) { toast('No quedan piezas por recibir de los pedidos de esta caja.', 'error'); return; }
  var clave = nuevaClave();
  var cats = Array.from(new Set(categorias().concat(CATEGORIAS_BASE))).sort(function (a, b) { return a.localeCompare(b, 'es'); });
  var h = abrirHoja({
    titulo: 'Recibir caja #' + e.numero, clase: 'completa ancha', cerrarFuera: false,
    html: '<p class="suave" style="margin-top:0">Marca cuántas llegaron de cada artículo. Lo que no llegó puede quedar <b>por llegar</b> (vendrá en otra caja) o marcarse como <b>faltante</b> para reclamarlo.</p>' +
      '<div id="rcResumen" class="totales" style="margin-bottom:12px"></div><div id="rcLineas"></div>' +
      '<datalist id="rcCats">' + cats.map(function (c) { return '<option value="' + esc(c) + '">'; }).join('') + '</datalist>',
    pie: '<button type="button" class="btn btn-ancho" id="rcOk">Recibir y pasar al inventario</button>'
  });
  function piezas() { return lineas.reduce(function (s, l) { return s + l.recibidas; }, 0); }
  function fpp() { var p = piezas(); return p > 0 ? Number(e.flete) / p : 0; }
  function costo(l) { return Number(l.item.precio) * factorCompra(l.compra) + fpp(); }
  function pintarResumen() {
    h.$('#rcResumen').innerHTML = '<div class="fila-entre"><span>Piezas que llegaron</span><span class="num fuerte">' + piezas() + '</span></div>' +
      '<div class="fila-entre"><span>Flete de la caja</span><span class="num">' + fmtUSD(e.flete) + '</span></div>' +
      '<div class="fila-entre"><span>Flete por pieza</span><span class="num fuerte">' + fmtUSD(fpp()) + '</span></div>';
    lineas.forEach(function (l, i) {
      var el = h.$('[data-costo="' + i + '"]');
      if (el) {
        var pv = l.destino.tipo === 'nueva' ? parseNum(l.destino.precio) : Number(l.destino.producto.precio);
        el.innerHTML = 'Costo real por pieza: <b>' + fmtUSD(costo(l)) + '</b>' +
          (!isNaN(pv) && pv > 0 && l.recibidas > 0 ? ' · ganancia ' + '<b class="' + (pv - costo(l) < 0 ? 'error-txt' : 'ok-txt') + '">' + fmtUSD(pv - costo(l)) + '</b>' : '');
      }
    });
  }
  function htmlLinea(l, i) {
    var it = l.item, pend = pendiente(it);
    var dest = l.destino.tipo === 'existente'
      ? '<div class="fila-entre" style="margin-top:8px"><span>Se suma a: <b>' + esc(l.destino.producto.nombre) + '</b> <span class="tenue">(' + esc([it.talla, it.color].filter(Boolean).join(' · ') || 'Única') + ')</span></span>' +
        '<button type="button" class="btn btn-plano btn-chico" data-nueva="' + i + '">Prenda nueva</button></div>'
      : '<div class="pila" style="margin-top:8px"><div class="campos-2"><label class="campo"><span>Nombre de la prenda</span><input data-k="nombre" data-i="' + i + '" value="' + esc(l.destino.nombre) + '"></label>' +
          '<label class="campo"><span>Categoría</span><input data-k="categoria" data-i="' + i + '" list="rcCats" value="' + esc(l.destino.categoria) + '"></label></div>' +
        '<div class="fila"><label class="campo crece"><span>Precio de venta ($)</span><input data-k="precio" data-i="' + i + '" inputmode="decimal" value="' + esc(l.destino.precio) + '"></label>' +
          '<button type="button" class="btn btn-plano btn-chico" data-existente="' + i + '" style="align-self:flex-end">Ya la tengo</button></div>' +
        '<div class="ayuda">Mismo nombre en varias líneas = una sola prenda con varias tallas.</div></div>';
    return '<div class="tarjeta" style="margin-bottom:10px;padding:12px">' +
      '<div class="fila">' + imgItem(it, 'miniatura') + '<div class="crece"><div class="fuerte">' + esc(descItem(it)) + '</div>' +
        '<div class="sub tenue">Pedido #' + l.compra.numero + ' · ' + fmtUSD(it.precio) + ' c/u · por llegar ' + pend + '</div></div></div>' +
      (l.partido ? '<div class="aviso" style="margin-top:8px;font-size:.85rem">Este pedido tiene paquetes en otra caja o sin enviar: marca solo lo que vino en esta.</div>' : '') +
      '<div class="fila-entre" style="margin-top:10px"><span>Llegaron</span><div class="contador"><button type="button" data-rm="' + i + '" aria-label="Menos">−</button><span>' + l.recibidas + '</span><button type="button" data-rp="' + i + '" aria-label="Más">+</button></div></div>' +
      '<div class="fila-entre" style="margin-top:6px"><span>No vinieron y son faltantes</span><div class="contador"><button type="button" data-fm="' + i + '" aria-label="Menos">−</button><span>' + l.faltantes + '</span><button type="button" data-fp="' + i + '" aria-label="Más">+</button></div></div>' +
      (l.recibidas > 0 ? dest : '') +
      '<div class="ayuda" data-costo="' + i + '" style="margin-top:6px"></div></div>';
  }
  function pintar() { h.$('#rcLineas').innerHTML = lineas.map(htmlLinea).join(''); pintarResumen(); }
  h.$('#rcLineas').addEventListener('input', function (ev) {
    var i = ev.target.dataset.i; if (i == null) return;
    lineas[Number(i)].destino[ev.target.dataset.k] = ev.target.value;
    pintarResumen();
  });
  h.$('#rcLineas').addEventListener('click', async function (ev) {
    var t = ev.target.closest('button'); if (!t) return;
    var d = t.dataset;
    function l(k) { return lineas[Number(d[k])]; }
    if (d.rm != null) { if (l('rm').recibidas > 0) l('rm').recibidas--; }
    else if (d.rp != null) { var a = l('rp'); if (a.recibidas + a.faltantes < pendiente(a.item)) a.recibidas++; }
    else if (d.fm != null) { if (l('fm').faltantes > 0) l('fm').faltantes--; }
    else if (d.fp != null) { var b = l('fp'); if (b.recibidas + b.faltantes < pendiente(b.item)) b.faltantes++; else if (b.recibidas > 0) { b.recibidas--; b.faltantes++; } }
    else if (d.nueva != null) { l('nueva').destino = { tipo: 'nueva', nombre: l('nueva').item.descripcion, categoria: '', precio: '' }; }
    else if (d.existente != null) {
      var p = await buscarPrenda('¿A qué prenda se suma?');
      if (!p) return;
      l('existente').destino = { tipo: 'existente', producto: p };
    } else return;
    pintar();
  });
  protegerBoton(h.$('#rcOk'), async function () {
    var faltantes = lineas.reduce(function (s, l) { return s + l.faltantes; }, 0);
    if (piezas() <= 0 && faltantes <= 0) throw new Error('Marca lo que llegó (o lo que faltó).');
    // Mismo nombre de prenda nueva en varias líneas = una prenda: debe tener un solo precio
    var precios = {};
    lineas.forEach(function (l) {
      if (l.recibidas <= 0 || l.destino.tipo !== 'nueva') return;
      var k = l.destino.nombre.trim().toLowerCase(), pv = parseNum(l.destino.precio);
      if (isNaN(pv)) return;
      if (k in precios && precios[k] !== pv) throw new Error('"' + l.destino.nombre.trim() + '" tiene dos precios de venta distintos. Es una sola prenda: ponle el mismo precio.');
      precios[k] = pv;
    });
    var envio = lineas.filter(function (l) { return l.recibidas > 0 || l.faltantes > 0; }).map(function (l) {
      var x = { item_id: l.item.id, recibidas: l.recibidas, faltantes: l.faltantes };
      if (l.recibidas > 0) {
        if (l.destino.tipo === 'existente') x.producto_id = l.destino.producto.id;
        else {
          var pv = parseNum(l.destino.precio);
          if (!l.destino.nombre.trim()) throw new Error('Falta el nombre de la prenda para "' + descItem(l.item) + '".');
          if (isNaN(pv) || pv < 0) throw new Error('Falta el precio de venta de "' + l.destino.nombre + '".');
          x.nueva = { nombre: l.destino.nombre.trim(), categoria: l.destino.categoria.trim(), precio: redondear2(pv) };
        }
      }
      return x;
    });
    var faltan = lineas.reduce(function (s, l) { return s + pendiente(l.item) - l.recibidas - l.faltantes; }, 0);
    if (piezas() <= 0 && Number(e.flete) > 0 && !(await confirmar({ titulo: 'No llegó ninguna pieza', mensaje: 'El flete de ' + fmtUSD(e.flete) + ' no se reparte en ninguna prenda: queda como pérdida. ¿Seguir?', boton: 'Sí, cerrar la caja' }))) return;
    if (faltan > 0 && !(await confirmar({ titulo: 'Quedan piezas por llegar', mensaje: faltan + ' pieza' + (faltan === 1 ? '' : 's') + ' no se marcaron ni como llegadas ni como faltantes: quedan "por llegar" (en otra caja). ¿Seguir?', boton: 'Sí, recibir' }))) return;
    await rpc('jab_recibir_envio', { p: { envio_id: e.id, clave: clave, lineas: envio } });
    toast(piezas() ? 'Entraron ' + piezas() + ' piezas al inventario' : 'Caja cerrada sin piezas', 'ok');
    h.cerrar();
    await Promise.all([refrescarCompras(), cargarCatalogo()]);
    verEnvio(e.id);
  }, 'Recibiendo…');
  pintar();
}

/* ---------------- Reembolso de faltantes ---------------- */
async function hojaReembolso(itemId) {
  var it = CP.items.find(function (i) { return i.id === itemId; }); if (!it) return;
  var c = compraPorId(it.compra_id), clave = nuevaClave();
  var valor = redondear2(it.faltantes * Number(it.precio) * factorCompra(c) - Number(it.reembolsado));
  var ok = await hojaMovimientoInversion({
    titulo: 'Reembolso de SHEIN', texto: descItem(it) + ' · faltan ' + it.faltantes + ' (pedido #' + c.numero + '). ¿A qué cuenta entró el reembolso?',
    monto: Math.max(0, valor), boton: 'Registrar reembolso',
    enviar: function (cuenta, monto, tasa) { return rpc('jab_reembolso_item', { p_item: itemId, p_cuenta: cuenta, p_monto: monto, p_tasa: tasa, p_clave: clave }); }
  });
  if (ok) { toast('Reembolso registrado', 'ok'); await refrescarCompras(); }
}
