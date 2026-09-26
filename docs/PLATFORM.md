# Key Cee Central CRM & BI — Platform Brainstorm

Companion to [BLUEPRINT.md](BLUEPRINT.md) (data model, rules, KPIs). This page is
the product view: who uses the platform, what they do each day, which screens
exist, and the order in which it grows.

## 1. Vision

One system where every customer enquiry at any Key Cee branch is captured,
owned, followed up and traced to a sale, so Head Office can see each day
where revenue is being won and where it is leaking, and act on it.

Success is measured by business outcomes, not by usage:

| Outcome | Measured by |
|---|---|
| Fewer lost enquiries | % of leads contacted within SLA; open leads with no next follow-up → 0 |
| Better follow-up discipline | Follow-up on-time % per staff and branch |
| Higher conversion | Won ÷ qualified leads, by branch, source and staff |
| Marketing spend that pays | Revenue per ₹ spent and cost per won lead, per campaign |
| Trustworthy MIS | Data-quality issue count trending down |

## 2. Users and their day

| User | Their day in the platform | Sees |
|---|---|---|
| **Sales staff / telecaller** | Opens *My Day*: overdue follow-ups first, then due today, then new leads. Calls, logs the outcome and sets the next follow-up in one step. Adds walk-in enquiries as leads. | Own leads |
| **Branch Manager** | Morning: branch Daily MIS and action list (uncontacted, overdue, stale). Reassigns leads, checks each staff member's follow-up discipline, enters or verifies sales. | Own branch |
| **Head Office admin / CRM executive** | Cross-branch MIS, campaign performance, data-quality queue. Manages staff, targets, pick-lists, campaigns; imports billing and lead data. | All branches |
| **Management (read-only)** | Monthly funnel, branch and staff performance, marketing return. | All branches, no edits |

## 3. Modules and screens

| Module | Screens | Key actions |
|---|---|---|
| **My Day** | Action list | Overdue / due today / not contacted / no next step, with one-tap open |
| **Leads** | List with filters, New lead, Lead detail | Mobile lookup prevents duplicate customers; log call + outcome + next follow-up; change stage (lost needs reason); reassign; add visit / quotation |
| **Customers** | Search, Customer detail | Full history across branches: leads, visits, sales |
| **Store & Sales** | Walk-in visit, Sales list, New sale | A sale linked to a lead marks it Won automatically; walk-in sales recorded without a lead |
| **Marketing** | Campaigns list with results, New campaign | Spend, qualified leads, won leads, revenue per ₹ |
| **MIS & Reports** | Daily MIS, Monthly funnel, Staff performance, Campaigns, Pipeline ageing, Data quality, Setup gaps | Same screens for every role; data scoped automatically |
| **Admin** | Staff (Employee Master), Targets, Pick-lists & rules, Data import | Create logins, set monthly targets, confirm placeholder values, import leads/sales CSV |

## 4. How it is built

| Layer | Choice | Why |
|---|---|---|
| Database | PostgreSQL (Supabase, or any Postgres host) | Business rules and branch security enforced in one place |
| Web app | Node.js + Express, server-rendered pages | Fast on low-end phones, no app install, one small service to host, easy to maintain |
| Sign-in | Staff login (email + password) managed by Head Office | No per-user licence cost; access follows the Employee Master |
| Security | Every page runs its queries *as the signed-in employee* | A bug in a screen cannot show another branch's data; the database refuses |
| Hosting | One small Node service (e.g. Render / Railway / a VPS) + managed Postgres | Roughly US$10–35 / month to start |

## 5. Roadmap

| Phase | Scope | Depends on |
|---|---|---|
| **1. Foundation** ✅ | Database, rules, branch security, KPI/MIS views, tests | — |
| **2. Operating app** ✅ (this PR) | Sign-in, My Day, leads, follow-ups, customers, visits, quotations, sales, campaigns, MIS screens, admin, CSV import | — |
| **3. Go-live pilot** | Replace placeholders with real values; import current lead sheet and 3 months of billing; pilot at one branch for 2 weeks; fix what staff struggle with | Head Office answers (below) |
| **4. Roll-out** | All three branches; daily MIS e-mail/WhatsApp summary to managers; target & incentive tracking | Pilot feedback, incentive rules |
| **5. Intelligence** | Lead scoring from history, best time to call, repeat-purchase / upgrade reminders (e.g. phone age), AI-written management commentary on the MIS | 3–6 months of clean data |
| **Later, with a business case** | Click-to-call / call recording integration, WhatsApp Business API, Samsung promo/offer tracking, customer-facing enquiry forms feeding leads directly | Volumes that justify the cost |

## 6. Needed from Head Office

1. OK on the five architecture refinements (BLUEPRINT §2).
2. Real pick-list values: statuses, designations, departments, access levels, lead stages, sources, lost reasons, product categories.
3. Business rules: first-contact SLA, follow-up grace period, stale-lead days.
4. Billing software name and a sample export; the current lead sheet(s).
5. Per branch: staff count, footfall, size, opening date.
6. Target measures in use, and incentive rules.
7. Who should be the first Head Office admin login.
