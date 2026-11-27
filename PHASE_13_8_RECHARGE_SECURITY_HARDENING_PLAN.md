# TEKFIX ERP – PHASE 13.8
# FINAL RECHARGE SECURITY HARDENING & DATABASE BOUNDARY ELIMINATION PLAN

**Date:** 2026-11-09  
**Target Environment:** PRODUCTION LIVE (`tekfix-45b38` / Firestore `asia-south1`)  
**Production Budget Constraint:** Strict ₹0.00 (Firebase Spark Plan + Supabase Free Tier – Zero Credit Cards, Zero Payments)  
**Lead Security Architect & Auditor:** Principal Cloud Security Architect, Senior Firebase Engineer, Financial Systems Auditor  
**Mode:** READ-ONLY CONSOLIDATED IMPLEMENTATION PLAN (No Source Code Modified, No Rules Deployed)  

---

## 1. EXECUTIVE SUMMARY & OBJECTIVE

### The Core Problem:
In Phase 13.7, an adversarial security audit verified that while the Supabase Recharge Bridge application tier ([`recharge-bridge/index.ts`](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts)) strictly verifies hardware-bound ECDSA P-256 signatures and nonces, the **Firestore database security rules** ([`firebase/firestore.rules`](file:///d:/tekfix_pos/firebase/firestore.rules)) allow any authenticated shop owner session to write directly to:
- `recharge_wallets`
- `recharge_transactions`
- `recharge_wallet_logs`
- `recharge_commissions`
- `recharge_float_deposits`
- `recharge_daily_reconciliation`

This permits an owner token holder (or an attacker on an un-enrolled device, compromised browser, or cURL script) to completely bypass the hardware-bound trusted-device boundary, modify operator wallet balances directly, and fabricate transactions.

### The Objective:
Permanently eliminate all direct client write access to recharge financial collections in Firestore, restricting writes exclusively to the verified, hardware-authenticated Supabase Edge Function backend, while:
1. **Preserving 100% ERP compatibility:** POS, Stock, Purchases, Repairs, Returns, Expenses, Rent, Staff, and Payroll remain completely unaffected.
2. **Preserving read access:** Real-time dashboards, summaries, and streams continue functioning without interruption.
3. **Preserving ₹0.00 cost:** Zero billing upgrades, zero credit cards, and zero Blaze requirement.
4. **Preserving historical records:** Zero data loss, zero schema breakage.

---

## 2. THREAT MODEL & BYPASS ELIMINATION ARCHITECTURE

```
                      CURRENT VULNERABLE STATE (PHASE 13.6)
                      ────────────────────────────────────
   [Unregistered Device / cURL] ──(Direct Firestore REST)──► [Firestore DB] ──► MODIFIES BALANCE!
                                                                                (Bypasses ECDSA!)

                      HARDENED ZERO-TRUST ARCHITECTURE (PHASE 13.8)
                      ─────────────────────────────────────────────
   [Unregistered Device / cURL] ──(Direct Firestore REST)──► [Firestore DB] ──► HTTP 403 PERMISSION_DENIED!
                                                                                (allow write: if false;)

   [Owner Enrolled Device]
          │
          │ 1. Firebase ID Token + Hardware ECDSA P-256 Signature + Nonce
          ▼
   [Supabase Edge Function]
          │ 2. Validates RS256 Token against Google JWKS
          │ 3. Verifies Owner UID against shops/{shopId}
          │ 4. Verifies Device is Registered, Active, and Non-Revoked (Max 2 Quota)
          │ 5. Validates 300s CSPRNG Nonce and Consumes Atomically
          │ 6. Verifies WebCrypto ECDSA P-256 Signature over Canonical Payload
          │ 7. Verifies Sufficient Positive Integer Paise Balance
          │ 8. Exchanges Scoped Service Account Key for Google OAuth2 Datastore Token (₹0 Cost)
          ▼
   [Firestore REST API (:commit)]
          │ 9. Applies Atomic Optimistic Lock (updateTime) and Idempotency Lock (exists: false)
          ▼
   [Immutable Firestore Ledgers]
```

---

## 3. FIRESTORE SECURITY RULES HARDENING SPECIFICATION

### A. Collections to Lock Down Direct Writes (`allow write: if false;`):
In [`firebase/firestore.rules`](file:///d:/tekfix_pos/firebase/firestore.rules):

1. **`recharge_wallets/{walletId}`**:
   - `allow read: if isShopMember(shop);` (Preserved for dashboards and UI balance displays)
   - `allow create, update, delete: if false;` (Direct client modification permanently revoked)
2. **`recharge_transactions/{txnId}`**:
   - `allow read: if isShopMember(shop);` (Preserved for transaction history)
   - `allow create, update, delete: if false;` (Direct client insertion/mutation permanently revoked)
3. **`recharge_wallet_logs/{logId}`**:
   - `allow read: if isShopMember(shop);` (Preserved for audit ledgers)
   - `allow create, update, delete: if false;` (Direct client insertion permanently revoked)
4. **`recharge_commissions/{id}`**:
   - `allow read: if isShopMember(shop);`
   - `allow create, update, delete: if false;`
5. **`recharge_float_deposits/{id}`**:
   - `allow read: if isShopMember(shop);`
   - `allow create, update, delete: if false;`
6. **`recharge_daily_reconciliation/{businessDate}`**:
   - `allow read: if isShopMember(shop);`
   - `allow create, update, delete: if false;`
   - `match /corrections/{correctionId} { allow read: if isShopMember(shop); allow write: if false; }`
7. **`trusted_devices/{deviceId}` & `device_challenges/{nonceId}`**:
   - `allow read: if isOwner(shop);`
   - `allow write: if false;`

### B. Conditional Hardening for Shared Collection `accounting_cash_bank/{txId}`:
`accounting_cash_bank` is shared across POS, Expenses, Rent, Purchases, Repairs, and Recharge.
To deny direct recharge writes while leaving non-recharge ERP modules 100% operational:

```javascript
match /accounting_cash_bank/{txId} {
  allow read: if isShopMember(shop);

  // Recharge transactions MUST NOT be written directly by client
  allow create: if isShopMember(shop) &&
    !('isRecharge' in request.resource.data && request.resource.data.isRecharge == true) &&
    !txId.matches('CB_DIST_PAY_.*') &&
    !txId.matches('CB_RECHARGE_.*');

  allow update: if isShopMember(shop) &&
    !('isRecharge' in resource.data && resource.data.isRecharge == true) &&
    !('isRecharge' in request.resource.data && request.resource.data.isRecharge == true) &&
    !txId.matches('CB_DIST_PAY_.*') &&
    !txId.matches('CB_RECHARGE_.*');

  allow delete: if isOwner(shop) &&
    !('isRecharge' in resource.data && resource.data.isRecharge == true);
}
```

### C. Verification of Non-Recharge ERP Isolation:
| Module | Collections Targeted | Write Rule Unchanged? | Verification |
| :--- | :--- | :---: | :--- |
| **POS Sales** | `sales`, `sales_invoices`, `sales_orders`, `daily_sales` | **YES** | Completely separate match paths. |
| **Inventory** | `inventory`, `items`, `inventory_logs`, `stockMovements` | **YES** | Completely separate match paths. |
| **Purchases** | `purchases`, `purchase_bills`, `vendor_ledger`, `parties` | **YES** | Completely separate match paths. |
| **Repairs** | `service_jobs`, `services` | **YES** | Completely separate match paths. |
| **Returns** | `returns` | **YES** | Completely separate match paths. |
| **Expenses & Rent** | `expenses`, `rent_records`, `accounting_cash_bank` (non-recharge) | **YES** | Non-recharge paths remain open to `isShopMember(shop)`. |
| **Staff & Payroll** | `staff`, `staff_attendance`, `salary_payments` | **YES** | Completely separate match paths. |

---

## 4. DEDICATED GOOGLE SERVICE ACCOUNT ARCHITECTURE (100% ZERO COST)

### A. Acceptability & Security Assessment:
- **Zero Cost Guarantee:** Google Cloud IAM Service Accounts are **100% FREE** on Google Cloud and Firebase Spark plans. There is zero subscription fee, zero billing requirement, and zero Blaze upgrade needed.
- **Least-Privilege Scoping:**
  - Dedicated ID: `tekfix-recharge-backend@tekfix-45b38.iam.gserviceaccount.com`
  - Assigned IAM Role: `roles/datastore.user` (Cloud Datastore User).
  - Scope: Restricted exclusively to reading and writing Firestore documents.
  - Denied: Cannot access Cloud Storage, Compute, Billing, IAM permissions, or project configuration.
- **Never Exposed to Flutter:**
  - The Service Account private key JSON is stored strictly as an encrypted Supabase Secret: `FIREBASE_SERVICE_ACCOUNT_KEY`.
  - Flutter clients NEVER receive, handle, or store this key.
  - Supabase Edge Functions NEVER print or log the key.

### B. Server-Side OAuth2 Token Exchange Protocol:
In `supabase/functions/recharge-bridge/index.ts`:
1. Parse the service account JSON (`client_email`, `private_key`).
2. Construct and sign an RS256 JWT assertion using WebCrypto:
   - Header: `{ "alg": "RS256", "typ": "JWT" }`
   - Payload:
     ```json
     {
       "iss": "tekfix-recharge-backend@tekfix-45b38.iam.gserviceaccount.com",
       "sub": "tekfix-recharge-backend@tekfix-45b38.iam.gserviceaccount.com",
       "aud": "https://oauth2.googleapis.com/token",
       "scope": "https://www.googleapis.com/auth/datastore",
       "iat": Math.floor(Date.now() / 1000),
       "exp": Math.floor(Date.now() / 1000) + 3600
     }
     ```
3. POST to `https://oauth2.googleapis.com/token` with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`.
4. Cache the resulting `access_token` in memory (valid for 55 minutes) to avoid repeated token calls.
5. Call Firestore REST API (`:commit`) with `Authorization: Bearer <GOOGLE_ACCESS_TOKEN>`.

---

## 5. SUPABASE EDGE FUNCTION ENFORCEMENT OF ALL 8 SECURITY GUARDS

Before any Firestore write is committed via the Service Account token, `supabase/functions/recharge-bridge/index.ts` strictly validates:

1. **Guard 1 (Authentication):** Firebase ID Token verified cryptographically via Google JWKS (RS256) with dynamic cache invalidation on unknown `kid`.
2. **Guard 2 (Tenant & Owner Authorization):** Verifies `ownerUid === callerUid` against `shops/{shopId}`. Rejects staff accounts with HTTP 403 `PERMISSION_DENIED`.
3. **Guard 3 (Mandatory Trusted Device):** Rejects missing, empty, or un-enrolled `deviceId`.
4. **Guard 4 (Device Quota & State):** Verifies device is `isActive: true` and `isRevoked: false`. Enforces maximum 2 active devices (1 Android mobile + 1 Windows laptop).
5. **Guard 5 (Ephemeral Challenge Nonce):** 128-bit CSPRNG nonce generated with 300-second TTL. Atomically consumed (single-use enforced).
6. **Guard 6 (Genuine ECDSA P-256 Signature):** Verifies WebCrypto signature against registered SPKI public key over `${shopId}:${callerUid}:${deviceId}:${nonce}`.
7. **Guard 7 (Integer Paise & Balance Integrity):** Verifies amount is a strictly positive integer in paise and `currentBalancePaise >= amountPaise`.
8. **Guard 8 (Atomic Concurrency & Idempotency):** Commits multi-document write via Firestore `:commit` with `updateTime` lock on wallet and `{ exists: false }` lock on recharge transaction and ledger log.

---

## 6. BACKUP, ROLLBACK & DISASTER RECOVERY PROTOCOL

Per Requirement 11 (*"Verify backup and rollback before changing rules"*):

### A. Pre-Deployment Backup:
1. Create local timestamped backup of the active production rules:
   ```bash
   cp firebase/firestore.rules firebase/firestore.rules.backup.phase13_7
   ```
2. Verify exact SHA-256 hash match against the deployed rules on `tekfix-45b38`.

### B. Instant Rollback Procedure:
If any unexpected permission issue occurs during verification:
1. Revert `firebase/firestore.rules` from `firebase/firestore.rules.backup.phase13_7`.
2. Deploy rollback rules immediately:
   ```bash
   cmd /c "firebase deploy --only firestore:rules --project=tekfix-45b38"
   ```
3. Rollback execution time: **< 30 seconds**.
4. Zero historical data impact: Firestore rules updates alter security filters only, without deleting or corrupting any stored documents.

---

## 7. FREE-TIER BUDGET & COST INVARIANT VERIFICATION

Per Requirement 12 (*"Verify all free-tier limits and possible charges. No billing upgrade or payment is permitted"*):

| Free Tier Parameter | Plan Limit | TekFix Projected Usage | Safety Factor | Cost |
| :--- | :--- | :--- | :--- | :--- |
| **Google Cloud Service Account** | Unlimited | 1 Service Account | Unlimited | **₹0.00** |
| **Google OAuth2 Token Endpoint** | Free API | ~10 - 20 token exchanges / day | Unlimited | **₹0.00** |
| **Firestore Reads (Spark Plan)** | 50,000 / day | ~1,500 / day | **33x Headroom** | **₹0.00** |
| **Firestore Writes (Spark Plan)**| 20,000 / day | ~500 / day | **40x Headroom** | **₹0.00** |
| **Supabase Invocations** | 500,000 / month | ~10,000 - 20,000 / month | **25x Headroom** | **₹0.00** |
| **Supabase DB Storage** | 500 MB | < 1 MB | **500x Headroom** | **₹0.00** |
| **Supabase Network Egress** | 5 GB / month | < 25 MB / month | **200x Headroom** | **₹0.00** |

**Zero Billing Invariant:** Both Google Cloud and Supabase Free Tiers do not charge automatically. If quotas are ever reached, operations fail closed rather than incurring charges. No credit card is linked.

---

## 8. COMPREHENSIVE VERIFICATION & TEST PLAN

The following 8 mandatory test cases will be executed locally and in automated suites before production activation:

| Test ID | Test Scenario | Expected Result | Verification Tool |
| :--- | :--- | :--- | :--- |
| **TEST-1** | Direct Firestore REST write with Owner token to `recharge_wallets` | **HTTP 403 PERMISSION_DENIED** | `recharge_security_boundary_test.dart` |
| **TEST-2** | Debit request originating from an unregistered device | **HTTP 403 Device Not Registered** | `recharge_backend_bridge_test.dart` |
| **TEST-3** | Debit request originating from a Staff account | **HTTP 403 Staff Forbidden** | `recharge_backend_bridge_test.dart` |
| **TEST-4** | Debit request originating from a revoked device | **HTTP 403 Device Revoked** | `recharge_backend_bridge_test.dart` |
| **TEST-5** | Duplicate transaction submission with same idempotency key | **HTTP 409 / Idempotent Replay** | `recharge_backend_bridge_test.dart` |
| **TEST-6** | Concurrent debits against ₹1,000 wallet balance | **Exact 0 Paise Balance / Zero Underflow** | `recharge_backend_bridge_test.dart` (TEST 13) |
| **TEST-7** | Valid registered Owner device with genuine ECDSA P-256 signature | **HTTP 200 Success & Atomic Commit** | `recharge_backend_bridge_test.dart` |
| **TEST-8** | Full regression of POS, Sales, Stock, Purchases, Repairs, Expenses | **135 / 135 Tests Passing (100%)** | Full Flutter test suite |

---

## 9. HONEST INVENTORY OF REMAINING OPERATIONAL BLOCKERS

1. **Google Cloud Service Account Creation:**
   - A Service Account key JSON for `tekfix-45b38` must be created in Google Cloud Console with the `Cloud Datastore User` role.
   - *Why this is a blocker:* An agent cannot bypass Google Cloud Console authentication to create private keys without user login.
2. **Supabase Secret Configuration:**
   - The key must be set in Supabase Secrets: `supabase secrets set FIREBASE_SERVICE_ACCOUNT_KEY='<JSON>'`.
3. **Supabase CLI Project Link:**
   - The local Supabase CLI requires user authentication (`npx supabase login`) to deploy Edge Functions to the remote free project.

---

## 10. STEP-BY-STEP EXECUTION SEQUENCE (PENDING USER AUTHORIZATION)

Once authorized by the user, execution will follow this strict order:
1. **Step 1:** Backup active production `firestore.rules`.
2. **Step 2:** User creates the free Google Service Account in Google Cloud Console and sets it in Supabase Secrets.
3. **Step 3:** Update `supabase/functions/recharge-bridge/index.ts` to include OAuth2 token exchange with Firestore.
4. **Step 4:** Deploy Edge Function to Supabase: `npx supabase functions deploy recharge-bridge`.
5. **Step 5:** Deploy hardened Firestore rules: `firebase deploy --only firestore:rules --project=tekfix-45b38`.
6. **Step 6:** Execute all 135+ automated tests and run live end-to-end transaction test from the owner's enrolled device.

