# HPMS — Application-Layer Invariants v1.0

> Business rules enforced in service code, not at the database. This file is the
> domain-layer checklist for review and testing.

The database enforces structural invariants only — uniqueness, referential integrity,
NOT NULL, basic type sanity. Every rule below is a **business invariant** owned by an
application service.

Companion docs: [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) · [08_DEVIATIONS](./08_DEVIATIONS.md) · [01_ARCHITECTURE](./01_ARCHITECTURE.md).

Each rule:

- States the rule precisely.
- Names the module and service that owns it.
- Lists the tests that must cover it.

**If you add a new business rule, add it here first. If you find a rule that has no
test, that's a bug.**

---

## 1. Invitation codes (mall-userms)

### I-001 · Every registered user gets exactly one invitation code

- **Rule:** On successful user registration, a row in `ucenter_inviter_code` is created
  in the same transaction. The code is a generated short alphanumeric string that survives
  uniqueness check on `ucenter_inviter_code.code`.
- **Module:** `mall-userms`
- **Owner:** `InviterCodeService.createForUser(userId)` — invoked from the user-registration flow.
- **Tests:**
  - register a fresh user → exactly one `ucenter_inviter_code` row exists with status `ACTIVE`
  - simulate code-collision on first attempt → service retries until success
  - registration transaction rolls back if code creation fails

### I-002 · Code generation collision retry

- **Rule:** Generator produces a code; if the unique-key insert fails, retry up to N times
  (suggested N=5) before surfacing as a 5xx. Generation must be entropy-driven (not
  monotonic) to keep codes unguessable.
- **Module:** `mall-userms`
- **Owner:** `InviterCodeGenerator`.
- **Tests:** force two collisions then a success — exactly 3 generator calls, 1 stored row.

### I-003 · Code revocation on user suspension

- **Rule:** When `mall-userms` suspends a user, the same transaction sets
  `ucenter_inviter_code.status = 'REVOKED'`. Validation endpoints reject `REVOKED` codes
  with a clear "code invalid" response — never disclose the underlying suspension.
- **Module:** `mall-userms`
- **Owner:** `UserSuspensionService` (existing) + new hook into `InviterCodeService`.
- **Tests:** suspend a user → their code rejects new registrations; existing bindings
  remain.

---

## 2. Inviter ↔ Invitee binding (mall-userms)

### I-010 · Binding is created on registration only

- **Rule:** `ucenter_inviter_binding` is written exclusively by the registration flow,
  in the same transaction as the user creation. No admin endpoint mutates bindings.
- **Module:** `mall-userms`
- **Owner:** `RegistrationService.register(...)`.
- **Tests:** assert no other code path reaches `InviterBindingMapper.insert()`.

### I-011 · Lifetime binding (UNIQUE-violation = silent ignore)

- **Rule:** If a user has been bound previously, any new code submitted at registration
  is silently ignored. The user proceeds normally; no error. Detection: `UNIQUE` violation
  on `invitee_user_id` is caught and converted to a no-op (PRD §5.1).
- **Module:** `mall-userms`
- **Owner:** `RegistrationService.applyInvitationCode(...)`.
- **Tests:**
  - user A bound to B; user A submits a new code at re-registration → no error,
    binding unchanged
  - QA scenario #3 (PRD §8)

### I-012 · Self-invitation is rejected

- **Rule:** If the validated invitation code resolves to the same `user_id` as the
  registering user, the binding is not created (this should be impossible in practice
  since codes only exist after registration completes — but defensively reject).
- **Module:** `mall-userms`
- **Owner:** `RegistrationService.applyInvitationCode(...)`.
- **Tests:** force the rare race; assert no row inserted.

### I-013 · No-cycle invariant is irrelevant by construction

- **Note:** Because binding is set once at registration and never moves, a cycle is
  structurally impossible (an Inviter must exist before they can be invited; their own
  Inviter row was set when they registered earlier). No runtime check needed.

### I-014 · Binding is immutable after creation

- **Rule:** No service updates `ucenter_inviter_binding` rows. Admin-driven reassignment
  is not in scope for MVP.
- **Module:** `mall-userms`
- **Tests:** static analysis — no `update` SQL or MyBatis-Plus update call against
  `InviterBindingMapper`.

---

## 3. Field-promoter soft tag (mall-userms)

### I-020 · Tag does not affect commission logic

- **Rule:** The `user_flag` column is read by reporting and admin-filter endpoints only.
  No commission calculation, batch logic, or Inviter eligibility checks branch on it.
- **Module:** `mall-userms` (column owner), `mall-rebate` (reads via Feign for filtered reports).
- **Tests:** snapshot test of the batch service: same input with `user_flag=NULL` and
  `user_flag='FIELD_PROMOTER'` produces identical commission rows.

### I-021 · Only admins can set the tag

- **Rule:** Tag set/unset endpoint requires admin role; service-layer re-check enforces
  this even if the controller annotation is removed.
- **Module:** `mall-userms`
- **Owner:** `UserAdminService.setUserFlag(...)`.

---

## 4. Commission rate config (mall-rebate)

### I-030 · Single active config row

- **Rule:** `inviter_commission_rate_config` has exactly one row. Service initialization
  asserts `count = 1` and fails fast otherwise.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionRateService.assertSingleRow()` — invoked at boot.
- **Tests:** integration test with 0 rows fails boot; with 2 rows fails boot.

### I-031 · Update is transactional with history insert

- **Rule:** Rate update is a single transaction:
  1. INSERT `inviter_commission_rate_config_history` with the `prev_*` and `new_*` values plus the actor + reason.
  2. UPDATE `inviter_commission_rate_config` with the new values.
  3. Emit a structured Kibana log line.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionRateService.update(actor, newRates, reason)`.
- **Tests:** simulate failure between (1) and (2) — both roll back; live config and
  history stay consistent.

### I-032 · Reason is required on every change

- **Rule:** `reason` is non-blank; whitespace-only fails validation. Enforced both at
  controller (Bean Validation) and service.
- **Module:** `mall-rebate`
- **Tests:** empty reason → 400; reason of `"   "` → 400.

### I-033 · Rate change is effective from the next billing cycle

- **Rule:** A rate change committed mid-month does not affect the current month's batch.
  The batch reads the rate row and snapshots it into `inviter_commission_batch.rate_config_snapshot`
  at start.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionBatchService`.
- **Tests:** batch begins; rate change committed concurrently; batch's resulting rows use
  the snapshot, not the new value.

### I-034 · Only admins can update rates

- **Rule:** Admin role required; service-layer re-check.
- **Module:** `mall-rebate`
- **Tests:** QA scenario #7 (PRD §8) — non-admin returns 403.

---

## 5. Commission engine (mall-rebate)

### I-040 · Single-level attribution

- **Rule:** Commission is computed only for the direct Inviter of the user who placed
  the settled order. The batch never walks up the binding chain.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionBatchService.runBatch(billingMonth)`.
- **Tests:**
  - A→B→C→D chain; D places a settled order; only the (C, D, month) commission row exists
  - QA scenario #5 (PRD §8)

### I-041 · Tier formula

- **Rule:** Per Invitee, per billing month, commission =
  - `tier1_rate_bp × min(invitee_monthly_sales, tier1_threshold) / 10000`
  - `+ tier2_rate_bp × max(invitee_monthly_sales − tier1_threshold, 0) / 10000`
  - rounded to 2 decimal places (rounding mode pending Finance).
- **Module:** `mall-rebate`
- **Owner:** `CommissionCalculator.compute(invitee_monthly_sales, rateConfig)`.
- **Tests:**
  - ₦800,000 → ₦8,000 (entirely tier 1)
  - ₦1,000,000 exact → ₦10,000
  - ₦1,500,000 → ₦20,000 (₦10,000 + ₦10,000)
  - ₦0 → ₦0
  - banker's vs half-up rounding chosen and asserted in test fixtures

### I-042 · Idempotent batch re-run

- **Rule:** Running the batch twice for the same `billing_month` produces the same final
  state. Implementation uses `INSERT ... ON DUPLICATE KEY UPDATE` against
  `uq_inviter_record_iim`. Updated values: `invitee_monthly_sales`, `commission_amount`,
  `batch_id`, `rate_config_id`. Status, approval, and paid timestamps are NOT overwritten
  if the row is already past `CALCULATED`.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionBatchService`.
- **Tests:**
  - run batch, capture state, run again with identical inputs → identical state
  - new settled order added between runs → re-run picks it up
  - already-`APPROVED` row → re-run does not flip back to `CALCULATED`

### I-043 · Suspended Inviter accrues no commission

- **Rule:** Before upserting a record, the batch checks the Inviter's `status` in
  `mall-userms` (via Feign or via a join if same DB). If suspended, the row is skipped.
- **Module:** `mall-rebate`
- **Tests:** QA scenario #8 (PRD §8) — suspended inviter; settled invitee order produces
  no record.
- **Open:** Q2 (PRD §10) — exact mid-month semantics still pending PM confirmation.

### I-044 · Status workflow

- **Rule:** `CALCULATED → APPROVED → PAID` happy path. `CALCULATED → DISPUTED → APPROVED → PAID`
  dispute path. Reverse transitions are not allowed.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionWorkflowService`.

### I-045 · Approval triggers wallet credit

- **Rule:** When an admin approves a batch, all `CALCULATED` rows for that batch flip to
  `APPROVED`. In the same transaction the service Feign-calls `mall-payment` to credit
  the balance. On Feign failure the transaction rolls back. After payment confirms
  (synchronous response), rows transition to `PAID`.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionWorkflowService.approveBatch(...)`.
- **Tests:** Feign failure → status stays `CALCULATED`; success → status advances to `PAID`.

### I-046 · Batch run is recorded explicitly

- **Rule:** Every batch invocation creates an `inviter_commission_batch` row at start
  (`status = RUNNING`), captures the rate-config snapshot into
  `rate_config_snapshot` JSON, and updates to `COMPLETED` or `FAILED` at end. The
  xxl-job log id is written for cross-reference.
- **Module:** `mall-rebate`
- **Owner:** `InviterCommissionBatchService`.

### I-047 · Idempotent payment credit

- **Rule:** The Feign call to `mall-payment` carries a deterministic idempotency key
  (e.g. `batch_id + ":" + record_id`). Retries with the same key do not double-credit.
- **Module:** `mall-rebate` (sender), `mall-payment` (receiver).
- **Tests:** simulate retry; balance increments exactly once.

---

## 6. Format validators (mall-userms)

Pure input validation; the database stores whatever the application inserts.

### I-080 · Invitation code format

- Generator output: 8 alphanumeric characters, uppercase + digits. Excludes confusable
  chars (0/O, 1/I/l).
- Validator on incoming registration: regex `^[A-HJ-NP-Z2-9]{8}$` (illustrative; final
  charset to be confirmed when generator is implemented).

### I-081 · billing_month format

- Regex `^[0-9]{4}-(0[1-9]|1[0-2])$`. Validated on every write path that accepts a
  billing month from outside.

### I-082 · phone_number, business_reg_number, and other userms formats

- Inherited from `mall-userms` existing validators. HPMS adds nothing new here.

---

## 7. Open questions

Tracked here so they don't get lost in design conversation.

- **Q1** — Reserved `actor_admin_id` UUID for system-seeded rate config? Or do we leave
  the column NULL on the seed row only? (Currently: NULL on the very first history row;
  service enforces NOT NULL on subsequent rows.)
- **Q2** — Rounding mode for commission: banker's vs half-up. Finance decision.
- **Q3** — Mid-month suspension semantics for orders that settle on the suspension day.
- **Q4** — Decoupling code revocation from user suspension (separate "deactivate code"
  use case).
- **Q5** — Soft-tag governance: who can grant `FIELD_PROMOTER`? Just super-admin or any
  admin?

---

## What changed from the previous version

Previous v1.0 (29 April 2026) had ~50 invariants for a 3-tier hierarchy + barcodes +
onboarding-bonus model. That entire model was replaced by the PRD rewrite.

Removed (no longer applicable):

- Hierarchy parent-level checks, recruit-permission rules, barcode chain alignment,
  onboarding-bonus payment workflow, commission split matrix, OVERRIDE/DIRECT
  type coherence, audit-log polymorphism rules, pharmacy-verification workflow,
  pharmacy reassignment rules.

Added (new for the unified model):

- Invitation-code lifecycle and revocation (I-001 … I-003)
- Lifetime-binding silent-ignore semantics (I-010 … I-014)
- Field-promoter soft-tag rules (I-020 … I-021)
- Rate-config single-row + history-with-reason (I-030 … I-034)
- Single-level attribution + tier formula (I-040 … I-041)
- Idempotent batch + explicit batch run record (I-042 … I-046)
- Idempotent payment credit (I-047)

---

*End of document — Application Invariants v1.0 — 4 May 2026.*
