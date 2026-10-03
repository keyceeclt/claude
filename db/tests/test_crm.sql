-- =============================================================================
-- Test suite: business rules, KPI calculations, branch security.
-- Uses TEST fixtures only (names like "Test Staff"); not business data.
-- Any failed assertion raises and stops scripts/test.sh.
-- =============================================================================

create schema crm_test;
grant usage on schema crm_test to crm_app;

create function crm_test.eq(actual anyelement, expected anyelement, what text)
returns void language plpgsql as $$
begin
    if actual is distinct from expected then
        raise exception 'FAIL %: expected %, got %', what, expected, actual;
    end if;
    raise notice 'ok   %', what;
end $$;

create function crm_test.raises(stmt text, what text)
returns void language plpgsql as $$
begin
    begin
        execute stmt;
    exception when others then
        raise notice 'ok   % (rejected: %)', what, sqlerrm;
        return;
    end;
    raise exception 'FAIL %: statement was accepted', what;
end $$;

-- Rows a statement changed (row-level security hides rows rather than raising).
create function crm_test.affected(stmt text)
returns bigint language plpgsql as $$
declare n bigint;
begin
    execute stmt;
    get diagnostics n = row_count;
    return n;
end $$;

grant execute on all functions in schema crm_test to crm_app;
set client_min_messages = notice;

-- Everything below acts for the first company (Key Cee) unless it says otherwise.
select set_config('app.tenant_id', tenant_id::text, false) from crm.tenant where code = 'KEYCEE';

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into crm.employee (employee_id, employee_name, branch_id, status, crm_access_level, reporting_manager_id, exit_date) values
    ('T-HO',  'Test HO Admin',         null, 'ACTIVE', 'HO_ADMIN',       null,   null),
    ('T-HOV', 'Test HO Viewer',        null, 'ACTIVE', 'HO_VIEWER',      'T-HO', null),
    ('T-BM1', 'Test Manager HiLITE',   1,    'ACTIVE', 'BRANCH_MANAGER', 'T-HO', null),
    ('T-S1',  'Test Staff HiLITE 1',   1,    'ACTIVE', 'STAFF',          'T-BM1', null),
    ('T-S2',  'Test Staff HiLITE 2',   1,    'ACTIVE', 'STAFF',          'T-BM1', null),
    ('T-BM3', 'Test Manager Appas',    3,    'ACTIVE', 'BRANCH_MANAGER', 'T-HO', null),
    ('T-S3',  'Test Staff Appas',      3,    'ACTIVE', 'STAFF',          'T-BM3', null),
    ('T-OLD', 'Test Exited Staff',     1,    'EXITED', 'STAFF',          'T-BM1', crm.local_date(now()) - 1);

insert into crm.customer (customer_name, mobile, home_branch_id, created_by) values
    ('Test Customer A', '+91 98470 00001', 1, 'T-S1'),
    ('Test Customer B', '09847000002',     1, 'T-S2'),
    ('Test Customer C', '9847000003',      3, 'T-S3'),
    (null,              '9847000004',      1, 'T-S1');

insert into crm.campaign (campaign_code, campaign_name, source_code, branch_id, start_date, end_date, actual_spend)
values ('T-CAMP', 'Test social campaign', 'SOCIAL_ADS', 1, crm.local_date(now()) - 30, crm.local_date(now()) + 30, 10000);

insert into crm.lead (customer_id, branch_id, assigned_to, source_code, campaign_id, product_category, created_by, created_at)
values
    (1, 1, 'T-S1', 'SOCIAL_ADS', 1, 'MOBILE', 'T-S1', now() - interval '3 days'),   -- lead 1: will be won
    (2, 1, 'T-S2', 'SOCIAL_ADS', 1, 'TV',     'T-S2', now() - interval '3 days'),   -- lead 2: overdue follow-up
    (3, 3, 'T-S3', 'WALK_IN',    null, 'MOBILE', 'T-S3', now() - interval '1 day'), -- lead 3: Appas
    (4, 1, 'T-S1', 'SOCIAL_ADS', 1, 'MOBILE', 'T-S1', now() - interval '3 days'),   -- lead 4: junk
    (1, 1, 'T-OLD', 'PHONE_INQUIRY', null, null, 'T-OLD', now() - interval '10 days'); -- lead 5: orphaned

-- -----------------------------------------------------------------------------
-- Data entry rules
-- -----------------------------------------------------------------------------
select crm_test.eq((select mobile from crm.customer where customer_id = 1), '9847000001', 'mobile +91 normalised');
select crm_test.eq((select mobile from crm.customer where customer_id = 2), '9847000002', 'mobile leading 0 normalised');
select crm_test.raises($$insert into crm.customer (mobile) values ('98470 00001')$$, 'duplicate mobile rejected');
select crm_test.raises($$insert into crm.customer (mobile) values ('12345')$$, 'invalid mobile rejected');
select crm_test.raises($$insert into crm.employee (employee_id, employee_name, status, crm_access_level)
                         values ('X', 'X', 'NOT_A_STATUS', 'STAFF')$$, 'unknown status rejected');
select crm_test.eq((select stage_code from crm.lead where lead_id = 1), 'NEW', 'new lead defaults to first stage');

-- -----------------------------------------------------------------------------
-- Lead stage rules
-- -----------------------------------------------------------------------------
select crm_test.raises($$update crm.lead set stage_code = 'WON' where lead_id = 1$$, 'cannot mark won without a sale');
select crm_test.raises($$update crm.lead set stage_code = 'LOST' where lead_id = 2$$, 'lost needs a reason');
update crm.lead set stage_code = 'INVALID' where lead_id = 4;

-- Activities: first contact and follow-ups.
insert into crm.lead_activity (lead_id, employee_id, activity_type, completed_at, outcome) values
    (1, 'T-S1', 'CALL', now() - interval '3 days' + interval '1 hour', 'CONNECTED_INTERESTED'),
    (2, 'T-S2', 'CALL', now() - interval '3 days' + interval '1 hour', 'CONNECTED_CALLBACK'),
    (3, 'T-S3', 'CALL', now() - interval '1 day' + interval '1 hour', 'NO_ANSWER');
insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at) values
    (2, 'T-S2', 'CALL', now() - interval '2 days'),    -- overdue
    (3, 'T-S3', 'CALL', now() + interval '1 day');     -- pending

select crm_test.eq((select first_contact_hours from crm.v_lead_status where lead_id = 1), 1.0, 'first contact time measured');
select crm_test.eq((select first_contact_at from crm.lead where lead_id = 3), null::timestamptz, 'no-answer call is not a contact');
select crm_test.eq((select attention_reason from crm.v_lead_status where lead_id = 2), 'FOLLOWUP_OVERDUE', 'overdue follow-up flagged');
select crm_test.eq((select attention_reason from crm.v_lead_status where lead_id = 1), 'NO_NEXT_FOLLOWUP', 'open lead without next step flagged');
select crm_test.eq((select attention_reason from crm.v_lead_status where lead_id = 3), 'NOT_CONTACTED_WITHIN_SLA', 'uncontacted lead past SLA flagged');

-- Visits, quotations, sales.
select crm_test.raises($$insert into crm.store_visit (customer_id, lead_id, branch_id, visit_at) values (2, 1, 1, now())$$,
                       'visit customer must match lead');
insert into crm.store_visit (customer_id, lead_id, branch_id, visit_at, attended_by) values (1, 1, 1, now() - interval '1 day', 'T-S1');
insert into crm.quotation (quotation_no, customer_id, lead_id, branch_id, prepared_by, quoted_on, valid_until, total_value)
values ('Q1', 1, 1, 1, 'T-S1', crm.local_date(now()) - 1, crm.local_date(now()) + 6, 52000);

select crm_test.raises($$insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, net_value)
                         values ('BAD', 1, crm.local_date(now()), 2, 1, 100)$$, 'sale customer must match lead');
insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, quotation_id, sold_by, net_value)
values ('INV-1', 1, crm.local_date(now()), 1, 1, 1, 'T-S1', 50000);
insert into crm.sale_item (sale_id, line_no, product_category, quantity, line_value) values ((select sale_id from crm.sale where invoice_no = 'INV-1'), 1, 'MOBILE', 1, 50000);
insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, sold_by, net_value)
values ('INV-2', 1, crm.local_date(now()), null, null, 'T-S2', 20000);                   -- walk-in counter sale

select crm_test.eq((select stage_code from crm.lead where lead_id = 1), 'WON', 'linked sale marks lead won');
select crm_test.eq((select count(*) from crm.lead_stage_history where lead_id = 1), 2::bigint, 'stage history kept (NEW, WON)');

-- -----------------------------------------------------------------------------
-- KPI recalculation
-- -----------------------------------------------------------------------------
-- HiLITE cohort: leads 1, 2, 4 (junk), 5 -> qualified 3, won 1.
select crm_test.eq((select sum(qualified_leads) from crm.v_branch_funnel_monthly where branch_id = 1), 3::numeric, 'junk leads excluded from qualified');
select crm_test.eq((select sum(won) from crm.v_branch_funnel_monthly where branch_id = 1), 1::numeric, 'won leads counted');

select crm_test.eq((select leads from crm.v_campaign_performance where campaign_code = 'T-CAMP'), 3::bigint, 'campaign leads');
select crm_test.eq((select qualified_leads from crm.v_campaign_performance where campaign_code = 'T-CAMP'), 2::bigint, 'campaign qualified leads');
select crm_test.eq((select won_value from crm.v_campaign_performance where campaign_code = 'T-CAMP'), 50000::numeric, 'campaign revenue = linked sales only');
select crm_test.eq((select cost_per_won_lead from crm.v_campaign_performance where campaign_code = 'T-CAMP'), 10000.00::numeric, 'cost per won lead');
select crm_test.eq((select revenue_per_rupee_spent from crm.v_campaign_performance where campaign_code = 'T-CAMP'), 5.00::numeric, 'revenue per rupee spent');

select crm_test.eq((select sales_value from crm.v_daily_mis where branch_id = 1 and mis_date = crm.local_date(now())), 70000::numeric, 'daily MIS total sales');
select crm_test.eq((select walk_in_sales_value from crm.v_daily_mis where branch_id = 1 and mis_date = crm.local_date(now())), 20000::numeric, 'daily MIS walk-in sales separated');
select crm_test.eq((select lead_sales_value from crm.v_daily_mis where branch_id = 1 and mis_date = crm.local_date(now())), 50000::numeric, 'daily MIS lead sales');

insert into crm.staff_target (employee_id, period_type, period_start, period_end, target_type, target_value)
values ('T-S1', 'MONTH', date_trunc('month', crm.local_date(now()))::date,
        (date_trunc('month', crm.local_date(now())) + interval '1 month - 1 day')::date, 'SALES_VALUE', 200000);
select crm_test.eq((select sales_value_achievement_pct from crm.v_staff_performance_monthly
                    where employee_id = 'T-S1' and month = date_trunc('month', crm.local_date(now()))::date), 25.0, 'staff target achievement');

select crm_test.eq((select count(*) from crm.v_data_quality_issues where issue_code = 'OPEN_LEAD_OWNER_EXITED'), 1::bigint, 'DQ: lead owned by exited staff');
select crm_test.eq((select count(*) from crm.v_data_quality_issues where issue_code = 'CUSTOMER_NAME_MISSING'), 1::bigint, 'DQ: customer name missing');
select crm_test.eq((select count(*) from crm.v_data_quality_issues where issue_code = 'SALE_NO_CUSTOMER'), 1::bigint, 'DQ: sale without customer');
select crm_test.eq((select count(*) > 0 from crm.v_setup_gaps where item = 'LEAD_STAGE'), true, 'setup gaps list placeholder stages');

-- -----------------------------------------------------------------------------
-- Branch security (row level security as the app role)
-- -----------------------------------------------------------------------------
set role crm_app;

set app.employee_id = 'T-HO';
select crm_test.eq((select count(*) from crm.lead), 5::bigint, 'HO sees all leads');

set app.employee_id = 'T-BM1';
select crm_test.eq((select count(*) from crm.lead), 4::bigint, 'HiLITE manager sees HiLITE leads only');
select crm_test.eq((select count(distinct branch_id) from crm.v_daily_mis where sales_count > 0 or new_leads > 0), 1::bigint, 'manager MIS limited to own branch');
select crm_test.eq((select count(*) from crm.employee), 4::bigint, 'manager sees own branch staff');

set app.employee_id = 'T-BM3';
select crm_test.eq((select count(*) from crm.lead), 1::bigint, 'Appas manager sees Appas leads only');
select crm_test.eq((select count(*) from crm.sale), 0::bigint, 'Appas manager cannot see HiLITE sales');

set app.employee_id = 'T-S1';
select crm_test.eq((select count(*) from crm.lead), 2::bigint, 'staff sees only own leads');
select crm_test.eq((select count(*) from crm.customer where customer_id = 2), 0::bigint, 'staff cannot see colleague''s customer');
select crm_test.eq((select count(*) from crm.find_customer_by_mobile('9847000002')), 1::bigint, 'staff can find existing customer by mobile');
select crm_test.raises($$insert into crm.lead (customer_id, branch_id, assigned_to, source_code) values (1, 3, 'T-S1', 'WALK_IN')$$,
                       'staff cannot create lead in another branch');
select crm_test.raises($$insert into crm.lead_stage (code, label, stage_order) values ('X', 'X', 99)$$,
                       'staff cannot change configuration');
insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at) values (1, 'T-S1', 'CALL', now() + interval '1 day');
select crm_test.eq((select count(*) from crm.lead_activity where lead_id = 1), 2::bigint, 'staff can log follow-up on own lead');

set app.employee_id = 'T-HOV';
select crm_test.raises($$insert into crm.customer (mobile) values ('9847000099')$$, 'read-only HO viewer cannot write');

set app.employee_id = 'T-OLD';
select crm_test.eq((select count(*) from crm.lead), 0::bigint, 'exited staff sees nothing');

reset app.employee_id;
select crm_test.eq((select count(*) from crm.lead), 0::bigint, 'unknown user sees nothing');

-- -----------------------------------------------------------------------------
-- AI agents: suggest, never decide
-- -----------------------------------------------------------------------------
set app.employee_id = 'AI-AGENT';
select crm_test.eq((select count(*) from crm.lead), 5::bigint, 'agent reads all leads of its company');
select crm_test.eq(crm_test.affected($$update crm.lead set stage_code = 'LOST', lost_reason = 'PRICE' where lead_id = 2$$),
                   0::bigint, 'agent cannot change a lead');
select crm_test.raises($$insert into crm.customer (mobile) values ('9847000055')$$, 'agent cannot create customers');
select crm_test.raises($$insert into crm.sale (invoice_no, branch_id, invoice_date, net_value) values ('AI-1', 1, now()::date, 1)$$,
                       'agent cannot record sales');
insert into crm.agent_run (agent, branch_id, status) values ('LEAD_RESCUE', 1, 'RUNNING');
insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes, origin, agent_run_id)
values (2, 'T-S2', 'CALL', now() + interval '2 hours', 'Agent: customer asked for a call back', 'AGENT', 1);
insert into crm.agent_suggestion (run_id, kind, lead_id, branch_id, assigned_to, activity_type, suggested_due_at, reason, status, activity_id)
values (1, 'FOLLOWUP', 2, 1, 'T-S2', 'CALL', now() + interval '2 hours', 'Follow-up overdue by 2 days', 'APPLIED',
        (select max(activity_id) from crm.lead_activity where origin = 'AGENT'));
insert into crm.agent_suggestion (run_id, kind, lead_id, branch_id, assigned_to, activity_type, suggested_due_at, reason)
values (1, 'FOLLOWUP', 1, 1, 'T-S1', 'WHATSAPP', now() + interval '1 day', 'No next follow-up after quotation');
update crm.agent_run set status = 'DONE', cost_usd = 0.25, items = 2, finished_at = now() where run_id = 1;
select crm_test.raises($$insert into crm.lead_activity (lead_id, employee_id, activity_type, completed_at, outcome, origin, agent_run_id)
                         values (2, 'T-S2', 'CALL', now(), 'CONNECTED_INTERESTED', 'AGENT', 1)$$, 'agent cannot log a completed contact');
select crm_test.raises($$insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at)
                         values (2, 'T-S2', 'CALL', now())$$, 'agent work is always marked as the agent''s');
select crm_test.eq(crm.ai_spend_this_month(), 0.25::numeric, 'AI spend this month');

set app.employee_id = 'T-S1';
select crm_test.raises($$insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, origin, agent_run_id)
                         values (1, 'T-S1', 'CALL', now(), 'AGENT', 1)$$, 'staff cannot pass work off as the agent''s');
select crm_test.eq((select count(*) from crm.agent_suggestion), 1::bigint, 'staff sees only suggestions for them');
select crm_test.raises($$select crm.undo_agent_followup(1)$$, 'staff cannot undo a colleague''s agent follow-up');
select crm_test.eq(crm_test.affected($$delete from crm.lead_activity where lead_id = 1$$), 0::bigint,
                   'staff cannot delete their own activity history');

set app.employee_id = 'T-S2';
select crm.undo_agent_followup(1);
select crm_test.eq((select status from crm.agent_suggestion where suggestion_id = 1), 'UNDONE', 'agent follow-up undone');
select crm_test.eq((select count(*) from crm.lead_activity where origin = 'AGENT'), 0::bigint, 'undone follow-up removed');

set app.employee_id = 'T-BM3';
select crm_test.eq((select count(*) from crm.agent_suggestion), 0::bigint, 'other branch manager sees no HiLITE suggestions');
reset role;
select crm_test.raises($$select crm.auth_set_password(crm.current_tenant_id(), 'AI-AGENT', 'x', false)$$, 'agent account cannot sign in');

-- -----------------------------------------------------------------------------
-- Company isolation: a second company on the same database
-- -----------------------------------------------------------------------------
select tenant_id as keycee_id from crm.tenant where code = 'KEYCEE' \gset
select crm.create_tenant('OTHER', 'Other Retail LLC', 'GENERAL', 'AE', '971', '^5[0-9]{8}$', 'Asia/Dubai', 'AED', 'en-AE');
select set_config('app.tenant_id', tenant_id::text, false) from crm.tenant where code = 'OTHER';
insert into crm.branch (code, name, city) values ('MAIN', 'Main store', 'Dubai');
insert into crm.employee (employee_id, employee_name, branch_id, status, crm_access_level, login_email)
values ('T-HO', 'Other HO Admin', null, 'ACTIVE', 'HO_ADMIN', 'ho@other.test');
insert into crm.customer (customer_name, mobile, created_by) values ('Other Customer', '+971 50 123 4567', 'T-HO');
insert into crm.lead (customer_id, branch_id, assigned_to, source_code, created_by)
select max(customer_id), (select branch_id from crm.branch where code = 'MAIN'), 'T-HO', 'WALK_IN', 'T-HO' from crm.customer;

select crm_test.eq((select mobile from crm.customer where customer_name = 'Other Customer'), '501234567', 'phone rule is per company');
select crm_test.raises($$insert into crm.customer (mobile) values ('9847000001')$$, 'other company rejects an Indian mobile');
select crm_test.raises($$insert into crm.lead (customer_id, branch_id, assigned_to, source_code)
                         values (1, (select branch_id from crm.branch where code = 'MAIN'), 'T-HO', 'WALK_IN')$$,
                       'cannot link to another company''s customer');
select crm_test.raises($$insert into crm.employee (employee_id, employee_name, status, crm_access_level, login_email)
                         values ('T-X', 'X', 'ACTIVE', 'STAFF', 'HO@other.test')$$, 'login email unique across companies');

set role crm_app;
set app.employee_id = 'T-HO';
select crm_test.eq((select count(*) from crm.lead), 1::bigint, 'second company sees only its own leads');
select crm_test.eq((select count(*) from crm.customer), 1::bigint, 'second company sees only its own customers');
select crm_test.eq((select count(*) from crm.branch), 1::bigint, 'second company sees only its own branches');
select crm_test.eq((select count(*) from crm.agent_suggestion), 0::bigint, 'second company sees no other suggestions');
select crm_test.eq((select count(*) from crm.lead_stage where code = 'WON'), 1::bigint, 'each company has its own stages');
select crm_test.raises(format($$insert into crm.lead_source (tenant_id, source_code, source_name) values (%s, 'X', 'X')$$, :keycee_id),
                       'cannot write into another company');
select crm_test.eq((select count(*) from crm.tenant), 1::bigint, 'company sees only its own company record');

select set_config('app.tenant_id', :'keycee_id', false);
select crm_test.eq((select count(*) from crm.lead), 5::bigint, 'same employee id in first company sees first company only');
select crm_test.eq((select count(*) from crm.customer where mobile = '501234567'), 0::bigint, 'first company cannot see second company customer');
reset role;

set client_min_messages = warning;
drop schema crm_test cascade;
