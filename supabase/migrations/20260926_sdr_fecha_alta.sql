-- Fecha de incorporación de cada SDR: antes de ese mes no aparece en las
-- métricas, rankings ni objetivos del equipo. null = desde siempre.
alter table public.sdr_users add column if not exists fecha_alta date;

-- Alejandro entra en octubre de 2026
update public.sdr_users set fecha_alta = '2026-10-01' where id = 9 and fecha_alta is null;
