# Mayorista (ventas al mayor)

App: `mayorista.html`. Es la tarea que más se repite: Kinan manda clientes, notas y pagos casi todos los días.

Antes de empezar, leer en el `CLAUDE.md` de la raíz la parte "Cargar un cliente del mayor" y las reglas críticas. El detalle de cada cliente ya cargado está en `docs/HISTORIAL.md` (buscar el nombre con Grep, no leerlo completo).

## Reglas

- Los pagos se aplican a **la factura más vieja primero**. Al anular o editar, recalcular TODO el cliente (`may_recalcular_cliente`).
- Todo se hace con las funciones de la base: `may_guardar_factura`, `may_registrar_abono`, `may_anular_*`, `may_recalcular_cliente`. Nunca escribir directo en las tablas `may_*`.
- En las notas de Valery se usa el precio **P.U.$**. El sello "PAGADO/CONTADO" **no es un pago**: es solo un justificante para el traslado.
- En el cuaderno, el 1 se parece al 7. Sumar con cuidado.
- Fecha de hoy = hora de Venezuela (`hoyLocal()`), nunca UTC.
- Cédula, RIF, teléfonos, grupo de WhatsApp y dirección exacta van **solo en la base**, nunca en el repo.
- Los 9 clientes del sistema de cobros viejo se retiraron a pedido de Kinan. **No volver a cargarlos desde el respaldo.**

## Tarea 1: cargar un cliente nuevo ("Siguiente cliente...")

Kinan manda: nombre, zona, teléfono, cédula o RIF, plazo (30 o 60 días) y fotos o texto (notas de Valery, cuaderno, WhatsApp o pedido de Notas) con los abonos (monto, fecha y método).

1. Armar la cuenta y **mostrársela antes de cargar**: facturas, abonos y lo que debe.
2. Preguntar solo lo que falte.
3. Enlazar cada producto por `inv_productos.codigo_valery` (exacto; si no, un prefijo que dé un solo producto).
4. Con su "dale", un bloque `DO` por cliente, en este orden:
   1. Crear el cliente en `may_clientes`.
   2. `may_guardar_factura(p_factura, p_items)` con `origen = 'carga_inicial'`. Hacer que falle (`RAISE`) si el total no coincide.
   3. `may_registrar_abono(...)` por cada abono.
   4. `may_recalcular_cliente`.
   5. Verificar lo facturado, lo abonado y lo que debe.
5. Anotar el cliente en `docs/HISTORIAL.md` (sin datos privados) y hacer commit.
6. Si se hicieron pruebas en transacciones que se deshicieron, ajustar el número de factura: `setval('may_facturas_numero_seq', max(numero))`.

## Tarea 2: factura nueva de un cliente que ya existe

1. Leer la nota o el pedido y armar los renglones en el mismo orden de la nota.
2. Mostrarle a Kinan el total antes de guardar.
3. Guardar con `may_guardar_factura` y verificar el total.
4. Anotarla en `docs/HISTORIAL.md`.

## Tarea 3: registrar abonos

1. Confirmar monto, fecha y método de cada abono.
2. `may_registrar_abono` por cada uno.
3. Verificar que la deuda quedó como Kinan espera.

## Tarea 4: corregir la cuenta de un cliente

1. Leer la cuenta fresca de la base (facturas, abonos, anulados).
2. Explicarle a Kinan en palabras simples qué está mal y qué se va a cambiar.
3. Esperar su "dale".
4. Respaldo antes de cambiar (ver `trabajo/base-de-datos/`).
5. Corregir con las funciones `may_*` y dejar el antes y el después en `historial_auditoria`.
6. Recalcular el cliente y verificar.

## Tarea 5: pedidos que anotó la caja

La cajera autorizada (lista `may_acceso_caja`) anota pedidos **sin precio**. Kinan les pone el precio y los factura (`may_facturar_pedido`) o los descarta. Antes de tocar el modo caja, leer `docs/sql/mayorista_caja.sql`.

## Pendiente

- [PENDIENTE] Descontar el inventario real al facturar (etapa 2).
- [PENDIENTE] Lo que sigue del modo caja: ver el pendiente 17 del `CLAUDE.md` de la raíz.
