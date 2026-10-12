-- ════════════════════════════════════════════════════════════════════
-- Cocina SDR · XP extra guardada en Supabase
--
-- La XP que no sale directamente de las demos (extras por limpiar,
-- misiones del día) y las comandas ya abiertas se guardan aquí, para que
-- el nivel de cada SDR sea el mismo en su cocina, en los niveles del
-- equipo y en la central del manager, en cualquier ordenador.
--   · Lee: cualquier sesión (hace falta para los niveles del equipo).
--   · Escribe: cada SDR solo filas suyas; no se pueden editar ni borrar.
--   · clave única por SDR: una misión o comanda no suma dos veces.
-- ════════════════════════════════════════════════════════════════════

create table if not exists public.xp_extras(
  id bigint generated always as identity primary key,
  sdr_id bigint not null references public.sdr_users(id) on delete cascade,
  ym text not null check (ym ~ '^\d{4}-\d{2}$'),
  tipo text not null check (tipo in ('extra','mision','abrir')),
  xp int not null default 0 check (xp between 0 and 100),
  motivo text check (char_length(motivo) <= 200),
  demo_id bigint,
  clave text not null,
  created_at timestamptz not null default now(),
  unique (sdr_id, clave)
);
create index if not exists xp_extras_ym_idx on public.xp_extras(ym);

alter table public.xp_extras enable row level security;

create policy xp_extras_lee on public.xp_extras for select to anon, authenticated
  using ((select sdr_private.current_user_id()) is not null);

create policy xp_extras_propio on public.xp_extras for insert to anon, authenticated
  with check (sdr_id = (select sdr_private.current_user_id()));
