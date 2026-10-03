import { Router } from 'express';
import { asUser } from '../db.js';
import { loadLookups } from '../lookups.js';
import { blank, market } from '../helpers.js';

const router = Router();

const isDate = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v);

function page(view, title, load) {
    return async (req, res) => {
        const data = await asUser(req.user, async (db) => ({ ...(await load(db, req)), L: await loadLookups(db) }));
        res.render(`reports/${view}`, { title, ...data });
    };
}

router.get('/', (req, res) => res.redirect('/reports/daily'));

router.get('/daily', page('daily', 'Daily MIS', async (db, req) => {
    const date = isDate(req.query.date) ? req.query.date : market(req.user).today();
    // Branch staff see their own branch column only (other branches would show as zeros).
    const branch = req.user.data_scope === 'ALL' ? null : req.user.branch_id;
    const rows = (await db.query(
        'select * from crm.v_daily_mis where mis_date = $1 and ($2::smallint is null or branch_id = $2) order by branch_id',
        [date, branch])).rows;
    const week = (await db.query(
        `select mis_date, sum(new_leads) as new_leads, sum(leads_reached) as leads_reached,
                sum(followups_due) as followups_due, sum(followups_on_time) as followups_on_time,
                sum(sales_count) as sales_count, sum(sales_value) as sales_value,
                sum(lead_sales_value) as lead_sales_value, sum(walk_in_sales_value) as walk_in_sales_value
         from crm.v_daily_mis where mis_date between $1::date - 6 and $1::date
         group by mis_date order by mis_date`, [date])).rows;
    const attention = (await db.query(
        `select branch_id, attention_reason, count(*) as n from crm.v_lead_status
         where attention_reason is not null group by 1, 2 order by 1, 2`)).rows;
    return { date, rows, week, attentionRows: attention };
}));

router.get('/funnel', page('funnel', 'Monthly funnel', async (db) => ({
    rows: (await db.query(
        `select * from crm.v_branch_funnel_monthly
         where month >= (date_trunc('month', crm.local_date(now())) - interval '5 months')
         order by month desc, branch_id`)).rows,
    sources: (await db.query(
        `select * from crm.v_source_performance_monthly
         where month >= (date_trunc('month', crm.local_date(now())) - interval '2 months')
         order by month desc, branch_id, leads desc`)).rows,
})));

router.get('/staff', page('staff', 'Staff performance', async (db, req) => {
    const m = typeof req.query.m === 'string' && /^\d{4}-\d{2}$/.test(req.query.m) ? `${req.query.m}-01` : null;
    const month = m || market(req.user).monthStart();
    return {
        month,
        rows: (await db.query(
            'select * from crm.v_staff_performance_monthly where month = $1 order by branch_id nulls first, sales_value desc',
            [month])).rows,
    };
}));

router.get('/ageing', page('ageing', 'Pipeline ageing', async (db, req) => {
    const branch = blank(req.query.branch);
    return {
        branch,
        rows: (await db.query(
            `select age_bucket, sum(open_leads) as open_leads, sum(stated_budget_value) as stated_budget_value,
                    sum(not_contacted_within_sla) as not_contacted_within_sla, sum(followup_overdue) as followup_overdue,
                    sum(no_next_followup) as no_next_followup, sum(stale) as stale
             from crm.v_open_lead_ageing where $1::smallint is null or branch_id = $1
             group by age_bucket
             order by array_position(array['0-2 days','3-7 days','8-15 days','16-30 days','30+ days'], age_bucket)`,
            [branch])).rows,
        byOwner: (await db.query(
            `select assigned_to, branch_id, sum(open_leads) as open_leads,
                    sum(not_contacted_within_sla + followup_overdue + no_next_followup + stale) as needing_action
             from crm.v_open_lead_ageing where $1::smallint is null or branch_id = $1
             group by 1, 2 order by needing_action desc`, [branch])).rows,
    };
}));

router.get('/data-quality', page('data-quality', 'Data quality', async (db) => ({
    summary: (await db.query(
        `select issue_code, severity, count(*) as n from crm.v_data_quality_issues
         group by 1, 2 order by case severity when 'HIGH' then 1 when 'MEDIUM' then 2 else 3 end, n desc`)).rows,
    rows: (await db.query(
        `select * from crm.v_data_quality_issues
         order by case severity when 'HIGH' then 1 when 'MEDIUM' then 2 else 3 end, issue_code limit 300`)).rows,
    gaps: (await db.query('select * from crm.v_setup_gaps order by config_table, item')).rows,
})));

export default router;
