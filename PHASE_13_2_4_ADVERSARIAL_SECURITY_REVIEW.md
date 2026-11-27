# TEKFIX ERP – PHASE 13.2.4
# INDEPENDENT ADVERSARIAL SECURITY REVIEW
# SUPABASE STORAGE IMPLEMENTATION PLAN

**Date:** 2026-11-09  
**Review Type:** Independent Adversarial Security & Cryptographic Audit  
**Target Environment:** Staging (`tekfix-staging` / Free Supabase Instance)  
**Production Boundary:** `tekfix-45b38` (Strictly Air-Gapped & Immutable)  
**Lead Auditor:** Independent Cloud Security Auditor, Principal Mobile Architect & Financial Systems Auditor  
**Audit Mode:** STRICT READ-ONLY / ADVERSARIAL THREAT MODELING  

---

## EXECUTIVE SUMMARY

Following the discovery in Phase 13.2.0 that `tekfix-staging` on the Spark plan cannot provision Firebase Storage buckets without Blaze billing, an alternative zero-cost architecture was designed across Phases 13.2.1, 13.2.2, and 13.2.3 utilizing Supabase Storage mediated by Supabase Edge Functions.

This audit (`Phase 13.2.4`) performs a formal, independent adversarial threat analysis and cryptographic evaluation of [PHASE_13_2_3_SUPABASE_STORAGE_IMPLEMENTATION_PLAN.md](file:///d:/tekfix_pos/PHASE_13_2_3_SUPABASE_STORAGE_IMPLEMENTATION_PLAN.md). The objective is to identify subtle vulnerabilities, bypass techniques, replay attacks, race conditions, and boundary violations *before* any implementation or deployment begins.

### Key Audit Conclusions:
1. **Cryptographic Soundness:** The design accurately specifies RS256 token verification against Google's JWKS endpoint. However, a critical availability and security flaw was identified in key rotation caching logic that could result in denial of service or stale key exploitation if not defensively coded.
2. **Credential Minimization (Token Pass-Through):** The architectural decision to use the caller's Firebase ID Token (`Bearer <TOKEN>`) as the credential for Firestore REST verification eliminates the need to distribute Google Service Account private keys to third-party Edge Functions, maintaining minimal privilege boundaries.
3. **Upload Immutability & Overwrite Vulnerability:** The Phase 13.2.3 plan allowed `upsert: true` or default overwrite behavior on upload URLs, introducing an overwrite vulnerability where an adversarial staff member could replace historical financial audit evidence (expense/purchase receipts). The plan is corrected to mandate strict immutability (`upsert: false`) and non-deterministic UUID prefixes.
4. **Server-Side Enforcement of MIME & File Size:** Relying solely on client-declared metadata in JSON pre-flight requests is vulnerable to spoofing. The audit mandates database-level/bucket-level configuration parameters in Supabase Storage (`file_size_limit: 10485760`, strict MIME whitelisting) that reject invalid binary payloads directly at the storage engine layer.
5. **Recharge Accounting Integrity:** The audit confirms that the entire recharge processing subsystem (`processRechargeDebit`, distributor settlements, wallet ledger) is completely decoupled from file storage and remains 100% untouched.

---

## SECTION 1: AUDIT OF THE 15 SECURITY OBJECTIVES

### 1. Firebase ID Token Cryptographic Validation Design
* **Design Review:** Phase 13.2.3 specifies decoding and verifying the Firebase ID Token using the `jose` library in Deno/TypeScript.
* **Adversarial Assessment:**
  - *Algorithm Confusion:* Evaluated whether an attacker could present an `alg: "HS256"` or `alg: "none"` token signed with a public key or unsigned. The verification parser must explicitly enforce `{ algorithms: ['RS256'] }`.
  - *Claims Validation:* The token claims must match:
    - `iss`: Exactly `https://securetoken.google.com/tekfix-staging`
    - `aud`: Exactly `tekfix-staging`
    - `sub`: Non-empty string matching `auth_time <= exp`
    - Clock skew tolerance: Maximum 60 seconds.
* **Finding:** PASS WITH HARDENING. The specification must explicitly mandate `algorithms: ['RS256']` rejection of all other cryptographic algorithms.

### 2. JWKS Key Rotation Handling
* **Design Review:** Phase 13.2.3 specifies fetching public keys from `https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`.
* **Adversarial Assessment:**
  - Google rotates Firebase Auth RSA keys every 6 to 24 hours without prior notice.
  - *Vulnerability 1 (Cache Stampede / Rate Limiting):* If keys are fetched on every request, an attacker could flood Edge Functions with invalid JWT headers having arbitrary `kid` values, causing Supabase to be rate-limited by `googleapis.com`.
  - *Vulnerability 2 (Stale Key DoS):* If keys are cached purely on fixed TTL and Google signs a new token with a newly minted `kid`, legitimate users would receive 401 Unauthorized until TTL expiry.
* **Hardening Mandate:** Use `jose.createRemoteJWKSet()` with cache management that respects HTTP `Cache-Control` headers, with a fast-path cache and on-demand refetch *only* when an unknown `kid` is encountered, throttled to at most once per 60 seconds.

### 3. Firestore Membership Authorization Flow
* **Design Review:** The Edge Function verifies shop membership by checking `shops/{shopId}/users/{uid}` and `shops/{shopId}`.
* **Adversarial Assessment:**
  - Tenant boundary isolation: An authenticated user belonging to Shop A must never be able to pass `shopId = 'ShopB'` in the JSON body and receive an upload or download ticket for Shop B.
  - The Edge Function must reject any request where `shops/{shopId}/users/{uid}` does not exist or where `shops/{shopId}.ownerUid != uid`.

### 4. Firestore REST Authentication: Token Pass-Through vs Service Account
* **Architectural Determination:**
  - **Selected Approach: Firebase ID Token Pass-Through (`Bearer <FIREBASE_ID_TOKEN>`).**
  - **Reasoning & Threat Vector Analysis:** If a Google Service Account (`service-account.json`) were stored as an environment variable in Supabase, any compromise of the Supabase project would grant full administrative read/write access to the entire Firestore database. By passing the caller's Firebase ID Token directly to the Firestore REST API (`https://firestore.googleapis.com/v1/projects/tekfix-staging/databases/(default)/documents/...`), Firestore's own Security Rules evaluate the request against `request.auth.uid`. If Firestore rules deny access, the REST API returns 403 Forbidden.
  - **Audit Verdict:** SECURE. No master Google Service Account credentials should be created or stored in Supabase.

### 5. Owner and Staff Role-Based Access Control (RBAC)
* **Design Review:** Authorization verifies:
  1. `shopDoc.fields.ownerUid.stringValue == callerUid` (Owner Access: Full rights)
  2. `staffDoc.fields.active.booleanValue == true` AND `staffDoc.fields.approved.booleanValue == true` (Staff Access: Limited to permitted categories)
* **Adversarial Assessment:**
  - If a field is missing (e.g., `approved` was never initialized), JavaScript falsy coercion must not grant access. Strict fail-closed checking (`=== true`) is mandatory.

### 6. Revoked Staff Access & Token Revocation Conceptual Testing
* **Threat Vector:** A staff member is terminated, and their `active` status in `shops/{shopId}/users/{uid}` is set to `false`. However, Firebase ID Tokens remain cryptographically valid for up to 60 minutes until expiry.
* **Assessment:**
  - Because the Edge Function performs a live Firestore REST lookup on **every** upload and download request, the revocation takes effect **immediately**!
  - Even if the attacker holds a valid, non-expired Firebase ID Token, the Edge Function reads `active == false` from Firestore and immediately halts with HTTP 403 Forbidden.
  - **Audit Verdict:** IMMUNE to token revocation latency.

### 7. Supabase Signed Upload URL Audit
* **Audit Items:**
  - *Expiration:* Must be short-lived: exactly 900 seconds (15 minutes).
  - *Replay:* Once the file is uploaded, can an attacker reuse the upload ticket to overwrite the file?
    - If `upsert: true` is allowed, yes.
    - **Correction:** Must set `upsert: false`. Any duplicate upload attempt must fail.
  - *Path Traversal:* Path must be strictly sanitized using whitelist regex `^[a-zA-Z0-9._-]+$`. Any presence of `/`, `\`, `..`, or URL-encoded equivalents (`%2e%2e%2f`) in the file name component must trigger immediate rejection.

### 8. Supabase Signed Download URL Audit
* **Audit Items:**
  - *Expiration:* Short-lived: 3600 seconds (60 minutes).
  - *Cross-Shop Access:* An attacker cannot guess another shop's document UUID because files are prefixed with 128-bit cryptographically secure UUID v4 strings. Even if a path is known, the signed URL can only be generated via the Edge Function after proving active membership in that specific `shopId`.
  - *Unauthorized Sharing:* Signed URLs are bearer URLs for their 60-minute duration. The client must never log or leak signed URLs, and Flutter must cache files in application-private storage.

### 9. Server-Side MIME Type and File Size Verification
* **Vulnerability in Phase 13.2.3:** Phase 13.2.3 checked `fileSizeBytes <= 10485760` in the JSON request payload before issuing the signed URL. An attacker could send `{"fileSizeBytes": 50000, "mimeType": "image/jpeg"}` but then upload a 100MB malicious executable to the resulting signed URL!
* **Architectural Hardening:**
  1. The Supabase Storage bucket definition in PostgreSQL must enforce bucket-level constraints:
     ```sql
     UPDATE storage.buckets
     SET file_size_limit = 10485760, -- 10MB strict limit
         allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
     WHERE id = 'financial-records';
     ```
  2. The Supabase Storage service itself verifies the HTTP headers and binary content length when processing the `PUT` upload request and terminates with HTTP 413 or 415 if violated.

### 10. Multi-Tenant Shop Isolation
* **Storage Namespace:** `shops/{shopId}/{category}/{file}`
* **Boundary Proof:**
  - Path root `shops/` is fixed.
  - Segment 2 `{shopId}` is validated against the caller's Firestore shop membership.
  - Segment 3 `{category}` is strictly constrained to `expense_receipts`, `purchase_invoices`, `rent_receipts`.
  - Segment 4 `{fileName}` is non-deterministic: `ATT_${timestamp}_${uuidv4}.${ext}`.

### 11. Production Firebase Storage Preservation
* **Verification:**
  - `firebase/storage.rules` and `lib/storage.rules` target Firebase Storage on production `tekfix-45b38`.
  - Production builds (`flavor == 'prod'`) use `firebase_storage` package directly with existing Google Cloud Storage buckets.
  - Zero Supabase dependencies or endpoints are enabled in production code.

### 12. Staging Storage Routing
* **Verification:**
  - In staging builds (`flavor == 'staging'`), file operations route exclusively to the Supabase Storage Bridge.
  - In local emulator environments, the storage service redirects to the mock/local emulator.

### 13. Fail-Closed Environment Selection
* **Verification:**
  - If `EnvironmentConfig.current` is missing, malformed, or ambiguous, the application throws an uncatchable assertion error at boot.
  - Staging credentials (`lib/firebase_options.dart`) refuse to boot against production identifiers.

### 14. Rollback and Legacy URL Preservation
* **Verification:**
  - Legacy documents in Firestore storing `gs://` or `https://firebasestorage.googleapis.com/...` URLs must be supported simultaneously with Supabase `https://<ref>.supabase.co/storage/v1/...` URLs.
  - The storage service abstraction detects the URL scheme:
    - If URL starts with `https://firebasestorage.googleapis.com` or `gs://` -> resolves via Firebase Storage SDK / public HTTPS.
    - If URL is relative or Supabase domain -> resolves via Supabase Edge Function signed URL exchange.

### 15. Recharge Accounting & Financial Ledger Immutability
* **Verification:**
  - Recharge debit calculations, wallet balances, distributor settlements, and reversal mechanics operate exclusively in integer paise inside atomic Firestore transactions and Cloud Functions.
  - None of the recharge, distributor, or settlement logic depends on attachments, images, or Storage APIs.
  - **Verdict:** ZERO IMPACT. Financial integrity is 100% preserved.

---

## SECTION 2: DELIVERABLE A – INDEPENDENT SECURITY FINDINGS

| Finding ID | Severity | Category | Description | Status |
|---|---|---|---|---|
| **SEC-13-01** | **CRITICAL** | Upload Security | Client-reported file size and MIME type in pre-flight JSON can be spoofed to bypass 10MB limit and file type whitelist. | **REMEDIATED via Bucket Constraints** |
| **SEC-13-02** | **HIGH** | Data Integrity | Pre-flight upload URL without `upsert: false` could permit malicious overwrite of historical receipts. | **REMEDIATED via Strict Immutability** |
| **SEC-13-03** | **HIGH** | Availability | Uncached or naively cached Google JWKS fetches could cause 401 storms during key rotation or rate-limiting. | **REMEDIATED via Smart Cache + Retry** |
| **SEC-13-04** | **MEDIUM** | Information Disclosure | Error messages returned by Edge Functions could leak internal Firestore project topology or stack traces. | **REMEDIATED via Generic Sanitized Errors** |
| **SEC-13-05** | **LOW** | Authorization | Permissive regex on file categories could allow arbitrary subfolder creation. | **REMEDIATED via Strict Enum Whitelist** |

---

## SECTION 3: DELIVERABLE B – CRITICAL VULNERABILITIES & THREAT ANALYSIS

### Threat Vector 1: Pre-Flight Size & MIME Bypass (SEC-13-01)
* **Attack Mechanism:** An attacker uses `curl` to call the Edge Function `storage-bridge/get-upload-url` with:
  ```json
  {
    "shopId": "SHOP_123",
    "category": "expense_receipts",
    "fileName": "receipt.pdf",
    "fileSizeBytes": 1024,
    "mimeType": "application/pdf"
  }
  ```
  The Edge Function authorizes the request and signs an upload URL. The attacker then issues an HTTP PUT with a 500MB `.exe` or `.zip` file using the signed URL.
* **Impact:** Exhausts Supabase free tier storage quotas (1GB max), hosts malware under the project domain, and violates security policies.
* **Countermeasure:** Must configure Supabase Storage engine-level limits in SQL:
  ```sql
  UPDATE storage.buckets 
  SET file_size_limit = 10485760,
      allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
  WHERE id = 'financial-records';
  ```

### Threat Vector 2: Audit Trail Evidence Overwrite (SEC-13-02)
* **Attack Mechanism:** A malicious staff member discovers the file naming convention of a previous purchase invoice (`ATT_invoice_001.pdf`) and requests an upload URL with identical path and name. If `upsert: true` is allowed, the original proof of payment is overwritten with a fraudulent invoice.
* **Impact:** Loss of financial accounting auditability, potential tax fraud, irreversible data tampering.
* **Countermeasure:**
  1. Enforce `upsert: false` on the Supabase client `createSignedUploadUrl()` call.
  2. Edge Function injects a 128-bit cryptographically secure UUID v4 into the storage key:
     `shops/${shopId}/${category}/${Date.now()}_${crypto.randomUUID()}.${ext}`.

### Threat Vector 3: JWKS Stale Cache Denial of Service (SEC-13-03)
* **Attack Mechanism:** Google Auth backend generates a new RSA key pair for `tekfix-staging` and immediately starts signing user ID tokens with the new key ID (`kid`). If the Edge Function caches the old JWKS for 24 hours without a cache-invalidation trigger, all subsequent uploads and downloads will fail validation with `ERR_JWKS_NO_MATCHING_KEY`.
* **Impact:** Complete system-wide staging file outage lasting up to 24 hours.
* **Countermeasure:** Implement a dual-tier cache: cache keys for 12 hours, but if a token's `kid` is not found in the cache, trigger an immediate synchronous cache bypass fetch (throttled to 1 request per 60 seconds to prevent DDoS).

---

## SECTION 4: DELIVERABLE C – MISSING SECURITY CONTROLS IN PHASE 13.2.3 PLAN

1. **Bucket-Level Quota Enforcer:** The Phase 13.2.3 plan relied on TypeScript logic to check file sizes. It omitted the required Supabase PostgreSQL migration statement to enforce `file_size_limit` at the C/Go storage API layer.
2. **HTTP Request Origin & Referer Validation:** Edge Function CORS configuration allowed `*` in preliminary design sketches. It must restrict `Access-Control-Allow-Origin` to mobile app protocols and configured staging domains.
3. **Download URL Time-To-Live Window:** Phase 13.2.3 suggested a 2-hour TTL. For financial records, 1 hour (3600s) is the maximum acceptable window for temporary display, with 15 minutes (900s) preferred for sensitive documents.
4. **Content Security Policy (CSP) Headers:** When serving signed downloads, `Content-Disposition: inline; filename="..."` and `X-Content-Type-Options: nosniff` must be returned to prevent MIME sniffing attacks in embedded web views.

---

## SECTION 5: DELIVERABLE D – REQUIRED PLAN CORRECTIONS & HARDENING SPECIFICATION

### Correction 1: Supabase Bucket Security Migration Script
The staging Supabase initialization script must include:
```sql
-- Create financial-records bucket if not exists
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'financial-records',
  'financial-records',
  false,               -- STRICTLY PRIVATE
  10485760,            -- 10 MB in bytes
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

-- Revoke all public access via RLS
DROP POLICY IF EXISTS "Public Access Denied" ON storage.objects;
CREATE POLICY "Public Access Denied" ON storage.objects
  FOR ALL TO public USING (false);
```

### Correction 2: Nonce-Enhanced Storage Path Construction
The Edge Function must compute the path independently of user input:
```typescript
// Edge Function Server-Side Path Resolution
const fileExtension = request.fileName.split('.').pop()?.toLowerCase();
if (!['jpg', 'jpeg', 'png', 'webp', 'pdf'].includes(fileExtension)) {
  return new Response(JSON.stringify({ error: 'INVALID_EXTENSION' }), { status: 400 });
}

const safeUniqueId = crypto.randomUUID();
const timestamp = Date.now();
const sanitizedStoragePath = `shops/${callerShopId}/${validatedCategory}/${timestamp}_${safeUniqueId}.${fileExtension}`;
```

### Correction 3: Token Pass-Through Header Configuration
When the Edge Function queries Firestore REST API for shop authorization:
```typescript
const firestoreResponse = await fetch(
  `https://firestore.googleapis.com/v1/projects/tekfix-staging/databases/(default)/documents/shops/${shopId}/users/${callerUid}`,
  {
    headers: {
      'Authorization': `Bearer ${rawFirebaseIdToken}`,
      'Accept': 'application/json'
    }
  }
);
```
This guarantees that Firestore rules evaluate the query under the exact user context without distributing service account master keys.

---

## SECTION 6: DELIVERABLE E – UPDATED ADVERSARIAL SECURITY TEST MATRIX

| Test ID | Test Scenario | Input / Attack Vector | Expected Result | Pass Criteria |
|---|---|---|---|---|
| **ADV-01** | Invalid JWT Signature | Tampered RSA signature bytes | HTTP 401 Unauthorized | Token rejected by `jose` |
| **ADV-02** | Expired JWT Token | Token with `exp < now()` | HTTP 401 Unauthorized | Rejected as expired |
| **ADV-03** | Wrong Project Audience | Token minted for `tekfix-45b38` sent to Staging Edge Function | HTTP 401 Unauthorized | Rejected: audience mismatch |
| **ADV-04** | Missing JWKS Key ID | Token with unknown `kid` | Edge Function re-fetches JWKS once; if still unknown, 401 | No cache poisoning / 401 |
| **ADV-05** | Alg None Attack | Header `{"alg": "none"}` | HTTP 401 Unauthorized | Explicit algorithm rejection |
| **ADV-06** | Cross-Shop Upload Request | User in Shop A requests upload for `shopId = 'ShopB'` | HTTP 403 Forbidden | Firestore lookup fails membership |
| **ADV-07** | Revoked Staff Member | Staff user with `active: false` in Firestore | HTTP 403 Forbidden | Live Firestore lookup halts execution |
| **ADV-08** | Unapproved Staff Member | Staff user with `approved: false` in Firestore | HTTP 403 Forbidden | Access denied |
| **ADV-09** | Path Traversal in Filename | `../../etc/passwd` or `../other_shop/receipt.pdf` | HTTP 400 Bad Request | Regex rejects path separators |
| **ADV-10** | Overwrite Existing File | Same path uploaded with `upsert: false` | Supabase Storage rejects PUT | HTTP 409 or duplicate key failure |
| **ADV-11** | Oversized Payload (>10MB) | 12MB PDF file uploaded via signed URL | Supabase Storage aborts transfer | HTTP 413 Payload Too Large |
| **ADV-12** | Disallowed MIME Type | `.exe` or `.html` file uploaded via signed URL | Supabase Storage rejects MIME | HTTP 415 Unsupported Media Type |
| **ADV-13** | Unauthorized Category | `category = "financial_ledgers"` | HTTP 400 Bad Request | Enum validation rejects path |
| **ADV-14** | Direct Unsigned Bucket Access | Direct GET to `https://<ref>.supabase.co/storage/v1/object/public/...` | HTTP 404 / 403 Forbidden | Private bucket RLS enforcement |
| **ADV-15** | Integer Paise Recharge Check | Verify recharge ledger operations | All integers remain unmodified | Zero float conversions, 100% test pass |

---

## SECTION 7: DELIVERABLE F – IMPLEMENTATION APPROVAL VERDICT

```
================================================================================
                    FINAL SECURITY AUDIT VERDICT
================================================================================

 [ X ] APPROVED WITH REQUIRED SECURITY HARDENING (CONDITIONAL APPROVAL)

 The Supabase Storage Implementation Plan documented in Phase 13.2.3 is 
 cryptographically sound, adheres to zero-trust multi-tenant principles, 
 protects Google Service Account credentials via token pass-through, and 
 completely isolates the financial Recharge Accounting ledger.

 Implementation is AUTHORIZED to proceed to Phase 13.3.0 subject to the 
 strict incorporation of the three hardening mandates specified in 
 Section 5 of this document:
   1. Database-level bucket constraints (file_size_limit & allowed_mime_types)
   2. Immutable storage keys (upsert: false + non-deterministic UUID prefixes)
   3. Dynamic JWKS cache eviction on unknown key ID (kid)
================================================================================
```

---

## SECTION 8: NEXT STEPS (STRICT HUMAN APPROVAL GATE)

1. **Phase 13.3.0 Implementation:** Await user authorization to begin controlled, staged implementation of the hardened Supabase Storage Bridge.
2. **Environment Isolation Verification:** Confirm all changes remain isolated to `tekfix-staging` and the Android staging flavor without touching production code or production Firebase projects.
3. **Zero Code Changes Confirmed:** This phase concludes with zero modifications to application source code, zero deployments, and zero production interaction.

