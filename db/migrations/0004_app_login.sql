-- =============================================================================
-- 0004 · Web app sign-in.
--
-- Passwords are stored as scrypt hashes. Neither crm_app (the role every page
-- query runs as) nor the web server can read the tables directly: sign-in goes
-- through the security-definer functions below, granted to crm_auth only.
--
-- Production: the web server logs in as a role that is a member of both
--   create role crm_server login password '...';
--   grant crm_app, crm_auth to crm_server;
-- Migrations and the admin CLIs (create-tenant, create-admin) run as the
-- database owner.
-- =============================================================================

do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'crm_auth') then
        create role crm_auth nologin;
    end if;
end $$;

create table crm.app_login (
    tenant_id             smallint not null references crm.tenant,
    employee_id           text not null,
    password_hash         text not null,
    must_change_password  boolean not null default true,
    last_login_at         timestamptz,
    updated_at            timestamptz not null default now(),
    primary key (tenant_id, employee_id),
    foreign key (tenant_id, employee_id) references crm.employee (tenant_id, employee_id)
);

revoke all on crm.app_login from crm_app;

-- Find the login for an email: active employee of an active company only.
create function crm.auth_find_login(p_email text)
returns table (tenant_id smallint, employee_id text, password_hash text)
language sql stable security definer set search_path = crm, pg_temp as $$
    select e.tenant_id, e.employee_id, l.password_hash
    from crm.employee e
    join crm.tenant t on t.tenant_id = e.tenant_id and t.is_active
    join crm.app_login l on l.tenant_id = e.tenant_id and l.employee_id = e.employee_id
    where lower(e.login_email) = lower(p_email)
      and (e.exit_date is null or e.exit_date > current_date)
$$;

-- Everything the app needs about the signed-in person and their company.
create function crm.auth_session_user(p_tenant smallint, p_employee text)
returns table (
    tenant_id smallint, tenant_name text, currency text, locale text, timezone text, phone_prefix text,
    ai_enabled boolean, employee_id text, employee_name text, branch_id smallint, branch_name text,
    access_level text, access_label text, data_scope text, can_write boolean, can_manage_config boolean,
    must_change_password boolean)
language sql stable security definer set search_path = crm, pg_temp as $$
    select t.tenant_id, t.name, t.currency, t.locale, t.timezone, t.phone_prefix, t.ai_enabled,
           e.employee_id, e.employee_name, e.branch_id, b.name,
           a.code, a.label, a.data_scope, a.can_write, a.can_manage_config, l.must_change_password
    from crm.employee e
    join crm.tenant t on t.tenant_id = e.tenant_id and t.is_active
    join crm.access_level a on a.tenant_id = e.tenant_id and a.code = e.crm_access_level
    join crm.app_login l on l.tenant_id = e.tenant_id and l.employee_id = e.employee_id
    left join crm.branch b on b.tenant_id = e.tenant_id and b.branch_id = e.branch_id
    where e.tenant_id = p_tenant and e.employee_id = p_employee
      and (e.exit_date is null or e.exit_date > current_date)
$$;

create function crm.auth_password_hash(p_tenant smallint, p_employee text)
returns text language sql stable security definer set search_path = crm, pg_temp as $$
    select password_hash from crm.app_login where tenant_id = p_tenant and employee_id = p_employee
$$;

create function crm.auth_record_login(p_tenant smallint, p_employee text)
returns void language sql security definer set search_path = crm, pg_temp as $$
    update crm.app_login set last_login_at = now() where tenant_id = p_tenant and employee_id = p_employee
$$;

-- Set a password. must_change = true for a temporary password issued by an admin.
-- The AI agent account can never sign in.
create function crm.auth_set_password(p_tenant smallint, p_employee text, p_hash text, p_must_change boolean)
returns void language plpgsql security definer set search_path = crm, pg_temp as $$
begin
    if exists (select 1 from crm.employee e join crm.access_level a
                 on a.tenant_id = e.tenant_id and a.code = e.crm_access_level
               where e.tenant_id = p_tenant and e.employee_id = p_employee and a.code = 'AI_AGENT') then
        raise exception 'The AI agent account cannot have a login' using errcode = 'check_violation';
    end if;
    insert into crm.app_login (tenant_id, employee_id, password_hash, must_change_password)
    values (p_tenant, p_employee, p_hash, p_must_change)
    on conflict (tenant_id, employee_id) do update
        set password_hash = excluded.password_hash,
            must_change_password = excluded.must_change_password,
            updated_at = now();
end $$;

create function crm.auth_has_login(p_tenant smallint, p_employee text)
returns boolean language sql stable security definer set search_path = crm, pg_temp as $$
    select exists (select 1 from crm.app_login where tenant_id = p_tenant and employee_id = p_employee)
$$;

-- Who in a company has a login (for the staff list).
create function crm.auth_logins(p_tenant smallint)
returns table (employee_id text, last_login_at timestamptz)
language sql stable security definer set search_path = crm, pg_temp as $$
    select employee_id, last_login_at from crm.app_login where tenant_id = p_tenant
$$;

revoke execute on function crm.auth_find_login(text), crm.auth_session_user(smallint, text),
    crm.auth_password_hash(smallint, text), crm.auth_record_login(smallint, text),
    crm.auth_set_password(smallint, text, text, boolean), crm.auth_has_login(smallint, text),
    crm.auth_logins(smallint)
    from public, crm_app;
grant usage on schema crm to crm_auth;
grant execute on function crm.auth_find_login(text), crm.auth_session_user(smallint, text),
    crm.auth_password_hash(smallint, text), crm.auth_record_login(smallint, text),
    crm.auth_set_password(smallint, text, text, boolean), crm.auth_has_login(smallint, text),
    crm.auth_logins(smallint)
    to crm_auth;

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
