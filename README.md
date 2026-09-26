# Key Cee Associates · Central CRM & Business Intelligence

Centralised multi-branch CRM, telecalling, follow-up, sales-conversion,
marketing-analytics and MIS platform for Key Cee Associates' Samsung Exclusive
Stores (HiLITE Mall and Mobile Plaza, Calicut; Appas, Sulthan Bathery).

- **[docs/PLATFORM.md](docs/PLATFORM.md)**: who uses it, modules, screens, roadmap.
- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)**: data model, business rules, roles, KPI definitions, open questions.

## What is here

| Path | Contents |
|---|---|
| `db/migrations/` | PostgreSQL schema, business-rule triggers, branch security, KPI/MIS views, web sign-in |
| `db/seed/0001_config.sql` | Branches (confirmed) and placeholder pick-lists (to be confirmed by Head Office) |
| `db/demo/demo_data.sql` | Fictional demo data for trying the app. Never load into production. |
| `db/tests/` | Database rule, KPI and security tests |
| `app/` | Web app (Node.js + Express, server-rendered, works on phones) |
| `app/test/` | End-to-end tests of the web app against a real database |

## Try it locally with demo data

Needs Node.js 20+ and PostgreSQL 15+.

```bash
createdb kc_crm
for f in db/migrations/*.sql db/seed/*.sql; do psql kc_crm -v ON_ERROR_STOP=1 -f "$f"; done
cd app && npm ci
export DATABASE_URL=postgresql:///kc_crm SESSION_SECRET=$(openssl rand -hex 32)
ALLOW_DEMO=1 npm run demo     # fictional staff, 360 leads, sales and campaigns
npm start                     # http://localhost:3000
```

Demo logins (password `demo-password`): `admin@demo.kc` (Head Office),
`manager.hilite@demo.kc` (Branch Manager), `anu@demo.kc` (sales staff).

## Run the tests

```bash
./scripts/test.sh                                            # temporary local PostgreSQL
DATABASE_URL=postgresql://user:pass@host/postgres ./scripts/test.sh   # existing server
```

GitHub Actions runs the same script on every pull request.

## Deploy

1. **Database**: any managed PostgreSQL 15+ (Supabase, Neon, Render, or a VPS).
   Run `db/migrations/*.sql` then `db/seed/0001_config.sql`, in order.
2. **Database login for the app**: follow the comment at the top of
   `db/migrations/0004_app_login.sql` to create `crm_server`. Every page query
   runs as the signed-in employee under row-level security.
3. **Web app**: deploy `app/` as a Node service (Render, Railway, a VPS).
   Environment: `DATABASE_URL`, `SESSION_SECRET` (32+ random characters),
   `NODE_ENV=production`, `PORT`. Serve it over HTTPS.
4. **First admin**:
   `npm run create-admin -- HO001 admin@keycee.example "Temporary-pass-1" "Admin Name"`.
   Sign in, change the password, then add staff and their logins under Admin.
5. **Confirm placeholders**: Admin › Pick-lists & rules, and Reports › Data quality
   lists what is still unconfirmed.
