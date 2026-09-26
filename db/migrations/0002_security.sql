-- =============================================================================
-- 0002 · Security: role-based, branch-scoped row level security.
--
-- Every signed-in user maps to one employee. The employee's CRM access level
-- decides what they see:
--   ALL     Head Office: every branch
--   BRANCH  Branch Manager: their own branch
--   OWN     Staff / telecaller: leads assigned to or created by them
-- can_write = false gives read-only access (e.g. an HO analyst).
-- Config and master data changes need can_manage_config.
--
-- Supabase: run `grant crm_app to authenticated;` after this migration and set
-- employee.auth_user_id for each login.
-- =============================================================================

do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'crm_app') then
        create role crm_app nologin;
    end if;
end $$;

-- The acting employee's scope, resolved once per statement.
create function crm.me_branch() returns smallint
language sql stable security definer set search_path = crm, pg_temp as $$
    select branch_id from crm.employee where employee_id = crm.current_employee_id()
$$;

create function crm.me_scope() returns text
language sql stable security definer set search_path = crm, pg_temp as $$
    select a.data_scope
    from crm.employee e join crm.access_level a on a.code = e.crm_access_level
    where e.employee_id = crm.current_employee_id()
$$;

create function crm.me_can_write() returns boolean
language sql stable security definer set search_path = crm, pg_temp as $$
    select coalesce(bool_and(a.can_write), false)
    from crm.employee e join crm.access_level a on a.code = e.crm_access_level
    where e.employee_id = crm.current_employee_id()
$$;

create function crm.me_can_manage_config() returns boolean
language sql stable security definer set search_path = crm, pg_temp as $$
    select coalesce(bool_and(a.can_manage_config), false)
    from crm.employee e join crm.access_level a on a.code = e.crm_access_level
    where e.employee_id = crm.current_employee_id()
$$;

-- System-maintained fields are written by triggers regardless of who acts.
alter function crm.tg_lead_stage_rules()      security definer set search_path = crm, pg_temp;
alter function crm.tg_lead_stage_history()    security definer set search_path = crm, pg_temp;
alter function crm.tg_sale_marks_lead_won()   security definer set search_path = crm, pg_temp;
alter function crm.tg_activity_touch_lead()   security definer set search_path = crm, pg_temp;
alter function crm.tg_check_lead_customer()   security definer set search_path = crm, pg_temp;

-- Customers can be shared across branches, so staff search by mobile through
-- this function before creating one (avoids duplicates hidden by RLS).
create function crm.find_customer_by_mobile(p_mobile text)
returns table (customer_id bigint, customer_name text, home_branch_id smallint)
language sql stable security definer set search_path = crm, pg_temp as $$
    select c.customer_id, c.customer_name, c.home_branch_id
    from crm.customer c
    where crm.current_employee_id() is not null
      and c.mobile = crm.normalize_mobile(p_mobile)
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant usage on schema crm to crm_app;
grant select on all tables in schema crm to crm_app;
grant insert, update on crm.customer, crm.lead, crm.lead_activity, crm.store_visit,
    crm.quotation, crm.sale, crm.sale_item, crm.campaign, crm.employee, crm.staff_target,
    crm.lookup_value, crm.access_level, crm.setting, crm.branch, crm.lead_source,
    crm.lead_stage, crm.activity_outcome
    to crm_app;
grant execute on all functions in schema crm to crm_app;
-- No DELETE for app users: records are closed or deactivated, never removed.

-- -----------------------------------------------------------------------------
-- Config / master data: everyone reads, config managers write
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
    foreach t in array array['lookup_value', 'access_level', 'setting', 'branch',
                             'lead_source', 'lead_stage', 'activity_outcome', 'campaign']
    loop
        execute format('alter table crm.%I enable row level security', t);
        execute format('create policy read_all on crm.%I for select to crm_app
                        using (crm.current_employee_id() is not null)', t);
        execute format('create policy config_insert on crm.%I for insert to crm_app
                        with check (crm.me_can_manage_config())', t);
        execute format('create policy config_update on crm.%I for update to crm_app
                        using (crm.me_can_manage_config())', t);
    end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Employees and targets
-- -----------------------------------------------------------------------------
alter table crm.employee enable row level security;
create policy employee_read on crm.employee for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or employee_id = crm.current_employee_id());
create policy employee_insert on crm.employee for insert to crm_app
    with check (crm.me_can_manage_config());
create policy employee_update on crm.employee for update to crm_app
    using (crm.me_can_manage_config());

alter table crm.staff_target enable row level security;
create policy staff_target_read on crm.staff_target for select to crm_app using (
    exists (select 1 from crm.employee e where e.employee_id = staff_target.employee_id));
create policy staff_target_insert on crm.staff_target for insert to crm_app
    with check (crm.me_can_manage_config());
create policy staff_target_update on crm.staff_target for update to crm_app
    using (crm.me_can_manage_config());

-- -----------------------------------------------------------------------------
-- Leads: the anchor for every scoped table
-- -----------------------------------------------------------------------------
alter table crm.lead enable row level security;
create policy lead_read on crm.lead for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or (crm.me_scope() = 'OWN' and crm.current_employee_id() in (assigned_to, created_by)));
create policy lead_insert on crm.lead for insert to crm_app with check (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() in ('BRANCH', 'OWN') and branch_id = crm.me_branch())));
create policy lead_update on crm.lead for update to crm_app using (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
        or (crm.me_scope() = 'OWN' and assigned_to = crm.current_employee_id())));

alter table crm.lead_stage_history enable row level security;
create policy lead_stage_history_read on crm.lead_stage_history for select to crm_app using (
    exists (select 1 from crm.lead l where l.lead_id = lead_stage_history.lead_id));

alter table crm.lead_activity enable row level security;
create policy lead_activity_read on crm.lead_activity for select to crm_app using (
    exists (select 1 from crm.lead l where l.lead_id = lead_activity.lead_id));
create policy lead_activity_insert on crm.lead_activity for insert to crm_app with check (
    crm.me_can_write()
    and exists (select 1 from crm.lead l where l.lead_id = lead_activity.lead_id)
    and (crm.me_scope() in ('ALL', 'BRANCH') or employee_id = crm.current_employee_id()));
create policy lead_activity_update on crm.lead_activity for update to crm_app using (
    crm.me_can_write()
    and exists (select 1 from crm.lead l where l.lead_id = lead_activity.lead_id)
    and (crm.me_scope() in ('ALL', 'BRANCH') or employee_id = crm.current_employee_id()));

-- -----------------------------------------------------------------------------
-- Customers: visible where the viewer has business with them
-- -----------------------------------------------------------------------------
alter table crm.customer enable row level security;
create policy customer_read on crm.customer for select to crm_app using (
    crm.me_scope() = 'ALL'
    or created_by = crm.current_employee_id()
    or (crm.me_scope() = 'BRANCH' and (
            home_branch_id = crm.me_branch()
            or exists (select 1 from crm.sale s where s.customer_id = customer.customer_id)
            or exists (select 1 from crm.store_visit v where v.customer_id = customer.customer_id)))
    or exists (select 1 from crm.lead l where l.customer_id = customer.customer_id));
create policy customer_insert on crm.customer for insert to crm_app
    with check (crm.me_can_write());
create policy customer_update on crm.customer for update to crm_app using (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or created_by = crm.current_employee_id()
        or exists (select 1 from crm.lead l where l.customer_id = customer.customer_id)));

-- -----------------------------------------------------------------------------
-- Visits, quotations, sales
-- -----------------------------------------------------------------------------
alter table crm.store_visit enable row level security;
create policy store_visit_read on crm.store_visit for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or attended_by = crm.current_employee_id()
    or exists (select 1 from crm.lead l where l.lead_id = store_visit.lead_id));
create policy store_visit_insert on crm.store_visit for insert to crm_app with check (
    crm.me_can_write() and (crm.me_scope() = 'ALL' or branch_id = crm.me_branch()));
create policy store_visit_update on crm.store_visit for update to crm_app using (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
        or attended_by = crm.current_employee_id()));

alter table crm.quotation enable row level security;
create policy quotation_read on crm.quotation for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or prepared_by = crm.current_employee_id()
    or exists (select 1 from crm.lead l where l.lead_id = quotation.lead_id));
create policy quotation_insert on crm.quotation for insert to crm_app with check (
    crm.me_can_write() and (crm.me_scope() = 'ALL' or branch_id = crm.me_branch()));
create policy quotation_update on crm.quotation for update to crm_app using (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
        or prepared_by = crm.current_employee_id()));

-- Sales normally arrive from billing; only HO and branch managers enter them.
alter table crm.sale enable row level security;
create policy sale_read on crm.sale for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or sold_by = crm.current_employee_id()
    or exists (select 1 from crm.lead l where l.lead_id = sale.lead_id));
create policy sale_insert on crm.sale for insert to crm_app with check (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())));
create policy sale_update on crm.sale for update to crm_app using (
    crm.me_can_write() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())));

alter table crm.sale_item enable row level security;
create policy sale_item_read on crm.sale_item for select to crm_app using (
    exists (select 1 from crm.sale s where s.sale_id = sale_item.sale_id));
create policy sale_item_insert on crm.sale_item for insert to crm_app with check (
    crm.me_can_write() and crm.me_scope() in ('ALL', 'BRANCH')
    and exists (select 1 from crm.sale s where s.sale_id = sale_item.sale_id));
create policy sale_item_update on crm.sale_item for update to crm_app using (
    crm.me_can_write() and crm.me_scope() in ('ALL', 'BRANCH')
    and exists (select 1 from crm.sale s where s.sale_id = sale_item.sale_id));
