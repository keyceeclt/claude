const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });
const tz = 'Asia/Kolkata';

export function fmtMoney(v) {
    return v === null || v === undefined || v === '' ? '—' : money.format(Number(v));
}
export function fmtNum(v) {
    return v === null || v === undefined ? '—' : Number(v).toLocaleString('en-IN');
}
export function fmtPct(v) {
    return v === null || v === undefined ? '—' : `${Number(v).toFixed(1)}%`;
}
export function fmtDate(v) {
    if (!v) return '—';
    const d = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? new Date(`${v}T00:00:00+05:30`) : new Date(v);
    return d.toLocaleDateString('en-IN', { timeZone: tz, day: '2-digit', month: 'short', year: 'numeric' });
}
export function fmtDateTime(v) {
    if (!v) return '—';
    return new Date(v).toLocaleString('en-IN', { timeZone: tz, day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}
export function todayIST() {
    return new Date().toLocaleDateString('en-CA', { timeZone: tz });
}
export function monthStartIST() {
    return `${todayIST().slice(0, 7)}-01`;
}

const ATTENTION = {
    NOT_CONTACTED_WITHIN_SLA: ['Not contacted in time', 'bad'],
    FOLLOWUP_OVERDUE: ['Follow-up overdue', 'bad'],
    NO_NEXT_FOLLOWUP: ['No next follow-up', 'warn'],
    STALE: ['Stale', 'warn'],
};
export function attention(code) {
    return ATTENTION[code] || null;
}

// Friendly text for database rule violations.
export function dbMessage(err) {
    if (!err || !err.code) return 'Something went wrong.';
    if (err.code === '42501') return 'You do not have access to do that.';
    if (err.code === '23505') {
        if (/customer_mobile/.test(err.constraint || '')) return 'A customer with this mobile number already exists.';
        if (/invoice_no/.test(err.constraint || '')) return 'This invoice number already exists for the branch.';
        return 'This record already exists.';
    }
    if (err.code === '23514') {
        if (/mobile/.test(err.constraint || '')) return 'Enter a valid 10-digit Indian mobile number.';
        return err.message.startsWith('new row') ? 'Some values are not allowed. Please check the form.' : err.message;
    }
    if (err.code === '23503') return 'A referenced record does not exist.';
    if (err.code === '23502') return `Missing required value: ${err.column}.`;
    if (err.code === '22P02' || err.code === '22007' || err.code === '22008') return 'A value has the wrong format.';
    return null;
}

// Run a form action; on a database rule violation go back with the message.
export async function act(res, back, fn) {
    try {
        const to = await fn();
        res.redirect(to || back);
    } catch (err) {
        const msg = dbMessage(err);
        if (!msg) throw err;
        res.redirect(withParam(back, 'err', msg));
    }
}

export function withParam(url, key, value) {
    const u = new URL(url, 'http://x');
    u.searchParams.set(key, value);
    return u.pathname + u.search;
}

export function blank(v) {
    return v === undefined || v === null || String(v).trim() === '' ? null : String(v).trim();
}

export function viewHelpers(req, res, next) {
    Object.assign(res.locals, {
        fmtMoney, fmtNum, fmtPct, fmtDate, fmtDateTime, attention, todayIST,
        msg: typeof req.query.msg === 'string' ? req.query.msg : null,
        err: typeof req.query.err === 'string' ? req.query.err : null,
        path: req.path,
        query: req.query,
        me: null,
        csrfToken: '',
    });
    next();
}
