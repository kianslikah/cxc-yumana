// JABELLA — vender: catálogo con fotos, carrito y cobro (contado, apartado o fiado).
'use strict';

var Carrito = { items: [] }; // {variante_id, cantidad, precio (null = precio de lista)}

function enCarrito(varId) {
  return Carrito.items.filter(function (i) { return i.variante_id === varId; }).reduce(function (s, i) { return s + i.cantidad; }, 0);
}
function precioItem(i) {
  if (i.precio != null) return i.precio;
  var v = ST.varPorId.get(i.variante_id), p = v && ST.prodPorId.get(v.producto_id);
  return p ? Number(p.precio) : 0;
}
function totalCarrito() { return redondear2(Carrito.items.reduce(function (s, i) { return s + i.cantidad * precioItem(i); }, 0)); }
function prendasCarrito() { return Carrito.items.reduce(function (s, i) { return s + i.cantidad; }, 0); }

// Ventana de una prenda: elegir talla/color y cantidad.
// opts = {boton, cualquiera (permite tallas sin existencia, para devoluciones), precioEditable}
function elegirVariante(p, opts) {
  opts = opts || {};
  return new Promise(function (resolver) {
    var vars = variantesActivas(p.id);
    var disp = function (v) { return opts.cualquiera ? 99 : v.stock - (opts.sinCarrito ? 0 : enCarrito(v.id)); };
    var elegida = vars.filter(function (v) { return disp(v) > 0; }).length === 1 ? vars.find(function (v) { return disp(v) > 0; }) : null;
    var cant = 1, listo = false;
    var precioEdit = opts.precioEditable != null ? opts.precioEditable : esDuena();
    var h = abrirHoja({
      titulo: p.nombre,
      html:
        imgProducto(p, 'foto-grande', true) +
        '<div class="fila-entre" style="margin:14px 0 6px"><div><div class="tenue">' + esc(p.codigo || '') + ' · ' + esc(p.categoria) + '</div>' +
          '<div style="font-size:1.4rem;font-weight:600" class="num">' + fmtUSD(p.precio) + '</div></div>' +
          (ST.cfg.tasa_bs ? '<div class="tenue derecha">' + fmtBs(p.precio * ST.cfg.tasa_bs) + '</div>' : '') + '</div>' +
        (p.notas ? '<p class="suave" style="margin:4px 0 10px">' + esc(p.notas) + '</p>' : '') +
        '<div class="tenue" style="margin:10px 0 6px">Talla y color</div>' +
        '<div class="variantes" id="evVars">' + (vars.length ? vars.map(function (v) {
          var d = disp(v);
          return '<button type="button" class="variante" data-v="' + v.id + '"' + (d <= 0 ? ' disabled' : '') + '>' + esc(descVariante(v)) +
            (opts.cualquiera ? '' : '<small>' + (d > 0 ? d + ' disp.' : 'agotada') + '</small>') + '</button>';
        }).join('') : '<span class="suave">Esta prenda no tiene tallas cargadas.</span>') + '</div>' +
        '<div class="fila-entre" style="margin-top:16px"><span>Cantidad</span>' +
          '<div class="contador"><button type="button" id="evMenos" aria-label="Menos">−</button><span id="evCant">1</span><button type="button" id="evMas" aria-label="Más">+</button></div></div>' +
        (precioEdit ? '<label class="campo" style="margin-top:14px"><span>Precio por unidad ($)</span><input id="evPrecio" inputmode="decimal" value="' + esc(fmtNum(p.precio)) + '"></label>' : ''),
      pie: '<button type="button" class="btn btn-ancho" id="evOk">' + esc(opts.boton || 'Agregar') + '</button>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    function marcar() {
      $$('.variante', h.el).forEach(function (b) { b.classList.toggle('activo', elegida && Number(b.dataset.v) === elegida.id); });
      if (elegida && cant > disp(elegida)) cant = Math.max(1, disp(elegida));
      h.$('#evCant').textContent = cant;
      h.$('#evOk').disabled = !elegida;
    }
    h.$('#evVars').addEventListener('click', function (e) {
      var b = e.target.closest('[data-v]'); if (!b || b.disabled) return;
      elegida = ST.varPorId.get(Number(b.dataset.v)); marcar();
    });
    h.$('#evMenos').onclick = function () { if (cant > 1) { cant--; marcar(); } };
    h.$('#evMas').onclick = function () {
      if (!elegida) { toast('Primero elige la talla'); return; }
      if (cant < disp(elegida)) { cant++; marcar(); } else toast('No hay más de esa talla');
    };
    h.$('#evOk').onclick = function () {
      if (!elegida) return;
      var precio = null;
      if (precioEdit) {
        var n = parseNum(h.$('#evPrecio').value);
        if (isNaN(n) || n < 0) { toast('Revisa el precio', 'error'); return; }
        n = redondear2(n);
        if (n !== Number(p.precio)) precio = n;
      }
      listo = true; h.cerrar();
      resolver({ variante_id: elegida.id, cantidad: cant, precio: precio });
    };
    marcar();
  });
}

var VistaVender = {
  titulo: 'Vender',
  cat: 'Todas',
  mostrar(cont) {
    cont.innerHTML =
      '<div class="buscador" style="margin-bottom:10px">' + icono('buscar', 'ic-chico') +
        '<input class="entrada" id="venBuscar" placeholder="Buscar prenda o código" autocomplete="off"></div>' +
      '<div class="chips" id="venCats" style="margin-bottom:14px"></div>' +
      '<div id="venRejilla"></div>' +
      '<div id="venBarra"></div>';
    var self = this;
    $('#venBuscar').addEventListener('input', debounce(function () { self.pintarRejilla(); }, 220));
    $('#venCats').addEventListener('click', function (e) {
      var b = e.target.closest('[data-cat]'); if (!b) return;
      self.cat = b.dataset.cat; self.pintarCats(); self.pintarRejilla();
    });
    $('#venRejilla').addEventListener('click', async function (e) {
      var b = e.target.closest('[data-p]'); if (!b) return;
      var p = ST.prodPorId.get(Number(b.dataset.p));
      var sel = await elegirVariante(p, { boton: 'Agregar a la venta' });
      if (!sel) return;
      var igual = Carrito.items.find(function (i) { return i.variante_id === sel.variante_id && i.precio === sel.precio; });
      if (igual) igual.cantidad += sel.cantidad; else Carrito.items.push(sel);
      toast('Agregada: ' + p.nombre, 'ok', 1500);
      self.pintarRejilla(); self.pintarBarra();
    });
    this.pintarCats(); this.pintarRejilla(); this.pintarBarra();
  },
  refrescar() { if ($('#venRejilla')) { this.pintarCats(); this.pintarRejilla(); this.pintarBarra(); } },
  pintarCats() {
    var cats = ['Todas'].concat(categorias());
    if (cats.indexOf(this.cat) < 0) this.cat = 'Todas';
    var self = this;
    $('#venCats').innerHTML = cats.length > 2 ? cats.map(function (c) {
      return '<button type="button" class="chip' + (c === self.cat ? ' activo' : '') + '" data-cat="' + esc(c) + '">' + esc(c) + '</button>';
    }).join('') : '';
  },
  pintarRejilla() {
    var cont = $('#venRejilla'); if (!cont) return;
    var q = normalizar($('#venBuscar').value.trim()), cat = this.cat;
    var lista = ST.productos.filter(function (p) {
      if (!p.activo) return false;
      if (cat !== 'Todas' && p.categoria !== cat) return false;
      return !q || normalizar(p.nombre).indexOf(q) >= 0 || normalizar(p.codigo).indexOf(q) >= 0;
    });
    lista.sort(function (a, b) { return (stockProducto(b.id) > 0) - (stockProducto(a.id) > 0) || b.id - a.id; });
    if (!lista.length) {
      cont.innerHTML = ST.productos.length
        ? '<div class="vacio">No hay prendas que coincidan.</div>'
        : '<div class="vacio"><h3>Todavía no hay prendas</h3>' + (esDuena() ? 'Carga el inventario en la pestaña Inventario para empezar a vender.' : 'La dueña debe cargar el inventario primero.') + '</div>';
      return;
    }
    cont.innerHTML = '<div class="rejilla"></div>';
    dibujarPorPartes(cont, lista, function (p) {
      var s = stockProducto(p.id) - variantesActivas(p.id).reduce(function (t, v) { return t + enCarrito(v.id); }, 0);
      return '<button type="button" class="prenda' + (s <= 0 ? ' agotada' : '') + '" data-p="' + p.id + '">' +
        imgProducto(p, 'foto') +
        '<div class="info"><div class="nombre">' + esc(p.nombre) + '</div>' +
        '<div class="precio num">' + fmtUSD(p.precio) + '</div>' +
        '<div class="disp">' + (s > 0 ? s + ' disponible' + (s === 1 ? '' : 's') : 'Agotada') + '</div></div></button>';
    }, 60, '.rejilla');
  },
  pintarBarra() {
    var cont = $('#venBarra'); if (!cont) return;
    if (!Carrito.items.length) { cont.innerHTML = ''; return; }
    var n = prendasCarrito();
    cont.innerHTML = '<button type="button" class="carrito-barra" id="venCobrar">' +
      '<div class="crece"><div style="font-size:.85rem;opacity:.8">' + n + ' prenda' + (n === 1 ? '' : 's') + '</div>' +
      '<div class="num" style="font-size:1.15rem;font-weight:600">' + fmtUSD(totalCarrito()) + '</div></div>' +
      '<span class="btn">Cobrar ' + icono('flecha', 'ic-chico') + '</span></button>';
    $('#venCobrar').onclick = function () { hojaCobro(); };
  }
};

function hojaCobro() {
  var estado = { tipo: 'contado', cliente: null, saldoFavor: 0 };
  var clave = nuevaClave(); // la misma en cada reintento de este cobro
  var puedeFiar = esDuena() || ST.cfg.vendedora_fia;
  var h = abrirHoja({
    titulo: 'Cobrar',
    clase: 'completa',
    cerrarFuera: false,
    html:
      '<div id="cbItems"></div>' +
      '<div class="seg" id="cbTipo" style="margin:14px 0">' +
        '<button type="button" data-t="contado" class="activo">Contado</button>' +
        '<button type="button" data-t="apartado">Apartado</button>' +
        (puedeFiar ? '<button type="button" data-t="fiado">Fiado</button>' : '') +
      '</div>' +
      '<div id="cbAyuda" class="tenue" style="margin:-6px 0 12px"></div>' +
      '<div class="tarjeta" style="padding:12px 14px;margin-bottom:12px"><div class="fila-entre">' +
        '<div class="crece"><div class="tenue">Clienta</div><div id="cbCliente" class="corta">Sin clienta</div></div>' +
        '<button type="button" class="btn btn-sec btn-chico" id="cbElegir">Elegir</button></div></div>' +
      '<h3 style="margin:4px 0 8px">Pago</h3>' +
      '<div id="cbPagos"></div>' +
      '<label class="campo" style="margin-top:12px"><span>Nota (opcional)</span><input id="cbNota" placeholder="Ej.: se lo lleva para regalo"></label>',
    pie: '<button type="button" class="btn btn-ancho" id="cbOk">Cobrar</button>'
  });

  var editor;
  function minimo() { return redondear2(totalCarrito() * Number(ST.cfg.abono_minimo_pct) / 100); }
  function actualizarTotales() {
    var t = totalCarrito();
    if (estado.tipo === 'contado') editor.setTotal(t, null, null);
    if (estado.tipo === 'apartado') editor.setTotal(t, minimo(), minimo());
    if (estado.tipo === 'fiado') editor.setTotal(t, null, 0);
    var ayuda = {
      contado: '',
      apartado: 'La prenda queda reservada ' + ST.cfg.dias_apartado + ' días. Abono mínimo: ' + Number(ST.cfg.abono_minimo_pct) + '%.',
      fiado: 'Se lleva la prenda y queda debiendo. Puede dejar un abono ahora.'
    }[estado.tipo];
    h.$('#cbAyuda').textContent = ayuda;
    h.$('#cbOk').textContent = { contado: 'Cobrar ' + fmtUSD(t), apartado: 'Apartar', fiado: 'Dejar fiado' }[estado.tipo];
  }
  function pintarItems() {
    if (!Carrito.items.length) { h.cerrar(); VistaVender.refrescar(); return; }
    h.$('#cbItems').innerHTML = Carrito.items.map(function (i, idx) {
      var v = ST.varPorId.get(i.variante_id), p = ST.prodPorId.get(v.producto_id);
      return '<div class="linea">' + imgProducto(p, 'miniatura') +
        '<div class="crece"><div class="corta">' + esc(p.nombre) + '</div>' +
        '<div class="sub tenue">' + esc(descVariante(v)) + ' · ' + fmtUSD(precioItem(i)) + (i.precio != null ? ' <span class="etq etq-lila">precio especial</span>' : '') + '</div></div>' +
        '<div class="contador"><button type="button" data-menos="' + idx + '" aria-label="Menos">−</button><span>' + i.cantidad + '</span>' +
        '<button type="button" data-mas="' + idx + '" aria-label="Más">+</button></div></div>';
    }).join('') +
    '<div class="fila-entre" style="margin-top:10px"><span class="suave">Total</span><span class="num fuerte" style="font-size:1.2rem">' + fmtUSD(totalCarrito()) + '</span></div>';
  }
  h.$('#cbItems').addEventListener('click', function (e) {
    var m = e.target.closest('[data-menos]'), p = e.target.closest('[data-mas]');
    if (m) {
      var i = Carrito.items[Number(m.dataset.menos)];
      i.cantidad--; if (i.cantidad <= 0) Carrito.items.splice(Number(m.dataset.menos), 1);
    } else if (p) {
      var it = Carrito.items[Number(p.dataset.mas)], v = ST.varPorId.get(it.variante_id);
      if (enCarrito(v.id) >= v.stock) { toast('No hay más de esa talla'); return; }
      it.cantidad++;
    } else return;
    pintarItems(); if (Carrito.items.length) actualizarTotales();
    VistaVender.refrescar();
  });
  h.$('#cbTipo').addEventListener('click', function (e) {
    var b = e.target.closest('[data-t]'); if (!b) return;
    estado.tipo = b.dataset.t;
    $$('#cbTipo button', h.el).forEach(function (x) { x.classList.toggle('activo', x === b); });
    actualizarTotales();
  });
  h.$('#cbElegir').onclick = async function () {
    var c = await elegirCliente();
    if (!c) return;
    estado.cliente = c;
    h.$('#cbCliente').textContent = c.nombre;
    h.$('#cbElegir').textContent = 'Cambiar';
    try { estado.saldoFavor = await saldoFavorCliente(c.id); } catch (e) { estado.saldoFavor = 0; }
    if (estado.saldoFavor > 0.004) toast(c.nombre + ' tiene ' + fmtUSD(estado.saldoFavor) + ' a favor', 'ok');
    editor.refrescar();
  };

  pintarItems();
  editor = editorPagos(h.$('#cbPagos'), {
    total: totalCarrito(),
    cliente: function () { return estado.cliente && estado.cliente.id; },
    saldoFavor: function () { return estado.saldoFavor; }
  });
  actualizarTotales();

  protegerBoton(h.$('#cbOk'), async function () {
    var total = totalCarrito();
    if (!Carrito.items.length) throw new Error('No hay prendas en la venta.');
    if (editor.errores()) throw new Error('Revisa los montos del pago: hay uno que no es un número.');
    if (estado.tipo !== 'contado' && !estado.cliente) throw new Error('Elige la clienta para el ' + estado.tipo + '.');
    await cargarConfig();
    if (editor.tasaCambio()) throw new Error('La tasa cambió. Revisa el cobro y vuelve a tocar el botón.');
    var cobrado = editor.cobrado();
    if (cobrado > total + 0.004) throw new Error('Lo cobrado es mayor que el total.');
    if (estado.tipo === 'contado' && Math.abs(cobrado - total) > 0.004) throw new Error('Falta cobrar ' + fmtUSD(total - cobrado) + '.');
    if (estado.tipo === 'apartado' && cobrado + 0.004 < minimo() && !esDuena()) throw new Error('El abono mínimo es ' + fmtUSD(minimo()) + '.');

    var id = await rpc('jab_registrar_venta', { p: {
      clave: clave,
      tipo: estado.tipo,
      cliente_id: estado.cliente ? estado.cliente.id : null,
      nota: h.$('#cbNota').value.trim(),
      items: Carrito.items.map(function (i) {
        var x = { variante_id: i.variante_id, cantidad: i.cantidad };
        if (i.precio != null) x.precio = i.precio;
        return x;
      }),
      pagos: editor.pagos()
    } });
    Carrito.items = [];
    h.cerrar();
    toast({ contado: 'Venta registrada', apartado: 'Apartado registrado', fiado: 'Fiado registrado' }[estado.tipo], 'ok');
    await cargarCatalogo();
    VistaVender.refrescar();
    verVenta(id, { recien: true });
  }, 'Registrando…');
}
