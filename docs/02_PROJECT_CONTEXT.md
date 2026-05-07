# MSC HPMS — Project Context & Handoff

**Purpose:** Complete context for continuing HPMS backend development in Claude Code.
Hand this to your next assistant alongside the new PRD, the architecture, the schema
design, the application invariants, and the deviations log.

**Status (6 May 2026):** PRD rewritten to v3.0 on 30 April. Team-lead resync on 4 May
shifted the architecture from a standalone HPMS service to additions inside three
existing `mall-parent` modules. Architecture, schema design, invariants, and deviations
docs all rewritten 4–6 May. **Implementation has not started.** Repo skeleton is
unnecessary now since HPMS lives inside `mall-parent`.

---

## 1. Project at a Glance

**What HPMS is.** An Inviter/Invitee referral platform inside the existing MSC platform.
Every registered pharmacy user is automatically an Inviter, generates a unique invitation
code + QR, and earns single-level commission on settled orders of any pharmacy they
directly invite. No multi-level cascade, no role hierarchy in the system. In-house field
promoters operate as standard Inviters with a soft tag (`user_flag = 'FIELD_PROMOTER'`)
for operational reporting only — salary and HR managed offline.

**Greenfield code, not greenfield infrastructure.** Distributed across `mall-userms`,
`mall-rebate`, `mall-payment`, `mall-order` (read-only), and `mall-job`. No new service.

**Authoritative product spec:** [MSC_HPMS_PRD_v3.0.md](./MSC_HPMS_PRD_v3.0.md). Earlier
PDFs (PRD v2.0, Process Diagrams, Data Dictionary) are retained for historical context
only — many of the entities they describe (3-tier promoters, barcodes-as-tree, onboarding
bonus) are no longer part of the system.

---

## 2. Timeline

| Date | Milestone |
|---|---|
| 21 Apr 2026 (Mon) | Sprint 1 kickoff — DONE (under previous PRD) |
| 23 Apr 2026 (Wed) | (was: repo skeleton) — superseded |
| 24 Apr 2026 (Fri) | (was: OpenAPI freeze) — superseded |
| **30 Apr 2026 (Wed)** | **PRD v3.0 dropped — fundamental rewrite of the model** |
| **4 May 2026 (Mon)** | **Team-lead resync — distributed-module architecture confirmed** |
| 4–6 May 2026 | Architecture, schema, invariants, deviations docs rewritten |
| TBD | MVP demo — being reassessed (PRD v3.0 §10 Q1) |
| TBD | Production go-live — being reassessed |

Working estimate for the rewrite phase ([01_ARCHITECTURE §9](./01_ARCHITECTURE.md#9-delivery-plan)):

- Phase 1 — `mall-userms` additions: ~3–5 days
- Phase 2 — `mall-rebate` additions: ~5–7 days
- Phase 3 — `mall-payment` integration: ~1–2 days
- Phase 4 — `mall-job` batch wiring: ~1 day
- Phase 5 — frontend integration, QA, UAT: ~5–7 days

These are coding-only estimates and exclude PRD-blocked items (rate defaults,
suspension semantics, rounding mode).

---

## 3. Team

- **Job Kumdan** — Backend lead. Primary engineer.
- **Team lead** (Baraka Aluja) — Reviews architecture and schema. Communicates in
  Chinese sometimes; English messages fine. Approved the distributed-module shift on
  4 May 2026.
- **PMs** — Authored PRD v3.0. Own remaining open questions.
- **Frontend lead** — Owns Admin web + mobile app codebases.
- **QA lead** — Picks up dev builds weekly.
- A few teammates handle other `mall-parent` modules; no one "owns" a single module —
  HPMS additions to `mall-userms`, `mall-rebate`, `mall-payment` are coordinated
  internally as needed.

---

## 4. Stack

All inherited from `mall-parent`. No new infrastructure.

```text
Java 21 LTS + Spring Boot 3.2.4 + Undertow
MyBatis-Plus 3.5.5 + manual SQL DDL + MySQL 8 (utf8mb4_unicode_ci)
Redis + Jedis 5.2.0
Nacos (config + discovery)
JWT HS256 + Spring Security + BCrypt
RocketMQ (existing topics; HPMS doesn't introduce new ones)
xxl-job (existing instance, mall-job module)
Logback + logstash-logback-encoder → Kibana
Knife4j 4.4.0 (API docs)
Hutool 5.8.29
FastJSON 2.0.53
OpenFeign + Spring Cloud LoadBalancer
```

The v0.4 deviation list (Flyway, Jackson, multi-stage Dockerfile, refresh tokens,
mall-commons replacement, Bucket4j, etc.) is **fully reverted** along with the
standalone-service decision. House conventions all the way.

---

## 5. Module Distribution — CRITICAL

HPMS is implemented across three existing modules. **No new microservice.** No top-level
HPMS package. Code-level partition keeps the option open to extract later if scale demands.

| Module | What HPMS adds | Tables |
|---|---|---|
| `mall-userms` | Invitation codes, Inviter↔Invitee bindings, soft `user_flag`, user-facing invite endpoints, admin user-flag endpoints | `ucenter_inviter_code`, `ucenter_inviter_binding`, new column `ucenter_user_base.user_flag` |
| `mall-rebate` | Rate config + history, commission records, batch run records, admin endpoints. New package `com.yuanfeng.rebate.inviter.*` — **no shared classes with existing rebate code** | `inviter_commission_rate_config`, `inviter_commission_rate_config_history`, `inviter_commission_batch`, `inviter_commission_record` |
| `mall-payment` | New income type `Sales Commission`; internal Feign endpoint to credit balances | (no schema changes) |

Two more modules participate without owning HPMS code:

- `mall-order` — source of settled-order data; `mall-rebate` reads via Feign
- `mall-job` — hosts the monthly commission xxl-job handler; mirrors `RebateDistributionJob`

See [01_ARCHITECTURE](./01_ARCHITECTURE.md) for the cross-module data flows.

---

## 6. Domain Rules — Hard Requirements (PRD v3.0)

### Inviter / Invitee model

- Every registered user automatically qualifies as an Inviter — no separate application,
  no Admin approval.
- Lifetime binding: each user is bound to at most one Inviter, ever. Subsequent codes
  are silently ignored.
- Single-level commission: the direct Inviter earns from each settled order placed by
  their direct Invitee. **No cascading.** A→B→C: B earns on C's orders, A earns nothing
  from C.
- No depth limit on the chain.

### Commission

- Triggered by an Invitee's order reaching SETTLED status (consumed in arrears by the
  monthly batch).
- Rate (default, configurable by Admin):
  - 1% on monthly settled Invitee orders up to ₦1,000,000
  - 2% on amounts above ₦1,000,000 per Invitee per month
- Calculated per pharmacy per month, then aggregated per Inviter.
- Settled commission is credited to the Inviter's MSC account balance (in `mall-payment`)
  with income type `Sales Commission`.
- No commission generated for non-SETTLED orders.

### Suspension

- Admin can suspend any user. Suspension freezes commission accrual immediately.
- Suspended user's invitation code is revoked — new registrations using it are rejected.
- Pre-existing bindings remain (suspension does not retroactively unbind invitees).

### Field promoters

- Operate as standard Inviters in the system — no commission-logic distinction.
- `user_flag = 'FIELD_PROMOTER'` is set by an admin endpoint for reporting/filtering only.
- Salary and HR managed offline by MSC HR.

---

## 7. Open Product Questions (still outstanding)

| # | Question | Status | Owner |
|---|---|---|---|
| 1 | Default commission rates at launch — confirm 1%/2%/₦1M threshold | Open | GM / Finance |
| 2 | Commission payout method — wallet only, or bank transfer too? | Open | Finance |
| 3 | What constitutes pharmacy certification (KYC) — document upload, manual review, or both? | Open | MSC Ops |
| 4 | How many field promoters at launch and in which cities? | Open | GM / Operations |
| 5 | Mid-month suspension semantics — exact rule for orders settling that day | Open | PM |
| 6 | Rounding mode (banker's vs half-up) | Open | Finance |
| 7 | Decoupling code revocation from user suspension — separate use case? | Open | PM |
| 8 | Soft-tag governance — who can grant `FIELD_PROMOTER`? | Open | Ops |
| 9 | Revised MVP delivery deadline | In progress | PO + team |

Many of these are blocking only the seed migration or specific tests; coding can begin
on most paths in parallel.

---

## 8. Already-Resolved Things (capturing decisions)

- **Service vs module:** module (distributed across mall-userms / mall-rebate / mall-payment).
  Team lead, 4 May 2026.
- **Field promoter management:** option B — soft tag (`user_flag` column). Team lead, 4 May 2026.
- **Pharmacy data ownership:** stays in mall-userms; HPMS does not own a `pharmacies`
  table. Implicit in distributed-module decision.
- **Commission engine reuses rebate module:** new tables and code, NO shared classes
  with existing rebate. Team lead, 4 May 2026.
- **Wallet credit mechanism:** Feign call from `mall-rebate` to `mall-payment` on admin
  approval; payment writes to existing balance with new income type code.
- **Order trigger:** Feign + monthly batch (no real-time per-order trigger). Verified
  against existing `RebateServiceClient` pattern in `mall-order`.
- **Audit:** Kibana for everything; one DB exception for `inviter_commission_rate_config_history`
  because PRD §5.5 requires a history view.
- **Storage timezone:** UTC at the connection, Africa/Lagos at the Spring/Jackson boundary.
- **PKs:** `BIGINT AUTO_INCREMENT` (matches surrounding modules; UUID deviation reverted).
- **Money:** `DECIMAL(15,2)`. **Rates:** stored as basis points (`INT`).

---

## 9. What's Next (in order)

1. **Send team lead the seed-config defaults question** (Q1 above) so we can finalize
   the launch values for `inviter_commission_rate_config`.
2. **Apply the DDL** in dev environment — the seven CREATE/ALTER statements from
   [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) §2–§3.
3. **Phase 1 implementation in `mall-userms`:**
   - `InviterCodeGenerator` + `InviterCodeService`
   - Registration flow extension (accept optional `invitation_code`)
   - `InviterBindingService` with the silent-ignore on UNIQUE violation
   - User suspension hook → revoke code
   - Admin endpoints for `user_flag`
   - Feign endpoints consumed by `mall-rebate` (lookup binding for invitee)
4. **Phase 2 implementation in `mall-rebate`:**
   - New package `com.yuanfeng.rebate.inviter.*`
   - Rate-config CRUD + history-with-reason
   - `InviterCommissionBatchService` with idempotent upsert
   - Admin endpoints (rate config, batch trigger, commission report, approve)
   - User-facing endpoints (my-summary, my-breakdown)
   - Feign clients to `mall-userms` and `mall-order`
5. **Phase 3 — `mall-payment`:** internal Feign endpoint `credit-commission` with
   idempotency key on `(batch_id, record_id)`.
6. **Phase 4 — `mall-job`:** xxl-job handler `InviterCommissionBatchJob`, scheduled
   monthly, callable on demand from xxl-job admin console.
7. **Frontend integration** — admin pages (rate config, history, commission report),
   user pages (my QR, my invitees, my commission).
8. **QA, UAT, launch.**

---

## 10. API Conventions

Follow each module's existing convention. No HPMS-wide path prefix. Examples:

- `mall-userms` — `POST /users/register`, `GET /invitations/my-code`,
  `PATCH /admin/users/{id}/flag`
- `mall-rebate` — `GET /inviter-commission/my-summary`,
  `PUT /admin/inviter-commission/rate-config`,
  `POST /admin/inviter-commission/run-batch`
- `mall-payment` — `POST /internal/payment/credit-commission` (Feign-only)

Response envelope: `{code, message, data, traceId}` per house. Pagination:
`{totalCount, pageSize, totalPage, currPage, list}`. DateTime in JSON: `yyyy-MM-dd HH:mm:ss`.

---

## 11. Anti-Patterns Already Flagged

From the existing codebase audit (still applicable):

- ❌ Hardcoded JWT secret in source — use env-injected
- ❌ Plaintext credentials in Nacos `bootstrap.yml` — use `${ENV_VAR}` substitution
- ❌ `Executors.newSingleThreadExecutor()` per call — use shared `@Bean ThreadPoolTaskExecutor`
- ❌ `allowedOriginPatterns("*")` in CORS — restrict per environment

These are existing-codebase issues; HPMS code added to those modules should not replicate them.

---

## 12. Working Agreements

- **Spec changes:** commission math, rate-config behaviour, lifetime-binding semantics
  require written PM + team-lead sign-off before implementation.
- **PRs:** under 400 lines reviewed in 4 hours; 400–800 in 1 day; over 800 split.
- **QA:** stable dev build by Tuesday EOD weekly. Bugs need traceId.

---

## 13. Risks Worth Tracking

1. **PM open questions blocking finalisation** — especially Q1 (rate defaults), Q5
   (mid-month suspension), Q6 (rounding). Code can proceed on assumptions but tests can't
   freeze without answers.
2. **Cross-module Feign chain depth** — batch goes mall-job → mall-rebate →
   mall-userms + mall-order. Failures of any leg need clean retries; the
   `inviter_commission_batch.status` is the recovery anchor.
3. **Tier-formula correctness across rate-change boundaries** — partially mitigated by
   `rate_config_snapshot` JSON, but admin UX needs to make the "next billing cycle"
   semantics clear.
4. **Idempotent payment credit** — the deterministic key `batch_id + ":" + record_id`
   needs to be honoured by `mall-payment`. Coordinate with whoever builds that endpoint.
5. **Single-engineer capacity** still applies as before.

---

## 14. What's Already Done

- [x] Original PRD, process diagrams, data dictionary read and reconciled (under v2.0 model)
- [x] Existing `mall-parent` codebase audited for relevant integration points
- [x] Original architecture doc (v0.4) sent to team lead and approved (under v2.0 model)
- [x] First-pass schema written for v2.0 model (now archived; not used)
- [x] **PRD v3.0 read and reconciled**
- [x] **Team-lead resync on 4 May 2026 — distributed-module architecture confirmed**
- [x] **Architecture v1.0 written**
- [x] **Schema design v1.0 written**
- [x] **Application invariants v1.0 written**
- [x] **Deviations log v1.0 written**
- [x] Standalone-service skeleton (`src/main/resources/db/migration/V1__init.sql`) removed
- [x] Resync brief disposed (decisions folded into the main docs)

---

## 15. Files in this Handoff

| File | Purpose |
|---|---|
| [00_README.md](./00_README.md) | Documentation index + maintenance guide |
| [01_ARCHITECTURE.md](./01_ARCHITECTURE.md) | Distributed-module architecture v1.0 |
| [02_PROJECT_CONTEXT.md](./02_PROJECT_CONTEXT.md) | This file |
| [archive/](./archive/) | Superseded PM-authored PDFs (PRD v2.0, Process Diagrams, Data Dictionary) |
| [06_SCHEMA_DESIGN.md](./06_SCHEMA_DESIGN.md) | Schema v1.0 (the seven new tables/columns across mall-userms and mall-rebate) |
| [07_APPLICATION_INVARIANTS.md](./07_APPLICATION_INVARIANTS.md) | Service-layer business rules + tests |
| [08_DEVIATIONS.md](./08_DEVIATIONS.md) | Numbered log of deliberate divergences from PM docs |
| [MSC_HPMS_PRD_v3.0.md](./MSC_HPMS_PRD_v3.0.md) | **The authoritative product spec** |

---

*End of handoff. Updated 6 May 2026.*
