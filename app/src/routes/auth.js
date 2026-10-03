import { Router } from 'express';
import { asAuth } from '../db.js';
import {
    verifyPassword, hashPassword, passwordProblem, startSession, endSession,
    loginBlocked, recordLoginFailure, clearLoginFailures,
} from '../auth.js';

const router = Router();

function safeNext(next) {
    return typeof next === 'string' && next.startsWith('/') && !next.startsWith('//') ? next : '/';
}

router.get('/login', (req, res) => {
    if (req.user) return res.redirect('/');
    res.render('login', { title: 'Sign in', next: safeNext(req.query.next), error: null, email: '' });
});

router.post('/login', async (req, res) => {
    const email = String(req.body.email || '').trim().toLowerCase();
    const password = String(req.body.password || '');
    const next = safeNext(req.body.next);
    const key = `${req.ip}|${email}`;
    const fail = (error) => res.status(401).render('login', { title: 'Sign in', next, error, email });

    if (loginBlocked(key)) return fail('Too many attempts. Wait 15 minutes and try again.');
    const { rows } = await asAuth((db) => db.query('select * from crm.auth_find_login($1)', [email]));
    if (!rows[0] || !verifyPassword(password, rows[0].password_hash)) {
        recordLoginFailure(key);
        return fail('Email or password is incorrect.');
    }
    clearLoginFailures(key);
    const { tenant_id: tenantId, employee_id: employeeId } = rows[0];
    await asAuth((db) => db.query('select crm.auth_record_login($1, $2)', [tenantId, employeeId]));
    startSession(res, tenantId, employeeId);
    res.redirect(next);
});

router.post('/logout', (req, res) => {
    endSession(res);
    res.redirect('/login');
});

router.get('/account/password', (req, res) => {
    if (!req.user) return res.redirect('/login');
    res.render('password', { title: 'Change password', error: null });
});

router.post('/account/password', async (req, res) => {
    if (!req.user) return res.redirect('/login');
    const { current, password, confirm } = req.body;
    const render = (error) => res.status(400).render('password', { title: 'Change password', error });
    const { rows } = await asAuth((db) => db.query('select crm.auth_password_hash($1, $2) as hash', [req.user.tenant_id, req.user.employee_id]));
    if (!rows[0]?.hash || !verifyPassword(String(current || ''), rows[0].hash)) return render('Current password is incorrect.');
    const problem = passwordProblem(password);
    if (problem) return render(problem);
    if (password !== confirm) return render('The two new passwords do not match.');
    await asAuth((db) => db.query('select crm.auth_set_password($1, $2, $3, false)',
        [req.user.tenant_id, req.user.employee_id, hashPassword(password)]));
    res.redirect('/?msg=Password changed.');
});

export default router;
