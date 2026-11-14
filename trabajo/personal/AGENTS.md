# Personal (empleados)

App: `personal.html`. Vales, deudas de los empleados y el pago del sábado. La usan solo los admin.

Especificación: `docs/plan_personal_vales.md`. SQL de referencia: `docs/sql/personal.sql`.

## Reglas

- **Los datos de los empleados (nombres, cargos, teléfonos, sueldos) van solo en la base y en el documento del plan.** Nunca en este repo, que es público.
- Las tablas de dinero (`emp_movimientos`, `emp_pagos`) solo se escriben con las funciones `emp_*`:
  - `emp_registrar_movimiento`: vale, deuda, descuento o ajuste.
  - `emp_anular_movimiento`: con motivo. No deja anular algo que ya entró en un pago.
  - `emp_cerrar_pago`: el pago del período.
  - `emp_anular_pago`: los vales vuelven a quedar sin descontar.
- Cuenta de cada empleado (`emp_cuentas()`): debe = deudas + vales + ajustes − descuentos.
- Pago = sueldo + domingos × extra − días que no vino − vales − cuota de la deuda (+ % de la venta online si aplica).
- Cada vale avisa al teléfono de los admin. El service worker de esta app es `sw_personal.js` y su alcance es **solo** `personal.html`. Nunca registrar otro service worker en la raíz: ahí vive el de Créditos.
- Hoy se paga cada semana, los sábados. **Desde enero será cada quincena** (`emp_config`).

## Tarea 1: cargar las deudas de los empleados

1. Kinan pasa la deuda de cada uno.
2. Mostrarle la lista antes de cargar.
3. Cargar con `emp_registrar_movimiento` (tipo deuda).
4. Verificar con `emp_cuentas()`.

## Tarea 2: un pago no cuadra

1. Leer los movimientos y los pagos del empleado.
2. Explicarle a Kinan la cuenta paso a paso.
3. Corregir solo con las funciones `emp_*` y con su "dale".

## Pendiente

- [PENDIENTE] Las deudas de cada empleado (Kinan las pasa).
- [PENDIENTE] La asistencia (pregunta 4 del plan de la tienda). Va a reemplazar los domingos y los días que hoy se marcan a mano.
