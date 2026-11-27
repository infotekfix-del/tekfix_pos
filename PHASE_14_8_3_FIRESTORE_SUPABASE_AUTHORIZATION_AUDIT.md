# TEKFIX ERP – PHASE 14.8.3
## CRITICAL FIRESTORE SECURITY RULES vs SUPABASE EDGE FUNCTION AUTHORIZATION AUDIT

**Date:** 2026-11-09  
**Role:** Independent Principal Cloud Security Architect, Firebase Security Specialist, PostgreSQL Financial Auditor  
**Audit Mode:** STRICT READ-ONLY ADVERSARIAL SECURITY AUDIT  
**Production Target:** `tekfix-45b38` (UNTOUCHED — ₹0.00 Budget Preserved)  
**Deliverable File:** `PHASE_14_8_3_FIRESTORE_SUPABASE_AUTHORIZATION_AUDIT.md`  
**Final Audit Verdict:** **FAIL / BLOCKER** (Critical Authorization Paradox & Un-deployed Backend)  

---

### TABLE OF CONTENTS
1. [Executive Summary & The Core Paradox](#1-executive-summary--the-core-paradox)
2. [Section 1: Firestore Authorization Analysis & REST Pass-Through Mechanics](#2-section-1-firestore-authorization-analysis--rest-pass-through-mechanics)
3. [Section 2: Firebase ID Token Validation Rigor](#3-section-2-firebase-id-token-validation-rigor)
4. [Section 3: Owner Device Trust & Anti-Spoofing Architecture](#4-section-3-owner-device-trust--anti-spoofing-architecture)
5. [Section 4: Financial Atomicity & Concurrency Safety](#5-section-4-financial-atomicity--concurrency-safety)
6. [Section 5: Supabase Credential Protection & RLS Isolation](#6-section-5-supabase-credential-protection--rls-isolation)
7. [Section 6: Zero-Cost Reliability & Free Plan SLA Analysis](#7-section-6-zero-cost-reliability--free-plan-sla-analysis)
8. [Section 7: Item-by-Item Verdict Matrix](#8-section-7-item-by-item-verdict-matrix)
9. [Section 8: The Required Architectural Remediation Blueprint](#9-section-8-the-required-architectural-remediation-blueprint)

---

### 1. EXECUTIVE SUMMARY & THE CORE PARADOX

This Phase 14.8.3 adversarial security audit investigates the exact interaction between Google Cloud Firestore Security Rules and the Supabase Edge Function bridge.

#### The Fundamental Architectural Blocker Identified:
In the proposed Phase 13.6 architecture, the Supabase Edge Function forwards the caller's Firebase ID Token to the Google Cloud Firestore v1 REST API (`Authorization: Bearer ${rawToken}`) to execute wallet debits and ledger postings.

This design creates a severe **Security Paradox**:
1. **Firestore Evaluates Rules on the Caller Identity:** When the Firestore REST API receives an end-user Firebase Auth token, it does **not** run with privileged administrative rights. It evaluates `firestore.rules` against the caller (`request.auth.uid`).
2. **Current Rules Must Permit the Owner:** For the Edge Function's REST commit to succeed, `firestore.rules` **must** allow `isOwner(shop)` to update `recharge_wallets` and create `recharge_transactions`.
3. **The Bypass Exploit:** Because Firestore Security Rules cannot inspect ECDSA P-256 signatures or challenge nonces, **any client or attacker possessing the owner's Firebase Auth token can bypass the Supabase Edge Function entirely and call the Firestore REST API directly**. They can arbitrarily inflate wallet balances or fabricate transactions from an un-enrolled device or a cURL script without any hardware cryptographic signature!
4. **The "Trusted Device" Rule Rejection:** Conversely, if `firestore.rules` blocks client writes (`allow write: if false`), the Edge Function's REST commit **will also be rejected with HTTP 403 PERMISSION DENIED** when forwarding the user's ID token.
5. **Verdict:** **FAIL / BLOCKER**. The Bearer Token Pass-Through model cannot simultaneously enforce hardware device gates while allowing Firestore writes on an end-user token. A privileged, zero-cost Google Cloud IAM Service Account token exchange is mandatory.

---

### 2. SECTION 1: FIRESTORE AUTHORIZATION ANALYSIS & REST PASS-THROUGH MECHANICS

#### A. What authentication identity does Firestore receive?
- In [supabase/functions/recharge-bridge/index.ts](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L556-L563):
  ```typescript
  const commitRes = await fetch(commitUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${rawToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(commitPayload),
  });
  ```
- **Identity Received:** Google Firestore parses the HTTP `Authorization: Bearer <TOKEN>` header. Because `rawToken` is an end-user JWT issued by `securetoken.google.com/tekfix-45b38`, Firestore sets:
  - `request.auth.uid = token.sub` (the authenticated user's Firebase Auth UID).
  - `request.auth.token = <JWT Claims>`.

#### B. Does Firestore evaluate the original user's Security Rules?
- **YES.** Firestore does **not** treat this request as coming from an administrative server. It evaluates [firebase/firestore.rules](file:///d:/tekfix_pos/firebase/firestore.rules) against `request.auth`.
- If the token belongs to a staff member, `isOwner(shop)` returns `false`.
- If the token belongs to the owner, `isOwner(shop)` returns `true`.

#### C. Are financial writes explicitly denied to ordinary authenticated clients?
- **Staff Accounts:** **YES.** In `firebase/firestore.rules` (lines 399–426), all writes to `recharge_wallets`, `recharge_transactions`, and `recharge_wallet_logs` require `isOwner(shop)`. Staff members are completely denied direct write access.
- **Owner Accounts:** **NO.** In `firebase/firestore.rules`:
  ```javascript
  match /recharge_wallets/{walletId} {
    allow update: if isOwner(shop) && ...;
  }
  match /recharge_transactions/{txnId} {
    allow create: if isOwner(shop);
    allow update: if isOwner(shop);
  }
  match /recharge_wallet_logs/{logId} {
    allow create: if isOwner(shop);
  }
  ```
  The owner is explicitly permitted to write directly to all three financial collections.

#### D. Will the Edge Function's REST commits be denied?
- **For Wallets & Transactions:** **NO.** Because the rules permit `isOwner(shop)`, the Edge Function's REST commit will be **accepted**.
- **For `trusted_devices` & `device_challenges`:** **YES.** Lines 645–657 of `firestore.rules` state:
  ```javascript
  match /trusted_devices/{deviceId} { allow write: if false; }
  match /device_challenges/{nonceId} { allow read, write: if false; }
  ```
  Any REST commit attempting to write device records to Firestore with `Bearer ${rawToken}` is rejected with `HTTP 403 PERMISSION_DENIED`. This is why Phase 13.6 diverted device storage into PostgreSQL.

#### E. The Security Dilemma (Why this is a Critical Blocker)
Because `recharge_wallets` allows `isOwner(shop)` direct update access:
- An attacker who steals the owner's Firebase credentials (phishing, session cookie theft, browser compromise) can issue a standard `PATCH` request directly to:
  `https://firestore.googleapis.com/v1/projects/tekfix-45b38/databases/(default)/documents/shops/{shopId}/recharge_wallets/WALLET_JIO`
  with body `{"fields": {"ownPrepaidBalancePaise": {"integerValue": "9999999"}}}`.
- Firestore evaluates `isOwner(shop)` $\rightarrow$ **PASS**.
- Balance is modified **without going through the Edge Function, without checking device registration, without checking the 2-device quota, and without an ECDSA P-256 signature from the hardware enclave**.
- **This destroys the entire hardware security boundary.**

---

### 3. SECTION 2: FIREBASE ID TOKEN VALIDATION RIGOR

The token validation engine in [supabase/functions/recharge-bridge/index.ts](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L88-L111) was audited:

| Token Validation Check | Implementation Code in `index.ts` | Evaluation | Line References |
|:---|:---|:---:|:---|
| **RS256 Algorithm Check** | `if (decodedHeader.alg !== "RS256") throw ...` | **PASS** | Lines 93–95 |
| **`kid` Header Presence** | `if (!decodedHeader.kid) throw ...` | **PASS** | Lines 89–92 |
| **Google JWKS Verification** | Fetches Google JWKS; imports public key via `jose.importJWK` | **PASS** | Lines 53–86, 104 |
| **Dynamic Key Rotation** | Refetches on missing `kid` with 60s rate limit throttle | **PASS** | Lines 59–62, 101 |
| **Issuer Binding** | `issuer: "https://securetoken.google.com/" + FIREBASE_PROJECT_ID` | **PASS** | Line 106 |
| **Audience Binding** | `audience: FIREBASE_PROJECT_ID` | **PASS** | Line 107 |
| **Expiration & Issued-At** | Validated natively inside `jose.jwtVerify()` | **PASS** | Lines 105–108 |
| **UID Extraction** | `callerUid = tokenPayload.sub` (never from user body) | **PASS** | Lines 617–618 |
| **Live Shop Owner Lookup** | Live fetch of `/shops/{shopId}` and `/users/{callerUid}` | **PASS** | Lines 117–148 |
| **Suspended User Check** | `active !== false && approved !== false` | **PASS** | Lines 144–145 |
| **Staff Rejection** | Returns `HTTP 403` if user role is not `owner`/`admin` | **PASS** | Lines 634–640 |

**Identified Missing Check:**
- **Token Revocation Endpoint:** The Edge Function validates JWT cryptographic signatures, but does not query Firebase Auth's `checkRevoked` API. A token revoked via the Firebase Admin SDK remains valid for up to 60 minutes until its expiration timestamp. However, this is partially mitigated by the live Firestore user document lookup (`active: false` stops the user immediately).

---

### 4. SECTION 3: OWNER DEVICE TRUST & ANTI-SPOOFING ARCHITECTURE

1. **Two-Device Hard Quota:**
   - Validated in `POST /register-device` ([index.ts lines 690–697](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L690-L697)).
   - `getActiveDeviceCount(shopId)` enforces `activeCount < 2`.
   - `deviceType` must be strictly `mobile` or `laptop`; `platform` must be `android` or `windows`.
2. **Staff Enrollment & Execution Lockout:**
   - In both `POST /register-device` and `POST /process-debit`, `verifyShopOwner()` executes first. Staff tokens are rejected with `HTTP 403 Forbidden` before any device lookup or transaction execution.
3. **Immediate Revocation Enforcement:**
   - In `POST /process-debit` ([index.ts lines 785–788](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L785-L788)):
     `if (!dev || !dev.isActive || dev.isRevoked) return 403`.
   - Revoked devices are barred from requesting challenges or signing transactions.
4. **Single-Use Cryptographic Nonce & Replay Defense:**
   - Nonces generated using `crypto.randomUUID()` with a 300-second (5-minute) TTL.
   - `consumeChallengeNonce()` ([index.ts lines 357–392](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L357-L392)) updates `consumed = true` in PostgreSQL before signature verification.
   - Any replayed nonce fails with `HTTP 403: Challenge nonce is invalid, expired, or already consumed`.
5. **Anti-Spoofing of Device Identity:**
   - The caller cannot spoof an authorized device by submitting another device's ID in the JSON body. The Edge Function pulls the `publicKeyPem` **from the database record matching `deviceId`**, not from the client payload. If the caller does not hold the physical private key corresponding to that public key, signature verification fails.

---

### 5. SECTION 4: FINANCIAL ATOMICITY & CONCURRENCY SAFETY

#### 5.1 Multi-Document Atomic Commit via REST API
In `executeFirestoreDebitCommit()` ([index.ts lines 489–554](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L489-L554)):
- Submits an atomic batch containing:
  1. Wallet balance decrement with precondition:
     ```json
     "currentDocument": { "updateTime": "<PREVIOUS_UPDATE_TIME>" }
     ```
  2. Transaction record creation with precondition:
     ```json
     "currentDocument": { "exists": false }
     ```
  3. Immutable wallet log creation with precondition:
     ```json
     "currentDocument": { "exists": false }
     ```
- **Concurrency Conflicts (HTTP 412 / 409):** Handled with exponential backoff and randomized jitter over 3 retries ([index.ts lines 574–579](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L574-L579)).
- **Double-Debit Prevention:** If the transaction already exists with `walletDebited: true`, the function recognizes the idempotent replay and returns the existing balance without re-executing the debit ([index.ts lines 437–459](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L437-L459)).
- **Integer Paise Integrity:**
  - `Number.isSafeInteger(amountPaise) && amountPaise > 0` strictly enforced ([index.ts lines 776–778](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L776-L778)).
  - Insufficient balance rejects immediately ([index.ts line 478](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L478)). Zero negative balances allowed.

---

### 6. SECTION 5: SUPABASE CREDENTIAL PROTECTION & RLS ISOLATION

1. **`service_role` Key Exposure Audit:**
   - Scanned `lib/recharge/supabase_recharge_bridge_client.dart` and the entire Flutter codebase:
   - **Result:** The Supabase `service_role` master key is **nowhere in client code**.
   - The Flutter client only holds standard Firebase user tokens and passes them in `Authorization: Bearer <TOKEN>`.
2. **Row-Level Security (RLS) Policies:**
   - In [supabase/migrations/20261109000001_recharge_trusted_devices.sql](file:///d:/tekfix_pos/supabase/migrations/20261109000001_recharge_trusted_devices.sql#L42-L57):
     ```sql
     CREATE POLICY "Deny public access to trusted devices" ON public.recharge_trusted_devices
         FOR ALL TO anon, authenticated USING (false);
     CREATE POLICY "Deny public access to challenges" ON public.recharge_device_challenges
         FOR ALL TO anon, authenticated USING (false);
     ```
   - Direct REST API calls to `/rest/v1/recharge_trusted_devices` with the public `anon` key are rejected by PostgreSQL. Only the server-side Edge Function (which holds the service role secret internally) can query or mutate device tables.

---

### 7. SECTION 6: ZERO-COST RELIABILITY & FREE PLAN SLA ANALYSIS

1. **Quota Headroom (Guaranteed ₹0.00/Month):**
   - Edge Function Invocations: 500,000/month free quota (TekFix uses ~4,500/month $\rightarrow$ **110x Headroom**).
   - PostgreSQL Storage: 500 MB free quota (TekFix device records use $< 2\text{ MB}$ $\rightarrow$ **250x Headroom**).
   - Egress Bandwidth: 5 GB/month free quota (TekFix uses $< 25\text{ MB}$ $\rightarrow$ **200x Headroom**).
   - **Cost Verdict:** Strict ₹0.00/month budget is preserved. No credit card required.
2. **The 7-Day Inactivity Pause Risk:**
   - *Constraint:* Supabase pauses free databases after 7 consecutive days of zero API calls.
   - *Impact:* If the store closes for an 8-day festival or holiday, the database pauses. Subsequent requests receive HTTP 503 until unpaused in the Supabase Dashboard (~60 seconds).
   - *Fail-Closed Mitigation:* If Supabase is paused or unreachable, `SupabaseRechargeBridgeClient` throws an exception, and the transaction is safely buffered in the **Offline Queue** with local balance reservation. It will flush once the backend resumes.
3. **Availability Limitations:**
   - Neither Firebase Spark nor Supabase Free provides a contractually binding 99.9% SLA. Occasional maintenance windows can occur. The offline queue architecture ensures business continuity during temporary cloud downtime.

---

### 8. SECTION 7: ITEM-BY-ITEM VERDICT MATRIX

| # | Evaluation Category | Verdict | Technical Findings & Source Code References |
|:---:|:---|:---:|:---|
| **A** | **Firestore Authorization Compatibility** | **BLOCKER** | Using user ID token pass-through requires `isOwner(shop)` on `recharge_wallets` in `firestore.rules` (L399-426), creating a direct Firestore REST API write bypass that circumvents the Edge Function and hardware ECDSA. |
| **B** | **Firebase Token Verification** | **PASS** | Validates RS256, Google JWKS, `kid`, issuer, audience, exp, and extracts `sub` strictly ([index.ts L88-111](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L88-L111)). |
| **C** | **Owner-Only Authorization** | **PASS** | Live Firestore lookup against `shops/{shopId}` and `users/{callerUid}` ([index.ts L117-148](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L117-L148)). |
| **D** | **Staff Isolation** | **PASS** | Staff accounts rejected with HTTP 403 at Edge Function ([index.ts L634-640](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L634-L640)) and Firestore rules ([firestore.rules L421-426](file:///d:/tekfix_pos/firebase/firestore.rules#L421-L426)). |
| **E** | **Device Trust** | **PASS** | Max 2 devices, mobile/laptop, registered SPKI public key used for verification ([index.ts L674-726](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L674-L726)). |
| **F** | **Nonce & Replay Protection** | **PASS** | 128-bit CSPRNG nonces, 300s TTL, consumed atomically in Postgres before signature validation ([index.ts L357-392](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L357-L392)). |
| **G** | **Financial Atomicity** | **PASS** | Multi-document Firestore REST `:commit` with `updateTime` lock and `{ exists: false }` ([index.ts L489-554](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts#L489-L554)). |
| **H** | **Supabase Credential Protection**| **PASS** | No `service_role` in Flutter client ([supabase_recharge_bridge_client.dart L20-72](file:///d:/tekfix_pos/lib/recharge/supabase_recharge_bridge_client.dart#L20-L72)); RLS denies public access ([sql L42-57](file:///d:/tekfix_pos/supabase/migrations/20261109000001_recharge_trusted_devices.sql#L42-L57)). |
| **I** | **Backup Compatibility** | **PASS** | Firestore remains sole authoritative ledger; 13 collections backed up by `firestore_backup_runner.js`. |
| **J** | **Free-Plan Reliability** | **PASS** | Ample quota (110x headroom); ₹0/month; daily store activity keeps project active; offline queue handles downtime. |
| **K** | **Production Feasibility** | **FAIL / BLOCKER**| 1) Remote Supabase Edge Function is not deployed; 2) The direct Firestore bypass vector in Category A must be closed with a Google Service Account before deployment. |

---

### 9. SECTION 8: THE REQUIRED ARCHITECTURAL REMEDIATION BLUEPRINT

To resolve the Category A authorization paradox permanently while maintaining **100% ₹0.00 cost** (no Blaze plan):

```
                                  [ THE AIRTIGHT ZERO-COST ARCHITECTURE ]
                                                     │
   [ Flutter App on Trusted Device ]                 │
      1. Firebase Auth SignIn                        │
      2. Sign Challenge Nonce with Hardware Key      │
      3. POST /process-debit                         │
         Header: Bearer <FIREBASE_ID_TOKEN>          │
         Body: { shopId, deviceId, nonce, ... }      │
                                                     ▼
                                 [ Supabase Edge Function (Deno Deploy) ]
                                   1. Verify Firebase ID Token via Google JWKS (RS256)
                                   2. Verify Owner Role in shops/{shopId}
                                   3. Consume Nonce & Verify ECDSA P-256 via WebCrypto
                                   4. Exchange Free Google IAM Service Account Key
                                      for Scoped Google OAuth2 Access Token
                                      (https://oauth2.googleapis.com/token)
                                                     │
                                                     ▼
                                 [ Google Cloud Firestore REST API ]
                                   POST /v1/projects/tekfix-45b38/...:commit
                                   Header: Bearer <GOOGLE_SERVICE_ACCOUNT_OAUTH_TOKEN>
                                   Precondition: updateTime / exists: false
                                                     │
                                                     ▼
                                 [ Hardened Firestore Security Rules ]
                                   match /recharge_wallets/{walletId} {
                                     allow read: if isShopMember(shop);
                                     allow write: if false;  <─── BLOCKS ALL DIRECT CLIENT WRITES!
                                   }
                                   match /recharge_transactions/{txnId} {
                                     allow read: if isShopMember(shop);
                                     allow write: if false;  <─── BLOCKS ALL DIRECT CLIENT WRITES!
                                   }
```

#### Why This Completely Resolves the Blocker:
1. **Google Cloud Service Accounts are 100% FREE ($0 / ₹0):** Google IAM service accounts do not require the Blaze plan or a credit card. They are completely free on standard Google Cloud / Firebase Spark.
2. **Air-Tight Database Protection:** By locking `recharge_wallets` and `recharge_transactions` to `allow write: if false`, **NO client, browser, or cURL script can modify balances directly**, even with a stolen owner password.
3. **Hardware Trust Enforced at Server Boundary:** The only entity capable of debiting wallets is the Supabase Edge Function, which executes the write using the scoped Google Service Account **only after the hardware ECDSA P-256 signature is mathematically verified**.

---

### AUDITOR CERTIFICATION NOTICE
This audit was performed in strict read-only mode. Production project `tekfix-45b38` remained untouched. No code or configuration was modified. The overall verdict is **`FAIL / BLOCKER`** until the Service Account token exchange remediation is implemented and remote deployment is completed.

