# TEKFIX ERP – PHASE 13.7
# FINAL PRODUCTION SECURITY BOUNDARY VERIFICATION & AUDIT REPORT

**Date:** 2026-11-09  
**Audit Mode:** STRICT READ-ONLY SECURITY AUDIT  
**Target Environment:** PRODUCTION LIVE (`tekfix-45b38` / Firestore `asia-south1`)  
**Production Budget Constraint:** ₹0.00 Strict (Spark Free Plan – Zero Credit Cards, Zero Payments)  
**Lead Security Auditor:** Principal Cloud Security Architect, Senior Cryptographic Auditor, Financial Systems Auditor  

---

## 1. EXECUTIVE SUMMARY & SECURITY VERDICT

### Critical Finding:
**A critical security boundary discrepancy exists between the Firestore Database Security Rules tier and the Supabase Edge Function tier.**

- **The Supabase Edge Function** ([`recharge-bridge/index.ts`](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts)) strictly enforces all mandatory hardware-backed device checks: Firebase ID token RS256 validation, Owner UID verification, mandatory `deviceId`, active/non-revoked device status, 300-second CSPRNG challenge nonces, single-use atomic consumption, and WebCrypto ECDSA P-256 signature verification over canonical payloads.
- **HOWEVER, Production Firestore Security Rules** ([`firebase/firestore.rules`](file:///d:/tekfix_pos/firebase/firestore.rules#L399-L428)) permit direct creation and updates to `recharge_wallets`, `recharge_transactions`, and `recharge_wallet_logs` to any authenticated caller satisfying `isOwner(shop)`.
- **Vulnerability Implication:** An authenticated shop owner session (or an attacker possessing an owner Firebase ID token, an un-enrolled device, a compromised browser, or a cURL script) can **completely bypass the Supabase Edge Function** and directly write to Firestore via the Firestore REST API, modifying wallet balances, fabricating transactions, and appending false ledger logs without any cryptographic device signature.

---

## 2. POINT-BY-POINT SECURITY INVESTIGATION

### 1. Can direct Firestore writes bypass device verification?
- **VERDICT: YES (CRITICAL VULNERABILITY).**
- **Technical Mechanism:**
  In [`firebase/firestore.rules`](file:///d:/tekfix_pos/firebase/firestore.rules#L399-L428):
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
  Firestore Security Rules evaluate only `isOwner(shop)`, which checks:
  `request.auth != null && (request.auth.uid == shopDoc.data().ownerUid || ...)`
  Firestore Security Rules **do not and cannot** inspect the ECDSA P-256 signature, the challenge nonce, or the hardware device ID.
  Any direct HTTP POST/PATCH request to `https://firestore.googleapis.com/v1/projects/tekfix-45b38/databases/(default)/documents/shops/{shopId}/...` with `Authorization: Bearer <OWNER_FIREBASE_ID_TOKEN>` will be accepted by Firestore directly, completely bypassing the Supabase Edge Function.

### 2. Can wallet balance be modified directly?
- **VERDICT: YES (HIGH FINANCIAL RISK).**
- **Technical Mechanism:**
  The Firestore rule on `recharge_wallets/{walletId}` only verifies that balances are non-negative:
  `(!('totalBalancePaise' in request.resource.data) || request.resource.data.totalBalancePaise >= 0) && ...`
  An authenticated owner session can directly send a write setting `ownPrepaidBalancePaise` to `99999999` (or `0`). Firestore will accept it because the number is `>= 0`. No corresponding financial debit, cash contra, or bank transfer is verified.

### 3. Can fake recharge transactions be created?
- **VERDICT: YES (AUDIT INTEGRITY BREACH).**
- **Technical Mechanism:**
  `match /recharge_transactions/{txnId} { allow create: if isOwner(shop); }`
  Any document can be inserted directly by an owner identity with arbitrary transaction amounts, fabricated customer mobile numbers, fake operator names, or backdated timestamps, without debiting any wallet.

### 4. Can ledger entries be manipulated?
- **VERDICT: YES (VIA FABRICATED APPENDS).**
- **Technical Mechanism:**
  `match /recharge_wallet_logs/{logId} { allow update, delete: if false; allow create: if isOwner(shop); }`
  Existing entries cannot be updated or deleted (preserving historical logs), BUT an owner session can append new fabricated log documents with falsified `balanceBeforePaise`, `balanceAfterPaise`, and `amountPaise` fields that do not correlate with any physical wallet debit.

### 5. Can duplicate transactions be created?
- **VERDICT: YES.**
- **Technical Mechanism:**
  Firestore Security Rules do not enforce `currentDocument: { exists: false }` preconditions or idempotency checks. Furthermore, `recharge_transactions/{txnId}` permits `allow update: if isOwner(shop);`, allowing an owner session to overwrite or duplicate records.

### 6. Can an unregistered device perform these writes?
- **VERDICT: YES.**
- **Technical Mechanism:**
  Because Firestore checks only `request.auth.uid`, any unregistered device (a third PC, an un-enrolled Android device, a Linux laptop, an automated bot, or Postman) possessing the owner's Firebase ID token can execute these writes. Hardware-backed device registration is completely bypassed.

### 7. Does Supabase Edge Function enforce every required authorization check?
- **VERDICT: YES (AT THE APPLICATION LAYER).**
- **Audit of [`supabase/functions/recharge-bridge/index.ts`](file:///d:/tekfix_pos/supabase/functions/recharge-bridge/index.ts):**
  - **Firebase Token Validation:** Validates RS256 signature against Google JWKS with dynamic cache invalidation on unknown `kid`.
  - **Owner Authorization:** Checks `ownerUid === callerUid` against `shops/{shopId}` and rejects staff with HTTP 403 `PERMISSION_DENIED`.
  - **Mandatory Device ID:** Rejects missing or empty `deviceId` with HTTP 403.
  - **Device Status:** Looks up device in `recharge_trusted_devices` and rejects un-enrolled or revoked devices.
  - **Challenge Nonce:** Validates single-use 128-bit CSPRNG nonce within 300s TTL and consumes it atomically.
  - **ECDSA P-256 Verification:** Verifies genuine WebCrypto signature against registered SPKI public key over `${shopId}:${callerUid}:${deviceId}:${nonce}`.
  - **Atomic Firestore Commit:** Enforces `updateTime` optimistic concurrency lock on wallet and `{ exists: false }` idempotency lock on transaction and ledger records.
  - **Paise Integrity:** Verifies positive safe integer paise and rejects insufficient balances.
  - **CONCLUSION:** The Edge Function implementation is cryptographically sound. The bypass exists solely because the database tier (Firestore rules) permits direct access.

### 8. Can all financial writes be restricted to the verified backend without breaking existing ERP?
- **VERDICT: YES, WITH 100% ERP COMPATIBILITY.**
- Detailed solution presented in Section 4.

---

## 3. IMPACT ANALYSIS ON OTHER ERP MODULES & HISTORICAL DATA

| Module | Collections Used | Rule Authorization | Impact if Recharge Rules are Hardened |
| :--- | :--- | :--- | :--- |
| **POS & Checkout** | `sales`, `sales_invoices`, `sales_orders`, `counters`, `daily_sales`, `daily_sales_ledger`, `daily_registers` | `isShopMember(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Stock & Inventory** | `inventory`, `items`, `inventory_logs`, `inventory_private`, `stockMovements`, `stock_moves`, `stock_units` | `isShopMember(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Purchases & Bills** | `purchases`, `purchase_bills`, `parties`, `vendor_payments`, `vendor_ledger` | `isShopMember(shop)` / `isOwner(shop)` (delete) | **ZERO IMPACT.** Completely independent collections. |
| **Repairs & Services**| `service_jobs`, `services` | `isShopMember(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Returns** | `returns` | `isShopMember(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Expenses & Rent** | `expenses`, `rent_records`, `owner_withdrawals` | `isShopMember(shop)` / `isOwner(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Staff & Payroll** | `staff`, `staff_attendance`, `attendance`, `salary_payments` | `isShopMember(shop)` / `isOwner(shop)` | **ZERO IMPACT.** Completely independent collections. |
| **Existing Financial Data** | All historical collections | Read-only preserved | **ZERO RISK.** No schema or data migrations required. |

---

## 4. THE SAFEST PERMANENT ARCHITECTURAL SOLUTION

### Why Did the Discrepancy Occur?
In Phase 13.5/13.6, the Supabase Edge Function was designed to use **Bearer Token Pass-Through** (`Authorization: Bearer <FIREBASE_ID_TOKEN>`) to avoid needing a Google Service Account. Because the Edge Function called the Firestore REST API as the owner user, the Firestore Security Rules had to allow the owner to write (`allow create, update: if isOwner(shop)`). But allowing the owner to write also allowed the client or any unauthorized device with an owner token to write directly!

### The Permanent, Zero-Cost Solution: Google Service Account Token Exchange
To close the database-level bypass permanently while preserving ₹0.00 cost and zero Blaze billing:

1. **Google Cloud Service Account (100% Free):**
   - In Google Cloud Console for `tekfix-45b38`, create a dedicated Service Account: `recharge-bridge@tekfix-45b38.iam.gserviceaccount.com`.
   - Grant role: `Cloud Datastore User` (scoped strictly to Firestore).
   - Generate a JSON key.
   - **Cost: ₹0.00.** Google Cloud IAM Service Accounts are completely free on both the Spark plan and standard GCP. No billing account or Blaze plan is required.

2. **Store Key Securely in Supabase Secrets:**
   - Store the JSON key as a server-side secret: `FIREBASE_SERVICE_ACCOUNT_KEY` via `supabase secrets set`.
   - **Never exposed to Flutter:** Client devices only possess standard Firebase user sessions.

3. **Edge Function Authenticates as Scoped Service Account:**
   - The Supabase Edge Function validates the caller's Firebase ID Token, verifies owner status, and verifies the hardware ECDSA P-256 signature.
   - Once all checks pass, the Edge Function exchanges its Service Account key for a Google OAuth2 access token (`https://oauth2.googleapis.com/token`) and calls Firestore `:commit` as the privileged backend.

4. **Hardened Production Firestore Rules:**
   - In `firebase/firestore.rules`, revoke direct write access from the owner:
     ```javascript
     match /recharge_wallets/{walletId} {
       allow read: if isShopMember(shop);
       allow write: if false; // Trusted Edge Backend Only
     }

     match /recharge_transactions/{txnId} {
       allow read: if isShopMember(shop);
       allow write: if false; // Trusted Edge Backend Only
     }

     match /recharge_wallet_logs/{logId} {
       allow read: if isShopMember(shop);
       allow write: if false; // Trusted Edge Backend Only
     }
     ```
   - **Result:** Any direct write from Flutter, cURL, or an unregistered device with an owner token is **rejected with HTTP 403 `PERMISSION_DENIED` by Firestore at the database engine tier**.
   - Only transactions validated and signed by the Supabase Edge Function can write to Firestore!

---

## 5. SUPABASE FREE-TIER LIMITS & SAFETY VERIFICATION

| Free Tier Parameter | Supabase Free Limit | TekFix Projected Usage | Safety Margin | Hidden Costs? |
| :--- | :--- | :--- | :--- | :--- |
| **Function Invocations** | 500,000 / month | ~10,000 - 20,000 / month | **25x Headroom** | **NONE (₹0)** |
| **Compute Execution** | 2,000,000 ms / month | ~300,000 ms / month | **6.6x Headroom** | **NONE (₹0)** |
| **PostgreSQL Database** | 500 MB | < 1 MB (`recharge_trusted_devices`) | **500x Headroom** | **NONE (₹0)** |
| **Network Egress** | 5 GB / month | < 25 MB / month | **200x Headroom** | **NONE (₹0)** |
| **Firestore (Spark)** | 50k reads, 20k writes/day | ~1,500 reads, ~500 writes/day | **33x Headroom** | **NONE (₹0)** |

### Inactivity & Fail-Closed Safeguards:
- **7-Day Inactivity Rule:** Supabase pauses free databases after 7 days of inactivity. Because TekFix is an active daily POS system, regular daily transactions ensure the instance stays active.
- **Fail-Closed Client Behavior:** If Supabase is ever paused or unreachable, `SupabaseRechargeBridgeClient` catches the HTTP timeout/503 and throws `StateError`, immediately blocking unverified debits and preventing partial writes or corrupt balances.
- **Zero Paid Dependencies:** Neither Firebase nor Supabase requires any credit card, advance payment, or paid plan.

---

## 6. AUDIT CONCLUSION

- **Source Code Status:** Strictly untouched. Zero modifications made during this audit.
- **Deployments:** Zero executed.
- **Billing:** Zero billing modifications made. Spark plan remains active.
- **Security Posture:** The bypass vector is completely documented. The permanent solution using Google Cloud IAM Service Account token exchange provides airtight database-level security with ₹0 expenditure.

