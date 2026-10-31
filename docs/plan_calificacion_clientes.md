# Calificación real de los clientes del detal (créditos y apartados)

**Estado:** hecho el 2026-10-31. Las reglas finales, ajustadas con Kinan, están en `docs/HISTORIAL.md` y en `docs/sql/calificacion_clientes.sql`. Cambian respecto de este diseño: lo de hoy solo resta, el atraso sin interés casi no castiga y con 1 cuenta terminada la nota máxima es B.

Pedido de Kinan del 2026-10-31: "sofisticar la clasificación de los clientes, si pagan bien o pagan mal, y calificarlos". Esto cubre los pendientes 2 (tope de crédito) y 16(b) (puntaje real en la ficha) de `CLAUDE.md`.

## Cómo está hoy

- **Créditos:** `clientes.score` vale **"B" en los 842 clientes**. Nunca se calculó, así que la letra que se ve en la ficha, en Cobranza y en la lista no dice nada.
- **Estadísticas:** existe un puntaje real en la base, `est_puntaje_clientes()`, que solo ve Kinan en `estadisticas.html`. Sus reglas están en `est_reglas_puntaje()`:

| Regla | Valor |
| --- | --- |
| Peso de la puntualidad | 0,7 |
| Peso del ritmo de pago | 0,3 |
| Días de gracia | 5, y después −2 puntos por día |
| Ritmo según días sin pagar | 100, 50, 20 o 0 puntos (tramos de 30, 60 y 90 días) |
| Letras | A ≥ 85, B ≥ 70, C ≥ 50 |
| Cuentas mínimas para calificar puntualidad | 2 |

## Decisiones de Kinan (2026-10-31)

1. **Lo que más pesa es la puntualidad:** terminar de pagar antes de la fecha límite.
2. **Pagar tarde con interés es "regular":** baja la nota, pero no se castiga como a un mal cliente.
3. **Cliente D o E al crear un crédito:**
   - El sistema avisa la nota y el motivo.
   - Si lo crea una cajera, el crédito queda esperando la aprobación de un admin (`pendiente_aprobacion`, que ya existe).
4. **Tope de crédito automático:** sale de lo que el cliente ya ha pagado bien antes.
5. **Cliente nuevo (N): sin tope automático** (Kinan, 2026-10-31). Cada cliente es diferente y depende del fiador, así que decide el admin. El sistema solo muestra que es nuevo y quién es su fiador.

## Diseño propuesto

### Nota de 0 a 100, con letra y nombre

| Letra | Puntos | Nombre |
| --- | --- | --- |
| A | 85 o más | Excelente |
| B | 70 a 84 | Bueno |
| C | 50 a 69 | Regular |
| D | 30 a 49 | Riesgoso |
| E | menos de 30 | No darle crédito |
| N | — | Nuevo, sin historial suficiente |

### Factores

Son pesos sugeridos para ajustar con Kinan. Salen solo de datos que ya existen: créditos, apartados, abonos e intereses.

| Factor | Peso | Qué mide |
| --- | --- | --- |
| Puntualidad | 45% | En cada cuenta cerrada, los días que terminó de pagar antes o después de la fecha límite, con 5 días de gracia |
| Atraso de hoy | 20% | Deuda vencida hoy y cuántos días lleva vencida |
| Constancia | 15% | Cada cuánto abona y cuántos días lleva sin pagar |
| Intereses | 10% | Cuántas veces se le cobró interés por atraso; un interés perdonado pesa menos |
| Historial | 10% | Cuentas terminadas, total pagado y antigüedad como cliente |

Hay dos casos que no pasan por los pesos:
- Si **nunca pagó nada y tiene una cuenta vencida**, queda en E directo.
- Si el cliente está **disputado**, se marca aparte.

### Razones

Cada nota trae 2 a 4 frases que la explican. Por ejemplo: "Pagó 5 de 6 cuentas a tiempo" o "Tiene $120 vencidos hace 40 días".

### Tope automático

- La base es lo más alto que el cliente ha pagado completo antes.
- Esa base se multiplica según la letra: A × 1,5, B × 1,2, C × 1,0, D × 0,5, E × 0.
- Al resultado se le resta lo que debe hoy.
- **Un cliente N no tiene tope automático:** se muestra "Nuevo: decide el admin según el fiador".

## Dónde vive

- **Una sola función de origen en la base:** se extiende o reemplaza `est_puntaje_clientes()`. La usan Créditos y Estadísticas, para que las dos digan lo mismo, y `est_reglas_puntaje()` se actualiza.
- **Créditos:**
  - La letra real sale en la ficha del cliente, en Cobranza y en la lista de clientes.
  - En la ficha, también la nota, las razones y el tope.
- **Al crear un crédito:**
  - Se muestran la nota, el tope y lo que debe el cliente.
  - Si es D o E, o si supera el tope:
    - con una cajera, el crédito queda en `pendiente_aprobacion` (hoy toda solicitud de cajera ya queda así: verificarlo);
    - con un admin, solo se avisa.
  - **En la pantalla de aprobar solicitudes** se muestran la nota, las razones, el tope y el fiador, para que el admin decida con todo a la vista.
- **`clientes.score`:** o se llena desde la función, o se deja de usar. Nunca puede volver a quedar una letra fija.

## Reglas para hacerlo

- No cambia ningún monto: solo lee y califica.
- Respaldo completo antes de crear o cambiar funciones. Usar `apply_migration`. Sin `DELETE`.
- **Revisar los resultados con Kinan:** mostrarle 10 clientes que él conozca bien (buenos y malos) con su nota y sus razones, y ajustar los pesos hasta que cuadre con lo que él sabe.
- Antes de publicar:
  - `/thermos`, que lo escribe Kinan, porque decide quién recibe crédito;
  - `/anti-slop-audit` en las vistas que cambian.
