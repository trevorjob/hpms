# MSC HPMS

Hierarchical Promotion Management System — Inviter/Invitee referral platform for MSC.

**HPMS is not a standalone service.** It is implemented as additions to three existing
modules of [`mall-parent`](../mall-parent): `mall-userms`, `mall-rebate`, and
`mall-payment`. This repo contains the design documentation only — code lives in those
modules.

## Where to start

- **New to the project?** Read [docs/00_README.md](./docs/00_README.md) first; it indexes
  everything in reading order.
- **Looking for the product spec?** [docs/MSC_HPMS_PRD_v3.0.md](./docs/MSC_HPMS_PRD_v3.0.md).
- **Looking for the technical design?** [docs/01_ARCHITECTURE.md](./docs/01_ARCHITECTURE.md)
  and [docs/06_SCHEMA_DESIGN.md](./docs/06_SCHEMA_DESIGN.md).
- **Working on it?** [docs/02_PROJECT_CONTEXT.md](./docs/02_PROJECT_CONTEXT.md) has the
  current state and open questions.

## Repository layout

```text
hpms/
├── CLAUDE.md          ← project rules for AI-assisted work
├── README.md          ← this file
└── docs/
    ├── 00_README.md   ← documentation index + maintenance protocol
    ├── 01–08_*.md     ← architecture, schema, invariants, deviations
    ├── MSC_HPMS_PRD_v3.0.md     ← authoritative product spec
    └── archive/       ← superseded v2 PRD / process diagrams / data dictionary
```
