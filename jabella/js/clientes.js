// JABELLA — clientas: lista, ficha, selector a pantalla completa y saldo a favor.
'use strict';

function formClienteHtml(c) {
  c = c || {};
  return '<div class="pila">' +
    '<label class="campo"><span>Nombre y apellido</span><input id="cliNombre" value="' + esc(c.nombre) + '" autocomplete="off"></label>' +
    '<div class="campos-2">' +
      '<label class="campo"><span>Teléfono</span><input id="cliTel" inputmode="tel" value="' + esc(c.telefono) + '" placeholder="0414…"></label>' +
      '<label class="campo"><span>Cédula</span><input id="cliCedula" inputmode="numeric" value="' + esc(c.cedula) + '"></label>' +
    '</div>' +
    '<label class="campo"><span>Notas</span><textarea id="cliNotas" placeholder="Talla, gustos, dirección…">' + esc(c.notas) + '</textarea></label>' +
  '</div>';
}

function leerFormCliente(h) {
  var d = {
    nombre: h.$('#cliNombre').value.trim(),
    telefono: h.$('#cliTel').value.trim() || null,
    cedula: h.$('#cliCedula').value.trim() || null,
    notas: h.$('#cliNotas').value.trim() || null
  };
  if (!d.nombre) throw new Error('Escribe el nombre de la clienta.');
  return d;
}

// Crear o editar. Devuelve Promise<cliente|null>
function editarCliente(c) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: c ? 'Editar clienta' : 'Nueva clienta',
      html: formClienteHtml(c),
      pie: '<button type="button" class="btn btn-ancho" id="cliGuardar">Guardar</button>',
      cerrarFuera: false,
      alCerrar: function () { if (!listo) resolver(null); }
    });
    if (!c) setTimeout(function () { h.$('#cliNombre').focus(); }, 60);
    protegerBoton(h.$('#cliGuardar'), async function () {
      var d = leerFormCliente(h);
      var r = c
        ? await sb.from('jab_clientes').update(d).eq('id', c.id).select().single()
        : await sb.from('jab_clientes').insert(d).select().single();
      if (r.error) throw r.error;
      await cargarClientes();
      toast(c ? 'Clienta actualizada' : 'Clienta guardada', 'ok');
      listo = true; h.cerrar(); resolver(r.data);
    });
  });
}

// Selector a pantalla completa (en iPhone los menús flotantes fallan con el teclado)
function elegirCliente() {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: 'Elegir clienta',
      clase: 'completa',
      html: '<div class="buscador">' + icono('buscar', 'ic-chico') +
              '<input class="entrada" id="selBuscar" placeholder="Nombre, teléfono o cédula" autocomplete="off"></div>' +
            '<button type="button" class="btn btn-sec btn-ancho" id="selNueva" style="margin:12px 0">' + icono('mas', 'ic-chico') + ' Nueva clienta</button>' +
            '<div id="selLista"></div>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    function pintar() {
      var q = normalizar(h.$('#selBuscar').value.trim());
      var lista = ST.clientes.filter(function (c) {
        return !q || normalizar(c.nombre).indexOf(q) >= 0 || String(c.telefono || '').indexOf(q) >= 0 || String(c.cedula || '').indexOf(q) >= 0;
      });
      var cont = h.$('#selLista');
      if (!lista.length) {
        cont.innerHTML = '<div class="vacio">' + (q ? 'No hay clientas con "' + esc(q) + '".' : 'Todavía no hay clientas.') + '</div>';
        return;
      }
      cont.innerHTML = '<div class="lista"></div>';
      dibujarPorPartes(cont, lista, function (c) {
        return '<button type="button" class="item" data-id="' + c.id + '">' +
          '<div class="miniatura sin-foto" style="width:40px;height:40px;border-radius:50%">' + esc(iniciales(c.nombre).toUpperCase()) + '</div>' +
          '<div class="crece"><div class="titulo corta">' + esc(c.nombre) + '</div><div class="sub">' + esc(c.telefono || 'Sin teléfono') + '</div></div></button>';
      }, 80, '.lista');
    }
    h.$('#selBuscar').addEventListener('input', debounce(pintar, 200));
    h.$('#selLista').addEventListener('click', function (e) {
      var b = e.target.closest('[data-id]'); if (!b) return;
      listo = true; h.cerrar(); resolver(ST.cliPorId.get(Number(b.dataset.id)));
    });
    h.$('#selNueva').onclick = async function () {
      var c = await editarCliente(null);
      if (c) { listo = true; h.cerrar(); resolver(c); }
    };
    pintar();
  });
}

/* ---------------- Vista Clientas ---------------- */
var VistaClientes = {
  titulo: 'Clientas',
  deudas: new Map(),
  aFavor: new Map(),
  async mostrar(cont) {
    cont.innerHTML =
      '<div class="encabezado"><h2>Clientas</h2>' +
        '<button type="button" class="btn btn-chico" id="cliNuevaBtn">' + icono('mas', 'ic-chico') + ' Nueva clienta</button></div>' +
      '<div class="buscador" style="margin-bottom:12px">' + icono('buscar', 'ic-chico') +
        '<input class="entrada" id="cliBuscar" placeholder="Buscar por nombre, teléfono o cédula" autocomplete="off"></div>' +
      '<div class="chips" id="cliFiltro" style="margin-bottom:12px">' +
        '<button type="button" class="chip activo" data-f="todas">Todas</button>' +
        '<button type="button" class="chip" data-f="deben">Deben</button>' +
        '<button type="button" class="chip" data-f="favor">Con saldo a favor</button></div>' +
      '<div id="cliLista"><div class="cargando">Cargando clientas…</div></div>';
    var self = this;
    this.filtro = 'todas';
    $('#cliNuevaBtn').onclick = async function () { var c = await editarCliente(null); if (c) self.pintar(); };
    $('#cliBuscar').addEventListener('input', debounce(function () { self.pintar(); }, 200));
    $('#cliFiltro').addEventListener('click', function (e) {
      var b = e.target.closest('[data-f]'); if (!b) return;
      $$('#cliFiltro .chip').forEach(function (x) { x.classList.toggle('activo', x === b); });
      self.filtro = b.dataset.f; self.pintar();
    });
    $('#cliLista').addEventListener('click', function (e) {
      var b = e.target.closest('[data-id]'); if (b) verCliente(Number(b.dataset.id));
    });
    try {
      await Promise.all([cargarClientes(), this.cargarSaldos()]);
      this.pintar();
    } catch (e) {
      $('#cliLista').innerHTML = '<div class="aviso aviso-error">No se pudieron cargar las clientas: ' + esc(errMsg(e)) + '</div>';
    }
  },
  async cargarSaldos() {
    var res = await Promise.all([
      traerTodo('jab_ventas', 'id, cliente_id, total, pagado', function (q) { return q.eq('estado', 'activa').in('tipo', ['apartado', 'fiado']); }),
      traerTodo('jab_saldo_favor_mov', 'cliente_id, monto')
    ]);
    var d = new Map(), f = new Map();
    res[0].forEach(function (v) {
      var s = redondear2(v.total - v.pagado);
      if (s > 0.004 && v.cliente_id) d.set(v.cliente_id, redondear2((d.get(v.cliente_id) || 0) + s));
    });
    res[1].forEach(function (m) { f.set(m.cliente_id, redondear2((f.get(m.cliente_id) || 0) + Number(m.monto))); });
    this.deudas = d; this.aFavor = f;
  },
  pintar() {
    var cont = $('#cliLista'); if (!cont) return;
    var q = normalizar(($('#cliBuscar') || {}).value || '');
    var self = this;
    var lista = ST.clientes.filter(function (c) {
      if (q && normalizar(c.nombre).indexOf(q) < 0 && String(c.telefono || '').indexOf(q) < 0 && String(c.cedula || '').indexOf(q) < 0) return false;
      if (self.filtro === 'deben') return (self.deudas.get(c.id) || 0) > 0;
      if (self.filtro === 'favor') return (self.aFavor.get(c.id) || 0) > 0.004;
      return true;
    });
    if (!lista.length) {
      cont.innerHTML = ST.clientes.length
        ? '<div class="vacio">Ninguna clienta coincide con la búsqueda.</div>'
        : '<div class="vacio"><h3>Aún no hay clientas</h3>Se agregan aquí o al momento de apartar o fiar.</div>';
      return;
    }
    cont.innerHTML = '<div class="lista"></div>';
    dibujarPorPartes(cont, lista, function (c) {
      var debe = self.deudas.get(c.id) || 0, fav = self.aFavor.get(c.id) || 0;
      return '<button type="button" class="item" data-id="' + c.id + '">' +
        '<div class="miniatura sin-foto" style="width:42px;height:42px;border-radius:50%">' + esc(iniciales(c.nombre).toUpperCase()) + '</div>' +
        '<div class="crece"><div class="titulo corta">' + esc(c.nombre) + '</div><div class="sub">' + esc(c.telefono || 'Sin teléfono') + '</div>' +
        (debe > 0 || fav > 0.004 ? '<div class="fila" style="gap:6px;margin-top:4px;flex-wrap:wrap">' +
          (debe > 0 ? '<span class="etq etq-aviso">Debe ' + fmtUSD(debe) + '</span>' : '') +
          (fav > 0.004 ? '<span class="etq etq-ok">A favor ' + fmtUSD(fav) + '</span>' : '') + '</div>' : '') +
      '</div></button>';
    }, 80, '.lista');
  }
};

async function verCliente(id) {
  var c = ST.cliPorId.get(id);
  if (!c || c.deleted_at) return;
  var h = abrirHoja({ titulo: c.nombre, clase: 'completa', html: '<div class="cargando">Cargando…</div>' });
  try {
    var res = await Promise.all([
      traerTodo('jab_ventas', '*', function (q) { return q.eq('cliente_id', id); }),
      traerTodo('jab_saldo_favor_mov', '*', function (q) { return q.eq('cliente_id', id); })
    ]);
    var ventas = res[0].sort(function (a, b) { return b.id - a.id; });
    var movs = res[1].sort(function (a, b) { return b.id - a.id; });
    var aFavor = redondear2(movs.reduce(function (s, m) { return s + Number(m.monto); }, 0));
    var debe = redondear2(ventas.filter(function (v) { return v.estado === 'activa' && (v.tipo === 'apartado' || v.tipo === 'fiado'); })
      .reduce(function (s, v) { return s + Math.max(0, v.total - v.pagado); }, 0));
    var compras = redondear2(ventas.filter(function (v) { return v.estado === 'activa'; }).reduce(function (s, v) { return s + Number(v.total); }, 0));

    var html =
      '<div class="tarjetas-kpi">' +
        '<div class="kpi"><div class="t">Debe</div><div class="v ' + (debe > 0 ? 'aviso-txt' : '') + '">' + fmtUSD(debe) + '</div></div>' +
        '<div class="kpi"><div class="t">Saldo a favor</div><div class="v ' + (aFavor > 0.004 ? 'ok-txt' : '') + '">' + fmtUSD(aFavor) + '</div></div>' +
        '<div class="kpi"><div class="t">Ha comprado</div><div class="v">' + fmtUSD(compras) + '</div></div>' +
      '</div>' +
      '<div class="tarjeta" style="margin-top:12px">' +
        '<div class="fila-entre"><div><div class="tenue">Teléfono</div>' + esc(c.telefono || '—') + '</div>' +
          '<div><div class="tenue">Cédula</div>' + esc(c.cedula || '—') + '</div></div>' +
        (c.notas ? '<div style="margin-top:10px"><div class="tenue">Notas</div>' + esc(c.notas) + '</div>' : '') +
        '<div class="botonera" style="margin-top:12px">' +
          (c.telefono ? '<button type="button" class="btn btn-sec btn-chico" id="cliWa">' + icono('enviar', 'ic-chico') + ' WhatsApp</button>' : '') +
          '<button type="button" class="btn btn-sec btn-chico" id="cliEditar">' + icono('editar', 'ic-chico') + ' Editar</button>' +
          (esDuena() ? '<button type="button" class="btn btn-peligro btn-chico" id="cliBorrar">' + icono('basura', 'ic-chico') + ' Borrar</button>' : '') +
        '</div>' +
      '</div>' +
      '<h3 style="margin:18px 0 8px">Compras</h3>' +
      (ventas.length ? '<div class="lista">' + ventas.map(filaVentaHtml).join('') + '</div>' : '<div class="vacio">Sin compras registradas.</div>') +
      (movs.length ? '<h3 style="margin:18px 0 8px">Movimientos de saldo a favor</h3><div class="lista">' + movs.map(function (m) {
        return '<div class="item"><div class="crece"><div>' + esc(m.motivo) + '</div><div class="sub">' + fmtFechaHora(m.creado_en) + '</div></div>' +
          '<span class="num ' + (m.monto > 0 ? 'ok-txt' : '') + '">' + (m.monto > 0 ? '+' : '') + fmtUSD(m.monto) + '</span></div>';
      }).join('') + '</div>' : '');
    h.cuerpo.innerHTML = html;

    var wa = h.$('#cliWa');
    if (wa) wa.onclick = function () { compartirTexto('Hola ' + c.nombre.split(' ')[0] + ', te escribimos de JABELLA Store.', c.telefono); };
    h.$('#cliEditar').onclick = async function () {
      var n = await editarCliente(c);
      if (n) { h.cerrar(); verCliente(id); if (VistaActual === VistaClientes) VistaClientes.pintar(); }
    };
    var br = h.$('#cliBorrar');
    if (br) br.onclick = async function () {
      if (debe > 0 || aFavor > 0.004) { toast('No se puede borrar: tiene deuda o saldo a favor.', 'error'); return; }
      if (!(await confirmar({ titulo: 'Borrar clienta', mensaje: 'Se ocultará "' + c.nombre + '". Sus compras quedan registradas.', boton: 'Borrar', peligro: true }))) return;
      var r = await sb.from('jab_clientes').update({ deleted_at: new Date().toISOString() }).eq('id', id);
      if (r.error) { toast(errMsg(r.error), 'error'); return; }
      await cargarClientes();
      toast('Clienta borrada', 'ok');
      h.cerrar();
      if (VistaActual === VistaClientes) VistaClientes.pintar();
    };
    h.cuerpo.addEventListener('click', function (e) {
      var b = e.target.closest('[data-venta]'); if (b) verVenta(Number(b.dataset.venta));
    });
  } catch (e) {
    h.cuerpo.innerHTML = '<div class="aviso aviso-error">' + esc(errMsg(e)) + '</div>';
  }
}
