# HPMS — Application-Layer Invariants

The database enforces **structural invariants only** (referential integrity, uniqueness,
compliance-mandated immutability, basic type sanity). Every rule below is a **business
invariant that lives in the application layer** — service code, validators, workflow
handlers, or batch jobs.

Companion docs: [06_SCHEMA_DESIGN.md](./06_SCHEMA_DESIGN.md) (design narrative)
and [08_DEVIATIONS.md](./08_DEVIATIONS.md) (engineering choices vs PM docs).

Each rule:

- States the rule precisely.
- Names the service/handler that owns enforcement.
- Lists the tests that must cover it.

**If you add a new business rule, add it here first. If you find a rule that has no test,
that's a bug.** This file is the checklist for the domain layer.

---

## 1. Promoter Hierarchy

### I-001 · Parent level correctness

- **Rule:** `FIELD_AGENT.parent_id` must reference a promoter with `level = FIELD_LEAD`.
  `FRONTLINE_REP.parent_id` must reference a promoter with `level = FIELD_AGENT`.
- **Owner:** `RecruitmentService` — `POST /api/v1/field-leads/agents`,
  `POST /api/v1/field-agents/reps`.
- **Tests:** reject agent-with-rep-parent, reject rep-with-lead-parent, reject rep-with-rep-parent.

### I-002 · Frontline Reps cannot recruit

- **Rule:** A `FRONTLINE_REP` attempting to create any child → hard 403. Logged to `audit_logs`
  with `action_type=ACCOUNT_CREATED` and a denied-recruitment reason.
- **Owner:** JWT role guard on recruitment endpoints (`@PreAuthorize` + service-layer re-check).
- **Tests:** QA scenario #1 (CLAUDE.md).

### I-003 · parent_id and level are immutable

- **Rule:** Once set at creation, `promoters.parent_id` and `promoters.level` cannot be changed.
  Suspension and reinstatement change `status`, never hierarchy.
- **Owner:** `PromoterUpdateService` — rejects any PATCH that touches these columns.
- **Tests:** PATCH with `parent_id` or `level` must return 400.

### I-004 · created_by polymorphism

- **Rule:** For `level=FIELD_LEAD`, `created_by` must be a valid `admin_id`. For AGENT/REP,
  `created_by` must be the recruiting promoter's `promoter_id`.
- **Owner:** `RecruitmentService`.
- **Tests:** unit tests over each recruit path.
- **Note:** May change with main-app integration identity decision (Pattern A vs B). See D-001.

### I-005 · Suspension requires reason

- **Rule:** When `promoters.status` transitions to `SUSPENDED`, `suspension_reason` must be
  provided (max 500 chars) and the action written to `audit_logs`.
- **Owner:** `PromoterSuspensionService`.
- **Tests:** suspend without reason → 400; suspend with reason → audit row exists.

### I-006 · Email required for Field Leads

- **Rule:** `email_address` is `NOT NULL` for `FIELD_LEAD`; optional for AGENT and REP.
- **Owner:** Validator on `POST /api/v1/admin/field-leads`.

---

## 2. Barcodes

### I-010 · Barcode creation is coupled to promoter creation

- **Rule:** A promoter and their barcode are created in the same transaction. Neither
  exists alone. `promoters.barcode_id` is populated before the transaction commits.
- **Owner:** `PromoterCreationService` (single transactional method).

### I-011 · root_barcode_id semantics

- **Rule:** For a `FIELD_LEAD` barcode, `root_barcode_id = barcode_id` (self).
  For `FIELD_AGENT` and `FRONTLINE_REP` barcodes, `root_barcode_id` points to the Field Lead
  at the top of the chain — NOT the direct parent.
- **Owner:** `BarcodeFactory`.
- **Tests:** create a 3-level chain, assert root barcode is the same UUID on all three rows.

### I-012 · parent_barcode_id alignment

- **Rule:** `barcodes.parent_barcode_id` must be NULL iff the owner is a `FIELD_LEAD`, and
  must reference the barcode of the owner's `promoters.parent_id` otherwise.
- **Owner:** `BarcodeFactory`.

### I-013 · Barcode is immutable after creation

- **Rule:** `promoter_id`, `parent_barcode_id`, `root_barcode_id` never change.
- **Owner:** `BarcodeUpdateService` — only `status` can be mutated.

### I-014 · Revoked barcodes cannot be scanned

- **Rule:** `POST /api/v1/promoter/barcodes/scan` returns `410 Gone` if the barcode status
  is `REVOKED`.
- **Owner:** `ScanService`.

### I-015 · Barcode code format

- **Rule:** `barcode_code` follows `MSC-{LVL}-{6 digits}` where `LVL ∈ {FL, AG, FR}`
  (Field Lead / Field Agent / Frontline Rep).
- **Owner:** `BarcodeFactory` — generates with the correct prefix at creation.
- **Note:** This corrects the older `CH/AG/AM` prefixes from earlier PRD drafts (see
  [02_PROJECT_CONTEXT §9](./02_PROJECT_CONTEXT.md)).

---

## 3. Pharmacy Onboarding

### I-020 · Soft duplicate detection

- **Rule:** Before INSERT, the registration service queries
  `(pharmacy_name, street_address, lga)` for exact matches. Any match blocks the insert
  and surfaces the candidate row(s) to Admin review queue.
- **Owner:** `PharmacyRegistrationService`.
- **Tests:** QA scenario #2.

### I-021 · Registration timestamp is the scan time

- **Rule:** `registration_timestamp` is the server-side timestamp captured at the moment
  the scan request hits the API — immutable thereafter. Online only; offline scan is out of
  scope for MVP (per Sprint 1 kickoff; QA scenario #10 withdrawn).
- **Owner:** `ScanService`.

### I-022 · Onboarding attribution is immutable

- **Rule:** `onboarding_barcode_id`, `onboarding_promoter_id`, `registration_timestamp`
  cannot be changed after INSERT. Admin reassignment of pharmacies (if/when implemented)
  must create a new `pharmacy_assignments` entity, not mutate these fields.
- **Owner:** `PharmacyUpdateService`.

### I-023 · Verification requires verifier

- **Rule:** When `verification_status` transitions to `VERIFIED` or `REJECTED`,
  `verification_date` and `verified_by` must both be populated. `REJECTED` additionally
  requires `rejection_reason`.
- **Owner:** `PharmacyVerificationService` — `PATCH /api/v1/admin/pharmacies/{id}/verify`.
- **Tests:** transition tests covering all valid and invalid status flips.

### I-024 · `first_order_settled_at` is set by the integration consumer, not a user

- **Rule:** Populated automatically when the `OrderSettledEvent` for a pharmacy's first
  SETTLED order is consumed from the main app's RocketMQ topic. No API allows a user to
  set this directly.
- **Owner:** `OrderSettlementEventConsumer`.

### I-025 · `onboarding_bonus_paid` is monotonic

- **Rule:** Once set to `1`, this flag cannot revert to `0`. Updates that would do so
  must raise a domain exception.
- **Owner:** `BonusPaymentService`.
- **Tests:** attempt to set 1 → 0 must throw.

---

## 4. Orders & Settlement

### I-030 · Only SETTLED orders are commission-eligible

- **Rule:** The commission batch filters to `order_status = 'SETTLED'` with a non-null
  `settlement_ref`, `settled_at`, and `billing_month`. Orders in any other status are
  excluded.
- **Owner:** `CommissionBatchJob`.
- **Tests:** seed mixed-status orders, assert only SETTLED is counted.

### I-031 · `orders` is a read-mirror — no write endpoints

- **Rule:** No HPMS API accepts order creation or modification. All rows in `orders` and
  `order_settlement_events` are written by the integration consumer projecting events from
  the main app. Direct INSERT/UPDATE from any other code path is a bug.
- **Owner:** `OrderSettlementEventConsumer`.
- **Note:** Architecture decision per [01_ARCHITECTURE §4.8](./01_ARCHITECTURE.md).

### I-032 · billing_month is derived, not user-input

- **Rule:** `billing_month = format(settled_at, "yyyy-MM")` in UTC (storage TZ).
  Computed by the settlement consumer, never accepted as input.
- **Owner:** `OrderSettlementEventConsumer`.

### I-033 · `commission_eligible` truth

- **Rule:** An `order_settlement_events` row has `commission_eligible = 1` iff
  `event_type = ORDER_SETTLED` AND the corresponding order has `order_value > 0`.
- **Owner:** `OrderSettlementEventConsumer`.

### I-034 · Idempotent event consumption

- **Rule:** Each consumed RocketMQ event carries a unique key. The consumer rejects
  duplicate keys without side effects. Used together with the `UNIQUE` on
  `settlement_ref` to make the projection safe under retries.
- **Owner:** `OrderSettlementEventConsumer`.

---

## 5. Commission Engine

### I-040 · Rate tiers

- **Rule:** For a pharmacy's monthly sales total `S`:
  - `gross = 0.01 × min(S, 1_000_000) + 0.02 × max(0, S - 1_000_000)`
  - Result rounded to 2 decimal places. Rounding mode pending Finance decision (Q10).
- **Owner:** `CommissionCalculator`.
- **Tests:** ₦1.5M → ₦20,000; ₦800K → ₦8,000; ₦1M exact → ₦10,000; ₦0 → ₦0.

### I-041 · Split matrix

- **Rule:** Split depends on the LEVEL of the pharmacy's onboarding promoter:

  | Onboarder level | Lead | Agent | Rep | commission_type per row |
  |---|---|---|---|---|
  | FIELD_LEAD      | 100% | —    | —   | DIRECT |
  | FIELD_AGENT     | 10%  | 90%  | —   | OVERRIDE (Lead), DIRECT (Agent) |
  | FRONTLINE_REP   | 0%   | 10%  | 90% | OVERRIDE (Agent), DIRECT (Rep). Lead row NOT created at 0%. |

- **Owner:** `CommissionSplitter`.
- **Tests:** QA scenarios #3, #4, #5.
- **Pending confirmation** of Field Lead 0% on Rep-onboarded pharmacies (Q1 in 02_PROJECT_CONTEXT).

### I-042 · commission_type ↔ split_percentage coherence

- **Rule:** `DIRECT` rows have `split_percentage = 100`. `OVERRIDE` rows have 90 or 10.
  The calculator produces only valid combinations; reject any other combination in test.
- **Owner:** `CommissionSplitter`.

### I-043 · net_commission formula

- **Rule:** `net_commission = round(gross_commission × split_percentage / 100, 2)`.
  Computed and written by the batch — not a database-generated column (see D-004).
- **Owner:** `CommissionCalculator`.
- **Tests:** assert every inserted `net_commission` equals the formula.

### I-044 · Idempotent batch re-run

- **Rule:** Re-running the batch for the same `billing_month` is a no-op for unchanged
  inputs. Implementation uses `INSERT ... ON DUPLICATE KEY UPDATE` against
  `uq_commission_ppb`, updating `total_pharmacy_sales`, `gross_commission`,
  `net_commission`, and `batch_id` only if the values changed.
- **Owner:** `CommissionBatchJob` (xxl-job handler).
- **Tests:** run batch twice, assert row count unchanged; run with new SETTLED orders, assert update.

### I-045 · Suspended promoters accrue no commission

- **Rule:** Before inserting a commission row, the batch checks
  `promoters.status != SUSPENDED`. Suspended promoters are skipped entirely for that month.
- **Owner:** `CommissionBatchJob`.
- **Tests:** QA scenario #8.
- **Open:** mid-month suspension semantics for upstream OVERRIDE rows — see Q11.

### I-046 · Status workflow

- **Rule:** `CALCULATED → APPROVED → PAID` happy path. `CALCULATED → DISPUTED → APPROVED → PAID`
  dispute path. `APPROVED` and `PAID` require `approved_by` and `approved_at`.
  `DISPUTED` requires `dispute_note`.
- **Owner:** `CommissionWorkflowService`.

### I-047 · CommissionBatchApprovedEvent published on approval

- **Rule:** When an admin approves a batch (transitions all `CALCULATED` rows to `APPROVED`
  for a billing_month), HPMS publishes `CommissionBatchApprovedEvent` to RocketMQ. The main
  app consumes this and credits promoter wallets.
- **Owner:** `CommissionWorkflowService` (publisher); main app (consumer).
- **Tests:** integration test asserts event payload matches the line items.

### I-048 · Batch run record

- **Rule:** Every commission batch invocation creates a `commission_batches` row at start
  (`status=RUNNING`), updates to `COMPLETED` or `FAILED` at end. The xxl-job log id is
  written to `xxl_job_log_id` for cross-reference. Records produced by a run reference it
  via `commission_records.batch_id`.
- **Owner:** `CommissionBatchJob`.

---

## 6. Onboarding Bonus

### I-050 · Trigger conditions

- **Rule:** Bonus becomes `READY_TO_PAY` only when BOTH:
  1. `verification_met_at` is populated (pharmacy verified).
  2. `first_order_met_at` is populated (first SETTLED order observed via integration).
- **Owner:** `BonusEligibilityEvaluator` (xxl-job — periodic scan).
- **Tests:** QA scenario #6 (bonus before first settled order must not pay).

### I-051 · Double-payment guard (app layer)

- **Rule:** Second INSERT for the same `pharmacy_id` is impossible at the DB (UNIQUE), but
  the service also handles the resulting error gracefully — on UNIQUE violation, return
  the existing bonus row instead of 500.
- **Owner:** `BonusCreationService`.
- **Tests:** QA scenario #7.

### I-052 · Split amounts

- **Rule:**
  - `FIELD_LEAD` direct onboarder: `recipient_1_amount = 2000`, `recipient_2_*` null.
  - `FIELD_AGENT` or `FRONTLINE_REP` onboarder: `recipient_1_amount = 1800`,
    `recipient_2_amount = 200`.
  - `total_bonus_amount` always equals the sum of recipient amounts (2000).
- **Owner:** `BonusSplitter`.
- **Tests:** three seed promoters at each level, assert correct amounts.

### I-053 · Supervisor linkage

- **Rule:** `recipient_2_id` (when non-null) must equal the `promoters.parent_id` of
  `recipient_1_id`. Validated at bonus creation.
- **Owner:** `BonusSplitter`.

### I-054 · Pharmacy flag sync

- **Rule:** When a bonus row's `trigger_status` transitions to `PAID`, the same transaction
  updates `pharmacies.onboarding_bonus_paid = 1`. Both writes must succeed or both roll back.
- **Owner:** `BonusPaymentService.disburse()` — single transactional method.
- **Tests:** assert DB state consistency after a paid bonus.

### I-055 · Paid bonus is terminal

- **Rule:** Once `trigger_status = PAID`, the row cannot be updated further. `paid_at`
  must be set.
- **Owner:** `BonusPaymentService`.

### I-056 · OnboardingBonusReadyEvent published on `READY_TO_PAY`

- **Rule:** When trigger_status transitions to `READY_TO_PAY`, HPMS publishes
  `OnboardingBonusReadyEvent` to RocketMQ. The main app credits the bonus and (optionally)
  publishes a paid-confirmation event back, prompting HPMS to flip to `PAID`.
- **Owner:** `BonusPaymentService` (publisher).

---

## 7. Audit Logs

### I-060 · Required-reason action types

- **Rule:** Writes with these `action_type` values must include `reason`:
  `ACCOUNT_SUSPENDED`, `PHARMACY_REJECTED`, `DISPUTE_RAISED`, `DISPUTE_RESOLVED`.
- **Owner:** `AuditLogger`.

### I-061 · previous_state / new_state population

- **Rule:** `previous_state` is null for creation events; `new_state` is null for deletion
  events (there are no deletion events in v1 — soft-delete not modelled).
- **Owner:** `AuditLogger`.

### I-062 · Actor polymorphism

- **Rule:** When `actor_role = ADMIN`, `actor_id` refers to `admins`. Otherwise it refers
  to `promoters`. `SYSTEM` uses a reserved UUID (Q9 — proposed
  `00000000-0000-0000-0000-000000000000`).
- **Owner:** `AuditLogger`.

### I-063 · No UPDATE, no DELETE, ever

- **Rule:** Any code path that would modify or delete an audit row is a bug. The DB
  enforces this two ways (triggers + GRANT — see D-007), but the app must not even attempt
  it. Attempts indicate a contract violation somewhere.
- **Owner:** every writer.

---

## 8. Verification Calls

> Full call-log workflow may be deferred for MVP — Q3 in [02_PROJECT_CONTEXT](./02_PROJECT_CONTEXT.md).
> If MVP ships with a simple verify toggle, invariants I-070..I-073 are inactive until
> the call-log feature is enabled.

### I-070 · follow_up_required auto-set

- **Rule:** On outcomes `SUSPICIOUS` or `CALLBACK_REQUESTED`, the service sets
  `follow_up_required = 1` automatically. Admin can also set it manually for any outcome.
- **Owner:** `VerificationCallService`.

### I-071 · follow_up_date required when follow_up_required = 1

- **Rule:** App-level validator enforces this on INSERT.
- **Owner:** `VerificationCallService`.

### I-072 · follow_up_done cascade

- **Rule:** When a new call log is created for a pharmacy, any previous calls with
  `follow_up_required = 1 AND follow_up_done = 0` are updated to `follow_up_done = 1`.
- **Owner:** `VerificationCallService`.

### I-073 · call_date not in future

- **Rule:** Reject any `call_date > today`.
- **Owner:** validator.

---

## 9. Format Validators

These are pure input-validation rules; the DB stores whatever the app inserts.

### I-080 · phone_number

- Nigerian format: `^\+234[0-9]{10}$`.

### I-081 · business_reg_number (CAC)

- Format: `^RC[0-9]{6,7}$`.

### I-082 · nafdac_licence_number

- Format: `^NAFDAC/PHARM/[A-Z0-9]+$`.

### I-083 · bank_account_number

- Exactly 10 digits, NUBAN checksum validated.

### I-084 · legal_rep_id_number

- Format depends on `legal_rep_id_type`:
  - NIN: 11 digits
  - BVN: 11 digits
  - PASSPORT: 2 letters + 7 digits
  - DRIVERS_LICENCE / VOTERS_CARD: per-issuer (document on implementation).

### I-085 · billing_month

- `^[0-9]{4}-(0[1-9]|1[0-2])$`.

---

## Open Questions (need answers, not enforcement)

- **Q9** — Reserved UUID for `audit_logs.actor_id` on `actor_role=SYSTEM` events.
  Current proposal: `00000000-0000-0000-0000-000000000000`. Confirm with ops.
- **Q10** — Rounding mode for commissions: banker's rounding vs half-up. Finance decision.
- **Q11** — If a promoter is suspended mid-month, does their DIRECT pharmacy still generate
  OVERRIDE commission for their upstream? PRD is silent.
- **Q12** — Identity pattern (HPMS users vs main-app users) — affects ownership of
  `created_by`, `verified_by`, `approved_by`. To be resolved in main-app integration design.

---

## Change log

- **2026-04-23** — Initial version. Moved from DB-layer CHECKs and triggers per
  architectural review.
- **2026-04-27** — Consolidation pass:
  - Removed offline-sync language from I-021 (online-only per Sprint 1 kickoff).
  - Updated API paths to `/api/v1/...` audience-segmented routes.
  - Added I-015 (barcode FL/AG/FR prefix), I-031 (orders read-mirror), I-034 (idempotent
    consumer), I-047 (CommissionBatchApprovedEvent), I-048 (batch run record),
    I-056 (OnboardingBonusReadyEvent).
  - Added Q12 (identity pattern decision pending).
