// Adds a company to the platform with a starter template (all values are
// placeholders the company confirms in Admin > Pick-lists & rules).
//   npm run create-tenant -- <CODE> "<Company name>" [GENERAL|ELECTRONICS] [country] [phone prefix]
//                            [phone pattern] [time zone] [currency] [locale]
// Defaults: GENERAL, IN, 91, ^[6-9][0-9]{9}$, Asia/Kolkata, INR, en-IN.
// Then: add branches in the app (or SQL) and npm run create-admin for the first admin.
import { asSystem, pool } from '../db.js';

const [code, name, template = 'GENERAL', country = 'IN', prefix = '91', pattern = '^[6-9][0-9]{9}$',
    timezone = 'Asia/Kolkata', currency = 'INR', locale = 'en-IN'] = process.argv.slice(2);
if (!code || !name) {
    console.error('Usage: npm run create-tenant -- <CODE> "<Company name>" [GENERAL|ELECTRONICS] [country] [phone prefix] [phone pattern] [time zone] [currency] [locale]');
    process.exit(1);
}
try {
    new Intl.NumberFormat(locale, { style: 'currency', currency });
    new Intl.DateTimeFormat('en', { timeZone: timezone });
} catch (err) {
    console.error(`Invalid locale, currency or time zone: ${err.message}`);
    process.exit(1);
}
const id = await asSystem(async (db) => (await db.query(
    'select crm.create_tenant($1, $2, $3, $4, $5, $6, $7, $8, $9) as id',
    [code, name, template.toUpperCase(), country, prefix, pattern, timezone, currency, locale])).rows[0].id);
console.log(`Company ${code.toUpperCase()} created (id ${id}) from the ${template.toUpperCase()} template. AI agents are off until an admin turns them on.`);
await pool.end();
