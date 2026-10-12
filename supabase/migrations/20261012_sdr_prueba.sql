-- ════════════════════════════════════════════════════════════════════
-- SDR Hub · Usuarios de prueba
--
-- Marca para usuarios que sirven para probar funciones nuevas (la cocina)
-- con datos reales del sistema sin que cuenten en las métricas del equipo.
-- El Hub los excluye del panel del manager, de las métricas del equipo y
-- de los totales; solo ellos ven las funciones en pruebas.
-- ════════════════════════════════════════════════════════════════════

alter table public.sdr_users
  add column if not exists es_prueba boolean not null default false;
