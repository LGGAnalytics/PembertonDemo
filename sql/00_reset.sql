-- =============================================================================
-- 00_reset.sql
-- Full rebuild: drops the three layers so the deploy is deterministic.
-- (Demo choice: source extracts are fully reloaded on every run. In production
--  this would be replaced by versioned migrations.)
-- =============================================================================
DROP SCHEMA IF EXISTS bi      CASCADE;
DROP SCHEMA IF EXISTS dbo     CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;
