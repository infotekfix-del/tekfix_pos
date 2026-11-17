# TEKFIX ERP – RECHARGE COMMISSION CONTROL IMPLEMENTATION PLAN & ARCHITECTURAL REPORT
**Feature:** Owner-Controlled Operator Commission ON/OFF Gates  
**Supported Operators:** Bharti Airtel, Reliance Jio, Vodafone Idea (Vi), BSNL Mobile  
**Target Release:** Windows Desktop & Android Mobile (v1.0.30)  
**Status:** **PROPOSED ARCHITECTURE & TEST SPECIFICATION (AWAITING OWNER APPROVAL)**  
**Safety Invariant:** Read-Only Inspection Completed. Zero Production Code or Data Modified.

---

## 1. Existing Production Architecture Inspection

An in-depth inspection of the current recharge financial pipeline was conducted across Flutter, Hive, Firebase Firestore, and Supabase PostgreSQL:

```
[Flutter UI: QuickRechargeDialog]
       │
       ▼ (Checks: isOwner, isEnrolledLocally)
[RechargeRecoveryEngine: Write-Ahead Intent]
       │
       ▼ (Signs ECDSA P-256 Nonce)
[Supabase Edge Function: /process-debit]
       │
       ▼ (recharge_process_debit RPC)
[PostgreSQL Database: recharge_transactions & recharge_commissions]
       │
       ▼ (HTTP 200 OK + balanceAfterPaise)
[Local Hive Settlement: Cash/Bank Move + recharges.put]
```

### Key Architectural Findings:
1. **Commission Calculation Point (`lib/recharge/quick_recharge_dialog.dart` L121-124 & L317):**
   - Margin is currently derived from `_defaultMargins[_operator]`: Jio 3.0%, Airtel 2.8%, Vi 3.5%, BSNL 4.0%.
   - `retailPaise = (retailAmount * 100).round();`
   - `costPaise = (costPrice * 100).round();`
   - `commissionPaise = ((retailAmount - costPrice) * 100).round();`
2. **Server-Side Commission Automation (`public.recharge_process_debit`):**
   - In PostgreSQL, if `p_commission_earned_paise > 0`, a row is automatically inserted into `public.recharge_commissions`.
   - If `p_commission_earned_paise == 0`, no commission row is inserted, and `v_cost_paise = p_amount_paise`.
3. **Double-Entry Ledger Integrity:**
   - When commission is earned, wallet is debited by `costPricePaise`, customer pays `retailAmountPaise`, and difference is recognized as commission income.
   - If commission is disabled (OFF), wallet is debited by `retailAmountPaise`, customer pays `retailAmountPaise`, resulting in ₹0 commission income and zero margin liability.
4. **Client-Side Bypass Risk Identified:**
   - Currently, commission rates are calculated in client code and sent to `/process-debit`.
   - **Remediation Required:** Commission ON/OFF must be enforced **server-authoritatively** inside the PostgreSQL RPC or Edge Function to satisfy Requirement 10 ("Prevent local cache or client-side bypass").

---

## 2. Server-Authoritative Database & Backend Design

### A. Supabase PostgreSQL Schema Extension
A dedicated, air-gapped configuration table with Row-Level Security (RLS) denying all direct client access:

```sql
-- 1. Operator Commission Control Table
CREATE TABLE IF NOT EXISTS public.recharge_commission_controls (
    shop_id TEXT NOT NULL,
    operator TEXT NOT NULL, -- 'AIRTEL', 'JIO', 'VI', 'BSNL', 'OTHER'
    is_enabled BOOLEAN NOT NULL DEFAULT true,
    margin_basis_points INT NOT NULL DEFAULT 300, -- 300 bps = 3.00%
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by_uid TEXT NOT NULL,
    PRIMARY KEY (shop_id, operator)
);

-- Deny direct public/authenticated client mutations (RLS)
ALTER TABLE public.recharge_commission_controls ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Deny direct client access" ON public.recharge_commission_controls 
FOR ALL TO anon, authenticated USING (false);

-- 2. Immutable Audit Log for Commission Settings Changes
CREATE TABLE IF NOT EXISTS public.recharge_commission_control_audits (
    audit_id TEXT NOT NULL PRIMARY KEY,
    shop_id TEXT NOT NULL,
    operator TEXT NOT NULL,
    previous_enabled BOOLEAN NOT NULL,
    new_enabled BOOLEAN NOT NULL,
    margin_basis_points INT NOT NULL,
    owner_uid TEXT NOT NULL,
    owner_name TEXT NOT NULL,
    device_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.recharge_commission_control_audits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Deny direct client access" ON public.recharge_commission_control_audits 
FOR ALL TO anon, authenticated USING (false);
```

### B. Server-Side RPC & Edge Function Enforcement
1. **`GET /commission-controls?shopId=...`:**
   - Returns the live ON/OFF status and margin for all 4 operators.
2. **`POST /update-commission-control`:**
   - **Auth Gate:** Validates Firebase Auth ID Token for `shopId` owner.
   - **Device Gate:** Verifies ECDSA P-256 single-use challenge nonce and signature from trusted hardware.
   - **Audit Gate:** Atomically inserts row into `recharge_commission_control_audits` and updates `recharge_commission_controls`.
3. **`recharge_process_debit` Server Enforcement:**
   - During transaction execution, PostgreSQL checks `recharge_commission_controls`:
     ```sql
     SELECT is_enabled INTO v_commission_enabled 
     FROM public.recharge_commission_controls 
     WHERE shop_id = p_shop_id AND operator = UPPER(p_operator);
     
     IF v_commission_enabled = false THEN
         -- Server-authoritative clamp: Force zero commission regardless of client payload
         v_commission_earned_paise := 0;
         v_cost_paise := v_retail_paise;
     END IF;
     ```
   - **Guarantee:** A compromised or outdated client cannot force commission credit when the server has toggled that operator OFF.

---

## 3. Mathematical Invariants & Accounting Rules

### Scenario 1: Commission ON (Standard Operation)
- **Retail Amount:** ₹239.00 (`retailPaise = 23900`)
- **Operator:** Jio (3.0% margin / 300 bps)
- **Calculations:**
  - `costPaise = 23900 - round(23900 * 0.03) = 23900 - 717 = 23183` (₹231.83)
  - `commissionPaise = 23900 - 23183 = 717` (₹7.17)
- **Ledger Impacts:**
  - Operator Wallet (`WALLET_JIO`): Decremented by **23,183 paise** (₹231.83 cost).
  - Cash / Bank Drawer: Incremented by **23,900 paise** (₹239.00 customer payment).
  - Commission Income: Credited by **717 paise** (₹7.17 profit).
  - Net Accounting Balance: `+239.00 (Asset) - 231.83 (Asset) = +7.17 (Equity/Profit)`. Balanced.

### Scenario 2: Commission OFF (Disabled by Owner)
- **Retail Amount:** ₹239.00 (`retailPaise = 23900`)
- **Operator:** Jio (Commission OFF)
- **Calculations:**
  - `costPaise = 23900` (₹239.00)
  - `commissionPaise = 0` (₹0.00)
- **Ledger Impacts:**
  - Operator Wallet (`WALLET_JIO`): Decremented by **23,900 paise** (₹239.00 full retail).
  - Cash / Bank Drawer: Incremented by **23,900 paise** (₹239.00 customer payment).
  - Commission Income: **0 paise** (No entry written to `recharge_commissions`).
  - Commission Ledger: **0 paise** (No entry written to `recharge_wallet_logs` for commission).
  - Net Accounting Balance: `+239.00 (Cash) - 239.00 (Wallet) = 0.00`. Zero margin, zero liability.

---

## 4. Owner Management UI & Staff Access Restrictions

### A. Owner Settings Screen
- Located in `QuickRechargeScreen` header actions as an exclusive Owner option: **"കമ്മീഷൻ നിയന്ത്രണം (Commission Controls)"**.
- Displays an operator grid:
  - **Bharti Airtel:** Switch (ON/OFF) • Current Rate: 2.8%
  - **Reliance Jio:** Switch (ON/OFF) • Current Rate: 3.0%
  - **Vodafone Idea (Vi):** Switch (ON/OFF) • Current Rate: 3.5%
  - **BSNL Mobile:** Switch (ON/OFF) • Current Rate: 4.0%
- **Toggle Interaction:**
  - Toggling an operator presents a mandatory confirmation dialog:
    - *Title:* "ഭാരതി എയർടെൽ കമ്മീഷൻ മാറ്റുക (Toggle Airtel Commission)"
    - *Input:* **മാറ്റത്തിനുള്ള കാരണം (Reason for Change)** — Minimum 5 characters required.
    - *Action:* Cryptographically signs change and commits to server.

### B. Staff Protection (Zero Access)
- Staff role (`AuthController.instance.isOwner == false`) is barred at 4 points:
  1. Menu items for commission settings are completely omitted from staff UI.
  2. Directly calling the dialog method triggers an immediate security alert and halts.
  3. Client-side controllers throw `StateError('Owner authorization required')`.
  4. Backend Edge Function validates Firebase UID against shop owner UID; staff requests are rejected with `HTTP 403 Forbidden`.

---

## 5. Comprehensive Test Specification (Pre-Implementation Plan)

Before deploying any production code, the following test suite will be implemented and executed:

| Test ID | Test Scenario | Expected Outcome | Verification Method |
| :---: | :--- | :--- | :--- |
| **COMM-CTRL-01** | Default state initialization | All 4 operators initialize to `is_enabled: true` | Unit test checking default map |
| **COMM-CTRL-02** | Owner toggles Airtel commission OFF | Server updates setting to `false`, writes immutable audit log with reason | Integration test with mocked Edge client |
| **COMM-CTRL-03** | Staff attempts to toggle commission | Request is rejected fail-closed with `Owner authorization required` | Security assertion test with staff role |
| **COMM-CTRL-04** | Recharge with Commission OFF | Wallet is debited full retail amount, commission is 0 paise, no commission entry created | End-to-end accounting simulation |
| **COMM-CTRL-05** | Recharge with Commission ON | Wallet debited at cost price, commission entry created in integer paise | Verification against historical formula |
| **COMM-CTRL-06** | Rogue client attempts to inject commission when OFF | Server clamps commission to 0 paise and debits full retail amount | Adversarial edge function test |
| **COMM-CTRL-07** | Historical immutability check | Toggling commission OFF does not modify any prior `recharge_transactions` or `recharge_commissions` | Pre/post database snapshot diff |
| **COMM-CTRL-08** | Interrupted/Pending transaction recovery | Recovery engine settles transaction using parameters recorded at intent time | Crash-recovery engine test |
| **COMM-CTRL-09** | Concurrency test | Simultaneous toggling and recharge debits do not produce race conditions or negative balances | Parallel async stress test |
| **COMM-CTRL-10** | EOD Daily Reconciliation | Night closing balances correctly balance with mixed commission ON/OFF transactions | Reconciliation formula audit |

---

## 6. Implementation Roadmap

1. **Phase 1: Backend Schema & Server Logic (Supabase)**
   - Apply SQL migration for `recharge_commission_controls` and `recharge_commission_control_audits`.
   - Update `recharge_process_debit` RPC with server-authoritative clamp.
   - Add `/get-commission-controls` and `/update-commission-control` in `recharge-bridge/index.ts`.
2. **Phase 2: Client Service & Models (Flutter)**
   - Create `RechargeCommissionControl` model with integer paise / basis points.
   - Add `getCommissionControls` and `updateCommissionControl` to `SupabaseRechargeBridgeClient` and `RechargeService`.
   - Update `QuickRechargeDialog._onAmountChanged` and `recordRecharge` to respect operator toggle.
3. **Phase 3: Owner UI**
   - Add `OperatorCommissionControlDialog` with Malayalee localization, reason validation, and hardware signing.
4. **Phase 4: Full Automated Verification**
   - Run complete unit and integration test suite (Tests COMM-CTRL-01 through COMM-CTRL-10).
5. **Phase 5: Release Build & Handover**
   - Bump version to `1.0.30+30` and prepare Windows and Android artifacts.

---

## 7. Explicit Decision Gate

> [!IMPORTANT]
> **STOP AND VERIFY:** In accordance with user directives and strict safety rules, **zero production code, database tables, or ledger entries have been modified**.
> 
> The architecture, schema, mathematical models, UI controls, and test suite are fully drafted and documented above.
> 
> **Awaiting Owner Authorization to proceed with implementation.**
