# MSC HPMS — Documentation Index

> Hierarchical Promotion Management System · Backend documentation hub

This folder is the single source of truth for HPMS backend design. Read in numbered order
if you're new; jump directly to a specific doc otherwise.

---

## Reading order

| # | Document | What it is | Audience |
|---|---|---|---|
| 01 | [Architecture](./01_ARCHITECTURE.md) | Stack choices, module boundaries, system context, deployment | CTO · backend lead · senior engineers |
| 02 | [Project Context](./02_PROJECT_CONTEXT.md) | Timeline, team, working agreements, anti-patterns, what's next | Anyone joining the project |
| 03 | [PRD v2.0](./03_PRD_v2.0.pdf) | Product requirements (PM-authored, informational) | All |
| 04 | [Process Diagrams v1.0](./04_ProcessDiagrams_v1.0.pdf) | Business process flowcharts (PM-authored, informational) | All |
| 05 | [Data Dictionary v1.0](./05_DataDictionary_v1.0.pdf) | Field-level entity definitions (PM-authored, informational) | All |
| 06 | [Schema Design](./06_SCHEMA_DESIGN.md) | Database design — entities, integrity, indexes, open questions | CTO · DBA · backend |
| 07 | [Application Invariants](./07_APPLICATION_INVARIANTS.md) | Business rules enforced in code, with owner + tests | Backend engineers · QA |
| 08 | [Deviations](./08_DEVIATIONS.md) | Numbered log of every place the implementation diverges from PM docs | CTO · reviewers |

The PM-authored docs (03–05) are **informational, not authoritative** — see
[CLAUDE.md](../CLAUDE.md) for the trust-level rule. Where engineering judgement
overrides the PM docs, the deviation is recorded in 08.

---

## Quick navigation by question

**"Where does this rule live — DB or app?"**
Schema design [§5](./06_SCHEMA_DESIGN.md#5-integrity-controls) gives the rule-by-rule split.
For app-layer rules, drill into [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md).

**"Why did we deviate from the data dictionary on X?"**
[08_DEVIATIONS](./08_DEVIATIONS.md) — search for the field name.

**"What's blocking the schema being final?"**
[06_SCHEMA_DESIGN §7](./06_SCHEMA_DESIGN.md#7-open-questions-for-finance-ops-and-integration)
lists the open Finance/Ops/Integration questions.

**"What's the commission split for an Agent-onboarded pharmacy?"**
[06_SCHEMA_DESIGN §4.2](./06_SCHEMA_DESIGN.md#42-split-scenarios) and
[07_APPLICATION_INVARIANTS I-041](./07_APPLICATION_INVARIANTS.md#i-041--split-matrix).

**"Why isn't the bonus amount enforced as a CHECK?"**
[08_DEVIATIONS D-005](./08_DEVIATIONS.md#d-005--split-percentages-and-bonus-amounts-not-encoded-in-ddl).

**"What goes in `audit_logs` and what guarantees its immutability?"**
[06_SCHEMA_DESIGN §3.8 + §5.4](./06_SCHEMA_DESIGN.md#38-audit_logs-append-only) and
[08_DEVIATIONS D-007](./08_DEVIATIONS.md#d-007--audit_logs-append-only--triggers--grant-defense-in-depth).

**"How does HPMS get order data?"**
[01_ARCHITECTURE §4.8](./01_ARCHITECTURE.md) (RocketMQ from main app) and
[06_SCHEMA_DESIGN §3.4 / §3.10](./06_SCHEMA_DESIGN.md) (read-mirror tables).

---

## Code locations

| Asset | Path |
|---|---|
| Initial schema (Flyway) | `src/main/resources/db/migration/V1__init.sql` |
| Project-wide design rules for AI assistants | `CLAUDE.md` (repo root) |
| All other documentation | this folder (`docs/`) |

---

## Document conventions

- **Numbered prefixes** (`NN_*.md`) define the canonical reading order.
- **Cross-references** use relative markdown links so they survive folder moves and
  render correctly in GitHub/GitLab.
- **Numbered identifiers** are stable references:
  - `D-NNN` — entries in 08_DEVIATIONS
  - `I-NNN` — entries in 07_APPLICATION_INVARIANTS
  - `Q-NNN` — open questions (currently across 06 and 07; consolidate when answered)
- **Source-of-truth ranking** when docs disagree:
  1. The implemented code (`V1__init.sql`, services)
  2. 08_DEVIATIONS (records why code differs from spec)
  3. 06_SCHEMA_DESIGN / 07_APPLICATION_INVARIANTS (engineering specs)
  4. 01_ARCHITECTURE (stack-level decisions)
  5. PM-authored PDFs (informational)

---

## Maintenance

When you change the schema or a business rule:

1. Update `V1__init.sql` (or add a `V2__*.sql` migration).
2. Update [06_SCHEMA_DESIGN](./06_SCHEMA_DESIGN.md) so the narrative matches.
3. If the change diverges from the PM docs, add a `D-NNN` entry to
   [08_DEVIATIONS](./08_DEVIATIONS.md).
4. If the change moves a rule between layers, update
   [07_APPLICATION_INVARIANTS](./07_APPLICATION_INVARIANTS.md).
5. If a Finance/Ops/Integration question gets answered, remove it from the open-questions
   list and update the relevant entry.

The numbered IDs (`D-NNN`, `I-NNN`) never get reused — when something is removed, leave a
tombstone entry referencing the commit that removed it.

---

*Last updated: 2026-04-27*
