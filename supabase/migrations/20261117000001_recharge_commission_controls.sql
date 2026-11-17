-- ============================================================================
-- TEKFIX ERP - PHASE 17.1: RECHARGE COMMISSION CONTROLS (OWNER-CONTROLLED ON/OFF)
-- ============================================================================
-- 1. Operator Commission Controls Table (Air-Gapped Supabase PostgreSQL)
-- 2. Immutable Audit Log for Settings Changes
-- 3. Server-Authoritative Enforcement RPC in recharge_process_debit
-- ============================================================================

-- 1. Operator Commission Control Settings
CREATE TABLE IF NOT EXISTS public.recharge_commission_controls (
    shop_id TEXT NOT NULL,
    operator TEXT NOT NULL, -- 'AIRTEL', 'JIO', 'VI', 'BSNL', 'OTHER'
    is_enabled BOOLEAN NOT NULL DEFAULT true,
    margin_basis_points INT NOT NULL DEFAULT 300, -- e.g. 300 bps = 3.00%
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by_uid TEXT NOT NULL,
    PRIMARY KEY (shop_id, operator)
);

-- Deny direct public/authenticated client access (RLS)
ALTER TABLE public.recharge_commission_controls ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Deny direct client access to commission controls" ON public.recharge_commission_controls;
CREATE POLICY "Deny direct client access to commission controls" ON public.recharge_commission_controls 
FOR ALL TO anon, authenticated USING (false);

-- 2. Immutable Audit Log for Settings Changes
CREATE TABLE IF NOT EXISTS public.recharge_commission_control_audits (
    audit_id TEXT NOT NULL PRIMARY KEY,
    shop_id TEXT NOT NULL,
    operator TEXT NOT NULL,
    previous_enabled BOOLEAN NOT NULL,
    new_enabled BOOLEAN NOT NULL,
    previous_margin_basis_points INT NOT NULL,
    new_margin_basis_points INT NOT NULL,
    owner_uid TEXT NOT NULL,
    owner_name TEXT NOT NULL,
    device_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.recharge_commission_control_audits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Deny direct client access to commission control audits" ON public.recharge_commission_control_audits;
CREATE POLICY "Deny direct client access to commission control audits" ON public.recharge_commission_control_audits 
FOR ALL TO anon, authenticated USING (false);

CREATE INDEX IF NOT EXISTS idx_recharge_comm_control_audits_shop_op 
ON public.recharge_commission_control_audits (shop_id, operator, created_at DESC);

-- ============================================================================
-- 3. RPC: recharge_get_commission_controls
-- Returns all operator commission controls, auto-seeding defaults if missing
-- ============================================================================
CREATE OR REPLACE FUNCTION public.recharge_get_commission_controls(
    p_shop_id TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_count INT;
    v_results JSONB;
BEGIN
    -- Seed defaults if shop has no settings yet
    SELECT count(*) INTO v_count FROM public.recharge_commission_controls WHERE shop_id = p_shop_id;
    IF v_count = 0 THEN
        INSERT INTO public.recharge_commission_controls (shop_id, operator, is_enabled, margin_basis_points, updated_by_uid)
        VALUES 
            (p_shop_id, 'JIO', true, 300, 'system_init'),
            (p_shop_id, 'AIRTEL', true, 280, 'system_init'),
            (p_shop_id, 'VI', true, 350, 'system_init'),
            (p_shop_id, 'BSNL', true, 400, 'system_init'),
            (p_shop_id, 'OTHER', true, 300, 'system_init')
        ON CONFLICT (shop_id, operator) DO NOTHING;
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'shopId', shop_id,
            'operator', operator,
            'isEnabled', is_enabled,
            'marginBasisPoints', margin_basis_points,
            'marginPercent', (margin_basis_points::numeric / 100.0),
            'updatedAt', updated_at,
            'updatedByUid', updated_by_uid
        ) ORDER BY operator
    ) INTO v_results
    FROM public.recharge_commission_controls
    WHERE shop_id = p_shop_id;

    RETURN COALESCE(v_results, '[]'::jsonb);
END;
$function$;

-- ============================================================================
-- 4. RPC: recharge_update_commission_control
-- Updates operator settings with mandatory audit log & reason validation
-- ============================================================================
CREATE OR REPLACE FUNCTION public.recharge_update_commission_control(
    p_shop_id TEXT,
    p_operator TEXT,
    p_is_enabled BOOLEAN,
    p_margin_basis_points INT,
    p_owner_uid TEXT,
    p_owner_name TEXT,
    p_device_id TEXT,
    p_reason TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_norm_op TEXT;
    v_prev_enabled BOOLEAN := true;
    v_prev_bps INT := 300;
    v_new_bps INT;
    v_audit_id TEXT;
    v_result JSONB;
BEGIN
    v_norm_op := UPPER(TRIM(p_operator));
    IF v_norm_op NOT IN ('AIRTEL', 'JIO', 'VI', 'BSNL', 'OTHER') THEN
        RAISE EXCEPTION 'Invalid operator: %. Allowed: AIRTEL, JIO, VI, BSNL, OTHER', p_operator;
    END IF;

    IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
        RAISE EXCEPTION 'Reason for commission setting change is mandatory (min 5 characters)';
    END IF;

    -- Fetch current settings if present
    SELECT is_enabled, margin_basis_points INTO v_prev_enabled, v_prev_bps
    FROM public.recharge_commission_controls
    WHERE shop_id = p_shop_id AND operator = v_norm_op;

    IF NOT FOUND THEN
        -- Default basis points per operator
        CASE v_norm_op
            WHEN 'JIO' THEN v_prev_bps := 300;
            WHEN 'AIRTEL' THEN v_prev_bps := 280;
            WHEN 'VI' THEN v_prev_bps := 350;
            WHEN 'BSNL' THEN v_prev_bps := 400;
            ELSE v_prev_bps := 300;
        END CASE;
    END IF;

    -- Determine new basis points: preserve saved percentage if not explicitly provided or if turning OFF
    IF p_margin_basis_points IS NOT NULL AND p_margin_basis_points >= 0 AND p_margin_basis_points <= 2000 THEN
        v_new_bps := p_margin_basis_points;
    ELSE
        v_new_bps := v_prev_bps;
    END IF;

    -- 1. Insert Immutable Audit Log
    v_audit_id := 'AUD_COMM_' || gen_random_uuid()::text;
    INSERT INTO public.recharge_commission_control_audits (
        audit_id, shop_id, operator, previous_enabled, new_enabled,
        previous_margin_basis_points, new_margin_basis_points,
        owner_uid, owner_name, device_id, reason, created_at
    ) VALUES (
        v_audit_id, p_shop_id, v_norm_op, v_prev_enabled, p_is_enabled,
        v_prev_bps, v_new_bps,
        p_owner_uid, p_owner_name, p_device_id, trim(p_reason), now()
    );

    -- Mirror into general recharge_audit_logs
    INSERT INTO public.recharge_audit_logs (
        shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload, created_at
    ) VALUES (
        p_shop_id, v_audit_id, 'COMMISSION_CONTROL_UPDATED', p_owner_uid, p_device_id, v_norm_op,
        jsonb_build_object(
            'operator', v_norm_op,
            'previousEnabled', v_prev_enabled,
            'newEnabled', p_is_enabled,
            'previousMarginBps', v_prev_bps,
            'newMarginBps', v_new_bps,
            'reason', trim(p_reason),
            'ownerName', p_owner_name
        ),
        now()
    );

    -- 2. Upsert Settings Table
    INSERT INTO public.recharge_commission_controls (
        shop_id, operator, is_enabled, margin_basis_points, updated_at, updated_by_uid
    ) VALUES (
        p_shop_id, v_norm_op, p_is_enabled, v_new_bps, now(), p_owner_uid
    )
    ON CONFLICT (shop_id, operator) DO UPDATE SET
        is_enabled = EXCLUDED.is_enabled,
        margin_basis_points = EXCLUDED.margin_basis_points,
        updated_at = EXCLUDED.updated_at,
        updated_by_uid = EXCLUDED.updated_by_uid;

    RETURN jsonb_build_object(
        'success', true,
        'auditId', v_audit_id,
        'shopId', p_shop_id,
        'operator', v_norm_op,
        'isEnabled', p_is_enabled,
        'marginBasisPoints', v_new_bps,
        'marginPercent', (v_new_bps::numeric / 100.0)
    );
END;
$function$;

-- ============================================================================
-- 5. Updated recharge_process_debit with Server-Authoritative Commission Clamp
-- ============================================================================
CREATE OR REPLACE FUNCTION public.recharge_process_debit(
    p_shop_id text,
    p_wallet_id text,
    p_txn_key text,
    p_idempotency_key text,
    p_customer_phone text,
    p_operator text,
    p_service_type text,
    p_amount_paise bigint,
    p_funding_type text,
    p_commission_earned_paise bigint,
    p_business_date date,
    p_device_id text,
    p_owner_uid text,
    p_notes text DEFAULT NULL::text,
    p_payment_mode text DEFAULT 'Cash'::text,
    p_retail_amount_paise bigint DEFAULT NULL::bigint,
    p_cost_price_paise bigint DEFAULT NULL::bigint,
    p_party_key text DEFAULT NULL::text,
    p_party_name text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_new_dist BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_existing RECORD;
    v_retail_paise BIGINT;
    v_cost_paise BIGINT;
    v_norm_op TEXT;
    v_comm_enabled BOOLEAN := true;
    v_effective_comm_paise BIGINT;
BEGIN
    v_retail_paise := COALESCE(p_retail_amount_paise, p_amount_paise);
    v_effective_comm_paise := COALESCE(p_commission_earned_paise, 0);

    -- Server-Authoritative Commission Control Lookup
    v_norm_op := UPPER(TRIM(COALESCE(p_operator, 'OTHER')));
    SELECT is_enabled INTO v_comm_enabled 
    FROM public.recharge_commission_controls 
    WHERE shop_id = p_shop_id AND operator = v_norm_op;

    IF FOUND AND v_comm_enabled = false THEN
        -- When Commission is OFF: Force 0 commission and full retail cost
        v_effective_comm_paise := 0;
        v_cost_paise := v_retail_paise;
    ELSE
        -- When Commission is ON: calculate cost price
        v_cost_paise := COALESCE(p_cost_price_paise, v_retail_paise - v_effective_comm_paise);
    END IF;

    -- Fast-path Idempotency Check by (shop_id, idempotency_key)
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
                'commission_earned_paise', v_existing.commission_earned_paise,
                'total_balance_paise', v_balance_after,
                'payment_mode', v_existing.payment_mode
            );
        ELSE
            RAISE EXCEPTION 'Transaction already exists in incomplete state: %', v_existing.txn_key;
        END IF;
    END IF;

    -- Concurrency Row Lock: Serialize concurrent debit operations on this wallet
    SELECT * INTO v_wallet FROM public.recharge_wallets 
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id 
    FOR UPDATE;

    IF NOT FOUND THEN
        PERFORM public.recharge_initialize_shop_wallets(p_shop_id);

        SELECT * INTO v_wallet FROM public.recharge_wallets 
        WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id 
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
        END IF;
    END IF;

    -- Concurrency-Safe Idempotency Re-Check under FOR UPDATE lock
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
                'commission_earned_paise', v_existing.commission_earned_paise,
                'total_balance_paise', v_balance_after,
                'payment_mode', v_existing.payment_mode
            );
        ELSE
            RAISE EXCEPTION 'Transaction already exists in incomplete state: %', v_existing.txn_key;
        END IF;
    END IF;

    -- Evaluate Sufficient Funds based on debit amount (v_cost_paise)
    v_balance_before := v_wallet.total_balance_paise;
    IF p_funding_type = 'distributorCredit' THEN
        IF v_wallet.distributor_credit_balance_paise < v_cost_paise THEN
            RAISE EXCEPTION 'INSUFFICIENT_DISTRIBUTOR_CREDIT: Required % paise, available % paise', 
                v_cost_paise, v_wallet.distributor_credit_balance_paise;
        END IF;
        v_new_dist := v_wallet.distributor_credit_balance_paise - v_cost_paise;
        v_new_own := v_wallet.own_prepaid_balance_paise;
    ELSE
        IF v_wallet.own_prepaid_balance_paise < v_cost_paise THEN
            RAISE EXCEPTION 'INSUFFICIENT_OWN_PREPAID: Required % paise, available % paise', 
                v_cost_paise, v_wallet.own_prepaid_balance_paise;
        END IF;
        v_new_own := v_wallet.own_prepaid_balance_paise - v_cost_paise;
        v_new_dist := v_wallet.distributor_credit_balance_paise;
    END IF;

    v_balance_after := v_new_own + v_new_dist;

    -- Update Wallet Balance
    UPDATE public.recharge_wallets SET
        own_prepaid_balance_paise = v_new_own,
        distributor_credit_balance_paise = v_new_dist,
        total_balance_paise = v_balance_after,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Record Transaction
    INSERT INTO public.recharge_transactions (
        shop_id, txn_key, wallet_id, customer_phone, operator, service_type,
        amount_paise, funding_type, commission_earned_paise, wallet_debited,
        status, device_id, owner_uid, business_date, idempotency_key, notes,
        payment_mode, retail_amount_paise, cost_price_paise, party_key, party_name, created_at
    ) VALUES (
        p_shop_id, p_txn_key, p_wallet_id, p_customer_phone, p_operator, COALESCE(p_service_type, 'mobile_recharge'),
        v_cost_paise, p_funding_type, v_effective_comm_paise, true,
        'completed', p_device_id, p_owner_uid, p_business_date, p_idempotency_key, p_notes,
        COALESCE(p_payment_mode, 'Cash'), v_retail_paise, v_cost_paise, p_party_key, p_party_name, now()
    );

    -- Insert Double-Entry Ledger Entry
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, entry_type, amount_paise, funding_type,
        balance_before_paise, balance_after_paise, reference_id, description,
        staff_id, created_at
    ) VALUES (
        p_shop_id, gen_random_uuid()::text, p_wallet_id, 'RECHARGE_DEBIT', v_cost_paise, p_funding_type,
        v_balance_before, v_balance_after, p_txn_key, 
        format('Recharge %s: %s (Retail: %s, Comm: %s)', p_operator, p_customer_phone, v_retail_paise, v_effective_comm_paise),
        p_owner_uid, now()
    );

    -- Auto-record commission ONLY if commission was enabled and > 0
    IF v_effective_comm_paise > 0 THEN
        INSERT INTO public.recharge_commissions (
            shop_id, commission_id, txn_key, operator, recharge_amount_paise,
            commission_paise, business_date, is_settled, created_at
        ) VALUES (
            p_shop_id, gen_random_uuid()::text, p_txn_key, p_operator,
            v_retail_paise, v_effective_comm_paise, p_business_date, false, now()
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'txn_key', p_txn_key,
        'amount_paise', v_cost_paise,
        'retail_amount_paise', v_retail_paise,
        'commission_earned_paise', v_effective_comm_paise,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'total_balance_paise', v_balance_after,
        'payment_mode', COALESCE(p_payment_mode, 'Cash')
    );
END;
$function$;
