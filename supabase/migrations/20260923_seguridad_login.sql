-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Seguridad del login
--
-- Antes: el PIN se comprobaba en el navegador y todas las tablas tenían
-- una política "true" → cualquiera con la URL podía leer los PINs y
-- leer/modificar/borrar cualquier dato.
--
-- Ahora:
--   · Los PINs se guardan cifrados (bcrypt) en un esquema privado que la
--     API no expone. La columna sdr_users.pin desaparece.
--   · El login se valida en el servidor (rpc sdr_login) y devuelve un
--     token de sesión que caduca. La app lo envía en la cabecera
--     "x-sdr-token" en cada petición.
--   · Bloqueo tras 5 PINs fallidos (15 min; 24 h a partir de 10).
--   · RLS real: sin sesión no se lee ni se escribe nada; cada SDR solo
--     modifica lo suyo; lo de configuración solo lo toca un manager.
--   · El rol (sdr/manager) sale siempre de la base de datos, no del
--     navegador.
--
-- Solo afecta a las tablas del SDR Hub. Las demás tablas del proyecto
-- no se tocan.
--
-- Para poner o resetear un PIN desde el SQL editor de Supabase:
--   select sdr_private.set_pin(<id_usuario>, '1234');
-- ════════════════════════════════════════════════════════════════════

begin;

-- ── Esquema privado (no expuesto por la API REST) ──
create schema if not exists sdr_private;
revoke all on schema sdr_private from public;
grant usage on schema sdr_private to anon, authenticated;

create table if not exists sdr_private.credenciales(
  user_id bigint primary key references public.sdr_users(id) on delete cascade,
  pin_hash text not null,
  intentos_fallidos int not null default 0,
  bloqueado_hasta timestamptz
);

create table if not exists sdr_private.sesiones(
  token uuid primary key default gen_random_uuid(),
  user_id bigint not null references public.sdr_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '16 hours'
);
create index if not exists sesiones_user_idx on sdr_private.sesiones(user_id);

revoke all on all tables in schema sdr_private from public, anon, authenticated;

-- ── Migrar los PINs actuales a hash y eliminar la columna en claro ──
insert into sdr_private.credenciales(user_id, pin_hash)
select id, extensions.crypt(pin, extensions.gen_salt('bf'))
from public.sdr_users
where pin is not null and pin <> ''
on conflict (user_id) do nothing;

alter table public.sdr_users drop column if exists pin;

-- ── Helpers de sesión ──
create or replace function sdr_private.request_token() returns uuid
language plpgsql stable set search_path = '' as $$
declare t text;
begin
  t := nullif(current_setting('request.headers', true), '')::json ->> 'x-sdr-token';
  if t is null or t !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;
  return t::uuid;
end $$;

create or replace function sdr_private.current_user_id() returns bigint
language sql stable security definer set search_path = '' as $$
  select s.user_id
  from sdr_private.sesiones s
  join public.sdr_users u on u.id = s.user_id and u.activo
  where s.token = sdr_private.request_token()
    and s.expires_at > now()
$$;

create or replace function sdr_private.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.sdr_users
    where id = sdr_private.current_user_id() and rol = 'manager'
  )
$$;

create or replace function sdr_private.set_pin(p_user_id bigint, p_pin text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_pin !~ '^\d{4}$' then
    raise exception 'El PIN debe tener 4 dígitos';
  end if;
  insert into sdr_private.credenciales(user_id, pin_hash)
  values (p_user_id, extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, intentos_fallidos = 0, bloqueado_hasta = null;
end $$;

revoke all on all functions in schema sdr_private from public;
grant execute on function sdr_private.request_token(), sdr_private.current_user_id(), sdr_private.is_manager()
  to anon, authenticated;

-- ── RPCs públicas (lo único que se puede llamar sin sesión es login_names y login) ──

-- Lista de nombres para el desplegable del login (sin datos sensibles)
create or replace function public.sdr_login_names()
returns table(id bigint, nombre text, rol text)
language sql stable security definer set search_path = '' as $$
  select id, nombre, rol from public.sdr_users where activo order by nombre
$$;

create or replace function public.sdr_login(p_user_id bigint, p_pin text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  u public.sdr_users;
  c sdr_private.credenciales;
  tok uuid;
begin
  select * into u from public.sdr_users where id = p_user_id;
  if not found then
    return json_build_object('ok', false, 'error', 'credenciales');
  end if;

  select * into c from sdr_private.credenciales where user_id = p_user_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'credenciales');
  end if;

  if c.bloqueado_hasta is not null and c.bloqueado_hasta > now() then
    return json_build_object('ok', false, 'error', 'bloqueado',
      'minutos', ceil(extract(epoch from c.bloqueado_hasta - now()) / 60));
  end if;

  if p_pin is null or c.pin_hash <> extensions.crypt(p_pin, c.pin_hash) then
    update sdr_private.credenciales
      set intentos_fallidos = intentos_fallidos + 1,
          bloqueado_hasta = case
            when intentos_fallidos + 1 >= 10 then now() + interval '24 hours'
            when (intentos_fallidos + 1) % 5 = 0 then now() + interval '15 minutes'
            else bloqueado_hasta end
      where user_id = p_user_id;
    return json_build_object('ok', false, 'error', 'credenciales');
  end if;

  if not u.activo then
    return json_build_object('ok', false, 'error', 'inactivo');
  end if;

  update sdr_private.credenciales
    set intentos_fallidos = 0, bloqueado_hasta = null
    where user_id = p_user_id;

  delete from sdr_private.sesiones where expires_at < now();
  insert into sdr_private.sesiones(user_id) values (p_user_id) returning token into tok;

  return json_build_object('ok', true, 'token', tok, 'user', to_json(u));
end $$;

-- Usuario de la sesión actual (null si el token no vale o ha caducado)
create or replace function public.sdr_me() returns json
language sql stable security definer set search_path = '' as $$
  select to_json(u) from public.sdr_users u where u.id = sdr_private.current_user_id()
$$;

create or replace function public.sdr_logout() returns void
language sql security definer set search_path = '' as $$
  delete from sdr_private.sesiones where token = sdr_private.request_token()
$$;

create or replace function public.sdr_change_pin(p_old text, p_new text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := sdr_private.current_user_id();
  h text;
begin
  if uid is null then
    return json_build_object('ok', false, 'error', 'sesion');
  end if;
  if p_new !~ '^\d{4}$' then
    return json_build_object('ok', false, 'error', 'formato');
  end if;
  select pin_hash into h from sdr_private.credenciales where user_id = uid;
  if h is null or h <> extensions.crypt(p_old, h) then
    return json_build_object('ok', false, 'error', 'pin_actual');
  end if;
  perform sdr_private.set_pin(uid, p_new);
  return json_build_object('ok', true);
end $$;

-- Un manager puede resetear el PIN de cualquier usuario
create or replace function public.sdr_reset_pin(p_user_id bigint, p_new text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not sdr_private.is_manager() then
    return json_build_object('ok', false, 'error', 'permiso');
  end if;
  if p_new !~ '^\d{4}$' then
    return json_build_object('ok', false, 'error', 'formato');
  end if;
  perform sdr_private.set_pin(p_user_id, p_new);
  delete from sdr_private.sesiones where user_id = p_user_id;
  return json_build_object('ok', true);
end $$;

revoke all on function public.sdr_login_names(), public.sdr_login(bigint, text), public.sdr_me(),
  public.sdr_logout(), public.sdr_change_pin(text, text), public.sdr_reset_pin(bigint, text) from public;
grant execute on function public.sdr_login_names(), public.sdr_login(bigint, text), public.sdr_me(),
  public.sdr_logout(), public.sdr_change_pin(text, text), public.sdr_reset_pin(bigint, text) to anon, authenticated;

-- ── RLS ──
-- Quitar las políticas abiertas actuales de las tablas del SDR Hub
do $$
declare r record;
begin
  for r in
    select tablename, policyname from pg_policies
    where schemaname = 'public' and tablename in (
      'sdr_users','comerciales','ciudades','demos','mensaje_dia','objetivos','llamadas',
      'noticias','kudos','tareas','vacaciones','reglas','config','comercial_ausencias')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'sdr_users','comerciales','ciudades','demos','mensaje_dia','objetivos','llamadas',
    'noticias','kudos','tareas','vacaciones','reglas','config','comercial_ausencias']
  loop
    execute format('alter table public.%I enable row level security', t);
    -- Lectura: cualquier usuario con sesión válida
    execute format($p$create policy sesion_lee on public.%I for select to anon, authenticated
      using ((select sdr_private.current_user_id()) is not null)$p$, t);
  end loop;

  -- Tablas de configuración / gestión: solo managers escriben
  foreach t in array array[
    'comerciales','ciudades','mensaje_dia','objetivos','llamadas',
    'noticias','reglas','config','comercial_ausencias']
  loop
    execute format($p$create policy manager_escribe on public.%I for all to anon, authenticated
      using ((select sdr_private.is_manager()))
      with check ((select sdr_private.is_manager()))$p$, t);
  end loop;
end $$;

-- sdr_users: solo managers pueden actualizar (p. ej. días de vacaciones). Altas/bajas desde Supabase.
create policy manager_actualiza on public.sdr_users for update to anon, authenticated
  using ((select sdr_private.is_manager()))
  with check ((select sdr_private.is_manager()));

-- demos y tareas: cada SDR lo suyo; el manager todo
create policy propio_o_manager on public.demos for all to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

create policy propio_o_manager on public.tareas for all to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

-- vacaciones: el SDR solo puede pedir (pendiente) y cancelar sus pendientes; aprobar es cosa del manager
create policy manager_todo on public.vacaciones for all to anon, authenticated
  using ((select sdr_private.is_manager()))
  with check ((select sdr_private.is_manager()));
create policy sdr_solicita on public.vacaciones for insert to anon, authenticated
  with check (sdr_id = (select sdr_private.current_user_id()) and estado = 'pendiente');
create policy sdr_cancela on public.vacaciones for delete to anon, authenticated
  using (sdr_id = (select sdr_private.current_user_id()) and estado = 'pendiente');

-- kudos: los envía el manager; el SDR solo puede marcarlos como vistos
create policy manager_todo on public.kudos for all to anon, authenticated
  using ((select sdr_private.is_manager()))
  with check ((select sdr_private.is_manager()));
create policy sdr_marca_visto on public.kudos for update to anon, authenticated
  using (es_grupal or destinatario_id = (select sdr_private.current_user_id()))
  with check (es_grupal or destinatario_id = (select sdr_private.current_user_id()));

commit;
