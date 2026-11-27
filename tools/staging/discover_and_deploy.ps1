# ==============================================================================
# TEKFIX ERP — PHASE 15.1.1: AUTONOMOUS STAGING DISCOVERY & DEPLOYMENT RUNNER
# STRICT SAFETY: PRODUCTION FIREBASE tekfix-45b38 REMAINS COMPLETELY UNTOUCHED
# ==============================================================================

param(
    [string]$DbPassword = ""
)

$ErrorActionPreference = "Stop"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "TEKFIX ERP - PHASE 15.1.1 AUTONOMOUS STAGING DISCOVERY & DEPLOYMENT" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Step 1: Check CLI Authentication
# ------------------------------------------------------------------------------
Write-Host "`n[Step 1] Checking Supabase CLI Authentication..." -ForegroundColor Yellow
$projectsJson = cmd.exe /c "npx.cmd supabase projects list --output-format json 2>nul"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectsJson) -or $projectsJson -match "AccessTokenRequiredError") {
    Write-Host "`n❌ Supabase CLI is not authenticated." -ForegroundColor Red
    Write-Host "Please complete the login in your terminal:" -ForegroundColor Yellow
    Write-Host "  npx.cmd supabase login" -ForegroundColor Yellow
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
    Write-Host "❌ Failed to parse Supabase projects output: $_" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# Step 2: Automatic Discovery of tekfix-recharge-staging
# ------------------------------------------------------------------------------
Write-Host "`n[Step 2] Discovering target staging project 'tekfix-recharge-staging' in 'ap-south-1'..." -ForegroundColor Yellow
$matchingProjects = @($projectsList | Where-Object { $_.name -eq "tekfix-recharge-staging" -and $_.region -eq "ap-south-1" })

if ($matchingProjects.Count -eq 0) {
    Write-Host "`n❌ Project Discovery Gate Failed: No project named 'tekfix-recharge-staging' found in region 'ap-south-1'." -ForegroundColor Red
    Write-Host "Please verify that the staging project has been created on your Supabase Dashboard." -ForegroundColor Yellow
    exit 1
}

if ($matchingProjects.Count -gt 1) {
    Write-Host "`n❌ Ambiguity Violation: Multiple projects named 'tekfix-recharge-staging' in 'ap-south-1'." -ForegroundColor Red
    exit 1
}

$discoveredProject = $matchingProjects[0]
$discoveredRef = "$($discoveredProject.id)".Trim()
Write-Host "  ✅ Target project discovered:" -ForegroundColor Green
Write-Host "     - Project Name: $($discoveredProject.name)" -ForegroundColor DarkGray
Write-Host "     - Region:       $($discoveredProject.region) (Mumbai)" -ForegroundColor DarkGray
Write-Host "     - Reference ID: $discoveredRef" -ForegroundColor DarkGray

# ------------------------------------------------------------------------------
# Step 3: Populate tools/staging/staging.local.json
# ------------------------------------------------------------------------------
Write-Host "`n[Step 3] Updating tools/staging/staging.local.json with discovered Reference ID..." -ForegroundColor Yellow
$configPath = Join-Path $PSScriptRoot "staging.local.json"
$configContent = @"
{
  "projectRef": "$discoveredRef"
}
"@

Set-Content -Path $configPath -Value $configContent -Encoding utf8
Write-Host "  ✅ staging.local.json successfully populated with Reference ID: $discoveredRef" -ForegroundColor Green

# ------------------------------------------------------------------------------
# Step 4: Execute Deploy and Smoke Test Orchestrator
# ------------------------------------------------------------------------------
Write-Host "`n[Step 4] Handing over to 3-Way Identity Deploy & Smoke Test Orchestrator..." -ForegroundColor Yellow
$deployScript = Join-Path $PSScriptRoot "deploy_and_smoke_test.ps1"

if ($DbPassword) {
    & $deployScript -ProjectRef $discoveredRef -DbPassword $DbPassword
} else {
    & $deployScript -ProjectRef $discoveredRef
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n❌ Deployment orchestrator failed with exit code $LASTEXITCODE." -ForegroundColor Red
    exit $LASTEXITCODE
}

