import { Router } from 'express';
import { asUser, asSystem } from '../db.js';
import { loadLookups } from '../lookups.js';
import { act, blank, dbMessage, monthStartIST } from '../helpers.js';
import { requireConfig, requireScope, hashPassword, passwordProblem } from '../auth.js';
import { parseCsv } from '../csv.js';

const router = Router();
const code = (v) => String(v || '').trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '');

// ------------------------------------------------------------------ staff
router.get('/employees', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const data = await asUser(req.user.employee_id, async (db) => ({
        rows: (await db.query(
            `select e.*, m.employee_name as manager_name from crm.employee e
             left join crm.employee m on m.employee_id = e.reporting_manager_id
             order by (e.exit_date is not null and e.exit_date <= current_date), e.branch_id nulls first, e.employee_name`)).rows,
        L: await loadLookups(db),
    }));
    const logins = await asSystem(async (db) => new Set(
        (await db.query('select employee_id from crm.app_login')).rows.map((r) => r.employee_id)));
    res.render('admin/employees', { title: 'Staff', logins, ...data });
});

router.get('/employees/new', requireConfig, async (req, res) => {
    const L = await asUser(req.user.employee_id, loadLookups);
    res.render('admin/employee-form', { title: 'Add staff', L, e: {}, targets: [], hasLogin: false });
});

function employeeValues(b) {
    return [blank(b.employee_name), blank(b.branch_id), blank(b.designation), blank(b.department), blank(b.joining_date),
        blank(b.status), blank(b.exit_date), blank(b.reporting_manager_id), blank(b.crm_access_level), blank(b.mobile),
        blank(b.login_email)?.toLowerCase() || null];
}

router.post('/employees', requireConfig, async (req, res) => {
    await act(res, '/admin/employees/new', () => asUser(req.user.employee_id, async (db) => {
        const id = blank(req.body.employee_id);
        await db.query(
            `insert into crm.employee (employee_id, employee_name, branch_id, designation, department, joining_date, status,
                                       exit_date, reporting_manager_id, crm_access_level, mobile, login_email)
             values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`, [id, ...employeeValues(req.body)]);
        return `/admin/employees/${encodeURIComponent(id)}?msg=Staff member added. Set a login below.`;
    }));
});

router.get('/employees/:id', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const data = await asUser(req.user.employee_id, async (db) => ({
        e: (await db.query('select * from crm.employee where employee_id = $1', [req.params.id])).rows[0],
        targets: (await db.query('select * from crm.staff_target where employee_id = $1 order by period_start desc, target_type', [req.params.id])).rows,
        L: await loadLookups(db),
    }));
    if (!data.e) return res.status(404).render('error', { title: 'Not found', message: 'No such staff member.' });
    const hasLogin = await asSystem(async (db) => (await db.query('select 1 from crm.app_login where employee_id = $1', [req.params.id])).rowCount > 0);
    res.render('admin/employee-form', { title: data.e.employee_name, hasLogin, ...data });
});

router.post('/employees/:id', requireConfig, async (req, res) => {
    const back = `/admin/employees/${encodeURIComponent(req.params.id)}`;
    await act(res, back, () => asUser(req.user.employee_id, async (db) => {
        await db.query(
            `update crm.employee set employee_name = $2, branch_id = $3, designation = $4, department = $5, joining_date = $6,
                    status = $7, exit_date = $8, reporting_manager_id = $9, crm_access_level = $10, mobile = $11, login_email = $12
             where employee_id = $1`, [req.params.id, ...employeeValues(req.body)]);
        return `${back}?msg=Saved.`;
    }));
});

router.post('/employees/:id/login', requireConfig, async (req, res) => {
    const back = `/admin/employees/${encodeURIComponent(req.params.id)}`;
    const problem = passwordProblem(req.body.password);
    if (problem) return res.redirect(`${back}?err=${encodeURIComponent(problem)}`);
    const { rows } = await asUser(req.user.employee_id, (db) =>
        db.query('select login_email from crm.employee where employee_id = $1', [req.params.id]));
    if (!rows[0]?.login_email) return res.redirect(`${back}?err=${encodeURIComponent('Save a login email for this person first.')}`);
    await asSystem((db) => db.query(
        `insert into crm.app_login (employee_id, password_hash, must_change_password) values ($1, $2, true)
         on conflict (employee_id) do update set password_hash = excluded.password_hash, must_change_password = true, updated_at = now()`,
        [req.params.id, hashPassword(req.body.password)]));
    res.redirect(`${back}?msg=${encodeURIComponent('Temporary password set. They must change it at first sign-in.')}`);
});

router.post('/employees/:id/target', requireConfig, async (req, res) => {
    const back = `/admin/employees/${encodeURIComponent(req.params.id)}`;
    await act(res, back, () => asUser(req.user.employee_id, async (db) => {
        const month = /^\d{4}-\d{2}$/.test(req.body.month || '') ? `${req.body.month}-01` : monthStartIST();
        await db.query(
            `insert into crm.staff_target (employee_id, period_type, period_start, period_end, target_type, target_value)
             values ($1, 'MONTH', $2::date, ($2::date + interval '1 month - 1 day')::date, $3, $4)
             on conflict (employee_id, target_type, period_start, period_end) do update set target_value = excluded.target_value`,
            [req.params.id, month, req.body.target_type, req.body.target_value]);
        return `${back}?msg=Target saved.`;
    }));
});

// ------------------------------------------------------------------ configuration
router.get('/config', requireConfig, async (req, res) => {
    const data = await asUser(req.user.employee_id, async (db) => ({
        lookups: (await db.query('select * from crm.lookup_value order by category, sort_order, code')).rows,
        settings: (await db.query('select * from crm.setting order by key')).rows,
        L: await loadLookups(db),
    }));
    res.render('admin/config', { title: 'Pick-lists & rules', ...data });
});

const CONFIG_TABLES = {
    lookup_value: { key: ['category', 'code'], label: 'label' },
    lead_stage: { key: ['code'], label: 'label' },
    lead_source: { key: ['source_code'], label: 'source_name' },
    activity_outcome: { key: ['code'], label: 'label' },
    access_level: { key: ['code'], label: 'label' },
};

router.post('/config/update', requireConfig, async (req, res) => {
    const t = CONFIG_TABLES[req.body.table];
    if (!t) return res.redirect('/admin/config?err=Unknown table');
    await act(res, '/admin/config', () => asUser(req.user.employee_id, async (db) => {
        const args = [req.body.label, req.body.confirmed !== 'yes'];
        const sets = [`${t.label} = $1`, 'is_placeholder = $2'];
        if (req.body.table !== 'access_level') {
            args.push(req.body.active === 'yes');
            sets.push(`is_active = $${args.length}`);
        }
        const where = t.key.map((k) => { args.push(req.body[k]); return `${k} = $${args.length}`; }).join(' and ');
        await db.query(`update crm.${req.body.table} set ${sets.join(', ')} where ${where}`, args);
        return '/admin/config?msg=Saved.';
    }));
});

router.post('/config/add', requireConfig, async (req, res) => {
    const b = req.body;
    await act(res, '/admin/config', () => asUser(req.user.employee_id, async (db) => {
        if (b.table === 'lookup_value') {
            await db.query(
                `insert into crm.lookup_value (category, code, label, sort_order, is_placeholder)
                 values ($1, $2, $3, coalesce((select max(sort_order) + 1 from crm.lookup_value where category = $1), 1), false)`,
                [b.category, code(b.code || b.label), b.label]);
        } else if (b.table === 'lead_source') {
            await db.query('insert into crm.lead_source (source_code, source_name, is_paid, is_placeholder) values ($1, $2, $3, false)',
                [code(b.code || b.label), b.label, b.is_paid === 'yes']);
        } else if (b.table === 'activity_outcome') {
            await db.query('insert into crm.activity_outcome (code, label, customer_reached, is_placeholder) values ($1, $2, $3, false)',
                [code(b.code || b.label), b.label, b.customer_reached === 'yes']);
        } else if (b.table === 'lead_stage') {
            await db.query(
                `insert into crm.lead_stage (code, label, stage_order, is_closed, is_lost, excluded_from_conversion, is_placeholder)
                 values ($1, $2, coalesce($3::int, (select max(stage_order) + 1 from crm.lead_stage)), $4, $5, $6, false)`,
                [code(b.code || b.label), b.label, blank(b.stage_order), b.kind !== 'open', b.kind === 'lost', b.kind === 'junk']);
        } else {
            throw Object.assign(new Error('bad'), { code: '42501' });
        }
        return '/admin/config?msg=Added.';
    }));
});

router.post('/config/setting', requireConfig, async (req, res) => {
    await act(res, '/admin/config', () => asUser(req.user.employee_id, async (db) => {
        await db.query('update crm.setting set value = $2, is_placeholder = false where key = $1', [req.body.key, req.body.value]);
        return '/admin/config?msg=Rule saved.';
    }));
});

// ------------------------------------------------------------------ CSV import
const IMPORTS = {
    leads: ['mobile', 'customer_name', 'branch_code', 'assigned_to', 'source_code', 'campaign_code',
        'product_category', 'product_interest', 'created_at', 'notes'],
    sales: ['invoice_no', 'branch_code', 'invoice_date', 'net_value', 'customer_mobile', 'customer_name', 'sold_by', 'lead_id'],
};

router.get('/import', requireScope('ALL', 'BRANCH'), (req, res) => {
    res.render('admin/import', { title: 'Import data', IMPORTS, result: null, type: 'leads', csv: '' });
});

async function customerFor(db, mobile, name, branchId, me) {
    if (!blank(mobile)) return null;
    const found = (await db.query('select customer_id from crm.find_customer_by_mobile($1)', [mobile])).rows[0];
    if (found) return found.customer_id;
    return (await db.query(
        `insert into crm.customer (customer_name, mobile, home_branch_id, created_by) values ($1, $2, $3, $4) returning customer_id`,
        [blank(name), mobile, branchId, me])).rows[0].customer_id;
}

async function importRow(db, type, r, me) {
    const branch = (await db.query('select branch_id from crm.branch where code = upper($1)', [r.branch_code])).rows[0];
    if (!branch) throw new Error(`Unknown branch_code "${r.branch_code}"`);
    if (type === 'leads') {
        const customerId = await customerFor(db, r.mobile, r.customer_name, branch.branch_id, me);
        if (!customerId) throw new Error('mobile is required');
        const campaign = blank(r.campaign_code)
            ? (await db.query('select campaign_id from crm.campaign where campaign_code = $1', [r.campaign_code])).rows[0]
            : null;
        if (blank(r.campaign_code) && !campaign) throw new Error(`Unknown campaign_code "${r.campaign_code}"`);
        const leadId = (await db.query(
            `insert into crm.lead (customer_id, branch_id, assigned_to, source_code, campaign_id, product_category, product_interest,
                                   created_by, created_at)
             values ($1, $2, $3, upper($4), $5, upper($6), $7, $8, coalesce($9::timestamptz, now())) returning lead_id`,
            [customerId, branch.branch_id, blank(r.assigned_to), r.source_code, campaign?.campaign_id ?? null,
             blank(r.product_category), blank(r.product_interest), me, blank(r.created_at)])).rows[0].lead_id;
        if (blank(r.notes)) {
            await db.query(
                `insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes)
                 values ($1, coalesce($2, $3), 'CALL', now(), $4)`, [leadId, blank(r.assigned_to), me, r.notes]);
        }
    } else {
        const customerId = blank(r.lead_id)
            ? (await db.query('select customer_id from crm.lead where lead_id = $1', [r.lead_id])).rows[0]?.customer_id
            : await customerFor(db, r.customer_mobile, r.customer_name, branch.branch_id, me);
        if (blank(r.lead_id) && !customerId) throw new Error(`Unknown lead_id ${r.lead_id}`);
        await db.query(
            `insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, sold_by, net_value)
             values ($1, $2, $3, $4, $5, $6, $7)`,
            [r.invoice_no, branch.branch_id, r.invoice_date, customerId, blank(r.lead_id), blank(r.sold_by), r.net_value]);
    }
}

// Every row is checked; nothing is saved unless all rows pass and "Import" was chosen.
router.post('/import', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const type = IMPORTS[req.body.type] ? req.body.type : 'leads';
    const csv = String(req.body.csv || '');
    const { header, records } = parseCsv(csv);
    const missing = IMPORTS[type].filter((c) => !header.includes(c));
    const result = { total: records.length, ok: 0, errors: [], saved: false, missing };
    if (!missing.length && records.length) {
        await asUser(req.user.employee_id, async (db) => {
            await db.query('savepoint import_all');
            for (const [i, r] of records.entries()) {
                await db.query('savepoint import_row');
                try {
                    await importRow(db, type, r, req.user.employee_id);
                    await db.query('release savepoint import_row');
                    result.ok += 1;
                } catch (err) {
                    await db.query('rollback to savepoint import_row');
                    result.errors.push({ line: i + 2, message: (err.code && dbMessage(err)) || err.message });
                }
            }
            if (req.body.mode === 'import' && !result.errors.length) result.saved = true;
            else await db.query('rollback to savepoint import_all');
        });
    }
    res.render('admin/import', { title: 'Import data', IMPORTS, result, type, csv: result.saved ? '' : csv });
});

export default router;
