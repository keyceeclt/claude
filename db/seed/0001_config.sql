-- =============================================================================
-- Seed: Key Cee Associates, the first company on the platform.
--
-- CONFIRMED (from Key Cee Head Office): company, market and the three branches.
-- PLACEHOLDER: everything the ELECTRONICS template adds (pick-lists, stages,
-- sources, rules). These are starting points, NOT Key Cee business data;
-- crm.v_setup_gaps lists them until Head Office confirms or replaces them.
-- =============================================================================

select crm.create_tenant('KEYCEE', 'Key Cee Associates', 'ELECTRONICS');

insert into crm.branch (tenant_id, code, name, location, city, district)
select t.tenant_id, b.* from crm.tenant t, (values
    ('HILITE',       'HiLITE Mall',  'HiLITE Mall', 'Calicut',         null),
    ('MOBILE_PLAZA', 'Mobile Plaza', 'Mavoor Road', 'Calicut',         null),
    ('APPAS',        'Appas',        'Appas',       'Sulthan Bathery', 'Wayanad')) b(code, name, location, city, district)
where t.code = 'KEYCEE';
