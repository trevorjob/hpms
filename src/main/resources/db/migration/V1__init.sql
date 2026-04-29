-- =====================================================================
-- MSC HPMS — Initial Schema (Flyway V1)
-- Hierarchical Promotion Management System
-- Target: MySQL 8.0+ / MariaDB 10.5+
-- Engine: InnoDB · Charset: utf8mb4 · Collation: utf8mb4_unicode_ci
--
-- TIMEZONE POLICY
--   Storage: UTC (this script forces SET time_zone = '+00:00').
--   Display: Africa/Lagos (handled at the Spring/Jackson layer).
--   This is a deliberate deviation from the house convention of "Lagos
--   everywhere" — see docs/08_DEVIATIONS.md (D-018) for the full rationale.
--
-- DESIGN PHILOSOPHY
--   The database enforces STRUCTURAL INVARIANTS only:
--     * Referential integrity (FKs)
--     * Uniqueness (including composite batch idempotency)
--     * NOT NULL on genuinely required fields
--     * Immutability required for compliance (audit_logs append-only)
--     * Basic type/range sanity (e.g., order_value > 0)
--   Business rules live in the application layer.
--   See docs/07_APPLICATION_INVARIANTS.md for the full list.
-- =====================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET time_zone = '+00:00';

-- =====================================================================
-- 0. admins
-- (Pending identity-pattern decision — Pattern A vs B vs main-app integration.
--  Kept for now so referencing tables can compile; may be removed if Pattern B
--  is chosen. See 02_PROJECT_CONTEXT §6.)
-- =====================================================================
CREATE TABLE admins (
    admin_id         BINARY(16)   NOT NULL,
    full_name        VARCHAR(100) NOT NULL,
    email_address    VARCHAR(255) NOT NULL,
    phone_number     VARCHAR(16)  NULL,
    password_hash    VARCHAR(255) NOT NULL,
    status           ENUM('ACTIVE','SUSPENDED','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (admin_id),
    UNIQUE KEY uq_admins_email (email_address),
    KEY ix_admins_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 1. promoters  (all 3 levels in one table, differentiated by `level`)
-- =====================================================================
CREATE TABLE promoters (
    promoter_id           BINARY(16)    NOT NULL,
    full_name             VARCHAR(100)  NOT NULL,
    phone_number          VARCHAR(16)   NOT NULL,      -- format validated in app
    email_address         VARCHAR(255)  NULL,          -- required for FIELD_LEAD (app-enforced)
    level                 ENUM('FIELD_LEAD','FIELD_AGENT','FRONTLINE_REP') NOT NULL,
    parent_id             BINARY(16)    NULL,          -- structural rule: NULL iff level=FIELD_LEAD
    barcode_id            BINARY(16)    NULL,          -- 1:1 to barcodes; nullable only at insert-time (circular FK)
    territory             VARCHAR(100)  NOT NULL,
    cross_region_approved TINYINT(1)    NOT NULL DEFAULT 0,
    status                ENUM('ACTIVE','SUSPENDED','INACTIVE','PENDING') NOT NULL DEFAULT 'PENDING',
    suspension_reason     VARCHAR(500)  NULL,          -- required-when-SUSPENDED is an app rule
    bank_account_number   VARCHAR(10)   NULL,
    bank_name             VARCHAR(100)  NULL,
    created_by            BINARY(16)    NOT NULL,      -- admin_id or promoter_id (polymorphic; no FK)
    created_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (promoter_id),
    UNIQUE KEY uq_promoters_phone    (phone_number),
    UNIQUE KEY uq_promoters_email    (email_address),
    UNIQUE KEY uq_promoters_barcode  (barcode_id),
    KEY ix_promoters_parent          (parent_id),
    KEY ix_promoters_status          (status),
    KEY ix_promoters_level           (level),
    KEY ix_promoters_territory       (territory),
    KEY ix_promoters_created_by      (created_by),

    -- Structural shape only: FIELD_LEAD has no parent; AGENT/REP must have one.
    -- Parent-LEVEL correctness (Agent→Lead, Rep→Agent) is enforced by the app
    -- at recruit endpoints (POST /api/v1/admin/field-leads, etc.).
    CONSTRAINT chk_promoters_hierarchy CHECK (
        (level = 'FIELD_LEAD'    AND parent_id IS NULL) OR
        (level = 'FIELD_AGENT'   AND parent_id IS NOT NULL) OR
        (level = 'FRONTLINE_REP' AND parent_id IS NOT NULL)
    ),
    CONSTRAINT fk_promoters_parent
        FOREIGN KEY (parent_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 2. barcodes
-- Format MSC-FL-NNNNNN (Field Lead), MSC-AG-NNNNNN (Agent), MSC-FR-NNNNNN (Rep)
-- =====================================================================
CREATE TABLE barcodes (
    barcode_id         BINARY(16)   NOT NULL,
    barcode_code       VARCHAR(32)  NOT NULL,
    qr_payload         VARCHAR(512) NOT NULL,
    promoter_id        BINARY(16)   NOT NULL,
    parent_barcode_id  BINARY(16)   NULL,              -- NULL for FIELD_LEAD (app-aligned with promoter.level)
    root_barcode_id    BINARY(16)   NOT NULL,          -- always the Field Lead's barcode (self for leads)
    status             ENUM('ACTIVE','REVOKED') NOT NULL DEFAULT 'ACTIVE',
    created_at         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (barcode_id),
    UNIQUE KEY uq_barcodes_code     (barcode_code),
    UNIQUE KEY uq_barcodes_qr       (qr_payload),
    UNIQUE KEY uq_barcodes_promoter (promoter_id),
    KEY ix_barcodes_parent          (parent_barcode_id),
    KEY ix_barcodes_root            (root_barcode_id),
    KEY ix_barcodes_status          (status),

    CONSTRAINT fk_barcodes_promoter
        FOREIGN KEY (promoter_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_barcodes_parent
        FOREIGN KEY (parent_barcode_id) REFERENCES barcodes(barcode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_barcodes_root
        FOREIGN KEY (root_barcode_id) REFERENCES barcodes(barcode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Close the circular FK promoters.barcode_id → barcodes.barcode_id
ALTER TABLE promoters
    ADD CONSTRAINT fk_promoters_barcode
        FOREIGN KEY (barcode_id) REFERENCES barcodes(barcode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT;

-- =====================================================================
-- 3. pharmacies
-- =====================================================================
CREATE TABLE pharmacies (
    pharmacy_id              BINARY(16)   NOT NULL,
    pharmacy_name            VARCHAR(150) NOT NULL,
    business_reg_number      VARCHAR(16)  NOT NULL,    -- HARD unique: primary duplicate-detection field (CAC)
    nafdac_licence_number    VARCHAR(32)  NULL,
    legal_rep_name           VARCHAR(100) NOT NULL,
    legal_rep_phone          VARCHAR(16)  NOT NULL,
    legal_rep_id_type        ENUM('NIN','BVN','PASSPORT','DRIVERS_LICENCE','VOTERS_CARD') NOT NULL,
    legal_rep_id_number      VARCHAR(32)  NOT NULL,
    street_address           VARCHAR(200) NOT NULL,
    lga                      VARCHAR(100) NOT NULL,
    state                    VARCHAR(100) NOT NULL,
    onboarding_barcode_id    BINARY(16)   NOT NULL,    -- immutability is an app rule
    onboarding_promoter_id   BINARY(16)   NOT NULL,    -- denormalised from barcode; immutability is an app rule
    verification_status      ENUM('PENDING','VERIFIED','REJECTED') NOT NULL DEFAULT 'PENDING',
    verification_date        DATETIME     NULL,
    verified_by              BINARY(16)   NULL,
    rejection_reason         VARCHAR(500) NULL,
    first_order_settled_at   DATETIME     NULL,
    onboarding_bonus_paid    TINYINT(1)   NOT NULL DEFAULT 0,  -- monotonic 0→1; enforced in app
    registration_timestamp   DATETIME     NOT NULL,    -- exact scan time; immutable (app)
    created_at               DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (pharmacy_id),
    UNIQUE KEY uq_pharmacies_cac      (business_reg_number),
    UNIQUE KEY uq_pharmacies_nafdac   (nafdac_licence_number),
    -- SOFT duplicate detection: non-unique, queried by app before INSERT to flag for Admin review
    KEY ix_pharmacies_soft_dupe       (pharmacy_name, street_address, lga),
    KEY ix_pharmacies_territory       (state, lga),
    KEY ix_pharmacies_verification    (verification_status),
    KEY ix_pharmacies_onboard_barcode (onboarding_barcode_id),
    KEY ix_pharmacies_onboard_promoter(onboarding_promoter_id),
    KEY ix_pharmacies_verified_by     (verified_by),
    KEY ix_pharmacies_first_order     (first_order_settled_at),

    CONSTRAINT fk_pharmacies_onboard_barcode
        FOREIGN KEY (onboarding_barcode_id) REFERENCES barcodes(barcode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_pharmacies_onboard_promoter
        FOREIGN KEY (onboarding_promoter_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_pharmacies_verified_by
        FOREIGN KEY (verified_by) REFERENCES admins(admin_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 4. orders  (read-mirrored from main app via RocketMQ events)
-- HPMS does NOT originate orders. The integration consumer projects
-- main-app order events into this table.
-- =====================================================================
CREATE TABLE orders (
    order_id        BINARY(16)     NOT NULL,
    pharmacy_id     BINARY(16)     NOT NULL,
    order_value     DECIMAL(15,2)  NOT NULL,
    order_status    ENUM('PENDING','PROCESSING','SETTLED','FAILED','CANCELLED') NOT NULL DEFAULT 'PENDING',
    settled_at      DATETIME       NULL,
    settlement_ref  VARCHAR(100)   NULL,               -- UNIQUE when set (MySQL allows multiple NULLs)
    billing_month   CHAR(7)        NULL,               -- YYYY-MM; format validation is app-layer
    created_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (order_id),
    UNIQUE KEY uq_orders_settlement_ref (settlement_ref),
    KEY ix_orders_pharmacy       (pharmacy_id),
    KEY ix_orders_status         (order_status),
    KEY ix_orders_settled_at     (settled_at),
    KEY ix_orders_billing_month  (billing_month),
    KEY ix_orders_batch_scan     (order_status, billing_month),

    CONSTRAINT chk_orders_value CHECK (order_value > 0),
    -- Commission-engine contract: a SETTLED order without these three fields
    -- silently corrupts a full month of commission. This is structural — not business logic.
    CONSTRAINT chk_orders_settled_fields CHECK (
        order_status <> 'SETTLED' OR
        (settled_at IS NOT NULL AND settlement_ref IS NOT NULL AND billing_month IS NOT NULL)
    ),
    CONSTRAINT fk_orders_pharmacy
        FOREIGN KEY (pharmacy_id) REFERENCES pharmacies(pharmacy_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 5. commission_batches  (NEW — explicit batch run record)
-- One row per batch invocation. xxl-job calls the commission job; the job
-- inserts a RUNNING row, processes the month, then updates to COMPLETED
-- or FAILED. Re-runs for the same billing_month create new rows; the
-- composite uniqueness on commission_records makes the upsert idempotent.
-- =====================================================================
CREATE TABLE commission_batches (
    batch_id                  BINARY(16)     NOT NULL,
    billing_month             CHAR(7)        NOT NULL,                            -- YYYY-MM
    status                    ENUM('RUNNING','COMPLETED','FAILED','CANCELLED')
                                             NOT NULL DEFAULT 'RUNNING',
    trigger_source            ENUM('SYSTEM_CRON','ADMIN_MANUAL') NOT NULL,
    triggered_by_admin_id     BINARY(16)     NULL,                                -- non-null when ADMIN_MANUAL
    started_at                DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at              DATETIME       NULL,
    error_message             VARCHAR(2000)  NULL,
    total_orders_processed    INT            NULL,
    total_records_upserted    INT            NULL,
    total_gross_commission    DECIMAL(15,2)  NULL,
    xxl_job_log_id            BIGINT         NULL,                                -- link to xxl-job execution history

    PRIMARY KEY (batch_id),
    KEY ix_batches_billing_month (billing_month, started_at),
    KEY ix_batches_status        (status),
    KEY ix_batches_admin         (triggered_by_admin_id),

    CONSTRAINT fk_batches_admin
        FOREIGN KEY (triggered_by_admin_id) REFERENCES admins(admin_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 6. commission_records
-- Composite UNIQUE(promoter_id, pharmacy_id, billing_month) is the critical
-- DB-level invariant: it makes batch re-runs idempotent (INSERT ... ON
-- DUPLICATE KEY UPDATE). Split percentages and formula live in the app.
-- =====================================================================
CREATE TABLE commission_records (
    commission_id         BINARY(16)     NOT NULL,
    batch_id              BINARY(16)     NULL,         -- last batch that touched this row
    promoter_id           BINARY(16)     NOT NULL,
    pharmacy_id           BINARY(16)     NOT NULL,
    billing_month         CHAR(7)        NOT NULL,
    total_pharmacy_sales  DECIMAL(15,2)  NOT NULL,
    commission_type       ENUM('DIRECT','OVERRIDE') NOT NULL,
    gross_commission      DECIMAL(15,2)  NOT NULL,
    split_percentage      DECIMAL(5,2)   NOT NULL,     -- value range validated in app (100/90/10 today)
    net_commission        DECIMAL(15,2)  NOT NULL,     -- computed by app: ROUND(gross × split / 100, 2)
    status                ENUM('CALCULATED','APPROVED','DISPUTED','PAID') NOT NULL DEFAULT 'CALCULATED',
    dispute_note          VARCHAR(500)   NULL,
    calculated_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    approved_by           BINARY(16)     NULL,
    approved_at           DATETIME       NULL,

    PRIMARY KEY (commission_id),
    -- Idempotent batch guarantee — re-running the batch for the same billing_month
    -- cannot create duplicate rows (used with INSERT ... ON DUPLICATE KEY UPDATE).
    UNIQUE KEY uq_commission_ppb (promoter_id, pharmacy_id, billing_month),
    KEY ix_commission_batch         (batch_id),
    KEY ix_commission_promoter      (promoter_id),
    KEY ix_commission_pharmacy      (pharmacy_id),
    KEY ix_commission_billing_month (billing_month),
    KEY ix_commission_status        (status),
    KEY ix_commission_approved_by   (approved_by),
    KEY ix_commission_report        (billing_month, status),
    KEY ix_commission_leaderboard   (billing_month, status, promoter_id, net_commission),

    CONSTRAINT fk_commission_batch
        FOREIGN KEY (batch_id) REFERENCES commission_batches(batch_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_commission_promoter
        FOREIGN KEY (promoter_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_commission_pharmacy
        FOREIGN KEY (pharmacy_id) REFERENCES pharmacies(pharmacy_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_commission_approved_by
        FOREIGN KEY (approved_by) REFERENCES admins(admin_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 7. onboarding_bonuses
-- UNIQUE(pharmacy_id) is the only hard double-payment guard that needs to
-- be at the DB level (race-safe). Split amounts and supervisor validation
-- are enforced by the bonus-payment service.
-- =====================================================================
CREATE TABLE onboarding_bonuses (
    bonus_id             BINARY(16)     NOT NULL,
    pharmacy_id          BINARY(16)     NOT NULL,      -- UNIQUE: one bonus per pharmacy, ever
    total_bonus_amount   DECIMAL(10,2)  NOT NULL,
    recipient_1_id       BINARY(16)     NOT NULL,
    recipient_1_amount   DECIMAL(10,2)  NOT NULL,
    recipient_2_id       BINARY(16)     NULL,
    recipient_2_amount   DECIMAL(10,2)  NULL,
    trigger_status       ENUM('WAITING_VERIFICATION','WAITING_FIRST_ORDER','READY_TO_PAY','PAID')
                                        NOT NULL DEFAULT 'WAITING_VERIFICATION',
    verification_met_at  DATETIME       NULL,
    first_order_met_at   DATETIME       NULL,
    paid_at              DATETIME       NULL,
    created_at           DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (bonus_id),
    UNIQUE KEY uq_bonus_pharmacy (pharmacy_id),
    KEY ix_bonus_recipient_1 (recipient_1_id),
    KEY ix_bonus_recipient_2 (recipient_2_id),
    KEY ix_bonus_trigger     (trigger_status),
    KEY ix_bonus_paid_at     (paid_at),

    CONSTRAINT fk_bonus_pharmacy
        FOREIGN KEY (pharmacy_id) REFERENCES pharmacies(pharmacy_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bonus_recipient_1
        FOREIGN KEY (recipient_1_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bonus_recipient_2
        FOREIGN KEY (recipient_2_id) REFERENCES promoters(promoter_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 8. audit_logs   ***APPEND-ONLY — COMPLIANCE REQUIREMENT***
-- Two-layer enforcement:
--   1. DB triggers below raise SQLSTATE 45000 on UPDATE / DELETE.
--   2. The application DB user is granted INSERT-only on this table
--      (defense-in-depth, configured outside this migration — see
--      docs/06_SCHEMA_DESIGN §5.4 and 01_ARCHITECTURE §6).
-- =====================================================================
CREATE TABLE audit_logs (
    log_id          BINARY(16)   NOT NULL,
    actor_id        BINARY(16)   NOT NULL,    -- polymorphic: promoter_id OR admin_id (no FK)
    actor_role      ENUM('ADMIN','FIELD_LEAD','FIELD_AGENT','FRONTLINE_REP','SYSTEM') NOT NULL,
    action_type     ENUM(
        'ACCOUNT_CREATED','ACCOUNT_SUSPENDED','ACCOUNT_REINSTATED',
        'PHARMACY_VERIFIED','PHARMACY_REJECTED',
        'COMMISSION_APPROVED','BONUS_PAID',
        'BARCODE_GENERATED','BARCODE_REVOKED',
        'DISPUTE_RAISED','DISPUTE_RESOLVED'
    )                            NOT NULL,
    entity_type     ENUM('PROMOTER','PHARMACY','ORDER','COMMISSION','BONUS','BARCODE') NOT NULL,
    entity_id       BINARY(16)   NOT NULL,
    previous_state  JSON         NULL,
    new_state       JSON         NULL,
    reason          VARCHAR(500) NULL,         -- required-when-X is an app rule
    ip_address      VARCHAR(45)  NULL,
    occurred_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (log_id),
    KEY ix_audit_actor       (actor_id),
    KEY ix_audit_entity      (entity_type, entity_id),
    KEY ix_audit_action      (action_type),
    KEY ix_audit_occurred_at (occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='APPEND-ONLY. UPDATE and DELETE blocked by triggers AND by GRANT. Do not emit modifying DML against this table.';

DELIMITER $$
CREATE TRIGGER trg_audit_logs_no_update BEFORE UPDATE ON audit_logs
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'audit_logs is append-only: UPDATE forbidden';
END$$
CREATE TRIGGER trg_audit_logs_no_delete BEFORE DELETE ON audit_logs
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'audit_logs is append-only: DELETE forbidden';
END$$
DELIMITER ;

-- =====================================================================
-- 9. verification_call_logs
-- (Full call-log workflow may be deferred for MVP per open question Q3 in
--  02_PROJECT_CONTEXT — table created so post-MVP rollout is just an
--  enable, not a migration.)
-- =====================================================================
CREATE TABLE verification_call_logs (
    call_log_id        BINARY(16)    NOT NULL,
    pharmacy_id        BINARY(16)    NOT NULL,
    admin_id           BINARY(16)    NOT NULL,
    call_date          DATE          NOT NULL,
    call_outcome       ENUM('CONFIRMED','SUSPICIOUS','NO_ANSWER','WRONG_NUMBER','CALLBACK_REQUESTED') NOT NULL,
    notes              VARCHAR(1000) NULL,
    follow_up_required TINYINT(1)    NOT NULL DEFAULT 0,
    follow_up_date     DATE          NULL,
    follow_up_done     TINYINT(1)    NOT NULL DEFAULT 0,
    created_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (call_log_id),
    KEY ix_vcl_pharmacy      (pharmacy_id),
    KEY ix_vcl_admin         (admin_id),
    KEY ix_vcl_call_date     (call_date),
    KEY ix_vcl_outcome       (call_outcome),
    KEY ix_vcl_followup_due  (follow_up_required, follow_up_done, follow_up_date),

    CONSTRAINT fk_vcl_pharmacy
        FOREIGN KEY (pharmacy_id) REFERENCES pharmacies(pharmacy_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_vcl_admin
        FOREIGN KEY (admin_id) REFERENCES admins(admin_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 10. order_settlement_events
-- Append-only projection of main-app order state transitions.
-- Consumed from RocketMQ via integration/mainapp/.
-- =====================================================================
CREATE TABLE order_settlement_events (
    event_id             BINARY(16)   NOT NULL,
    order_id             BINARY(16)   NOT NULL,
    pharmacy_id          BINARY(16)   NOT NULL,
    from_status          ENUM('PENDING','PROCESSING','SETTLED','FAILED','CANCELLED') NULL,
    to_status            ENUM('PENDING','PROCESSING','SETTLED','FAILED','CANCELLED') NOT NULL,
    event_type           ENUM('ORDER_CREATED','PAYMENT_INITIATED','PAYMENT_CONFIRMED',
                              'ORDER_SETTLED','ORDER_FAILED','ORDER_CANCELLED') NOT NULL,
    settlement_ref       VARCHAR(100) NULL,          -- UNIQUE when set
    triggered_by         ENUM('SYSTEM','PAYMENT_GATEWAY','ADMIN') NOT NULL,
    gateway_response     JSON         NULL,
    commission_eligible  TINYINT(1)   NOT NULL DEFAULT 0,
    billing_month        CHAR(7)      NULL,
    occurred_at          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (event_id),
    UNIQUE KEY uq_ose_settlement_ref (settlement_ref),
    KEY ix_ose_order        (order_id),
    KEY ix_ose_pharmacy     (pharmacy_id),
    KEY ix_ose_event_type   (event_type),
    KEY ix_ose_occurred_at  (occurred_at),
    KEY ix_ose_billing_scan (commission_eligible, billing_month),

    CONSTRAINT fk_ose_order
        FOREIGN KEY (order_id) REFERENCES orders(order_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,  -- never silently wipe event timeline
    CONSTRAINT fk_ose_pharmacy
        FOREIGN KEY (pharmacy_id) REFERENCES pharmacies(pharmacy_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- END OF V1__init.sql
-- =====================================================================
