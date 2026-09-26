# Key Cee Associates · Central CRM & Business Intelligence

Centralised multi-branch CRM, telecalling, follow-up, sales-conversion,
marketing-analytics and MIS platform for Key Cee Associates' Samsung Exclusive
Stores (HiLITE Mall and Mobile Plaza, Calicut; Appas, Sulthan Bathery).

Start with **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)**: modules, data model,
lead stages, roles, KPI definitions, MIS, stack and open questions.

## What is here (phase 1: data foundation)

| Path | Contents |
|---|---|
| `db/migrations/0001_foundation.sql` | Tables and business-rule triggers |
| `db/migrations/0002_security.sql` | Branch- and role-scoped row-level security |
| `db/migrations/0003_reporting.sql` | KPI, MIS, leakage and data-quality views |
| `db/seed/0001_config.sql` | Branches (confirmed) and placeholder pick-lists (to be confirmed) |
| `db/tests/test_crm.sql` | Rule, KPI and security tests |

## Run the tests

Needs PostgreSQL 15+ client and server binaries.

```bash
./scripts/test-db.sh                                  # temporary local cluster
DATABASE_URL=postgresql://user:pass@host/db ./scripts/test-db.sh   # existing server
```

## Deploy to Supabase

1. Create a Supabase project; open the SQL editor.
2. Run the three migrations in order, then `db/seed/0001_config.sql`.
3. Run `grant crm_app to authenticated;` and add `crm` to the exposed schemas (Settings → API).
4. Add each employee to `crm.employee` with `auth_user_id` set to their Supabase login id.
5. Replace placeholders: `select * from crm.v_setup_gaps;` lists what is still unconfirmed.
