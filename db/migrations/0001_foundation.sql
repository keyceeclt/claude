-- =============================================================================
-- Key Cee Associates · Central CRM & BI
-- 0001 · Foundation: configuration, master data, sales pipeline, marketing.
--
-- Design rules (see docs/BLUEPRINT.md):
--   * One lead links to BOTH a customer and a source/campaign (joins the two flows).
--   * Follow-ups are lead activities with a due date (no separate table).
--   * Store visits, quotations and sales are optional steps, not a mandatory chain.
--   * A sale keeps its lead_id (blank for walk-ins) so revenue traces to campaigns.
--   * "Won" is set by the system when a sale is linked to a lead; never by hand.
-- =============================================================================

create schema if not exists crm;

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- Generic pick-lists. Rows seeded with is_placeholder = true are NOT confirmed
-- business values; Head Office must replace or confirm them (see v_setup_gaps).
create table crm.lookup_value (
    category        text    not null,
    code            text    not null,
    label           text    not null,
    sort_order      int     not null default 0,
    is_placeholder  boolean not null default true,
    is_active       boolean not null default true,
    primary key (category, code),
    check (code ~ '^[A-Z0-9_]+$')
);

-- Existence check used by CHECK constraints. Deactivated values stay valid so
-- history is never broken; the UI offers only active ones.
create function crm.lookup_ok(p_category text, p_code text)
returns boolean language sql stable as $$
    select p_code is null
        or exists (select 1 from crm.lookup_value
                   where category = p_category and code = p_code)
$$;

-- CRM access levels. Labels are configurable; data_scope drives security.
create table crm.access_level (
    code               text primary key check (code ~ '^[A-Z0-9_]+$'),
    label              text    not null,
    data_scope         text    not null check (data_scope in ('ALL', 'BRANCH', 'OWN')),
    can_write          boolean not null default true,
    can_manage_config  boolean not null default false,
    is_placeholder     boolean not null default true,
    sort_order         int     not null default 0
);

-- Tunable business rules (SLA hours, stale-lead days, ...).
create table crm.setting (
    key             text primary key,
    value           numeric not null,
    unit            text    not null,
    description     text    not null,
    is_placeholder  boolean not null default true
);

create function crm.setting_value(p_key text)
returns numeric language sql stable as $$
    select value from crm.setting where key = p_key
$$;

-- -----------------------------------------------------------------------------
-- 01_COMPANY / 03_HR
-- -----------------------------------------------------------------------------

create table crm.branch (
    branch_id   smallint generated always as identity primary key,
    code        text not null unique check (code ~ '^[A-Z0-9_]+$'),
    name        text not null,
    location    text,
    city        text,
    district    text,
    opened_on   date,
    is_active   boolean not null default true
);

-- Employee_Master. branch_id NULL = Head Office.
-- Changes from the field list: Reporting_Manager holds an Employee_ID;
-- Target moved to staff_target; Exit_Date, mobile and login added.
create table crm.employee (
    employee_id           text primary key,
    employee_name         text not null,
    branch_id             smallint references crm.branch,
    designation           text check (crm.lookup_ok('DESIGNATION', designation)),
    department            text check (crm.lookup_ok('DEPARTMENT', department)),
    joining_date          date,
    status                text not null check (crm.lookup_ok('EMPLOYEE_STATUS', status)),
    exit_date             date,
    reporting_manager_id  text references crm.employee,
    crm_access_level      text not null references crm.access_level,
    mobile                text,
    login_email           text unique,
    auth_user_id          uuid unique,       -- Supabase auth.users.id
    created_at            timestamptz not null default now(),
    check (reporting_manager_id is distinct from employee_id),
    check (exit_date is null or joining_date is null or exit_date >= joining_date)
);

-- Replaces the single Target field: one row per employee, period and measure.
-- target_type is a fixed list because the system computes actuals for it.
create table crm.staff_target (
    target_id     bigint generated always as identity primary key,
    employee_id   text not null references crm.employee,
    period_type   text not null check (period_type in ('DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR')),
    period_start  date not null,
    period_end    date not null,
    target_type   text not null check (target_type in ('SALES_VALUE', 'SALES_COUNT', 'LEADS_WON', 'STORE_VISITS')),
    target_value  numeric(14, 2) not null check (target_value >= 0),
    unique (employee_id, target_type, period_start, period_end),
    check (period_end >= period_start)
);

-- -----------------------------------------------------------------------------
-- 04_CRM · Customers
-- -----------------------------------------------------------------------------

-- Indian mobile numbers: strip spaces/+91/leading 0, keep 10 digits.
create function crm.normalize_mobile(p text)
returns text language sql immutable as $$
    select case
        when d ~ '^91[6-9][0-9]{9}$' then substr(d, 3)
        when d ~ '^0[6-9][0-9]{9}$'  then substr(d, 2)
        else d
    end
    from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

create table crm.customer (
    customer_id        bigint generated always as identity primary key,
    customer_name      text,
    mobile             text not null unique check (mobile ~ '^[6-9][0-9]{9}$'),
    alt_mobile         text check (alt_mobile is null or alt_mobile ~ '^[6-9][0-9]{9}$'),
    email              text,
    area               text,
    city               text,
    district           text,
    segment            text check (crm.lookup_ok('CUSTOMER_SEGMENT', segment)),
    home_branch_id     smallint references crm.branch,
    marketing_consent  boolean,             -- NULL = not asked yet
    created_by         text references crm.employee,
    created_at         timestamptz not null default now()
);

create function crm.tg_customer_normalize() returns trigger language plpgsql as $$
begin
    new.mobile := crm.normalize_mobile(new.mobile);
    if new.alt_mobile is not null then
        new.alt_mobile := nullif(crm.normalize_mobile(new.alt_mobile), '');
    end if;
    new.customer_name := nullif(btrim(new.customer_name), '');
    return new;
end $$;

create trigger customer_normalize before insert or update on crm.customer
    for each row execute function crm.tg_customer_normalize();

-- -----------------------------------------------------------------------------
-- 06_MARKETING · Campaigns and lead sources
-- -----------------------------------------------------------------------------

create table crm.lead_source (
    source_code     text primary key check (source_code ~ '^[A-Z0-9_]+$'),
    source_name     text    not null,
    is_paid         boolean not null default false,
    is_placeholder  boolean not null default true,
    is_active       boolean not null default true
);

create table crm.campaign (
    campaign_id    bigint generated always as identity primary key,
    campaign_code  text unique,
    campaign_name  text not null,
    source_code    text not null references crm.lead_source,
    branch_id      smallint references crm.branch,   -- NULL = all branches
    start_date     date not null,
    end_date       date,
    budget         numeric(14, 2) check (budget >= 0),
    actual_spend   numeric(14, 2) check (actual_spend >= 0),
    objective      text,
    created_at     timestamptz not null default now(),
    check (end_date is null or end_date >= start_date)
);

-- -----------------------------------------------------------------------------
-- 04_CRM · Leads, stages, activities (follow-ups)
-- -----------------------------------------------------------------------------

create table crm.lead_stage (
    code                      text primary key check (code ~ '^[A-Z0-9_]+$'),
    label                     text    not null,
    stage_order               int     not null,
    is_closed                 boolean not null default false,
    is_won                    boolean not null default false,
    is_lost                   boolean not null default false,
    excluded_from_conversion  boolean not null default false,  -- junk / duplicate / wrong number
    is_placeholder            boolean not null default true,
    is_active                 boolean not null default true,
    check (not (is_won and is_lost)),
    check (not (is_won or is_lost) or is_closed)
);

-- Exactly one "won" stage, owned by the system.
create unique index lead_stage_single_won on crm.lead_stage (is_won) where is_won;

create table crm.lead (
    lead_id                bigint generated always as identity primary key,
    customer_id            bigint   not null references crm.customer,
    branch_id              smallint not null references crm.branch,
    assigned_to            text references crm.employee,
    source_code            text not null references crm.lead_source,
    campaign_id            bigint references crm.campaign,
    product_category       text check (crm.lookup_ok('PRODUCT_CATEGORY', product_category)),
    product_interest       text,
    budget_value           numeric(14, 2) check (budget_value >= 0),
    expected_purchase_on   date,
    stage_code             text not null references crm.lead_stage,
    lost_reason            text check (crm.lookup_ok('LOST_REASON', lost_reason)),
    created_by             text references crm.employee,
    created_at             timestamptz not null default now(),
    first_contact_at       timestamptz,   -- system: first activity that reached the customer
    last_activity_at       timestamptz,   -- system
    stage_changed_at       timestamptz not null default now(),
    closed_at              timestamptz    -- system
);

create index lead_branch_stage on crm.lead (branch_id, stage_code);
create index lead_assigned on crm.lead (assigned_to);
create index lead_customer on crm.lead (customer_id);
create index lead_campaign on crm.lead (campaign_id);

create table crm.lead_stage_history (
    history_id   bigint generated always as identity primary key,
    lead_id      bigint not null references crm.lead,
    from_stage   text references crm.lead_stage,
    to_stage     text not null references crm.lead_stage,
    changed_at   timestamptz not null default now(),
    changed_by   text references crm.employee
);

create table crm.activity_outcome (
    code               text primary key check (code ~ '^[A-Z0-9_]+$'),
    label              text    not null,
    customer_reached   boolean not null,
    is_placeholder     boolean not null default true,
    is_active          boolean not null default true
);

-- One table for calls, WhatsApp, visits-as-activity and scheduled follow-ups.
--   due_at set, completed_at NULL  -> pending follow-up (overdue once due_at passes)
--   completed_at set               -> done; outcome required
create table crm.lead_activity (
    activity_id    bigint generated always as identity primary key,
    lead_id        bigint not null references crm.lead,
    employee_id    text   not null references crm.employee,
    activity_type  text   not null check (crm.lookup_ok('ACTIVITY_TYPE', activity_type)),
    due_at         timestamptz,
    completed_at   timestamptz,
    outcome        text references crm.activity_outcome,
    notes          text,
    created_at     timestamptz not null default now(),
    check (due_at is not null or completed_at is not null),
    check ((completed_at is null) = (outcome is null))
);

create index lead_activity_lead on crm.lead_activity (lead_id);
create index lead_activity_open_due on crm.lead_activity (due_at) where completed_at is null;

-- -----------------------------------------------------------------------------
-- 05_SALES · Store visits, quotations, sales (all optional steps)
-- -----------------------------------------------------------------------------

create table crm.store_visit (
    visit_id      bigint generated always as identity primary key,
    customer_id   bigint   not null references crm.customer,
    lead_id       bigint references crm.lead,     -- NULL = walk-in without a lead
    branch_id     smallint not null references crm.branch,
    visit_at      timestamptz not null,
    attended_by   text references crm.employee,
    notes         text,
    created_at    timestamptz not null default now()
);

create table crm.quotation (
    quotation_id   bigint generated always as identity primary key,
    quotation_no   text,
    customer_id    bigint   not null references crm.customer,
    lead_id        bigint references crm.lead,
    branch_id      smallint not null references crm.branch,
    prepared_by    text references crm.employee,
    quoted_on      date not null,
    valid_until    date,
    total_value    numeric(14, 2) not null check (total_value >= 0),
    status         text not null default 'OPEN' check (status in ('OPEN', 'ACCEPTED', 'REJECTED', 'EXPIRED')),
    created_at     timestamptz not null default now(),
    unique (branch_id, quotation_no)
);

-- Revenue source of truth. Expected to be loaded from the billing system.
create table crm.sale (
    sale_id        bigint generated always as identity primary key,
    invoice_no     text     not null,
    branch_id      smallint not null references crm.branch,
    invoice_date   date     not null,
    customer_id    bigint references crm.customer,   -- NULL only for anonymous counter sales
    lead_id        bigint references crm.lead,       -- NULL = walk-in / direct sale
    quotation_id   bigint references crm.quotation,
    sold_by        text references crm.employee,
    net_value      numeric(14, 2) not null check (net_value >= 0),
    created_at     timestamptz not null default now(),
    unique (branch_id, invoice_no),
    check (lead_id is null or customer_id is not null)
);

create index sale_lead on crm.sale (lead_id);
create index sale_branch_date on crm.sale (branch_id, invoice_date);

create table crm.sale_item (
    sale_id           bigint not null references crm.sale on delete cascade,
    line_no           int    not null,
    product_category  text check (crm.lookup_ok('PRODUCT_CATEGORY', product_category)),
    model_code        text,
    description       text,
    quantity          int not null check (quantity > 0),
    line_value        numeric(14, 2) not null check (line_value >= 0),
    primary key (sale_id, line_no)
);

-- -----------------------------------------------------------------------------
-- Business-rule triggers
-- -----------------------------------------------------------------------------

-- Employee acting in this session (Supabase JWT first, then app.employee_id for
-- server jobs and tests). Exited staff resolve to NULL and so see nothing.
create function crm.current_employee_id()
returns text language sql stable security definer set search_path = crm, pg_temp as $$
    select e.employee_id
    from crm.employee e
    where (e.exit_date is null or e.exit_date > current_date)
      and e.employee_id = coalesce(
            (select employee_id from crm.employee
             where auth_user_id = nullif(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub', '')::uuid),
            nullif(current_setting('app.employee_id', true), ''))
$$;

-- Visits, quotations and sales linked to a lead must be for that lead's customer.
create function crm.tg_check_lead_customer() returns trigger language plpgsql as $$
declare
    v_customer bigint;
begin
    if new.lead_id is not null then
        select customer_id into v_customer from crm.lead where lead_id = new.lead_id;
        if new.customer_id is distinct from v_customer then
            raise exception '%: customer % does not match lead % (customer %)',
                tg_table_name, new.customer_id, new.lead_id, v_customer
                using errcode = 'check_violation';
        end if;
    end if;
    return new;
end $$;

create trigger store_visit_lead_customer before insert or update on crm.store_visit
    for each row execute function crm.tg_check_lead_customer();
create trigger quotation_lead_customer before insert or update on crm.quotation
    for each row execute function crm.tg_check_lead_customer();
create trigger sale_lead_customer before insert or update on crm.sale
    for each row execute function crm.tg_check_lead_customer();

-- Lead stage rules.
create function crm.tg_lead_stage_rules() returns trigger language plpgsql as $$
declare
    s crm.lead_stage;
begin
    if tg_op = 'INSERT' and new.stage_code is null then
        select code into new.stage_code from crm.lead_stage
        where is_active and not is_closed order by stage_order limit 1;
    end if;

    select * into s from crm.lead_stage where code = new.stage_code;

    if tg_op = 'UPDATE' and new.stage_code is not distinct from old.stage_code
       and new.lost_reason is not distinct from old.lost_reason then
        return new;
    end if;

    if s.is_won and not exists (select 1 from crm.sale where lead_id = new.lead_id) then
        raise exception 'Lead % cannot be marked won without a linked sale', new.lead_id
            using errcode = 'check_violation';
    end if;
    if s.is_lost and new.lost_reason is null then
        raise exception 'Choose a lost reason to close lead % as lost', new.lead_id
            using errcode = 'check_violation';
    end if;
    if not s.is_lost then
        new.lost_reason := null;
    end if;

    if tg_op = 'INSERT' or new.stage_code is distinct from old.stage_code then
        new.stage_changed_at := now();
        new.closed_at := case when s.is_closed then now() end;
    end if;
    return new;
end $$;

create trigger lead_stage_rules before insert or update of stage_code, lost_reason on crm.lead
    for each row execute function crm.tg_lead_stage_rules();

create function crm.tg_lead_stage_history() returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' or new.stage_code is distinct from old.stage_code then
        insert into crm.lead_stage_history (lead_id, from_stage, to_stage, changed_by)
        values (new.lead_id,
                case when tg_op = 'UPDATE' then old.stage_code end,
                new.stage_code,
                crm.current_employee_id());
    end if;
    return null;
end $$;

create trigger lead_stage_history after insert or update of stage_code on crm.lead
    for each row execute function crm.tg_lead_stage_history();

-- A linked sale moves the lead to the won stage.
create function crm.tg_sale_marks_lead_won() returns trigger language plpgsql as $$
begin
    if new.lead_id is not null then
        update crm.lead
        set stage_code = (select code from crm.lead_stage where is_won)
        where lead_id = new.lead_id
          and stage_code <> (select code from crm.lead_stage where is_won);
    end if;
    return null;
end $$;

create trigger sale_marks_lead_won after insert or update of lead_id on crm.sale
    for each row execute function crm.tg_sale_marks_lead_won();

-- Activities keep lead.first_contact_at / last_activity_at current.
create function crm.tg_activity_touch_lead() returns trigger language plpgsql as $$
begin
    if new.completed_at is not null then
        update crm.lead l
        set last_activity_at = greatest(l.last_activity_at, new.completed_at),
            first_contact_at = case
                when (select customer_reached from crm.activity_outcome where code = new.outcome)
                then least(coalesce(l.first_contact_at, new.completed_at), new.completed_at)
                else l.first_contact_at end
        where l.lead_id = new.lead_id;
    end if;
    return null;
end $$;

create trigger activity_touch_lead after insert or update of completed_at, outcome on crm.lead_activity
    for each row execute function crm.tg_activity_touch_lead();
