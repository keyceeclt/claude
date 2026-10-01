-- =============================================================================
-- 0006 · AI sales agents.
--
-- Agents suggest; people decide.
--   * Every agent run is logged (crm.agent_run) with its token use and cost,
--     so each company's AI spend is visible and capped by its monthly budget.
--   * Agents act through the company's "AI-AGENT" employee record, as role
--     crm_app, so the same row-level security applies to them as to staff.
--   * Agents may only read, log their runs, write suggestions and briefs, and
--     (when the company allows it) schedule a pending follow-up. They cannot
--     change leads, customers, sales or configuration, and cannot record a
--     completed contact with a customer.
--   * Anything an agent scheduled can be undone by staff (crm.undo_agent_followup).
-- =============================================================================

-- Is the acting employee an AI agent?
create function crm.me_is_agent() returns boolean
language sql stable security definer set search_path = crm, pg_temp as $$
    select coalesce(bool_or(e.crm_access_level = 'AI_AGENT'), false)
    from crm.employee e
    where e.tenant_id = crm.current_tenant_id() and e.employee_id = crm.current_employee_id()
$$;

-- -----------------------------------------------------------------------------
-- Runs: one row per agent job (a schedule tick or a button press).
-- -----------------------------------------------------------------------------
create table crm.agent_run (
    run_id         bigint generated always as identity primary key,
    tenant_id      smallint not null default crm.current_tenant_id() references crm.tenant,
    agent          text not null check (agent in ('LEAD_RESCUE', 'FOLLOWUP_WRITER', 'DAILY_BRIEF')),
    requested_by   text,                -- employee who pressed the button; NULL = schedule
    branch_id      smallint,
    lead_id        bigint,
    status         text not null default 'RUNNING' check (status in ('RUNNING', 'DONE', 'FAILED', 'SKIPPED')),
    model          text,
    input_tokens   int not null default 0,
    output_tokens  int not null default 0,
    cost_usd       numeric(10, 4) not null default 0 check (cost_usd >= 0),
    items          int not null default 0,  -- suggestions / briefs produced
    note           text,                    -- why skipped or failed
    started_at     timestamptz not null default now(),
    finished_at    timestamptz,
    unique (tenant_id, run_id),
    foreign key (tenant_id, requested_by) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id)
);
create index agent_run_month on crm.agent_run (tenant_id, started_at);

alter table crm.lead_activity
    add foreign key (tenant_id, agent_run_id) references crm.agent_run (tenant_id, run_id),
    add check ((origin = 'AGENT') = (agent_run_id is not null));

-- -----------------------------------------------------------------------------
-- Suggestions: next steps (Lead Rescue) and message drafts (Follow-up Writer).
--   OPEN       waiting for a person
--   ACCEPTED   a person acted on it (activity_id = the follow-up they created)
--   DISMISSED  a person declined it
--   APPLIED    the agent scheduled the follow-up itself (company allows it)
--   UNDONE     a person cancelled what the agent scheduled
-- -----------------------------------------------------------------------------
create table crm.agent_suggestion (
    suggestion_id     bigint generated always as identity primary key,
    tenant_id         smallint not null default crm.current_tenant_id() references crm.tenant,
    run_id            bigint not null,
    kind              text not null check (kind in ('FOLLOWUP', 'MESSAGE')),
    lead_id           bigint not null,
    branch_id         smallint not null,
    assigned_to       text,              -- who should act (the lead owner)
    priority          smallint not null default 2 check (priority between 1 and 3),  -- 1 = today
    activity_type     text check (crm.lookup_ok(tenant_id, 'ACTIVITY_TYPE', activity_type)),
    suggested_due_at  timestamptz,
    reason            text not null,     -- why, citing the lead's own record
    message           text,              -- draft wording for the customer
    status            text not null default 'OPEN'
                      check (status in ('OPEN', 'ACCEPTED', 'DISMISSED', 'APPLIED', 'UNDONE')),
    activity_id       bigint,
    decided_by        text,
    decided_at        timestamptz,
    created_at        timestamptz not null default now(),
    foreign key (tenant_id, run_id) references crm.agent_run (tenant_id, run_id),
    foreign key (tenant_id, lead_id) references crm.lead (tenant_id, lead_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    foreign key (tenant_id, assigned_to) references crm.employee (tenant_id, employee_id),
    foreign key (tenant_id, decided_by) references crm.employee (tenant_id, employee_id),
    check (kind <> 'FOLLOWUP' or (activity_type is not null and suggested_due_at is not null)),
    check (kind <> 'MESSAGE' or message is not null),
    check ((status in ('ACCEPTED', 'APPLIED')) <= (activity_id is not null) or kind = 'MESSAGE'),
    check ((status in ('OPEN', 'APPLIED')) = (decided_at is null))
);
create index agent_suggestion_open on crm.agent_suggestion (tenant_id, assigned_to) where status = 'OPEN';
create index agent_suggestion_lead on crm.agent_suggestion (lead_id);

-- -----------------------------------------------------------------------------
-- Daily briefs: a short narrative per branch (branch_id NULL = whole company),
-- written only from the numbers stored with it in facts.
-- -----------------------------------------------------------------------------
create table crm.agent_brief (
    brief_id            bigint generated always as identity primary key,
    tenant_id           smallint not null default crm.current_tenant_id() references crm.tenant,
    run_id              bigint not null,
    branch_id           smallint,
    brief_date          date not null,
    body                text not null,
    facts               jsonb not null,
    unverified_numbers  text[] not null default '{}',  -- numbers in body not found in facts
    created_at          timestamptz not null default now(),
    foreign key (tenant_id, run_id) references crm.agent_run (tenant_id, run_id),
    foreign key (tenant_id, branch_id) references crm.branch (tenant_id, branch_id),
    unique nulls not distinct (tenant_id, branch_id, brief_date)
);

-- -----------------------------------------------------------------------------
-- Security
-- -----------------------------------------------------------------------------
grant select on crm.agent_run, crm.agent_suggestion, crm.agent_brief to crm_app;
grant insert on crm.agent_run, crm.agent_suggestion, crm.agent_brief to crm_app;
grant update (status, input_tokens, output_tokens, cost_usd, items, note, model, finished_at) on crm.agent_run to crm_app;
grant update (status, activity_id, decided_by, decided_at) on crm.agent_suggestion to crm_app;
grant update (body, facts, unverified_numbers, run_id, created_at) on crm.agent_brief to crm_app;
grant delete on crm.lead_activity to crm_app;   -- only agent follow-ups, see policy below

alter table crm.agent_run enable row level security;
create policy agent_run_read on crm.agent_run for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or requested_by = crm.current_employee_id());
create policy agent_run_insert on crm.agent_run for insert to crm_app with check (crm.me_is_agent());
create policy agent_run_update on crm.agent_run for update to crm_app using (crm.me_is_agent());

alter table crm.agent_suggestion enable row level security;
create policy agent_suggestion_read on crm.agent_suggestion for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
    or assigned_to = crm.current_employee_id());
create policy agent_suggestion_insert on crm.agent_suggestion for insert to crm_app with check (crm.me_is_agent());
create policy agent_suggestion_update on crm.agent_suggestion for update to crm_app using (
    crm.me_can_write() and not crm.me_is_agent() and (
        crm.me_scope() = 'ALL'
        or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch())
        or assigned_to = crm.current_employee_id()));

alter table crm.agent_brief enable row level security;
create policy agent_brief_read on crm.agent_brief for select to crm_app using (
    crm.me_scope() = 'ALL'
    or (crm.me_scope() = 'BRANCH' and branch_id = crm.me_branch()));
create policy agent_brief_insert on crm.agent_brief for insert to crm_app with check (crm.me_is_agent());
create policy agent_brief_update on crm.agent_brief for update to crm_app using (crm.me_is_agent());

-- Company isolation, as on every other table (0002 covered the older ones).
do $$
declare t text;
begin
    foreach t in array array['agent_run', 'agent_suggestion', 'agent_brief'] loop
        execute format('create policy tenant_isolation on crm.%I as restrictive to crm_app
                        using (tenant_id = crm.current_tenant_id())
                        with check (tenant_id = crm.current_tenant_id())', t);
    end loop;
end $$;

-- What agents may NOT do. Restrictive policies are ANDed with everything else.
do $$
declare t text;
begin
    foreach t in array array['customer', 'lead', 'store_visit', 'quotation', 'sale', 'sale_item',
                             'campaign', 'employee', 'staff_target', 'lookup_value', 'access_level',
                             'setting', 'branch', 'lead_source', 'lead_stage', 'activity_outcome'] loop
        execute format('create policy no_agent_insert on crm.%I as restrictive for insert to crm_app
                        with check (not crm.me_is_agent())', t);
        execute format('create policy no_agent_update on crm.%I as restrictive for update to crm_app
                        using (not crm.me_is_agent())', t);
    end loop;
end $$;
create policy no_agent_update on crm.tenant as restrictive for update to crm_app using (not crm.me_is_agent());

-- People can never be given the agent's access level through the app.
create policy no_agent_level_insert on crm.employee as restrictive for insert to crm_app
    with check (crm_access_level <> 'AI_AGENT');
create policy no_agent_level_update on crm.employee as restrictive for update to crm_app
    using (crm_access_level <> 'AI_AGENT') with check (crm_access_level <> 'AI_AGENT');

-- Activities: agents only add pending follow-ups marked as theirs; people
-- cannot pass their own work off as the agent's, and vice versa.
create policy agent_origin_insert on crm.lead_activity as restrictive for insert to crm_app
    with check ((origin = 'AGENT') = crm.me_is_agent() and (origin <> 'AGENT' or completed_at is null));
create policy agent_origin_update on crm.lead_activity as restrictive for update to crm_app
    using (not crm.me_is_agent());
-- Delete exists only to undo an agent's pending follow-up.
create policy lead_activity_undo on crm.lead_activity for delete to crm_app using (
    origin = 'AGENT' and completed_at is null and crm.me_can_write() and not crm.me_is_agent()
    and exists (select 1 from crm.lead l where l.lead_id = lead_activity.lead_id)
    and (crm.me_scope() in ('ALL', 'BRANCH') or employee_id = crm.current_employee_id()));

-- Undo a follow-up the agent scheduled: removes it while still pending and
-- keeps the suggestion as the record of what happened. Runs as the caller,
-- so the policies above decide whether they may.
create function crm.undo_agent_followup(p_suggestion bigint)
returns void language plpgsql as $$
declare
    s crm.agent_suggestion;
    n int;
begin
    select * into s from crm.agent_suggestion where suggestion_id = p_suggestion and status = 'APPLIED';
    if not found then
        raise exception 'Nothing to undo' using errcode = 'check_violation';
    end if;
    delete from crm.lead_activity where activity_id = s.activity_id and origin = 'AGENT' and completed_at is null;
    get diagnostics n = row_count;
    if n = 0 then
        raise exception 'This follow-up was already done or cannot be undone' using errcode = 'check_violation';
    end if;
    update crm.agent_suggestion
       set status = 'UNDONE', activity_id = null, decided_by = crm.current_employee_id(), decided_at = now()
     where suggestion_id = p_suggestion;
end $$;
grant execute on function crm.undo_agent_followup(bigint), crm.me_is_agent() to crm_app;

-- -----------------------------------------------------------------------------
-- AI spend
-- -----------------------------------------------------------------------------
-- This company's AI spend in the current calendar month (company time zone).
create function crm.ai_spend_this_month() returns numeric
language sql stable security definer set search_path = crm, pg_temp as $$
    select coalesce(sum(cost_usd), 0) from crm.agent_run
    where tenant_id = crm.current_tenant_id()
      and crm.local_date(started_at) >= date_trunc('month', crm.local_date(now()))::date
$$;
grant execute on function crm.ai_spend_this_month() to crm_app;

create view crm.v_ai_usage_monthly with (security_invoker = true) as
select tenant_id,
       date_trunc('month', crm.local_date(started_at))::date as month,
       agent,
       count(*) as runs,
       count(*) filter (where status = 'FAILED') as failed_runs,
       count(*) filter (where status = 'SKIPPED') as skipped_runs,
       sum(items) as items,
       sum(input_tokens) as input_tokens,
       sum(output_tokens) as output_tokens,
       sum(cost_usd) as cost_usd
from crm.agent_run
group by 1, 2, 3;

-- How people respond to suggestions: the measure of whether agents help.
create view crm.v_agent_suggestion_outcomes with (security_invoker = true) as
select s.tenant_id,
       date_trunc('month', crm.local_date(s.created_at))::date as month,
       s.branch_id, s.kind,
       count(*) as suggestions,
       count(*) filter (where s.status = 'OPEN') as open,
       count(*) filter (where s.status = 'ACCEPTED') as accepted,
       count(*) filter (where s.status = 'APPLIED') as auto_applied,
       count(*) filter (where s.status = 'DISMISSED') as dismissed,
       count(*) filter (where s.status = 'UNDONE') as undone,
       count(distinct s.lead_id) filter (where l.stage_code = st.code) as leads_later_won
from crm.agent_suggestion s
join crm.lead l on l.lead_id = s.lead_id
left join crm.lead_stage st on st.tenant_id = l.tenant_id and st.is_won
group by 1, 2, 3, 4;

grant select on crm.v_ai_usage_monthly, crm.v_agent_suggestion_outcomes to crm_app;
