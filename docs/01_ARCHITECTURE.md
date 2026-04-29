# MSC HPMS — Backend Architecture

**Technical Direction — v0.4 MVP**

| | |
|---|---|
| Project | MSC Hierarchical Promotion Management System (HPMS) |
| Document version | 0.4 — Informational |
| Author | Jubril (Backend Lead) |
| Date | 21 April 2026 |
| MVP launch | 20 May 2026 (demo 15 May) |
| Repo | `hpms-backend` |

> **About this document.** This is an informational record of the technical direction for HPMS backend. Configuration patterns follow the existing service conventions. Stack choices are documented here for visibility — deviations from house convention are called out explicitly with their reasons. No approval is being requested; feedback and corrections are welcome.

---

## 1. Overview

HPMS is a Spring Boot service that automates MSC's tiered offline promotion network — barcode-based pharmacy onboarding, three-level promoter hierarchy, multi-level commission calculation, and audit. Three clients: Admin web, Promoter mobile app, Pharmacy mobile app.

HPMS is built as a **modular monolith** that integrates with the existing MSC main application. Promoter payouts, order settlement, and certain identity concerns flow through the main app; HPMS owns the hierarchy, attribution, commission calculation, and audit logic. Module boundaries within HPMS are drawn so that scheduled tasks, admin functionality, and promoter functionality can be cleanly extracted as independent services in the future.

MVP feature-complete demo: 15 May 2026. Production launch: 20 May 2026.

---

## 2. Stack at a Glance

| Layer | Choice | Version | Notes |
|---|---|---|---|
| Language | Java | 21 LTS | Matches house |
| Framework | Spring Boot | 3.2.4 | Matches house |
| Web server | Undertow | bundled | Matches house (Tomcat excluded) |
| Data access | MyBatis-Plus | 3.5.5 | Matches house, XML mappers |
| Database | MySQL | 8.x | utf8mb4_unicode_ci, tz Africa/Lagos |
| Schema migrations | Flyway | 10.x | Deviation — house uses manual SQL |
| Cache | Redis + Jedis | 5.2.0 | Matches house |
| Config & discovery | Nacos | existing instance | Config + service registration |
| Auth | JWT (jjwt) + Spring Security | HS256 | Matches house, + refresh tokens |
| Password hashing | BCrypt | Spring bundled | Matches house |
| Async | `@EventListener` / `@Async` + RocketMQ for cross-service | bundled / existing | Broker only for main-app integration |
| Scheduled jobs | xxl-job | existing instance | Matches house — see `mall-job` |
| Logging | Logback + logstash-logback-encoder | 7.4 | Matches house |
| API docs | Knife4j | 4.4.0 | Matches house |
| Utilities | Hutool | 5.8.29 | Matches house |
| JSON | Jackson | Spring default | Deviation — house uses FastJSON |
| Object storage | MinIO (in-house) | existing instance | For CSV exports |
| Payment integration | via main app | — | HPMS does not handle payment directly |
| Primary keys | UUID (BINARY(16)) | — | Deviation — house uses BIGINT |
| Money | BigDecimal, DECIMAL(15,2) | — | Same as house intent |
| Container base | eclipse-temurin:21-jre-alpine | — | Matches house |

---

## 3. System Context

```
                           ┌──────────────────┐
                           │   Admin Portal   │
                           │      (Web)       │
                           └────────┬─────────┘
                                    │
     ┌──────────────────┐           │           ┌──────────────────┐
     │   Promoter App   │───────────┼───────────│   Pharmacy App   │
     │     (Mobile)     │           │           │     (Mobile)     │
     └────────┬─────────┘           │           └────────┬─────────┘
              │                     │                    │
              └─────────── HTTPS ───┼────────────────────┘
                                    ▼
                           ┌──────────────────┐
                           │  HPMS Backend    │
                           │  (Spring Boot)   │
                           └───┬──────┬───┬────┘
                               │      │   │
                               │      │   └─── Nacos / Logstash / xxl-job
                               │      │
                ┌──────────────┘      └──────────── MainApp (existing)
                ▼                                   ├── Order/settlement events
         ┌──────────────┐                           ├── Promoter wallet & payouts
         │  MySQL 8     │                           ├── Identity / user records
         │  Redis       │                           └── Paystack integration
         │  MinIO       │
         └──────────────┘
```

HPMS is a single Spring Boot service. Three clients consume the same versioned REST API. The existing MSC main application owns payment processing (Paystack), promoter wallet/payout, and order settlement. HPMS owns hierarchy, attribution, commission calculation, and audit. Cross-system communication uses RocketMQ for events and HTTP for synchronous calls.

---

## 4. Decisions

### 4.1 Architecture shape and module boundaries

- Single Spring Boot service. One deployable JAR, one process.
- **Modular monolith** structured for future service extraction. Three top-level boundaries are drawn now so they can become independent services later without surgical refactoring:
  1. **Admin module** — admin portal endpoints and admin-specific use cases
  2. **Promoter module** — promoter mobile app endpoints and promoter-specific use cases
  3. **Jobs module** — scheduled tasks (commission batch, audit housekeeping)
- A **Core module** holds shared domain logic and is consumed by the three boundary modules above.
- Cross-module communication goes through public domain services only. No mapper-level access across modules.

```
com.msc.hpms
├── admin/              ← future Admin service
│   ├── api/            ← admin REST controllers (/api/v1/admin/...)
│   ├── pharmacy/       ← admin operations: verify, reject
│   ├── promoter/       ← admin operations: suspend, reinstate
│   └── reporting/
│
├── promoter/           ← future Promoter service
│   ├── api/            ← promoter REST controllers (/api/v1/promoter/...)
│   ├── auth/
│   ├── barcode/
│   ├── pharmacy/       ← promoter view of their pharmacies
│   ├── earnings/
│   └── hierarchy/
│
├── jobs/               ← future Scheduled Tasks service
│   ├── commission/     ← monthly commission batch
│   ├── bonus/          ← bonus eligibility scanner
│   └── audit/          ← audit log housekeeping
│
├── integration/        ← integration with MSC main app
│   ├── mainapp/        ← outbound calls / event consumers
│   └── paystack/       ← reserved (delegated to main app)
│
└── core/               ← shared domain
    ├── pharmacy/
    ├── promoter/       ← PromoterDomainService (suspend, reinstate, etc.)
    ├── barcode/
    ├── order/          ← read-only mirror of main-app order data
    ├── commission/     ← commission calculation engine
    ├── bonus/
    ├── audit/
    └── common/         ← envelope, exceptions, utilities, AOP annotations
```

**Cross-module rule:** any class in `admin/`, `promoter/`, or `jobs/` may only depend on `core/` services. `admin/` MUST NOT import from `promoter/` or vice versa. `core/` modules expose public services and DTOs; entities and mappers stay internal.

**Database ownership** by core module (one MySQL, but each table has a logical owner):

| Table | Owned by |
|---|---|
| `promoters`, `promoter_hierarchy_audit` | `core/promoter` |
| `barcodes` | `core/barcode` |
| `pharmacies`, `verification_call_logs` | `core/pharmacy` |
| `orders`, `order_settlement_events` | `core/order` (read-mirrored from main app) |
| `commission_records`, `commission_batches` | `core/commission` |
| `onboarding_bonuses` | `core/bonus` |
| `audit_logs` | `core/audit` |

### 4.2 Language, framework, server

- Java 21 LTS (matches house).
- Spring Boot 3.2.4 (matches house).
- Undertow as embedded server; Tomcat excluded (matches house).
- Maven build, single-module for MVP; module split later if needed.
- Packaged as runnable JAR.

### 4.3 Data access and persistence

- MyBatis-Plus 3.5.5 (matches house).
- Entities follow house conventions: `@TableName(snake_case)`, `@Data` (Lombok), Serializable, field-level `@TableField` for camelCase↔snake_case mapping.
- `BaseMapper<Entity>` for CRUD; custom methods declared on mapper interface and implemented in `src/main/resources/mapper/*.xml`.
- Pagination returns `IPage<T>`, wrapped at controller layer in a `PageResult<T>` DTO.
- **Deviation — primary keys:** UUIDs stored as `BINARY(16)`, serialized as string in JSON. House uses auto-increment BIGINT. HPMS uses UUIDs to match the PRD/data dictionary and to avoid enumeration attacks on IDs exposed in QR codes, mobile deep links, and public API responses. `BINARY(16)` keeps index size and join performance reasonable.
- Money: `BigDecimal` in Java, `DECIMAL(15,2)` in MySQL, serialized as string in JSON to preserve precision.
- Timestamps: `LocalDateTime` in Java, `DATETIME` in MySQL, timezone Africa/Lagos.

### 4.4 Database

- MySQL 8.x on the existing in-house MySQL instance (matches house).
- Charset/collation `utf8mb4` / `utf8mb4_unicode_ci` (matches house).
- Timezone Africa/Lagos.
- **Deviation — migrations:** Flyway from day one. House uses manual SQL scripts; drift and rollback risk is unacceptable for a greenfield service with financial data. Migrations live in `src/main/resources/db/migration/` as `V{n}__{snake_case_name}.sql`. Spring's `ddl-auto` is set to `validate` in non-dev profiles.

### 4.5 Configuration, discovery, and secrets

- Nacos for **dynamic configuration AND service registration** (matches house pattern).
- Service registration enables unified service management/visibility and future interoperability with other MSC services.
- Single service registered under the name `hpms` in MVP.
- Extension configs follow the existing pattern: `base.yaml`, `mybatis.yaml`, `redis.yaml`. HPMS-specific extension: `hpms.yaml` for commission thresholds, performance tiers, feature flags.
- Four environment profiles mirroring the house pattern: local, dev, test, prod.
- **Deviation — secrets:** All credentials (database, Redis, JWT signing key, main-app integration tokens) injected via environment variables and referenced in Nacos configs as `${ENV_VAR}`. No plaintext passwords committed to repo or to Nacos.

### 4.6 Authentication and authorization

- JWT HS256 via JJWT library (matches house).
- JWT signing key: 256-bit random, env-injected, rotatable.
- **Deviation — refresh tokens:** Access token 15 minutes, refresh token 30 days (mobile) / 12 hours (admin web). House uses single 60-minute tokens. Refresh flow prevents mobile users from logging in every hour while keeping access tokens short-lived for revocation hygiene.
- BCrypt password hashing (matches house).
- Spring Security + method-level `@PreAuthorize`. Roles re-checked in service layer for defense in depth.
- Custom `JwtAuthenticationTokenFilter`, patterned after the house implementation, re-implemented locally.
- CORS configured per environment. Production restricts to known admin/mobile origins; no wildcard origins above local profile.
- Rate limiting: Bucket4j-backed filter in front of sensitive endpoints (`/auth/login`, `/barcodes/scan`).

> **Identity integration with main app:** the relationship between HPMS promoter records and main-app user records is a boundary decision to be finalized during integration design. Two viable patterns: (a) HPMS owns its own users table and exchanges promoter↔main-app-user mappings via integration events, or (b) HPMS uses main-app-issued JWTs and treats main-app user IDs as foreign keys. To be resolved in integration design phase.

### 4.7 API conventions

- REST over HTTPS. JSON request/response.
- **Versioned base path:** `/api/v1/...` — deviation from house (which has no versioning prefix). Cheap insurance; zero cost to add now, painful to retrofit.
- **Audience-segmented paths:** `/api/v1/admin/...` and `/api/v1/promoter/...` reflect the module boundaries from §4.1 and make future service extraction simpler.
- Response envelope follows house shape:

```json
{
  "code": 1,
  "message": "...",
  "data": { },
  "traceId": "..."
}
```

- Pagination envelope follows house shape: `totalCount, pageSize, totalPage, currPage, list`.
- Error codes: 5-digit integer scheme matching the house domain-grouping pattern. HPMS reserves the **20xxx** range to avoid collision with existing 11xxx–18xxx ranges.

```
20xxx = HPMS-generic    21xxx = promoter / hierarchy
22xxx = barcode         23xxx = pharmacy
24xxx = order           25xxx = commission / bonus
26xxx = audit           27xxx = verification
28xxx = main-app integration
```

- DateTime JSON format `"yyyy-MM-dd HH:mm:ss"` with Africa/Lagos timezone — standardized consistently in both `@JsonFormat` and Docker.
- OpenAPI docs: Knife4j 4.4.0 at `/doc.html`, v3 spec at `/v3/api-docs` (matches house).
- **Deviation — JSON library:** Jackson (Spring default) instead of house FastJSON. FastJSON v1 had serious CVEs; Jackson is the Spring default and deeply integrated.

### 4.8 Asynchronous work and main-app integration

- **In-process events** via Spring `@EventListener` for HPMS-internal domain events (e.g., pharmacy verified → bonus eligibility check).
- **Fire-and-forget work** via `@Async` backed by a shared `ThreadPoolTaskExecutor` bean (not per-call Executors).
- **Cross-service messaging via RocketMQ** (matches house) for integration with the main app:
  - HPMS consumes order settlement events published by the main app
  - HPMS publishes commission-finalized events for the main app to action (wallet credit / payout queue)
  - HPMS publishes promoter status change events (suspended, reinstated)
- Idempotency keys on all consumed events; consumers safe to retry.
- Topic and consumer group naming follows house conventions (mirror the `mall-*` patterns).

### 4.9 Scheduled jobs

- **xxl-job** for all scheduled tasks (matches house — see `mall-job` for the integration pattern). HPMS registers as an executor against the existing xxl-job admin console.
- Commission batch: triggered monthly (cron `0 0 2 1 * ?`) via xxl-job and manually re-runnable through the xxl-job admin console.
- Idempotent — re-runs upsert on composite key `(promoter_id, pharmacy_id, billing_month)`.
- xxl-job execution history provides built-in audit trail and re-run capability.

### 4.10 Logging and observability

- SLF4J + Logback (matches house).
- `logback-spring.xml` per-profile appender setup (matches house):
  - local profile → `ConsoleAppender`, plain-text pattern
  - dev/test/prod → `LogstashTcpSocketAppender`, JSON format, async delivery with queue 10240 and 80% discard threshold
- Custom JSON fields: `APP_NAME=hpms`, `APP_ENV={profile}`, `SERVER_IP`, `traceId`.
- Correlation ID filter sets `traceId` in MDC and in the API response envelope. TraceId is a UUID generated per request (SkyWalking integration deferred to post-MVP).
- Actuator endpoints: `/actuator/health` public, `/actuator/prometheus` internal-only for future metrics scraping.

### 4.11 Utilities and cross-cutting concerns

- Hutool 5.8.29 for general utilities (matches house).
- HPMS does NOT depend on `mall-commons`. Patterns (`ResponseResult` envelope, `PageResult` pagination, exception handler, custom annotations) are adapted and rewritten cleanly in the HPMS `core/common/` package.
- Reason: greenfield service benefits from a clean dependency graph, zero external version drift, and freedom to evolve independently.
- Custom AOP annotations adapted from the house pattern: `@SysLog` (method-level audit log emission), `@RateLimit` (Bucket4j-backed), `@RoleRequired` (complements `@PreAuthorize`).
- Global exception handler in `core/common/exception/` maps domain exceptions to the `ResponseResult` envelope with the appropriate 2xxxx error code.

### 4.12 Deployment

- Dockerfile based on `eclipse-temurin:21-jre-alpine` (matches house).
- Timezone Africa/Lagos set in the image (matches house).
- **Deviation — multi-stage Dockerfile:** build stage + runtime stage, smaller and cleaner runtime image.
- JVM tuning via `JAVA_OPTS` env var (matches house).
- Environments: local, dev, test, prod (matches house).
- Single repo, trunk-based with feature branches (deviation from house multi-repo submodule structure — monolith).
- Migrations run automatically by Flyway on app startup (deviation from manual SQL).

---

## 5. Data Model Summary

Nine entities, defined in the Data Dictionary v1.0 and implemented in `V1__init.sql`.

- **promoters** — single table, `level` field differentiates Field Lead / Field Agent / Frontline Rep.
- **barcodes** — one per promoter, with `parent_barcode_id` chain and `root_barcode_id` shortcut for attribution.
- **pharmacies** — duplicate detection on `business_registration_number` (hard) and `pharmacy_name + street_address + lga` (soft).
- **orders** — read-mirrored from main app via integration events. HPMS does NOT originate orders.
- **order_settlement_events** — append-only log of order status transitions consumed from main app.
- **commission_records** — one per promoter per pharmacy per billing month, composite unique key.
- **onboarding_bonuses** — one per pharmacy ever, unique constraint prevents double-payment.
- **audit_logs** — append-only, immutable, monthly partitioning from month 6 in production.
- **verification_call_logs** — multiple per pharmacy, tracks admin verification calls.

---

## 6. Non-Functional Concerns

**Performance.** Commission batch completes in under 10 minutes for 10,000 pharmacies (PRD §4.6). Core API p95 under 300 ms excluding the batch trigger. Benchmark against 1,000 pharmacies planned for end of Sprint 2.

**Availability.** 99.5% core API uptime per PRD. Single-instance deployment in MVP. JWT statelessness and idempotent consumers leave the door open for horizontal scaling post-MVP.

**Security.** TLS at gateway. BCrypt password hashing. RBAC at controller and service layers. PII fields (phone, email, bank account) encrypted at rest. Rate limiting on sensitive endpoints. No secrets in repo or in Nacos plaintext.

**Auditability.** Every commission event, status change, and admin action writes an `audit_log` entry with actor, timestamp, entity snapshot, and reason. Immutable by schema design and by database grant — the application DB user has INSERT-only on this table.

**Data protection.** Automated daily MySQL backups with 30-day retention. Point-in-time recovery via existing DB infrastructure. Restoration drill before go-live.

---

## 7. Deviations from House Convention — Summary

| Area | House pattern | HPMS pattern | Reason |
|---|---|---|---|
| Primary keys | Auto-increment BIGINT | UUID stored as BINARY(16) | PRD requirement; enumeration-attack resistance on public IDs |
| Schema migrations | Manual SQL scripts | Flyway, auto-run on startup | Drift and rollback risk unacceptable for financial data |
| JSON library | FastJSON 2.0.53 | Jackson | Spring default; FastJSON has CVE history |
| Timestamps | `java.util.Date` | `LocalDateTime` | Modern, immutable, timezone-safer |
| API versioning | No prefix | `/api/v1/` | Cheap insurance; painful to retrofit |
| JWT tokens | Single 60-min token | Access 15 min + refresh 30d/12h | Mobile UX without relaxing access token hygiene |
| JWT secret | Hardcoded in source | Env-injected 256-bit random | Security hardening |
| `mall-commons` | Shared library dependency | Patterns adapted locally | Greenfield — clean dependency graph, no version drift |
| Distributed tx | Seata | Local `@Transactional` + idempotent consumers | Single MySQL, no distributed transactions needed |
| Rate limiting | Sentinel | Bucket4j filter | Avoid SCA dependency overhead |
| Inter-service calls | Feign | RocketMQ events for main-app integration | Async, decoupled |
| Repo structure | Multi-repo submodules | Single repo, feature branches | Monolith |
| Dockerfile | Single-stage | Multi-stage | Smaller runtime image |
| CORS | `allowedOriginPatterns("*")` | Per-env restricted origins | Security hardening |
| Async executor | `newSingleThreadExecutor()` per call | Shared `ThreadPoolTaskExecutor` | Fixes thread leak |

---

## 8. Out of Scope for MVP

Confirmed by Sprint 1 kickoff and the Definition of Done.

- Offline barcode scanning and local sync.
- Payment disbursement — handled by main app integration.
- Multi-currency support.
- KPI leaderboards, advanced dashboards, audit log live search UI.
- Push notifications, WhatsApp/email QR sharing.
- A fourth hierarchy level.
- Horizontal scaling and multi-instance deployment.
- APM / distributed tracing (SkyWalking) — deferred to post-MVP.

---

## 9. Delivery Plan

**Sprint 1 (21 April – 1 May): APIs and foundations**
- Repo, CI pipeline, dev deployment running end-to-end by 23 April.
- Auth, RBAC, promoter hierarchy CRUD, barcode generation, pharmacy registration with duplicate detection.
- OpenAPI spec published and frozen by 24 April for frontend to mock against.
- Main-app integration contracts drafted and shared with the main-app team.

**Sprint 2 (4 May – 15 May): Commission engine and integration**
- Onboarding bonus trigger, monthly commission batch (xxl-job), admin verification and suspension flows.
- Promoter app endpoints — barcode display, pharmacy list, earnings breakdown.
- Main-app integration: order settlement event consumer, commission-finalized event publisher.
- Frontend integration, QA, UAT.
- Demo 15 May.

**UAT hardening (15 May – 20 May)**
- Bug fixes, performance benchmarking, backup/restore drill, security review.
- Production launch 20 May.

---

## 10. Top Risks

**Main-app integration scope and contract ownership.** The interface between HPMS and the main app (events, payloads, identity mapping) must be agreed early. Slippage here cascades to commission delivery and promoter payout. This is now the highest-priority risk.

**Commission correctness under edge cases.** Mid-month suspension, pharmacy reassignment, and cross-region scenarios remain under-specified in the PRD. Open questions need closure by 23 April or dependent work stalls.

**Contract drift between frontend and backend.** If the OpenAPI contract is not frozen by 24 April, Sprint 2 integration time suffers disproportionately.

**Single-engineer backend capacity.** Any blocker on the primary backend engineer stalls all dependent work. Optional second engineer confirmation this week would materially reduce Sprint 2 risk.

---

*Document end. v0.4 — 21 April 2026.*
