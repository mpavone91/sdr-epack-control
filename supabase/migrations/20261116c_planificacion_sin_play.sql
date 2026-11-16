-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Planificación: "Sí lo hice, pero no le di a Play"
--
-- A veces el SDR hace el bloque y se le olvida darle a Play, y quedaba
-- como no hecho. Ahora puede marcarlo como hecho después; sin_play = true
-- indica que se marcó así (el tiempo no se midió con el cronómetro).
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.planificacion_bloques
  add column if not exists sin_play boolean not null default false;

commit;
