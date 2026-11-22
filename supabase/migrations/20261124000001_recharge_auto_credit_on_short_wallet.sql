-- ============================================================================
-- QUICK RECHARGE: AUTO CREDIT ON SHORT WALLET (owner decision 2026-11-20)
-- Operators (e.g. Airtel) auto-refill the SIM on credit when it runs low, so a
-- recharge must never be rejected for a short system balance. recharge_process_debit
-- now uses own + credit pockets together, and records any shortfall as an
-- automatic distributor credit (wallet credit load + distributor payable) first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recharge_process_debit(p_shop_id text, p_wallet_id text, p_txn_key text, p_idempotency_key text, p_customer_phone text, p_operator text, p_service_type text, p_amount_paise bigint, p_funding_type text, p_commission_earned_paise bigint, p_business_date date, p_device_id text, p_owner_uid text, p_notes text DEFAULT NULL::text, p_payment_mode text DEFAULT 'Cash'::text, p_retail_amount_paise bigint DEFAULT NULL::bigint, p_cost_price_paise bigint DEFAULT NULL::bigint, p_party_key text DEFAULT NULL::text, p_party_name text DEFAULT NULL::text)
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
    v_own_avail BIGINT;
    v_dist_avail BIGINT;
    v_take_own BIGINT;
    v_take_dist BIGINT;
    v_auto_credit BIGINT := 0;
    v_auto_dist_id TEXT;
    v_auto_key TEXT;
    v_auto_dues_before BIGINT;
    v_acc_op TEXT;
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
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

    -- Evaluate funds (owner rule 2026-11-20): own + credit pockets together.
    -- If the wallet is short, the operator auto-refills the SIM on credit, so
    -- the shortfall is recorded as an automatic distributor credit (payable)
    -- before the debit. The recharge is never rejected for a short balance.
    v_balance_before := v_wallet.total_balance_paise;
    v_own_avail := v_wallet.own_prepaid_balance_paise;
    v_dist_avail := v_wallet.distributor_credit_balance_paise;

    IF v_own_avail + v_dist_avail < v_cost_paise THEN
        v_auto_credit := v_cost_paise - (v_own_avail + v_dist_avail);
        v_acc_op := lower(TRIM(COALESCE(p_operator, '')));
        v_auto_key := 'AUTOCR_' || p_idempotency_key;

        -- Distributor: the one last used for this operator, else an active one named for it
        SELECT l.distributor_id INTO v_auto_dist_id
        FROM public.recharge_distributor_ledger l
        JOIN public.recharge_distributors d
          ON d.shop_id = l.shop_id AND d.distributor_id = l.distributor_id AND d.is_active
        WHERE l.shop_id = p_shop_id AND (l.operator = v_acc_op OR l.wallet_id = p_wallet_id)
        ORDER BY l.created_at DESC LIMIT 1;
        IF v_auto_dist_id IS NULL THEN
            SELECT distributor_id INTO v_auto_dist_id
            FROM public.recharge_distributors
            WHERE shop_id = p_shop_id AND is_active
              AND (lower(COALESCE(default_operator, '')) = v_acc_op
                   OR upper(distributor_id) LIKE '%' || upper(v_acc_op) || '%')
            ORDER BY (lower(COALESCE(default_operator, '')) = v_acc_op) DESC, created_at LIMIT 1;
        END IF;
        IF v_auto_dist_id IS NULL THEN
            RAISE EXCEPTION 'AUTO_CREDIT_NO_DISTRIBUTOR: no active distributor for % (wallet short by % paise)',
                p_operator, v_auto_credit;
        END IF;

        PERFORM 1 FROM public.recharge_distributors
        WHERE shop_id = p_shop_id AND distributor_id = v_auto_dist_id FOR UPDATE;
        v_auto_dues_before := public.recharge_acc_account_field(p_shop_id, v_auto_dist_id, v_acc_op, 'balance_paise');
        v_prev := public.recharge_acc_last_closing(p_shop_id, v_acc_op);
        v_pid := public.recharge_acc_period_id(v_acc_op, v_prev.created_at);

        -- Wallet log: a credit load (counted in period movements, not a classification)
        INSERT INTO public.recharge_wallet_logs (
            shop_id, log_id, wallet_id, entry_type, amount_paise,
            balance_before_paise, balance_after_paise, description, staff_id, created_at, device_id,
            adjustment_sign, period_id, idempotency_key, reason, distributor_id, business_date, reference_no
        ) VALUES (
            p_shop_id, v_auto_key, p_wallet_id, 'distributor_credit', v_auto_credit,
            v_balance_before, v_balance_before + v_auto_credit,
            format('Auto credit (%s auto-refill) for recharge %s', p_operator, p_txn_key),
            p_owner_uid, now(), COALESCE(p_device_id, 'DEV_UNSPECIFIED'),
            1, v_pid, v_auto_key, 'Operator auto-refill: wallet short for recharge', v_auto_dist_id,
            public.recharge_acc_ist_date(now()), p_txn_key
        );

        -- Payable to the distributor
        INSERT INTO public.recharge_distributor_ledger (
            shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
            balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at,
            operator, idempotency_key, signed_balance_before_paise, signed_balance_after_paise, created_by
        ) VALUES (
            p_shop_id, v_auto_key, v_auto_dist_id, p_wallet_id, v_auto_credit, 'credit_extended',
            GREATEST(v_auto_dues_before, 0), GREATEST(v_auto_dues_before + v_auto_credit, 0), 'credit_stock',
            p_txn_key, 'AUTO CREDIT: operator auto-refill for recharge ' || p_txn_key, now(),
            v_acc_op, v_auto_key, v_auto_dues_before, v_auto_dues_before + v_auto_credit, p_owner_uid
        );

        UPDATE public.recharge_distributors
        SET outstanding_balance_paise = outstanding_balance_paise + v_auto_credit
        WHERE shop_id = p_shop_id AND distributor_id = v_auto_dist_id;

        INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
        VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_AUTO_CREDIT', p_owner_uid, p_device_id, v_auto_key,
            jsonb_build_object('operator', v_acc_op, 'distributor', v_auto_dist_id, 'amount', v_auto_credit,
                'recharge', p_txn_key, 'wallet_before', v_balance_before, 'recharge_cost', v_cost_paise));

        v_dist_avail := v_dist_avail + v_auto_credit;
        v_balance_before := v_balance_before + v_auto_credit;
    END IF;

    -- Take from the selected pocket first, the rest from the other pocket
    IF p_funding_type = 'distributorCredit' THEN
        v_take_dist := LEAST(v_dist_avail, v_cost_paise);
        v_take_own := v_cost_paise - v_take_dist;
    ELSE
        v_take_own := LEAST(v_own_avail, v_cost_paise);
        v_take_dist := v_cost_paise - v_take_own;
    END IF;
    v_new_own := v_own_avail - v_take_own;
    v_new_dist := v_dist_avail - v_take_dist;

    v_balance_after := v_new_own + v_new_dist;

    -- Update Wallet Balance
    UPDATE public.recharge_wallets SET
        own_prepaid_balance_paise = v_new_own,
        distributor_credit_balance_paise = v_new_dist,
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
        shop_id, log_id, wallet_id, txn_key, entry_type, amount_paise,
        balance_before_paise, balance_after_paise, description,
        staff_id, device_id, created_at
    ) VALUES (
        p_shop_id, gen_random_uuid()::text, p_wallet_id, p_txn_key, 'debit', v_cost_paise,
        v_balance_before, v_balance_after,
        format('Recharge %s: %s [%s] (Retail: %s, Comm: %s)', p_operator, p_customer_phone, p_funding_type, v_retail_paise, v_effective_comm_paise),
        p_owner_uid, COALESCE(p_device_id, 'DEV_UNSPECIFIED'), now()
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
        'payment_mode', COALESCE(p_payment_mode, 'Cash'),
        'auto_credit_paise', v_auto_credit,
        'auto_credit_distributor_id', v_auto_dist_id
    );
END;
$function$;
