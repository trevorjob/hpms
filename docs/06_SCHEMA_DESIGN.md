# MSC HPMS — Schema Design Document

> **Hierarchical Promotion Management System · Database Architecture · v1.0**

| | |
|---|---|
| **Project code** | MSC-HPMS-001 |
| **Target engine** | MySQL 8.0+ / MariaDB 10.5+ |
| **Charset / collation** | `utf8mb4` / `utf8mb4_unicode_ci` (matches house) |
| **Storage timezone** | UTC (display in Africa/Lagos at app boundary — see D-018) |
| **Migration** | Flyway — `src/main/resources/db/migration/V1__init.sql` |
| **Document version** | 1.0 |
| **Status** | Pending CTO sign-off |
| **Companion docs** | [07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md) · [08_DEVIATIONS.md](./08_DEVIATIONS.md) · [01_ARCHITECTURE.md](./01_ARCHITECTURE.md) |

---

## 1. Executive Summary

This document specifies the initial database schema for the MSC Hierarchical Promotion
Management System (HPMS) — a greenfield platform that automates pharmacy onboarding,
three-tier commission calculation, KPI tracking, and compliance controls for the MSC
field promoter network.

HPMS is a **modular monolith** (Spring Boot) integrating with the existing MSC main app.
Pharmacy orders, payments, and promoter wallet payouts live in the main app; HPMS owns
hierarchy, attribution, commission calculation, bonus eligibility, and audit. Cross-system
communication uses RocketMQ events. See [01_ARCHITECTURE.md](./01_ARCHITECTURE.md) for the
full system context.

### 1.1 What this schema enables

- End-to-end pharmacy onboarding from barcode scan to verification to bonus disbursement,
  with immutable ownership timestamps that resolve attribution disputes.
- A strict three-level promoter hierarchy (Field Lead → Field Agent → Frontline Rep)
  hard-capped across the DB and application layers.
- Monthly commission calculation with **idempotent batch re-runs** — composite uniqueness
  on `commission_records` makes double-counting structurally impossible.
- Explicit batch-run records (`commission_batches`) tied to xxl-job execution for
  observable, retryable monthly runs.
- Read-mirrored order data from the main app (RocketMQ projection), with structural
  guards that protect the commission engine from a buggy projector.
- A **tamper-resistant audit trail** meeting the 12-month compliance retention requirement,
  enforced two ways: DB triggers AND a least-privilege GRANT for the application user.
- A one-time onboarding bonus guarded by `UNIQUE(pharmacy_id)` at the DB and a
  three-condition workflow at the app layer.

### 1.2 Design philosophy — where rules live

The database enforces **structural invariants only**:

- Referential integrity (foreign keys)
- Uniqueness (including composite batch idempotency)
- `NOT NULL` on genuinely required fields
- Compliance-mandated immutability (`audit_logs` append-only)
- Basic type/range sanity (e.g., `order_value > 0`)

**Business rules live in the application layer.** Commission splits, bonus amounts,
workflow state transitions, format validation, cross-row checks, and field immutability
are enforced by services and covered by unit tests. The full catalogue is in
[07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md).

**Why this split?** Business rules change — Finance adjusts splits, Product adds tiers,
Legal tweaks compliance thresholds. Every such change encoded in DDL becomes a schema
migration. Triggers for cross-row validation add further cost: cryptic errors, hidden
side-effects, friction with bulk loads, seeds, and replication. Keeping business rules
in code makes them testable, versionable, and changeable.

### 1.3 Key design decisions

| Decision | Rationale |
|---|---|
| Three-tier hierarchy hard-capped | Structural `CHECK` at DB + parent-level check in recruitment service |
| Single `promoters` table | All three tiers in one table, differentiated by `level` ENUM |
| UUIDs as `BINARY(16)` | ~3× index/join cost reduction vs `CHAR(36)`. Matches architecture §4.3 |
| Composite commission uniqueness | `UNIQUE(promoter_id, pharmacy_id, billing_month)` — idempotent batch re-runs |
| Explicit `commission_batches` table | Each xxl-job run is a row; admins can cross-reference run failures and `commission_records.batch_id` |
| Append-only `audit_logs` (2 layers) | DB triggers + DB user GRANT (`INSERT, SELECT` only). Compliance-grade |
| Hard + soft duplicate detection | CAC number is hard `UNIQUE`; `(name, address, lga)` is non-unique KEY for Admin review |
| `net_commission` as plain column | Computed and written by batch; formula not locked into DDL |
| Polymorphic `audit_logs.actor_id` | Refers to `promoters` OR `admins`; no FK (MySQL has no union FK) |
| UTC storage timezone | Removes ambiguity; render Lagos at the JSON boundary |
| `orders` is a read-mirror | Projected from main-app RocketMQ events; no HPMS write endpoints |

---

## 2. Entity Overview

| Table | Purpose | Owner module | Est. rows @ 2-yr scale |
|---|---|---|---|
| `admins` | MSC back-office users (pending identity-pattern decision) | `core/common` | ~50 |
| `promoters` | All three tiers in one table, differentiated by `level` | `core/promoter` | ~20,000 |
| `barcodes` | One barcode per promoter; `parent_barcode_id` chain + `root_barcode_id` shortcut | `core/barcode` | ~20,000 |
| `pharmacies` | Customer pharmacies. Onboarding attribution is permanent | `core/pharmacy` | ~200,000 |
| `orders` | Read-mirror of main-app orders. Only `SETTLED` contributes | `core/order` | ~10M |
| `commission_batches` | One row per xxl-job batch invocation | `core/commission` | ~24 (months) |
| `commission_records` | One row per (promoter, pharmacy, billing_month). Batch-generated | `core/commission` | ~5M |
| `onboarding_bonuses` | One row per pharmacy, ever. `UNIQUE(pharmacy_id)` is the double-payment guard | `core/bonus` | ~200,000 |
| `audit_logs` | **APPEND-ONLY** compliance ledger. 12-month minimum retention | `core/audit` | ~50M |
| `verification_call_logs` | Admin verification calls (may be deferred for MVP) | `core/pharmacy` | ~1M |
| `order_settlement_events` | State-transition projection from main-app RocketMQ events | `core/order` | ~30M |

> Row count estimates assume ~20K promoters, ~200K onboarded pharmacies, and ~4 settled
> orders per pharmacy per month over 24 months. Module ownership per
> [01_ARCHITECTURE §4.1](./01_ARCHITECTURE.md).

---

## 3. Per-Entity Breakdown

For each entity, only the fields that carry business weight are listed. Standard
timestamps and surrogate keys are omitted unless they carry unusual semantics.

### 3.1 `promoters`

> All three tiers in one table. Self-referencing `parent_id`. Row shape governed by `level`.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `promoter_id` | `BINARY(16)` | UUID primary key |
| `level` | `ENUM` | `FIELD_LEAD` / `FIELD_AGENT` / `FRONTLINE_REP`. Immutable (app, I-003) |
| `parent_id` | `BINARY(16)` FK | `NULL` iff `FIELD_LEAD`. Must reference correct-level parent (I-001). Immutable |
| `phone_number` | `VARCHAR(16)` | `UNIQUE`. Nigerian `+234` format (I-080) |
| `email_address` | `VARCHAR(255)` | `UNIQUE` if provided. Required for `FIELD_LEAD` (I-006) |
| `barcode_id` | `BINARY(16)` FK | `UNIQUE` 1:1 with `barcodes`. Nullable only at insert-time (D-002) |
| `status` | `ENUM` | `ACTIVE` / `SUSPENDED` / `INACTIVE` / `PENDING`. `SUSPENDED` freezes accrual (I-045) |
| `suspension_reason` | `VARCHAR(500)` | Required when `status = SUSPENDED` (I-005) |
| `territory` | `VARCHAR(100)` | Assigned state/region. Indexed for geographic reporting |
| `cross_region_approved` | `BOOLEAN` | Default `0`. Admin-only flag |
| `created_by` | `BINARY(16)` | Polymorphic — admin for `FIELD_LEAD`, promoter for AGENT/REP (I-004) |

**DB-enforced:** `chk_promoters_hierarchy` (structural shape), FK to `parent_id`,
`UNIQUE` on phone/email/barcode_id.

### 3.2 `barcodes`

> Every promoter has exactly one barcode. Sub-barcodes carry `parent_barcode_id`;
> `root_barcode_id` always points to the Field Lead.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `barcode_code` | `VARCHAR(32)` | `UNIQUE`. Format `MSC-FL-NNNNNN` / `MSC-AG-NNNNNN` / `MSC-FR-NNNNNN` (I-015) |
| `qr_payload` | `VARCHAR(512)` | `UNIQUE`. Barcode code + integrity checksum |
| `promoter_id` | `BINARY(16)` FK | `UNIQUE` 1:1. Cannot be reassigned (I-013) |
| `parent_barcode_id` | `BINARY(16)` FK | `NULL` for Field Leads. Aligned with owner's `promoters.parent_id` (I-012) |
| `root_barcode_id` | `BINARY(16)` FK | Always the Field Lead's barcode; equals `barcode_id` for Leads themselves |
| `status` | `ENUM` | `ACTIVE` / `REVOKED`. Revoked barcodes cannot be scanned (I-014) |

### 3.3 `pharmacies`

> Customer entities. Onboarding attribution is permanent. Online-only registration —
> offline scan was dropped from MVP at Sprint 1 kickoff.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `business_reg_number` | `VARCHAR(16)` | **HARD** `UNIQUE`. CAC number. Primary duplicate-detection field |
| `nafdac_licence_number` | `VARCHAR(32)` | `UNIQUE` if present. Multiple NULLs permitted (D-016) |
| `(name, street_address, lga)` | composite KEY | **SOFT** duplicate detection — flags for Admin review (I-020). Does not block |
| `onboarding_barcode_id` | `BINARY(16)` FK | Barcode scanned at registration. Immutable (I-022) |
| `onboarding_promoter_id` | `BINARY(16)` FK | Denormalised from barcode. Immutable |
| `verification_status` | `ENUM` | `PENDING` / `VERIFIED` / `REJECTED`. Workflow in I-023 |
| `verified_by` | `BINARY(16)` FK | Required when `verification_status != PENDING` (I-023) |
| `rejection_reason` | `VARCHAR(500)` | Required when `REJECTED` (I-023) |
| `first_order_settled_at` | `DATETIME` | Set by integration consumer on first SETTLED event (I-024) |
| `onboarding_bonus_paid` | `BOOLEAN` | Monotonic 0 → 1 (I-025). Synced from `onboarding_bonuses.PAID` (I-054) |
| `registration_timestamp` | `DATETIME` | Server-side scan time. Immutable (I-021) |

### 3.4 `orders` (read-mirror)

> No HPMS write endpoints — populated by `OrderSettlementEventConsumer` from
> main-app RocketMQ events (I-031).

| Field | Type | Rule / Business meaning |
|---|---|---|
| `order_value` | `DECIMAL(15,2)` | NGN. `CHECK order_value > 0` |
| `order_status` | `ENUM` | `PENDING` / `PROCESSING` / `SETTLED` / `FAILED` / `CANCELLED` |
| `settled_at` | `DATETIME` | Set only on `SETTLED` |
| `settlement_ref` | `VARCHAR(100)` | `UNIQUE` when present. Required when `SETTLED` (DB CHECK) |
| `billing_month` | `CHAR(7)` | `YYYY-MM`. Derived from `settled_at` (I-032) |

**DB-enforced:** `chk_orders_settled_fields` — a `SETTLED` row without `settled_at`,
`settlement_ref`, and `billing_month` is rejected. Protects the commission engine from
a buggy projector.

### 3.5 `commission_batches`

> One row per xxl-job batch invocation. Admins can re-run via the xxl-job admin console.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `batch_id` | `BINARY(16)` | UUID PK |
| `billing_month` | `CHAR(7)` | Which month this batch processes |
| `status` | `ENUM` | `RUNNING` → `COMPLETED` \| `FAILED` \| `CANCELLED` |
| `trigger_source` | `ENUM` | `SYSTEM_CRON` (xxl-job scheduled) / `ADMIN_MANUAL` (admin re-run) |
| `triggered_by_admin_id` | `BINARY(16)` FK | Required when `ADMIN_MANUAL` |
| `xxl_job_log_id` | `BIGINT` | Cross-reference into xxl-job execution history |
| Summary counters | INT / DECIMAL | `total_orders_processed`, `total_records_upserted`, `total_gross_commission` — filled on completion |
| `error_message` | `VARCHAR(2000)` | Set when `FAILED` |

### 3.6 `commission_records`

> Batch-generated. Never inserted by hand. One row per (promoter, pharmacy, billing_month).

| Field | Type | Rule / Business meaning |
|---|---|---|
| **`UNIQUE(promoter_id, pharmacy_id, billing_month)`** | composite | **Idempotent batch guarantee** |
| `batch_id` | `BINARY(16)` FK | Last batch that touched this row (I-048) |
| `commission_type` | `ENUM` | `DIRECT` (onboarder) / `OVERRIDE` (upstream). App-enforced coherence with `split_percentage` (I-042) |
| `total_pharmacy_sales` | `DECIMAL(15,2)` | Sum of SETTLED `order_value` in the billing month |
| `gross_commission` | `DECIMAL(15,2)` | 1% of first ₦1M + 2% of excess (I-040) |
| `split_percentage` | `DECIMAL(5,2)` | 100/90/10 today. Enforced in app (D-005) |
| `net_commission` | `DECIMAL(15,2)` | App-computed: `ROUND(gross × split / 100, 2)` (I-043) |
| `status` | `ENUM` | `CALCULATED` / `APPROVED` / `DISPUTED` / `PAID`. Workflow in I-046 |
| `dispute_note` | `VARCHAR(500)` | Required when `DISPUTED` (I-046) |
| `approved_by`, `approved_at` | FK + `DATETIME` | Both required when `APPROVED` or `PAID` (I-046) |

### 3.7 `onboarding_bonuses`

> ₦2,000 one-time bonus per pharmacy. Layered double-payment guards.

| Field | Type | Rule / Business meaning |
|---|---|---|
| **`UNIQUE(pharmacy_id)`** | constraint | **DB-level guard: second INSERT impossible** |
| `total_bonus_amount` | `DECIMAL(10,2)` | Always ₦2,000 (app-enforced, I-052) |
| `recipient_1_id` / `amount` | FK + `DECIMAL` | Direct onboarder. ₦2,000 (FL direct) or ₦1,800 (Agent/Rep) |
| `recipient_2_id` / `amount` | FK + `DECIMAL` | Supervisor one level up. `NULL` iff FL direct. App verifies parent linkage (I-053) |
| `trigger_status` | `ENUM` | `WAITING_VERIFICATION` → `WAITING_FIRST_ORDER` → `READY_TO_PAY` → `PAID` (I-050) |
| `verification_met_at`, `first_order_met_at` | `DATETIME` | Both required before `READY_TO_PAY` |
| `paid_at` | `DATETIME` | Set when bonus disbursed. Terminal state (I-055) |

### 3.8 `audit_logs` [APPEND-ONLY]

> Compliance ledger. No `UPDATE` or `DELETE` — ever.
> **Two-layer enforcement:** DB triggers raise SQLSTATE 45000, AND the application DB
> user holds only `INSERT, SELECT` privileges on this table (D-007).

| Field | Type | Rule / Business meaning |
|---|---|---|
| `actor_id` | `BINARY(16)` | No FK (polymorphic — promoters or admins). Resolved by `actor_role` (I-062) |
| `actor_role` | `ENUM` | `ADMIN` / `FIELD_LEAD` / `FIELD_AGENT` / `FRONTLINE_REP` / `SYSTEM` |
| `action_type` | `ENUM` | 11 values covering account, pharmacy, commission, bonus, barcode, dispute events |
| `entity_type`, `entity_id` | `ENUM` + `BINARY(16)` | Polymorphic reference. Composite indexed |
| `previous_state`, `new_state` | `JSON` | Before/after snapshots (I-061) |
| `reason` | `VARCHAR(500)` | Required for `SUSPEND` / `REJECT` / `DISPUTE_*` (I-060) |
| `ip_address` | `VARCHAR(45)` | IPv6-safe. `NULL` for `SYSTEM` actions |

### 3.9 `verification_call_logs`

> Admin verification calls. Many per pharmacy. **May be deferred for MVP** — Q3 in
> [02_PROJECT_CONTEXT](./02_PROJECT_CONTEXT.md). Table exists so post-MVP rollout is an
> enable, not a migration.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `call_outcome` | `ENUM` | `CONFIRMED` / `SUSPICIOUS` / `NO_ANSWER` / `WRONG_NUMBER` / `CALLBACK_REQUESTED` |
| `follow_up_required` | `BOOLEAN` | Auto-set in app on `SUSPICIOUS` / `CALLBACK_REQUESTED` (I-070) |
| `follow_up_date` | `DATE` | Required when `follow_up_required = 1` (I-071) |
| `follow_up_done` | `BOOLEAN` | Auto-flipped when a later call log exists (I-072) |

### 3.10 `order_settlement_events`

> Append-only projection of main-app order state transitions. Consumed via RocketMQ.

| Field | Type | Rule / Business meaning |
|---|---|---|
| `from_status` / `to_status` | `ENUM` | `from_status` `NULL` only on `ORDER_CREATED` |
| `event_type` | `ENUM` | `ORDER_CREATED` / `PAYMENT_INITIATED` / `PAYMENT_CONFIRMED` / `ORDER_SETTLED` / `ORDER_FAILED` / `ORDER_CANCELLED` |
| `settlement_ref` | `VARCHAR(100)` | `UNIQUE` when present. Required on `ORDER_SETTLED` |
| `commission_eligible` | `BOOLEAN` | App-set: `true` iff `event_type = ORDER_SETTLED` AND `order_value > 0` (I-033) |
| `billing_month` | `CHAR(7)` | `YYYY-MM`. Set when `commission_eligible = 1` |
| `gateway_response` | `JSON` | Raw payment gateway payload from main app. Encrypted at rest (app layer) |
| `triggered_by` | `ENUM` | `SYSTEM` / `PAYMENT_GATEWAY` / `ADMIN` |

---

## 4. Commission Logic

### 4.1 Rate tiers (per pharmacy, per month)

| Monthly pharmacy sales | Rate | Commission on that tier |
|---|---|---|
| First ₦1,000,000 | 1% | Up to ₦10,000 |
| Every ₦ above ₦1,000,000 | 2% | Uncapped |

**Worked examples** (test cases in I-040):

- ₦1,500,000 monthly sales → (1% × ₦1M) + (2% × ₦500K) = ₦10,000 + ₦10,000 = **₦20,000** gross
- ₦800,000 monthly sales → 1% × ₦800K = **₦8,000** gross
- ₦1,000,000 exact → **₦10,000** gross

### 4.2 Split scenarios

The split depends on the `level` of the promoter who directly onboarded the pharmacy
(the owner of the scanned barcode).

| Who onboarded the pharmacy | Field Lead | Field Agent | Frontline Rep | `commission_type` |
|---|---|---|---|---|
| Field Lead direct | 100% | — | — | DIRECT (Lead only) |
| Field Agent | 10% | 90% | — | OVERRIDE / DIRECT |
| Frontline Rep | 0% | 10% | 90% | OVERRIDE / DIRECT |

> The Lead's 0% row under a Frontline Rep onboard is **not created** — no commission row
> means no commission. ⚠️ Pending PM confirmation (Q1 in 02_PROJECT_CONTEXT).

### 4.3 Enforcement split

| Rule | Where enforced |
|---|---|
| `UNIQUE(promoter_id, pharmacy_id, billing_month)` | **DB** — idempotent batch re-runs |
| Only `SETTLED` orders feed the batch | **DB** `chk_orders_settled_fields` + **app** filter (I-030) |
| `settlement_ref` globally unique | **DB** `UNIQUE` on both `orders` and `order_settlement_events` |
| Rate tiers (1% / 2%) | **App** — `CommissionCalculator` (I-040) |
| Split matrix (100 / 90 / 10) | **App** — `CommissionSplitter` (I-041) |
| `net_commission` formula | **App** (I-043), with unit tests asserting the result on every inserted row |
| `commission_type` ↔ `split_percentage` coherence | **App** (I-042) |
| Suspended promoters skipped | **App** (I-045) |
| Status workflow | **App** `CommissionWorkflowService` (I-046) |
| Batch run record creation | **App** — `CommissionBatchJob` (xxl-job handler) (I-048) |
| Approved-batch event publish | **App** — `CommissionWorkflowService` → RocketMQ (I-047) |

### 4.4 Onboarding bonus (₦2,000 one-time)

Paid once per pharmacy once both conditions are met (I-050):

1. `verification_status = VERIFIED`, AND
2. `first_order_settled_at` is populated.

| Onboarder level | Recipient 1 (onboarder) | Recipient 2 (supervisor) |
|---|---|---|
| Field Lead direct | ₦2,000 (100%) | — (null) |
| Field Agent | ₦1,800 (90%) — to Agent | ₦200 (10%) — to Lead |
| Frontline Rep | ₦1,800 (90%) — to Rep | ₦200 (10%) — to Agent |

When `trigger_status` reaches `READY_TO_PAY`, HPMS publishes `OnboardingBonusReadyEvent`
to RocketMQ; main app credits the bonus and (optionally) confirms back, prompting
HPMS to flip to `PAID` (I-056).

---

## 5. Integrity Controls

### 5.1 Three-level hierarchy cap

| Layer | Mechanism |
|---|---|
| **DB (structural)** | `CHECK chk_promoters_hierarchy` — `FIELD_LEAD` ⇔ `parent_id` NULL; AGENT/REP ⇔ `parent_id` NOT NULL |
| **App (parent level)** | Recruitment endpoints verify parent's `level` matches expectation (I-001) |
| **App (recruitment rights)** | JWT role guard on recruit endpoints; Frontline Reps cannot recruit (I-002) |
| **App (immutability)** | `PromoterUpdateService` rejects PATCHes touching `parent_id` or `level` (I-003) |
| **Audit** | Every recruitment attempt written to `audit_logs` |

### 5.2 Duplicate pharmacy detection

| Check | Layer | Behaviour |
|---|---|---|
| `business_reg_number` (CAC) | **HARD** DB `UNIQUE` | Second `INSERT` fails. No override. |
| `(name, street_address, lga)` | **SOFT** non-unique KEY | App `SELECT`s before `INSERT` and flags matches for Admin review |
| `nafdac_licence_number` | `UNIQUE` if present | Multiple NULLs permitted (standard MySQL) |

### 5.3 Onboarding bonus double-payment guard

Three layered mechanisms — each alone would prevent double-payment:

1. **DB (race-safe)** — `UNIQUE(pharmacy_id)` on `onboarding_bonuses`. Second INSERT fails.
2. **App (workflow)** — `trigger_status` cannot transition to `PAID` without both
   `verification_met_at` AND `first_order_met_at` populated (I-050).
3. **App (monotonic flag)** — `pharmacies.onboarding_bonus_paid` cannot flip 1 → 0 (I-025).
   Synced in the same transaction as the bonus `PAID` transition (I-054).

### 5.4 Audit trail (compliance-grade, two-layer enforcement)

| Layer | Mechanism |
|---|---|
| DB triggers | `BEFORE UPDATE` / `BEFORE DELETE` raise SQLSTATE 45000 |
| DB grant | Application user holds `INSERT, SELECT` only on `audit_logs`. `UPDATE`/`DELETE` privileges are NOT granted at all |
| Retention | 12-month minimum. Archival job pending Ops decision (Q7) |
| Polymorphic actor | `actor_id` has no FK; `actor_role` disambiguates |
| Mandatory reason | App-enforced for `SUSPEND` / `REJECT` / `DISPUTE_*` (I-060) |

The grant layer covers the case where someone with `SUPER` or `TRIGGER` privilege bypasses
the triggers — only a DBA with elevated rights could touch the table at all. See
[01_ARCHITECTURE §6](./01_ARCHITECTURE.md) and [08_DEVIATIONS D-007](./08_DEVIATIONS.md).

### 5.5 Commission integrity

- Only `SETTLED` orders are eligible — DB `CHECK` couples `order_status = SETTLED` to
  non-null `settlement_ref`, `settled_at`, and `billing_month`.
- `settlement_ref` is `UNIQUE` on both `orders` and `order_settlement_events`. Protects
  against duplicate event delivery from RocketMQ.
- `UNIQUE(promoter_id, pharmacy_id, billing_month)` makes monthly batch re-runs idempotent
  by construction (`INSERT ... ON DUPLICATE KEY UPDATE`).
- Each batch run is recorded in `commission_batches`; `commission_records.batch_id`
  attributes every row to the run that produced it.
- Formula correctness verified by unit test, not DDL — see I-043.

### 5.6 Immutability guarantees

| Field | Layer | Notes |
|---|---|---|
| `promoters.parent_id` | App (I-003) | Enforced by update service |
| `promoters.level` | App (I-003) | Enforced by update service |
| `pharmacies.onboarding_barcode_id` | App (I-022) | |
| `pharmacies.onboarding_promoter_id` | App (I-022) | |
| `pharmacies.registration_timestamp` | App (I-021) | Server-side scan time |
| `pharmacies.onboarding_bonus_paid` | App (I-025) | Monotonic 0 → 1 only |
| `barcodes.promoter_id` | App (I-013) | 1:1, cannot be reassigned |
| `barcodes.parent_barcode_id`, `root_barcode_id` | App (I-013) | Field Lead attribution is permanent |
| `audit_logs` (entire row) | **DB triggers + GRANT** | Compliance enforcement |

---

## 6. Index Strategy

Every foreign key is indexed (InnoDB does not always auto-index the referencing side).
Additional indexes target the hottest query patterns.

### 6.1 Hot-path queries

| Query pattern | Index | Why |
|---|---|---|
| Commission batch window | `orders(order_status, billing_month)` | Batch scans SETTLED rows for a billing month |
| Monthly commission report | `commission_records(billing_month, status)` | Admin report filter |
| KPI leaderboard (post-MVP) | `commission_records(billing_month, status, promoter_id, net_commission)` | Covering index — avoids clustered-index lookups |
| "Which records did this batch produce" | `commission_records(batch_id)` | Cross-reference batch → rows |
| "Latest run for a month" | `commission_batches(billing_month, started_at)` | Most-recent-batch lookup |
| Field Lead attribution | `barcodes(root_barcode_id)` | Every barcode carries the Lead's barcode as root |
| Batch settlement scan | `order_settlement_events(commission_eligible, billing_month)` | Filters eligible events by month |
| Overdue-followup dashboard | `verification_call_logs(follow_up_required, follow_up_done, follow_up_date)` | Compliance dashboard filter |
| Audit trail by entity | `audit_logs(entity_type, entity_id)` | Lookup full history for one record |
| Pharmacy attribution | `pharmacies(onboarding_barcode_id)` + `(onboarding_promoter_id)` | Commission engine starting point |
| Soft duplicate detection | `pharmacies(pharmacy_name, street_address, lga)` | App `SELECT` before every `INSERT` |

### 6.2 Indexing philosophy

- Every FK is explicitly indexed — explicit survives migrations cleanly.
- Composite indexes ordered by selectivity unless query patterns require otherwise.
- Covering indexes only where read volume justifies the write cost (currently the
  leaderboard).
- No triggers on hot-path tables (`orders`, `commission_records`, `order_settlement_events`)
  — trigger overhead on batch INSERT and on RocketMQ projection would be significant.

---

## 7. Open Questions for Finance, Ops, and Integration

The schema accommodates all outcomes, but the following business and integration questions
gate go-live readiness.

| # | Question | Impact |
|---|---|---|
| Q1 | Field Lead 0% on Rep-onboarded pharmacies — confirmed? | Affects which `commission_records` rows the batch creates. No DDL impact |
| Q2 | Pharmacy reassignment when onboarder is suspended | Schema does not model reassignment. Need `pharmacy_assignments` table or documented policy |
| Q3 | MVP verification — call-log workflow or simple toggle? | If toggle, `verification_call_logs` is dormant for MVP |
| Q4 | Cross-region Field Lead approval in MVP? | `cross_region_approved` flag exists; question is whether it's exposed in MVP UI |
| Q5 | Reinstatement workflow for suspended promoters? | Status transitions currently unconstrained; may need state-machine table |
| Q6 | Commission rounding mode — banker's vs half-up? | App-layer decision (I-040); changes `CommissionCalculator` implementation |
| Q7 | Audit log archival — where and how? | 12-month retention enforced; archival target (cold storage) unspecified |
| Q8 | Suspension mid-month effect on OVERRIDE commissions upstream? | Affects batch filter logic |
| Q9 | Reserved UUID for `audit_logs.actor_id` on `SYSTEM` events? | Proposed: `00000000-0000-0000-0000-000000000000`. Confirm with ops |
| Q10 | Identity pattern A vs B (HPMS users vs main-app users)? | Affects `admins`, `created_by`, `verified_by`, `approved_by`. Resolved in main-app integration design |

---

## 8. Sign-off

This schema is proposed for CTO approval. Sign-off acknowledges that:

- The engineering choices documented here correctly express the PRD v2.0 business rules
  and align with the architecture decisions in [01_ARCHITECTURE.md](./01_ARCHITECTURE.md).
- Deviations from the Data Dictionary v1.0 are intentional and captured in
  [08_DEVIATIONS.md](./08_DEVIATIONS.md) (20 numbered entries).
- Business rules that moved to the application layer are catalogued in
  [07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md) (50+ numbered invariants,
  each with named owning service and required tests).
- Open questions in §7 require business / integration answers before go-live.

| Role | Signature | Date |
|---|---|---|
| CTO, MSC | | |
| Database Engineering Lead | | |

---

*End of document — MSC HPMS Schema Design v1.0*
