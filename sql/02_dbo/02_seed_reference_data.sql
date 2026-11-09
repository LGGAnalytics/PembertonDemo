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

INSERT INTO dbo.ref_instrument (instrument_type, seniority, seniority_rank, price_basis) VALUES
    ('Revolving Credit Facility','Senior secured',1,'PCT_OF_PAR'),
    ('Senior Secured Term Loan','Senior secured',1,'PCT_OF_PAR'),
    ('Unitranche','Senior secured',2,'PCT_OF_PAR'),
    ('Second Lien','Junior',3,'PCT_OF_PAR'),
    ('Holdco PIK Note','Structurally subordinated',4,'PCT_OF_PAR'),
    ('Equity co-invest','Equity',5,'PER_UNIT');

-- ETL runtime configuration (see dbo.usp_run_etl / dbo.usp_discover_periods)
INSERT INTO dbo.etl_config (config_key, config_value, description) VALUES
    ('lookback_months', '6',  'Incremental mode: only periods within this many months of the latest month-end are rebuilt.'),
    ('overlap_hours',   '0',  'Incremental mode: rows loaded up to this many hours BEFORE the watermark are re-read (safety overlap). The client uses 4; the demo uses 0 because the full load and the delta are minutes apart.'),
    ('fail_on_period',  NULL, 'TEST HOOK: when set to a date, usp_build_facility_month raises for that period. Must be NULL in normal runs.');

-- Spec 004: common rating score (1 strong .. 5 distressed). Demo convention, not an
-- agency-published mapping: investment grade -> 1, BB -> 2, B+/B -> 3, B-/CCC+ -> 4, below -> 5.
INSERT INTO dbo.ref_rating_scale (agency, rating, score, rank) VALUES
    ('S&P','AAA',1,1),
    ('S&P','AA+',1,2),
    ('S&P','AA',1,3),
    ('S&P','AA-',1,4),
    ('S&P','A+',1,5),
    ('S&P','A',1,6),
    ('S&P','A-',1,7),
    ('S&P','BBB+',1,8),
    ('S&P','BBB',1,9),
    ('S&P','BBB-',1,10),
    ('S&P','BB+',2,11),
    ('S&P','BB',2,12),
    ('S&P','BB-',2,13),
    ('S&P','B+',3,14),
    ('S&P','B',3,15),
    ('S&P','B-',4,16),
    ('S&P','CCC+',4,17),
    ('S&P','CCC',5,18),
    ('S&P','CCC-',5,19),
    ('S&P','CC',5,20),
    ('S&P','C',5,21),
    ('S&P','D',5,22),
    ('Moody''s','Aaa',1,1),
    ('Moody''s','Aa1',1,2),
    ('Moody''s','Aa2',1,3),
    ('Moody''s','Aa3',1,4),
    ('Moody''s','A1',1,5),
    ('Moody''s','A2',1,6),
    ('Moody''s','A3',1,7),
    ('Moody''s','Baa1',1,8),
    ('Moody''s','Baa2',1,9),
    ('Moody''s','Baa3',1,10),
    ('Moody''s','Ba1',2,11),
    ('Moody''s','Ba2',2,12),
    ('Moody''s','Ba3',2,13),
    ('Moody''s','B1',3,14),
    ('Moody''s','B2',3,15),
    ('Moody''s','B3',4,16),
    ('Moody''s','Caa1',4,17),
    ('Moody''s','Caa2',5,18),
    ('Moody''s','Caa3',5,19),
    ('Moody''s','Ca',5,20),
    ('Moody''s','C',5,21),
    ('Committee','A',1,1),
    ('Committee','B',2,2),
    ('Committee','C',3,3),
    ('Committee','D',4,4),
    ('Committee','E',5,5);
