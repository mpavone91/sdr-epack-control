-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Planificación: enlace opcional en los bloques
--
-- Ej.: "📞 Llamar inbounds" con el enlace al reporte de inbounds de
-- Salesforce. Se guarda en la plantilla (el bloque que crea el manager)
-- y se copia a cada bloque del calendario, así que cada vez que se
-- reutiliza el bloque (arrastrar, repetir, copiar semana) lleva el enlace.
-- Los bloques propios también pueden tener el suyo.
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.planificacion_plantillas
  add column if not exists enlace text check (enlace is null or (char_length(enlace) <= 2000 and enlace ~* '^https?://'));

alter table public.planificacion_bloques
  add column if not exists enlace text check (enlace is null or (char_length(enlace) <= 2000 and enlace ~* '^https?://'));

commit;
