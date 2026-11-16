# TEKFIX ERP – PRODUCTION RECHARGE BACKEND PREPARATION REPORT

**Date:** 2026-11-16  
**Checkpoint:** `d8bcaf3`  
**Base Commit Preserved:** `050c29d`  
**Backup Branch Preserved:** `wip-backup-20261112`  
**Status:** AUDIT COMPLETE — STOPPED BEFORE DEPLOYMENT (AWAITING OWNER APPROVAL)

---

## 1. EXACT ROOT CAUSE ANALYSIS [PASS]

### Evidence & Root Cause:
1. **Shared Project URL:** `lib/firebase_options.dart` (Line 60) hardcodes `expectedSupabaseEdgeUrl` to `https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge`.
2. **Remote Environment Variable:** The live Supabase instance `mwhsvidbrfkryuiwhnev` was provisioned during Staging/UAT with remote secret `STAGING_IDENTITY_MODE="true"`.
3. **Edge Function Logic (`supabase/functions/recharge-bridge/index.ts` Lines 34–35, 60–80):**
   ```typescript
   const RAW_STAGING_MODE = Deno.env.get("STAGING_IDENTITY_MODE");
   const STAGING_IDENTITY_MODE = RAW_STAGING_MODE === "true";
   ```
   When `STAGING_IDENTITY_MODE` is `"true"`, `/issue-staging-token` is active, and the Edge Function expects HMAC HS256 tokens rather than verifying Google RS256 JWKS tokens.
4. **Live Verification Probe:**
   - Probing `https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge/issue-staging-token` returned **HTTP 400** ("Missing mandatory parameters..."), proving the endpoint is actively serving staging tokens. In production mode, this endpoint returns **HTTP 403** ("Forbidden: Staging identity issuance is disabled in production mode.").

---

## 2. PRODUCTION CONFIGURATION READINESS [PASS]

1. **Code Hardening (`supabase/functions/recharge-bridge/index.ts` Lines 60–85):**
   - Missing or invalid `STAGING_IDENTITY_MODE` fails closed (must be explicitly `"true"` or `"false"`).
   - `FIREBASE_PROJECT_ID === "tekfix-45b38"` is enforced ONLY when `STAGING_IDENTITY_MODE` is not `"true"`.
   - Staging mode continues working unchanged with synthetic Option A / staging Firebase.
2. **Client-Side Startup Fail-Closed Guard (`lib/firebase_options.dart` & `lib/main.dart`):**
   - In production builds, `SUPABASE_PROD_EDGE_URL` must be explicitly defined via `--dart-define`.
   - If missing or pointing to the staging project `mwhsvidbrfkryuiwhnev`, the client immediately throws `StateError` and halts on startup. Never falls back to staging.
3. **Production Config Template:** Created `supabase/production_config.env.example` with zero secrets:
   - `STAGING_IDENTITY_MODE=false`
   - `FIREBASE_PROJECT_ID=tekfix-45b38`

---

## 3. COMPONENT VERIFICATION AUDIT

- **Firebase Token Verification (by Code Review):** **PASS** — RS256 JWKS verification against `securetoken.google.com/tekfix-45b38` enforced when `STAGING_IDENTITY_MODE=false`.
- **Owner Authorization (by Code Review):** **PASS** — Enforces `shopDoc.fields.ownerUid == callerUid` and `userDoc.fields.role == "owner"`.
- **Firestore Access (by Code Review):** **PASS** — Uses caller's Bearer token for read-only REST fetch to `firestore.googleapis.com/.../shops/${shopId}`.
- **Supabase Secret Names (by Code Review):** **PASS** — Secret names verified (`FIREBASE_PROJECT_ID`, `STAGING_IDENTITY_MODE`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`).
- **Live Production Firebase Token Verification:** **NOT VERIFIED** — No live production requests executed.
- **Live Production Owner Authorization:** **NOT VERIFIED** — No live production requests executed.
- **Live Production Firestore Access:** **NOT VERIFIED** — No live production requests executed.
- **Live Production Supabase Secrets Configuration:** **NOT VERIFIED** — No remote writes or secrets set.

---

## 4. ISOLATION & ARCHITECTURAL BLOCKER [FAIL - SHARED PROJECT BLOCKER]

- **Blocker:** If the single project `mwhsvidbrfkryuiwhnev` has its secrets changed to `STAGING_IDENTITY_MODE=false`, the staging Android app on the physical TECNO phone will immediately break because it relies on staging token issuance.
- **Resolution:** A dedicated Production Supabase Project (e.g. `<prod-ref>`) MUST be used for live production.

---

## 5. PREPARED DEPLOYMENT PLAN (DO NOT EXECUTE UNTIL APPROVED)

```bash
# Pre-requisite 1: Confirm PostgreSQL migrations were tested on staging
# Pre-requisite 2: Confirm backup / PITR (Point-In-Time Recovery) is enabled on target project

# Step 1: Link CLI to dedicated production project
supabase link --project-ref <prod-ref>

# Step 2: Dry-run database schema migrations first
supabase db push --dry-run

# Step 3: Apply migrations after dry-run verification
supabase db push

# Step 4: Set production environment secrets in Supabase vault (no secret values in history)
supabase secrets set FIREBASE_PROJECT_ID=tekfix-45b38 STAGING_IDENTITY_MODE=false

# Step 5: Deploy production Edge Function
supabase functions deploy recharge-bridge --no-verify-jwt
```

---

## 6. ROLLBACK PLAN [PASS]

### Scenario A: New Production Project Rollback (Function Not Live Yet / Failed Deployment)
1. **Disable or Delete Function:**
   ```bash
   supabase link --project-ref <prod-ref>
   supabase functions delete recharge-bridge
   ```
2. **Redeploy Previous Git Function Version (if reverting code):**
   ```bash
   git checkout <previous-commit-hash> supabase/functions/recharge-bridge/
   supabase functions deploy recharge-bridge --no-verify-jwt
   ```

### Scenario B: Restoring Staging Project (If `mwhsvidbrfkryuiwhnev` Was Accidentally Touched)
1. **Restore Secret Names in Vault:**
   - Secret names to set: `STAGING_IDENTITY_MODE=true`
   - Secret names to restore from secure offline vault: `STAGING_JWT_SECRET`, `STAGING_BOOTSTRAP_SECRET`
   - Secret name to unset: `FIREBASE_PROJECT_ID`
   ```bash
   supabase link --project-ref mwhsvidbrfkryuiwhnev
   supabase secrets set STAGING_IDENTITY_MODE=true STAGING_JWT_SECRET=<val> STAGING_BOOTSTRAP_SECRET=<val>
   supabase secrets unset FIREBASE_PROJECT_ID
   ```
2. **Redeploy Staging Function:**
   ```bash
   supabase functions deploy recharge-bridge --no-verify-jwt
   ```

---

## 7. ANDROID & WINDOWS CLIENT COMPATIBILITY [PASS]

- **Flutter Endpoint Resolution:** In `lib/firebase_options.dart`, `productionSupabaseEdgeUrl` requires `--dart-define=SUPABASE_PROD_EDGE_URL=https://<prod-ref>.supabase.co/functions/v1/recharge-bridge` and throws if missing or pointing to staging.
- **Firebase Auth Hook:** In `lib/main.dart`, passes authentic `FirebaseAuth.instance.currentUser?.getIdToken()`.
- **Integrity:** Keystores, `key.properties`, and Git snapshots remain 100% untouched.

---

**FINAL STATUS:** STOPPED. Awaiting explicit owner authorization before performing any deployment.
