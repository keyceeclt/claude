-- =============================================================================
-- Configuration seed.
--
-- CONFIRMED (from Head Office): the three branches.
-- PLACEHOLDER (is_placeholder = true): everything else. These are starter
-- values so the system runs; they are NOT Key Cee business data. Replace or
-- confirm them, then set is_placeholder = false. crm.v_setup_gaps lists what
-- is still unconfirmed.
-- =============================================================================

-- Confirmed
insert into crm.branch (code, name, location, city, district) values
    ('HILITE',       'HiLITE Mall',  'HiLITE Mall',  'Calicut',         null),
    ('MOBILE_PLAZA', 'Mobile Plaza', 'Mavoor Road',  'Calicut',         null),
    ('APPAS',        'Appas',        'Appas',        'Sulthan Bathery', 'Wayanad');

-- Placeholder: CRM access levels. data_scope drives row security and is the
-- part that matters; codes and labels can be renamed freely.
insert into crm.access_level (code, label, data_scope, can_write, can_manage_config, sort_order) values
    ('HO_ADMIN',       'Head Office Admin',      'ALL',    true,  true,  1),
    ('HO_VIEWER',      'Head Office Viewer',     'ALL',    false, false, 2),
    ('BRANCH_MANAGER', 'Branch Manager',         'BRANCH', true,  false, 3),
    ('STAFF',          'Sales Staff / Telecaller', 'OWN',  true,  false, 4);

insert into crm.lookup_value (category, code, label, sort_order) values
    -- Employee_Master
    ('EMPLOYEE_STATUS', 'ACTIVE',        'Active', 1),
    ('EMPLOYEE_STATUS', 'ON_NOTICE',     'On notice', 2),
    ('EMPLOYEE_STATUS', 'EXITED',        'Exited', 3),
    ('DEPARTMENT',      'SALES',         'Sales', 1),
    ('DEPARTMENT',      'TELECALLING',   'Telecalling', 2),
    ('DEPARTMENT',      'MARKETING',     'Marketing', 3),
    ('DEPARTMENT',      'MANAGEMENT',    'Management', 4),
    ('DESIGNATION',     'SALES_EXECUTIVE',  'Sales Executive', 1),
    ('DESIGNATION',     'TELECALLER',       'Telecaller', 2),
    ('DESIGNATION',     'BRANCH_MANAGER',   'Branch Manager', 3),
    ('DESIGNATION',     'CRM_EXECUTIVE',    'CRM Executive', 4),
    -- CRM
    ('CUSTOMER_SEGMENT', 'NEW',          'New customer', 1),
    ('CUSTOMER_SEGMENT', 'REPEAT',       'Repeat customer', 2),
    ('ACTIVITY_TYPE',   'CALL',          'Phone call', 1),
    ('ACTIVITY_TYPE',   'WHATSAPP',      'WhatsApp', 2),
    ('ACTIVITY_TYPE',   'SMS',           'SMS', 3),
    ('ACTIVITY_TYPE',   'IN_STORE',      'In-store discussion', 4),
    ('LOST_REASON',     'PRICE',         'Price', 1),
    ('LOST_REASON',     'BOUGHT_ELSEWHERE', 'Bought elsewhere', 2),
    ('LOST_REASON',     'STOCK_UNAVAILABLE', 'Stock / model unavailable', 3),
    ('LOST_REASON',     'FINANCE_NOT_APPROVED', 'Finance not approved', 4),
    ('LOST_REASON',     'PLAN_DROPPED',  'Purchase plan dropped', 5),
    ('LOST_REASON',     'NOT_REACHABLE', 'Not reachable after attempts', 6),
    -- Sales
    ('PRODUCT_CATEGORY', 'MOBILE',       'Mobile phones', 1),
    ('PRODUCT_CATEGORY', 'TABLET',       'Tablets', 2),
    ('PRODUCT_CATEGORY', 'WEARABLE',     'Wearables & audio', 3),
    ('PRODUCT_CATEGORY', 'LAPTOP',       'Laptops', 4),
    ('PRODUCT_CATEGORY', 'TV',           'Televisions', 5),
    ('PRODUCT_CATEGORY', 'APPLIANCE',    'Home appliances', 6),
    ('PRODUCT_CATEGORY', 'ACCESSORY',    'Accessories', 7);

-- Placeholder: lead stages. Flags (closed / won / lost / junk) drive the KPIs.
-- WON is set only by the system when a sale is linked to the lead.
insert into crm.lead_stage (code, label, stage_order, is_closed, is_won, is_lost, excluded_from_conversion) values
    ('NEW',             'New',              1, false, false, false, false),
    ('CONTACTED',       'Contacted',        2, false, false, false, false),
    ('INTERESTED',      'Interested',       3, false, false, false, false),
    ('VISIT_SCHEDULED', 'Visit scheduled',  4, false, false, false, false),
    ('VISITED',         'Visited store',    5, false, false, false, false),
    ('QUOTED',          'Quotation given',  6, false, false, false, false),
    ('WON',             'Won (sale linked)', 7, true, true,  false, false),
    ('LOST',            'Lost',             8, true,  false, true,  false),
    ('INVALID',         'Invalid / duplicate / wrong number', 9, true, false, false, true);

insert into crm.lead_source (source_code, source_name, is_paid) values
    ('WALK_IN',          'Walk-in enquiry',        false),
    ('PHONE_INQUIRY',    'Phone enquiry',          false),
    ('WHATSAPP',         'WhatsApp enquiry',       false),
    ('SOCIAL_ADS',       'Facebook / Instagram ads', true),
    ('GOOGLE_ADS',       'Google ads',             true),
    ('REFERRAL',         'Referral',               false),
    ('EXISTING_CUSTOMER','Existing customer',      false),
    ('EVENT',            'Event / exhibition',     true);

insert into crm.activity_outcome (code, label, customer_reached) values
    ('CONNECTED_INTERESTED',     'Connected: interested',       true),
    ('CONNECTED_CALLBACK',       'Connected: call back later',  true),
    ('CONNECTED_NOT_INTERESTED', 'Connected: not interested',   true),
    ('NO_ANSWER',                'No answer',                   false),
    ('BUSY',                     'Busy / call cut',             false),
    ('SWITCHED_OFF',             'Switched off / not reachable', false),
    ('WRONG_NUMBER',             'Wrong number',                false);

insert into crm.setting (key, value, unit, description) values
    ('FIRST_CONTACT_SLA_HOURS', 4,  'hours', 'A new lead must be reached within this time'),
    ('FOLLOWUP_GRACE_HOURS',    24, 'hours', 'A follow-up done within this time after its due time counts as on time'),
    ('STALE_LEAD_DAYS',         7,  'days',  'An open lead with no activity for this long is flagged stale');
