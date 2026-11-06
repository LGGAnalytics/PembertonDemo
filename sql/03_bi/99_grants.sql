-- =============================================================================
-- Least privilege: Metabase connects as bi_reader and can read ONLY the bi
-- views. It has no access to staging or dbo.
-- (bi_reader is created by infra/postgres-init/01_init.sql)
-- =============================================================================
GRANT USAGE  ON SCHEMA bi TO bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO bi_reader;
