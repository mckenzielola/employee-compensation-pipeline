with emp as (

    select * from {{ ref('stg_employee_comp') }}
    where year_type = 'Calendar'
),
dept_overtime_summary as (
    select 
        department_code,
        year,
        COUNT(employee_identifier) as num_of_employees,
        sum(overtime) / COUNT(employee_identifier) as normalized_overtime_total,
        sum(salaries) / COUNT(employee_identifier) as normalized_salary_total
    from emp
    where 
        salaries > 0
    group by department_code, year
)

select * from dept_overtime_summary