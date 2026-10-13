{{ config(materialized='view') }}

with source as (

    select * from {{ source('employee_raw', 'EMPLOYEE_COMP') }}

),

cleaned as (

    select
        trim(organization_group_code)   as organization_group_code,
        trim(job_family_code)           as job_family_code,
        trim(job_code)                  as job_code,
        trim(year_type)                 as year_type,
        trim(year)                      as year,
        trim(organization_group)        as organization_group,
        trim(department_code)           as department_code,
        trim(department)                as department,
        trim(union_code)                as union_code,
        trim(union_name)                as union_name,
        trim(job_family)                as job_family,
        trim(job_name)                  as job_name,
        trim(employee_identifier)       as employee_identifier,
        salaries,
        overtime,
        other_salaries,
        total_salary,
        retirement,
        health_and_dental,
        other_benefits,
        total_benefits,
        total_compensation,
        hours,
        trim(employee_type)             as employee_type,
        -- already TIMESTAMP_NTZ in the raw table (parsed during the COPY load), passed through unchanged
        data_as_of,
        data_loaded_at

    from source
    where employee_identifier is not null AND year_type = 'Calendar'

)

select * from cleaned
