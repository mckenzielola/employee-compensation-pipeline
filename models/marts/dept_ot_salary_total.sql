with emp as (

    select * from {{ ref('stg_employee_comp') }}
    where year_type = 'Calendar'
),
dept_overtime_summary as (
    select
        department_code,
        year,
        sum(overtime) as overtime_total,
        sum(salaries) as salary_total
    from emp
    where 
        salaries > 0
    group by department_code, year
)

select * from dept_overtime_summary