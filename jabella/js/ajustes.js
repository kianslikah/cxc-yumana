// JABELLA — ajustes: tasa del día, mi cuenta, reglas de la tienda, usuarios y cuentas de dinero.
'use strict';

function hojaTasa() {
  var h = abrirHoja({
    titulo: 'Tasa del día',
    cerrarFuera: false,
    html: '<p class="suave" style="margin-top:0">Bolívares por cada dólar. Se usa para cobrar en Bs y hay que confirmarla cada día.' +
      (ST.cfg.tasa_actualizada_en ? '<br>Última: <b>' + fmtTasa(ST.cfg.tasa_bs) + '</b> (' + fmtFechaHora(ST.cfg.tasa_actualizada_en) + ')' : '') +
      (esDuena() ? '' : '<br><span class="tenue">Puedes confirmarla o ajustarla hasta 5 %. Un cambio mayor lo hace la dueña.</span>') + '</p>' +
      '<label class="campo"><span>Tasa de hoy (Bs por $)</span><input id="tsValor" inputmode="decimal" placeholder="Ej.: 36,50" value="' + (ST.cfg.tasa_bs ? esc(fmtTasa(ST.cfg.tasa_bs)) : '') + '"></label>',
    pie: '<button type="button" class="btn btn-ancho" id="tsOk">Guardar tasa</button>'
  });
  setTimeout(function () { h.$('#tsValor').select(); }, 80);
  protegerBoton(h.$('#tsOk'), async function () {
    var n = parseNum(h.$('#tsValor').value);
    if (isNaN(n) || n <= 0) throw new Error('Escribe una tasa válida.');
    if (ST.cfg.tasa_bs && (n > ST.cfg.tasa_bs * 1.5 || n < ST.cfg.tasa_bs / 1.5)) {
      if (!(await confirmar({ titulo: '¿Seguro?', mensaje: 'La tasa cambia mucho: de ' + fmtTasa(ST.cfg.tasa_bs) + ' a ' + fmtTasa(n) + '.', boton: 'Sí, guardar' }))) return;
    }
    await rpc('jab_actualizar_tasa', { p_tasa: n });
    await cargarConfig();
    toast('Tasa guardada: ' + fmtTasa(n), 'ok');
    h.cerrar();
    if (VistaActual && VistaActual.refrescar) VistaActual.refrescar();
  });
}

function hojaCambiarClave(obligatoria) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: obligatoria ? 'Crea tu clave' : 'Cambiar mi clave',
      cerrarFuera: !obligatoria,
      html: (obligatoria ? '<p class="suave" style="margin-top:0">Es tu primera vez entrando. Crea una clave que solo tú sepas.</p>' : '') +
        '<div class="pila"><label class="campo"><span>Clave nueva</span><input id="ccClave" type="password" autocomplete="new-password"></label>' +
        '<label class="campo"><span>Repite la clave</span><input id="ccClave2" type="password" autocomplete="new-password"></label>' +
        '<div class="ayuda">Mínimo 6 caracteres.</div></div>',
      pie: '<button type="button" class="btn btn-ancho" id="ccOk">Guardar clave</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    if (obligatoria) h.$('[data-cerrar]').hidden = true;
    protegerBoton(h.$('#ccOk'), async function () {
      var c1 = h.$('#ccClave').value, c2 = h.$('#ccClave2').value;
      if (c1.length < 6) throw new Error('La clave debe tener al menos 6 caracteres.');
      if (c1 !== c2) throw new Error('Las dos claves no son iguales.');
      var r = await sb.auth.updateUser({ password: c1 });
      if (r.error) {
        if (/different from the old/i.test(r.error.message)) throw new Error('La clave nueva debe ser distinta a la anterior.');
        throw r.error;
      }
      await rpc('jab_marcar_clave_cambiada');
      ST.yo.debe_cambiar_clave = false;
      toast('Clave guardada', 'ok');
      listo = true; h.cerrar(); resolver(true);
    });
  });
}

// Llama a la función del servidor que maneja usuarios y devuelve el mensaje de error legible
async function funcionUsuarios(body) {
  var r = await sb.functions.invoke('jab-usuarios', { body: body });
  if (r.error) {
    var msg = r.error.message;
    try { var j = await r.error.context.json(); if (j && j.error) msg = j.error; } catch (e) { /* sin cuerpo */ }
    throw new Error(msg);
  }
  if (r.data && r.data.error) throw new Error(r.data.error);
  return r.data;
}

var VistaAjustes = {
  titulo: 'Ajustes',
  async mostrar(cont) {
    var cfg = ST.cfg;
    cont.innerHTML = '<div id="ajRaiz" class="pila">' +
      '<div class="tarjeta"><div class="fila-entre"><div><h3>Tasa del día</h3>' +
        '<div class="num" style="font-size:1.5rem;font-weight:600;margin-top:4px">' + (cfg.tasa_bs ? fmtTasa(cfg.tasa_bs) + ' Bs/$' : 'Sin tasa') + '</div>' +
        '<div class="tenue">' + (cfg.tasa_actualizada_en ? 'Actualizada ' + fmtFechaHora(cfg.tasa_actualizada_en) : 'Ponla antes de cobrar en bolívares') + '</div></div>' +
        '<button type="button" class="btn btn-sec" data-a="tasa">Cambiar</button></div></div>' +
      '<div class="tarjeta"><h3>Apariencia</h3><p class="ayuda" style="margin:4px 0 10px">En este equipo. "Automático" usa el modo del teléfono o la laptop.</p>' +
        '<div class="seg" id="ajTema">' + [['auto', 'Automático'], ['claro', 'Claro'], ['noche', 'Noche']].map(function (x) {
          return '<button type="button" data-tema="' + x[0] + '"' + (temaActual() === x[0] ? ' class="activo"' : '') + '>' + x[1] + '</button>';
        }).join('') + '</div></div>' +
      '<div class="tarjeta"><h3>Mi cuenta</h3>' +
        '<p style="margin:6px 0 12px">' + esc(ST.yo.nombre) + ' <span class="tenue">(' + (esDuena() ? 'dueña' : 'vendedora') + ')</span><br><span class="tenue">Entras con: ' + esc(correoDe(ST.yo)) + '</span></p>' +
        (esDuena() ? '' : '<p class="ayuda" style="margin:-4px 0 12px">Puedes: vender de contado' + ['apartar', 'fiar', 'cambios', 'descuentos'].filter(puede).map(function (k) { return ', ' + PERMISOS[k].corto; }).join('') + '.</p>') +
        '<div class="botonera"><button type="button" class="btn btn-sec btn-chico" data-a="clave">' + icono('candado', 'ic-chico') + ' Cambiar mi clave</button>' +
        '<button type="button" class="btn btn-sec btn-chico" data-a="salir">' + icono('salir', 'ic-chico') + ' Salir</button></div></div>' +
      (esDuena() ?
        '<div class="tarjeta"><h3>Reglas de la tienda</h3><div class="pila" style="margin-top:10px">' +
          '<div class="campos-2"><label class="campo"><span>Días para retirar un apartado</span><input id="ajDias" inputmode="numeric" value="' + cfg.dias_apartado + '"></label>' +
          '<label class="campo"><span>Abono mínimo para apartar (%)</span><input id="ajPct" inputmode="decimal" value="' + fmtNum(cfg.abono_minimo_pct).replace(/,00$/, '') + '"></label></div>' +
          '<label class="campo"><span>Flete por libra del courier ($)</span><input id="ajTarifa" inputmode="decimal" value="' + fmtNum(cfg.tarifa_libra) + '"></label>' +
          '<label class="campo"><span>Tu WhatsApp para los avisos</span><input id="ajWa" type="tel" inputmode="tel" value="' + esc(cfg.whatsapp_duena || '') + '" placeholder="Ej.: 0414 123 4567"></label>' +
          '<div class="ayuda">La vendedora te avisa por aquí cada venta, cuando abre y cuando cierra la caja. Vacío = sin avisos.</div>' +
          '<button type="button" class="btn btn-chico" data-a="reglas" style="align-self:flex-start">Guardar reglas</button></div></div>' +
        '<div class="tarjeta"><h3>Historial de la tasa</h3><div id="ajTasas" style="margin-top:8px"><div class="cargando">Cargando…</div></div></div>' +
        '<div class="tarjeta"><div class="fila-entre"><h3>Usuarios</h3><button type="button" class="btn btn-chico" data-a="nuevoUsuario">' + icono('mas', 'ic-chico') + ' Nuevo usuario</button></div>' +
          '<p class="ayuda">Cada persona entra con su correo y su clave. Lo que puede hacer la vendedora se marca en su ficha.</p>' +
          '<div id="ajUsuarios" style="margin-top:10px"></div></div>' +
        '<div class="tarjeta"><div class="fila-entre"><h3>Cuentas de dinero</h3><button type="button" class="btn btn-sec btn-chico" data-a="nuevaCuenta">' + icono('mas', 'ic-chico') + ' Cuenta</button></div>' +
          '<p class="ayuda">Dónde está el dinero (efectivo, banco, Zelle…).</p><div id="ajCuentas"></div></div>' +
        '<div class="tarjeta"><div class="fila-entre"><h3>Formas de pago</h3><button type="button" class="btn btn-sec btn-chico" data-a="nuevoMetodo">' + icono('mas', 'ic-chico') + ' Forma de pago</button></div>' +
          '<p class="ayuda">Cómo pagan las clientas y a qué cuenta va ese dinero.</p><div id="ajMetodos"></div></div>'
        : '') +
    '</div>';
    var self = this;
    $('#ajRaiz').addEventListener('click', async function (e) {
      var tb = e.target.closest('#ajTema [data-tema]');
      if (tb) {
        aplicarTema(tb.dataset.tema);
        $$('#ajTema button').forEach(function (x) { x.classList.toggle('activo', x === tb); });
        return;
      }
      var b = e.target.closest('[data-a]'); if (!b) return;
      var a = b.dataset.a;
      try {
        if (a === 'tasa') hojaTasa();
        if (a === 'clave') hojaCambiarClave(false);
        if (a === 'salir') salir();
        if (a === 'reglas') await self.guardarReglas(b);
        if (a === 'nuevoUsuario') { if (await hojaUsuario(null)) self.pintarUsuarios(); }
        if (a === 'usuario') { if (await hojaUsuario(ST.usrPorId.get(b.dataset.id))) self.pintarUsuarios(); }
        if (a === 'nuevaCuenta' || a === 'cuenta') { if (await hojaCuenta(a === 'cuenta' ? ST.cuentas.find(function (c) { return c.id === Number(b.dataset.id); }) : null)) self.pintarCuentas(); }
        if (a === 'nuevoMetodo' || a === 'metodo') { if (await hojaMetodo(a === 'metodo' ? ST.metodos.find(function (m) { return m.id === Number(b.dataset.id); }) : null)) self.pintarCuentas(); }
      } catch (err) { toast(errMsg(err), 'error'); }
    });
    if (esDuena()) { this.pintarUsuarios().then(function () { self.pintarTasas(); }); this.pintarCuentas(); }
  },
  // No redibujar mientras se escribe en un campo de esta pantalla
  refrescar() {
    var raiz = $('#ajRaiz');
    if (raiz && !raiz.contains(document.activeElement)) this.mostrar($('#vista'));
  },
  async pintarTasas() {
    var c = $('#ajTasas'); if (!c) return;
    var r = await sb.from('jab_tasas').select('*').order('id', { ascending: false }).limit(10);
    if (r.error) { c.innerHTML = '<div class="aviso aviso-error">' + esc(errMsg(r.error)) + '</div>'; return; }
    c.innerHTML = r.data.length ? '<div class="lista">' + r.data.map(function (t) {
      var u = ST.usrPorId.get(t.usuario_id);
      return '<div class="item"><div class="crece">' + fmtFechaHora(t.creado_en) + '<div class="sub">' + esc(u ? u.nombre : '—') + '</div></div>' +
        '<span class="num fuerte">' + fmtTasa(t.tasa) + '</span></div>';
    }).join('') + '</div>' : '<div class="tenue">Todavía no se ha puesto ninguna tasa.</div>';
  },
  async guardarReglas(btn) {
    var dias = Number($('#ajDias').value), pct = parseNum($('#ajPct').value), tarifa = parseNum($('#ajTarifa').value);
    if (isNaN(tarifa) || tarifa < 0) throw new Error('Revisa el flete por libra.');
    if (!Number.isInteger(dias) || dias < 1 || dias > 120) throw new Error('Los días deben estar entre 1 y 120.');
    if (isNaN(pct) || pct < 0 || pct > 100) throw new Error('El porcentaje debe estar entre 0 y 100.');
    var wa = $('#ajWa').value.trim();
    if (wa && (!/^[0-9+() -]{7,20}$/.test(wa) || telefonoWa(wa).length < 10)) throw new Error('Revisa tu número de WhatsApp (ej.: 0414 123 4567).');
    btn.disabled = true;
    try {
      await rpc('jab_actualizar_config', { p: { dias_apartado: dias, abono_minimo_pct: pct, tarifa_libra: redondear2(tarifa), whatsapp_duena: wa } });
      await cargarConfig();
      toast('Reglas guardadas', 'ok');
    } finally { btn.disabled = false; }
  },
  async pintarUsuarios() {
    var c = $('#ajUsuarios'); if (!c) return;
    try { await cargarUsuarios(); } catch (e) { c.innerHTML = '<div class="aviso aviso-error">' + esc(errMsg(e)) + '</div>'; return; }
    c.innerHTML = '<div class="lista">' + ST.usuarios.map(function (u) {
      return '<button type="button" class="item" data-a="usuario" data-id="' + u.id + '">' + icono('usuario') +
        '<div class="crece"><div class="titulo">' + esc(u.nombre) + (u.id === ST.yo.id ? ' <span class="tenue">(tú)</span>' : '') + '</div>' +
        '<div class="sub corta">' + esc(correoDe(u)) + (u.rol !== 'duena' && Number(u.comision_pct) > 0 ? ' · comisión ' + fmtNum(u.comision_pct).replace(/,00$/, '') + ' %' : '') + '</div></div>' +
        '<span class="etq ' + (u.rol === 'duena' ? 'etq-lila' : '') + '">' + (u.rol === 'duena' ? 'Dueña' : 'Vendedora') + '</span>' +
        (u.activo ? '' : '<span class="etq etq-error">Inactivo</span>') + '</button>';
    }).join('') + '</div>';
  },
  async pintarCuentas() {
    var c1 = $('#ajCuentas'), c2 = $('#ajMetodos'); if (!c1) return;
    await cargarMetodos();
    c1.innerHTML = '<div class="lista">' + ST.cuentas.map(function (c) {
      return '<button type="button" class="item" data-a="cuenta" data-id="' + c.id + '"><div class="crece"><div class="titulo">' + esc(c.nombre) + '</div>' +
        '<div class="sub">' + (c.moneda === 'VES' ? 'Bolívares' : 'Dólares') + '</div></div>' + (c.activa ? '' : '<span class="etq">Desactivada</span>') + '</button>';
    }).join('') + '</div>';
    c2.innerHTML = '<div class="lista">' + ST.metodos.map(function (m) {
      var cu = cuentaDe(m);
      return '<button type="button" class="item" data-a="metodo" data-id="' + m.id + '"' + (m.es_saldo_favor ? ' disabled' : '') + '><div class="crece"><div class="titulo">' + esc(m.nombre) + '</div>' +
        '<div class="sub">' + (m.es_saldo_favor ? 'Usa el saldo a favor de la clienta' : 'Va a: ' + esc(cu ? cu.nombre : '—')) + '</div></div>' +
        (m.activo ? '' : '<span class="etq">Desactivada</span>') + '</button>';
    }).join('') + '</div>';
  }
};

var PERMISOS = {
  apartar: { texto: 'Puede apartar', ayuda: 'Reservar prendas con un abono.', corto: 'apartar' },
  fiar: { texto: 'Puede vender fiado', ayuda: 'Que la clienta se lleve la prenda debiendo (respeta el límite de cada clienta).', corto: 'fiar' },
  cambios: { texto: 'Puede hacer cambios', ayuda: 'Cambiar o devolver prendas de una venta.', corto: 'hacer cambios' },
  descuentos: { texto: 'Puede cambiar precios', ayuda: 'Hacer descuentos o poner otro precio al vender.', corto: 'cambiar precios' }
};
function correoDe(u) { return u.correo || (u.usuario ? u.usuario + '@' + JAB_CONFIG.dominio : '—'); }
var correoOk = function (c) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(c); };

function hojaUsuario(u) {
  return new Promise(function (resolver) {
    var listo = false, nuevo = !u, creadoId = null;
    var base = u || { rol: 'vendedora', activo: true, permisos: {}, comision_pct: 5 };
    var h = abrirHoja({
      titulo: nuevo ? 'Nuevo usuario' : u.nombre,
      cerrarFuera: false,
      html: '<div class="pila">' +
        '<label class="campo"><span>Nombre</span><input id="usNombre" value="' + esc(u ? u.nombre : '') + '" placeholder="Ej.: Ana"></label>' +
        '<label class="campo"><span>Correo para entrar</span><input id="usCorreo" type="email" inputmode="email" autocapitalize="none" autocorrect="off" spellcheck="false" value="' + esc(u ? (u.correo || '') : '') + '" placeholder="Ej.: ana@gmail.com"></label>' +
        (nuevo ? '<label class="campo"><span>Clave temporal</span><input id="usClave" autocomplete="off" placeholder="Mínimo 6 caracteres"></label>' +
          '<div class="ayuda">Dásela en persona. Al entrar por primera vez le pedirá crear su propia clave.</div>'
          : (u.correo ? '' : '<div class="ayuda">Hoy entra con "' + esc(u.usuario) + '". Si le pones un correo, desde ahora entra con el correo.</div>')) +
        '<label class="campo"><span>Rol</span><select id="usRol"><option value="vendedora">Vendedora (vende; no ve costos, dinero ni reportes)</option>' +
          '<option value="duena"' + (base.rol === 'duena' ? ' selected' : '') + '>Dueña (ve y hace todo)</option></select></label>' +
        '<div id="usPermisos" class="tarjeta pila" style="padding:12px 14px">' +
          '<div><h3>Qué puede hacer</h3><div class="ayuda" style="margin-top:4px">Vender de contado siempre puede.</div></div>' +
          Object.keys(PERMISOS).map(function (k) {
            return '<label class="fila" style="align-items:flex-start"><input type="checkbox" data-permiso="' + k + '"' + (permisoDe(Object.assign({}, base, { rol: 'vendedora', activo: true }), k) ? ' checked' : '') +
              ' style="width:20px;height:20px;flex:none;margin-top:2px"><span>' + PERMISOS[k].texto + '<br><span class="tenue" style="font-size:.85rem">' + PERMISOS[k].ayuda + '</span></span></label>';
          }).join('') +
          '<label class="campo"><span>Comisión por venta de contado (%)</span><input id="usComision" inputmode="decimal" value="' + esc(fmtNum(base.comision_pct || 0).replace(/,00$/, '')) + '"></label>' +
          '<div class="ayuda">Se gana sobre lo vendido de contado y cobrado completo. Apartados y fiados no suman. 0 = sin comisión.</div>' +
        '</div>' +
        (nuevo ? '' : '<label class="fila"><input type="checkbox" id="usActivo"' + (u.activo ? ' checked' : '') + ' style="width:20px;height:20px"> Puede entrar al sistema</label>' +
          '<button type="button" class="btn btn-sec btn-chico" id="usClaveBtn" style="align-self:flex-start">' + icono('candado', 'ic-chico') + ' Ponerle una clave nueva</button>') +
      '</div>',
      pie: '<button type="button" class="btn btn-ancho" id="usOk">' + (nuevo ? 'Crear usuario' : 'Guardar') + '</button>',
      alCerrar: function () { if (!listo) resolver(creadoId != null); }
    });
    function verPermisos() { h.$('#usPermisos').hidden = h.$('#usRol').value === 'duena'; }
    h.$('#usRol').addEventListener('change', verPermisos);
    verPermisos();
    var cb = h.$('#usClaveBtn');
    if (cb) cb.onclick = async function () {
      var clave = await confirmar({ titulo: 'Clave nueva para ' + u.nombre, mensaje: 'Dásela en persona. Al entrar le pedirá cambiarla.', pedir: 'Clave nueva (mínimo 6)', boton: 'Guardar clave' });
      if (!clave) return;
      try { await funcionUsuarios({ accion: 'clave', id: u.id, clave: clave }); toast('Clave cambiada', 'ok'); }
      catch (e) { toast(errMsg(e), 'error'); }
    };
    function leerPermisos() {
      var permisos = {};
      $$('[data-permiso]', h.el).forEach(function (x) { permisos[x.dataset.permiso] = x.checked; });
      var pct = parseNum(h.$('#usComision').value || '0');
      if (isNaN(pct) || pct < 0 || pct > 50) throw new Error('La comisión debe estar entre 0 y 50 %.');
      return { permisos: permisos, comision_pct: redondear2(pct) };
    }
    protegerBoton(h.$('#usOk'), async function () {
      var nombre = h.$('#usNombre').value.trim(), rol = h.$('#usRol').value;
      var correo = h.$('#usCorreo').value.trim().toLowerCase();
      if (!nombre) throw new Error('Escribe el nombre.');
      var perm = rol === 'vendedora' ? leerPermisos() : null;
      if (nuevo) {
        var clave = h.$('#usClave').value;
        if (!correoOk(correo)) throw new Error('Escribe un correo válido (ej.: ana@gmail.com).');
        if (clave.length < 6) throw new Error('La clave debe tener al menos 6 caracteres.');
        // Si ya se creó en un intento anterior, no se vuelve a crear
        if (creadoId == null) {
          var r = await funcionUsuarios({ accion: 'crear', correo: correo, nombre: nombre, clave: clave, rol: rol });
          creadoId = r.id;
        }
        if (perm) await rpc('jab_guardar_permisos', { p_id: creadoId, p: perm });
        toast('Usuario creado. Entra con ' + correo, 'ok');
      } else {
        var activo = h.$('#usActivo').checked;
        if (correo && !correoOk(correo)) throw new Error('Escribe un correo válido (ej.: ana@gmail.com).');
        if (!correo && u.correo) throw new Error('Escribe el correo con el que entra.');
        if (u.id === ST.yo.id && (!activo || rol !== 'duena')) {
          if (!(await confirmar({ titulo: 'Cuidado', mensaje: 'Te vas a quitar permisos a ti misma. ¿Seguro?', boton: 'Sí, seguir', peligro: true }))) return;
        }
        await rpc('jab_actualizar_usuario', { p_id: u.id, p_nombre: nombre, p_rol: rol, p_activo: activo });
        if (perm) await rpc('jab_guardar_permisos', { p_id: u.id, p: perm });
        if (correo && correo !== (u.correo || '')) {
          await funcionUsuarios({ accion: 'correo', id: u.id, correo: correo });
          toast('Desde ahora entra con ' + correo, 'ok');
        } else toast('Usuario actualizado', 'ok');
        if (u.id === ST.yo.id) {
          var yo = await sb.from('jab_usuarios').select('*').eq('id', ST.yo.id).single();
          if (!yo.error) ST.yo = yo.data;
        }
      }
      listo = true; h.cerrar(); resolver(true);
    }, nuevo ? 'Creando…' : 'Guardando…');
  });
}

function hojaCuenta(c) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: c ? 'Cuenta: ' + c.nombre : 'Nueva cuenta',
      cerrarFuera: false,
      html: '<div class="pila"><label class="campo"><span>Nombre</span><input id="cuNombre" value="' + esc(c ? c.nombre : '') + '" placeholder="Ej.: Banesco"></label>' +
        '<label class="campo"><span>Moneda</span><select id="cuMoneda"' + (c ? ' disabled' : '') + '><option value="USD">Dólares</option><option value="VES"' + (c && c.moneda === 'VES' ? ' selected' : '') + '>Bolívares</option></select></label>' +
        '<label class="fila"><input type="checkbox" id="cuCierre"' + (c ? (c.cuenta_en_cierre ? ' checked' : '') : '') + ' style="width:20px;height:20px"> Se cuenta en el cierre de caja (efectivo)</label>' +
        (c ? '<label class="fila"><input type="checkbox" id="cuActiva"' + (c.activa ? ' checked' : '') + ' style="width:20px;height:20px"> Activa</label>' : '') + '</div>',
      pie: '<button type="button" class="btn btn-ancho" id="cuOk">Guardar</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    protegerBoton(h.$('#cuOk'), async function () {
      var nombre = h.$('#cuNombre').value.trim();
      if (!nombre) throw new Error('Escribe el nombre.');
      var enCierre = h.$('#cuCierre').checked;
      var r = c ? await sb.from('jab_cuentas').update({ nombre: nombre, activa: h.$('#cuActiva').checked, cuenta_en_cierre: enCierre }).eq('id', c.id)
                : await sb.from('jab_cuentas').insert({ nombre: nombre, moneda: h.$('#cuMoneda').value, orden: ST.cuentas.length + 1, cuenta_en_cierre: enCierre });
      if (r.error) throw r.error;
      listo = true; h.cerrar(); resolver(true);
    });
  });
}

function hojaMetodo(m) {
  return new Promise(function (resolver) {
    var listo = false;
    var h = abrirHoja({
      titulo: m ? 'Forma de pago: ' + m.nombre : 'Nueva forma de pago',
      cerrarFuera: false,
      html: '<div class="pila"><label class="campo"><span>Nombre</span><input id="mtNombre" value="' + esc(m ? m.nombre : '') + '" placeholder="Ej.: Pago móvil Banesco"></label>' +
        '<label class="campo"><span>El dinero va a la cuenta</span><select id="mtCuenta">' + ST.cuentas.filter(function (c) { return c.activa; }).map(function (c) {
          return '<option value="' + c.id + '"' + (m && m.cuenta_id === c.id ? ' selected' : '') + '>' + esc(c.nombre) + (c.moneda === 'VES' ? ' (Bs)' : ' ($)') + '</option>';
        }).join('') + '</select></label>' +
        (m ? '<label class="fila"><input type="checkbox" id="mtActivo"' + (m.activo ? ' checked' : '') + ' style="width:20px;height:20px"> Activa</label>' : '') + '</div>',
      pie: '<button type="button" class="btn btn-ancho" id="mtOk">Guardar</button>',
      alCerrar: function () { if (!listo) resolver(false); }
    });
    protegerBoton(h.$('#mtOk'), async function () {
      var nombre = h.$('#mtNombre').value.trim();
      if (!nombre) throw new Error('Escribe el nombre.');
      var d = { nombre: nombre, cuenta_id: Number(h.$('#mtCuenta').value) };
      var r = m ? await sb.from('jab_metodos_pago').update(Object.assign(d, { activo: h.$('#mtActivo').checked })).eq('id', m.id)
                : await sb.from('jab_metodos_pago').insert(Object.assign(d, { orden: ST.metodos.length + 1 }));
      if (r.error) throw r.error;
      listo = true; h.cerrar(); resolver(true);
    });
  });
}
