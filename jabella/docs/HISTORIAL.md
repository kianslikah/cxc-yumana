# Historial de entregas — JABELLA Store

## Entrega 1 — 2026-10-08: base del sistema

- Montado sobre la infraestructura de Yumana pero aislado (decisión de Kinan para no crear cuentas nuevas): web en `app.mercantilyumana.com/jabella/`, base con prefijo `jab_` en el Supabase de Yumana. Respaldo previo de Yumana: `respaldo_20261008b`. Migraciones: `jabella_01_tablas_y_funciones_internas`, `jabella_02_funciones_ventas`, `jabella_03_dinero_seguridad_datos`.
- Revisión profunda (thermo-nuclear) aplicada: anti-repetición por clave, anular pago con bloqueo correcto, tasa de hoy obligatoria y vendedora ±5 %, pago anulado en venta entregada pasa a fiado, cambio sobre fiado abona la deuda, prendas archivadas no se venden.
- Usuarios con rol dueña/vendedora; entrada con usuario y clave; cambio de clave obligatorio la primera vez; Edge Function `usuarios` para crear usuarios y cambiar claves.
- Inventario: prendas con foto (comprimida en el teléfono antes de subir), categoría, precio, costo (solo dueña), tallas/colores con existencia, ajustes de existencia con motivo, "Guardar y cargar otra" para el conteo inicial.
- Vender: catálogo con fotos, carrito, cobro **contado / apartado / fiado**, pagos mixtos en $ y Bs con la tasa del día, saldo a favor como forma de pago, recibo por WhatsApp.
- Apartados: 50 % mínimo y 15 días (configurable), abonos, entrega (o entrega dejando fiado), dar más días, cancelar (abono a saldo a favor o se lo queda la tienda).
- Fiados con abonos; cambios (con la venta original o, la dueña, sin venta registrada); diferencia a cobrar o saldo a favor; no hay devoluciones de dinero.
- Dinero (dueña): saldo de cada cuenta calculado desde pagos y movimientos; gastos, retiros, ingresos, mover/cambiar moneda, saldo inicial/corrección; anular movimientos.
- Ventas por día con lo cobrado por método; listas de apartados (vencidos en rojo) y fiados (del más viejo).
- Cambios en vivo entre laptop y teléfono (Realtime) y recarga al volver a la app.

## Entrega 2 — 2026-10-08: compras SHEIN y modo noche

- Respaldo previo: `respaldo_20261008c` (55 tablas, 12.673 filas). Migración `jabella_04_compras`. Huellas de Yumana iguales antes y después; las 52 funciones `jab_` iguales a las probadas.
- Pedido SHEIN con artículos (foto, talla, color, precio), total pagado (reparte impuestos y descuentos), pago desde una cuenta como inversión; paquetes con tracking, en camino → casillero.
- Caja de reempaque: paquetes del casillero, peso y volumétrico, flete = mayor × $6,99/lb (configurable en Ajustes), pago del flete, etapas tránsito → aduana → llegó (`jab_envio_estado`, solo cambia la etapa).
- Recepción: llegaron / faltantes por artículo, prenda nueva (mismo nombre = una prenda con tallas) o suma a una existente, costo real por pieza y costo promedio ponderado; caja vacía permitida (flete como pérdida); por defecto 0 si el pedido tiene paquetes fuera de la caja.
- Faltantes sin caja (`jab_marcar_faltante`), reembolsos ligados al artículo (en $, recalculados por trigger aunque se anulen desde Dinero), anular pedido o caja preguntando si devolvieron el dinero.
- Reintentos sin duplicar: clave por pedido/caja nueva (si ya se creó, se aplica como edición) y por cada artículo y paquete nuevo. Pedido con mercancía recibida: total, cantidades y precios fijos.
- Gasto "Mercancía (SHEIN y flete)" desde Dinero se marca solo como inversión (trigger).
- Modo noche: Ajustes → Apariencia (Automático / Claro / Noche), guardado por equipo.
- Revisión profunda aplicada (1 alto: Ajustes no respondía por `data-tema` en `<html>`; 5 medios: reembolso en Bs, duplicados al reintentar una edición, cerrar lo que nunca llega, recepción por defecto, etapa que pisaba ediciones; y los bajos de concurrencia, factor y rastro).

## Entrega 3 — 2026-10-08: reportes y cierre de caja

- Reportes (dueña): ganancia neta del período (ventas con costo − costo − gastos del local + abonos retenidos), vendido, invertido, cobrado, por cobrar, aviso de piezas sin costo, barras por día (ganancia/costo, colores validados para daltonismo, con tabla), gastos por categoría, lo más vendido, por vendedora; prendas sin movimiento 30/60/90 días.
- Cierre de caja ciego (cualquier usuaria) desde Ventas → Por día; la dueña lo revisa y puede cuadrar el saldo con lo contado (movimiento de ajuste con rastro). Cuentas que entran al cierre: casilla en Ajustes → Cuentas.
- Migración `jabella_05_reportes_cierre` (mismo respaldo `respaldo_20261008c`). 57 funciones `jab_` iguales a las probadas; huellas de Yumana iguales. Pruebas: 111 + 85 + 32.
- Revisión profunda aplicada: cuadrar solo el cierre más reciente y recalcular la diferencia desde los movimientos vivos hasta la hora del cierre (antes se podía ajustar dos veces la misma diferencia); "Cuadra" se decide por cuenta, no por la suma en $; cierre exige tasa si hay cuenta en Bs; lo cobrado por método del día solo lo ve la dueña (cierre de verdad a ciegas); lo devuelto en un cambio toma el costo de su venta original; `jab_sin_movimiento` devuelve jsonb (sin corte de 1000 filas) y cuenta desde la última venta o entrada de mercancía; "Invertido" descuenta reembolsos; la ganancia neta suma/resta los descuadres de caja cuadrados; fechas al revés o de más de un año ya no traban la pantalla; "Cerrar caja" no abre dos hojas y recarga las cuentas.
- Decisión pendiente para Kinan/Albany: los apartados cuentan como venta el día que se apartan (si se cancelan, dejan de contar en ese mes).

## Entrega 4 — 2026-10-15: vendedora (Ana), permisos, comisión, por llegar y foto del pago

- Respaldos previos: `respaldo_20261015` (antes del respaldo diario) y `respaldo_20261015b` (61 tablas, 15.705 filas, igual al original). Migraciones: `jabella_06_respaldo_diario`, `jabella_07_perfiles_comisiones` (= `004`), `jabella_08_respaldo_comprobantes`. Las 70 funciones `jab_` iguales a las probadas; 42 RPC para `authenticated`, 0 para `anon`, 0 internas expuestas; huellas de Yumana iguales antes y después. Edge Function `jab-usuarios` v2. Pruebas: 111 + 85 + 32 + 64 en local y 41 en la interfaz simulada.
- Entrar con correo y clave; Ajustes → Usuarios: crear con correo y clave temporal, cambiar correo, permisos por persona (apartar, fiar, cambios, cambiar precios) y % de comisión (5 % por defecto para vendedoras nuevas). La casilla general "la vendedora puede fiar" pasó a ser permiso por persona.
- Comisión: solo contado cobrado completo, % fijo en cada venta; "¿Quién vendió?" para la dueña; "Vendió" y la comisión en el detalle de la venta; "Tu comisión" (hoy, semana, mes, por cobrar) en Ventas de la vendedora; Reportes → Comisiones con "Pagar comisión" (gasto "Comisiones", nunca más de lo que se debe).
- Prendas por llegar: las 109 de la categoría "pendiente por llegar" quedaron marcadas. En Vender llevan etiqueta y solo se apartan; no se entregan hasta marcarlas "Ya llegó" (Inventario → Por llegar → "Llegaron varias", con su categoría real). Casilla en el editor de la prenda. "Ordenar categorías" para renombrar o unir.
- Foto del pago: botón en cada pago al cobrar, abonar o hacer un cambio (se sube al tomarla); ícono en el detalle para verla o agregarla después.
- Pendientes chicos hechos: límite de fiado por clienta, "Recordarle" por WhatsApp en apartados y fiados (y en la ficha de la clienta con lo que debe), "Por reembolsar" en Compras, sugerir prenda existente al recibir una caja.
- Respaldo automático diario de todas las tablas `jab_` dentro de la base (`jab_respaldo.diario`), con la lista de fotos y los correos de las cuentas.
- Decidido: los apartados no dan comisión (aunque se entreguen) porque Albany paga solo lo cobrado en el momento. Si quiere que cuenten al entregarse, es un cambio chico.
