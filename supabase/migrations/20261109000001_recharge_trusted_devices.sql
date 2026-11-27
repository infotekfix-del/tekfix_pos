-- ============================================================================
-- TEKFIX ERP - PHASE 13.6: RECHARGE TRUSTED DEVICES & CHALLENGES MIGRATION
-- ZERO-COST DATABASE-LEVEL STATE STORE FOR HARDWARE-BOUND RECHARGE SESSIONS
-- ============================================================================

-- 1. Trusted Devices Table
CREATE TABLE IF NOT EXISTS public.recharge_trusted_devices (
    device_id TEXT PRIMARY KEY,
    shop_id TEXT NOT NULL,
    owner_uid TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK (device_type IN ('mobile', 'laptop')),
    platform TEXT NOT NULL CHECK (platform IN ('android', 'windows')),
    device_model TEXT,
    public_key_pem TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_revoked BOOLEAN NOT NULL DEFAULT false,
    enrolled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    revocation_reason TEXT
);

-- Index on shop_id and active status for device quota queries
CREATE INDEX IF NOT EXISTS idx_recharge_trusted_devices_shop_active 
ON public.recharge_trusted_devices (shop_id, is_active, is_revoked);

-- Atomic Quota Enforcement: strictly 1 active device per type per shop (Race Condition Prevention)
CREATE UNIQUE INDEX IF NOT EXISTS uq_recharge_trusted_devices_quota 
ON public.recharge_trusted_devices (shop_id, device_type) 
WHERE (is_active = true AND is_revoked = false);

-- 2. Ephemeral Nonce Challenges Table
CREATE TABLE IF NOT EXISTS public.recharge_device_challenges (
    nonce TEXT PRIMARY KEY,
    shop_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    owner_uid TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed BOOLEAN NOT NULL DEFAULT false
);

-- Index on expiry for garbage collection and TTL verification
CREATE INDEX IF NOT EXISTS idx_recharge_challenges_expiry 
ON public.recharge_device_challenges (expires_at);

-- 3. Row-Level Security (Strict Zero Public Access)
ALTER TABLE public.recharge_trusted_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recharge_device_challenges ENABLE ROW LEVEL SECURITY;

-- Deny all direct public/anon access. Access is restricted exclusively to the
-- Edge Function backend using the internal server-side service role.
DROP POLICY IF EXISTS "Deny public access to trusted devices" ON public.recharge_trusted_devices;
CREATE POLICY "Deny public access to trusted devices" ON public.recharge_trusted_devices
    FOR ALL TO anon, authenticated
    USING (false);

DROP POLICY IF EXISTS "Deny public access to challenges" ON public.recharge_device_challenges;
CREATE POLICY "Deny public access to challenges" ON public.recharge_device_challenges
    FOR ALL TO anon, authenticated
    USING (false);

