# TekFix ERP & POS — Project Summary

Comprehensive architecture, codebase map, data models, and feature status for the TekFix ERP & POS system.

---

## 1. App Overview

- **Purpose:** An offline-first enterprise retail ERP, Point-of-Sale (POS), service/repair tracking, and telecom recharge accounting system designed for mobile retail and electronics repair businesses in Kerala, India. Features bilingual English/Malayalam UI labels (`English (മലയാളം)`).
- **Target Platforms:**
  - **Windows Desktop:** 64-bit production executable built via Flutter Windows C++ runner, utilizing native Win32 APIs for raw thermal receipt and TSPL barcode label printing.
  - **Mobile / Tablet (Android):** Responsive Material 3 layout for handheld operation by store staff and mobile management by owners.
- **Tech Stack & Libraries:**
  - **Core Framework:** Flutter 3.x / Dart 3.x (State management via `Provider`).
  - **Local Storage (Offline-First):** Hive (`hive_flutter: ^1.1.0`) with 20 distinct data boxes.
  - **Cloud Backend & Sync:**
    - Google Cloud Firestore (`cloud_firestore: ^7.1.0`) via an offline-first transactional queue (`tek_sync_queue`) with atomic increment/decrement sync logic and UUID (`_id`) resolution.
    - Firebase Auth (`firebase_auth: ^7.0.1`) and Firebase Storage (`firebase_storage: ^14.0.1`).
    - Supabase Edge Functions (`http: ^1.6.0`) for zero-cost hardware-signed Recharge Accounting backend bridging (`recharge-bridge`).
  - **Hardware & Printing:**
    - `win32: ^5.15.0` & `ffi: ^2.1.3` for direct Windows raw printer spooling (`windows_raw_printer.dart`).
    - `pdf: ^3.10.8` & `printing: ^5.12.0` for 80mm/58mm thermal receipts, A4 invoices, and PDF reports.
  - **Security & Cryptography:**
    - `crypto: ^3.0.3` for cryptographic hashing and ECDSA P-256 signatures via `DeviceSecurityService`.
    - Windows DPAPI secure credential storage and Android Keystore integration.
  - **Charts & UI:**
    - `fl_chart: ^1.3.0` for analytics and sales trend charts.
    - `google_fonts: ^8.2.1` with `Noto Sans Malayalam` fallback to prevent vowel sign / chandrakala clipping.
    - `qr_flutter: ^4.1.0` for UPI payment QR codes.
  - **Device & Location:**
    - `geolocator: ^14.0.1` for staff attendance geofencing.
    - `package_info_plus: ^8.1.0`, `file_picker: ^10.2.4`, `url_launcher: ^6.2.5`.

---

## 2. Folder & File Structure

```text
d:\tekfix_pos\
├── pubspec.yaml                     # Dependencies, environment constraints, and asset configuration
├── lib/
│   ├── main.dart                    # App entry point, Hive setup, Db layer, AppShell, and core views
│   ├── firebase_options.dart        # Firebase configuration for Windows and Android platforms
│   ├── firestore.rules              # Cloud Firestore security rules with tenant isolation
│   ├── storage.rules                # Firebase Storage security rules for bills and receipts
│   │
│   ├── attendance/                  # Staff attendance, geofencing, and approvals
│   │   ├── attendance_models.dart   # AttendanceRecord, shift, and geo-coordinate models
│   │   ├── attendance_service.dart  # Check-in/out logic, geofencing checks, and Firestore sync
│   │   ├── owner_attendance_approvals_view.dart # Owner UI to approve or reject attendance requests
│   │   ├── owner_attendance_dashboard.dart      # Real-time overview of staff on duty and hours worked
│   │   └── staff_attendance_screen.dart         # Staff interface for clocking in/out with selfie/location
│   │
│   ├── audit/                       # System diagnostics and hardware audits
│   │   └── hardware_audit_screen.dart # Screen auditing thermal printers, display scaling, and storage
│   │
│   ├── auth/                        # User authentication and authorization
│   │   ├── auth_controller.dart     # Authentication state controller (Owner vs Staff roles)
│   │   ├── login_gate.dart          # Entry gate switching between LoginScreen and AppShell
│   │   └── new_account_alert_service.dart # Security alerts when new accounts access the shop
│   │
│   ├── barcode/                     # Barcode and thermal label generation
│   │   ├── barcode_label_models.dart  # Barcode label layout and dimension definitions
│   │   ├── barcode_label_service.dart # Label generation and formatting service
│   │   ├── barcode_print_dialog.dart  # Dialog for previewing and printing item barcodes
│   │   ├── tspl_generator.dart        # TSPL printer control language command generator
│   │   └── windows_raw_printer.dart   # Direct Win32 API spooler for thermal label printers
│   │
│   ├── core/                        # Core device and hardware information
│   │   └── device.dart              # Device identification and platform fingerprinting
│   │
│   ├── expenses/                    # Store expense management and categorization
│   │   ├── add_expense_dialog.dart  # Form dialog for recording immediate or recurring expenses
│   │   ├── expense_cleanup_dialog.dart # Dialog to audit, prune, or recategorize expense items
│   │   ├── expense_cleanup_service.dart# Cleanup and deduplication utility for expense records
│   │   ├── expense_management_screen.dart # Main screen for viewing expenses, filters, and totals
│   │   ├── expense_models.dart      # ExpenseRecord and category aggregation models
│   │   └── expense_service.dart     # Service handling expense CRUD, ledger deductions, and sync
│   │
│   ├── inventory/                   # Internal consumables and shop equipment tracking
│   │   └── consumables_service.dart # Service for tracking non-sale internal consumables (tape, flux, solder)
│   │
│   ├── migration/                   # One-time database schema and feature migrations
│   │   └── feature_upgrade_migration.dart # Automatic pre-migration backup and backfill for sale dates
│   │
│   ├── notifications/               # In-app alerts, low-stock warnings, and order updates
│   │   ├── notification_drawer.dart # Slide-out drawer displaying unread system notifications
│   │   ├── notification_models.dart # AppNotification schema and urgency levels
│   │   ├── notification_service.dart# Service for triggering and persisting system notifications
│   │   ├── staff_notifications_screen.dart # Staff-facing notification listing
│   │   └── tek_notification_panel.dart     # Top-level dropdown notification badge and panel
│   │
│   ├── orders/                      # Internal store stock requests and parts ordering
│   │   ├── order_models.dart        # StaffOrder and item requisition data structures
│   │   ├── order_service.dart       # Order dispatching, status updates, and supplier grouping
│   │   ├── owner_orders_view.dart   # Owner interface for approving and placing bulk orders
│   │   └── staff_orders_screen.dart # Staff interface for requisitioning out-of-stock items
│   │
│   ├── owner/                       # Owner private finances and trusted devices
│   │   ├── owner_finance_models.dart# Owner drawings, salary withdrawals, and capital models
│   │   ├── owner_finance_service.dart # Accounting service isolating personal drawings from shop cash
│   │   ├── owner_ledger_view.dart   # Owner ledger displaying monthly salary and drawings history
│   │   ├── owner_trusted_devices_screen.dart # UI for reviewing active authenticated devices
│   │   └── owner_withdrawal_dialog.dart # Dialog for logging owner personal drawings with notes
│   │
│   ├── pos/                         # Point-of-Sale checkout, EOD registers, and denominations
│   │   ├── cash_denomination_calculator.dart # Interactive Indian rupee cash denomination widget
│   │   ├── daily_register_models.dart # EOD closing records, shift reconciliations, and variances
│   │   ├── daily_register_service.dart# Register opening/closing and daily sales ledger queries
│   │   ├── daily_sales_ledger_view.dart # Day-wise sales ledger, filterable by date and biller
│   │   ├── pos_models.dart          # Cart items, discounts, taxes, and checkout payloads
│   │   ├── pos_service.dart         # Invoice generation, stock deduction, and ledger updates
│   │   └── staff_pos_screen.dart    # Dedicated mobile-friendly POS touch screen for billers
│   │
│   ├── purchases/                   # Vendor purchase bills, OCR parsing, and stock receiving
│   │   ├── imei_validator.dart      # Luhn-check and validation engine for phone IMEI numbers
│   │   ├── invoice_parser_service.dart # Extractor service parsing supplier invoice images/PDFs
│   │   ├── manual_purchase_draft_service.dart # Offline auto-saving draft service for bill entry
│   │   ├── manual_purchase_entry_screen.dart # Screen for keying in multi-item vendor invoices
│   │   ├── purchase_bills_dashboard_view.dart # Dashboard listing vendor bills and payment status
│   │   ├── purchase_bill_details_screen.dart # Detailed line-by-line view of a purchase bill
│   │   ├── purchase_bill_service.dart # Ingestion, stock increment, and vendor balance updates
│   │   ├── purchase_bill_upload_screen.dart # Document picker and camera scanner for purchase bills
│   │   ├── purchase_calculation_engine.dart # Subtotals, GST slabs, and discount calculation logic
│   │   ├── purchase_models.dart     # PurchaseBill, PurchaseLineItem, and Vendor models
│   │   ├── quick_register_drawer.dart # Quick-add drawer for registering new items during bill entry
│   │   ├── smart_inventory_combobox.dart # Auto-suggest dropdown matching existing inventory items
│   │   ├── smart_inventory_models.dart # Search rank and scoring models for inventory lookups
│   │   ├── smart_inventory_search_engine.dart # Fuzzy search engine matching barcodes, names, and models
│   │   ├── supplier_search_sheet.dart # Bottom sheet modal for quick vendor lookup and creation
│   │   └── vendor_ledger_screen.dart # Ledger showing purchases and payments made to a vendor
│   │
│   ├── recharge/                    # Quick Recharge accounting and operator wallet management
│   │   ├── commission_dialogs.dart  # Dialogs for configuring operator commission percentages
│   │   ├── daily_reconciliation_screen.dart # EOD operator balance audit and discrepancy tracker
│   │   ├── quick_recharge_dialog.dart # Modal dialog for executing and recording mobile recharges
│   │   ├── quick_recharge_screen.dart # Central Recharge Accounting dashboard with operator cards
│   │   ├── recharge_backend_bridge.dart # Abstract bridge definition for recharge execution
│   │   ├── recharge_models.dart     # RechargeRecord, OperatorWallet, and Distributor models
│   │   ├── recharge_recovery_engine.dart # Background engine resolving dead-letter/pending recharges
│   │   ├── recharge_reports_screen.dart # Detailed analytics on recharge volume and earned commissions
│   │   ├── recharge_service.dart    # Core business service managing wallet balances and debits
│   │   ├── supabase_recharge_bridge_client.dart # Supabase Edge Function implementation of the bridge
│   │   └── wallet_distributor_dialogs.dart # Dialogs for managing distributor accounts and top-ups
│   │
│   ├── reminders/                   # Customer payment reminders and service follow-ups
│   │   ├── followups_screen.dart    # Dashboard for after-sales service satisfaction follow-ups
│   │   ├── reminder_service.dart    # Service computing due dates and formatting WhatsApp messages
│   │   └── reminders_screen.dart    # Screen listing pending customer credit dues and reminder buttons
│   │
│   ├── rent/                        # Store property rent tracking and daily amortization
│   │   ├── daily_rent_history_view.dart # Ledger displaying daily rent accruals and payments
│   │   ├── daily_rent_payment_dialog.dart # Dialog for logging rent payments made to the landlord
│   │   ├── daily_rent_settings_dialog.dart # Configuration for monthly rent and daily amortization
│   │   ├── rent_models.dart         # DailyRentRecord, RentSettings, and Landlord models
│   │   └── rent_service.dart        # Service tracking daily rent expense deductions from cash
│   │
│   ├── repairs/                     # Device repair and service ticketing
│   │   ├── repair_models.dart       # ServiceJob, repair stages, defect checklists, and estimates
│   │   ├── repair_service.dart      # Job ticket creation, status changes, and parts utilization
│   │   ├── service_bill_dialog.dart # Dialog converting completed service jobs into POS invoices
│   │   └── staff_repairs_screen.dart# Technician dashboard for updating repair status and notes
│   │
│   ├── returns/                     # Customer sales returns and refunds
│   │   ├── customer_returns_screen.dart # Workflow screen for initiating and processing returns
│   │   ├── return_details_screen.dart # Inspection screen for returned items and refund breakdown
│   │   ├── return_models.dart       # CustomerReturn, ReturnedItem, and refund payment modes
│   │   ├── return_service.dart      # Service handling stock restock, cash refund, and ledger credit
│   │   └── returns_dashboard_view.dart # Dashboard displaying recent customer returns and analytics
│   │
│   ├── security/                    # Hardware key generation, DPAPI vault, and device security
│   │   ├── device_security_service.dart # ECDSA P-256 key management and request payload signing
│   │   ├── platform_hardware_key_store.dart # Native platform keystore / DPAPI storage bridge
│   │   ├── staging_identity_service.dart # Environment identity configuration and certificates
│   │   └── trusted_device_controller.dart # Controller tracking registered devices
│   │
│   ├── shared/                      # Localization strings and shared text constants
│   │   └── tek_pos_strings.dart     # Standard Malayalam and English text string definitions
│   │
│   ├── staff/                       # Staff management, shifts, payroll, and activity logging
│   │   ├── activity_log.dart        # Immutable audit logger recording user actions with diffs
│   │   ├── presence_service.dart    # Real-time presence tracking via heartbeats
│   │   ├── salary_calculator.dart   # Monthly salary, attendance deductions, and advance calculator
│   │   ├── staff_accounts_view.dart # Owner UI for creating staff members and assigning PINs
│   │   └── staff_tracking_view.dart # Live monitoring view of staff activity and current presence
│   │
│   ├── storage/                     # Cloud file storage clients
│   │   ├── storage_bridge.dart      # Abstract storage interface for document uploads
│   │   └── supabase_storage_bridge_client.dart # Supabase storage implementation for bills/receipts
│   │
│   ├── sync/                        # Offline-first Firestore synchronization engine
│   │   └── sync_engine.dart         # Two-way sync queue, conflict resolution, and network listener
│   │
│   ├── theme/                       # Enterprise design system tokens and typography
│   │   └── tek_tokens.dart          # TekColors, TekTypography, and Material 3 TekTheme definitions
│   │
│   ├── ui/                          # Global reusable UI widgets
│   │   ├── sync_status_icon.dart    # Cloud sync status indicator with queue count badge
│   │   ├── tek_feedback.dart        # Standardized snackbars, toast alerts, and confirmation dialogs
│   │   ├── tek_global_search_dialog.dart # Global search dialog across sales, items, and customers
│   │   ├── tek_kpi_card.dart        # Glassmorphic KPI metric summary card
│   │   ├── tek_quick_actions.dart   # Floating or grid quick-action shortcut bar
│   │   ├── tek_sales_chart.dart     # Responsive sales revenue chart with interactive tooltips
│   │   ├── tek_top_nav_bar.dart     # Desktop top navigation header with user profile and quick tools
│   │   │
│   │   └── dashboard/               # Main dashboard modular widgets
│   │       ├── alert_banner.dart    # Dismissible urgent alerts (low stock, unpaid dues)
│   │       ├── dashboard_screen.dart# Main responsive dashboard layout combining widgets
│   │       ├── dashboard_tokens.dart# Color and spacing tokens specific to dashboard metrics
│   │       ├── hero_banner.dart     # Welcome banner with current date, shift info, and quick stats
│   │       ├── quick_actions.dart   # Dashboard quick-access buttons for high-frequency workflows
│   │       ├── recent_activity.dart # Live feed of recent sales, repairs, and stock movements
│   │       ├── sales_chart.dart     # Revenue and profit trend graph for day/week/month
│   │       ├── service_summary.dart # Overview of pending, in-progress, and ready repair jobs
│   │       ├── sidebar.dart         # Collapsible desktop navigation sidebar with badge counts
│   │       ├── stat_card.dart       # Individual glassmorphism KPI card for metrics
│   │       ├── top_bar.dart         # Top action bar with search, notification panel, and clock
│   │       └── weather_card.dart    # Local weather widget for Kerala retail footfall context
│   │
│   ├── update/                      # In-app application update manager
│   │   ├── app_update_management_view.dart # Screen for checking updates and downloading releases
│   │   ├── app_update_service.dart  # Update checker communicating with release endpoints
│   │   ├── windows_update_banner.dart # Banner alerting users when a new Windows EXE is available
│   │   ├── windows_update_dialog.dart # Progress dialog downloading and applying Inno Setup updates
│   │   ├── windows_update_models.dart # Update release metadata, version, and changelog models
│   │   └── windows_update_service.dart# Windows native download, silent install, and restart runner
│   │
│   └── utils/                       # Global utility functions and adapters
│       ├── tek_helpers.dart         # Number parsing (`tekD`, `tekI`, `tekR2`), rupee formatters, and dates
│       └── timestamp_adapter.dart   # Firestore Timestamp to Hive-safe serialization adapter
```

---

## 3. Module & Screen Catalog

| Module / Screen | Primary File | Role & Functionality |
| :--- | :--- | :--- |
| **Dashboard** | `lib/ui/dashboard/dashboard_screen.dart` | Executive overview of today's sales, gross profit, cash in hand, active repair jobs, low-stock warnings, and recent activity feed. |
| **Sale / POS** | `lib/main.dart` (`SaleView`) & `lib/pos/staff_pos_screen.dart` | Fast checkout cart supporting barcode scanning, manual item search, backdated sales entry, cash/UPI/credit splits, and thermal printing. |
| **Daily Sales & EOD** | `lib/pos/daily_sales_ledger_view.dart` | Daily register showing all sales bills for a date, cashier shifts, physical cash denomination reconciliation, and closing ledger. |
| **Quick Recharge** | `lib/recharge/quick_recharge_screen.dart` | Telecom recharge accounting dashboard: manages Airtel, Jio, Vi, and BSNL wallets, distributor top-ups, earned commissions, and daily reconciliation. |
| **Items / Stock** | `lib/main.dart` (`ItemsView`) | Inventory catalog management: item creation, barcode generation, HSN codes, buying/selling rates, low-stock thresholds, and stock adjustments. |
| **Services / Repairs** | `lib/main.dart` (`ServicesView`) & `lib/repairs/staff_repairs_screen.dart` | Mobile & device repair ticketing: job intake, defect checklists, technician assignment, status tracking, customer delivery, and billing. |
| **Customer Returns** | `lib/returns/returns_dashboard_view.dart` | Processing returns against sales invoices: restocks items into inventory, reverses GST/sales, and issues cash refunds or party ledger credits. |
| **Purchase Bills** | `lib/purchases/purchase_bills_dashboard_view.dart` | Inward vendor purchase management: logs supplier tax invoices, auto-increments stock, and tracks accounts payable to distributors. |
| **Staff & Attendance** | `lib/main.dart` (`StaffView`) & `lib/attendance/staff_attendance_screen.dart` | Employee directory, biometric/selfie check-in with GPS geofencing, shift tracking, salary calculation, and owner attendance approvals. |
| **Customers (Parties)** | `lib/main.dart` (`PartiesView`) | Customer and supplier directory: tracks credit limits, running balances (dues/receivables), transaction history, and payment collection. |
| **Payment Reminders** | `lib/reminders/reminders_screen.dart` | Credit collection dashboard: displays overdue customer balances and provides one-click WhatsApp payment reminder generation. |
| **After-Sales Follow-ups** | `lib/reminders/followups_screen.dart` | Customer engagement dashboard: schedules follow-ups after device repair or purchase to ensure customer satisfaction and collect feedback. |
| **Expenses** | `lib/expenses/expense_management_screen.dart` | Operational store expense ledger: categorizes overheads (electricity, tea, supplies), records payment mode (Cash/Bank), and audits receipts. |
| **Daily Rent Ledger** | `lib/rent/daily_rent_history_view.dart` | Automated shop rent amortization: tracks daily accruals and logs lump-sum payments made to the landlord from cash or bank. |
| **Owner Salary & Drawings**| `lib/owner/owner_ledger_view.dart` | Dedicated owner equity ledger: tracks monthly owner salary and personal cash drawings separately from operational store expenses. |
| **Trusted Devices** | `lib/owner/owner_trusted_devices_screen.dart` | Security audit screen: shows all hardware devices connected to the store account (hardware restrictions for recharge removed). |
| **Purchase & Expense** | `lib/main.dart` (`PurchaseExpenseView`) | Combined view of day-to-day purchases and operating expenses for quick operational accounting. |
| **Cash & Bank** | `lib/main.dart` (`CashBankView`) | Bank account balances, cash in register, contra transfers (Cash to Bank / Bank to Cash), and running transaction log. |
| **Reports** | `lib/main.dart` (`ReportsView`) | Analytics and tax reporting: daily sales, item-wise profitability, GST reports (B2C/B2B), stock valuation, and date-range filters. |
| **Settings & Print** | `lib/main.dart` (`SettingsView`) | Store profile, tax settings, receipt header/footer, thermal printer selection (80mm vs 58mm), and backup controls. |

---

## 4. Hive Boxes & Data Models

All monetary values are stored in **integer paise or standard decimal floating-point rupees** formatted via `tekD` and `tekR2`. Dates are stored in **ISO 8601 UTC** and formatted to **IST (Asia/Kolkata)** for presentation.

### Core Hive Boxes (`allBoxes`)

1. **`tek_items` (`boxItems`)**
   - `_id` (`String`): Global UUID.
   - `name` (`String`): Item description.
   - `code` / `barcode` (`String`): SKU or scannable barcode.
   - `category` (`String`): Item classification.
   - `unit` (`String`): Unit of measurement (`Pcs`, `Mtr`, `Set`).
   - `cost` (`double`): Wholesale purchase cost.
   - `price` (`double`): Retail selling price (MRP).
   - `stock` (`int`): Current on-hand quantity.
   - `minStock` (`int`): Reorder warning threshold.
   - `taxRate` (`double`): GST rate percentage (e.g., `18.0`).
   - `hsn` (`String`): Harmonized System of Nomenclature code.
   - `isConsumable` (`bool`): Flag for internal shop supplies.
   - `updatedAt` (`String`): ISO 8601 timestamp.

2. **`tek_parties` (`boxParties`)**
   - `_id` (`String`): Global UUID.
   - `name` (`String`): Customer or supplier name.
   - `phone` (`String`): 10-digit mobile number.
   - `type` (`String`): `'Customer'` or `'Supplier'`.
   - `balance` (`double`): Net balance (positive = receivable/due, negative = payable).
   - `address` (`String`): Physical billing address.
   - `gstin` (`String`): 15-character GST identification number.
   - `creditLimit` (`double`): Maximum credit threshold.
   - `createdAt` / `updatedAt` (`String`): Timestamps.

3. **`tek_sales` (`boxSales`)**
   - `_id` (`String`): Global UUID.
   - `invoice` (`String`): Human-readable sequence (e.g., `INV-C10042`).
   - `createdAt` (`String`): Real-world entry timestamp.
   - `saleDate` (`String`): Effective business/accounting date (for backdated sales).
   - `partyId` (`String?`): Customer UUID reference.
   - `partyName` / `partyPhone` (`String`): Denormalized customer details.
   - `items` (`List<Map>`): Line items: `[{itemId, name, qty, price, cost, taxRate, total}]`.
   - `subtotal` / `discount` / `tax` / `total` (`double`): Bill totals.
   - `cash` / `upi` / `due` (`double`): Payment mode split.
   - `status` (`String`): `'Paid'`, `'Partial'`, `'Unpaid'`, `'Cancelled'`, `'Returned'`.
   - `returnedAmount` (`double`): Value refunded via customer returns.
   - `biller` (`String`): Username/ID of cashier who created the bill.
   - `shopId` (`String`): Multi-tenant shop identifier.

4. **`tek_service_jobs` (`boxServices`)**
   - `_id` (`String`): Global UUID.
   - `jobId` (`String`): Unique service ticket (e.g., `SRV-20261118-C1001`).
   - `customerName` / `phone` (`String`): Customer contact details.
   - `deviceModel` (`String`): Brand and model name.
   - `imei` / `serialNo` (`String`): Unique device identifier.
   - `issue` (`String`): Reported customer defect.
   - `costEst` / `advance` (`double`): Financial estimate and deposit.
   - `status` (`String`): `'Received'`, `'In Progress'`, `'Waiting for Parts'`, `'Ready'`, `'Delivered'`.
   - `assignedTo` (`String`): Technician name.
   - `receivedAt` / `deliveredAt` (`String`): Timestamps.

5. **`tek_recharges` (`boxRecharges`)**
   - `_id` (`String`): Global UUID.
   - `mobileNumber` (`String`): 10-digit customer mobile.
   - `operator` (`String`): `'Airtel'`, `'Jio'`, `'Vi'`, `'BSNL'`.
   - `amount` (`double`): Customer payment amount (Principal).
   - `commissionRate` (`double`): Operator commission percentage.
   - `commissionEarned` (`double`): Net income from transaction (`amount * rate`).
   - `walletDebit` (`double`): Net amount deducted from operator wallet.
   - `timestamp` (`String`): Transaction time.
   - `status` (`String`): `'SUCCESS'`, `'PENDING'`, `'FAILED'`.
   - `operatorTxnId` (`String`): External reference ID.
   - `performedBy` (`String`): Owner account username.

6. **`tek_recharge_reconciliation` (`boxRechargeReconciliation`)**
   - `_id` (`String`): Reconciliation UUID.
   - `date` (`String`): Accounting date (`YYYY-MM-DD`).
   - `operatorBalances` (`Map<String, Map>`): `{ 'Airtel': { opening, closing, actual, variance } }`.
   - `totalCommission` (`double`): Total income recognized for the day.
   - `verifiedBy` (`String`): Owner username who completed reconciliation.

7. **`tek_bank` (`boxBank`)**
   - `cash_in_hand` (`double`): Current physical cash balance.
   - `bank_balance` (`double`): Current digital bank/UPI account balance.
   - `txn_log` (`List<Map>`): Rolling log of the last 500 cash/bank movements.

8. **`tek_expenses` (`boxExpenses`)**
   - `_id` (`String`): Expense UUID.
   - `date` (`String`): Expense date.
   - `category` (`String`): Overhead category (`Tea & Snacks`, `Rent`, `Electricity`, `Tools`).
   - `amount` (`double`): Amount paid.
   - `paymentMode` (`String`): `'Cash'` or `'Bank'`.
   - `note` (`String`): Description.

9. **`tek_audit_logs` (`boxAudit`)**
   - `_id` (`String`): Audit UUID.
   - `timestamp` (`String`): ISO 8601 creation time.
   - `user` / `role` (`String`): Actor and permissions.
   - `action` (`String`): Action identifier (`Invoice Created`, `Money In`, `Item Modified`).
   - `entity` / `entityId` (`String`): Target entity name and key.
   - `oldValue` / `newValue` (`dynamic`): Audit state diff.
   - `reason` (`String`): Mandatory explanation (e.g., for backdated sales or cancellations).

10. **`tek_sync_queue` (`boxSyncQueue`)**
    - `_id` (`String`): Queue entry UUID.
    - `collection` (`String`): Target Firestore collection path.
    - `action` (`String`): `'create'`, `'update'`, `'delete'`, `'increment'`.
    - `payload` (`Map<String, dynamic>`): Document data.
    - `timestamp` (`String`): Enqueue time.
    - `attempts` (`int`): Retry counter.

---

## 5. Current Theme Setup

- **Design System Location:** `lib/theme/tek_tokens.dart` and `lib/ui/dashboard/dashboard_tokens.dart`.
- **Color Palette (`TekColors`):**
  - **Surfaces:**
    - `mainBg`: `#070B18` (Deep midnight navy)
    - `sidebarBg`: `#0B1226` (Dark slate navy)
    - `cardBg`: `#111B35` (Glassmorphic card surface)
    - `elevatedSurface`: `#172442` (Modal and dropdown surface)
  - **Accents & Primaries:**
    - `primaryBlue`: `#1677FF` (Primary brand blue)
    - `electricCyan`: `#00D4FF` (High-contrast neon highlight)
    - `premiumPurple`: `#8B5CF6` (Secondary accent)
  - **Status Badges:**
    - `success`: `#22C55E` (Emerald green)
    - `warning`: `#F59E0B` (Amber orange)
    - `error`: `#F43F5E` (Coral red)
  - **Borders & Dividers:**
    - `border`: `#263452`
    - `borderSubtle`: `#1A2640`
- **Typography (`TekTypography`):**
  - **Primary Engine:** Google Fonts `Noto Sans Malayalam` combined with system sans-serif (`Roboto`, `Segoe UI`).
  - Explicit line height of `1.35`–`1.4` set on Malayalam text tokens to prevent vowel sign (`മാത്രകൾ`) and chandrakala (`ചന്ദ്രക്കല`) clipping across responsive screens.
  - Defined styles: `titleLarge` (22px bold), `titleMedium` (16px semi-bold), `bodyPrimary` (14px), `bodySecondary` (13px), `caption` (11px).
- **ThemeData Registration:**
  - Configured in `lib/main.dart` via `_buildTheme(Brightness.dark)` and `TekTheme.darkTheme`.
  - Material 3 enabled (`useMaterial3: true`).
  - Dark mode set as the primary enterprise experience (`themeMode: ThemeMode.dark`).
  - Resilient error theme defined in `TekFixStartupErrorApp` to display legible startup diagnostics if Flutter engine or Hive fails.

---

## 6. Features Completed vs. Pending / Half-Done

### Features Completed
- [x] **Windows & Android Cross-Platform Deployment:** Single Dart codebase running natively on Windows x64 and Android mobile/tablets.
- [x] **Offline-First Storage & Firestore Sync:** Hive local-first caching with background bidirectional queue sync (`SyncEngine`) handling offline network disruptions.
- [x] **Dual Authentication & Role Control:** Secure Owner vs Staff roles with PIN login, session locks, and activity logging.
- [x] **Sales & Point of Sale (POS):** Full retail billing engine with discount controls, multi-mode payments (Cash, UPI, Credit), and thermal printing.
- [x] **Backdated Sales Entry (Feature Upgrade Phase 1):**
  - Date/time picker on POS cart with "Backdated (മുൻകാലം)" visual chip.
  - Role-based validation: Owner can backdate to any open period; Staff restricted to `backdate_days_limit` (default 1 day).
  - Validation blocking backdates into dates with closed daily reconciliations.
  - Stores distinct `saleDate` (business date) and `createdAt` (audit timestamp).
  - Accurate backdating propagation across stock moves, cash ledgers, party ledgers, and sales reports.
- [x] **Daily Sales & EOD Reconciliation:** Shift registers, automated cash variance calculations, and Indian rupee denomination breakdown calculator.
- [x] **Quick Recharge Accounting Module:**
  - Multi-operator wallet management (Airtel, Jio, Vi, BSNL).
  - Correct accounting: separates recharge principal from actual earned commission.
  - Distributor management and wallet top-up tracking.
  - Daily opening/closing reconciliation and variance tracking.
  - Supabase Edge Function bridge for zero-cost hardware-signed operations.
  - **Permanent removal of trusted-device restrictions:** Owner can execute recharges from any authorized laptop, desktop, or mobile device.
- [x] **Inventory & Stock Management:** Barcode generation, stock adjustment audits, and consumable supply tracking.
- [x] **Device Repair & Service Ticketing:** Multi-stage repair workflows, customer intake, technician tracking, and service billing.
- [x] **Customer Returns & Restocking:** Full return management restoring inventory, reversing GST, and issuing refunds.
- [x] **Vendor Purchase Bills:** Manual vendor invoice entry, stock incrementing, and accounts payable tracking.
- [x] **Staff Management & Geofenced Attendance:** Geolocation-validated check-in/out, owner approval queue, and salary calculation.
- [x] **Overhead Expenses & Daily Rent:** Category-based expense tracking and daily rent amortization.
- [x] **Owner Equity & Drawings:** Clean separation of owner withdrawals and salary from business operational cash.
- [x] **In-App Application Auto-Updates:** Windows native update checker, Inno Setup executable downloader, and silent installer.

### Features Pending or Half-Done
- [ ] **Phone-First Customer Auto-Fill (Feature Upgrade Phase 2):**
  - Moving phone input to top of POS customer section with 10-digit auto-search.
  - Auto-filling customer name, address, and running balance on 10th digit.
  - Inline quick customer creation modal when number is not found.
- [ ] **POS Customer History & Buying Patterns (Feature Upgrade Phase 3):**
  - Collapsible side drawer displaying customer's last 5 purchases, average spend, and active repair tickets.
  - One-click copy of items from previous bills into current cart.
  - Real-time customer credit limit warnings during checkout.
- [ ] **Standalone Warranty Registry & IMEI Tracker (Feature Upgrade Phase 4):**
  - Dedicated `tek_warranties` box tracking serial numbers, IMEIs, and warranty start/end dates.
  - Searchable warranty registry for walk-in claims.
  - Printable PDF warranty certificate.
- [ ] **Automated Supplier Invoice OCR:** Document upload exists, but automated OCR extraction of vendor line items via cloud vision is currently a stub/manual entry.
- [ ] **Direct Bluetooth ESC/POS on Mobile:** Mobile printing currently relies on Android print spooler rather than direct Bluetooth SPP socket connections.

---

## 7. Known Bugs or Issues

1. **Startup Initialization Race Condition (Mitigated):**
   - On Windows, if native plugins or display drivers initialize slowly, Flutter could show a white screen if unhandled exceptions occurred in `main()`.
   - *Status:* Mitigated via `TekFixStartupErrorApp` and `runZonedGuarded`, but background service initializations must remain non-blocking.
2. **Offline Concurrent Edit LWW (Last-Write-Wins):**
   - If two offline devices modify the exact same item price or stock simultaneously before syncing, Firestore reconciliation resolves via timestamp (last-write-wins). Stock movements mitigate this by syncing as delta increments rather than absolute values.
3. **Audit Log & Sync Queue Growth:**
   - Over months of heavy retail billing, `tek_audit_logs` and completed `tek_sync_queue` records can grow large. Periodic compaction or archiving to cold storage is recommended.
4. **Thermal Printer Paper Cut Spooling:**
   - Certain generic 80mm ESC/POS USB printers on Windows ignore the GS `V` 0 hardware cut command sent through the Windows generic text spooler.
