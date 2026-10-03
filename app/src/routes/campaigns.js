import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { act, blank } from '../helpers.js';
import { requireConfig } from '../auth.js';

const router = Router();

router.get('/', async (req, res) => {
    const data = await asUser(req.user, async (db) => ({
        rows: (await db.query('select * from crm.v_campaign_performance order by start_date desc')).rows,
        L: await loadLookups(db),
    }));
    res.render('campaigns/list', { title: 'Campaigns', ...data });
});

router.post('/', requireConfig, async (req, res) => {
    const b = req.body;
    await act(res, '/campaigns', () => asUser(req.user, async (db) => {
        await db.query(
            `insert into crm.campaign (campaign_code, campaign_name, source_code, branch_id, start_date, end_date, budget, actual_spend, objective)
             values ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
            [blank(b.campaign_code), b.campaign_name, b.source_code, blank(b.branch_id), b.start_date, blank(b.end_date),
             blank(b.budget), blank(b.actual_spend), blank(b.objective)]);
        return '/campaigns?msg=Campaign created.';
    }));
});

router.post('/:id/spend', requireConfig, async (req, res) => {
    await act(res, '/campaigns', () => asUser(req.user, async (db) => {
        await db.query('update crm.campaign set actual_spend = $2, end_date = coalesce($3, end_date) where campaign_id = $1',
            [req.params.id, blank(req.body.actual_spend), blank(req.body.end_date)]);
        return '/campaigns?msg=Campaign updated.';
    }));
});

export default router;
