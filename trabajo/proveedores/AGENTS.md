# Proveedores

App: `Proveedores_yumana.html` (con "yumana" en minúscula).
**No usar** `Proveedores_Yumana_App.html`: es la versión vieja que guarda en el navegador.

## Reglas

- Los saldos de las facturas los recalcula la base sola (trigger `trg_recalc_abonado`).
- Los pagos se registran con las funciones `prov_registrar_abono` y `prov_aplicar_saldo_favor`.
- Si un pago es más grande que la factura, el sobrante pasa a las otras facturas del proveedor. Si es más que toda la deuda, queda saldo a favor.
- Las devoluciones se registran como abono. Todo deja rastro en `prov_auditoria`.
- Fecha de hoy = hora de Venezuela (`hoyLocal()`).
- La forma de pago "Transferencia" se quitó a pedido de Kinan.

## Tarea 1: registrar un pago

1. Confirmar con Kinan proveedor, factura, monto, fecha y método.
2. **Revisar el monto dos veces.** Un pago de $1.971,99 escrito como $1.971.099 pagó 7 facturas por error (caso MYSTIC, 2026-10-27).
3. Si el pago deja saldo a favor, avisarle antes de guardar.

## Tarea 2: deshacer un pago equivocado

1. Usar el botón "Deshacer pago" de la app: deshace el pago completo con todas sus partes y su saldo a favor.
2. Si avisa "A MEDIAS", terminar a mano el paso que faltó (la app dice cuál).
3. [PENDIENTE] Pasarlo a una sola función de la base (`prov_deshacer_pago`, el SQL está en `docs/sql/prov_deshacer_pago.sql`). Hay que hacerlo cuando Kinan abra la sesión desde una computadora, porque el conector pide un permiso que en el iPad no aparece.

## Tarea 3: corregir fechas o montos

1. Leer los datos frescos y explicarle a Kinan qué se cambia y a cuántos registros afecta.
2. Esperar su "dale".
3. Respaldo, corrección y rastro en la auditoría.
