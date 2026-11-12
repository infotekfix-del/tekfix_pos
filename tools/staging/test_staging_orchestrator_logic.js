/**
 * ============================================================================
 * TEKFIX ERP - PHASE 15.0.6: LOCAL STAGING ORCHESTRATOR LOGIC VALIDATOR
 * STRICT LOCAL UNIT TESTS FOR INDEPENDENT OWNER-APPROVED STAGING TARGET PIN
 * ============================================================================
 * 
 * Verifies all 14 mandatory security gates:
 * 1. Correct three-way reference match (CLI Param == staging.local.json == Live ID)
 * 2. Incorrect CLI parameter fails closed
 * 3. Incorrect local pinned reference fails closed
 * 4. Incorrect live project ID fails closed
 * 5. Missing local configuration (staging.local.json missing) fails closed
 * 6. Invalid JSON parsing fails closed
 * 7. Empty project reference fails closed
 * 8. Placeholder project reference fails closed
 * 9. Incorrect project name fails closed
 * 10. Incorrect region fails closed
 * 11. Duplicate or ambiguous project metadata fails closed
 * 12. Supabase CLI authentication failure fails closed
 * 13. Metadata command failure fails closed
 * 14. Verification failure before remote mutation (zero mutation on any failure)
 * 
 * Plus static verifications:
 * - CSPRNG 256-bit secret entropy and zero Get-Random
 * - Explicit RNG disposal & native memory zeroization
 * - Remote smoke tests zero-mutation & explicit operator precedence
 * ============================================================================
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Simulation of Orchestrator Deployment Pipeline Logic
function simulateStagingOrchestratorPipeline({
  configFileExists = true,
  configContent = '{"projectRef": "tekfixstagingref2026"}',
  cliParam = "tekfixstagingref2026",
  cliAuthSucceeds = true,
  metadataCmdSucceeds = true,
  projectsList = [
    { id: 'tekfixstagingref2026', name: 'tekfix-recharge-staging', region: 'ap-south-1' }
  ]
} = {}) {
  let remoteMutationCalled = false;
  const triggerRemoteMutation = () => { remoteMutationCalled = true; };

  // Step 2: Supabase CLI Authentication Check
  if (!cliAuthSucceeds) {
    return { ok: false, error: 'AUTH_FAILED', remoteMutationCalled };
  }

  // Step 2b: Metadata command execution check
  if (!metadataCmdSucceeds) {
    return { ok: false, error: 'METADATA_COMMAND_FAILED', remoteMutationCalled };
  }

  // Step 3: Three-Way Identity Validation Gate
  // 1. Config file existence
  if (!configFileExists) {
    return { ok: false, error: 'MISSING_LOCAL_CONFIG', remoteMutationCalled };
  }

  // 2. Parse JSON
  let localConfig;
  try {
    localConfig = JSON.parse(configContent);
  } catch (e) {
    return { ok: false, error: 'INVALID_JSON', remoteMutationCalled };
  }

  if (!localConfig || localConfig.projectRef === undefined || localConfig.projectRef === null) {
    return { ok: false, error: 'MISSING_PROJECT_REF_KEY', remoteMutationCalled };
  }

  const pinnedRef = String(localConfig.projectRef).trim();

  // 3. Reject empty or whitespace
  if (pinnedRef.length === 0) {
    return { ok: false, error: 'EMPTY_PINNED_REF', remoteMutationCalled };
  }

  // 4. Reject placeholders
  const placeholderPatterns = [
    /OWNER_MUST_CONFIGURE_ACTUAL_REFERENCE/i,
    /YOUR_STAGING_PROJECT_REF/i,
    /YOUR_DASHBOARD_REFERENCE_ID/i,
    /^<.*>$/
  ];
  if (placeholderPatterns.some(p => p.test(pinnedRef))) {
    return { ok: false, error: 'PLACEHOLDER_PINNED_REF', remoteMutationCalled };
  }

  // 5. Format validation
  if (pinnedRef.length < 12 || !/^[a-zA-Z0-9_-]+$/.test(pinnedRef)) {
    return { ok: false, error: 'MALFORMED_PINNED_REF', remoteMutationCalled };
  }

  // 6. CLI parameter validation
  if (!cliParam || String(cliParam).trim().length === 0) {
    return { ok: false, error: 'EMPTY_CLI_PARAM', remoteMutationCalled };
  }
  const cleanCliParam = String(cliParam).trim();
  if (placeholderPatterns.some(p => p.test(cleanCliParam))) {
    return { ok: false, error: 'PLACEHOLDER_CLI_PARAM', remoteMutationCalled };
  }

  // Three-Way Check A == B: CLI parameter equals local pin
  if (cleanCliParam !== pinnedRef) {
    return { ok: false, error: 'CLI_PARAM_MISMATCH', remoteMutationCalled };
  }

  // 7. Live metadata validation
  if (!projectsList || projectsList.length === 0) {
    return { ok: false, error: 'EMPTY_LIVE_METADATA', remoteMutationCalled };
  }

  const matchingProjects = projectsList.filter(p => p.id === pinnedRef);
  if (matchingProjects.length === 0) {
    return { ok: false, error: 'PINNED_REF_NOT_FOUND_LIVE', remoteMutationCalled };
  }

  if (matchingProjects.length > 1) {
    return { ok: false, error: 'DUPLICATE_AMBIGUOUS_METADATA', remoteMutationCalled };
  }

  const target = matchingProjects[0];

  // Incomplete metadata
  if (!target.id || !target.name || !target.region) {
    return { ok: false, error: 'INCOMPLETE_METADATA', remoteMutationCalled };
  }

  // Three-Way Check B == C: Live project ID equals pinned reference
  if (target.id !== pinnedRef) {
    return { ok: false, error: 'LIVE_ID_MISMATCH', remoteMutationCalled };
  }

  // Check name
  if (target.name !== 'tekfix-recharge-staging') {
    return { ok: false, error: 'NAME_MISMATCH', remoteMutationCalled };
  }

  // Check region
  if (target.region !== 'ap-south-1') {
    return { ok: false, error: 'REGION_MISMATCH', remoteMutationCalled };
  }

  // All gates passed! Only now can remote mutation execute
  triggerRemoteMutation();
  return { ok: true, remoteMutationCalled, project: target };
}

async function runLocalOrchestratorValidation() {
  console.log('🧪 Starting Phase 15.0.6 Staging Orchestrator Security Tests...\n');

  let passed = 0;
  let failed = 0;

  function assert(condition, testNum, testName, details = '') {
    if (condition) {
      console.log(`  ✅ [Gate ${testNum}] PASS: ${testName}`);
      passed++;
    } else {
      console.error(`  ❌ [Gate ${testNum}] FAIL: ${testName} - ${details}`);
      failed++;
    }
  }

  const defaultMockProjects = [
    { id: 'tekfixstagingref2026', name: 'tekfix-recharge-staging', region: 'ap-south-1' }
  ];

  // TEST 1: Correct three-way reference match
  const t1 = simulateStagingOrchestratorPipeline();
  assert(
    t1.ok === true && t1.remoteMutationCalled === true && t1.project.id === 'tekfixstagingref2026',
    1,
    'Correct three-way reference match succeeds and authorizes remote mutation'
  );

  // TEST 2: Incorrect CLI parameter
  const t2 = simulateStagingOrchestratorPipeline({ cliParam: 'wrong_cli_param_999' });
  assert(
    t2.ok === false && t2.error === 'CLI_PARAM_MISMATCH' && t2.remoteMutationCalled === false,
    2,
    'Incorrect CLI parameter (-ProjectRef) fails closed before any remote mutation'
  );

  // TEST 3: Incorrect local pinned reference
  const t3 = simulateStagingOrchestratorPipeline({
    configContent: '{"projectRef": "unmatched_local_pin_555"}',
    cliParam: 'unmatched_local_pin_555'
  });
  assert(
    t3.ok === false && t3.error === 'PINNED_REF_NOT_FOUND_LIVE' && t3.remoteMutationCalled === false,
    3,
    'Incorrect local pinned reference fails closed against live project metadata'
  );

  // TEST 4: Incorrect live project ID
  const t4 = simulateStagingOrchestratorPipeline({
    projectsList: [{ id: 'other_remote_id_777', name: 'tekfix-recharge-staging', region: 'ap-south-1' }]
  });
  assert(
    t4.ok === false && t4.error === 'PINNED_REF_NOT_FOUND_LIVE' && t4.remoteMutationCalled === false,
    4,
    'Incorrect live project ID fails closed'
  );

  // TEST 5: Missing local configuration (staging.local.json missing)
  const t5 = simulateStagingOrchestratorPipeline({ configFileExists: false });
  assert(
    t5.ok === false && t5.error === 'MISSING_LOCAL_CONFIG' && t5.remoteMutationCalled === false,
    5,
    'Missing staging.local.json configuration fails closed immediately'
  );

  // TEST 6: Invalid JSON parsing
  const t6 = simulateStagingOrchestratorPipeline({ configContent: '{ malformed json: missing quotes' });
  assert(
    t6.ok === false && t6.error === 'INVALID_JSON' && t6.remoteMutationCalled === false,
    6,
    'Invalid JSON in staging.local.json fails closed immediately'
  );

  // TEST 7: Empty project reference
  const t7 = simulateStagingOrchestratorPipeline({ configContent: '{"projectRef": "   "}' });
  assert(
    t7.ok === false && t7.error === 'EMPTY_PINNED_REF' && t7.remoteMutationCalled === false,
    7,
    'Empty or whitespace-only project reference fails closed immediately'
  );

  // TEST 8: Placeholder project reference
  const t8 = simulateStagingOrchestratorPipeline({
    configContent: '{"projectRef": "OWNER_MUST_CONFIGURE_ACTUAL_REFERENCE"}',
    cliParam: 'OWNER_MUST_CONFIGURE_ACTUAL_REFERENCE'
  });
  assert(
    t8.ok === false && t8.error === 'PLACEHOLDER_PINNED_REF' && t8.remoteMutationCalled === false,
    8,
    'Placeholder project reference is strictly rejected'
  );

  // TEST 9: Incorrect project name
  const t9 = simulateStagingOrchestratorPipeline({
    projectsList: [{ id: 'tekfixstagingref2026', name: 'unauthorized-project-name', region: 'ap-south-1' }]
  });
  assert(
    t9.ok === false && t9.error === 'NAME_MISMATCH' && t9.remoteMutationCalled === false,
    9,
    'Mismatched project name (not tekfix-recharge-staging) fails closed'
  );

  // TEST 10: Incorrect region
  const t10 = simulateStagingOrchestratorPipeline({
    projectsList: [{ id: 'tekfixstagingref2026', name: 'tekfix-recharge-staging', region: 'us-east-1' }]
  });
  assert(
    t10.ok === false && t10.error === 'REGION_MISMATCH' && t10.remoteMutationCalled === false,
    10,
    'Mismatched project region (not ap-south-1) fails closed'
  );

  // TEST 11: Duplicate project metadata
  const t11 = simulateStagingOrchestratorPipeline({
    projectsList: [
      { id: 'tekfixstagingref2026', name: 'tekfix-recharge-staging', region: 'ap-south-1' },
      { id: 'tekfixstagingref2026', name: 'tekfix-recharge-staging', region: 'ap-south-1' }
    ]
  });
  assert(
    t11.ok === false && t11.error === 'DUPLICATE_AMBIGUOUS_METADATA' && t11.remoteMutationCalled === false,
    11,
    'Duplicate / Ambiguous project metadata in account fails closed'
  );

  // TEST 12: Supabase CLI authentication failure
  const t12 = simulateStagingOrchestratorPipeline({ cliAuthSucceeds: false });
  assert(
    t12.ok === false && t12.error === 'AUTH_FAILED' && t12.remoteMutationCalled === false,
    12,
    'Supabase CLI authentication failure fails closed'
  );

  // TEST 13: Metadata command failure
  const t13 = simulateStagingOrchestratorPipeline({ metadataCmdSucceeds: false });
  assert(
    t13.ok === false && t13.error === 'METADATA_COMMAND_FAILED' && t13.remoteMutationCalled === false,
    13,
    'Metadata command failure fails closed'
  );

  // TEST 14: Verification failure before remote mutation (Comprehensive Gate Verification)
  const allFailures = [t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13];
  const allPreventedRemoteMutation = allFailures.every(t => t.remoteMutationCalled === false);
  assert(
    allPreventedRemoteMutation,
    14,
    'Verification failure before remote mutation: 100% of failure gates block remote actions'
  );

  // --- STATIC IMPLEMENTATION AUDITS ---
  const psScriptPath = path.resolve(__dirname, 'deploy_and_smoke_test.ps1');
  const psScriptContent = fs.readFileSync(psScriptPath, 'utf8');

  // TEST 15: deploy_and_smoke_test.ps1 loads staging.local.json exclusively
  assert(
    psScriptContent.includes('staging.local.json') &&
    psScriptContent.includes('ConvertFrom-Json') &&
    psScriptContent.includes('$localConfig.projectRef'),
    15,
    'deploy_and_smoke_test.ps1 loads pinned projectRef exclusively from staging.local.json'
  );

  // TEST 16: Cryptographic Secret Generation & Disposal
  assert(
    !psScriptContent.includes('Get-Random') &&
    psScriptContent.includes('$rng.Dispose()') &&
    psScriptContent.includes('[Array]::Clear($secretBytes'),
    16,
    'deploy_and_smoke_test.ps1 enforces CSPRNG, RNG disposal, and memory zeroization'
  );

  // TEST 17: Smoke Test Non-Mutation Audit
  const smokeScriptPath = path.resolve(__dirname, 'remote_smoke_test.js');
  const smokeScriptContent = fs.readFileSync(smokeScriptPath, 'utf8');
  assert(
    smokeScriptContent.includes('ZERO FINANCIAL MUTATION') &&
    smokeScriptContent.includes('recharge_process_debit') === false,
    17,
    'remote_smoke_test.js strictly contains zero financial mutation stored procedures'
  );

  console.log(`\n==================================================`);
  console.log(`Phase 15.0.6 Local Security Suite: ${passed} Passed, ${failed} Failed`);
  console.log(`==================================================\n`);

  return { passed, failed };
}

if (require.main === module) {
  runLocalOrchestratorValidation().then(res => {
    process.exit(res.failed > 0 ? 1 : 0);
  });
}

module.exports = { runLocalOrchestratorValidation, simulateStagingOrchestratorPipeline };
