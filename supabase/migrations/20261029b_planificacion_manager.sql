-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Planificación: lo que hace el manager y resultados
--
--   · planificacion_bloques.visto_at: cuándo vio el SDR un bloque que le
--     puso el manager (null = aún no lo ha visto).
--   · planificacion_bloques.res_*: lo que sacó el SDR del bloque (llamadas,
--     conectadas, demos), para medir qué tipo de bloque funciona mejor.
--   · planificacion_mensajes: recordatorios del manager a un SDR ("entra a
--     ver tu planificación"). El SDR los ve en el Hub y los marca como
--     leídos. Mismas reglas que notas_cocina.
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.planificacion_bloques
  add column if not exists visto_at timestamptz,
  add column if not exists res_llamadas int check (res_llamadas between 0 and 2000),
  add column if not exists res_conectadas int check (res_conectadas between 0 and 2000),
  add column if not exists res_demos int check (res_demos between 0 and 200);

create table if not exists public.planificacion_mensajes(
  id bigint generated always as identity primary key,
  sdr_id bigint not null references public.sdr_users(id) on delete cascade,
  autor_id bigint references public.sdr_users(id) on delete set null,
  texto text not null check (char_length(texto) between 1 and 500),
  created_at timestamptz not null default now(),
  leida_at timestamptz
);
create index if not exists planif_mensajes_sdr_idx on public.planificacion_mensajes(sdr_id);

alter table public.planificacion_mensajes enable row level security;

create policy planif_msg_lee on public.planificacion_mensajes for select to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));
create policy planif_msg_manager_crea on public.planificacion_mensajes for insert to anon, authenticated
  with check ((select sdr_private.is_manager()) and autor_id = (select sdr_private.current_user_id()));
create policy planif_msg_marcar_leida on public.planificacion_mensajes for update to anon, authenticated
  using ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()))
  with check ((select sdr_private.is_manager()) or sdr_id = (select sdr_private.current_user_id()));
create policy planif_msg_manager_borra on public.planificacion_mensajes for delete to anon, authenticated
  using ((select sdr_private.is_manager()));

-- El SDR solo puede marcarlo como leído (mismo trigger que las notas de la cocina)
create trigger planif_msg_solo_leida before update on public.planificacion_mensajes
  for each row execute function sdr_private.notas_solo_leida();

commit;
