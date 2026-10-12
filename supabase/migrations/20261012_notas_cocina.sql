-- ════════════════════════════════════════════════════════════════════
-- Cocina SDR · Notas del manager
--
-- Notas que el manager deja en la cocina de un SDR. El SDR las ve en su
-- pizarra y las marca como leídas. El chat en directo no se guarda.
--   · Lee: el propio SDR o un manager.
--   · Escribe y borra: solo un manager (como autor de la nota).
--   · Actualiza: solo la columna leida_at (el SDR al leerla).
-- ════════════════════════════════════════════════════════════════════

create table if not exists public.notas_cocina(
  id bigint generated always as identity primary key,
  sdr_id bigint not null references public.sdr_users(id) on delete cascade,
  autor_id bigint references public.sdr_users(id) on delete set null,
  texto text not null check (char_length(texto) between 1 and 500),
  created_at timestamptz not null default now(),
  leida_at timestamptz
);
create index if not exists notas_cocina_sdr_idx on public.notas_cocina(sdr_id);

alter table public.notas_cocina enable row level security;

drop policy if exists notas_lee on public.notas_cocina;
create policy notas_lee on public.notas_cocina for select to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

drop policy if exists notas_manager_crea on public.notas_cocina;
create policy notas_manager_crea on public.notas_cocina for insert to anon, authenticated
  with check ((select sdr_private.is_manager()) and autor_id = (select sdr_private.current_user_id()));

drop policy if exists notas_marcar_leida on public.notas_cocina;
create policy notas_marcar_leida on public.notas_cocina for update to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

drop policy if exists notas_manager_borra on public.notas_cocina;
create policy notas_manager_borra on public.notas_cocina for delete to anon, authenticated
  using ((select sdr_private.is_manager()));

revoke all on public.notas_cocina from anon, authenticated;
grant select, insert, delete on public.notas_cocina to anon, authenticated;
grant update (leida_at) on public.notas_cocina to anon, authenticated;
