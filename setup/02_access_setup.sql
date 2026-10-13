-- Access setup for employee compensation marts.
-- Note: this account does not support masking / row access policies (Enterprise-only),
-- so access is enforced with secure views. Roles get the views, never the base tables.

USE ROLE ACCOUNTADMIN;

-- Roles
CREATE ROLE IF NOT EXISTS PUBLIC_ANALYST;
CREATE ROLE IF NOT EXISTS LEADERSHIP;
CREATE ROLE IF NOT EXISTS DEPT_HEAD;

-- Basic access
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE PUBLIC_ANALYST;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE LEADERSHIP;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE DEPT_HEAD;
GRANT USAGE ON DATABASE EMPLOYEE_DB TO ROLE PUBLIC_ANALYST;
GRANT USAGE ON DATABASE EMPLOYEE_DB TO ROLE LEADERSHIP;
GRANT USAGE ON DATABASE EMPLOYEE_DB TO ROLE DEPT_HEAD;
GRANT USAGE ON SCHEMA EMPLOYEE_DB.PUBLIC TO ROLE PUBLIC_ANALYST;
GRANT USAGE ON SCHEMA EMPLOYEE_DB.PUBLIC TO ROLE LEADERSHIP;
GRANT USAGE ON SCHEMA EMPLOYEE_DB.PUBLIC TO ROLE DEPT_HEAD;

-- Mapping: which user heads which department
CREATE TABLE IF NOT EXISTS EMPLOYEE_DB.PUBLIC.DEPT_HEAD_MAPPING (
  user_name STRING, department_code STRING);

-- Public: aggregated pay and overtime by department, no individual records
GRANT SELECT ON TABLE EMPLOYEE_DB.PUBLIC.DEPT_OT_SALARY_TOTAL TO ROLE PUBLIC_ANALYST;
GRANT SELECT ON TABLE EMPLOYEE_DB.PUBLIC.DEPT_OT_SALARY_NORMALIZED TO ROLE PUBLIC_ANALYST;

-- Leadership: individual records, employee identifier masked
-- Keeps the first letter of each name, masks every other letter (Reggie Walters -> R***** W******)
CREATE OR REPLACE SECURE VIEW EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_LEADERSHIP COPY GRANTS AS
SELECT REGEXP_REPLACE(employee_identifier, '\\B\\w', '*') AS employee_identifier,
       department_code, year, job_name, overtime, threshold, amount_above
FROM EMPLOYEE_DB.PUBLIC.QRT_HIGH_OT;

GRANT SELECT ON VIEW EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_LEADERSHIP TO ROLE LEADERSHIP;

-- Department heads: unmasked individual records, only for their own department
CREATE OR REPLACE SECURE VIEW EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_DEPT_HEAD COPY GRANTS AS
SELECT e.employee_identifier, e.department_code, e.year, e.job_name,
       e.overtime, e.threshold, e.amount_above
FROM EMPLOYEE_DB.PUBLIC.QRT_HIGH_OT e
JOIN EMPLOYEE_DB.PUBLIC.DEPT_HEAD_MAPPING m
  ON e.department_code = m.department_code
 AND m.user_name = CURRENT_USER();

GRANT SELECT ON VIEW EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_DEPT_HEAD TO ROLE DEPT_HEAD;


-- Assign users and test (replace <USERNAME> and <DEPT_CODE>, then uncomment)
-- Usernames must be UPPERCASE to match CURRENT_USER().
-- =====================================================================

-- -- 1. Give a user one or more roles
GRANT ROLE PUBLIC_ANALYST TO USER <USERNAME>;
GRANT ROLE LEADERSHIP     TO USER <USERNAME>;
GRANT ROLE DEPT_HEAD      TO USER <USERNAME>;

-- -- 2. Dept heads also need a mapping row: it decides which department they see
INSERT INTO EMPLOYEE_DB.PUBLIC.DEPT_HEAD_MAPPING VALUES ('<USERNAME>', '<DEPT_CODE>');   -- e.g. 'POL'

-- -- 3. Test as each role (run as that user)
USE ROLE PUBLIC_ANALYST;
SELECT * FROM EMPLOYEE_DB.PUBLIC.DEPT_OT_SALARY_TOTAL LIMIT 10;               -- works: aggregates only
SELECT * FROM EMPLOYEE_DB.PUBLIC.QRT_HIGH_OT LIMIT 10;                        -- should fail: no individual records

USE ROLE LEADERSHIP;
SELECT * FROM EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_LEADERSHIP LIMIT 10;     -- all departments, masked names

USE ROLE DEPT_HEAD;
SELECT department_code, COUNT(*) FROM EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_DEPT_HEAD GROUP BY 1;  -- only <DEPT_CODE>, unmasked


-- ENTERPRISE EDITION ALTERNATIVE (reference only - not supported on standard account)
-- With Enterprise, security is attached to the table itself instead of separate views:
-- one table is granted to LEADERSHIP and DEPT_HEAD, and the policies change what each
-- role sees. Run only if you have an Enterprise access
-- =====================================================================

-- -- Masking policy: Dept heads see full names, everyone else sees R***** W******
CREATE OR REPLACE MASKING POLICY EMPLOYEE_DB.PUBLIC.MASK_EMP_NAME AS (val STRING) RETURNS STRING ->
  CASE WHEN IS_ROLE_IN_SESSION('DEPT_HEAD') OR IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN val
       ELSE REGEXP_REPLACE(val, '\\B\\w', '*') END;

-- -- Row access policy: Leadership sees all rows, Dept heads only their department
CREATE OR REPLACE ROW ACCESS POLICY EMPLOYEE_DB.PUBLIC.RAP_DEPT AS (dept STRING) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('ACCOUNTADMIN')
  OR IS_ROLE_IN_SESSION('LEADERSHIP')
  OR (IS_ROLE_IN_SESSION('DEPT_HEAD') AND EXISTS (
        SELECT 1 FROM EMPLOYEE_DB.PUBLIC.DEPT_HEAD_MAPPING m
        WHERE m.user_name = CURRENT_USER() AND m.department_code = dept));

-- -- Attach policies to the table 
ALTER TABLE EMPLOYEE_DB.PUBLIC.EMP_HIGH_OVERTIME
  MODIFY COLUMN employee_identifier SET MASKING POLICY EMPLOYEE_DB.PUBLIC.MASK_EMP_NAME;
ALTER TABLE EMPLOYEE_DB.PUBLIC.EMP_HIGH_OVERTIME
  ADD ROW ACCESS POLICY EMPLOYEE_DB.PUBLIC.RAP_DEPT ON (department_code);

-- -- Grant the single table to both individual-level roles
GRANT SELECT ON TABLE EMPLOYEE_DB.PUBLIC.EMP_HIGH_OVERTIME TO ROLE LEADERSHIP;
GRANT SELECT ON TABLE EMPLOYEE_DB.PUBLIC.EMP_HIGH_OVERTIME TO ROLE DEPT_HEAD;
