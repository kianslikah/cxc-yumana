# Mapa de operaciones: cómo editarlo

`mapa_yumana.html` (raíz del repo) va **cifrado**: el repo es público y el mapa tiene cifras del negocio y nombres del personal. La clave **no** está en el repo (la tiene Kinan).

Piezas: `shell.html` (marcado y estilos, sin datos) + 5 scripts que solo existen cifrados: `layout.js` (plano y medidas), `contenido.js` (análisis, protocolos, supuestos), `graficos.js`, `escena.js` (3D, Three.js r128) y `ui.js`.

1. Sacar las piezas: `MAPA_CLAVE='xxxx-xxxx-xxxx-xxxx' node herramientas/mapa/descifrar.js` → quedan en `herramientas/mapa/build/` (ignorada por git: **nunca subirla**).
2. Editar las piezas en `build/` (o `shell.html`).
3. Mirarlo en local sin cifrar (opcional): `node herramientas/mapa/armar.js` → arma el HTML en la carpeta temporal del sistema; se niega a escribir dentro del repo.
4. Volver a cifrar: `MAPA_CLAVE='…' node herramientas/mapa/cifrar.js` → reescribe `mapa_yumana.html` (valida con `node --check`).
5. Antes de subir: `git status` no debe mostrar nada de `build/`, y `grep -c Kinan mapa_yumana.html` debe dar 0. Subir la versión del Portal (`?v=` en `portal_apps.url` de `mapa`).
