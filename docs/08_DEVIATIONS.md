# HPMS — Engineering Deviations from PM Documents

Per [CLAUDE.md](../CLAUDE.md), the PRD v2.0, Process Diagrams v1.0, and Data Dictionary v1.0
are **informational, not authoritative**. This file is the canonical log of every place
the implemented schema / system diverges from or extends the PM-authored specs.

Update this file whenever a schema or API decision deviates from the docs.
Each entry: **what the doc says → what we implemented → why**.

Companion docs: [06_SCHEMA_DESIGN.md](./06_SCHEMA_DESIGN.md) (the design narrative)
and [07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md) (rules enforced
in the application layer).

---

## Architectural principle (applies to every entry below)

The database enforces **structural invariants only**:
referential integrity, uniqueness, NOT NULL, compliance-mandated immutability
(`audit_logs`), and basic type sanity.

**Business rules live in the application layer.** Split percentages, bonus amounts,
workflow state machines, cross-row validation, and format regexes are enforced by
services and tested in unit tests. See [07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md)
for the full catalogue.

Rationale: business rules change (Finance may alter a split, Product may add a
tier); schema CHECKs turn every such change into a migration. Trigger-based
cross-row validation is also fragile — cryptic errors, hidden side-effects, and
fights with bulk loads and replication.

---

## D-001 · `admins` table added

**Doc status:** Not defined in Data Dictionary.
**Implemented:** `admins (admin_id, full_name, email_address, phone_number, password_hash, status, ...)`.
**Why:** Multiple columns reference an admin identity — `promoters.created_by` (for FIELD_LEAD rows),
`pharmacies.verified_by`, `commission_records.approved_by`, `verification_call_logs.admin_id`,
`commission_batches.triggered_by_admin_id`, and `audit_logs.actor_id` with `actor_role=ADMIN`.
A dedicated table is required for referential integrity.
**Pending:** May be removed if the main-app integration adopts Pattern B (HPMS uses main-app
identity directly). See [02_PROJECT_CONTEXT §6](./02_PROJECT_CONTEXT.md). For now, table stays
so referencing tables compile.
**Ref:** `V1__init.sql` §0.

---

## D-002 · `promoters.barcode_id` nullable at insert time

**Doc status:** Data Dictionary §1 marks `barcode_id` as Required + Unique.
**Implemented:** Column is `NULL` at insert, filled inside the same transaction as barcode creation.
**Why:** `promoters.barcode_id → barcodes.barcode_id` and `barcodes.promoter_id → promoters.promoter_id`
are a circular FK. Either side must be nullable to allow any insert order. The uniqueness constraint
still enforces 1:1. Application invariant I-010 guarantees both are populated before txn commit.
**Ref:** `promoters` table, `fk_promoters_barcode` constraint added after `barcodes` creation.

---

## D-003 · Soft duplicate detection is a non-unique KEY, not UNIQUE

**Doc status:** Data Dictionary §3 describes `(pharmacy_name, street_address, lga)` as a duplicate-detection
rule. PRD says this check "flags for Admin review" — it's the SOFT check; CAC is the HARD check.
**Implemented:** Non-unique KEY on `(pharmacy_name, street_address, lga)`. Application runs a SELECT
before INSERT to surface soft matches (invariant I-020).
**Why:** A UNIQUE constraint would hard-block legitimate edge cases (two pharmacies at the same
address in genuinely different units). The PRD explicitly describes this as a flag, not a block.
Only `business_reg_number` (CAC) is a hard unique.
**Ref:** `pharmacies.ix_pharmacies_soft_dupe`.

---

## D-004 · `commission_records.net_commission` is a plain column, NOT generated

**Doc status:** Data Dictionary §5 describes `net_commission = gross_commission × (split_percentage / 100)`
as a validation rule.
**Implemented:** Plain `DECIMAL(15,2) NOT NULL`. The batch job computes and writes the value.
**Why (reversed from earlier design):** An earlier revision made this a `GENERATED ALWAYS AS (...) STORED`
column. That locked rounding mode, precision, and the formula itself into DDL. If Finance ever
switches to banker's rounding, caps a payout, or adjusts the formula, a schema migration is needed.
Enforcement moved to the app (invariant I-043) with a contract test asserting
`net_commission = ROUND(gross × split / 100, 2)` on every inserted row.

---

## D-005 · Split percentages and bonus amounts NOT encoded in DDL

**Doc status:** Data Dictionary §5 and §6 describe split percentages (100/90/10) and
bonus amounts (₦2,000 / ₦1,800 / ₦200) as validation rules.
**Implemented:** Stored as plain columns with no CHECK. Validation is at the app layer
(invariants I-041, I-042, I-052).
**Why (reversed from earlier design):** An earlier revision added
`CHECK split_percentage IN (100, 90, 10)`, `CHECK total_bonus_amount = 2000.00`, and a
multi-branch CHECK on the bonus split shape. These hard-code today's business numbers into
schema DDL. Any business-side change (a new promoter tier, a bonus increase, a regional
variant) becomes a migration. Keeping these in the app layer makes them testable,
versionable, and changeable without touching the database.

---

## D-006 · `order_settlement_events.fk_ose_order` uses RESTRICT, not CASCADE

**Doc status:** Not specified in docs.
**Implemented:** `ON DELETE RESTRICT`.
**Why:** Audit/compliance retention (≥12 months, PRD §Audit) means order deletions should never be
possible. Using CASCADE would silently wipe event timelines if ever triggered. Orders are managed
via `order_status` enum, never deleted. Additionally — `orders` is a read-mirror from the main
app; deletion isn't a path HPMS exposes at all.

---

## D-007 · `audit_logs` append-only — TRIGGERS + GRANT (defense in depth)

**Doc status:** Data Dictionary §7 says "Immutable. No record can be edited or deleted by any user,
including Super Admins."
**Implemented:** Two layers:

1. `BEFORE UPDATE` and `BEFORE DELETE` triggers raise SQLSTATE 45000.
2. The application DB user is granted `INSERT, SELECT` only on `audit_logs` —
   `UPDATE` and `DELETE` privileges are not granted at all.

**Why this is the one place we keep enforcement at the DB:** This is a **compliance invariant**,
not a business rule. The entire value of the audit log depends on it being unmodifiable. An app
bug or a misbehaving ORM must not be able to violate it. The GRANT layer covers the case
where someone with `SUPER` or `TRIGGER` privilege bypasses the triggers — only a DBA with
elevated rights could touch the table at all.
**Ref:** `trg_audit_logs_no_update`, `trg_audit_logs_no_delete`. Grant statements are
provisioned outside the migration; see deployment runbook.

---

## D-008 · `audit_logs.actor_id` has NO FK

**Doc status:** Data Dictionary §7 says `actor_id` "references promoters or admins table."
**Implemented:** No FK; indexed only. Application resolves to the correct table using `actor_role`
(invariant I-062).
**Why:** MySQL does not support polymorphic/union FKs. Splitting into `actor_promoter_id` /
`actor_admin_id` would pollute the table. Acceptable because audit_logs are append-only and
actor integrity is asserted at write time by the application.

---

## D-009 · Hierarchy enforcement: structural CHECK only, no triggers

**Doc status:** PRD states hard 3-level cap; Data Dictionary §1 says parent rules in prose.
**Implemented:**

- `CHECK chk_promoters_hierarchy` enforces STRUCTURAL SHAPE only:
  FIELD_LEAD ⇒ parent_id NULL; AGENT/REP ⇒ parent_id NOT NULL.
- Parent-level correctness (Agent's parent = Lead, Rep's parent = Agent) is enforced at the
  recruitment endpoints (invariant I-001).
- Immutability of `parent_id` and `level` is enforced by the update service (invariant I-003).

**Why (reversed from earlier design):** An earlier revision added BEFORE INSERT and BEFORE UPDATE
triggers verifying parent's level via subquery and blocking immutable fields. Better handled in
app code: cleaner error messages, easier to test, no subquery on every insert, no conflict with
bulk seeds or test fixtures.
**Ref:** `promoters.chk_promoters_hierarchy`.

---

## D-010 · Field immutability enforced in app, not triggers

**Doc status:** Data Dictionary calls out many fields as "immutable after creation"
(pharmacies.onboarding_*, pharmacies.registration_timestamp, promoters.parent_id, barcodes.*).
**Implemented:** No triggers. Immutability is enforced by update services that reject PATCHes
touching those columns (invariants I-003, I-013, I-022, I-025).
**Why:** Triggers produce cryptic errors, interfere with seed/test data, and scatter domain
rules across two layers. The update services already validate the PATCH payload — rejecting a
disallowed column there is one extra check with a proper domain error.

---

## D-011 · Onboarding bonus: only UNIQUE(pharmacy_id) at DB level

**Doc status:** Data Dictionary §6 describes split amounts, supervisor linkage,
trigger_status progression, and sync with `pharmacies.onboarding_bonus_paid`.
**Implemented:** Only `UNIQUE(pharmacy_id)` is enforced at the DB — the single invariant
that MUST be race-safe. Everything else (split amounts, supervisor = recipient_1's parent,
bonus/pharmacy flag sync on PAID, terminal-state guard) is enforced in `BonusPaymentService`
(invariants I-050..I-055).
**Why:** Service-layer enforcement is explicit, testable, and localised. The earlier
AFTER UPDATE trigger that synced `pharmacies.onboarding_bonus_paid` was actively dangerous
— a hidden cross-table side effect makes the bonus payment flow impossible to reason about
by reading the schema.

---

## D-012 · Structural order-settlement CHECK retained

**Doc status:** Data Dictionary §4 describes `settled_at`, `settlement_ref`, `billing_month`
as required when `order_status = SETTLED`.
**Implemented:** `chk_orders_settled_fields` — a SETTLED row without all three fields is
rejected at the DB.
**Why we kept this one:** This is the commission engine's core contract. A SETTLED order
missing `settled_at` silently corrupts a full month of commission calculation. It's structural
(single-row, no business numbers), cheap, and protects against bugs in the RocketMQ projection
consumer that writes this table.
**Ref:** `orders.chk_orders_settled_fields`.

---

## D-013 · `commission_batches` table added

**Doc status:** Not in the Data Dictionary. The 9-entity list in CLAUDE.md does not include it.
**Implemented:** New table — one row per batch invocation. Holds `billing_month`, `status`
(`RUNNING/COMPLETED/FAILED/CANCELLED`), `trigger_source` (`SYSTEM_CRON/ADMIN_MANUAL`),
`triggered_by_admin_id`, `started_at`, `completed_at`, `error_message`, summary counters,
and `xxl_job_log_id` for cross-reference. `commission_records.batch_id` is a nullable FK
to it.
**Why:** xxl-job will trigger the commission batch monthly and admins can re-run via the
xxl-job admin console. Without an explicit batch row, "which run produced this commission" and
"which run failed at 03:00" are unanswerable from the DB. The architecture doc lists this
table under `core/commission` ownership.
**Ref:** `V1__init.sql` §5.

---

## D-014 · UUIDs stored as `BINARY(16)`, not `CHAR(36)`

**Doc status:** Data Dictionary writes "UUID" generically.
**Implemented:** `BINARY(16)` for all UUID columns. Application converts to/from string at
the boundary (MyBatis-Plus `TypeHandler` or Jackson serializer).
**Why:** ~3× index size and join cost reduction vs `CHAR(36)`. Matches the architecture
direction (§4.3) and the deviation reasoning recorded there: enumeration-attack resistance
on QR codes, mobile deep links, and public API responses, while keeping index/join performance
acceptable.
**Ops note:** seed and ad-hoc SQL must use `UUID_TO_BIN('xxxxxxxx-...')` to insert literal
UUIDs.

---

## D-015 · Indexes added beyond Data Dictionary

**Doc status:** PM docs specify some indexes; CLAUDE.md adds "Key Indexes to Always Include."
**Implemented (additions not in either list):**

- `orders.ix_orders_batch_scan (order_status, billing_month)` — commission batch hot path.
- `commission_records.ix_commission_report (billing_month, status)` — monthly report.
- `commission_records.ix_commission_leaderboard (billing_month, status, promoter_id, net_commission)` — covering index for KPI leaderboard (post-MVP).
- `commission_records.ix_commission_batch (batch_id)` — "which records did this batch produce".
- `order_settlement_events.ix_ose_billing_scan (commission_eligible, billing_month)` — batch filter.
- `verification_call_logs.ix_vcl_followup_due (follow_up_required, follow_up_done, follow_up_date)` — overdue-followup dashboard.
- `commission_batches.ix_batches_billing_month (billing_month, started_at)` — locate the latest run for a month.

**Why:** Query patterns implied by the API surface and the commission batch are not reflected
in the PM's index guidance.

---

## D-016 · `nafdac_licence_number` UNIQUE allows multiple NULLs

**Doc status:** Data Dictionary §3 says NAFDAC is optional + unique-if-provided.
**Implemented:** `UNIQUE KEY uq_pharmacies_nafdac` — MySQL treats NULLs as distinct, so multiple
NULLs coexist. No extra CHECK needed.
**Why:** Standard MySQL semantics match the doc's intent. Noted here because it's not obvious
to teams expecting other DBMS behaviour.

---

## D-017 · Format validation not in DDL

**Doc status:** Data Dictionary specifies formats for `phone_number`, `business_reg_number`,
`nafdac_licence_number`, `bank_account_number`, `billing_month`, `legal_rep_id_number`,
and barcode codes.
**Implemented:** No REGEXP CHECKs. Validation in app (invariants I-080..I-085).
**Why:** Format rules change (new CAC prefix, new phone format, new NUBAN scheme) and
belong in a single source of truth — the validator module — where they're tested,
versioned, and reused across read/write paths.

---

## D-018 · Storage timezone is UTC, NOT Africa/Lagos

**Doc status:** Architecture doc §4.4 says "tz Africa/Lagos" for the MySQL container. The
existing house convention is Africa/Lagos throughout.
**Implemented:** Migration sets `SET time_zone = '+00:00'` and stores all `DATETIME` values
in UTC. The Spring application sets `spring.jackson.time-zone=Africa/Lagos` and renders
all API responses in Lagos local time. Docker container TZ stays Africa/Lagos for log
timestamps and cron expressions.
**Why this departs from house convention:**

- MySQL `DATETIME` has no embedded timezone — values are bare wall-clock. UTC removes
  ambiguity; storing local Lagos means a session with `time_zone='+00:00'` reads
  garbage.
- `CURRENT_TIMESTAMP` defaults arrive in UTC, which is what we want as the canonical
  time of record.
- The main-app integration consumes RocketMQ events that may be in any TZ; UTC at the
  DB makes the conversion at the boundary explicit and testable.
- Nigeria has no DST, so the "what you see is what people expect" upside is small;
  the downside (silent corruption from a misconfigured session) is real.

Display in Lagos at the JSON boundary preserves the user-facing convention.
**Ref:** `V1__init.sql` header, all `DATETIME` columns, `chk_orders_settled_fields`.

---

## D-019 · Plain `DATETIME`, not `DATETIME(3)`

**Doc status:** Data Dictionary says "Timestamp" generically.
**Implemented:** Plain `DATETIME` (second precision) — matches the Spring `LocalDateTime`
default and house convention.
**Why (reversed from earlier design):** An earlier revision used `DATETIME(3)` for
millisecond precision to preserve scan-time ordering on offline syncs. Offline sync was
dropped from MVP at Sprint 1 kickoff (see [02_PROJECT_CONTEXT §9](./02_PROJECT_CONTEXT.md))
— without that requirement, second precision is sufficient and matches the rest of the
MSC stack.

---

## D-020 · Monetary columns are `DECIMAL(15,2)`

**Doc status:** Data Dictionary says "Decimal" generically.
**Implemented:** `DECIMAL(15,2)` for pharmacy sales / commissions / batch totals.
`DECIMAL(10,2)` for the ₦2,000 onboarding bonus where the range is fixed.
**Why:** Matches the architecture doc §2 stack table and the house intent. 15 digits
covers ₦999,999,999,999.99 — well beyond any plausible aggregated commission figure.

---

## Open Questions Still Unresolved

These need business or integration answers; the schema accommodates all outcomes but
cannot enforce a decision until made:

1. **Pharmacy verification method** — call only, document upload, or both? Schema allows
   both (`verification_call_logs` exists; document storage table not yet defined). May be
   simplified for MVP per Q3 in [02_PROJECT_CONTEXT](./02_PROJECT_CONTEXT.md).
2. **Commission payout** — disbursement happens in main app per architecture decision.
   HPMS publishes `CommissionBatchApprovedEvent`; main-app schema is not our concern.
3. **Field Lead removed mid-month** — schema does not define reassignment. Need
   `pharmacy_assignments` table or a documented policy. (Open question Q2 in
   PROJECT_CONTEXT.)
4. **Reinstatement workflow** — schema allows `status=ACTIVE` again after `SUSPENDED`,
   but no state machine constraints; lives in app workflow.
5. **Commission rounding mode** (banker's vs half-up) — app-enforced, Finance decision.
6. **Mid-month suspension effect on OVERRIDE commissions** — PRD silent.
7. **Identity pattern A vs B** — affects whether `admins` survives and how `created_by` /
   `verified_by` / `approved_by` map. To be settled in main-app integration design.

---

## Template for future entries

```text
## D-NNN · Short title

**Doc status:** What the PRD/DD/diagrams say (or don't say).
**Implemented:** What the code/schema actually does.
**Why:** The engineering rationale.
**Ref:** File / line / constraint name.
```
