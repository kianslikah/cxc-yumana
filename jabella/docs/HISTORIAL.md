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
