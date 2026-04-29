# MSC HPMS — Project Context & Handoff

**Purpose:** Complete context for continuing HPMS backend development in Claude Code. Hand this to your next assistant alongside the PRD, process diagrams, and data dictionary.

**Status:** Sprint 1 in progress. Architecture doc v0.4 sent to CTO. Repos to be created. DB schema in progress (you started this in Claude Code).

---

## 1. Project at a Glance

**What HPMS is.** A Spring Boot service that automates MSC's tiered offline promotion network for pharmacies in Nigeria. Greenfield, not migrating from legacy. Three clients: Admin web portal, Promoter mobile app, Pharmacy mobile app.

**Core domain.**
- **3-level promoter hierarchy:** Field Lead → Field Agent → Frontline Rep. Hard cap, no exceptions.
- **Barcode-based pharmacy onboarding:** promoters display QR, pharmacies scan, registration is attributed to the scanning promoter immutably.
- **Multi-level commission engine:** monthly commission with override splits up the hierarchy; one-time onboarding bonus per pharmacy.
- **Audit-everything posture:** every commission event, status change, admin action logged immutably.

**Key product decision.** HPMS records and calculates commissions. **Actual payouts happen in the existing MSC main app** — HPMS publishes commission-finalized events; main app credits wallets / processes payouts.

---

## 2. Timeline (immovable)

| Date | Milestone |
|---|---|
| 21 Apr 2026 (Mon) | Sprint 1 kickoff — DONE |
| 23 Apr 2026 (Wed) | Repo skeleton deployed to dev — TARGET |
| 24 Apr 2026 (Fri) | OpenAPI contract frozen — TARGET |
| 1 May 2026 (Fri) | Sprint 1 review — all APIs ready for UI build |
| 4 May 2026 (Mon) | Sprint 2 kickoff |
| 15 May 2026 (Fri) | MVP demo to GM, Fang Junjie, Abdulwahab — UAT sign-off |
| 20 May 2026 (Wed) | Production go-live |

**~25 working days from kickoff to demo. ~30 to launch.**

---

## 3. Team

- **Jubril** — Backend lead (you). Primary engineer. May get one optional second backend engineer.
- **CTO** (Baraka Aluja) — Tech lead. Reviews architecture and schema. Communicates in Chinese; messages to him in English are fine, sometimes Chinese is appropriate.
- **Bruce** — Senior stakeholder, currently on leave. CTO will sync with him on architecture decisions when he returns.
- **PMs** — Authored PRD/process diagrams/data dictionary. Own open product questions.
- **Frontend lead** — Owns Admin web + mobile app codebase(s). Will mock against OpenAPI starting 24 April.
- **QA lead** — Will start hitting dev by Tuesday EOD each week.

---

## 4. Stack — Final Decisions

```
Java 21 LTS + Spring Boot 3.2.4 + Undertow
MyBatis-Plus 3.5.5 + Flyway 10.x + MySQL 8.x (utf8mb4_unicode_ci, tz Africa/Lagos)
Redis + Jedis 5.2.0
Nacos (config + service registration)
JWT HS256 (jjwt) + Spring Security + BCrypt
RocketMQ (cross-service integration with main app)
xxl-job (scheduled tasks — see existing mall-job for pattern)
Logback + logstash-logback-encoder 7.4
Knife4j 4.4.0 (API docs at /doc.html)
Hutool 5.8.29
Jackson (NOT FastJSON)
MinIO (in-house, for CSV exports)
Bucket4j (rate limiting — NOT Sentinel)
Multi-stage Dockerfile, eclipse-temurin:21-jre-alpine
```

**Explicitly NOT used:**
- Seata (no distributed transactions; single MySQL)
- Feign (replaced by RocketMQ events for main-app integration)
- Spring Cloud Gateway (not needed)
- mall-commons dependency (patterns adapted, not depended on)
- Sentinel (Bucket4j instead)
- Spring Batch (xxl-job instead)
- SkyWalking (deferred to post-MVP)

---

## 5. Module Boundaries — CRITICAL

The CTO explicitly asked for the codebase to be partitioned so that **scheduled tasks, admin functionality, and promoter functionality** can be cleanly extracted as independent services in the future. This is a hard requirement, not a nice-to-have.

```
com.msc.hpms
├── admin/              ← future Admin service
│   ├── api/            ← /api/v1/admin/... controllers
│   ├── pharmacy/       ← admin operations: verify, reject
│   ├── promoter/       ← admin operations: suspend, reinstate
│   └── reporting/
│
├── promoter/           ← future Promoter service
│   ├── api/            ← /api/v1/promoter/... controllers
│   ├── auth/
│   ├── barcode/
│   ├── pharmacy/       ← promoter view of their pharmacies
│   ├── earnings/
│   └── hierarchy/
│
├── jobs/               ← future Scheduled Tasks service
│   ├── commission/     ← monthly commission batch (xxl-job handler)
│   ├── bonus/          ← bonus eligibility scanner
│   └── audit/          ← audit log housekeeping
│
├── integration/        ← integration with MSC main app
│   ├── mainapp/        ← outbound HTTP / RocketMQ event consumers + producers
│   └── webhook/
│
└── core/               ← shared domain (the "library" for the boundary modules)
    ├── pharmacy/
    ├── promoter/       ← PromoterDomainService (suspend, reinstate, etc.)
    ├── barcode/
    ├── order/          ← read-mirror of main-app order data
    ├── commission/     ← commission calculation engine
    ├── bonus/
    ├── audit/
    └── common/         ← envelope, exceptions, utilities, AOP annotations
```

**Cross-module rules (enforce in code review, write in CONTRIBUTING.md):**

1. `admin/`, `promoter/`, `jobs/` MUST NOT import from each other directly.
2. `admin/`, `promoter/`, `jobs/` MAY only depend on `core/` services.
3. `core/` modules expose **public services** and **DTOs**. Entities and mappers stay internal.
4. Database access is owned per-module. No mapper from one module accesses tables owned by another.
5. Cross-module communication uses Spring `@EventListener` for HPMS-internal events.
6. Integration with the main app uses RocketMQ events through `integration/mainapp/`.

**Database ownership (logical, in one MySQL instance):**

| Tables | Owner module |
|---|---|
| `promoters`, `promoter_hierarchy_audit` | `core/promoter` |
| `barcodes` | `core/barcode` |
| `pharmacies`, `verification_call_logs` | `core/pharmacy` |
| `orders`, `order_settlement_events` | `core/order` (read-only, mirrored from main app) |
| `commission_records`, `commission_batches` | `core/commission` |
| `onboarding_bonuses` | `core/bonus` |
| `audit_logs` | `core/audit` |

---

## 6. Main-App Integration — Open Design

This is the new requirement. **HPMS must integrate with the existing MSC main app**, because:

- Pharmacy orders likely originate in the main app, not HPMS.
- Pharmacy payments/settlement (Paystack) are handled by the main app.
- Promoter commission payouts go through wallets/payout flows owned by the main app.
- Identity may overlap between systems.

### Integration touchpoints (to be finalized with the main-app team)

**Inbound to HPMS (consumed):**
- `OrderSettledEvent` — order settled, contains pharmacy_id, order_value, settled_at, settlement_ref. Drives commission eligibility.
- `OrderRefundedEvent` — for future, claw-back logic post-MVP.
- (Optional) `PharmacyKycUpdatedEvent` — if KYC lives in main app.

**Outbound from HPMS (published):**
- `CommissionBatchApprovedEvent` — fired when admin approves a monthly batch. Contains line items: `(promoter_id, billing_month, net_commission)`. Main app consumes this to credit promoter wallets.
- `OnboardingBonusReadyEvent` — fired when bonus trigger conditions met. Main app credits the bonus.
- `PromoterStatusChangedEvent` — suspended/reinstated. Main app may use this to freeze wallet activity.

**Synchronous HTTP (to be decided per call):**
- `GET /mainapp/users/{id}` — resolve promoter↔user identity, if HPMS doesn't own users.
- Possibly: pharmacy enrichment data, payment method status.

### Identity question (to be resolved)

Two patterns possible:

**Pattern A: HPMS owns its own users table.** HPMS issues its own JWTs. Promoter records map to main-app users via an integration field (`mainapp_user_id`).

**Pattern B: HPMS uses main-app identity.** Main app issues JWTs; HPMS treats main-app user ID as the foreign key into its `promoters` table. HPMS doesn't have its own users table.

Pattern B is cleaner for integration but requires the main app to support HPMS scopes/audience in its JWTs. Pattern A is more autonomous but requires sync logic. **Decision pending — needs discussion with main-app team.**

### Commission lifecycle with integration

```
1. Pharmacy places order in main app
2. Main app processes payment via Paystack
3. Main app publishes OrderSettledEvent → RocketMQ
4. HPMS integration/mainapp consumer receives event
5. HPMS persists order_settlement_events row (read-mirror)
6. HPMS jobs/commission monthly batch (xxl-job) processes settled orders
7. HPMS creates commission_records (status=CALCULATED)
8. Admin reviews + approves → status=APPROVED
9. HPMS publishes CommissionBatchApprovedEvent → RocketMQ
10. Main app consumes, credits promoter wallet, processes payout
11. (Optional) Main app publishes CommissionPaidEvent
12. HPMS marks commission_records as status=PAID
```

---

## 7. Domain Rules — Hard Requirements

### Hierarchy
- 3 levels max. Hard cap. Field Lead → Field Agent → Frontline Rep.
- Field Leads created by Admin only.
- Field Agents recruited by Field Leads only.
- Frontline Reps recruited by Field Agents only.
- Frontline Reps CANNOT recruit. Enforce at API level (not just UI).

### Commissions

**Onboarding bonus** (₦2,000 one-time per pharmacy, paid only when verified + first order settled):

| Onboarded by | Direct recipient | Override recipient |
|---|---|---|
| Field Lead | Field Lead 100% (₦2,000) | — |
| Field Agent | Field Agent 90% (₦1,800) | Field Lead 10% (₦200) |
| Frontline Rep | Frontline Rep 90% (₦1,800) | Field Agent 10% (₦200) |

⚠️ **Field Lead receives 0% on Frontline Rep-onboarded pharmacies.** Confirm this with PMs before implementation.

**Monthly commission** (calculated on settled orders only, per pharmacy per month):
- 1% on first ₦1,000,000 of monthly pharmacy sales
- 2% on amount above ₦1,000,000

| Scenario | Field Lead | Field Agent | Frontline Rep |
|---|---|---|---|
| Field Lead direct sale | 100% | — | — |
| Field Agent-onboarded pharmacy | 10% override | 90% | — |
| Frontline Rep-onboarded pharmacy | 0% | 10% override | 90% |

### Pharmacy onboarding
- Barcode must be scanned before registration accepted. No manual override.
- Online only — offline scan is OUT OF MVP scope (confirmed at kickoff).
- Duplicate detection (canonical, per data dictionary):
  - **Hard:** `business_registration_number` (CAC number) — block immediately
  - **Soft:** `pharmacy_name + street_address + lga` exact match — block, flag for admin
- Ownership timestamp set server-side at scan time. Immutable.

### Suspension
- Admin can suspend any promoter; suspension freezes commission accrual immediately.
- Suspended promoter's barcode → REVOKED, cannot be scanned.
- Pharmacies under suspended promoter remain active but flagged for admin reassignment review.

---

## 8. Open Product Questions — Need Closure by 23 April

These four questions are blocking design completeness. Send to PMs as a spec delta memo:

1. **Field Lead 0% on Frontline Rep-onboarded pharmacies** — confirmed? Or should Field Lead get a small override (e.g., 5%, with Rep dropping to 85%)?
2. **Suspension mid-month** — what happens to in-flight commissions for the suspended promoter? Do downstream promoters' commissions still flow if their upstream is suspended? Do upstream overrides still flow if downstream is suspended?
3. **Pharmacy verification workflow** — does MVP require call-log workflow (per Process Diagram 8), or is a simple admin "verify" toggle sufficient? Recommendation: simple toggle for MVP, full workflow post-MVP.
4. **Cross-region** — is cross-region Field Lead approval in MVP, or deferred?

---

## 9. Spec Inconsistencies (already identified, fix in code/comments)

- **PRD vs Process Diagram vs Data Dictionary** disagree on duplicate detection criteria. **Use the Data Dictionary version**: hard on `business_registration_number`, soft on `pharmacy_name + street_address + lga`.
- **API paths in PRD §6** still say `/users/champions`, `/users/agents`, `/users/ambassadors` — these are old terminology. Use `/api/v1/admin/field-leads`, `/api/v1/field-leads/agents`, etc.
- **Data dictionary barcode format** says `MSC-CH-...` but prototype shows `MSC-FL-...`. Use `MSC-FL-...` (FL = Field Lead, AG = Agent, FR = Frontline Rep) — match the renamed terminology.
- **PRD §4.6 says barcode scanning works offline** — this was deprecated at kickoff. Online only.
- **QA scenario #10 (offline scan)** — withdrawn.

---

## 10. Definition of Done (per feature)

A feature is "done" only when ALL of:

- [ ] Endpoint implemented and deployed to dev
- [ ] OpenAPI spec updated and merged
- [ ] Unit tests passing
- [ ] Integration tests passing against real MySQL via Testcontainers
- [ ] Error responses conform to the agreed error envelope with documented 2xxxx codes
- [ ] Audit log entries written wherever the data dictionary requires them
- [ ] RBAC enforced at controller level AND re-checked in service layer
- [ ] QA has hit the endpoint on dev and signed off
- [ ] Code reviewed and merged to develop

"Demoable" is NOT "done."

---

## 11. API Conventions

- Base path: `/api/v1/`
- Audience prefix: `/api/v1/admin/...` and `/api/v1/promoter/...`
- Response envelope:

```json
{
  "code": 1,
  "message": "Operation successful",
  "data": { },
  "traceId": "uuid-here"
}
```

`code: 1` = success, `code: 0` = failure. (House convention. Don't use HTTP status alone.)

- Pagination envelope: `{ totalCount, pageSize, totalPage, currPage, list }`
- DateTime: `"yyyy-MM-dd HH:mm:ss"`, timezone Africa/Lagos
- Error code ranges (5-digit ints):

```
20xxx = HPMS-generic       21xxx = promoter / hierarchy
22xxx = barcode            23xxx = pharmacy
24xxx = order              25xxx = commission / bonus
26xxx = audit              27xxx = verification
28xxx = main-app integration
```

---

## 12. Anti-Patterns to Avoid (from existing codebase audit)

The existing MSC codebase has known issues. Do NOT replicate:

- ❌ Hardcoded JWT secret `"sangeng"` in source — use env-injected 256-bit random
- ❌ Plaintext credentials in Nacos `bootstrap.yml` — use `${ENV_VAR}` substitution
- ❌ `Executors.newSingleThreadExecutor()` per call — use a shared `@Bean ThreadPoolTaskExecutor`
- ❌ Duplicate error code 10002 — keep error codes unique
- ❌ Package typo `annnotation` (3 n's) — spell `annotation` correctly
- ❌ Class typo `BizCodeEnume` — spell `BizCodeEnum` correctly
- ❌ `allowedOriginPatterns("*")` in CORS — restrict per environment
- ❌ Single 60-min JWT with no refresh — use access + refresh
- ❌ Manual SQL migrations — use Flyway
- ❌ FastJSON — use Jackson

---

## 13. Existing Codebase Patterns to Borrow (don't depend on, just learn from)

The existing MSC services have good patterns worth learning:

- **`ResponseResult<T>` envelope** with `code`/`message`/`data` shape — adopt the shape, write your own implementation
- **`PageUtils` pagination wrapper** — adopt the shape (`totalCount, pageSize, totalPage, currPage, list`), write your own
- **`GlobalExceptionHandler`** mapping domain exceptions to envelope responses — adopt the pattern, write your own
- **AOP annotations**: `@SysLog`, `@RoleRequired`, `@RepeatClick` — adopt the pattern, write your own (without the bugs)
- **Logback profile-based appenders**: console for local, Logstash TCP for dev/test/prod — copy the structure
- **Nacos bootstrap.yml** with extension configs (`base.yaml`, `mybatis.yaml`, `redis.yaml`) — copy the structure
- **xxl-job pattern** from `mall-job` — reference for HPMS scheduled tasks
- **JwtAuthenticationTokenFilter** — copy the structure, write your own with the secret externalized
- **Dockerfile pattern** with Africa/Lagos timezone and JAVA_OPTS — copy and make multi-stage

---

## 14. Working Agreements (signed at kickoff)

- **API contract:** OpenAPI published by 24 April; breaking changes need 24h written notice.
- **Environments:** dev = `develop` branch always deployed; staging = `release/*`; prod = tagged releases. No direct DB modifications.
- **PRs:** under 400 lines reviewed in 4 hours; 400-800 in 1 day; over 800 split. CI must be green.
- **QA:** stable dev build by Tuesday EOD weekly. Bugs need traceId.
- **Spec changes:** commission math, hierarchy rules, bonus logic require written PM+CTO sign-off before implementation.

---

## 15. Risks Worth Tracking

1. **Main-app integration scope and contract** — highest risk. Slippage cascades to commission delivery.
2. **Commission correctness under edge cases** — needs the four open PMquestions answered.
3. **Frontend-backend contract drift** — mitigated by 24 April freeze.
4. **Single-engineer backend capacity** — push for second engineer confirmation this week.
5. **PM open questions not closed by Wednesday** — escalate if needed.

---

## 16. What's Already Done

- [x] PRD, process diagrams, data dictionary read and reconciled
- [x] Existing MSC codebase audited (see existing service for conventions)
- [x] Architecture doc v0.4 sent to CTO
- [x] CTO feedback received and incorporated:
  - Nacos for service registration (in addition to config)
  - xxl-job for scheduled tasks (not @Scheduled)
  - Module boundaries (admin/promoter/jobs) for future service extraction
  - Schema review when ready
- [x] Sprint 1 kickoff DoD agreed
- [x] Offline scan dropped from MVP

---

## 17. What's Next (in order)

1. **DB schema** — finish `V1__init.sql`. Send to CTO for review when ready.
2. **Spec delta memo to PMs** — close the 4 open questions by Wednesday.
3. **Repo skeleton** — Spring Boot app with module structure, Flyway migration, Nacos config, JWT filter, response envelope, exception handler, Knife4j, Docker, deployed to dev by Wednesday.
4. **Main-app integration design** — meet with main-app team to agree on event contracts and identity pattern. Document in `INTEGRATION.md`.
5. **OpenAPI contract** — frozen by Friday so frontend can mock.
6. **Task breakdown** — derive tickets from OpenAPI endpoints + integration work.
7. **Sprint 1 build:** auth, RBAC, hierarchy, barcode, pharmacy registration with duplicate detection.
8. **Sprint 2 build:** commission engine, bonus trigger, admin verify/suspend, promoter app endpoints, main-app integration, frontend integration, QA.
9. **UAT week:** bug fixes, performance benchmark, backup/restore drill.
10. **Production launch 20 May.**

---

## 18. Files in this Handoff

- `01_ARCHITECTURE.md` — architecture doc v0.4 (the file that goes to CTO)
- `02_PROJECT_CONTEXT.md` — this file (the one for your next assistant)
- `03_PRD_v2.0.pdf` — Product Requirements Document
- `04_ProcessDiagrams_v1.0.pdf` — Business process flowcharts
- `05_DataDictionary_v1.0.pdf` — Field-level entity definitions

---

*End of handoff. Good luck.*
