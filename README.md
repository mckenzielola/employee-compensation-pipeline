# Employee Compensation Pipeline

Loads City and County of San Francisco employee compensation data from S3 into Snowflake, cleans it with dbt, produces overtime analysis tables, and exposes them to three audiences with different access levels.

- **Database / schema:** `EMPLOYEE_DB.PUBLIC`
- **Warehouses:** `LOAD_WH` (daily load), `COMPUTE_WH` (dbt)
- **dbt project:** `employee_comp`
- **Data covered:** 2013–2026, calendar years

This repo stores the setup scripts and dbt project that define the pipeline. Running it requires a Snowflake account, the S3 bucket, and a local `profiles.yml` (not included).

---

## 1. Repo structure

```
├── README.md
├── setup/
│   ├── 01_pipeline_setup.sql          # role, warehouse, database, S3 integration, raw table, daily load task
│   └── 02_access_setup.sql            # consumer roles, secure views, grants
├── dbt_project.yml                    # staging = views, marts = tables
├── packages.yml
├── models/
│   ├── sources.yml                    # declares the raw EMPLOYEE_COMP table
│   ├── staging/
│   │   ├── stg_employee_comp.sql
│   │   └── schema.yml                 # staging tests
│   └── marts/
│       ├── dept_ot_salary_total.sql
│       ├── dept_ot_salary_normalized.sql
│       ├── qrt_high_ot.sql
│       └── schema.yml                 # mart tests
└── tests/
    ├── assert_dept_totals_reconcile.sql
    └── generic/
        └── expression_is_true.sql     # reusable test used in schema.yml
```

## 2. Build order

| Step | What to run | Creates |
|---|---|---|
| 1 | `setup/01_pipeline_setup.sql` | `LOADER_ROLE`, `LOAD_WH`, `EMPLOYEE_DB`, storage integration, stage, raw `EMPLOYEE_COMP` table, daily task |
| 2 | `dbt build` | Staging view, three mart tables, and all tests |
| 3 | `setup/02_access_setup.sql` | `PUBLIC_ANALYST`, `LEADERSHIP`, `DEPT_HEAD` roles, secure views, grants |

Step 3 must run after Step 2, because its views and grants reference the tables dbt creates. Run `dbt build` again after every data load.

---

## 3. Pipeline overview

```
S3: s3://ccsf-employee-compensation/datasets/*.csv
   │  setup/01_pipeline_setup.sql (stage + daily task, 6:00 AM Pacific)
   ▼
EMPLOYEE_COMP                  raw table, Fiscal + Calendar rows
   │  dbt: models/staging
   ▼
stg_employee_comp              VIEW  - cleaned, calendar-year rows only
   │  dbt: models/marts
   ├──► dept_ot_salary_total        TABLE - overtime & salary totals per department per year
   ├──► dept_ot_salary_normalized   TABLE - overtime & salary per employee, per department per year
   └──► qrt_high_ot                 TABLE - employees with unusually high overtime
            │  setup/02_access_setup.sql
            ▼
   Secure views + role grants (PUBLIC_ANALYST, LEADERSHIP, DEPT_HEAD)
```

---

## 4. Ingestion (`setup/01_pipeline_setup.sql`)

The file is organized in numbered steps with an overview at the top. Account-level objects (role, warehouse, database, storage integration) are created as `ACCOUNTADMIN`. Everything else is created as `LOADER_ROLE`, so the load objects aren't owned by an admin.

- **Source:** CSV files in `s3://ccsf-employee-compensation/datasets/`, read through the external stage `AWS_RAW_EMPLOYEE_DATA` with the file format `CSV_FMT`.
- **Numeric columns** are loaded with `TRY_TO_DOUBLE(REPLACE(col, ',', ''))` to strip thousands separators. Values that can't be parsed become `NULL` rather than failing the load.
- **`data_as_of` and `data_loaded_at` are stored as text**, exactly as they appear in the CSV (e.g. `2026 Oct 04 11:22:41 PM`). To sort or compare them, convert in the query: `TRY_TO_TIMESTAMP(data_loaded_at, 'YYYY/MM/DD HH12:MI:SS AM')`.
- **A dry run (Step 7)** checks that the file parses and counts values that would silently become `NULL`, before anything is loaded.
- **Task `LOAD_EMPLOYEE_COMP_DAILY`** (6:00 AM Pacific, on `LOAD_WH`) deletes and reloads the table inside one transaction. If the load fails or loads 0 rows, it rolls back and the previous data stays. It suspends itself after 3 consecutive failures.
- **A one-time migration block** moves ownership of objects originally created as `ACCOUNTADMIN` to `LOADER_ROLE`. Skip it on a fresh build.

---

## 5. Transformations (dbt)

Materialization is set once in `dbt_project.yml`: `staging` builds as **views** and `marts` as **tables**. Don't add `config(materialized=...)` to individual models, because it overrides the project setting.

### 5.1 `stg_employee_comp` (view)
- Reads the raw table through `{{ source('employee_raw', 'EMPLOYEE_COMP') }}`.
- Trims whitespace on all text columns.
- Keeps only `year_type = 'Calendar'`. The source has Fiscal and Calendar versions of each employee-year, so keeping one avoids double-counting.
- Drops rows with no `employee_identifier`.
- Passes `data_as_of` and `data_loaded_at` through unchanged.

### 5.2 `dept_ot_salary_total` (table)
- One row per **department and year**: `overtime_total` and `salary_total`.
- Includes rows with `salaries > 0`. Departments with no overtime appear with $0.
- Answers: *which departments have the most overtime in total?*

### 5.3 `dept_ot_salary_normalized` (table)
- One row per **department and year**: `num_of_employees`, `normalized_overtime_total` (overtime ÷ employees), and `normalized_salary_total` (salary ÷ employees).
- Same filter: `salaries > 0`.
- Answers: *which departments have the most overtime per employee?* This adjusts for department size.

### 5.4 `qrt_high_ot` (table): unusually high overtime
An employee-year is flagged when **both** tests pass:

1. **Peer test (Tukey's upper fence).** Overtime is above `Q3 + 1.5 × IQR` for their **department + job + year** group. Q1 and Q3 are the 25th and 75th percentiles of overtime in that group, and IQR = Q3 − Q1. This finds overtime far above coworkers in the same role.
2. **Materiality test.** Overtime ÷ base salary is at or above the **citywide 75th percentile** of that ratio among employees with overtime (currently **21.8%**, column `ot_salary_cutoff`). This keeps amounts that are large relative to the person's own pay. The cutoff is calculated from the data, so it updates when the data changes.

Rows with `overtime <= 0` or `salaries <= 0` are never flagged.

Output columns: `employee_identifier`, `department_code`, `year`, `job_name`, `salaries`, `overtime`, `threshold` (the fence), `amount_above` (overtime minus fence), `ot_salary_ratio`, `ot_salary_cutoff`.

Current result: **12,664 rows / 5,850 distinct employees**.

---

## 6. Tests

Run with `dbt build` or `dbt test`. All tests currently pass, plus 2 expected warnings.

| Model | Tests |
|---|---|
| `stg_employee_comp` | Total compensation equals salary + benefits (±$1); `not_null` on key columns; `year_type` is only `'Calendar'`; non-negative overtime and salaries, and known `employee_type` values (both **warn** only, because negatives are legitimate adjustments) |
| `dept_ot_salary_total`, `dept_ot_salary_normalized` | One row per department and year; `department_code` and `year` not null |
| `qrt_high_ot` | Every row is above its fence; every row's ratio is at or above the cutoff; overtime and salary > 0; key columns not null |
| `tests/assert_dept_totals_reconcile.sql` | Department totals add up to the staging totals (same `salaries > 0` filter, ±$1) |

The 2 warnings report the 20 negative overtime rows and 9 negative salary rows in the source.

---

## 7. Access control (`setup/02_access_setup.sql`)

| Role | Can query | Sees |
|---|---|---|
| `PUBLIC_ANALYST` | `DEPT_OT_SALARY_TOTAL`, `DEPT_OT_SALARY_NORMALIZED` | Department aggregates only, no individual records |
| `LEADERSHIP` | `V_EMP_HIGH_OVERTIME_LEADERSHIP` | All individual records, names masked (`Reggie Walters` → `R***** W******`) |
| `DEPT_HEAD` | `V_EMP_HIGH_OVERTIME_DEPT_HEAD` | Unmasked records, only for their own department |

- Access is enforced with **secure views**, because this account is Standard edition, which doesn't support masking or row access policies. The Enterprise policy version is kept, commented out, at the bottom of the file for reference.
- **Never grant `SELECT` on the individual-level base tables to these roles.** That bypasses the masking and filtering.
- Masking uses `REGEXP_REPLACE(employee_identifier, '\\B\\w', '*')`. It keeps the first character of each word and replaces the rest one-for-one with `*`. Older numeric IDs are masked the same way (`9197` → `9***`).
- **Adding a department head** takes two steps, and both are required:
  ```sql
  GRANT ROLE DEPT_HEAD TO USER <USERNAME>;
  INSERT INTO EMPLOYEE_DB.PUBLIC.DEPT_HEAD_MAPPING VALUES ('<USERNAME>', '<DEPT_CODE>');  -- username uppercase
  ```
  The role allows access to the view, and the mapping row decides which department's rows the user sees.

---

## 8. Assumptions

- **Calendar year only.** Fiscal-year rows are excluded to avoid counting each employee-year twice.
- **One row = one employee-year** within a department and job. An employee who changed jobs mid-year appears in more than one row and is compared within each job separately.
- **Negative overtime is a pay adjustment** for another period or job (per the dataset documentation), not overtime worked. It's included in department totals, so they are *net* of corrections (−$66,837 across 20 rows), and is never flagged as high overtime.
- **`employee_identifier` is treated as the employee name.** Older years hold a numeric ID instead (from a system migration). Both are treated as identifying and both are masked.
- **Peer group = department + job + year**, so employees are compared with people in the same role.
- **1.5 × IQR** is the standard (Tukey) outlier fence. 3 × IQR would flag only extreme cases.
- **Materiality cutoff = 75th percentile of overtime ÷ salary**, the same Q3 benchmark the fence uses. It's roughly 7 extra hours per week, assuming 2,080 regular hours per year and time-and-a-half pay.
- **`salaries` is regular (base) pay**, not total income.

---

## 9. Limitations

- **Departments change over time.** Of 63 department codes, only 44 appear in all 14 years, because departments are created, merged and renamed. A department missing from a year is a property of the source data, not a pipeline error.
- **2026 is a partial year** (data as of Oct 4, 2026), so its totals aren't comparable to full years.
- **Small groups.** Fences for department + job + year groups with only a few people are unreliable. No minimum group size is applied.
- **Mostly-zero groups.** Q1 and Q3 are calculated from all employees, including those with $0 overtime. In groups where more than 75% have no overtime (about half of all groups), the fence is $0 and the materiality test does all the filtering.
- **The ratio cutoff is citywide.** In jobs where heavy overtime is normal (e.g. police, fire), most overtime earners pass the materiality test, so the fence does most of the filtering.
- **Part-year and part-time employees** have low annual salaries, which can make their overtime ratio look high.
- **The daily load loads every `.csv` in the stage.** If more than one full file is present, the rows are duplicated. Keep only the current file in the S3 folder.
- **The mart tables don't refresh automatically.** The task reloads only the raw table, so `dbt build` must run after each load.
- **dbt rebuilds tables with `CREATE OR REPLACE`,** which drops table-level grants. Grants to `PUBLIC_ANALYST` on the department tables must be reapplied after each `dbt build`, unless they're added to the models with a dbt `grants` config.
- **Access depends on manually managed data:** `DEPT_HEAD_MAPPING` and role grants are not in version control, so changes to them aren't reviewed.

---

## 10. Common commands

```bash
dbt build                         # build all models and run all tests, in dependency order
dbt test                          # run tests only
dbt build --select qrt_high_ot    # rebuild and test one model
```

```sql
-- check the daily load
SHOW TASKS LIKE 'LOAD_EMPLOYEE_COMP_DAILY' IN SCHEMA EMPLOYEE_DB.PUBLIC;
SELECT name, state, return_value, error_message, scheduled_time
FROM TABLE(EMPLOYEE_DB.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'LOAD_EMPLOYEE_COMP_DAILY'))
ORDER BY scheduled_time DESC LIMIT 10;

-- test access as each role
USE ROLE PUBLIC_ANALYST; SELECT * FROM EMPLOYEE_DB.PUBLIC.DEPT_OT_SALARY_NORMALIZED WHERE year = '2025';
USE ROLE LEADERSHIP;     SELECT * FROM EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_LEADERSHIP LIMIT 10;
USE ROLE DEPT_HEAD;      SELECT * FROM EMPLOYEE_DB.PUBLIC.V_EMP_HIGH_OVERTIME_DEPT_HEAD LIMIT 10;
```
