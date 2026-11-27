# TEKFIX ERP – PHASE 13.0.8
# STAGING-ONLY CLOUD FUNCTIONS REGION SYNCHRONIZATION REPORT

**Execution Date:** 2026-11-08  
**Role:** Senior Firebase Architect and Security Engineer  
**Target Staging Project:** `tekfix-staging`  
**Staging Region:** `asia-south1` (Mumbai, India)  
**Production Project:** `tekfix-45b38` (Preserved in `us-central1`)  
**Final Verdict:** **A. PASSED**  

---

## 1. EXECUTIVE SUMMARY

In Phase 13.0.8, Cloud Functions and the Flutter client were successfully synchronized for the dedicated staging project (`tekfix-staging`) targeting `asia-south1` (Mumbai). 

### Key Accomplishments:
1. **Server-Side Region Resolution:** Updated `firebase/functions/index.js` to dynamically bind all three Cloud Functions (`onStaffCheckIn`, `autoCloseForgottenCheckouts`, `processRechargeDebit`) to `asia-south1` when executing under `tekfix-staging` (or `FUNCTION_REGION=asia-south1`), while preserving `us-central1` for production (`tekfix-45b38`).
2. **Environment-Authoritative Flutter Client:** Enhanced `lib/firebase_options.dart` to provide `DefaultFirebaseOptions.functionsRegion` and `DefaultFirebaseOptions.functionsInstance`, explicitly resolving to `FirebaseFunctions.instanceFor(region: 'asia-south1')` for Staging while preserving `us-central1` for Production.
3. **Recharge Client Callable Modernization:** Updated [recharge_service.dart](file:///d:/tekfix_pos/lib/recharge/recharge_service.dart) to route `processRechargeDebit` calls through `DefaultFirebaseOptions.functionsInstance`, eliminating hardcoded default regions and guaranteeing client-server region alignment.
4. **Security & Financial Integrity Preserved:** Strict server-level environment isolation ensures region cannot be tampered with via untrusted runtime payloads. All transaction logic, idempotency checks, and integer paise accounting remain 100% unaltered.
5. **Empirical Verification:** **136 / 136 tests passed** (6 backend region tests, 8 Flutter environment tests, 92 Flutter recharge accounting tests, and 30 adversarial emulator security tests) with **zero static analysis warnings**.

---

## 2. PRE-IMPLEMENTATION CHANGE PLAN (FILE-BY-FILE)

| File | Component | Intended Change | Production Safety Justification |
| :--- | :--- | :--- | :--- |
| [firebase/functions/index.js](file:///d:/tekfix_pos/firebase/functions/index.js) | Backend Cloud Functions | Introduce `resolveFunctionsRegion()` inspecting `GCLOUD_PROJECT` / `FIREBASE_CONFIG` / `FUNCTION_REGION`. Bind `onStaffCheckIn`, `autoCloseForgottenCheckouts`, and `processRechargeDebit` via `regionalFunctions`. | Defaults to `us-central1` if `tekfix-45b38` or unspecified. Zero logic alterations to transaction flow or integer paise. |
| [lib/firebase_options.dart](file:///d:/tekfix_pos/lib/firebase_options.dart) | Flutter Environment Options | Add `functionsRegion` and `functionsInstance` accessors. Provide pure helpers `parseEnvironment` and `resolveFunctionsRegion`. | Production environment resolves to `us-central1`. Staging resolves to `asia-south1`. Fail-closed on missing configs. |
| [lib/recharge/recharge_service.dart](file:///d:/tekfix_pos/lib/recharge/recharge_service.dart) | Offline Queue & Online Debit | Replace `FirebaseFunctions.instance.httpsCallable` with `DefaultFirebaseOptions.functionsInstance.httpsCallable`. | Ensures client requests target the exact matching region for the active environment. Preserves all transaction payloads and error handling. |
| [test/firebase_functions_region_environment_test.dart](file:///d:/tekfix_pos/test/firebase_functions_region_environment_test.dart) | New Flutter Test Suite | Comprehensive unit tests for staging/production region resolution, environment parsing, and fail-closed rejections. | Verifies isolation boundaries in isolation. |
| [scratch/phase13_0_8_backend_region_test.js](file:///d:/tekfix_pos/scratch/phase13_0_8_backend_region_test.js) | New Node.js Backend Suite | Verifies `__trigger.regions` for staging (`asia-south1`), production (`us-central1`), and untrusted input protection. | Verifies exported triggers on Node.js without deployment. |

---

## 3. IMPLEMENTATION DETAILS

### A. Backend Regionalization ([firebase/functions/index.js](file:///d:/tekfix_pos/firebase/functions/index.js))
```javascript
/**
 * Region Configuration for Cloud Functions (Phase 13.0.8):
 *
 * - Staging ('tekfix-staging'): Explicitly pins all Cloud Functions to 'asia-south1' (Mumbai).
 * - Production ('tekfix-45b38'): Preserves existing legacy default 'us-central1' (Iowa).
 *
 * Security & Isolation Rules:
 * 1. Resolved exclusively from trusted server-level environment variables:
 *    - FUNCTION_REGION or FIREBASE_FUNCTIONS_REGION (deployment/process environment)
 *    - GCLOUD_PROJECT / FIREBASE_CONFIG.projectId (injected by Google Cloud / Firebase)
 * 2. Never accepts or derives region from runtime client/user payload data.
 */
function resolveFunctionsRegion() {
  const explicitRegion = process.env.FUNCTION_REGION || process.env.FIREBASE_FUNCTIONS_REGION;
  if (explicitRegion) {
    return explicitRegion.trim().toLowerCase();
  }

  let projectId = process.env.GCLOUD_PROJECT || "";
  if (!projectId && process.env.FIREBASE_CONFIG) {
    try {
      const parsed = typeof process.env.FIREBASE_CONFIG === "string"
        ? JSON.parse(process.env.FIREBASE_CONFIG)
        : process.env.FIREBASE_CONFIG;
      projectId = parsed.projectId || "";
    } catch (_) {}
  }

  projectId = projectId.trim().toLowerCase();
  if (projectId === "tekfix-staging" || projectId.includes("staging")) {
    return "asia-south1";
  }

  // Production (tekfix-45b38) or default preserves legacy us-central1
  return "us-central1";
}

const FUNCTIONS_REGION = resolveFunctionsRegion();
const regionalFunctions = functions.region(FUNCTIONS_REGION);

exports._resolveFunctionsRegion = resolveFunctionsRegion;
exports.onStaffCheckIn = regionalFunctions.firestore.document(...).onCreate(...);
exports.autoCloseForgottenCheckouts = regionalFunctions.pubsub.schedule(...).onRun(...);
exports.processRechargeDebit = regionalFunctions.https.onCall(async (data, context) => { ... });
```

### B. Flutter Client Configuration ([lib/firebase_options.dart](file:///d:/tekfix_pos/lib/firebase_options.dart))
```dart
  /// Authoritative Cloud Functions region for the active environment (Phase 13.0.8).
  ///
  /// - Staging (`tekfix-staging`): Explicitly pins to `asia-south1` (Mumbai).
  /// - Production (`tekfix-45b38`): Preserves legacy default `us-central1`.
  /// - Development: Defaults to `asia-south1` (or custom `FIREBASE_FUNCTIONS_REGION`).
  static String get functionsRegion =>
      resolveFunctionsRegion(currentEnvironment, customRegion: _customFunctionsRegion);

  /// Pure region resolver for testing and authoritative resolution.
  static String resolveFunctionsRegion(
    TekFixEnvironment env, {
    String customRegion = '',
  }) {
    if (customRegion.isNotEmpty) {
      return customRegion.trim().toLowerCase();
    }
    switch (env) {
      case TekFixEnvironment.staging:
        return 'asia-south1';
      case TekFixEnvironment.production:
        return 'us-central1';
      case TekFixEnvironment.development:
        return 'asia-south1';
    }
  }

  /// Returns the configured [FirebaseFunctions] client instance for the active environment.
  ///
  /// - Staging uses `FirebaseFunctions.instanceFor(region: 'asia-south1')`.
  /// - Production uses `FirebaseFunctions.instanceFor(region: 'us-central1')`.
  /// - Strict fail-closed validation: Missing or invalid environment throws [StateError].
  static FirebaseFunctions get functionsInstance {
    return FirebaseFunctions.instanceFor(region: functionsRegion);
  }
```

### C. Client Callable Routing ([lib/recharge/recharge_service.dart](file:///d:/tekfix_pos/lib/recharge/recharge_service.dart))
Lines 242 and 723 updated to route through `DefaultFirebaseOptions.functionsInstance`:
```dart
// Line 242 (Offline queue drain replay)
final callable = DefaultFirebaseOptions.functionsInstance.httpsCallable('processRechargeDebit');

// Line 723 (Online direct debit)
final callable = DefaultFirebaseOptions.functionsInstance.httpsCallable('processRechargeDebit');
```

---

## 4. ENVIRONMENT SEPARATION & UNTRUSTED INPUT PROTECTION

1. **Compile-Time vs Runtime Protection:** Environment selection in Flutter is strictly bound to `--dart-define=TEKFIX_ENV=...`. Untrusted user data or runtime variables cannot alter the active environment or region.
2. **Server-Side Protection:** The Cloud Functions region in `firebase/functions/index.js` is resolved during initialization from container environment variables (`GCLOUD_PROJECT`, `FIREBASE_CONFIG`). A client sending `{ region: "..." }` or `{ projectId: "..." }` in the callable payload has zero effect on the server's regional deployment or execution context.
3. **Fail-Closed Safeguards:**
   - Attempting to build or initialize `TekFixEnvironment.staging` without human-configured staging project options throws a fatal `StateError`.
   - Attempting to pass an unknown environment string (e.g. `TEKFIX_ENV=local`) throws `StateError('Unknown TEKFIX_ENV...')`.

---

## 5. EMPIRICAL TEST VERIFICATION EVIDENCE

### Test Suite 1: Backend Region Synchronization (`scratch/phase13_0_8_backend_region_test.js`)
- **Status:** **6 / 6 PASSED (100%)**
  - `[PASS]` Staging project (`tekfix-staging`) sets region to `asia-south1` across all 3 functions.
  - `[PASS]` Production project (`tekfix-45b38`) preserves region as `us-central1` across all 3 functions.
  - `[PASS]` Empty/Default project preserves region as `us-central1`.
  - `[PASS]` `FIREBASE_CONFIG` JSON with staging project ID sets `asia-south1`.
  - `[PASS]` Explicit `FUNCTION_REGION` override is respected.
  - `[PASS]` Server region cannot be influenced by client payload or unauthenticated data.

### Test Suite 2: Flutter Region & Environment Suite (`test/firebase_functions_region_environment_test.dart`)
- **Status:** **8 / 8 PASSED (100%)**
  - `[PASS]` TEST 1: Staging environment resolves to `asia-south1`.
  - `[PASS]` TEST 2: Production environment preserves legacy `us-central1`.
  - `[PASS]` TEST 3: Development environment defaults to `asia-south1`.
  - `[PASS]` TEST 4: Custom region override is respected when provided.
  - `[PASS]` TEST 5: Environment parser correctly resolves valid values (`staging`, `STAGING`, `production`, `prod`, `dev`).
  - `[PASS]` TEST 6: Environment mismatch rejection (Invalid values `local`, `qa_test`, `""` throw `StateError`).
  - `[PASS]` TEST 7: Active compile-time environment preserves production default.
  - `[PASS]` TEST 8: Active compile-time production options point to `tekfix-45b38`.

### Test Suite 3: Full Flutter Recharge Accounting Regression Suites (10 Suites)
- **Status:** **92 / 92 PASSED (100%)**
  - `test/recharge_collection_accounting_test.dart`: 9 passed
  - `test/recharge_commission_accounting_test.dart`: 4 passed
  - `test/recharge_daily_reconciliation_test.dart`: 4 passed
  - `test/recharge_failure_refund_reversal_test.dart`: 8 passed
  - `test/recharge_float_distributor_settlement_test.dart`: 6 passed
  - `test/recharge_phase10_e2e_audit_test.dart`: 15 passed
  - `test/recharge_phase11_hardening_test.dart`: 8 passed
  - `test/recharge_reports_financial_reconciliation_test.dart`: 10 passed
  - `test/recharge_wallet_distributor_test.dart`: 27 passed
  - `test/quick_recharge_dashboard_test.dart`: 1 passed

### Test Suite 4: Adversarial Emulator Security & Financial Integrity Suite (`scratch/phase13_0_5_independent_audit_suite.js`)
- **Status:** **30 / 30 PASSED (100%)**
  - All 30 scenarios verified passing against the local Firebase emulator (Firestore 8080, Functions 5001), including maintenance mode atomicity, concurrency serialization, reversal replay rejection, and integer paise validation.

### Static Code Analysis (`flutter analyze`)
- **Command:** `flutter analyze lib/firebase_options.dart lib/recharge/recharge_service.dart test/firebase_functions_region_environment_test.dart`
- **Result:** **No issues found! (0 errors, 0 warnings, 0 lints)**

---

## 6. PRODUCTION PROTECTION VERIFICATION

- **ZERO Remote Deployments:** No `firebase deploy` commands were executed.
- **ZERO Production Connections:** Project `tekfix-45b38` was never contacted over the network.
- **ZERO Production Firestore Access:** Real customer databases and financial ledgers were completely untouched.
- **ZERO Ledger Deletions or Resets:** All accounting models and ledger immutability constraints remain intact.

---

## 7. FINAL VERDICT

```
================================================================================
FINAL VERDICT:
A. PASSED

All three Cloud Functions and the Flutter FirebaseFunctions client have been
fully synchronized to target 'asia-south1' for the dedicated staging project
(tekfix-staging), while strictly preserving legacy 'us-central1' for production
(tekfix-45b38). All 136 empirical automated, unit, accounting, and adversarial
tests passed with zero regressions. Zero deployments occurred.
================================================================================
```

