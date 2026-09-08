-- ===============================================================================
-- Donation Integrity & Investigation Program (DIIP) - Core SQL Queries
-- ===============================================================================
-- Description: This script contains the primary PostgreSQL datasets and KPIs 
-- used to power the Apache Superset executive dashboard.
-- ===============================================================================

-- -------------------------------------------------------------------------------
-- 1. Commitments vs. Disbursements by Country & Sector
-- Unnests arrays to calculate financial metrics at the country-sector granularity.
-- -------------------------------------------------------------------------------
SELECT 
    country,
    year,
    sector,
    SUM(DISTINCT total_commitments) AS commitments,
    SUM(DISTINCT total_disbursements) AS disbursements
FROM
 (
    SELECT 
        p.project_id,
        p.recipient_country AS country,
        p.start_actual_isodate AS year, 
        sector_item AS sector,
        p.total_commitments,
        p.total_disbursements
    FROM projects p,
         UNNEST(p.ad_sector_names) AS sector_item
    WHERE p.recipient_country IS NOT NULL 
      AND p.start_actual_isodate IS NOT NULL
 ) subquery
GROUP BY country, year, sector;

-- -------------------------------------------------------------------------------
-- 2. Economic Status vs. Total Project Funding by Country
-- Joins project funding with national GDP context to map financial flow vs. economic status.
-- -------------------------------------------------------------------------------
SELECT
    c.country, 
    AVG(c.gdp_per_capita_usd) AS avg_gdp, 
    SUM(p.total_commitments) AS total_commitments
FROM country_context c 
JOIN projects p ON c.country = p.recipient_country
WHERE (c.gdp_per_capita_usd > 0 OR c.gdp_per_capita_usd IS NOT NULL) 
  AND (p.total_commitments > 0 OR p.total_commitments IS NOT NULL)
GROUP BY c.country;

-- -------------------------------------------------------------------------------
-- 3. Average Breakdown of Suspicion Metrics
-- Unifies various risk indicators into a single aggregated distribution for the donut chart.
-- -------------------------------------------------------------------------------
SELECT 'Smurfing' AS suspicion_reason, AVG(smurfing) AS avg_value FROM suspicious_projects
UNION ALL
SELECT 'Discrepancy' AS suspicion_reason, AVG(discrepany) AS avg_value FROM suspicious_projects
UNION ALL
SELECT 'Precision' AS suspicion_reason, AVG(precision) AS avg_value FROM suspicious_projects
UNION ALL
SELECT 'Dispersion' AS suspicion_reason, AVG(dispersion) AS avg_value FROM suspicious_projects
UNION ALL
SELECT 'Fragmentation' AS suspicion_reason, AVG(fragmention) AS avg_value FROM suspicious_projects;

-- -------------------------------------------------------------------------------
-- 4. Average Financial Efficiency by Organizations
-- Calculates overhead ratio (Revenue to Expenses) to evaluate NGO/Partner efficiency.
-- -------------------------------------------------------------------------------
SELECT 
    o.org_id,
    o.org_name,
    AVG(ABS(f.total_revenue) / NULLIF(ABS(f.total_functional_expenses), 0)) AS avg_overhead_ratio
FROM organizations o
JOIN financial_filings f ON o.org_id = f.org_id
WHERE ABS(f.total_functional_expenses) > 0 
  AND f.total_revenue IS NOT NULL
GROUP BY o.org_id, o.org_name;

-- -------------------------------------------------------------------------------
-- 5. Geographical Distribution of Transactions by Dynamic Risk Levels
-- Uses spatial coordinates and assigns risk categories based on global average scores.
-- -------------------------------------------------------------------------------
WITH global_avg_risk AS (
    SELECT AVG(risk_score) AS avg_risk FROM suspicious_projects
)
SELECT 
    t.transaction_id,
    t.project_id,
    t.place_name,
    t.latitude,
    t.longitude,
    t.transaction_amount,
    CASE 
        WHEN s.sus_id IS NULL THEN 0 -- No suspicious flag
        WHEN s.risk_score < (SELECT avg_risk FROM global_avg_risk) THEN 1 -- Below average risk
        ELSE 2 -- Above average risk
    END AS risk_category
FROM transactions t
LEFT JOIN suspicious_projects s ON t.project_id = s.project_id
WHERE t.latitude IS NOT NULL 
  AND t.longitude IS NOT NULL
  AND t.transaction_amount > 0;

-- -------------------------------------------------------------------------------
-- 6. Project Title Keyword Word Cloud (NLP)
-- Leverages PostgreSQL native full-text search (to_tsvector) for high-performance text mining.
-- -------------------------------------------------------------------------------
SELECT 
    word,
    nentry AS frequency
FROM ts_stat($$
    SELECT to_tsvector('english', project_title) 
    FROM projects 
    WHERE project_title IS NOT NULL
$$)
ORDER BY frequency DESC
LIMIT 50;

-- -------------------------------------------------------------------------------
-- 7. Time Series Financial Execution: Commitments & Disbursements
-- Aggregates total financial metrics over time periods.
-- -------------------------------------------------------------------------------
-- Total Commitments KPI
SELECT 
    DATE_TRUNC('month', start_actual_isodate) AS time_period,
    SUM(total_commitments) AS total_commitments_sum
FROM projects
WHERE start_actual_isodate IS NOT NULL
GROUP BY time_period
ORDER BY time_period ASC;

-- Total Disbursements KPI
SELECT 
    DATE_TRUNC('month', start_actual_isodate) AS time_period,
    SUM(total_disbursements) AS total_disbursements_sum
FROM projects
WHERE start_actual_isodate IS NOT NULL
GROUP BY time_period
ORDER BY time_period ASC;

-- -------------------------------------------------------------------------------
-- 8. High-Level Executive KPIs: Deficit & Top Risk Sectors
-- -------------------------------------------------------------------------------
-- Deficit Ratio KPI
SELECT 
    (SUM(total_commitments) - SUM(total_disbursements)) / NULLIF(SUM(total_commitments), 0) * 100 AS deficit_ratio
FROM projects;



