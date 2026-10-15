// JABELLA — editor de pagos: uno o varios métodos, en $ o en Bs a la tasa del día.
// Lo usan el cobro de una venta, los abonos y la diferencia de un cambio.
'use strict';

// o = { total: número en $ (lo máximo a cobrar), minimo: $ (opcional, apartado),
//       cliente: function () -> id | null, saldoFavor: function () -> $ disponible,
//       vacio: true si se permite no cobrar nada (fiado), alCambiar: function () }
function editorPagos(cont, o) {
  var filas = [];
  var tasaInicial = tasaVigente();

  function metodosDisponibles() {
    var cli = o.cliente ? o.cliente() : null;
    var sf = o.saldoFavor ? o.saldoFavor() : 0;
    return ST.metodos.filter(function (m) {
      if (!m.activo) return false;
      if (m.es_saldo_favor) return !!cli && sf > 0.004;
      var c = cuentaDe(m);
      return c && c.activa;
    });
  }
  function tasa() { return tasaVigente(); }
  function metodo(id) { return ST.metodos.find(function (m) { return m.id === Number(id); }); }

  function usdFila(f) {
    var m = metodo(f.metodo_id);
    if (!m) return 0;
    var n = parseNum(f.texto);
    if (isNaN(n) || n <= 0) return 0;
    if (monedaMetodo(m) === 'VES') {
      if (!tasa()) return 0;
      if (f.usdAuto != null && f.texto === f.textoAuto) return f.usdAuto;
      return redondear2(n / tasa());
    }
    return redondear2(n);
  }
  function cobrado() { return redondear2(filas.reduce(function (s, f) { return s + usdFila(f); }, 0)); }
  function faltaSin(fila) {
    return redondear2(o.total - filas.reduce(function (s, f) { return f === fila ? s : s + usdFila(f); }, 0));
  }

  // Cuánto se precarga: el total, o el mínimo en un apartado, o nada en un fiado
  function objetivo() { return o.objetivo == null ? o.total : o.objetivo; }

  function autollenar(f) {
    var m = metodo(f.metodo_id);
    var falta = redondear2(faltaSin(f) - (o.total - objetivo()));
    if (m && m.es_saldo_favor) falta = Math.min(falta, o.saldoFavor ? o.saldoFavor() : 0);
    if (!m || falta <= 0) { f.texto = ''; f.usdAuto = null; f.textoAuto = null; return; }
    if (monedaMetodo(m) === 'VES') {
      if (!tasa()) { f.texto = ''; return; }
      f.texto = fmtNum(redondear2(falta * tasa()));
      f.usdAuto = redondear2(falta);
      f.textoAuto = f.texto;
    } else {
      f.texto = fmtNum(falta);
      f.usdAuto = null; f.textoAuto = null;
    }
  }

  function agregar() {
    var ms = metodosDisponibles();
    if (!ms.length) return;
    var usados = filas.map(function (f) { return Number(f.metodo_id); });
    var m = ms.find(function (x) { return usados.indexOf(x.id) < 0 && !x.es_saldo_favor; }) || ms[0];
    var f = { metodo_id: m.id, texto: '', referencia: '' };
    filas.push(f);
    autollenar(f);
    pintar();
    var inp = cont.querySelector('.pago:last-of-type input[data-monto]');
    if (inp && filas.length > 1) inp.focus();
  }

  function pideReferencia(m) { return m && !m.es_saldo_favor && !/efectivo/i.test(m.nombre); }

  function htmlFila(f, i) {
    var m = metodo(f.metodo_id);
    var mon = m ? monedaMetodo(m) : 'USD';
    var opciones = metodosDisponibles().map(function (x) {
      var ves = monedaMetodo(x) === 'VES';
      var sinTasa = ves && !tasa();
      return '<option value="' + x.id + '"' + (x.id === Number(f.metodo_id) ? ' selected' : '') + (sinTasa ? ' disabled' : '') + '>' +
        esc(x.nombre) + (ves ? ' (Bs)' : '') + (sinTasa ? ' — falta la tasa de hoy' : '') + '</option>';
    }).join('');
    var usd = usdFila(f), n = parseNum(f.texto), equiv = '';
    if (mon === 'VES' && usd > 0) equiv = '= ' + fmtBs(n) + ' ≈ ' + fmtUSD(usd) + ' a ' + fmtTasa(tasa());
    else if (mon === 'USD' && usd > 0 && tasa()) equiv = '= ' + fmtUSD(usd) + ' (≈ ' + fmtBs(usd * tasa()) + ')';
    if (m && m.es_saldo_favor) equiv = 'Disponible: ' + fmtUSD(o.saldoFavor ? o.saldoFavor() : 0);
    return '<div class="pago" data-i="' + i + '">' +
      '<div class="fila">' +
        '<select class="entrada crece" data-metodo aria-label="Método de pago">' + opciones + '</select>' +
        '<input class="entrada num" data-monto inputmode="decimal" style="width:40%" placeholder="' + (mon === 'VES' ? 'Bs' : '$') + '" value="' + esc(f.texto) + '" aria-label="Monto">' +
        (filas.length > 1 ? '<button type="button" class="btn btn-plano btn-icono" data-quitar aria-label="Quitar pago">' + icono('cerrar', 'ic-chico') + '</button>' : '') +
      '</div>' +
      '<div class="equiv" data-equiv>' + esc(equiv) + '</div>' +
      (pideReferencia(m) ? '<input class="entrada" data-ref style="margin-top:6px" placeholder="Referencia (opcional)" value="' + esc(f.referencia) + '">' : '') +
      (m && !m.es_saldo_favor ? htmlFoto(f) : '') +
    '</div>';
  }

  // Foto del pago (opcional): se sube apenas se toma, así al cobrar ya está lista
  function htmlFoto(f) {
    if (f.subiendo) return '<div class="pago-foto tenue">' + icono('foto', 'ic-chico') + ' Subiendo foto…</div>';
    if (f.comprobante) return '<div class="pago-foto">' + (f.vista ? '<img src="' + esc(f.vista) + '" alt="">' : '') +
      '<span class="ok-txt crece">' + icono('check', 'ic-chico') + ' Foto del pago lista</span>' +
      '<button type="button" class="btn btn-plano btn-chico" data-sin-foto>Quitar</button></div>';
    return '<button type="button" class="btn btn-plano btn-chico pago-foto-btn" data-foto>' + icono('camara', 'ic-chico') + ' Foto del pago</button>';
  }
  async function tomarFoto(f) {
    var file = await elegirFoto();
    if (!file) return;
    f.subiendo = true; pintar();
    try {
      var ruta = await subirComprobante(file);
      if (f.vista) URL.revokeObjectURL(f.vista);
      f.comprobante = ruta; f.vista = URL.createObjectURL(file);
    } catch (e) { toast('No se pudo subir la foto: ' + errMsg(e), 'error'); }
    finally { f.subiendo = false; if (filas.indexOf(f) >= 0) pintar(); }
  }

  function htmlResumen() {
    var c = cobrado(), falta = redondear2(o.total - c);
    var h = '<div class="totales" style="margin-top:10px">';
    h += '<div class="fila-entre"><span>A cobrar</span><span class="num fuerte">' + fmtUSD(o.total) + '</span></div>';
    if (tasa()) h += '<div class="fila-entre tenue"><span>En bolívares</span><span class="num">' + fmtBs(o.total * tasa()) + '</span></div>';
    if (o.minimo) h += '<div class="fila-entre tenue"><span>Mínimo para apartar</span><span class="num">' + fmtUSD(o.minimo) + '</span></div>';
    h += '<div class="fila-entre"><span>Cobrado</span><span class="num">' + fmtUSD(c) + '</span></div>';
    if (falta > 0.004) h += '<div class="fila-entre aviso-txt"><span>Falta</span><span class="num fuerte">' + fmtUSD(falta) + '</span></div>';
    else if (falta < -0.004) h += '<div class="fila-entre error-txt"><span>Te pasaste por</span><span class="num fuerte">' + fmtUSD(-falta) + '</span></div>';
    else h += '<div class="fila-entre ok-txt"><span>Completo</span>' + icono('check', 'ic-chico') + '</div>';
    return h + '</div>';
  }

  function pintar() {
    var avisoTasa = tasa() ? '' : '<div class="aviso" style="margin-bottom:8px">' + (ST.cfg.tasa_bs
      ? 'La tasa no se ha confirmado hoy. Para cobrar en bolívares toca "Tasa" arriba y guárdala.'
      : 'Para cobrar en bolívares primero pon la tasa del día (toca "Tasa" arriba).') + '</div>';
    cont.innerHTML = avisoTasa + filas.map(htmlFila).join('') +
      '<button type="button" class="btn btn-plano" data-agregar style="margin-top:6px">' + icono('mas', 'ic-chico') + ' Otro método</button>' +
      '<div data-resumen>' + htmlResumen() + '</div>';
    if (o.alCambiar) o.alCambiar();
  }
  function repintarResumen(div, f) {
    var r = cont.querySelector('[data-resumen]');
    if (r) r.innerHTML = htmlResumen();
    if (div && f) {
      var tmp = document.createElement('div');
      tmp.innerHTML = htmlFila(f, filas.indexOf(f));
      div.querySelector('[data-equiv]').textContent = tmp.querySelector('[data-equiv]').textContent;
    }
    if (o.alCambiar) o.alCambiar();
  }

  cont.addEventListener('change', function (e) {
    var div = e.target.closest('.pago'); if (!div) return;
    var f = filas[Number(div.dataset.i)];
    if (e.target.matches('[data-metodo]')) { f.metodo_id = Number(e.target.value); autollenar(f); pintar(); }
  });
  cont.addEventListener('input', function (e) {
    var div = e.target.closest('.pago'); if (!div) return;
    var f = filas[Number(div.dataset.i)];
    if (e.target.matches('[data-monto]')) { f.texto = e.target.value; repintarResumen(div, f); }
    if (e.target.matches('[data-ref]')) f.referencia = e.target.value;
  });
  cont.addEventListener('click', function (e) {
    if (e.target.closest('[data-agregar]')) { agregar(); return; }
    var fb = e.target.closest('[data-foto]'), sf = e.target.closest('[data-sin-foto]');
    if (fb || sf) {
      var fila = filas[Number(e.target.closest('.pago').dataset.i)];
      if (fb) tomarFoto(fila);
      else { fila.comprobante = null; if (fila.vista) URL.revokeObjectURL(fila.vista); fila.vista = null; pintar(); }
      return;
    }
    var q = e.target.closest('[data-quitar]');
    if (q) { filas.splice(Number(q.closest('.pago').dataset.i), 1); pintar(); }
  });

  agregar();

  return {
    cobrado: cobrado,
    // objetivo: cuánto precargar (null = todo el total)
    setTotal: function (t, minimo, objetivoNuevo) {
      o.total = redondear2(t); o.minimo = minimo; o.objetivo = objetivoNuevo;
      if (filas.length === 1) autollenar(filas[0]);
      pintar();
    },
    refrescar: function () { filas.forEach(function (f) { if (f.texto === f.textoAuto) autollenar(f); }); pintar(); },
    // Si la tasa cambió desde que se abrió el cobro, recalcula y avisa (devuelve true)
    tasaCambio: function () {
      if (tasaVigente() === tasaInicial) return false;
      tasaInicial = tasaVigente();
      filas.forEach(function (f) { if (f.texto === f.textoAuto) autollenar(f); });
      pintar();
      return true;
    },
    // Lista para enviar a la base (descarta filas vacías)
    pagos: function () {
      if (filas.some(function (f) { return f.subiendo; })) throw new Error('Espera a que termine de subir la foto del pago.');
      var lista = [];
      filas.forEach(function (f) {
        var usd = usdFila(f);
        if (usd <= 0) return;
        var m = metodo(f.metodo_id);
        var p = { metodo_id: m.id, monto_usd: usd, referencia: (f.referencia || '').trim() };
        if (f.comprobante && !m.es_saldo_favor) p.comprobante = f.comprobante;
        if (monedaMetodo(m) === 'VES' && !m.es_saldo_favor) { p.monto = redondear2(parseNum(f.texto)); p.tasa = tasa(); }
        lista.push(p);
      });
      return lista;
    },
    // Filas con texto que no se entiende como número
    errores: function () {
      return filas.some(function (f) { return f.texto.trim() && (isNaN(parseNum(f.texto)) || parseNum(f.texto) < 0); });
    },
    resumenTexto: function () {
      return this.pagos().map(function (p) {
        var m = metodo(p.metodo_id);
        return m.nombre + ': ' + (p.monto ? fmtBs(p.monto) : fmtUSD(p.monto_usd));
      }).join(', ');
    }
  };
}

// Saldo a favor de una clienta (suma de sus movimientos)
async function saldoFavorCliente(id) {
  if (!id) return 0;
  var movs = await traerTodo('jab_saldo_favor_mov', 'id, monto', function (q) { return q.eq('cliente_id', id); });
  return redondear2(movs.reduce(function (s, x) { return s + Number(x.monto); }, 0));
}
