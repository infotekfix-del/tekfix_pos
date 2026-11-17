// ============================================================================
// TEKFIX ERP - PHASE 14.9.2: SECURE SUPABASE RECHARGE BRIDGE EDGE FUNCTION
// UNIFIED HARDWARE-BOUND ECDSA P-256 ZERO-TRUST SECURITY PERIMETER
// EVERY FINANCIAL MODIFICATION ENDPOINT REQUIRES TRUSTED DEVICE + ECDSA SIGNATURE
// ============================================================================
//
// Endpoints Supported:
// 1. POST /request-challenge       - Generates 128-bit CSPRNG challenge nonce (300s TTL)
// 2. POST /register-device         - Enrolls owner mobile or laptop (max 2 active quota, cross-signed)
// 3. POST /revoke-device           - Revokes registered trusted device
// 4. POST /process-debit           - Atomic wallet debit with full hardware ECDSA verification
// 5. POST /process-topup           - Atomic float deposit with full hardware ECDSA verification
// 6. POST /process-distributor-load - Atomic distributor load with full hardware ECDSA verification
// 7. POST /process-distributor-settlement - Atomic settlement with full hardware ECDSA verification
// 8. POST /process-refund          - Atomic refund with full hardware ECDSA verification
// 9. POST /process-reversal        - Atomic reversal with full hardware ECDSA verification
// 10. POST /process-reconciliation - Atomic reconciliation with full hardware ECDSA verification
// 11. POST /get-wallet             - Authoritative wallet balance read (Owner authenticated)
// 12. POST /get-distributor        - Authoritative distributor balance read (Owner authenticated)
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@4.14.4";

// ============================================================================
// ENVIRONMENT & IDENTITY MODE CONFIGURATION (STRICT FAIL-CLOSED)
// ============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// Identity Modes: Must be explicitly configured.
const RAW_STAGING_MODE = Deno.env.get("STAGING_IDENTITY_MODE");
const STAGING_IDENTITY_MODE = RAW_STAGING_MODE === "true";
const STAGING_JWT_SECRET = Deno.env.get("STAGING_JWT_SECRET") || "";
const STAGING_BOOTSTRAP_SECRET = Deno.env.get("STAGING_BOOTSTRAP_SECRET") || "";
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") || "";
const FIREBASE_SERVICE_ACCOUNT_B64 = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_B64") || "";
const GOOGLE_JWKS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

function constantTimeCompare(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const aBuf = new TextEncoder().encode(a);
  const bBuf = new TextEncoder().encode(b);
  if (aBuf.length !== bBuf.length) return false;
  let diff = 0;
  for (let i = 0; i < aBuf.length; i++) {
    diff |= aBuf[i] ^ bBuf[i];
  }
  return diff === 0;
}

// Synthetic Staging Shop Owners (Strict Whitelist: Zero Firestore Lookups)
const STAGING_SHOP_OWNERS: Readonly<Record<string, readonly string[]>> = Object.freeze({
  "shop_staging_001": Object.freeze(["owner_staging_001", "owner_staging_backup"]),
  "shop_test_149": Object.freeze(["owner_test_149", "test_owner_uid"]),
});

// Enforce configuration integrity on startup/first load
function validateEnvironmentConfiguration(): void {
  // Fail-closed gate: STAGING_IDENTITY_MODE must be explicitly "true" or "false"
  if (RAW_STAGING_MODE !== "true" && RAW_STAGING_MODE !== "false") {
    throw new Error(
      `FATAL SECURITY CONFIGURATION: STAGING_IDENTITY_MODE must be explicitly set to "true" or "false" (received: "${RAW_STAGING_MODE ?? "undefined"}"). Server refused to start.`
    );
  }

  if (STAGING_IDENTITY_MODE) {
    // Staging mode validation (Option A HMAC identity): does NOT require production Firebase ID
    if (!STAGING_JWT_SECRET || new TextEncoder().encode(STAGING_JWT_SECRET).length < 32) {
      throw new Error(
        "FATAL SECURITY CONFIGURATION: STAGING_IDENTITY_MODE is true, but STAGING_JWT_SECRET is missing or has insufficient entropy (< 32 bytes / 256 bits). Server refused to start."
      );
    }
  } else {
    // Production Mode: Must have FIREBASE_PROJECT_ID explicitly set and strictly match tekfix-45b38
    if (!FIREBASE_PROJECT_ID) {
      throw new Error(
        "FATAL SECURITY CONFIGURATION: Production identity mode active, but FIREBASE_PROJECT_ID is not configured. Server refused to start."
      );
    }
    if (FIREBASE_PROJECT_ID !== "tekfix-45b38") {
      throw new Error(
        `FATAL SECURITY CONFIGURATION: Production FIREBASE_PROJECT_ID must strictly equal "tekfix-45b38" (received: "${FIREBASE_PROJECT_ID}"). Server refused to start.`
      );
    }
  }
}

// Immediate startup evaluation
try {
  validateEnvironmentConfiguration();
} catch (e) {
  console.error("[recharge-bridge:startup_validation_failed]", e);
}

// Supabase DB Client
const supabase = (SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY)
  ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  : null;

// ============================================================================
// 1. BOUNDED JWKS CACHE & FIREBASE TOKEN VALIDATION
// ============================================================================

interface JWKCache {
  keys: Map<string, any>;
  expiresAt: number;
  lastFetchTime: number;
}

const jwkCache: JWKCache = {
  keys: new Map(),
  expiresAt: 0,
  lastFetchTime: 0,
};

const MIN_REFETCH_INTERVAL_MS = 60 * 1000;

async function getGooglePublicKey(kid: string, forceRefetch = false): Promise<any> {
  const now = Date.now();
  if (!forceRefetch && now < jwkCache.expiresAt && jwkCache.keys.has(kid)) {
    return jwkCache.keys.get(kid);
  }

  if (forceRefetch && (now - jwkCache.lastFetchTime) < MIN_REFETCH_INTERVAL_MS) {
    if (jwkCache.keys.has(kid)) return jwkCache.keys.get(kid);
    throw new Error(`Rate limit exceeded for JWKS refetch. Key ID "${kid}" remains unknown.`);
  }

  const response = await fetch(GOOGLE_JWKS_URL);
  if (!response.ok) {
    throw new Error(`Failed to fetch Google JWKS: ${response.statusText}`);
  }

  const cacheControl = response.headers.get("Cache-Control") || "";
  const maxAgeMatch = cacheControl.match(/max-age=(\d+)/);
  const ttlSeconds = maxAgeMatch ? parseInt(maxAgeMatch[1], 10) : 21600;

  const data = await response.json();
  jwkCache.keys.clear();
  for (const key of data.keys) {
    jwkCache.keys.set(key.kid, key);
  }
  jwkCache.expiresAt = now + (ttlSeconds * 1000);
  jwkCache.lastFetchTime = now;

  if (!jwkCache.keys.has(kid)) {
    throw new Error(`Key ID "${kid}" not found in Google JWKS even after live refetch.`);
  }

  return jwkCache.keys.get(kid);
}

async function verifyFirebaseIdToken(token: string): Promise<jose.JWTPayload> {
  validateEnvironmentConfiguration();

  // --------------------------------------------------------------------------
  // OPTION A: STAGING IDENTITY MODE (Strict Air-Gapped HMAC Verification)
  // --------------------------------------------------------------------------
  if (STAGING_IDENTITY_MODE) {
    const secretBytes = new TextEncoder().encode(STAGING_JWT_SECRET);
    if (secretBytes.length < 32) {
      throw new Error("Staging JWT secret entropy violation (< 32 bytes).");
    }

    // Inspect header for algorithm: ONLY HS256 is permitted for staging HMAC
    const header = jose.decodeProtectedHeader(token);
    if (!header.alg || header.alg !== "HS256") {
      throw new Error(`Algorithm confusion rejected: Staging tokens must use HS256 exclusively (received: ${header.alg}).`);
    }

    // Cryptographic verification with strict claims enforcement
    const { payload } = await jose.jwtVerify(token, secretBytes, {
      algorithms: ["HS256"],
      issuer: "tekfix-staging-identity",
      audience: "tekfix-staging-audience",
      currentDate: new Date(),
    });

    if (!payload.sub || typeof payload.sub !== "string" || payload.sub.trim().length === 0) {
      throw new Error("Invalid staging ID token: Missing or empty subject claim (sub).");
    }

    return payload;
  }

  // --------------------------------------------------------------------------
  // PRODUCTION IDENTITY MODE (Strict Google Cloud RS256 Verification)
  // --------------------------------------------------------------------------
  if (!FIREBASE_PROJECT_ID) {
    throw new Error("Server configuration error: FIREBASE_PROJECT_ID must be set in production mode.");
  }

  const decodedHeader = jose.decodeProtectedHeader(token);
  if (!decodedHeader.kid) {
    throw new Error("Token missing 'kid' in header.");
  }
  if (decodedHeader.alg !== "RS256") {
    throw new Error(`Unsupported token algorithm "${decodedHeader.alg}". Only RS256 is permitted in production.`);
  }

  let jwk: any;
  try {
    jwk = await getGooglePublicKey(decodedHeader.kid, false);
  } catch (_e) {
    jwk = await getGooglePublicKey(decodedHeader.kid, true);
  }

  const publicKey = await jose.importJWK(jwk, "RS256");
  const { payload } = await jose.jwtVerify(token, publicKey, {
    algorithms: ["RS256"],
    issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
    audience: FIREBASE_PROJECT_ID,
  });

  return payload;
}

// ============================================================================
// 2. OWNER AUTHORIZATION CHECK VIA FIRESTORE READ-ONLY IDENTITY VERIFICATION
// ============================================================================

async function verifyShopOwner(
  shopId: string,
  callerUid: string,
  rawToken: string,
  tokenRole?: string
): Promise<boolean> {
  // STRICT OWNER ROLE VALIDATION: If token carries a role claim, it MUST be strictly "owner"
  // Admin, cashier, staff, manager, viewer, etc. are strictly denied.
  if (tokenRole && tokenRole.toLowerCase() !== "owner") {
    console.warn(`[verifyShopOwner] Access denied: Token role "${tokenRole}" is not authorized. STRICT OWNER ONLY.`);
    return false;
  }

  // --------------------------------------------------------------------------
  // OPTION A: STAGING IDENTITY MODE (Strict Whitelist - Zero Firestore Calls)
  // --------------------------------------------------------------------------
  if (STAGING_IDENTITY_MODE) {
    if (!shopId || !callerUid) {
      return false;
    }

    const authorizedOwners = STAGING_SHOP_OWNERS[shopId];
    if (!authorizedOwners) {
      console.warn(`[verifyShopOwner] Access denied: Unknown staging shop "${shopId}".`);
      return false;
    }

    const isAuthorized = authorizedOwners.includes(callerUid);
    if (!isAuthorized) {
      console.warn(`[verifyShopOwner] Access denied: Caller "${callerUid}" is not an authorized owner for shop "${shopId}".`);
      return false;
    }

    return true;
  }

  // --------------------------------------------------------------------------
  // PRODUCTION IDENTITY MODE (Read-Only Production Firestore REST Call)
  // --------------------------------------------------------------------------
  if (!FIREBASE_PROJECT_ID) {
    console.error("[verifyShopOwner] Production error: FIREBASE_PROJECT_ID is not configured.");
    return false;
  }

  // Condition 1: Fetch and verify the Shop document
  const firestoreShopUrl = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents/shops/${shopId}`;
  const response = await fetch(firestoreShopUrl, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!response.ok) {
    console.error(`[verifyShopOwner] Shop fetch failed with status ${response.status}`);
    return false;
  }

  const shopDoc = await response.json();
  const shopOwnerUid = shopDoc.fields?.ownerUid?.stringValue;

  // STRICT REQUIREMENT: shops/{shopId}.ownerUid MUST explicitly match callerUid
  if (!shopOwnerUid || shopOwnerUid !== callerUid) {
    console.warn(`[verifyShopOwner] Access denied: shopOwnerUid "${shopOwnerUid}" does not match callerUid "${callerUid}".`);
    return false;
  }

  // Condition 2: Fetch and verify the live User document under shops/{shopId}/users/{callerUid}
  // NO SHORT-CIRCUIT: User document must explicitly exist and be verified!
  const userUrl = `${firestoreShopUrl}/users/${callerUid}`;
  const userRes = await fetch(userUrl, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!userRes.ok) {
    console.warn(`[verifyShopOwner] Access denied: User document for "${callerUid}" does not exist or fetch failed (status: ${userRes.status}).`);
    return false;
  }

  const userDoc = await userRes.json();
  if (!userDoc || !userDoc.fields) {
    console.warn(`[verifyShopOwner] Access denied: Malformed or empty user document for "${callerUid}".`);
    return false;
  }

  // Condition 3: User role must strictly equal "owner" (admin, manager, cashier, staff strictly denied)
  const userRole = userDoc.fields?.role?.stringValue?.toLowerCase();
  if (userRole !== "owner") {
    console.warn(`[verifyShopOwner] Access denied: User role is "${userRole}", required strictly "owner".`);
    return false;
  }

  // Condition 4 & 5: active and approved status validation (matching firestore.rules lines 23-26)
  // An owner is active and approved unless explicitly set to false.
  const isActive = userDoc.fields?.active !== undefined
    ? userDoc.fields.active.booleanValue !== false
    : true;
  const isApproved = userDoc.fields?.approved !== undefined
    ? userDoc.fields.approved.booleanValue !== false
    : true;

  if (!isActive) {
    console.warn(`[verifyShopOwner] Access denied: User "${callerUid}" is inactive (active=false).`);
    return false;
  }

  if (!isApproved) {
    console.warn(`[verifyShopOwner] Access denied: User "${callerUid}" is explicitly unapproved (approved=false).`);
    return false;
  }

  // Condition 6: If token carries a role claim, it must match the Firestore role ("owner")
  if (tokenRole && tokenRole.toLowerCase() !== userRole) {
    console.warn(`[verifyShopOwner] Access denied: Token role "${tokenRole}" mismatches Firestore user role "${userRole}".`);
    return false;
  }

  return true;
}

// ============================================================================
// 3. CRYPTOGRAPHIC UTILITIES (ECDSA P-256 WebCrypto)
// ============================================================================

function derToP1363Signature(derHex: string): Uint8Array {
  const der = new Uint8Array(derHex.match(/.{1,2}/g)!.map((byte) => parseInt(byte, 16)));
  if (der[0] !== 0x30) throw new Error("Invalid DER sequence header");

  let pos = 2;
  if (der[1] & 0x80) {
    pos += (der[1] & 0x7f);
  }

  if (der[pos] !== 0x02) throw new Error("Expected integer tag for r");
  pos++;
  const rLen = der[pos++];
  let r = der.slice(pos, pos + rLen);
  pos += rLen;

  if (der[pos] !== 0x02) throw new Error("Expected integer tag for s");
  pos++;
  const sLen = der[pos++];
  let s = der.slice(pos, pos + sLen);

  while (r.length > 32 && r[0] === 0) r = r.slice(1);
  while (s.length > 32 && s[0] === 0) s = s.slice(1);

  const p1363 = new Uint8Array(64);
  p1363.set(r, 32 - r.length);
  p1363.set(s, 64 - s.length);
  return p1363;
}

async function verifyEcdsaP256Signature(
  publicKeyPem: string,
  canonicalPayload: string,
  signatureHex: string
): Promise<{ valid: boolean; error?: string }> {
  try {
    const cleanPem = publicKeyPem
      .replace(/-----BEGIN [A-Z ]+-----/g, "")
      .replace(/-----END [A-Z ]+-----/g, "")
      .replace(/\s+/g, "");

    const binarySpki = Uint8Array.from(atob(cleanPem), (c) => c.charCodeAt(0));
    const cryptoKey = await crypto.subtle.importKey(
      "spki",
      binarySpki,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"]
    );

    const cleanHex = signatureHex.trim().toLowerCase();
    const p1363Signature = derToP1363Signature(cleanHex);
    const dataBytes = new TextEncoder().encode(canonicalPayload);

    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: { name: "SHA-256" } },
      cryptoKey,
      p1363Signature,
      dataBytes
    );
    return { valid };
  } catch (err: any) {
    console.error("[verifyEcdsaP256Signature] Verification error:", err?.message || err);
    return { valid: false, error: err?.message || String(err) };
  }
}

// ============================================================================
// 4. TRUSTED DEVICE & NONCE STORE (POSTGRESQL AIR-GAPPED)
// ============================================================================

interface TrustedDevice {
  deviceId: string;
  shopId: string;
  ownerUid: string;
  deviceType: "mobile" | "laptop";
  platform: "android" | "windows";
  deviceModel: string;
  publicKeyPem: string;
  isActive: boolean;
  isRevoked: boolean;
  enrolledAt: string;
  lastVerifiedAt: string;
}

async function getTrustedDevice(shopId: string, deviceId: string): Promise<TrustedDevice | null> {
  if (!supabase) return null;

  const { data, error } = await supabase
    .from("recharge_trusted_devices")
    .select("*")
    .eq("shop_id", shopId)
    .eq("device_id", deviceId)
    .maybeSingle();

  if (!error && data) {
    return {
      deviceId: data.device_id,
      shopId: data.shop_id,
      ownerUid: data.owner_uid,
      deviceType: data.device_type,
      platform: data.platform,
      deviceModel: data.device_model || "",
      publicKeyPem: data.public_key_pem,
      isActive: data.is_active,
      isRevoked: data.is_revoked,
      enrolledAt: data.enrolled_at,
      lastVerifiedAt: data.last_verified_at,
    };
  }
  return null;
}

async function saveTrustedDevice(dev: TrustedDevice): Promise<boolean> {
  if (supabase) {
    const { error } = await supabase.from("recharge_trusted_devices").upsert({
      device_id: dev.deviceId,
      shop_id: dev.shopId,
      owner_uid: dev.ownerUid,
      device_type: dev.deviceType,
      platform: dev.platform,
      device_model: dev.deviceModel,
      public_key_pem: dev.publicKeyPem,
      is_active: dev.isActive,
      is_revoked: dev.isRevoked,
      enrolled_at: dev.enrolledAt,
      last_verified_at: dev.lastVerifiedAt,
    });
    if (error) {
      console.error("[saveTrustedDevice] Postgres error:", error);
      return false;
    }
    return true;
  }
  return false;
}

async function getActiveDevices(shopId: string): Promise<TrustedDevice[]> {
  if (supabase) {
    const { data, error } = await supabase
      .from("recharge_trusted_devices")
      .select("*")
      .eq("shop_id", shopId)
      .eq("is_active", true)
      .eq("is_revoked", false);

    if (!error && data) {
      return data.map((d: any) => ({
        deviceId: d.device_id,
        shopId: d.shop_id,
        ownerUid: d.owner_uid,
        deviceType: d.device_type,
        platform: d.platform,
        deviceModel: d.device_model || "",
        publicKeyPem: d.public_key_pem,
        isActive: d.is_active,
        isRevoked: d.is_revoked,
        enrolledAt: d.enrolled_at,
        lastVerifiedAt: d.last_verified_at,
      }));
    }
  }
  return [];
}

async function isShopBootstrapLocked(shopId: string): Promise<boolean> {
  if (!supabase) return false;
  try {
    const { data, error } = await supabase.rpc("recharge_is_bootstrap_locked", { p_shop_id: shopId });
    if (!error && typeof data === "boolean") {
      return data;
    }
    const { data: stateData, error: stateErr } = await supabase
      .from("recharge_shop_bootstrap_state")
      .select("is_bootstrap_consumed")
      .eq("shop_id", shopId)
      .maybeSingle();
    if (!stateErr && stateData?.is_bootstrap_consumed === true) {
      return true;
    }
  } catch (err) {
    console.error("[isShopBootstrapLocked] Error checking bootstrap lock:", err);
  }
  return false;
}

async function saveChallengeNonce(nonce: string, shopId: string, deviceId: string, ownerUid: string, ttlSeconds: number): Promise<void> {
  const expiresAtMs = Date.now() + (ttlSeconds * 1000);
  if (supabase) {
    await supabase.from("recharge_device_challenges").insert({
      nonce,
      shop_id: shopId,
      device_id: deviceId,
      owner_uid: ownerUid,
      expires_at: new Date(expiresAtMs).toISOString(),
      consumed: false,
    });
  }
}

async function consumeChallengeNonce(nonce: string, shopId: string, deviceId: string, ownerUid: string): Promise<boolean> {
  if (supabase) {
    // ATOMIC CONDITIONAL UPDATE: Row-locking atomic consumption prevents concurrent replay races
    const { data, error } = await supabase
      .from("recharge_device_challenges")
      .update({ consumed: true })
      .eq("nonce", nonce)
      .eq("shop_id", shopId)
      .eq("device_id", deviceId)
      .eq("owner_uid", ownerUid)
      .eq("consumed", false)
      .gte("expires_at", new Date().toISOString())
      .select();

    if (error || !data || data.length === 0) return false;
    return true;
  }
  return false;
}

// ============================================================================
// 5. UNIFIED MANDATORY HARDWARE SECURITY PERIMETER MIDDLEWARE
// ============================================================================

async function enforceHardwareSecurity({
  shopId,
  callerUid,
  deviceId,
  nonce,
  deviceSignature,
  operationType,
  canonicalData,
}: {
  shopId: string;
  callerUid: string;
  deviceId: string;
  nonce: string;
  deviceSignature: string;
  operationType: string;
  canonicalData: string;
}): Promise<{ valid: boolean; error?: string; status?: number }> {
  if (!deviceId || typeof deviceId !== "string" || deviceId.trim() === "") {
    return { valid: false, error: "Trusted Device Required: deviceId is missing or empty.", status: 403 };
  }

  const dev = await getTrustedDevice(shopId, deviceId);
  if (!dev || !dev.isActive || dev.isRevoked) {
    return { valid: false, error: `Device ${deviceId} is not registered or has been revoked.`, status: 403 };
  }
  if (dev.ownerUid !== callerUid) {
    return { valid: false, error: "Device ownership mismatch with authenticated owner.", status: 403 };
  }

  if (!nonce || !deviceSignature) {
    return { valid: false, error: "Trusted Device Error: Both nonce and deviceSignature are required.", status: 403 };
  }

  // Atomically consume nonce
  const nonceValid = await consumeChallengeNonce(nonce, shopId, deviceId, callerUid);
  if (!nonceValid) {
    return { valid: false, error: "Challenge nonce is invalid, expired, or already consumed (Replay blocked).", status: 403 };
  }

  // Bind signature to operationType, shopId, callerUid, deviceId, nonce, and canonical data
  // Prevents cross-endpoint signature reuse and data tampering
  const canonicalPayload = `${operationType}:${shopId}:${callerUid}:${deviceId}:${nonce}:${canonicalData}`;
  const sigResult = await verifyEcdsaP256Signature(dev.publicKeyPem, canonicalPayload, deviceSignature);

  if (!sigResult.valid) {
    return { valid: false, error: `Cryptographic signature verification failed: ${sigResult.error || "Invalid key or altered payload."}`, status: 403 };
  }

  return { valid: true };
}

// ============================================================================
// 6. SECURE RESPONSE UTILITIES
// ============================================================================

function jsonResponse(data: any, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
    },
  });
}

// ============================================================================
// 6B. SERVER-AUTHORITATIVE ATOMIC BANK RESERVATION IN FIRESTORE (Phase 16.4.16 & 16.4.19)
// ============================================================================

let cachedGoogleAccessToken: { token: string; expiresAt: number } | null = null;

async function getGoogleFirestoreAccessToken(): Promise<string | null> {
  if (!FIREBASE_SERVICE_ACCOUNT_B64) return null;
  const now = Date.now();
  if (cachedGoogleAccessToken && cachedGoogleAccessToken.expiresAt > now + 60000) {
    return cachedGoogleAccessToken.token;
  }

  try {
    const rawJson = atob(FIREBASE_SERVICE_ACCOUNT_B64);
    const sa = JSON.parse(rawJson);
    if (!sa.client_email || !sa.private_key) {
      throw new Error("Invalid service account JSON: missing client_email or private_key");
    }

    const key = await jose.importPKCS8(sa.private_key, "RS256");
    const nowSec = Math.floor(now / 1000);
    const jwt = await new jose.SignJWT({
      iss: sa.client_email,
      sub: sa.client_email,
      aud: "https://oauth2.googleapis.com/token",
      scope: "https://www.googleapis.com/auth/datastore",
    })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuedAt(nowSec)
      .setExpirationTime(nowSec + 3600)
      .sign(key);

    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    if (!tokenRes.ok) {
      const errText = await tokenRes.text();
      throw new Error(`Google OAuth2 token request failed (${tokenRes.status}): ${errText}`);
    }

    const tokenData = await tokenRes.json();
    cachedGoogleAccessToken = {
      token: tokenData.access_token,
      expiresAt: now + (tokenData.expires_in ?? 3600) * 1000,
    };
    return cachedGoogleAccessToken.token;
  } catch (err: any) {
    console.error("[getGoogleFirestoreAccessToken] Error:", err.message);
    throw err;
  }
}

async function reserveBankFundsInFirestore(params: {
  shopId: string;
  rawToken: string;
  ref: string;
  amountPaise: number;
  walletId: string;
  callerUid: string;
  staffName?: string;
}): Promise<{ success: boolean; error?: string; status?: number }> {
  const { shopId, rawToken, ref, amountPaise, walletId, callerUid, staffName } = params;

  // Phase 16.4.18: Hard failure if FIREBASE_PROJECT_ID is not configured.
  // STAGING_IDENTITY_MODE must NEVER bypass financial operations or fake successful reservations.
  if (!FIREBASE_PROJECT_ID) {
    console.error("[reserveBankFundsInFirestore] FATAL: FIREBASE_PROJECT_ID is not configured.");
    return {
      success: false,
      error: "HARD_FAILURE: FIREBASE_PROJECT_ID is not configured. Server refused to process financial top-up without authoritative Firestore integration.",
      status: 500,
    };
  }

  const amount = amountPaise / 100.0;
  const docBasePath = `projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;
  const baseUrl = `https://firestore.googleapis.com/v1/${docBasePath}`;
  
  let authHeader = `Bearer ${rawToken}`;
  try {
    const saToken = await getGoogleFirestoreAccessToken();
    if (saToken) {
      authHeader = `Bearer ${saToken}`;
    }
  } catch (saErr: any) {
    return {
      success: false,
      error: `Failed to authenticate with Google Firestore: ${saErr.message}`,
      status: 500,
    };
  }

  const headers = {
    Authorization: authHeader,
    "Content-Type": "application/json",
  };

  const maxRetries = 5;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      // 1. Begin atomic readWrite transaction
      const beginRes = await fetch(`${baseUrl}:beginTransaction`, {
        method: "POST",
        headers,
        body: JSON.stringify({ options: { readWrite: {} } }),
      });

      if (!beginRes.ok) {
        const errText = await beginRes.text();
        if (beginRes.status === 409 && attempt < maxRetries) {
          await new Promise((r) => setTimeout(r, attempt * 200 + Math.floor(Math.random() * 100)));
          continue;
        }
        return { success: false, error: `Firestore transaction start failed: ${errText}`, status: 500 };
      }

      const { transaction } = await beginRes.json();

      // 2. Read current bank balance within transaction
      const bankDocUrl = `${baseUrl}/shops/${shopId}/bank/bank_balance?transaction=${encodeURIComponent(transaction)}`;
      const bankRes = await fetch(bankDocUrl, { headers });

      if (!bankRes.ok) {
        if (bankRes.status === 409 && attempt < maxRetries) {
          await new Promise((r) => setTimeout(r, attempt * 200 + Math.floor(Math.random() * 100)));
          continue;
        }
        return {
          success: false,
          error: `Failed to read authoritative bank balance from Firestore (status: ${bankRes.status})`,
          status: 400,
        };
      }

      const bankDoc = await bankRes.json();
      const currentVal = bankDoc.fields?.v?.doubleValue !== undefined
        ? Number(bankDoc.fields.v.doubleValue)
        : (bankDoc.fields?.v?.integerValue !== undefined ? Number(bankDoc.fields.v.integerValue) : 0.0);
      const updateTime = bankDoc.updateTime;

      // 3. Reject insufficient balance atomically
      if (currentVal < amount) {
        return {
          success: false,
          error: `Insufficient bank balance: Available ₹${currentVal.toFixed(2)}, Required ₹${amount.toFixed(2)}`,
          status: 400,
        };
      }

      const newBalance = currentVal - amount;
      const nowIso = new Date().toISOString();

      // 4. Commit atomic reservation: decrement bank_balance & write RESERVED voucher
      const commitUrl = `${baseUrl}:commit`;
      const commitBody = {
        transaction,
        writes: [
          {
            update: {
              name: `${docBasePath}/shops/${shopId}/bank/bank_balance`,
              fields: {
                v: { doubleValue: newBalance },
                _by: { stringValue: callerUid },
                _st: { stringValue: nowIso },
              },
            },
            currentDocument: {
              updateTime,
            },
          },
          {
            update: {
              name: `${docBasePath}/shops/${shopId}/accounting_cash_bank/CB_TOPUP_${ref}`,
              fields: {
                id: { stringValue: `CB_TOPUP_${ref}` },
                type: { stringValue: "DEBIT" },
                entryType: { stringValue: "DEBIT" },
                transactionCategory: { stringValue: "RECHARGE_FLOAT_TOPUP" },
                category: { stringValue: "ASSET_TRANSFER" },
                isRecharge: { booleanValue: true },
                isExpense: { booleanValue: false },
                isSalesRevenue: { booleanValue: false },
                status: { stringValue: "RESERVED" },
                walletId: { stringValue: walletId },
                amount: { doubleValue: amount },
                amountPaise: { integerValue: amountPaise },
                paymentMode: { stringValue: "BANK" },
                mode: { stringValue: "Bank" },
                referenceNo: { stringValue: ref },
                createdByUid: { stringValue: callerUid },
                createdByName: { stringValue: staffName || "Shop Owner" },
                createdAt: { stringValue: nowIso },
              },
            },
          },
        ],
      };

      const commitRes = await fetch(commitUrl, {
        method: "POST",
        headers,
        body: JSON.stringify(commitBody),
      });

      if (!commitRes.ok) {
        const errText = await commitRes.text();
        if (commitRes.status === 409 && attempt < maxRetries) {
          // Document contention / concurrency collision - exponential backoff with jitter and retry
          await new Promise((r) => setTimeout(r, attempt * 200 + Math.floor(Math.random() * 100)));
          continue;
        }
        return { success: false, error: `Firestore reservation commit conflict: ${errText}`, status: 409 };
      }

      return { success: true };
    } catch (err: any) {
      if (attempt < maxRetries) {
        await new Promise((r) => setTimeout(r, attempt * 200 + Math.floor(Math.random() * 100)));
        continue;
      }
      return { success: false, error: `Firestore reservation exception: ${err.message}`, status: 500 };
    }
  }
  return { success: false, error: "Firestore reservation failed after max retries due to document contention", status: 409 };
}

async function finalizeBankSettlementInFirestore(
  shopId: string,
  rawToken: string,
  ref: string,
  serverDepositId: string
): Promise<void> {
  if (!FIREBASE_PROJECT_ID) {
    console.error("[finalizeBankSettlementInFirestore] FATAL: FIREBASE_PROJECT_ID is not configured.");
    return;
  }
  const baseUrl = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;
  const url = `${baseUrl}/shops/${shopId}/accounting_cash_bank/CB_TOPUP_${ref}?updateMask.fieldPaths=status&updateMask.fieldPaths=supabaseDepositId&updateMask.fieldPaths=confirmedAt`;
  
  let authHeader = `Bearer ${rawToken}`;
  try {
    const saToken = await getGoogleFirestoreAccessToken();
    if (saToken) authHeader = `Bearer ${saToken}`;
  } catch (_) {}

  await fetch(url, {
    method: "PATCH",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({
      fields: {
        status: { stringValue: "SETTLED" },
        supabaseDepositId: { stringValue: serverDepositId },
        confirmedAt: { stringValue: new Date().toISOString() },
      },
    }),
  }).catch((e) => console.warn(`[finalizeBankSettlement] Notice: ${e}`));
}

async function compensateFailedBankReservation(
  shopId: string,
  rawToken: string,
  ref: string,
  amount: number,
  errorMessage: string
): Promise<void> {
  if (!FIREBASE_PROJECT_ID) {
    console.error("[compensateFailedBankReservation] FATAL: FIREBASE_PROJECT_ID is not configured.");
    return;
  }
  const docBasePath = `projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;
  const baseUrl = `https://firestore.googleapis.com/v1/${docBasePath}`;
  
  let authHeader = `Bearer ${rawToken}`;
  try {
    const saToken = await getGoogleFirestoreAccessToken();
    if (saToken) authHeader = `Bearer ${saToken}`;
  } catch (_) {}

  const headers = { Authorization: authHeader, "Content-Type": "application/json" };
  await fetch(`${baseUrl}:commit`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      writes: [
        {
          transform: {
            document: `${docBasePath}/shops/${shopId}/bank/bank_balance`,
            fieldTransforms: [
              {
                fieldPath: "v",
                increment: { doubleValue: amount },
              },
            ],
          },
        },
        {
          update: {
            name: `${docBasePath}/shops/${shopId}/accounting_cash_bank/CB_TOPUP_${ref}`,
            fields: {
              status: { stringValue: "CANCELLED" },
              cancellationReason: { stringValue: errorMessage },
              cancelledAt: { stringValue: new Date().toISOString() },
            },
          },
          updateMask: {
            fieldPaths: ["status", "cancellationReason", "cancelledAt"],
          },
        },
      ],
    }),
  }).catch((e) => console.error(`[compensateFailedBankReservation] Compensation failed: ${e}`));
}

// ============================================================================
// 7. MAIN SERVER HANDLER
// ============================================================================

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type",
      },
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed. Only POST is accepted." }, 405);
  }

  const url = new URL(req.url);
  const pathname = url.pathname;

  try {
    // ------------------------------------------------------------------------
    // ENDPOINT 1: POST /request-challenge (CHALLENGE NONCE ISSUER)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/request-challenge")) {
      const body = await req.json().catch(() => ({}));
      const shopId = typeof body.shopId === "string" ? body.shopId.trim() : "";
      const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
      const ownerUid = typeof body.ownerUid === "string" ? body.ownerUid.trim() : "";
      const isBootstrap = body.isBootstrap === true;

      if (!shopId || !deviceId) {
        return jsonResponse({ error: "Missing mandatory parameters: shopId and deviceId are required." }, 400);
      }

      if (!supabase) {
        return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
      }

      // Whitelist check in Staging Mode
      if (STAGING_IDENTITY_MODE) {
        if (!ownerUid) {
          return jsonResponse({ error: "Missing mandatory parameter: ownerUid is required in staging mode." }, 400);
        }
        const authorizedOwners = STAGING_SHOP_OWNERS[shopId];
        if (!authorizedOwners || !authorizedOwners.includes(ownerUid)) {
          console.warn(`[request-challenge] Access denied: "${ownerUid}" is not whitelisted for "${shopId}".`);
          return jsonResponse(
            { error: `Unauthorized: Owner "${ownerUid}" is not whitelisted for shop "${shopId}".` },
            403
          );
        }
      }

      // Case 1: Initial Bootstrap Challenge (Zero active devices exist & Bootstrap never consumed)
      if (isBootstrap) {
        // PERMANENT INVARIANT: Check if shop bootstrap was EVER consumed in database audit state
        const isLocked = await isShopBootstrapLocked(shopId);
        if (isLocked) {
          return jsonResponse({
            error: "Initial bootstrap gate closed: Initial bootstrap opportunity was already consumed and can NEVER be reopened. Revocation or deletion of devices does not reset this gate. Mutual cross-signing from existing device required.",
          }, 403);
        }

        const activeDevices = await getActiveDevices(shopId);
        if (activeDevices.length > 0) {
          return jsonResponse({
            error: "Initial bootstrap gate closed: Shop already has active devices. Mutual cross-signing required.",
          }, 403);
        }

        const nonce = `NONCE_${Date.now()}_${crypto.randomUUID().replace(/-/g, "")}`;
        const ttlSeconds = 300;
        const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();

        await saveChallengeNonce(nonce, shopId, deviceId, ownerUid, ttlSeconds);

        return jsonResponse({
          success: true,
          nonce,
          expiresAt,
          isBootstrap: true,
        });
      }

      // Case 2: Standard Challenge for Registered Device
      const dev = await getTrustedDevice(shopId, deviceId);
      if (!dev || !dev.isActive || dev.isRevoked) {
        return jsonResponse({ error: `Device ${deviceId} is not registered or has been revoked.` }, 403);
      }
      if (ownerUid && dev.ownerUid !== ownerUid) {
        return jsonResponse({ error: "Device ownership mismatch with authenticated owner." }, 403);
      }

      const effectiveOwnerUid = ownerUid || dev.ownerUid;
      const nonce = `NONCE_${Date.now()}_${crypto.randomUUID().replace(/-/g, "")}`;
      const ttlSeconds = 300;
      const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();

      await saveChallengeNonce(nonce, shopId, deviceId, effectiveOwnerUid, ttlSeconds);

      return jsonResponse({
        success: true,
        nonce,
        expiresAt,
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 0: POST /issue-staging-token (HARDENED CRYPTOGRAPHIC ISSUER)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/issue-staging-token")) {
      if (!STAGING_IDENTITY_MODE) {
        return jsonResponse(
          { error: "Forbidden: Staging identity issuance is disabled in production mode." },
          403
        );
      }

      validateEnvironmentConfiguration();

      const body = await req.json().catch(() => ({}));
      const shopId = typeof body.shopId === "string" ? body.shopId.trim() : "";
      const ownerUid = typeof body.ownerUid === "string" ? body.ownerUid.trim() : "";
      const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
      const nonce = typeof body.nonce === "string" ? body.nonce.trim() : "";
      const deviceSignature = typeof body.deviceSignature === "string" ? body.deviceSignature.trim() : "";

      // Attack Vectors 1, 2, 3, 4: Reject missing identifiers or proof
      if (!shopId || !ownerUid || !deviceId || !nonce || !deviceSignature) {
        return jsonResponse(
          {
            error: "Missing mandatory parameters: shopId, ownerUid, deviceId, nonce, and deviceSignature are all required.",
          },
          400
        );
      }

      // Attack Vectors 5 & 6: Whitelist Enforcement
      const authorizedOwners = STAGING_SHOP_OWNERS[shopId];
      if (!authorizedOwners || !authorizedOwners.includes(ownerUid)) {
        console.warn(`[issue-staging-token] Access denied: "${ownerUid}" is not whitelisted for "${shopId}".`);
        return jsonResponse(
          { error: `Unauthorized: Owner "${ownerUid}" is not whitelisted for shop "${shopId}".` },
          403
        );
      }

      if (!supabase) {
        return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
      }

      // Attack Vectors 8 & 9: Device Registration & Revocation Enforcement
      const dev = await getTrustedDevice(shopId, deviceId);
      if (!dev) {
        console.warn(`[issue-staging-token] Access denied: Device "${deviceId}" is not registered.`);
        return jsonResponse(
          { error: `Unauthorized: Device "${deviceId}" is not registered in trusted devices.` },
          403
        );
      }

      if (!dev.isActive || dev.isRevoked) {
        console.warn(`[issue-staging-token] Access denied: Device "${deviceId}" has been revoked or deactivated.`);
        return jsonResponse(
          { error: `Unauthorized: Device "${deviceId}" has been revoked or deactivated.` },
          403
        );
      }

      if (dev.ownerUid !== ownerUid) {
        console.warn(`[issue-staging-token] Access denied: Device ownerUid "${dev.ownerUid}" mismatches "${ownerUid}".`);
        return jsonResponse(
          { error: "Unauthorized: Device ownership mismatch with requested ownerUid." },
          403
        );
      }

      // Attack Vectors 7, 10, 11, 12: Nonce Consumption & Replay Prevention
      const nonceValid = await consumeChallengeNonce(nonce, shopId, deviceId, ownerUid);
      if (!nonceValid) {
        console.warn(`[issue-staging-token] Access denied: Challenge nonce is invalid, expired, or already consumed.`);
        return jsonResponse(
          { error: "Unauthorized: Challenge nonce is invalid, expired, or already consumed." },
          403
        );
      }

      // Cryptographic Proof of Possession: Verify ECDSA P-256 signature
      const canonicalPayload = `ISSUE_STAGING_TOKEN:${shopId}:${ownerUid}:${deviceId}:${nonce}`;
      const sigResult = await verifyEcdsaP256Signature(dev.publicKeyPem, canonicalPayload, deviceSignature);

      if (!sigResult.valid) {
        console.warn(`[issue-staging-token] Access denied: Signature verification failed for device "${deviceId}": ${sigResult.error}`);
        return jsonResponse(
          { error: "Unauthorized: Cryptographic signature verification failed. Caller does not possess device private key.", details: sigResult.error },
          403
        );
      }

      // Issue short-lived, cryptographically signed Option A JWT (1 hour TTL)
      const now = Math.floor(Date.now() / 1000);
      const ttlSeconds = 3600;
      const secretBytes = new TextEncoder().encode(STAGING_JWT_SECRET);

      const token = await new jose.SignJWT({
        iss: "tekfix-staging-identity",
        aud: "tekfix-staging-audience",
        sub: ownerUid,
        shop_id: shopId,
        device_id: deviceId,
        role: "owner",
        auth_time: now,
      })
        .setProtectedHeader({ alg: "HS256", typ: "JWT" })
        .setIssuedAt(now)
        .setExpirationTime(now + ttlSeconds)
        .sign(secretBytes);

      return jsonResponse({
        success: true,
        token,
        tokenType: "Bearer",
        expiresIn: ttlSeconds,
        expiresAt: new Date((now + ttlSeconds) * 1000).toISOString(),
        shopId,
        ownerUid,
        deviceId,
        role: "owner",
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 2B: POST /register-device (UNAUTHENTICATED INITIAL BOOTSTRAP GATE)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/register-device") && !(req.headers.get("Authorization") || "").startsWith("Bearer ")) {
      if (!STAGING_IDENTITY_MODE) {
        return jsonResponse({ error: "Missing or malformed Authorization header" }, 401);
      }

      const body = await req.json().catch(() => ({}));
      const shopId = typeof body.shopId === "string" ? body.shopId.trim() : "";
      const ownerUid = typeof body.ownerUid === "string" ? body.ownerUid.trim() : "";
      const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
      const deviceType = typeof body.deviceType === "string" ? body.deviceType.trim() : "";
      const platform = typeof body.platform === "string" ? body.platform.trim() : "";
      const deviceModel = typeof body.deviceModel === "string" ? body.deviceModel.trim() : "";
      const publicKeyPem = typeof body.publicKeyPem === "string" ? body.publicKeyPem.trim() : "";
      const nonce = typeof body.nonce === "string" ? body.nonce.trim() : "";
      const deviceSignature = typeof body.deviceSignature === "string" ? body.deviceSignature.trim() : "";
      const bootstrapSecret = typeof body.bootstrapSecret === "string" ? body.bootstrapSecret.trim() : "";

      if (!shopId || !ownerUid || !deviceId || !deviceType || !platform || !publicKeyPem || !nonce || !deviceSignature || !bootstrapSecret) {
        return jsonResponse({
          error: "Missing mandatory bootstrap parameters: shopId, ownerUid, deviceId, deviceType, platform, publicKeyPem, nonce, deviceSignature, and bootstrapSecret are required.",
        }, 400);
      }

      if (!["mobile", "laptop"].includes(deviceType)) {
        return jsonResponse({ error: "Invalid deviceType. Must be 'mobile' or 'laptop'." }, 400);
      }
      if (!["android", "windows"].includes(platform)) {
        return jsonResponse({ error: "Invalid platform. Must be 'android' or 'windows'." }, 400);
      }
      if (deviceType === "mobile" && platform !== "android") {
        return jsonResponse({ error: "Invalid platform for mobile. Mobile must be 'android'." }, 400);
      }
      if (deviceType === "laptop" && platform !== "windows") {
        return jsonResponse({ error: "Invalid platform for laptop. Laptop must be 'windows'." }, 400);
      }

      const authorizedOwners = STAGING_SHOP_OWNERS[shopId];
      if (!authorizedOwners || !authorizedOwners.includes(ownerUid)) {
        return jsonResponse({ error: `Unauthorized: Owner "${ownerUid}" is not whitelisted for shop "${shopId}".` }, 403);
      }

      if (!supabase) {
        return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
      }

      // STRICT GATE: Initial bootstrap is ONLY permitted when bootstrap was NEVER consumed and activeDevices.length === 0!
      const isLocked = await isShopBootstrapLocked(shopId);
      if (isLocked) {
        return jsonResponse({
          error: "Initial bootstrap gate closed: Initial device bootstrap was already consumed for this shop and can NEVER be reopened. Revocation or deletion of devices does not reset this gate. Mutual cross-signing from existing device required.",
        }, 403);
      }

      const activeDevices = await getActiveDevices(shopId);
      if (activeDevices.length > 0) {
        return jsonResponse({
          error: "Initial bootstrap gate closed: Shop already has active devices. Enrolling additional devices requires mutual cross-signing from existing device.",
        }, 403);
      }

      // Validate Bootstrap Secret (constant-time)
      if (!STAGING_BOOTSTRAP_SECRET || !constantTimeCompare(bootstrapSecret, STAGING_BOOTSTRAP_SECRET)) {
        console.warn(`[register-device] Access denied: Invalid bootstrap secret for shop "${shopId}".`);
        return jsonResponse({ error: "Unauthorized: Invalid owner bootstrap secret." }, 403);
      }

      // Consume Challenge Nonce
      const nonceValid = await consumeChallengeNonce(nonce, shopId, deviceId, ownerUid);
      if (!nonceValid) {
        return jsonResponse({ error: "Unauthorized: Challenge nonce is invalid, expired, or already consumed." }, 403);
      }

      // Verify Proof of Possession of Key
      const canonicalPayload = `BOOTSTRAP_DEVICE:${shopId}:${ownerUid}:${deviceId}:${nonce}`;
      const sigResult = await verifyEcdsaP256Signature(publicKeyPem, canonicalPayload, deviceSignature);
      if (!sigResult.valid) {
        return jsonResponse({ error: "Unauthorized: Cryptographic proof of possession verification failed.", details: sigResult.error }, 403);
      }

      // ATOMIC PERSISTENCE & PERMANENT LOCKOUT VIA DATABASE STORED PROCEDURE:
      // Concurrently-safe enrollment: inserts permanent lockout and device record atomically
      const { data: rpcRes, error: rpcErr } = await supabase.rpc("recharge_consume_bootstrap", {
        p_shop_id: shopId,
        p_device_id: deviceId,
        p_owner_uid: ownerUid,
        p_device_type: deviceType,
        p_platform: platform,
        p_device_model: deviceModel || "Unknown Device",
        p_public_key_pem: publicKeyPem,
      });

      if (rpcErr || !rpcRes || !rpcRes.success) {
        console.error("[register-device] Atomic bootstrap consumption failed:", rpcErr || rpcRes?.error);
        return jsonResponse({
          error: rpcRes?.error || "Failed to persist trusted device and permanently lock bootstrap in database.",
        }, 403);
      }

      // Issue initial Option A JWT
      const now = Math.floor(Date.now() / 1000);
      const ttlSeconds = 3600;
      const secretBytes = new TextEncoder().encode(STAGING_JWT_SECRET);
      const token = await new jose.SignJWT({
        iss: "tekfix-staging-identity",
        aud: "tekfix-staging-audience",
        sub: ownerUid,
        shop_id: shopId,
        device_id: deviceId,
        role: "owner",
        auth_time: now,
      })
        .setProtectedHeader({ alg: "HS256", typ: "JWT" })
        .setIssuedAt(now)
        .setExpirationTime(now + ttlSeconds)
        .sign(secretBytes);

      return jsonResponse({
        success: true,
        enrolled: true,
        deviceId,
        token,
        tokenType: "Bearer",
        expiresIn: ttlSeconds,
      });
    }

    const adminKeyHeader = req.headers.get("x-admin-key") || req.headers.get("X-Admin-Key") || "";
    const isServiceAdmin = Boolean(adminKeyHeader && STAGING_BOOTSTRAP_SECRET && constantTimeCompare(adminKeyHeader, STAGING_BOOTSTRAP_SECRET));

    const authHeader = req.headers.get("Authorization") || "";
    let tokenPayload: jose.JWTPayload | null = null;
    let callerUid = "";
    let tokenRole = "";
    let rawToken = "";

    if (authHeader.startsWith("Bearer ")) {
      rawToken = authHeader.substring(7).trim();
      try {
        tokenPayload = await verifyFirebaseIdToken(rawToken);
        callerUid = tokenPayload.sub || "";
        tokenRole = (tokenPayload.role as string | undefined) || "";
      } catch (err: any) {
        if (!isServiceAdmin) {
          console.error("[recharge-bridge] Token verification failed:", err.message);
          return jsonResponse({ error: `Authentication failed: ${err.message}` }, 401);
        }
      }
    } else if (!isServiceAdmin) {
      return jsonResponse({ error: "Missing or malformed Authorization header" }, 401);
    }

    if (isServiceAdmin && !tokenRole) {
      tokenRole = "admin";
      callerUid = "SYSTEM_ADMIN_SERVICE";
    }

    const body = await req.json().catch(() => ({}));
    const shopId = body.shopId || "";
    if (!shopId) {
      return jsonResponse({ error: "Missing mandatory parameter: shopId" }, 400);
    }

    // ------------------------------------------------------------------------
    // ADMINISTRATIVE ENDPOINTS (STRICT ADMIN-ONLY AUTHORIZATION)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/admin/emergency-device-recovery") || pathname.endsWith("/admin-emergency-recovery")) {
      if (tokenRole !== "admin" && tokenRole !== "system_admin") {
        return jsonResponse({
          error: "Unauthorized: Emergency device recovery is restricted exclusively to authorized system administrators. Non-admin roles (staff, manager, owner) are strictly forbidden.",
        }, 403);
      }

      if (!supabase) {
        return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
      }

      const {
        adminIdentity,
        authReference,
        newDeviceId,
        newDeviceType,
        newPlatform,
        newPublicKeyPem,
        ownerUid,
      } = body;

      if (!adminIdentity || !authReference || !newDeviceId || !newDeviceType || !newPlatform || !newPublicKeyPem || !ownerUid) {
        return jsonResponse({
          error: "Missing required parameters for administrative recovery: shopId, ownerUid, adminIdentity, authReference, newDeviceId, newDeviceType, newPlatform, newPublicKeyPem are required.",
        }, 400);
      }

      const { data: rpcRes, error: rpcErr } = await supabase.rpc("recharge_admin_emergency_device_recovery", {
        p_shop_id: shopId,
        p_admin_identity: adminIdentity,
        p_auth_reference: authReference,
        p_new_device_id: newDeviceId,
        p_new_device_type: newDeviceType,
        p_new_platform: newPlatform,
        p_new_public_key_pem: newPublicKeyPem,
        p_owner_uid: ownerUid,
      });

      if (rpcErr) {
        console.error("[admin-emergency-recovery] RPC Error:", rpcErr);
        return jsonResponse({ error: rpcErr.message }, 403);
      }

      if (!rpcRes || !rpcRes.success) {
        return jsonResponse({ error: rpcRes?.error || "Administrative recovery failed" }, 403);
      }

      return jsonResponse(rpcRes, 200);
    }

    if (pathname.endsWith("/admin/issue-recovery-ticket")) {
      if (tokenRole !== "admin" && tokenRole !== "system_admin") {
        return jsonResponse({
          error: "Unauthorized: Issuing recovery tickets is restricted exclusively to authorized system administrators.",
        }, 403);
      }

      if (!supabase) {
        return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
      }

      const { ticketId, ownerUid, adminIdentity, metadata } = body;
      if (!ticketId || !ownerUid || !adminIdentity) {
        return jsonResponse({
          error: "Missing required parameters: shopId, ownerUid, ticketId, adminIdentity are required.",
        }, 400);
      }

      const { data: rpcRes, error: rpcErr } = await supabase.rpc("recharge_admin_issue_recovery_ticket", {
        p_ticket_id: ticketId,
        p_shop_id: shopId,
        p_owner_uid: ownerUid,
        p_admin_identity: adminIdentity,
        p_metadata: metadata || {},
      });

      if (rpcErr) {
        return jsonResponse({ error: rpcErr.message }, 403);
      }

      if (!rpcRes || !rpcRes.success) {
        return jsonResponse({ error: rpcRes?.error || "Ticket issuance failed" }, 403);
      }

      return jsonResponse(rpcRes, 200);
    }

    // Live Owner Authorization Check (Strict Owner-Only Enforcement)
    const isOwner = await verifyShopOwner(shopId, callerUid, rawToken, tokenRole);
    if (!isOwner) {
      return jsonResponse({ error: "Unauthorized: Only an authenticated shop owner can perform recharge operations." }, 403);
    }

    if (!supabase) {
      return jsonResponse({ error: "PostgreSQL Database connection unconfigured" }, 503);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 2: POST /register-device (SECURE ENROLLMENT WITH CROSS-SIGNING)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/register-device")) {
      const {
        deviceId,
        deviceType,
        platform,
        deviceModel,
        publicKeyPem,
        authorizingDeviceId,
        authorizingSignature,
        nonce,
      } = body;

      if (!deviceId || !deviceType || !platform || !publicKeyPem) {
        return jsonResponse({ error: "Missing required registration parameters" }, 400);
      }

      if (!["mobile", "laptop"].includes(deviceType)) {
        return jsonResponse({ error: "Invalid deviceType. Must be 'mobile' or 'laptop'." }, 400);
      }
      if (!["android", "windows"].includes(platform)) {
        return jsonResponse({ error: "Invalid platform. Must be 'android' or 'windows'." }, 400);
      }
      if (deviceType === "mobile" && platform !== "android") {
        return jsonResponse({ error: "Invalid platform for mobile. Mobile must be 'android'." }, 400);
      }
      if (deviceType === "laptop" && platform !== "windows") {
        return jsonResponse({ error: "Invalid platform for laptop. Laptop must be 'windows'." }, 400);
      }

      const activeDevices = await getActiveDevices(shopId);

      // Check Quota and Device Type Limits (Strictly 1 Mobile Android + 1 Laptop Windows)
      const existingSameType = activeDevices.find((d) => d.deviceType === deviceType && d.deviceId !== deviceId);
      if (existingSameType) {
        return jsonResponse({
          error: `Quota Exceeded: A trusted ${deviceType} (${existingSameType.deviceId}) is already registered. Revoke it before replacing.`,
        }, 400);
      }

      const existingSamePlatform = activeDevices.find((d) => d.platform === platform && d.deviceId !== deviceId);
      if (existingSamePlatform) {
        return jsonResponse({
          error: `Quota Exceeded: A trusted ${platform} device (${existingSamePlatform.deviceId}) is already registered. Revoke it before replacing.`,
        }, 400);
      }

      if (activeDevices.length >= 2) {
        return jsonResponse({
          error: "Quota Exceeded: Maximum 2 active trusted devices allowed per shop (1 mobile + 1 laptop).",
        }, 400);
      }

      // Enrollment Security Check:
      // Case 1: First device bootstrap requires fresh owner auth (auth_time within 300s)
      if (activeDevices.length === 0) {
        const isLocked = await isShopBootstrapLocked(shopId);
        if (isLocked) {
          return jsonResponse({
            error: "Initial bootstrap gate closed: Initial device bootstrap was already consumed for this shop and can NEVER be reopened. Revocation or deletion of devices does not reset this gate. Total hardware-loss recovery requires approved administrative recovery.",
          }, 403);
        }

        const authTime = tokenPayload?.auth_time as number | undefined;
        const nowSec = Math.floor(Date.now() / 1000);
        if (!authTime || (nowSec - authTime) > 300) {
          return jsonResponse({
            error: "Initial Device Bootstrap Gate: Enrolling the first trusted device requires fresh owner re-authentication (auth_time < 300s). Re-login to continue.",
          }, 403);
        }
      }

      // Case 2: If 1 device is already active, registering the 2nd device MUST be authorized by the existing device.
      if (activeDevices.length === 1) {
        const existingDevice = activeDevices[0];
        if (!authorizingDeviceId || !authorizingSignature || !nonce) {
          return jsonResponse({
            error: "Secondary Enrollment Gate: Enrolling a second device requires mutual cross-signing from existing trusted device " + existingDevice.deviceId,
          }, 403);
        }

        if (authorizingDeviceId !== existingDevice.deviceId) {
          return jsonResponse({ error: "Authorizing device mismatch" }, 403);
        }

        const authResult = await enforceHardwareSecurity({
          shopId,
          callerUid,
          deviceId: authorizingDeviceId,
          nonce,
          deviceSignature: authorizingSignature,
          operationType: "ENROLL_SECONDARY_DEVICE",
          canonicalData: `${deviceId}:${deviceType}:${platform}:${publicKeyPem.substring(0, 32)}`,
        });

        if (!authResult.valid) {
          return jsonResponse({ error: `Secondary device authorization failed: ${authResult.error}` }, authResult.status || 403);
        }
      }

      const nowIso = new Date().toISOString();
      const devRecord: TrustedDevice = {
        deviceId,
        shopId,
        ownerUid: callerUid,
        deviceType: deviceType as any,
        platform: platform as any,
        deviceModel: deviceModel || "Unknown Device",
        publicKeyPem,
        isActive: true,
        isRevoked: false,
        enrolledAt: nowIso,
        lastVerifiedAt: nowIso,
      };

      const saved = await saveTrustedDevice(devRecord);
      if (!saved) {
        return jsonResponse({ error: "Failed to persist trusted device registration" }, 500);
      }

      return jsonResponse({
        success: true,
        deviceId,
        deviceType,
        platform,
        message: "Device registered and active",
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 3: POST /revoke-device
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/revoke-device")) {
      const { deviceId, reason } = body;
      if (!deviceId) return jsonResponse({ error: "deviceId is mandatory" }, 400);

      const existing = await getTrustedDevice(shopId, deviceId);
      if (!existing) {
        return jsonResponse({ error: `Device ${deviceId} not found.` }, 404);
      }

      existing.isActive = false;
      existing.isRevoked = true;
      existing.lastVerifiedAt = new Date().toISOString();

      await saveTrustedDevice(existing);
      return jsonResponse({
        success: true,
        deviceId,
        message: `Device revoked: ${reason || "Owner request"}`,
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 4: POST /process-debit (WITH UNIFIED HARDWARE SECURITY)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-debit")) {
      const {
        walletId,
        rechargeId,
        idempotencyKey,
        customerPhone,
        operator,
        serviceType,
        amountPaise,
        fundingType,
        commissionEarnedPaise,
        businessDate,
        deviceId,
        deviceSignature,
        nonce,
        notes,
        paymentMode,
        retailAmountPaise,
        costPricePaise,
        partyKey,
        partyName,
      } = body;

      const txnKey = idempotencyKey || rechargeId;
      if (!txnKey || !operator || !amountPaise) {
        return jsonResponse({ error: "Missing mandatory recharge parameters" }, 400);
      }

      if (typeof amountPaise !== "number" || !Number.isSafeInteger(amountPaise) || amountPaise <= 0) {
        return jsonResponse({ error: `Invalid amountPaise: ${amountPaise}. Must be a strictly positive integer.` }, 400);
      }

      const targetWalletId = walletId || `WALLET_${operator.toUpperCase()}`;
      const canonicalData = `${targetWalletId}:${txnKey}:${amountPaise}:${fundingType || "ownPrepaid"}`;

      // Enforce Hardware ECDSA
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_DEBIT",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_debit", {
        p_shop_id: shopId,
        p_wallet_id: targetWalletId,
        p_txn_key: txnKey,
        p_idempotency_key: txnKey,
        p_customer_phone: customerPhone || "RECHARGE_COUNTER",
        p_operator: operator,
        p_service_type: serviceType || "mobile_recharge",
        p_amount_paise: amountPaise,
        p_funding_type: fundingType === "distributorCredit" ? "distributorCredit" : "ownPrepaid",
        p_commission_earned_paise: commissionEarnedPaise || 0,
        p_business_date: businessDate || new Date().toISOString().split("T")[0],
        p_device_id: deviceId,
        p_owner_uid: callerUid,
        p_notes: notes || null,
        p_payment_mode: paymentMode || "Cash",
        p_retail_amount_paise: retailAmountPaise || amountPaise,
        p_cost_price_paise: costPricePaise || null,
        p_party_key: partyKey ? String(partyKey) : null,
        p_party_name: partyName || null,
      });

      if (error) {
        console.error("[process-debit] PostgreSQL RPC Error:", error);
        return jsonResponse({ error: error.message }, 400);
      }

      return jsonResponse({
        success: true,
        rechargeId: txnKey,
        walletId: targetWalletId,
        operator,
        amountPaise,
        balanceBeforePaise: data.balance_before_paise,
        balanceAfterPaise: data.balance_after_paise,
        totalBalancePaise: data.total_balance_paise,
        idempotentReplay: data.idempotent_replay || false,
        message: data.idempotent_replay ? "Recharge debit already processed idempotently" : "Recharge debit completed successfully",
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 5: POST /process-topup (SECURED WITH HARDWARE ECDSA & ATOMIC BANK RESERVATION)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-topup")) {
      const { walletId, amountPaise, source, staffId, staffName, referenceId, description, deviceId, deviceSignature, nonce } = body;

      if (!walletId || !amountPaise || amountPaise <= 0) {
        return jsonResponse({ error: "Invalid topup parameters" }, 400);
      }

      const ref = referenceId || `TOPUP_${Date.now()}`;
      const canonicalData = `${walletId}:${amountPaise}:${ref}:${source || "bank"}`;

      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_TOPUP",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      // 1. Idempotency pre-check against Supabase: Check if reference already processed
      const cleanRef = ref.trim().toUpperCase();
      const { data: existingDep } = await supabase
        .from("recharge_float_deposits")
        .select("*")
        .eq("shop_id", shopId)
        .eq("normalized_ref", cleanRef)
        .maybeSingle();

      if (existingDep) {
        if (Number(existingDep.amount_paise) === Number(amountPaise)) {
          const { data: wallet } = await supabase
            .from("recharge_wallets")
            .select("total_balance_paise, own_prepaid_balance_paise")
            .eq("shop_id", shopId)
            .eq("wallet_id", walletId)
            .single();

          return jsonResponse({
            success: true,
            wallet_id: walletId,
            amount_paise: amountPaise,
            total_balance_paise: wallet?.total_balance_paise ?? 0,
            reference_id: existingDep.deposit_id,
            idempotent_replay: true,
          });
        } else {
          return jsonResponse(
            { error: "Idempotency conflict: reference already processed with different payload" },
            400
          );
        }
      }

      // 2. Race-safe server-authoritative Firestore bank reservation (Phase 16.4.16)
      const isBankSource = !source || source.toLowerCase() === "bank";
      if (isBankSource) {
        const reservation = await reserveBankFundsInFirestore({
          shopId,
          rawToken,
          ref,
          amountPaise,
          walletId,
          callerUid,
          staffName,
        });

        if (!reservation.success) {
          return jsonResponse({ error: reservation.error }, reservation.status || 400);
        }
      }

      // 3. Credit Operator Wallet in Supabase
      const { data, error } = await supabase.rpc("recharge_process_topup", {
        p_shop_id: shopId,
        p_wallet_id: walletId,
        p_amount_paise: amountPaise,
        p_source: source || "bank",
        p_staff_id: staffId || callerUid,
        p_staff_name: staffName || "Owner",
        p_reference_id: ref,
        p_description: description || null,
        p_device_id: deviceId,
      });

      if (error) {
        // Compensate reserved bank funds if Supabase RPC failed
        if (isBankSource) {
          await compensateFailedBankReservation(
            shopId,
            rawToken,
            ref,
            amountPaise / 100.0,
            error.message
          );
        }
        return jsonResponse({ error: error.message }, 400);
      }

      // 4. Finalize voucher in Firestore to SETTLED
      if (isBankSource) {
        await finalizeBankSettlementInFirestore(
          shopId,
          rawToken,
          ref,
          data?.reference_id || ref
        );
      }

      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 6: POST /process-distributor-load (SECURED WITH HARDWARE ECDSA)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-distributor-load")) {
      const { walletId, distributorId, amountPaise, staffId, staffName, notes, deviceId, deviceSignature, nonce } = body;

      if (!walletId || !distributorId || !amountPaise || amountPaise <= 0) {
        return jsonResponse({ error: "Invalid distributor load parameters" }, 400);
      }

      const canonicalData = `${walletId}:${distributorId}:${amountPaise}`;
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_DISTRIBUTOR_LOAD",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_distributor_load", {
        p_shop_id: shopId,
        p_wallet_id: walletId,
        p_distributor_id: distributorId,
        p_amount_paise: amountPaise,
        p_staff_id: staffId || callerUid,
        p_staff_name: staffName || "Owner",
        p_notes: notes || null,
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 7: POST /process-distributor-settlement (SECURED WITH HARDWARE ECDSA)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-distributor-settlement")) {
      const { distributorId, walletId, amountPaise, paymentMode, staffId, referenceId, notes, deviceId, deviceSignature, nonce } = body;

      if (!distributorId || !walletId || !amountPaise || amountPaise <= 0) {
        return jsonResponse({ error: "Invalid settlement parameters" }, 400);
      }

      const canonicalData = `${distributorId}:${walletId}:${amountPaise}:${paymentMode || "cash"}`;
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_DISTRIBUTOR_SETTLEMENT",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_distributor_settlement", {
        p_shop_id: shopId,
        p_distributor_id: distributorId,
        p_wallet_id: walletId,
        p_amount_paise: amountPaise,
        p_payment_mode: paymentMode || "cash",
        p_staff_id: staffId || callerUid,
        p_reference_id: referenceId || null,
        p_notes: notes || null,
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 8: POST /process-refund (SECURED WITH HARDWARE ECDSA)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-refund")) {
      const { txnKey, refundMode, reason, staffId, deviceId, deviceSignature, nonce } = body;

      if (!txnKey) return jsonResponse({ error: "txnKey is mandatory" }, 400);

      const canonicalData = `${txnKey}:${refundMode || "cash"}`;
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_REFUND",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_refund", {
        p_shop_id: shopId,
        p_txn_key: txnKey,
        p_refund_mode: refundMode || "cash",
        p_reason: reason || "Customer request",
        p_staff_id: staffId || callerUid,
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 9: POST /process-reversal (SECURED WITH HARDWARE ECDSA)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-reversal")) {
      const { txnKey, operatorReference, reason, staffId, deviceId, deviceSignature, nonce } = body;

      if (!txnKey) return jsonResponse({ error: "txnKey is mandatory" }, 400);

      const canonicalData = `${txnKey}:${operatorReference || ""}`;
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_REVERSAL",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_reversal", {
        p_shop_id: shopId,
        p_txn_key: txnKey,
        p_operator_reference: operatorReference || "",
        p_reason: reason || "Operator failed/reversed",
        p_staff_id: staffId || callerUid,
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 10: POST /process-reconciliation (SECURED WITH HARDWARE ECDSA)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/process-reconciliation")) {
      const { businessDate, actualPhysicalBalancePaise, reconciledBy, deviceId, deviceSignature, nonce } = body;

      const bDate = businessDate || new Date().toISOString().split("T")[0];
      const canonicalData = `${bDate}:${actualPhysicalBalancePaise || 0}`;

      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "PROCESS_RECONCILIATION",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_process_daily_reconciliation", {
        p_shop_id: shopId,
        p_business_date: bDate,
        p_actual_physical_balance_paise: actualPhysicalBalancePaise || 0,
        p_reconciled_by: reconciledBy || callerUid,
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 11: POST /get-wallet (READ-ONLY OWNER AUTHENTICATED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/get-wallet")) {
      const { walletId } = body;
      let { data, error } = await supabase
        .from("recharge_wallets")
        .select("*")
        .eq("shop_id", shopId)
        .eq("wallet_id", walletId)
        .maybeSingle();

      if (error) return jsonResponse({ error: error.message }, 500);

      // Self-healing: if wallet does not exist in PostgreSQL for this shop, idempotently initialize
      if (!data) {
        await supabase.rpc("recharge_initialize_shop_wallets", { p_shop_id: shopId });
        const retry = await supabase
          .from("recharge_wallets")
          .select("*")
          .eq("shop_id", shopId)
          .eq("wallet_id", walletId)
          .maybeSingle();
        data = retry.data;
      }

      return jsonResponse({ success: true, wallet: data });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 11B: POST /initialize-wallets (IDEMPOTENT OWNER AUTHENTICATED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/initialize-wallets")) {
      const { data, error } = await supabase.rpc("recharge_initialize_shop_wallets", {
        p_shop_id: shopId,
      });

      if (error) return jsonResponse({ error: error.message }, 500);

      const { data: wallets, error: wErr } = await supabase
        .from("recharge_wallets")
        .select("*")
        .eq("shop_id", shopId);

      if (wErr) return jsonResponse({ error: wErr.message }, 500);
      return jsonResponse({ success: true, result: data, wallets });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 12: POST /get-distributor (READ-ONLY OWNER AUTHENTICATED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/get-distributor")) {
      const { distributorId } = body;
      const { data, error } = await supabase
        .from("recharge_distributors")
        .select("*")
        .eq("shop_id", shopId)
        .eq("distributor_id", distributorId)
        .maybeSingle();

      if (error) return jsonResponse({ error: error.message }, 500);
      return jsonResponse({ success: true, distributor: data });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 13: POST /get-devices (READ-ONLY OWNER AUTHENTICATED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/get-devices")) {
      const { data, error } = await supabase
        .from("recharge_trusted_devices")
        .select("*")
        .eq("shop_id", shopId);

      if (error) return jsonResponse({ error: error.message }, 500);
      return jsonResponse({
        success: true,
        devices: (data || []).map((d: any) => ({
          deviceId: d.device_id,
          shopId: d.shop_id,
          ownerUid: d.owner_uid,
          deviceType: d.device_type,
          platform: d.platform,
          deviceModel: d.device_model || "",
          isActive: d.is_active,
          isRevoked: d.is_revoked,
          enrolledAt: d.enrolled_at,
          lastVerifiedAt: d.last_verified_at,
        })),
      });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 14: POST /get-commission-controls (READ-ONLY OWNER AUTHENTICATED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/get-commission-controls")) {
      const { data, error } = await supabase.rpc("recharge_get_commission_controls", {
        p_shop_id: shopId,
      });

      if (error) return jsonResponse({ error: error.message }, 500);
      return jsonResponse({ success: true, controls: data || [] });
    }

    // ------------------------------------------------------------------------
    // ENDPOINT 15: POST /update-commission-control (HARDWARE ECDSA SIGNED)
    // ------------------------------------------------------------------------
    if (pathname.endsWith("/update-commission-control")) {
      const {
        operator,
        isEnabled,
        marginBasisPoints,
        reason,
        ownerName,
        deviceId,
        deviceSignature,
        nonce,
      } = body;

      if (!operator || typeof isEnabled !== "boolean") {
        return jsonResponse({ error: "operator and isEnabled (boolean) are mandatory" }, 400);
      }

      if (!reason || typeof reason !== "string" || reason.trim().length < 5) {
        return jsonResponse({ error: "Reason is mandatory (min 5 characters)" }, 400);
      }

      const normOp = operator.toUpperCase().trim();
      const validOps = ["AIRTEL", "JIO", "VI", "BSNL", "OTHER"];
      if (!validOps.includes(normOp)) {
        return jsonResponse({ error: `Invalid operator: ${operator}. Allowed: ${validOps.join(", ")}` }, 400);
      }

      const bpsStr = (marginBasisPoints !== null && marginBasisPoints !== undefined) ? String(marginBasisPoints) : "";
      const canonicalData = `${normOp}:${isEnabled}:${bpsStr}:${reason.trim()}`;

      // Enforce Hardware ECDSA
      const hwAuth = await enforceHardwareSecurity({
        shopId,
        callerUid,
        deviceId,
        nonce,
        deviceSignature,
        operationType: "UPDATE_COMMISSION_CONTROL",
        canonicalData,
      });

      if (!hwAuth.valid) {
        return jsonResponse({ error: hwAuth.error }, hwAuth.status || 403);
      }

      const { data, error } = await supabase.rpc("recharge_update_commission_control", {
        p_shop_id: shopId,
        p_operator: normOp,
        p_is_enabled: isEnabled,
        p_margin_basis_points: marginBasisPoints !== undefined ? marginBasisPoints : null,
        p_owner_uid: callerUid,
        p_owner_name: ownerName || "Owner",
        p_device_id: deviceId || "UNKNOWN_DEVICE",
        p_reason: reason.trim(),
      });

      if (error) return jsonResponse({ error: error.message }, 400);
      return jsonResponse(data);
    }

    return jsonResponse({ error: `Unknown endpoint: ${pathname}` }, 404);
  } catch (err: any) {
    console.error("[recharge-bridge] Handler exception:", err);
    return jsonResponse({ error: err.message || "Internal server error" }, 500);
  }
});
