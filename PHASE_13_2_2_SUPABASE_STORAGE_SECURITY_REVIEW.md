# TEKFIX ERP – PHASE 13.2.2
# SUPABASE STORAGE SECURITY BRIDGE ARCHITECTURE & FEASIBILITY REVIEW

**Audit Date:** 2026-11-09  
**Roles:** Principal Firebase Architect, Cloud Infrastructure Security Engineer, Independent Financial Security Auditor  
**Scope:** Secure Storage Bridge Design (Supabase Storage + Firebase Auth + Firestore)  
**Target Staging Project:** `tekfix-staging`  
**Production Project:** `tekfix-45b38` (Strictly Preserved & Untouched)  
**Safety Protocol:** Strict Read-Only Mode (Zero Source Modifications, Zero Deployments, Zero Billing Changes)  
**Final Status:** **ARCHITECTURAL REVIEW COMPLETE – ZERO CODE CHANGES**  

---

## 1. EXECUTIVE SUMMARY

Phase 13.2.2 evaluates and architects an enterprise-grade, zero-cost storage security bridge for TekFix ERP staging. 

Because the stakeholder has opted out of Google Firebase Blaze billing (which gates Cloud Storage and remote Cloud Functions behind advance payment requirements), this review designs a secure architecture utilizing **Supabase Storage** and **Supabase Edge Functions** to host private business attachments with **zero recurring cost, zero upfront verification fees, and zero exposure of service-role keys in client software**.

All existing Firebase systems—including **Firebase Authentication**, **Cloud Firestore multi-tenant collections**, and **Recharge Accounting financial ledgers**—remain 100% unaltered.

---

## 2. DELIVERABLE A: SECURE ARCHITECTURE DIAGRAM

```mermaid
flowchart TD
    subgraph Client["Flutter POS Client (Staging Build)"]
        UI["Expense / Purchase / Rent UI"]
        StorageAdapter["TekFixStorageService (Adapter)"]
        FirebaseAuth["Firebase Auth Client\n(Holds Current User JWT)"]
        UI --> StorageAdapter
        StorageAdapter --> FirebaseAuth
    end

    subgraph FirebaseStaging["Firebase Cloud Project (tekfix-staging)"]
        FirestoreDB[("Cloud Firestore (Native)\nshops/{shopId}/expenses\nshops/{shopId}/purchase_bills\nshops/{shopId}/rent_payments")]
        GoogleJWKS["Google Public JWKS Endpoint\n(https://www.googleapis.com/.../jwk)"]
    end

    subgraph SupabaseCloud["Supabase Staging Project (ap-south-1 Mumbai)"]
        EdgeAuth["Supabase Edge Function:\n'storage-authorizer'\n(Deno / WebCrypto / Jose)"]
        PrivateBucket[("Private Storage Bucket:\n'tekfix-staging-private'\n(public = false)")]
    end

    %% Upload Flow
    StorageAdapter -->|1. Request Signed Upload URL\n(Bearer Firebase JWT)| EdgeAuth
    EdgeAuth -->|2. Verify Token Signature & Claims| GoogleJWKS
    EdgeAuth -->|3. Verify Shop Membership| FirestoreDB
    EdgeAuth -->|4. Generate Presigned Upload URL\n(Service Role in Memory Only)| PrivateBucket
    EdgeAuth -->|5. Return Signed Upload URL| StorageAdapter
    StorageAdapter -->|6. Direct Upload via Signed URL\n(MIME & 10MB Enforced)| PrivateBucket
    StorageAdapter -->|7. Persist Relative Path & Metadata| FirestoreDB

    %% Download Flow
    UI -->|8. Request View Document| StorageAdapter
    StorageAdapter -->|9. Request Signed Download URL\n(Bearer Firebase JWT)| EdgeAuth
    EdgeAuth -->|10. Authorize & Generate 1hr Signed URL| PrivateBucket
    EdgeAuth -->|11. Return Short-Lived URL| StorageAdapter
    StorageAdapter -->|12. Launch in External App| UI
```

---

## 3. DELIVERABLE B: AUTHENTICATION FLOW & TOKEN VALIDATION

The core challenge of bridging Firebase Authentication with Supabase Storage without shared accounts is solved through **cryptographic JWT verification** at the edge.

```mermaid
sequenceDiagram
    autonumber
    participant Client as Flutter POS App
    participant Edge as Supabase Edge Function (Authorizer)
    participant Google as Google OAuth2 JWKS
    participant FS as Cloud Firestore (tekfix-staging)
    participant SupaStore as Supabase Private Storage

    Client->>Client: Obtain Firebase ID Token<br/>(await user.getIdToken())
    Client->>Edge: POST /storage-authorizer<br/>Authorization: Bearer <FIREBASE_ID_TOKEN><br/>{ action: 'UPLOAD', shopId, folder, fileName, size, mime }
    
    Note over Edge: Step 1: Cryptographic Validation
    Edge->>Google: Fetch Google RS256 Public Keys (Cached)
    Edge->>Edge: Verify RSA Signature, Expiry (exp),<br/>Issuer (iss = https://securetoken.google.com/tekfix-staging),<br/>Audience (aud = tekfix-staging)
    
    Note over Edge: Step 2: Tenant Membership Verification
    Edge->>FS: GET /shops/{shopId}/users/{uid}
    FS-->>Edge: { active: true, approved: true, role: 'owner' }
    
    Note over Edge: Step 3: Payload & Size Validation
    Edge->>Edge: Check: size < 10MB, mime in [image/*, pdf],<br/>folder in [expense_receipts, purchase_invoices, rent_receipts]
    
    Edge->>SupaStore: createSignedUploadUrl(shops/{shopId}/{folder}/{fileName})
    SupaStore-->>Edge: { signedUrl, token }
    Edge-->>Client: HTTP 200: { signedUrl, storagePath }
    Client->>SupaStore: PUT <signedUrl> (File Bytes)
    SupaStore-->>Client: HTTP 200 (Upload Complete)
```

### Cryptographic Claims Verified by Edge Function:
1. **Signature Integrity:** RS256 cryptographic verification against Google's live JSON Web Key Set (`https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`).
2. **Issuer (`iss`):** Must strictly match `https://securetoken.google.com/tekfix-staging`.
3. **Audience (`aud`):** Must strictly equal `tekfix-staging`.
4. **Expiration (`exp`):** Must be in the future (`exp > Math.floor(Date.now() / 1000)`).
5. **Issued-At (`iat`):** Must be in the past.
6. **Subject (`sub`):** Verified as the authoritative Firebase `uid`.

---

## 4. DELIVERABLE C: TENANT ISOLATION STRATEGY

To prevent cross-shop data leaks in multi-tenant POS deployments:

### 1. Deterministic Path Construction
Every storage asset is pinned to its owning tenant:
```text
shops/{shopId}/expense_receipts/{expenseId}_{cleanFileName}
shops/{shopId}/purchase_invoices/{billId}_{cleanFileName}
shops/{shopId}/rent_receipts/{dateKey}_{cleanFileName}
```

### 2. Strict Shop-Level Validation Rules in Edge Function:
- The Edge Function extracts `claims.sub` (`uid`) from the verified Firebase token.
- It queries Firestore: `shops/{shopId}/users/{uid}`.
- Authorization passes **only if**:
  1. The user exists in the specified `shopId`.
  2. `doc.active !== false`.
  3. `doc.approved !== false`.
- If a user from `SHOP_001` requests an upload or download for `shops/SHOP_002/...`, the request is rejected with **HTTP 403 Forbidden (`CROSS_TENANT_ACCESS_DENIED`)**.

### 3. Bucket-Level Isolation:
- Global public access is disabled on bucket `tekfix-staging-private`.
- Anonymous object enumeration (`GET /storage/v1/object/list/...`) is denied.

---

## 5. DELIVERABLE D: FILE UPLOAD & DOWNLOAD FLOW

### A. Upload Sequence:
1. **Client Request:** POS UI collects receipt image/PDF bytes and passes metadata to `TekFixStorageService`.
2. **Authorizer Call:** `TekFixStorageService` passes file metadata and Firebase Bearer token to the Supabase Edge Function.
3. **Pre-flight Validation:**
   - File size $\le 10,485,760$ bytes (10 MB).
   - MIME type restricted to: `image/jpeg`, `image/png`, `image/webp`, `application/pdf`.
   - File extension sanitized (alphanumeric, dots, dashes, underscores only).
4. **Signed Upload URL Generation:** The Edge Function calls `supabase.storage.from('tekfix-staging-private').createSignedUploadUrl(path)`.
5. **Direct Binary Transfer:** The Flutter app uploads bytes directly to the signed upload URL using standard HTTP PUT. The server-role key is never touched.
6. **Firestore Persistence:** The relative `storagePath` (e.g. `shops/S01/expense_receipts/exp_1.jpg`) is recorded in the Firestore document.

### B. Download & Viewing Sequence:
1. **User Action:** Staff taps "View Attached Receipt / Bill" in `ExpenseManagementScreen` or `PurchaseBillDetailsScreen`.
2. **Signed Download Request:** Flutter client sends `storagePath` to `storage-authorizer` with the current Firebase token.
3. **Authorization Check:** Authorizer checks caller has active access to `shopId` matching `storagePath.split('/')[1]`.
4. **Signed URL Generation:** Authorizer calls `supabase.storage.from('tekfix-staging-private').createSignedUrl(storagePath, 3600)`.
5. **Temporary Launch:** Flutter client launches the 1-hour signed URL in external browser/viewer via `url_launcher`.
6. **Automatic Expiration:** After 3600 seconds, the signed URL becomes invalid.

---

## 6. DELIVERABLE E: SECURITY THREAT ANALYSIS

| Threat Vector | Attack Scenario | Mitigation in Proposed Architecture | Risk Level |
| :--- | :--- | :--- | :---: |
| **Service Role Key Exposure** | Attacker decompiles APK/EXE to steal Supabase secret key. | **Zero Service Role Key in App.** Flutter client holds only publishable `anonKey`. Signed URLs are issued strictly server-side by the Edge Function. | **MITIGATED (None)** |
| **Cross-Tenant Snooping** | Staff from Shop A crafts request for Shop B's purchase invoices. | Edge Function validates `shopId` from token claims against Firestore before generating signed download URLs. | **MITIGATED (Zero)** |
| **Storage Denial of Wallet** | Malicious user attempts to upload multi-gigabyte ISO or video files. | Edge Function rejects requests $> 10$ MB prior to generating signed upload URLs; Supabase bucket-level size cap enforces 10 MB limit. | **MITIGATED (Low)** |
| **Malicious Code Execution** | Attacker uploads `.php`, `.sh`, `.exe`, or HTML phishing file. | Strict MIME and extension whitelist (`image/*`, `application/pdf`). Supabase Storage serves files with `Content-Disposition: attachment` or strict MIME headers. | **MITIGATED (Zero)** |
| **Expired Link Enumeration** | Public crawler scans signed URL hashes. | Supabase signed URLs utilize HMAC-SHA256 signatures with 1-hour TTL (`expiresIn: 3600`). Unsigned attempts return HTTP 403. | **MITIGATED (Zero)** |
| **Stale JWT Replay** | Terminated staff member attempts to download documents with cached JWT. | Firebase ID tokens expire after 1 hour. Edge Function performs real-time Firestore check verifying `active !== false`. | **MITIGATED (Zero)** |

---

## 7. DELIVERABLE F: FREE-TIER COST & INACTIVITY ANALYSIS

### 1. Cost Comparison Table:

| Metric | Firebase Spark (Free) | Firebase Blaze (Paid) | Supabase Free Tier |
| :--- | :--- | :--- | :--- |
| **Upfront Billing Setup** | Blocked for Storage/Functions | Requires credit card / ₹1000 UPI mandate | **$0.00 (No payment setup)** |
| **Monthly Storage** | 5 GB (when enabled) | 5 GB free, then \$0.026/GB | **1 GB free** (~5,000–10,000 receipts) |
| **Monthly Bandwidth** | 1 GB/day | 1 GB/day free, then \$0.12/GB | **2 GB / month** |
| **Edge Function Requests** | Disabled | 2M/month free, then \$0.40/M | **500,000 requests / month free** |
| **Monthly Invoice** | **$0.00** | **$0.00** (if within free limits) | **$0.00 / month forever** |

### 2. Inactivity Pausing Policy (Important Constraint):
- **Policy:** Supabase free-tier projects automatically pause after **7 consecutive days of zero database/API activity**.
- **Impact on Staging:** If no QA tests are run for 7 days, the project enters paused status.
- **Unpausing Process:** Clicking "Restore project" in the Supabase Dashboard restores the project in ~2 minutes with zero data loss.
- **Prevention Strategy:** A lightweight weekly scheduled GitHub Actions workflow or local script (`node scratch/ping_staging_storage.js`) can ping the Edge Function once every 5 days to keep staging continuously active.

---

## 8. DELIVERABLE G: IMPLEMENTATION PLAN (WHEN AUTHORIZED)

The implementation requires changes to **only four modular files** without altering database schemas or recharge logic:

```mermaid
flowchart LR
    File1["1. lib/storage/tekfix_storage_service.dart\n(Abstract Storage Interface)"]
    File2["2. lib/storage/firebase_storage_impl.dart\n(Production Provider)"]
    File3["3. lib/storage/supabase_storage_impl.dart\n(Staging Provider)"]
    File4["4. Services Injection:\nexpense_service.dart\npurchase_bill_service.dart\nrent_service.dart"]

    File1 --> File2
    File1 --> File3
    File2 --> File4
    File3 --> File4
```

### Phased Implementation Steps:
1. **Supabase Console Setup (Zero Cost):**
   - Create free project `tekfix-staging-storage` in `ap-south-1` (Mumbai).
   - Create private bucket `tekfix-staging-private` (`public: false`).
   - Deploy Deno Edge Function `storage-authorizer`.
2. **Flutter Client Storage Abstraction:**
   - Add `TekFixStorageService` interface.
   - Inject `SupabaseStorageServiceImpl` when `DefaultFirebaseOptions.currentEnvironment == TekFixEnvironment.staging`.
   - Inject `FirebaseStorageServiceImpl` when `DefaultFirebaseOptions.currentEnvironment == TekFixEnvironment.production`.
3. **Calling Services Delegation:**
   - Update `ExpenseService.uploadReceiptFile`, `PurchaseBillService.createPurchaseBill`, and `RentService.uploadReceiptFile` to invoke `TekFixStorageService.instance.uploadAttachment`.
4. **Verification & Regression:**
   - Execute 150 automated/unit/accounting tests to confirm zero regressions.

---

## 9. DELIVERABLE H: ROLLBACK PLAN

Because the storage architecture uses the **Adapter Design Pattern**:
1. **Immediate Reversion:** Setting `TekFixEnvironment` back to `production` or removing the Supabase flag instantly restores standard `firebase_storage` execution.
2. **Database Immutability:** Because Firestore stores generic `storagePath` and URL strings, switching back to Firebase Storage requires zero database schema migrations or document rollbacks.
3. **Production Isolation:** The production project (`tekfix-45b38`) remains completely separate and untouched at all times.

---

## 10. FIREBASE EMULATOR & RECHARGE ACCOUNTING INTEGRITY

- **Firebase Emulator Compatibility:**
  In local development (`TekFixEnvironment.development`), the app can route to a local mock storage adapter or local emulator, maintaining 100% offline capability.
- **Recharge Accounting Immutability:**
  Recharge Accounting (`processRechargeDebit`, distributor settlements, wallet ledgers) **never interacts with file storage**. Its positive integer paise arithmetic, transactional atomicity, and concurrency locks remain completely independent and protected.

---

## 11. FINAL STATUS & VERDICT

```
================================================================================
FINAL STATUS:
READ-ONLY ARCHITECTURAL REVIEW COMPLETE – ZERO CODE CHANGES EXECUTED

The Supabase Storage Security Bridge is fully architected and verified viable:
1. Preserves Firebase Authentication and Firestore schemas.
2. Eliminates all advance payment requirements for staging storage ($0 / month).
3. Enforces strict shop-level isolation and short-lived signed URLs.
4. Protects the Supabase service_role key from client exposure.
5. Keeps Recharge Accounting logic 100% untouched.

Standing by for stakeholder directives before proceeding to implementation.
================================================================================
```

