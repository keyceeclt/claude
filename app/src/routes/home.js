import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { todayIST, monthStartIST } from '../helpers.js';

const router = Router();

router.get('/', async (req, res) => {
    const owner = typeof req.query.owner === 'string' && req.query.owner ? req.query.owner : null;
    const data = await asUser(req.user.employee_id, async (db) => {
        const L = await loadLookups(db);
        const ownerFilter = owner ? 'and assigned_to = $1' : 'and ($1::text is null)';
        const followups = (await db.query(
            `select * from crm.v_my_followups
             where (followup_status = 'OVERDUE' or due_on <= $2::date) ${ownerFilter.replace('assigned_to', 'employee_id')}
             order by due_at limit 200`, [owner, todayIST()])).rows;
        const attentionLeads = (await db.query(
            `select ls.lead_id, ls.assigned_to, ls.branch_id, ls.stage_code, ls.product_category, ls.created_at,
                    ls.attention_reason, ls.days_since_activity, c.customer_name, c.mobile
             from crm.v_lead_status ls join crm.customer c on c.customer_id = ls.customer_id
             where ls.attention_reason in ('NOT_CONTACTED_WITHIN_SLA', 'NO_NEXT_FOLLOWUP', 'STALE') ${ownerFilter}
             order by case ls.attention_reason when 'NOT_CONTACTED_WITHIN_SLA' then 1 when 'NO_NEXT_FOLLOWUP' then 2 else 3 end,
                      ls.created_at
             limit 200`, [owner])).rows;
        const today = (await db.query(
            `select coalesce(sum(new_leads), 0) as new_leads, coalesce(sum(leads_reached), 0) as leads_reached,
                    coalesce(sum(sales_count), 0) as sales_count, coalesce(sum(sales_value), 0) as sales_value
             from crm.v_daily_mis where mis_date = $1::date`, [todayIST()])).rows[0];
        const month = (await db.query(
            `select coalesce(sum(sales_value), 0) as sales_value, sum(target_sales_value) as target_sales_value,
                    coalesce(sum(cohort_won), 0) as won, coalesce(sum(qualified_leads), 0) as qualified
             from crm.v_staff_performance_monthly where month = $1::date
               and ($2::text is null or employee_id = $2)`,
            [monthStartIST(), req.user.data_scope === 'OWN' ? req.user.employee_id : owner])).rows[0];
        return { L, followups, attentionLeads, today, month };
    });
    res.render('home', { title: 'My Day', owner, ...data });
});

export default router;
