# Base de datos (Supabase)

Proyecto de Yumana: `tkkiuxaamdyfbildcvtp` (plan Pro, respaldo diario automático).
Se trabaja con el conector **`Supabase`**. **Nunca** usar el conector `Electro Montana` desde aquí: es de otro negocio.

## Qué se puede hacer sin preguntar y qué no

| Acción | ¿Hace falta el "dale" de Kinan? |
|---|---|
| Consultar (SELECT) para diagnosticar | No |
| Crear tablas, columnas, índices, funciones o políticas sin borrar nada | No, pero con respaldo antes |
| Borrar datos, DROP, TRUNCATE | **Sí** |
| Cambiar montos de créditos, abonos, facturas o saldos | **Sí** |
| Borrar un esquema de respaldo | **Sí, siempre** |

Para pedir el "dale": explicar en palabras simples qué se va a hacer y a cuántos registros afecta.

## Paso 1: respaldo antes de una tanda de cambios

1. Crear el esquema `respaldo_AAAAMMDD` (si ya existe ese día, agregar `b`, `c`...).
2. Copiar cada tabla de `public`: `CREATE TABLE respaldo_x.t AS TABLE public.t`.
3. Verificar que el número de filas coincida tabla por tabla.
4. Quitarle el acceso a `anon` y `authenticated` a ese esquema.
5. Anotar el respaldo en la lista del `CLAUDE.md` de la raíz (regla 11).

## Paso 2: hacer el cambio

- Cambios de estructura con `apply_migration`, para que queden registrados.
- **El conector se cuelga con `DELETE`.** Para quitar algo: borrado suave (`deleted_at`) o dejar la fila en $0 con una nota.
- Un `UPDATE` suelto también se puede colgar: envolverlo en un bloque `DO $$ BEGIN ... END $$;`.
- Toda corrección de dinero deja el valor de antes y el de después en `historial_auditoria`.

## Reglas de seguridad

- Toda tabla nueva: `ENABLE ROW LEVEL SECURITY` + política `solo_personal_activo` con `public.es_staff()`. **Nunca `USING (true)`**: dejaría la tabla abierta a cualquiera con la key pública.
- Las funciones `SECURITY DEFINER` llevan su propia guardia (`es_staff()`, `may_exigir_personal()`, `emp_exigir_admin()`, `est_exigir_acceso()`) y no se ejecutan para `anon`.
- Las tablas `jab_*` son de JABELLA: no se tocan desde Yumana.
- Cuentas nuevas creadas desde Créditos nacen inactivas y de solo lectura. Un admin las activa.

## Pendiente

- [PENDIENTE] Crear usuarios con una función del servidor y apagar el registro público de Supabase.
- [PENDIENTE] Kinan: activar "leaked password protection" en Supabase Auth.
- [PENDIENTE] Kinan decide si desactiva los admin que no entran desde junio.
- [PENDIENTE] Kinan decide si se desactiva la tabla vieja `inv_usuarios`.
