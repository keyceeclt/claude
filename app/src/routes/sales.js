import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { act, blank, market } from '../helpers.js';
import { requireScope } from '../auth.js';

const router = Router();

router.get('/sales', async (req, res) => {
    const from = blank(req.query.from) || `${market(req.user).today().slice(0, 7)}-01`;
    const to = blank(req.query.to) || market(req.user).today();
    const branch = blank(req.query.branch);
    const data = await asUser(req.user, async (db) => {
        const rows = (await db.query(
            `select s.*, c.customer_name, c.mobile from crm.sale s
             left join crm.customer c on c.customer_id = s.customer_id
             where s.invoice_date between $1 and $2 and ($3::smallint is null or s.branch_id = $3)
             order by s.invoice_date desc, s.sale_id desc limit 500`, [from, to, branch])).rows;
        return { rows, L: await loadLookups(db) };
    });
    res.render('sales/list', { title: 'Sales', from, to, branch, ...data });
});

router.get('/sales/new', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const leadId = blank(req.query.lead_id);
    const data = await asUser(req.user, async (db) => {
        const lead = leadId ? (await db.query(
            `select l.lead_id, l.branch_id, l.assigned_to, c.customer_name, c.mobile from crm.lead l
             join crm.customer c on c.customer_id = l.customer_id where l.lead_id = $1`, [leadId])).rows[0] : null;
        const quotations = leadId ? (await db.query(
            "select * from crm.quotation where lead_id = $1 and status = 'OPEN' order by quoted_on desc", [leadId])).rows : [];
        return { lead, quotations, L: await loadLookups(db) };
    });
    res.render('sales/new', { title: 'Record sale', ...data });
});

router.post('/sales', requireScope('ALL', 'BRANCH'), async (req, res) => {
    const b = req.body;
    const back = b.lead_id ? `/sales/new?lead_id=${encodeURIComponent(b.lead_id)}` : '/sales/new';
    await act(res, back, () => asUser(req.user, async (db) => {
        let customerId = null;
        let branchId = req.user.data_scope === 'ALL' ? blank(b.branch_id) : req.user.branch_id;
        const leadId = blank(b.lead_id);
        if (leadId) {
            const lead = (await db.query('select customer_id, branch_id from crm.lead where lead_id = $1', [leadId])).rows[0];
            if (!lead) throw Object.assign(new Error('denied'), { code: '42501' });
            customerId = lead.customer_id;
        } else if (blank(b.mobile)) {
            customerId = (await db.query('select customer_id from crm.find_customer_by_mobile($1)', [b.mobile])).rows[0]?.customer_id;
            if (!customerId) {
                customerId = (await db.query(
                    `insert into crm.customer (customer_name, mobile, home_branch_id, created_by)
                     values ($1, $2, $3, $4) returning customer_id`,
                    [blank(b.customer_name), b.mobile, branchId, req.user.employee_id])).rows[0].customer_id;
            }
        }
        const saleId = (await db.query(
            `insert into crm.sale (invoice_no, branch_id, invoice_date, customer_id, lead_id, quotation_id, sold_by, net_value)
             values ($1, $2, $3, $4, $5, $6, $7, $8) returning sale_id`,
            [b.invoice_no, branchId, b.invoice_date, customerId, leadId, blank(b.quotation_id), blank(b.sold_by), b.net_value])).rows[0].sale_id;
        const cats = [].concat(b.item_category || []);
        let line = 0;
        for (let i = 0; i < cats.length; i += 1) {
            const value = blank([].concat(b.item_value || [])[i]);
            if (!blank(cats[i]) && !value) continue;
            line += 1;
            await db.query(
                `insert into crm.sale_item (sale_id, line_no, product_category, model_code, quantity, line_value)
                 values ($1, $2, $3, $4, $5, $6)`,
                [saleId, line, blank(cats[i]), blank([].concat(b.item_model || [])[i]),
                 blank([].concat(b.item_qty || [])[i]) || 1, value || 0]);
        }
        if (blank(b.quotation_id)) {
            await db.query("update crm.quotation set status = 'ACCEPTED' where quotation_id = $1", [b.quotation_id]);
        }
        return leadId ? `/leads/${leadId}?msg=Sale recorded. The lead is now Won.` : '/sales?msg=Sale recorded.';
    }));
});

router.get('/visits/new', async (req, res) => {
    const L = await asUser(req.user, loadLookups);
    res.render('sales/visit', { title: 'Walk-in visit', L });
});

// A walk-in visit; optionally opens a lead at the same time.
router.post('/visits', async (req, res) => {
    const b = req.body;
    await act(res, '/visits/new', () => asUser(req.user, async (db) => {
        const branchId = req.user.data_scope === 'ALL' ? blank(b.branch_id) : req.user.branch_id;
        let customerId = (await db.query('select customer_id from crm.find_customer_by_mobile($1)', [b.mobile])).rows[0]?.customer_id;
        if (!customerId) {
            customerId = (await db.query(
                `insert into crm.customer (customer_name, mobile, home_branch_id, created_by)
                 values ($1, $2, $3, $4) returning customer_id`,
                [blank(b.customer_name), b.mobile, branchId, req.user.employee_id])).rows[0].customer_id;
        }
        let leadId = null;
        if (b.create_lead === 'yes') {
            leadId = (await db.query(
                `insert into crm.lead (customer_id, branch_id, assigned_to, source_code, product_category, product_interest, created_by)
                 values ($1, $2, $3, $4, $5, $6, $3) returning lead_id`,
                [customerId, branchId, req.user.employee_id, b.source_code || 'WALK_IN', blank(b.product_category),
                 blank(b.product_interest)])).rows[0].lead_id;
        }
        await db.query(
            `insert into crm.store_visit (customer_id, lead_id, branch_id, visit_at, attended_by, notes)
             values ($1, $2, $3, coalesce($4::timestamptz, now()), $5, $6)`,
            [customerId, leadId, branchId, market(req.user).localTimestamp(b.visit_at), req.user.employee_id, blank(b.notes)]);
        return leadId ? `/leads/${leadId}?msg=Visit recorded and lead opened. Schedule the follow-up.` : '/visits/new?msg=Walk-in visit recorded.';
    }));
});

export default router;
