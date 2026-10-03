// Loads a fictional demo company ("Demo Electronics", code DEMO) with staff,
// leads and sales, and gives every demo employee the same password.
//   npm run demo            (refuses unless ALLOW_DEMO=1 is set)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { asSystem, pool } from '../db.js';
import { hashPassword } from '../auth.js';

if (process.env.ALLOW_DEMO !== '1') {
    console.error('Demo data is fictional. Set ALLOW_DEMO=1 to load it (never on the production database).');
    process.exit(1);
}
const here = path.dirname(fileURLToPath(import.meta.url));
const sql = fs.readFileSync(path.join(here, '../../../db/demo/demo_data.sql'), 'utf8');
const password = process.env.DEMO_PASSWORD || 'demo-password';
await asSystem(async (db) => {
    if ((await db.query("select 1 from crm.tenant where code = 'DEMO'")).rowCount) {
        throw new Error('The demo company already exists.');
    }
    await db.query(sql);
    await db.query(
        `select crm.auth_set_password(e.tenant_id, e.employee_id, $1, false)
         from crm.employee e join crm.tenant t on t.tenant_id = e.tenant_id
         where t.code = 'DEMO' and e.employee_id like 'DEMO-%'`, [hashPassword(password)]);
});
console.log(`Demo company loaded. Sign in as admin@demo.kc, manager.mall@demo.kc or anu@demo.kc with password "${password}".`);
await pool.end();
