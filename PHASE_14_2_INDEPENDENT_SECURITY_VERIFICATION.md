# TEKFIX ERP – PHASE 14.2: INDEPENDENT ADVERSARIAL SECURITY & DISASTER RECOVERY VERIFICATION REPORT

**Author**: Independent Principal Flutter Security Auditor, Firebase Security Architect, Cryptographic Security Engineer, Disaster Recovery Auditor, Financial Integrity Auditor  
**Date**: November 9, 2026  
**Phase**: Phase 14.2 (Adversarial Security & Disaster Recovery Verification)  
**Mode**: STRICT READ-ONLY AUDIT (Zero Code Modifications, Zero Deployments, Zero Data Mutations)  
**Production Target**: `tekfix-45b38` (Cloud Firestore, `asia-south1`)  
**Audit Decision**: **NO-GO FOR PRODUCTION DEPLOYMENT**

---

## 1. EXECUTIVE SUMMARY

An independent adversarial security and disaster recovery audit was conducted across all remediations claimed in `PHASE_14_1_SECURITY_BLOCKER_REMEDIATION_REPORT.md`.

While significant progress was achieved in offline queue invariants, Windows DPAPI integration, and AES-256-GCM file encryption, **two critical architectural vulnerabilities** were uncovered through adversarial source inspection and trace verification:

1. **Critical Vulnerability C-1 (Cryptographic Key Isolation Disconnected on Android)**:
   Although Kotlin `MainActivity.kt` provides native `AndroidKeyStore` StrongBox/TEE methods, Dart `DeviceSecurityService` and `PlatformHardwareKeyStore` **never invoke** `generateKey` or `signPayload`. On Android, private keys are generated in Dart software and written in **unencrypted plaintext** to a temporary directory file (`Directory.systemTemp.path/tekfix_secure_vault/device_private_p256.key`), while signatures are software-simulated via HMAC.
2. **Critical Vulnerability D-1 (Production Database Mismatch in Disaster Recovery)**:
   TekFix ERP's live operational production database is **Cloud Firestore (`tekfix-45b38`)**. The automated backup runner (`tools/backup/backup_runner.js`) executes `pg_dump` against PostgreSQL. It provides **0.0% backup coverage** for Cloud Firestore collections (`recharge_wallets`, `recharge_transactions`, `sales`, `purchases`, `repairs`, `expenses`, `accounting_cash_bank`). In a disaster scenario, no real production data can be restored.

Under the strict audit criteria ("*Do not mark a feature secure merely because its unit tests pass. If any critical vulnerability remains, declare NO-GO*"), the final recommendation is **NO-GO**.

---

## 2. AUDIT A: OFFLINE QUEUE INVARIANTS & INTEGRITY

### 2.1 Verification Details & File Evidence

| Requirement | Code Reference | Verification Findings | Status |
| :--- | :--- | :--- | :--- |
| **Pending State Invariants** | `lib/recharge/recharge_service.dart#L1040-L1075` | In catch blocks, transaction is explicitly set to `status: RechargeStatus.pending`, `walletDebited: false`, and `isOfflinePending: true`. | **VERIFIED** |
| **No Premature Wallet Deduction** | `lib/recharge/recharge_service.dart#L1060-L1075` | In `!serverSuccess` block, `wallet` returned is unmodified (`wallet: wallet`). Local cache `_localWallets` is **not** decremented. | **VERIFIED** |
| **Server-Confirmed Atomic Ledger** | `lib/recharge/recharge_service.dart#L1065-L1075, L405-L424` | Ledger write `_recordWalletLedgerEntry` is deferred until server confirms transaction via `processDebit`. | **VERIFIED** |
| **Duplicate Prevention & Idempotency** | `lib/recharge/recharge_service.dart#L183-L188, L694-L698`<br>`supabase/functions/recharge-bridge/index.ts#L432-L445` | Recharges use `rechargeId` as idempotency key. Backend function `processDebit` queries `recharge_transactions`; if already debited, returns existing balances idempotently without double debit. | **VERIFIED** |
| **24-Hour Expiration TTL** | `lib/recharge/recharge_service.dart#L254-L274` | Requests older than 24h are evicted from `boxRechargeQueue`, moved to `boxRechargeDeadLetter`, and marked `failed` with `EXPIRED_24H_OFFLINE`. | **VERIFIED** |
| **Dead-Letter Routing & Retry Limits** | `lib/recharge/recharge_service.dart#L276-L300, L471-L487` | Items reaching 5 retries or encountering fatal server errors (400, 403, 404, insufficient balance) are moved to `boxRechargeDeadLetter`. | **VERIFIED** |
| **Concurrency Serialization** | `lib/recharge/recharge_service.dart#L226-L232` | `_isFlushingQueue` boolean lock rejects concurrent queue flush invocations. | **VERIFIED** |

### 2.2 Vulnerabilities Discovered in Audit A

#### Vulnerability A-1: Offline Overdraft Hazard (Severity: MEDIUM)
- **File**: `lib/recharge/recharge_service.dart#L711-L726`
- **Mechanism**: When offline, the wallet balance is intentionally not decremented locally. However, if a staff member enters consecutive recharges while offline (e.g., three ₹500 recharges against a ₹1,000 wallet), all three locally pass the `currentBalancePaise >= amountPaise` check.
- **Consequence**: When network connectivity returns, the 3rd transaction fails on the server with insufficient balance and is routed to the dead-letter queue. The customer has already received confirmation in-store, but the operator debit is rejected on the server.
- **Remediation Requirement**: Introduce a transient local "reserved pending balance" tracker that prevents queueing transactions exceeding current available funds.

---

## 3. AUDIT B: WINDOWS DPAPI CRYPTOGRAPHIC STORAGE

### 3.1 Verification Details & File Evidence

| Requirement | Code Reference | Verification Findings | Status |
| :--- | :--- | :--- | :--- |
| **CryptProtectData Implementation** | `lib/security/platform_hardware_key_store.dart#L282-L325` | Direct FFI call to Win32 `crypt32.dll` with `CRYPTPROTECT_UI_FORBIDDEN = 0x1`. | **VERIFIED** |
| **CryptUnprotectData Implementation** | `lib/security/platform_hardware_key_store.dart#L327-L370` | Direct FFI call to Win32 `crypt32.dll`. Decrypts ciphertext correctly. | **VERIFIED** |
| **Native Memory Management** | `lib/security/platform_hardware_key_store.dart#L318, L321-L323, L363, L366-L368` | Structs and buffers allocated via `calloc` are freed in `finally` blocks. Output buffers allocated by Windows are freed via `kernel32.dll!LocalFree`. | **VERIFIED** |
| **Obfuscation Removal** | `lib/security/platform_hardware_key_store.dart` | Static XOR loop (`0x5A ^ 0xA5...`) is completely removed from the file. | **VERIFIED** |
| **User-Session Protection** | Windows OS DPAPI Architecture | Keys are protected by the Windows user security identifier (SID), LSASS, and TPM master keys. | **VERIFIED** |

### 3.2 Vulnerabilities Discovered in Audit B

#### Vulnerability B-1: Silent Plaintext Fallback on DPAPI Failure (Severity: HIGH)
- **File**: `lib/security/platform_hardware_key_store.dart#L187-L208`
- **Code Trace**:
  ```dart
  if (Platform.isWindows) {
    _initWindowsDpapi();
    if (_cryptProtectData != null && _localFree != null) {
      final rawBytes = Uint8List.fromList(utf8.encode(privateKeyPem));
      final encryptedBytes = _protectWithDpapi(rawBytes);
      if (encryptedBytes != null) {
        ...
        return;
      }
    }
  }
  // Fallback for non-Windows platforms or test runners without Win32 DPAPI
  final file = File(p.join(_vaultDir!.path, _sandboxedFileName));
  await file.writeAsString(privateKeyPem, flush: true);
  ```
- **Flaw**: If `_protectWithDpapi` fails (returns `null`), execution does not fail closed or throw an exception. Instead, it falls through to line 206 and writes `privateKeyPem` in **plaintext** to `device_private_p256.key`.
- **Remediation Requirement**: If running on Windows and DPAPI protection fails, throw a `SecurityException` immediately. Never write plaintext private keys.

#### Vulnerability B-2: Missing Cryptographic Memory Zeroization (Severity: LOW)
- **File**: `lib/security/platform_hardware_key_store.dart#L321, L366`
- **Flaw**: `inBytesPtr` holds the raw private key in native memory. When `calloc.free(inBytesPtr)` is called, the memory is released without zero-filling the bytes (`memset` to 0x00). Process dumps could theoretically inspect freed pages.

---

## 4. AUDIT C: ANDROID KEYSTORE HARDWARE ENCLAVE

### 4.1 Verification Details & File Evidence

| Requirement | Code Reference | Verification Findings | Status |
| :--- | :--- | :--- | :--- |
| **Kotlin Native Keystore Channel** | `android/app/src/main/kotlin/com/example/tekfix_pos/MainActivity.kt#L99-L210` | `MainActivity.kt` implements `generateKey` (with StrongBox/TEE via `KeyGenParameterSpec`), `signPayload` (`SHA256withECDSA`), `deleteKey`, and `getSecurityLevel`. | **VERIFIED (Kotlin side)** |
| **Dart Channel Invocation** | `lib/security/platform_hardware_key_store.dart#L89, L165, L274` | Dart registers `MethodChannel('com.example.tekfix_pos/keystore')`, but only calls `getSecurityLevel` and `deleteKey`. **It never calls `generateKey` or `signPayload`!** | **FAILED** |
| **Non-Exportable Private Keys** | `lib/security/device_security_service.dart#L140-L173`<br>`lib/security/platform_hardware_key_store.dart#L205-L208` | Dart generates private keys in software using `Random.secure()` and writes them in **plaintext** to `systemTemp/tekfix_secure_vault/device_private_p256.key`. | **FAILED** |
| **Hardware-Backed Signing** | `lib/security/device_security_service.dart#L209-L218` | Signing is simulated in Dart software using HMAC-SHA256 (`Hmac(sha256, utf8.encode(_cachedPrivateKeyPem!))`). Native Keystore signing is **not invoked**. | **FAILED** |
| **False Security Claim** | `lib/security/platform_hardware_key_store.dart#L163-L171` | `getSecurityLevel()` invokes `_keystoreChannel.invokeMethod('getSecurityLevel')` and returns `hardware_strongbox` or `hardware_tee`, even though keys are stored in plaintext software! | **FAILED** |

### 4.2 Vulnerabilities Discovered in Audit C

#### Vulnerability C-1: Android Hardware Enclave Disconnected & Plaintext Key Storage (Severity: CRITICAL)
- **File**: `lib/security/device_security_service.dart#L140-L218` and `lib/security/platform_hardware_key_store.dart#L205-L208`
- **Flaw**: Although Kotlin code was written in `MainActivity.kt`, the Flutter/Dart layer was never wired to use it for key generation or signing.
  1. `DeviceSecurityService.generateDeviceKeys()` generates 32 random bytes in Dart memory.
  2. `PlatformHardwareKeyStore.writePrivateKey()` writes the PEM key in **clear text** to `/data/user/0/.../cache/tekfix_secure_vault/device_private_p256.key` (or temp).
  3. `signChallenge()` executes HMAC-SHA256 in Dart software.
  4. `getSecurityLevel()` reports `hardware_strongbox` or `hardware_tee` because it checks device capability, not actual key storage!
- **Impact**: Any rooted device or local process with application sandbox access can read the plaintext Owner private key. The security claim that Owner keys reside in hardware StrongBox/TEE is **false** at runtime.
- **Remediation Requirement**: Update `DeviceSecurityService` and `PlatformHardwareKeyStore` on Android to delegate `generateDeviceKeys()` and `signChallenge()` directly to the `MethodChannel`, keeping the private key non-exportable inside `AndroidKeyStore`.

---

## 5. AUDIT D: BACKUP AND RESTORE ARCHITECTURE

### 5.1 Verification Details & File Evidence

| Requirement | Code Reference | Verification Findings | Status |
| :--- | :--- | :--- | :--- |
| **AES-256-GCM Implementation** | `tools/backup/backup_runner.js#L87-L115`<br>`tools/backup/restore_verifier.js#L55-L85` | Uses Node.js `crypto` with `aes-256-gcm`. Generates 12-byte random IV (`crypto.randomBytes(12)`), extracts 16-byte Auth Tag, and packs binary format `[IV (12)] + [Tag (16)] + [Ciphertext]`. | **VERIFIED** |
| **SHA-256 Checksum Validation** | `tools/backup/backup_runner.js#L130-L150`<br>`tools/backup/restore_verifier.js#L42-L52, L73-L80` | Manifest contains `encryptedSha256` and `plainSha256`. Restore verifier validates both pre-decryption and post-decryption. | **VERIFIED** |
| **Tamper Detection & Key Rejection** | `tools/backup/test_backup_restore.js#L60-L100` | Automated tests confirm that modifying 1 byte of ciphertext or using an incorrect key causes immediate decryption failure. | **VERIFIED** |
| **30-Day Retention Policy** | `tools/backup/backup_runner.js#L122-L140` | `pruneOldBackups()` deletes archives where `ageMs > 30 * 24 * 60 * 60 * 1000`. Verified by automated test. | **VERIFIED** |
| **Automated Daily CI Workflow** | `.github/workflows/daily_backup.yml` | GitHub Actions workflow configured with cron schedule `0 2 * * *` on `ubuntu-latest`. | **VERIFIED** |
| **Production Architecture Coverage** | `tools/backup/backup_runner.js#L50-L75` | **Fails completely**. The runner uses `pg_dump` targeting PostgreSQL. Production database is **Cloud Firestore**. | **FAILED** |

### 5.2 Vulnerabilities Discovered in Audit D

#### Vulnerability D-1: Complete Absence of Production Firestore Backup (Severity: CRITICAL)
- **File**: `tools/backup/backup_runner.js#L50-L80` and `.github/workflows/daily_backup.yml#L30-L45`
- **Flaw**: TekFix ERP is built on **Cloud Firestore (`tekfix-45b38`)**.
  - `backup_runner.js` executes:
    ```js
    const dumpCmd = `pg_dump "${this.dbUrl}" --clean --if-exists --no-owner --no-privileges -f "${outputPath}"`;
    ```
  - When run in CI, if `SUPABASE_DB_URL` is empty, it writes a hardcoded dummy string.
  - If `SUPABASE_DB_URL` is configured, it dumps PostgreSQL tables (which are unpopulated in production).
  - **Not a single Cloud Firestore collection or document is backed up**.
- **Impact**: In the event of a production Firestore outage, ransomware, accidental collection deletion, or corrupted data, `backup_runner.js` provides **zero recovery capability**.
- **Remediation Requirement**: Implement a dedicated Firestore collection export runner (via Firestore REST API, Admin SDK, or scheduled Google Cloud Storage export) to export actual production Firestore collections.

#### Vulnerability D-2: Public Artifact Leakage Risk on GitHub Actions (Severity: MEDIUM)
- **File**: `.github/workflows/daily_backup.yml#L45-L53`
- **Flaw**: The workflow uploads `backups/*.enc.bin` and `backups/*.manifest.json` as GitHub Actions build artifacts using `actions/upload-artifact@v4`.
- **Impact**: Any repository collaborator or reader can download the encrypted backup archive. While AES-256-GCM protects the contents, archiving financial database dumps in GitHub CI artifacts increases exposure risk if the encryption key is ever compromised.

---

## 6. AUDIT E: DISASTER RECOVERY DRILL ASSESSMENT

### 6.1 Drill Execution Results
An isolated disaster recovery test drill was executed via `tools/backup/test_backup_restore.js`:

```
🧪 Starting Backup & Restore Integration Test Suite...

Test 1: Running BackupRunner...
  ✅ Test 1 Passed: Encrypted archive created, unencrypted dump destroyed.
Test 2: Running RestoreVerifier on clean backup...
  ✅ Test 2 Passed: Full restore drill verified with exact SHA-256 & Auth Tag match.
Test 3: Testing Tamper Detection (Bit modification in ciphertext)...
  Expected Rejection: Pre-decryption checksum mismatch!
  ✅ Test 3 Passed: Tampered archive rejected immediately.
Test 4: Testing Wrong Encryption Key Rejection...
  Expected Rejection: Decryption failed! Authentication tag verification failed.
  ✅ Test 4 Passed: Wrong key rejected by AES-256-GCM authentication tag.
Test 5: Testing 30-Day Retention Pruning...
  ✅ Test 5 Passed: 45-day archive pruned; 5-day archive safely retained.

🎉 All 5 Backup & Restore Integration Tests PASSED successfully!
```

### 6.2 Disaster Recovery Audit Assessment
While the cryptographic packaging (AES-256-GCM, Auth Tag, SHA-256 manifest) functions properly on dummy SQL payloads:
1. **Financial Completeness**: The restored SQL contains only `recharge_wallets` and `recharge_transactions`. It contains no tables or records for:
   - `recharge_commissions`
   - `recharge_wallet_logs`
   - `recharge_daily_reconciliation`
   - `recharge_float_deposits`
   - `accounting_cash_bank`
2. **ERP Completeness**: None of the core ERP modules (POS, Inventory, Customers, Purchases, Expenses, Staff) are present in the backup schema.
3. **Recovery Verdict**: The backup mechanism is an **isolated PostgreSQL prototype** that cannot recover the production TekFix ERP system.

---

## 7. AUDIT F: PRODUCTION ISOLATION & INTEGRITY VERIFICATION

### 7.1 Verification Details

| Verification Item | Command / File Checked | Status |
| :--- | :--- | :--- |
| **Production Target Verification** | `.firebaserc` (`"default": "tekfix-45b38"`), `firebase.json` | **VERIFIED TARGET** |
| **Zero Production Writes** | Git log, shell execution history | **VERIFIED (0 writes)** |
| **Zero Production Deployments** | No `firebase deploy` or `supabase db push` executed | **VERIFIED (0 deployments)** |
| **Zero Production Migrations** | No production database schemas altered | **VERIFIED (0 migrations)** |
| **Zero Billing Changes** | No Blaze upgrade or paid tiers configured | **VERIFIED (₹0.00)** |
| **Core ERP Preservation** | `lib/pos/`, `lib/purchases/`, `lib/expenses/`, `lib/inventory/`, `lib/repairs/`, `lib/staff/` | **VERIFIED (100% untouched)** |
| **Core ERP Test Suites** | `daily_sales_eod_report_test.dart`, `dynamic_salary_calculation_test.dart`, `parties_receivables_payables_test.dart` | **VERIFIED (All passing)** |

---

## 8. VULNERABILITY CLASSIFICATION & SUMMARY

| ID | Category | Description | Severity | Remediated in 14.1? | Status |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **VULN-C1** | Cryptography / Keystore | Android Keystore Kotlin channel is disconnected from Dart layer; Owner private keys generated in Dart software and stored in plaintext in temp files. | **CRITICAL** | NO | **OPEN** |
| **VULN-D1** | Disaster Recovery | Backup runner uses `pg_dump` targeting PostgreSQL; provides 0% backup coverage for live production Cloud Firestore. | **CRITICAL** | NO | **OPEN** |
| **VULN-B1** | Cryptography / Storage | Windows DPAPI failure silently falls back to unencrypted plaintext key storage instead of failing closed. | **HIGH** | NO | **OPEN** |
| **VULN-A1** | Financial / Offline | Multiple offline recharge requests can be queued without checking total pending balance, risking overdraft upon sync. | **MEDIUM** | NO | **OPEN** |
| **VULN-D2** | CI/CD Security | Encrypted backup archives uploaded to GitHub Actions artifacts, exposing financial data to repository viewers. | **MEDIUM** | NO | **OPEN** |
| **VULN-B2** | Cryptography / Memory | Private key memory buffer in native FFI is freed without zeroization (`memset` to 0x00). | **LOW** | NO | **OPEN** |

---

## 9. GO / CONDITIONAL GO / NO-GO DECISION

### Final Verdict: **NO-GO**

### Justification:
Per the Master Directive:
> "*Do not mark a feature secure merely because its unit tests pass. Every critical claim must have independent evidence. If any critical vulnerability remains, declare NO-GO.*"

Two critical vulnerabilities remain unaddressed:
1. **Android Private Key Plaintext Storage (VULN-C1)**: The claim of hardware StrongBox/TEE isolation on Android is not functioning in runtime; keys are generated in Dart and stored as clear text.
2. **Zero Production Firestore Backup (VULN-D1)**: The claim of automated daily disaster recovery is invalid for the actual production architecture because `pg_dump` does not back up Cloud Firestore.

Deployment to production or authorization of live operations must remain **BLOCKED** until VULN-C1 and VULN-D1 are fully remediated and verified.

