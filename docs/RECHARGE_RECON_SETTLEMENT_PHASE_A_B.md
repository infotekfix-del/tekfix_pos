# Quick Recharge – Reconciliation, Cumulative Tracker & Distributor Settlement
## Phase A (Audit) + Phase B (Accounting Design) — awaiting owner approval

Date: 2026-11-19. Read-only audit. No code, rules, functions or data were changed.

---

## PHASE A — EXISTING SYSTEM AUDIT

### A1. Where things actually live (important)

| Concern | Today | Evidence |
|---|---|---|
| Server path for financial posting | **Supabase Edge Function `recharge-bridge` + Postgres procedures**. Firebase Cloud Functions are not used for recharge | `lib/recharge/recharge_backend_bridge.dart` (default mode `supabaseEdgeFunction`); `supabase/functions/recharge-bridge/index.ts`; `supabase/migrations/2026110900000[2-3]_*.sql` |
| Owner authorization on server | Edge function verifies Firebase ID token, reads `shops/{shopId}/users/{uid}` (active, approved, role owner), plus ECDSA device signature and challenge nonce | `index.ts:227-345`, client `requestChallenge` |
| Recharge debit, wallet top-up, distributor credit load | Go through server (`process-debit`, `process-topup`, `process-distributor-load`) | `recharge_service.dart:542, 948, 1157, 1361` |
| **Distributor payment** | **Client-only.** Writes Firestore directly (`recharge_distributors`, `recharge_distributor_ledger`, `accounting_cash_bank`) and calls `Db.moveMoney`. The server endpoint `process-distributor-settlement` exists but is **never called** | `recharge_service.dart:1530-1700` |
| Refund / reversal / daily reconciliation | Client-side. Server endpoints `process-refund`, `process-reversal`, `process-reconciliation` exist but are **never called** | grep: no client callers |
| Morning opening / night closing | Client writes Hive box `boxRechargeReconciliation` and Firestore `recharge_daily_reconciliation/{businessDate}` | `recharge_service.dart:5043-5520` |
| Distributor master | Recharge module's own `DistributorProfile` (`recharge_distributors`), **not** the ERP Parties module | `recharge_models.dart:552` |
| Reports / Today's totals | Computed in the client from the in-memory `_localRecharges` cache (Hive-hydrated) | `recharge_service.dart:4285` |
| Business date | `getBusinessDate()` = UTC + 05:30 (correct IST) | `recharge_service.dart:208` |

### A2. How each dashboard number is computed today

| Card | Formula today |
|---|---|
| Today's Total Recharge | Sum of today's successful `RechargeEntry.amount` (face value) from the local cache |
| Available Wallet Float | Σ over Airtel/Jio/Vi/BSNL of live `ownPrepaidBalancePaise + distributorCreditBalancePaise` (from server `get-wallet`) |
| Distributor Outstanding | Σ distributors of `openingPayable + totalCreditReceived − totalPaymentsMade − totalAdjustments` |
| Today's Commission | `netCommissionIncomePaise` from the report |

### A3. Commission model (Definition E)

- **Prepaid load margin.** The commission comes at **top-up time**. The bank pays ₹1,000 and the wallet receives ₹1,030 (`PREPAID_TOPUP_WITH_COMMISSION`, `recharge_service.dart:2864-2945`). The ₹30 is recorded as a confirmed commission.
- **Postpaid accrual.** This is a separate, later commission entry (`recordPostpaidCommission`). A `COMMISSION_CREDIT` wallet log is written when it is settled to the wallet.
- **Clawback.** `COMMISSION_WALLET_REVERSAL` is used for this.
- **No operator deducts commission at recharge time** in the current code. So for every operator today, **wallet debit = face value**. Definition E's "instant deduction" case is supported in the design (field `walletDebitPaise`), but no existing data uses it.

### A4. How distributor payable is created today

- `processDistributorCredit` increases both `wallet.distributorCreditBalancePaise` and `distributor.totalCreditReceivedPaise` by the same amount (`recharge_service.dart:1080-1120`).
- An agent settlement can also add `totalAdjustmentsPaise` and `pendingReturnPaise`.
- A distributor has **one** outstanding balance and a single `defaultOperator`. There are **no per-operator accounts**.
- `DistributorLedgerEntry` has **no operator field**. The Supabase ledger does have `wallet_id`.

### A5. Conflicts with the Section 2 definitions and the v2 rules (reported, not resolved)

| # | Conflict | Where |
|---|---|---|
| C1 | **Opening ≠ previous verified closing.** The morning opening is typed in by hand and stored as a reconciliation voucher only. Nothing is carried forward | `recordMorningOpeningBalance` |
| C2 | **Period = calendar date**, not closing snapshot → closing snapshot. Recharges after closing still count in the same day | `calculateAutomaticReconciliation` filters logs by `getBusinessDate(e.timestamp) == businessDate` |
| C3 | No raw / unexplained difference, no classification step, no Pending Verification / Discrepancy statuses | — |
| C4 | **Distributor payment is client-authoritative.** It is also not truly idempotent: a random ID is generated per tap, and the duplicate check is in memory only | `recordDistributorPayment` |
| C5 | **Excess payment is blocked on the server.** `outstanding_balance_paise CHECK (>= 0)` and the procedure raises an error if the payment is larger than the outstanding. The client ledger entry clamps the after-balance to 0 | SQL `20261109000002:83`, `…0003:291-345` |
| C6 | **No operator-wise distributor accounts** (Section 8C) | model |
| C7 | **Two ledgers.** Supabase tables are authoritative for wallet debits and top-ups, but reconciliation reads Firestore `recharge_wallet_logs`. The two can drift | `calculateAutomaticReconciliation:5207` |
| C8 | **Rules weakness.** `recharge_distributors` allows create/update by **any shop member** (staff could edit outstanding). `recharge_daily_reconciliation` and `recharge_daily_collections` also allow writes by shop members | `firebase/firestore.rules:457-460, 496-505` |
| C9 | Recharge accounting writes go to **Hive and Firestore directly**. They are not routed through the sync queue. However, they are not blocked when offline (Firestore SDK offline persistence will queue them) | service |
| C10 | **Date filters use device-local midnight**, not IST. Last 7 Days, Previous Month and All Time filters are missing | `DateRangeFilterType.getRange` |
| C11 | **All-time totals would need the full local history.** No aggregation or summary docs exist | `generateFinancialReport` |
| C12 | **Owner instruction conflict.** Earlier in this project you said *"don't touch supabase/"*. A correct server path (v2 §11, §12) needs **new Supabase migrations and edge-function routes** | — |

### A6. Reusable components

- `OperatorWallet`, `WalletLedgerEntry` (entry types), and `getBusinessDate` / `getShopNow` (IST).
- `DailyReconciliationRecord` and `DailyOperatorBalanceEntry` (fields already present: opening, top-ups, credits, debits, reversals, expected, actual, difference, lock via `isImmutable`, corrections via `authorizeReconciliationCorrection`).
- `DistributorProfile`, `DistributorLedgerEntry`, `recharge_distributor_ledger`.
- `RechargeReportFilter` and `generateFinancialReport` (gross / refund / failed per operator).
- Commission controls and clawback (unchanged).
- Server: `verifyShopOwner`, device signature, challenge nonce, `recharge_prevent_ledger_tampering` trigger, and the top-up idempotency pattern from migration `20261116000002`.
- `daily_reconciliation_screen.dart` (morning and night UI) and `wallet_distributor_dialogs.dart` (payment dialog) can be extended rather than replaced.
- About 20 existing recharge test files, including `recharge_daily_reconciliation_test.dart` (21 tests) and `recharge_float_distributor_settlement_test.dart`.

### A7. Minimum required changes (summary)

1. **Server (Supabase).** Add a migration and edge routes for:
   - period close and morning verify (with classification);
   - per-operator distributor payment that allows an advance;
   - an idempotency key on every new posting;
   - read-only aggregate endpoints.
2. **Client.** Route these four postings to the server and block them when offline. Add period logic, the new dashboard cards and tables, and the date filters.
3. **Firestore rules.** Tighten C8 to owner-only.
4. **No new collections or tables** where an existing one fits (see B6).

---

## PHASE B — ACCOUNTING DESIGN

All amounts are integer paise. Operators *o* ∈ {Airtel, Jio, Vi, BSNL}. Period *P* is defined for one operator.

### B1. Period

- `P_k` = (`closeTs(k−1)`, `closeTs(k)`], where `closeTs` is the server timestamp of a **verified** closing snapshot.
- `periodId = "{operator}_{closeTs(k−1) as ISO}"`.
- A ledger entry belongs to `P_k` if `closeTs(k−1) < entry.serverTs ≤ closeTs(k)` (open-ended for the current period).
- `businessDate` (IST) is stored for reporting only. It never decides the period. This handles a shop that was closed on Sunday (C) and a recharge done after closing (§13 #23).

### B2. Opening

```
Opening(o, P_k) = ActualClosing(o, P_{k−1})   // last VERIFIED closing, any date
```

If no verified closing exists, the status is `PREVIOUS_CLOSING_MISSING`. No auto-calculation is done. The owner posts a **reference-balance adjustment** (type `OPENING_REFERENCE`, audited). That adjustment becomes the opening of the first period.

### B3. Morning entry

```
RawDiff        = MorningActual − Opening
RecordedNet    = Σ signed ledger entries for o with closeTs(k−1) < ts ≤ morningTs
                 (+TOPUP +CREDIT_LOAD +COMMISSION_CREDIT +REVERSAL_CREDIT
                  −RECHARGE_DEBIT(walletDebitPaise) −COMMISSION_WALLET_REVERSAL ± ADJUSTMENT)
Unexplained    = RawDiff − RecordedNet
```

- `Unexplained > 0` → status **Pending Verification**. The owner must classify it (Top-Up own / Top-Up distributor credit (+ distributor) / Refund / Bonus / Commission credit / Manual correction / Other). One ledger entry is posted for that amount.
- `Unexplained < 0` → status **Discrepancy**. Nothing is posted automatically. The owner investigates, then posts a documented adjustment (status **Adjustment Required** until then).
- `Unexplained = 0` → status **Verified**.
- Only `Unexplained` is ever posted. RawDiff is never posted.
- The morning submission is idempotent per `(shopId, o, periodId)`. A second submission returns the first result.

TEST 1: Opening 500, morning 1,500, RecordedNet 0 → Unexplained **1,000**.
TEST 1b: a ₹200 recharge is recorded after closing, so RecordedNet = −200. Unexplained = 1,000 − (−200) = **1,200**. The ₹200 debit is already in the ledger and is not posted again.

### B4. Expected closing and variance

```
Expected(o,P) = Opening
              + Σ TOPUP + Σ PREPAID_TOPUP_WITH_COMMISSION      (incl. confirmed morning top-up)
              + Σ CREDIT_LOAD + Σ COMMISSION_CREDIT + Σ REFUND/REVERSAL_CREDIT
              − Σ RECHARGE_DEBIT.walletDebitPaise   (status SUCCESS, or PENDING with walletDebited=true)
              − Σ COMMISSION_WALLET_REVERSAL
              ± Σ ADJUSTMENT
Variance      = Actual − Expected
```

- Status: Variance = 0 → **Match**; < 0 → **Shortage**; > 0 → **Excess**. Owner flag, or a pending recharge that is still unresolved → **Investigation Required**.
- Pending recharges that have not debited the wallet are shown separately and are not subtracted. A failed recharge has no debit log, so it is never subtracted.
- Verifying a closing writes a **locked** snapshot. A later correction is an `ADJUSTMENT` entry in the next period that references the locked one. The locked record is never edited.

TEST 2: 500 + 1,000 + 500 − 1,200 = **800**. TEST 3: Actual 750 → Variance **−50, Shortage**.

### B5. Recharge volume, cumulative and breakdown

```
Gross(o, range)  = Σ faceValuePaise   where status = SUCCESS (incl. later refunded, counted once)
Refunds(o,range) = Σ refund/reversal paise dated in range
Net              = Gross − Refunds
Cumulative(o)    = Gross over All Time;  CumulativeTotal = Σ_o Cumulative(o)
Today            = range = today's IST business date
```

- Failed, cancelled and duplicate (same `rechargeId`) transactions are excluded.
- **Distributor payments never touch any recharge record, so Cumulative can never go down because of one.** TEST 6 asserts this.
- TEST 4: 1,000 + 500 + 2,000 + 0 = **3,500**.
- **Source.** Server SQL aggregate (`SUM … GROUP BY operator`) over `recharge_transactions`, through a read-only edge route. No full history is downloaded. Optional daily summary rows are derived and rebuildable. A "summary vs ledger" check endpoint compares them.
- **Date filters.** Today, Yesterday, Last 7 Days, This Week (**Monday** start, shown in the UI), This Month, Previous Month, Custom, All Time. All boundaries use IST `[00:00, 24:00)`.

### B6. Distributor settlement (per distributor, per operator)

```
Payable(d,o)     = OpeningPayable(d,o) + Σ CREDIT_LOAD(d,o) − Σ Adjustments(d,o)
Paid(d,o)        = Σ PAYMENT(d,o)
Balance(d,o)     = Payable − Paid
Outstanding(d,o) = max(Balance, 0)      Advance(d,o) = max(−Balance, 0)

Card Outstanding = Σ_{d,o} Outstanding(d,o)     // never netted
Card Advance     = Σ_{d,o} Advance(d,o)
Net Position     = Outstanding − Advance        // info only, separate label
```

- A payment carries `operator`. It only touches `(d, o)`. An excess is never moved to another operator.
- Existing data: the current single balance per distributor is migrated **read-only** as `OpeningPayable(d, defaultOperator)`. Ledger rows without an operator are mapped to `defaultOperator`. No existing row is edited.
- TEST 5: Airtel 1,000 / Jio 500 / Vi 2,000, then pay Airtel 1,500. Airtel goes to −500 (**Advance 500**); Jio and Vi are unchanged. Outstanding card **2,500**, Advance card **500**, Net **2,000**.

### B7. Proof that nothing is counted twice

| Dimension | Inputs | Never includes |
|---|---|---|
| A. Recharge volume | `recharge_transactions.face_value` (SUCCESS) | wallet logs, distributor payments, commission |
| B. Wallet balance | wallet ledger entries only (top-ups, credit loads, debits = `walletDebitPaise`, commission credits/clawbacks, adjustments) | distributor *payments* (a payment is cash leaving the shop, not wallet money), recharge face value |
| C. Distributor settlement | distributor ledger (credit loads, payments, adjustments) | recharge volume, wallet debits |

- A distributor credit load is posted **once**, as a single atomic transaction that writes two rows: a wallet log (B) and a distributor ledger row (C). These are two different dimensions, not a double count.
- A prepaid commission adds to the wallet once, via `PREPAID_TOPUP_WITH_COMMISSION`. Income is recognised once, in commissions. The wallet log is not counted as income.
- The morning top-up posts only `Unexplained`, and `RecordedNet` already removes entries that are in the ledger. This is the TEST 1b proof.

### B8. Ledger record fields (every new financial row)

`shopId, operator, distributorId?, amountPaise, transactionType, businessDate (IST), periodId, createdAt (server now()), createdBy, status, referenceId, idempotencyKey (UNIQUE per shop)`.

- **Rounding rule.** Commission % uses `round-half-up to the nearest paise, applied once per transaction`, documented in code and tested.
- **Offline rule.** These four postings are blocked when offline:
  - morning top-up classification;
  - closing verification;
  - adjustments;
  - distributor payments.

  They are never written to Hive, the sync queue or the Firestore offline cache. The client creates the `idempotencyKey` before the first attempt and stores it with the pending form (Hive, form draft only). A retry, or a retry after an app restart, reuses the same key.

### B9. Planned changes (for approval)

**Supabase (`supabase/`), which needs your explicit OK because of C12:**

1. **New migration** `2026112000000x_recharge_period_reconciliation_settlement.sql`. It is **additive only**:
   - `recharge_distributor_ledger`: add `operator`, `idempotency_key` (unique) and `entry_type 'opening_payable'`. Relax `balance_after_paise >= 0` for new rows only (new column `signed_balance_after_paise`); old CHECKs stay for old rows.
   - New table `recharge_period_snapshots` (morning and closing snapshots, lock flag, `period_id`, unique `(shop, operator, period_id, kind)`). The existing `recharge_daily_reconciliation` table cannot be reused because its key is the calendar date.
   - `recharge_wallet_logs` and `recharge_transactions`: add a nullable `wallet_debit_paise` (defaults to face value) and `idempotency_key`.
   - New procedures, each `SECURITY DEFINER`, row-locked and idempotent:
     - `recharge_verify_morning`
     - `recharge_post_classified_adjustment`
     - `recharge_verify_closing`
     - `recharge_distributor_payment_v2` (allows advance, per operator)
     - `recharge_volume_aggregate` (read-only)
     - `recharge_settlement_aggregate` (read-only)
2. **Edge function `recharge-bridge/index.ts`.** Add six routes that reuse the existing `verifyShopOwner` and device signature checks, plus server-side validation:
   - amount > 0 and ≤ ₹10,00,000;
   - operator is in the enum;
   - date is not in the future and not in a locked period;
   - idempotency key format.

**Firestore rules (`firebase/firestore.rules`):**

- `recharge_distributors` create/update → **owner only** (C8).
- `recharge_daily_collections` create/update → owner only.

**Firebase Functions:** none.

**Client (`lib/recharge/` only):**

- Models: new fields are optional with defaults, so old data still parses.
- `recharge_service.dart`: new server-routed methods. `recordDistributorPayment` is routed to `distributor-payment-v2`, and the old direct Firestore write is kept only in `localTestMock` mode.
- Period logic and the online-only guard.
- `quick_recharge_screen.dart`:
  - six cards;
  - operator balance cards (opening / morning and net top-up / today / expected / actual / variance);
  - operator breakdown table;
  - settlement table;
  - status colours.
- `daily_reconciliation_screen.dart`: raw → recorded → unexplained → classify flow.
- `wallet_distributor_dialogs.dart`: operator field, advance display, idempotency key.
- `recharge_models.dart` (`DateRangeFilterType`): the new filters, in IST.

**Tests:** new `test/recharge_period_settlement_test.dart` (TEST 1–14) on the local mock backend, plus SQL tests for the Supabase procedures.

### B10. Limitations to know now

- **Emulators.** Section 14 asks for Firestore Emulator and Functions tests. The posting path is Supabase, so the equivalent is a **local Supabase stack** (`supabase start`, needs Docker). If Docker is not available here, those items will be reported as **NOT TESTED**, and only the Dart mock-backend and unit tests will run.
- **Not runnable by me:**
  - deploying migrations or edge functions to staging or production;
  - the Windows EXE manual checklist.
- **Unverified (C7).** I have not confirmed that Supabase and Firestore wallet logs match for live data. I will not read production data to check. Phase C would add a read-only "ledger consistency" check you can run yourself.

---

## DECISIONS NEEDED BEFORE PHASE C

1. **Approve editing `supabase/`** (migration + edge routes) — C12. Without it, the financial postings cannot be server-authoritative, and §11 and §12 cannot be met.
2. **Approve the per-operator distributor model** and the read-only mapping of today's single balance to `defaultOperator` (B6).
3. **Approve tightening the Firestore rules** for `recharge_distributors` and `recharge_daily_collections` to owner-only (C8).
4. **Approve leaving `recharge_daily_reconciliation` in place, read-only for history**, with new periods going into `recharge_period_snapshots`.
