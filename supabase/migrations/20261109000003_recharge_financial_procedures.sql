-- ============================================================================
-- TEKFIX ERP - PHASE 14.9: FINANCIAL STORED PROCEDURES (ACID TRANSACTIONS)
-- PURE INTEGER PAISE ATOMICITY - ZERO PARTIAL WRITES
-- ============================================================================

-- 1. Atomic Wallet Debit with Idempotency & Row Locking
CREATE OR REPLACE FUNCTION public.recharge_process_debit(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_txn_key TEXT,
    p_idempotency_key TEXT,
    p_customer_phone TEXT,
    p_operator TEXT,
    p_service_type TEXT,
    p_amount_paise BIGINT,
    p_funding_type TEXT,
    p_commission_earned_paise BIGINT,
    p_business_date DATE,
    p_device_id TEXT,
    p_owner_uid TEXT,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_new_dist BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_existing RECORD;
BEGIN
    -- Idempotency Check by (shop_id, idempotency_key)
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            -- Retrieve current wallet balance to return
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
                'total_balance_paise', v_balance_after
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
        RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
    END IF;

    v_new_own := v_wallet.own_prepaid_balance_paise;
    v_new_dist := v_wallet.distributor_credit_balance_paise;
    v_balance_before := v_wallet.total_balance_paise;

    -- Negative Balance Prevention & Invariant Verification
    IF p_funding_type = 'distributorCredit' THEN
        IF v_new_dist < p_amount_paise THEN
            RAISE EXCEPTION 'Insufficient distributor credit balance: Available % paise, requested % paise', v_new_dist, p_amount_paise;
        END IF;
        v_new_dist := v_new_dist - p_amount_paise;
    ELSE
        IF v_new_own < p_amount_paise THEN
            RAISE EXCEPTION 'Insufficient own prepaid balance: Available % paise, requested % paise', v_new_own, p_amount_paise;
        END IF;
        v_new_own := v_new_own - p_amount_paise;
    END IF;

    v_balance_after := v_new_own + v_new_dist;

    -- Atomic Wallet Balance Update
    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = v_new_own,
        distributor_credit_balance_paise = v_new_dist,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Insert Transaction Record
    INSERT INTO public.recharge_transactions (
        shop_id, txn_key, wallet_id, customer_phone, operator, service_type,
        amount_paise, funding_type, commission_earned_paise, wallet_debited,
        status, device_id, owner_uid, business_date, idempotency_key, notes, created_at
    ) VALUES (
        p_shop_id, p_txn_key, p_wallet_id, p_customer_phone, p_operator, COALESCE(p_service_type, 'mobile_recharge'),
        p_amount_paise, p_funding_type, p_commission_earned_paise, true,
        'completed', p_device_id, p_owner_uid, p_business_date, p_idempotency_key, p_notes, now()
    );

    -- Insert Double-Entry Ledger Entry
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, created_at
    ) VALUES (
        p_shop_id, gen_random_uuid()::text, p_wallet_id, p_txn_key, 'debit',
        p_amount_paise, v_balance_before, v_balance_after, 'Recharge debit: ' || p_operator || ' (' || p_customer_phone || ')', p_owner_uid, now()
    );

    -- Auto-record commission if applicable
    IF p_commission_earned_paise > 0 THEN
        INSERT INTO public.recharge_commissions (
            shop_id, commission_id, txn_key, operator, recharge_amount_paise,
            commission_paise, business_date, is_settled, created_at
        ) VALUES (
            p_shop_id, gen_random_uuid()::text, p_txn_key, p_operator,
            p_amount_paise, p_commission_earned_paise, p_business_date, false, now()
        );
    END IF;

    -- Return JSON result
    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'txn_key', p_txn_key,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'total_balance_paise', v_balance_after,
        'own_prepaid_balance_paise', v_new_own,
        'distributor_credit_balance_paise', v_new_dist
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 2. Atomic Wallet Top-Up / Float Deposit
CREATE OR REPLACE FUNCTION public.recharge_process_topup(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_amount_paise BIGINT,
    p_source TEXT,
    p_staff_id TEXT,
    p_staff_name TEXT,
    p_reference_id TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_ref TEXT := COALESCE(p_reference_id, gen_random_uuid()::text);
BEGIN
    IF p_amount_paise <= 0 THEN
        RAISE EXCEPTION 'Top-up amount must be strictly positive: %', p_amount_paise;
    END IF;

    -- Lock wallet row
    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;
    v_new_own := v_wallet.own_prepaid_balance_paise + p_amount_paise;
    v_balance_after := v_new_own + v_wallet.distributor_credit_balance_paise;

    -- Update balance
    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = v_new_own,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Ledger Log
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, staff_name, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, NULL, 'topup',
        p_amount_paise, v_balance_before, v_balance_after, COALESCE(p_description, 'Prepaid wallet top-up'), p_staff_id, p_staff_name, now()
    );

    -- Float deposit record
    INSERT INTO public.recharge_float_deposits (
        shop_id, deposit_id, wallet_id, amount_paise, source, deposited_by, reference_no, notes, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, p_amount_paise, COALESCE(p_source, 'bank'), p_staff_id, p_reference_id, p_description, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'wallet_id', p_wallet_id,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'own_prepaid_balance_paise', v_new_own,
        'distributor_credit_balance_paise', v_wallet.distributor_credit_balance_paise,
        'reference_id', v_ref
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. Atomic Distributor Credit Stock Load
CREATE OR REPLACE FUNCTION public.recharge_process_distributor_load(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_distributor_id TEXT,
    p_amount_paise BIGINT,
    p_staff_id TEXT,
    p_staff_name TEXT,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_dist RECORD;
    v_new_dist_credit BIGINT;
    v_new_dist_outstanding BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_entry_id TEXT := gen_random_uuid()::text;
BEGIN
    IF p_amount_paise <= 0 THEN
        RAISE EXCEPTION 'Distributor load amount must be positive: %', p_amount_paise;
    END IF;

    -- Lock both wallet and distributor
    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet % not found', p_wallet_id;
    END IF;

    SELECT * INTO v_dist FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Distributor % not found', p_distributor_id;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;
    v_new_dist_credit := v_wallet.distributor_credit_balance_paise + p_amount_paise;
    v_balance_after := v_wallet.own_prepaid_balance_paise + v_new_dist_credit;
    v_new_dist_outstanding := v_dist.outstanding_balance_paise + p_amount_paise;

    -- Update Wallet
    UPDATE public.recharge_wallets
    SET distributor_credit_balance_paise = v_new_dist_credit,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Update Distributor Outstanding Debt
    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = v_new_dist_outstanding
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    -- Double entry in wallet logs
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, staff_name, created_at
    ) VALUES (
        p_shop_id, v_entry_id, p_wallet_id, 'distributor_credit',
        p_amount_paise, v_balance_before, v_balance_after, 'Credit loaded by ' || v_dist.name, p_staff_id, p_staff_name, now()
    );

    -- Record in distributor ledger
    INSERT INTO public.recharge_distributor_ledger (
        shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
        balance_before_paise, balance_after_paise, payment_mode, notes, created_at
    ) VALUES (
        p_shop_id, v_entry_id, p_distributor_id, p_wallet_id, p_amount_paise, 'credit_extended',
        v_dist.outstanding_balance_paise, v_new_dist_outstanding, 'credit_stock', p_notes, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'wallet_id', p_wallet_id,
        'distributor_id', p_distributor_id,
        'distributor_credit_balance_paise', v_new_dist_credit,
        'outstanding_balance_paise', v_new_dist_outstanding,
        'entry_id', v_entry_id
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. Atomic Distributor Settlement Payment
CREATE OR REPLACE FUNCTION public.recharge_process_distributor_settlement(
    p_shop_id TEXT,
    p_distributor_id TEXT,
    p_wallet_id TEXT,
    p_amount_paise BIGINT,
    p_payment_mode TEXT,
    p_staff_id TEXT,
    p_reference_id TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_dist RECORD;
    v_new_outstanding BIGINT;
    v_entry_id TEXT := gen_random_uuid()::text;
BEGIN
    IF p_amount_paise <= 0 THEN
        RAISE EXCEPTION 'Settlement payment amount must be positive: %', p_amount_paise;
    END IF;

    SELECT * INTO v_dist FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Distributor % not found', p_distributor_id;
    END IF;

    IF v_dist.outstanding_balance_paise < p_amount_paise THEN
        RAISE EXCEPTION 'Settlement payment % exceeds outstanding balance %', p_amount_paise, v_dist.outstanding_balance_paise;
    END IF;

    v_new_outstanding := v_dist.outstanding_balance_paise - p_amount_paise;

    -- Update outstanding balance
    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = v_new_outstanding
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    -- Record in distributor ledger
    INSERT INTO public.recharge_distributor_ledger (
        shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
        balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at
    ) VALUES (
        p_shop_id, v_entry_id, p_distributor_id, p_wallet_id, p_amount_paise, 'settlement_payment',
        v_dist.outstanding_balance_paise, v_new_outstanding, p_payment_mode, p_reference_id, p_notes, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'distributor_id', p_distributor_id,
        'settled_amount_paise', p_amount_paise,
        'outstanding_balance_paise', v_new_outstanding,
        'entry_id', v_entry_id
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 5. Atomic Customer Refund with Wallet Restitution
CREATE OR REPLACE FUNCTION public.recharge_process_refund(
    p_shop_id TEXT,
    p_txn_key TEXT,
    p_refund_mode TEXT,
    p_reason TEXT,
    p_staff_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_wallet RECORD;
    v_refund_id TEXT := gen_random_uuid()::text;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
BEGIN
    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % not found', p_txn_key;
    END IF;

    IF v_txn.status = 'refunded' THEN
        RAISE EXCEPTION 'Transaction % already refunded', p_txn_key;
    END IF;

    IF v_txn.status = 'reversed' THEN
        RAISE EXCEPTION 'Transaction % is already reversed; cannot refund an already reversed transaction', p_txn_key;
    END IF;

    IF v_txn.status != 'completed' THEN
        RAISE EXCEPTION 'Transaction % in status % cannot be refunded. Only completed transactions can be refunded.', p_txn_key, v_txn.status;
    END IF;

    -- Lock Wallet
    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Associated wallet % not found', v_txn.wallet_id;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;

    -- Restitute wallet balance based on funding type
    IF v_txn.funding_type = 'distributorCredit' THEN
        UPDATE public.recharge_wallets
        SET distributor_credit_balance_paise = distributor_credit_balance_paise + v_txn.amount_paise,
            last_updated_at = now()
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
    ELSE
        UPDATE public.recharge_wallets
        SET own_prepaid_balance_paise = own_prepaid_balance_paise + v_txn.amount_paise,
            last_updated_at = now()
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
    END IF;

    v_balance_after := v_balance_before + v_txn.amount_paise;

    -- Update Transaction status
    UPDATE public.recharge_transactions
    SET status = 'refunded'
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    -- Insert Refund Record
    INSERT INTO public.recharge_refunds (
        shop_id, refund_id, txn_key, customer_phone, amount_paise,
        refund_mode, status, reason, processed_by, created_at
    ) VALUES (
        p_shop_id, v_refund_id, p_txn_key, v_txn.customer_phone, v_txn.amount_paise,
        p_refund_mode, 'completed', p_reason, p_staff_id, now()
    );

    -- Log to wallet ledger
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, created_at
    ) VALUES (
        p_shop_id, v_refund_id, v_txn.wallet_id, p_txn_key, 'refund',
        v_txn.amount_paise, v_balance_before, v_balance_after, 'Refund for txn: ' || p_txn_key, p_staff_id, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'refund_id', v_refund_id,
        'txn_key', p_txn_key,
        'amount_paise', v_txn.amount_paise,
        'balance_after_paise', v_balance_after
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 6. Atomic Operator Reversal & Commission Clawback
CREATE OR REPLACE FUNCTION public.recharge_process_reversal(
    p_shop_id TEXT,
    p_txn_key TEXT,
    p_operator_reference TEXT,
    p_reason TEXT,
    p_staff_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_wallet RECORD;
    v_reversal_id TEXT := gen_random_uuid()::text;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
BEGIN
    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % not found', p_txn_key;
    END IF;

    IF v_txn.status = 'reversed' THEN
        RAISE EXCEPTION 'Transaction % already reversed', p_txn_key;
    END IF;

    IF v_txn.status = 'refunded' THEN
        RAISE EXCEPTION 'Transaction % is already refunded; cannot reverse an already refunded transaction', p_txn_key;
    END IF;

    IF v_txn.status != 'completed' THEN
        RAISE EXCEPTION 'Transaction % in status % cannot be reversed. Only completed transactions can be reversed.', p_txn_key, v_txn.status;
    END IF;

    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Associated wallet % not found', v_txn.wallet_id;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;

    -- Return money to wallet
    IF v_txn.funding_type = 'distributorCredit' THEN
        UPDATE public.recharge_wallets
        SET distributor_credit_balance_paise = distributor_credit_balance_paise + v_txn.amount_paise,
            last_updated_at = now()
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
    ELSE
        UPDATE public.recharge_wallets
        SET own_prepaid_balance_paise = own_prepaid_balance_paise + v_txn.amount_paise,
            last_updated_at = now()
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
    END IF;

    v_balance_after := v_balance_before + v_txn.amount_paise;

    -- Mark transaction reversed
    UPDATE public.recharge_transactions
    SET status = 'reversed'
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    -- Void / clawback commission
    UPDATE public.recharge_commissions
    SET is_settled = false,
        commission_paise = 0
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    -- Record reversal
    INSERT INTO public.recharge_reversals (
        shop_id, reversal_id, txn_key, wallet_id, amount_paise,
        commission_clawback_paise, operator_reference, reason, processed_by, created_at
    ) VALUES (
        p_shop_id, v_reversal_id, p_txn_key, v_txn.wallet_id, v_txn.amount_paise,
        v_txn.commission_earned_paise, p_operator_reference, p_reason, p_staff_id, now()
    );

    -- Log to wallet ledger
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, created_at
    ) VALUES (
        p_shop_id, v_reversal_id, v_txn.wallet_id, p_txn_key, 'reversal',
        v_txn.amount_paise, v_balance_before, v_balance_after, 'Operator reversal: ' || p_reason, p_staff_id, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'reversal_id', v_reversal_id,
        'txn_key', p_txn_key,
        'amount_paise', v_txn.amount_paise,
        'commission_clawback_paise', v_txn.commission_earned_paise,
        'balance_after_paise', v_balance_after
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 7. Atomic End-of-Day Daily Reconciliation
CREATE OR REPLACE FUNCTION public.recharge_process_daily_reconciliation(
    p_shop_id TEXT,
    p_business_date DATE,
    p_actual_physical_balance_paise BIGINT,
    p_reconciled_by TEXT
) RETURNS JSONB AS $$
DECLARE
    v_calc_balance BIGINT := 0;
    v_discrepancy BIGINT := 0;
    v_status TEXT := 'balanced';
    v_recon_id TEXT := gen_random_uuid()::text;
    v_existing RECORD;
BEGIN
    -- Check if already reconciled
    SELECT * INTO v_existing FROM public.recharge_daily_reconciliation
    WHERE shop_id = p_shop_id AND business_date = p_business_date;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'recon_id', v_existing.recon_id,
            'status', v_existing.status,
            'is_existing', true,
            'discrepancy_paise', v_existing.discrepancy_paise
        );
    END IF;

    -- Sum all active wallet balances for the shop
    SELECT COALESCE(SUM(total_balance_paise), 0) INTO v_calc_balance
    FROM public.recharge_wallets
    WHERE shop_id = p_shop_id;

    v_discrepancy := p_actual_physical_balance_paise - v_calc_balance;

    IF v_discrepancy != 0 THEN
        v_status := 'discrepancy';
    END IF;

    INSERT INTO public.recharge_daily_reconciliation (
        shop_id, recon_id, business_date, calculated_balance_paise,
        actual_physical_balance_paise, discrepancy_paise, status, reconciled_by, reconciled_at
    ) VALUES (
        p_shop_id, v_recon_id, p_business_date, v_calc_balance,
        p_actual_physical_balance_paise, v_discrepancy, v_status, p_reconciled_by, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'recon_id', v_recon_id,
        'business_date', p_business_date,
        'calculated_balance_paise', v_calc_balance,
        'actual_physical_balance_paise', p_actual_physical_balance_paise,
        'discrepancy_paise', v_discrepancy,
        'status', v_status
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

