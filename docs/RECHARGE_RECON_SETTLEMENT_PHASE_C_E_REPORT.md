# Quick Recharge v2 — Phase C–E Report
## Period reconciliation, cumulative recharge, operator-wise distributor settlement

Date: 2026-11-19. Built from the approved design in `docs/RECHARGE_RECON_SETTLEMENT_PHASE_A_B.md` (owner approval: "Approve all four").
Nothing is committed. Nothing is deployed. No live shop data was read or written.

---

## 1. Files created — PASS (exist, analyzer clean)

| File | Purpose |
|---|---|
| `lib/recharge/recharge_period_accounting.dart` | Pure rules (no I/O):<br>• IST dates and filters, with Monday as week start<br>• periods; morning raw / recorded / unexplained; expected closing and variance<br>• volume (gross / refunds / net); per-operator settlement (outstanding / advance)<br>• rupee parsing; half-up rounding; integer-only ₹ formatting |
| `lib/recharge/recharge_accounting_backend.dart` | Backend interface + `LocalAccountingBackend`, an in-memory backend for tests and `localTestMock` mode. It is idempotent: the same key returns the same result, and concurrent same-key calls post once. |
| `lib/recharge/recharge_accounting_service.dart` | Picks the backend and enforces owner-only and online-only before anything is sent. It keeps a persisted idempotency key per form until the server confirms. It also contains `SupabaseAccountingBackend`, which signs every posting with the device key. |
| `lib/recharge/recharge_period_widgets.dart` | UI pieces:<br>• Morning dialog (raw → recorded → unexplained → classify)<br>• Reference-balance dialog; Night-closing dialog (variance + lock)<br>• Operator-wise payment dialog (advance preview)<br>• Operator Breakdown section with detail sheet; Settlement table |
| `supabase/migrations/20261120000001_recharge_period_reconciliation_settlement.sql` | Additive migration: new columns, `recharge_period_snapshots`, 7 `SECURITY DEFINER` procedures executable by `service_role` only, and tamper triggers |
| `test/recharge_period_settlement_test.dart` | 31 tests: TEST 1–14 plus edge cases |
| `test/recharge_period_ui_test.dart` | 7 tests: dialogs, offline block, phone width, rules text |
| `docs/RECHARGE_RECON_SETTLEMENT_PHASE_A_B.md`, this report | Audit and design; results |

## 2. Files modified — PASS

| File | Change |
|---|---|
| `lib/recharge/quick_recharge_screen.dart` | **Summary cards:**<br>• 6 required cards + the existing Successful and Failed/Pending cards<br>• "Available Wallet Float" renamed **Total Operator Wallet Balance** (live total; subtitle shows the total of openings)<br>**Operator cards:**<br>• show period figures with status chips<br>• Morning / Reference / Closing buttons open the new dialogs<br>**New sections:** Operator Breakdown and Distributor Settlement table added.<br>**"Direct Pay":** now opens the operator-wise server payment.<br>**Legacy settlement card:** stats now use operator-wise figures.<br>**Banner:** morning banner now uses the period state. |
| `lib/recharge/recharge_service.dart` | +1 read-only accessor: `getLocalRecharges()` |
| `lib/recharge/supabase_recharge_bridge_client.dart` | +1 method: `accountingCall()` (only `accounting-*` endpoints) |
| `supabase/functions/recharge-bridge/index.ts` | +7 `accounting-*` routes. They sit behind the existing global owner gate; each posting also has a device signature and server-side validation. |
| `firebase/firestore.rules` (deployed copy) and `lib/firestore.rules` (copy used by tests) | `recharge_distributors` and `recharge_daily_collections` create/update changed to **owner-only** |
| `test/quick_recharge_dashboard_test.dart` | Expects the renamed wallet card and the two new cards |

Not changed:
- `daily_reconciliation_screen.dart`
- `wallet_distributor_dialogs.dart`
- commission logic
- POS, Sales, Purchase, Inventory, Expenses

## 3. Existing components reused — PASS

- Data and models:
  - `OperatorWallet`, `WalletLedgerEntry` entry types, `DistributorProfile` (no second distributor master)
  - `RechargeEntry` statuses; the existing commission report (instant vs periodic split)
- Server and security:
  - the `recharge-bridge` owner gate (`verifyShopOwner`), `enforceHardwareSecurity` + challenge nonce
  - `recharge_prevent_ledger_tampering`
  - existing tables: `recharge_wallet_logs`, `recharge_distributor_ledger`, `recharge_audit_logs`
- UI and services:
  - `TekColors` dark theme, `_buildMetricCard`
  - `RechargeBackendBridge` modes, `DeviceSecurityService`

## 4. Database schema changes (Supabase, additive only) — NOT TESTED (not run anywhere)

**Existing tables, new columns only:**
- `recharge_wallet_logs`, new nullable/defaulted columns:
  - `adjustment_sign`, `category`, `period_id`, `idempotency_key` (unique), `reason`, `distributor_id`, `business_date`
- `recharge_distributor_ledger`, new columns:
  - `operator`, `idempotency_key` (unique), `signed_balance_before/after_paise`, `payment_date`, `reference_no`, `created_by`
  - Legacy `balance_*` columns get `GREATEST(…,0)` values, so the old CHECKs still hold.
- `recharge_distributors`, new columns: `default_operator`, `legacy_opening_paise`
  - A one-time derivation writes only these new columns. The legacy single balance becomes an opening payable on the default operator; if that is unknown, it is shown as "Unassigned".

**New table:** `recharge_period_snapshots`
- Holds morning, closing and reference snapshots.
- Unique per operator, period and kind; unique idempotency key.
- RLS denies direct access; it is immutable via the tamper trigger.

**Triggers:**
- New tamper trigger on `recharge_distributor_ledger`. No existing procedure updates or deletes it.

Existing data impact:
- No Firestore collections added or changed.
- No existing row updated (except the two new columns above), and nothing deleted.

## 5. Firebase Functions changes — NOT APPLICABLE

None. Recharge postings run on the Supabase Edge Function. Firebase Functions are not on this path.

## 6. Security rule changes — PASS (text check) / NOT TESTED (emulator)

- `recharge_distributors` create/update: `isShopMember` → `isOwner`.
- `recharge_daily_collections` create/update: `isShopMember` → `isOwner`.
- Verified by a rules-text test on both rules files. **Not** run in the Firestore Emulator: the rules-unit-testing package is not installed here, and installing it means a download.
- Left as-is (outside the approved scope): `recharge_daily_reconciliation` still allows shop-member create.

## 7. Accounting calculation rules (as implemented)

**Opening and period**
- Opening = the last **verified** closing (any date). A period runs from that closing's server time to the next one, so a recharge after closing belongs to the next period.
- No previous closing → no auto-calculation. The owner posts an audited **reference balance** instead.

**Morning entry**
- Raw = morning − previous closing.
- Recorded = signed ledger movements since that closing.
- **Unexplained = Raw − Recorded.**
- The server recomputes it. Only an owner-classified amount up to the remaining unexplained balance is posted.
- A negative value is a **Discrepancy** and is never auto-posted; only a documented correction can resolve it.

**Closing and variance**
- Expected = Opening + top-ups + credit loads + refunds/commission/bonus credits − settled actual debits − debited-pending − clawbacks ± adjustments.
- Variance = Actual − Expected → Match / Shortage / Excess. A debited-pending recharge makes it Investigation Required.
- Verifying a closing **locks** the period. A later correction is a new adjustment, never an edit; a non-adjustment entry dated into a locked period is refused.

**Volume**
- Gross = face value of recharges with status success or refunded (counted once per id).
- Refunds are dated when the refund happened. **Net = Gross − Refunds.**
- Failed, pending and disputed recharges are never counted.
- Distributor payments never touch volume.

**Settlement** (per distributor × operator)
- Balance = payable − paid → Outstanding = max(B,0), Advance = max(−B,0).
- Cards sum each separately, never netted. "Net position" is shown separately, for information only.

**Money**
- Integer paise. Rupee input is parsed without floating point; display formatting is integer-only (₹1,23,456.00).
- Rounding rule (helper + tests): half-up to the nearest paise, once per transaction. The existing commission code was **not** switched to it, to keep existing commission logic unchanged.

**Offline**
- All postings are blocked when the device reports no network.
- Nothing goes to the sync queue or Firestore. Hive holds only the form's idempotency key (draft), not the financial record.

## 8. Unit test results — PASS

```
flutter test test/recharge_period_ui_test.dart test/recharge_period_settlement_test.dart -r expanded
00:06 +38: All tests passed!
```

TEST 1–14 map to `recharge_period_settlement_test.dart`:

| Test | What it checks |
|---|---|
| TEST 1, 1b | morning net top-up, overnight recharge |
| TEST 2, 3 | expected closing, Shortage |
| TEST 4 | cumulative |
| TEST 5 | Airtel advance; Jio/Vi unchanged; cards 2,500 / 500 |
| TEST 6 | payment never lowers cumulative |
| TEST 7 | failed/pending/duplicate excluded |
| TEST 8 | same-key payment posts once |
| TEST 9 | refund counted once |
| TEST 10 | staff denied on all 5 postings + service |
| TEST 11 | actual debit vs face value |
| TEST 12 | 23:59 / 00:01 IST |
| TEST 13 | post-closing transaction in the next period |
| TEST 14 | concurrent keys |

Extra checks:
- closing missing, duplicate morning, negative difference, distributor credit classification
- shop closed for a day, locked period, reason required, partial/full payment
- network failure retry, app-restart key reuse, offline block, wrong-operator reversal
- validation limits, money parsing and rounding

## 9. Integration test results (full Flutter suite) — PASS with pre-existing failures

```
flutter test -r expanded
01:08 +793 -29: Some tests failed.
```

**29 failures, down from 30 before this work.** All of them are in files that were already failing before this change:
- dashboard_responsive_layout; phase16_3_financial_recovery; phase16_4_1; phase16_4_8
- phase16_desktop_and_recharge 10/11/15:
  - 10 is from pre-existing header and nav-grid overflows in a small test window;
  - 11 is from a cash-ledger amount in the old recharge dialog.
- phase7_security; recharge_failure_refund; recharge_phase10; recharge_reports; staging_password_auth

`quick_recharge_dashboard_test` now passes after the expected card-title update. No failure points at a file created in this work.

## 10. Emulator / database tests — NOT TESTED

- No Docker, Supabase CLI or Deno on this machine. The SQL migration and the edge-function TypeScript were **not compiled or executed**.
- Firestore Emulator rules tests were not run (see 6).
- Before production, run on staging:
  - `supabase db reset`, or apply the migration to a staging project;
  - `deno check supabase/functions/recharge-bridge/index.ts`;
  - the manual checklist below against staging.

## 11. flutter analyze — PASS for changed areas

```
flutter analyze lib/recharge test/recharge_period_settlement_test.dart test/recharge_period_ui_test.dart
No issues found!
```

The whole project still reports 666 issues, all in files this work did not touch: test lint and pre-existing warnings.

## 12. Windows EXE manual checklist — NOT TESTED (waiting for the owner)

Use a **staging** shop first.
1. Open Quick Recharge as owner. Expected:
   - 8 cards: Today, Cumulative, Total Operator Wallet Balance, Outstanding, Advance, Commission, Successful, Failed/Pending.
   - Operator cards show a status chip.
2. Operator with no verified closing. Expected:
   - The button reads **Reference**.
   - Enter the balance and a reason, tick confirm → saved. The chip changes from "Previous closing missing".
3. **Morning**: enter the app balance → the preview shows Previous closing / Actual / Already recorded / New Net Top-Up.
   - Save → status *Pending Verification* (orange).
   - Classify (Top-Up own), reason, confirm → status *Verified* (green). Expected closing increases by that amount only.
4. Morning below the closing with nothing recorded → *Discrepancy* (red). Nothing is posted until a correction with a reason.
5. Same operator, Morning again in the same period → blocked ("already entered").
6. **Closing**: enter actual = expected → *Match* (green). Actual lower → *Shortage* (red) and a reason is required.
   - After saving, the next Morning uses this closing as its opening.
7. Do a recharge after closing → it appears in the new period, not the closed one.
8. **Breakdown**: try Today / Yesterday / Last 7 / This Week (starts Monday) / This Month / Previous Month / Custom / All Time.
   - Totals change and Cumulative stays.
   - Tap an operator → the detail sheet opens.
9. **Pay distributor**: Airtel outstanding ₹1,000, pay ₹1,500 → the preview says ₹500 ADVANCE (blue).
   - After saving: Airtel advance ₹500; Jio and Vi unchanged; Outstanding card excludes Airtel; Advance card ₹500. Cumulative is unchanged.
10. Double-tap Record payment, or retry after a network error → only one payment row.
11. Turn off the network → any posting shows "You are offline… nothing was saved".
12. Log in as staff → Quick Recharge stays locked. Firestore writes to `recharge_distributors` from staff are rejected.

## Remaining limitations (honest list)

1. **Server side is unverified.** The Supabase migration and edge routes are written but were never executed or type-checked here, and they need deploying. **Until they are deployed, the period sections show a server error**, and the dashboard falls back to the old operator figures.
2. **Volume source.** Cumulative and operator volume come from the recharge records already on the device (the same source as the existing Today's total). That means no extra history download, but it is **not** a Firestore/SQL aggregation. A summary-vs-ledger check endpoint was **not** built. (Partial vs §5 PERFORMANCE RULE.)
3. **Other legacy paths are still client-side.** These old distributor flows still write from the client:
   - Agent Settlement and Recharge Return dialogs
   - the old `DistributorPaymentDialog` class (now unreachable from the dashboard)
   - recharge refunds and reversals

   Moving them to the server is a follow-up.
4. **Distributors must exist in Supabase.** A distributor that exists only in Firestore makes a v2 payment fail with `UNKNOWN_DISTRIBUTOR`.
5. **Old reconciliation screen still active.** The old calendar-day Daily Reconciliation screen remains reachable from the navigation grid and still writes its own records. The new flow lives on the operator cards.
6. **Edge-function shopId.** The edge function trusts `body.shopId` after `verifyShopOwner` confirms the caller owns that shop. That is the existing pattern, unchanged.
7. **Not run:** Windows EXE checks, emulator tests, and staging deployment.
