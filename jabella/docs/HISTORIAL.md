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
