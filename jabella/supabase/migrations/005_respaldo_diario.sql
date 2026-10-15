-- =====================================================================
-- JABELLA: respaldo automático diario de todas sus tablas (además del respaldo diario de Supabase).
-- En producción: jabella_06_respaldo_diario (antes de la 004) y jabella_08_respaldo_comprobantes.
-- Una fila por tabla y por día con todas sus filas en jsonb. Nada se borra: si corre dos veces el
-- mismo día, se actualiza la copia de ese día. Esquema cerrado (solo el dueño de la base lo lee).
-- Al mudar JABELLA a su propia base, cada fila de jab_respaldo.diario se puede volver a cargar con
-- jsonb_populate_recordset.
-- =====================================================================
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

create schema jab_respaldo;
revoke all on schema jab_respaldo from public, anon, authenticated;

create table jab_respaldo.diario (
  fecha date not null,
  tabla text not null,
  filas int not null,
  datos jsonb not null,
  creado_en timestamptz not null default now(),
  primary key (fecha, tabla)
);
revoke all on table jab_respaldo.diario from public, anon, authenticated;

create or replace function jab_respaldo.respaldar() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_hoy date := (now() at time zone 'America/Caracas')::date;
  v_filas int;
  v_datos jsonb;
  n int := 0;
  b text;
begin
  for r in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'r' and c.relname like 'jab\_%' order by c.relname loop
    execute format('select count(*)::int, coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', r.relname)
      into v_filas, v_datos;
    insert into jab_respaldo.diario (fecha, tabla, filas, datos) values (v_hoy, r.relname, v_filas, v_datos)
    on conflict (fecha, tabla) do update set filas = excluded.filas, datos = excluded.datos, creado_en = now();
    n := n + 1;
  end loop;
  -- Qué fotos existen (los archivos viven en los buckets, que no permiten borrar)
  foreach b in array array['jab-fotos', 'jab-comprobantes'] loop
    insert into jab_respaldo.diario (fecha, tabla, filas, datos)
    select v_hoy, 'storage:' || b, count(*),
           coalesce(jsonb_agg(jsonb_build_object('name', name, 'size', metadata->>'size', 'creado', created_at) order by name), '[]'::jsonb)
      from storage.objects where bucket_id = b
    on conflict (fecha, tabla) do update set filas = excluded.filas, datos = excluded.datos, creado_en = now();
  end loop;
  -- Correos de las cuentas de JABELLA (para poder rehacer los usuarios)
  insert into jab_respaldo.diario (fecha, tabla, filas, datos)
  select v_hoy, 'auth:usuarios', count(*),
         coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'email', a.email, 'creado', a.created_at)), '[]'::jsonb)
    from auth.users a where a.id in (select id from public.jab_usuarios)
  on conflict (fecha, tabla) do update set filas = excluded.filas, datos = excluded.datos, creado_en = now();
  return n;
end $$;
revoke execute on function jab_respaldo.respaldar() from public, anon, authenticated;

-- Todos los días a las 2:30 a. m. de Venezuela (06:30 UTC)
select cron.schedule('jabella-respaldo-diario', '30 6 * * *', $$select jab_respaldo.respaldar()$$);

-- Primera copia ahora mismo
select jab_respaldo.respaldar();
