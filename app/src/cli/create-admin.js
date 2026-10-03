// Creates or resets a web login for an employee of a company. If the employee
// does not exist yet and a name is given, creates them at head office with the
// config-managing access level (used once to bootstrap a company's first admin).
//   npm run create-admin -- <company code> <employee_id> <email> <temporary password> ["Full Name"]
import { asSystem, pool } from '../db.js';
import { hashPassword, passwordProblem } from '../auth.js';

const [company, employeeId, email, password, name] = process.argv.slice(2);
if (!company || !employeeId || !email || !password) {
    console.error('Usage: npm run create-admin -- <company code> <employee_id> <email> <temporary password> ["Full Name"]');
    process.exit(1);
}
const problem = passwordProblem(password);
if (problem) {
    console.error(problem);
    process.exit(1);
}
await asSystem(async (db) => {
    const tenant = (await db.query('select tenant_id from crm.tenant where code = upper($1)', [company])).rows[0];
    if (!tenant) throw new Error(`No company with code ${company}. Create it with npm run create-tenant.`);
    await db.query("select set_config('app.tenant_id', $1, true)", [String(tenant.tenant_id)]);
    const { rowCount } = await db.query(
        'update crm.employee set login_email = $3 where tenant_id = $1 and employee_id = $2',
        [tenant.tenant_id, employeeId, email.toLowerCase()]);
    if (!rowCount) {
        if (!name) throw new Error(`Employee ${employeeId} not found. Pass a name to create them as an admin.`);
        await db.query(
            `insert into crm.employee (employee_id, employee_name, status, crm_access_level, login_email)
             values ($1, $2,
                     (select code from crm.lookup_value where tenant_id = $4 and category = 'EMPLOYEE_STATUS' order by sort_order limit 1),
                     (select code from crm.access_level where tenant_id = $4 and can_manage_config and data_scope = 'ALL' order by sort_order limit 1),
                     $3)`, [employeeId, name, email.toLowerCase(), tenant.tenant_id]);
    }
    await db.query('select crm.auth_set_password($1, $2, $3, true)', [tenant.tenant_id, employeeId, hashPassword(password)]);
});
console.log(`Login ready for ${employeeId} <${email}>. They must change the password at first sign-in.`);
await pool.end();
