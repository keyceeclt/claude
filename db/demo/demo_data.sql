-- =============================================================================
-- DEMO DATA: fictional staff, customers, leads and sales for trying the app.
-- Every name starts with "Demo" and every Employee ID with "DEMO-".
-- Never load this into the production database.
-- =============================================================================
select setseed(0.42);

insert into crm.employee (employee_id, employee_name, branch_id, designation, department, status, crm_access_level, reporting_manager_id, login_email) values
    ('DEMO-HO1', 'Demo HO Admin',            null, 'CRM_EXECUTIVE',   'MANAGEMENT',  'ACTIVE', 'HO_ADMIN',       null,       'admin@demo.kc'),
    ('DEMO-HO2', 'Demo Management Viewer',   null, null,              'MANAGEMENT',  'ACTIVE', 'HO_VIEWER',      'DEMO-HO1', 'viewer@demo.kc'),
    ('DEMO-M1',  'Demo Manager HiLITE',      1,    'BRANCH_MANAGER',  'SALES',       'ACTIVE', 'BRANCH_MANAGER', 'DEMO-HO1', 'manager.hilite@demo.kc'),
    ('DEMO-M2',  'Demo Manager Mobile Plaza',2,    'BRANCH_MANAGER',  'SALES',       'ACTIVE', 'BRANCH_MANAGER', 'DEMO-HO1', 'manager.plaza@demo.kc'),
    ('DEMO-M3',  'Demo Manager Appas',       3,    'BRANCH_MANAGER',  'SALES',       'ACTIVE', 'BRANCH_MANAGER', 'DEMO-HO1', 'manager.appas@demo.kc'),
    ('DEMO-S11', 'Demo Staff Anu',           1,    'SALES_EXECUTIVE', 'SALES',       'ACTIVE', 'STAFF', 'DEMO-M1', 'anu@demo.kc'),
    ('DEMO-S12', 'Demo Staff Rahul',         1,    'TELECALLER',      'TELECALLING', 'ACTIVE', 'STAFF', 'DEMO-M1', 'rahul@demo.kc'),
    ('DEMO-S21', 'Demo Staff Fathima',       2,    'SALES_EXECUTIVE', 'SALES',       'ACTIVE', 'STAFF', 'DEMO-M2', 'fathima@demo.kc'),
    ('DEMO-S22', 'Demo Staff Vishnu',        2,    'TELECALLER',      'TELECALLING', 'ACTIVE', 'STAFF', 'DEMO-M2', 'vishnu@demo.kc'),
    ('DEMO-S31', 'Demo Staff Joseph',        3,    'SALES_EXECUTIVE', 'SALES',       'ACTIVE', 'STAFF', 'DEMO-M3', 'joseph@demo.kc');

insert into crm.campaign (campaign_code, campaign_name, source_code, branch_id, start_date, end_date, budget, actual_spend) values
    ('DEMO-FB-ONAM', 'Demo Onam social ads',    'SOCIAL_ADS', null, current_date - 50, current_date - 20, 60000, 58000),
    ('DEMO-GG-TV',   'Demo Google TV search',   'GOOGLE_ADS', 1,    current_date - 40, null,              30000, 21000),
    ('DEMO-EXPO',    'Demo Bathery expo stall', 'EVENT',      3,    current_date - 25, current_date - 23, 15000, 15000);

-- 360 customers with fictional numbers 90000 00001...
insert into crm.customer (customer_name, mobile, area, home_branch_id, created_by, created_at)
select 'Demo Customer ' || g,
       '90000' || lpad(g::text, 5, '0'),
       (array['Mavoor Rd','Nadakkavu','Kallai','Feroke','Kunnamangalam','Bathery','Meenangadi','Ambalavayal'])[1 + (g % 8)],
       1 + (g % 3), null, now() - interval '60 days'
from generate_series(1, 360) g;

-- One lead per customer over the last 60 days.
insert into crm.lead (customer_id, branch_id, assigned_to, source_code, campaign_id, product_category, product_interest,
                      budget_value, created_by, created_at)
select c.customer_id, c.home_branch_id,
       case c.home_branch_id when 1 then (array['DEMO-S11','DEMO-S12'])[1 + (c.customer_id % 2)]
                             when 2 then (array['DEMO-S21','DEMO-S22'])[1 + (c.customer_id % 2)]
                             else 'DEMO-S31' end,
       src.source_code, src.campaign_id,
       (array['MOBILE','MOBILE','MOBILE','TV','APPLIANCE','TABLET','WEARABLE','LAPTOP'])[1 + floor(random() * 8)::int],
       null,
       (array[15000, 25000, 40000, 60000, 90000])[1 + floor(random() * 5)::int],
       'DEMO-M' || c.home_branch_id,
       now() - (floor(random() * 58) || ' days')::interval - (floor(random() * 9) || ' hours')::interval
from crm.customer c
cross join lateral (
    select s.source_code,
           (select campaign_id from crm.campaign k where k.source_code = s.source_code
              and (k.branch_id is null or k.branch_id = c.home_branch_id) order by random() limit 1) as campaign_id
    from crm.lead_source s where c.customer_id > 0 order by random() limit 1) src
where c.mobile like '90000%';

-- First call for most leads: completed some hours after creation.
insert into crm.lead_activity (lead_id, employee_id, activity_type, completed_at, outcome, notes)
select l.lead_id, l.assigned_to, 'CALL',
       least(now(), l.created_at + ((1 + floor(random() * 30)) || ' hours')::interval),
       (array['CONNECTED_INTERESTED','CONNECTED_INTERESTED','CONNECTED_CALLBACK','CONNECTED_NOT_INTERESTED','NO_ANSWER','SWITCHED_OFF','WRONG_NUMBER'])[1 + floor(random() * 7)::int],
       'Demo call'
from crm.lead l where l.assigned_to like 'DEMO-%' and random() < 0.88;

-- Next follow-ups: some done (on time or late), some still pending or overdue.
insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, completed_at, outcome)
select l.lead_id, l.assigned_to, 'CALL', d.due, d.done, case when d.done is not null then 'CONNECTED_CALLBACK' end
from crm.lead l
cross join lateral (select l.created_at + ((2 + floor(random() * 6)) || ' days')::interval as due) d0
cross join lateral (
    select d0.due,
           case when d0.due < now() and random() < 0.7
                then least(now(), d0.due + ((floor(random() * 40)) || ' hours')::interval) end as done) d
where l.assigned_to like 'DEMO-%' and random() < 0.8;

-- Stages for leads that were reached.
update crm.lead set stage_code = 'INVALID'
where lead_id in (select lead_id from crm.lead_activity where outcome = 'WRONG_NUMBER');
update crm.lead set stage_code = (array['CONTACTED','INTERESTED','VISIT_SCHEDULED'])[1 + floor(random() * 3)::int]
where stage_code = 'NEW' and first_contact_at is not null;

-- Store visits and quotations for a share of interested leads.
insert into crm.store_visit (customer_id, lead_id, branch_id, visit_at, attended_by)
select l.customer_id, l.lead_id, l.branch_id, least(now(), l.created_at + ((1 + floor(random() * 7)) || ' days')::interval), l.assigned_to
from crm.lead l where l.stage_code in ('INTERESTED', 'VISIT_SCHEDULED') and random() < 0.65;
update crm.lead set stage_code = 'VISITED' where lead_id in (select lead_id from crm.store_visit where lead_id is not null);

insert into crm.quotation (quotation_no, customer_id, lead_id, branch_id, prepared_by, quoted_on, valid_until, total_value)
select 'DQ-' || l.lead_id, l.customer_id, l.lead_id, l.branch_id, l.assigned_to,
       crm.local_date(v.visit_at), crm.local_date(v.visit_at) + 7, l.budget_value
from crm.lead l join crm.store_visit v on v.lead_id = l.lead_id
where random() < 0.5;
update crm.lead set stage_code = 'QUOTED' where lead_id in (select lead_id from crm.quotation);

-- Sales for about half of the visited leads (marks them Won automatically).
insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, sold_by, net_value)
select 'DINV-' || l.lead_id, l.branch_id,
       least(current_date, crm.local_date(v.visit_at) + floor(random() * 4)::int),
       l.customer_id, l.lead_id, l.assigned_to, round(l.budget_value * (0.85 + random() * 0.3))
from crm.lead l join crm.store_visit v on v.lead_id = l.lead_id
where random() < 0.55;

-- Some losses with reasons.
update crm.lead set stage_code = 'LOST',
       lost_reason = (array['PRICE','BOUGHT_ELSEWHERE','STOCK_UNAVAILABLE','PLAN_DROPPED'])[1 + floor(random() * 4)::int]
where stage_code in ('CONTACTED', 'QUOTED') and random() < 0.3;

-- Walk-in counter sales without a lead.
insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, sold_by, net_value)
select 'DWALK-' || g, 1 + (g % 3), current_date - floor(random() * 58)::int, null, null,
       (array['DEMO-S11','DEMO-S21','DEMO-S31'])[1 + (g % 3)], (array[1999, 4999, 12999, 18999, 32999])[1 + floor(random() * 5)::int]
from generate_series(1, 150) g;

-- Monthly sales targets for staff.
insert into crm.staff_target (employee_id, period_type, period_start, period_end, target_type, target_value)
select e.employee_id, 'MONTH', date_trunc('month', current_date)::date,
       (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'SALES_VALUE', 600000
from crm.employee e where e.employee_id like 'DEMO-S%';
