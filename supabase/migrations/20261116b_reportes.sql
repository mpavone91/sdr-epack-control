-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Reportes (biblioteca de enlaces)
--
-- Enlaces directos a reportes (Salesforce, Looker, hojas…) que guarda el
-- equipo para tenerlos a mano.
--   · compartido = true  → lo ve todo el equipo.
--   · compartido = false → solo lo ve quien lo creó (y el manager).
--   · Cualquier sesión puede crear, firmando como sí misma.
--   · Editar / borrar: quien lo creó o un manager.
-- ════════════════════════════════════════════════════════════════════

begin;

create table if not exists public.reportes(
  id bigint generated always as identity primary key,
  titulo text not null check (char_length(titulo) between 1 and 80),
  url text not null check (char_length(url) <= 2000 and url ~* '^https?://'),
  descripcion text check (char_length(descripcion) <= 300),
  categoria text check (char_length(categoria) <= 40),
  emoji text check (char_length(emoji) <= 8),
  compartido boolean not null default true,
  autor_id bigint references public.sdr_users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists reportes_autor_idx on public.reportes(autor_id);

alter table public.reportes enable row level security;

create policy reportes_lee on public.reportes for select to anon, authenticated
  using ((select sdr_private.current_user_id()) is not null
         and (compartido or autor_id = (select sdr_private.current_user_id()) or (select sdr_private.is_manager())));

create policy reportes_crea on public.reportes for insert to anon, authenticated
  with check (autor_id = (select sdr_private.current_user_id()));

create policy reportes_edita on public.reportes for update to anon, authenticated
  using (autor_id = (select sdr_private.current_user_id()) or (select sdr_private.is_manager()))
  with check (autor_id = (select sdr_private.current_user_id()) or (select sdr_private.is_manager()));

create policy reportes_borra on public.reportes for delete to anon, authenticated
  using (autor_id = (select sdr_private.current_user_id()) or (select sdr_private.is_manager()));

commit;
