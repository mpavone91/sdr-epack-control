-- ════════════════════════════════════════════════════════════════════
-- Cocina SDR · Notas del manager
--
-- Notas que el manager deja en la cocina de un SDR. El SDR las ve en su
-- pizarra y las marca como leídas. El chat en directo no se guarda.
--   · Lee: el propio SDR o un manager.
--   · Escribe y borra: solo un manager, y firmando como él mismo.
--   · Actualiza: el SDR solo puede marcarla como leída (lo impide un
--     trigger si intenta cambiar cualquier otra cosa).
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

create policy notas_lee on public.notas_cocina for select to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

create policy notas_manager_crea on public.notas_cocina for insert to anon, authenticated
  with check ((select sdr_private.is_manager()) and autor_id = (select sdr_private.current_user_id()));

create policy notas_marcar_leida on public.notas_cocina for update to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));

create policy notas_manager_borra on public.notas_cocina for delete to anon, authenticated
  using ((select sdr_private.is_manager()));

-- Un SDR solo puede tocar leida_at
create or replace function sdr_private.notas_solo_leida() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not sdr_private.is_manager() and (new.texto is distinct from old.texto or new.sdr_id is distinct from old.sdr_id
     or new.autor_id is distinct from old.autor_id or new.created_at is distinct from old.created_at) then
    raise exception 'Solo se puede marcar la nota como leída';
  end if;
  return new;
end $$;

create trigger notas_solo_leida before update on public.notas_cocina
  for each row execute function sdr_private.notas_solo_leida();
