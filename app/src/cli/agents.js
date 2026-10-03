// Scheduled agent runs for every company that has AI agents switched on.
//   npm run agents -- rescue            Lead Rescue (e.g. every 2 hours in shop hours)
//   npm run agents -- brief             Daily brief per branch + company (e.g. 8:00 each morning)
//   npm run agents -- all [--company CODE]
// Example cron (server in UTC, India 08:00 = 02:30 UTC):
//   30 2 * * *        cd /srv/crm/app && npm run agents -- brief
//   0 4-13/2 * * *    cd /srv/crm/app && npm run agents -- rescue
import { asAuth, asUser, pool } from '../db.js';
import { runLeadRescue, runAllBriefs } from '../agents/agents.js';
import { AGENT_EMPLOYEE } from '../agents/runner.js';

const args = process.argv.slice(2);
const what = args[0];
const only = args.includes('--company') ? String(args[args.indexOf('--company') + 1] || '').toUpperCase() : null;
if (!['rescue', 'brief', 'all'].includes(what)) {
    console.error('Usage: npm run agents -- rescue|brief|all [--company CODE]');
    process.exit(1);
}

let failed = false;
const companies = await asAuth(async (db) => (await db.query('select * from crm.ai_enabled_tenants()')).rows);
for (const c of companies.filter((x) => !only || x.code === only)) {
    const log = (msg) => console.log(`[${new Date().toISOString()}] ${c.code} ${msg}`);
    try {
        if (what === 'rescue' || what === 'all') {
            const r = await runLeadRescue(c.tenant_id);
            log(`lead rescue: ${r.status}${r.items != null ? `, ${r.items} suggestions, ${r.scheduled || 0} scheduled` : ''}${r.note ? ` (${r.note})` : ''}`);
            failed ||= r.status === 'FAILED';
        }
        if (what === 'brief' || what === 'all') {
            const branches = await asUser({ tenant_id: c.tenant_id, employee_id: AGENT_EMPLOYEE }, async (db) =>
                (await db.query('select branch_id from crm.branch where is_active order by branch_id')).rows.map((b) => b.branch_id));
            for (const r of await runAllBriefs(c.tenant_id, branches)) {
                log(`daily brief: ${r.status}${r.unverified?.length ? `, unverified numbers ${r.unverified.join(' ')}` : ''}${r.note ? ` (${r.note})` : ''}`);
                failed ||= r.status === 'FAILED';
            }
        }
    } catch (err) {
        failed = true;
        log(`error: ${err.message}`);
    }
}
if (!companies.length) console.log('No company has AI agents switched on.');
await pool.end();
process.exit(failed ? 1 : 0);
