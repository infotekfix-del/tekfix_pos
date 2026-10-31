# 📱 TekFix POS & Orders Ecosystem

Unified Cross-Platform Enterprise POS, Staff Attendance, and Product Orders Management System for **TEKFIX MOBILE HUB / TEKFIX DIGITAL**.

---

## 🚀 Applications & Download Links

This repository powers both the **Windows Desktop Owner Panel** and the **Mobile Staff POS & Orders App** from a single unified codebase.

| Application | Target Platform | Target Role | Download Link / Release Asset |
| :--- | :--- | :--- | :--- |
| **🖥️ TekFix Owner Panel** | Windows 10 / 11 (x64) | Shop Owner / Admins | [Download Windows Package (`tekfix_pos-windows-x64.zip`)](https://github.com/infotekfix-del/tekfix_pos/releases/latest/download/tekfix_pos-windows-x64.zip)<br>*(Extract the ZIP and run `tekfix_pos.exe`)* |
| **📱 TekFix Staff POS & Orders** | Android 8.0+ (ARM64 / ARMv7) | Staff / Technicians | [Download Android APK (`app-release.apk`)](https://github.com/infotekfix-del/tekfix_pos/releases/latest/download/app-release.apk) |

---

## 🌟 Key Architecture & Features

### 1. 🖥️ Windows Desktop (Owner Panel)
- **Role-Based Access Control (RBAC):** Full administrative controls with complete P&L analytics, inventory cost margins, and audit trail.
- **Real-Time Staff Orders Management:**
  - Live stream of all staff product orders submitted across all shops.
  - Quick status picker (Submitted, Pending, Confirmed, Processing, Completed, Cancelled) with immediate Cloud Firestore sync.
  - One-click RFC-4180 CSV export for order fulfillment and stock purchasing.
- **Attendance & Cash Register Approvals:**
  - Real-time GPS location and shift hours verification.
  - Cash-in-drawer reconciliation comparing expected vs counted cash.
- **Inventory & Stock Management:** Low-stock alerts, barcode scanner integration, and thermal bill printing.

### 2. 📱 Android Mobile (Staff Portal & POS)
- **Attendance-Gated Access:** POS sales and operations unlock only upon active check-in.
- **TekFix Orders (Section 13 Integration):**
  - **Catalog Ordering:** Browse in-store inventory with real-time stock levels, category filters, and quantity steppers.
  - **Custom Item Entry:** Add custom parts, display combos, and non-inventory items with model, variant, and remarks.
  - **Sequential Order ID:** Collision-proof format `TF-YYYYMMDD-XXXX` generated via atomic Firestore transactions.
  - **WhatsApp Group Dispatch:** One-tap submission to the company WhatsApp group (`https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4`) with clipboard formatting.
- **Service & Repairs Tracking:** Log incoming repair jobs, diagnostics, technician assignments, and customer notifications.
- **Strict Data Protection:** Staff cannot view sensitive financial metrics, margins, or delete records.

---

## 🛠️ Tech Stack & Backend

- **Frontend:** Flutter 3.x (Dart 3.x)
- **Central Database:** Cloud Firestore (Project `tekfix-45b38`)
- **Local Persistence & Offline Cache:** Hive Box Storage
- **Authentication:** Firebase Auth with document-level Role-Based Access Control
- **Security:** Strict Server-Side Firestore Security Rules (`firestore.rules`)

---

## 📦 Building from Source

### 1. Prerequisites
- Flutter SDK 3.27+
- Android Studio / Android SDK (for Android APK)
- Visual Studio 2022 with C++ Desktop Development (for Windows Desktop)

### 2. Build Commands

#### Build Android Release APK:
```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

#### Build Windows Desktop Release:
```bash
flutter build windows --release
# Output: build/windows/x64/runner/Release/
```

---

## 📄 License & Ownership
Copyright © 2026 **TekFix Digital**. All rights reserved.
