-- ============================================================================
-- QUICK RECHARGE: DISTRIBUTOR CASH FOR THE SHOP'S DAILY REGISTER (2026-11-21)
-- The agent collects cash from the drawer in the evening. The Daily Register
-- must expect that outflow, otherwise it shows a false shortage.
--   recharge_acc_distributor_cash(shop, date): cash that left / came back for
--   one IST business date:
--     * distributor payments and agent settlements paid in CASH (-), using the
--       actual cash part of an agent settlement;
--     * agent recharge-amount returns received in CASH (+).
-- Read-only, additive. NOT TESTED (no Supabase CLI here).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recharge_acc_distributor_cash(p_shop_id TEXT, p_date DATE)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('success', true, 'date', p_date,
        'entries', COALESCE(jsonb_agg(x ORDER BY x->>'at'), '[]'::jsonb))
    FROM (
        SELECT jsonb_build_object(
            'kind', 'payment',
            'distributor_id', l.distributor_id,
            'operator', COALESCE(l.operator, ''),
            'cash_paise', -COALESCE(l.actual_payment_paise, l.amount_paise),
            'at', l.created_at,
            'reference_id', l.entry_id) AS x
        FROM public.recharge_distributor_ledger l
        WHERE l.shop_id = p_shop_id
          AND l.entry_type = 'settlement_payment'
          AND l.payment_mode = 'cash'
          AND COALESCE(l.payment_date, public.recharge_acc_ist_date(l.created_at)) = p_date
          AND COALESCE(l.actual_payment_paise, l.amount_paise) > 0
        UNION ALL
        SELECT jsonb_build_object(
            'kind', 'agent_return',
            'distributor_id', e.distributor_id,
            'operator', e.operator,
            'cash_paise', e.cash_bank_paise,
            'at', e.created_at,
            'reference_id', e.event_id)
        FROM public.recharge_acc_events e
        WHERE e.shop_id = p_shop_id AND e.kind = 'agent_return'
          AND e.payment_mode = 'cash' AND e.business_date = p_date
    ) q;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.recharge_acc_distributor_cash(text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_acc_distributor_cash(text, date) TO service_role;
