# Customer CRM layer — summary, rules, test checklist

Phone-number-driven CRM for TekFix ERP & POS (Phases 0–6). Code lives in `lib/crm/`.

## What is where

| Area | Files |
|---|---|
| Phone normalisation, paise | `lib/crm/phone_utils.dart` |
| Customer model, CRM core + indexes | `lib/crm/customer_models.dart`, `lib/crm/customer_crm.dart` |
| Migration (dry run / apply) | `lib/crm/customer_migration.dart`, tools screen in `lib/crm/crm_app.dart` |
| POS auto-fill card | `lib/crm/pos_customer_panel.dart` (SaleView + StaffPosScreen) |
| History screen | `lib/crm/customer_history.dart`, `lib/crm/customer_history_screen.dart` |
| Search | `lib/crm/customer_search.dart` (Parties list + global search) |
| Segments, templates, WhatsApp, log, automations | `lib/crm/crm_messaging.dart`, `lib/crm/crm_messaging_screen.dart` |
| Roles | `lib/crm/crm_permissions.dart`, `crmCan()` in `lib/crm/crm_app.dart`, `AuthController.isAdmin` |
| Sync | `lib/sync/sync_engine.dart` (4 soft collections) |
| Firestore rules | `firebase/firestore.rules` section 17b |

Storage: customers are parties (`tek_parties` → `parties`). Sales carry `customerId`,
`customerPhone`, `customerName`. Totals/bill counts are derived locally from sales
(`customer_stats`, never synced). Local rebuildable indexes: `customer_phone_index`,
`customer_sales_index`, `customer_stats`, `customer_crm_refs`. Synced CRM boxes:
`tek_crm_templates`→`message_templates`, `tek_crm_settings`→`crm_settings`,
`tek_crm_campaigns`→`campaigns`, `tek_message_log`→`message_log`.

## Roles

| Action | Staff / Biller | Owner / Admin |
|---|---|---|
| Look up customer (POS, search), view history | yes | yes |
| Bill, one WhatsApp / call from history, edit customer | yes | yes |
| Export, campaigns (bulk send), segments, templates, automations | no | yes |
| Migration, rebuild indexes | no | yes |

Admin = `shops/{shop}/users/{uid}.role == 'admin'` (stored as `auth_is_admin`).
Navigation entries for Offers / CRM Tools are still owner-only (the app shell gates on
`isOwner`); the screens themselves accept admin.

## Firestore rules diff (`firebase/firestore.rules`, added before section 18)

```diff
+      // 17b. CUSTOMER CRM (customers live in /parties above)
+      match /message_templates/{id} {
+        allow read: if isShopMember(shop);
+        allow create, update, delete: if isOwner(shop);
+      }
+      match /crm_settings/{id} {
+        allow read: if isShopMember(shop);
+        allow create, update, delete: if isOwner(shop);
+      }
+      match /campaigns/{id} {
+        allow read, create, update, delete: if isOwner(shop);
+      }
+      match /message_log/{id} {
+        allow read: if isOwner(shop);
+        allow create: if isShopMember(shop) &&
+          request.resource.data.customerId is string &&
+          request.resource.data.status in ['sent', 'skipped', 'failed'];
+        allow update, delete: if isOwner(shop);
+      }
```

No existing rule changed. `isOwner()` already includes role `admin`. Every CRM path
requires sign-in + shop membership. Validated with
`firebase deploy --only firestore:rules --dry-run` (compiles). Deploy:
`firebase deploy --only firestore:rules`.

Existing exposure to review separately (not changed): the root fallback
`match /parties/{id} { allow read, write: if isSignedIn(); }` lets ANY signed-in user of
any shop read root-level `/parties` (the app uses `shops/{shop}/parties`, so it is probably
unused). Removing it would close a cross-shop phone-number leak.

## Automated tests

`test/crm_customer_test.dart`, `crm_pos_panel_test.dart`, `crm_history_test.dart`,
`crm_search_test.dart`, `crm_messaging_test.dart`, `crm_permissions_test.dart`:
phone normalisation, duplicate prevention, index updates (save/edit/return/delete/sync
arrival/offline duplicates), migration idempotency, history grouping/filters, search,
segment filters, opt-in/opt-out, templates, senders, queue/dedupe/daily cap, report,
automations, role matrix.

```
flutter test --no-pub test/crm_customer_test.dart test/crm_pos_panel_test.dart test/crm_history_test.dart test/crm_search_test.dart test/crm_messaging_test.dart test/crm_permissions_test.dart
```

## Manual test checklist

Before: back up `C:\Users\acer\Documents\tek_*.hive`. Run
`flutter run -d windows --no-pub`.

- [ ] **Migration**: More → Customer CRM Tools → Dry run (counts only) → Backup & Apply →
      Dry run again shows "nothing to do". Backup folder is printed.
- [ ] **Add customer at billing**: Sale/POS → type a new 10-digit number (`+91 …` or
      `0…` too) → name field says "New customer" → save bill → customer appears in Parties.
- [ ] **Lookup**: type the same number again → card shows name (locked; Edit unlocks),
      total spent, last visit, pending balance, last 3 purchases.
- [ ] **Walk-in**: bill with no number → works as before.
- [ ] **Duplicate number**: Parties → add a customer with an existing number (any format)
      → blocked, offer to open the existing customer.
- [ ] **Second device after sync**: on another device (owner), after sync, typing the
      number shows the same customer and bills.
- [ ] **Offline billing then sync**: disconnect, bill a new number, reconnect → customer and
      bill reach the other device; totals there are recomputed (not copied).
- [ ] **History search**: Parties → tap customer → search an item name; set a date range;
      tap a bill → Print / WhatsApp bill; Service / Warranty tab shows jobs and warranties.
- [ ] **Search**: Parties and Ctrl+K: last 4 digits, full number, Malayalam name.
- [ ] **Segment preview count**: Customer Offers → tick filters → count/preview match
      expectations; customers with opt-in off are not listed.
- [ ] **Opt-out respected**: in a campaign queue tap "Opt out (STOP)" → customer marked
      Do-not-message and never appears in later segments/automations.
- [ ] **Delay & daily cap**: after a send the button counts down; at the cap sending stops.
- [ ] **Campaign report**: sent/skipped counts; a bill within 7 days shows in "Bought in 7 days".
- [ ] **Automations**: all off by default; switch one on → "Due today" lists it once.
- [ ] **Staff login**: staff POS shows the customer card and history; Offers / CRM Tools
      screens say "Owner / Admin only".
- [ ] **After rules deploy**: message log / templates / campaigns appear in Firestore under
      `shops/{shop}/…`; sync icon stays green.
