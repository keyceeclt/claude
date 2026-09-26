# Key Cee Associates · Central CRM & Business Intelligence — Blueprint v0.1

Status: **draft for Head Office review** (2026-09-26). Built from the operating
mode, knowledge-base structure, company profile, Employee_Master fields and
architecture shared in the project. Nothing below invents business data: any
value not supplied by Head Office is a **placeholder** in the database
(`is_placeholder = true`) and is listed live by `crm.v_setup_gaps`.

---

## 1. Understand: what the platform must answer

Every screen and report exists to answer the management questions:

| Question | Where it is answered |
|---|---|
| What happened? | Daily MIS (`v_daily_mis`), branch funnel (`v_branch_funnel_monthly`) |
| Why did it happen? | Stage history, lost reasons, source/campaign performance |
| Where are we losing opportunities? | Lead leakage flags (`v_lead_status.attention_reason`), ageing (`v_open_lead_ageing`) |
| What needs attention now? | Overdue follow-ups, leads not contacted within SLA, leads with no next step |
| Who is responsible? | Every lead has an owner; every follow-up has an employee |
| What should happen next? | Each open lead should carry a scheduled follow-up (flagged when missing) |
| Did the action work? | Month-on-month funnel, follow-up on-time %, target achievement |

## 2. Validate: conflicts resolved against the given architecture

The architecture as given is kept. Five refinements (proposed in the project
chat, **awaiting Head Office OK**, built as the working default):

1. **A lead links to both a customer and a source/campaign.** This is what
   joins the sales pipeline to marketing attribution.
2. **Follow-ups are lead activities with a due date**, not a separate table.
   One table makes overdue and missed follow-ups measurable.
3. **Store visits, quotations and sales are optional steps.** Walk-ins buy
   without being a lead; many sales skip a quotation. A mandatory chain would
   push staff to enter fake records.
4. **A sale keeps its Lead_ID** (blank for walk-ins), so revenue traces to a
   campaign and walk-in revenue is reported separately.
5. **Conversion is derived, not entered.** A lead becomes *Won* only when a
   sale is linked to it; the database rejects a manual "Won".

Employee_Master changes: `Reporting_Manager` stores an Employee_ID; `Target`
moved to a separate `staff_target` table (employee × period × measure);
`Exit_Date`, mobile and login added so past staff's work stays attributable.

## 3. Structure: modules and data model

```
 06_MARKETING                     04_CRM                                   05_SALES
 ┌──────────┐   ┌─────────────┐   ┌──────────┐   ┌───────────────────┐
 │ campaign │──▶│ lead_source │──▶│   lead   │◀──│     customer      │
 └──────────┘   └─────────────┘   └────┬─────┘   └───────────────────┘
                                       │ owner = employee, branch
         ┌─────────────────┬───────────┼──────────────┬──────────────┐
         ▼                 ▼           ▼              ▼              ▼
  lead_activity     lead_stage_   store_visit     quotation        sale ── sale_item
  (calls, WhatsApp,   history     (lead optional) (lead optional) (lead optional;
   follow-ups)                                                     revenue truth)
```

| Module | Tables | Notes |
|---|---|---|
| Company / HR | `branch`, `employee`, `staff_target` | Branch NULL on employee = Head Office |
| Customers | `customer` | One record per mobile (normalised to 10 digits; duplicates rejected) |
| Leads | `lead`, `lead_stage`, `lead_stage_history` | Stage history recorded automatically |
| Telecalling & follow-up | `lead_activity`, `activity_outcome` | Outcome says whether the customer was actually reached |
| Store / sales | `store_visit`, `quotation`, `sale`, `sale_item` | Sales expected from the billing system |
| Marketing | `campaign`, `lead_source` | Spend on campaign; paid sources flagged |
| Configuration | `lookup_value`, `access_level`, `setting` | All pick-lists editable by HO, no code change |

## 4. Lead stages (placeholder — confirm)

| Stage | Type | Counts in conversion? |
|---|---|---|
| New → Contacted → Interested → Visit scheduled → Visited → Quoted | Open | Yes |
| Won (sale linked) | Closed, set by system only | Yes (numerator) |
| Lost | Closed, **reason required** | Yes |
| Invalid / duplicate / wrong number | Closed | **No** (junk is excluded so it neither inflates nor deflates conversion) |

## 5. Roles and data access

Enforced in the database (row-level security), so every app, report or export
obeys it automatically.

| Access level (placeholder name) | Sees | Can change |
|---|---|---|
| Head Office Admin | All branches | Everything incl. configuration, staff, targets |
| Head Office Viewer | All branches | Nothing (read-only) |
| Branch Manager | Own branch: leads, customers, sales, staff | Own branch records, sales entry |
| Sales Staff / Telecaller | Leads assigned to or created by them | Own leads and follow-ups |
| Exited staff / unknown login | Nothing | Nothing |

Staff can look up any customer by mobile before creating one, so duplicates are
caught across branches without exposing other branches' pipelines.

## 6. KPI definitions (the rules the numbers follow)

| KPI | Definition | Guard against |
|---|---|---|
| Qualified leads | Leads minus junk stage | Treating volume as success |
| Lead conversion % | Won ÷ qualified, **by month the lead was created** | Late wins counted in the wrong month |
| First-contact time | Hours from lead creation to first activity that *reached* the customer | Counting unanswered calls as contact |
| Follow-up on-time % | Follow-ups completed within grace window ÷ follow-ups due | Activity counts as "productivity" |
| Leakage flags | Not contacted within SLA · follow-up overdue · no next follow-up · stale | Leads silently dying |
| Lead revenue vs walk-in revenue | Sales with / without a linked lead, reported separately | Mixing walk-ins into campaign ROI |
| Campaign cost per qualified lead / per won lead, revenue per ₹ spent | From campaign spend and linked sales | High lead volume read as campaign success |
| Target achievement % | Actual ÷ monthly target by measure (sales value, sales count, leads won, visits) | A single undefined "Target" |
| Data-quality issues | 14 checks (`v_data_quality_issues`), severity-ranked | Hidden DQ problems |

Attribution is single-touch (the lead's own source/campaign). Multi-touch can
come later if marketing needs it.

## 7. MIS and reports (07_REPORTING)

| Report | Built on | Audience |
|---|---|---|
| Daily MIS (per branch per day) | `v_daily_mis` + leakage list | Branch Manager daily, HO roll-up |
| Weekly / Monthly MIS | `v_branch_funnel_monthly`, `v_staff_performance_monthly`, `v_source_performance_monthly` | HO, Branch Managers |
| Marketing review | `v_campaign_performance` | HO / marketing |
| Action list | `v_lead_status` where `attention_reason` is set, `v_open_lead_ageing` | Staff (own), Manager (branch) |
| Data-quality & setup gaps | `v_data_quality_issues`, `v_setup_gaps` | HO |

Branch comparison rule: branch figures are shown side by side only with their
context (market, staff count, footfall). That context is **not yet provided**
(see §9), and Wayanad is a different market from the two Calicut stores.

## 8. Stack (practical, low-cost)

| Layer | Choice | Why |
|---|---|---|
| Database + login + security | **PostgreSQL on Supabase** (free tier to start, ~US$25/month Pro when live) | Managed backups, built-in login, row-level security per branch, no server to run |
| Staff / telecaller app | Phase 2: mobile-friendly web app (Next.js) on Supabase | Works on the phones staff already use; no app-store install |
| MIS dashboards | Phase 2: Looker Studio (free) or Metabase reading the MIS views | Management reports without custom code |
| Data loads | CSV import from billing and existing lead sheets into staging, validated before load | Keeps bad data out of the core tables |

Everything in this repository is plain PostgreSQL 15+ and runs on any
Postgres host, so the hosting choice is not locked in.

## 9. Gaps — needed from Head Office

**Blocking fair analysis**
- Branch context: staff count, floor size, footfall, opening date per branch.
- Where sales data comes from (billing software name / export format) and whether invoices carry salesperson and customer mobile.
- Where leads live today (sheets, WhatsApp, a CRM?) so existing data can be imported and cleaned.

**Replace the placeholders** (listed live in `crm.v_setup_gaps`)
- Employee Status, Designation, Department, CRM access levels.
- Lead stages, lead sources, lost reasons, activity types and outcomes.
- Product categories, customer segments.
- Rules: first-contact SLA (placeholder 4 h), follow-up grace (24 h), stale lead (7 days).

**Decisions**
- OK on the five architecture refinements in §2.
- Can a lead be reassigned across branches? (Currently: no, a lead belongs to one branch.)
- Target measures and periods actually used (currently monthly: sales value, sales count, leads won, visits).
- Incentive structure (05_SALES) — not modelled until the rules are shared.

## 10. Test and improve

`scripts/test-db.sh` builds a fresh database and runs 47 checks covering the
business rules (no Won without a sale, lost needs a reason, duplicate and
invalid mobiles rejected, visit/sale must match the lead's customer), the KPI
arithmetic (conversion excludes junk, campaign cost per won lead, walk-in vs
lead revenue, target achievement), and branch security (manager sees only
their branch, staff only their leads, exited staff nothing). CI runs it on
every pull request.

Next iteration (after §9 answers): replace placeholders, import a real data
sample and run the data-quality pass on it, then build the staff app and the
Daily MIS dashboard.
