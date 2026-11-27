-- ============================================================================
-- SECURITY: only the Edge Function (service_role) may run recharge procedures
-- (security audit 2026-11-22). Thirteen older SECURITY DEFINER procedures
-- (recharge_process_debit, recharge_process_topup, recharge_update_commission_
-- control, ...) were still executable by the anon / authenticated roles, so
-- anyone holding the app's public anon key could call them through
-- /rest/v1/rpc and skip the Edge Function's owner and device checks.
-- The app only calls them through the Edge Function, which uses service_role.
-- ============================================================================

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname LIKE 'recharge\_%'
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
    END LOOP;
END $$;

-- Functions created later in this schema are not runnable by the public
-- roles unless a migration grants it on purpose.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
