# ==============================================================================
# TEKFIX ERP — PHASE 15.0.3: AUTOMATED STAGING DEPLOYMENT & SMOKE TEST ORCHESTRATOR
# STRICT SAFETY: PRODUCTION FIREBASE tekfix-45b38 REMAINS COMPLETELY UNTOUCHED
# ==============================================================================

param(
    [string]$ProjectRef = "",
    [string]$DbPassword = ""
)

$ErrorActionPreference = "Stop"

# Non-negotiable Staging Target Constraints
$EXPECTED_STAGING_NAME = "tekfix-recharge-staging"
$EXPECTED_STAGING_REGION = "ap-south-1"
$CONFIG_FILE_PATH = Join-Path $PSScriptRoot "staging.local.json"

# Deployment State Tracker for Accurate Partial-Deployment Reporting
$DeploymentState = [ordered]@{
    "1. CLI Verification"                 = $false
    "2. Authentication Verification"       = $false
    "3. Pinned Identity & Region Gate"     = $false
    "4. Project Link"                     = $false
    "5. Database Migrations (15 Entities)" = $false
    "6. Staging Secrets (CSPRNG 256-bit)" = $false
    "7. Edge Function Deployment"         = $false
    "8. 10-Vector Smoke Tests (Zero Fin)" = $false
}

function Report-DeploymentStatus {
    Write-Host "`n================================================================================" -ForegroundColor Yellow
    Write-Host "STAGING DEPLOYMENT STATUS BREAKDOWN:" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Yellow
    foreach ($step in $DeploymentState.Keys) {
        $done = $DeploymentState[$step]
        $color = if ($done) { "Green" } else { "Red" }
        $mark = if ($done) { "✅ PASS" } else { "❌ NOT EXECUTED / FAILED" }
        Write-Host "  $step : $mark" -ForegroundColor $color
    }
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "`nROLLBACK & REMEDIATION NOTICE:" -ForegroundColor Cyan
    Write-Host "  - Secret removal & Edge Function deletion revoke access, but DO NOT reverse database migrations." -ForegroundColor DarkGray
    Write-Host "  - Routine schema corrections MUST be applied via forward-only migrations (e.g. 20261109000004_fix.sql)." -ForegroundColor DarkGray
    Write-Host "  - 'supabase db reset' is a DESTRUCTIVE DISASTER-ONLY ACTION that erases all data. Do not run routinely." -ForegroundColor DarkGray
    Write-Host "================================================================================" -ForegroundColor Yellow
}

function Assert-StepSuccess([string]$StepName) {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ CRITICAL ERROR: $StepName failed with exit code $LASTEXITCODE." -ForegroundColor Red
        Write-Host "Deployment stopped immediately. No further steps will be executed." -ForegroundColor Red
        Report-DeploymentStatus
        exit $LASTEXITCODE
    }
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "TEKFIX ERP - PHASE 15.0.3 REMOTE STAGING DEPLOYMENT ORCHESTRATOR" -ForegroundColor Cyan
Write-Host "Target Project Name:   $EXPECTED_STAGING_NAME" -ForegroundColor Cyan
Write-Host "Target Project Region: $EXPECTED_STAGING_REGION (Mumbai, India)" -ForegroundColor Cyan
Write-Host "Safety Guarantee:      Production Firebase tekfix-45b38 is 100% UNTOUCHED" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Cyan

try {
    # --------------------------------------------------------------------------
    # Step 1: Verify Supabase CLI
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 1/8] Verifying Supabase CLI..." -ForegroundColor Yellow
    $npxCmd = Get-Command "npx.cmd" -ErrorAction SilentlyContinue
    if (-not $npxCmd) {
        Write-Error "npx.cmd not found. Ensure Node.js is installed."
        exit 1
    }

    $cliVersion = & npx.cmd supabase --version
    Assert-StepSuccess "Supabase CLI version check"
    Write-Host "  Supabase CLI Version: $cliVersion" -ForegroundColor Green
    $DeploymentState["1. CLI Verification"] = $true

    # --------------------------------------------------------------------------
    # Step 2: Verify Supabase Authentication
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 2/8] Checking Supabase Authentication..." -ForegroundColor Yellow
    $projectsJson = cmd.exe /c "npx.cmd supabase projects list --output-format json 2>nul"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectsJson) -or $projectsJson -match "AccessTokenRequiredError") {
        Write-Host "  Supabase CLI is not logged in." -ForegroundColor Red
        Write-Host "  Please run: npx.cmd supabase login" -ForegroundColor Yellow
        Write-Host "  Or set:     `$env:SUPABASE_ACCESS_TOKEN = '<your-token>'" -ForegroundColor Yellow
        Write-Host "  (Never paste tokens into chat)." -ForegroundColor DarkGray
        exit 1
    }

    $projectsList = $null
    try {
        $parsedJson = $projectsJson | ConvertFrom-Json
        if ($parsedJson.projects) {
            $projectsList = @($parsedJson.projects)
        } else {
            $projectsList = @($parsedJson)
        }
    } catch {
        Write-Host "  Failed to parse Supabase project metadata: $_" -ForegroundColor Red
        exit 1
    }
    Assert-StepSuccess "Supabase authentication check"
    $DeploymentState["2. Authentication Verification"] = $true

    # --------------------------------------------------------------------------
    # Step 3: Exact Three-Way Pinned Project Identity & Region Gate
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 3/8] Validating Three-Way Immutable Project Identity & Region Gate..." -ForegroundColor Yellow

    # --- 1. LOCAL CONFIGURATION VALIDATION (staging.local.json) ---
    if (-not (Test-Path $CONFIG_FILE_PATH)) {
        Write-Host "`n❌ CONFIGURATION ERROR: Private configuration '$CONFIG_FILE_PATH' is missing." -ForegroundColor Red
        Write-Host "Please create 'tools/staging/staging.local.json' with your Supabase Reference ID:" -ForegroundColor Yellow
        Write-Host '  { "projectRef": "your_supabase_dashboard_reference_id" }' -ForegroundColor Yellow
        exit 1
    }

    $rawJsonContent = Get-Content -Path $CONFIG_FILE_PATH -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($rawJsonContent)) {
        Write-Error "CONFIGURATION ERROR: '$CONFIG_FILE_PATH' is empty."
        exit 1
    }

    $localConfig = $null
    try {
        $localConfig = $rawJsonContent | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "CONFIGURATION ERROR: Failed to parse JSON in '$CONFIG_FILE_PATH': $_"
        exit 1
    }

    if ($null -eq $localConfig -or $null -eq $localConfig.projectRef) {
        Write-Error "CONFIGURATION ERROR: Missing required 'projectRef' key in '$CONFIG_FILE_PATH'."
        exit 1
    }

    $PINNED_STAGING_PROJECT_REF = "$($localConfig.projectRef)".Trim()

    if ([string]::IsNullOrWhiteSpace($PINNED_STAGING_PROJECT_REF)) {
        Write-Error "CONFIGURATION ERROR: 'projectRef' in '$CONFIG_FILE_PATH' is empty or whitespace-only."
        exit 1
    }

    # Reject known placeholders
    $placeholderPatterns = @("OWNER_MUST_CONFIGURE_ACTUAL_REFERENCE", "YOUR_STAGING_PROJECT_REF", "YOUR_DASHBOARD_REFERENCE_ID", "^<.*>$")
    foreach ($pat in $placeholderPatterns) {
        if ($PINNED_STAGING_PROJECT_REF -match $pat) {
            Write-Host "`n❌ CONFIGURATION BLOCKED: 'projectRef' in '$CONFIG_FILE_PATH' still contains placeholder value '$PINNED_STAGING_PROJECT_REF'." -ForegroundColor Red
            Write-Host "Please configure your actual Supabase Dashboard Reference ID in 'tools/staging/staging.local.json'." -ForegroundColor Yellow
            exit 1
        }
    }

    # Format verification: must be alphanumeric / hyphen / underscore, minimum 12 chars
    if ($PINNED_STAGING_PROJECT_REF.Length -lt 12 -or $PINNED_STAGING_PROJECT_REF -notmatch "^[a-zA-Z0-9_-]+$") {
        Write-Error "SECURITY GATE: Pinned project reference '$PINNED_STAGING_PROJECT_REF' is malformed. Expected valid Supabase reference."
        exit 1
    }

    # --- 2. CLI PARAMETER VALIDATION (-ProjectRef) ---
    if ([string]::IsNullOrWhiteSpace($ProjectRef)) {
        Write-Error "SECURITY GATE: CLI parameter -ProjectRef is required and cannot be empty. Aborting."
        exit 1
    }

    $ProjectRef = $ProjectRef.Trim()

    # Reject placeholder in CLI parameter
    foreach ($pat in $placeholderPatterns) {
        if ($ProjectRef -match $pat) {
            Write-Error "SECURITY GATE: Supplied -ProjectRef contains placeholder '$ProjectRef'."
            exit 1
        }
    }

    if ($ProjectRef.Length -lt 12 -or $ProjectRef -notmatch "^[a-zA-Z0-9_-]+$") {
        Write-Error "SECURITY GATE: Supplied -ProjectRef '$ProjectRef' is malformed. Expected valid Supabase reference."
        exit 1
    }

    # THREE-WAY CHECK A == B: CLI parameter must strictly equal local staging.local.json pin
    if ($ProjectRef -ne $PINNED_STAGING_PROJECT_REF) {
        Write-Error "SECURITY VIOLATION: Supplied -ProjectRef '$ProjectRef' DOES NOT MATCH local pin '$PINNED_STAGING_PROJECT_REF' in staging.local.json. Aborting to protect unrelated projects!"
        exit 1
    }

    # --- 3. LIVE SUPABASE ACCOUNT METADATA VALIDATION ---
    if (-not $projectsList -or $projectsList.Count -eq 0) {
        Write-Error "SECURITY GATE: No project metadata returned from Supabase CLI. Check authentication and permissions. Aborting."
        exit 1
    }

    # Find all live projects matching pinned reference
    $matchingProjects = @($projectsList | Where-Object { $_.id -eq $PINNED_STAGING_PROJECT_REF })

    # Reject unknown reference
    if ($matchingProjects.Count -eq 0) {
        Write-Error "SECURITY GATE: Pinned project reference '$PINNED_STAGING_PROJECT_REF' not found in your Supabase account. Aborting."
        exit 1
    }

    # Reject duplicate or ambiguous project metadata
    if ($matchingProjects.Count -gt 1) {
        Write-Error "SECURITY VIOLATION: Ambiguous project metadata! Multiple projects returned with reference '$PINNED_STAGING_PROJECT_REF'. Aborting."
        exit 1
    }

    $targetProject = $matchingProjects[0]

    # Reject incomplete project metadata
    if ([string]::IsNullOrWhiteSpace($targetProject.id) -or [string]::IsNullOrWhiteSpace($targetProject.name) -or [string]::IsNullOrWhiteSpace($targetProject.region)) {
        Write-Error "SECURITY GATE: Incomplete project metadata returned from Supabase CLI. Aborting."
        exit 1
    }

    # THREE-WAY CHECK B == C: Live project ID must strictly equal local pin
    if ($targetProject.id -ne $PINNED_STAGING_PROJECT_REF) {
        Write-Error "SECURITY VIOLATION: Live project ID '$($targetProject.id)' does not equal pinned reference '$PINNED_STAGING_PROJECT_REF'. Aborting."
        exit 1
    }

    # Verify project name and region
    if ($targetProject.name -ne $EXPECTED_STAGING_NAME) {
        Write-Error "SECURITY VIOLATION: Project '$PINNED_STAGING_PROJECT_REF' has name '$($targetProject.name)', which DOES NOT strictly match '$EXPECTED_STAGING_NAME'. Aborting!"
        exit 1
    }

    if ($targetProject.region -ne $EXPECTED_STAGING_REGION) {
        Write-Error "REGION MISMATCH: Project region is '$($targetProject.region)', expected '$EXPECTED_STAGING_REGION' (Mumbai). Aborting."
        exit 1
    }

    Write-Host "  ✅ Three-Way Immutable Staging Identity Verified:" -ForegroundColor Green
    Write-Host "     - CLI Parameter (-ProjectRef):       $ProjectRef" -ForegroundColor DarkGray
    Write-Host "     - Local Config (staging.local.json): $PINNED_STAGING_PROJECT_REF" -ForegroundColor DarkGray
    Write-Host "     - Live Supabase Account ID:          $($targetProject.id) ($($targetProject.name), $($targetProject.region))" -ForegroundColor DarkGray
    $DeploymentState["3. Pinned Identity & Region Gate"] = $true

    # --------------------------------------------------------------------------
    # Step 4: Link Project
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 4/8] Linking local repository to pinned staging project ($ProjectRef)..." -ForegroundColor Yellow
    if ($DbPassword) {
        & npx.cmd supabase link --project-ref $ProjectRef --password $DbPassword --yes
    } else {
        & npx.cmd supabase link --project-ref $ProjectRef --yes
    }
    Assert-StepSuccess "Supabase link to staging project"
    $DeploymentState["4. Project Link"] = $true

    # --------------------------------------------------------------------------
    # Step 5: Push 4 Migrations in Sequence
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 5/8] Applying 4 Database Migrations in sequence..." -ForegroundColor Yellow
    if ($DbPassword) {
        & npx.cmd supabase db push --remote --include-all --password $DbPassword --yes
    } else {
        & npx.cmd supabase db push --remote --include-all --yes
    }
    Assert-StepSuccess "Database migrations push"
    $DeploymentState["5. Database Migrations (15 Entities)"] = $true

    # --------------------------------------------------------------------------
    # Step 6: Generate & Set Option A Staging Secrets (Strict CSPRNG)
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 6/8] Generating CSPRNG 256-bit Staging Secret & configuring remote vault..." -ForegroundColor Yellow
    
    # Strictly use System.Security.Cryptography.RandomNumberGenerator (Cryptographically Secure PRNG)
    $secretBytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($secretBytes)
        $stagingSecret = ($secretBytes | ForEach-Object { $_.ToString("x2") }) -join ""

        # Entropy & Length Verification
        if ($secretBytes.Length -lt 32 -or $stagingSecret.Length -ne 64) {
            Write-Error "FATAL CRYPTOGRAPHIC FAILURE: Staging secret failed 256-bit entropy/length check."
            exit 1
        }

        & npx.cmd supabase secrets set "STAGING_IDENTITY_MODE=true" "STAGING_JWT_SECRET=$stagingSecret" --remote=$ProjectRef --yes
        Assert-StepSuccess "Supabase secrets configuration"
        Write-Host "  ✅ 256-bit CSPRNG Secret persisted to Supabase Vault (Value NOT logged, 64-char hex verified)" -ForegroundColor Green
        $DeploymentState["6. Staging Secrets (CSPRNG 256-bit)"] = $true
    }
    finally {
        # Secure cleanup: Dispose RNG and zeroize temporary byte buffer immediately
        $rng.Dispose()
        [Array]::Clear($secretBytes, 0, $secretBytes.Length)
    }

    # --------------------------------------------------------------------------
    # Step 7: Deploy Edge Function
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 7/8] Deploying recharge-bridge Edge Function (Option A)..." -ForegroundColor Yellow
    & npx.cmd supabase functions deploy recharge-bridge --remote=$ProjectRef --no-verify-jwt --use-api --yes
    Assert-StepSuccess "Edge Function deployment"
    $DeploymentState["7. Edge Function Deployment"] = $true

    # --------------------------------------------------------------------------
    # Step 8: Run 10-Vector Remote Smoke Tests
    # --------------------------------------------------------------------------
    Write-Host "`n[Step 8/8] Executing 10-Vector Remote Smoke Tests (Zero Financial Modification)..." -ForegroundColor Yellow
    $edgeUrl = "https://$ProjectRef.supabase.co/functions/v1/recharge-bridge"
    $env:STAGING_EDGE_URL = $edgeUrl
    $env:STAGING_JWT_SECRET = $stagingSecret

    node tools/staging/remote_smoke_test.js
    Assert-StepSuccess "Remote smoke test execution"
    $DeploymentState["8. 10-Vector Smoke Tests (Zero Fin)"] = $true

    Write-Host "`n================================================================================" -ForegroundColor Cyan
    Write-Host "STAGING DEPLOYMENT & VERIFICATION COMPLETED SUCCESSFULLY (100% GREEN)." -ForegroundColor Green
    Write-Host "Production Firebase tekfix-45b38 remained 100% UNTOUCHED." -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Cyan
    Report-DeploymentStatus
}
finally {
    # Guarantees local environment variables are cleared post-execution
    # NOTE: This local session cleanup removes local process env variables only.
    # It does NOT remove encrypted secrets persisted in the hosted Supabase Vault.
    # To rotate or delete remote vault secrets, run: npx supabase secrets unset STAGING_JWT_SECRET
    Remove-Item env:STAGING_JWT_SECRET -ErrorAction SilentlyContinue
    Remove-Item env:STAGING_EDGE_URL -ErrorAction SilentlyContinue
}
