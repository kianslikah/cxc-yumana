# Skills instalados en el repo

Claude Code los carga solo en cada sesión (nube o local). Son instrucciones en
Markdown: no ejecutan nada, no necesitan claves ni servicios externos.

| Comando | Qué hace | Cuándo |
|---|---|---|
| `/anti-slop-audit mayorista.html` | Revisa una pantalla y reporta lo que se ve a medias (estados vacíos, textos genéricos, desvíos del estándar visual, inputs chicos). Solo lee. Se puede pedir un eje: `surface`, `craft`, `states`, `words`, `finish`. | Antes de publicar una vista nueva o rediseñada. |
| `/anti-slop-fix` | Corrige los hallazgos de la auditoría anterior, valida con `node --check`, re-audita y reporta reparado / rechazado. | Después de `/anti-slop-audit`. |
| `/thermos` | Lanza dos revisores en paralelo sobre los cambios pendientes (bugs + dinero + seguridad, y calidad) y da un veredicto: publicar / corregir antes / no publicar. Gasta dos agentes. | Antes de subir a `main` una entrega grande o que toque saldos, abonos, intereses, facturas o la base. |

Reglas que respetan los tres: reporte en español, el estándar visual del
CLAUDE.md manda (nunca proponen cambiar paleta, fuentes ni layout), un archivo
por app no es deuda, los archivos muertos del repo quedan fuera.

Origen: `anti-slop` (luantaraschi, MIT) y `thermos-claude` (theocarranza, MIT,
adaptación del rubric abierto de Cursor). Se copió solo el Markdown y se adaptó
al proyecto; no se instalaron sus hooks ni los skills `build` y `text`.
