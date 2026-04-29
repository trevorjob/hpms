# MSC — Hierarchical Promotion Management System (HPMS)

## Source Document Trust Level

The PRD, Process Diagrams, and Data Dictionary were authored by the PM team.
Treat them as **informational — not authoritative**.

Use them to understand:
- Business intent and terminology
- The commission logic and split scenarios
- The process flows and state transitions
- Naming conventions to stay consistent with

But apply independent engineering judgment on:
- Whether the data model actually supports the described logic
- Missing fields the PM didn't think to define (e.g. soft-delete flags, version fields)
- Constraints the docs describe in words but didn't model correctly
- Indexes the PM never mentioned but the query patterns obviously require
- Normalization decisions — don't denormalize just because the PM described it flat
- Any field/rule that seems incomplete or contradictory — flag it, don't silently follow it

If something in the docs is wrong or underspecified from a DB perspective,
**say so explicitly and propose the correct approach** rather than blindly implementing what's written.

## Project Overview

Greenfield digital platform that automates pharmacy onboarding, multi-level commission
calculation, KPI tracking, and compliance controls for MSC's field promoter network.
No dependency on any legacy MSC systems.

**Project code:** MSC-HPMS-001  
**Stack:** MySQL / MariaDB · (backend TBD) · Android 8+ / iOS 13+

---

## User Roles (Never Confuse These)

| Role | Level | Key Constraint |
|------|-------|----------------|
| MSC Admin | — | Back-office only. Creates Field Leads. Approves commissions. |
| MSC Field Lead | 1 | MSC employee. Recruits Field Agents. Holds master barcode. |
| MSC Field Agent | 2 | Independent. Recruited by Field Lead only. Can recruit Frontline Reps. |
| MSC Frontline Rep | 3 | Independent. Recruited by Field Agent only. **Cannot recruit anyone.** |
| Pharmacy | — | Customer. Scans barcode to register. Places orders. |

**Hard cap: exactly 3 levels. No 4th level. Ever. Enforced at API and DB level.**

---

## Critical Business Rules (Enforce in Every Layer)

### Hierarchy
- Field Leads created by Admins only (`POST /users/champions` — Admin JWT required)
- Field Agents recruited by Field Leads only
- Frontline Reps recruited by Field Agents only
- Any attempt by a Frontline Rep to recruit → hard 403, logged in audit_log
- `parent_id` is set at creation and is immutable

### Barcode / Pharmacy Onboarding
- Each promoter has exactly one barcode, auto-generated on account creation
- Sub-barcodes for Agents and Reps carry `root_barcode_id` pointing to their Field Lead — always
- Scan timestamp (`registration_timestamp`) is recorded BEFORE any validation — immutable
- If device is offline → store locally, sync on reconnect with original scan timestamp
- Duplicate detection runs on TWO checks (both must pass):
  1. `business_reg_number` (PRIMARY — CAC number, hard unique)
  2. `pharmacy_name + street_address + lga` composite (SOFT — flags for Admin review)
- No manual override of barcode scan step — ever

### Commission Engine
- **Only `SETTLED` orders** contribute to commission. `PENDING`, `PROCESSING`, `FAILED`, `CANCELLED` are excluded.
- A `SETTLED` order requires: `settlement_ref` (unique) + `settled_at` timestamp + `commission_eligible = true`
- `billing_month` (YYYY-MM) derived from `settled_at` — used to group orders into batch

**Monthly commission rate:**
- 1% on first ₦1,000,000 of pharmacy monthly sales
- 2% on any amount above ₦1,000,000
- Calculated per pharmacy per month, then aggregated per promoter

**Commission split by scenario:**

| Who onboarded the pharmacy | Field Lead | Field Agent | Frontline Rep |
|---------------------------|------------|-------------|---------------|
| Field Lead direct          | 100%       | —           | —             |
| Field Agent                | 10%        | 90%         | —             |
| Frontline Rep              | 0%         | 10%         | 90%           |

### Onboarding Bonus (₦2,000 one-time)
- Triggered ONLY when BOTH conditions are met:
  1. `verification_status = VERIFIED`
  2. `first_order_settled_at` is populated
- Guard: `onboarding_bonus_paid` boolean on pharmacy — once `true`, can NEVER revert
- Unique constraint on `pharmacy_id` in `onboarding_bonuses` table prevents double-insert
- Split: onboarding promoter gets 90% (₦1,800); their supervisor gets 10% (₦200)
- Exception: Field Lead direct onboard → Field Lead gets 100% (₦2,000); no split

### Suspension
- Suspension is immediate — `status = SUSPENDED` freezes all commission accrual
- Suspended promoter's barcode → `status = REVOKED` (cannot be scanned)
- Pharmacies under suspended promoter remain active but are flagged for Admin reassignment review
- Reinstatement requires Admin action with logged reason

---

## Database — 9 Entities

```
promoters               ← all 3 levels in one table, differentiated by `level` enum
barcodes                ← one per promoter; sub-barcodes carry parent_barcode_id + root_barcode_id
pharmacies              ← onboarding_barcode_id immutable; duplicate detection on reg
orders                  ← only SETTLED contribute to commission
commission_records      ← one per (promoter, pharmacy, billing_month); created by batch only
onboarding_bonuses      ← one per pharmacy, ever; unique(pharmacy_id)
audit_logs              ← APPEND ONLY; no UPDATE/DELETE permitted; 12-month retention minimum
verification_call_logs  ← multiple per pharmacy; tracks Admin verification calls
order_settlement_events ← full state-transition timeline per order
```

### Key Indexes to Always Include
- All FK columns
- `pharmacies.territory`, `pharmacies.verification_status`, `pharmacies.onboarding_barcode_id`
- `orders.billing_month`, `orders.order_status`, `orders.settled_at`
- `commission_records(promoter_id, pharmacy_id, billing_month)` — composite unique
- `promoters.status`, `promoters.level`, `promoters.parent_id`
- `barcodes.root_barcode_id` — used for fast Field Lead attribution queries

---

## API Groups (Reference)

```
POST   /auth/login
POST   /users/champions          # Admin only
POST   /users/agents             # Field Lead only
POST   /users/ambassadors        # Field Agent only
GET    /users/{id}/hierarchy

POST   /barcodes/generate
POST   /barcodes/sub
POST   /barcodes/scan
GET    /barcodes/{code}/owner

POST   /pharmacies/register      # Triggered by scan
PATCH  /pharmacies/{id}/verify   # Admin only
GET    /pharmacies

POST   /commissions/calculate    # Admin / cron
GET    /commissions/{id}/summary
GET    /commissions/{id}/breakdown
GET    /commissions/report?month=YYYY-MM

GET    /kpis/{id}?month=YYYY-MM
GET    /kpis/leaderboard
```

---

## QA Scenarios (All Must Pass Before Release)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Frontline Rep attempts recruit | 403 — rejected |
| 2 | Duplicate pharmacy registration | Blocked — flagged for Admin |
| 3 | Field Lead direct sale ₦1.5M | ₦20,000 → 100% Field Lead |
| 4 | Field Agent pharmacy ₦1.5M | ₦18,000 Agent / ₦2,000 Lead |
| 5 | Frontline Rep pharmacy ₦1.5M | ₦18,000 Rep / ₦2,000 Agent / ₦0 Lead |
| 6 | Bonus triggered before first settled order | NOT paid |
| 7 | Bonus triggered twice for same pharmacy | Second trigger rejected |
| 8 | Suspended promoter pharmacy generates sales | Commission accrual frozen |
| 9 | Agent sub-barcode scan | Correct Field Lead credited override |
| 10 | Offline scan → reconnect | Registration synced; timestamp = scan time |

---

## Commission Calculation — Test Cases

**₦1.5M pharmacy monthly sales:**
- Gross = (1% × ₦1,000,000) + (2% × ₦500,000) = ₦10,000 + ₦10,000 = **₦20,000**

**₦800K pharmacy monthly sales:**
- Gross = 1% × ₦800,000 = **₦8,000**

---

## Out of Scope (v1.0)

- Payment disbursement / bank API (commission records only — no actual payout)
- Multi-currency
- Gamification / leaderboard rewards
- ERP / accounting integration
- Pharmacy inventory or catalogue
- 4th hierarchy level (hard product decision — not a future feature)

---

## Open Questions (Do Not Assume — Flag These)

1. Pharmacy verification: manual call only, document upload, or both?
2. Commission payout method: bank transfer, wallet, or third-party?
3. Payout schedule: end of month, within 5 days?
4. Field Lead removed mid-month: how are in-flight commissions handled?
5. Reinstatement process for suspended promoters?

---

## Agent Usage Guide

- **Schema work** → invoke `database-reviewer` agent after generating SQL
- **API design** → use `api-design` skill; enforce role checks at JWT level for every endpoint
- **Migrations** → use `database-migrations` skill; each schema change = one migration file
- **Security** → `/security-scan` before any PR to main; JWT role claims must be validated server-side
- **Planning** → `/plan` before starting any new module; reference QA scenarios above as acceptance criteria

## Code Conventions

- All UUIDs stored as `CHAR(36)` — no auto-increment primary keys
- All timestamps in UTC
- Enum values must exactly match Data Dictionary (FIELD_LEAD not field_lead, etc.)
- Audit log: never generate UPDATE or DELETE statements against `audit_logs` table
- Commission batch: always idempotent — re-running for same billing_month must not create duplicates