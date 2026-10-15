# Mudanza de JABELLA a su propia base y su propio dominio

Hoy JABELLA vive dentro del Supabase de Yumana (todo con prefijo `jab_`) y se publica en
`app.mercantilyumana.com/jabella/`. Kinan quiere, más adelante, una base y un dominio solo para Albany.
Todo está preparado para eso: nada de JABELLA depende de tablas de Yumana.

## Qué hace falta (lo pone Kinan o Albany)

1. **Cuenta de Supabase de Albany** (o un proyecto nuevo en la organización de Kinan). Plan Pro si se quiere
   el respaldo diario de Supabase y pg_cron sin límites (el plan gratis pausa el proyecto si no se usa 7 días).
2. **Dominio**: comprar uno (ej. `jabellastore.com`) y decidir dónde se publica la app:
   - GitHub Pages de un repo nuevo (`albany/jabella`), igual que hoy, o
   - Netlify/Vercel/Cloudflare Pages (gratis para este tamaño).
3. Darle a Claude el conector de Supabase del proyecto nuevo y el repo nuevo.

## Pasos (los hace Claude, en una sesión)

1. **Base nueva**: correr en orden `supabase/migrations/001` → `005`. Crear los buckets `jab-fotos` (público)
   y `jab-comprobantes` (privado) con sus políticas (vienen en las migraciones).
2. **Congelar la tienda** unos minutos (avisar a Albany y a Ana; nadie vende mientras se copia).
3. **Copiar los datos**: el respaldo de hoy de `jab_respaldo.diario` trae cada tabla en jsonb. En la base nueva,
   por cada tabla: `insert into public.jab_x select * from jsonb_populate_recordset(null::public.jab_x, <datos>)`,
   respetando el orden de las llaves (usuarios → config → cuentas → métodos → clientes → productos → variantes →
   ventas → items → pagos → …) y luego ajustar las secuencias (`setval`) al máximo id de cada tabla.
4. **Usuarias**: crear las cuentas de Auth en la base nueva con los correos del respaldo (`auth:usuarios`)
   **antes** de copiar los datos, procurando el mismo id (para que las ventas sigan a su nombre); si no se
   puede, cambiar el id viejo por el nuevo en todas las columnas `usuario_id`/`vendedora_id`/`comision_usuario_id`
   antes de cargar. Las claves no se pueden copiar: se les pone una temporal y la app les pide cambiarla al entrar.
5. **Fotos**: copiar los archivos de `jab-fotos` y `jab-comprobantes` (la lista exacta está en el respaldo,
   `storage:jab-fotos` y `storage:jab-comprobantes`), con un script que los baje de la base vieja y los suba
   a la nueva con el mismo nombre.
6. **Edge Function** `jab-usuarios`: desplegarla en el proyecto nuevo (`verify_jwt` apagado; revisa la sesión
   por dentro).
7. **App**: copiar la carpeta `jabella/` al repo nuevo y cambiar solo `js/config.js` (URL y key pública del
   proyecto nuevo). Apuntar el dominio.
8. **Verificar**: conteo de filas por tabla igual al respaldo, saldos de las cuentas (`jab_saldos_cuentas`)
   iguales, una venta de prueba anulada al final.
9. **Después de una semana sin problemas** (y con el "dale" de Kinan): quitar los objetos `jab_` de la base
   de Yumana con un respaldo previo. Mientras tanto quedan ahí, sin uso.

## Lo que NO cambia para Albany y Ana

Misma app, mismos botones, mismos datos. Solo cambia la dirección web y, una vez, la clave.
