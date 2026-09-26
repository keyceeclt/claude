import crypto from 'node:crypto';
import { asSystem } from './db.js';

const SECRET = process.env.SESSION_SECRET || '';
if (SECRET.length < 32) {
    if (process.env.NODE_ENV === 'production') {
        throw new Error('SESSION_SECRET must be set to at least 32 characters');
    }
}
const secret = SECRET || crypto.randomBytes(32).toString('hex');
const SESSION_HOURS = 12;
const COOKIE = 'kc_sid';

// ---------------------------------------------------------------- passwords
export function hashPassword(password) {
    const salt = crypto.randomBytes(16);
    const hash = crypto.scryptSync(password, salt, 64);
    return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

export function verifyPassword(password, stored) {
    const [scheme, saltHex, hashHex] = String(stored || '').split('$');
    if (scheme !== 'scrypt' || !saltHex || !hashHex) return false;
    const expected = Buffer.from(hashHex, 'hex');
    const actual = crypto.scryptSync(password, Buffer.from(saltHex, 'hex'), expected.length);
    return crypto.timingSafeEqual(expected, actual);
}

export function passwordProblem(password) {
    if (typeof password !== 'string' || password.length < 10) return 'Password must be at least 10 characters.';
    return null;
}

// ---------------------------------------------------------------- sessions
function sign(value) {
    return crypto.createHmac('sha256', secret).update(value).digest('base64url');
}

function readCookies(req) {
    const out = {};
    for (const part of (req.headers.cookie || '').split(';')) {
        const i = part.indexOf('=');
        if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
    }
    return out;
}

function cookieFlags() {
    const secure = process.env.NODE_ENV === 'production' ? '; Secure' : '';
    return `; Path=/; HttpOnly; SameSite=Lax${secure}`;
}

export function startSession(res, employeeId) {
    const payload = Buffer.from(JSON.stringify({ e: employeeId, x: Date.now() + SESSION_HOURS * 3600e3 }))
        .toString('base64url');
    res.setHeader('Set-Cookie', `${COOKIE}=${payload}.${sign(payload)}${cookieFlags()}; Max-Age=${SESSION_HOURS * 3600}`);
}

export function endSession(res) {
    res.setHeader('Set-Cookie', `${COOKIE}=${cookieFlags()}; Max-Age=0`);
}

function readSession(req) {
    const raw = readCookies(req)[COOKIE];
    if (!raw) return null;
    const [payload, sig] = raw.split('.');
    if (!payload || !sig) return null;
    const expected = sign(payload);
    if (sig.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
    try {
        const data = JSON.parse(Buffer.from(payload, 'base64url').toString());
        return data.x > Date.now() ? { employeeId: data.e, raw } : null;
    } catch {
        return null;
    }
}

// ---------------------------------------------------------------- middleware
export async function loadUser(req, res, next) {
    const session = readSession(req);
    req.user = null;
    if (session) {
        const { rows } = await asSystem((db) => db.query(
            `select e.employee_id, e.employee_name, e.branch_id, b.name as branch_name,
                    a.code as access_level, a.label as access_label, a.data_scope,
                    a.can_write, a.can_manage_config, l.must_change_password
             from crm.employee e
             join crm.access_level a on a.code = e.crm_access_level
             join crm.app_login l on l.employee_id = e.employee_id
             left join crm.branch b on b.branch_id = e.branch_id
             where e.employee_id = $1 and (e.exit_date is null or e.exit_date > current_date)`,
            [session.employeeId]));
        if (rows[0]) {
            req.user = rows[0];
            req.csrfToken = sign(`csrf:${session.raw}`);
        }
    }
    res.locals.me = req.user;
    res.locals.csrfToken = req.csrfToken || '';
    next();
}

export function requireLogin(req, res, next) {
    if (!req.user) return res.redirect(`/login?next=${encodeURIComponent(req.originalUrl)}`);
    if (req.user.must_change_password && !req.path.startsWith('/account')) {
        return res.redirect('/account/password');
    }
    next();
}

export function checkCsrf(req, res, next) {
    // Sign-in has no session yet; SameSite=Lax cookies cover login CSRF.
    if (req.method !== 'POST' || req.path === '/login') return next();
    const token = req.body?._csrf || '';
    if (!req.csrfToken || token.length !== req.csrfToken.length
        || !crypto.timingSafeEqual(Buffer.from(token), Buffer.from(req.csrfToken))) {
        return res.status(403).render('error', { title: 'Session expired', message: 'Please reload the page and try again.' });
    }
    next();
}

export function requireScope(...scopes) {
    return (req, res, next) => scopes.includes(req.user.data_scope)
        ? next()
        : res.status(403).render('error', { title: 'Not allowed', message: 'Your access level does not include this page.' });
}

export function requireConfig(req, res, next) {
    return req.user.can_manage_config
        ? next()
        : res.status(403).render('error', { title: 'Not allowed', message: 'Only Head Office admins can change this.' });
}

// Simple in-memory brute-force guard for the login form.
const failures = new Map();
export function loginBlocked(key) {
    const f = failures.get(key);
    return f && f.count >= 8 && Date.now() - f.first < 15 * 60e3;
}
export function recordLoginFailure(key) {
    const f = failures.get(key);
    if (!f || Date.now() - f.first > 15 * 60e3) failures.set(key, { count: 1, first: Date.now() });
    else f.count += 1;
}
export function clearLoginFailures(key) {
    failures.delete(key);
}
