with emp as (
    select * from {{ ref('stg_employee_comp') }}
    where year_type = 'Calendar'
),
job_group as (
    select department_code, job_name, year,
           count(*) as group_size,
           percentile_cont(0.25) within group (order by overtime) as q1,
           percentile_cont(0.75) within group (order by overtime) as q3
    from emp
    group by department_code, job_name, year
),

ratio_cutoff as (
    select percentile_cont(0.75) within group (order by overtime / salaries) as ot_salary_cutoff
    from emp
    where overtime > 0
      and salaries > 0
)
select e.employee_identifier, e.department_code, e.year, e.job_name,
       e.salaries, e.overtime,
       g.q3 + 1.5 * (g.q3 - g.q1)               as threshold,
       e.overtime - (g.q3 + 1.5 * (g.q3 - g.q1)) as amount_above,
       e.overtime / e.salaries                  as ot_salary_ratio,
       r.ot_salary_cutoff
from emp e
join job_group g using (department_code, job_name, year)
cross join ratio_cutoff r
where e.overtime > 0
  and e.salaries > 0
  and e.overtime > g.q3 + 1.5 * (g.q3 - g.q1)
  and e.overtime / e.salaries >= r.ot_salary_cutoff
