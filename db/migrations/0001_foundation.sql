-- =============================================================================
-- Agentic Sales CRM for retail
-- 0001 · Foundation: companies (tenants), configuration, master data,
--        sales pipeline, marketing.
--
-- Multi-company design:
--   * Every row carries tenant_id. It defaults to the company of the current
--     session (crm.current_tenant_id()), so application code never passes it.
--   * Row-level security (0002) keeps each company's data invisible to others.
--   * Relationships use composite keys (tenant_id, id), so a record can never
--     point at another company's record, even by guessing an id.
--
-- Sales design rules (see docs/BLUEPRINT.md):
--   * One lead links to BOTH a customer and a source/campaign.
--   * Follow-ups are lead activities with a due date (no separate table).
--   * Store visits, quotations and sales are optional steps, not a chain.
--   * A sale keeps its lead_id (blank for walk-ins) so revenue traces to campaigns.
--   * "Won" is set by the system when a sale is linked to a lead; never by hand.
-- =============================================================================

create schema if not exists crm;

-- -----------------------------------------------------------------------------
-- Companies
-- -----------------------------------------------------------------------------

create table crm.tenant (
    tenant_id              smallint generated always as identity primary key,
    code                   text not null unique check (code ~ '^[A-Z0-9_]+$'),
    name                   text not null,
    -- Market settings (formerly hard-coded for India).
    country_code           text not null default 'IN',
    phone_prefix           text not null default '91',             -- dialling code
    phone_pattern          text not null default '^[6-9][0-9]{9}$', -- national mobile number
    timezone               text not null default 'Asia/Kolkata',
    currency               text not null default 'INR',
    locale                 text not null default 'en-IN',
    -- AI agents: off until the company switches them on.
    ai_enabled             boolean not null default false,
    ai_monthly_budget_usd  numeric(10, 2) not null default 0 check (ai_monthly_budget_usd >= 0),
    ai_auto_schedule       boolean not null default false,  -- Lead Rescue may schedule follow-ups itself
    is_active              boolean not null default true,
    created_at             timestamptz not null default now(),
    check (now() at time zone timezone is not null)
);

-- The company this session acts for. Set by the server per request
-- (app.tenant_id); NULL means no company, so every scoped query returns nothing.
create function crm.current_tenant_id()
returns smallint language sql stable as $$
    select nullif(current_setting('app.tenant_id', true), '')::smallint
$$;

create function crm.tenant_timezone()
returns text language sql stable security definer set search_path = crm, pg_temp as $$
    select coalesce((select timezone from crm.tenant where tenant_id = crm.current_tenant_id()), 'UTC')
$$;

-- Calendar date in the company's own time zone.
create function crm.local_date(ts timestamptz)
returns date language sql stable as $$
    select (ts at time zone crm.tenant_timezone())::date
$$;

-- -----------------------------------------------------------------------------
-- Configuration (per company)
-- -----------------------------------------------------------------------------

-- Generic pick-lists. Rows with is_placeholder = true come from a starter
-- template and are NOT confirmed by the company (see v_setup_gaps).
create table crm.lookup_value (
    tenant_id       smallint not null default crm.current_tenant_id() references crm.tenant,
    category        text    not null,
    code            text    not null,
    label           text    not null,
    sort_order      int     not null default 0,
    is_placeholder  boolean not null default true,
    is_active       boolean not null default true,
    primary key (tenant_id, category, code),
    check (code ~ '^[A-Z0-9_]+$')
);

-- Existence check used by CHECK constraints. Deactivated values stay valid so
-- history is never broken; the UI offers only active ones.
create function crm.lookup_ok(p_tenant smallint, p_category text, p_code text)
returns boolean language sql stable security definer set search_path = crm, pg_temp as $$
    select p_code is null
        or exists (select 1 from crm.lookup_value
                   where tenant_id = p_tenant and category = p_category and code = p_code)
$$;

-- CRM access levels. Labels are configurable; data_scope drives security.
create table crm.access_level (
    tenant_id          smallint not null default crm.current_tenant_id() references crm.tenant,
    code               text    not null check (code ~ '^[A-Z0-9_]+$'),
    label              text    not null,
    data_scope         text    not null check (data_scope in ('ALL', 'BRANCH', 'OWN')),
    can_write          boolean not null default true,
    can_manage_config  boolean not null default false,
    is_placeholder     boolean not null default true,
    sort_order         int     not null default 0,
    primary key (tenant_id, code)
);

-- Tunable business rules (SLA hours, stale-lead days, ...).
create table crm.setting (
    tenant_id       smallint not null default crm.current_tenant_id() references crm.tenant,
    key             text    not null,
    value           numeric not null,
    unit            text    not null,
    description     text    not null,
    is_placeholder  boolean not null default true,
    primary key (tenant_id, key)
);

create function crm.setting_value(p_key text)
returns numeric language sql stable as $$
    select value from crm.setting where tenant_id = crm.current_tenant_id() and key = p_key
$$;

-- -----------------------------------------------------------------------------
-- Branches (stores) and staff
-- -----------------------------------------------------------------------------

create table crm.branch (
    branch_id   smallint generated always as identity primary key,
    tenant_id   smallint not null default crm.current_tenant_id() references crm.tenant,
    code        text not null check (code ~ '^[A-Z0-9_]+$'),
    name        text not null,
    location    text,
    city        text,
    district    text,
    opened_on   date,
    is_active   boolean not null default true,
    unique (tenant_id, code),
    unique (tenant_id, branch_id)
);

-- Employee master. branch_id NULL = head office. Employee IDs are the
-- company's own codes, unique within the company.
create table crm.employee (
    tenant_id             smallint not null default crm.current_tenant_id() references crm.tenant,
    employee_id           text not null,
    employee_name         text not null,
    branch_id             smallint,
    designation           text check (crm.lookup_ok(tenant_id, 'DESIGNATION', designation)),
    department            text check (crm.lookup_ok(tenant_id, 'DEPARTMENT', department)),
    joining_date          date,
    status                text not null check (crm.lookup_ok(tenant_id, 'EMPLOYEE_STATUS', status)),
    exit_date             date,
    reporting_manager_id  text,
    crm_access_level      text not null,
    mobile                text,
    login_email           text,
    created_at            timestamptz not null default now(),
    primary key (tenant_id, employee_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, reporting_manager_id) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, crm_access_level) references crm.access_level (tenant_id, code),
    check (reporting_manager_id is distinct from employee_id),
    check (exit_date is null or joining_date is null or exit_date >= joining_date)
);

-- One login email across the whole platform identifies person and company.
create unique index employee_login_email on crm.employee (lower(login_email)) where login_email is not null;

-- Targets: one row per employee, period and measure. target_type is a fixed
-- list because the system computes actuals for it.
create table crm.staff_target (
    target_id     bigint generated always as identity primary key,
    tenant_id     smallint not null default crm.current_tenant_id() references crm.tenant,
    employee_id   text not null,
    period_type   text not null check (period_type in ('DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR')),
    period_start  date not null,
    period_end    date not null,
    target_type   text not null check (target_type in ('SALES_VALUE', 'SALES_COUNT', 'LEADS_WON', 'STORE_VISITS')),
    target_value  numeric(14, 2) not null check (target_value >= 0),
    foreign key (tenant_id, employee_id) references crm.employee (tenant_id, employee_id),
    unique (tenant_id, employee_id, target_type, period_start, period_end),
    check (period_end >= period_start)
);

-- -----------------------------------------------------------------------------
-- Customers
-- -----------------------------------------------------------------------------

-- Strip spaces, punctuation, the country code and a trunk 0 from a phone number.
create function crm.normalize_mobile(p text, p_prefix text)
returns text language sql immutable as $$
    select case
        when p_prefix <> '' and d like p_prefix || '%' and length(d) > length(p_prefix) + 8
            then substr(d, length(p_prefix) + 1)
        when d like '0%' and length(d) > 9 then ltrim(d, '0')
        else d
    end
    from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

-- Normalise with the current company's phone rule (used by lookups).
create function crm.normalize_mobile(p text)
returns text language sql stable security definer set search_path = crm, pg_temp as $$
    select crm.normalize_mobile(p, coalesce(
        (select phone_prefix from crm.tenant where tenant_id = crm.current_tenant_id()), ''))
$$;

create table crm.customer (
    customer_id        bigint generated always as identity primary key,
    tenant_id          smallint not null default crm.current_tenant_id() references crm.tenant,
    customer_name      text,
    mobile             text not null,
    alt_mobile         text,
    email              text,
    area               text,
    city               text,
    district           text,
    segment            text check (crm.lookup_ok(tenant_id, 'CUSTOMER_SEGMENT', segment)),
    home_branch_id     smallint,
    marketing_consent  boolean,             -- NULL = not asked yet
    created_by         text,
    created_at         timestamptz not null default now(),
    constraint customer_mobile_unique unique (tenant_id, mobile),
    unique (tenant_id, customer_id),
    foreign key (tenant_id, home_branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, created_by) references crm.employee (tenant_id, employee_id)
);

-- Normalise and validate phone numbers with the company's own rule.
create function crm.tg_customer_normalize() returns trigger
language plpgsql security definer set search_path = crm, pg_temp as $$
declare
    t crm.tenant;
begin
    select * into t from crm.tenant where tenant_id = new.tenant_id;
    new.mobile := crm.normalize_mobile(new.mobile, t.phone_prefix);
    if new.mobile !~ t.phone_pattern then
        raise exception 'Invalid mobile number %', new.mobile
            using errcode = 'check_violation', constraint = 'customer_mobile_check';
    end if;
    if nullif(btrim(coalesce(new.alt_mobile, '')), '') is null then
        new.alt_mobile := null;
    else
        new.alt_mobile := crm.normalize_mobile(new.alt_mobile, t.phone_prefix);
        if new.alt_mobile !~ t.phone_pattern then
            raise exception 'Invalid alternate mobile number %', new.alt_mobile
                using errcode = 'check_violation', constraint = 'customer_alt_mobile_check';
        end if;
    end if;
    new.customer_name := nullif(btrim(new.customer_name), '');
    return new;
end $$;

create trigger customer_normalize before insert or update on crm.customer
    for each row execute function crm.tg_customer_normalize();

-- -----------------------------------------------------------------------------
-- Marketing: lead sources and campaigns
-- -----------------------------------------------------------------------------

create table crm.lead_source (
    tenant_id       smallint not null default crm.current_tenant_id() references crm.tenant,
    source_code     text    not null check (source_code ~ '^[A-Z0-9_]+$'),
    source_name     text    not null,
    is_paid         boolean not null default false,
    is_placeholder  boolean not null default true,
    is_active       boolean not null default true,
    primary key (tenant_id, source_code)
);

create table crm.campaign (
    campaign_id    bigint generated always as identity primary key,
    tenant_id      smallint not null default crm.current_tenant_id() references crm.tenant,
    campaign_code  text,
    campaign_name  text not null,
    source_code    text not null,
    branch_id      smallint,   -- NULL = all branches
    start_date     date not null,
    end_date       date,
    budget         numeric(14, 2) check (budget >= 0),
    actual_spend   numeric(14, 2) check (actual_spend >= 0),
    objective      text,
    created_at     timestamptz not null default now(),
    unique (tenant_id, campaign_code),
    unique (tenant_id, campaign_id),
    foreign key (tenant_id, source_code) references crm.lead_source (tenant_id, source_code),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    check (end_date is null or end_date >= start_date)
);

-- -----------------------------------------------------------------------------
-- Leads, stages, activities (follow-ups)
-- -----------------------------------------------------------------------------

create table crm.lead_stage (
    tenant_id                 smallint not null default crm.current_tenant_id() references crm.tenant,
    code                      text    not null check (code ~ '^[A-Z0-9_]+$'),
    label                     text    not null,
    stage_order               int     not null,
    is_closed                 boolean not null default false,
    is_won                    boolean not null default false,
    is_lost                   boolean not null default false,
    excluded_from_conversion  boolean not null default false,  -- junk / duplicate / wrong number
    is_placeholder            boolean not null default true,
    is_active                 boolean not null default true,
    primary key (tenant_id, code),
    check (not (is_won and is_lost)),
    check (not (is_won or is_lost) or is_closed)
);

-- Exactly one "won" stage per company, owned by the system.
create unique index lead_stage_single_won on crm.lead_stage (tenant_id) where is_won;

create table crm.lead (
    lead_id                bigint generated always as identity primary key,
    tenant_id              smallint not null default crm.current_tenant_id() references crm.tenant,
    customer_id            bigint   not null,
    branch_id              smallint not null,
    assigned_to            text,
    source_code            text not null,
    campaign_id            bigint,
    product_category       text check (crm.lookup_ok(tenant_id, 'PRODUCT_CATEGORY', product_category)),
    product_interest       text,
    budget_value           numeric(14, 2) check (budget_value >= 0),
    expected_purchase_on   date,
    stage_code             text not null,
    lost_reason            text check (crm.lookup_ok(tenant_id, 'LOST_REASON', lost_reason)),
    created_by             text,
    created_at             timestamptz not null default now(),
    first_contact_at       timestamptz,   -- system: first activity that reached the customer
    last_activity_at       timestamptz,   -- system
    stage_changed_at       timestamptz not null default now(),
    closed_at              timestamptz,   -- system
    unique (tenant_id, lead_id),
    foreign key (tenant_id, customer_id) references crm.customer (tenant_id, customer_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, assigned_to) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, created_by) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, source_code) references crm.lead_source (tenant_id, source_code),
    foreign key (tenant_id, campaign_id) references crm.campaign (tenant_id, campaign_id),
    foreign key (tenant_id, stage_code) references crm.lead_stage (tenant_id, code)
);

create index lead_branch_stage on crm.lead (tenant_id, branch_id, stage_code);
create index lead_assigned on crm.lead (tenant_id, assigned_to);
create index lead_customer on crm.lead (customer_id);
create index lead_campaign on crm.lead (campaign_id);

create table crm.lead_stage_history (
    history_id   bigint generated always as identity primary key,
    tenant_id    smallint not null default crm.current_tenant_id() references crm.tenant,
    lead_id      bigint not null,
    from_stage   text,
    to_stage     text not null,
    changed_at   timestamptz not null default now(),
    changed_by   text,
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id)
);

create index lead_stage_history_lead on crm.lead_stage_history (lead_id);

create table crm.activity_outcome (
    tenant_id          smallint not null default crm.current_tenant_id() references crm.tenant,
    code               text    not null check (code ~ '^[A-Z0-9_]+$'),
    label              text    not null,
    customer_reached   boolean not null,
    is_placeholder     boolean not null default true,
    is_active          boolean not null default true,
    primary key (tenant_id, code)
);

-- One table for calls, WhatsApp, in-store talks and scheduled follow-ups.
--   due_at set, completed_at NULL  -> pending follow-up (overdue once due_at passes)
--   completed_at set               -> done; outcome required
-- origin tells who created it: a person, an import, or an AI agent.
create table crm.lead_activity (
    activity_id    bigint generated always as identity primary key,
    tenant_id      smallint not null default crm.current_tenant_id() references crm.tenant,
    lead_id        bigint not null,
    employee_id    text   not null,
    activity_type  text   not null check (crm.lookup_ok(tenant_id, 'ACTIVITY_TYPE', activity_type)),
    due_at         timestamptz,
    completed_at   timestamptz,
    outcome        text,
    notes          text,
    origin         text not null default 'USER' check (origin in ('USER', 'IMPORT', 'AGENT')),
    agent_run_id   bigint,          -- set when origin = 'AGENT' (see 0005)
    created_at     timestamptz not null default now(),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id),
    foreign key (tenant_id, employee_id) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, outcome) references crm.activity_outcome (tenant_id, code),
    check (due_at is not null or completed_at is not null),
    check ((completed_at is null) = (outcome is null))
);

create index lead_activity_lead on crm.lead_activity (lead_id);
create index lead_activity_open_due on crm.lead_activity (tenant_id, due_at) where completed_at is null;

-- -----------------------------------------------------------------------------
-- Store visits, quotations, sales (all optional steps)
-- -----------------------------------------------------------------------------

create table crm.store_visit (
    visit_id      bigint generated always as identity primary key,
    tenant_id     smallint not null default crm.current_tenant_id() references crm.tenant,
    customer_id   bigint   not null,
    lead_id       bigint,     -- NULL = walk-in without a lead
    branch_id     smallint not null,
    visit_at      timestamptz not null,
    attended_by   text,
    notes         text,
    created_at    timestamptz not null default now(),
    foreign key (tenant_id, customer_id) references crm.customer (tenant_id, customer_id),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, attended_by) references crm.employee (tenant_id, employee_id)
);

create table crm.quotation (
    quotation_id   bigint generated always as identity primary key,
    tenant_id      smallint not null default crm.current_tenant_id() references crm.tenant,
    quotation_no   text,
    customer_id    bigint   not null,
    lead_id        bigint,
    branch_id      smallint not null,
    prepared_by    text,
    quoted_on      date not null,
    valid_until    date,
    total_value    numeric(14, 2) not null check (total_value >= 0),
    status         text not null default 'OPEN' check (status in ('OPEN', 'ACCEPTED', 'REJECTED', 'EXPIRED')),
    created_at     timestamptz not null default now(),
    unique (tenant_id, branch_id, quotation_no),
    unique (tenant_id, quotation_id),
    foreign key (tenant_id, customer_id) references crm.customer (tenant_id, customer_id),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, prepared_by) references crm.employee (tenant_id, employee_id)
);

-- Revenue source of truth. Expected to be loaded from the billing system.
create table crm.sale (
    sale_id        bigint generated always as identity primary key,
    tenant_id      smallint not null default crm.current_tenant_id() references crm.tenant,
    invoice_no     text     not null,
    branch_id      smallint not null,
    invoice_date   date     not null,
    customer_id    bigint,   -- NULL only for anonymous counter sales
    lead_id        bigint,   -- NULL = walk-in / direct sale
    quotation_id   bigint,
    sold_by        text,
    net_value      numeric(14, 2) not null check (net_value >= 0),
    created_at     timestamptz not null default now(),
    constraint sale_invoice_no_unique unique (tenant_id, branch_id, invoice_no),
    unique (tenant_id, sale_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, customer_id) references crm.customer (tenant_id, customer_id),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id),
    foreign key (tenant_id, quotation_id) references crm.quotation (tenant_id, quotation_id),
    foreign key (tenant_id, sold_by) references crm.employee (tenant_id, employee_id),
    check (lead_id is null or customer_id is not null)
);

create index sale_lead on crm.sale (lead_id);
create index sale_branch_date on crm.sale (tenant_id, branch_id, invoice_date);

create table crm.sale_item (
    tenant_id         smallint not null default crm.current_tenant_id() references crm.tenant,
    sale_id           bigint not null,
    line_no           int    not null,
    product_category  text check (crm.lookup_ok(tenant_id, 'PRODUCT_CATEGORY', product_category)),
    model_code        text,
    description       text,
    quantity          int not null check (quantity > 0),
    line_value        numeric(14, 2) not null check (line_value >= 0),
    primary key (sale_id, line_no),
    foreign key (tenant_id, sale_id) references crm.sale (tenant_id, sale_id) on delete cascade
);

-- -----------------------------------------------------------------------------
-- Business-rule triggers
-- -----------------------------------------------------------------------------

-- Employee acting in this session (set by the server per request).
-- Exited staff resolve to NULL and so see nothing.
create function crm.current_employee_id()
returns text language sql stable security definer set search_path = crm, pg_temp as $$
    select e.employee_id
    from crm.employee e
    where e.tenant_id = crm.current_tenant_id()
      and e.employee_id = nullif(current_setting('app.employee_id', true), '')
      and (e.exit_date is null or e.exit_date > current_date)
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
        where tenant_id = new.tenant_id and is_active and not is_closed
        order by stage_order limit 1;
    end if;

    select * into s from crm.lead_stage where tenant_id = new.tenant_id and code = new.stage_code;

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
        insert into crm.lead_stage_history (tenant_id, lead_id, from_stage, to_stage, changed_by)
        values (new.tenant_id, new.lead_id,
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
declare
    v_won text;
begin
    if new.lead_id is not null then
        select code into v_won from crm.lead_stage where tenant_id = new.tenant_id and is_won;
        update crm.lead set stage_code = v_won
        where lead_id = new.lead_id and stage_code <> v_won;
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
                when (select customer_reached from crm.activity_outcome
                      where tenant_id = new.tenant_id and code = new.outcome)
                then least(coalesce(l.first_contact_at, new.completed_at), new.completed_at)
                else l.first_contact_at end
        where l.lead_id = new.lead_id;
    end if;
    return null;
end $$;

create trigger activity_touch_lead after insert or update of completed_at, outcome on crm.lead_activity
    for each row execute function crm.tg_activity_touch_lead();
