/*==============================================================================
  ENERGY TRADING DEMO - Energy-Charts API Data Pipeline Setup
  
  This script creates a complete data pipeline for ingesting and analyzing
  European energy market data from the Energy-Charts API, with AI-powered
  semantic search and natural language query capabilities.
  
  Architecture:
    • External Access Integration for Energy-Charts API
    • Raw JSON ingestion tables with change data capture streams  
    • Transformation procedures for incremental processing
    • LLM-generated metadata and documentation
    • Cortex Search services for semantic discovery
    • AI Agent with Cortex Analyst for natural language queries
==============================================================================*/

-------------------------------------------------------------------------------
-- SECTION 1: Account Configuration, Roles & External Access
-------------------------------------------------------------------------------


USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE AI_ENGINEER;
CREATE OR REPLACE NETWORK RULE NR_ENERGY_CHARTS_API
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.energy-charts.info:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EAI_ENERGY_CHARTS
  ALLOWED_NETWORK_RULES = (NR_ENERGY_CHARTS_API)
  ENABLED = TRUE;

-- Grant AI_ENGINEER role access to the external access integration
GRANT USAGE ON INTEGRATION EAI_ENERGY_CHARTS TO ROLE AI_ENGINEER;



USE ROLE AI_ENGINEER;
CREATE SCHEMA IF NOT EXISTS AI_DEVELOPMENT.SI_ENERGY_TRADING_COMPANY;

USE SCHEMA AI_DEVELOPMENT.SI_ENERGY_TRADING_COMPANY;



-------------------------------------------------------------------------------
-- SECTION 2: Database & Schema Creation
-------------------------------------------------------------------------------

-- TIME_SERIES_METADATA: Stores metadata and LLM-generated documentation for each time series
create or alter TABLE TIME_SERIES_METADATA (
	SERIES_ID NUMBER(38,0) NOT NULL autoincrement start 1 increment 1 noorder,
	TIME_SERIES_NAME VARCHAR(16777216) NOT NULL,
	TITLE VARCHAR(16777216),
	DESCRIPTION VARCHAR(16777216),
	COUNTRY VARCHAR(16777216),
	CATEGORY VARCHAR(16777216),
	DATA_QUALITY_NOTES VARCHAR(16777216),
	SOURCE_URL VARCHAR(16777216),
	CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
	UPDATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
	constraint UQ_TS_DOC_NAME unique (TIME_SERIES_NAME),
	primary key (SERIES_ID)
);

-- MARKET_DATA: Core fact table storing time-series values with composite PK (series_id, timestamp, snapshot_at)
-- Supports both historical data (snapshot_at = '1970-01-01') and forecast snapshots (snapshot_at = ingestion time)
create or alter TABLE MARKET_DATA (
	ID NUMBER(38,0) autoincrement start 1 increment 1 noorder,
	SERIES_ID NUMBER(38,0) NOT NULL,
	TIME_SERIES_NAME VARCHAR(16777216) NOT NULL,
	TIMESTAMP TIMESTAMP_NTZ(9) NOT NULL,
	SNAPSHOT_AT TIMESTAMP_NTZ(9) NOT NULL,
	VALUE NUMBER(18,6),
	UNIT VARCHAR(16777216),
	RESOLUTION VARCHAR(16777216),
	DATA_QUALITY_SCORE FLOAT,
	SOURCE_SYSTEM VARCHAR(16777216),
	CREATED_AT TIMESTAMP_NTZ(9),
	METADATA VARIANT,
	constraint UQ_MARKET_DATA_ID unique (ID),
	constraint PK_MARKET_DATA primary key (SERIES_ID, TIMESTAMP, SNAPSHOT_AT)
);

-- SERIES_ID_SEQ: Sequence for generating series IDs in MARKET_DATA table
CREATE OR REPLACE SEQUENCE SERIES_ID_SEQ
START = 1 
INCREMENT = 1;
-------------------------------------------------------------------------------
-- SECTION 3: ENERGY_CHARTS Tables - Raw JSON Ingestion Layer
-------------------------------------------------------------------------------
-- The following tables contain  raw JSON tables for each Energy-Charts API endpoint
-- and corresponding streams for change data capture (CDC) to enable
-- incremental processing in the transformation layer.



-- PUBLIC_POWER_JSON: Raw historical public power generation data by production type
CREATE TABLE IF NOT EXISTS PUBLIC_POWER_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);

CREATE OR REPLACE STREAM STRM_PUBLIC_POWER_JSON
  ON TABLE PUBLIC_POWER_JSON
  APPEND_ONLY = TRUE;

-------------------------------------------------------------------------------
-- SECTION 4: Views - JSON to Normalized Time-Series Transformation
-------------------------------------------------------------------------------
-- These views flatten the raw JSON payloads into normalized time-series format
-- compatible with the MARKET_DATA.MARKET_DATA table structure.

-- VW_PUBLIC_POWER_MARKET_DATA: Flattens public power generation by production type
CREATE OR ALTER VIEW VW_PUBLIC_POWER_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, request_url, payload
  FROM PUBLIC_POWER_JSON
),
ts AS (
  SELECT
    country,
    ingested_at,
    f.value::NUMBER AS epoch_seconds,
    f.index AS ts_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"unix_seconds") f
),
pt AS (
  SELECT
    country,
    ingested_at,
    request_url,
    pt.value:"name"::STRING AS series_name,
    d.value::FLOAT AS series_value,
    d.index AS val_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"production_types") pt,
       LATERAL FLATTEN(input => pt.value:"data") d
),
joined AS (
  SELECT
    p.country,
    p.ingested_at,
    p.request_url,
    p.series_name,
    p.series_value,
    t.epoch_seconds
  FROM pt p
  JOIN ts t
    ON p.country = t.country
   AND p.ingested_at = t.ingested_at
   AND p.val_idx = t.ts_idx
)
SELECT
  ROW_NUMBER() OVER (ORDER BY country, series_name, epoch_seconds) AS id,
  CONCAT('Energy-Charts /public_power ', UPPER(country), ' - ', series_name) AS time_series_name,
  TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
  TO_DECIMAL(series_value, 18, 6) AS value,
  'MW' AS unit,
  '15-minute' AS resolution,
  1.0::FLOAT AS data_quality_score,
  CONCAT('Energy-Charts public_power for country', UPPER(country), ' ', series_name) AS source_system,
  CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
  OBJECT_CONSTRUCT(
    'name', CONCAT('Energy-Charts /public_power ', UPPER(country), ' - ', series_name),
    'country', UPPER(country),
    'type', 'historical',
    'production_type', series_name,
    'endpoint', '/public_power',
    'unit', 'MW',
    'resolution', '15-minute',
    'source', CONCAT('Energy-Charts public_power for country', UPPER(country), ' ', series_name),
    'url', request_url
  ) AS metadata
FROM joined
WHERE series_value IS NOT NULL;

-- CBET_JSON & CBPF_JSON: Cross-border electricity trading and physical flows
CREATE TABLE IF NOT EXISTS CBET_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);
-- Stream for incremental processing
CREATE OR REPLACE STREAM STRM_CBET_JSON
  ON TABLE CBET_JSON
  APPEND_ONLY = TRUE;

CREATE TABLE IF NOT EXISTS CBPF_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);

CREATE OR REPLACE STREAM STRM_CBPF_JSON
  ON TABLE CBPF_JSON
  APPEND_ONLY = TRUE;

-- PUBLIC_POWER_FORECAST_JSON: Day-ahead generation forecasts by production type
CREATE TABLE IF NOT EXISTS PUBLIC_POWER_FORECAST_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);

CREATE OR REPLACE STREAM STRM_PUBLIC_POWER_FORECAST_JSON
  ON TABLE PUBLIC_POWER_FORECAST_JSON
  APPEND_ONLY = TRUE;

-- VW_CBET_MARKET_DATA: Cross-border electricity trading view
create or replace view VW_CBET_MARKET_DATA(
	ID,
	TIME_SERIES_NAME,
	TIMESTAMP,
	VALUE,
	UNIT,
	RESOLUTION,
	DATA_QUALITY_SCORE,
	SOURCE_SYSTEM,
	CREATED_AT,
	METADATA
) as
WITH src AS (
  SELECT country, ingested_at, payload
  FROM CBET_JSON
),
ts AS (
  SELECT
    country,
    ingested_at,
    f.value::NUMBER AS epoch_seconds,
    f.index AS ts_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"unix_seconds") f
),
countries_data AS (
  SELECT
    s.country,
    s.ingested_at,
    c.value:"name"::STRING AS country_name,
    d.value::FLOAT AS series_value,
    d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => s.payload:"countries") c,
       LATERAL FLATTEN(input => c.value:"data") d
)
,
joined AS (
  SELECT
    c.country,
    c.ingested_at,
    c.country_name,
    c.series_value,
    t.epoch_seconds
  FROM countries_data c
  JOIN ts t
    ON c.country = t.country
   AND c.ingested_at = t.ingested_at
   AND c.val_idx = t.ts_idx
)
SELECT
  ROW_NUMBER() OVER (ORDER BY country, country_name, epoch_seconds) AS id,
  CONCAT('Energy-Charts /cbet Cross-Border Electricity Trading (CBET) ', UPPER(country), ' to/from ', country_name) AS time_series_name,
  TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
  TO_DECIMAL(series_value, 18, 6) AS value,
  'MW' AS unit,
  '15-minute' AS resolution,
  1.0::FLOAT AS data_quality_score,
  CONCAT('Energy-Charts Cross-Border Electricity Trading (CBET) for country ', UPPER(country), ' to/from ', country_name) AS source_system,
  CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
  OBJECT_CONSTRUCT(
    'name', CONCAT('Energy-Charts /cbet Cross-Border Electricity Trading (CBET) ', UPPER(country), ' to/from ', country_name),
    'country', UPPER(country),
    'type', 'historical',
    'endpoint', '/cbet',
    'counterparty', country_name
  ) AS metadata
FROM joined
WHERE series_value IS NOT NULL;

-- VW_CBPF_MARKET_DATA: Cross-border physical flows view
CREATE OR ALTER VIEW VW_CBPF_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, payload
  FROM CBPF_JSON
),
ts AS (
  SELECT
    country,
    ingested_at,
    f.value::NUMBER AS epoch_seconds,
    f.index AS ts_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"unix_seconds") f
),
countries_data AS (
  SELECT
    s.country,
    s.ingested_at,
    c.value:"name"::STRING AS country_name,
    d.value::FLOAT AS series_value,
    d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => s.payload:"countries") c,
       LATERAL FLATTEN(input => c.value:"data") d
)
,
joined AS (
  SELECT
    c.country,
    c.ingested_at,
    c.country_name,
    c.series_value,
    t.epoch_seconds
  FROM countries_data c
  JOIN ts t
    ON c.country = t.country
   AND c.ingested_at = t.ingested_at
   AND c.val_idx = t.ts_idx
)
SELECT
  ROW_NUMBER() OVER (ORDER BY country, country_name, epoch_seconds) AS id,
  CONCAT('Energy-Charts /cbpf Cross-Border Physical Flows (cbpf) ', UPPER(country), ' to/from ', country_name) AS time_series_name,
  TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
  TO_DECIMAL(series_value, 18, 6) AS value,
  'MW' AS unit,
  '15-minute' AS resolution,
  1.0::FLOAT AS data_quality_score,
  CONCAT('Energy-Charts Cross-Border Physical Flows (cbpf) for country ', UPPER(country), ' to/from ', country_name) AS source_system,
  CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
  OBJECT_CONSTRUCT(
    'name', CONCAT('Energy-Charts /cbpf Cross-Border Physical Flows (cbpf) ', UPPER(country), ' to/from ', country_name),
    'country', UPPER(country),
    'type', 'historical',
    'endpoint', '/cbpf',
    'counterparty', country_name
  ) AS metadata
FROM joined
WHERE series_value IS NOT NULL;

-- Additional raw tables for other Energy-Charts endpoints
CREATE TABLE IF NOT EXISTS TOTAL_POWER_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);
-- Stream for incremental processing
CREATE OR REPLACE STREAM STRM_TOTAL_POWER_JSON
  ON TABLE TOTAL_POWER_JSON
  APPEND_ONLY = TRUE;

CREATE TABLE IF NOT EXISTS INSTALLED_POWER_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);
-- Stream for incremental processing
CREATE OR REPLACE STREAM STRM_INSTALLED_POWER_JSON
  ON TABLE INSTALLED_POWER_JSON
  APPEND_ONLY = TRUE;

CREATE TABLE IF NOT EXISTS FREQUENCY_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);
-- Stream for incremental processing
CREATE OR REPLACE STREAM STRM_FREQUENCY_JSON
  ON TABLE FREQUENCY_JSON
  APPEND_ONLY = TRUE;

CREATE TABLE IF NOT EXISTS PRICE_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);

CREATE OR REPLACE STREAM STRM_PRICE_JSON
  ON TABLE PRICE_JSON
  APPEND_ONLY = TRUE;

-- Legacy table (endpoint deprecated, kept for backward compatibility)
CREATE TABLE IF NOT EXISTS PRICE_TEST_MTU_CHANGE_JSON (
  ingested_at TIMESTAMP_LTZ,
  country STRING,
  request_url STRING,
  payload VARIANT
);

-- INGEST_ERRORS: Centralized error logging for API ingestion failures
CREATE TABLE IF NOT EXISTS INGEST_ERRORS (
  logged_at TIMESTAMP_LTZ,
  endpoint STRING,
  country STRING,
  status_code NUMBER,
  error_message STRING,
  context VARIANT
);

-- VW_PUBLIC_POWER_FORECAST_MARKET_DATA: Day-ahead generation forecasts
create or replace view VW_PUBLIC_POWER_FORECAST_MARKET_DATA(
	ID,
	TIME_SERIES_NAME,
	TIMESTAMP,
	VALUE,
	UNIT,
	RESOLUTION,
	DATA_QUALITY_SCORE,
	SOURCE_SYSTEM,
	CREATED_AT,
  METADATA
) as
WITH src AS (
  SELECT country, ingested_at, request_url, payload
  FROM PUBLIC_POWER_FORECAST_JSON
),
ts AS (
  SELECT
    country,
    ingested_at,
    f.value::NUMBER AS epoch_seconds,
    f.index AS ts_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"unix_seconds") f
),
pt AS (
  SELECT
    country,
    ingested_at,
    payload:"production_type"::STRING AS series_name,
    d.value::FLOAT AS series_value,
    d.index AS val_idx
  FROM src,
       LATERAL FLATTEN(input => payload:"forecast_values") d
),
joined AS (
  SELECT
    p.country,
    p.ingested_at,
    s.request_url,
    p.series_name,
    p.series_value,
    t.epoch_seconds
  FROM pt p
  JOIN ts t
    ON p.country = t.country
   AND p.ingested_at = t.ingested_at
   AND p.val_idx = t.ts_idx
  JOIN src s ON s.country = p.country AND s.ingested_at = p.ingested_at
)
SELECT
  ROW_NUMBER() OVER (ORDER BY country, series_name, epoch_seconds) AS id,
  CONCAT('Energy-Charts /public_power_forecast ', UPPER(country), ' - ', series_name) AS time_series_name,
  TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
  TO_DECIMAL(series_value, 18, 6) AS value,
  'MW' AS unit,
  '15-minute' AS resolution,
  1.0::FLOAT AS data_quality_score,
  CONCAT('Energy-Charts public_power_forecast for country ', UPPER(country), ' ', series_name) AS source_system,
  CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
  OBJECT_CONSTRUCT(
      'name', CONCAT('Energy-Charts /public_power_forecast ', UPPER(country), ' - ', series_name),
      'country', UPPER(country),
      'type', 'forecast',
      'production_type', series_name,
      'endpoint', '/public_power_forecast',
      'unit', 'MW',
      'resolution', '15-minute',
      'source', CONCAT('Energy-Charts public_power_forecast for country ', UPPER(country), ' ', series_name),
      'url', request_url
    ) AS metadata
FROM joined
WHERE series_value IS NOT NULL;

-- VW_TOTAL_POWER_MARKET_DATA: Total electricity generation including industrial self-supply
CREATE OR ALTER VIEW VW_TOTAL_POWER_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, request_url, payload FROM TOTAL_POWER_JSON
), ts AS (
  SELECT country, ingested_at, f.value::NUMBER AS epoch_seconds, f.index AS ts_idx
  FROM src, LATERAL FLATTEN(input => payload:"unix_seconds") f
), pt AS (
  SELECT s.country, s.ingested_at,
         COALESCE(p.value:"name"::STRING, CONCAT('Total ', p.value:"country"::STRING)) AS series_name,
         d.value::FLOAT AS series_value, d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => COALESCE(s.payload:"production_types", s.payload:"series", s.payload:"values")) p,
       LATERAL FLATTEN(input => COALESCE(p.value:"data", p.value)) d
), joined AS (
  SELECT p.country, p.ingested_at, s.request_url, p.series_name, p.series_value, t.epoch_seconds
  FROM pt p 
  JOIN ts t ON p.country=t.country AND p.ingested_at=t.ingested_at AND p.val_idx=t.ts_idx
  JOIN src s ON s.country = p.country AND s.ingested_at = p.ingested_at
)
SELECT ROW_NUMBER() OVER (ORDER BY country, series_name, epoch_seconds) AS id,
       CONCAT('Energy-Charts /total_power ', UPPER(country), ' - ', series_name) AS time_series_name,
       TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
       TO_DECIMAL(series_value, 18, 6) AS value,
       'MW' AS unit,
       '15-minute' AS resolution,
       1.0::FLOAT AS data_quality_score,
       CONCAT('Energy-Charts total_power for country ', UPPER(country), ' ', series_name) AS source_system,
       CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
       OBJECT_CONSTRUCT(
         'name', CONCAT('Energy-Charts /total_power ', UPPER(country), ' - ', series_name),
         'country', UPPER(country),
         'type', 'historical',
         'production_type', series_name,
         'endpoint', '/total_power',
         'unit', 'MW',
         'resolution', '15-minute',
         'source', CONCAT('Energy-Charts total_power for country ', UPPER(country), ' ', series_name),
         'url', request_url
       ) AS metadata
FROM joined WHERE series_value IS NOT NULL;

-- VW_INSTALLED_POWER_MARKET_DATA: Installed capacity by technology (monthly & yearly)
CREATE OR ALTER VIEW VW_INSTALLED_POWER_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, request_url, payload FROM INSTALLED_POWER_JSON
), ts AS (
  SELECT 
    country, 
    ingested_at, 
    f.value::STRING AS time_str, 
    f.index AS ts_idx
  FROM src, LATERAL FLATTEN(input => payload:"time") f
), pt AS (
  SELECT 
    s.country, 
    s.ingested_at,
    p.value:"name"::STRING AS series_name,
    d.value::FLOAT AS series_value, 
    d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => s.payload:"production_types") p,
       LATERAL FLATTEN(input => p.value:"data") d
), joined AS (
  SELECT 
    p.country, 
    p.ingested_at, 
    s.request_url,
    p.series_name, 
    p.series_value, 
    t.time_str
  FROM pt p 
  JOIN ts t ON p.country = t.country 
           AND p.ingested_at = t.ingested_at 
           AND p.val_idx = t.ts_idx
  JOIN src s ON s.country = p.country AND s.ingested_at = p.ingested_at
)
SELECT 
  ROW_NUMBER() OVER (ORDER BY country, series_name, time_str) AS id,
  CONCAT('Energy-Charts /installed_power ', UPPER(country), ' - ', series_name) AS time_series_name,
  CASE 
    WHEN REGEXP_LIKE(time_str, '^[0-9]{4}-[0-9]{2}$') THEN TO_TIMESTAMP_NTZ(CONCAT(time_str, '-01'))
    WHEN REGEXP_LIKE(time_str, '^[0-9]{2}\\.[0-9]{4}$') THEN TO_TIMESTAMP_NTZ(CONCAT(SUBSTR(time_str, 4, 4), '-', SUBSTR(time_str, 1, 2), '-01'))
    ELSE TO_TIMESTAMP_NTZ(CONCAT(time_str, '-01-01'))
  END AS timestamp,
  TO_DECIMAL(series_value, 18, 6) AS value,
  'MW' AS unit,
  CASE 
    WHEN REGEXP_LIKE(time_str, '^[0-9]{4}-[0-9]{2}$') THEN 'monthly'
    WHEN REGEXP_LIKE(time_str, '^[0-9]{2}\\.[0-9]{4}$') THEN 'monthly'
    ELSE 'yearly'
  END AS resolution,
  1.0::FLOAT AS data_quality_score,
  CONCAT('Energy-Charts installed_power for country ', UPPER(country), ' ', series_name) AS source_system,
  CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
  OBJECT_CONSTRUCT(
    'name', CONCAT('Energy-Charts /installed_power ', UPPER(country), ' - ', series_name),
    'country', UPPER(country),
    'type', 'historical',
    'production_type', series_name,
    'endpoint', '/installed_power',
    'unit', 'MW',
    'resolution', CASE 
      WHEN REGEXP_LIKE(time_str, '^[0-9]{4}-[0-9]{2}$') THEN 'monthly'
      WHEN REGEXP_LIKE(time_str, '^[0-9]{2}\\.[0-9]{4}$') THEN 'monthly'
      ELSE 'yearly'
    END,
    'source', CONCAT('Energy-Charts installed_power for country ', UPPER(country), ' ', series_name),
    'url', request_url
  ) AS metadata
FROM joined 
WHERE series_value IS NOT NULL;

-- VW_FREQUENCY_MARKET_DATA: Grid frequency measurements (1-minute resolution)
CREATE OR ALTER VIEW VW_FREQUENCY_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, request_url, payload FROM FREQUENCY_JSON
), ts AS (
  SELECT country, ingested_at, f.value::NUMBER AS epoch_seconds, f.index AS ts_idx
  FROM src, LATERAL FLATTEN(input => payload:"unix_seconds") f
), dt AS (
  SELECT s.country, s.ingested_at,
         d.value::FLOAT AS series_value, d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => s.payload:"data") d
), joined AS (
  SELECT d.country, d.ingested_at, s.request_url, 'Grid Frequency' AS series_name, d.series_value, t.epoch_seconds
  FROM dt d JOIN ts t ON d.country=t.country AND d.ingested_at=t.ingested_at AND d.val_idx=t.ts_idx
  JOIN src s ON s.country = d.country AND s.ingested_at = d.ingested_at
)
SELECT ROW_NUMBER() OVER (ORDER BY country, series_name, epoch_seconds) AS id,
       CONCAT('Energy-Charts /frequency ', UPPER(country), ' - ', series_name) AS time_series_name,
       TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
       TO_DECIMAL(series_value, 18, 6) AS value,
       'Hz' AS unit,
       '1-minute' AS resolution,
       1.0::FLOAT AS data_quality_score,
       CONCAT('Energy-Charts frequency for country ', UPPER(country), ' ', series_name) AS source_system,
       CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
       OBJECT_CONSTRUCT(
         'name', CONCAT('Energy-Charts /frequency ', UPPER(country), ' - ', series_name),
         'country', UPPER(country),
         'type', 'historical',
         'endpoint', '/frequency',
         'unit', 'Hz',
         'resolution', '1-minute',
    'source', CONCAT('Energy-Charts frequency for country ', UPPER(country), ' ', series_name),
    'url', request_url
       ) AS metadata
FROM joined WHERE series_value IS NOT NULL;

-- VW_PRICE_MARKET_DATA: Day-ahead electricity prices by bidding zone
CREATE OR ALTER VIEW VW_PRICE_MARKET_DATA AS
WITH src AS (
  SELECT country, ingested_at, request_url, payload FROM PRICE_JSON
), ts AS (
  SELECT country, ingested_at, f.value::NUMBER AS epoch_seconds, f.index AS ts_idx
  FROM src, LATERAL FLATTEN(input => payload:"unix_seconds") f
), pt AS (
  SELECT s.country, s.ingested_at,
         'Price' AS series_name,
         d.value::FLOAT AS series_value, d.index AS val_idx
  FROM src s,
       LATERAL FLATTEN(input => s.payload:"price") d
), joined AS (
  SELECT p.country, p.ingested_at, s.request_url, p.series_name, p.series_value, t.epoch_seconds
  FROM pt p JOIN ts t ON p.country=t.country AND p.ingested_at=t.ingested_at AND p.val_idx=t.ts_idx
  JOIN src s ON s.country = p.country AND s.ingested_at = p.ingested_at
)
SELECT ROW_NUMBER() OVER (ORDER BY country, series_name, epoch_seconds) AS id,
       CONCAT('Energy-Charts /price day-ahead for country ', UPPER(country), ' - ', series_name) AS time_series_name,
       TO_TIMESTAMP_NTZ(epoch_seconds) AS timestamp,
       TO_DECIMAL(series_value, 18, 6) AS value,
       'EUR/MWh' AS unit,
       'hourly' AS resolution,
       1.0::FLOAT AS data_quality_score,
       CONCAT('Energy-Charts price day-ahead for country ', UPPER(country), ' ', series_name) AS source_system,
       CAST(ingested_at AS TIMESTAMP_NTZ) AS created_at,
       OBJECT_CONSTRUCT(
         'name', CONCAT('Energy-Charts /price day-ahead for country ', UPPER(country), ' - ', series_name),
         'country', UPPER(country),
         'type', 'day-ahead',
    'endpoint', '/price',
    'unit', 'EUR/MWh',
    'resolution', 'hourly',
    'source', CONCAT('Energy-Charts price day-ahead for country ', UPPER(country), ' ', series_name),
    'url', request_url
       ) AS metadata
FROM joined WHERE series_value IS NOT NULL;

-------------------------------------------------------------------------------
-- SECTION 5: Data Ingestion Procedures
-------------------------------------------------------------------------------
-- These Python stored procedures fetch data from the Energy-Charts API
-- and store raw JSON responses in the appropriate tables.

-- INGEST_FORECAST_ENDPOINTS: Fetches day-ahead forecast data
-- Endpoints: /public_power_forecast, /price (day-ahead)
-- Note: Deletes previous forecast snapshots to keep only the latest
CREATE OR REPLACE PROCEDURE INGEST_FORECAST_ENDPOINTS(
  COUNTRIES ARRAY,
  INCLUDE_PRICE BOOLEAN
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = 3.10
PACKAGES = ('snowflake-snowpark-python','requests')
EXTERNAL_ACCESS_INTEGRATIONS = (EAI_ENERGY_CHARTS)
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import requests
from typing import Any, Dict, List, Optional
from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, current_timestamp, to_variant
from datetime import datetime
from zoneinfo import ZoneInfo

BASE_URL = "https://api.energy-charts.info"

SUPPORTED_COUNTRIES = ["de", "nl", "fr", "uk"]

LOCAL_TZ = ZoneInfo("Europe/Berlin")

COUNTRY_TO_BZN = {
    "de": "DE-LU",
    "nl": "NL",
    "fr": "FR",
    "uk": None
}

ENDPOINTS = {
    "public_power_forecast": "/public_power_forecast",
    "price": "/price",
}

RAW_TABLES = {
    "public_power_forecast": "PUBLIC_POWER_FORECAST_JSON",
    "price": "PRICE_JSON",
}

def fetch_json(path: str, params: Dict[str, Any]) -> Dict[str, Any]:
    url = BASE_URL + path
    r = requests.get(url, params=params, timeout=60)
    r.raise_for_status()
    return {"_request_url": r.url, "_payload": r.json()}

def capture_error(errors: List[Dict[str, Any]], endpoint: str, country: str, exc: Exception, params: Dict[str, Any]) -> None:
    status_code: Optional[int] = None
    message = str(exc)
    try:
        if hasattr(exc, 'response') and exc.response is not None:
            status_code = exc.response.status_code
            try:
                message = f"{message} | body={exc.response.text[:1000]}"
            except Exception:
                pass
    except Exception:
        pass
    errors.append({
        "logged_at": None,
        "endpoint": endpoint,
        "country": country,
        "status_code": status_code,
        "error_message": message,
        "context": {"params": params}
    })

def run(session: Session, COUNTRIES: list = None, INCLUDE_PRICE: bool = True) -> str:
    countries = [c.lower() for c in (COUNTRIES or ["de", "nl", "fr", "uk"]) if c.lower() in SUPPORTED_COUNTRIES]
    forecast_type = "day-ahead"
    production_types = ["solar", "wind_onshore", "wind_offshore", "load"]

    raw_batches: Dict[str, List[Dict[str, Any]]] = {k: [] for k in RAW_TABLES.keys()}
    errors: List[Dict[str, Any]] = []

    # Current day in Europe/Berlin for forecasting endpoints
    today_start = datetime.now(LOCAL_TZ).date().strftime("%Y-%m-%d")

    for code in countries:
        # Overwrite previous forecast entries for this country; keep only latest snapshot
        try:
            session.sql(f"DELETE FROM PUBLIC_POWER_FORECAST_JSON WHERE country = '{code}'").collect()
        except Exception:
            pass
        for ptype in production_types:
            params = {"country": code, "production_type": ptype, "forecast_type": forecast_type, "start": today_start}
            try:
                resp = fetch_json(ENDPOINTS["public_power_forecast"], params)
                raw_batches["public_power_forecast"].append({"country": code, "request_url": resp.get("_request_url"), "payload": resp.get("_payload")})
            except Exception as exc:
                capture_error(errors, "public_power_forecast", code, exc, params)

        if INCLUDE_PRICE:
            bzn = COUNTRY_TO_BZN.get(code)
            if bzn:
                params = {"bzn": bzn, "forecast_type": forecast_type}
                try:
                    resp = fetch_json(ENDPOINTS["price"], params)
                    raw_batches["price"].append({"country": code, "request_url": resp.get("_request_url"), "payload": resp.get("_payload")})
                except Exception as exc:
                    capture_error(errors, "price", code, exc, params)
            else:
                # Explicitly log unsupported zones as an error event
                errors.append({
                    "logged_at": None,
                    "endpoint": "price",
                    "country": code,
                    "status_code": None,
                    "error_message": "Unsupported or missing billing zone for country",
                    "context": {"params": {"country": code}}
                })

    inserted = 0
    for ep, rows in raw_batches.items():
        if not rows:
            continue
        df = session.create_dataframe(rows)
        df = df.with_column("ingested_at", current_timestamp())
        df = df.select("ingested_at", "country", col("request_url"), to_variant(col("payload")).alias("payload"))
        df.write.mode("append").save_as_table(RAW_TABLES[ep])
        inserted += df.count()

    if errors:
        df_err = session.create_dataframe(errors)
        df_err = df_err.with_column("logged_at", current_timestamp())
        df_err = df_err.select("logged_at", "endpoint", "country", col("status_code"), col("error_message"), to_variant(col("context")).alias("context"))
        df_err.write.mode("append").save_as_table("INGEST_ERRORS")

    return f"Inserted forecast/day-ahead batches for {len(countries)} countries; approx rows inserted: {inserted}; errors logged: {len(errors)}"
$$;

-- INGEST_HISTORICAL_ENDPOINTS_RAW: Fetches historical time-series data
-- Endpoints: /public_power, /total_power, /installed_power, /frequency, /cbet, /cbpf
-- Note: Supports date range filtering via START_DATE and END_DATE parameters
CREATE OR REPLACE PROCEDURE INGEST_HISTORICAL_ENDPOINTS_RAW(
  COUNTRIES ARRAY,
  INCLUDE_CROSS_BORDER BOOLEAN,
  START_DATE STRING,
  END_DATE STRING
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = 3.10
PACKAGES = ('snowflake-snowpark-python','requests')
EXTERNAL_ACCESS_INTEGRATIONS = (EAI_ENERGY_CHARTS)
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import requests
from typing import Any, Dict, List, Optional
from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, current_timestamp, to_variant
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

BASE_URL = "https://api.energy-charts.info"
SUPPORTED_COUNTRIES = ["de", "nl", "fr", "uk"]
LOCAL_TZ = ZoneInfo("Europe/Berlin")

ENDPOINTS = {
    "public_power": "/public_power",
    "total_power": "/total_power",
    "installed_power": "/installed_power",
    "frequency": "/frequency",
    "cbet": "/cbet",
    "cbpf": "/cbpf",
}

RAW_TABLES = {
    "public_power": "PUBLIC_POWER_JSON",
    "total_power": "TOTAL_POWER_JSON",
    "installed_power": "INSTALLED_POWER_JSON",
    "frequency": "FREQUENCY_JSON",
    "cbet": "CBET_JSON",
    "cbpf": "CBPF_JSON",
}

def fetch_json(path: str, params: Dict[str, Any]) -> Dict[str, Any]:
    url = BASE_URL + path
    r = requests.get(url, params=params, timeout=60)
    r.raise_for_status()
    return {"_request_url": r.url, "_payload": r.json()}

def run(session: Session, COUNTRIES: list = None, INCLUDE_CROSS_BORDER: bool = True, START_DATE: str = None, END_DATE: str = None) -> str:
    countries = [c.lower() for c in (COUNTRIES or ["de", "nl", "fr", "uk"]) if c.lower() in SUPPORTED_COUNTRIES]
    # Defaults: if start is null → previous day; if end is null → omit parameter
    if isinstance(START_DATE, str) and START_DATE.strip():
        start_param = START_DATE.strip()
    else:
        start_param = (datetime.now(LOCAL_TZ).date() - timedelta(days=1)).strftime("%Y-%m-%d")

    if isinstance(END_DATE, str) and END_DATE.strip():
        end_param = END_DATE.strip()
    else:
        end_param = datetime.now(LOCAL_TZ).date().strftime("%Y-%m-%d")

    raw_batches: Dict[str, List[Dict[str, Any]]] = {k: [] for k in RAW_TABLES.keys()}
    inserted = 0
    errors: List[Dict[str, Any]] = []

    for code in countries:
        # public_power, total_power, frequency use start/end window
        for ep in ["public_power", "total_power", "frequency"]:
            params = {"country": code, "start": start_param}
            if end_param:
                params["end"] = end_param
            try:
                resp = fetch_json(ENDPOINTS[ep], params)
                raw_batches[ep].append({"country": code, "request_url": resp.get("_request_url"), "payload": resp.get("_payload")})
            except Exception as exc:
                errors.append({
                    "logged_at": None,
                    "endpoint": ep,
                    "country": code,
                    "status_code": None,
                    "error_message": str(exc),
                    "context": {"params": params}
                })

        # installed_power supports only country and time_step; use monthly
        ip_params = {"country": code, "time_step": "monthly"}
        try:
            resp = fetch_json(ENDPOINTS["installed_power"], ip_params)
            raw_batches["installed_power"].append({"country": code, "request_url": resp.get("_request_url"), "payload": resp.get("_payload")})
        except Exception as exc:
            errors.append({
                "logged_at": None,
                "endpoint": "installed_power",
                "country": code,
                "status_code": None,
                "error_message": str(exc),
                "context": {"params": ip_params}
            })

        if INCLUDE_CROSS_BORDER:
            for ep in ["cbet", "cbpf"]:
                params = {"country": code, "start": start_param}
                if end_param:
                    params["end"] = end_param
                try:
                    resp = fetch_json(ENDPOINTS[ep], params)
                    raw_batches[ep].append({"country": code, "request_url": resp.get("_request_url"), "payload": resp.get("_payload")})
                except Exception as exc:
                    errors.append({
                        "logged_at": None,
                        "endpoint": ep,
                        "country": code,
                        "status_code": None,
                        "error_message": str(exc),
                        "context": {"params": params}
                    })

    for ep, rows in raw_batches.items():
        if not rows:
            continue
        df = session.create_dataframe(rows)
        df = df.with_column("ingested_at", current_timestamp())
        df = df.select("ingested_at", "country", col("request_url"), to_variant(col("payload")).alias("payload"))
        df.write.mode("append").save_as_table(RAW_TABLES[ep])
        inserted += df.count()

    # Write errors to error table (events)
    if errors:
        df_err = session.create_dataframe(errors)
        df_err = df_err.with_column("logged_at", current_timestamp())
        df_err = df_err.select("logged_at", "endpoint", "country", col("status_code"), col("error_message"), to_variant(col("context")).alias("context"))
        df_err.write.mode("append").save_as_table("INGEST_ERRORS")

    return f"Inserted historical endpoint batches for {len(countries)} countries; approx rows inserted: {inserted}; errors logged: {len(errors)}"
$$;

-------------------------------------------------------------------------------
-- SECTION 6: Metadata & Transformation Procedures
-------------------------------------------------------------------------------
-- These SQL procedures manage time-series metadata and transform raw JSON
-- into normalized market data using incremental stream processing.

-- SEED_TIME_SERIES_METADATA_FROM_VIEWS: Initializes metadata table with all time series names
CREATE OR REPLACE PROCEDURE SEED_TIME_SERIES_METADATA_FROM_VIEWS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  INSERT INTO TIME_SERIES_METADATA (
    series_id, time_series_name, created_at, updated_at
  )
  SELECT SERIES_ID_SEQ.NEXTVAL AS series_id, s.time_series_name, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
  FROM (
    SELECT DISTINCT time_series_name FROM VW_PUBLIC_POWER_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_PUBLIC_POWER_FORECAST_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_TOTAL_POWER_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_INSTALLED_POWER_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_FREQUENCY_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_CBET_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_CBPF_MARKET_DATA
    UNION ALL
    SELECT DISTINCT time_series_name FROM VW_PRICE_MARKET_DATA
  ) s
  WHERE NOT EXISTS (
    SELECT 1 FROM TIME_SERIES_METADATA d
    WHERE d.time_series_name = s.time_series_name
  );

  RETURN 'Seeded documentation series IDs for distinct time series names.';
END;
$$;





-- TRANSFORM_MARKET_DATA_FROM_VIEWS: Main transformation procedure
-- Processes records from views, deduplicates, and merges into MARKET_DATA
-- Parameters:
--   FULL_LOAD (default FALSE): When TRUE, processes all data; when FALSE, only new data from streams
-- Uses composite primary key (series_id, timestamp, snapshot_at) for upserts
CREATE OR REPLACE PROCEDURE TRANSFORM_MARKET_DATA_FROM_VIEWS(FULL_LOAD BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  -- Materialize deduped sources into temp tables (incremental or full load based on parameter)
  CREATE OR REPLACE TEMP TABLE _TMP_PUBLIC_POWER AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_PUBLIC_POWER_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_PUBLIC_POWER_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_PUBLIC_POWER_FORECAST AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp, created_at ORDER BY created_at DESC) AS rn
    FROM VW_PUBLIC_POWER_FORECAST_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_PUBLIC_POWER_FORECAST_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_TOTAL_POWER AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_TOTAL_POWER_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_TOTAL_POWER_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_INSTALLED_POWER AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_INSTALLED_POWER_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_INSTALLED_POWER_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_FREQUENCY AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_FREQUENCY_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_FREQUENCY_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_PRICE AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_PRICE_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_PRICE_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_CBET AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_CBET_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_CBET_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  CREATE OR REPLACE TEMP TABLE _TMP_CBPF AS
  SELECT v.time_series_name, v.timestamp, v.value, v.unit, v.resolution, v.data_quality_score, v.source_system, v.created_at, v.metadata
  FROM (
    SELECT time_series_name, timestamp, value, unit, resolution, data_quality_score, source_system, created_at, metadata,
           ROW_NUMBER() OVER (PARTITION BY time_series_name, timestamp ORDER BY created_at DESC) AS rn
    FROM VW_CBPF_MARKET_DATA
    WHERE :FULL_LOAD OR EXISTS (
      SELECT 1 FROM STRM_CBPF_JSON s
      WHERE s.ingested_at = created_at
    )
  ) v
  WHERE rn = 1;

  -- MERGEs from temp tables (lookup series_id from TIME_SERIES_METADATA)
  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_PUBLIC_POWER s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_PUBLIC_POWER_FORECAST s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = s.created_at
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, s.created_at, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_TOTAL_POWER s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_INSTALLED_POWER s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_FREQUENCY s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_PRICE s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = s.created_at
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, s.created_at, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_CBET s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  MERGE INTO MARKET_DATA t
  USING (
    SELECT m.series_id AS series_id,
           s.time_series_name, s.timestamp, s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata
    FROM _TMP_CBPF s
    LEFT JOIN TIME_SERIES_METADATA m ON s.time_series_name = m.time_series_name
  ) s
  ON t.time_series_name = s.time_series_name AND t.timestamp = s.timestamp AND t.snapshot_at = TO_TIMESTAMP_NTZ('1970-01-01')
  WHEN NOT MATCHED THEN INSERT (series_id, time_series_name, timestamp, snapshot_at, value, unit, resolution, data_quality_score, source_system, created_at, metadata)
  VALUES (s.series_id, s.time_series_name, s.timestamp, TO_TIMESTAMP_NTZ('1970-01-01'), s.value, s.unit, s.resolution, s.data_quality_score, s.source_system, s.created_at, s.metadata);

  DROP TABLE IF EXISTS _TMP_PUBLIC_POWER;
  DROP TABLE IF EXISTS _TMP_PUBLIC_POWER_FORECAST;
  DROP TABLE IF EXISTS _TMP_TOTAL_POWER;
  DROP TABLE IF EXISTS _TMP_INSTALLED_POWER;
  DROP TABLE IF EXISTS _TMP_FREQUENCY;
  DROP TABLE IF EXISTS _TMP_PRICE;
  DROP TABLE IF EXISTS _TMP_CBET;
  DROP TABLE IF EXISTS _TMP_CBPF;

  RETURN 'Transform completed successfully.';
END
$$;


-------------------------------------------------------------------------------
-- SECTION 7: AI-Powered Features
-------------------------------------------------------------------------------
-- This section includes LLM-powered metadata generation, Cortex Search services,
-- semantic views, and AI agents for natural language querying.

USE ROLE AI_ENGINEER;
USE WAREHOUSE AI_WH;
USE DATABASE ENERGY_TRADING_DEMO;
USE SCHEMA MARKET_DATA;

-- GENERATE_LLM_TIME_SERIES_METADATA: Uses Cortex LLM to generate business-friendly documentation
-- Generates 50-100 word descriptions for each time series using Claude
CREATE OR REPLACE PROCEDURE GENERATE_LLM_TIME_SERIES_METADATA()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  model_name STRING DEFAULT 'claude-4-sonnet';
  doc_count NUMBER;
BEGIN
  -- Ensure documentation table has all current series names
  CALL SEED_TIME_SERIES_METADATA_FROM_VIEWS();

  /* Generate concise descriptions (50–100 words) for each series in documentation table */
  CREATE OR REPLACE TEMP TABLE _TMP_TS_DOCS AS
  WITH meta AS (
    SELECT
      d.series_id,
      d.time_series_name,
      /* derive details from current MARKET_DATA when available */
      (SELECT ANY_VALUE(md.unit) FROM MARKET_DATA md WHERE md.time_series_name = d.time_series_name) AS unit,
      (SELECT ANY_VALUE(md.resolution) FROM MARKET_DATA md WHERE md.time_series_name = d.time_series_name) AS resolution,
      (SELECT ANY_VALUE(md.source_system) FROM MARKET_DATA md WHERE md.time_series_name = d.time_series_name) AS source_system,
      REGEXP_SUBSTR(d.time_series_name, '/[a-z_]+') AS endpoint_token,
      REGEXP_SUBSTR(d.time_series_name, '/[a-z_]+\\s+([A-Z]{2})', 1, 1, 'c', 1) AS country_code
    FROM TIME_SERIES_METADATA d
  ), docs AS (
    SELECT
      series_id,
      time_series_name,
      unit,
      resolution,
      source_system,
      endpoint_token,
      country_code,
      COALESCE(CONCAT('https://api.energy-charts.info', endpoint_token), 'https://api.energy-charts.info/') AS endpoint_url,
      'https://api.energy-charts.info/' AS docs_url,
      COALESCE(
        CASE endpoint_token
          WHEN '/public_power' THEN 'Returns public net electricity production for a given country by production type; subtype "solarlog" for CH.'
          WHEN '/public_power_forecast' THEN 'Forecast of public net electricity production for a given country by production type. production_type in {solar, wind_onshore, wind_offshore, load}; forecast_type in {current, intraday, day-ahead}; for load only day-ahead.'
          WHEN '/total_power' THEN 'Total net electricity production (incl. industrial self-supply) by production type; currently only available for Germany.'
          WHEN '/installed_power' THEN 'Installed power by production type; unit GW (battery capacity in GWh). Monthly installation/decommission in MW. time_step can be yearly or monthly (monthly only DE). Optional installation_decommission flag.'
          WHEN '/frequency' THEN 'Grid frequency measured at Fraunhofer ISE (Freiburg) for RG Continental Europe (formerly UCTE). Underlying data available in 1-second timesteps from 2022-05-01.'
          WHEN '/price' THEN 'Day-ahead spot market price (EUR/MWh) for specified bidding zone. Some zones licensed CC BY 4.0 from SMARD.de; others are for private/internal use only; commercial reuse requires licensing from data providers (e.g., EPEX SPOT).'
          WHEN '/cbet' THEN 'Cross-border electricity trading (GW) between a country and neighbors; positive = import, negative = export.'
          WHEN '/cbpf' THEN 'Cross-border physical flows (GW) between a country and neighbors; positive = import, negative = export.'
        END,
        'Energy-Charts time series endpoint.'
      ) AS endpoint_context,
      CONCAT('Business overview: ', time_series_name) AS title,
      CONCAT(
        'You are an energy markets analyst. Write a concise, business-oriented description (50–100 words) for the following energy time series. ',
        'Include explicitly: name ("', time_series_name, '"), unit (', COALESCE(unit, 'N/A'), '), resolution (', COALESCE(resolution, 'N/A'), '), and source (', COALESCE(source_system, 'Energy-Charts'), '). ',
        'Also reference the Energy-Charts chart API endpoint (', COALESCE(endpoint_token, 'N/A'), ') and the documentation at https://api.energy-charts.info/. ',
        'Use the following endpoint context in your explanation: ', endpoint_context, '. ',
        'Paraphrase and incorporate this context in clear, business-friendly prose, including key parameter options and constraints when relevant. ',
        'Explain business relevance for trading, hedging, portfolio optimization, and risk management; typical analytics; and key caveats (latency, revisions). ',
        'Write in a neutral, informative tone, in a single coherent paragraph without bullets. Limit strictly to 50–100 words.'
      ) AS prompt
    FROM meta
  ), completions AS (
    SELECT
      d.series_id,
      d.time_series_name,
      d.title,
      d.endpoint_url,
      d.docs_url,
      d.country_code,
      SNOWFLAKE.CORTEX.COMPLETE(:model_name, d.prompt)::STRING AS description
    FROM docs d
  )
  SELECT
    c.series_id,
    c.time_series_name,
    c.title,
    c.description,
    c.country_code AS country,
    /* lightweight defaults; can be refined later */
    NULL::STRING AS category,
    NULL::STRING AS data_quality_notes,
    c.endpoint_url AS source_url,
    CURRENT_TIMESTAMP() AS created_at,
    CURRENT_TIMESTAMP() AS updated_at
  FROM completions c;

  MERGE INTO TIME_SERIES_METADATA t
  USING _TMP_TS_DOCS s
  ON t.time_series_name = s.time_series_name
  WHEN MATCHED THEN UPDATE SET
    t.series_id = s.series_id,
    t.title = s.title,
    t.description = s.description,
    t.country = s.country,
    t.category = s.category,
    t.data_quality_notes = s.data_quality_notes,
    t.source_url = s.source_url,
    t.updated_at = s.updated_at
  WHEN NOT MATCHED THEN INSERT (
    series_id, time_series_name, title, description, country, category, data_quality_notes, source_url, created_at, updated_at
  ) VALUES (
    s.series_id, s.time_series_name, s.title, s.description, s.country, s.category, s.data_quality_notes, s.source_url, s.created_at, s.updated_at
  );

  SELECT COUNT(*) INTO :doc_count FROM TIME_SERIES_METADATA;

  DROP TABLE IF EXISTS _TMP_TS_DOCS;

  RETURN 'LLM documentation generated/upserted. Total rows now: ' || doc_count;
END;
$$;

-- SEND_EMAIL: Utility procedure for sending HTML emails (used by AI Agent)
CREATE OR ALTER PROCEDURE SEND_EMAIL(
  RECIPIENT VARCHAR,
  SUBJECT VARCHAR,
  TEXT VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'send_email'
EXECUTE AS OWNER
AS
$$
from snowflake.snowpark import Session

def send_email(session: Session, recipient: str, subject: str, text: str) -> str:
    """
    Sends an email using Snowflake's email functionality.
    
    Args:
        session (Session): Active Snowflake Snowpark session
        recipient (str): Email address of the recipient
        subject (str): Subject line of the email
        text (str): Body content of the email (will be sent as HTML)
    
    Returns:
        str: Confirmation message indicating email was sent
    """
    session.call(
        'SYSTEM$SEND_EMAIL',
        'ai_email_int',
        recipient,
        subject,
        text,
        'text/html'
    )
    
    # Return a confirmation message
    return f'Email was sent to {recipient} with subject: "{subject}".'
$$;

-- ENERGY_TIME_SERIES_SEARCH: Semantic search on time series descriptions
-- Enables natural language queries to find relevant time series by meaning
CREATE OR REPLACE CORTEX SEARCH SERVICE ENERGY_TIME_SERIES_SEARCH
  ON DESCRIPTION
  ATTRIBUTES SERIES_ID,TIME_SERIES_NAME,TITLE,COUNTRY,SOURCE_URL
  WAREHOUSE = AI_WH
  TARGET_LAG = '30 days'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
  INITIALIZE = ON_CREATE 
  COMMENT = 'Time Series Description Search'
  AS  (
	SELECT
		DESCRIPTION,
		SERIES_ID,
		TIME_SERIES_NAME,
		TITLE,
		COUNTRY,
		SOURCE_URL
	FROM TIME_SERIES_METADATA
);

-- TIME_SERIES_SEARCH: Semantic search on time series names
-- Enables fuzzy matching and similarity search on time series identifiers
CREATE OR REPLACE CORTEX SEARCH SERVICE TIME_SERIES_SEARCH
  ON TIME_SERIES_NAME
  ATTRIBUTES TIME_SERIES_NAME,SERIES_ID,DESCRIPTION,TITLE,COUNTRY
  WAREHOUSE = AI_WH
  TARGET_LAG = '30 days'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
  INITIALIZE = ON_CREATE 
  COMMENT = 'Time Series Name Search'
  AS  (
	SELECT
		TIME_SERIES_NAME,
		SERIES_ID,
		DESCRIPTION,
		TITLE,
		COUNTRY
	FROM TIME_SERIES_METADATA
);

-- ENERGY_TRADING_TIME_SERIES: Semantic view for Cortex Analyst
-- Defines the schema, relationships, and business semantics for natural language queries
create or replace semantic view ENERGY_TRADING_TIME_SERIES
	tables (
		MARKET_DATA primary key (ID),
		TIME_SERIES_METADATA primary key (SERIES_ID)
	)
	relationships (
		JOIN as MARKET_DATA(SERIES_ID) references TIME_SERIES_METADATA(SERIES_ID)
	)
	facts (
		MARKET_DATA.VALUE as VALUE with synonyms=('amount','count','figure','level','magnitude','measure','number','quantity','reading') comment='The VALUE column represents the financial value of a market-related transaction, event, or metric, measured in a monetary unit, with positive values indicating gains or increases and negative values indicating losses or decreases.'
	)
	dimensions (
		MARKET_DATA.DATA_QUALITY_SCORE as DATA_QUALITY_SCORE with synonyms=('accuracy_rating','confidence_level','data_accuracy','data_precision_score','data_reliability_score','quality_rating','validity_score') comment='A score indicating the reliability and accuracy of the market data, with higher values representing higher quality data.',
		MARKET_DATA.ID as ID with synonyms=('identifier','key_id','primary_key','record_id','row_id','row_identifier','unique_id','unique_identifier') comment='Unique identifier for each market data record.',
		MARKET_DATA.METADATA as METADATA with synonyms=('additional_info','attributes','auxiliary_data','details','extra_attributes','extra_data','properties','supplementary_info') comment='Metadata is additional information that provides context about the market data, such as data source, creation date, update frequency, or other attributes that describe the characteristics of the data.',
		MARKET_DATA.RESOLUTION as RESOLUTION with synonyms=('accuracy','detail_level','frequency','granularity','interval','precision','scale','scope') comment='The frequency at which market data is aggregated and reported, with options including 1-minute, 15-minute, and hourly intervals.',
		MARKET_DATA.SOURCE_SYSTEM as SOURCE_SYSTEM with synonyms=('data_origin','data_provider','data_source','origin_system','source_of_data','system_of_origin','system_source') comment='The source system from which the market data is obtained, indicating the regional transmission organization or independent system operator that provided the data.',
		MARKET_DATA.TIMESTAMP as TIMESTAMP with synonyms=('creation_time','date','datetime','entry_time','event_time','log_time','record_time','time') comment='Date and time at which the market data was recorded, with a one-minute granularity.',
		MARKET_DATA.TIME_SERIES_NAME as TIME_SERIES_NAME with synonyms=('data_series','data_stream_name','metric_id','metric_name','series_name','signal_name','time_series_id') comment='The name of the time series being reported, such as a specific electricity market price or load forecast.',
		MARKET_DATA.UNIT as UNIT with synonyms=('measurement_type','measurement_unit','unit_code','unit_description','unit_label','unit_name','unit_of_measurement','unit_type') comment='Unit of measurement for market data values, indicating the currency and unit of the data point, such as price per megawatt-hour or megawatt capacity.',
		TIME_SERIES_METADATA.CATEGORY as CATEGORY,
		TIME_SERIES_METADATA.COUNTRY as COUNTRY,
		TIME_SERIES_METADATA.DATA_QUALITY_NOTES as DATA_QUALITY_NOTES,
		TIME_SERIES_METADATA.DESCRIPTION as DESCRIPTION with cortex search service ENERGY_TIME_SERIES_SEARCH,
		TIME_SERIES_METADATA.SERIES_ID as SERIES_ID,
		TIME_SERIES_METADATA.SOURCE_URL as SOURCE_URL,
		TIME_SERIES_METADATA.TIME_SERIES_NAME as TIME_SERIES_NAME with cortex search service TIME_SERIES_SEARCH,
		TIME_SERIES_METADATA.TITLE as TITLE
	)
	with extension (CA='{"tables":[{"name":"MARKET_DATA","dimensions":[{"name":"DATA_QUALITY_SCORE","sample_values":["1"]},{"name":"ID","sample_values":["1","2","3"]},{"name":"METADATA"},{"name":"RESOLUTION","sample_values":["1-minute","15-minute","hourly"]},{"name":"SOURCE_SYSTEM","sample_values":["PJM_RT_SYSTEM","ERCOT_SCADA","NORD_POOL_TSO"]},{"name":"TIME_SERIES_NAME"},{"name":"TIMESTAMP","sample_values":["2024-01-01T00:00:00.000+0000","2024-01-01T00:01:00.000+0000","2024-01-01T00:02:00.000+0000"]},{"name":"UNIT","sample_values":["USD/MWh","MW","EUR/MWh"]}],"facts":[{"name":"VALUE","sample_values":["2000.000000","-1000.000000","85000.000000"]}]},{"name":"TIME_SERIES_METADATA","dimensions":[{"name":"CATEGORY"},{"name":"COUNTRY"},{"name":"DATA_QUALITY_NOTES"},{"name":"DESCRIPTION"},{"name":"SERIES_ID"},{"name":"SOURCE_URL"},{"name":"TIME_SERIES_NAME"},{"name":"TITLE"}]}],"relationships":[{"name":"JOIN"}],"verified_queries":[{"name":"Check for missing data in the German public residual load dataset for the last 4 weeks. Analyze data completeness by checking for gaps in timestamps, missing values, and data availability patterns. Include total expected vs actual data points, identify any missing time periods and identify statistical outliers","question":"Check for missing data in the German public residual load dataset for the last 4 weeks. Analyze data completeness by checking for gaps in timestamps, missing values, and data availability patterns. Include total expected vs actual data points, identify any missing time periods and identify statistical outliers","sql":"WITH __market_data AS (\\n  SELECT\\n    data_quality_score,\\n    resolution,\\n    timestamp,\\n    series_id,\\n    value\\n  FROM energy_trading_demo.market_data.market_data\\n), __time_series_documentation AS (\\n  SELECT\\n    series_id,\\n    time_series_name\\n  FROM energy_trading_demo.market_data.time_series_documentation\\n), raw_data AS (\\n  SELECT\\n    md.timestamp,\\n    md.value,\\n    md.data_quality_score,\\n    md.resolution\\n  FROM __market_data AS md\\n  LEFT OUTER JOIN __time_series_documentation AS tsd\\n    ON md.series_id = tsd.series_id\\n  WHERE\\n    tsd.time_series_name = ''Energy-Charts /public_power DE - Wind onshore''\\n    AND md.timestamp >= DATEADD(WEEK, -4, CURRENT_DATE)\\n    AND md.timestamp <= CURRENT_DATE\\n), statistics AS (\\n  SELECT\\n    COUNT(*) AS total_records,\\n    COUNT(DISTINCT DATE_TRUNC(''DAY'', timestamp)) AS days_with_data,\\n    COUNT(DISTINCT DATE_TRUNC(''HOUR'', timestamp)) AS hours_with_data,\\n    MIN(timestamp) AS earliest_timestamp,\\n    MAX(timestamp) AS latest_timestamp,\\n    COUNT(CASE WHEN value IS NULL THEN 1 END) AS null_values,\\n    ARRAY_UNIQUE_AGG(resolution) AS resolutions,\\n    MIN(value) AS min_value,\\n    MAX(value) AS max_value,\\n    AVG(value) AS avg_value,\\n    STDDEV(value) AS stddev_value,\\n    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY\\n      value) AS Q1,\\n    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY\\n      value) AS MEDIAN,\\n    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY\\n      value) AS Q3\\n  FROM raw_data\\n)\\nSELECT\\n  rd.timestamp,\\n  rd.value,\\n  rd.data_quality_score,\\n  rd.resolution,\\n  s.total_records,\\n  s.days_with_data,\\n  s.hours_with_data,\\n  s.earliest_timestamp,\\n  s.latest_timestamp,\\n  s.null_values,\\n  s.resolutions,\\n  s.min_value,\\n  s.max_value,\\n  s.avg_value,\\n  s.stddev_value,\\n  s.Q1,\\n  s.MEDIAN,\\n  s.Q3\\nFROM raw_data AS rd\\nCROSS JOIN statistics AS s\\nORDER BY\\n  rd.timestamp DESC NULLS LAST\\n -- Generated by Cortex Analyst\\n;","use_as_onboarding_question":false,"verified_by":"Mihael Radosevic","verified_at":1761601143}]}');

-- AGENT_FROM_SQL: AI Agent for natural language energy market queries
-- Combines Cortex Analyst (text-to-SQL), Cortex Search (semantic discovery),
-- and email functionality for comprehensive energy trading analysis



use role AI_ENGINEER;
CREATE OR REPLACE AGENT SNOWFLAKE_INTELLIGENCE.AGENTS.TIME_SERIES_AGENT
  COMMENT = 'Decision‑ready European power market time series from Energy‑Charts cover public net generation by technology (15‑minute), generation forecasts (current/intraday/day‑ahead), Germany’s total generation, installed capacity by technology (GW; batteries GWh; monthly installs/decommissions in MW), grid frequency (Hz, 1‑minute), day‑ahead prices (EUR/MWh, hourly, MTU test to 15‑minute), and cross‑border trading and physical flows (GW). Consistent units, resolution, and source enable fast exploration, benchmarking, hedging, load shaping, risk management, and portfolio optimization.' 
  PROFILE = '{"display_name":"Energy Time Series Agent"}' 
  FROM SPECIFICATION
  $$
  {"models":{"orchestration":"claude-sonnet-4-5"},"orchestration":{},"instructions":{"response":"You are an expert for energy trading and can answer question about time series market data. Answer in the same language as the user question.\nThe response should contain a trend charts for each time series requested and for a chart to answer the question if feasible.\n","orchestration":"On every business question about energy time series.\nStrictly follow the steps before trying a alternate approaches.\n1. The Cortex Search tool Time_series_doc_search takes the user input and return the relevant time series names. \n2. Use the time series names as filter in the Cortex Analyst tool and check if data is available. \n3. If data is available continue to process the use question"},"tools":[{"tool_spec":{"type":"cortex_analyst_text_to_sql","name":"Energy_timeseries_analyst","description":"TABLE1: MARKET_DATA\n- Database: ENERGY_TRADING_DEMO, Schema: MARKET_DATA\n- Contains time-series market data for energy trading with timestamps, values, and metadata about data quality and sources. The table stores actual market measurements and prices from various energy trading systems and regional transmission organizations.\n- Serves as the primary fact table with numerical values representing financial transactions, prices, or quantities in energy markets. Data is collected at different resolutions (1-minute, 15-minute, hourly) from multiple source systems like PJM, ERCOT, and Nord Pool.\n- LIST OF COLUMNS: ID (unique identifier), TIMESTAMP (date/time of market data record), VALUE (financial/quantity measurement), DATA_QUALITY_SCORE (reliability rating), RESOLUTION (data frequency interval), SOURCE_SYSTEM (origin system like PJM_RT_SYSTEM), TIME_SERIES_NAME (metric identifier - links to same column in other tables), UNIT (measurement unit like USD/MWh)\n\nTABLE2: TIME_SERIES_METADATA\n- Database: ENERGY_TRADING_DEMO, Schema: MARKET_DATA\n- Provides detailed documentation and explanatory content for each time series, organized into sections covering purpose, data sources, and market patterns. Contains comprehensive textual descriptions explaining the business context and trading relevance of each metric.\n- Includes keyword tagging for searchability and categorization of documentation into logical sections. The content helps traders and analysts understand the background, acquisition methods, and typical behavior patterns of market data.\n- LIST OF COLUMNS: DOC_ID (unique document identifier), TIME_SERIES_NAME (metric identifier - links to same column in other tables), SECTION_NAME (documentation category), CONTENT (detailed explanatory text), KEYWORDS (searchable tags array)\n\nTABLE3: TIME_SERIES_METADATA\n- Database: ENERGY_TRADING_DEMO, Schema: MARKET_DATA\n- Stores structural metadata about each time series including data types, sources, frequency, units, and value ranges. Provides essential reference information for understanding the technical characteristics and business context of each metric.\n- Contains trading relevance descriptions and key market drivers that influence each time series, helping users understand the factors affecting price movements and market behavior. Includes value range constraints for data validation.\n- LIST OF COLUMNS: SERIES_ID (unique series identifier), TIME_SERIES_NAME (metric identifier with cortex search - links to same column in other tables), DATA_SOURCE (origin like EPEX SPOT), DATA_TYPE (format classification), DESCRIPTION (brief summary), TYPICAL_FREQUENCY (collection interval), TYPICAL_UNIT (measurement standard), VALUE_RANGE_MIN (minimum threshold), VALUE_RANGE_MAX (maximum threshold), KEY_DRIVERS (influencing factors), TRADING_RELEVANCE (business importance)\n\nREASONING:\nThis semantic view represents a comprehensive energy trading time series data system that combines actual market data with rich metadata and documentation. The three tables work together to provide a complete picture: MARKET_DATA contains the actual time-stamped values and measurements, while TIME_SERIES_METADATA and TIME_SERIES_METADATA provide contextual information, explanations, and technical specifications. The relationships are built around TIME_SERIES_NAME as the common key, allowing users to access both the raw data and its comprehensive documentation. This structure supports energy traders, analysts, and systems that need both the numerical data and deep understanding of market context, data sources, and trading implications.\n\nDESCRIPTION:\nThe ENERGY_TRADING_TIME_SERIES semantic view from the ENERGY_TRADING_DEMO database provides a comprehensive energy market data system combining actual time-series measurements with detailed documentation and metadata. The MARKET_DATA table stores timestamped financial values and quantities from various energy trading systems (PJM, ERCOT, Nord Pool) at different resolutions, while TIME_SERIES_METADATA offers detailed explanatory content about market patterns, data sources, and trading context organized into searchable sections. The TIME_SERIES_METADATA table provides technical specifications including data types, frequency, units, value ranges, and key market drivers that influence each metric. All three tables are linked through TIME_SERIES_NAME, enabling users to access both raw market data and comprehensive contextual information for energy trading analysis and decision-making."}},{"tool_spec":{"type":"cortex_search","name":"Time_series_doc_search","description":"the tool takes the user question, executes a vector search and returns the most relevant time series names"}},{"tool_spec":{"type":"generic","name":"send-email","description":"Use this tool to send emails.","input_schema":{"type":"object","properties":{"recipient":{"description":"The email address of the recipient.","type":"string"},"subject":{"description":"The subject of the email.","type":"string"},"text":{"description":"The text of the email. Supports html code for formatted emails.","type":"string"}},"required":["recipient","subject","text"]}}}],"tool_resources":{"Energy_timeseries_analyst":{"execution_environment":{"query_timeout":60,"type":"warehouse","warehouse":""},"semantic_view":"ENERGY_TRADING_TIME_SERIES"},"Time_series_doc_search":{"max_results":8,"search_service":"ENERGY_TIME_SERIES_SEARCH","title_column":"TIME_SERIES_NAME"},"send-email":{"execution_environment":{"type":"warehouse","warehouse":""},"identifier":"SEND_EMAIL","name":"SEND_EMAIL(VARCHAR, VARCHAR, VARCHAR)","type":"procedure"}}}
  $$;

