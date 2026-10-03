# Agentic Sales CRM for Retail

A sales CRM for multi-branch retailers, with AI agents that rescue slipping
enquiries, draft follow-up messages and brief managers every morning.
Agents suggest; people decide. Many companies share one platform, each kept
separate by the database itself. Key Cee Associates (Samsung Exclusive Stores:
HiLITE Mall and Mobile Plaza, Calicut; Appas, Sulthan Bathery) is the first company.

- **[docs/PLATFORM.md](docs/PLATFORM.md)**: users, AI agents and their guardrails, multi-company design, screens, roadmap.
- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)**: data model, business rules, roles, KPI definitions, open questions (Key Cee).

## What is here

| Path | Contents |
|---|---|
| `db/migrations/` | PostgreSQL schema: companies, rules, security, KPI/MIS views, sign-in, starter templates, AI agents |
| `db/seed/0001_config.sql` | Key Cee as company #1: its three branches (confirmed) and template placeholders |
| `db/demo/demo_data.sql` | A fictional demo company with staff, leads and sales. Never load into production. |
| `db/tests/` | Database tests: rules, KPIs, branch security, agent limits, company isolation |
| `app/` | Web app and agents (Node.js + Express, server-rendered, works on phones) |
| `app/src/agents/` | Lead Rescue, Follow-up Writer, Daily Brief; the AI client; the run/budget logic |
| `app/test/` | End-to-end tests of the web app and agents against a real database |

## Try it locally with demo data

Needs Node.js 20+ and PostgreSQL 15+.

```bash
createdb crm
for f in db/migrations/*.sql db/seed/*.sql; do psql crm -v ON_ERROR_STOP=1 -f "$f"; done
cd app && npm ci
export DATABASE_URL=postgresql:///crm SESSION_SECRET=$(openssl rand -hex 32)
ALLOW_DEMO=1 npm run demo     # fictional company "Demo Electronics": staff, 360 leads, sales
npm start                     # http://localhost:3000
```

Demo logins (password `demo-password`): `admin@demo.kc` (head office),
`manager.mall@demo.kc` (branch manager), `anu@demo.kc` (sales staff).

To try the agents without an AI key, start the app with `AI_PROVIDER=fake`
(canned, deterministic answers), then switch agents on under Admin › AI agents.

## AI agents

| Setting | Where |
|---|---|
| AI key | Server environment `ANTHROPIC_API_KEY`. Without it the CRM works as normal and agents stay off. |
| Model | `AI_MODEL` (default `claude-opus-5-5`); prices for cost tracking `AI_PRICE_INPUT_PER_MTOK` / `AI_PRICE_OUTPUT_PER_MTOK` (default 4 / 20 USD) |
| On/off, monthly budget, auto-scheduling | Per company, Admin › AI agents |
| Leads per Lead Rescue run | `AI_RESCUE_BATCH` (default 20) |

Schedule the agents with cron (the server's clock; India 08:00 is 02:30 UTC):

```cron
30 2 * * *        cd /srv/crm/app && npm run agents -- brief
0 4-13/2 * * *    cd /srv/crm/app && npm run agents -- rescue
```

## Run the tests

```bash
./scripts/test.sh                                            # temporary local PostgreSQL
DATABASE_URL=postgresql://user:pass@host/postgres ./scripts/test.sh   # existing server
```

The agents are tested against a stand-in model; no AI key is needed. GitHub
Actions runs the same script on every pull request.

## Deploy

1. **Database**: any managed PostgreSQL 15+. Run `db/migrations/*.sql` then
   `db/seed/0001_config.sql`, in order.
2. **Database login for the app**: follow the comment at the top of
   `db/migrations/0004_app_login.sql` to create `crm_server`. Every page query
   runs as the signed-in employee, inside their company, under row-level security.
3. **Web app**: deploy `app/` as a Node service. Environment: `DATABASE_URL`,
   `SESSION_SECRET` (32+ random characters), `NODE_ENV=production`, `PORT`,
   optionally `APP_NAME` and `ANTHROPIC_API_KEY`. Serve it over HTTPS.
4. **Companies**: Key Cee exists after the seed. Add another with
   `npm run create-tenant -- ACME "Acme Retail" GENERAL` (options: country,
   phone prefix and pattern, time zone, currency, locale), then add its branches.
5. **First admin per company**:
   `npm run create-admin -- KEYCEE HO001 admin@keycee.example "Temporary-pass-1" "Admin Name"`.
   Sign in, change the password, then add staff and their logins under Admin.
6. **Confirm placeholders**: Admin › Pick-lists & rules; Reports › Data quality
   lists what is still unconfirmed.
7. **Agents** (optional): set `ANTHROPIC_API_KEY`, add the cron entries above,
   and have each company's admin switch agents on with a budget.
