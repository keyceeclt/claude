-- =============================================================================
-- 0003 · Reporting layer (07_REPORTING): KPI and MIS views.
--
-- All views are security_invoker, so a Branch Manager's MIS shows only their
-- branch and a staff member's shows only their own work, from the same view.
--
-- Metric rules (see docs/BLUEPRINT.md, "KPI definitions"):
--   * Conversion = won leads / qualified leads (junk stages excluded), by the
--     month the lead was CREATED (cohort), so late wins count to the right month.
--   * Revenue = sales.net_value. Lead revenue = sales linked to a lead.
--     Walk-in revenue (no lead) is reported separately, never mixed into ROI.
--   * Activities are shown next to outcomes, never as productivity by themselves.
--   * Dates are Asia/Kolkata calendar dates.
-- =============================================================================

create function crm.local_date(ts timestamptz)
returns date language sql immutable as $$
    select (ts at time zone 'Asia/Kolkata')::date
$$;

create function crm.pct(num numeric, den numeric)
returns numeric language sql immutable as $$
    select case when den > 0 then round(100.0 * num / den, 1) end
$$;

-- -----------------------------------------------------------------------------
-- Per-lead status: the building block for leakage, ageing and funnels
-- -----------------------------------------------------------------------------
create view crm.v_lead_status with (security_invoker = true) as
with base as (
    select
        l.lead_id, l.customer_id, l.branch_id, l.assigned_to, l.source_code, l.campaign_id,
        l.product_category, l.budget_value, l.stage_code,
        s.is_closed, s.is_won, s.is_lost, s.excluded_from_conversion,
        l.created_at, crm.local_date(l.created_at) as created_on,
        l.first_contact_at, l.last_activity_at, l.closed_at,
        round((extract(epoch from (l.first_contact_at - l.created_at)) / 3600.0)::numeric, 1)
            as first_contact_hours,
        current_date - crm.local_date(l.created_at) as age_days,
        current_date - crm.local_date(coalesce(l.last_activity_at, l.created_at)) as days_since_activity,
        fu.pending_followups, fu.overdue_followups, fu.next_followup_at,
        exists (select 1 from crm.store_visit v where v.lead_id = l.lead_id) as has_visit,
        exists (select 1 from crm.quotation q where q.lead_id = l.lead_id) as has_quotation,
        coalesce(sv.won_value, 0) as won_value,
        sv.first_sale_on
    from crm.lead l
    join crm.lead_stage s on s.code = l.stage_code
    cross join lateral (
        select count(*) filter (where a.completed_at is null and a.due_at is not null) as pending_followups,
               count(*) filter (where a.completed_at is null and a.due_at < now())      as overdue_followups,
               min(a.due_at) filter (where a.completed_at is null)                     as next_followup_at
        from crm.lead_activity a where a.lead_id = l.lead_id
    ) fu
    cross join lateral (
        select sum(x.net_value) as won_value, min(x.invoice_date) as first_sale_on
        from crm.sale x where x.lead_id = l.lead_id
    ) sv
)
select b.*,
    case
        when b.is_closed then null
        when b.first_contact_at is null
             and now() - b.created_at > make_interval(hours => crm.setting_value('FIRST_CONTACT_SLA_HOURS')::int)
            then 'NOT_CONTACTED_WITHIN_SLA'
        when b.overdue_followups > 0 then 'FOLLOWUP_OVERDUE'
        when b.pending_followups = 0 then 'NO_NEXT_FOLLOWUP'
        when b.days_since_activity >= crm.setting_value('STALE_LEAD_DAYS') then 'STALE'
    end as attention_reason
from base b;

-- -----------------------------------------------------------------------------
-- Follow-up discipline
-- -----------------------------------------------------------------------------
create view crm.v_followup_status with (security_invoker = true) as
select
    a.activity_id, a.lead_id, l.branch_id, a.employee_id, a.activity_type,
    a.due_at, crm.local_date(a.due_at) as due_on, a.completed_at, a.outcome,
    case
        when a.completed_at is null and a.due_at >= now() then 'PENDING'
        when a.completed_at is null then 'OVERDUE'
        when a.completed_at <= a.due_at
             + make_interval(hours => crm.setting_value('FOLLOWUP_GRACE_HOURS')::int) then 'ON_TIME'
        else 'LATE'
    end as followup_status
from crm.lead_activity a
join crm.lead l on l.lead_id = a.lead_id
join crm.lead_stage s on s.code = l.stage_code
-- A follow-up still pending when its lead closed is no longer owed.
where a.due_at is not null
  and (a.completed_at is not null or not s.is_closed);

-- -----------------------------------------------------------------------------
-- Daily MIS: one row per branch per day
-- -----------------------------------------------------------------------------
create view crm.v_daily_mis with (security_invoker = true) as
with
leads as (
    select branch_id, created_on as d,
           count(*) as new_leads,
           count(*) filter (where excluded_from_conversion) as junk_leads
    from crm.v_lead_status group by 1, 2),
acts as (
    select l.branch_id, crm.local_date(a.completed_at) as d,
           count(*) as activities_completed,
           count(distinct a.lead_id) filter (where o.customer_reached) as leads_reached
    from crm.lead_activity a
    join crm.lead l on l.lead_id = a.lead_id
    join crm.activity_outcome o on o.code = a.outcome
    where a.completed_at is not null group by 1, 2),
fus as (
    select branch_id, due_on as d,
           count(*) as followups_due,
           count(*) filter (where followup_status = 'ON_TIME') as followups_on_time,
           count(*) filter (where followup_status = 'LATE')    as followups_late,
           count(*) filter (where followup_status = 'OVERDUE') as followups_still_overdue
    from crm.v_followup_status group by 1, 2),
visits as (
    select branch_id, crm.local_date(visit_at) as d,
           count(*) as store_visits,
           count(*) filter (where lead_id is null) as walk_in_visits
    from crm.store_visit group by 1, 2),
quotes as (
    select branch_id, quoted_on as d, count(*) as quotations, sum(total_value) as quotation_value
    from crm.quotation group by 1, 2),
sales as (
    select branch_id, invoice_date as d,
           count(*) as sales_count, sum(net_value) as sales_value,
           count(*) filter (where lead_id is not null)          as lead_sales_count,
           coalesce(sum(net_value) filter (where lead_id is not null), 0) as lead_sales_value,
           count(*) filter (where lead_id is null)              as walk_in_sales_count,
           coalesce(sum(net_value) filter (where lead_id is null), 0)     as walk_in_sales_value
    from crm.sale group by 1, 2),
lost as (
    select l.branch_id, crm.local_date(h.changed_at) as d, count(distinct h.lead_id) as leads_lost
    from crm.lead_stage_history h
    join crm.lead_stage s on s.code = h.to_stage and s.is_lost
    join crm.lead l on l.lead_id = h.lead_id group by 1, 2),
spine as (
    select b.branch_id, d::date as d
    from crm.branch b
    cross join generate_series(
        (select least(min(created_on), min(first_sale_on)) from crm.v_lead_status),
        current_date, interval '1 day') d
    union
    select branch_id, d from sales)
select
    sp.d as mis_date, branch_id,
    (select b.name from crm.branch b where b.branch_id = sp.branch_id) as branch_name,
    coalesce(leads.new_leads, 0)               as new_leads,
    coalesce(leads.junk_leads, 0)              as junk_leads,
    coalesce(acts.activities_completed, 0)     as activities_completed,
    coalesce(acts.leads_reached, 0)            as leads_reached,
    coalesce(fus.followups_due, 0)             as followups_due,
    coalesce(fus.followups_on_time, 0)         as followups_on_time,
    coalesce(fus.followups_late, 0)            as followups_late,
    coalesce(fus.followups_still_overdue, 0)   as followups_still_overdue,
    crm.pct(fus.followups_on_time, fus.followups_due) as followup_on_time_pct,
    coalesce(visits.store_visits, 0)           as store_visits,
    coalesce(visits.walk_in_visits, 0)         as walk_in_visits,
    coalesce(quotes.quotations, 0)             as quotations,
    coalesce(quotes.quotation_value, 0)        as quotation_value,
    coalesce(sales.sales_count, 0)             as sales_count,
    coalesce(sales.sales_value, 0)             as sales_value,
    coalesce(sales.lead_sales_count, 0)        as lead_sales_count,
    coalesce(sales.lead_sales_value, 0)        as lead_sales_value,
    coalesce(sales.walk_in_sales_count, 0)     as walk_in_sales_count,
    coalesce(sales.walk_in_sales_value, 0)     as walk_in_sales_value,
    coalesce(lost.leads_lost, 0)               as leads_lost
from spine sp
left join leads  using (branch_id, d)
left join acts   using (branch_id, d)
left join fus    using (branch_id, d)
left join visits using (branch_id, d)
left join quotes using (branch_id, d)
left join sales  using (branch_id, d)
left join lost   using (branch_id, d);

-- -----------------------------------------------------------------------------
-- Branch funnel by lead-creation month (cohort)
-- -----------------------------------------------------------------------------
create view crm.v_branch_funnel_monthly with (security_invoker = true) as
select
    date_trunc('month', created_on)::date as month,
    branch_id,
    count(*)                                                      as leads,
    count(*) filter (where excluded_from_conversion)              as junk_leads,
    count(*) filter (where not excluded_from_conversion)          as qualified_leads,
    count(*) filter (where first_contact_at is not null)          as contacted,
    count(*) filter (where has_visit)                             as visited,
    count(*) filter (where has_quotation)                         as quoted,
    count(*) filter (where is_won)                                as won,
    count(*) filter (where is_lost)                               as lost,
    count(*) filter (where not is_closed)                         as still_open,
    crm.pct(count(*) filter (where is_won),
            count(*) filter (where not excluded_from_conversion)) as conversion_pct,
    sum(won_value)                                                as won_value,
    percentile_cont(0.5) within group (order by first_contact_hours)
        filter (where first_contact_hours is not null)            as median_first_contact_hours
from crm.v_lead_status
group by 1, 2;

-- -----------------------------------------------------------------------------
-- Lead source and campaign performance (06_MARKETING)
-- -----------------------------------------------------------------------------
create view crm.v_source_performance_monthly with (security_invoker = true) as
select
    date_trunc('month', ls.created_on)::date as month,
    ls.branch_id, ls.source_code, src.is_paid,
    count(*)                                             as leads,
    count(*) filter (where not ls.excluded_from_conversion) as qualified_leads,
    count(*) filter (where ls.is_won)                    as won,
    crm.pct(count(*) filter (where ls.is_won),
            count(*) filter (where not ls.excluded_from_conversion)) as conversion_pct,
    sum(ls.won_value)                                    as won_value
from crm.v_lead_status ls
join crm.lead_source src on src.source_code = ls.source_code
group by 1, 2, 3, 4;

create view crm.v_campaign_performance with (security_invoker = true) as
select
    c.campaign_id, c.campaign_code, c.campaign_name, c.source_code, c.branch_id,
    c.start_date, c.end_date, c.budget, c.actual_spend,
    count(ls.lead_id)                                                  as leads,
    count(ls.lead_id) filter (where not ls.excluded_from_conversion)   as qualified_leads,
    count(ls.lead_id) filter (where ls.first_contact_at is not null)   as contacted,
    count(ls.lead_id) filter (where ls.is_won)                         as won,
    crm.pct(count(ls.lead_id) filter (where ls.is_won),
            count(ls.lead_id) filter (where not ls.excluded_from_conversion)) as conversion_pct,
    coalesce(sum(ls.won_value), 0)                                     as won_value,
    round(c.actual_spend / nullif(count(ls.lead_id) filter (where not ls.excluded_from_conversion), 0), 2)
                                                                       as cost_per_qualified_lead,
    round(c.actual_spend / nullif(count(ls.lead_id) filter (where ls.is_won), 0), 2)
                                                                       as cost_per_won_lead,
    round(coalesce(sum(ls.won_value), 0) / nullif(c.actual_spend, 0), 2) as revenue_per_rupee_spent
from crm.campaign c
left join crm.v_lead_status ls on ls.campaign_id = c.campaign_id
group by c.campaign_id;

-- -----------------------------------------------------------------------------
-- Staff performance by month (outcomes first, activity as context)
-- -----------------------------------------------------------------------------
create view crm.v_staff_performance_monthly with (security_invoker = true) as
with facts as (
    select assigned_to as employee_id, date_trunc('month', created_on)::date as month,
           1 as leads_assigned,
           (not excluded_from_conversion)::int as qualified_leads,
           is_won::int as cohort_won,
           0 as leads_won, 0::numeric as won_value, 0 as sales_count, 0::numeric as sales_value,
           0 as activities_completed, 0 as leads_reached,
           0 as followups_due, 0 as followups_on_time, 0 as followups_overdue, 0 as visits_attended
    from crm.v_lead_status where assigned_to is not null
    union all
    select assigned_to, date_trunc('month', first_sale_on)::date,
           0, 0, 0, 1, won_value, 0, 0, 0, 0, 0, 0, 0, 0
    from crm.v_lead_status where is_won and assigned_to is not null
    union all
    select sold_by, date_trunc('month', invoice_date)::date,
           0, 0, 0, 0, 0, 1, net_value, 0, 0, 0, 0, 0, 0
    from crm.sale where sold_by is not null
    union all
    select a.employee_id, date_trunc('month', crm.local_date(a.completed_at))::date,
           0, 0, 0, 0, 0, 0, 0, 1, o.customer_reached::int, 0, 0, 0, 0
    from crm.lead_activity a join crm.activity_outcome o on o.code = a.outcome
    where a.completed_at is not null
    union all
    select employee_id, date_trunc('month', due_on)::date,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
           (followup_status = 'ON_TIME')::int, (followup_status = 'OVERDUE')::int, 0
    from crm.v_followup_status
    union all
    select attended_by, date_trunc('month', crm.local_date(visit_at))::date,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    from crm.store_visit where attended_by is not null
),
agg as (
    select employee_id, month,
           sum(leads_assigned) as leads_assigned, sum(qualified_leads) as qualified_leads,
           sum(cohort_won) as cohort_won, sum(leads_won) as leads_won, sum(won_value) as won_value,
           sum(sales_count) as sales_count, sum(sales_value) as sales_value,
           sum(activities_completed) as activities_completed, sum(leads_reached) as leads_reached,
           sum(followups_due) as followups_due, sum(followups_on_time) as followups_on_time,
           sum(followups_overdue) as followups_overdue, sum(visits_attended) as visits_attended
    from facts group by 1, 2
),
targets as (
    select employee_id, period_start as month,
           max(target_value) filter (where target_type = 'SALES_VALUE')  as target_sales_value,
           max(target_value) filter (where target_type = 'SALES_COUNT')  as target_sales_count,
           max(target_value) filter (where target_type = 'LEADS_WON')    as target_leads_won,
           max(target_value) filter (where target_type = 'STORE_VISITS') as target_store_visits
    from crm.staff_target where period_type = 'MONTH' group by 1, 2
)
select
    a.month, a.employee_id, e.employee_name, e.branch_id,
    a.leads_assigned, a.qualified_leads, a.cohort_won,
    crm.pct(a.cohort_won, a.qualified_leads) as lead_conversion_pct,
    a.leads_won, a.won_value, a.sales_count, a.sales_value,
    t.target_sales_value, crm.pct(a.sales_value, t.target_sales_value) as sales_value_achievement_pct,
    t.target_sales_count, t.target_leads_won, t.target_store_visits,
    a.visits_attended,
    a.followups_due, a.followups_on_time, a.followups_overdue,
    crm.pct(a.followups_on_time, a.followups_due) as followup_on_time_pct,
    a.activities_completed, a.leads_reached
from agg a
join crm.employee e on e.employee_id = a.employee_id
left join targets t on t.employee_id = a.employee_id and t.month = a.month;

-- -----------------------------------------------------------------------------
-- Open pipeline ageing and leakage
-- -----------------------------------------------------------------------------
create view crm.v_open_lead_ageing with (security_invoker = true) as
select
    branch_id, assigned_to,
    case when age_days <= 2  then '0-2 days'
         when age_days <= 7  then '3-7 days'
         when age_days <= 15 then '8-15 days'
         when age_days <= 30 then '16-30 days'
         else '30+ days' end                                  as age_bucket,
    count(*)                                                  as open_leads,
    coalesce(sum(budget_value), 0)                            as stated_budget_value,
    count(*) filter (where attention_reason = 'NOT_CONTACTED_WITHIN_SLA') as not_contacted_within_sla,
    count(*) filter (where attention_reason = 'FOLLOWUP_OVERDUE')         as followup_overdue,
    count(*) filter (where attention_reason = 'NO_NEXT_FOLLOWUP')         as no_next_followup,
    count(*) filter (where attention_reason = 'STALE')                    as stale
from crm.v_lead_status
where not is_closed
group by 1, 2, 3;

-- -----------------------------------------------------------------------------
-- Data quality (never hidden: surfaced in every MIS)
-- -----------------------------------------------------------------------------
create view crm.v_data_quality_issues with (security_invoker = true) as
select 'CUSTOMER_NAME_MISSING' as issue_code, 'LOW' as severity, 'customer' as entity,
       c.customer_id::text as entity_id, c.home_branch_id as branch_id, c.mobile as detail
from crm.customer c where c.customer_name is null
union all
select 'OPEN_LEAD_UNASSIGNED', 'HIGH', 'lead', l.lead_id::text, l.branch_id, l.stage_code
from crm.v_lead_status l where not l.is_closed and l.assigned_to is null
union all
select 'OPEN_LEAD_OWNER_EXITED', 'HIGH', 'lead', l.lead_id::text, l.branch_id, e.employee_id
from crm.v_lead_status l join crm.employee e on e.employee_id = l.assigned_to
where not l.is_closed and e.exit_date <= current_date
union all
select 'LEAD_NO_PRODUCT_CATEGORY', 'LOW', 'lead', l.lead_id::text, l.branch_id, null
from crm.lead l where l.product_category is null
union all
select 'PAID_SOURCE_LEAD_NO_CAMPAIGN', 'MEDIUM', 'lead', l.lead_id::text, l.branch_id, l.source_code
from crm.lead l join crm.lead_source s on s.source_code = l.source_code
where s.is_paid and l.campaign_id is null
union all
select 'LEAD_SOURCE_DIFFERS_FROM_CAMPAIGN', 'MEDIUM', 'lead', l.lead_id::text, l.branch_id,
       l.source_code || ' vs ' || c.source_code
from crm.lead l join crm.campaign c on c.campaign_id = l.campaign_id
where l.source_code <> c.source_code
union all
select 'DUPLICATE_OPEN_LEAD', 'MEDIUM', 'lead', l.lead_id::text, l.branch_id,
       'customer ' || l.customer_id || ', ' || coalesce(l.product_category, 'no category')
from (select ls.*, count(*) over (partition by customer_id, branch_id, product_category) as n
      from crm.v_lead_status ls where not ls.is_closed) l
where l.n > 1
union all
select 'SALE_NO_CUSTOMER', 'MEDIUM', 'sale', s.sale_id::text, s.branch_id, s.invoice_no
from crm.sale s where s.customer_id is null
union all
select 'SALE_NO_SALESPERSON', 'MEDIUM', 'sale', s.sale_id::text, s.branch_id, s.invoice_no
from crm.sale s where s.sold_by is null
union all
select 'SALE_ITEMS_TOTAL_MISMATCH', 'HIGH', 'sale', s.sale_id::text, s.branch_id,
       s.net_value || ' vs items ' || i.items_value
from crm.sale s
join (select sale_id, sum(line_value) as items_value from crm.sale_item group by 1) i using (sale_id)
where i.items_value <> s.net_value
union all
select 'QUOTATION_EXPIRED_STILL_OPEN', 'LOW', 'quotation', q.quotation_id::text, q.branch_id, q.quotation_no
from crm.quotation q where q.status = 'OPEN' and q.valid_until < current_date
union all
select 'ACTIVITY_BEFORE_LEAD_CREATED', 'MEDIUM', 'lead_activity', a.activity_id::text, l.branch_id, null
from crm.lead_activity a join crm.lead l on l.lead_id = a.lead_id
where a.completed_at < l.created_at
union all
select 'EMPLOYEE_NO_REPORTING_MANAGER', 'LOW', 'employee', e.employee_id, e.branch_id, e.employee_name
from crm.employee e join crm.access_level a on a.code = e.crm_access_level
where e.reporting_manager_id is null and a.data_scope <> 'ALL'
  and (e.exit_date is null or e.exit_date > current_date)
union all
select 'ENDED_CAMPAIGN_NO_SPEND', 'MEDIUM', 'campaign', c.campaign_id::text, c.branch_id, c.campaign_name
from crm.campaign c where c.end_date < current_date and c.actual_spend is null;

-- -----------------------------------------------------------------------------
-- Setup gaps: configuration still running on placeholder values
-- -----------------------------------------------------------------------------
create view crm.v_setup_gaps with (security_invoker = true) as
select 'lookup_value' as config_table, category as item, count(*) as placeholder_count,
       string_agg(code, ', ' order by sort_order, code) as codes
from crm.lookup_value where is_placeholder group by category
union all
select 'access_level', 'CRM_ACCESS_LEVEL', count(*), string_agg(code, ', ' order by sort_order)
from crm.access_level where is_placeholder having count(*) > 0
union all
select 'lead_stage', 'LEAD_STAGE', count(*), string_agg(code, ', ' order by stage_order)
from crm.lead_stage where is_placeholder having count(*) > 0
union all
select 'lead_source', 'LEAD_SOURCE', count(*), string_agg(source_code, ', ' order by source_code)
from crm.lead_source where is_placeholder having count(*) > 0
union all
select 'activity_outcome', 'ACTIVITY_OUTCOME', count(*), string_agg(code, ', ' order by code)
from crm.activity_outcome where is_placeholder having count(*) > 0
union all
select 'setting', key, 1, value::text || ' ' || unit
from crm.setting where is_placeholder;

grant select on all tables in schema crm to crm_app;
grant execute on all functions in schema crm to crm_app;
