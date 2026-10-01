import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { act, blank, market } from '../helpers.js';
import { requireScope } from '../auth.js';
import { aiAvailable, LANGUAGES } from './ai.js';

const router = Router();
const PAGE = 100;

router.param('id', (req, res, next, id) => (/^\d+$/.test(id)
    ? next()
    : res.status(404).render('error', { title: 'Not found', message: 'This page does not exist.' })));

router.get('/', async (req, res) => {
    const f = {
        status: ['open', 'closed', 'all'].includes(req.query.status) ? req.query.status : 'open',
        stage: blank(req.query.stage), branch: blank(req.query.branch), owner: blank(req.query.owner),
        source: blank(req.query.source), attention: blank(req.query.attention), q: blank(req.query.q),
        page: Math.max(1, parseInt(req.query.page, 10) || 1),
    };
    const data = await asUser(req.user, async (db) => {
        const L = await loadLookups(db);
        const where = [];
        const args = [];
        const add = (sql, v) => { args.push(v); where.push(sql.replace('?', `$${args.length}`)); };
        if (f.status === 'open') where.push('not ls.is_closed');
        if (f.status === 'closed') where.push('ls.is_closed');
        if (f.stage) add('ls.stage_code = ?', f.stage);
        if (f.branch) add('ls.branch_id = ?::smallint', f.branch);
        if (f.owner) add('ls.assigned_to = ?', f.owner);
        if (f.source) add('ls.source_code = ?', f.source);
        if (f.attention === 'any') where.push('ls.attention_reason is not null');
        else if (f.attention) add('ls.attention_reason = ?', f.attention);
        if (f.q) {
            args.push(`%${f.q.toLowerCase()}%`);
            args.push(f.q.replace(/\D/g, '').replace(/^(91|0)(?=[6-9]\d{9}$)/, '') || '~');
            where.push(`(lower(c.customer_name) like $${args.length - 1} or c.mobile like '%' || $${args.length} || '%')`);
        }
        args.push(PAGE + 1, (f.page - 1) * PAGE);
        const rows = (await db.query(
            `select ls.*, c.customer_name, c.mobile
             from crm.v_lead_status ls join crm.customer c on c.customer_id = ls.customer_id
             ${where.length ? `where ${where.join(' and ')}` : ''}
             order by ls.created_at desc
             limit $${args.length - 1} offset $${args.length}`, args)).rows;
        return { L, rows: rows.slice(0, PAGE), more: rows.length > PAGE };
    });
    res.render('leads/list', { title: 'Leads', f, ...data });
});

router.get('/new', async (req, res) => {
    const L = await asUser(req.user, loadLookups);
    let customer = null;
    const mobile = blank(req.query.mobile);
    if (mobile) {
        customer = await asUser(req.user, async (db) =>
            (await db.query('select * from crm.find_customer_by_mobile($1)', [mobile])).rows[0] || false);
    }
    res.render('leads/new', { title: 'New lead', L, mobile, customer });
});

router.post('/', async (req, res) => {
    const b = req.body;
    const back = `/leads/new?mobile=${encodeURIComponent(b.mobile || '')}`;
    await act(res, back, () => asUser(req.user, async (db) => {
        const branchId = req.user.data_scope === 'ALL' ? blank(b.branch_id) : req.user.branch_id;
        let customerId = (await db.query('select customer_id from crm.find_customer_by_mobile($1)', [b.mobile])).rows[0]?.customer_id;
        if (!customerId) {
            customerId = (await db.query(
                `insert into crm.customer (customer_name, mobile, area, home_branch_id, created_by)
                 values ($1, $2, $3, $4, $5) returning customer_id`,
                [blank(b.customer_name), b.mobile, blank(b.area), branchId, req.user.employee_id])).rows[0].customer_id;
        }
        const assigned = req.user.data_scope === 'OWN' ? req.user.employee_id : blank(b.assigned_to) || req.user.employee_id;
        const leadId = (await db.query(
            `insert into crm.lead (customer_id, branch_id, assigned_to, source_code, campaign_id, product_category,
                                   product_interest, budget_value, expected_purchase_on, created_by)
             values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning lead_id`,
            [customerId, branchId, assigned, b.source_code, blank(b.campaign_id), blank(b.product_category),
             blank(b.product_interest), blank(b.budget_value), blank(b.expected_purchase_on), req.user.employee_id])).rows[0].lead_id;
        const due = market(req.user).localTimestamp(b.first_followup_at);
        if (due) {
            await db.query(
                `insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes)
                 values ($1, $2, $3, $4, $5)`,
                [leadId, assigned, b.followup_type || 'CALL', due, blank(b.notes)]);
        }
        return `/leads/${leadId}?msg=Lead created.`;
    }));
});

async function loadLead(db, id) {
    const lead = (await db.query(
        `select ls.*, l.product_interest, l.expected_purchase_on, l.lost_reason, l.created_by,
                c.customer_name, c.mobile, c.alt_mobile, c.area, c.email, c.segment, c.customer_id
         from crm.v_lead_status ls
         join crm.lead l on l.lead_id = ls.lead_id
         join crm.customer c on c.customer_id = ls.customer_id
         where ls.lead_id = $1`, [id])).rows[0];
    if (!lead) return null;
    const q = async (sql) => (await db.query(sql, [id])).rows;
    return {
        lead,
        activities: await q(`select a.*, f.followup_status from crm.lead_activity a
                             left join crm.v_followup_status f on f.activity_id = a.activity_id
                             where a.lead_id = $1 order by coalesce(a.completed_at, a.due_at) desc`),
        history: await q('select * from crm.lead_stage_history where lead_id = $1 order by changed_at desc'),
        visits: await q('select * from crm.store_visit where lead_id = $1 order by visit_at desc'),
        quotations: await q('select * from crm.quotation where lead_id = $1 order by quoted_on desc'),
        sales: await q('select * from crm.sale where lead_id = $1 order by invoice_date desc'),
        suggestions: await q(`select * from crm.agent_suggestion where lead_id = $1
                              and (kind = 'FOLLOWUP' or status = 'OPEN') order by created_at desc limit 10`),
        otherLeads: await q(`select l.lead_id, l.stage_code, l.created_at, l.branch_id from crm.lead l
                             where l.customer_id = (select customer_id from crm.lead where lead_id = $1) and l.lead_id <> $1
                             order by l.created_at desc`),
    };
}

router.get('/:id', async (req, res) => {
    const data = await asUser(req.user, async (db) => {
        const d = await loadLead(db, req.params.id);
        return d && { ...d, L: await loadLookups(db) };
    });
    if (!data) return res.status(404).render('error', { title: 'Lead not found', message: 'This lead does not exist, or it is not assigned to you.' });
    res.render('leads/show', { title: `Lead #${req.params.id}`, aiOn: aiAvailable(req.user), LANGUAGES, ...data });
});

// Log a contact. It closes the lead's oldest pending follow-up (so on-time
// discipline is measured) and schedules the next one.
router.post('/:id/activity', async (req, res) => {
    const id = req.params.id;
    const b = req.body;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        const pending = (await db.query(
            `select activity_id from crm.lead_activity where lead_id = $1 and completed_at is null
             order by due_at limit 1`, [id])).rows[0];
        if (pending && b.close_pending !== 'no') {
            await db.query(
                `update crm.lead_activity set completed_at = now(), outcome = $2, activity_type = $3,
                        notes = coalesce($4, notes), employee_id = $5
                 where activity_id = $1`,
                [pending.activity_id, b.outcome, b.activity_type, blank(b.notes), req.user.employee_id]);
        } else {
            await db.query(
                `insert into crm.lead_activity (lead_id, employee_id, activity_type, completed_at, outcome, notes)
                 values ($1, $2, $3, now(), $4, $5)`,
                [id, req.user.employee_id, b.activity_type, b.outcome, blank(b.notes)]);
        }
        const next = market(req.user).localTimestamp(b.next_followup_at);
        if (next) {
            await db.query(
                `insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes)
                 values ($1, $2, $3, $4, $5)`,
                [id, req.user.employee_id, b.next_type || 'CALL', next, blank(b.next_notes)]);
        }
        return `/leads/${id}?msg=Activity saved.`;
    }));
});

router.post('/:id/followup', async (req, res) => {
    const id = req.params.id;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        await db.query(
            `insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes)
             values ($1, $2, $3, $4, $5)`,
            [id, req.user.employee_id, req.body.activity_type || 'CALL', market(req.user).localTimestamp(req.body.due_at), blank(req.body.notes)]);
        return `/leads/${id}?msg=Follow-up scheduled.`;
    }));
});

router.post('/:id/stage', async (req, res) => {
    const id = req.params.id;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        const { rowCount } = await db.query(
            'update crm.lead set stage_code = $2, lost_reason = $3 where lead_id = $1',
            [id, req.body.stage_code, blank(req.body.lost_reason)]);
        if (!rowCount) throw Object.assign(new Error('denied'), { code: '42501' });
        return `/leads/${id}?msg=Stage updated.`;
    }));
});

router.post('/:id/assign', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const id = req.params.id;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        const { rowCount } = await db.query('update crm.lead set assigned_to = $2 where lead_id = $1', [id, req.body.assigned_to]);
        if (!rowCount) throw Object.assign(new Error('denied'), { code: '42501' });
        await db.query(
            'update crm.lead_activity set employee_id = $2 where lead_id = $1 and completed_at is null',
            [id, req.body.assigned_to]);
        return `/leads/${id}?msg=Lead reassigned.`;
    }));
});

router.post('/:id/visit', async (req, res) => {
    const id = req.params.id;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        const l = (await db.query('select customer_id, branch_id from crm.lead where lead_id = $1', [id])).rows[0];
        await db.query(
            `insert into crm.store_visit (customer_id, lead_id, branch_id, visit_at, attended_by, notes)
             values ($1, $2, $3, coalesce($4::timestamptz, now()), $5, $6)`,
            [l.customer_id, id, l.branch_id, market(req.user).localTimestamp(req.body.visit_at), req.user.employee_id, blank(req.body.notes)]);
        return `/leads/${id}?msg=Store visit recorded.`;
    }));
});

router.post('/:id/quotation', async (req, res) => {
    const id = req.params.id;
    const b = req.body;
    await act(res, `/leads/${id}`, () => asUser(req.user, async (db) => {
        const l = (await db.query('select customer_id, branch_id from crm.lead where lead_id = $1', [id])).rows[0];
        await db.query(
            `insert into crm.quotation (quotation_no, customer_id, lead_id, branch_id, prepared_by, quoted_on, valid_until, total_value)
             values ($1, $2, $3, $4, $5, coalesce($6::date, crm.local_date(now())), $7, $8)`,
            [blank(b.quotation_no), l.customer_id, id, l.branch_id, req.user.employee_id,
             blank(b.quoted_on), blank(b.valid_until), b.total_value]);
        return `/leads/${id}?msg=Quotation recorded.`;
    }));
});

export default router;
