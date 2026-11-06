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
