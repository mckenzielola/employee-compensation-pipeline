-- =====================================================================
-- EMPLOYEE_COMP pipeline: S3 -> Snowflake -> dbt -> access
-- Run top to bottom. Steps 1-3 need ACCOUNTADMIN; Steps 4-10 run as
-- LOADER_ROLE so the objects (and the task) are not owned by an admin.
-- IF NOT EXISTS is used so re-running the file doesn't wipe existing objects.
--
-- Order:
--   1  Role and warehouse            (account level)
--   2  Database and schema
--   3  Storage integration           (account level, plus one AWS step)
--   *  One-time migration            (existing account only - skip on a fresh build)
--   4  File format
--   5  External stage
--   6  Raw table
--   7  Dry run
--   8  First load and verify
--   9  View
--   10 Daily task
--   11 Build dbt models               (dbt, not SQL)
--   12 Access setup                  (access_setup.sql)
--   13 Monitoring / troubleshooting
-- =====================================================================


-- =====================================================================
-- STEP 1: Role and warehouse (ACCOUNTADMIN)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- dedicated role for loading; granted to SYSADMIN so admins keep visibility
CREATE ROLE IF NOT EXISTS LOADER_ROLE;
GRANT ROLE LOADER_ROLE TO ROLE SYSADMIN;
GRANT ROLE LOADER_ROLE TO USER MCKENZIEMORGAN;

-- dedicated warehouse: small, suspends after 60s idle, wakes on demand
CREATE WAREHOUSE IF NOT EXISTS LOAD_WH
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for EMPLOYEE_DB loads';

GRANT USAGE, OPERATE ON WAREHOUSE LOAD_WH TO ROLE LOADER_ROLE;

-- account-level privilege required for a role to run scheduled tasks
GRANT EXECUTE TASK ON ACCOUNT TO ROLE LOADER_ROLE;


-- =====================================================================
-- STEP 2: Database and schema (ACCOUNTADMIN)
-- =====================================================================
CREATE DATABASE IF NOT EXISTS EMPLOYEE_DB;
CREATE SCHEMA IF NOT EXISTS EMPLOYEE_DB.PUBLIC;   -- exists by default; listed so the setup is explicit

GRANT USAGE ON DATABASE EMPLOYEE_DB TO ROLE LOADER_ROLE;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT, CREATE TASK
  ON SCHEMA EMPLOYEE_DB.PUBLIC TO ROLE LOADER_ROLE;


-- =====================================================================
-- STEP 3: Storage integration (ACCOUNTADMIN)
-- Do NOT use CREATE OR REPLACE here: replacing it generates a new
-- external ID and breaks the AWS IAM trust policy.
-- =====================================================================
CREATE STORAGE INTEGRATION IF NOT EXISTS CCSF_EMP
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::181250799317:role/Snowflake-bucket-read'
  STORAGE_ALLOWED_LOCATIONS = ('s3://ccsf-employee-compensation/datasets/');

-- copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID into the
-- IAM role's trust policy in AWS (one-time step on the AWS side)
DESC INTEGRATION CCSF_EMP;

GRANT USAGE ON INTEGRATION CCSF_EMP TO ROLE LOADER_ROLE;


-- ---------------------------------------------------------------------
-- ONE-TIME MIGRATION - existing account only. SKIP ON A FRESH BUILD.
-- These objects were first created manually as ACCOUNTADMIN; this hands
-- them to LOADER_ROLE. On a fresh build they don't exist yet and the
-- statements below would fail.
-- ---------------------------------------------------------------------
ALTER TASK EMPLOYEE_DB.PUBLIC.LOAD_EMPLOYEE_COMP_DAILY SUSPEND;   -- a task must be suspended to change ownership
GRANT OWNERSHIP ON STAGE EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA    TO ROLE LOADER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP            TO ROLE LOADER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW  EMPLOYEE_DB.PUBLIC.EMPLOYEE_VIEW            TO ROLE LOADER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TASK  EMPLOYEE_DB.PUBLIC.LOAD_EMPLOYEE_COMP_DAILY TO ROLE LOADER_ROLE COPY CURRENT GRANTS;
DROP TABLE IF EXISTS EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP_NEW;            -- leftover from the old swap-based task


-- =====================================================================
-- From here on: run as the loader role on the load warehouse
-- =====================================================================
USE ROLE LOADER_ROLE;
USE WAREHOUSE LOAD_WH;
USE SCHEMA EMPLOYEE_DB.PUBLIC;


-- =====================================================================
-- STEP 4: File format (one definition shared by every load)
-- =====================================================================
CREATE FILE FORMAT IF NOT EXISTS EMPLOYEE_DB.PUBLIC.CSV_FMT
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';


-- =====================================================================
-- STEP 5: External stage (pointer to the S3 folder)
-- =====================================================================
CREATE STAGE IF NOT EXISTS EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA
  STORAGE_INTEGRATION = CCSF_EMP
  URL = 's3://ccsf-employee-compensation/datasets/'
  FILE_FORMAT = EMPLOYEE_DB.PUBLIC.CSV_FMT;

-- confirm Snowflake can see the files
LIST @EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA PATTERN = '.*[.]csv';


-- =====================================================================
-- STEP 6: Target table
-- =====================================================================
CREATE TABLE IF NOT EXISTS EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP (
    organization_group_code VARCHAR(2),
    job_family_code VARCHAR(15),
    job_code VARCHAR(5),
    year_type VARCHAR(10),
    year VARCHAR(4),
    organization_group VARCHAR(60),
    department_code VARCHAR(5),
    department VARCHAR(35),
    union_code VARCHAR(10),
    union_name VARCHAR(50),
    job_family VARCHAR(50),
    job_name VARCHAR(75),
    employee_identifier VARCHAR(50),
    salaries DOUBLE,
    overtime DOUBLE,
    other_salaries DOUBLE,
    total_salary DOUBLE,
    retirement DOUBLE,
    health_and_dental DOUBLE,
    other_benefits DOUBLE,
    total_benefits DOUBLE,
    total_compensation DOUBLE,
    hours DOUBLE,
    employee_type VARCHAR(50),
    -- stored as text so the values match the CSV exactly (e.g. '2026 Oct 04 11:22:41 PM')
    data_as_of VARCHAR(30),
    data_loaded_at VARCHAR(30)
);


-- =====================================================================
-- STEP 7: Dry run (nothing is loaded)
-- VALIDATION_MODE can't be combined with a transforming COPY
-- (COPY ... FROM (SELECT ...)), which is what this load uses. So the
-- dry run is split into two checks instead.
-- =====================================================================

-- 7a. Parse check: column count, quoting, encoding. Reads the raw file
--     only; returns parse errors, or no rows if the file parses cleanly.
SELECT COUNT(*) AS rows_in_file, MAX(METADATA$FILE_ROW_NUMBER) AS last_row
FROM @EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA
  (FILE_FORMAT => 'EMPLOYEE_DB.PUBLIC.CSV_FMT', PATTERN => '.*[.]csv');

-- 7b. Transform check: run the same conversions as the load and count
--     values that would silently become NULL (TRY_ functions hide errors).
SELECT
  COUNT(*)                                                                         AS total_rows,
  COUNT_IF($14 IS NOT NULL AND TRY_TO_DOUBLE(REPLACE($14, ',', '')) IS NULL)       AS bad_salaries,
  COUNT_IF($22 IS NOT NULL AND TRY_TO_DOUBLE(REPLACE($22, ',', '')) IS NULL)       AS bad_total_comp,
  COUNT_IF($23 IS NOT NULL AND TRY_TO_DOUBLE(REPLACE($23, ',', '')) IS NULL)       AS bad_hours,
  COUNT_IF($25 IS NOT NULL AND TRY_TO_TIMESTAMP($25, 'YYYY MON DD HH12:MI:SS AM') IS NULL) AS bad_data_as_of,
  COUNT_IF($26 IS NOT NULL AND TRY_TO_TIMESTAMP($26, 'YYYY/MM/DD HH12:MI:SS AM') IS NULL)  AS bad_data_loaded_at
FROM @EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA
  (FILE_FORMAT => 'EMPLOYEE_DB.PUBLIC.CSV_FMT', PATTERN => '.*[.]csv');


-- =====================================================================
-- STEP 8: First load (manual) and verify
-- =====================================================================
COPY INTO EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP
  FROM (
    SELECT
      $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
      TRY_TO_DOUBLE(REPLACE($14, ',', '')), -- salaries
      TRY_TO_DOUBLE(REPLACE($15, ',', '')), -- overtime
      TRY_TO_DOUBLE(REPLACE($16, ',', '')), -- other_salaries
      TRY_TO_DOUBLE(REPLACE($17, ',', '')), -- total_salary
      TRY_TO_DOUBLE(REPLACE($18, ',', '')), -- retirement
      TRY_TO_DOUBLE(REPLACE($19, ',', '')), -- health_and_dental
      TRY_TO_DOUBLE(REPLACE($20, ',', '')), -- other_benefits
      TRY_TO_DOUBLE(REPLACE($21, ',', '')), -- total_benefits
      TRY_TO_DOUBLE(REPLACE($22, ',', '')), -- total_compensation
      TRY_TO_DOUBLE(REPLACE($23, ',', '')), -- hours
      $24,                                  -- employee_type
      $25,                                  -- data_as_of     (kept as the original CSV text)
      $26                                   -- data_loaded_at (kept as the original CSV text)
    FROM @EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA
  )
  FILE_FORMAT = (FORMAT_NAME = 'EMPLOYEE_DB.PUBLIC.CSV_FMT')
  PATTERN = '.*[.]csv'
  ON_ERROR = ABORT_STATEMENT;

-- row count should match total_rows from 7b
SELECT COUNT(*) AS rows_loaded,
       COUNT_IF(total_compensation IS NULL) AS null_total_comp,
       MAX(TRY_TO_TIMESTAMP(data_loaded_at, 'YYYY/MM/DD HH12:MI:SS AM')) AS latest_data_loaded_at  -- text column, convert to compare
FROM EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP;


-- =====================================================================
-- STEP 9: View (what users and dashboards query)
-- =====================================================================
CREATE OR REPLACE VIEW EMPLOYEE_DB.PUBLIC.EMPLOYEE_VIEW AS
SELECT * FROM EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP;


-- =====================================================================
-- STEP 10: Daily task (full refresh, all-or-nothing)
-- Delete + reload inside one transaction: if the COPY fails or loads
-- 0 rows, it rolls back and yesterday's data stays in place.
-- FORCE = TRUE is needed because COPY otherwise skips files it has
-- already loaded in the last 64 days. Keep only the current CSV in the
-- S3 folder, or the reload will include older files (duplicates).
-- =====================================================================
CREATE OR REPLACE TASK EMPLOYEE_DB.PUBLIC.LOAD_EMPLOYEE_COMP_DAILY
  WAREHOUSE = LOAD_WH
  SCHEDULE = 'USING CRON 0 6 * * * America/Los_Angeles'
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS
BEGIN
  BEGIN TRANSACTION;
  DELETE FROM EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP;

  COPY INTO EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP
    FROM (
      SELECT
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
        TRY_TO_DOUBLE(REPLACE($14, ',', '')), TRY_TO_DOUBLE(REPLACE($15, ',', '')),
        TRY_TO_DOUBLE(REPLACE($16, ',', '')), TRY_TO_DOUBLE(REPLACE($17, ',', '')),
        TRY_TO_DOUBLE(REPLACE($18, ',', '')), TRY_TO_DOUBLE(REPLACE($19, ',', '')),
        TRY_TO_DOUBLE(REPLACE($20, ',', '')), TRY_TO_DOUBLE(REPLACE($21, ',', '')),
        TRY_TO_DOUBLE(REPLACE($22, ',', '')), TRY_TO_DOUBLE(REPLACE($23, ',', '')),
        $24,
        $25,   -- data_as_of     (original CSV text)
        $26    -- data_loaded_at (original CSV text)
      FROM @EMPLOYEE_DB.PUBLIC.AWS_RAW_EMPLOYEE_DATA
    )
    FILE_FORMAT = (FORMAT_NAME = 'EMPLOYEE_DB.PUBLIC.CSV_FMT')
    PATTERN = '.*[.]csv'
    ON_ERROR = ABORT_STATEMENT
    FORCE = TRUE;

  LET row_count NUMBER := (SELECT COUNT(*) FROM EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP);
  IF (row_count = 0) THEN
    ROLLBACK;
    RETURN 'No rows loaded - previous data kept';
  END IF;

  COMMIT;
  RETURN 'Loaded ' || row_count || ' rows';
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;  -- re-raise so the run is marked FAILED in TASK_HISTORY
END;

-- tasks are created suspended; this starts the schedule
ALTER TASK EMPLOYEE_DB.PUBLIC.LOAD_EMPLOYEE_COMP_DAILY RESUME;

-- optional: run once now instead of waiting for 6 AM
-- EXECUTE TASK EMPLOYEE_DB.PUBLIC.LOAD_EMPLOYEE_COMP_DAILY;


-- =====================================================================
-- STEP 11: Build the dbt models (run dbt, not this file)
-- The staging view and mart tables are defined in models/ and built by
-- dbt, so their SQL is NOT repeated here. Run after the raw table has
-- data (Step 8). dbt connects using profiles.yml.
--
--   dbt build        -- builds stg_employee_comp, dept_ot_salary_total,
--                    -- dept_ot_salary_normalized, qrt_high_ot, then runs the tests
--
-- Re-run after every daily load so the marts reflect the new data.
-- =====================================================================


-- =====================================================================
-- STEP 12: Access setup (run access_setup.sql)
-- Creates PUBLIC_ANALYST / LEADERSHIP / DEPT_HEAD, the department head
-- mapping table, and the secure views. Must run AFTER Step 11 because
-- the views and grants reference the mart tables dbt creates.
-- =====================================================================


-- =====================================================================
-- STEP 13: Monitoring / troubleshooting
-- =====================================================================

-- Is the task running or suspended?
SHOW TASKS LIKE 'LOAD_EMPLOYEE_COMP_DAILY' IN SCHEMA EMPLOYEE_DB.PUBLIC;

-- Did the task succeed? (last 7 days of runs, with error messages)
SELECT name, state, return_value, error_code, error_message, scheduled_time, completed_time
FROM TABLE(EMPLOYEE_DB.INFORMATION_SCHEMA.TASK_HISTORY(
  TASK_NAME => 'LOAD_EMPLOYEE_COMP_DAILY',
  SCHEDULED_TIME_RANGE_START => DATEADD(day, -7, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

-- Which files loaded, how many rows, first error per file
SELECT file_name, status, row_count, row_parsed, first_error_message, first_error_line_number, last_load_time
FROM TABLE(EMPLOYEE_DB.INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'EMPLOYEE_DB.PUBLIC.EMPLOYEE_COMP',
  START_TIME => DATEADD(day, -7, CURRENT_TIMESTAMP())))
ORDER BY last_load_time DESC;

