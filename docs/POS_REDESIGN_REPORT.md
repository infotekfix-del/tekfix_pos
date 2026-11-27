# TEKFIX ERP & POS — New POS (Sale / Billing) Redesign — Final Report

Version 2 spec, steps 3a–3h. Date: 19 Nov 2026. Branch: `phase-16-4-execution-20261117`.
**Status: built and tested in automated tests; NOT yet verified by hand in the real app.**
The new POS is behind the setting **"Use new POS (പുതിയ POS)"**, which is **OFF by default**.
The old POS is unchanged and still the default. Nothing is committed.

> **ചുരുക്കം (Malayalam summary):** പുതിയ POS പൂർണ്ണമായി ഉണ്ടാക്കി (3a–3h). ബില്ലിംഗ് ലോജിക്
> ഒന്നും മാറ്റിയിട്ടില്ല — പഴയ `_checkout()` തന്നെയാണ് ബിൽ സേവ് ചെയ്യുന്നത്. 65 പുതിയ ടെസ്റ്റുകളും
> 111 പഴയ ടെസ്റ്റുകളും പാസായി. പക്ഷേ യഥാർത്ഥ ആപ്പിൽ കൈകൊണ്ട് പരീക്ഷിച്ചിട്ടില്ല, രണ്ടാം
> മോണിറ്റർ ഇവിടെ ഇല്ലാത്തതിനാൽ അതും പരീക്ഷിച്ചിട്ടില്ല. അതുകൊണ്ട് സ്വിച്ച് ഇപ്പോഴും OFF ആണ്.

---

## 1. Summary of UI changes

| Area | What the cashier gets |
|---|---|
| Theme | Light Material 3 theme from one token file (`pos_theme.dart`): indigo / teal / violet, green-amber-red status colours, 12 px radius, tabular money digits, visible focus ring, WCAG AA contrast. Status is always icon + words, never colour alone. |
| Layout | ≥1100 px: search area + fixed 420 px bill panel. 800–1099 px: 340 px panel. <800 px (phone): one column + bottom "Cart (n) – ₹total" bar. GRAND TOTAL and COMPLETE PAYMENT are pinned and visible at 1366×768 (tested). |
| Discovery | Search always focused (name / barcode / code / SKU / IMEI / serial, 200 ms debounce, ↑↓ Enter; exact scan adds at once). Landing view = Top Selling (last 30 days, by qty) + Favorites (☆) + 9 category chips; **no inventory grid**. View All (F4): lazy list, search, category, in-stock filter, sort. |
| Cards | Name (2 lines + tooltip), big price, stock as words (In stock / Low / Out), category icon, "IMEI tracked"/brand, "In bill n", flash on add. Purchase price only for owner/admin while holding **Alt**. |
| Customer | One box for phone or name (F3): phone-first auto-select, top-8 suggestions with **masked phone** (98\*\*\*\*\*\*21) and due tag, recent-customer chips, walk-in default, "New customer" (name + mobile, duplicate number → "Customer already exists – select?"). Selected card: old due big red / "No due" green, purchase history (3 inline + side panel with every bill: date, invoice, items, amount, paid, due, status). |
| Cart | Typed qty (1..stock), − / +, price edit (existing dialog), remove with 5 s **Undo**, IMEI lines fixed at 1 and never added twice, discount shown as ₹ and %, clear asks first. |
| Payment | CASH / UPI-CARD / CREDIT / SPLIT buttons. Cash: "Received" + Exact/₹500/₹1000/₹2000 + change; less than bill is refused. UPI: dynamic QR + cashier must press **"UPI Received (ലഭിച്ചു)"** (card: confirm on complete). Credit: needs a customer; shows total due after the bill. Split: the existing Cash + UPI/Card fields. F12 / Ctrl+Enter, button disables with a loader. Success dialog: invoice no., payment, change, A4 / Thermal / WhatsApp / New bill. |
| Privacy | Customer View (F11): full-screen customer page, Esc + staff PIN to leave. Second monitor: customer window opens automatically. Both get **only** `CustomerDisplayState`. |
| Productivity | F6 hold, F7 held bills (resume / owner discard), Ctrl+R recent bills (reprint / WhatsApp), Ctrl+P reprint last (thermal), F8 discount, F9 payment, F1 help overlay. |

## 2. Modified / new files

**New (lib/pos/new_pos/, 18 files, ~5,600 lines)**

| File | Kind | Purpose |
|---|---|---|
| `pos_theme.dart` | library | design tokens + `posTheme()` |
| `pos_discovery.dart` | pure | category chip mapping, Top Selling, Favorites helpers |
| `pos_customer_logic.dart` | pure | phone masking, recent customers |
| `pos_cart_logic.dart` | pure | qty check, discount %, IMEI mask / duplicate check |
| `pos_payment_logic.dart` | pure | payment modes → existing cash/upi amounts, change, UPI link, UPI ID check |
| `pos_hold_logic.dart` | pure | held-bill draft, total, age, resume re-check |
| `pos_pin.dart` | pure | Customer View PIN (SHA-256, salted) |
| `customer_display.dart` | library | `CustomerDisplayState` + read-only `CustomerDisplayView` (no main.dart / Hive / Firestore import) |
| `customer_display_window.dart` | library | second-monitor window entry + `CustomerDisplayHost` |
| `pos_display_monitors.dart` | library | monitor list + window placement (win32) |
| `pos_kiosk_window.dart` | library | full screen + always-on-top for Customer View (win32) |
| `new_pos_shell.dart` | `part of main.dart` | screen shell, search, bill panel, checkout flow |
| `new_pos_catalog.dart` | part | chips, Top Selling, Favorites, cards, View All |
| `new_pos_customer.dart` | part | customer section + history panel |
| `new_pos_cart.dart` | part | bill lines |
| `new_pos_payment.dart` | part | payment area, UPI QR, bill-saved dialog, UPI ID setting |
| `new_pos_privacy.dart` | part | Customer View page, PIN dialogs, display state builder, owner settings |
| `new_pos_extras.dart` | part | hold/resume, recent bills, reprint, help |

The screen files are `part of main.dart` **on purpose**: they drive the same private `_SaleViewState` (same cart list, same customer controller, same `_addToCart`, `_editPrice`, `_pickSaleDate`, `_checkout`), so no billing code was copied or moved.

**Modified**

| File | Change |
|---|---|
| `lib/main.dart` | imports + `part` lines; `SaleView.build` returns the new shell when the setting is on; "Use new POS" button in the old POS app bar (owner/admin); at the start of `main()` the customer-display window branches off before Firebase/Hive. No billing / sync / stock code touched. |
| `lib/pos/pos_service.dart` | default shop UPI ID → `Q085585286@ybl` (staff phone POS QR), as requested. (The same file also holds the earlier, separate WhatsApp-invoice change, not part of this redesign.) |
| `pubspec.yaml`, `pubspec.lock` | + `desktop_multi_window` |
| `windows/flutter/generated_plugin_registrant.cc`, `generated_plugins.cmake` | generated by `flutter pub add` |

**New tests**: `test/new_pos_{shell,baseline,catalog,customer,customer_create,cart,payment,privacy,hold}_test.dart`, `test/pos_discovery_test.dart`, helper `test/new_pos_test_utils.dart`. New doc: this file.

## 3. New packages

| Package | Version | Reason | Platforms |
|---|---|---|---|
| `desktop_multi_window` | ^0.3.1 (resolved 0.3.1) | Second window for the customer display in the **same process** (own small engine). Flutter 3.47.7's own multi-window API is still marked experimental in the SDK, so it was not used. | Windows, macOS, Linux. **Not Android** — conflicts with the spec's "Windows and Android" rule; the code only runs on Windows and a second monitor does not apply to phones. |

No `window_manager` / `screen_retriever`: full screen, always-on-top and monitor detection use the existing `win32` package. `qr_flutter` and `crypto` were already dependencies.

## 4. New local keys (settings box `tek_settings`, not synced)

| Key | Content | Who sets it |
|---|---|---|
| `pos_new_ui` | `'true'` / `'false'` — use the new POS | owner / admin |
| `pos_favorites` | list of item `_id`s | cashier (☆) |
| `pos_held_bills` | up to 10 cart drafts (item id/key, name, qty, price, IMEI, customer phone/name/party id, discount, held time, by) — no cost | cashier (F6) |
| `pos_view_pin_hash` | SHA-256 of the Customer View PIN (never the PIN) | owner / admin |
| `pos_welcome_message` | customer-screen welcome text | owner / admin |
| `pos_customer_display` | `auto` / `second` / `off` | owner / admin |
| `shop_upi` *(existing key, now editable)* | shop UPI ID for the QR; default `Q085585286@ybl` | owner / admin |

No new Hive boxes, no new item/party/sale fields, no new Firestore collections. Settings are per PC.

## 5. Customer Privacy Mode

- **Layer A (always):** no inventory grid on landing; stock as words; no purchase price (owner + Alt only); search results close after each add; masked phone in suggestions; no ERP toasts with business data added; back to landing after each bill.
- **Layer C — Customer View (single monitor):** F11 / button. Clears search, switches this app's window to **full screen + always on top**, shows the customer page. Every key is swallowed except **Esc → staff PIN** (4–6 digits, hashed; owner sets it; staff are told to ask the owner when none is set). Correct PIN returns to the exact same bill. The existing `admin_pass` (owner admin password, plain text) was deliberately **not** reused.
- **Data minimisation:** the customer page and the second window receive only `CustomerDisplayState` (shop, customer name, old due, lines {name, qty, unit price, line total, masked IMEI}, subtotal, discount, total, total due after bill, payment status, optional UPI QR, message). Tests assert no cost, stock, keys, item ids, full IMEI or warranty ever appear, including in the JSON sent to the second window.
- **Known limitations:** Windows still allows **Alt+Tab, the Windows key and Ctrl+Alt+Del**; an app cannot block them. Full screen / on top is best effort. **The real fix is a cheap second monitor facing the customer, or a physical privacy filter.** The full-screen switch itself has not been seen on screen (tests cannot run it).

## 6. Multi-monitor status — **implemented, not verified on hardware**

- Opens automatically (mode Auto / Second monitor) on a monitor other than the POS window's, full screen, no frame, no taskbar button, **without taking the cashier's focus**. Updates ≈100–200 ms after any change (debounced 100 ms).
- Unplug → hidden within ~1.5 s, billing unaffected; re-plug → shown again. Mode "Second monitor" shows a TV-off icon when none is found.
- The window runs no Hive / Firebase / login (branch at the start of `main()`).
- Verified: build with the plugin, normal app start-up, the state JSON. **Not verified: the window on a real second monitor, unplug/re-plug** — this PC has one monitor. Developer check on one monitor: start the app with `TEKFIX_DISPLAY_TEST=1` and open the new POS (window appears as a 640×480 box on the right).

## 7. Business-logic preservation

The new screen calls the **existing** `_checkout()` once per bill. It only fills the existing `cash` and `upi` amounts from the chosen payment mode; "received" and "change" are not stored. Invoice numbering, stock deduction, stock moves, paper-sheet deduction, money moves, party balance, CRM indexing, audit log and sync are untouched. Card is still recorded together with UPI (as before). GST is stored as before (rate only); no round-off (none existed).

**Old screen vs new screen — same bill (automated, temporary Hive):** 2 × "weva screen gurd" (₹150, cost ₹40, stock 10), discount ₹20, Cash ₹200 + UPI ₹80.

| Field | Old POS | New POS |
|---|---|---|
| subtotal | 300.0 | 300.0 |
| discount | 20.0 | 20.0 |
| total | 280.0 | 280.0 |
| cash / upi / due | 200.0 / 80.0 / 0.0 | 200.0 / 80.0 / 0.0 |
| profit | 200.0 | 200.0 |
| gstRate | 0.0 | 0.0 |
| lines (itemId, name, price, cost, qty) | identical | identical |
| stock after | 10 → 8 | 8 → 6 |
| invoice | different numbers (no duplicate) | |

**Other bills checked on the new screen against the stored values** (not compared with the old screen):

| Bill | Stored |
|---|---|
| Cash ₹500 for ₹150 | cash 150, upi 0, due 0 (change ₹350 shown only) |
| UPI via QR + "UPI Received" | cash 0, upi 150, due 0 |
| Split 100 + 50 | cash 100, upi 50, due 0 |
| Credit to customer with old due ₹450 | due 150, customer balance 600 |
| Double-tap on Complete | exactly 1 sale |
| Hold → resume | no sale, stock unchanged while held |

**Not done:** the spec's 5-bill baseline with an **IMEI phone** and **credit** compared old-vs-new, on a test shop / backup copy in the real app.

## 8. flutter analyze

- New files + new tests + `pos_service.dart`: **0 errors, 0 warnings**; 2 infos, both pre-existing in `pos_service.dart` (lines 322, 355, `curly_braces_in_flow_control_structures`).
- `lib/main.dart`: **0 errors**; 2 warnings, both pre-existing (`iconOnly` unused parameter, lines 1399 and 1442); 10 issues in total, all pre-existing.

## 9. Test results (only tests actually run)

| Suite | Tests | Result |
|---|---|---|
| `new_pos_shell_test` | 6 | pass |
| `new_pos_baseline_test` (old vs new) | 1 | pass |
| `pos_discovery_test` | 12 | pass |
| `new_pos_catalog_test` | 6 | pass |
| `new_pos_customer_test` | 6 | pass |
| `new_pos_customer_create_test` | 1 | pass |
| `new_pos_cart_test` | 7 | pass |
| `new_pos_payment_test` | 7 | pass |
| `new_pos_privacy_test` | 13 | pass |
| `new_pos_hold_test` | 6 | pass |
| **New POS total** | **65** | **all pass** |
| Older suites re-run (WhatsApp invoice, CRM ×6, job intake, barcode labels, backdated sales, EOD report) | 111 | all pass |

Covered: cart qty rules, duplicate-IMEI block, `CustomerDisplayState` has no stock / purchase price, double-click creates one sale, layouts at 1366×768, 1000 px and 390 px without overflow.
Known older failures not touched: `staging_password_auth_test` (4 failures that existed before this work).
Tests run on a temporary Hive with the sync engine not started — no shop data, no Firestore.

**Bugs the tests found and fixed during the work:** IMEI line 72 px too wide; cash quick buttons 40 px too wide at 1000 px; category chips unreachable with a mouse (horizontal scroller); UPI status row overflow; PIN dialog freed its text controller while closing (crash).

**Manual checklist (spec §18, 31 items): not executed.** Only app start-up was checked after each step (log: no new errors).

## 10. Unresolved issues and risks

1. **No hands-on verification** of the new screen in the real app; the switch stays OFF until the owner tries it.
2. **Second monitor and real full screen** not seen on hardware (one-monitor PC).
3. **5-bill baseline** (IMEI phone, credit old-vs-new) and the 31-item manual checklist still to do — on a backup copy, never on live data.
4. **Card = UPI**: the existing logic has no separate card amount; adding one would be an accounting change needing approval.
5. **No IMEI picker** existed to reuse; IMEI items are single records (one unit each).
6. **New customer flow**: the old screen created a customer automatically when a new number was typed and the bill completed; the new screen asks for "New customer" first (deliberate step). Can be switched back if preferred.
7. **Alt+Tab / Windows key** cannot be blocked (see §5).
8. **`desktop_multi_window` has no Android support** (spec asks for Windows + Android packages).
9. **Staff phone POS** (`staff_pos_screen.dart`) still writes sales straight to Firestore (existing behaviour, out of scope, not changed).
10. **Old POS** has its own layout errors (product cards overflow, ListTile ink warnings) — not fixed, the old screen was left as is.
11. **Hive writes inside widget tests** can stay pending into the next test (test-only effect); tests that save are grouped or kept in their own files.
12. Settings are per PC: favorites, held bills, PIN, UPI ID and display mode must be set on each billing PC.

## 11. Screenshots

**Not captured.** The real app's screens can only be opened by hand here, and test renders use placeholder fonts that would not show Malayalam or the real look. To see each view: Sale / POS → **Use new POS (പുതിയ POS)** (cashier view), **F11** (customer view / privacy mode), a second monitor or `TEKFIX_DISPLAY_TEST=1` (second-monitor view), a phone-width window (phone view).

---

### Backups made during the work
- Code + data before the redesign: `D:\tekfix_backups\pos_redesign_start_20261119_1015`
- Data before each relaunch: `D:\tekfix_backups\pre_relaunch9_…` through `pre_relaunch17_20261119_1303`

### To finish (recommended order)
1. Owner opens the new POS, sets the Customer View PIN and UPI ID, tries F11.
2. Run the 5-bill baseline + manual checklist on a **backup copy** (not live data).
3. Try a second monitor (or `TEKFIX_DISPLAY_TEST=1`).
4. Then switch the default to the new POS and commit (own hunks only).
