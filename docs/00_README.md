# MSC HPMS — Documentation Index

> Hierarchical Promotion Management System · Backend documentation hub

This folder is the single source of truth for HPMS backend design. Read in numbered
order if you're new; jump directly to a specific doc otherwise.

**As of 6 May 2026, HPMS is implemented as additions inside three existing `mall-parent`
modules — `mall-userms`, `mall-rebate`, `mall-payment` — not as a standalone service.**
The earlier standalone-service design has been fully replaced. See [01_ARCHITECTURE](./01_ARCHITECTURE.md)
for the current shape.

---

## Reading order

| # | Document | What it is | Audience |
|---|---|---|---|
| 00 | [README](./00_README.md) | This file — index + maintenance guide | All |
| 01 | [Architecture](./01_ARCHITECTURE.md) | Distributed-module architecture v1.0 | Team lead · backend |
| 02 | [Project Context](./02_PROJECT_CONTEXT.md) | Timeline, team, decisions made, what's next | Anyone joining the project |
| — | [PRD v3.0](./MSC_HPMS_PRD_v3.0.md) | **THE AUTHORITATIVE PRODUCT SPEC** | All |
| 06 | [Schema Design](./06_SCHEMA_DESIGN.md) | DDL for the seven new tables/columns across mall-userms and mall-rebate | Team lead · DBA · backend |
| 07 | [Application Invariants](./07_APPLICATION_INVARIANTS.md) | Service-layer business rules with owner + tests | Backend · QA |
| 08 | [Deviations](./08_DEVIATIONS.md) | Numbered log of deliberate divergences from PM docs | Team lead · reviewers |

The previous PM-authored PDFs (PRD v2.0, Process Diagrams v1.0, Data Dictionary v1.0)
have been moved to [archive/](./archive/) — they describe the v2.0 model (3-tier
promoter hierarchy, barcodes-as-tree, onboarding bonus) which was abandoned on 30 April
2026 when [PRD v3.0](./MSC_HPMS_PRD_v3.0.md) was issued. Kept for forensic context only;
do not implement anything from them.

---

## Quick navigation by question

**"What does HPMS look like as a system?"**
[01_ARCHITECTURE](./01_ARCHITECTURE.md) — module distribution, cross-module data flows,
stack inheritance.

**"Where does each table live and why?"**
[06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) — full DDL with annotations, plus the migration
order.

**"Where does this rule live — DB or application?"**
Schema design [§5](./06_SCHEMA_DESIGN.md#5-integrity-controls) gives the rule-by-rule
split. Application-layer rules drill into [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md).

**"Why did we deviate from the PRD on X?"**
[08_DEVIATIONS](./08_DEVIATIONS.md) — search for the topic.

**"What's blocking implementation?"**
[02_PROJECT_CONTEXT §7](./02_PROJECT_CONTEXT.md#7-open-product-questions-still-outstanding)
lists open product questions; [06_SCHEMA_DESIGN §8](./06_SCHEMA_DESIGN.md#8-open-questions-for-finance--pm--ops)
lists schema-blocking ones.

**"What's the commission formula?"**
[07_APPLICATION_INVARIANTS I-041](./07_APPLICATION_INVARIANTS.md#i-041--tier-formula)
plus the rate config table in
[06_SCHEMA_DESIGN §3.1](./06_SCHEMA_DESIGN.md#31-inviter_commission_rate_config--current-active-rates-single-row).

**"Why no audit_logs table?"**
[08_DEVIATIONS D-003](./08_DEVIATIONS.md#d-003--no-audit_logs-table--kibana-is-the-audit-trail).

**"How does HPMS get order data?"**
Feign call from `mall-rebate` to `mall-order` during the monthly batch — see
[01_ARCHITECTURE §4.3](./01_ARCHITECTURE.md#43-monthly-commission-batch).
[08_DEVIATIONS D-013](./08_DEVIATIONS.md#d-013--order-data-is-read-only-via-feign--no-read-mirror-in-hpms).

**"How does commission get paid?"**
[01_ARCHITECTURE §4.4](./01_ARCHITECTURE.md#44-admin-approves-a-commission-batch--wallet-credit) —
admin approves → mall-rebate Feign-calls mall-payment to credit the balance with income
type `Sales Commission`.

**"What's the lifetime-binding rule?"**
[07_APPLICATION_INVARIANTS I-011](./07_APPLICATION_INVARIANTS.md#i-011--lifetime-binding-unique-violation--silent-ignore)
plus [08_DEVIATIONS D-008](./08_DEVIATIONS.md#d-008--lifetime-binding-via-unique-then-silent-ignore).

---

## Code locations

| Asset | Path |
|---|---|
| HPMS code in mall-userms | `mall-userms/src/main/java/com/yuanfeng/userms/inviter/` (planned package) |
| HPMS code in mall-rebate | `mall-rebate/src/main/java/com/yuanfeng/rebate/inviter/` (planned package) |
| HPMS code in mall-payment | folded into existing payment package; new income type code only |
| HPMS xxl-job handler | `mall-job/src/main/java/com/yuanfeng/job/job/InviterCommissionBatchJob.java` (planned) |
| Schema DDL | applied manually per module — see [06_SCHEMA_DESIGN §7](./06_SCHEMA_DESIGN.md#7-migration-order-manual-sql) |
| Project-wide design rules for AI assistants | `CLAUDE.md` (repo root) |
| All design documentation | this folder (`docs/`) |

---

## Document conventions

- **Numbered prefixes** (`NN_*.md`) define the canonical reading order. New design
  documents should be added to the next available number.
- **Cross-references** use relative markdown links so they survive folder moves and
  render correctly in GitHub/GitLab/Kibana viewers.
- **Numbered identifiers** are stable references:
  - `D-NNN` — entries in 08_DEVIATIONS
  - `I-NNN` — entries in 07_APPLICATION_INVARIANTS
  - `Q-N` — open questions (currently in 02 and 06; consolidate when answered)
- **Source-of-truth ranking** when docs disagree:
  1. The implemented code in the relevant module
  2. [08_DEVIATIONS](./08_DEVIATIONS.md) (records why code differs from spec)
  3. [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) and [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md)
  4. [01_ARCHITECTURE](./01_ARCHITECTURE.md)
  5. [PRD v3.0](./MSC_HPMS_PRD_v3.0.md)
  6. PM-authored PDFs (03–05) — informational only, superseded by PRD v3.0

---

## Maintenance protocol

When you change something:

1. **Schema change** — apply the DDL manually in dev, then update
   [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) so the narrative matches.
2. **Business rule moves between layers** — update
   [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md). If it diverges from PRD,
   add a `D-NNN` entry to [08_DEVIATIONS](./08_DEVIATIONS.md).
3. **A Finance / Ops / PM question gets answered** — remove it from the open-questions
   list in 02 and/or 06 and update the relevant rule.
4. **The PRD changes** — flag the version, capture what changed in
   [02_PROJECT_CONTEXT](./02_PROJECT_CONTEXT.md), update each affected doc.

The numbered IDs (`D-NNN`, `I-NNN`) **never get reused**. When something is removed,
leave a tombstone entry referencing the commit that removed it. **Note:** the current
`D-NNN` numbering started fresh on 4 May 2026 with the architecture rewrite — references
to `D-007` etc. in older artefacts (git history, the team-lead resync brief) refer to a
different numbering and should be checked by date.

---

## Version history

| Date | Change |
|---|---|
| 21 Apr 2026 | Initial architecture (v0.4) and v2.0-PRD-based schema docs |
| 30 Apr 2026 | PRD rewritten to v3.0 (flat Inviter/Invitee model) |
| 4 May 2026 | Team-lead resync — distributed-module architecture confirmed |
| 4–6 May 2026 | All design docs rewritten to v1.0 — current state |

---

*Last updated: 6 May 2026.*
