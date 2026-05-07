# MSC — HPMS Project Rules

Read this file when working on HPMS. The full design lives in [docs/](./docs/) — this
file is just orientation and the rules that matter for any change.

---

## What HPMS is

Inviter/Invitee referral platform inside MSC's existing platform.

- Every registered pharmacy user automatically becomes an Inviter.
- Each user has a unique invitation code + QR code, generated on registration.
- Single-level commission: the direct Inviter earns from each settled order placed by
  their direct Invitee. **No cascading.** The chain has unlimited depth, but each node
  only earns from the node directly below it.
- Lifetime binding: a user is bound to one Inviter, ever. Subsequent codes are silently
  ignored.
- Commission rates are Admin-configurable at runtime, with full change history.
- In-house field promoters operate as standard Inviters; a soft tag (`user_flag`) marks
  them for operational reporting only — commission logic does not branch.

The authoritative product spec is [docs/MSC_HPMS_PRD_v3.0.md](./docs/MSC_HPMS_PRD_v3.0.md).
The PDFs in [docs/archive/](./docs/archive/) describe an earlier 3-tier model that was
abandoned on 30 April 2026 — they are kept for forensic context only and do not reflect
the current system.

---

## Architecture in one paragraph

HPMS is **not a standalone service**. It is implemented as additions to three existing
modules of `mall-parent` (located at `c:/Users/HP/Videos/mall-parent`):

| Module | What HPMS adds |
|---|---|
| `mall-userms` | Invitation codes, Inviter↔Invitee bindings, soft `user_flag` column, user-facing invite endpoints, admin user-flag endpoints |
| `mall-rebate` | Rate config + history, commission records, batch run records, admin endpoints. New package `com.yuanfeng.rebate.inviter.*` with **no shared classes with existing rebate code** |
| `mall-payment` | New income type `Sales Commission`; internal Feign endpoint to credit balances |

`mall-order` is read-only via Feign (source of settled-order data). `mall-job` hosts the
monthly commission xxl-job handler. Inter-module communication is OpenFeign for sync,
existing RocketMQ topics where already in use.

Full architecture: [docs/01_ARCHITECTURE.md](./docs/01_ARCHITECTURE.md).

---

## Source document trust level

The original PM-authored docs (PRD v2.0, Process Diagrams, Data Dictionary — now in
[docs/archive/](./docs/archive/)) and the current [PRD v3.0](./docs/MSC_HPMS_PRD_v3.0.md)
are **informational, not authoritative**.

Use them to understand:

- Business intent and terminology
- Commission logic (rate tiers, single-level attribution)
- Process flows and state transitions
- Naming conventions

Apply independent engineering judgement on:

- Whether the data model actually supports the described logic
- Missing fields the PM didn't think to define
- Constraints described in words but not modelled correctly
- Indexes the PM never mentioned but query patterns require
- Anything underspecified or contradictory — flag it explicitly, don't silently follow

When the implementation diverges from the PM docs, the deviation is captured in
[docs/08_DEVIATIONS.md](./docs/08_DEVIATIONS.md) with rationale.

---

## Hard rules

These are non-negotiable; getting any of them wrong is a real bug.

### Lifetime binding

- A user is bound to at most one Inviter, **ever**. Enforced by `UNIQUE(invitee_user_id)`
  on `ucenter_inviter_binding`.
- A user attempting registration with a new code after already being bound: the new code
  is **silently ignored**. No error to the user. Detection is via catching the unique
  violation in service code.

### Single-level commission

- The commission batch never walks up the binding chain.
- Exactly one `inviter_commission_record` row per `(inviter_user_id, invitee_user_id, billing_month)`.
- Composite UNIQUE makes the monthly batch idempotent via `INSERT ... ON DUPLICATE KEY UPDATE`.

### Commission tier formula

- Stored as basis points (`INT`) to avoid floating-point drift. `100 BP = 1%`.
- `commission = round(tier1_rate_bp × min(sales, threshold) / 10000 + tier2_rate_bp × max(sales − threshold, 0) / 10000, 2)`.
- Rate-config is a single-row table; updates copy the previous values into
  `inviter_commission_rate_config_history` in the same transaction. Reason is mandatory
  on every change.
- Rate changes take effect from the **next** billing cycle. The current month uses the
  rate captured in `inviter_commission_batch.rate_config_snapshot` at batch start.

### Suspension

- When a user is suspended in `mall-userms`, the same transaction sets
  `ucenter_inviter_code.status = 'REVOKED'`. Subsequent registrations using the code
  are rejected.
- Suspension freezes commission accrual for that user. Pre-existing bindings stay.

### Code partition inside `mall-rebate`

- All HPMS code lives under `com.yuanfeng.rebate.inviter.*`. No shared classes,
  controllers, services, or mappers with the existing rebate module. Tables use the
  `inviter_commission_*` prefix; no joins or FKs to `rebate_*` tables.

### Audit trail

- Audit goes to **Kibana** via structured Logback log lines for every admin action,
  rate change, suspension, batch run.
- The **one DB exception** is `inviter_commission_rate_config_history`, because PRD §5.5
  explicitly requires the admin rate-config page to display historical changes.

---

## Stack and conventions

Everything inherited from `mall-parent`:

- Java 21 LTS, Spring Boot 3.2.4, Undertow, MyBatis-Plus 3.5.5, MySQL 8
- `utf8mb4` / `utf8mb4_unicode_ci`. Storage timezone UTC; display Africa/Lagos at the
  Spring/Jackson boundary.
- Manual SQL DDL applied per module (house pattern); no Flyway for HPMS tables.
- BIGINT auto-increment primary keys (matches surrounding modules; UUIDs were a
  reverted v0.4 deviation).
- `DECIMAL(15,2)` for money. Rates as `INT` basis points.
- FastJSON 2.0.53 (house JSON library).
- OpenFeign for sync inter-module calls. xxl-job (existing instance) for scheduled tasks.
- Logback → Logstash TCP → Kibana for application logs.

---

## Code conventions

- **Table naming:** `ucenter_inviter_*` in mall-userms; `inviter_commission_*` in mall-rebate.
- **No DB triggers anywhere in HPMS.** Cross-row and immutability rules live in service code.
- **No format CHECK constraints.** Format validation in service-layer validators.
- **No FKs across the userms↔rebate boundary.** Use service calls (Feign) for cross-module reads.
- **Idempotency keys** on every Feign write that may be retried (e.g. payment credit:
  `batch_id + ":" + record_id`).

---

## Open questions

These need product / Finance / Ops answers before some paths can be finalised. See
[docs/02_PROJECT_CONTEXT.md §7](./docs/02_PROJECT_CONTEXT.md#7-open-product-questions-still-outstanding)
and [docs/06_SCHEMA_DESIGN.md §8](./docs/06_SCHEMA_DESIGN.md#8-open-questions-for-finance--pm--ops).

Don't hard-code answers to these in code without flagging:

1. Default commission rates at launch (1% / 2% / ₦1M threshold) — Finance.
2. Mid-month suspension semantics for orders settling on the suspension day — PM.
3. Rounding mode (banker's vs half-up) — Finance.
4. Whether code revocation can be decoupled from user suspension — PM.
5. Soft-tag governance — who can grant `FIELD_PROMOTER` — Ops.

---

## Documentation map

When you change something, the doc to update is usually obvious. Quick reference:

| What changed | Where to update |
|---|---|
| Schema (DDL) | [docs/06_SCHEMA_DESIGN.md](./docs/06_SCHEMA_DESIGN.md) |
| A business rule moved between layers | [docs/07_APPLICATION_INVARIANTS.md](./docs/07_APPLICATION_INVARIANTS.md) |
| Implementation diverges from PM docs | Add `D-NNN` entry in [docs/08_DEVIATIONS.md](./docs/08_DEVIATIONS.md) |
| Cross-module integration shape | [docs/01_ARCHITECTURE.md](./docs/01_ARCHITECTURE.md) |
| Timeline / decisions / open questions | [docs/02_PROJECT_CONTEXT.md](./docs/02_PROJECT_CONTEXT.md) |
| Adding a new design doc | Next number after 08; update [docs/00_README.md](./docs/00_README.md) |
