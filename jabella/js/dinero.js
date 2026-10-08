// JABELLA — dinero (solo la dueña): cuánto hay en cada cuenta, gastos, retiros y cambios de moneda.
'use strict';

var TIPOS_MOV = {
  gasto: { t: 'Registrar gasto', btn: 'Gasto', ayuda: 'Alquiler, bolsas, sueldo, servicios… sale de la cuenta que elijas.' },
  retiro: { t: 'Retiro', btn: 'Retiro', ayuda: 'Dinero que sacas para ti o para la casa.' },
  ingreso: { t: 'Ingreso extra', btn: 'Ingreso', ayuda: 'Dinero que entra y no es una venta (ej.: aporte de capital).' },
  transferencia: { t: 'Mover o cambiar dinero', btn: 'Mover / cambiar', ayuda: 'Pasar dinero de una cuenta a otra. Si cambias $ a Bs, escribe cuánto sale y cuánto llega.' },
  ajuste: { t: 'Saldo inicial o corrección', btn: 'Corregir saldo', ayuda: 'Para poner lo que ya había al empezar, o cuadrar una cuenta. Usa negativo para restar.' }
};
var CATEGORIAS_GASTO = ['Alquiler', 'Sueldo vendedora', 'Bolsas y empaques', 'Servicios', 'Publicidad', 'Transporte', 'Mercancía (SHEIN y flete)', 'Otros'];

var VistaDinero = {
  titulo: 'Dinero',
  async mostrar(cont) {
    if (!esDuena()) { cont.innerHTML = '<div class="vacio">Solo la dueña ve esta sección.</div>'; return; }
    cont.innerHTML = '<div id="dnRaiz">' +
      '<div class="encabezado"><h2>Dinero</h2></div>' +
      '<div id="dnCuentas"><div class="cargando">Cargando cuentas…</div></div>' +
      '<div class="botonera" style="margin:14px 0">' + Object.keys(TIPOS_MOV).map(function (k) {
        return '<button type="button" class="btn ' + (k === 'gasto' ? '' : 'btn-sec') + ' btn-chico" data-mov="' + k + '">' + esc(TIPOS_MOV[k].btn) + '</button>';
      }).join('') + '</div>' +
      '<h3 style="margin:18px 0 8px">Movimientos recientes</h3><div id="dnMovs"></div></div>';
    var self = this;
    $('#dnRaiz').addEventListener('click', async function (e) {
      var b = e.target.closest('[data-mov]');
      if (b) { if (await hojaMovimiento(b.dataset.mov)) self.refrescar(); return; }
      var a = e.target.closest('[data-anular-mov]');
      if (a) {
        if (!(await confirmar({ titulo: 'Anular movimiento', mensaje: 'El movimiento queda anulado y el saldo de la cuenta se corrige.', boton: 'Anular', peligro: true }))) return;
        try { await rpc('jab_anular_movimiento', { p_grupo: a.dataset.anularMov }); toast('Movimiento anulado', 'ok'); self.refrescar(); }
        catch (err) { toast(errMsg(err), 'error'); }
      }
    });
    this.refrescar();
  },
  async refrescar() {
    if (!$('#dnCuentas')) return;
    try {
      var res = await Promise.all([
        rpc('jab_saldos_cuentas'),
        sb.from('jab_movimientos_dinero').select('*').order('id', { ascending: false }).limit(80)
      ]);
      if (res[1].error) throw res[1].error;
      this.pintarCuentas(res[0]);
      this.pintarMovs(res[1].data);
    } catch (e) {
      $('#dnCuentas').innerHTML = '<div class="aviso aviso-error">No se pudo cargar: ' + esc(errMsg(e)) + '</div>';
    }
  },
  pintarCuentas(saldos) {
    var tasa = ST.cfg.tasa_bs, totalUsd = 0, faltaTasa = false;
    var html = saldos.filter(function (c) { return c.activa || Math.abs(c.saldo) > 0.004; }).map(function (c) {
      var usd = c.moneda === 'VES' ? (tasa ? c.saldo / tasa : 0) : Number(c.saldo);
      if (c.moneda === 'VES' && !tasa) faltaTasa = true;
      totalUsd += usd;
      return '<div class="kpi"><div class="t">' + esc(c.nombre) + '</div><div class="v ' + (c.saldo < -0.004 ? 'error-txt' : '') + '">' + fmtMonto(c.saldo, c.moneda) + '</div>' +
        (c.moneda === 'VES' ? '<div class="s">≈ ' + (tasa ? fmtUSD(usd) : '—') + '</div>' : '') + '</div>';
    }).join('');
    $('#dnCuentas').innerHTML =
      '<div class="tarjeta" style="margin-bottom:10px"><div class="tenue">Total en todas las cuentas</div>' +
        '<div style="font-size:1.8rem;font-weight:600" class="num">' + fmtUSD(totalUsd) + '</div>' +
        '<div class="tenue">' + (faltaTasa ? 'Falta la tasa para sumar los bolívares' : 'Bolívares convertidos a la tasa de hoy (' + fmtTasa(tasa) + ')') + '</div></div>' +
      '<div class="cuentas">' + html + '</div>' +
      '<p class="ayuda">Las ventas y abonos suman solos a la cuenta de su método de pago. Para que cuadre con la realidad, registra aquí gastos y retiros, y pon el saldo inicial de cada cuenta con "Corregir saldo".</p>';
  },
  pintarMovs(movs) {
    var c = $('#dnMovs');
    if (!movs.length) { c.innerHTML = '<div class="vacio">Todavía no hay gastos, retiros ni movimientos.</div>'; return; }
    var cuentas = new Map(ST.cuentas.map(function (x) { return [x.id, x]; }));
    var vistos = new Set();
    c.innerHTML = '<div class="lista">' + movs.map(function (m) {
      var cu = cuentas.get(m.cuenta_id) || {};
      var primero = !vistos.has(m.grupo); vistos.add(m.grupo);
      var nombreTipo = { gasto: 'Gasto', retiro: 'Retiro', ingreso: 'Ingreso', transferencia: m.monto < 0 ? 'Sale (movimiento)' : 'Entra (movimiento)', ajuste: 'Corrección' }[m.tipo];
      return '<div class="item"><div class="crece"><div class="' + (m.anulado_en ? 'tachado' : '') + '">' + esc(nombreTipo) +
        (m.categoria ? ' · ' + esc(m.categoria) : '') + '</div>' +
        '<div class="sub">' + esc(cu.nombre || '') + ' · ' + fmtFechaHora(m.creado_en) + (m.descripcion ? ' · ' + esc(m.descripcion) : '') + (m.anulado_en ? ' · anulado' : '') + '</div></div>' +
        '<div class="num ' + (m.anulado_en ? 'tachado' : m.monto < 0 ? '' : 'ok-txt') + '">' + (m.monto > 0 ? '+' : '') + fmtMonto(m.monto, cu.moneda) + '</div>' +
        (!m.anulado_en && primero ? '<button type="button" class="btn btn-plano btn-icono" data-anular-mov="' + m.grupo + '" aria-label="Anular">' + icono('basura', 'ic-chico') + '</button>' : '<span style="width:42px"></span>') +
      '</div>';
    }).join('') + '</div>';
  }
};

function hojaMovimiento(tipo) {
  return new Promise(function (resolver) {
    var t = TIPOS_MOV[tipo], listo = false, clave = nuevaClave();
    var cuentas = ST.cuentas.filter(function (c) { return c.activa; });
    var opc = cuentas.map(function (c) { return '<option value="' + c.id + '">' + esc(c.nombre) + (c.moneda === 'VES' ? ' (Bs)' : ' ($)') + '</option>'; }).join('');
    var h = abrirHoja({
      titulo: t.t,
      cerrarFuera: false,
      html: '<p class="suave" style="margin-top:0">' + esc(t.ayuda) + '</p><div class="pila">' +
        '<label class="campo"><span>' + (tipo === 'transferencia' ? 'Sale de' : 'Cuenta') + '</span><select id="mvCuenta">' + opc + '</select></label>' +
        '<label class="campo"><span id="mvMontoEtq">Monto</span><input id="mvMonto" inputmode="decimal" placeholder="0,00"></label>' +
        (tipo === 'transferencia' ?
          '<label class="campo"><span>Llega a</span><select id="mvDestino">' + opc + '</select></label>' +
          '<label class="campo" id="mvMonto2Campo"><span id="mvMonto2Etq">Monto que llega</span><input id="mvMonto2" inputmode="decimal" placeholder="0,00"></label>' : '') +
        (tipo === 'gasto' ? '<label class="campo"><span>Tipo de gasto</span><select id="mvCat">' + CATEGORIAS_GASTO.map(function (c) { return '<option>' + esc(c) + '</option>'; }).join('') + '</select></label>' : '') +
        '<label class="campo"><span>Descripción (opcional)</span><input id="mvDesc"></label>' +
        '<div class="ayuda" id="mvEquiv"></div></div>',
      pie: '<button type="button" class="btn btn-ancho" id="mvOk">Guardar</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    function cuenta(sel) { return ST.cuentas.find(function (c) { return c.id === Number(h.$(sel).value); }); }
    function actualizar() {
      var c1 = cuenta('#mvCuenta');
      h.$('#mvMontoEtq').textContent = 'Monto en ' + (c1.moneda === 'VES' ? 'bolívares' : 'dólares');
      var n = parseNum(h.$('#mvMonto').value), eq = '';
      if (!isNaN(n) && c1.moneda === 'VES' && ST.cfg.tasa_bs) eq = '≈ ' + fmtUSD(n / ST.cfg.tasa_bs) + ' a la tasa de hoy';
      if (tipo === 'transferencia') {
        var c2 = cuenta('#mvDestino');
        var mismo = c1.moneda === c2.moneda;
        h.$('#mvMonto2Campo').hidden = mismo;
        h.$('#mvMonto2Etq').textContent = 'Monto que llega en ' + (c2.moneda === 'VES' ? 'bolívares' : 'dólares');
        var n2 = parseNum(h.$('#mvMonto2').value);
        if (!mismo && !isNaN(n) && !isNaN(n2) && n > 0 && n2 > 0) {
          var tasaUsada = c1.moneda === 'USD' ? n2 / n : n / n2;
          eq = 'Tasa del cambio: ' + fmtTasa(tasaUsada) + ' Bs por $';
        }
      }
      h.$('#mvEquiv').textContent = eq;
    }
    if (tipo === 'transferencia' && cuentas.length > 1) h.$('#mvDestino').selectedIndex = 1;
    h.el.addEventListener('input', actualizar);
    h.el.addEventListener('change', actualizar);
    actualizar();
    setTimeout(function () { h.$('#mvMonto').focus(); }, 80);
    protegerBoton(h.$('#mvOk'), async function () {
      var n = parseNum(h.$('#mvMonto').value);
      if (isNaN(n) || n === 0 || (tipo !== 'ajuste' && n < 0)) throw new Error('Escribe un monto válido.');
      var c1 = cuenta('#mvCuenta');
      if (c1.moneda === 'VES' && !ST.cfg.tasa_bs) throw new Error('Primero pon la tasa del día.');
      var p = { clave: clave, tipo: tipo, cuenta_id: c1.id, monto: redondear2(n), descripcion: h.$('#mvDesc').value.trim() };
      if (tipo === 'gasto') p.categoria = h.$('#mvCat').value;
      if (tipo === 'transferencia') {
        var c2 = cuenta('#mvDestino');
        if (c2.id === c1.id) throw new Error('Elige cuentas distintas.');
        if (c2.moneda === 'VES' && !ST.cfg.tasa_bs) throw new Error('Primero pon la tasa del día.');
        p.cuenta_destino_id = c2.id;
        if (c1.moneda !== c2.moneda) {
          var n2 = parseNum(h.$('#mvMonto2').value);
          if (isNaN(n2) || n2 <= 0) throw new Error('Escribe cuánto llega a la otra cuenta.');
          p.monto_destino = redondear2(n2);
        }
      }
      await rpc('jab_registrar_movimiento', { p: p });
      toast('Guardado', 'ok');
      listo = true; h.cerrar(); resolver(true);
    });
  });
}
