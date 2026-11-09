-- =============================================================================
-- LAYER 2 - DBO : reference / conformance data used by the ETL procedures
-- to standardise free-text source values.
-- =============================================================================
INSERT INTO dbo.ref_country (country_code, iso3_code, country_name, region) VALUES
    ('GB','GBR','United Kingdom','UK & Ireland'),
    ('IE','IRL','Ireland','UK & Ireland'),
    ('DE','DEU','Germany','DACH'),
    ('FR','FRA','France','Western Europe'),
    ('NL','NLD','Netherlands','Benelux'),
    ('BE','BEL','Belgium','Benelux'),
    ('ES','ESP','Spain','Southern Europe'),
    ('IT','ITA','Italy','Southern Europe'),
    ('PT','PRT','Portugal','Southern Europe'),
    ('SE','SWE','Sweden','Nordics'),
    ('DK','DNK','Denmark','Nordics');

INSERT INTO dbo.ref_sector (sector_name, sector_group) VALUES
    ('Healthcare','Defensive'),
    ('Software & Technology','Growth'),
    ('Business Services','Defensive'),
    ('Industrials','Cyclical'),
    ('Consumer','Cyclical'),
    ('Education','Defensive'),
    ('Financial Services','Defensive'),
    ('Transportation & Logistics','Cyclical'),
    ('Food & Beverage','Defensive'),
    ('Telecommunications','Growth');

INSERT INTO dbo.ref_instrument (instrument_type, seniority, seniority_rank) VALUES
    ('Revolving Credit Facility','Senior secured',1),
    ('Senior Secured Term Loan','Senior secured',1),
    ('Unitranche','Senior secured',2),
    ('Second Lien','Junior',3),
    ('Holdco PIK Note','Structurally subordinated',4);

-- ETL runtime configuration (see dbo.usp_run_etl / dbo.usp_discover_periods)
INSERT INTO dbo.etl_config (config_key, config_value, description) VALUES
    ('lookback_months', '6',  'Incremental mode: only periods within this many months of the latest month-end are rebuilt.'),
    ('overlap_hours',   '0',  'Incremental mode: rows loaded up to this many hours BEFORE the watermark are re-read (safety overlap). The client uses 4; the demo uses 0 because the full load and the delta are minutes apart.'),
    ('fail_on_period',  NULL, 'TEST HOOK: when set to a date, usp_build_facility_month raises for that period. Must be NULL in normal runs.');
