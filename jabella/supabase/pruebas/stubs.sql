-- Simula lo mínimo de Supabase para probar la migración localmente
do $$ begin if not exists (select 1 from pg_roles where rolname=$a$anon$a$) then create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls; end if; end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub','')::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','anon') $$;
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
grant usage on schema auth, storage, public to anon, authenticated, service_role;
grant all on storage.objects to authenticated;
-- Igual que Supabase: lo nuevo en public queda con permisos para los roles de la API
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
