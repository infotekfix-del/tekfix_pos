-- ============================================================================
-- TEKFIX ERP - PHASE 15.4.2: EMERGENCY DEVICE RECOVERY SECURITY HARDENING
-- PREVENTS SPOOFING, REPLAY, PRIVILEGE ESCALATION & UNCHECKED RECOVERY
-- ENFORCES SERVER-SIDE ADMIN ALLOWLIST, SINGLE-USE TICKETS & STRICT PERMISSIONS
-- ============================================================================

-- 1. Administrative Allowlist Table
CREATE TABLE IF NOT EXISTS public.recharge_admin_allowlist (
    admin_identity TEXT PRIMARY KEY,
    full_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by TEXT NOT NULL DEFAULT 'SYSTEM'
);

-- Index on active admins
CREATE INDEX IF NOT EXISTS idx_recharge_admin_allowlist_active 
ON public.recharge_admin_allowlist (admin_identity, is_active);

-- Enable RLS (Strict Zero Public/Anon/Authenticated Access)
ALTER TABLE public.recharge_admin_allowlist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Deny public access to admin allowlist" ON public.recharge_admin_allowlist;
CREATE POLICY "Deny public access to admin allowlist" ON public.recharge_admin_allowlist
    FOR ALL TO anon, authenticated
    USING (false);

-- Seed Initial Authorized Administrator Identities
INSERT INTO public.recharge_admin_allowlist (admin_identity, full_name, is_active, created_by)
VALUES 
    ('ADMIN_SUPER_001', 'Lead Systems Administrator', true, 'INITIAL_SEED'),
    ('ADMIN_SECURITY_OPS', 'Security Operations Lead', true, 'INITIAL_SEED')
ON CONFLICT (admin_identity) DO UPDATE 
SET is_active = true, full_name = EXCLUDED.full_name;

-- 2. Emergency Recovery Incident Tickets Table
CREATE TABLE IF NOT EXISTS public.recharge_recovery_tickets (
    ticket_id TEXT PRIMARY KEY,
    shop_id TEXT NOT NULL,
    owner_uid TEXT NOT NULL,
    admin_identity TEXT NOT NULL REFERENCES public.recharge_admin_allowlist(admin_identity),
    status TEXT NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED', 'CONSUMED', 'CANCELLED', 'EXPIRED')),
    issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    consumed_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_recharge_recovery_tickets_lookup 
ON public.recharge_recovery_tickets (ticket_id, shop_id, status);

-- Enable RLS (Strict Zero Public/Anon/Authenticated Access)
ALTER TABLE public.recharge_recovery_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Deny public access to recovery tickets" ON public.recharge_recovery_tickets;
CREATE POLICY "Deny public access to recovery tickets" ON public.recharge_recovery_tickets
    FOR ALL TO anon, authenticated
    USING (false);

-- 3. Anti-Tampering Triggers for Recovery Audit Tables
CREATE OR REPLACE FUNCTION public.recharge_prevent_ticket_tampering()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('app.admin_override', true) = 'true' THEN
        RETURN OLD;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SECURITY VIOLATION: Deletion of recovery incident tickets is strictly prohibited';
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'CONSUMED' AND NEW.status != 'CONSUMED' THEN
        RAISE EXCEPTION 'SECURITY VIOLATION: Un-consuming a processed recovery ticket is strictly prohibited';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_recharge_protect_recovery_tickets ON public.recharge_recovery_tickets;
CREATE TRIGGER trg_recharge_protect_recovery_tickets
BEFORE UPDATE OR DELETE ON public.recharge_recovery_tickets
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ticket_tampering();

-- 4. Secure Ticket Issuance Procedure (Restricted to service_role)
CREATE OR REPLACE FUNCTION public.recharge_admin_issue_recovery_ticket(
    p_ticket_id TEXT,
    p_shop_id TEXT,
    p_owner_uid TEXT,
    p_admin_identity TEXT,
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB AS $$
DECLARE
    v_admin_valid BOOLEAN;
    v_bootstrap_owner TEXT;
    v_now TIMESTAMPTZ := now();
BEGIN
    -- 1. Verify administrator identity exists in active allowlist
    SELECT is_active INTO v_admin_valid
    FROM public.recharge_admin_allowlist
    WHERE admin_identity = p_admin_identity;

    IF v_admin_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Unauthorized Admin: Administrator identity "' || p_admin_identity || '" is not registered in active allowlist'
        );
    END IF;

    -- 2. Verify shop has completed bootstrap and owner UID matches
    SELECT enrolled_by_owner_uid INTO v_bootstrap_owner
    FROM public.recharge_shop_bootstrap_state
    WHERE shop_id = p_shop_id AND is_bootstrap_consumed = true;

    IF v_bootstrap_owner IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Shop Bootstrap Incomplete: Cannot issue emergency recovery ticket for uninitialized shop'
        );
    END IF;

    IF v_bootstrap_owner != p_owner_uid THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cross-Shop Security Violation: Owner UID "' || p_owner_uid || '" does not match enrolled shop owner'
        );
    END IF;

    -- 3. Insert ticket
    INSERT INTO public.recharge_recovery_tickets (
        ticket_id,
        shop_id,
        owner_uid,
        admin_identity,
        status,
        issued_at,
        metadata
    ) VALUES (
        p_ticket_id,
        p_shop_id,
        p_owner_uid,
        p_admin_identity,
        'ISSUED',
        v_now,
        p_metadata
    );

    RETURN jsonb_build_object(
        'success', true,
        'ticketId', p_ticket_id,
        'message', 'Emergency recovery ticket issued successfully'
    );
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Ticket Collision: Recovery ticket ID "' || p_ticket_id || '" already exists'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Hardened Emergency Device Recovery Procedure
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
    v_admin_valid BOOLEAN;
    v_bootstrap_owner TEXT;
    v_ticket RECORD;
    v_now TIMESTAMPTZ := now();
BEGIN
    -- 1. Validate device type and platform pairing
    IF p_new_device_type NOT IN ('mobile', 'laptop') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid deviceType: Must be "mobile" or "laptop"');
    END IF;

    IF p_new_platform NOT IN ('android', 'windows') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid platform: Must be "android" or "windows"');
    END IF;

    IF p_new_device_type = 'mobile' AND p_new_platform != 'android' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Platform mismatch: Mobile devices must run "android"');
    END IF;

    IF p_new_device_type = 'laptop' AND p_new_platform != 'windows' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Platform mismatch: Laptop devices must run "windows"');
    END IF;

    -- 2. Validate Public Key PEM format
    IF p_new_public_key_pem IS NULL 
       OR p_new_public_key_pem NOT LIKE '%-----BEGIN PUBLIC KEY-----%'
       OR p_new_public_key_pem NOT LIKE '%-----END PUBLIC KEY-----%'
       OR length(trim(p_new_public_key_pem)) < 100 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid public key: Must be a valid SPKI PEM encoded ECDSA P-256 public key');
    END IF;

    -- 3. Verify Administrator Identity against Active Allowlist
    SELECT is_active INTO v_admin_valid
    FROM public.recharge_admin_allowlist
    WHERE admin_identity = p_admin_identity;

    IF v_admin_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Unauthorized Admin Identity: "' || COALESCE(p_admin_identity, 'NULL') || '" is not registered in active allowlist'
        );
    END IF;

    -- 4. Atomically Consume the Single-Use Recovery Ticket
    UPDATE public.recharge_recovery_tickets
    SET status = 'CONSUMED', consumed_at = v_now
    WHERE ticket_id = p_auth_reference
      AND shop_id = p_shop_id
      AND owner_uid = p_owner_uid
      AND admin_identity = p_admin_identity
      AND status = 'ISSUED'
    RETURNING * INTO v_ticket;

    IF v_ticket.ticket_id IS NULL THEN
        -- Detailed diagnostics for security audit verification
        IF EXISTS (SELECT 1 FROM public.recharge_recovery_tickets WHERE ticket_id = p_auth_reference AND status = 'CONSUMED') THEN
            RETURN jsonb_build_object('success', false, 'error', 'Ticket Replay Rejected: Recovery ticket "' || p_auth_reference || '" has already been consumed');
        ELSIF EXISTS (SELECT 1 FROM public.recharge_recovery_tickets WHERE ticket_id = p_auth_reference AND (shop_id != p_shop_id OR owner_uid != p_owner_uid OR admin_identity != p_admin_identity)) THEN
            RETURN jsonb_build_object('success', false, 'error', 'Ticket Validation Failed: Incident ticket does not match target shop, owner, or issuing administrator');
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Invalid Ticket: Incident ticket reference "' || COALESCE(p_auth_reference, 'NULL') || '" is unissued or invalid');
        END IF;
    END IF;

    -- 5. Verify shop bootstrap was already consumed and owner matches
    SELECT enrolled_by_owner_uid INTO v_bootstrap_owner
    FROM public.recharge_shop_bootstrap_state
    WHERE shop_id = p_shop_id AND is_bootstrap_consumed = true;

    IF v_bootstrap_owner IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Shop Bootstrap Incomplete: Cannot recover shop without initial bootstrap');
    END IF;

    IF v_bootstrap_owner != p_owner_uid THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cross-Shop Security Violation: Owner UID does not match enrolled shop owner');
    END IF;

    -- 6. Atomically Revoke All Previous Devices for this shop
    UPDATE public.recharge_trusted_devices 
    SET is_active = false,
        is_revoked = true,
        revoked_at = v_now,
        revocation_reason = 'Admin emergency recovery: ' || p_auth_reference || ' (Authorized by ' || p_admin_identity || ')'
    WHERE shop_id = p_shop_id AND is_active = true;

    -- 7. Register the Newly Audited Device Directly
    -- Note: Bootstrap remains permanently consumed in recharge_shop_bootstrap_state!
    INSERT INTO public.recharge_trusted_devices (
        device_id, shop_id, owner_uid, device_type, platform,
        device_model, public_key_pem, is_active, is_revoked,
        enrolled_at, last_verified_at
    ) VALUES (
        p_new_device_id, p_shop_id, p_owner_uid, p_new_device_type, p_new_platform,
        'Admin Emergency Recovered Device (' || p_auth_reference || ')',
        p_new_public_key_pem, true, false,
        v_now, v_now
    );

    -- 8. Record Immutable Financial & Security Audit Log
    INSERT INTO public.recharge_audit_logs (
        shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload, created_at
    ) VALUES (
        p_shop_id,
        'AUDIT_REC_' || gen_random_uuid(),
        'ADMIN_EMERGENCY_DEVICE_RECOVERY',
        p_admin_identity,
        p_new_device_id,
        p_auth_reference,
        jsonb_build_object(
            'authReference', p_auth_reference,
            'adminIdentity', p_admin_identity,
            'newDeviceId', p_new_device_id,
            'deviceType', p_new_device_type,
            'platform', p_new_platform
        ),
        v_now
    );

    RETURN jsonb_build_object(
        'success', true,
        'ticketId', p_auth_reference,
        'deviceId', p_new_device_id,
        'message', 'Emergency device recovered successfully. Bootstrap remains permanently locked.'
    );
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Device Conflict: Device ID already registered or quota conflict.'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. STRICT SECURITY PRIVILEGES: Revoke from PUBLIC, anon, and authenticated
-- Execution is granted EXCLUSIVELY to service_role (the internal backend server role)
REVOKE EXECUTE ON FUNCTION public.recharge_admin_issue_recovery_ticket(TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_admin_issue_recovery_ticket(TEXT, TEXT, TEXT, TEXT, JSONB) TO service_role;

REVOKE EXECUTE ON FUNCTION public.recharge_admin_emergency_device_recovery(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_admin_emergency_device_recovery(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;

-- 7. Update Administrative Synthetic Teardown Function
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
    DELETE FROM public.recharge_recovery_tickets WHERE shop_id = p_shop_id;
    DELETE FROM public.recharge_audit_logs WHERE shop_id = p_shop_id;
    DELETE FROM public.recharge_wallet_logs WHERE shop_id = p_shop_id;
    DELETE FROM public.recharge_admin_allowlist WHERE admin_identity LIKE 'ADMIN_TEST_%';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION public.recharge_admin_teardown_test_shop(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_admin_teardown_test_shop(TEXT) TO service_role;
