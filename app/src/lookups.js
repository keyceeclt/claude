// Pick-lists for forms and labels, read as the signed-in user.
export async function loadLookups(db) {
    const q = [
        'select category, code, label, is_active from crm.lookup_value order by category, sort_order, label',
        'select * from crm.lead_stage order by stage_order',
        'select * from crm.lead_source order by source_name',
        'select * from crm.activity_outcome order by customer_reached desc, label',
        'select * from crm.branch order by branch_id',
        `select employee_id, employee_name, branch_id, crm_access_level = 'AI_AGENT' as is_agent,
                         (exit_date is null or exit_date > crm.local_date(now())) as is_active
                  from crm.employee order by employee_name`,
        `select campaign_id, campaign_name, source_code, branch_id, start_date, end_date
                  from crm.campaign order by start_date desc`,
        'select * from crm.access_level order by sort_order',
    ];
    // One connection runs one query at a time, so run them in sequence.
    const results = [];
    for (const sql of q) results.push(await db.query(sql));
    const [lv, stages, sources, outcomes, branches, employees, campaigns, levels] = results;
    const list = {};
    const label = {};
    for (const r of lv.rows) {
        (list[r.category] ||= []).push(r);
        label[`${r.category}:${r.code}`] = r.label;
    }
    const byCode = (rows, key) => Object.fromEntries(rows.map((r) => [r[key], r]));
    return {
        list,
        label: (category, code) => (code ? label[`${category}:${code}`] || code : '—'),
        active: (category) => (list[category] || []).filter((r) => r.is_active),
        stages: stages.rows,
        stage: byCode(stages.rows, 'code'),
        sources: sources.rows,
        source: byCode(sources.rows, 'source_code'),
        outcomes: outcomes.rows,
        outcome: byCode(outcomes.rows, 'code'),
        branches: branches.rows,
        branch: byCode(branches.rows, 'branch_id'),
        // People only: the AI agent is never offered as an owner or manager.
        employees: employees.rows.filter((e) => !e.is_agent),
        employee: byCode(employees.rows, 'employee_id'),
        campaigns: campaigns.rows,
        levels: levels.rows,
        assignableLevels: levels.rows.filter((a) => a.code !== 'AI_AGENT'),
    };
}
