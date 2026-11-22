# TekFix POS — Status Report & Handover (2026-11-22)

Owner: unais. Repo: `D:\tekfix_pos`, branch `phase-16-4-execution-20261117`.
Last pushed commit: `7520c3e`. Work after that commit is listed in section 2 (deployed 22 Nov; code commit pending).

---

## 1. ചെയ്തു കഴിഞ്ഞത് (Done and live)

### Quick Recharge (server-authoritative, Supabase)
- Agent settlement, recharge amount return, customer refund, failed / commission / credit reversals: server-only, owner-only, online-only, with idempotency keys.
- Own Money option removed: every wallet refill is distributor credit.
- Refill commission 3.9%: ₹1,039 = ₹1,000 payable + ₹39 profit (Top-up Commission card).
- Excess is a separate account (not own money, not profit); a Shortage is only shown.
- Distributor is picked automatically from the operator (Jio → Kochi Jio Prime, Airtel → Apex, …).
- **Recharge Edit (✏️)** on SUCCESS rows: mobile number / Cash↔UPI edit, or a Correction for a wrong amount/operator (the old entry becomes CORRECTED, its wallet debit comes back, and New Recharge opens pre-filled). Locked after that operator's night closing is verified.
- Supabase: migrations up to `20261128000001` on Staging and Production; `recharge-bridge` is Staging v41, Production v10.

### Purchases / Vendors
- Vendor balance = bills − returns − payments (integer paise).
- Delete Bill is now **Void** (no hard delete, reason required, Firestore copy marked voided); payments on a voided bill stay as vendor advance.
- Purchase Return (Credit Note or Cash/Bank refund), limited to the bill amount, unique return ID, cannot double-save.
- Owner-only: Void and Return (checked by AuthController only).
- Return amount starts empty; Record Payment pre-fills the exact balance (₹278.50, not ₹279).

### Daily Register (EOD)
- Expected cash = opening + sales cash + recharge cash − recharge agent cash − refunds − expenses − drawings
  − vendor cash paid + customer dues received + service advances + commission cash ± Money In/Out.
- Each line shows on the EOD sheet, PDF and WhatsApp report. UPI/Bank is never counted as drawer cash.
- Staff salary is already an expense, so it is not added again.

### Tests
- Full suite: **951 passed, 0 failed** (4 UAT-only tests skipped in the production build; they pass with `--dart-define=TEKFIX_ENV=staging_uat`).

---

## 2. ഇന്ന് ചെയ്ത security / bug fixes (NOT committed yet)

| # | What | Status |
|---|------|--------|
| 1 | **Firestore: anyone signed in could make themselves OWNER of any shop** (`shops/{shop}/users/{uid}` allowed self-create with any role) | Fixed in `firebase/firestore.rules` + `lib/firestore.rules`. Emulator-tested. **Deployed to Production 22 Nov (old rules: `D:	ekfix_backupsirestore_rules_20261122`).** |
| 2 | **Firestore: staff could edit the shop document, incl. `ownerUid`** | Fixed (owner only; `ownerUid` cannot change from the client). Emulator-tested. **Deployed.** |
| 3 | **Firestore: a catch-all rule overrode every owner-only rule** (staff could write users/roles, settings, salary_payments, meta, owner_withdrawals, trusted_devices; read campaigns/message_log) | Fixed by excluding those collections from the catch-all. Staff sync (sales, staff, returns, …) still works. Emulator-tested. **Deployed.** |
| 4 | **Supabase: 13 money procedures were callable with the public anon key** (`recharge_process_debit`, `recharge_process_topup`, `recharge_update_commission_control`, …), skipping the Edge Function's owner check | Migration `20261129000001_recharge_revoke_public_execute.sql`. **Applied on Staging and Production and verified** (0 open, service_role keeps access). |
| 5 | **App update hijack**: `app_config/version` is writable by any signed-in user, and the app downloaded whatever link it held | The app now accepts update links only from `https://github.com/infotekfix-del/tekfix_pos/` (`AppUpdateInfo.isTrustedUpdateUrl`); other links are blocked. Built into the new EXE. |
| 6 | GitHub token was stored in the git remote URL and in 2 release scripts | Removed; scripts read `GITHUB_TOKEN`. The old tokens were revoked and a new one was set by the owner. |
| 7 | Dashboard stat cards overflowed on small phones (360px) | Fixed (sparkline hides when there is no room). |
| 8 | 29 old failing tests | Updated to current behaviour (recharge money never moves ERP cash/bank: the separation rule from commit `cbae208`; new screen texts; theme rules; staging-only tests run only in UAT). |

Firestore rules tests: `tools/firestore_rules_test` (25 cases, all pass). Run them before every rules deploy.

---

## 3. ഉടമ ചെയ്യേണ്ടത് (Owner actions)

1. Security fixes #1–#4 are deployed. Open Quick Recharge once and check it loads normally (it reads the server).
2. **GitHub 2FA** before 11 Dec 2026 (banner on github.com).
3. Record today's ₹1,000 vendor cash payment: Purchase Bills → Record Payment / Record Advance Payment, mode **Cash**.
4. When the first recharge of the day exists, ask for the ✏️ Edit check (open the dialog only; one small Cash → UPI → Cash test if you agree).
5. Open the app only with the Desktop "TekFix POS (New)" or the taskbar icon (both are the Release build). Never two copies at once.

---

## 4. ഇനി ചെയ്യാനുള്ളത് (Backlog, in priority order)

| Priority | Item | Notes |
|---|---|---|
| CRITICAL | **Root Firestore collections are open to any signed-in user** (`/purchase_bills`, `/vendor_ledger`, `/accounting_cash_bank`, `/audit_logs`, `/products`, `/stock_units`, plus old `/sales`, `/parties`, `/staff`, `/salary_payments`, …) | Root docs have no `shopId`, so the rules cannot scope them. Plan: (a) stop the root "dual-writes" in `purchase_bill_service.dart` (lines ~324–2916) or add `shopId` to them, (b) backfill `shopId` on old root docs with an admin script, (c) change root rules to `isShopMember(resource.data.shopId)`. Test with `tools/firestore_rules_test` first. |
| HIGH | Restrict who can write `app_config/version` | Today: any signed-in user (links are now allow-listed in the app). Plan: an `app_config/admins` doc set once in the Firebase console with the owner's uid; the rule allows write only to those uids. |
| HIGH | Firebase Auth public sign-up / App Check | Anyone can create a Firebase account with the public API key. Consider Firebase App Check and turning off open email sign-up (owners register through a controlled flow). |
| MEDIUM | Staff devices can still write `staff`, `message_templates`, `crm_settings`, `campaigns` through the catch-all | They are synced from staff devices today. Make the sync engine push these only from owner devices, then add them to the catch-all exclusion. |
| MEDIUM | Local data on this PC (Hive) is not encrypted | Needs a one-time migration that re-encrypts every box with a key kept in the Windows secure store. |
| MEDIUM | App auto-lock (PIN after idle time) for the owner screens | Not present today. |
| MEDIUM | Purchase Return with item selection (reduces stock) | Today a return is amount-only. |
| LOW | Daily Register "other cash" lines use the cash log, which keeps the last 500 entries | Fine while every day is closed; an old unclosed day could miss lines. |
| LOW | Recharge "Corrected" shows only on this PC, not on the mobile app | Wallet balances are server-side, so they are right everywhere. |
| INFO | Trusted-device signing is OFF (owner decision 2026-11-18) | Secret `TRUSTED_DEVICE_ENFORCEMENT=on` turns it back on. |
| INFO | Airtel ₹1,360 stays labelled "own money" (owner decision) | Do not reclassify with ⇄; Apex is already paid in full. |

---

## 5. Agent-നുള്ള handover (when this session ends)

Rules (keep these):
- Reply to the owner in Malayalam, technical terms in English; UI strings "English (മലയാളം)"; money in integer paise.
- Ask the owner before: any money save in the real app, any Production deploy (Supabase or Firebase), any commit/push.
- Never type passwords/tokens; the owner logs in. Never print tokens; `GITHUB_TOKEN` holds the GitHub token.
- One app copy only. Start: `Start-Process "D:\tekfix_pos\build\windows\x64\runner\Release\tekfix_pos.exe" -WorkingDirectory "D:\tekfix_pos\build\windows\x64\runner\Release"`. Close it (CloseMainWindow) before `flutter build windows --release`.
- Supabase: Staging `mwhsvidbrfkryuiwhnev` first, then Production `bxjlqcqcjfifzjrqpcov`; always `--remote`; back up the production edge function (`supabase functions download`) before deploying; never edit an applied migration.
- Firebase rules deploy (after `tools/firestore_rules_test` passes): `npx firebase-tools deploy --only firestore:rules --project tekfix-45b38` (owner approval first).

Checks before finishing any task:
- `flutter analyze lib` → 0 errors; `flutter test` → all pass (951 today).
- Rules changed? `cd tools/firestore_rules_test && npm install && npm test` → 25 passed.

Notes from earlier sessions: `C:\Users\acer\AppData\Local\Claude-Data\claude_pzs8sxrjxfjjc\side-session-notes\local_6b89d64f-f00e-4643-a5a7-033a44efbfad\recharge_v2_1_legacy_server_path.md`.
