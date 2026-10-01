// Formatting follows the signed-in person's company (currency, locale, time zone).
const DEFAULT_MARKET = { currency: 'INR', locale: 'en-IN', timezone: 'Asia/Kolkata' };
const cache = new Map();

export function market(m) {
    const t = { ...DEFAULT_MARKET, ...Object.fromEntries(Object.entries(m || {}).filter(([k, v]) => k in DEFAULT_MARKET && v)) };
    const key = `${t.currency}|${t.locale}|${t.timezone}`;
    if (cache.has(key)) return cache.get(key);
    const money = new Intl.NumberFormat(t.locale, { style: 'currency', currency: t.currency, maximumFractionDigits: 0 });
    const f = {
        ...t,
        currencySymbol: money.formatToParts(0).find((p) => p.type === 'currency')?.value || t.currency,
        fmtMoney: (v) => (v === null || v === undefined || v === '' ? '—' : money.format(Number(v))),
        fmtNum: (v) => (v === null || v === undefined ? '—' : Number(v).toLocaleString(t.locale)),
        fmtDate: (v) => {
            if (!v) return '—';
            // A bare date is a calendar day: show it as is, never shifted by time zone.
            const d = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? new Date(`${v}T12:00:00Z`) : new Date(v);
            const timeZone = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? 'UTC' : t.timezone;
            return d.toLocaleDateString(t.locale, { timeZone, day: '2-digit', month: 'short', year: 'numeric' });
        },
        fmtDateTime: (v) => (v ? new Date(v).toLocaleString(t.locale, {
            timeZone: t.timezone, day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—'),
        today: () => new Date().toLocaleDateString('en-CA', { timeZone: t.timezone }),
        monthStart: () => `${f.today().slice(0, 7)}-01`,
        // "2026-09-26T10:30" from <input type=datetime-local> is the company's local time.
        localTimestamp: (v) => {
            const s = blank(v);
            if (!s || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s)) return s;
            const asUtc = new Date(`${s}:00Z`);
            return new Date(asUtc.getTime() - offsetMinutes(asUtc, t.timezone) * 60e3).toISOString();
        },
    };
    cache.set(key, f);
    return f;
}

// Minutes the time zone is ahead of UTC at a given instant.
function offsetMinutes(date, timeZone) {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
        timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
    }).formatToParts(date).map((x) => [x.type, x.value]));
    return (Date.UTC(+p.year, p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - date.getTime()) / 60e3;
}

export function fmtPct(v) {
    return v === null || v === undefined ? '—' : `${Number(v).toFixed(1)}%`;
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
    if (err.code === 'P0001') return err.message;
    if (err.code === '23505') {
        if (/customer_mobile/.test(err.constraint || '')) return 'A customer with this mobile number already exists.';
        if (/invoice_no/.test(err.constraint || '')) return 'This invoice number already exists for the branch.';
        return 'This record already exists.';
    }
    if (err.code === '23514') {
        if (/mobile/.test(err.constraint || '')) return 'Enter a valid mobile number.';
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
        ...market(),
        fmtPct, attention,
        appName: process.env.APP_NAME || 'Retail Sales CRM',
        msg: typeof req.query.msg === 'string' ? req.query.msg : null,
        err: typeof req.query.err === 'string' ? req.query.err : null,
        path: req.path,
        query: req.query,
        me: null,
        csrfToken: '',
    });
    next();
}
