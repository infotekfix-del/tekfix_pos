// ============================================================================
// TEKFIX ERP - PHASE 13.3.0: SUPABASE EDGE FUNCTION (storage-bridge)
// DENO / TYPESCRIPT BACKEND IMPLEMENTATION
// ============================================================================
//
// Mandatory Security Implementations:
// 1. JWT validation against Google JWKS with dynamic cache invalidation on unknown kid.
// 2. Token pass-through to Firestore REST API for shop authorization.
// 3. Immutability enforcement: upsert: false and non-deterministic UUID prefixes.
// 4. Server-side MIME and file size validation (backed by storage.buckets constraints).
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@4.14.4";

// Environment Configuration
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const STAGING_FIREBASE_PROJECT_ID = "tekfix-staging";
const BUCKET_NAME = "financial-records";

// Bounded JWKS Caching Structure
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

const MIN_REFETCH_INTERVAL_MS = 60 * 1000; // 60s throttle to prevent stampede
const GOOGLE_JWKS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

/**
 * Fetch Google JWKS with dynamic cache invalidation when an unknown `kid` is encountered.
 */
async function getGooglePublicKey(kid: string, forceRefetch = false): Promise<any> {
  const now = Date.now();

  // If key is cached and not expired, return immediately
  if (!forceRefetch && now < jwkCache.expiresAt && jwkCache.keys.has(kid)) {
    return jwkCache.keys.get(kid);
  }

  // Throttle forced refetch to avoid rate limiting from Google
  if (forceRefetch && (now - jwkCache.lastFetchTime) < MIN_REFETCH_INTERVAL_MS) {
    if (jwkCache.keys.has(kid)) return jwkCache.keys.get(kid);
    throw new Error(`Rate limit exceeded for JWKS refetch. Key ID "${kid}" remains unknown.`);
  }

  // Fetch updated JWKS from Google
  const response = await fetch(GOOGLE_JWKS_URL);
  if (!response.ok) {
    throw new Error(`Failed to fetch Google JWKS: ${response.statusText}`);
  }

  // Parse Cache-Control header or default to 6 hours
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

/**
 * Cryptographically verify Firebase ID Token using RS256 and Google JWKS.
 */
async function verifyFirebaseIdToken(token: string): Promise<jose.JWTPayload> {
  const decodedHeader = jose.decodeProtectedHeader(token);
  if (!decodedHeader.kid) {
    throw new Error("Token missing 'kid' in header.");
  }
  if (decodedHeader.alg !== "RS256") {
    throw new Error(`Unsupported token algorithm "${decodedHeader.alg}". Only RS256 is permitted.`);
  }

  let jwk: any;
  try {
    jwk = await getGooglePublicKey(decodedHeader.kid, false);
  } catch (_e) {
    // Dynamic cache invalidation on unknown kid: retry once with forceRefetch = true
    jwk = await getGooglePublicKey(decodedHeader.kid, true);
  }

  const publicKey = await jose.importJWK(jwk, "RS256");
  const { payload } = await jose.jwtVerify(token, publicKey, {
    issuer: `https://securetoken.google.com/${STAGING_FIREBASE_PROJECT_ID}`,
    audience: STAGING_FIREBASE_PROJECT_ID,
  });

  return payload;
}

/**
 * Verify shop membership via Firestore REST API using the caller's ID token.
 */
async function verifyShopMembership(shopId: string, uid: string, rawToken: string): Promise<boolean> {
  const firestoreUrl = `https://firestore.googleapis.com/v1/projects/${STAGING_FIREBASE_PROJECT_ID}/databases/(default)/documents/shops/${shopId}`;

  // 1. Check shop document
  const shopRes = await fetch(firestoreUrl, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!shopRes.ok) return false;
  const shopData = await shopRes.json();
  const ownerUid = shopData.fields?.ownerUid?.stringValue;

  if (ownerUid === uid) return true; // Direct shop owner authorized

  // 2. Check user membership document
  const userRes = await fetch(`${firestoreUrl}/users/${uid}`, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!userRes.ok) return false;
  const userData = await userRes.json();

  const active = userData.fields?.active?.booleanValue ?? true;
  const approved = userData.fields?.approved?.booleanValue ?? true;

  return active && approved;
}

// Main HTTP Server Handler
serve(async (req: Request) => {
  // CORS Headers
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing Bearer token" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const rawToken = authHeader.replace("Bearer ", "").trim();
    const tokenPayload = await verifyFirebaseIdToken(rawToken);
    const callerUid = tokenPayload.sub;

    if (!callerUid) {
      return new Response(JSON.stringify({ error: "Invalid token subject" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const url = new URL(req.url);
    const pathname = url.pathname;
    const body = await req.json();
    const { shopId } = body;

    if (!shopId) {
      return new Response(JSON.stringify({ error: "Missing shopId" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Verify tenant authorization
    const isMember = await verifyShopMembership(shopId, callerUid, rawToken);
    if (!isMember) {
      return new Response(JSON.stringify({ error: "Access Denied: Not an active member of this shop" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // ROUTE A: GET UPLOAD URL
    if (pathname.endsWith("/get-upload-url")) {
      const { category, fileName, fileSizeBytes, mimeType } = body;

      const allowedCategories = ["expense_receipts", "purchase_invoices", "rent_receipts"];
      if (!allowedCategories.includes(category)) {
        return new Response(JSON.stringify({ error: "Invalid storage category" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const allowedMimes = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
      if (!allowedMimes.includes(mimeType)) {
        return new Response(JSON.stringify({ error: "Unsupported MIME type" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (fileSizeBytes > 10 * 1024 * 1024) {
        return new Response(JSON.stringify({ error: "File exceeds 10 MB limit" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Sanitize extension and enforce non-deterministic random UUID prefix
      const cleanExt = fileName.split(".").pop()?.toLowerCase() || "bin";
      const randomId = crypto.randomUUID();
      const storageKey = `shops/${shopId}/${category}/${Date.now()}_${randomId}.${cleanExt}`;

      // Enforce upsert: false (Strict Immutability)
      const { data, error } = await supabase.storage
        .from(BUCKET_NAME)
        .createSignedUploadUrl(storageKey, { upsert: false });

      if (error) {
        return new Response(JSON.stringify({ error: error.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(
        JSON.stringify({
          signedUrl: data.signedUrl,
          storagePath: storageKey,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ROUTE B: GET DOWNLOAD URL
    if (pathname.endsWith("/get-download-url")) {
      const { storagePath, expiresIn = 3600 } = body;

      // Verify path belongs to the requested shop
      if (!storagePath.startsWith(`shops/${shopId}/`)) {
        return new Response(JSON.stringify({ error: "Cross-shop path access forbidden" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const cappedExpiresIn = Math.min(expiresIn, 3600); // Max 1 hour
      const { data, error } = await supabase.storage
        .from(BUCKET_NAME)
        .createSignedUrl(storagePath, cappedExpiresIn);

      if (error) {
        return new Response(JSON.stringify({ error: error.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(
        JSON.stringify({ signedUrl: data.signedUrl }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(JSON.stringify({ error: "Endpoint not found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message || "Internal server error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

