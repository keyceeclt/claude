# Agentic Sales CRM for Retail — Platform

Companion to [BLUEPRINT.md](BLUEPRINT.md) (data model, rules and KPIs, written
for Key Cee Associates, the first company on the platform). This page is the
product view: who uses it, what the AI agents do, which screens exist, how
companies are kept apart, and the order in which it grows.

## 1. Vision

A sales CRM for multi-branch retailers in which every customer enquiry is
captured, owned, followed up and traced to a sale, and in which AI agents
work alongside the sales team: they spot the enquiries that are slipping, say
what to do next, draft the message, and brief each manager every morning.

**Agents suggest, people decide.** Agents read the CRM, write suggestions,
drafts and briefs, and (only if a company allows it) put a follow-up in a
salesperson's day. They never change a lead's stage, record a sale, edit a
customer, or send anything to a customer. Every agent action is logged,
costed and can be undone.

Success is measured by business outcomes, not by usage:

| Outcome | Measured by |
|---|---|
| Fewer lost enquiries | % of leads contacted within SLA; open leads with no next follow-up → 0 |
| Better follow-up discipline | Follow-up on-time % per staff and branch |
| Higher conversion | Won ÷ qualified leads, by branch, source and staff |
| Marketing spend that pays | Revenue per unit spent and cost per won lead, per campaign |
| Agents that earn their cost | Suggestions accepted vs dismissed/undone; AI spend per company per month |
| Trustworthy MIS | Data-quality issue count trending down |

## 2. Users and their day

| User | Their day in the platform | Sees |
|---|---|---|
| **Sales staff / telecaller** | Opens *My Day*: overdue follow-ups, AI-suggested next steps (schedule or dismiss), due today, new leads. On a lead, asks the AI for a WhatsApp draft, edits it, sends it from their own phone. | Own leads |
| **Branch Manager** | Morning: the AI daily brief for the branch, then the Daily MIS and action list. Reassigns leads, checks follow-up discipline, enters or verifies sales. | Own branch |
| **Head Office admin** | Cross-branch MIS and the company brief, campaign performance, data-quality queue. Manages staff, targets, pick-lists, campaigns, imports, and the AI agents (on/off, monthly budget, auto-scheduling). | All branches |
| **Management (read-only)** | Monthly funnel, branch and staff performance, marketing return. | All branches, no edits |

## 3. The AI agents

| Agent | When | Reads | Produces | Who acts |
|---|---|---|---|---|
| **Lead Rescue** | On a schedule (e.g. every 2 hours in shop hours) or "Run now" | Open leads the CRM's own rules flag as at risk: not contacted in time, follow-up overdue, no next step, stale; with their recent activity and notes | One next step per lead: channel, time (inside contact hours), priority, a reason citing the lead's record, an opening line | The lead owner schedules or dismisses it. If the company allows auto-scheduling, the follow-up is added directly (only where none is pending) and shows as "scheduled by AI" with an Undo button |
| **Follow-up Writer** | On demand, from a lead page | That lead's record: interest, stage, quotations, visits, recent notes | A short WhatsApp message in the chosen language plus a tip for the salesperson | The salesperson edits and sends it from WhatsApp; nothing is sent automatically |
| **Daily Brief** | Each morning (schedule) or "Write today's brief" | Figures the CRM already computed: yesterday's MIS, month to date vs target, at-risk pipeline, overdue follow-ups by staff, lead sources | A headline and 3–6 points (urgent / leak / win / action), each with an owner | Branch manager (branch brief), head office (company brief) |

How the agents are kept honest:

- **Facts come from the CRM, not the model.** The rules decide which leads are
  at risk; the model only chooses the next step and writes the words.
- **Numbers are checked.** Every number in a daily brief is compared with the
  figures it was written from; anything not found is shown to the reader as
  "check before acting".
- **The database enforces the limits.** Agents act through an "AI sales agent"
  employee record in each company. Row-level policies stop it from changing
  leads, customers, sales or settings, from logging a completed contact, or
  from signing in; staff cannot pass their own work off as the agent's.
- **Spend is capped.** Each company has a monthly AI budget (USD). Every run
  records its tokens and cost; agents stop for the month once the budget is used.
- **Off by default.** A company's agents run only after its admin switches
  them on and sets a budget, and only if the server has an AI key.
- **Staff notes are data.** The prompts tell the model to treat anything typed
  by staff as information about the customer, never as instructions.

Model: Claude Opus 5.5 (`claude-opus-5-5`) through the official Anthropic SDK,
with structured (schema-checked) answers, adaptive thinking and server-side
fallback to Anthropic's recommended model if a request is declined. The model
and token prices are environment settings (see README).

## 4. Many companies, one platform

| What | How |
|---|---|
| Isolation | Every row carries the company's `tenant_id`. A restrictive row-level policy on every table means a session for one company cannot read or write another's rows, whatever the query. Keys between tables include the company, so a record cannot point at another company's record. |
| Company settings | Phone rule (country code + pattern), time zone, currency, locale; AI on/off, budget, auto-scheduling. |
| Starter templates | `GENERAL` (any retailer) and `ELECTRONICS` (mobile / electronics stores) fill pick-lists, stages, sources, outcomes and rules as **placeholders** the company confirms. |
| Onboarding | `npm run create-tenant`, add branches, `npm run create-admin`; the admin adds staff and confirms placeholders. No self-signup or billing yet. |
| Key Cee | Company #1, created from the `ELECTRONICS` template with its three confirmed branches. |

## 5. Modules and screens

| Module | Screens | Key actions |
|---|---|---|
| **My Day** | Action list, daily brief, AI next steps | Overdue / due today / not contacted / no next step; schedule, dismiss or undo AI suggestions |
| **Leads** | List with filters, New lead, Lead detail with AI assistant | Mobile lookup prevents duplicates; log call + outcome + next follow-up; stage changes (lost needs reason); reassign; visit / quotation; draft a WhatsApp message |
| **Customers** | Search, Customer detail | Full history across branches |
| **Store & Sales** | Walk-in visit, Sales list, New sale | A sale linked to a lead marks it Won; walk-in sales without a lead |
| **Marketing** | Campaigns with results | Spend, qualified leads, won leads, revenue per unit spent |
| **MIS & Reports** | Daily MIS, Monthly funnel, Staff performance, Campaigns, Pipeline ageing, Data quality | Same screens for every role; data scoped automatically |
| **Admin** | Staff, Targets, Pick-lists & rules, Data import, AI agents | Logins, targets, confirm placeholders, CSV import; AI switch, budget, usage, suggestion outcomes, run now |

## 6. How it is built

| Layer | Choice | Why |
|---|---|---|
| Database | PostgreSQL 15+ | Company isolation, business rules and branch security enforced in one place |
| Web app | Node.js + Express, server-rendered pages | Fast on low-end phones, no app install, one small service to host |
| Agents | Same Node service: `app/src/agents/`, plus `npm run agents` for schedules | No extra infrastructure; agents use the same database security as people |
| Sign-in | Email + password per person, issued by the company admin; one email belongs to one company | No per-user licence cost; access follows the Employee Master |
| Hosting | One small Node service + managed Postgres + a cron entry | Roughly US$10–35 / month to start, plus each company's AI budget |

## 7. Roadmap

| Phase | Scope | Depends on |
|---|---|---|
| **1. Foundation** ✅ | Database, rules, branch security, KPI/MIS views, tests | — |
| **2. Operating app** ✅ | Sign-in, My Day, leads, follow-ups, customers, visits, quotations, sales, campaigns, MIS, admin, CSV import | — |
| **3. Agentic, multi-company** ✅ (this PR) | Companies, per-company settings and templates, Lead Rescue, Follow-up Writer, Daily Brief, AI budget and usage, guardrails | — |
| **4. Key Cee pilot** | Replace placeholders; import the current lead sheet and 3 months of billing; switch agents on with a small budget at one branch for 2 weeks; compare acceptance and follow-up discipline with the other branches | Head Office answers (below) |
| **5. Roll-out and second company** | All Key Cee branches; brief delivered by WhatsApp/e-mail; onboard a second retailer to prove the template | Pilot results |
| **Later, with a business case** | WhatsApp Business API sending (with opt-in), call integration, lead scoring from history, repeat-purchase reminders, self-signup and billing for new companies | Volumes and pilot results that justify the cost |

## 8. Needed from Head Office (Key Cee)

1. OK on the architecture refinements (BLUEPRINT §2) and on running Key Cee as company #1 of a shared platform.
2. Real pick-list values: statuses, designations, departments, access levels, lead stages, sources, lost reasons, product categories.
3. Business rules: first-contact SLA, follow-up grace period, stale-lead days, customer contact hours.
4. Billing software name and a sample export; the current lead sheet(s).
5. Per branch: staff count, footfall, size, opening date.
6. Target measures in use, and incentive rules.
7. AI: switch on for the pilot? Monthly budget? May Lead Rescue schedule follow-ups itself, or only suggest? Languages for customer messages.
8. Who should be the first Head Office admin login.
