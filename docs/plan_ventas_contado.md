# Ventas de contado en el ecosistema (sin inventario todavía)

Pedido de Kinan del 2026-10-31. Adelanta la fase 3 del plan de la tienda (pendiente 19 de `CLAUDE.md`), pero sin tocar el inventario: el inventario se organiza aparte y se conecta después.

## El problema

Hoy lo que se vende de contado solo queda en Valery. El ecosistema no sabe qué se vende, quién lo vende ni cuánto se gana. Kinan quiere empezar la semana del 2026-11-02 para que todos se acostumbren al sistema.

## Decisiones de Kinan

1. **La cajera registra la venta en el momento de facturar.** No la arma el vendedor en el piso.
2. **Valery sigue para la factura fiscal**, que es rápida. Nuestro sistema registra la venta para tener el dato. No se usa la nota de venta de Valery, que es lenta al imprimir.
3. **Se imprime una orden en la ticketera de 80 mm de la caja** (ya existe). Es para que se la lleve el cliente y como registro de la venta.
4. **Sin inventario:** la venta no descuenta existencias.
5. **Ganancia:** Kinan pasa un Excel de Valery con los productos (código, descripción, precio, **costo** y existencia). Es el pendiente 10. El costo se guarda en cada renglón al vender, como foto del costo de ese día, para que la ganancia de una venta vieja no cambie si después cambia el costo.

## Cómo trabaja la cajera

Meta: menos de 30 segundos más por venta.

1. Busca el producto por **código de Valery o por nombre**. Enter lo agrega con cantidad 1 y el precio del catálogo, que se puede cambiar.
2. Elige **quién vendió** con botones (los empleados que venden).
3. Elige **cómo pagó**: un método o mixto, repartiendo el total entre varios. Usa los mismos nombres de método que Créditos.
4. Opcional: **cliente** (nombre, cédula y teléfono) y **número de factura de Valery**.
5. **Guardar** registra la venta e imprime el ticket en un segundo. Es HTML y `window.print`, como los recibos de 80 mm de Créditos; no es un PDF. Lleva:
   - el encabezado de Mercantil Yumana;
   - "ORDEN DE VENTA #N", la fecha y la hora;
   - el vendedor y la cajera;
   - los productos en el orden de la casa: Cantidad → Producto (con su código de Valery) → Precio → Subtotal;
   - el total, la forma de pago y la factura de Valery, si se anotó.
6. Después factura en Valery como hoy, copiando los códigos del ticket.

Además:
- **Ventas del día:** lista con el total por forma de pago. Es la base del cierre de caja de la fase 2.
- **Anular una venta:** solo un admin, con motivo, borrado suave y rastro.

## Base de datos (a revisar en la sesión que lo construya)

- **Tablas:**
  - Reusar `inv_ventas` y `inv_venta_items`. Hoy tienen 7 ventas de prueba de junio de `Venta_prueba.html`, que hay que marcar como prueba o ignorar.
  - Agregar quién vendió, los pagos repartidos, la anulación (quién, cuándo y por qué) y, en cada renglón, `costo_unitario`.
- **Función:** una función atómica nueva para registrar la venta, con guardia `es_staff()` y número de orden seguido.
  - No usar el guardado de `Venta_prueba.html`: inserta en pasos sueltos (si falla a mitad, queda incompleta) y descuenta inventario.
  - Revisar si `inv_registrar_venta` sirve o se reemplaza.
- **Seguridad:** RLS con `es_staff()`. Botón con `protegerBoton()`. Hora de Venezuela.

## Pantallas

- **`ventas.html`:** app nueva con el estilo iPhone y los colores del ecosistema (ver `CLAUDE.md`).
  - Tarjeta en el portal para admin y cajera.
  - Pensada para la PC de la caja: teclado primero, buscador con `debounce` y catálogo cargado una vez.
- **`Venta_prueba.html`:** pasa a ser un archivo muerto.
- **Estadísticas:** nueva sección "Ventas de contado" con:
  - lo vendido y la ganancia (cuando haya costo);
  - por vendedor, por producto, por forma de pago, por día y por hora;
  - lo más vendido.
  
  Es la que hoy está "preparada" en "Inventario y ventas".

## Lo que falta de Kinan

- El Excel de Valery con los productos y su costo.
- Confirmar quiénes venden (para los botones) y las formas de pago que se usan en la caja.
