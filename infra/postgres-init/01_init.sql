-- Runs once, on first start of the Postgres container.
-- 1) Application database used internally by Metabase (questions, dashboards, users).
CREATE DATABASE metabase_app;

-- 2) Read-only role Metabase uses to query the warehouse (least privilege).
CREATE ROLE bi_reader LOGIN PASSWORD 'bi_reader_pw';
