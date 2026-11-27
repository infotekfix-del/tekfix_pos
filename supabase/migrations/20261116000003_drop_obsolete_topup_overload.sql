-- ============================================================================
-- Migration: 20261116000003_drop_obsolete_topup_overload.sql
-- Description: Drops the obsolete 8-argument overload of recharge_process_topup
--              retaining strictly the 9-argument version with device_id tracking,
--              canonical idempotency verification, and immutability protection.
-- ============================================================================

-- 1. Drop the legacy 8-argument overload created in 20261116000001
DROP FUNCTION IF EXISTS public.recharge_process_topup(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_amount_paise BIGINT,
    p_source TEXT,
    p_staff_id TEXT,
    p_staff_name TEXT,
    p_reference_id TEXT,
    p_description TEXT
);

-- 2. Ensure explicit grants on the authoritative 9-argument procedure
REVOKE ALL ON FUNCTION public.recharge_process_topup(
    TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.recharge_process_topup(
    TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO service_role;

COMMENT ON FUNCTION public.recharge_process_topup(
    TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) IS 'Authoritative atomic topup procedure with device_id tracking, normalized UTR idempotency, and deposit immutability.';
