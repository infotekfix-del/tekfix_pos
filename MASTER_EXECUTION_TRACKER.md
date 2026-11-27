# TEKFIX ERP — MASTER EXECUTION TRACKER
## ISOLATED RECHARGE ACCOUNTING & CONTROLLED PRODUCTION LAUNCH

**Project:** TekFix ERP (Flutter Retail ERP + Isolated Supabase PostgreSQL Recharge Backend)  
**Target Production Firebase:** `tekfix-45b38` (Strictly **UNTOUCHED**, ₹0.00 Budget Preserved)  
**Target Staging Supabase:** `tekfix-recharge-staging` (Free Tier, `ap-south-1` Mumbai, Ref: `mwhsvidbrfkryuiwhnev`)  
**Last Updated:** 2026-11-11  

---

### CURRENT EXECUTION STATUS

```
================================================================================
STATUS: PHASE 16.4.3 FINAL UAT READINESS & SECURITY GAPS REMEDIATION (CONDITIONAL PASS)
        SECRET SANITIZATION:    100% SCRUBBED across all test harnesses (0 hardcoded secrets)
        GIT HISTORY AUDIT:      PASS (0 occurrences in git commit history; tools/ untracked)
        REMOTE VAULT ROTATION:  BLOCKED (Awaiting explicit owner approval per safety rules)
        OLD KEY INVALIDATION:   NOT VERIFIED (Awaiting remote rotation execution)
        ANDROID STAGING APK:    Output\staging_uat_phase16_4_3\app-staging-release.apk (75.5 MB)
        APK VERSION / CODE:     1.0.29-staging / Version Code 29 (In-Place Upgrade Verified)
        APK SHA-256 (16.4.3):   A7F0938AF863A987E490C66C234A7E7088F901074452B603B54E39BE7A262B9A
        APK SHA-256 (16.4.2):   FCF72C179AFFCC93FD8EA5890D90043D0A7DBF0C5C2EED99648DF9D9B6372124 (Preserved)
        APK SHA-256 (16.2):     A9AD2510EB631C1EE55FF10E19FECBE028898D925F24F0BDCBA15BB4DE3DAC29 (Preserved)
        SIGNING CERTIFICATE:    dccb3155...6dc8 (100% Match across all builds)
        WINDOWS RUNNER EXE:     build\windows\x64\runner\Release\tekfix_pos.exe (15.2 MB)
        WINDOWS AOT SNAPSHOT:   build\windows\x64\runner\Release\data\app.so (13.6 MB)
        WINDOWS DPAPI:          PASS (Native crypt32.dll FFI round-trip verified)
        WINDOWS TPM:            NOT VERIFIED (Requires Windows Administrator elevation)
        ANDROID HW KEYSTORE:    NOT VERIFIED (0 physical ADB devices attached)
        CLOUD BACKUP RESTORE:   BLOCKED (No separate staging DB instance; safety rule against overwriting)
        LOCAL BACKUP & RESTORE: PASS (Local Hive 5-entity restore 100% verified; pg_dump runner verified)
        ADVERSARIAL CRASHES:    PASS (5 / 5 crash scenarios auto-reconciled with 0 ledger drift)
        FINANCIAL INTEGRITY:    PASS (Db.sales = ₹0.00; missing customer -> MANUAL_REVIEW_REQUIRED)
        SERVER AUTHORIZATION:   PASS (Live Supabase Edge Function HTTP 401/403 logs documented)
        PRODUCTION FIREBASE:    tekfix-45b38 STRICTLY UNTOUCHED (₹0.00 Cost, 0 Reads, 0 Writes)
        STATIC ANALYSIS:        0 compilation errors (Clean baseline)
================================================================================
Application Architecture:  ONE Unified Flutter ERP (d:\tekfix_pos)
Primary Entry Point:       lib/main.dart (Single App, No Duplicate APK)
Core Retail POS Backend:   Production Firebase Spark Plan tekfix-45b38 (UNTOUCHED / INACTIVE IN UAT)
Recharge Staging Backend:  Isolated Supabase PostgreSQL (mwhsvidbrfkryuiwhnev, ap-south-1 Mumbai)
Android Staging APK:       Output\staging_uat_phase16_4_3\app-staging-release.apk (75.5 MB)
Windows Desktop Binary:    build\windows\x64\runner\Release\tekfix_pos.exe (15.2 MB)
Windows Desktop AOT:       build\windows\x64\runner\Release\data\app.so (13.6 MB)
================================================================================
```

---

### INDEPENDENT PRE-FLIGHT AUDIT MATRIX

| Audit Gate | Scope | Verification Detail | Status |
|:---|:---|:---|:---:|
| **1. Independent Pin in staging.local.json** | Configuration | Exclusively loaded from gitignored `staging.local.json` | **VERIFIED** |
| **2. Pinned Reference 3-Condition Gate** | Security Gate | Strict equality: CLI `-ProjectRef` == Local JSON == Live ID (`mwhsvidbrfkryuiwhnev`) | **VERIFIED** |
| **3. Mismatch & Malformation Rejection**| Security Gate | Rejects wrong refs, regions, placeholders, duplicates | **VERIFIED** |
| **4. Cryptographic Secret Hygiene** | Cryptography | CSPRNG 256-bit secret stored in remote vault; local RNG disposed & zeroized | **VERIFIED** |
| **5. Smoke Test Purity** | Testing | 10/10 vectors passed against live Edge Function with 0 financial modifications | **VERIFIED** |
| **6. Remote PostgreSQL ACID & Financial** | Testing | 13/13 financial tests passed live on remote PostgreSQL 17 | **VERIFIED** |
| **7. Automated Regression Suite** | Quality Assurance | 751/751 Tests Passed (Exit code 0). 100% Pass Rate across 17 suites | **VERIFIED** |
| **8. Production Boundary Isolation** | Operations | Production commands omitted; Firebase `tekfix-45b38` 100% untouched | **VERIFIED** |
| **9. Staging Cloud Provisioning (15.1)**| Remote Cloud | Linked, migrated, vaulted secrets set, function deployed | **COMPLETE** |
| **10. Emergency Device Recovery (15.4.2)**| Security Audit | Allowlist, single-use ticket lifecycle, routine permissions, 12 attack tests | **VERIFIED** |
| **11. Physical Device Pairing (15.3)** | Real Devices | Android Phone (TEE) + Windows Laptop (DPAPI) Pairing | **GATED FOR OWNER** |
| **12. Production Launch (16.0)** | Live Production | Separate future owner-authorized activity | **GATED FOR OWNER** |

---

### DETAILED TEST SUITE EXECUTION METRICS (RECONCILED: 751 EXECUTIONS / 751 UNIQUE TESTS)

| Test Suite Category | Framework | Command | Executions | Unique Tests | Passing | Failing | Exit Code | Result |
|:---|:---|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Flutter ERP Core Suite** | Flutter Test | `flutter test` (entire test directory) | 439 | 439 | 439 | 0 | 0 | **PASS** |
| **Phase 15.4.2 Emergency Recovery Security** | Node.js | `node tools/staging/test_phase15_4_2_emergency_recovery_adversarial.js` | 33 | 33 | 33 | 0 | 0 | **PASS** |
| **Phase 15.4.1 Permanent Lockout Audit** | Node.js | `node tools/staging/test_phase15_4_1_permanent_bootstrap_lockout.js` | 17 | 17 | 17 | 0 | 0 | **PASS** |
| **Phase 15.4 Integrated Acceptance Audit** | Node.js | `node tools/staging/test_phase15_4_integrated_acceptance.js` | 31 | 31 | 31 | 0 | 0 | **PASS** |
| **Phase 15.3 Remote Staging Financials** | Node.js | `node tools/staging/test_phase15_3_uat_financial_and_security.js` | 18 | 18 | 18 | 0 | 0 | **PASS** |
| **Phase 15.2.5 Token Issuance Audit** | Node.js | `node tools/staging/test_phase15_2_5_token_issuance_adversarial.js` | 19 | 19 | 19 | 0 | 0 | **PASS** |
| **Phase 15.2.4 Secret Elimination** | Node.js | `node tools/staging/test_phase15_2_4_secret_elimination_adversarial.js` | 13 | 13 | 13 | 0 | 0 | **PASS** |
| **Production Auth Hardening Suite**| Node.js | `node tools/staging/test_production_authorization_hardening.js` | 12 | 12 | 12 | 0 | 0 | **PASS** |
| **Remote Staging Smoke Suite (10-Vector)** | Node.js | `node tools/staging/remote_smoke_test.js` | 10 | 10 | 10 | 0 | 0 | **PASS** |
| **Remote PostgreSQL Financial Suite** | PostgreSQL | `npx supabase db query -f tools/staging/remote_financial_tests.sql` | 13 | 13 | 13 | 0 | 0 | **PASS** |
| **Staging Orchestrator Security Logic** | Node.js | `node tools/staging/test_staging_orchestrator_logic.js` | 17 | 17 | 17 | 0 | 0 | **PASS** |
| **Option A Adversarial Suite** | Node.js | `node tools/backup/test_phase15_option_a_adversarial.js` | 15 | 15 | 15 | 0 | 0 | **PASS** |
| **PostgreSQL 14-Entity Reconciliation**| Node.js | `node tools/backup/test_migration_reconciliation.js` | 1 | 1 | 1 | 0 | 0 | **PASS** |
| **Recharge Adversarial Pen-Test** | Node.js | `node tools/backup/test_adversarial_suite.js` | 25 | 25 | 25 | 0 | 0 | **PASS** |
| **Encrypted Backup & Retention Drills**| Node.js | `node tools/backup/test_backup_restore.js` | 10 | 10 | 10 | 0 | 0 | **PASS** |
| **Firestore Disaster Recovery Suite** | Node.js | `node tools/backup/test_firestore_backup_restore.js` | 50 | 50 | 50 | 0 | 0 | **PASS** |
| **Supabase Disaster Recovery Suite**  | Node.js | `node tools/backup/test_supabase_backup_restore.js` | 28 | 28 | 28 | 0 | 0 | **PASS** |
| **FULL REGRESSION TOTAL** | — | — | **751** | **751** | **751** | **0** | **0** | **100% PASS** |

---

### AUTHORITATIVE DELIVERABLES REGISTRY

0. [PHASE_16_4_1_EVIDENCE_VERIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_4_1_EVIDENCE_VERIFICATION_REPORT.md)
   - Phase 16.4.1 independent evidence verification: Detailed provenance analysis for identical Android APK hash (Phase 16.2 binary retained), explicit NOT VERIFIED status for Android hardware (0 devices on ADB) and Windows TPM (Administrator privileges required), verified native DPAPI via Dart FFI, executed isolated staging backup/restore drill with 100% fidelity across all 5 partitions (Cash, Bank, Receivables, History, Recovery Queue), captured verbatim logs and ledger balances from 5 financial crash tests, documented server-side rejection logs from live Supabase Edge Function, and re-certified 100% production Firebase isolation.
0. [PHASE_16_4_ADVERSARIAL_CERTIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_4_ADVERSARIAL_CERTIFICATION_REPORT.md)
   - Phase 16.4 final adversarial financial integrity & hardware security certification: Outbox atomicity & crash recovery matrix (0 duplicate postings), fail-closed invalid customer isolation (`MANUAL_REVIEW_REQUIRED`), physical hardware cryptographic security (Android Keystore TEE ECDSA P-256 vs Windows DPAPI), zero `Db.sales` retail turnover inflation, disaster recovery & durability architecture, clean Windows release build (`tekfix_pos.exe` SHA-256: `8ED112DC7D80B84EA927EEB611F14A87198FE5DB39B67B97B46FD5AE067071F7`, `app.so` SHA-256: `D827585901057D103301B62B6C0E6D3575C523DC7C4FCB56BCDE4A9BB8A4D999`), Android Staging APK (SHA-256: `A9AD2510EB631C1EE55FF10E19FECBE028898D925F24F0BDCBA15BB4DE3DAC29`), 86/86 test pass rate (100%), and 0 static compilation errors.
0. [PHASE_16_3_FINANCIAL_RECOVERY_AND_SECURITY_REPORT.md](file:///d:/tekfix_pos/PHASE_16_3_FINANCIAL_RECOVERY_AND_SECURITY_REPORT.md)
   - Phase 16.3 financial recovery & security audit report: Cross-backend write-ahead outbox journaling (`Db.rechargeQueue`), startup crash auto-reconciliation, physical device binding verification, and 7/7 recovery test suite pass rate.
0. [PHASE_16_2_SECURE_RECHARGE_INTEGRATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_2_SECURE_RECHARGE_INTEGRATION_REPORT.md)
   - Phase 16.2 secure recharge integration report: Integration of QuickRechargeDialog with server-authoritative Supabase PostgreSQL, hardware ECDSA challenge signing, and removal of local authoritative wallet writes.
1. [PHASE_15_4_6_1_FINAL_VERIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_6_1_FINAL_VERIFICATION_REPORT.md)
   - Phase 15.4.6.1 final credential consistency and test completion audit: Reconciled working password `Staging@TekFix2026` vs documentation typo `StagingOwner#2026!`, executed full automated test suite with `--dart-define=TEKFIX_UAT=true` (453 passed, 2 environment contract assertions), executed `flutter analyze` (0 compilation errors, 274 total issues), confirmed multi-layer production Firebase isolation, verified binary SHA-256 (`2FA32E62CC87BC48173D9AA0EBB78326BD8C4110E4A2B0D6FA74F38ED65FE3D8`), and kept physical hardware UAT strictly PENDING.
2. [PHASE_15_4_6_STAGING_UAT_READINESS_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_6_STAGING_UAT_READINESS_REPORT.md)
   - Phase 15.4.6 master readiness report: Independent verification of crash fixes, complete zero-Firebase safeguards across 10 modules, multi-subscription broadcast stream safety, 16/16 automated test pass rate, clean static analysis (0 errors), APK verification (SHA-256: `2FA32E62CC87BC48173D9AA0EBB78326BD8C4110E4A2B0D6FA74F38ED65FE3D8`), regression freeze, and 11-step physical Android UAT execution checklist (marked PENDING for owner hardware testing).
2. [PHASE_15_4_5_RUNTIME_CRASH_FIX_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_5_RUNTIME_CRASH_FIX_REPORT.md)
   - Phase 15.4.5 runtime crash fix report: Diagnosed and resolved `[core/no-app]` Firebase error and `Bad state: Stream has already been listened to` error on physical Android. Converted streams to `.asBroadcastStream()`, added zero-Firebase guards to `AttendanceService`, `PosService`, `DailyRegisterService`, `ConsumablesService`, `StaffOrdersScreen`, and `StaffAttendanceScreen`, added dark diagnostic error recovery builder to `lib/main.dart`, and built verified staging APK.
3. [PHASE_15_4_4_FINAL_APK_DELIVERY_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_4_FINAL_APK_DELIVERY_REPORT.md)
   - Phase 15.4.4 final delivery report: Confirmed successful staging build, verified APK package identity `com.example.tekfix_pos.staging` (version 1.0.28-staging) via AAPT, verified bit-level SHA-256 (`4df384b19650ee280f0d2f49f30974c8496e71add2832da4ed4000328c3a003a`), verified zero-Firebase production isolation, copied delivery binary to `Output/staging_uat/app-staging-release.apk`, and provided physical device installation instructions.
2. [PHASE_15_4_3_STAGING_LOGIN_FIX_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_3_STAGING_LOGIN_FIX_REPORT.md)
   - Phase 15.4.3 master fix report: Traced exact call stack of `[core/no-app]` on physical Android, confirmed installed APK was compiled in Phase 15.3 prior to salted-hash authentication, implemented zero-Firebase local salted-hash authentication and PIN `9999` reset, guarded all background services (AppUpdate, OrderService, Presence, Inventory, Notifications, Repairs) against runtime Firebase calls, added 6/6 regression tests, and compiled fresh Android Staging APK (SHA-256: `4df384b19650ee280f0d2f49f30974c8496e71add2832da4ed4000328c3a003a`).
2. [PHASE_15_4_2_EMERGENCY_DEVICE_RECOVERY_SECURITY_AUDIT.md](file:///d:/tekfix_pos/PHASE_15_4_2_EMERGENCY_DEVICE_RECOVERY_SECURITY_AUDIT.md)
2. [PHASE_15_4_1_PERMANENT_BOOTSTRAP_LOCKOUT_AUDIT.md](file:///d:/tekfix_pos/PHASE_15_4_1_PERMANENT_BOOTSTRAP_LOCKOUT_AUDIT.md)
   - Phase 15.4.1 master report: Discovery and resolution of dynamic activeDevices.length reopening vulnerability, deployment of `public.recharge_shop_bootstrap_state`, anti-tampering database triggers prohibiting DELETE and UPDATE to false, atomic stored procedure `public.recharge_consume_bootstrap`, device loss recovery protocol via `public.recharge_admin_emergency_device_recovery`, 10-vector adversarial test suite (17/17 PASS), full regression audit (718/718 PASS), and approval for physical owner UAT.
2. [tools/staging/test_phase15_4_1_permanent_bootstrap_lockout.js](file:///d:/tekfix_pos/tools/staging/test_phase15_4_1_permanent_bootstrap_lockout.js)
   - Dedicated 17-test adversarial suite testing Vectors A through J including device revocation, row deletion, token expiry, parallel race conditions, anti-tamper trigger exceptions, staff denial, and cross-shop isolation.
3. [supabase/migrations/20261110000001_recharge_permanent_bootstrap_lockout.sql](file:///d:/tekfix_pos/supabase/migrations/20261110000001_recharge_permanent_bootstrap_lockout.sql)
   - Database migration establishing `public.recharge_shop_bootstrap_state`, anti-tampering trigger `trg_recharge_protect_bootstrap_state`, stored procedure `recharge_consume_bootstrap`, and administrative recovery procedures.
4. [PHASE_15_4_FINAL_INTEGRATED_SECURITY_FINANCIAL_ACCEPTANCE_REPORT.md](file:///d:/tekfix_pos/PHASE_15_4_FINAL_INTEGRATED_SECURITY_FINANCIAL_ACCEPTANCE_REPORT.md)
   - Phase 15.4 master report: Complete architectural verification, absolute production isolation (Firebase `tekfix-45b38` untouched, ₹0.00 cost), owner/staff authorization matrix, device enrollment security audit (vectors A through O), bootstrap secret lifecycle, Android Keystore & Windows DPAPI hardware cryptography, recharge pass-through financial reconciliation, retail ERP regression, backup/DR drills, and the four explicit governance decisions.
2. [tools/staging/test_phase15_4_integrated_acceptance.js](file:///d:/tekfix_pos/tools/staging/test_phase15_4_integrated_acceptance.js)
   - Dedicated Phase 15.4 test suite covering all 15 device enrollment vectors (A through O) including real parallel concurrent race condition testing against remote Supabase staging, pass-through integer paise financial equations, and production zero-touch guarantees.
3. [PHASE_15_3_1_PHYSICAL_UAT_READINESS_REPORT.md](file:///d:/tekfix_pos/PHASE_15_3_1_PHYSICAL_UAT_READINESS_REPORT.md)
   - Phase 15.3.1 master reconciliation report: 670 executions / 665 unique tests reconciled, bootstrap secret delivery audit, Android Keystore P-256 non-extractability & TEE acceptance verification, Windows DPAPI user-profile protection classification (honestly distinguishing from TPM), PostgreSQL partial unique index `uq_recharge_trusted_devices_quota` for atomic quota enforcement, ₹10.00 wallet debit verified to the exact paise, and physical UAT operator instructions.
2. [tools/staging/audit_test_counts.js](file:///d:/tekfix_pos/tools/staging/audit_test_counts.js)
   - Independent verification harness that runs all 14 project test suites, parsing test outcomes and outputting the mathematical reconciliation table.
3. [PHASE_15_3_PHYSICAL_UAT_FINAL_REPORT.md](file:///d:/tekfix_pos/PHASE_15_3_PHYSICAL_UAT_FINAL_REPORT.md)
   - Phase 15.3 master report documenting pre-flight build SHA-256 verification, bootstrap credential safety audit, Windows DPAPI FFI results, remote staging financial debit reconciliation (₹10.00 / 1,000 paise on Airtel wallet), cross-device enrollment, device quota, ERP regression (439 Flutter tests), and physical hardware gate status.
4. [tools/staging/test_phase15_3_uat_financial_and_security.js](file:///d:/tekfix_pos/tools/staging/test_phase15_3_uat_financial_and_security.js)
   - 18-vector remote staging financial and security suite verifying expired token rejection, staff authorization denial, unauthorized shop rejection, bootstrap enrollment, cross-device enrollment, quota limits, ₹10 financial debit, and device revocation on live Supabase staging backend.
5. [PHASE_15_2_5_FINAL_TOKEN_ISSUANCE_SECURITY_AUDIT.md](file:///d:/tekfix_pos/PHASE_15_2_5_FINAL_TOKEN_ISSUANCE_SECURITY_AUDIT.md)
   - Phase 15.2.5 master security audit report documenting independent token issuance penetration testing, discovery and resolution of identifier-only vulnerability, ECDSA P-256 challenge-response gate, one-way initial bootstrap gate, 19-vector adversarial test suite, and audited release binary checksums.
6. [tools/staging/test_phase15_2_5_token_issuance_adversarial.js](file:///d:/tekfix_pos/tools/staging/test_phase15_2_5_token_issuance_adversarial.js)
   - 19-vector adversarial pen-testing suite covering unauthenticated challenge retrieval, signature requirements, unwhitelisted shop rejection, atomic single-use nonce consumption, revoked device rejection, concurrent race conditions, bootstrap enrollment gating, and permanent closure after initial enrollment.
7. [PHASE_15_2_4_SECRET_ELIMINATION_AND_SECURITY_HARDENING_REPORT.md](file:///d:/tekfix_pos/PHASE_15_2_4_SECRET_ELIMINATION_AND_SECURITY_HARDENING_REPORT.md)
   - Phase 15.2.4 master report documenting complete elimination of client signing secrets, server-authoritative token issuance endpoint, remote Supabase Vault secret rotation, empirical revocation verification (HTTP 401), 13-vector adversarial tests, 622 regression tests, and audited binary checksums with zero client secrets.
8. [tools/staging/test_phase15_2_4_secret_elimination_adversarial.js](file:///d:/tekfix_pos/tools/staging/test_phase15_2_4_secret_elimination_adversarial.js)
   - 13-vector adversarial test suite covering client secret elimination, live token issuance, unwhitelisted identity rejection, revoked secret rejection, token tampering, and hardware signature mutex.
9. [PHASE_15_2_3_PHYSICAL_UAT_ARTIFACT_ISOLATION_REPORT.md](file:///d:/tekfix_pos/PHASE_15_2_3_PHYSICAL_UAT_ARTIFACT_ISOLATION_REPORT.md)
   - Phase 15.2.3 report documenting dedicated physical UAT build isolation, package separation, compile-time AOT pruning, runtime safety gates, SHA-256 verification, and physical UAT readiness.
10. [build/app/outputs/flutter-apk/app-staging-release.apk](file:///d:/tekfix_pos/build/app/outputs/flutter-apk/app-staging-release.apk)
    - Dedicated Android Staging UAT APK (SHA-256: `1685786eca798e7e99d9ae38b16d59ea2efbeea292805d401db68a32be1e62fd`, Zero secrets verified).
11. [build/windows/x64/runner/Release/tekfix_pos.exe](file:///d:/tekfix_pos/build/windows/x64/runner/Release/tekfix_pos.exe)
    - Dedicated Windows Staging UAT Desktop Binary (Runner SHA-256: `fed62be5d539421b8733c289fd1ccb7d2cdfc321598dd566a86990656aecc33e`, AOT `app.so` SHA-256: `03e06b741be281d7c5fb126b0e8becec295b36d6430e75f629305ad02e084482`, Zero secrets verified).
12. [PHASE_15_2_2_PRODUCTION_AUTHORIZATION_HARDENING_FINAL_REPORT.md](file:///d:/tekfix_pos/PHASE_15_2_2_PRODUCTION_AUTHORIZATION_HARDENING_FINAL_REPORT.md)
    - Phase 15.2.2 report documenting the elimination of the ownerUid short-circuit, live user document verification, 12/12 unit tests, 10/10 remote smoke tests, and readiness for Phase 15.3 Physical Device UAT.
13. [tools/staging/test_production_authorization_hardening.js](file:///d:/tekfix_pos/tools/staging/test_production_authorization_hardening.js)
    - Production authorization hardening unit test suite verifying all 12 fail-closed security conditions with simulated Firestore responses.
14. [PHASE_15_2_1_AUTHORIZATION_AND_PRODUCTION_ISOLATION_FINAL_REPORT.md](file:///d:/tekfix_pos/PHASE_15_2_1_AUTHORIZATION_AND_PRODUCTION_ISOLATION_FINAL_REPORT.md)
    - Phase 15.2.1 report resolving strict owner-only gate (admins denied), proving 100% air-gapped Option A staging isolation with 0 Firestore/JWKS calls, and classifying all audit vectors.
15. [PHASE_15_2_FINAL_STAGING_SECURITY_AND_UAT_REPORT.md](file:///d:/tekfix_pos/PHASE_15_2_FINAL_STAGING_SECURITY_AND_UAT_REPORT.md)
    - Phase 15.2 master report documenting migration version verification, real PostgreSQL concurrency audit (5/5 PASS), audit log immutability, Edge Function owner-only gate, dual-backend isolation, disaster recovery (14+1 tables), and step-by-step physical device UAT runbook for Android and Windows.
16. [tools/staging/real_postgresql_concurrency_audit.js](file:///d:/tekfix_pos/tools/staging/real_postgresql_concurrency_audit.js)
    - Real PostgreSQL concurrency audit script opening parallel process database connections to test row-locking debits, idempotency races, refund/reversal mutual exclusion, and distributor over-settlement limits.
17. [PHASE_15_1_1_ACTUAL_STAGING_DEPLOYMENT_FINAL_REPORT.md](file:///d:/tekfix_pos/PHASE_15_1_1_ACTUAL_STAGING_DEPLOYMENT_FINAL_REPORT.md)
    - Master report documenting completed remote staging deployment, 3-way validation, 10/10 remote smoke tests, 13/13 live PostgreSQL financial tests, and Categories A–I status classification.
18. [tools/staging/discover_and_deploy.ps1](file:///d:/tekfix_pos/tools/staging/discover_and_deploy.ps1)
    - Autonomous script that queries `supabase projects list`, discovers `tekfix-recharge-staging` in `ap-south-1`, auto-populates `staging.local.json`, and triggers the deployment orchestrator.
19. [tools/staging/deploy_and_smoke_test.ps1](file:///d:/tekfix_pos/tools/staging/deploy_and_smoke_test.ps1)
    - Staging deployment orchestrator with independent pin loading from `tools/staging/staging.local.json`, 3-way validation gate, RNG disposal, memory zeroization, sequential migrations, and automatic session cleanup.
20. [tools/staging/remote_smoke_test.js](file:///d:/tekfix_pos/tools/staging/remote_smoke_test.js)
    - 10-vector remote smoke test suite asserting exact HTTP status and error payload with zero financial ledger balance modifications.
21. [tools/staging/remote_financial_tests.sql](file:///d:/tekfix_pos/tools/staging/remote_financial_tests.sql)
    - 13-test live PostgreSQL financial verification suite verifying pure integer paise accounting, ACID guarantees, idempotency, overdraft protection, double-refund protection, distributor settlement, and double-entry ledger.
22. [tools/staging/staging.local.example.json](file:///d:/tekfix_pos/tools/staging/staging.local.example.json)
    - Safe tracked template file for the private staging configuration.
23. [build/app/outputs/flutter-apk/app-prod-release.apk](file:///d:/tekfix_pos/build/app/outputs/flutter-apk/app-prod-release.apk)
    - Production-ready Android release APK (76.5 MB).
24. [build/windows/x64/runner/Release/tekfix_pos.exe](file:///d:/tekfix_pos/build/windows/x64/runner/Release/tekfix_pos.exe)
    - Production-ready Windows x64 desktop release binary (15.2 MB).
25. [PHASE_15_5_OWNER_AUTH_LOGOUT_FINAL_REPORT.md](file:///d:/tekfix_pos/PHASE_15_5_OWNER_AUTH_LOGOUT_FINAL_REPORT.md)
    - Phase 15.5 master report documenting emergency fix for staging owner authentication auto-login vulnerability (fail-closed equality check), implementation of mobile More screen owner profile header and bottom red logout card, settings logout tile, complete 24-module RBAC audit, 9/9 automated test verification in `test/owner_auth_mobile_logout_test.dart`, and delivery of fresh physical staging release APK (SHA-256: `14952766375C79AEB016DAB9B72DAF060F054E49A123BFF8B808189330DBBEF6`).
26. [Output/staging_uat/app-staging-release.apk](file:///d:/tekfix_pos/Output/staging_uat/app-staging-release.apk)
    - Dedicated Android Staging UAT APK with Phase 15.5 fail-closed owner authentication and mobile logout (74.4 MB, Package: `com.example.tekfix_pos.staging`, Version: `1.0.28-staging`).
27. [PHASE_16_IMPLEMENTATION_AND_VERIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_IMPLEMENTATION_AND_VERIFICATION_REPORT.md)
    - Phase 16 master report documenting Windows desktop verification, complete removal of WeatherCard from home dashboard, implementation of 10th Quick Action Recharge card, QuickRechargeDialog with full cash flow integration (Cash, UPI, Credit / Due), resolution of Daily Rent calendar tiles text collision, and renaming of duplicate "Daily" bottom navigation labels to "Day Book / Ledger" and "Rent / Schedule".
28. [build/windows/x64/runner/Release/tekfix_pos.exe](file:///d:/tekfix_pos/build/windows/x64/runner/Release/tekfix_pos.exe)
    - Updated Windows x64 desktop release binary with Phase 16 features (Runner SHA-256: `8ED112DC7D80B84EA927EEB611F14A87198FE5DB39B67B97B46FD5AE067071F7`, AOT `app.so` SHA-256: `D827585901057D103301B62B6C0E6D3575C523DC7C4FCB56BCDE4A9BB8A4D999`).
29. [PHASE_16_4_1_EVIDENCE_VERIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_4_1_EVIDENCE_VERIFICATION_REPORT.md)
    - Independent audit verification report detailing APK hash collision analysis, Windows DPAPI vs TPM boundaries, ADB device scans, and 5 crash recovery scenarios.
30. [PHASE_16_4_2_SECURITY_REMEDIATION_AND_VERIFICATION_REPORT.md](file:///d:/tekfix_pos/PHASE_16_4_2_SECURITY_REMEDIATION_AND_VERIFICATION_REPORT.md)
    - Master remediation and independent verification report covering 100% staging secret scrubbing from all test scripts, fresh Android staging release APK compilation (`Output\staging_uat_phase16_4_2\app-staging-release.apk`, SHA-256: `FCF72C179AFFCC93FD8EA5890D90043D0A7DBF0C5C2EED99648DF9D9B6372124`), DPAPI FFI tests, local backup/restore empirical verification, crash drills, and production isolation.
31. [Output/staging_uat_phase16_4_2/app-staging-release.apk](file:///d:/tekfix_pos/Output/staging_uat_phase16_4_2/app-staging-release.apk)
    - Clean fresh Android Staging UAT release APK with Phase 16.4.2 changes (75.5 MB, Package: `com.example.tekfix_pos.staging`, Version: `1.0.28-staging`, SHA-256: `FCF72C179AFFCC93FD8EA5890D90043D0A7DBF0C5C2EED99648DF9D9B6372124`).
32. [PHASE_16_4_3_FINAL_UAT_READINESS_REPORT.md](file:///d:/tekfix_pos/PHASE_16_4_3_FINAL_UAT_READINESS_REPORT.md)
    - Phase 16.4.3 master readiness report documenting secret incident audit, git history check, APK upgrade compatibility with versionCode 29, Cloud backup status (BLOCKED per safety rules), live server authorization evidence, financial integrity, production isolation, and Conditional Pass certification.
33. [Output/staging_uat_phase16_4_3/app-staging-release.apk](file:///d:/tekfix_pos/Output/staging_uat_phase16_4_3/app-staging-release.apk)
    - Production-grade Android Staging UAT release APK with Phase 16.4.3 changes (75.5 MB, Package: `com.example.tekfix_pos.staging`, Version: `1.0.29-staging`, Version Code: `29`, SHA-256: `A7F0938AF863A987E490C66C234A7E7088F901074452B603B54E39BE7A262B9A`). Direct in-place upgrade compatible with existing installations.
