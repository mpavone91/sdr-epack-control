-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Asistente (chat con IA)
--
--   · demos.updated_at: cuándo se tocó por última vez una demo en el Hub.
--     Sirve para preguntas como "lo que llevo sin actualizar desde hace
--     3 meses". Las demos existentes empiezan con su fecha de creación.
--   · asistente_uso: preguntas y tokens por usuario y día, para el límite
--     diario y para saber cuánto se gasta. Solo la toca la Edge Function
--     (service_role); nadie más puede leerla ni escribirla.
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.demos add column if not exists updated_at timestamptz;
update public.demos set updated_at = coalesce(created_at, now()) where updated_at is null;
alter table public.demos alter column updated_at set default now();
alter table public.demos alter column updated_at set not null;

create or replace function sdr_private.tocar_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger demos_updated_at before update on public.demos
  for each row execute function sdr_private.tocar_updated_at();

create table if not exists public.asistente_uso(
  user_id bigint not null references public.sdr_users(id) on delete cascade,
  fecha date not null,
  preguntas int not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  primary key (user_id, fecha)
);
alter table public.asistente_uso enable row level security;
revoke all on public.asistente_uso from anon, authenticated;

commit;
