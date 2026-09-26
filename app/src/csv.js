// Minimal RFC 4180 CSV parser: quoted fields, escaped quotes, CRLF.
export function parseCsv(text) {
    const rows = [];
    let row = [];
    let field = '';
    let quoted = false;
    const s = String(text || '').replace(/^﻿/, '');
    for (let i = 0; i < s.length; i += 1) {
        const ch = s[i];
        if (quoted) {
            if (ch === '"' && s[i + 1] === '"') { field += '"'; i += 1; }
            else if (ch === '"') quoted = false;
            else field += ch;
        } else if (ch === '"') quoted = true;
        else if (ch === ',') { row.push(field); field = ''; }
        else if (ch === '\n' || ch === '\r') {
            if (ch === '\r' && s[i + 1] === '\n') i += 1;
            row.push(field); rows.push(row); row = []; field = '';
        } else field += ch;
    }
    if (field !== '' || row.length) { row.push(field); rows.push(row); }
    const nonEmpty = rows.filter((r) => r.some((c) => c.trim() !== ''));
    if (!nonEmpty.length) return { header: [], records: [] };
    const header = nonEmpty[0].map((h) => h.trim().toLowerCase());
    const records = nonEmpty.slice(1).map((r) => Object.fromEntries(header.map((h, i) => [h, (r[i] ?? '').trim()])));
    return { header, records };
}
