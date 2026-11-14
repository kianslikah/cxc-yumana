# Planes de la tienda

Aquí se piensa **antes** de construir. Los documentos de los planes viven en `docs/` (no se mueven):

| Plan | Archivo | Estado |
|---|---|---|
| Calificación de clientes y tope de crédito | `docs/plan_calificacion_clientes.md` | Hecho el 2026-10-31 |
| App Personal (vales, deudas, pago del sábado) | `docs/plan_personal_vales.md` | Versión 1 hecha el 2026-10-28 |
| Ventas de contado (app nueva `ventas.html`) | `docs/plan_ventas_contado.md` | [PENDIENTE] Por construir |
| Sistematizar la tienda en 6 fases | Documento en claude.ai (enlace en el pendiente 19 del `CLAUDE.md` de la raíz) | Fase 1 en curso |

Las 6 fases: (1) bases: un usuario por empleado y catálogo con costos; (2) el día de la tienda: entrada y salida, checklist, caja diaria con cierre; (3) venta de contado con vendedor; (4) inventario real y entregas; (5) nómina, comisiones, permisos y gastos; (6) ficha única del cliente, garantías y ganancia real. Cada fase corre en paralelo con el papel 1 o 2 semanas antes de dejarlo.

## Pasos para armar un plan nuevo

1. Escuchar qué quiere Kinan y cuál es el problema de hoy (cómo se hace ahora, quién lo hace).
2. Revisar qué ya existe en el código y en la base. No proponer rehacer lo que ya está.
3. Escribir el plan en `docs/plan_<tema>.md`: el problema, las decisiones de Kinan, cómo se va a usar, qué tablas y pantallas, y las preguntas que faltan.
4. Hacerle a Kinan solo las preguntas que cambian el diseño. Lo que falte queda como `[PENDIENTE]`.
5. Cuando Kinan lo apruebe, construir en una sesión aparte siguiendo `trabajo/apps/`.
6. Al terminar, marcar el pendiente como hecho en el `CLAUDE.md` de la raíz.

## Reglas

- Los datos de los empleados y de los clientes van solo en el documento privado y en la base, nunca en estos archivos.
- Valery queda solo para la factura legal. La visión a 2-3 meses: el ciclo completo del producto con ganancia (pendiente 11 del `CLAUDE.md` de la raíz).
- [PENDIENTE] Importar el catálogo desde Valery con costo y existencia (sin costos no hay ganancia). Kinan puede exportarlo.
