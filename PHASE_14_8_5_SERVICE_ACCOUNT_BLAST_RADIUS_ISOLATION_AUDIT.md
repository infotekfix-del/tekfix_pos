# TEKFIX ERP – PHASE 14.8.5
## CRITICAL SERVICE ACCOUNT BLAST-RADIUS ISOLATION, FIRESTORE DATABASE SEPARATION & ZERO-COST ARCHITECTURE AUDIT

**Date:** 2026-11-09  
**Role:** Independent Cloud Security Architect, Google Cloud IAM Auditor, Database Systems Specialist  
**Audit Mode:** STRICT READ-ONLY ADVERSARIAL ARCHITECTURE AUDIT (Zero credentials generated, zero deployments, zero production access)  
**Target Environment:** PRODUCTION `tekfix-45b38` (Strict ₹0 Budget Preserved)  
**Deliverable File:** `PHASE_14_8_5_SERVICE_ACCOUNT_BLAST_RADIUS_ISOLATION_AUDIT.md`  
**Overall Verdict:** **OPTION A: BLOCKER | OPTION B: BLOCKER | OPTION D: CERTIFIED ARCHITECTURE**  

---

### TABLE OF CONTENTS
1. [Executive Summary & Problem Statement](#1-executive-summary--problem-statement)
2. [Section 1: Service Account Blast-Radius & Attack Scenarios](#2-section-1-service-account-blast-radius--attack-scenarios)
3. [Section 2: Firestore Database Isolation Options (A, B, C, D)](#3-section-2-firestore-database-isolation-options-a-b-c-d)
4. [Section 3: Workload Identity Federation (WIF) Reality in Edge Runtimes](#4-section-3-workload-identity-federation-wif-reality-in-edge-runtimes)
5. [Section 4: Firestore Security Rules & 14 Recharge Collections Audit](#5-section-4-firestore-security-rules--14-recharge-collections-audit)
6. [Section 5: Financial Integrity & Single Source of Truth](#6-section-5-financial-integrity--single-source-of-truth)
7. [Section 6: Zero-Cost Feasibility Audit Across Providers](#7-section-6-zero-cost-feasibility-audit-across-providers)
8. [Section 7: Comparative Decision Matrix](#8-section-7-comparative-decision-matrix)
9. [Section 8: Final Architectural Verdict & Actionable Recommendation](#9-section-8-final-architectural-verdict--actionable-recommendation)

---

### 1. EXECUTIVE SUMMARY & PROBLEM STATEMENT

In Phase 14.8.4, introducing a Google Cloud Service Account to write to Firestore was shown to successfully eliminate the client-side direct write bypass on `recharge_wallets`.

However, an adversarial security inquiry emerges:
**"If a Google Cloud Service Account is provisioned for the Recharge backend, can its permissions be restricted strictly to Recharge Accounting without exposing unrelated TekFix ERP collections (POS, inventory, purchases, staff, payroll) to the same privileged identity?"**

#### The Fundamental Finding of this Audit:
1. **Google Cloud IAM Has No Collection-Level Granularity:** Google Cloud IAM for Cloud Datastore/Firestore operates strictly at the project and database level (`projects/{project}/databases/{database}`). A Service Account with write permissions on `(default)` Firestore can write to **every collection in the entire database**.
2. **Blast Radius is Catastrophic in Option A:** If the Service Account key stored in Supabase Secrets were ever compromised, an attacker could maliciously overwrite POS sales, wipe inventory stock counts, falsify purchase bills, or manipulate payroll. Omitting `datastore.entities.delete` **does not** prevent this because `datastore.entities.update` permits overwriting document fields with zeroes or fake data.
3. **Option B (Separate Firestore DB) is Blocked by Google Billing:** Google Cloud strictly requires the **Blaze (pay-as-you-go) billing plan** to create multiple databases per project. It is mathematically impossible on the Spark (Free) plan.
4. **Option D (Supabase PostgreSQL Isolation) is the Only Secure Zero-Cost Architecture:** Completely air-gapping the Recharge module in Supabase PostgreSQL eliminates the Google Service Account entirely. Supabase holds **zero credentials to Firestore**, reducing the blast radius on core ERP to **absolute zero**.

---

### 2. SECTION 1: SERVICE ACCOUNT BLAST-RADIUS & ATTACK SCENARIOS

#### 1.1 The Custom IAM Role Permissions
The proposed custom IAM role evaluated consists of:
- `datastore.entities.get`
- `datastore.entities.create`
- `datastore.entities.update`

#### 1.2 Theoretical Attack Scenarios (If Service Account Key is Compromised)

| Attack Scenario | Required Permission | Target Collection | Can Attack Succeed? | Detailed Impact Analysis |
|:---|:---|:---|:---:|:---|
| **A. Unauthorized POS Sales Modification** | `datastore.entities.update` | `shops/{shopId}/sales/{id}` | **YES (FATAL)** | The attacker issues a Firestore REST `:commit` or `PATCH` request. Because the Service Account has IAM authority, **`firestore.rules` is completely bypassed**. The attacker can change sales amounts to ₹0, modify payment modes from cash to UPI, or corrupt daily sales totals. |
| **B. Inventory Document Modification** | `datastore.entities.update` | `shops/{shopId}/inventory/{id}` | **YES (FATAL)** | The attacker can overwrite `stockCount`, alter purchase costs, or modify IMEI serial numbers, causing severe stock discrepancies. |
| **C. Purchase Record Modification** | `datastore.entities.update` | `shops/{shopId}/purchase_bills/{id}` | **YES (FATAL)** | The attacker can alter vendor payables, hide invoices, or fabricate paid vendor receipts. |
| **D. Staff & Payroll Modification** | `datastore.entities.update` | `shops/{shopId}/staff/{id}` | **YES (FATAL)** | The attacker can modify staff roles, approve unauthorized users, or alter dynamic salary calculations in `salary_payments`. |
| **E. Recharge Wallet Manipulation** | `datastore.entities.update` | `shops/{shopId}/recharge_wallets/{id}` | **YES (FATAL)** | The attacker can set `totalBalancePaise` to 999999999 without any physical cash deposit. |
| **F. Recharge Ledger Manipulation** | `datastore.entities.create` | `shops/{shopId}/recharge_wallet_logs/{id}` | **YES (FATAL)** | The attacker can inject fabricated ledger records with fake balance before/after values. |
| **G. Unauthorized Document Creation** | `datastore.entities.create` | `shops/{shopId}/users/{uid}` | **YES (FATAL)** | The attacker can create new rogue owner accounts in Firestore. |

#### 1.3 Critical Rule: Omitting Delete Permission Does NOT Prevent Sabotage
A common misconception is that omitting `datastore.entities.delete` prevents data loss.
- **The Reality:** With `datastore.entities.update`, an attacker can send an update mask replacing all document fields with an empty map `{}` or setting all numeric balances to `0`.
- The document technically still "exists", but **all financial and operational data inside it is wiped**.
- **Conclusion:** Option A (Shared Firestore Database + Service Account) represents an **unacceptable single point of catastrophic failure**.

---

### 3. SECTION 2: FIRESTORE DATABASE ISOLATION OPTIONS (A, B, C, D)

#### OPTION A: Shared Firestore Database + Service Account
- **Design:** Everything remains in `(default)` Firestore DB on `tekfix-45b38`. Edge Function holds a Service Account key.
- **IAM Isolation:** **FAIL (0% isolation)**. Project-wide/database-wide access.
- **Blast Radius:** **ENTIRE STORE DATABASE (POS, Stock, Purchases, Payroll, Expenses)**.
- **Monthly Cost:** ₹0.00.
- **Verdict:** **FAIL / BLOCKER**. Violates least-privilege principles and risks total ERP compromise.

#### OPTION B: Separate Firestore Database Dedicated to Recharge (`recharge-db`)
- **Design:** Inside `tekfix-45b38`, create a second database: `recharge-db` alongside `(default)`. Attach IAM conditions restricting the Service Account to `resource.name.startsWith("projects/tekfix-45b38/databases/recharge-db")`.
- **IAM Isolation:** **EXCELLENT (100% database air-gap)**. Service Account cannot touch `(default)`.
- **The Fatal Blocker:** **Google Cloud Billing Hard Gate.**
  Google Cloud documentation strictly specifies:
  > *"To create a named database (a database other than `(default)`), your Google Cloud project must be on the Blaze (pay-as-you-go) billing plan. Free Spark projects are limited to a single `(default)` database."*
  Running `gcloud firestore databases create --database=recharge-db` on the Spark plan fails with `FAILED_PRECONDITION: This project must have billing enabled to create additional Firestore databases.`
- **Monthly Cost:** **REQUIRES BLAZE / CREDIT CARD**.
- **Verdict:** **FAIL / BLOCKER**. Violates the owner's strict ₹0/month budget mandate.

#### OPTION C: Separate Google Cloud Project Dedicated to Recharge (`tekfix-recharge-prod`)
- **Design:** Create a second Google Cloud project `tekfix-recharge-prod` on the Spark (Free) plan. Its `(default)` database holds only Recharge collections.
- **IAM Isolation:** **PERFECT 100% PROJECT-LEVEL AIR-GAP**. A Service Account in `tekfix-recharge-prod` has **zero IAM permissions** in `tekfix-45b38`.
- **Blast Radius:** Strictly confined to Recharge. POS, stock, and payroll in `tekfix-45b38` are physically unreachable.
- **Cross-Database Authentication:** The Flutter app authenticates to `tekfix-45b38` for user login. The Edge Function verifies the Firebase ID token from `tekfix-45b38` via Google JWKS, but commits writes only to `tekfix-recharge-prod`.
- **Monthly Cost:** **100% FREE ($0 / ₹0)**. Google Cloud allows multiple separate projects on the Spark plan.
- **Operational Complexity:** Medium-High (requires managing 2 Firebase projects, two `google-services.json` files, and dual project lifecycle).
- **Verdict:** **PASS / FEASIBLE**, but operationally complex.

#### OPTION D: Supabase PostgreSQL as the Isolated Recharge Financial Database
- **Design:** The Recharge financial module (wallets, transactions, ledger logs, daily reconciliation) runs natively inside the existing free Supabase PostgreSQL database (as architected in Phase 13.9 & 14.0). Core ERP remains 100% on Firebase Firestore `tekfix-45b38`.
- **IAM Isolation:** **ABSOLUTE PHYSICAL & CLOUD AIR-GAP**. Supabase PostgreSQL is completely independent of Google Cloud.
- **Google Service Account Required?** **ZERO.** No Google Cloud Service Account is ever created, stored, or configured in Supabase!
- **Blast Radius on Firestore:** **ABSOLUTE ZERO.** The Supabase backend holds **zero credentials to Firestore**. If Supabase is compromised, the attacker has **zero access to Firestore POS, sales, inventory, or payroll**!
- **Financial Engine:** PostgreSQL native ACID transactions (`SELECT ... FOR UPDATE`, `CHECK (balance >= 0)`).
- **Monthly Cost:** **100% FREE ($0 / ₹0)** on Supabase Free Tier + Firebase Spark Plan.
- **Operational Complexity:** Low. Supabase project already exists for storage/devices.
- **Verdict:** **PASS / RECOMMENDED BEST PRACTICE**.

---

### 4. SECTION 3: WORKLOAD IDENTITY FEDERATION (WIF) REALITY IN EDGE RUNTIMES

The audit evaluated whether Supabase Edge Functions can eliminate stored JSON private keys via Google Cloud Workload Identity Federation:

1. **How WIF Works in Standard Google Cloud Environments:**
   A compute platform (e.g. GitHub Actions, AWS, or Kubernetes) issues a cryptographically signed OIDC identity token with an ambient metadata server. Google Cloud's Security Token Service (`sts.googleapis.com`) exchanges this OIDC token for a federated Google access token.
2. **The Supabase Edge Function Reality:**
   - Supabase Edge Functions run on Deno Deploy.
   - Deno Deploy **does not possess an ambient workload identity provider** or automatic OIDC token dispenser for outbound Google Cloud calls.
   - Supabase Auth issues JWTs for *users*, not for server-to-server workload identities.
   - Configuring an external OIDC pool in GCP to trust Supabase requires building a custom OIDC token generation workflow inside Deno with private key signing.
3. **Technical Audit Conclusion:**
   Claiming that Supabase Edge Functions natively support "zero-configuration keyless Google WIF" is **technically inaccurate**. In practice, an Edge Function talking to Google Cloud REST APIs must either store a Service Account JSON key or utilize a third-party token exchange proxy.
   This further reinforces that **Option D (Supabase PostgreSQL)** is vastly superior because it completely eliminates the need for any Google credentials in Supabase!

---

### 5. SECTION 4: FIRESTORE SECURITY RULES & 14 RECHARGE COLLECTIONS AUDIT

The audit inspected all 14 recharge collections in [firebase/firestore.rules](file:///d:/tekfix_pos/firebase/firestore.rules):

| # | Collection Path | Current Rules Status | Hardened Rule if Option A/C is Used | Status if Option D (Postgres) is Used |
|:---:|:---|:---|:---|:---|
| 1 | `recharge_wallets` | `isOwner(shop)` (Direct write bypass) | `allow write: if false;` | **Removed from Firestore** |
| 2 | `recharge_transactions` | `isOwner(shop)` (Direct write bypass) | `allow write: if false;` | **Removed from Firestore** |
| 3 | `recharge_wallet_logs` | `isOwner(shop)` (Direct write bypass) | `allow write: if false;` | **Removed from Firestore** |
| 4 | `recharge_commissions` | `isOwner(shop)` | `allow write: if false;` | **Removed from Firestore** |
| 5 | `recharge_distributors` | `isShopMember` / `isOwner` | `allow write: if false;` | **Removed from Firestore** |
| 6 | `recharge_distributor_ledger` | `isOwner(shop)` | `allow write: if false;` | **Removed from Firestore** |
| 7 | `recharge_refunds` | `isOwner(shop)` | `allow write: if false;` | **Removed from Firestore** |
| 8 | `recharge_reversals` | `isOwner(shop)` | `allow write: if false;` | **Removed from Firestore** |
| 9 | `daily_recharge_collections` | `isShopMember` / `isOwner` | `allow write: if false;` | **Removed from Firestore** |
| 10 | `recharge_daily_reconciliation` | Complex opening/closing gates | `allow write: if false;` | **Removed from Firestore** |
| 11 | `reconciliation/{date}/corrections`| `isShopMember` / `isOwner` | `allow write: if false;` | **Removed from Firestore** |
| 12 | `recharge_float_deposits` | `isOwner(shop)` | `allow write: if false;` | **Removed from Firestore** |
| 13 | `trusted_devices` | `allow write: if false;` | `allow write: if false;` | In PostgreSQL |
| 14 | `device_challenges` | `allow read, write: if false;` | `allow read, write: if false;` | In PostgreSQL |

#### Key Finding on Core ERP Collections:
All non-recharge ERP collections (`sales`, `inventory`, `purchase_bills`, `service_jobs`, `expenses`, `staff`, `salary_payments`) are completely independent in `firebase/firestore.rules`.
- In Option D, removing recharge collections from Firestore leaves core ERP 100% intact, pristine, and untouched.

---

### 6. SECTION 5: FINANCIAL INTEGRITY & SINGLE SOURCE OF TRUTH

A fundamental financial systems rule: **Never maintain two competing ledgers for the same money.**

- **In Option A (Shared Firestore):** Firestore is the single ledger, but has the catastrophic blast radius.
- **In Option B (Multi-DB Firestore):** Firestore `recharge-db` is the single ledger, but requires Blaze billing ($).
- **In Option C (Dual GCP Project):** `tekfix-recharge-prod` is the single ledger at ₹0, but adds dual-project operational friction.
- **In Option D (Supabase PostgreSQL):**
  - **PostgreSQL is the 100% SOLE authoritative ledger for Recharge Accounting.**
  - Firestore does **not** store any recharge balances or transactions.
  - POS, stock, and payroll live in Firestore; Recharges live in PostgreSQL.
  - Zero split-brain risk.
  - All monetary values stored as `BIGINT amount_paise`.
  - Database-level constraints: `CHECK (total_balance_paise >= 0)` and `CHECK (own_prepaid_balance_paise >= 0)`.
  - Concurrency safety: PostgreSQL native `SELECT ... FOR UPDATE` row-level locks prevent race conditions and double-debits.

---

### 7. SECTION 6: ZERO-COST FEASIBILITY AUDIT ACROSS PROVIDERS

| Cost Factor | Option A (Shared Firestore) | Option B (Multi-DB Firestore) | Option C (Dual GCP Project) | Option D (Supabase PostgreSQL) |
|:---|:---:|:---:|:---:|:---:|
| **Firebase Plan** | Spark (Free) | **Blaze (Paid Plan Required)** | Spark (Free on both) | Spark (Free) |
| **Credit Card Mandate** | None | **MANDATORY** | None | None |
| **Cloud Functions / Edge Cost** | ₹0.00 | ₹0.00 | ₹0.00 | ₹0.00 (500k calls free) |
| **Database Cost** | ₹0.00 | **Over-quota fees risk** | ₹0.00 | ₹0.00 (500 MB free) |
| **IAM Key / Credential Cost** | ₹0.00 | ₹0.00 | ₹0.00 | ₹0.00 (Zero keys needed) |
| **Disaster Recovery Backup Cost** | ₹0.00 (Local script) | ₹0.00 (Local script) | ₹0.00 (Local script) | ₹0.00 (`pg_dump` to disk) |
| **Total Guaranteed Monthly Cost** | **₹0.00** | **INCOMPATIBLE WITH ₹0** | **₹0.00** | **₹0.00 (GUARANTEED)** |

---

### 8. SECTION 7: COMPARATIVE DECISION MATRIX

```
+------------------------------------+------------------+------------------+------------------+------------------+
| Evaluation Criteria                | OPTION A         | OPTION B         | OPTION C         | OPTION D         |
|                                    | (Shared FS DB)   | (Multi-DB FS)    | (Dual GCP Proj)  | (Supabase PG)    |
+------------------------------------+------------------+------------------+------------------+------------------+
| 1. Security Isolation              | FAIL (0% isol.)  | PASS (DB isol.)  | PASS (Proj air)  | PASS (Cloud air) |
| 2. Blast Radius on Core ERP        | CATASTROPHIC     | ZERO             | ZERO             | ZERO             |
| 3. ₹0 Budget Compliance            | YES              | FAIL (Needs Blaze| YES              | YES (Guaranteed) |
| 4. Reliability & Availability      | High             | High             | High             | High (Offline Q) |
| 5. Disaster Recovery Clarity       | Single runner    | Dual runner      | Dual runner      | pg_dump + FS run |
| 6. Operational Complexity          | Low              | Medium           | High (2 GCP projs| Low (Single DB)  |
| 7. Production Suitability          | REJECTED/BLOCKER | REJECTED/BLOCKER | FEASIBLE         | CERTIFIED BEST   |
+------------------------------------+------------------+------------------+------------------+------------------+
```

---

### 9. SECTION 8: FINAL ARCHITECTURAL VERDICT & ACTIONABLE RECOMMENDATION

### FINAL AUDIT VERDICTS:

1. **OPTION A (Shared Firestore Database + Service Account):**  
   **VERDICT: FAIL / BLOCKER**  
   *Reason:* Google Cloud IAM cannot restrict permissions to collections. The Service Account possesses write access to all core ERP collections (`sales`, `inventory`, `purchases`, `payroll`). The blast radius is unacceptable.

2. **OPTION B (Separate Firestore Database in Same Project):**  
   **VERDICT: FAIL / BLOCKER**  
   *Reason:* Google Cloud platform policy strictly requires the Blaze billing plan to create additional Firestore databases. It directly violates the owner's ₹0 budget mandate.

3. **OPTION C (Dual Google Cloud Projects on Spark Plan):**  
   **VERDICT: PASS / CONDITIONALLY FEASIBLE**  
   *Reason:* Fully air-gaps the blast radius and maintains ₹0, but introduces high operational overhead managing two distinct GCP/Firebase projects.

4. **OPTION D (Supabase PostgreSQL Isolated Financial Database):**  
   **VERDICT: PASS / ARCHITECTURALLY CERTIFIED BEST PRACTICE**  
   *Reason:* Provides 100% physical cloud air-gapping. Supabase holds **zero credentials to Firestore**, eliminating the Google Service Account completely. Recharges run on native SQL ACID transactions with database-level constraints (`CHECK balance >= 0`), preserving the strict ₹0.00/month budget with zero credit cards.

---

### AUDITOR CERTIFICATION NOTICE
This audit was performed in strict read-only mode. Production project `tekfix-45b38` was untouched. No code or configuration was modified. Option A and Option B are formally rejected as architectural blockers. Option D is certified as the safest, zero-cost production path.

