-- =============================================================================
-- 0004 · Web app sign-in.
--
-- Passwords are stored as scrypt hashes and are readable only by the server's
-- own database login, never by crm_app (the role every page query runs as).
-- Production: create a login role for the web server, e.g.
--   create role crm_server login password '...';
--   grant crm_app to crm_server;
--   grant usage on schema crm to crm_server;
--   grant select, insert, update on crm.app_login to crm_server;
--   grant select on crm.employee, crm.access_level, crm.branch to crm_server;
-- =============================================================================

create table crm.app_login (
    employee_id           text primary key references crm.employee,
    password_hash         text not null,
    must_change_password  boolean not null default true,
    last_login_at         timestamptz,
    updated_at            timestamptz not null default now()
);

revoke all on crm.app_login from crm_app;

-- Pending follow-ups for "My Day" and the lead page, with lead context.
create view crm.v_my_followups with (security_invoker = true) as
select f.activity_id, f.lead_id, f.branch_id, f.employee_id, f.activity_type,
       f.due_at, f.due_on, f.followup_status,
       c.customer_name, c.mobile, l.stage_code, l.product_category, l.assigned_to
from crm.v_followup_status f
join crm.lead l on l.lead_id = f.lead_id
join crm.customer c on c.customer_id = l.customer_id
where f.completed_at is null;

grant select on crm.v_my_followups to crm_app;
