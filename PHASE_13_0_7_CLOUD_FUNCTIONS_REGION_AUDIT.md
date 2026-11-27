# TEKFIX ERP – PHASE 13.0.7
# CLOUD FUNCTIONS REGION AUDIT REPORT
# STRICT READ-ONLY MODE

**Audit Date:** 2026-11-08  
**Auditor Roles:** Senior Firebase Architect, DevOps Engineer, Independent Security Auditor  
**Production Project:** `tekfix-45b38`  
**Production Firestore Location:** `asia-south1` (Mumbai)  
**Target Staging Project:** `tekfix-staging`  
**Safety Protocol:** Strict Read-Only Mode (Zero Source Modifications, Zero Deployments, Zero Remote Connections)  

---

## 1. EXECUTIVE SUMMARY

The Phase 13.0.7 audit was conducted to inspect, verify, and document the Cloud Functions region configuration in the TekFix ERP codebase before configuring the newly isolated Staging environment (`tekfix-staging`).

### Key Audit Highlights:
- **Zero Explicit Region Declarations:** Neither `firebase/functions/index.js` nor `firebase.json` declares a deployment region.
- **Implicit Default Region Active:** All 3 Cloud Functions currently fall back to the Firebase Functions v1 SDK default region: **`us-central1` (Council Bluffs, Iowa, USA)**.
- **Geographic Inter-Service Mismatch:** Production Firestore is hosted in **`asia-south1` (Mumbai, India)**, while Cloud Functions default to **`us-central1` (Iowa, USA)**.
- **Client-Side Dependency:** Flutter client code in `lib/recharge/recharge_service.dart` calls `FirebaseFunctions.instance.httpsCallable('processRechargeDebit')`, which defaults to calling `us-central1`.
- **Verdict:** **C. CONFIGURATION ISSUE FOUND** (Implicit default region causes severe cross-continental inter-service latency and requires synchronized client-backend region declaration before staging deployment).

---

## 2. DETAILED AUDIT FINDINGS

### A. Production Functions Region & Code Inspection
- **Source File Inspected:** `firebase/functions/index.js` (673 lines)
- **Functions SDK Version:** Firebase Functions v1 (`"firebase-functions": "^4.5.0"`) imported via `const functions = require("firebase-functions");`.
- **`setGlobalOptions` Status:** **NOT FOUND**. (`setGlobalOptions` is a Firebase Functions v2 API; the codebase operates exclusively on Firebase Functions v1 syntax).
- **Explicit `.region(...)` Declarations:** **0 of 3 functions**.

### B. Inventory of Cloud Functions & Configured Regions

| Exported Function | Trigger Type | Configured Region in Code | Effective Deployment Region | Target Resource / Location |
| :--- | :--- | :--- | :--- | :--- |
| **`onStaffCheckIn`** | Firestore `onCreate`<br>`shops/{shopId}/attendance/{attendanceId}` | *None (Omitted)* | **`us-central1`** (Default) | Firestore (`asia-south1`) |
| **`autoCloseForgottenCheckouts`** | Pub/Sub Scheduled Cron<br>`45 23 * * *` (`Asia/Kolkata`) | *None (Omitted)* | **`us-central1`** (Default) | Firestore (`asia-south1`) |
| **`processRechargeDebit`** | HTTPS Callable (`functions.https.onCall`) | *None (Omitted)* | **`us-central1`** (Default) | Firestore (`asia-south1`) & Client POS |

### C. Inspection of `firebase.json`
```json
    "functions": [
        {
            "source": "firebase/functions",
            "codebase": "default",
            "ignore": [
                "node_modules",
                ".git",
                "firebase-debug.log",
                "firebase-debug.*.log"
            ]
        }
    ]
```
*Finding:* No region or deployment override is configured in `firebase.json`.

### D. Inspection of Flutter Client Callers
In `lib/recharge/recharge_service.dart`:
- Line 242:
  ```dart
  final callable = FirebaseFunctions.instance.httpsCallable('processRechargeDebit');
  ```
- Line 723:
  ```dart
  final callable = FirebaseFunctions.instance.httpsCallable('processRechargeDebit');
  ```
*Finding:* `FirebaseFunctions.instance` uses the SDK default region `us-central1`. It does NOT use `FirebaseFunctions.instanceFor(region: 'asia-south1')`.

---

## 3. COMPARISON: CLOUD FUNCTIONS (`us-central1`) VS FIRESTORE (`asia-south1`)

```mermaid
flowchart LR
    subgraph ClientLayer["POS Client (India - IST)"]
        ClientApp["TekFix Flutter POS App"]
    end

    subgraph USRegion["GCP Region: us-central1 (Iowa, USA)"]
        Functions["Cloud Functions v1\n(processRechargeDebit,\nonStaffCheckIn,\nautoCloseForgottenCheckouts)"]
    end

    subgraph IndiaRegion["GCP Region: asia-south1 (Mumbai, India)"]
        FirestoreDB[("Cloud Firestore\nNative DB (asia-south1)")]
    end

    ClientApp -->|1. HTTPS Call (~220ms RTT)| Functions
    Functions <-->|2. Serial Reads in db.runTransaction (~200ms RTT each)| FirestoreDB
    Functions -->|3. Writes in Transaction (~200ms RTT)| FirestoreDB
    Functions -->|4. Return Result (~220ms RTT)| ClientApp
```

### Architectural & Latency Impact Analysis:
1. **Inter-Continental Latency Penalty:**
   - Round-trip time (RTT) between Iowa (`us-central1`) and Mumbai (`asia-south1`) averages **180ms - 240ms**.
   - In `processRechargeDebit`, a serializable transaction (`db.runTransaction()`) executes 5 authoritative document reads (`shopRef`, `membershipRef`, `reconRef`, `txnRef`, `walletRef`) followed by multi-document writes (`transactions`, `reconciliation`, `distributor_wallets`, `wallet_ledger`).
   - Because Firestore transactions execute across this cross-continental WAN, transaction lock durations increase by **600ms - 1,200ms**.
   - Under concurrent POS load or multiple recharge debits, this extended latency dramatically increases the risk of `ABORTED: Too much contention on these documents` and client timeouts.
2. **Network Egress Costs:**
   - Google Cloud charges inter-continental network egress between North America and Asia for every document payload exchanged between Cloud Functions and Firestore.
3. **Scheduled Cron Inefficiencies:**
   - `autoCloseForgottenCheckouts` runs daily at 23:45 IST. Because it runs in `us-central1`, it scans all shops and queries all unclosed attendance records in `asia-south1` across transatlantic lines.

---

## 4. RECOMMENDED STAGING CLOUD FUNCTIONS REGION

### Recommendation: **`asia-south1` (Mumbai)**

### Justification:
1. **Co-location with Firestore:** Co-locating Cloud Functions in `asia-south1` with Staging Firestore in `asia-south1` reduces database read/write latency to **< 5ms** within the Google Cloud internal VPC network.
2. **Financial Integrity & Transaction Velocity:** Minimizing `db.runTransaction()` execution time directly safeguards wallet debit atomicity and eliminates lock contention windows.
3. **Data Residency & Compliance:** Keeps all financial data, audit logs, and POS execution within the Indian sovereign data boundary.

---

## 5. CONFIGURATION CONFLICTS & SECURITY FINDINGS

### Conflict 1: Client-Server Region Desynchronization Risk (CRITICAL)
- If Cloud Functions in `index.js` are updated to `.region('asia-south1')`, but the Flutter client code is left unchanged (`FirebaseFunctions.instance`), the Flutter app will continue targeting `https://us-central1-tekfix-staging.cloudfunctions.net/processRechargeDebit`.
- Result: **HTTP 404 NOT FOUND (`FirebaseFunctionsException: NOT_FOUND`)**.
- **Requirement:** Any change to backend function region MUST be accompanied by an identical update in Flutter:
  ```dart
  FirebaseFunctions.instanceFor(region: 'asia-south1')
  ```

### Conflict 2: Existing Production Region Ambiguity
- Because source code contains no `.region(...)`, if the production project (`tekfix-45b38`) was deployed via standard `firebase deploy`, its live functions are currently hosted in `us-central1`.
- If the human DevOps engineer previously deployed functions with an explicit `--region` CLI parameter, remote production could be in `asia-south1`, but local source code does not reflect this reality.

---

## 6. AUDIT SUMMARY TABLE

| Parameter | Current Status / Finding | Recommendation for Staging |
| :--- | :--- | :--- |
| **Production Functions Region** | `us-central1` (Implicit SDK Default) | Migrate to `asia-south1` |
| **Individual Function Regions** | 0 declared (All 3 use default) | Declare `.region('asia-south1')` explicitly on all 3 |
| **Default Region Usage** | 100% (All functions) | 0% (Explicit declarations required) |
| **Firestore Region** | `asia-south1` (Mumbai) | `asia-south1` (Mumbai) |
| **Recommended Staging Region** | `asia-south1` (Mumbai) | `asia-south1` (Mumbai) |
| **Flutter Client Region Config** | `us-central1` (Default instance) | Update to `FirebaseFunctions.instanceFor(region: 'asia-south1')` |
| **Configuration Conflicts** | Cross-continent mismatch (`us-central1` vs `asia-south1`) | Synchronize backend and client to `asia-south1` |
| **Security Findings** | Unnecessary cross-region egress and latency hazard | Co-locate compute and database in `asia-south1` |

---

## 7. FINAL VERDICT

```
================================================================================
FINAL VERDICT:
C. CONFIGURATION ISSUE FOUND

Reason:
1. In firebase/functions/index.js, all 3 Cloud Functions lack explicit region
   declarations, defaulting to us-central1 (USA).
2. Production Firestore is located in asia-south1 (Mumbai, India).
3. This creates a severe cross-continental inter-service latency mismatch
   (~200ms+ round-trip penalty per Firestore transaction step).
4. Flutter client callers currently default to us-central1.
5. Moving Staging to asia-south1 requires synchronized updates to both
   firebase/functions/index.js and lib/recharge/recharge_service.dart.
================================================================================
```

---

## 8. ACTION REQUIRED FROM HUMAN STAKEHOLDER

Before any code modification or staging deployment is authorized:
1. **Clarify Production Live Function Status:** Confirm whether live production functions in `tekfix-45b38` are currently running in `us-central1` or `asia-south1`.
2. **Authorize Region Standardization for Staging:** Approve standardizing both Staging Cloud Functions and Staging Firestore in **`asia-south1` (Mumbai)**.
3. **Authorize Synchronized Client Update:** Approve updating `lib/recharge/recharge_service.dart` to use `FirebaseFunctions.instanceFor(region: 'asia-south1')`.

*Strict read-only safety rules enforced. Zero files modified. Zero deployments executed. Standing by for human stakeholder authorization.*

