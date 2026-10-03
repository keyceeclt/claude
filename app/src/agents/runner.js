// Runs one agent job for one company, as that company's AI-AGENT employee.
//
//   1. Check the company has agents on and budget left; log the run.
//   2. Gather facts from the CRM (through row-level security, like any user).
//   3. Ask the model (outside any database transaction).
//   4. Save suggestions / briefs and record tokens and cost on the run.
import { asUser } from '../db.js';
import { getLlm, costUsd, AgentError } from './llm.js';

export const AGENT_EMPLOYEE = 'AI-AGENT';

export async function runAgent({ tenantId, agent, requestedBy = null, branchId = null, leadId = null }, job) {
    const llm = getLlm();
    const who = { tenant_id: tenantId, employee_id: AGENT_EMPLOYEE };
    const start = await asUser(who, async (db) => {
        const company = (await db.query(
            `select tenant_id, name, currency, locale, timezone, ai_enabled, ai_monthly_budget_usd, ai_auto_schedule
             from crm.tenant`)).rows[0];
        if (!company) throw new AgentError('This company has no AI agent account.');
        const spend = (await db.query('select crm.ai_spend_this_month() as s')).rows[0].s;
        const skip = !llm ? 'No AI service is configured on the server.'
            : !company.ai_enabled ? 'AI agents are switched off for this company.'
                : spend >= company.ai_monthly_budget_usd
                    ? `Monthly AI budget used up (${spend.toFixed(2)} of ${company.ai_monthly_budget_usd} USD).` : null;
        const runId = (await db.query(
            `insert into crm.agent_run (agent, requested_by, branch_id, lead_id, status, model, note, finished_at)
             values ($1, $2, $3, $4, $5, $6, $7, case when $5 = 'SKIPPED' then now() end) returning run_id`,
            [agent, requestedBy, branchId, leadId, skip ? 'SKIPPED' : 'RUNNING', llm?.model ?? null, skip])).rows[0].run_id;
        if (skip) return { runId, skip };
        return { runId, company, facts: await job.gather(db, company) };
    });
    if (start.skip) return { runId: start.runId, status: 'SKIPPED', note: start.skip };

    const finish = (status, fields) => asUser(who, (db) => db.query(
        `update crm.agent_run set status = $2, items = $3, input_tokens = $4, output_tokens = $5, cost_usd = $6,
                note = $7, finished_at = now() where run_id = $1`,
        [start.runId, status, fields.items || 0, fields.usage?.input_tokens || 0, fields.usage?.output_tokens || 0,
            fields.usage ? costUsd(fields.usage) : 0, fields.note || null]));

    if (job.isEmpty?.(start.facts)) {
        await finish('DONE', { note: 'Nothing needed attention.' });
        return { runId: start.runId, status: 'DONE', items: 0, note: 'Nothing needed attention.' };
    }
    let answer;
    try {
        answer = await llm.complete({ ...job.ask(start.facts, start.company), input: start.facts });
    } catch (err) {
        await finish('FAILED', { usage: err.usage, note: err.message.slice(0, 500) });
        if (err instanceof AgentError) return { runId: start.runId, status: 'FAILED', note: err.message };
        throw err;
    }
    try {
        const result = await asUser(who, (db) => job.save(db, answer.data, start.facts, start.company, start.runId));
        await finish('DONE', { usage: answer.usage, items: result.items });
        return { runId: start.runId, status: 'DONE', ...result };
    } catch (err) {
        await finish('FAILED', { usage: answer.usage, note: `Could not save the answer: ${err.message}`.slice(0, 500) });
        throw err;
    }
}
