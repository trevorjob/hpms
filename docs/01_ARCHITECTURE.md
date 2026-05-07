# MSC HPMS — Architecture v1.0

> Technical direction — distributed-module approach.

| | |
|---|---|
| Project | MSC Hierarchical Promotion Management System (HPMS) |
| Document version | 1.0 — Distributed across existing mall-parent modules |
| Author | Job Kumdan (Backend Lead) |
| Date | 4 May 2026 |
| Supersedes | v0.4 (21 April 2026) — standalone-service approach abandoned after PRD rewrite |
| Approved by | Team lead (resync 4 May 2026) |
| MVP launch | TBD — being reassessed after scope change |

> **About this version.** The previous architecture (v0.4, 21 April 2026) described HPMS
> as a standalone Spring Boot service. Following the rewrite of the PRD on 30 April 2026
> and the team-lead resync on 4 May 2026, **HPMS is no longer a standalone service.** It
> is implemented as additions to three existing modules in `mall-parent`. This document
> replaces v0.4 in full.

---

## 1. What HPMS is

A self-service referral platform for pharmacy onboarding and growth. Every registered
pharmacy user automatically becomes an Inviter, generates a unique invitation code and
QR code, and earns single-level commission on the settled orders of any pharmacy they
directly invite. There is no multi-level cascade and no role hierarchy. The authoritative
product spec is [MSC_HPMS_PRD_v3.0.md](./MSC_HPMS_PRD_v3.0.md); the previous PDF is
retained only for historical context.

In-house field promoters operate as standard Inviters in the system. Their salary and
HR are managed offline. A soft tag (`user_flag`) on the user record marks them for
operational reporting only; commission logic does not branch.

---

## 2. Module distribution

HPMS does not ship as its own service or Maven module. The functionality is implemented
as new code and new tables inside three existing modules of `mall-parent`:

| Module | What HPMS adds | New tables/columns |
|---|---|---|
| `mall-userms` | Invitation codes, Inviter↔Invitee bindings, field-promoter tag, user-facing invite endpoints | `ucenter_inviter_code`, `ucenter_inviter_binding`; new column `user_flag` on the existing user table |
| `mall-rebate` | Inviter-commission rate config + history, commission records, batch run records, admin rate-config & report endpoints, batch handler called by `mall-job` | `inviter_commission_rate_config`, `inviter_commission_rate_config_history`, `inviter_commission_record`, `inviter_commission_batch` |
| `mall-payment` | New income type `Sales Commission`; consumes commission-approval Feign call to credit the user balance | (no new tables — uses existing balance/income tables) |

Two more existing modules participate without owning HPMS code:

| Module | Role |
|---|---|
| `mall-order` | Source of settled-order data. `mall-rebate`'s commission batch reads from it via Feign. No HPMS-specific code lives here. |
| `mall-job` | Hosts the monthly commission batch as an xxl-job handler, mirrored on the existing `RebateDistributionJob` pattern. Calls `mall-rebate` via Feign. |

### Code-level partitioning

Within `mall-rebate`, all HPMS code lives under a dedicated package
`com.yuanfeng.rebate.inviter.*` — controllers, services, mappers, entities, Feign clients.
**No shared classes with the existing rebate code.** The `inviter_commission_*` tables are
not joined to or referenced from the existing `rebate_*` tables. This is the team-lead's
explicit instruction (resync, 4 May 2026): same module, same JAR, same DB, but logically
separated so the two concerns can evolve independently and the package can be extracted
to its own service later if scale demands.

The same partitioning applies in `mall-userms`: HPMS-specific code lives under
`com.yuanfeng.userms.inviter.*`.

### Why not a separate service

Captured here so the reasoning isn't lost:

1. **Coupled with existing business by design.** The new PRD makes HPMS lean heavily on
   existing user records, balances, and order events. A standalone service would have
   been a thin shell around remote calls.
2. **Rebate is the unified commission concept.** All commission-style logic in the
   platform consolidates here. Different commission rules separate at the package level.
3. **Infrastructure cost.** 17 microservices already run in production. Each addition
   consumes cluster resources. When transaction volume warrants it, finer service
   splitting can happen — package boundaries make extraction tractable.

---

## 3. Stack inheritance

Everything is inherited from `mall-parent`. No new infrastructure, no new dependencies,
no new Nacos namespace, no new Docker image, no new CI pipeline.

| Layer | Stack |
|---|---|
| Language | Java 21 LTS |
| Framework | Spring Boot 3.2.4 |
| Web server | Undertow (Tomcat excluded) |
| Data access | MyBatis-Plus 3.5.5, XML mappers |
| Database | MySQL 8 (`utf8mb4_unicode_ci`, connection tz Africa/Lagos, UTC at storage layer) |
| Schema migrations | Manual SQL (house convention) |
| Cache | Redis + Jedis 5.2.0 |
| Config & discovery | Nacos |
| Auth | JWT HS256 via JJWT + Spring Security |
| Async | RocketMQ 5.1.4 (existing topics only; HPMS does not introduce new ones) |
| Sync inter-module | OpenFeign + Nacos discovery + Spring Cloud LoadBalancer |
| Scheduled jobs | xxl-job (existing instance, `mall-job` module) |
| Logging | Logback + logstash-logback-encoder → Kibana |
| API docs | Knife4j 4.4.0 |
| JSON | FastJSON 2.0.53 |
| Money | `BigDecimal` in Java, `DECIMAL(15,2)` in MySQL |

The v0.4 architecture proposed several deviations from house convention (Flyway, Jackson,
multi-stage Dockerfile, refresh-tokens, etc.). **All of those are now reverted.** HPMS
inherits everything from the surrounding modules.

---

## 4. Cross-module data flows

### 4.1 Pharmacy registers with an invitation code

```text
Pharmacy app                    mall-userms
    │
    │  POST /users/register { invitation_code: "..." }
    ├───────────────────────────────►
    │
    │     1. Validate code → ucenter_inviter_code lookup
    │     2. Create user (existing flow)
    │     3. If valid code AND user not previously bound:
    │           INSERT ucenter_inviter_binding(invitee_user_id, inviter_user_id, …)
    │     4. Generate THIS user's own invitation code:
    │           INSERT ucenter_inviter_code(user_id, code, …)
    │     5. Audit: structured log line → Kibana
    │
    │  ◄──── 200 OK with user profile + their own code
```

If the user is already bound (registered with a code previously), step 3 is skipped
silently — PRD rule, never error to the user.

### 4.2 Order settled → no real-time HPMS work

`mall-order` settles an order normally; no HPMS Feign call is added to the settlement
path. Commission is computed monthly because the rate tier (1% up to ₦1M, 2% above) needs
the full per-Invitee monthly total to apply correctly. Doing it incrementally is harder
and not required by the PRD.

### 4.3 Monthly commission batch

```text
xxl-job (cron 0 0 2 1 * ?)
    │
    ▼
mall-job: InviterCommissionBatchJob
    │  Feign → mall-rebate /api/inviter-commission/run-batch?billingMonth=YYYY-MM
    ▼
mall-rebate: InviterCommissionBatchService
    │
    │  1. INSERT inviter_commission_batch(status=RUNNING, …)
    │  2. Feign → mall-order: settled orders in [billingMonth start, end)
    │  3. Feign → mall-userms: bindings for the invitee user_ids
    │  4. Read current inviter_commission_rate_config
    │  5. Aggregate per (inviter, invitee), apply tier formula, compute commission
    │  6. UPSERT inviter_commission_record on (inviter_user_id, invitee_user_id, billing_month)
    │     using INSERT ... ON DUPLICATE KEY UPDATE (idempotent re-runs)
    │  7. UPDATE inviter_commission_batch(status=COMPLETED, totals, completed_at)
    │  8. Audit: structured log line per batch → Kibana
    │
    │  ◄──── 200 OK
```

Re-runnable from xxl-job admin console with the same `billing_month` parameter — the
composite unique key makes the upsert a no-op for unchanged data.

### 4.4 Admin approves a commission batch → wallet credit

```text
Admin web                      mall-rebate                    mall-payment
    │
    │  PATCH /api/admin/inviter-commission/batches/{id}/approve
    ├───────────────────────────►
    │                              │
    │                              │  UPDATE inviter_commission_record
    │                              │     SET status=APPROVED, approved_by, approved_at
    │                              │  WHERE batch_id = … AND status='CALCULATED'
    │                              │
    │                              │  Feign → mall-payment: creditCommissionBalance(line items)
    │                              ├──────────────────────►
    │                              │                          │
    │                              │                          │  Credit balance per user
    │                              │                          │  Insert income line:
    │                              │                          │     income_type='Sales Commission'
    │                              │                          │
    │                              │  ◄────────────────────── 200 OK
    │                              │
    │                              │  UPDATE inviter_commission_record
    │                              │     SET status=PAID, paid_at
    │
    │  ◄──── 200 OK with batch summary
```

### 4.5 Admin updates the commission rate

```text
Admin web                      mall-rebate
    │
    │  PUT /api/admin/inviter-commission/rate-config
    │      { tier1_threshold, tier1_rate, tier2_rate, reason }
    ├───────────────────────────►
    │
    │   Single transaction:
    │     1. INSERT inviter_commission_rate_config_history(
    │            actor_id, prev_*, new_*, reason, effective_from, occurred_at)
    │     2. UPDATE inviter_commission_rate_config SET … (single-row table)
    │     3. Audit: structured log line → Kibana
    │
    │  Effective for next billing month (current month uses the rate
    │  active when the batch runs).
    │
    │  ◄──── 200 OK
```

---

## 5. API surface

All endpoints live inside the existing modules' controllers. No new gateway routes.

### 5.1 mall-userms (existing path conventions apply)

User-facing:

- `POST /users/register` — extended to accept optional `invitation_code`
- `GET /invitations/my-code` — returns the authenticated user's invitation code + QR payload
- `GET /invitations/validate?code={code}` — pre-registration validation
- `GET /invitations/invitees` — list of users the authenticated user has invited
- `GET /invitations/stats` — total invitees, cumulative commission (commission total fetched from rebate via Feign)

Admin:

- `GET /admin/users?user_flag=FIELD_PROMOTER&...` — filter by soft tag
- `PATCH /admin/users/{id}/flag` — set/unset `user_flag`

### 5.2 mall-rebate

Public (authenticated user):

- `GET /inviter-commission/my-summary?month=YYYY-MM`
- `GET /inviter-commission/my-breakdown?month=YYYY-MM`

Admin:

- `GET /admin/inviter-commission/rate-config`
- `PUT /admin/inviter-commission/rate-config`
- `GET /admin/inviter-commission/rate-config/history`
- `POST /admin/inviter-commission/run-batch?billingMonth=YYYY-MM` (also called by mall-job)
- `GET /admin/inviter-commission/report?month=YYYY-MM`
- `GET /admin/inviter-commission/batches/{id}`
- `PATCH /admin/inviter-commission/batches/{id}/approve`

### 5.3 mall-payment

Internal (Feign only, called by mall-rebate):

- `POST /internal/payment/credit-commission` — credits commission line items, records `Sales Commission` income type

---

## 6. Logging, audit, observability

Inherited from house pattern: SLF4J → Logstash TCP → Kibana.

Per team-lead direction, **HPMS does not maintain a separate `audit_logs` table.**
Structured log lines via Kibana cover all admin actions, suspensions, and rate changes.

The one exception: **`inviter_commission_rate_config_history`** is a DB table because the
PRD §5.5 explicitly requires the admin rate-config page to display a historical view, and
serving that from Kibana would be both heavier and less reliable than reading from a small
table.

---

## 7. Security

All inherited from `mall-parent`:

- JWT HS256 via the existing auth flow
- BCrypt password hashing
- Spring Security + `@PreAuthorize` at controllers
- Per-environment CORS
- Rate limiting (existing patterns)

HPMS-specific concerns:

- Invitation codes are public-by-design (printed on QR codes, shared) — no additional
  protection. Suspension of a user deactivates their code via a status flag; subsequent
  scans of a deactivated code reject at the userms validation step.
- Commission rate-config endpoints are admin-only (`@PreAuthorize` + service-layer
  re-check).
- The `inviter_commission_record` table contains money figures by user — standard
  RBAC on read endpoints.

---

## 8. Out of scope (Phase 1 MVP)

Per [MSC_HPMS_PRD_v3.0.md §9](./MSC_HPMS_PRD_v3.0.md):

- System-level role distinction between field promoters and external Inviters (managed
  offline; soft tag is for reporting only).
- Multi-level cascading commissions (single-level only by design).
- Salary payroll integration (offline by MSC HR).
- B2B tiered promotion + virtual badges (deferred).
- Push notifications for commission events.
- Advanced cohort analytics.
- Direct payment disbursement (commission lands in the existing balance — withdrawals
  follow the existing flow).

---

## 9. Delivery plan

Timeline being reassessed after the scope change (PRD v3.0 Open Question Q1). Working
estimates pending re-plan:

- **Phase 1 — userms additions:** invitation code generation, binding, registration
  extension, admin tag endpoints. ~3-5 days.
- **Phase 2 — rebate additions:** rate-config CRUD + history, commission record schema,
  batch handler, admin endpoints. ~5-7 days.
- **Phase 3 — payment integration:** internal credit endpoint, income type. ~1-2 days.
- **Phase 4 — mall-job batch wiring:** xxl-job handler + Feign client. ~1 day.
- **Phase 5 — frontend integration, QA, UAT.** ~5-7 days.

---

## 10. Top risks

1. **Tier-formula correctness across the rate-change boundary.** Settled orders from
   month N use the rate active when month N's batch runs. If the rate changes mid-month,
   confusion is possible. The history table + clear admin UX mitigate.
2. **Idempotency of the batch.** Composite unique on `inviter_commission_record` plus
   `INSERT ... ON DUPLICATE KEY UPDATE` is the lever; needs explicit tests with re-runs.
3. **Cross-module Feign chain depth.** Batch goes mall-job → rebate → order + userms.
   Failures of any leg need clean retries; the batch row's `RUNNING/FAILED/COMPLETED`
   status is the recovery anchor.
4. **Suspended Inviter mid-month.** The PRD says suspension freezes accrual immediately
   and revokes the code. The batch must respect the user's status at the time it runs;
   "suspended at any point during the month" semantics need a one-line product
   confirmation (Open question).

---

*Document end. v1.0 — 4 May 2026. Replaces v0.4.*
