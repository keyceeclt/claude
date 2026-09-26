import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { act, blank } from '../helpers.js';

const router = Router();
router.param('id', (req, res, next, id) => (/^\d+$/.test(id)
    ? next()
    : res.status(404).render('error', { title: 'Not found', message: 'This page does not exist.' })));

router.get('/', async (req, res) => {
    const q = blank(req.query.q);
    const rows = await asUser(req.user.employee_id, async (db) => {
        const digits = q ? q.replace(/\D/g, '') : '';
        return (await db.query(
            `select c.*, (select count(*) from crm.lead l where l.customer_id = c.customer_id) as leads,
                    (select coalesce(sum(net_value), 0) from crm.sale s where s.customer_id = c.customer_id) as sales_value
             from crm.customer c
             where $1::text is null or lower(c.customer_name) like '%' || lower($1) || '%'
                   or ($2 <> '' and c.mobile like '%' || $2 || '%')
             order by c.created_at desc limit 100`, [q, digits])).rows;
    });
    res.render('customers/list', { title: 'Customers', q, rows });
});

router.get('/:id', async (req, res) => {
    const data = await asUser(req.user.employee_id, async (db) => {
        const customer = (await db.query('select * from crm.customer where customer_id = $1', [req.params.id])).rows[0];
        if (!customer) return null;
        const q = async (sql) => (await db.query(sql, [req.params.id])).rows;
        return {
            customer,
            L: await loadLookups(db),
            leads: await q('select * from crm.v_lead_status where customer_id = $1 order by created_at desc'),
            sales: await q('select * from crm.sale where customer_id = $1 order by invoice_date desc'),
            visits: await q('select * from crm.store_visit where customer_id = $1 order by visit_at desc'),
        };
    });
    if (!data) return res.status(404).render('error', { title: 'Customer not found', message: 'This customer does not exist, or you do not have access.' });
    res.render('customers/show', { title: data.customer.customer_name || data.customer.mobile, ...data });
});

router.post('/:id', async (req, res) => {
    const b = req.body;
    await act(res, `/customers/${req.params.id}`, () => asUser(req.user.employee_id, async (db) => {
        const { rowCount } = await db.query(
            `update crm.customer set customer_name = $2, alt_mobile = $3, email = $4, area = $5, city = $6,
                    district = $7, segment = $8, marketing_consent = $9
             where customer_id = $1`,
            [req.params.id, blank(b.customer_name), blank(b.alt_mobile), blank(b.email), blank(b.area), blank(b.city),
             blank(b.district), blank(b.segment), b.marketing_consent === '' || b.marketing_consent === undefined ? null : b.marketing_consent === 'yes']);
        if (!rowCount) throw Object.assign(new Error('denied'), { code: '42501' });
        return `/customers/${req.params.id}?msg=Customer updated.`;
    }));
});

export default router;
