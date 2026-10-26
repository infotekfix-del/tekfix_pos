# Tekfix Orders - Native Android Staff Order Management App

A modern, high-performance native Android application built with **Kotlin**, **Jetpack Compose**, **Material 3 Design**, and **Firebase** for daily staff product order management at **Tekfix Digital**.

---

## 📱 Features

### 1. User Roles & Access Control
- **Staff:**
  - Secure authentication (session persistence, active account check).
  - Searchable product catalog (Name, SKU, Model, Category, Availability).
  - Method A (Select from catalog with quantity stepper) & Method B (+ Add custom product).
  - Real-time Order Cart with quantity editing, item remarks, and general order remarks.
  - Complete Order Preview with validation & confirmation dialog.
  - Automatic sequential Order ID generation (`TF-YYYYMMDD-XXXX`).
  - Offline draft preservation (restores cart on app restart).
  - Order History with quick re-ordering / duplication.
- **Admin:**
  - Comprehensive dashboard with order statistics and pending review queue.
  - Product Catalog Management (Add, edit, toggle active status, delete).
  - CSV Import with column validation, duplicate SKU detection, and summary reports.
  - Staff Account Management (Create staff, activate/deactivate, trigger password resets).
  - Analytics & Reports (Order totals, units ordered, orders by staff, CSV export).
  - WhatsApp Integration Settings (Group invitation link, optional automated cloud API gateway).

---

### 2. WhatsApp Group Integration & Supported Fallback
- **Target Company WhatsApp Group:**
  `https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4`
- **Dynamic Message Formatter (Section 13 Specification):**
  Automatically formats the order into the exact company format with emoji headers, dividers, item numbers, models, remarks, and total sums.
- **Reliable Fallback Workflow:**
  1. Order is securely saved to Cloud Firestore with status `ORDER_SAVED`.
  2. If an authorized WhatsApp Business API gateway is configured, automated delivery is attempted.
  3. Otherwise, the app activates the supported fallback modal:
     - 📋 **"Copy Order Text"** button (copies the formatted message to Android clipboard).
     - 📲 **"Open WhatsApp Group"** button (launches the WhatsApp group invitation link directly).
     - 📤 **"Share via Apps"** button (system share intent).
     - Explicit guidance informing the staff member that the order is recorded in the cloud and ready to be posted into the group.

---

## 🛠️ Technology Stack & Architecture
- **Language:** Kotlin 2.0+
- **UI Framework:** Jetpack Compose (Material 3)
- **Architecture:** MVVM + Repository Pattern + Clean Architecture
- **Async & Reactive:** Kotlin Coroutines & StateFlow
- **Backend & Database:** Firebase Authentication, Cloud Firestore (Offline Persistence enabled)
- **Notifications:** Firebase Cloud Messaging (FCM) & Android Notification Channels
- **Utilities:** OpenCSV / RFC-4180 CSV parser & exporter

---

## 🚀 Build & Installation Instructions

### Prerequisites
1. **Android Studio:** Android Studio Hedgehog / Iguana / Koala / Ladybug or newer.
2. **JDK:** Java 17 or Java 21 (bundled inside Android Studio at `C:\Program Files\Android\Android Studio\jbr`).
3. **Android SDK:** API Level 34 / 35.

### Building via Android Studio
1. Open Android Studio.
2. Select **File -> Open...** and navigate to `d:\tekfix_pos\tekfix_orders`.
3. Allow Gradle to sync dependencies.
4. Select a connected Android device or Emulator.
5. Click **Run 'app'** (`Shift + F10`).

### Building APK via Command Line
Run the following command in PowerShell / Terminal from the `tekfix_orders` directory:

```powershell
# Set Java Home if necessary
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# Build Debug APK
.\gradlew.bat assembleDebug

# Build Production Release APK
.\gradlew.bat assembleRelease
```

The compiled APK will be located at:
`tekfix_orders/app/build/outputs/apk/release/app-release-unsigned.apk` (or `debug/app-debug.apk`).

---

## 🧪 Testing Scenarios
1. **Staff Login:** Enter staff email/password -> redirects to `StaffDashboard`.
2. **Product Catalog Selection:** Search "iPhone", select 20 Pcs -> added to cart.
3. **Manual Custom Product:** Tap "+ Custom", enter "Custom Product", Model "V1", 5 Pcs -> added to cart.
4. **Order Preview:** Verify Order ID, Date/Time, total product types and quantities.
5. **Idempotent Submission:** Tap "SUBMIT ORDER" -> dialog confirms -> order saved in Firestore.
6. **WhatsApp Sharing:** Tap "Copy Order Text" -> copies formatted order -> tap "Open WhatsApp Group" -> opens group link.
7. **Admin Product Management:** Add product, edit product, import CSV with duplicate SKU check.
8. **Admin Staff Management:** Create staff account, toggle active status, send password reset.
9. **Admin Reports:** View top products, export orders to CSV.
