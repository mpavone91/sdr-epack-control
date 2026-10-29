-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Planificación (calendario semanal de bloques)
--
-- El manager crea "bloques" (plantillas): Llamar inbounds 1 h, Campaña
-- tal 2 h urgente… Cada SDR los arrastra a su calendario de la semana y
-- los ejecuta con play / pausa / terminar. El manager ve en directo qué
-- está haciendo cada uno y cuánto de lo planificado se cumple.
--
--   · planificacion_plantillas: los bloques que crea el manager.
--       sdr_id null = para todo el equipo; si no, solo para ese SDR.
--       Lee: cualquier sesión. Escribe: solo un manager.
--   · planificacion_bloques: lo que cada SDR pone en su calendario.
--       Lee: el propio SDR o un manager (el manager también puede
--       planificar por ellos). Cada SDR solo toca lo suyo.
--   · sdr_users.email: a dónde se mandan los avisos por email.
--
-- Avisos por email (Edge Function "planificacion-avisos", ver
-- supabase/functions/planificacion-avisos): pg_cron la llama cada minuto
-- con un secreto guardado en el Vault; ella se lo pasa a
-- planificacion_avisos_claim(), que devuelve los avisos pendientes:
--   · inicio : el bloque empieza ahora y aún no le han dado a play.
--   · fin    : el tiempo del bloque se ha cumplido → 15 min de descanso.
--   · urgente: el manager ha creado un bloque urgente para planificar.
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.sdr_users add column if not exists email text;
alter table public.sdr_users add column if not exists avisos_email boolean not null default true;

create table if not exists public.planificacion_plantillas(
  id bigint generated always as identity primary key,
  titulo text not null check (char_length(titulo) between 1 and 80),
  descripcion text check (char_length(descripcion) <= 500),
  emoji text check (char_length(emoji) <= 8),
  color text not null default '#3b7dd8' check (color ~ '^#[0-9a-fA-F]{6}$'),
  duracion_min int not null default 60 check (duracion_min between 15 and 480 and duracion_min % 15 = 0),
  prioridad text not null default 'normal' check (prioridad in ('normal','alta','urgente')),
  sdr_id bigint references public.sdr_users(id) on delete cascade,
  fecha_limite date,
  activa boolean not null default true,
  orden int not null default 0,
  autor_id bigint references public.sdr_users(id) on delete set null,
  aviso_urgente_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.planificacion_bloques(
  id bigint generated always as identity primary key,
  sdr_id bigint not null references public.sdr_users(id) on delete cascade,
  plantilla_id bigint references public.planificacion_plantillas(id) on delete set null,
  titulo text not null check (char_length(titulo) between 1 and 80),
  emoji text check (char_length(emoji) <= 8),
  color text not null default '#3b7dd8' check (color ~ '^#[0-9a-fA-F]{6}$'),
  prioridad text not null default 'normal' check (prioridad in ('normal','alta','urgente')),
  fecha date not null,
  hora_inicio time not null,
  duracion_min int not null check (duracion_min between 15 and 600 and duracion_min % 15 = 0),
  -- planificado → en_curso ⇄ pausado → completado · o saltado si no se hizo
  estado text not null default 'planificado' check (estado in ('planificado','en_curso','pausado','completado','saltado')),
  started_at timestamptz,                  -- primera vez que le dio a play
  corriendo_desde timestamptz,             -- play actual (null si está en pausa o parado)
  trabajado_seg int not null default 0,    -- segundos acumulados antes del play actual
  completed_at timestamptz,
  notas text check (char_length(notas) <= 500),
  aviso_inicio_at timestamptz,
  aviso_fin_at timestamptz,
  creado_por bigint references public.sdr_users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists planif_bloques_sdr_fecha_idx on public.planificacion_bloques(sdr_id, fecha);
create index if not exists planif_bloques_fecha_idx on public.planificacion_bloques(fecha);

alter table public.planificacion_plantillas enable row level security;
alter table public.planificacion_bloques enable row level security;

create policy plantillas_lee on public.planificacion_plantillas for select to anon, authenticated
  using ((select sdr_private.current_user_id()) is not null);
create policy plantillas_manager on public.planificacion_plantillas for all to anon, authenticated
  using ((select sdr_private.is_manager()))
  with check ((select sdr_private.is_manager()));

create policy bloques_propio_o_manager on public.planificacion_bloques for all to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

-- ── Avisos por email ──
-- Devuelve los avisos que toca mandar y los marca como enviados en la misma
-- transacción, para que dos ejecuciones seguidas no manden el mismo email.
-- Solo la puede llamar la Edge Function (service_role) y además exige el
-- secreto 'planificacion_cron' del Vault, que únicamente conoce pg_cron.
create or replace function public.planificacion_avisos_claim(p_secret text)
returns table(tipo text, bloque_id bigint, plantilla_id bigint, sdr_id bigint, nombre text, email text,
              titulo text, emoji text, prioridad text, fecha date, hora_inicio time, duracion_min int,
              descripcion text, fecha_limite date, siguiente_titulo text, siguiente_hora time)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ahora timestamptz := now();
  hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  if p_secret is null or p_secret is distinct from
     (select decrypted_secret from vault.decrypted_secrets where name = 'planificacion_cron') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- inicio: entre la hora de inicio y 10 min después, sin haberle dado a play
  return query
  with c as (
    update public.planificacion_bloques b set aviso_inicio_at = ahora
    from public.sdr_users u
    where u.id = b.sdr_id and u.activo and u.avisos_email and coalesce(u.email,'') <> ''
      and b.aviso_inicio_at is null and b.estado = 'planificado' and b.fecha = hoy
      and ahora >= ((b.fecha + b.hora_inicio) at time zone 'Europe/Madrid')
      and ahora <  ((b.fecha + b.hora_inicio) at time zone 'Europe/Madrid') + interval '10 minutes'
    returning b.*, u.nombre as u_nombre, u.email as u_email
  )
  select 'inicio'::text, c.id, c.plantilla_id, c.sdr_id, c.u_nombre, c.u_email, c.titulo, c.emoji, c.prioridad,
         c.fecha, c.hora_inicio, c.duracion_min, null::text, null::date, null::text, null::time
  from c;

  -- fin: el tiempo trabajado (con play) llega a la duración del bloque
  return query
  with c as (
    update public.planificacion_bloques b set aviso_fin_at = ahora
    from public.sdr_users u
    where u.id = b.sdr_id and u.activo and u.avisos_email and coalesce(u.email,'') <> ''
      and b.aviso_fin_at is null and b.estado = 'en_curso' and b.corriendo_desde is not null
      and b.trabajado_seg + extract(epoch from ahora - b.corriendo_desde) >= b.duracion_min * 60
    returning b.*, u.nombre as u_nombre, u.email as u_email
  )
  select 'fin'::text, c.id, c.plantilla_id, c.sdr_id, c.u_nombre, c.u_email, c.titulo, c.emoji, c.prioridad,
         c.fecha, c.hora_inicio, c.duracion_min, null::text, null::date, n.titulo, n.hora_inicio
  from c
  left join lateral (
    select x.titulo, x.hora_inicio from public.planificacion_bloques x
    where x.sdr_id = c.sdr_id and x.fecha = hoy and x.estado = 'planificado' and x.id <> c.id
      and x.hora_inicio >= (ahora at time zone 'Europe/Madrid')::time
    order by x.hora_inicio limit 1
  ) n on true;

  -- urgente: bloque urgente nuevo del manager → a cada SDR al que va dirigido
  return query
  with c as (
    update public.planificacion_plantillas p set aviso_urgente_at = ahora
    where p.aviso_urgente_at is null and p.activa and p.prioridad = 'urgente'
    returning p.*
  )
  select 'urgente'::text, null::bigint, c.id, u.id, u.nombre, u.email, c.titulo, c.emoji, c.prioridad,
         null::date, null::time, c.duracion_min, c.descripcion, c.fecha_limite, null::text, null::time
  from c
  join public.sdr_users u on u.rol = 'sdr' and u.activo and u.avisos_email and coalesce(u.email,'') <> ''
    and (c.sdr_id is null or c.sdr_id = u.id);
end $$;

revoke all on function public.planificacion_avisos_claim(text) from public, anon, authenticated;
grant execute on function public.planificacion_avisos_claim(text) to service_role;

commit;

-- ── Llamar a la Edge Function cada minuto ──
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

select vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'planificacion_cron',
                           'Secreto con el que pg_cron llama a la función planificacion-avisos')
where not exists (select 1 from vault.secrets where name = 'planificacion_cron');

select cron.schedule('planificacion-avisos', '* * * * *', $cron$
  select net.http_post(
    url := 'https://ilzntryzijdfnntwuthp.supabase.co/functions/v1/planificacion-avisos',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'planificacion_cron')),
    body := '{}'::jsonb)
$cron$);
