# Créditos y apartados (detal)

App: `Apartados_Yumana_App.html`. Es la app más grande (~9.800 líneas) y la más crítica.
**No usar** `CxC_Yumana_App.html`, `Apartados_Yumana.html` ni `Apartados_v2.html`: son versiones viejas, muertas.

No leer la app completa. Buscar con Grep la función que hace falta y leer solo ese tramo.

## Reglas de dinero (romper una cuesta plata)

1. `monto_total` **ya incluye el interés**. Saldo = `monto_total − pagado`. Nunca sumar el interés aparte.
2. Interés: 10% compuesto sobre el saldo, en `intereses_aplicados.monto_interes`. Fecha = fecha del crédito + N meses (N = intereses previos + 1).
3. **Nunca restar sobre datos en memoria.** Leer el registro fresco de la base. Mejor: reconstruir desde la fuente (subtotal + intereses vivos). Por no hacerlo se descuadraron los créditos #124 y #111.
4. El "pago a la cuenta" se reparte a lo **más viejo primero**.
5. Todo botón de guardar usa `protegerBoton()` (un doble toque ya causó un descuadre de $17).
6. Supabase corta en 1.000 filas sin avisar: paginar siempre (`traerTodoBD`).
7. Borrado suave: `deleted_at IS NULL` = activo.

Helpers que ya existen (usar, no rehacer): `traerTodoBD`, `redondear2`, `saldoFrescoCuenta`, `reconstruirTotalCuenta`, `recalcularSaldoCuenta` / `recalcularOAvisar`, `esDeudaViva`, `marcarPartesGrupo`, `confirmAction`.

## Tarea 1: un saldo no cuadra

1. Leer de la base el crédito, sus abonos y sus intereses vivos.
2. Usar el "Verificar cuadre" de la app o reconstruir el total a mano.
3. Explicarle a Kinan la diferencia, con montos y fechas.
4. Con su "dale": respaldo, corrección y rastro del antes y el después en `historial_auditoria`.

## Tarea 2: perdonar o quitar un interés

1. Nunca borrarlo: dejarlo en $0 con una nota que explique por qué.
2. Reconstruir el total de la cuenta y verificar el saldo.

## Tarea 3: cambio en la app

Seguir los pasos de `trabajo/apps/`. Como toca dinero, correr `/thermos` antes de publicar.

## Datos

- Calificación de clientes y tope de crédito: las reglas viven en la base, en `cli_reglas_calificacion()`. Para cambiar una nota se cambia ahí, sin tocar la app. Diseño en `docs/plan_calificacion_clientes.md`.
- Los clientes nuevos (N) no tienen tope automático: decide el admin según el fiador.
