# Fase 1, paso 1: app Personal (vales, deudas y pago del sábado)

Pedido de Kinan del 2026-10-28. Es el primer paso del plan para sistematizar la tienda (pendiente 19 de `CLAUDE.md`).

**Estado:** la versión 1 (puntos 1 a 5, con los avisos al teléfono) se hizo el 2026-10-28. Detalle en `docs/HISTORIAL.md`.

**Datos de los empleados** (nombres, cargos, teléfonos, sueldos, turnos y domingos): están en el documento del plan, secciones "Equipo de hoy" y "Pago de hoy". Se leen con el conector de Claude Docs. **No copiarlos a este repo, que es público.** Se cargan solo en la base.

## El problema

- Los empleados piden vales de $5 o $10 durante la semana.
  - Kinan los anota en el WhatsApp de cada empleado.
  - Si él no está, Fayssal o Bassma los anotan en otro lado, y Kinan tiene que buscarlos.
- La mayoría de los empleados le debe dinero a la tienda.
  - Esas deudas no están en Créditos (se revisó el 2026-10-28).
  - Hoy Kinan pregunta uno por uno cuánto descontar.
- Regla de Kinan:
  - Lo ideal es que nadie saque vales. Si alguien saca, queda anotado sí o sí.
  - Cada vale le llega como aviso al teléfono en el momento (opción A), por ejemplo: "Bassma le dio $10 a Javier".
- Hoy se paga cada semana, los sábados casi al cierre, en dólares. **Desde enero será cada quincena.**

## Qué hace la versión 1

App `personal.html`, con una tarjeta nueva en el portal. La usan solo los admin activos: Kinan, Fayssal, Bassma Al Chibani y Rami.

1. **Empleados.** Cada uno con:
   - Nombre, cargo y teléfono.
   - Sueldo del período en USD y extra por domingo trabajado.
   - Si está activo.
   - Sus reglas especiales:
     - Hay quien cobra lo mismo trabaje o no el domingo.
     - Hay quien tiene otro sueldo base.
     - A Mariagny se le descuenta el sábado que no va: sueldo ÷ 6.
     - Lixney cobra 1% de la venta online ya cobrada, sin créditos.
2. **Cuenta de cada empleado.**
   - Muestra sus vales y sus deudas (compra o préstamo, con la cuota que se descuenta en cada pago) y los descuentos ya aplicados.
   - Lo que debe = deudas + vales − descuentos.
3. **Registrar un vale** en dos toques desde el teléfono.
   - Queda a nombre de quien lo da y con la hora de Venezuela.
   - El botón usa `protegerBoton()`.
4. **Pago del sábado.** Por cada empleado se calcula:

   | Concepto | De dónde sale por ahora |
   | --- | --- |
   | + sueldo | Ficha del empleado |
   | + domingos trabajados | Se marcan a mano hasta que exista la asistencia |
   | − días que no fue | Sueldo ÷ 6 por cada día |
   | + comisión | El 1% de Lixney se pone a mano hasta que exista la venta online |
   | − vales del período | Cuenta del empleado |
   | − cuota de deuda | Cuenta del empleado; se puede cambiar |
   | **= a pagar** | |

   - Al cerrar el pago queda todo guardado en una función atómica (RPC).
   - Sale el recibo por WhatsApp para cada empleado.
5. **Aviso de cada vale al teléfono de Kinan.** Puede ir en una segunda entrega.
   - Es una notificación web push: el portal se agrega a la pantalla de inicio del iPhone.
   - Lleva un service worker y una Edge Function.
   - La clave privada VAPID va como secreto de Supabase, nunca en el repo.

**El período tiene que ser configurable** (semana o quincena), porque desde enero el pago es quincenal.

## Base de datos

- **Tablas:**
  - `emp_empleados`.
  - `emp_movimientos`, con:
    - tipo: vale, deuda, descuento o ajuste;
    - monto, fecha, nota;
    - `registrado_por` y `pago_id`;
    - `deleted_at`.
  - `emp_pagos`, con:
    - período y empleado;
    - sueldo, domingos, días descontados, comisión, vales, cuota y total;
    - `pagado_por`.
- **RLS:** solo admin activo (`es_admin()`); nunca `USING (true)`.
  - Las funciones `SECURITY DEFINER` llevan su propia guardia y no se pueden ejecutar desde `anon`.
- **Borrado suave** (`deleted_at`). No usar `DELETE`:
  - El conector pide un permiso que desde el iPad no aparece, y se cuelga.
  - Un vale mal puesto se anula con rastro.
- **Antes de crear:** respaldo completo (`respaldo_AAAAMMDD`).
- **Antes de publicar:**
  - `/thermos`, que lo escribe Kinan, porque toca dinero.
  - `/anti-slop-audit` en la vista nueva.
  - Estándar visual del Portal.

## Lo que falta de Kinan

- Cuánto debe hoy cada empleado y cuánto descontarle cada sábado.
- Pregunta 4 del plan: ¿marcar asistencia con el teléfono de cada uno o con una tablet fija? ¿Con foto?
