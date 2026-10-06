---
name: thermos
description: "Revisión doble antes de publicar: lanza en paralelo los dos subagentes thermo-nuclear (bugs/seguridad/dinero y calidad/mantenibilidad) sobre los cambios pendientes o el último commit, y sintetiza un solo veredicto en español. Usar antes de subir una entrega grande a main."
disable-model-invocation: true
metadata:
  origen: "https://github.com/theocarranza/thermos-claude (adaptación Claude Code del plugin Thermos de Cursor), adaptado para Mercantil Yumana"
---

# Thermos (Mercantil Yumana)

Corre los dos revisores thermo-nuclear como subagentes en segundo plano, en
paralelo, y junta sus resultados en un solo veredicto. **Solo lee: no edita
archivos, no hace commit, no toca la base de datos.**

## Cuándo usarlo

Antes de publicar a `main` una entrega grande (nueva vista, cambio en cálculo
de saldos, abonos, intereses, facturas, reparto de pagos, migración). Para un
cambio chico (un texto, un color) no hace falta: gasta dos agentes.

## Flujo

1. **Alcance.** Aquí se publica directo a `main`, así que el diff normal es:
   - los cambios sin commitear: `git diff` + `git diff --cached` (+ archivos
     nuevos con `git status --porcelain`), o
   - si ya se commiteó y no se ha publicado: `git diff origin/main...HEAD`, o
   - si Kinan nombra un commit: `git show <sha>`.
   Decir cuál se eligió antes de lanzar nada. Si no hay cambios, decirlo y parar.
2. **Recoger el diff con Bash** y escribirlo a un archivo del scratchpad
   (`diff_thermos.patch`) junto con la lista de archivos tocados y los
   mensajes de commit. Los archivos de las apps tienen miles de líneas: pasar
   la **ruta** del patch, no pegarlo.
3. **Lanzar los dos revisores en un solo mensaje** con la herramienta Agent y
   `run_in_background: true`:
   - `subagent_type: "thermo-nuclear-review-subagent"` → bugs, roturas de
     funciones existentes, seguridad, **errores de dinero**.
   - `subagent_type: "thermo-nuclear-code-quality-review-subagent"` →
     mantenibilidad, duplicación, espagueti, helpers que ya existen.
4. **Darles a los dos el mismo contexto:** ruta del patch, archivos cambiados,
   commits, y el bloque "Reglas de la casa" de abajo pegado completo. Pedirles
   hallazgos priorizados con `archivo:línea` y evidencia, leyendo el código
   alrededor en vez de adivinar. Pedir el reporte **en español**.
5. **Sintetizar** cuando terminen: hallazgos primero, sin duplicados; lo que
   los dos encontraron pesa más; desacuerdos se resuelven con criterio propio.
   Terminar con un veredicto claro: **Publicar / Publicar después de corregir X
   / No publicar**, y la lista de lo que hay que corregir antes.
6. Si un revisor se interrumpe o no devuelve nada, decirlo. Nunca presentar una
   corrida a medias como revisión completa ni inventar lo que diría.

## Reglas de la casa (pegar completas a los dos subagentes)

Contexto: apps web internas de Mercantil Yumana (tienda en Socopó, Venezuela).
HTML/CSS/JS puro, **un archivo por app, sin build ni framework**, publicado en
GitHub Pages; backend Supabase (PostgreSQL + Auth, cliente JS en el HTML).
**Producción con dinero real, sin ambiente de pruebas.** Usuarios: el dueño
desde iPad/iPhone y una cajera en una PC con Windows 7.

Reglas de dinero (romper una cuesta plata; un hallazgo aquí es alta prioridad):
- `monto_total` **ya incluye el interés**. Saldo = `monto_total − monto_pagado`
  (apartados: `monto_abonado`). Nunca sumar el interés aparte.
- **Nunca restar ni ajustar sobre datos en memoria.** Al eliminar o editar
  montos, leer el registro fresco de la base o reconstruir desde la fuente de
  verdad (productos reales + intereses vivos). Toda operación de saldo debe
  ser idempotente.
- **Anti doble clic obligatorio:** todo botón que guarde usa `protegerBoton()`
  o un candado equivalente.
- **Reparto de pagos a lo más viejo primero** (mayorista y "pago a la cuenta"
  de créditos). Al anular o editar, recalcular todo el cliente desde cero.
- **Supabase corta en 1000 filas en silencio:** toda consulta que pueda pasar
  de 1000 pagina con `.range()` en bucle (`traerTodo` / `traerTodoBD`).
- **Borrado suave:** `deleted_at IS NULL` = activo. Todo filtro de saldo,
  suma o lista debe excluir eliminados.
- **Tablas nuevas nacen bloqueadas por RLS:** una tabla nueva sin
  `ENABLE ROW LEVEL SECURITY` + política = la app no lee nada.
- Correcciones de montos dejan rastro en `historial_auditoria`.
- Interés: 10% compuesto sobre el saldo, fecha = fecha del crédito + N meses.
- Redondear a 2 decimales (`redondear2`) al guardar montos.

Reglas de seguridad y plataforma:
- El repo es **público**: ninguna clave secreta en el código ni en commits;
  solo la key *publishable* de Supabase puede ir en los HTML.
- iOS Safari: inputs ≥16px (si no, hace zoom), `input[type=date]` con
  `-webkit-appearance:none; width:100% !important`.
- Caché agresiva: si cambia una app, el portal versiona su URL (`?v=`).
- Rendimiento en la PC vieja: buscadores con `debounce`, listas por partes
  (80 + "Mostrar más"), no cargar librerías pesadas al abrir.

Lo que **no** es hallazgo aquí (evita falsos positivos):
- **Archivos de miles de líneas.** `Apartados_Yumana_App.html` tiene ~10.000 y
  `mayorista.html` ~2.400 **por decisión de diseño** (un archivo por app, sin
  build). La regla de "no pasar de 1.000 líneas" **no aplica**; sí aplica
  evitar duplicar un helper que ya existe en el mismo archivo.
- `var`, funciones globales, `innerHTML` con `prEsc`/escape, `confirm()` y
  `prompt()` nativos: son el idioma del proyecto, no deuda nueva.
- Español en nombres de funciones, variables y comentarios: es la norma.
- Emojis dentro de los mensajes de WhatsApp al cliente: se conservan a propósito.
- Los archivos muertos del repo (`CxC_Yumana_App.html`, `Apartados_Yumana.html`,
  `Apartados_v2.html`, `Proveedores_Yumana_App.html`, `Diagnostico.html`,
  `TestLogin.html`, `Cargador.html`, `subir fotos.html`) están fuera de alcance.
- Sin feature flags, sin paquetes, sin CI: las secciones de "devex" y "feature
  leaks" del rubric casi nunca aplican; si no hay nada, decirlo en una línea.

## Reporte

Si los resúmenes de los subagentes ya se ven en pantalla, no repetirlos:
dar el veredicto unificado, los hallazgos de más peso y lo que quedó sin
confirmar. Todo en español, directo, sin teoría.
