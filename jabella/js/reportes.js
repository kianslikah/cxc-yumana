// JABELLA — reportes (solo la dueña): ganancia del período, ventas por día, lo más vendido,
// lo que no se mueve y cierres de caja. El cierre lo hace cualquiera (la vendedora cuenta sin ver lo esperado).
'use strict';

var VistaReportes = {
  titulo: 'Reportes',
  pestana: 'ganancia',
  periodo: 'mes',
  desde: null, hasta: null,
  diasSinMov: 30,
  async mostrar(cont) {
    if (!esDuena()) { cont.innerHTML = '<div class="vacio">Solo la dueña ve esta sección.</div>'; return; }
    cont.innerHTML = '<div id="rpRaiz">' +
      '<div class="encabezado"><h2>Reportes</h2></div>' +
      '<div class="seg" id="rpPestanas" style="margin-bottom:14px">' +
        '<button type="button" data-p="ganancia">Ganancias</button><button type="button" data-p="quietas">Sin movimiento</button>' +
        '<button type="button" data-p="cierres">Cierres de caja</button></div>' +
      '<div id="rpCuerpo"></div></div>';
    var self = this;
    $('#rpRaiz').addEventListener('click', function (e) {
      var b;
      if ((b = e.target.closest('[data-p]'))) { self.pestana = b.dataset.p; self.pintar(); return; }
      if ((b = e.target.closest('[data-per]'))) { self.periodo = b.dataset.per; self.pintar(); return; }
      if ((b = e.target.closest('[data-dias]'))) { self.diasSinMov = Number(b.dataset.dias); self.pintar(); return; }
      if ((b = e.target.closest('[data-cierre]'))) { verCierre(Number(b.dataset.cierre)); }
    });
    $('#rpRaiz').addEventListener('change', function (e) {
      if (e.target.id === 'rpDesde' || e.target.id === 'rpHasta') {
        self.desde = $('#rpDesde').value; self.hasta = $('#rpHasta').value;
        if (self.desde && self.hasta) self.pintar();
      }
    });
    this.pintar();
  },
  refrescar() { if ($('#rpRaiz') && !$('#rpRaiz').contains(document.activeElement)) this.pintar(); },
  rango() {
    var hoy = hoyCaracas(), y = Number(hoy.slice(0, 4)), m = Number(hoy.slice(5, 7));
    var pad = function (n) { return String(n).padStart(2, '0'); };
    if (this.periodo === 'hoy') return [hoy, hoy];
    if (this.periodo === '7') return [sumarDias(hoy, -6), hoy];
    if (this.periodo === 'mes') return [y + '-' + pad(m) + '-01', hoy];
    if (this.periodo === 'pasado') {
      var py = m === 1 ? y - 1 : y, pm = m === 1 ? 12 : m - 1;
      return [py + '-' + pad(pm) + '-01', sumarDias(y + '-' + pad(m) + '-01', -1)];
    }
    var d = this.desde || sumarDias(hoy, -29), h = this.hasta || hoy;
    if (h > hoy) h = hoy;
    if (d > h) { var x = d; d = h; h = x; }
    if (diasEntre(d, h) > 400) d = sumarDias(h, -400);
    return [d, h];
  },
  pintar() {
    var self = this;
    $$('#rpPestanas button').forEach(function (b) { b.classList.toggle('activo', b.dataset.p === self.pestana); });
    var c = $('#rpCuerpo');
    c.innerHTML = '<div class="cargando">Calculando…</div>';
    var f = { ganancia: this.pintarGanancia, quietas: this.pintarQuietas, cierres: this.pintarCierres }[this.pestana];
    f.call(this, c).catch(function (e) { c.innerHTML = '<div class="aviso aviso-error">No se pudo cargar: ' + esc(errMsg(e)) + '</div>'; });
  },
  async pintarGanancia(c) {
    var r = this.rango(), self = this;
    var chips = [['hoy', 'Hoy'], ['7', '7 días'], ['mes', 'Este mes'], ['pasado', 'Mes pasado'], ['otro', 'Elegir fechas']];
    c.innerHTML =
      '<div class="chips" style="margin-bottom:10px">' + chips.map(function (x) {
        return '<button type="button" class="chip' + (self.periodo === x[0] ? ' activo' : '') + '" data-per="' + x[0] + '">' + x[1] + '</button>';
      }).join('') + '</div>' +
      (this.periodo === 'otro' ? '<div class="campos-2" style="margin-bottom:10px"><label class="campo"><span>Desde</span><input type="date" id="rpDesde" value="' + r[0] + '" max="' + hoyCaracas() + '"></label>' +
        '<label class="campo"><span>Hasta</span><input type="date" id="rpHasta" value="' + r[1] + '" max="' + hoyCaracas() + '"></label></div>' : '') +
      '<div class="tenue" style="margin-bottom:8px">' + (r[0] === r[1] ? fmtFechaLarga(r[0]) : 'Del ' + fmtFecha(r[0]) + ' al ' + fmtFecha(r[1])) + '</div>' +
      '<div id="rpDatos"><div class="cargando">Calculando…</div></div>';
    var cont = $('#rpDatos'), d;
    try { d = await rpc('jab_reporte', { p_desde: r[0], p_hasta: r[1] }); }
    catch (e) { cont.innerHTML = '<div class="aviso aviso-error">No se pudo cargar: ' + esc(errMsg(e)) + '</div>'; return; }
    if (!cont.isConnected) return;
    var bruta = redondear2(Number(d.ventas_con_costo) - Number(d.costo));
    var descuadres = Number(d.descuadres || 0);
    var neta = redondear2(bruta - Number(d.gastos) + Number(d.abonos_retenidos) + descuadres);
    var margen = Number(d.ventas_con_costo) > 0 ? Math.round(bruta / Number(d.ventas_con_costo) * 100) : 0;
    cont.innerHTML =
      '<div class="tarjeta" style="margin-bottom:10px"><div class="tenue">Ganancia neta</div>' +
        '<div class="num ' + (neta < 0 ? 'error-txt' : '') + '" style="font-size:2rem;font-weight:600">' + fmtUSD(neta) + '</div>' +
        '<div class="tenue">Ganancia de las ventas ' + fmtUSD(bruta) + ' − gastos del local ' + fmtUSD(d.gastos) +
          (Number(d.abonos_retenidos) > 0 ? ' + abonos que se quedó la tienda ' + fmtUSD(d.abonos_retenidos) : '') +
          (Math.abs(descuadres) >= 0.005 ? (descuadres < 0 ? ' − faltantes de caja ' : ' + sobrantes de caja ') + fmtUSD(Math.abs(descuadres)) : '') + '</div></div>' +
      '<div class="tarjetas-kpi">' +
        '<div class="kpi"><div class="t">Vendido</div><div class="v">' + fmtUSD(d.ventas) + '</div><div class="s">' + d.ventas_n + ' ventas · ' + d.prendas + ' prendas</div></div>' +
        '<div class="kpi"><div class="t">Ganancia de las ventas</div><div class="v">' + fmtUSD(bruta) + '</div><div class="s">' + margen + ' % de lo vendido</div></div>' +
        '<div class="kpi"><div class="t">Gastos del local</div><div class="v">' + fmtUSD(d.gastos) + '</div><div class="s">sin mercancía ni flete</div></div>' +
        '<div class="kpi"><div class="t">Invertido en mercancía</div><div class="v">' + fmtUSD(d.invertido) + '</div><div class="s">pedidos y flete, menos reembolsos</div></div>' +
        '<div class="kpi"><div class="t">Entró en dinero</div><div class="v">' + fmtUSD(d.cobrado) + '</div><div class="s">ventas y abonos</div></div>' +
        '<div class="kpi"><div class="t">Por cobrar hoy</div><div class="v">' + fmtUSD(d.por_cobrar) + '</div><div class="s">fiados y apartados</div></div>' +
      '</div>' +
      (Number(d.piezas_sin_costo) > 0 ? '<div class="aviso" style="margin-top:10px">' + d.piezas_sin_costo + ' pieza' + (d.piezas_sin_costo == 1 ? '' : 's') +
        ' vendida' + (d.piezas_sin_costo == 1 ? '' : 's') + ' no tenían costo cargado (' + fmtUSD(d.ventas_sin_costo) + ' en ventas): su ganancia no se cuenta. Carga el costo en Inventario → filtro "Sin costo".</div>' : '') +
      '<h3 style="margin:18px 0 8px">Ventas por ' + (d.por_dia.length > 45 ? 'semana' : 'día') + '</h3><div class="tarjeta" style="padding:12px" id="rpGrafico"></div>' +
      (d.gastos_por_categoria.length ? '<h3 style="margin:18px 0 8px">Gastos del local</h3><div class="lista">' + d.gastos_por_categoria.map(function (g) {
        return '<div class="item"><div class="crece">' + esc(g.categoria) + '</div><span class="num">' + fmtUSD(g.total) + '</span></div>';
      }).join('') + '</div>' : '') +
      '<h3 style="margin:18px 0 8px">Lo más vendido</h3>' +
      (d.top.length ? '<div class="tarjeta" style="padding:4px 12px"><table class="tabla"><thead><tr><th>Prenda</th><th class="derecha">Unid.</th><th class="derecha">Vendido</th><th class="derecha">Ganancia</th></tr></thead><tbody>' +
        d.top.map(function (t) {
          return '<tr><td>' + esc(t.nombre) + '</td><td class="derecha num">' + t.unidades + '</td><td class="derecha num">' + fmtUSD(t.ventas) + '</td>' +
            '<td class="derecha num">' + (t.ganancia == null ? '<span class="tenue">sin costo</span>' : fmtUSD(t.ganancia)) + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '<div class="vacio">Sin ventas en este período.</div>') +
      (d.por_vendedora.length > 1 ? '<h3 style="margin:18px 0 8px">Por quien vendió</h3><div class="lista">' + d.por_vendedora.map(function (v) {
        return '<div class="item"><div class="crece">' + esc(v.nombre) + '<div class="sub">' + v.ventas_n + ' ventas</div></div><span class="num">' + fmtUSD(v.total) + '</span></div>';
      }).join('') + '</div>' : '');
    graficoVentas($('#rpGrafico'), agruparSemanas(d.por_dia), Number(d.piezas_sin_costo) > 0);
  },
  async pintarQuietas(c) {
    var self = this;
    var lista = await rpc('jab_sin_movimiento', { p_dias: this.diasSinMov });
    var valor = lista.reduce(function (s, p) { return s + Number(p.stock) * Number(p.costo || 0); }, 0);
    c.innerHTML = '<div class="chips" style="margin-bottom:10px">' + [30, 60, 90].map(function (n) {
        return '<button type="button" class="chip' + (self.diasSinMov === n ? ' activo' : '') + '" data-dias="' + n + '">' + n + '+ días</button>';
      }).join('') + '</div>' +
      '<p class="suave" style="margin-top:0">Prendas con existencia que no se venden desde hace ' + this.diasSinMov + ' días o más. Buenas candidatas para una oferta.</p>' +
      (lista.length ? '<div class="tarjetas-kpi" style="margin-bottom:10px"><div class="kpi"><div class="t">Prendas</div><div class="v">' + lista.length + '</div></div>' +
        '<div class="kpi"><div class="t">Dinero parado (a costo)</div><div class="v">' + fmtUSD(valor) + '</div></div></div>' +
        '<div class="lista">' + lista.map(function (p) {
          var pr = ST.prodPorId.get(p.producto_id);
          return '<div class="item">' + (pr ? imgProducto(pr, 'miniatura') : '') + '<div class="crece"><div class="titulo corta">' + esc(p.nombre) + '</div>' +
            '<div class="sub">' + esc(p.codigo) + ' · ' + p.stock + ' en tienda · ' + (p.ultima_venta ? 'última venta ' + fmtFecha(p.ultima_venta) : 'nunca se ha vendido') + '</div></div>' +
            '<div class="derecha"><div class="num fuerte">' + p.dias + ' días</div><div class="sub">' + fmtUSD(p.precio) + '</div></div></div>';
        }).join('') + '</div>'
        : '<div class="vacio"><h3>Todo se está moviendo</h3>No hay prendas con existencia sin ventas en ese plazo.</div>');
  },
  async pintarCierres(c) {
    var lista = await traerTodo('jab_cierres', '*', null, 'id');
    lista.reverse();
    c.innerHTML = '<p class="suave" style="margin-top:0">Al final del día, la vendedora (o tú) toca <b>Cerrar caja</b> en Ventas y cuenta el efectivo sin ver cuánto debería haber. Aquí ves la diferencia.</p>' +
      (lista.length ? '<div class="lista" id="rpCierres"></div>' : '<div class="vacio"><h3>Todavía no hay cierres</h3>Se hacen desde Ventas → Por día → Cerrar caja.</div>');
    if (lista.length) dibujarPorPartes($('#rpCierres'), lista, filaCierreHtml, 60);
  }
};

function cierreCuadra(ci) { return ci.detalle.every(function (d) { return Math.abs(Number(d.diferencia)) < 0.005; }); }
function etiquetaCierre(ci) {
  var dif = Number(ci.diferencia_usd);
  if (cierreCuadra(ci)) return '<span class="etq etq-ok">Cuadra</span>';
  if (Math.abs(dif) < 0.005) return '<span class="etq etq-aviso">Descuadre entre cuentas</span>';
  return '<span class="etq ' + (dif < 0 ? 'etq-error' : 'etq-aviso') + '">' + (dif < 0 ? 'Falta ' : 'Sobra ') + fmtUSD(Math.abs(dif)) + '</span>';
}
function filaCierreHtml(ci) {
  var u = ST.usrPorId.get(ci.usuario_id);
  return '<button type="button" class="item" data-cierre="' + ci.id + '"><div class="crece"><div class="titulo">Cierre #' + ci.numero + ' · ' + fmtFecha(ci.fecha) + '</div>' +
    '<div class="sub">' + esc(u ? u.nombre : '—') + ' · ' + fmtHora(ci.creado_en) + (ci.revisado_en ? ' · revisado' : '') + '</div></div>' + etiquetaCierre(ci) + '</button>';
}

// Más de 45 días: se agrupa por semana para que las barras se lean
function agruparSemanas(dias) {
  if (dias.length <= 45) return dias.map(function (d) { return { etq: d.dia, ventas: Number(d.ventas), ganancia: Number(d.ganancia), semana: false }; });
  var out = [];
  for (var i = 0; i < dias.length; i += 7) {
    var g = dias.slice(i, i + 7);
    out.push({ etq: g[0].dia, ventas: g.reduce(function (s, d) { return s + Number(d.ventas); }, 0),
      ganancia: g.reduce(function (s, d) { return s + Number(d.ganancia); }, 0), semana: true });
  }
  return out;
}

// Barras apiladas: abajo la ganancia (color fuerte), arriba el resto de lo vendido (lo que costó).
// Los colores salen de --graf-ganancia/--graf-costo, que cambian con el modo noche.
function graficoVentas(cont, datos, haySinCosto) {
  if (!datos.some(function (d) { return d.ventas > 0; })) { cont.innerHTML = '<div class="vacio" style="padding:18px">Sin ventas en este período.</div>'; return; }
  var W = Math.max(260, cont.clientWidth - 24), H = 210, mI = 46, mD = 6, mA = 10, mB = 24;
  var ancho = W - mI - mD, alto = H - mA - mB;
  var max = Math.max.apply(null, datos.map(function (d) { return d.ventas; }));
  var paso = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000].find(function (p) { return max / p <= 4; }) || 10000;
  var tope = Math.ceil(max / paso) * paso, y = function (v) { return mA + alto - v / tope * alto; };
  var n = datos.length, slot = ancho / n, bw = Math.max(2, Math.min(28, slot - 2));
  var cadaEtq = Math.max(1, Math.ceil(n / Math.max(1, Math.floor(ancho / 30))));
  var svg = '<svg class="rp-svg" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="Ventas y ganancia por ' + (datos[0].semana ? 'semana' : 'día') + '">';
  for (var v = 0; v <= tope + 0.001; v += paso) {
    svg += '<line x1="' + mI + '" x2="' + (W - mD) + '" y1="' + y(v) + '" y2="' + y(v) + '" style="stroke:var(--borde)" stroke-width="1"/>' +
      '<text x="' + (mI - 6) + '" y="' + (y(v) + 4) + '" text-anchor="end" font-size="11" style="fill:var(--texto-3)">$' + (v >= 1000 ? (v / 1000) + 'k' : v) + '</text>';
  }
  datos.forEach(function (d, i) {
    var x = mI + i * slot + (slot - bw) / 2, g = Math.max(0, Math.min(d.ganancia, d.ventas)), r = Math.min(4, bw / 2);
    var yTop = y(d.ventas), yG = y(g), base = y(0);
    if (d.ventas > 0) {
      // segmento de arriba (costo) con la punta redondeada; 2px de separación con la ganancia
      var hC = Math.max(0, yG - yTop - (g > 0 ? 2 : 0));
      if (hC > 0) {
        var rr = Math.min(r, hC);
        svg += '<path d="M' + x + ',' + (yTop + hC) + ' V' + (yTop + rr) + ' Q' + x + ',' + yTop + ' ' + (x + rr) + ',' + yTop + ' H' + (x + bw - rr) +
          ' Q' + (x + bw) + ',' + yTop + ' ' + (x + bw) + ',' + (yTop + rr) + ' V' + (yTop + hC) + ' Z" style="fill:var(--graf-costo)"/>';
      }
      if (g > 0) svg += '<rect x="' + x + '" y="' + yG + '" width="' + bw + '" height="' + Math.max(1, base - yG) + '" style="fill:var(--graf-ganancia)"' + (hC > 0 ? '' : ' rx="' + r + '"') + '/>';
    }
    // zona de toque: toda la columna, más ancha que la barra
    svg += '<rect class="rp-zona" data-i="' + i + '" x="' + (mI + i * slot) + '" y="' + mA + '" width="' + slot + '" height="' + alto + '" fill="transparent"/>';
    if (i % cadaEtq === 0) svg += '<text x="' + (x + bw / 2) + '" y="' + (H - 6) + '" text-anchor="middle" font-size="11" style="fill:var(--texto-3)">' + Number(d.etq.slice(8, 10)) + '</text>';
  });
  svg += '</svg>';
  cont.innerHTML =
    '<div class="rp-leyenda"><span><span class="muestra" style="background:var(--graf-ganancia)"></span>Ganancia</span>' +
      '<span><span class="muestra" style="background:var(--graf-costo)"></span>' + (haySinCosto ? 'Costo (y prendas sin costo)' : 'Costo de lo vendido') + '</span>' +
      '<span class="tenue">Barra completa = lo vendido. Toca una barra para ver el detalle.</span></div>' +
    '<div style="position:relative">' + svg + '<div class="rp-tip"></div></div>' +
    '<details style="margin-top:8px"><summary class="tenue" style="cursor:pointer">Ver como tabla</summary>' +
      '<table class="tabla" style="margin-top:6px"><thead><tr><th>' + (datos[0].semana ? 'Semana del' : 'Día') + '</th><th class="derecha">Vendido</th><th class="derecha">Ganancia</th></tr></thead><tbody>' +
      datos.filter(function (d) { return d.ventas !== 0 || d.ganancia !== 0; }).map(function (d) {
        return '<tr><td>' + fmtFecha(d.etq) + '</td><td class="derecha num">' + fmtUSD(d.ventas) + '</td><td class="derecha num">' + fmtUSD(d.ganancia) + '</td></tr>';
      }).join('') + '</tbody></table></details>';
  var tip = cont.querySelector('.rp-tip');
  function mostrar(ev) {
    var z = ev.target.closest && ev.target.closest('.rp-zona'); if (!z) { tip.style.display = 'none'; return; }
    var d = datos[Number(z.dataset.i)];
    tip.innerHTML = (d.semana ? 'Semana del ' : '') + fmtFecha(d.etq) + '<br>Vendido ' + fmtUSD(d.ventas) + '<br>Ganancia ' + fmtUSD(d.ganancia);
    tip.style.display = 'block';
    var cx = Number(z.getAttribute('x')) + Number(z.getAttribute('width')) / 2;
    tip.style.left = Math.min(Math.max(0, cx - tip.offsetWidth / 2), W - tip.offsetWidth) + 'px';
  }
  var svgEl = cont.querySelector('svg');
  svgEl.addEventListener('mousemove', mostrar);
  svgEl.addEventListener('click', mostrar);
  svgEl.addEventListener('mouseleave', function () { tip.style.display = 'none'; });
}

/* ---------------- Cierre de caja ---------------- */
var _cierreAbierto = false;
async function hojaCierre() {
  if (_cierreAbierto) return;
  _cierreAbierto = true;
  try { await cargarMetodos(); } catch (e) { _cierreAbierto = false; toast(errMsg(e), 'error'); return; }
  var cuentas = ST.cuentas.filter(function (c) { return c.activa && c.cuenta_en_cierre; });
  if (!cuentas.length) { _cierreAbierto = false; toast('No hay cuentas de efectivo marcadas para el cierre (Ajustes → Cuentas de dinero).', 'error', 6000); return; }
  var clave = nuevaClave();
  var h = abrirHoja({
    titulo: 'Cerrar caja', cerrarFuera: false, alCerrar: function () { _cierreAbierto = false; },
    html: '<p class="suave" style="margin-top:0">Cuenta el dinero que hay ahora y escríbelo. No hace falta saber cuánto debería haber: el sistema lo compara y la dueña ve el resultado.</p>' +
      '<div class="pila">' + cuentas.map(function (c) {
        return '<label class="campo"><span>¿Cuánto hay en ' + esc(c.nombre) + '? (' + (c.moneda === 'VES' ? 'Bs' : '$') + ')</span><input data-cuenta="' + c.id + '" inputmode="decimal" placeholder="0,00"></label>';
      }).join('') +
      '<label class="campo"><span>Nota (opcional)</span><input id="ciNota" placeholder="Ej.: saqué $5 para el delivery"></label></div>',
    pie: '<button type="button" class="btn btn-ancho" id="ciOk">Enviar cierre</button>'
  });
  setTimeout(function () { var i = h.$('[data-cuenta]'); if (i) i.focus(); }, 80);
  protegerBoton(h.$('#ciOk'), async function () {
    var conteos = $$('[data-cuenta]', h.el).map(function (inp) {
      var n = parseNum(inp.value);
      if (isNaN(n) || n < 0) throw new Error('Escribe cuánto hay en cada cuenta (0 si no hay nada).');
      return { cuenta_id: Number(inp.dataset.cuenta), contado: redondear2(n) };
    });
    var id = await rpc('jab_registrar_cierre', { p: { clave: clave, nota: h.$('#ciNota').value.trim(), conteos: conteos } });
    h.cerrar();
    toast('Cierre enviado. ¡Buen trabajo!', 'ok');
    if (esDuena()) verCierre(id);
  }, 'Enviando…');
}

async function verCierre(id) {
  var r = await sb.from('jab_cierres').select('*').eq('id', id).single();
  if (r.error || !r.data) { toast(r.error ? errMsg(r.error) : 'No se encontró el cierre.', 'error'); return; }
  var ci = r.data, u = ST.usrPorId.get(ci.usuario_id), dif = Number(ci.diferencia_usd), cuadra = cierreCuadra(ci);
  var h = abrirHoja({
    titulo: 'Cierre #' + ci.numero,
    html: '<div class="tenue" style="margin-bottom:10px">' + fmtFechaLarga(ci.fecha) + ' · ' + fmtHora(ci.creado_en) + ' · ' + esc(u ? u.nombre : '—') + '</div>' +
      '<div class="tarjeta" style="padding:4px 12px"><table class="tabla"><thead><tr><th>Cuenta</th><th class="derecha">Debía haber</th><th class="derecha">Contado</th><th class="derecha">Diferencia</th></tr></thead><tbody>' +
      ci.detalle.map(function (d) {
        var df = Number(d.diferencia);
        return '<tr><td>' + esc(d.nombre) + '</td><td class="derecha num">' + fmtMonto(d.esperado, d.moneda) + '</td><td class="derecha num">' + fmtMonto(d.contado, d.moneda) + '</td>' +
          '<td class="derecha num ' + (Math.abs(df) < 0.005 ? 'ok-txt' : df < 0 ? 'error-txt' : 'aviso-txt') + '">' + (df > 0 ? '+' : '') + fmtMonto(df, d.moneda) + '</td></tr>';
      }).join('') + '</tbody></table></div>' +
      '<div class="totales" style="margin-top:10px"><div class="fila-entre"><span>Diferencia total</span><span class="num grande ' + (cuadra ? 'ok-txt' : dif < 0 ? 'error-txt' : 'aviso-txt') + '">' +
        (cuadra ? 'Cuadra' : (dif > 0 ? '+' : '') + fmtUSD(dif)) + '</span></div>' +
        (!cuadra && Math.abs(dif) < 0.005 ? '<div class="ayuda">En dólares se compensa, pero cada cuenta tiene diferencia (¿un cobro en $ anotado como Bs?).</div>' : '') + '</div>' +
      (ci.nota ? '<p><span class="tenue">Nota:</span> ' + esc(ci.nota) + '</p>' : '') +
      (ci.revisado_en ? '<div class="aviso aviso-ok" style="margin-top:12px">Revisado ' + fmtFechaHora(ci.revisado_en) +
          (ci.nota_revision ? ': ' + esc(ci.nota_revision) + '.' : ci.ajustado ? ': el saldo se cuadró con lo contado' +
            (ci.ajuste && ci.ajuste.length ? ' (' + ci.ajuste.map(function (a) { return esc(a.nombre) + ' ' + (Number(a.monto) > 0 ? '+' : '') + fmtMonto(a.monto, a.moneda); }).join(', ') + ')' : '') + '.' : ' sin ajustar el saldo.') + '</div>'
        : (cuadra ? '<div class="botonera" style="margin-top:14px"><button type="button" class="btn" data-rev="no">Marcar revisado</button></div>'
          : '<p class="ayuda" style="margin-top:14px">Usa solo una de las dos: si ya sabes la causa (un gasto sin anotar), anótalo en Dinero y toca <b>Revisado sin ajustar</b>. Si la diferencia es real (se perdió o sobró dinero), toca <b>Cuadrar con lo contado</b>. Si hay cierres más nuevos, cuadra el último: el saldo es acumulado y ya incluye esta diferencia.</p>' +
            '<div class="botonera"><button type="button" class="btn" data-rev="si">Cuadrar con lo contado</button><button type="button" class="btn btn-sec" data-rev="no">Revisado sin ajustar</button></div>'))
  });
  h.cuerpo.addEventListener('click', async function (e) {
    var b = e.target.closest('[data-rev]'); if (!b || b.disabled) return;
    $$('[data-rev]', h.el).forEach(function (x) { x.disabled = true; });
    try {
      await rpc('jab_revisar_cierre', { p_cierre: id, p_ajustar: b.dataset.rev === 'si' });
      toast(b.dataset.rev === 'si' ? 'Saldo cuadrado con lo contado' : 'Cierre revisado', 'ok');
      h.cerrar();
      if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
    } catch (err) { toast(errMsg(err), 'error'); $$('[data-rev]', h.el).forEach(function (x) { x.disabled = false; }); }
  });
}
