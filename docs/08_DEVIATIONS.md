# HPMS — Engineering Deviations

> Numbered log of every place the implementation deliberately diverges from the PRD,
> the PM-authored Data Dictionary, or what a casual reader might assume.
> Companion docs: [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) · [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md).

Per [CLAUDE.md](../CLAUDE.md), the PM-authored documents (PRD, Process Diagrams, Data
Dictionary) are **informational, not authoritative**. Where engineering judgement
overrides what they say, the deviation is captured here with rationale.

Update this file whenever a schema or service decision diverges from the docs. Each
entry: **what the doc says → what we implemented → why**.

---

## Architectural principle

The database enforces **structural invariants only**: referential integrity, uniqueness,
NOT NULL, basic type sanity. Business rules — rate tiers, lifetime-binding semantics,
status workflows, format validation — live in service code and are tested there. See
[07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md) for the full catalogue.

Rationale: business rules change. Encoding them in DDL turns every PM tweak into a
schema migration. Triggers and complex CHECK constraints also fight bulk loads,
replication, and ORMs. Service-layer enforcement keeps rules testable, versionable, and
changeable.

---

## D-001 · HPMS does not ship as its own service

**Doc status:** Original architecture (v0.4) and earlier internal docs framed HPMS as a
standalone Spring Boot service.
**Implemented:** HPMS is implemented as additions to three existing modules of
`mall-parent` — `mall-userms`, `mall-rebate`, `mall-payment`. No new microservice, no new
deployment unit, no new Nacos namespace.
**Why:** Team-lead direction (resync, 4 May 2026). The new product model is tightly
coupled with existing user / order / wallet entities; a standalone service would have
been a thin shell of remote calls. mall-rebate becomes the unified commission concept.
17 microservices already run in production; not adding an 18th unless transaction volume
demands it.
**Ref:** [01_ARCHITECTURE §2](./01_ARCHITECTURE.md#2-module-distribution).

---

## D-002 · Code-level partition inside `mall-rebate`, no shared classes with rebate

**Doc status:** PM docs treat HPMS commission as a single feature; don't address how it
sits beside the existing rebate logic.
**Implemented:** All HPMS code in `mall-rebate` lives under `com.yuanfeng.rebate.inviter.*`
with its own controllers, services, mappers, and entities. **Zero shared classes with the
existing rebate module.** Tables use the `inviter_commission_*` prefix; no joins or FKs
to existing `rebate_*` tables.
**Why:** Team-lead instruction — the two concepts are conceptually distinct (rebate =
customer cashback, commission = inviter reward) and should evolve independently. Strict
package partition keeps the option open to extract HPMS to its own service later.

---

## D-003 · No `audit_logs` table — Kibana is the audit trail

**Doc status:** PRD §5.7 lists an audit trail as a Risk & Compliance Control. The
previous schema design had a dedicated `audit_logs` table with append-only DB triggers.
**Implemented:** Audit trail lives in Kibana via structured Logback log lines. No
HPMS-owned `audit_logs` table.
**Why:** Team-lead direction (4 May 2026 resync). House pattern is centralised logging
through Logstash + Kibana; adding a parallel DB audit table duplicates the truth.
**One exception:** `inviter_commission_rate_config_history` is a DB table because PRD
§5.5 explicitly requires the admin rate-config page to display historical changes.
Serving that view from Kibana queries would be both heavier and less reliable than reading
from a small append-only table — see [D-004](#d-004--inviter_commission_rate_config_history-is-a-db-table-not-only-a-kibana-stream).

---

## D-004 · `inviter_commission_rate_config_history` is a DB table, not only a Kibana stream

**Doc status:** Per D-003, audit goes to Kibana.
**Implemented:** Rate changes are logged BOTH to Kibana (per platform pattern) AND to
`inviter_commission_rate_config_history` in MySQL.
**Why:** PRD §5.5 mandates that the admin rate-config page show historical changes
("Current active commission rates are always visible on the configuration page" + "All
rate changes logged in the audit trail"). The admin UI needs a fast, paginated, filtered
read — that's a relational query, not a log-search query. The DB table is the read model;
Kibana is the immutable audit ledger.

---

## D-005 · `inviter_commission_rate_config` is a single-row table

**Doc status:** Not specified.
**Implemented:** The active rate config is exactly one row. Updates are `UPDATE`
statements with the previous values copied to history first, all in one transaction.
The application asserts `count = 1` at boot.
**Why:** The current rate is read on every batch run and on every admin page render —
making it a single row keeps that O(1) without an extra `WHERE active = 1` predicate.
Historical effective-from logic isn't needed because PRD §5.5 explicitly says rate changes
take effect "from the next billing cycle"; we capture the rate-at-batch-time in
`inviter_commission_batch.rate_config_snapshot` for forensics.

---

## D-006 · Commission rates stored as basis points, not decimals

**Doc status:** PRD §5.4 describes rates as percentages ("1% on first ₦1,000,000",
"2% above").
**Implemented:** Rate columns (`tier1_rate_bp`, `tier2_rate_bp`) are `INT` storing basis
points. `100 BP = 1%`. Computation: `commission = sales × rate_bp / 10000`.
**Why:** Eliminates floating-point drift in money math. `DECIMAL × DECIMAL` works but
`INT × DECIMAL / 10000` is even cleaner and easier to reason about in SQL and Java.
Admin UI accepts percentage input and converts at the boundary.

---

## D-007 · Single `commission_amount` column — no gross/net/split separation

**Doc status:** Previous design (v0.4) had `gross_commission`, `split_percentage`,
`net_commission`, and `commission_type` (DIRECT/OVERRIDE) on each row.
**Implemented:** One column: `commission_amount`. No split, no override, no type field.
**Why:** New PRD model is single-level direct attribution. There's no override and no
split — every commission row is the full amount owed to the direct Inviter. The previous
columns existed for the 3-tier hierarchy that no longer exists.

---

## D-008 · Lifetime binding via UNIQUE-then-silent-ignore

**Doc status:** PRD §5.1: "If a user has previously been bound, any subsequent invitation
code entered is silently ignored. Original binding preserved. No error shown to the user."
**Implemented:** `ucenter_inviter_binding` has `UNIQUE(invitee_user_id)`. The
registration service catches the unique-violation exception and converts it to a no-op,
without surfacing an error.
**Why:** This is the simplest race-safe encoding of a lifetime rule. Doing it in
application code via a pre-check would be subject to a race between the SELECT and the
INSERT. The unique constraint makes it correct under any concurrency.

---

## D-009 · Bindings have no FK to `ucenter_user_base`

**Doc status:** Not specified.
**Implemented:** `ucenter_inviter_binding.invitee_user_id` and `inviter_user_id` are
`BIGINT` references to `ucenter_user_base.user_id` but with no `FOREIGN KEY` constraint.
**Why:** Cross-table FKs aren't the convention in `mall-userms` — the existing tables
rely on service-level lookups. Following local pattern. Referential integrity is enforced
by the registration flow (a binding is only created when the validating SELECT on the
inviter's code succeeds, and the invitee is the user being created in the same
transaction).

---

## D-010 · Codes are stored separately from the user record, not as a column

**Doc status:** PRD describes invitation codes as a per-user attribute.
**Implemented:** `ucenter_inviter_code` is a separate table 1:1 with users.
**Why:** Allows status (`ACTIVE`/`REVOKED`) and future rotation without polluting the
user table. Matches the existing pattern in `mall-userms` of separating ucenter side-data
into dedicated tables.

---

## D-011 · `ucenter_inviter_code.qr_payload` is stored, not derived

**Doc status:** PRD §5.3 says the QR code encodes "the invitation code".
**Implemented:** A separate `qr_payload` column stores the actual payload (code +
checksum). The QR generator reads this column, not the bare code.
**Why:** Tamper resistance. If the QR contained only the code, anyone who saw a code
could fabricate a QR pointing to the same registration page. Storing a checksummed payload
lets the validation endpoint reject pasted/typed codes that didn't come through a real
QR scan if the use case ever requires it. (For MVP both paths are accepted; the column
exists so we can tighten later without a schema change.)

---

## D-012 · Pharmacy data lives in `mall-userms`, not HPMS

**Doc status:** Earlier internal docs (the v2.0 schema design) had a dedicated
`pharmacies` table.
**Implemented:** Pharmacies are users in `mall-userms` (`UcenterUserBusinessInfoEntity` for
the business profile, `UcenterKycApplicationEntity` for KYC). HPMS references `user_id`
directly.
**Why:** New PRD makes every Inviter a registered pharmacy user. There's no notion of a
pharmacy that isn't a user, and the existing entities already cover business profile + KYC.
Duplicating would create a sync problem. KYC is not required for someone to be an Inviter
(per PRD §3) — only to place orders. The HPMS commission logic looks at users-with-bindings
regardless of KYC status.

---

## D-013 · Order data is read-only via Feign — no read-mirror in HPMS

**Doc status:** Previous schema design had `orders` and `order_settlement_events` tables
mirroring main-app data.
**Implemented:** No HPMS tables for orders. The monthly commission batch in `mall-rebate`
calls `mall-order` via Feign to enumerate settled orders for the billing period.
**Why:** The data is already in `mall-order`. Maintaining a read-mirror means dual writes,
sync risk, and storage cost. Feign calls within the same process cluster are cheap and
match the existing rebate-module pattern.

---

## D-014 · `BIGINT` primary keys, not UUIDs

**Doc status:** v0.4 deviation list specified `BINARY(16)` UUIDs.
**Implemented:** All HPMS tables use `BIGINT NOT NULL AUTO_INCREMENT` primary keys
matching the surrounding modules' convention.
**Why:** The UUID deviation was justified for a standalone service that exposed IDs in
QR codes and public APIs. With HPMS now distributed inside `mall-userms` and `mall-rebate`,
the pattern is to match the surrounding tables. The exposed identity in QR codes is the
invitation `code` (a separate, human-readable column) — not the row's PK.

---

## D-015 · No real-time per-order commission trigger from `mall-order`

**Doc status:** PRD §5.4 says "Commission trigger: an Invitee's order reaches SETTLED
status."
**Implemented:** No Feign call from `mall-order` to `mall-rebate` on settlement. Commission
is computed in the monthly batch, which queries settled orders in arrears.
**Why:** The tier formula needs the *full per-Invitee monthly total* to apply 1% vs 2%
correctly. Doing it incrementally would force the per-order handler to recompute the
month's running total and emit a delta — much harder than a once-per-month batch with
the same idempotency guarantees. Latency is acceptable: PRD doesn't require intra-month
visibility, and Inviter dashboards refresh from the same `inviter_commission_record`
table as the report.

---

## D-016 · `user_flag` is `VARCHAR(32)`, not a boolean

**Doc status:** Internal discussion proposed `is_field_promoter BOOLEAN`.
**Implemented:** A nullable `VARCHAR(32)` with `'FIELD_PROMOTER'` as the only current
value.
**Why:** Leaves room for additional tags (e.g. `BETA_TESTER`, `MERCHANT_PARTNER`) without
a schema migration each time. NULL = no tag, which is the common case.

---

## D-017 · Storage timezone is UTC, not Africa/Lagos

**Doc status:** Existing `mall-parent` modules use `time_zone = '+08:00'` or `+01:00` at
the connection level depending on environment.
**Implemented:** HPMS-relevant DDL is timezone-agnostic, but the design assumes the
connection is set to UTC for storage and Africa/Lagos at the Spring/Jackson boundary for
display.
**Why:** `DATETIME` carries no timezone metadata; UTC at storage removes ambiguity.
Render-as-Lagos at the JSON boundary preserves the user-facing convention. This is
already how the existing modules operate de facto — formalising it here.

---

## D-018 · No DB-level triggers anywhere in HPMS

**Doc status:** Previous v0.4 schema design used triggers extensively (audit log
immutability, hierarchy enforcement, immutability checks).
**Implemented:** Zero triggers. All cross-row and immutability rules are in service code.
**Why:** Triggers produce cryptic errors, fight bulk loads / replication / ORMs, and
scatter domain rules across two layers. The previous justification (compliance-grade
audit log immutability) no longer applies because audit goes to Kibana now (D-003).
Single source of truth = service layer.

---

## D-019 · Format validation is service-side, not DDL CHECK

**Doc status:** PRD specifies formats for `phone_number`, `business_reg_number`,
`billing_month`, etc.
**Implemented:** No `CHECK` constraints, no `REGEXP` constraints. Format rules live in
validators in the application.
**Why:** Format rules change. Encoding them in DDL turns every PM tweak into a schema
migration. Validators are testable, versionable, and reusable across read and write
paths.

---

## D-020 · Manual SQL migrations, not Flyway

**Doc status:** v0.4 architecture proposed Flyway. House pattern is manual SQL applied
out-of-band and tracked in the team runbook.
**Implemented:** Manual SQL. Same as the surrounding modules.
**Why:** HPMS is now inside existing modules; following Flyway only for HPMS tables
would be inconsistent. Reverting the v0.4 deviation.

---

## Open questions

These are surfaced in [the new PRD §10](./MSC_HPMS_PRD_v3.0.md) and in the schema design
§8. Re-listed here for visibility:

1. Confirm launch defaults: `tier1_threshold = ₦1,000,000`, `tier1_rate = 1%`,
   `tier2_rate = 2%`. Pending Finance.
2. Mid-month suspension semantics — exact rule for orders that settle on the suspension
   day, and whether already-bound invitees' future commissions stop.
3. Reserved admin user_id for system-initiated config changes (or NULL on the seed row).
4. Decoupling code revocation from user suspension — separate use case?
5. Rounding mode for commission: banker's vs half-up. Pending Finance.
6. Soft-tag governance — who can grant `FIELD_PROMOTER`?

---

## What was discarded from earlier versions

For traceability — these deviations existed in the prior version of this file (drafted
for the v2.0 PRD's 3-tier hierarchy) and are no longer applicable:

- D-001..D-002 (admins table; nullable barcode_id) — entire model gone (D-001, D-012).
- D-003 (soft duplicate detection KEY) — pharmacies table gone (D-012).
- D-004..D-005 (generated/check columns for splits) — splits gone (D-007).
- D-006..D-008 (audit_logs append-only triggers) — replaced by Kibana (D-003).
- D-009..D-011 (hierarchy / pharmacy / bonus immutability triggers) — entire model gone.
- D-013..D-014 (commission_batches added; BINARY(16) UUIDs) — first survives in spirit
  (we have `inviter_commission_batch`); second reverted (D-014 in this file is the
  *opposite* of the old D-014).
- D-015..D-019 (assorted indexes / nafdac unique / format CHECK / DATETIME(3) /
  DECIMAL(15,2)) — folded into D-014 / D-019 / matched-house-conventions.

The renumbering is intentional: D-NNN identifiers in this file are NOT the same as
D-NNN identifiers in any pre-v3 version of this document. If you find an old reference
to D-007 in another doc, check its date — pre-4 May 2026, it meant something else.

---

## Template for future entries

```text
## D-NNN · Short title

**Doc status:** What the PRD/PM docs say (or don't say).
**Implemented:** What the code/schema actually does.
**Why:** The engineering rationale.
**Ref:** File / line / table / service.
```

---

*End of document — Deviations v1.0 — 4 May 2026.*
