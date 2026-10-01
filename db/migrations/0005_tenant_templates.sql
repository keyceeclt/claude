-- =============================================================================
-- 0005 · Starter templates for a new company.
--
-- crm.create_tenant() creates a company and fills its configuration from a
-- retail template. Every template value is a PLACEHOLDER (is_placeholder =
-- true): a starting point the company confirms or replaces in
-- Admin > Pick-lists & rules. crm.v_setup_gaps lists what is unconfirmed.
--
-- Templates: GENERAL (any retailer), ELECTRONICS (consumer electronics /
-- mobile stores). Add more by extending the product-category block.
-- =============================================================================

create function crm.apply_retail_template(p_tenant smallint, p_template text)
returns void language plpgsql security definer set search_path = crm, pg_temp as $$
begin
    if p_template not in ('GENERAL', 'ELECTRONICS') then
        raise exception 'Unknown template %', p_template;
    end if;

    -- Access levels: data_scope drives security; names can be changed freely.
    insert into crm.access_level (tenant_id, code, label, data_scope, can_write, can_manage_config, sort_order, is_placeholder) values
        (p_tenant, 'HO_ADMIN',       'Head Office Admin',        'ALL',    true,  true,  1, true),
        (p_tenant, 'HO_VIEWER',      'Head Office Viewer',       'ALL',    false, false, 2, true),
        (p_tenant, 'BRANCH_MANAGER', 'Branch Manager',           'BRANCH', true,  false, 3, true),
        (p_tenant, 'STAFF',          'Sales Staff / Telecaller', 'OWN',    true,  false, 4, true),
        -- Used only by the AI agents (see 0006); not assignable to people.
        (p_tenant, 'AI_AGENT',       'AI sales agent',           'ALL',    true,  false, 9, false);

    insert into crm.lookup_value (tenant_id, category, code, label, sort_order)
    select p_tenant, v.* from (values
        ('EMPLOYEE_STATUS', 'ACTIVE',            'Active', 1),
        ('EMPLOYEE_STATUS', 'ON_NOTICE',         'On notice', 2),
        ('EMPLOYEE_STATUS', 'EXITED',            'Exited', 3),
        ('DEPARTMENT',      'SALES',             'Sales', 1),
        ('DEPARTMENT',      'TELECALLING',       'Telecalling', 2),
        ('DEPARTMENT',      'MARKETING',         'Marketing', 3),
        ('DEPARTMENT',      'MANAGEMENT',        'Management', 4),
        ('DESIGNATION',     'SALES_EXECUTIVE',   'Sales Executive', 1),
        ('DESIGNATION',     'TELECALLER',        'Telecaller', 2),
        ('DESIGNATION',     'BRANCH_MANAGER',    'Branch Manager', 3),
        ('DESIGNATION',     'CRM_EXECUTIVE',     'CRM Executive', 4),
        ('CUSTOMER_SEGMENT', 'NEW',              'New customer', 1),
        ('CUSTOMER_SEGMENT', 'REPEAT',           'Repeat customer', 2),
        ('ACTIVITY_TYPE',   'CALL',              'Phone call', 1),
        ('ACTIVITY_TYPE',   'WHATSAPP',          'WhatsApp', 2),
        ('ACTIVITY_TYPE',   'SMS',               'SMS', 3),
        ('ACTIVITY_TYPE',   'IN_STORE',          'In-store discussion', 4),
        ('LOST_REASON',     'PRICE',             'Price', 1),
        ('LOST_REASON',     'BOUGHT_ELSEWHERE',  'Bought elsewhere', 2),
        ('LOST_REASON',     'STOCK_UNAVAILABLE', 'Stock / model unavailable', 3),
        ('LOST_REASON',     'FINANCE_NOT_APPROVED', 'Finance not approved', 4),
        ('LOST_REASON',     'PLAN_DROPPED',      'Purchase plan dropped', 5),
        ('LOST_REASON',     'NOT_REACHABLE',     'Not reachable after attempts', 6)
    ) v;

    if p_template = 'ELECTRONICS' then
        insert into crm.lookup_value (tenant_id, category, code, label, sort_order)
        select p_tenant, 'PRODUCT_CATEGORY', v.* from (values
            ('MOBILE', 'Mobile phones', 1), ('TABLET', 'Tablets', 2), ('WEARABLE', 'Wearables & audio', 3),
            ('LAPTOP', 'Laptops', 4), ('TV', 'Televisions', 5), ('APPLIANCE', 'Home appliances', 6),
            ('ACCESSORY', 'Accessories', 7)) v;
    else
        insert into crm.lookup_value (tenant_id, category, code, label, sort_order)
        select p_tenant, 'PRODUCT_CATEGORY', v.* from (values
            ('GENERAL', 'General merchandise', 1), ('PREMIUM', 'Premium range', 2),
            ('ACCESSORY', 'Accessories', 3), ('SERVICE', 'Services & warranty', 4)) v;
    end if;

    -- Lead stages. Flags (closed / won / lost / junk) drive the KPIs.
    -- WON is set only by the system when a sale is linked to the lead.
    insert into crm.lead_stage (tenant_id, code, label, stage_order, is_closed, is_won, is_lost, excluded_from_conversion) values
        (p_tenant, 'NEW',             'New',               1, false, false, false, false),
        (p_tenant, 'CONTACTED',       'Contacted',         2, false, false, false, false),
        (p_tenant, 'INTERESTED',      'Interested',        3, false, false, false, false),
        (p_tenant, 'VISIT_SCHEDULED', 'Visit scheduled',   4, false, false, false, false),
        (p_tenant, 'VISITED',         'Visited store',     5, false, false, false, false),
        (p_tenant, 'QUOTED',          'Quotation given',   6, false, false, false, false),
        (p_tenant, 'WON',             'Won (sale linked)', 7, true,  true,  false, false),
        (p_tenant, 'LOST',            'Lost',              8, true,  false, true,  false),
        (p_tenant, 'INVALID',         'Invalid / duplicate / wrong number', 9, true, false, false, true);

    insert into crm.lead_source (tenant_id, source_code, source_name, is_paid) values
        (p_tenant, 'WALK_IN',           'Walk-in enquiry',          false),
        (p_tenant, 'PHONE_INQUIRY',     'Phone enquiry',            false),
        (p_tenant, 'WHATSAPP',          'WhatsApp enquiry',         false),
        (p_tenant, 'SOCIAL_ADS',        'Facebook / Instagram ads', true),
        (p_tenant, 'GOOGLE_ADS',        'Google ads',               true),
        (p_tenant, 'REFERRAL',          'Referral',                 false),
        (p_tenant, 'EXISTING_CUSTOMER', 'Existing customer',        false),
        (p_tenant, 'EVENT',             'Event / exhibition',       true);

    insert into crm.activity_outcome (tenant_id, code, label, customer_reached) values
        (p_tenant, 'CONNECTED_INTERESTED',     'Connected: interested',        true),
        (p_tenant, 'CONNECTED_CALLBACK',       'Connected: call back later',   true),
        (p_tenant, 'CONNECTED_NOT_INTERESTED', 'Connected: not interested',    true),
        (p_tenant, 'NO_ANSWER',                'No answer',                    false),
        (p_tenant, 'BUSY',                     'Busy / call cut',              false),
        (p_tenant, 'SWITCHED_OFF',             'Switched off / not reachable', false),
        (p_tenant, 'WRONG_NUMBER',             'Wrong number',                 false);

    insert into crm.setting (tenant_id, key, value, unit, description) values
        (p_tenant, 'FIRST_CONTACT_SLA_HOURS', 4,  'hours', 'A new lead must be reached within this time'),
        (p_tenant, 'FOLLOWUP_GRACE_HOURS',    24, 'hours', 'A follow-up done within this time after its due time counts as on time'),
        (p_tenant, 'STALE_LEAD_DAYS',         7,  'days',  'An open lead with no activity for this long is flagged stale');

    -- The AI agents act through this employee record, so every agent action
    -- goes through the same security rules and shows "AI sales agent" in history.
    insert into crm.employee (tenant_id, employee_id, employee_name, status, crm_access_level)
    values (p_tenant, 'AI-AGENT', 'AI sales agent', 'ACTIVE', 'AI_AGENT');
end $$;

-- Create a company with its market settings and a starter template.
create function crm.create_tenant(
    p_code text, p_name text, p_template text default 'GENERAL',
    p_country text default 'IN', p_phone_prefix text default '91', p_phone_pattern text default '^[6-9][0-9]{9}$',
    p_timezone text default 'Asia/Kolkata', p_currency text default 'INR', p_locale text default 'en-IN')
returns smallint language plpgsql security definer set search_path = crm, pg_temp as $$
declare
    v_id smallint;
begin
    insert into crm.tenant (code, name, country_code, phone_prefix, phone_pattern, timezone, currency, locale)
    values (upper(p_code), p_name, p_country, p_phone_prefix, p_phone_pattern, p_timezone, p_currency, p_locale)
    returning tenant_id into v_id;
    perform crm.apply_retail_template(v_id, p_template);
    return v_id;
end $$;

revoke execute on function crm.apply_retail_template(smallint, text) from public, crm_app;
revoke execute on function crm.create_tenant(text, text, text, text, text, text, text, text, text) from public, crm_app;
