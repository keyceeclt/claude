import { Router } from 'express';
import { asUser } from '../db.js';
import { act, blank } from '../helpers.js';
import { requireConfig } from '../auth.js';
import { getLlm, MODEL } from '../agents/llm.js';
import { runFollowupWriter, runLeadRescue, runAllBriefs, LANGUAGES } from '../agents/agents.js';

const router = Router();

router.param('id', (req, res, next, id) => (/^\d+$/.test(id)
    ? next()
    : res.status(404).render('error', { title: 'Not found', message: 'This page does not exist.' })));

const safeBack = (v, fallback) => (typeof v === 'string' && v.startsWith('/') && !v.startsWith('//') ? v : fallback);
const denied = () => Object.assign(new Error('denied'), { code: '42501' });
const fail = (message) => Object.assign(new Error(message), { code: 'P0001' });

export function aiAvailable(user) {
    return Boolean(getLlm() && user?.ai_enabled);
}

// ------------------------------------------------------------------ Follow-up Writer
router.post('/leads/:id/draft', async (req, res) => {
    const back = `/leads/${req.params.id}`;
    if (!aiAvailable(req.user)) return res.redirect(`${back}?err=${encodeURIComponent('AI agents are not switched on for your company.')}#ai`);
    if (!req.user.can_write) return res.status(403).render('error', { title: 'Not allowed', message: 'Your access level is read-only.' });
    const lead = await asUser(req.user, async (db) => (await db.query(
        'select lead_id, branch_id from crm.lead where lead_id = $1', [req.params.id])).rows[0]);
    if (!lead) return res.status(404).render('error', { title: 'Lead not found', message: 'This lead does not exist, or it is not assigned to you.' });
    const result = await runFollowupWriter(req.user.tenant_id, {
        leadId: lead.lead_id, branchId: lead.branch_id, requestedBy: req.user.employee_id,
        language: req.body.language, goal: blank(req.body.goal),
    });
    const q = result.status === 'DONE' ? `msg=${encodeURIComponent('Draft ready. Review it before sending.')}`
        : `err=${encodeURIComponent(`No draft: ${result.note}`)}`;
    res.redirect(`${back}?${q}#ai`);
});

// ------------------------------------------------------------------ act on suggestions
router.post('/suggestions/:id/accept', async (req, res) => {
    const back = safeBack(req.body.back, '/');
    await act(res, back, () => asUser(req.user, async (db) => {
        const s = (await db.query(
            "select * from crm.agent_suggestion where suggestion_id = $1 and status = 'OPEN' and kind = 'FOLLOWUP'",
            [req.params.id])).rows[0];
        if (!s) throw denied();
        const owner = req.user.data_scope === 'OWN' ? req.user.employee_id : s.assigned_to || req.user.employee_id;
        const activityId = (await db.query(
            `insert into crm.lead_activity (lead_id, employee_id, activity_type, due_at, notes)
             values ($1, $2, $3, greatest($4::timestamptz, now()), $5) returning activity_id`,
            [s.lead_id, owner, s.activity_type, s.suggested_due_at, `AI suggestion: ${s.reason}`])).rows[0].activity_id;
        const { rowCount } = await db.query(
            `update crm.agent_suggestion set status = 'ACCEPTED', activity_id = $2, decided_by = $3, decided_at = now()
             where suggestion_id = $1`, [s.suggestion_id, activityId, req.user.employee_id]);
        if (!rowCount) throw denied();
        return `${back.split('?')[0]}?msg=${encodeURIComponent('Follow-up scheduled.')}`;
    }));
});

for (const [action, from, to, kind, msg] of [
    ['dismiss', 'OPEN', 'DISMISSED', null, 'Suggestion dismissed.'],
    ['used', 'OPEN', 'ACCEPTED', 'MESSAGE', 'Marked as sent. Log the contact when the customer replies.'],
]) {
    router.post(`/suggestions/:id/${action}`, async (req, res) => {
        const back = safeBack(req.body.back, '/');
        await act(res, back, () => asUser(req.user, async (db) => {
            const { rowCount } = await db.query(
                `update crm.agent_suggestion set status = $2, decided_by = $3, decided_at = now()
                 where suggestion_id = $1 and status = $4 and ($5::text is null or kind = $5)`,
                [req.params.id, to, req.user.employee_id, from, kind]);
            if (!rowCount) throw denied();
            return `${back.split('?')[0]}?msg=${encodeURIComponent(msg)}`;
        }));
    });
}

router.post('/suggestions/:id/undo', async (req, res) => {
    const back = safeBack(req.body.back, '/');
    await act(res, back, () => asUser(req.user, async (db) => {
        await db.query('select crm.undo_agent_followup($1)', [req.params.id]);
        return `${back.split('?')[0]}?msg=${encodeURIComponent('The AI follow-up was removed.')}`;
    }));
});

// ------------------------------------------------------------------ settings and usage (admins)
router.get('/settings', requireConfig, async (req, res) => {
    const data = await asUser(req.user, async (db) => ({
        company: (await db.query('select * from crm.tenant')).rows[0],
        spend: (await db.query('select crm.ai_spend_this_month() as s')).rows[0].s,
        usage: (await db.query('select * from crm.v_ai_usage_monthly order by month desc, agent limit 24')).rows,
        outcomes: (await db.query(
            `select o.*, b.name as branch_name from crm.v_agent_suggestion_outcomes o
             left join crm.branch b on b.branch_id = o.branch_id order by month desc, branch_name, kind limit 36`)).rows,
        runs: (await db.query(
            `select r.*, e.employee_name as requested_by_name from crm.agent_run r
             left join crm.employee e on e.tenant_id = r.tenant_id and e.employee_id = r.requested_by
             order by r.started_at desc limit 20`)).rows,
    }));
    res.render('ai/settings', { title: 'AI agents', serviceReady: Boolean(getLlm()), model: MODEL, ...data });
});

router.post('/settings', requireConfig, async (req, res) => {
    await act(res, '/ai/settings', () => asUser(req.user, async (db) => {
        const budget = Number(req.body.budget);
        if (!Number.isFinite(budget) || budget < 0) throw fail('Enter a monthly budget of 0 or more.');
        const { rowCount } = await db.query(
            'update crm.tenant set ai_enabled = $1, ai_monthly_budget_usd = $2, ai_auto_schedule = $3',
            [req.body.enabled === 'yes', budget, req.body.auto_schedule === 'yes']);
        if (!rowCount) throw denied();
        return '/ai/settings?msg=Saved.';
    }));
});

router.post('/run/:agent', requireConfig, async (req, res) => {
    if (!aiAvailable(req.user)) return res.redirect(`/ai/settings?err=${encodeURIComponent('Switch AI agents on first (and make sure the server has an AI key).')}`);
    let note;
    if (req.params.agent === 'rescue') {
        const r = await runLeadRescue(req.user.tenant_id);
        note = r.status === 'DONE' ? `Lead Rescue: ${r.items} suggestions${r.scheduled ? `, ${r.scheduled} follow-ups scheduled` : ''}.`
            : `Lead Rescue ${r.status.toLowerCase()}: ${r.note}`;
    } else if (req.params.agent === 'brief') {
        const branches = await asUser(req.user, async (db) => (await db.query(
            'select branch_id from crm.branch where is_active order by branch_id')).rows.map((b) => b.branch_id));
        const rs = await runAllBriefs(req.user.tenant_id, branches, req.user.employee_id);
        const bad = rs.find((r) => r.status !== 'DONE');
        note = bad ? `Daily brief ${bad.status.toLowerCase()}: ${bad.note}` : `Daily brief written for ${rs.length - 1} branches and the company.`;
    } else {
        return res.status(404).render('error', { title: 'Not found', message: 'No such agent.' });
    }
    res.redirect(`/ai/settings?msg=${encodeURIComponent(note)}`);
});

export { LANGUAGES };
export default router;
