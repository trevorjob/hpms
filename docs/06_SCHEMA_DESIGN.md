# MSC HPMS — Schema Design v1.0

> Database design — distributed across `mall-userms` and `mall-rebate`.

| | |
|---|---|
| Project | MSC HPMS |
| Document version | 1.0 — distributed-module approach |
| Target engine | MySQL 8 (matches house) |
| Charset / collation | `utf8mb4` / `utf8mb4_unicode_ci` |
| Storage timezone | UTC at the connection; Africa/Lagos at the app boundary |
| Migration approach | Manual SQL DDL applied per module (house convention) |
| Author | Job Kumdan |
| Date | 4 May 2026 |
| Supersedes | Schema Design v1.0 (29 April 2026) — written for the standalone-service approach |
| Companion docs | [01_ARCHITECTURE](./01_ARCHITECTURE.md) · [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md) · [08_DEVIATIONS](./08_DEVIATIONS.md) |

---

## 1. Executive summary

HPMS adds **six new tables** and **one new column** across two existing modules of
`mall-parent`:

- `mall-userms` — invitation codes, Inviter↔Invitee bindings, plus a soft tag on the
  user record for in-house field promoters.
- `mall-rebate` — commission rate config + history, commission records, batch run records.

`mall-payment` is touched at runtime (commission credits go to the existing balance with a
new income-type code `Sales Commission`) but no schema changes there.

`mall-order` is touched read-only via Feign; no schema changes.

The previous schema (10 tables for a standalone HPMS service with a 3-tier promoter
hierarchy, barcodes-as-tree, and onboarding bonus) is fully discarded.

### 1.1 Design philosophy

The database enforces **structural invariants only** — referential integrity, uniqueness,
NOT NULL, basic type sanity. Business rules (rate tiers, lifetime-binding semantics,
commission-status workflow) live in service code and are tested there.
See [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md).

### 1.2 Key design decisions

| Decision | Rationale |
|---|---|
| Distributed across existing modules | Team-lead direction (4 May 2026 resync). No new microservice |
| `inviter_*` / `ucenter_inviter_*` table prefixes | Make the partition obvious in `SHOW TABLES` and avoid any risk of joining to the unrelated `rebate_*` tables |
| `BIGINT` primary keys (auto-increment) | Match the surrounding modules' convention. UUIDs were a v0.4 deviation that was reverted along with the standalone-service decision |
| `BIGINT user_id` references | Match `ucenter_user_base.user_id` (existing) |
| Composite uniqueness on `(inviter_user_id, invitee_user_id, billing_month)` | Idempotent monthly batch re-runs via `INSERT ... ON DUPLICATE KEY UPDATE` |
| Single-row `inviter_commission_rate_config` + separate history table | Current rate is read on every batch run — single row keeps that O(1). History is a separate growth-only table for the admin UI |
| `invitation_code` is one row per user (not stored on the user table) | Allows status (active/revoked) and rotation later without polluting the user table; also matches the existing pattern of separating ucenter side-data |
| Lifetime binding | `UNIQUE(invitee_user_id)` on `ucenter_inviter_binding` — second binding attempt fails at the DB |
| Plain `DATETIME` (no fractional seconds) | Matches house pattern. Offline-scan was dropped from MVP, so ms-precision lost its only justification |
| `DECIMAL(15,2)` for money | Matches existing `mall-parent` modules |
| Audit logging via Kibana, not a DB table | Team-lead direction. The one exception is `inviter_commission_rate_config_history` because the PRD §5.5 requires displaying the rate history in the admin UI |

---

## 2. Tables in `mall-userms`

Three changes: a new column on the existing user table, plus two new tables.

### 2.1 New column on the existing user base table

```sql
ALTER TABLE ucenter_user_base
    ADD COLUMN user_flag VARCHAR(32) NULL
    COMMENT 'Operational soft tag — e.g. FIELD_PROMOTER for MSC employees acting as Inviters. NULL for ordinary users.';

CREATE INDEX ix_ucenter_user_base_flag ON ucenter_user_base(user_flag);
```

A `VARCHAR` (rather than a boolean or enum) leaves room for additional tags later without
a schema migration. Today's only value is `FIELD_PROMOTER`.

### 2.2 `ucenter_inviter_code` — invitation code per user

```sql
CREATE TABLE ucenter_inviter_code (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    user_id         BIGINT       NOT NULL,
    code            VARCHAR(16)  NOT NULL          COMMENT 'Short alphanumeric, e.g. 8 chars; URL- and QR-safe',
    qr_payload      VARCHAR(512) NOT NULL          COMMENT 'Encoded payload for QR generation; contains code + checksum',
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                                                    COMMENT 'ACTIVE / REVOKED. REVOKED on user suspension; cannot be scanned',
    create_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    update_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_inviter_code_user (user_id),
    UNIQUE KEY uq_inviter_code_code (code),
    KEY ix_inviter_code_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — one row per registered user; carries their invitation code and QR payload.';
```

- `UNIQUE(user_id)` enforces 1:1 — every user has at most one code at any time.
- `UNIQUE(code)` makes lookup cheap and prevents collisions in code generation.
- Code generation runs at registration; the application retries on the rare unique-violation.

### 2.3 `ucenter_inviter_binding` — Inviter↔Invitee binding

```sql
CREATE TABLE ucenter_inviter_binding (
    id                 BIGINT      NOT NULL AUTO_INCREMENT,
    invitee_user_id    BIGINT      NOT NULL          COMMENT 'The user who was invited (always the row identity)',
    inviter_user_id    BIGINT      NOT NULL          COMMENT 'The user whose invitation code was used',
    bound_via_code     VARCHAR(16) NOT NULL          COMMENT 'The actual code value used at registration; preserved for audit',
    bound_at           DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                    COMMENT 'Server timestamp when the binding was recorded; immutable',
    PRIMARY KEY (id),
    UNIQUE KEY uq_inviter_binding_invitee (invitee_user_id),
    KEY ix_inviter_binding_inviter (inviter_user_id),
    KEY ix_inviter_binding_bound_at (bound_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — lifetime Inviter→Invitee binding. UNIQUE(invitee_user_id) enforces one-binding-ever per user.';
```

- `UNIQUE(invitee_user_id)` is the lifetime-binding rule. A second registration with a
  different code by the same user fails at the DB; the registration service catches the
  unique violation and silently ignores the new code (PRD §5.1).
- No FK to `ucenter_user_base` because cross-table FKs aren't house pattern in `mall-userms`
  (existing tables use explicit lookups in service code). Following local convention.
- `bound_via_code` is intentionally denormalized — codes can be revoked or reissued; the
  binding row preserves the exact code that was used for audit.

---

## 3. Tables in `mall-rebate`

All new tables sit under the `inviter_commission_*` prefix and contain no shared columns,
joins, or FKs to existing `rebate_*` tables. Code-level partition is a separate package
(`com.yuanfeng.rebate.inviter.*`) per
[01_ARCHITECTURE §2](./01_ARCHITECTURE.md#2-module-distribution).

### 3.1 `inviter_commission_rate_config` — current active rates (single row)

```sql
CREATE TABLE inviter_commission_rate_config (
    id                  BIGINT         NOT NULL AUTO_INCREMENT,
    tier1_threshold     DECIMAL(15,2)  NOT NULL          COMMENT 'Monthly per-Invitee sales threshold; default 1,000,000.00',
    tier1_rate_bp       INT            NOT NULL          COMMENT 'Tier 1 rate in basis points; 100 = 1%. Stored as BP to avoid float drift',
    tier2_rate_bp       INT            NOT NULL          COMMENT 'Tier 2 rate in basis points; 200 = 2%',
    effective_from      DATETIME       NOT NULL          COMMENT 'When this config became active. Set to update_time on insert',
    update_time         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — single-row table. Always exactly one row; updates create a history entry then UPDATE.';
```

- **Single-row table.** The application asserts `SELECT COUNT(*) FROM inviter_commission_rate_config = 1`
  at boot. Rate updates are `UPDATE` statements, not inserts; the previous value is
  copied into `inviter_commission_rate_config_history` first within the same transaction.
- Rates stored as **basis points** (integer) rather than decimal percents to eliminate
  floating-point drift in the formula. `100 BP = 1%`. Computation:
  `commission = sales × rate_bp / 10000`.
- `effective_from` is informational; the rate that *applies* to a billing month is
  whichever row is present in this table when the batch for that month runs (PRD §5.5
  "Rate changes take effect from the next billing cycle").

### 3.2 `inviter_commission_rate_config_history` — append-only change log

```sql
CREATE TABLE inviter_commission_rate_config_history (
    id                       BIGINT         NOT NULL AUTO_INCREMENT,
    actor_admin_id           BIGINT         NOT NULL          COMMENT 'mall-userms admin user_id who performed the change',
    prev_tier1_threshold     DECIMAL(15,2)  NULL              COMMENT 'NULL for the very first row only',
    prev_tier1_rate_bp       INT            NULL,
    prev_tier2_rate_bp       INT            NULL,
    new_tier1_threshold      DECIMAL(15,2)  NOT NULL,
    new_tier1_rate_bp        INT            NOT NULL,
    new_tier2_rate_bp        INT            NOT NULL,
    reason                   VARCHAR(500)   NOT NULL          COMMENT 'Required by PRD §5.5; admin must provide a reason on every change',
    occurred_at              DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY ix_inviter_rate_history_occurred (occurred_at),
    KEY ix_inviter_rate_history_actor (actor_admin_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — append-only history of rate changes. Read by the admin UI history view (PRD §5.5).';
```

- Append-only **by application convention** — the rate-change service is the only writer.
  No DB triggers (Kibana logging is the platform pattern; for compliance-critical tables
  we discussed triggers + GRANT in v0.4 but that was for a standalone audit table that
  no longer exists).
- `prev_*` columns are `NULL` only for the first row (initial config seed).

### 3.3 `inviter_commission_batch` — one row per batch run

```sql
CREATE TABLE inviter_commission_batch (
    id                       BIGINT         NOT NULL AUTO_INCREMENT,
    billing_month            CHAR(7)        NOT NULL          COMMENT 'YYYY-MM. Format validated in app',
    status                   VARCHAR(16)    NOT NULL DEFAULT 'RUNNING'
                                                              COMMENT 'RUNNING / COMPLETED / FAILED / CANCELLED',
    trigger_source           VARCHAR(16)    NOT NULL          COMMENT 'SYSTEM_CRON / ADMIN_MANUAL',
    triggered_by_admin_id    BIGINT         NULL              COMMENT 'Required when trigger_source=ADMIN_MANUAL',
    rate_config_snapshot     JSON           NULL              COMMENT 'Rate-config row values captured at batch start, for forensics',
    started_at               DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at             DATETIME       NULL,
    error_message            VARCHAR(2000)  NULL,
    total_orders_processed   INT            NULL,
    total_records_upserted   INT            NULL,
    total_gross_commission   DECIMAL(15,2)  NULL,
    xxl_job_log_id           BIGINT         NULL              COMMENT 'Cross-reference into xxl-job execution history',
    PRIMARY KEY (id),
    KEY ix_inviter_batch_billing (billing_month, started_at),
    KEY ix_inviter_batch_status (status),
    KEY ix_inviter_batch_xxl (xxl_job_log_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — explicit batch-run record. Allows admins to see which run produced/failed which rows.';
```

- `rate_config_snapshot` JSON is captured once at batch start so the run is reproducible
  even if an admin changes the rate while the batch is mid-flight.
- A re-run for the same `billing_month` creates a *new* row; the upsert against
  `inviter_commission_record` uses the new `id` for `batch_id`.

### 3.4 `inviter_commission_record` — one row per (Inviter, Invitee, billing_month)

```sql
CREATE TABLE inviter_commission_record (
    id                       BIGINT         NOT NULL AUTO_INCREMENT,
    batch_id                 BIGINT         NOT NULL          COMMENT 'The most recent batch that wrote this row',
    inviter_user_id          BIGINT         NOT NULL,
    invitee_user_id          BIGINT         NOT NULL,
    billing_month            CHAR(7)        NOT NULL          COMMENT 'YYYY-MM',
    invitee_monthly_sales    DECIMAL(15,2)  NOT NULL          COMMENT 'Sum of SETTLED order_value for this invitee in this month',
    commission_amount        DECIMAL(15,2)  NOT NULL          COMMENT 'Tier-formula result. Computed in app',
    rate_config_id           BIGINT         NOT NULL          COMMENT 'Which inviter_commission_rate_config row was applied',
    status                   VARCHAR(16)    NOT NULL DEFAULT 'CALCULATED'
                                                              COMMENT 'CALCULATED / APPROVED / DISPUTED / PAID',
    dispute_note             VARCHAR(500)   NULL,
    calculated_at            DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    approved_by_admin_id     BIGINT         NULL,
    approved_at              DATETIME       NULL,
    paid_at                  DATETIME       NULL              COMMENT 'Set after mall-payment confirms credit',
    PRIMARY KEY (id),
    UNIQUE KEY uq_inviter_record_iim (inviter_user_id, invitee_user_id, billing_month),
    KEY ix_inviter_record_batch (batch_id),
    KEY ix_inviter_record_inviter (inviter_user_id),
    KEY ix_inviter_record_invitee (invitee_user_id),
    KEY ix_inviter_record_billing (billing_month),
    KEY ix_inviter_record_status (status),
    KEY ix_inviter_record_report (billing_month, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='HPMS — one row per (inviter, invitee, billing_month). Composite UNIQUE makes batch re-runs idempotent.';
```

- **`UNIQUE(inviter_user_id, invitee_user_id, billing_month)`** is the critical
  invariant. Batch uses `INSERT ... ON DUPLICATE KEY UPDATE` to make re-runs no-ops for
  unchanged inputs.
- Single `commission_amount` column — no `gross / split / net` separation, no
  `commission_type DIRECT/OVERRIDE`. Single-level attribution by design.
- `rate_config_id` lets us trace which rate produced this row even if the rate changes
  later. With `inviter_commission_batch.rate_config_snapshot`, every row is fully
  reproducible.

---

## 4. Cross-module data flows

See [01_ARCHITECTURE §4](./01_ARCHITECTURE.md#4-cross-module-data-flows) for the
full diagrams. Schema-side notes:

- **Registration with code:** single transaction in `mall-userms` writes both
  `ucenter_inviter_binding` (if a valid code) and `ucenter_inviter_code` (always —
  the new user's own code). UNIQUE violations on `invitee_user_id` are caught and
  silently ignored.
- **Monthly batch:** single transaction per Invitee per billing month for the upsert.
  Cross-module reads (settled orders from mall-order, bindings from mall-userms) happen
  via Feign before the transaction opens.
- **Approval:** transition to `APPROVED` and the Feign call to mall-payment are in the
  same DB transaction. If the Feign call fails, the transaction rolls back and status
  stays `CALCULATED`. mall-payment's idempotency key on the credit endpoint protects
  against retry double-credit.

---

## 5. Integrity controls

### 5.1 Lifetime binding

| Layer | Mechanism |
|---|---|
| DB | `UNIQUE(invitee_user_id)` on `ucenter_inviter_binding` |
| App | Registration service catches the unique violation and silently ignores the new code (PRD §5.1) |

### 5.2 Single-level commission attribution

| Layer | Mechanism |
|---|---|
| DB | `inviter_commission_record.UNIQUE(inviter, invitee, billing_month)` |
| App | Batch only computes one row per binding per month — never walks up the binding chain |

### 5.3 Idempotent monthly batch

| Layer | Mechanism |
|---|---|
| DB | Composite UNIQUE on `inviter_commission_record` |
| App | `INSERT ... ON DUPLICATE KEY UPDATE` in the batch service |
| Forensics | `inviter_commission_batch.rate_config_snapshot` JSON freezes the rate at batch start |

### 5.4 Rate-config history

| Layer | Mechanism |
|---|---|
| DB | `inviter_commission_rate_config_history` (append-only by app convention) |
| App | The rate-update service writes both rows in one transaction; UPDATEs the live config and inserts the history row |
| Display | Admin rate-config page reads the history table directly |
| Logging | Same change is also emitted as a structured Kibana log line |

### 5.5 Code revocation on user suspension

| Layer | Mechanism |
|---|---|
| App | When a user is suspended in `mall-userms`, the same transaction sets `ucenter_inviter_code.status = 'REVOKED'` |
| DB | Validation endpoint (`GET /invitations/validate?code=…`) joins on `status = 'ACTIVE'` |
| Lifetime bindings | Pre-existing bindings remain — suspension freezes future accrual but does not retroactively invalidate already-bound users |

### 5.6 Field-promoter tag

| Layer | Mechanism |
|---|---|
| DB | `ucenter_user_base.user_flag` column, indexed |
| App | Set/unset via admin endpoint; commission logic does NOT branch on it; reports/dashboards filter on it |

---

## 6. Index strategy

Hot-path queries and their supporting indexes:

| Query | Index | Why |
|---|---|---|
| Batch enumerates settled orders for the month | (in mall-order, existing) | Done via Feign — not our index to build |
| Batch looks up an invitee's binding | `ucenter_inviter_binding(invitee_user_id)` UNIQUE | One row per invitee, by definition |
| Validate an invitation code at registration | `ucenter_inviter_code(code)` UNIQUE | Hot path on every invited registration |
| Inviter dashboard — "my invitees" | `ucenter_inviter_binding(inviter_user_id)` | List of children |
| Inviter dashboard — "my commission this month" | `inviter_commission_record(inviter_user_id, billing_month, status)` (covered by `(inviter)` + `(billing_month, status)`) | Filter + sum |
| Admin commission report by month | `inviter_commission_record(billing_month, status)` | Workflow + reporting hot path |
| Latest batch for a billing month | `inviter_commission_batch(billing_month, started_at)` | "Re-run the latest" / "show last completion" |
| Filter users by soft tag | `ucenter_user_base(user_flag)` | Operations dashboards |

### 6.1 Indexing philosophy

- Every UNIQUE constraint creates an index; every join column gets one too.
- `inviter_commission_record` has more indexes than usual because the table feeds three
  hot queries (per-inviter dashboard, per-month report, batch upsert) with very different
  predicates. Write cost is acceptable — it's only written by the monthly batch.
- The single-row `inviter_commission_rate_config` has no extra indexes; primary key is
  enough.

---

## 7. Migration order (manual SQL)

Execute on the same MySQL instance both modules already use. Because each statement is a
self-contained DDL with no FKs across modules, ordering is loose; the safe sequence is:

1. `ALTER TABLE ucenter_user_base ADD COLUMN user_flag ...`
2. `CREATE TABLE ucenter_inviter_code ...`
3. `CREATE TABLE ucenter_inviter_binding ...`
4. `CREATE TABLE inviter_commission_rate_config ...`
5. `CREATE TABLE inviter_commission_rate_config_history ...`
6. `CREATE TABLE inviter_commission_batch ...`
7. `CREATE TABLE inviter_commission_record ...`
8. Seed `inviter_commission_rate_config` with the launch defaults — pending Finance:
   `tier1_threshold = 1000000.00, tier1_rate_bp = 100, tier2_rate_bp = 200`. Confirm
   before running.
9. (Optional) seed an initial history row corresponding to the launch defaults so the
   admin UI shows "Initial config" as the first entry.

The full DDL is the union of the snippets in §2 and §3 above. No separate migration file
is committed to the repo because the house pattern is to apply DDL manually and track it
in the team's runbook.

---

## 8. Open questions for Finance / PM / Ops

| # | Question | Impact |
|---|---|---|
| Q1 | Confirm launch defaults: `tier1_threshold = ₦1,000,000`, `tier1_rate = 1%`, `tier2_rate = 2%` (PRD §10 Q2) | Initial seed of `inviter_commission_rate_config` |
| Q2 | What does "suspension freezes commission accrual immediately" mean for orders that settle the same day a user is suspended? Are those orders included in the batch or not? | Batch filter logic |
| Q3 | When a user is suspended, do already-bound invitees' future-month commissions stop too? Or only the suspended user's outbound commission stops? | Service logic; no schema change either way |
| Q4 | Reserved admin user_id used for `actor_admin_id` on system-initiated config changes (e.g. seed)? | Single hardcoded ID or NULL; affects the NOT NULL constraint on the history row |
| Q5 | Is there a "deactivate user's invitation code without suspending the account" use case? | Currently revocation is coupled to user suspension; could be split if PM wants |

---

## 9. What was discarded from v0.4

For traceability — these tables are no longer part of HPMS:

- `promoters` (3-tier hierarchy) — replaced by `ucenter_inviter_binding` (flat, lifetime).
- `barcodes` (chain via `parent_barcode_id` + `root_barcode_id`) — replaced by
  `ucenter_inviter_code` (flat, one per user).
- `pharmacies` — pharmacies are users in `mall-userms` (`UcenterUserBusinessInfoEntity`,
  `UcenterKycApplicationEntity`).
- `orders`, `order_settlement_events` — read-mirror not needed; Feign to `mall-order`
  on demand.
- `onboarding_bonuses` — removed entirely from PRD v3.0.
- `commission_records.commission_type / split_percentage / gross_commission /
  net_commission` — collapsed to a single `commission_amount`.
- `audit_logs` — replaced by Kibana for everything except the rate-config history
  (which has its own table because the admin UI needs it).
- `verification_call_logs` — out of scope for MVP per PRD §10 Q4.

The reasoning is captured in [08_DEVIATIONS](./08_DEVIATIONS.md).

---

*End of document — Schema Design v1.0 — 4 May 2026.*
