// Loads fictional DEMO data and gives every demo employee the same password.
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
    await db.query(sql);
    await db.query(
        `insert into crm.app_login (employee_id, password_hash, must_change_password)
         select employee_id, $1, false from crm.employee where employee_id like 'DEMO-%'
         on conflict (employee_id) do nothing`, [hashPassword(password)]);
});
console.log(`Demo data loaded. Sign in as admin@demo.kc, manager.hilite@demo.kc or anu@demo.kc with password "${password}".`);
await pool.end();
