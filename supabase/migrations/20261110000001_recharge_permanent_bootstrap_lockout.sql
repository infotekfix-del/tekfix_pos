-- ============================================================================
-- TEKFIX ERP - PHASE 15.4.1: PERMANENT BOOTSTRAP LOCKOUT MIGRATION
-- GUARANTEES INITIAL DEVICE BOOTSTRAP CAN NEVER REOPEN AFTER FIRST USE
-- IMMUTABLE DATABASE-LEVEL STATE STORE & ATOMIC STORED PROCEDURE
-- ============================================================================

-- 1. Permanent Shop Bootstrap State Table
CREATE TABLE IF NOT EXISTS public.recharge_shop_bootstrap_state (
    shop_id TEXT PRIMARY KEY,
    is_bootstrap_consumed BOOLEAN NOT NULL DEFAULT true,
    consumed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    first_device_id TEXT NOT NULL,
    first_device_type TEXT NOT NULL,
    first_platform TEXT NOT NULL,
    enrolled_by_owner_uid TEXT NOT NULL,
    recovery_lock BOOLEAN NOT NULL DEFAULT true
);

-- Index on consumed status for instant fail-closed checks
CREATE INDEX IF NOT EXISTS idx_recharge_bootstrap_consumed 
ON public.recharge_shop_bootstrap_state (shop_id, is_bootstrap_consumed);

-- 2. Row-Level Security (Strict Zero Public/Anon/Authenticated Access)
ALTER TABLE public.recharge_shop_bootstrap_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Deny public access to bootstrap state" ON public.recharge_shop_bootstrap_state;
CREATE POLICY "Deny public access to bootstrap state" ON public.recharge_shop_bootstrap_state
    FOR ALL TO anon, authenticated
    USING (false);

-- 3. Anti-Tampering Trigger: Prohibits DELETION and Prohibits Reopening
CREATE OR REPLACE FUNCTION public.recharge_prevent_bootstrap_tampering()
RETURNS TRIGGER AS $$
BEGIN
    -- Allow administrative synthetic test teardown ONLY when explicitly flagged via session config
    IF current_setting('app.admin_override', true) = 'true' THEN
        RETURN OLD;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SECURITY VIOLATION: Deletion of bootstrap audit state is strictly prohibited';
    END IF;
    IF TG_OP = 'UPDATE' AND (OLD.is_bootstrap_consumed IS TRUE AND NEW.is_bootstrap_consumed IS NOT TRUE) THEN
        RAISE EXCEPTION 'SECURITY VIOLATION: Reopening consumed bootstrap state is strictly prohibited';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_recharge_protect_bootstrap_state ON public.recharge_shop_bootstrap_state;
CREATE TRIGGER trg_recharge_protect_bootstrap_state
BEFORE UPDATE OR DELETE ON public.recharge_shop_bootstrap_state
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_bootstrap_tampering();

-- 4. Atomic Stored Procedure: recharge_consume_bootstrap
-- Concurrently-safe enrollment: inserts permanent lockout and device record atomically
CREATE OR REPLACE FUNCTION public.recharge_consume_bootstrap(
    p_shop_id TEXT,
    p_device_id TEXT,
    p_owner_uid TEXT,
    p_device_type TEXT,
    p_platform TEXT,
    p_device_model TEXT,
    p_public_key_pem TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_already_consumed BOOLEAN;
    v_now TIMESTAMPTZ := now();
BEGIN
    -- 1. Check if bootstrap was EVER consumed for this shop in the audit state table
    SELECT is_bootstrap_consumed INTO v_already_consumed
    FROM public.recharge_shop_bootstrap_state
    WHERE shop_id = p_shop_id;

    IF v_already_consumed IS TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Permanent Bootstrap Lockout: Initial bootstrap opportunity was already consumed and can NEVER be reopened. Revocation or deletion of devices does not reset this gate.'
        );
    END IF;

    -- 2. Concurrency-safe insertion into recharge_shop_bootstrap_state
    -- Primary Key constraint on shop_id guarantees exactly one winner in race conditions
    INSERT INTO public.recharge_shop_bootstrap_state (
        shop_id,
        is_bootstrap_consumed,
        consumed_at,
        first_device_id,
        first_device_type,
        first_platform,
        enrolled_by_owner_uid,
        recovery_lock
    ) VALUES (
        p_shop_id,
        true,
        v_now,
        p_device_id,
        p_device_type,
        p_platform,
        p_owner_uid,
        true
    );

    -- 3. Insert into recharge_trusted_devices
    INSERT INTO public.recharge_trusted_devices (
        device_id,
        shop_id,
        owner_uid,
        device_type,
        platform,
        device_model,
        public_key_pem,
        is_active,
        is_revoked,
        enrolled_at,
        last_verified_at
    ) VALUES (
        p_device_id,
        p_shop_id,
        p_owner_uid,
        p_device_type,
        p_platform,
        p_device_model,
        p_public_key_pem,
        true,
        false,
        v_now,
        v_now
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Initial device enrolled and bootstrap permanently locked'
    );
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Permanent Bootstrap Lockout: Concurrent or duplicate bootstrap attempt rejected. Gate is permanently closed.'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Helper Function: Check whether bootstrap is permanently locked
CREATE OR REPLACE FUNCTION public.recharge_is_bootstrap_locked(p_shop_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_locked BOOLEAN;
BEGIN
    SELECT is_bootstrap_consumed INTO v_locked
    FROM public.recharge_shop_bootstrap_state
    WHERE shop_id = p_shop_id;

    RETURN COALESCE(v_locked, false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Administrative Teardown for Synthetic Test Shops Only
CREATE OR REPLACE FUNCTION public.recharge_admin_teardown_test_shop(p_shop_id TEXT)
RETURNS VOID AS $$
BEGIN
    -- STRICT SAFETY: Only synthetic test shops can EVER be torn down
    IF p_shop_id NOT LIKE 'shop_test_%' AND p_shop_id NOT LIKE 'shop_staging_%' THEN
        RAISE EXCEPTION 'SECURITY VIOLATION: Administrative teardown is restricted exclusively to synthetic test shops';
    END IF;

    -- Set local session override strictly for this transaction
    PERFORM set_config('app.admin_override', 'true', true);

    DELETE FROM public.recharge_trusted_devices WHERE shop_id = p_shop_id;
    DELETE FROM public.recharge_shop_bootstrap_state WHERE shop_id = p_shop_id;
    DELETE FROM public.recharge_device_challenges WHERE shop_id = p_shop_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Disaster Recovery: Administrative Device Recovery (When Both Devices are Lost)
CREATE OR REPLACE FUNCTION public.recharge_admin_emergency_device_recovery(
    p_shop_id TEXT,
    p_admin_identity TEXT,
    p_auth_reference TEXT,
    p_new_device_id TEXT,
    p_new_device_type TEXT,
    p_new_platform TEXT,
    p_new_public_key_pem TEXT,
    p_owner_uid TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
BEGIN
    -- 1. Verify bootstrap was already consumed (cannot recover uninitialized shop)
    IF NOT EXISTS (SELECT 1 FROM public.recharge_shop_bootstrap_state WHERE shop_id = p_shop_id AND is_bootstrap_consumed = true) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Shop has not completed initial bootstrap');
    END IF;

    -- 2. Revoke all previous devices for this shop
    UPDATE public.recharge_trusted_devices 
    SET is_active = false, is_revoked = true, revoked_at = v_now, revocation_reason = 'Admin emergency recovery: ' || p_auth_reference
    WHERE shop_id = p_shop_id AND is_active = true;

    -- 3. Register the new audited device directly (bootstrap remains permanently consumed!)
    INSERT INTO public.recharge_trusted_devices (
        device_id, shop_id, owner_uid, device_type, platform,
        device_model, public_key_pem, is_active, is_revoked,
        enrolled_at, last_verified_at
    ) VALUES (
        p_new_device_id, p_shop_id, p_owner_uid, p_new_device_type, p_new_platform,
        'Admin Emergency Recovered Device', p_new_public_key_pem, true, false,
        v_now, v_now
    );

    -- 4. Record immutable audit log
    INSERT INTO public.recharge_wallet_logs (
        shop_id, wallet_id, entry_type, amount_paise, balance_before_paise, balance_after_paise,
        reference_id, description, created_by_uid, created_by_name
    ) VALUES (
        p_shop_id, 'SYSTEM', 'ADJUSTMENT', 0, 0, 0,
        p_auth_reference, 'ADMIN EMERGENCY DEVICE RECOVERY by ' || p_admin_identity || ' for ' || p_new_device_id,
        p_admin_identity, 'System Administrator'
    );

    RETURN jsonb_build_object('success', true, 'message', 'Emergency device recovered successfully. Bootstrap remains locked.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
