-- SDR Hub · Confirmación de asistencia
-- Guarda cuándo el SDR confirmó con el cliente que la demo sigue en pie.
-- null = sin confirmar. Al reagendar, la app lo vuelve a poner a null.
alter table public.demos add column if not exists confirmada_at timestamptz;
