# Vendor bill import (PDF / photo → purchase bill)

Branch: `phase-16-4-execution-20261117` · Date: 2026-11-20 · Not committed.

## 1. Audit of what already existed

| File | What it did | Problems found |
|---|---|---|
| `invoice_parser_service.dart` | Hand-written PDF "stream" scanner + regex parser | Only read plain `(text) Tj` strings. **No ToUnicode / CID font support** → modern bills from Tally, Zoho, Busy, browsers come out empty or as garbage. No text positions, so table columns and rows were lost. Money as `double`. When nothing was read it **invented an invoice number `INV-<file name>` and today's date** (fake data). The "OCR" was a fake: it only scanned image bytes for ASCII. |
| `purchase_bill_upload_screen.dart` (5,965 lines) | Older upload screen, reached from the dashboard "Upload / Capture Bill" | Used the parser above. Put the **HSN code into SKU/barcode** → a new item gets barcode `8517…`, which many items share. Vendor match was a loose substring match. Money as `double`. |
| `manual_purchase_entry_screen.dart` | The real, working purchase entry (calc engine in paise, IMEI, payments, duplicate check) | Its "Auto-Extract Bill (OCR)" button used the same broken parser; defaulted GST to 18% when unknown. |
| `purchase_bill_service.dart` `matchProductInFirestore` | Product matching | **Exact match only** (barcode / SKU / exact normalized name). No fuzzy matching, so vendor spellings never matched. |
| `quick_register_drawer.dart` | New-product sheet | Worked; no unit / IMEI / category pre-fill. Reused. |
| `smart_inventory_combobox.dart` | Typing search for manual entry | Fine, not involved. |
| `test/phase6_invoice_ingestion_extraction_test.dart` | 5 tests | Only tested the regexes on hand-typed perfect text, never a real PDF. Still passes. |

Extraction method before: on-device regex text parsing, no OCR, no AI.

## 2. What was built (all offline, no paid service, no API key)

New folder `lib/purchases/bill_import/`:

- `pdf_text_extractor.dart`: pure-Dart PDF reader. Handles object streams (PDF 1.5+), Flate/ASCIIHex/ASCII85, page tree, Form XObjects, WinAnsi + /Differences, **Type0/CID fonts with ToUnicode**, and text/graphics matrices. Gives every text run with its position.
- `bill_ocr_service.dart`: photos and scanned PDFs on **Windows** use the built-in Windows OCR (offline, free) through PowerShell. Scanned PDFs are rasterised with the existing `printing` package. On Android, image OCR says "not available" (see options below). PDFs work on both platforms.
- `bill_text_layout.dart`: groups runs into lines and columns.
- `vendor_bill_parser.dart`: vendor, GSTIN (skips our own GSTIN), phone, bill no. (same cell, next cell or the cell below), date (day-first, `12-Nov-26`, …; skips Due date), item table by header columns, and merging of wrapped/vertically-centred rows. Every row is **cross-checked arithmetically** (qty × rate − disc ≈ taxable; × (1 + GST) ≈ amount). Also reads IMEIs under item names, CGST/SGST/IGST, round off, freight (as other charges), and the grand total. Detects GST-inclusive rates and converts them to before-GST rates. **All money is in integer paise.**
- `bill_item_matcher.dart`: fuzzy matching: abbreviations (SAM GAL → Samsung Galaxy, BLK → Black), typos, barcode/SKU printed on the bill, and a **variant guard** (A15 ≠ A25, 128 ≠ 256 are never auto-linked). Remembers each confirmed "vendor wording → item" (Hive settings key `bill_import_item_aliases_v1`), so the next bill from that vendor links instantly.
- `bill_import_service.dart`: runs the whole chain and matches the vendor (GSTIN → phone → name).
- `bill_import_screen.dart`: Upload → Review → Continue.

Hooks (minimal):
- `purchase_bills_dashboard_view.dart`: "Upload Vendor Bill (ബിൽ അപ്‌ലോഡ്)" now opens the new flow. The old upload screen is left in the code but is no longer opened from here.
- `manual_purchase_entry_screen.dart`: new `importedBill` parameter. The "Auto-Extract Bill" button opens the new flow. Saving is unchanged: it uses the **same `confirmPurchaseBill`** as a manual bill, with `entrySource: bill_upload`. An import opened from the dashboard never overwrites or deletes a parked manual draft.
- `quick_register_drawer.dart`: optional pre-fill of unit, category and IMEI tracking.

### Options for even better reading (not wired in; owner's choice)

| Option | Cost | Notes |
|---|---|---|
| Current built-in (PDF text + Windows OCR) | Free, offline | Good for digital PDFs from billing software; fair for clear photos on Windows. |
| Android photo OCR with `google_mlkit_text_recognition` | Free, offline | Adds a plugin (~4 MB). Needs owner OK to add a dependency. |
| Cloud AI (e.g. Claude / Gemini vision) for messy photos | Paid per bill, roughly ₹0.5–₹3 per page; needs internet + API key | Best for crumpled or handwritten bills. The bill image would be sent to the provider. Not added. |

## 3. Tests

- `test/vendor_bill_import_test.dart` (22): paise parsing, real PDFs (standard font, embedded TrueType/CID, browser-generated fixture), GST-inclusive bills, discount vs GST %, 4-digit qty vs HSN, Tally-box bill no., freight, OCR clean-up, fuzzy matching, aliases, vendor matching, hand-off maths.
- `test/vendor_bill_import_save_test.dart` (5): parse → match against Hive → `confirmPurchaseBill` → stock +5 on the linked item, new item created (barcode ≠ HSN), vendor balance = total − paid. Also review-screen render at 1400 px and 390 px (phone), and Purchase Entry pre-fill.
- The existing purchase suites (phase6, manual entry flow/widget/custom item, purchase bills module, edit bill, direct item addition, phase2, calc engine, phase4 ledger, payment status) still pass.
- `flutter analyze --no-pub lib`: 0 errors.

## 4. Owner test checklist (ഉടമയ്ക്കുള്ള ടെസ്റ്റ് ലിസ്റ്റ്)

Take a Hive backup first (copy `C:\Users\acer\Documents` Hive files). Use one real vendor PDF.

1. Purchases → **Upload Vendor Bill (ബിൽ അപ്‌ലോഡ്)** → choose the vendor's PDF.
2. Check that vendor name, GSTIN, bill no. and date are correct. If the vendor is new, tap **Add as new vendor (പുതിയ വെണ്ടർ)**.
3. Check that every line has the right name, qty, rate and GST %. Each line is coloured: green = linked, orange = "Is it…?" (tap **Yes (അതെ)** or pick another item), red = NEW.
4. On a NEW line, tap **Add as new item (പുതിയ ഐറ്റം ചേർക്കുക)**. Name, HSN, GST, unit and MRP are filled in; enter the selling price and save.
5. The bottom card should say **Matches the bill ✓ (ബില്ലുമായി ഒത്തുപോകുന്നു)**. If not, fix the line it warns about.
6. Tap **Continue (തുടരുക)**. The usual Purchase Entry opens with everything filled in. Enter IMEIs for phones, set the payment and Save.
7. Check: item stock went up, the new item is in Stock, the vendor ledger shows the balance, and the bill shows the attached PDF.
8. Upload another bill from the same vendor. Items you linked last time should now be green automatically.
9. Windows only: try a clear photo/screenshot of a bill (JPG/PNG).
10. Android: PDF upload should work; a photo shows a "Windows only" message.
