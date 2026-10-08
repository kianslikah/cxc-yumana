// JABELLA — inventario: prendas con foto, tallas/colores, existencia, precio y costo (solo dueña).
'use strict';

var VistaInventario = {
  titulo: 'Inventario',
  filtro: 'todas',
  cat: '',
  mostrar(cont) {
    cont.innerHTML =
      '<div class="encabezado"><h2>Inventario</h2>' +
        (esDuena() ? '<button type="button" class="btn btn-chico" id="invNueva">' + icono('mas', 'ic-chico') + ' Nueva prenda</button>' : '') + '</div>' +
      '<div id="invKpi" style="margin-bottom:14px"></div>' +
      '<div class="fila" style="margin-bottom:10px;flex-wrap:wrap">' +
        '<div class="buscador crece" style="min-width:200px">' + icono('buscar', 'ic-chico') +
          '<input class="entrada" id="invBuscar" placeholder="Buscar prenda o código" autocomplete="off"></div>' +
        '<select class="entrada" id="invCat" style="width:auto;min-width:150px" aria-label="Categoría"></select></div>' +
      '<div class="chips" id="invFiltro" style="margin-bottom:12px">' +
        '<button type="button" class="chip activo" data-f="todas">Todas</button>' +
        '<button type="button" class="chip" data-f="con">Con existencia</button>' +
        '<button type="button" class="chip" data-f="agotadas">Agotadas</button>' +
        (esDuena() ? '<button type="button" class="chip" data-f="sincosto">Sin costo</button><button type="button" class="chip" data-f="archivadas">Archivadas</button>' : '') +
      '</div>' +
      '<div id="invLista"></div>';
    var self = this;
    var nb = $('#invNueva'); if (nb) nb.onclick = function () { editarProducto(null); };
    $('#invBuscar').addEventListener('input', debounce(function () { self.pintarLista(); }, 220));
    $('#invCat').addEventListener('change', function (e) { self.cat = e.target.value; self.pintarLista(); });
    $('#invFiltro').addEventListener('click', function (e) {
      var b = e.target.closest('[data-f]'); if (!b) return;
      self.filtro = b.dataset.f;
      $$('#invFiltro .chip').forEach(function (x) { x.classList.toggle('activo', x === b); });
      self.pintarLista();
    });
    $('#invLista').addEventListener('click', function (e) {
      var b = e.target.closest('[data-p]'); if (!b) return;
      var p = ST.prodPorId.get(Number(b.dataset.p));
      if (esDuena()) editarProducto(p); else verProducto(p);
    });
    this.refrescar();
  },
  refrescar() {
    if (!$('#invLista')) return;
    var cats = categorias(), self = this;
    $('#invCat').innerHTML = '<option value="">Todas las categorías</option>' + cats.map(function (c) {
      return '<option' + (c === self.cat ? ' selected' : '') + '>' + esc(c) + '</option>';
    }).join('');
    this.pintarKpi(); this.pintarLista();
  },
  pintarKpi() {
    var activos = ST.productos.filter(function (p) { return p.activo; });
    var unidades = 0, valorVenta = 0, valorCosto = 0, sinCosto = 0;
    activos.forEach(function (p) {
      var s = stockProducto(p.id);
      unidades += s; valorVenta += s * Number(p.precio);
      if (ST.costos.has(p.id)) valorCosto += s * ST.costos.get(p.id); else if (s > 0) sinCosto++;
    });
    $('#invKpi').innerHTML = '<div class="tarjetas-kpi">' +
      '<div class="kpi"><div class="t">Prendas</div><div class="v">' + activos.length + '</div><div class="s">modelos activos</div></div>' +
      '<div class="kpi"><div class="t">Unidades</div><div class="v">' + unidades + '</div><div class="s">en tienda</div></div>' +
      '<div class="kpi"><div class="t">Valor a precio de venta</div><div class="v">' + fmtUSD(valorVenta) + '</div></div>' +
      (esDuena() ? '<div class="kpi"><div class="t">Valor a costo</div><div class="v">' + fmtUSD(valorCosto) + '</div><div class="s">' +
        (sinCosto ? sinCosto + ' prenda' + (sinCosto === 1 ? '' : 's') + ' sin costo' : 'todas con costo') + '</div></div>' : '') +
    '</div>';
  },
  pintarLista() {
    var cont = $('#invLista'); if (!cont) return;
    var q = normalizar($('#invBuscar').value.trim()), f = this.filtro, cat = this.cat;
    var lista = ST.productos.filter(function (p) {
      if (f === 'archivadas' ? p.activo : !p.activo) return false;
      if (cat && p.categoria !== cat) return false;
      if (q && normalizar(p.nombre).indexOf(q) < 0 && normalizar(p.codigo).indexOf(q) < 0) return false;
      var s = stockProducto(p.id);
      if (f === 'con') return s > 0;
      if (f === 'agotadas') return s <= 0;
      if (f === 'sincosto') return !ST.costos.has(p.id);
      return true;
    }).sort(function (a, b) { return b.id - a.id; });
    if (!lista.length) {
      cont.innerHTML = ST.productos.length
        ? '<div class="vacio">Ninguna prenda coincide con el filtro.</div>'
        : '<div class="vacio"><h3>El inventario está vacío</h3>' +
            (esDuena() ? 'Carga cada prenda con su foto, tallas y cuántas hay. Usa "Guardar y cargar otra" para ir rápido.' +
              '<br><button type="button" class="btn" onclick="editarProducto(null)">' + icono('mas', 'ic-chico') + ' Cargar la primera prenda</button>'
              : 'La dueña todavía no ha cargado prendas.') + '</div>';
      return;
    }
    cont.innerHTML = '<div class="lista"></div>';
    dibujarPorPartes(cont, lista, function (p) {
      var vars = variantesActivas(p.id), s = stockProducto(p.id);
      var resumen = vars.map(function (v) { return esc(descVariante(v)) + ' <b>' + v.stock + '</b>'; }).join(' · ');
      return '<button type="button" class="item" data-p="' + p.id + '">' + imgProducto(p, 'miniatura') +
        '<div class="crece"><div class="titulo corta">' + esc(p.nombre) + '</div>' +
          '<div class="sub corta">' + esc(p.codigo) + ' · ' + esc(p.categoria) + '</div>' +
          '<div class="sub corta">' + (resumen || 'Sin tallas') + '</div></div>' +
        '<div class="derecha"><div class="num fuerte">' + fmtUSD(p.precio) + '</div>' +
          '<div class="sub ' + (s <= 0 ? 'error-txt' : '') + '">' + (s > 0 ? s + ' en tienda' : 'Agotada') + '</div>' +
          (esDuena() && !ST.costos.has(p.id) ? '<div class="sub aviso-txt">sin costo</div>' : '') + '</div></button>';
    }, 60, '.lista');
  }
};

// Vista de solo lectura (vendedora)
function verProducto(p) {
  abrirHoja({
    titulo: p.nombre,
    html: imgProducto(p, 'foto-grande', true) +
      '<div class="fila-entre" style="margin:14px 0"><div class="tenue">' + esc(p.codigo) + ' · ' + esc(p.categoria) + '</div>' +
      '<div class="num fuerte" style="font-size:1.3rem">' + fmtUSD(p.precio) + '</div></div>' +
      (p.notas ? '<p class="suave">' + esc(p.notas) + '</p>' : '') +
      '<div class="lista">' + variantesActivas(p.id).map(function (v) {
        return '<div class="item"><div class="crece">' + esc(descVariante(v)) + '</div><span class="num ' + (v.stock ? 'fuerte' : 'error-txt') + '">' + (v.stock || 'Agotada') + '</span></div>';
      }).join('') + '</div>'
  });
}

var PRESETS_TALLAS = [
  { n: 'S · M · L', t: ['S', 'M', 'L'] },
  { n: 'XS a XL', t: ['XS', 'S', 'M', 'L', 'XL'] },
  { n: 'Única', t: ['Única'] },
  { n: 'Jeans 4–16', t: ['4', '6', '8', '10', '12', '14', '16'] },
  { n: 'Calzado 35–40', t: ['35', '36', '37', '38', '39', '40'] }
];

function editarProducto(p, opts) {
  opts = opts || {};
  var nueva = !p;
  p = p || { nombre: '', categoria: opts.categoria || '', precio: '', notas: '', activo: true };
  var filas = nueva ? [] : (ST.varPorProducto.get(p.id) || []).map(function (v) {
    return { id: v.id, talla: v.talla, color: v.color, stock: v.stock, activo: v.activo };
  });
  if (nueva) filas.push({ talla: '', color: '', stock: '' });
  var fotoNueva = null, fotoSubida = null, quitarFoto = false, clave = nueva ? nuevaClave() : null;
  var costo = !nueva && ST.costos.has(p.id) ? ST.costos.get(p.id) : null;
  var cats = Array.from(new Set(categorias().concat(CATEGORIAS_BASE))).sort(function (a, b) { return a.localeCompare(b, 'es'); });

  var h = abrirHoja({
    titulo: nueva ? 'Nueva prenda' : 'Editar · ' + p.codigo,
    clase: 'completa ancha',
    cerrarFuera: false,
    html:
      '<div class="foto-editor"><div id="epFoto">' + imgProducto(p, '', true) + '</div>' +
        '<div class="pila"><label class="btn btn-sec btn-chico" style="position:relative;overflow:hidden">' + icono('camara', 'ic-chico') + ' Foto' +
          '<input type="file" id="epArchivo" accept="image/*" style="position:absolute;inset:0;opacity:0"></label>' +
          '<button type="button" class="btn btn-plano btn-chico" id="epQuitarFoto"' + (p.foto ? '' : ' hidden') + '>Quitar foto</button></div></div>' +
      '<div class="pila" style="margin-top:14px">' +
        '<label class="campo"><span>Nombre de la prenda</span><input id="epNombre" value="' + esc(p.nombre) + '" placeholder="Ej.: Blusa de lino manga corta"></label>' +
        '<label class="campo"><span>Categoría</span><input id="epCat" list="epCats" value="' + esc(p.categoria) + '" placeholder="Ej.: Blusas"><datalist id="epCats">' +
          cats.map(function (c) { return '<option value="' + esc(c) + '">'; }).join('') + '</datalist></label>' +
        '<div class="campos-2">' +
          '<label class="campo"><span>Precio de venta ($)</span><input id="epPrecio" inputmode="decimal" value="' + esc(p.precio === '' ? '' : fmtNum(p.precio)) + '"></label>' +
          '<label class="campo"><span>Costo por prenda ($)</span><input id="epCosto" inputmode="decimal" value="' + esc(costo == null ? '' : fmtNum(costo)) + '" placeholder="Con flete"></label>' +
        '</div>' +
        '<div class="ayuda" id="epGanancia">El costo es lo que te costó cada prenda (SHEIN + su parte del flete). Solo tú lo ves.</div>' +
        '<label class="campo"><span>Notas (opcional)</span><input id="epNotas" value="' + esc(p.notas || '') + '" placeholder="Tela, detalles, de qué pedido viene…"></label>' +
      '</div>' +
      '<h3 style="margin:20px 0 8px">Tallas, colores y existencia</h3>' +
      '<div class="chips" id="epPresets" style="margin-bottom:10px">' + PRESETS_TALLAS.map(function (x, i) {
        return '<button type="button" class="chip" data-preset="' + i + '">+ ' + esc(x.n) + '</button>';
      }).join('') + '</div>' +
      '<div class="tarjeta" style="padding:6px 10px"><table class="tabla"><thead><tr><th>Talla</th><th>Color</th><th style="width:96px">Hay</th><th style="width:44px"></th></tr></thead>' +
        '<tbody id="epVars"></tbody></table>' +
        '<button type="button" class="btn btn-plano btn-chico" id="epMasTalla">' + icono('mas', 'ic-chico') + ' Otra talla o color</button></div>' +
      (nueva ? '' : '<label class="fila" style="margin-top:16px"><input type="checkbox" id="epActivo"' + (p.activo ? ' checked' : '') + ' style="width:20px;height:20px"> Prenda activa (sale en Vender)</label>'),
    pie: '<div class="botonera">' + (nueva ? '<button type="button" class="btn btn-sec" id="epOtra">Guardar y cargar otra</button>' : '') +
      '<button type="button" class="btn" id="epGuardar">Guardar</button></div>'
  });

  function pintarFilas() {
    h.$('#epVars').innerHTML = filas.map(function (f, i) {
      if (f.id) {
        return '<tr' + (f.activo ? '' : ' class="tenue"') + '><td><input class="entrada" data-i="' + i + '" data-k="talla" value="' + esc(f.talla) + '"></td>' +
          '<td><input class="entrada" data-i="' + i + '" data-k="color" value="' + esc(f.color) + '"></td>' +
          '<td><button type="button" class="btn btn-sec btn-chico" data-ajustar="' + i + '" title="Ajustar existencia">' + f.stock + ' ' + icono('editar', 'ic-chico') + '</button></td>' +
          '<td>' + (f.stock === 0 ? '<button type="button" class="btn btn-plano btn-icono" data-ocultar="' + i + '" aria-label="' + (f.activo ? 'Ocultar talla' : 'Mostrar talla') + '">' +
            icono(f.activo ? 'basura' : 'mas', 'ic-chico') + '</button>' : '') + '</td></tr>';
      }
      return '<tr><td><input class="entrada" data-i="' + i + '" data-k="talla" value="' + esc(f.talla) + '" placeholder="M"></td>' +
        '<td><input class="entrada" data-i="' + i + '" data-k="color" value="' + esc(f.color) + '" placeholder="Opcional"></td>' +
        '<td><input class="entrada num" data-i="' + i + '" data-k="stock" inputmode="numeric" value="' + esc(f.stock) + '" placeholder="0"></td>' +
        '<td><button type="button" class="btn btn-plano btn-icono" data-quitar="' + i + '" aria-label="Quitar">' + icono('cerrar', 'ic-chico') + '</button></td></tr>';
    }).join('') || '<tr><td colspan="4" class="tenue">Agrega al menos una talla (o "Única").</td></tr>';
  }
  function pintarGanancia() {
    var pr = parseNum(h.$('#epPrecio').value), co = parseNum(h.$('#epCosto').value);
    var el = h.$('#epGanancia');
    if (!isNaN(pr) && !isNaN(co) && co > 0 && pr > 0) {
      var g = pr - co;
      el.innerHTML = 'Ganancia por prenda: <b class="' + (g < 0 ? 'error-txt' : 'ok-txt') + '">' + fmtUSD(g) + '</b> (' + Math.round(g / co * 100) + '% sobre el costo)';
    } else {
      el.textContent = 'El costo es lo que te costó cada prenda (SHEIN + su parte del flete). Solo tú lo ves.';
    }
  }

  h.$('#epPrecio').addEventListener('input', pintarGanancia);
  h.$('#epCosto').addEventListener('input', pintarGanancia);
  h.$('#epVars').addEventListener('input', function (e) {
    var i = e.target.dataset.i; if (i == null) return;
    filas[Number(i)][e.target.dataset.k] = e.target.value;
  });
  h.$('#epArchivo').addEventListener('change', function (e) {
    var f = e.target.files && e.target.files[0]; if (!f) return;
    fotoNueva = f; fotoSubida = null; quitarFoto = false;
    h.$('#epFoto').innerHTML = '<img src="' + URL.createObjectURL(f) + '" alt="">';
    h.$('#epQuitarFoto').hidden = false;
  });
  h.$('#epQuitarFoto').onclick = function () {
    fotoNueva = null; quitarFoto = true;
    h.$('#epFoto').innerHTML = '<div class="sin-foto">' + esc(iniciales(h.$('#epNombre').value).toUpperCase()) + '</div>';
    h.$('#epQuitarFoto').hidden = true;
  };
  h.$('#epPresets').addEventListener('click', function (e) {
    var b = e.target.closest('[data-preset]'); if (!b) return;
    filas = filas.filter(function (f) { return f.id || f.talla.trim() || String(f.stock).trim(); });
    PRESETS_TALLAS[Number(b.dataset.preset)].t.forEach(function (t) {
      if (!filas.some(function (f) { return normalizar(f.talla) === normalizar(t) && !f.color; })) filas.push({ talla: t, color: '', stock: '' });
    });
    pintarFilas();
  });
  h.$('#epMasTalla').onclick = function () { filas.push({ talla: '', color: '', stock: '' }); pintarFilas(); };
  h.$('#epVars').addEventListener('click', async function (e) {
    var t;
    if ((t = e.target.closest('[data-quitar]'))) { filas.splice(Number(t.dataset.quitar), 1); pintarFilas(); return; }
    if ((t = e.target.closest('[data-ocultar]'))) { var f = filas[Number(t.dataset.ocultar)]; f.activo = !f.activo; pintarFilas(); return; }
    if ((t = e.target.closest('[data-ajustar]'))) {
      var fila = filas[Number(t.dataset.ajustar)];
      var nuevo = await ajustarExistencia(fila, p);
      if (nuevo != null) { fila.stock = nuevo; pintarFilas(); }
    }
  });

  async function guardar() {
    var nombre = h.$('#epNombre').value.trim();
    var precio = parseNum(h.$('#epPrecio').value);
    var costoTxt = h.$('#epCosto').value.trim(), costoN = costoTxt ? parseNum(costoTxt) : null;
    if (!nombre) throw new Error('Escribe el nombre de la prenda.');
    if (isNaN(precio) || precio < 0) throw new Error('Revisa el precio de venta.');
    if (costoTxt && (isNaN(costoN) || costoN < 0)) throw new Error('Revisa el costo.');
    var vars = filas.filter(function (f) { return f.id || f.talla.trim() || f.color.trim() || String(f.stock).trim(); });
    if (!vars.length) throw new Error('Agrega al menos una talla (o "Única").');
    var payloadVars = vars.map(function (f) {
      if (f.id) return { id: f.id, talla: f.talla.trim(), color: f.color.trim(), activo: f.activo };
      var st = String(f.stock).trim() === '' ? 0 : Number(f.stock);
      if (!Number.isInteger(st) || st < 0) throw new Error('La existencia de la talla "' + (f.talla || '—') + '" debe ser un número entero.');
      return { talla: f.talla.trim() || (vars.length === 1 ? 'Única' : ''), color: f.color.trim(), stock: st };
    });
    var datos = {
      id: nueva ? null : p.id, nombre: nombre, categoria: h.$('#epCat').value.trim(),
      precio: redondear2(precio), notas: h.$('#epNotas').value.trim(), variantes: payloadVars
    };
    if (costoN != null) datos.costo = costoN;
    if (clave) datos.clave = clave;
    if (!nueva) datos.activo = h.$('#epActivo').checked;
    // La foto se sube una sola vez aunque se reintente el guardado
    if (fotoNueva) { fotoSubida = fotoSubida || await subirFoto(fotoNueva); datos.foto = fotoSubida.foto; datos.foto_mini = fotoSubida.foto_mini; }
    else if (quitarFoto) { datos.foto = ''; datos.foto_mini = ''; }
    await rpc('jab_guardar_producto', { p: datos });
    await cargarCatalogo();
    if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
    return datos;
  }
  protegerBoton(h.$('#epGuardar'), async function () {
    await guardar();
    toast(nueva ? 'Prenda guardada' : 'Cambios guardados', 'ok');
    h.cerrar();
  });
  var otra = h.$('#epOtra');
  if (otra) protegerBoton(otra, async function () {
    var d = await guardar();
    toast('Guardada. Carga la siguiente.', 'ok');
    h.cerrar();
    editarProducto(null, { categoria: d.categoria });
  });

  pintarFilas();
  pintarGanancia();
  if (nueva) setTimeout(function () { h.$('#epNombre').focus(); }, 80);
}

// Corrige la existencia de una talla (conteo, prenda dañada, etc.). Queda registrado.
function ajustarExistencia(fila, p) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: 'Ajustar existencia',
      cerrarFuera: false,
      html: '<p style="margin-top:0">' + esc(p.nombre) + ' · <b>' + esc(descVariante(fila)) + '</b><br><span class="tenue">Ahora hay ' + fila.stock + '.</span></p>' +
        '<div class="pila"><label class="campo"><span>¿Cuántas hay realmente?</span><input id="ajNuevo" inputmode="numeric" value="' + fila.stock + '"></label>' +
        '<label class="campo"><span>Motivo</span><select id="ajMotivo"><option>Conteo</option><option>Prenda dañada</option><option>Pérdida</option>' +
          '<option>Regalo o muestra</option><option>Llegó mercancía</option><option>Otro</option></select></label></div>',
      pie: '<button type="button" class="btn btn-ancho" id="ajOk">Guardar existencia</button>',
      alCerrar: function () { if (!listo) resolver(null); }
    });
    setTimeout(function () { h.$('#ajNuevo').select(); }, 80);
    protegerBoton(h.$('#ajOk'), async function () {
      var n = Number(h.$('#ajNuevo').value.trim());
      if (!Number.isInteger(n) || n < 0) throw new Error('Escribe un número entero.');
      await rpc('jab_ajustar_stock', { p_variante: fila.id, p_nuevo: n, p_nota: h.$('#ajMotivo').value });
      await cargarCatalogo();
      if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
      toast('Existencia actualizada', 'ok');
      listo = true; h.cerrar(); resolver(n);
    });
  });
}
