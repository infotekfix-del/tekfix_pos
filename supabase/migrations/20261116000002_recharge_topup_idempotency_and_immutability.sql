-- ============================================================================
-- TEKFIX ERP - PHASE 16.4.10: TOP-UP IDEMPOTENCY, REPLAY SAFETY & LEDGER IMMUTABILITY
-- ZERO FLOATING POINT, ZERO OVERWRITES, STRICT INTEGER PAISE FIDELITY
-- ============================================================================

-- 1. Add device_id & normalized_ref to recharge_float_deposits
ALTER TABLE public.recharge_float_deposits
ADD COLUMN IF NOT EXISTS device_id TEXT NOT NULL DEFAULT 'DEV_UNSPECIFIED';

-- Add generated column for normalized reference number (trimmed and uppercase)
-- Enables strict unique index while safely ignoring legacy empty/null references
ALTER TABLE public.recharge_float_deposits
ADD COLUMN IF NOT EXISTS normalized_ref TEXT 
GENERATED ALWAYS AS (NULLIF(UPPER(TRIM(reference_no)), '')) STORED;

-- Create partial unique index on (shop_id, normalized_ref)
-- Prevents duplicate bank UTR deposits while allowing NULL/empty reference rows
CREATE UNIQUE INDEX IF NOT EXISTS idx_recharge_float_deposits_shop_utr 
ON public.recharge_float_deposits (shop_id, normalized_ref)
WHERE normalized_ref IS NOT NULL;

-- 2. Add device_id & reference_no to recharge_wallet_logs
ALTER TABLE public.recharge_wallet_logs
ADD COLUMN IF NOT EXISTS device_id TEXT NOT NULL DEFAULT 'DEV_UNSPECIFIED';

ALTER TABLE public.recharge_wallet_logs
ADD COLUMN IF NOT EXISTS reference_no TEXT;

-- 3. Enhanced Stored Procedure: Atomic Top-Up with Deterministic Idempotency & Replay Safety
CREATE OR REPLACE FUNCTION public.recharge_process_topup(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_amount_paise BIGINT,
    p_source TEXT,
    p_staff_id TEXT,
    p_staff_name TEXT,
    p_reference_id TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_device_id TEXT DEFAULT 'DEV_UNSPECIFIED'
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_ref TEXT := COALESCE(NULLIF(TRIM(p_reference_id), ''), gen_random_uuid()::text);
    v_existing RECORD;
    v_clean_ref TEXT := NULLIF(UPPER(TRIM(p_reference_id)), '');
BEGIN
    IF p_amount_paise <= 0 THEN
        RAISE EXCEPTION 'Top-up amount must be strictly positive: %', p_amount_paise;
    END IF;

    -- ========================================================================
    -- DETERMINISTIC IDEMPOTENCY CHECK
    -- Check if deposit_id or normalized UTR already exists for this shop
    -- ========================================================================
    SELECT * INTO v_existing FROM public.recharge_float_deposits
    WHERE shop_id = p_shop_id 
      AND (
          deposit_id = v_ref 
          OR (v_clean_ref IS NOT NULL AND normalized_ref = v_clean_ref)
      );

    IF FOUND THEN
        -- Parameter Integrity Verification: Replayed request must match exact original parameters
        IF v_existing.amount_paise != p_amount_paise THEN
            RAISE EXCEPTION 'Idempotency conflict: Reference % already registered with different amount (% paise vs % paise)', 
                p_reference_id, v_existing.amount_paise, p_amount_paise;
        END IF;

        IF v_existing.wallet_id != p_wallet_id THEN
            RAISE EXCEPTION 'Idempotency conflict: Reference % already registered for different wallet (% vs %)', 
                p_reference_id, v_existing.wallet_id, p_wallet_id;
        END IF;

        -- Retrieve current wallet balance to return idempotent confirmation (Zero extra balance deduction/credit)
        SELECT total_balance_paise, own_prepaid_balance_paise, distributor_credit_balance_paise 
        INTO v_wallet FROM public.recharge_wallets
        WHERE shop_id = p_shop_id AND wallet_id = v_existing.wallet_id;

        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'wallet_id', v_existing.wallet_id,
            'amount_paise', v_existing.amount_paise,
            'total_balance_paise', v_wallet.total_balance_paise,
            'own_prepaid_balance_paise', v_wallet.own_prepaid_balance_paise,
            'distributor_credit_balance_paise', v_wallet.distributor_credit_balance_paise,
            'reference_id', v_existing.deposit_id,
            'message', 'Idempotent replay: original topup confirmed without duplicate balance credit'
        );
    END IF;

    -- ========================================================================
    -- CONCURRENCY ROW LOCK: Serialize concurrent operations on this wallet
    -- ========================================================================
    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Auto-initialize shop wallets idempotently if not yet provisioned
        PERFORM public.recharge_initialize_shop_wallets(p_shop_id);

        SELECT * INTO v_wallet FROM public.recharge_wallets
        WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
        END IF;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;
    v_new_own := v_wallet.own_prepaid_balance_paise + p_amount_paise;
    v_balance_after := v_new_own + v_wallet.distributor_credit_balance_paise;

    -- Update balance
    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = v_new_own,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Ledger Log (Double-Entry Audit Record)
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, 
        staff_id, staff_name, device_id, reference_no, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, NULL, 'topup',
        p_amount_paise, v_balance_before, v_balance_after, COALESCE(p_description, 'Prepaid wallet top-up'), 
        p_staff_id, p_staff_name, COALESCE(p_device_id, 'DEV_UNSPECIFIED'), p_reference_id, now()
    );

    -- Float deposit record (Immutable Audit Voucher)
    INSERT INTO public.recharge_float_deposits (
        shop_id, deposit_id, wallet_id, amount_paise, source, deposited_by, 
        reference_no, notes, device_id, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, p_amount_paise, COALESCE(p_source, 'bank'), p_staff_id, 
        p_reference_id, p_description, COALESCE(p_device_id, 'DEV_UNSPECIFIED'), now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'wallet_id', p_wallet_id,
        'amount_paise', p_amount_paise,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'own_prepaid_balance_paise', v_new_own,
        'distributor_credit_balance_paise', v_wallet.distributor_credit_balance_paise,
        'total_balance_paise', v_balance_after,
        'reference_id', v_ref
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. Database-Level Immutability: Prevent UPDATE or DELETE on Financial Logs & Deposits
CREATE OR REPLACE FUNCTION public.recharge_prevent_ledger_tampering()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutability violation: Modification or deletion of historical audit entries in % is strictly forbidden.', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_float_deposit_tampering ON public.recharge_float_deposits;
CREATE TRIGGER trg_prevent_float_deposit_tampering
BEFORE UPDATE OR DELETE ON public.recharge_float_deposits
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ledger_tampering();

DROP TRIGGER IF EXISTS trg_prevent_wallet_logs_tampering ON public.recharge_wallet_logs;
CREATE TRIGGER trg_prevent_wallet_logs_tampering
BEFORE UPDATE OR DELETE ON public.recharge_wallet_logs
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ledger_tampering();
