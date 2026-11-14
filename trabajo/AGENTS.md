# Carpetas de trabajo de Mercantil Yumana

Guía para cualquier asistente de IA (Claude, Codex u otro) que ayude a Kinan.
Cada carpeta es un tipo de tarea que se repite. Entra a la carpeta de la tarea y lee su `AGENTS.md` antes de empezar.

El contexto completo del sistema (apps, base de datos, reglas críticas) está en el `CLAUDE.md` de la raíz del repo. **Ese archivo manda.** Si algo de aquí choca con él, gana el de la raíz.

## Qué hay en cada carpeta

| Carpeta | Para qué |
|---|---|
| `mayorista/` | Ventas al mayor: cargar un cliente nuevo, facturas, abonos, corregir una cuenta, estado por WhatsApp |
| `creditos/` | Créditos y apartados del detal: saldos, intereses, cobranza, cuadre |
| `proveedores/` | Facturas y pagos a proveedores |
| `personal/` | Empleados: vales, deudas y el pago del sábado |
| `apps/` | Cambiar o crear una app del ecosistema y publicarla |
| `base-de-datos/` | Trabajar directo en Supabase: respaldos, consultas y cambios |
| `planes/` | Planes y decisiones de la tienda antes de construir algo |

JABELLA Store (la tienda de ropa de Albany) tiene su guía en `jabella/AGENTS.md`. Es un negocio aparte: no se mezcla con Yumana.

Electro Montana NO se trabaja desde este repo. Tiene su propio repositorio, su propia base y su propio conector.

## Reglas de Kinan que valen en todas las carpetas

1. **Español siempre.** Pasos exactos y concretos, sin teoría.
2. Kinan no es programador y trabaja desde iPad o iPhone. Entregarle cosas funcionando, no explicaciones técnicas.
3. **Es producción con dinero real.** No hay ambiente de pruebas. Un error de saldo es plata perdida.
4. **Diagnosticar antes de proponer.** Si algo falla, ir al código y a los datos. No mandarlo a probar a ciegas.
5. Cuestionar lo que no cuadre. No aprobar todo.
6. **Agrupar varios cambios en una sola entrega.** No hacer un ciclo de probar y subir por cada cambio chico.
7. Decir claramente cuándo termina una tarea y cuándo empieza otra.
8. **Una sesión por tarea.** Kinan paga por uso: no leer archivos enormes completos, buscar por partes.
9. **El repo es público.** Nunca escribir aquí claves, contraseñas, cédulas, RIF, teléfonos, direcciones ni datos de empleados. Esos datos van solo en la base.
10. Si falta información, preguntar o escribir `[PENDIENTE]`. Nunca inventar montos, fechas ni nombres.
