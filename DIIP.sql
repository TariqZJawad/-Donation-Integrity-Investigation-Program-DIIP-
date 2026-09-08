-- ============================================================================
-- MODULE: Core Organizations & Entities Management
-- DESCRIPTION: Establishes baseline tables for international organizations,
--              headquarters tracking, and formal registration identifiers.
-- ============================================================================

CREATE TABLE organizations (
    org_id INTEGER PRIMARY KEY,
    org_name VARCHAR(75),
    headquarters_country VARCHAR(15),
    registration_number INTEGER 
);

-- ============================================================================
-- MODULE: Macroeconomic Country Context & Indicators
-- DESCRIPTION: Stores longitudinal socio-economic and demographic benchmarks 
--              per country to evaluate regional development and impact metrics.
-- ============================================================================

CREATE TABLE country_context (
    country_code TEXT,
    record_year DATE, 
    population_density NUMERIC,
    poverty_headcount_ratio NUMERIC,
    gdp_per_capita_usd NUMERIC,
    PRIMARY KEY (country_code, record_year)
);

-- ============================================================================
-- MODULE: Institutional Financial Filings
-- DESCRIPTION: Tracks annual audited financial metrics, operational expenses,
--              and executive compensation structures for registered entities.
-- ============================================================================

CREATE TABLE financial_filings (
    filing_id VARCHAR(15) PRIMARY KEY,
    org_id INTEGER REFERENCES organizations(org_id),
    tax_year DATE,
    total_revenue BIGINT,
    total_functional_expenses BIGINT,
    executive_compensation BIGINT
);

-- ============================================================================
-- MODULE: Aid Projects Master Catalog
-- DESCRIPTION: Stores high-level project metadata, aggregate financial commitments,
--              disbursements, execution timelines, and sectoral classifications.
-- ============================================================================

CREATE TABLE projects (
    project_id VARCHAR(10) PRIMARY KEY,
    project_title TEXT,
    total_commitments NUMERIC,
    total_disbursements NUMERIC,
    start_actual_isodate DATE,
    end_actual_isodate DATE,
    recipient_country VARCHAR(40),
    ad_sector_names TEXT,
    status VARCHAR(15)
);

-- ============================================================================
-- MODULE: Project Transactions & Geospatial Ledger
-- DESCRIPTION: Records granular transaction-level financial flows (in USD) linked 
--              to parent projects, alongside precise geospatial coordinates.
-- ============================================================================

CREATE TABLE transactions (
    transaction_id TEXT PRIMARY KEY,
    project_id VARCHAR(10) REFERENCES projects(project_id),
    transaction_date DATE,
    transaction_amount NUMERIC,
    place_name TEXT,
    latitude NUMERIC,
    longitude NUMERIC
);


-- ============================================================================
-- MODULE: Raw Ingestion - Transaction Staging
-- DESCRIPTION: Staging layer for capturing unparsed financial transaction data
--              prior to relational transformation and validation.
-- ============================================================================

CREATE TABLE raw_transactions (
    transaction_id TEXT,
    project_id TEXT,
    transaction_year TEXT,
    transaction_currency TEXT,
    transaction_value NUMERIC
);

-- ============================================================================
-- MODULE: Raw Ingestion - Geospatial Location Staging
-- DESCRIPTION: Staging catalog for raw geographic metadata, administrative 
--              codes, and gazetteer references associated with project sites.
-- ============================================================================

CREATE TABLE raw_locations (
    project_id TEXT,
    project_location_id TEXT,
    precision_code TEXT,
    geoname_id TEXT,
    place_name TEXT,
    latitude NUMERIC,
    longitude NUMERIC,
    location_type_code TEXT,
    location_type_name TEXT,
    gazetteer_adm_code TEXT,
    location_class TEXT,
    geographic_exactness TEXT
);

-- ============================================================================
-- MODULE: Raw Ingestion - Project Portfolio Staging
-- DESCRIPTION: Staging repository for high-level project properties, timelines,
--              donor-recipient mappings, and aggregate financial commitments.
-- ============================================================================

CREATE TABLE raw_projects (
    project_id TEXT,
    is_geocoded TEXT,
    project_title TEXT,
    start_actual_isodate TEXT,
    start_actual_type TEXT,
    end_actual_isodate TEXT,
    end_actual_type TEXT,
    donors TEXT,
    donors_iso3 TEXT,
    recipients TEXT,
    recipients_iso3 TEXT,
    ad_sector_codes TEXT,
    ad_sector_names TEXT,
    status TEXT,
    transaction_start_year TEXT,
    transaction_end_year TEXT,
    total_commitments NUMERIC,
    total_disbursements NUMERIC
);

-- ============================================================================
-- MODULE: Spatial & Relational Mismatch Diagnostic
-- DESCRIPTION: Evaluates discrepancy and unmatched distinct entities between 
--              project recipient designations and macroeconomic country codes.
-- ============================================================================

-- 1. Count distinct recipient codes/names in 'projects' that have NO match in 'country_context'
SELECT 
    'Unmatched in Country Context' AS discrepancy_type,
    COUNT(DISTINCT p.recipients_iso3) AS unmatched_count
FROM raw_projects p
WHERE NOT EXISTS (
    SELECT 1 
    FROM country_context cc 
    WHERE cc.country_code = p.recipients_iso3
)
UNION ALL

-- 2. Count distinct country codes in 'country_context' that are never referenced in 'projects'
SELECT 
    'Unused in Projects' AS discrepancy_type,
    COUNT(DISTINCT cc.country_code) AS unmatched_count
FROM country_context cc
WHERE NOT EXISTS (
    SELECT 1 
    FROM raw_projects p 
    WHERE p.recipients_iso3 = cc.country_code
);

-- ============================================================================
-- MODULE: Schema Alignment & Entity Standardization
-- DESCRIPTION: Expands the character limit of country codes/names to accommodate
--              regional blocs, multinational unions, and extended string labels,
--              then renames the column for clarity.
-- ============================================================================

-- 1. Alter column data type to support extended text descriptions
ALTER TABLE country_context 
ALTER COLUMN country_code TYPE VARCHAR(40);

-- 2. Rename the column to appropriately represent entities/countries
ALTER TABLE country_context 
RENAME COLUMN country_code TO country;

-- ============================================================================
-- MODULE: Country Name Standardization Update
-- DESCRIPTION: Replaces ISO3 codes in country_context with full descriptive 
--              recipient names from raw_projects where a match exists.
-- ============================================================================

UPDATE country_context cc
SET country = sub.full_name
FROM (
    SELECT DISTINCT 
        p.recipients_iso3 AS iso_code,
        p.recipients AS full_name
    FROM raw_projects p
    WHERE p.recipients_iso3 IS NOT NULL 
      AND p.recipients IS NOT NULL
) sub
WHERE cc.country = sub.iso_code;

select cc.country  from country_context cc where length(trim(cc.country)) > 3;

-- ============================================================================
-- MODULE: ETL Migration - Populate 'projects' Table (Updated)
-- DESCRIPTION: Extracts project data and stores the full recipient name directly 
--              to match the standardized 'country_context' nomenclature.
-- ============================================================================

INSERT INTO projects (
    project_id,
    project_title,
    total_commitments,
    total_disbursements,
    start_actual_isodate,
    end_actual_isodate,
    recipient_country,
    ad_sector_names,
    status
)
SELECT DISTINCT 
    p.project_id,
    p.project_title,
    CAST(p.total_commitments AS NUMERIC),
    CAST(p.total_disbursements AS NUMERIC),
    CAST(NULLIF(p.start_actual_isodate, '') AS DATE),
    CAST(NULLIF(p.end_actual_isodate, '') AS DATE),
    p.recipients AS recipiente_country, -- Direct usage of the full recipient name
    p.ad_sector_names,
    p.status
FROM raw_projects p
WHERE p.project_id IS NOT NULL
ON CONFLICT (project_id) DO NOTHING;


-- ============================================================================
-- MODULE: ETL Migration - Populate 'transactions' Table
-- DESCRIPTION: Extracts granular financial transactions and geospatial points
--              from raw_transactions and raw_locations, mapping them to parent 
--              projects and ignoring duplicate transaction IDs.
-- ============================================================================

INSERT INTO transactions (
    transaction_id,
    project_id,
    transaction_date,
    transaction_amount,
    place_name,
    latitude,
    longitude
)
SELECT 
    t.transaction_id,
    t.project_id,
    -- Formats transaction year into a standardized DATE format (YYYY-01-01)
    CAST(CONCAT(t.transaction_year, '-01-01') AS DATE) AS transaction_date,
    CAST(t.transaction_value AS NUMERIC) AS transaction_amount,
    l.place_name,
    CAST(l.latitude AS NUMERIC),
    CAST(l.longitude AS NUMERIC)
FROM raw_transactions t
LEFT JOIN raw_locations l ON t.project_id = l.project_id
WHERE t.transaction_id IS NOT NULL
  -- Ensures we only insert transactions that successfully match an existing project in the 'projects' table
  AND EXISTS (
      SELECT 1 FROM projects pr WHERE pr.project_id = t.project_id
  )
ON CONFLICT (transaction_id) DO NOTHING;

-- ============================================================================
-- MODULE: Cleanup Raw Staging Tables
-- DESCRIPTION: Drops legacy raw data tables (raw_transactions, raw_projects, 
--              and raw_locations) to free up storage and finalize the 
--              relational database restructuring.
-- ============================================================================

DROP TABLE IF EXISTS raw_transactions CASCADE;
DROP TABLE IF EXISTS raw_projects CASCADE;
DROP TABLE IF EXISTS raw_locations CASCADE;

-- ============================================================================
-- MODULE: Suspicious Projects Registry & Risk Scoring Engine Schema
-- DESCRIPTION: Stores flagged projects along with granular anomaly sub-scores,
--              analytical arrays (sectors, countries, years), and overall risk score.
-- ============================================================================

CREATE TABLE suspicious_projects (
    sus_id SERIAL PRIMARY KEY,
    project_id VARCHAR(10) REFERENCES projects(project_id),
    impact_gap REAL,
    smurfing REAL,
    discrepany REAL,
    precision REAL,
    dispersion REAL,
    fragmention REAL,
    sector TEXT[],      -- Result of string_to_array for sectoral breakdown
    countries TEXT[],   -- Result of string_to_array for involved regions/countries
    years TEXT[],       -- Result of string_to_array for temporal spread
    risk_score REAL,
    primary_flag_reason TEXT,
    CONSTRAINT unique_suspicious_project UNIQUE (project_id)
);

-- ============================================================================
-- MODULE: Database Schema Metadata Catalog
-- DESCRIPTION: Creates the 'db_scema' inventory table (without primary key) 
--              and populates it with complete structural metadata for all 
--              database tables as presented in the Entity-Relationship diagram.
-- ============================================================================

-- 1. Create the schema catalog table
CREATE TABLE db_scema (
    table_name VARCHAR(30),
    column_name VARCHAR(30),
    data_type VARCHAR(15),
    key_type VARCHAR(15),
    notes TEXT
);

-- 2. Populate metadata for 'projects' table
INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
('projects', 'project_id', 'VARCHAR', 'primary key', 'Unique identifier for each project'),
('projects', 'project_title', 'TEXT', 'normal', 'Descriptive title of the project'),
('projects', 'total_commitments', 'NUMERIC', 'normal', 'Total financial commitments in USD'),
('projects', 'total_disbursements', 'NUMERIC', 'normal', 'Total actual disbursements in USD'),
('projects', 'start_actual_isodate', 'DATE', 'normal', 'Actual start date of the project'),
('projects', 'end_actual_isodate', 'DATE', 'normal', 'Actual end date of the project'),
('projects', 'recipient_country', 'VARCHAR', 'normal', 'Standardized recipient country or bloc name'),
('projects', 'ad_sector_names', 'ARRAY', 'normal', 'Array of associated sector names'),
('projects', 'status', 'VARCHAR', 'normal', 'Current execution status of the project');

-- 3. Populate metadata for 'transactions' table
INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
('transactions', 'transaction_id', 'VARCHAR', 'primary key', 'Unique identifier for each financial transaction'),
('transactions', 'project_id', 'VARCHAR', 'foreign key', 'References projects(project_id)'),
('transactions', 'transaction_date', 'DATE', 'normal', 'Date of the transaction'),
('transactions', 'transaction_amount', 'NUMERIC', 'normal', 'Financial amount in USD'),
('transactions', 'place_name', 'TEXT', 'normal', 'Name of the specific location'),
('transactions', 'latitude', 'NUMERIC', 'normal', 'Geospatial latitude coordinate'),
('transactions', 'longitude', 'NUMERIC', 'normal', 'Geospatial longitude coordinate');

-- 4. Populate metadata for 'financial_filings' table
INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
('financial_filings', 'filing_id', 'VARCHAR', 'primary key', 'Unique identifier for organization financial filings'),
('financial_filings', 'org_id', 'INTEGER', 'foreign key', 'References organizations(org_id)'),
('financial_filings', 'tax_year', 'DATE', 'normal', 'Filing tax year'),
('financial_filings', 'total_revenue', 'NUMERIC', 'normal', 'Total revenue reported'),
('financial_filings', 'total_functional_expenses', 'NUMERIC', 'normal', 'Total functional expenses'),
('financial_filings', 'executive_compensation', 'NUMERIC', 'normal', 'Total executive compensation amount');

-- 5. Populate metadata for 'organizations' table
INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
('organizations', 'org_id', 'INTEGER', 'primary key', 'Unique identifier for organizations'),
('organizations', 'org_name', 'TEXT', 'normal', 'Official organization name'),
('organizations', 'headquarters_country', 'TEXT', 'normal', 'Country of organization headquarters'),
('organizations', 'registration_number', 'TEXT', 'normal', 'Official legal registration number');

-- 6. Populate metadata for 'suspicious_projects' table

INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
(
    'suspicious_projects', 
    'sus_id', 
    'INTEGER', 
    'primary key', 
    'Unique auto-incrementing surrogate identifier for each anomaly detection evaluation record.'
),
(
    'suspicious_projects', 
    'project_id', 
    'VARCHAR', 
    'foreign key', 
    'References projects(project_id) to link anomaly scores directly to the parent project.'
),
(
    'suspicious_projects', 
    'impact_gap', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) calculated via Min-Max scaling on the raw financial gap (Total Commitments minus Total Disbursements).'
),
(
    'suspicious_projects', 
    'smurfing', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) calculated via Min-Max scaling on the total count of micro-transactions per project to detect structuring.'
),
(
    'suspicious_projects', 
    'discrepany', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) evaluating logic flaws such as end dates preceding start dates or completed status with minimal spending.'
),
(
    'suspicious_projects', 
    'precision', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) calculated via Min-Max scaling on the frequency of missing, null, or zero geospatial coordinates (lat/lon).'
),
(
    'suspicious_projects', 
    'dispersion', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) calculated via Min-Max scaling on the spatial spread (latitude and longitude range span) of project locations.'
),
(
    'suspicious_projects', 
    'fragmention', 
    'REAL', 
    'normal', 
    'Normalized sub-score (Scale 0 to 10) calculated via Min-Max scaling on the array length of diverse sectoral categories assigned to the project.'
),
(
    'suspicious_projects', 
    'sector', 
    'ARRAY', 
    'normal', 
    'Native PostgreSQL text array storing the parsed list of associated sector names for multi-sector tracking.'
),
(
    'suspicious_projects', 
    'countries', 
    'ARRAY', 
    'normal', 
    'Native PostgreSQL text array storing the standardized recipient country or regional bloc.'
),
(
    'suspicious_projects', 
    'years', 
    'ARRAY', 
    'normal', 
    'Native PostgreSQL text array storing distinct active transaction years derived from financial timelines.'
),
(
    'suspicious_projects', 
    'risk_score', 
    'REAL', 
    'normal', 
    'Aggregated overall risk score (Scale 0 to 60) summing all normalized sub-scores to quantify cumulative anomaly exposure.'
),
(
    'suspicious_projects', 
    'primary_flag_reason', 
    'TEXT', 
    'normal', 
    'Descriptive text label identifying the dominant anomaly factor using the GREATEST mathematical evaluation across sub-scores.'
);

-- 7. Populate metadata for 'country_context' table
INSERT INTO db_scema (table_name, column_name, data_type, key_type, notes) VALUES
('country_context', 'country', 'VARCHAR', 'primary key', 'Country or regional bloc name'),
('country_context', 'record_year', 'DATE', 'normal', 'Macroeconomic context recording year'),
('country_context', 'population_density', 'NUMERIC', 'normal', 'Country population density metric'),
('country_context', 'poverty_headcount_ratio', 'NUMERIC', 'normal', 'Poverty headcount ratio metric'),
('country_context', 'gdp_per_capita_usd', 'NUMERIC', 'normal', 'Gross domestic product per capita in USD');

-- ============================================================================
-- MODULE: Alter Table Column Type & Convert to Array
-- DESCRIPTION: Alters 'ad_sector_names' column type to TEXT[] and parses 
--              comma or pipe-delimited text into a native PostgreSQL array.
-- ============================================================================

-- 1. Alter column type to TEXT[] using a USING clause to parse existing string data
ALTER TABLE projects 
ALTER COLUMN ad_sector_names TYPE TEXT[] 
USING string_to_array(TRIM(ad_sector_names), '|');

-- ============================================================================
-- MODULE: Global Text Data Cleaning & Trimming
-- DESCRIPTION: Applies TRIM() across all text and character columns for all 
--              tables to eliminate leading/trailing whitespace inconsistencies.
-- ============================================================================

-- 1. Clean 'projects' table
UPDATE projects 
SET project_id = TRIM(project_id),
    project_title = TRIM(project_title),
    recipient_country = TRIM(recipient_country),
    status = TRIM(status);

-- 2. Clean 'transactions' table
UPDATE transactions 
SET transaction_id = TRIM(transaction_id),
    project_id = TRIM(project_id),
    place_name = TRIM(place_name);

-- 3. Clean 'suspicious_projects' table
UPDATE suspicious_projects 
SET project_id = TRIM(project_id),
    primary_flag_reason = TRIM(primary_flag_reason);

-- 4. Clean 'organizations' table
UPDATE organizations 
SET org_name = TRIM(org_name),
    headquarters_country = TRIM(headquarters_country);

-- 5. Clean 'financial_filings' table
UPDATE financial_filings 
SET filing_id = TRIM(filing_id);

-- 6. Clean 'country_context' table
UPDATE country_context 
SET country = TRIM(country);

-- 7. Clean 'db_scema' table
UPDATE db_scema 
SET table_name = TRIM(table_name),
    column_name = TRIM(column_name),
    data_type = TRIM(data_type),
    key_type = TRIM(key_type),
    notes = TRIM(notes);

-- ============================================================================
-- MODULE: COMPLETE NORMALIZED ANOMALY DETECTION ENGINE
-- DESCRIPTION: Computes raw metrics for ALL anomaly indicators, applies Min-Max 
--              Normalization (scaling from 0 to 10), populates analytical arrays, 
--              and calculates the comprehensive risk score.
-- ============================================================================

-- STEP 1: Initialize all project IDs in the registry
INSERT INTO suspicious_projects (project_id)
SELECT project_id 
FROM projects
ON CONFLICT (project_id) DO NOTHING;


-- STEP 2: Normalize Impact Gap (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        p.project_id,
        CASE 
            WHEN p.total_commitments > 0 THEN COALESCE(p.total_commitments, 0) - COALESCE(p.total_disbursements, 0)
            ELSE 0 
        END AS raw_val
    FROM projects p
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET impact_gap = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 3: Normalize Smurfing / Transaction Count (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        p.project_id,
        COALESCE(tx.cnt, 0)::REAL AS raw_val
    FROM projects p
    LEFT JOIN (
        SELECT project_id, COUNT(*) AS cnt 
        FROM transactions 
        GROUP BY project_id
    ) tx ON p.project_id = tx.project_id
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET smurfing = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 4: Normalize Timeline / Financial Discrepancy (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        p.project_id,
        CASE 
            WHEN p.end_actual_isodate < p.start_actual_isodate THEN 10.0
            WHEN p.status ILIKE '%complete%' AND p.total_disbursements < (p.total_commitments * 0.10) THEN 5.0
            ELSE 0.0
        END AS raw_val
    FROM projects p
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET discrepany = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 5: Normalize Geospatial Precision Anomaly (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        p.project_id,
        COALESCE(bad_coords.cnt, 0)::REAL AS raw_val
    FROM projects p
    LEFT JOIN (
        SELECT project_id, COUNT(*) AS cnt 
        FROM transactions 
        WHERE latitude = 0 OR latitude IS NULL OR longitude = 0 OR longitude IS NULL
        GROUP BY project_id
    ) bad_coords ON p.project_id = bad_coords.project_id
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET precision = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 6: Normalize Spatial Dispersion (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        p.project_id,
        COALESCE(COALESCE(coord.lat_spread, 0) + COALESCE(coord.lon_spread, 0), 0) AS raw_val
    FROM projects p
    LEFT JOIN (
        SELECT 
            project_id, 
            (MAX(latitude) - MIN(latitude)) AS lat_spread,
            (MAX(longitude) - MIN(longitude)) AS lon_spread
        FROM transactions
        WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        GROUP BY project_id
    ) coord ON p.project_id = coord.project_id
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET dispersion = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 7: Normalize Sectoral Fragmentation (Scale 0 to 10)
WITH raw_data AS (
    SELECT 
        project_id,
        COALESCE(array_length(ad_sector_names, 1), 0)::REAL AS raw_val
    FROM projects
),
stats AS (
    SELECT MAX(raw_val) AS max_val, MIN(raw_val) AS min_val FROM raw_data
)
UPDATE suspicious_projects sp
SET fragmention = CASE 
    WHEN stats.max_val = stats.min_val THEN 0.0
    ELSE ROUND(CAST(((rd.raw_val - stats.min_val) / NULLIF(stats.max_val - stats.min_val, 0)) * 10 AS NUMERIC), 2)
END
FROM raw_data rd, stats
WHERE sp.project_id = rd.project_id;


-- STEP 8: Populate Analytical Arrays (Sectors, Countries, Years)
UPDATE suspicious_projects sp
SET sector = p.ad_sector_names,
    countries = ARRAY[p.recipient_country]
FROM projects p
WHERE sp.project_id = p.project_id;

UPDATE suspicious_projects sp
SET years = sub.yrs
FROM (
    SELECT project_id, ARRAY_AGG(DISTINCT EXTRACT(YEAR FROM transaction_date)::TEXT) AS yrs
    FROM transactions
    WHERE transaction_date IS NOT NULL
    GROUP BY project_id
) sub
WHERE sp.project_id = sub.project_id;


-- STEP 9: Aggregate Final Normalized Risk Score (Scale 0 to 60) & Set Primary Flag
UPDATE suspicious_projects
SET risk_score = COALESCE(impact_gap, 0) + 
                 COALESCE(smurfing, 0) + 
                 COALESCE(discrepany, 0) + 
                 COALESCE(precision, 0) + 
                 COALESCE(dispersion, 0) + 
                 COALESCE(fragmention, 0),
    primary_flag_reason = CASE 
        WHEN GREATEST(COALESCE(impact_gap,0), COALESCE(smurfing,0), COALESCE(discrepany,0), COALESCE(precision,0), COALESCE(dispersion,0), COALESCE(fragmention,0)) = impact_gap THEN 'Normalized High Impact Financial Gap'
        WHEN GREATEST(COALESCE(impact_gap,0), COALESCE(smurfing,0), COALESCE(discrepany,0), COALESCE(precision,0), COALESCE(dispersion,0), COALESCE(fragmention,0)) = smurfing THEN 'Normalized Transaction Fragmentation'
        WHEN GREATEST(COALESCE(impact_gap,0), COALESCE(smurfing,0), COALESCE(discrepany,0), COALESCE(precision,0), COALESCE(dispersion,0), COALESCE(fragmention,0)) = dispersion THEN 'Normalized Extreme Geographic Dispersion'
        ELSE 'Multi-Factor Normalized Anomaly'
    END;









