-- the department rollup should add up to the same totals as the staging model
-- (using the same salaries > 0 filter as dept_ot_salary_total)
-- returns a row (fails) if overtime or salary totals differ by more than $1

with staging as (
    select sum(overtime) as overtime, sum(salaries) as salaries
    from {{ ref('stg_employee_comp') }}
    where year_type = 'Calendar'
      and salaries > 0
),

rollup as (
    select sum(overtime_total) as overtime, sum(salary_total) as salaries
    from {{ ref('dept_ot_salary_total') }}
)

select *
from staging, rollup
where abs(staging.overtime - rollup.overtime) > 1
   or abs(staging.salaries - rollup.salaries) > 1
