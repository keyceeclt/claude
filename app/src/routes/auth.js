import { Router } from 'express';
import { asSystem } from '../db.js';
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
    const { rows } = await asSystem((db) => db.query(
        `select e.employee_id, l.password_hash
         from crm.employee e join crm.app_login l on l.employee_id = e.employee_id
         where lower(e.login_email) = $1 and (e.exit_date is null or e.exit_date > current_date)`, [email]));
    if (!rows[0] || !verifyPassword(password, rows[0].password_hash)) {
        recordLoginFailure(key);
        return fail('Email or password is incorrect.');
    }
    clearLoginFailures(key);
    await asSystem((db) => db.query('update crm.app_login set last_login_at = now() where employee_id = $1', [rows[0].employee_id]));
    startSession(res, rows[0].employee_id);
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
    const { rows } = await asSystem((db) => db.query('select password_hash from crm.app_login where employee_id = $1', [req.user.employee_id]));
    if (!rows[0] || !verifyPassword(String(current || ''), rows[0].password_hash)) return render('Current password is incorrect.');
    const problem = passwordProblem(password);
    if (problem) return render(problem);
    if (password !== confirm) return render('The two new passwords do not match.');
    await asSystem((db) => db.query(
        'update crm.app_login set password_hash = $2, must_change_password = false, updated_at = now() where employee_id = $1',
        [req.user.employee_id, hashPassword(password)]));
    res.redirect('/?msg=Password changed.');
});

export default router;
