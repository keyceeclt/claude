// Creates or resets a web login. If the employee does not exist yet and a name
// is given, creates them as a Head Office employee with the config-managing
// access level (used once to bootstrap the first admin).
//   npm run create-admin -- <employee_id> <email> <temporary password> ["Full Name"]
import { asSystem, pool } from '../db.js';
import { hashPassword, passwordProblem } from '../auth.js';

const [employeeId, email, password, name] = process.argv.slice(2);
if (!employeeId || !email || !password) {
    console.error('Usage: npm run create-admin -- <employee_id> <email> <temporary password>');
    process.exit(1);
}
const problem = passwordProblem(password);
if (problem) {
    console.error(problem);
    process.exit(1);
}
await asSystem(async (db) => {
    const { rowCount } = await db.query('update crm.employee set login_email = $2 where employee_id = $1', [employeeId, email.toLowerCase()]);
    if (!rowCount) {
        if (!name) throw new Error(`Employee ${employeeId} not found. Pass a name to create them as Head Office admin.`);
        await db.query(
            `insert into crm.employee (employee_id, employee_name, status, crm_access_level, login_email)
             values ($1, $2,
                     (select code from crm.lookup_value where category = 'EMPLOYEE_STATUS' order by sort_order limit 1),
                     (select code from crm.access_level where can_manage_config and data_scope = 'ALL' order by sort_order limit 1),
                     $3)`, [employeeId, name, email.toLowerCase()]);
    }
    await db.query(
        `insert into crm.app_login (employee_id, password_hash, must_change_password) values ($1, $2, true)
         on conflict (employee_id) do update set password_hash = excluded.password_hash, must_change_password = true, updated_at = now()`,
        [employeeId, hashPassword(password)]);
});
console.log(`Login ready for ${employeeId} <${email}>. They must change the password at first sign-in.`);
await pool.end();
