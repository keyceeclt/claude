// End-to-end tests: real HTTP requests against the app and a real database.
// Needs DATABASE_URL pointing at a fresh database with db/migrations and
// db/seed applied (scripts/test-db.sh does this).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/server.js';
import { asSystem, pool } from '../src/db.js';
import { hashPassword } from '../src/auth.js';

let server;
let base;
const PASSWORD = 'correct-horse-9';

before(async () => {
    await asSystem(async (db) => {
        await db.query(`insert into crm.employee (employee_id, employee_name, branch_id, status, crm_access_level, login_email, exit_date) values
            ('A-HO',  'Test Admin',     null, 'ACTIVE', 'HO_ADMIN',       'ho@test.kc', null),
            ('A-BM1', 'Test Manager 1', 1,    'ACTIVE', 'BRANCH_MANAGER', 'bm1@test.kc', null),
            ('A-S1',  'Test Staff 1',   1,    'ACTIVE', 'STAFF',          's1@test.kc', null),
            ('A-S2',  'Test Staff 2',   1,    'ACTIVE', 'STAFF',          's2@test.kc', null),
            ('A-S3',  'Test Staff 3',   3,    'ACTIVE', 'STAFF',          's3@test.kc', null),
            ('A-NEW', 'Test Newcomer',  1,    'ACTIVE', 'STAFF',          'new@test.kc', null),
            ('A-OLD', 'Test Leaver',    1,    'EXITED', 'STAFF',          'old@test.kc', current_date)`);
        const hash = hashPassword(PASSWORD);
        await db.query(`insert into crm.app_login (employee_id, password_hash, must_change_password)
                        select employee_id, $1, employee_id = 'A-NEW' from crm.employee where employee_id like 'A-%'`, [hash]);
    });
    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
    server.close();
    await pool.end();
});

// Minimal browser: cookie jar + CSRF token from the last page.
function browser() {
    let cookie = '';
    let csrf = '';
    async function request(method, path, form) {
        const res = await fetch(base + path, {
            method,
            redirect: 'manual',
            headers: { cookie, ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}) },
            body: form ? new URLSearchParams({ _csrf: csrf, ...form }).toString() : undefined,
        });
        const set = res.headers.get('set-cookie');
        if (set) cookie = set.split(';')[0];
        const html = await res.text();
        const m = html.match(/name="_csrf" value="([^"]+)"/);
        if (m) csrf = m[1];
        return { status: res.status, location: res.headers.get('location'), html };
    }
    return {
        get: (p) => request('GET', p),
        post: (p, form) => request('POST', p, form),
        async follow(r) {
            let res = r;
            while (res.status === 302 || res.status === 303) res = await request('GET', res.location);
            return res;
        },
        async login(email, password = PASSWORD) {
            const r = await request('POST', '/login', { email, password, next: '/' });
            await request('GET', '/');
            return r;
        },
    };
}

const said = (location) => decodeURIComponent(String(location).replace(/\+/g, ' '));
const q = async (sql, args) => (await asSystem((db) => db.query(sql, args))).rows;

test('sign-in: wrong password is rejected, right one lands on My Day', async () => {
    const b = browser();
    assert.equal((await b.post('/login', { email: 's1@test.kc', password: 'nope-nope-nope' })).status, 401);
    const ok = await b.post('/login', { email: 'S1@test.kc', password: PASSWORD, next: '/' });
    assert.equal(ok.status, 302);
    const home = await b.get('/');
    assert.equal(home.status, 200);
    assert.match(home.html, /My Day/);
});

test('sign-in: exited staff cannot sign in', async () => {
    const b = browser();
    assert.equal((await b.post('/login', { email: 'old@test.kc', password: PASSWORD })).status, 401);
});

test('first sign-in forces a password change', async () => {
    const b = browser();
    await b.post('/login', { email: 'new@test.kc', password: PASSWORD, next: '/' });
    const r = await b.get('/leads');
    assert.equal(r.location, '/account/password');
    await b.get('/account/password');
    const bad = await b.post('/account/password', { current: PASSWORD, password: 'short', confirm: 'short' });
    assert.equal(bad.status, 400);
    const good = await b.post('/account/password', { current: PASSWORD, password: 'a-new-password-1', confirm: 'a-new-password-1' });
    assert.equal(good.status, 302);
    assert.equal((await b.get('/leads')).status, 200);
});

test('forms without the CSRF token are refused', async () => {
    const b = browser();
    await b.login('s1@test.kc');
    const res = await fetch(`${base}/leads`, { method: 'POST', redirect: 'manual', body: 'mobile=9800000001',
        headers: { 'content-type': 'application/x-www-form-urlencoded' } });
    assert.ok([302, 403].includes(res.status));
    assert.equal((await q("select count(*)::int as n from crm.customer where mobile = '9800000001'"))[0].n, 0);
});

let leadId;

test('staff creates a lead for a new customer, then logs a call with the next follow-up', async () => {
    const b = browser();
    await b.login('s1@test.kc');
    const lookup = await b.get('/leads/new?mobile=%2B91%2098000%2000011');
    assert.match(lookup.html, /New customer/);
    const created = await b.post('/leads', {
        mobile: '+91 98000 00011', customer_name: 'Test Buyer', source_code: 'WALK_IN', product_category: 'MOBILE',
        first_followup_at: '2020-01-01T10:00',
    });
    assert.equal(created.status, 302);
    leadId = Number(created.location.match(/\/leads\/(\d+)/)[1]);
    const page = await b.follow(created);
    assert.match(page.html, /Test Buyer/);
    assert.match(page.html, /overdue/);

    const logged = await b.post(`/leads/${leadId}/activity`, {
        activity_type: 'CALL', outcome: 'CONNECTED_INTERESTED', notes: 'Wants S-series', next_followup_at: '2099-01-01T11:00',
    });
    assert.equal(logged.status, 302);
    const acts = await q('select due_at, completed_at, outcome from crm.lead_activity where lead_id = $1 order by due_at', [leadId]);
    assert.equal(acts.length, 2, 'pending follow-up completed, next one scheduled');
    assert.equal(acts[0].outcome, 'CONNECTED_INTERESTED');
    assert.equal(acts[1].completed_at, null);
    const [lead] = await q('select first_contact_at, assigned_to from crm.lead where lead_id = $1', [leadId]);
    assert.ok(lead.first_contact_at);
    assert.equal(lead.assigned_to, 'A-S1');
});

test('looking up an existing mobile reuses the customer', async () => {
    const b = browser();
    await b.login('s2@test.kc');
    const page = await b.get('/leads/new?mobile=9800000011');
    assert.match(page.html, /Existing customer/);
    await b.post('/leads', { mobile: '9800000011', source_code: 'PHONE_INQUIRY' });
    assert.equal((await q("select count(*)::int as n from crm.customer where mobile = '9800000011'"))[0].n, 1);
});

test('staff cannot open a colleague\'s lead or manager-only pages', async () => {
    const b = browser();
    await b.login('s3@test.kc');
    assert.equal((await b.get(`/leads/${leadId}`)).status, 404);
    assert.equal((await b.get('/sales/new')).status, 403);
    assert.equal((await b.get('/admin/config')).status, 403);
    const list = await b.get('/leads?status=all');
    assert.doesNotMatch(list.html, /Test Buyer/);
});

test('stage rules: no manual Won, Lost needs a reason', async () => {
    const b = browser();
    await b.login('s1@test.kc');
    await b.get(`/leads/${leadId}`);
    const won = await b.post(`/leads/${leadId}/stage`, { stage_code: 'WON' });
    assert.match(said(won.location), /without a linked sale/);
    await b.get(`/leads/${leadId}`);
    const lost = await b.post(`/leads/${leadId}/stage`, { stage_code: 'LOST', lost_reason: '' });
    assert.match(said(lost.location), /lost reason/);
    assert.equal((await q('select stage_code from crm.lead where lead_id = $1', [leadId]))[0].stage_code, 'NEW');
});

test('manager records a visit, quotation and sale; the lead becomes Won', async () => {
    const b = browser();
    await b.login('bm1@test.kc');
    await b.get(`/leads/${leadId}`);
    await b.post(`/leads/${leadId}/visit`, { notes: 'Came with family' });
    await b.get(`/leads/${leadId}`);
    await b.post(`/leads/${leadId}/quotation`, { quotation_no: 'Q-T1', total_value: '52000' });
    const form = await b.get(`/sales/new?lead_id=${leadId}`);
    assert.match(form.html, /Q-T1/);
    const [quote] = await q('select quotation_id from crm.quotation where lead_id = $1', [leadId]);
    const sale = await b.post('/sales', {
        lead_id: String(leadId), invoice_no: 'T-INV-1', invoice_date: '2026-09-01', sold_by: 'A-S1', net_value: '50000',
        quotation_id: String(quote.quotation_id), item_category: 'MOBILE', item_model: 'S-series', item_qty: '1', item_value: '50000',
    });
    assert.equal(sale.status, 302);
    const [lead] = await q('select stage_code from crm.lead where lead_id = $1', [leadId]);
    assert.equal(lead.stage_code, 'WON');
    assert.equal((await q("select status from crm.quotation where quotation_no = 'Q-T1'"))[0].status, 'ACCEPTED');
    const dup = await b.post('/sales', { invoice_no: 'T-INV-1', invoice_date: '2026-09-01', net_value: '10' });
    assert.match(said(dup.location), /already exists/);
});

test('walk-in visit opens a lead', async () => {
    const b = browser();
    await b.login('s1@test.kc');
    await b.get('/visits/new');
    const r = await b.post('/visits', { mobile: '9800000077', customer_name: 'Test Walker', create_lead: 'yes', source_code: 'WALK_IN' });
    assert.match(r.location, /^\/leads\/\d+/);
    assert.equal((await q("select count(*)::int as n from crm.store_visit v join crm.customer c using (customer_id) where c.mobile = '9800000077' and v.lead_id is not null"))[0].n, 1);
});

test('every page renders for manager, admin and staff', async () => {
    const pages = ['/', '/leads', '/leads/new', '/customers', '/sales', '/campaigns', '/visits/new', '/reports/daily',
        '/reports/funnel', '/reports/staff', '/reports/ageing', '/reports/data-quality'];
    for (const email of ['bm1@test.kc', 'ho@test.kc', 's1@test.kc']) {
        const b = browser();
        await b.login(email);
        for (const p of pages) assert.equal((await b.get(p)).status, 200, `${email} ${p}`);
        if (email !== 's1@test.kc') {
            for (const p of ['/admin/employees', '/admin/import']) assert.equal((await b.get(p)).status, 200, `${email} ${p}`);
        }
    }
    const admin = browser();
    await admin.login('ho@test.kc');
    assert.equal((await admin.get('/admin/config')).status, 200);
    assert.equal((await admin.get(`/leads/${leadId}`)).status, 200);
});

test('manager sees own branch only in the Daily MIS', async () => {
    const b = browser();
    await b.login('bm1@test.kc');
    const r = await b.get('/reports/daily?date=2026-09-01');
    assert.match(r.html, /HiLITE Mall/);
    assert.doesNotMatch(r.html, /Appas/);
});

test('admin adds staff, creates a login and sets a target', async () => {
    const b = browser();
    await b.login('ho@test.kc');
    await b.get('/admin/employees/new');
    const r = await b.post('/admin/employees', {
        employee_id: 'A-X1', employee_name: 'Test Added', branch_id: '2', status: 'ACTIVE', crm_access_level: 'STAFF',
        login_email: 'X1@test.kc', reporting_manager_id: 'A-HO',
    });
    assert.equal(r.status, 302, r.location);
    await b.get('/admin/employees/A-X1');
    await b.post('/admin/employees/A-X1/login', { password: 'temporary-pass-1' });
    await b.get('/admin/employees/A-X1');
    await b.post('/admin/employees/A-X1/target', { month: '2026-09', target_type: 'SALES_VALUE', target_value: '300000' });
    const nb = browser();
    const login = await nb.post('/login', { email: 'x1@test.kc', password: 'temporary-pass-1', next: '/' });
    assert.equal(login.status, 302);
    assert.equal((await q("select target_value from crm.staff_target where employee_id = 'A-X1'"))[0].target_value, 300000);
});

test('admin confirms a placeholder value and changes a rule', async () => {
    const b = browser();
    await b.login('ho@test.kc');
    await b.get('/admin/config');
    await b.post('/admin/config/update', { table: 'lead_source', source_code: 'REFERRAL', label: 'Customer referral', confirmed: 'yes', active: 'yes' });
    const [src] = await q("select source_name, is_placeholder from crm.lead_source where source_code = 'REFERRAL'");
    assert.deepEqual(src, { source_name: 'Customer referral', is_placeholder: false });
    await b.get('/admin/config');
    await b.post('/admin/config/setting', { key: 'STALE_LEAD_DAYS', value: '5' });
    assert.equal((await q("select value from crm.setting where key = 'STALE_LEAD_DAYS'"))[0].value, 5);
});

test('CSV import checks every row and saves nothing if one fails', async () => {
    const b = browser();
    await b.login('ho@test.kc');
    await b.get('/admin/import');
    const header = 'invoice_no,branch_code,invoice_date,net_value,customer_mobile,customer_name,sold_by,lead_id';
    const bad = `${header}\nCSV-1,HILITE,2026-09-02,1000,9800000101,Test Csv,,\nCSV-2,NOWHERE,2026-09-02,1000,,,,`;
    const r1 = await b.post('/admin/import', { type: 'sales', mode: 'import', csv: bad });
    assert.match(r1.html, /Unknown branch_code/, r1.html.slice(r1.html.lastIndexOf('</textarea>'), r1.html.lastIndexOf('</textarea>') + 1200));
    assert.equal((await q("select count(*)::int as n from crm.sale where invoice_no like 'CSV-%'"))[0].n, 0);
    const good = `${header}\nCSV-1,HILITE,2026-09-02,1000,9800000101,Test Csv,,\n"CSV-2",appas,2026-09-02,2500,,,A-S3,`;
    const r2 = await b.post('/admin/import', { type: 'sales', mode: 'import', csv: good });
    assert.match(r2.html, /Imported 2 rows/);
    assert.equal((await q("select count(*)::int as n from crm.sale where invoice_no like 'CSV-%'"))[0].n, 2);
});
