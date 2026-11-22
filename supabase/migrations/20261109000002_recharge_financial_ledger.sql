-- ============================================================================
-- TEKFIX ERP - PHASE 14.9: COMPLETE POSTGRESQL RECHARGE ACCOUNTING SCHEMA
-- ZERO-COST DATABASE-LEVEL STATE STORE & FINANCIAL LEDGER
-- STRICT INTEGER PAISE ARITHMETIC - ZERO FLOATING POINT
-- ============================================================================

-- 1. Operator Master Wallets
CREATE TABLE IF NOT EXISTS public.recharge_wallets (
    shop_id TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    operator TEXT NOT NULL,
    sim_number TEXT NOT NULL DEFAULT '',
    own_prepaid_balance_paise BIGINT NOT NULL DEFAULT 0 CHECK (own_prepaid_balance_paise >= 0),
    distributor_credit_balance_paise BIGINT NOT NULL DEFAULT 0 CHECK (distributor_credit_balance_paise >= 0),
    total_balance_paise BIGINT GENERATED ALWAYS AS (own_prepaid_balance_paise + distributor_credit_balance_paise) STORED,
    last_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, wallet_id)
);

CREATE INDEX IF NOT EXISTS idx_recharge_wallets_shop 
ON public.recharge_wallets (shop_id);

-- 2. Financial Transactions Ledger
CREATE TABLE IF NOT EXISTS public.recharge_transactions (
    shop_id TEXT NOT NULL,
    txn_key TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    customer_phone TEXT NOT NULL,
    operator TEXT NOT NULL,
    service_type TEXT NOT NULL DEFAULT 'mobile_recharge',
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    funding_type TEXT NOT NULL CHECK (funding_type IN ('ownPrepaid', 'distributorCredit')),
    commission_earned_paise BIGINT NOT NULL DEFAULT 0 CHECK (commission_earned_paise >= 0),
    wallet_debited BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed', 'refunded', 'reversed')),
    device_id TEXT NOT NULL,
    owner_uid TEXT NOT NULL,
    business_date DATE NOT NULL,
    idempotency_key TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, txn_key),
    FOREIGN KEY (shop_id, wallet_id) REFERENCES public.recharge_wallets(shop_id, wallet_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_recharge_transactions_idempotency 
ON public.recharge_transactions (shop_id, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_recharge_transactions_date 
ON public.recharge_transactions (shop_id, business_date);

CREATE INDEX IF NOT EXISTS idx_recharge_transactions_wallet 
ON public.recharge_transactions (shop_id, wallet_id);

-- 3. Double-Entry Immutable Wallet Audit Logs
CREATE TABLE IF NOT EXISTS public.recharge_wallet_logs (
    shop_id TEXT NOT NULL,
    log_id TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    txn_key TEXT,
    entry_type TEXT NOT NULL CHECK (entry_type IN ('debit', 'credit', 'topup', 'float_deposit', 'distributor_refill', 'distributor_credit', 'reversal', 'adjustment', 'refund')),
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    balance_before_paise BIGINT NOT NULL CHECK (balance_before_paise >= 0),
    balance_after_paise BIGINT NOT NULL CHECK (balance_after_paise >= 0),
    description TEXT,
    staff_id TEXT,
    staff_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, log_id),
    FOREIGN KEY (shop_id, wallet_id) REFERENCES public.recharge_wallets(shop_id, wallet_id)
);

CREATE INDEX IF NOT EXISTS idx_recharge_wallet_logs_wallet 
ON public.recharge_wallet_logs (shop_id, wallet_id, created_at DESC);

-- 4. Distributor Profiles & Ledger
CREATE TABLE IF NOT EXISTS public.recharge_distributors (
    shop_id TEXT NOT NULL,
    distributor_id TEXT NOT NULL,
    name TEXT NOT NULL,
    phone TEXT NOT NULL,
    credit_limit_paise BIGINT NOT NULL DEFAULT 0 CHECK (credit_limit_paise >= 0),
    outstanding_balance_paise BIGINT NOT NULL DEFAULT 0 CHECK (outstanding_balance_paise >= 0),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, distributor_id)
);

CREATE TABLE IF NOT EXISTS public.recharge_distributor_ledger (
    shop_id TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    distributor_id TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    entry_type TEXT NOT NULL CHECK (entry_type IN ('credit_extended', 'settlement_payment')),
    balance_before_paise BIGINT NOT NULL CHECK (balance_before_paise >= 0),
    balance_after_paise BIGINT NOT NULL CHECK (balance_after_paise >= 0),
    payment_mode TEXT CHECK (payment_mode IN ('cash', 'bank_transfer', 'upi', 'cheque', 'credit_stock')),
    reference_id TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, entry_id),
    FOREIGN KEY (shop_id, distributor_id) REFERENCES public.recharge_distributors(shop_id, distributor_id)
);

CREATE INDEX IF NOT EXISTS idx_distributor_ledger_distributor 
ON public.recharge_distributor_ledger (shop_id, distributor_id, created_at DESC);

-- 5. Float Deposits & Capital Injections
CREATE TABLE IF NOT EXISTS public.recharge_float_deposits (
    shop_id TEXT NOT NULL,
    deposit_id TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    source TEXT NOT NULL CHECK (source IN ('bank', 'cash', 'owner_capital')),
    deposited_by TEXT NOT NULL,
    reference_no TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, deposit_id),
    FOREIGN KEY (shop_id, wallet_id) REFERENCES public.recharge_wallets(shop_id, wallet_id)
);

-- 6. Commissions Ledger
CREATE TABLE IF NOT EXISTS public.recharge_commissions (
    shop_id TEXT NOT NULL,
    commission_id TEXT NOT NULL,
    txn_key TEXT NOT NULL,
    operator TEXT NOT NULL,
    recharge_amount_paise BIGINT NOT NULL CHECK (recharge_amount_paise > 0),
    commission_paise BIGINT NOT NULL CHECK (commission_paise >= 0),
    business_date DATE NOT NULL,
    is_settled BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, commission_id)
);

CREATE INDEX IF NOT EXISTS idx_recharge_commissions_date 
ON public.recharge_commissions (shop_id, business_date);

-- 7. Customer Refunds
CREATE TABLE IF NOT EXISTS public.recharge_refunds (
    shop_id TEXT NOT NULL,
    refund_id TEXT NOT NULL,
    txn_key TEXT NOT NULL,
    customer_phone TEXT NOT NULL,
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    refund_mode TEXT NOT NULL CHECK (refund_mode IN ('cash', 'upi', 'credit_note')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
    reason TEXT NOT NULL,
    processed_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, refund_id)
);

-- 8. Operator Reversals & Clawbacks
CREATE TABLE IF NOT EXISTS public.recharge_reversals (
    shop_id TEXT NOT NULL,
    reversal_id TEXT NOT NULL,
    txn_key TEXT NOT NULL,
    wallet_id TEXT NOT NULL,
    amount_paise BIGINT NOT NULL CHECK (amount_paise > 0),
    commission_clawback_paise BIGINT NOT NULL DEFAULT 0 CHECK (commission_clawback_paise >= 0),
    operator_reference TEXT,
    reason TEXT NOT NULL,
    processed_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, reversal_id),
    FOREIGN KEY (shop_id, wallet_id) REFERENCES public.recharge_wallets(shop_id, wallet_id)
);

-- 9. Daily Collections & End-of-Day Reconciliation
CREATE TABLE IF NOT EXISTS public.daily_recharge_collections (
    shop_id TEXT NOT NULL,
    business_date DATE NOT NULL,
    total_sales_count INT NOT NULL DEFAULT 0 CHECK (total_sales_count >= 0),
    total_sales_paise BIGINT NOT NULL DEFAULT 0 CHECK (total_sales_paise >= 0),
    total_commission_paise BIGINT NOT NULL DEFAULT 0 CHECK (total_commission_paise >= 0),
    cash_collected_paise BIGINT NOT NULL DEFAULT 0 CHECK (cash_collected_paise >= 0),
    upi_collected_paise BIGINT NOT NULL DEFAULT 0 CHECK (upi_collected_paise >= 0),
    is_closed BOOLEAN NOT NULL DEFAULT false,
    closed_at TIMESTAMPTZ,
    PRIMARY KEY (shop_id, business_date)
);

CREATE TABLE IF NOT EXISTS public.recharge_daily_reconciliation (
    shop_id TEXT NOT NULL,
    recon_id TEXT NOT NULL,
    business_date DATE NOT NULL,
    calculated_balance_paise BIGINT NOT NULL CHECK (calculated_balance_paise >= 0),
    actual_physical_balance_paise BIGINT NOT NULL CHECK (actual_physical_balance_paise >= 0),
    discrepancy_paise BIGINT NOT NULL DEFAULT 0,
    status TEXT NOT NULL CHECK (status IN ('balanced', 'discrepancy', 'resolved')),
    reconciled_by TEXT NOT NULL,
    reconciled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, recon_id)
);

CREATE TABLE IF NOT EXISTS public.reconciliation_corrections (
    shop_id TEXT NOT NULL,
    correction_id TEXT NOT NULL,
    recon_id TEXT NOT NULL,
    business_date DATE NOT NULL,
    correction_amount_paise BIGINT NOT NULL,
    reason TEXT NOT NULL,
    approved_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, correction_id),
    FOREIGN KEY (shop_id, recon_id) REFERENCES public.recharge_daily_reconciliation(shop_id, recon_id)
);

-- 10. Centralized Immutable Recharge Audit Logs
CREATE TABLE IF NOT EXISTS public.recharge_audit_logs (
    shop_id TEXT NOT NULL,
    audit_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    actor_uid TEXT NOT NULL,
    device_id TEXT,
    entity_id TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shop_id, audit_id)
);

CREATE INDEX IF NOT EXISTS idx_recharge_audit_logs_event 
ON public.recharge_audit_logs (shop_id, event_type, created_at DESC);

-- ============================================================================
-- 11. ROW-LEVEL SECURITY (RLS) POLICIES
-- ============================================================================
ALTER TABLE public.recharge_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_wallet_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_distributors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_distributor_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_float_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_reversals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_recharge_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_daily_reconciliation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_audit_logs ENABLE ROW LEVEL SECURITY;

-- Deny all direct client access (anon and authenticated).
-- All reads and writes must be mediated by the Edge Function backend.
DO $$ 
DECLARE
    tbl TEXT;
BEGIN
    FOR tbl IN 
        SELECT unnest(ARRAY[
            'recharge_wallets',
            'recharge_transactions',
            'recharge_wallet_logs',
            'recharge_distributors',
            'recharge_distributor_ledger',
            'recharge_float_deposits',
            'recharge_commissions',
            'recharge_refunds',
            'recharge_reversals',
            'daily_recharge_collections',
            'recharge_daily_reconciliation',
            'reconciliation_corrections',
            'recharge_audit_logs'
        ])
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS "Deny direct public client access" ON public.%I;', tbl);
        EXECUTE format('CREATE POLICY "Deny direct public client access" ON public.%I FOR ALL TO anon, authenticated USING (false);', tbl);
    END LOOP;
END $$;

