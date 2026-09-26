import pg from 'pg';

// Counts come back as numbers, money as numbers, dates as 'YYYY-MM-DD' strings.
pg.types.setTypeParser(20, (v) => parseInt(v, 10));
pg.types.setTypeParser(1700, (v) => parseFloat(v));
pg.types.setTypeParser(1082, (v) => v);

export const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: Number(process.env.DB_POOL_SIZE || 10),
});

async function inTransaction(setup, fn) {
    const client = await pool.connect();
    try {
        await client.query('begin');
        await setup(client);
        const result = await fn(client);
        await client.query('commit');
        return result;
    } catch (err) {
        await client.query('rollback').catch(() => {});
        throw err;
    } finally {
        client.release();
    }
}

// Runs fn as the signed-in employee: row-level security decides what they
// can see and change, so a page cannot leak another branch's data.
export function asUser(employeeId, fn) {
    return inTransaction(async (client) => {
        await client.query('set local role crm_app');
        await client.query("select set_config('app.employee_id', $1, true)", [employeeId]);
    }, fn);
}

// Server-only work (sign-in, password changes). Never used to serve page data.
export function asSystem(fn) {
    return inTransaction(async () => {}, fn);
}
