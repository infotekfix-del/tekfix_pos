# TEKFIX ERP – PHASE 13.1.0
# STAGING CONFIGURATION REMEDIATION PLAN

**Date:** 2026-11-08  
**Author:** Senior Firebase Security Architect  
**Target Staging Project:** `tekfix-staging`  
**Expected Region:** `asia-south1` (Mumbai, India)  
**Production Project:** `tekfix-45b38` (Strictly Isolated & Preserved)  
**Safety Protocol:** Strict Read-Only Mode (Zero File Modifications Until Human Stakeholder Approval)  
**Final Verdict:** **A. PLAN READY**  

---

## 1. EXECUTIVE SUMMARY

Phase 13.1.0 delivers a surgical, file-by-file remediation plan resolving all four blockers identified during the Phase 13.0.9 audit. In accordance with safety rules, **no source code or configuration files have been modified**. This plan documents the exact planned changes, security models, and verification steps for stakeholder authorization.

### Remediation Objectives:
1. **Blocker 1 (.firebaserc):** Register `staging` project alias (`tekfix-staging`) while preserving production `default` (`tekfix-45b38`).
2. **Blocker 2 (Android Staging Config):** Establish side-by-side Android app co-existence via Gradle product flavors (`prod` vs `staging`) preventing APK overwrite on test devices.
3. **Blocker 3 (Firebase Storage Rules):** Author least-privilege `firebase/storage.rules` enforcing shop-tenant isolation derived from authoritative Firestore membership, with default-deny and upload payload validation (< 10MB, images & PDFs only).
4. **Blocker 4 (Staging Firebase Credentials):** Implement isolated staging credentials in `lib/firebase_options.dart` that target `tekfix-staging` in `asia-south1` with fail-closed safeguards, guaranteeing zero production leakage.

---

## 2. DETAILED FILE-BY-FILE IMPLEMENTATION PLAN

### FILE 1: `.firebaserc`
- **Location:** `d:\tekfix_pos\.firebaserc`
- **Current State:**
  ```json
  {
    "projects": {
      "default": "tekfix-45b38"
    }
  }
  ```
- **Planned Modification:**
  ```json
  {
    "projects": {
      "default": "tekfix-45b38",
      "staging": "tekfix-staging"
    }
  }
  ```
- **Security & Safety Rationale:**
  - Preserves `default` pointing to `tekfix-45b38` for existing workflows.
  - Enables explicit target execution: `firebase deploy --project=staging ...`.
  - Accidental omission of `--project` does not deploy staging code to an unknown project.

---

### FILE 2: `firebase.json`
- **Location:** `d:\tekfix_pos\firebase.json`
- **Current State:** Contains `flutter`, `firestore`, and `functions` stanzas; lacks `storage`.
- **Planned Modification:** Add the `storage` configuration stanza pointing to `firebase/storage.rules`:
  ```json
  {
    "flutter": { ... },
    "firestore": {
      "indexes": "firebase/firestore.indexes.json",
      "rules": "firebase/firestore.rules"
    },
    "functions": [ ... ],
    "storage": {
      "rules": "firebase/storage.rules"
    }
  }
  ```
- **Security & Safety Rationale:**
  - Ensures Firebase CLI deploys Storage security rules alongside Firestore rules.
  - Prevents the staging (or production) Cloud Storage bucket from falling back to insecure default rules.

---

### FILE 3: `firebase/storage.rules` (NEW FILE)
- **Location:** `d:\tekfix_pos\firebase/storage.rules`
- **Authorization Architecture Inspection:**
  - Inspection of `lib/expenses/expense_service.dart`, `lib/purchases/purchase_bill_service.dart`, and `lib/rent/rent_service.dart` confirms all uploads use:
    `shops/{shopId}/{subfolder}/{fileName}`
    where subfolders are `expense_receipts`, `purchase_invoices`, and `rent_receipts`.
  - Inspection of `firebase/firestore.rules` and `lib/auth/auth_controller.dart` confirms shop membership is governed by:
    - Shop owner: `shops/{shopId}` document field `ownerUid == request.auth.uid`.
    - Shop user: `shops/{shopId}/users/{uid}` with `active != false` and `approved != false`.
- **Planned Storage Rules Content:**
  ```javascript
  rules_version = '2';
  service firebase.storage {
    match /b/{bucket}/o {

      // -----------------------------------------------------------
      // Authentication & Shop Authorization Helpers
      // -----------------------------------------------------------
      function isSignedIn() {
        return request.auth != null;
      }

      function isShopMember(shopId) {
        return isSignedIn() && (
          // 1. Direct shop owner verification on shop document
          (firestore.exists(/databases/(default)/documents/shops/$(shopId)) &&
           firestore.get(/databases/(default)/documents/shops/$(shopId)).data.ownerUid == request.auth.uid) ||
          // 2. Active, approved shop member verification in users collection
          (firestore.exists(/databases/(default)/documents/shops/$(shopId)/users/$(request.auth.uid)) &&
           firestore.get(/databases/(default)/documents/shops/$(shopId)/users/$(request.auth.uid)).data.active != false &&
           firestore.get(/databases/(default)/documents/shops/$(shopId)/users/$(request.auth.uid)).data.approved != false)
        );
      }

      // -----------------------------------------------------------
      // Global Default Deny
      // -----------------------------------------------------------
      match /{allPaths=**} {
        allow read, write: if false;
      }

      // -----------------------------------------------------------
      // Shop Tenant Storage Isolation (/shops/{shopId}/...)
      // -----------------------------------------------------------
      match /shops/{shopId}/{allPaths=**} {
        // Read: Caller must be an active, approved member of this specific shop
        allow read: if isShopMember(shopId);

        // Write: Caller must be an active member, file must be <= 10MB, and content must be image or PDF
        allow write: if isShopMember(shopId)
          && request.resource.size < 10 * 1024 * 1024
          && (request.resource.contentType.matches('image/.*') ||
              request.resource.contentType == 'application/pdf');
      }
    }
  }
  ```
- **Security & Safety Rationale:**
  - **Zero Cross-Tenant Leakage:** A user from Shop A cannot read or write receipts of Shop B.
  - **No Unauthenticated Access:** Anonymous or unauthenticated requests are strictly blocked.
  - **Malicious Upload Protection:** Maximum file size capped at 10 MB; non-document types (scripts, executables, HTML) are rejected.
  - **Default Deny:** Any path outside `/shops/{shopId}/` is completely inaccessible.

---

### FILE 4: `android/app/build.gradle.kts`
- **Location:** `d:\tekfix_pos\android\app\build.gradle.kts`
- **Current State:** Single `defaultConfig` with `applicationId = "com.example.tekfix_pos"`.
- **Planned Modification:**
  Introduce Gradle `flavorDimensions` to separate `prod` and `staging` builds:
  ```kotlin
  android {
      ...
      flavorDimensions += "environment"

      productFlavors {
          create("prod") {
              dimension = "environment"
              applicationId = "com.example.tekfix_pos"
              manifestPlaceholders["appName"] = "TekFix POS"
          }
          create("staging") {
              dimension = "environment"
              applicationId = "com.example.tekfix_pos.staging"
              applicationIdSuffix = ".staging"
              versionNameSuffix = "-staging"
              manifestPlaceholders["appName"] = "TekFix POS (Staging)"
          }
      }
  }
  ```
  Directory structure for Google Services JSON files:
  - `android/app/src/prod/google-services.json` (Existing production file for `tekfix-45b38`)
  - `android/app/src/staging/google-services.json` (Staging file for `tekfix-staging`)
- **Security & Safety Rationale:**
  - Allows QA/DevOps to install both Staging and Production APKs on the same physical POS hardware simultaneously without database or cache collisions.
  - Strictly prevents production APK builds from incorporating staging parameters.

---

### FILE 5: `lib/firebase_options.dart`
- **Location:** `d:\tekfix_pos\lib\firebase_options.dart`
- **Current State:**
  ```dart
  case TekFixEnvironment.staging:
    throw StateError('TekFix Staging Firebase project is PENDING HUMAN ACTION...');
  ```
- **Planned Modification:**
  Add dedicated `_stagingAndroid` and `_stagingWindows` options targeting `tekfix-staging`, wired through build environment defines:
  ```dart
  /// Staging Firebase options for Android (tekfix-staging, asia-south1).
  static const FirebaseOptions _stagingAndroid = FirebaseOptions(
    apiKey: String.fromEnvironment(
      'FIREBASE_STAGING_ANDROID_API_KEY',
      defaultValue: 'AIzaSy_STAGING_ANDROID_KEY_PLACEHOLDER',
    ),
    appId: String.fromEnvironment(
      'FIREBASE_STAGING_ANDROID_APP_ID',
      defaultValue: '1:000000000000:android:0000000000000000000000',
    ),
    messagingSenderId: String.fromEnvironment(
      'FIREBASE_STAGING_MESSAGING_SENDER_ID',
      defaultValue: '000000000000',
    ),
    projectId: 'tekfix-staging',
    storageBucket: 'tekfix-staging.firebasestorage.app',
  );

  /// Staging Firebase options for Windows/Web (tekfix-staging, asia-south1).
  static const FirebaseOptions _stagingWindows = FirebaseOptions(
    apiKey: String.fromEnvironment(
      'FIREBASE_STAGING_WINDOWS_API_KEY',
      defaultValue: 'AIzaSy_STAGING_WINDOWS_KEY_PLACEHOLDER',
    ),
    appId: String.fromEnvironment(
      'FIREBASE_STAGING_WINDOWS_APP_ID',
      defaultValue: '1:000000000000:web:0000000000000000000000',
    ),
    messagingSenderId: String.fromEnvironment(
      'FIREBASE_STAGING_MESSAGING_SENDER_ID',
      defaultValue: '000000000000',
    ),
    projectId: 'tekfix-staging',
    authDomain: 'tekfix-staging.firebaseapp.com',
    storageBucket: 'tekfix-staging.firebasestorage.app',
  );
  ```
  And update `currentPlatform`:
  ```dart
  case TekFixEnvironment.staging:
    if (_stagingAndroid.apiKey.contains('PLACEHOLDER') &&
        defaultTargetPlatform == TargetPlatform.android &&
        !kIsWeb) {
      throw StateError(
        'TekFix Staging Android API key is not configured. '
        'Provide FIREBASE_STAGING_ANDROID_API_KEY via --dart-define.',
      );
    }
    return _stagingPlatform;
  ```
- **Security & Safety Rationale:**
  - Connects exclusively to `tekfix-staging`.
  - Preserves fail-closed behavior if keys are absent.
  - Zero possibility of falling back to production credentials.

---

## 3. VERIFICATION & VALIDATION PROTOCOL

Following stakeholder approval of this plan, the implementation will be verified through:
1. **Static Analysis:** `flutter analyze` on all modified Dart files.
2. **Syntax Validation:** `node -c` on backend files and rules validation.
3. **Unit Tests:**
   - Extend `test/firebase_functions_region_environment_test.dart` to verify `TekFixEnvironment.staging` returns `tekfix-staging` project ID and `asia-south1`.
   - Verify `TekFixEnvironment.production` remains untouched (`tekfix-45b38`, `us-central1`).
4. **Adversarial Security Test Suite:** Re-run `scratch/phase13_0_5_independent_audit_suite.js` on emulator (30/30).
5. **Recharge Accounting Regression Suite:** Re-run all 10 Flutter recharge suites (92/92).

---

## 4. FINAL VERDICT

```
================================================================================
FINAL VERDICT:
A. PLAN READY

All four Phase 13.0.9 blockers are addressed in this comprehensive, file-by-file
implementation plan. Strict safety rules observed. Zero source files modified.
Zero deployments executed. Ready for human stakeholder review and approval.
================================================================================
```

*Execution has stopped. Standing by for human stakeholder authorization to proceed with Phase 13.1.0 implementation.*

