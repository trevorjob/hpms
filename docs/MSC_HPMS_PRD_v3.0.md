**MSC**

**Hierarchical Promotion Management System**

**Product Requirements Document  •  v3.0**

Unified Inviter/Invitee Model  |  Hybrid Promotion Strategy  |  April 2026

| Document Version | 3.0 — Full revision: Unified Inviter/Invitee model. Phase 1 system simplicity prioritised. |
| :---- | :---- |
| **Previous Version** | v2.0 — 3-tier model: MSC Field Lead / MSC Field Agent / MSC Frontline Rep |
| **Status** | Draft (Pending Review) |
| **Author** | Jubril Osunlana |
| **Date** | 30 April 2026 |
| **Audience** | Product Designer, Frontend, Backend, Mobile, QA |
| **Approved by** | Mr. Bruce (GM) |
| **Project Code** | MSC-HPMS-001 |

*This document supersedes PRD v2.0. The 3-tier promoter structure has been replaced by a unified Inviter/Invitee model. In Phase 1, the system makes NO distinction between in-house field promoters and external pharmacy inviters — both operate under identical commission logic. Role differentiation and salary differences are managed offline. Sections marked ⟳ are updated from v2.0. Sections marked ♥ are new in v3.0.*

# **1\. Product Overview**

The Hierarchical Promotion Management System (HPMS) is a self-service digital promotion platform that powers MSC’s hybrid go-to-market strategy. The system combines two channels of pharmacy acquisition and growth, both managed under a single unified commission logic:

* Offline Ground Promotion: In-house field promoters (MSC employees) visit pharmacies door-to-door, guide them through APP download, registration, first procurement, and teach them to use their invitation codes. These promoters are not configured differently in the system — they are treated as standard Inviters. Their salary and performance data are managed offline by MSC.

* Referral Fission (Inviter/Invitee): Every registered pharmacy automatically becomes an Inviter. They can share a unique QR code or invitation code to bring other pharmacies onto the platform. Invited pharmacies become Invitees, can also become Inviters, and invite others — creating unlimited referral depth with single-level commission attribution at each node.

Phase 1 prioritises system simplicity. The platform maintains one unified promotion and commission logic for all participants. No system-level role distinction exists between field promoters and regular pharmacy inviters. This avoids dual logic complexity and reduces implementation and maintenance overhead.

*Key rule: Commission is attributed only to the immediate upper-level Inviter. There is no multi-level or cross-level commission. The chain can be unlimited in depth, but each node only earns from the node directly below it.*

# **2\. Goals & Success Metrics**

## **Business Goals**

* Enable every registered pharmacy to become a self-service promoter with zero onboarding friction.

* Support in-house field promoters operating as standard Inviters within the same system — no separate configuration.

* Drive pharmacy acquisition through both proactive field promotion and organic peer-to-peer referral.

* Automate single-level commission calculation for all Inviters under one unified rule.

* Support dynamic commission rate adjustment for flexible operational tuning across promotion cycles.

* Drive MSC APP downloads by requiring users to register and operate through the APP.

* Produce audit-ready commission and invitation records for every billing cycle.

## **Success Metrics**

| Metric | Baseline | Target (90 days) |
| ----- | ----- | ----- |
| Pharmacies onboarded (all channels) | 0 (new) | ≥ 500 pharmacies |
| Inviter activation rate | N/A | ≥ 40% of registered pharmacies |
| Pharmacies acquired via referral fission | 0 (new) | ≥ 200 pharmacies |
| Commission calculation errors | Unknown (manual) | 0% |
| Duplicate pharmacy bindings | Unknown | 0 |
| Commission payout disputes | High (manual) | \< 2% of payouts |
| APP downloads tracked via invite source | N/A | Trackable via invite attribution |

# **3\. User Roles**

*Phase 1: The system recognises only two roles — Inviter and Invitee. No system-level distinction between in-house field promoters and external pharmacy inviters. Salary and role differences are managed entirely offline by MSC HR and Operations.*

| Role | Definition & Permissions |
| ----- | ----- |
| Inviter | Any registered and certified pharmacy user. Automatically qualifies as Inviter upon completing standard registration — no separate application or Admin approval required. Generates personal QR code and invitation code. Invites other pharmacies. Earns commission on direct Invitee’s settled orders only. Views earnings in the Sales / Become a Promoter section. Note: In-house field promoters operate as standard Inviters in the system. No system flag distinguishes them. |
| Invitee | Registered via another user’s invitation code or QR code during sign-up. Permanently bound to the first Inviter who registered them. Cannot be re-invited by another user. Also automatically qualifies as an Inviter and can invite others, creating a continuous referral chain. |
| MSC Admin | MSC back-office staff. Manages platform configuration, commission rate settings, pharmacy management, commission reports, dispute resolution, audit logs, and suspension controls. |

*Offline management: In-house field promoters’ registered accounts are manually collected by MSC Operations. Performance data is separately aggregated offline. Fixed salary is paid through MSC payroll systems — not through the platform. The platform only handles commission payments for all Inviters under the same unified rule.*

# **4\. Promotion Process Flowchart**

*♥ New in v3.0 — Not present in v2.0*

*Formally approved by GM (Mr. Bruce) for inclusion in the PRD and for presentation in technical department alignment meetings. This flowchart defines the end-to-end promotion process for both in-house field promoters and external pharmacy Inviters.*

## **4.1  Overall Promotion Flow**

|  | START Promoter identifies a target pharmacy |  |
| ----- | :---: | ----- |
|  | **↓** |  |
|  | **STEP 1: Promoter shares their invitation QR code or invitation code with the target pharmacy** |  |
|  | **↓** |  |
|  | **STEP 2: Target pharmacy downloads MSC APPand opens registration page** |  |
|  | **↓** |  |
|  | **DECISIONDoes pharmacies enter the invitation codeor scan the QR code during registration?** |  |
| **NO → Registered without invite code. Placed in the Inviter tier. No Inviter attributed.** |  **←          YES          →** | **YES → Has this user been previously invited?** |
|  | **↓** | **↓** |
|  | **STEP 3:  Pharmacy bound as Invitee to the Inviter.Binding is permanent and immutable.** | **YES → New invite code silently ignored.Original binding preserved.** |
|  | **↓** |  |
|  | **STEP 4: Pharmacy completes standard registration and pharmacy certification** |  |
|  | **↓** |  |
|  | **STEP 5: Pharmacy places first procurement order on the MSC APP** |  |
|  | **↓** |  |
|  | **STEP 6: Pharmacy accesses Personal Center →“Become a Promoter” CTA** |  |
|  | **↓** |  |
|  | **STEP 7: Pharmacy views unique QR code and invitation code. Shares with neighbouring pharmacies.** |  |
|  | **↓** |  |
|  | **STEP 8: Invited pharmacy registers using the code.Become a new Invitee → also becomes an Inviter.Referral chain continues.** |  |
|  | **↓** |  |
|  | **COMMISSION TRIGGER: When Invitee’s order is SETTLED →Direct Inviter earns commission.No cascading. Single-level only.** |  |

## 

## **4.2  Commission Attribution Chain Example**

*A invites B, B invites C, C invites D. Each node only earns from the node directly below it. No cross-level or retroactive commission applies.*

| Promoter / Inviter A(Field staff or pharmacy) | Pharmacy B(Invitee of A,Inviter of C) | Pharmacy C(Invitee of B,Inviter of D) | Pharmacy D(Invitee of C) |
| :---: | :---: | ----- | ----- |
| **↓ earns from B’s orders** | **↓ earns from C’s orders** | **↓ earns from D’s orders** | No further chain |
| ✕ does NOT earn from C or D | ✕ does NOT earn from D |  |  |

# **5\. Functional Requirements**

## **5.1  Registration & Invitation Binding**

- The pharmacy registration page supports two paths:

* Standard registration — invitation code field left blank or not entered.

* Invited registration — user enters an invitation code or scans an Inviter’s QR code.

     

* Registered with valid invitation code → user bound as Invitee to that Inviter. Binding is permanent and immutable.

* Registered without invitation code → user placed in Inviter tier automatically. Can invite others immediately.

* Lifetime binding rule: each user can only be bound to one Inviter, ever. If a user has previously been bound, any subsequent invitation code entered is silently ignored. Original binding preserved. No error shown to the user.

* The invitation code field is optional; it must never block or delay the standard registration flow.

* Backend validates the invitation code after form submission. If already bound, the system ignores the new code and proceeds normally.

## **5.2  Promoter Self-Service Flow**

* Every registered and certified pharmacy user automatically qualifies as an Inviter upon completing registration. No separate application or Admin approval required.

* Users access promoter features via: Personal Center → Become a Promoter.

* Within the Become a Promoter section, users can view:

* My Invitation QR Code — unique, shareable, downloadable image.

* My Invitation Code — unique alphanumeric short code for manual sharing.

* Number of people I have invited — count of direct Invitees.

* Cumulative commission earned — total to date.

* Commission detail list — per settled order, per Invitee, with date.

* All users — whether they were invited themselves or not — can see and use the Become a Promoter entry. An Invitee is also automatically an Inviter for anyone they recruit.

## **5.3  QR Code & Invitation Code System**

* Each registered pharmacy user is automatically assigned a unique invitation code (short alphanumeric string) and QR code upon completing registration.

* The QR code encodes the invitation code and links to the MSC APP/H5 registration page with the code pre-filled.

* Users can share the QR code image or copy the invitation code via any channel ( WhatsApp, SMS, social media, or in person.)

* Scanning the QR code on the MSC APP or H5 homepage triggers the registration flow with the Inviter’s code pre-filled.

* QR codes and invitation codes are permanent while the account is active.

* Suspended account: QR code and invitation code are deactivated. New registrations using a deactivated code are rejected.

## **5.4  Commission Engine**

*Phase 1: One unified commission rule for all Inviters. No system distinction between field promoters and external pharmacy inviters. Both are treated identically by the commission engine.*

* Commission trigger: an Invitee’s order reaches SETTLED status.

* Commission attribution: paid only to the direct Inviter of the user who placed the order. No cascading.

* Commission rate (default, configurable via Admin): 1% on monthly settled Invitee orders up to ₦1,000,000. 2% on amounts above ₦1,000,000 per Invitee per month.

* Commission settlement: credited to the Inviter’s MSC account balance. Recorded as income type: Sales Commission. Withdrawable per existing financial logic.

* No commission generated without a fully settled order. Pending, failed, and cancelled orders are excluded.

* Every commission payment must have an auditable transaction reference linking it to the originating settled order.

## **5.5  Dynamic Commission Rate Management**

*♥ New in v3.0 — Not present in v2.0*

*New core feature in v3.0. Commission rates must be configurable by Admin at any time without code deployment, supporting flexible operational tuning across promotion cycles.*

* Admin Portal must include a dedicated Commission Rate Configuration page.

* Admin can update commission rates at any time via a visual interface — no technical deployment required.

* Rate changes take effect from the next billing cycle. Settled orders in the current cycle are unaffected.

* Configurable parameters: tier 1 threshold (default ₦1M), tier 1 rate (default 1%), tier 2 rate (default 2%).

* All rate changes logged in the audit trail: Admin actor, previous rate, new rate, effective date, timestamp, and reason.

* Current active commission rates are always visible on the configuration page.

## **5.6  KPI Tracking & Dashboards**

* Inviter Dashboard (Personal Center → Sales):

* Number of direct Invitees.

* Monthly and cumulative commission earned.

* Commission detail list per settled order per Invitee.

* Filter by date range.

* Admin Commission Report (Admin Portal):

* Network-wide commission report by billing month.

* Total Inviters, total Invitees, total commission paid.

* Exportable for Finance and offline performance tracking by MSC Operations.

## **5.7  Risk & Compliance Controls**

* No commission generated without a settled transaction reference.

* Lifetime binding rule prevents re-invitation of already-bound users, eliminating attribution disputes.

* Single-level commission only — no multi-level cascading, preventing any pyramid scheme risk.

* Admin can suspend any account. Suspension freezes commission accrual and deactivates QR/invitation codes immediately.

* All Admin actions (rate changes, suspensions) logged with actor \+ timestamp \+ reason.

* Duplicate pharmacy detection: block on same business\_registration\_number; flag for Admin review on same pharmacy\_name \+ address \+ LGA.

## **5.8  Non-Functional Requirements**

| Category | Requirement |
| ----- | ----- |
| Performance | Commission batch for 10,000 Invitees completes in under 10 minutes. |
| Availability | Core API uptime ≥ 99.5%. QR scanning works offline; registration syncs on reconnect. |
| Security | PII and financial data encrypted at rest and in transit (TLS 1.2+). RBAC is enforced at API level. |
| Auditability | Every commission event, rate change, and Admin action logged with actor, timestamp, and reason. |
| Mobile | Android 8+ and iOS 13+. Target APK size \< 30 MB. |
| Scalability | Architecture supports horizontal scaling as the referral network grows beyond 100,000 users. |

# 

# **6\. Screens & Surfaces**

*Updated to reflect the unified Inviter/Invitee model. New screens added: dynamic commission rate configuration page and Become a Promoter self-service flow in Personal Center.*

| Surface | Platform | Key Screens |
| ----- | ----- | ----- |
| Admin Portal | Web | Login, Commission rate configuration (new — view and update rates, view history), Pharmacy management, Inviter/Invitee network overview, Commission reports (exportable), Audit logs, Suspension controls |
| MSC APP / H5 | iOS \+ Android / Mobile Web | Registration with optional invite code field (updated), Personal Center → Become a Promoter (new CTA), My QR code & invitation code (new), My Invitees list (new), Earnings & commission detail (new), Order placement, Order history, Payment status |

# **7\. API Contract Summary**

*Updated to reflect the unified Inviter/Invitee model. Previous 3-tier hierarchy endpoints removed. Full OpenAPI spec to be authored separately by the Backend team.*

## **Auth & Users**

* POST /auth/login — Issue JWT for all roles.

* POST /auth/refresh — Refresh token.

* POST /users/register — Standard pharmacy registration with optional invitation\_code field.

* GET /users/{id}/profile — Return user profile including Inviter status and invitation code.

## **Invitation & QR Code**

* GET /invitations/my-code — Return authenticated user’s invitation code and QR code.

* GET /invitations/validate?code={code} — Validate invitation code before registration completes.

* GET /invitations/invitees — Return list of all Invitees bound to the authenticated Inviter.

* GET /invitations/stats — Return Inviter stats: total Invitees, cumulative commission.

## **Pharmacies**

* POST /pharmacies/register — Register pharmacy. Accepts optional invitation\_code. Triggers lifetime binding if valid.

* PATCH /pharmacies/{id}/verify — Mark pharmacy verified (Admin).

* GET /pharmacies — List with filters (status, inviter, region).

## **Commissions**

* POST /commissions/calculate — Trigger monthly batch (Admin / cron). Applies current active rate.

* GET /commissions/my-summary — Monthly commission summary for authenticated Inviter.

* GET /commissions/my-breakdown — Line-item breakdown per Invitee per settled order.

* GET /commissions/report?month=YYYY-MM — Full network commission report (Admin, exportable).

## **Commission Rate Configuration (New)**

* GET /config/commission-rates — Return current active commission rate configuration.

* PUT /config/commission-rates — Update rates (Admin only). Logged to audit trail. Effective next billing cycle.

* GET /config/commission-rates/history — Full history of rate changes with actor, timestamp, and reason.

## **Orders**

* POST /orders — Place a pharmacy order.

* PATCH /orders/{id}/status — Update order status.

* GET /orders/{id}/settlement — Return settlement details. Triggers commission on SETTLED status.

# 

# 

# **8\. QA Test Scenarios**

| \# | Scenario | Expected Result | Priority |
| ----- | ----- | ----- | ----- |
| 1 | Pharmacy registers with a valid invitation code | Bound as Invitee. Binding is permanent. | Critical |
| 2 | Pharmacy registers without an invitation code | Placed in the Inviter tier automatically. Can invite others. | Critical |
| 3 | Previously invited user enters a new invitation code | New code silently ignored. Original binding preserved. | Critical |
| 4 | Invitee places settled order — commission attributed to direct Inviter only | Direct Inviter earns commission. No cascading. | Critical |
| 5 | A → B → C chain: C places settled order | B earns commission on C’s order. A earns nothing from C. | Critical |
| 6 | Admin updates commission rate via configuration page | Rate saved. Audit log created. The new rate applies to the next billing cycle only. | Critical |
| 7 | Rate change attempted without Admin credentials | Rejected with 403 Forbidden. | Critical |
| 8 | Suspended user’s QR code scanned by new user | Registration rejected. Code shown as invalid. | High |
| 9 | Duplicate pharmacy registration with same CAC number | Registration blocked. Duplicate detected. | Critical |
| 10 | Commission batch run for 10,000 Invitees | Completes under 10 minutes. All records are correct. | High |
| 11 | Invitee accesses Become a Promoter section | QR code, invitation code, Invitee count, and earnings displayed correctly. | High |
| 12 | Field promoter (treated as standard Inviter) onboards pharmacy — commission calculated | Commission calculated identically to any other Inviter. No system distinction. | Critical |

# **9\. Out of Scope (v3.0 Phase 1 MVP)**

* System-level role distinction between field promoters and external pharmacy Inviters — managed offline in Phase 1\.

* Multi-level cascading commissions — single-level direct attribution only.

* Salary payroll integration for field promoters — handled offline by MSC HR.

* Large-B (B2B) tiered promotion and achievement scoring / virtual badges — deferred to post-MVP.

* Payment disbursement / bank API integration — commission balance only in MVP.

* Push notifications for commission events — deferred.

* Advanced analytics and cohort reporting — deferred.

# **10\. Open Questions**

| \# | Question | Owner | Status |
| ----- | ----- | ----- | ----- |
| 1 | What is the revised MVP delivery deadline following the scope change? (Pending team reassessment meeting) | PO \+ Team | In Progress |
| 2 | What are the default commission rates at launch? Are the 1%/2% thresholds confirmed? | GM / Finance | Open |
| 3 | How are commission payouts processed — MSC wallet balance only, or bank transfer also? | Finance / Backend | Open |
| 4 | What constitutes pharmacy certification — document upload, manual review, or both? | MSC Ops | Open |
| 5 | How many field promoters will be deployed at launch and in which cities? | GM / Operations | Open |
| 6 | Large-B (B2B) achievement scoring and virtual badge logic — calculation method and tier definitions? | GM / Product | Deferred |

*End of Document  —  MSC HPMS PRD v3.0  |  Unified Inviter/Invitee Model  |  Supersedes PRD v2.0*