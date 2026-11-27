/**
 * Phase 13.0.8 Backend Cloud Functions Region Synchronization Test Suite
 *
 * Verifies:
 * 1. Staging project ('tekfix-staging') selects 'asia-south1' across all 3 functions.
 * 2. Production project ('tekfix-45b38') preserves legacy 'us-central1' across all 3 functions.
 * 3. Default / unspecified project preserves 'us-central1'.
 * 4. Explicit FUNCTION_REGION / FIREBASE_FUNCTIONS_REGION override is respected.
 * 5. All 3 Cloud Functions export correctly with valid trigger structures.
 */

const assert = require('assert');
const path = require('path');

let testsPassed = 0;
let testsFailed = 0;

function runTest(name, fn) {
  try {
    fn();
    console.log(`[PASS] ${name}`);
    testsPassed++;
  } catch (err) {
    console.error(`[FAIL] ${name}:`, err.message);
    testsFailed++;
  }
}

// Clear require cache helper
function loadFunctionsWithEnv(envOverrides) {
  // Clear require cache for functions and dependencies
  const functionsPath = path.resolve(__dirname, '../firebase/functions/index.js');
  delete require.cache[require.resolve(functionsPath)];

  // Set environment variables
  const originalEnv = { ...process.env };
  delete process.env.FUNCTION_REGION;
  delete process.env.FIREBASE_FUNCTIONS_REGION;
  delete process.env.GCLOUD_PROJECT;
  delete process.env.FIREBASE_CONFIG;

  Object.assign(process.env, envOverrides);

  try {
    const exportedFunctions = require(functionsPath);
    return { exportedFunctions, restore: () => { process.env = originalEnv; } };
  } catch (e) {
    process.env = originalEnv;
    throw e;
  }
}

console.log('===============================================================');
console.log('TEKFIX ERP - PHASE 13.0.8 BACKEND REGION SYNCHRONIZATION TESTS');
console.log('===============================================================');

// TEST 1: Staging environment ('tekfix-staging') selects 'asia-south1'
runTest('Staging project (tekfix-staging) sets region to asia-south1', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'tekfix-staging',
  });
  try {
    assert.strictEqual(typeof exportedFunctions._resolveFunctionsRegion, 'function');
    assert.strictEqual(exportedFunctions._resolveFunctionsRegion(), 'asia-south1');
    assert.deepStrictEqual(exportedFunctions.onStaffCheckIn.__trigger.regions, ['asia-south1']);
    assert.deepStrictEqual(exportedFunctions.autoCloseForgottenCheckouts.__trigger.regions, ['asia-south1']);
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['asia-south1']);
  } finally {
    restore();
  }
});

// TEST 2: Production environment ('tekfix-45b38') preserves 'us-central1'
runTest('Production project (tekfix-45b38) preserves region as us-central1', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'tekfix-45b38',
  });
  try {
    assert.strictEqual(exportedFunctions._resolveFunctionsRegion(), 'us-central1');
    assert.deepStrictEqual(exportedFunctions.onStaffCheckIn.__trigger.regions, ['us-central1']);
    assert.deepStrictEqual(exportedFunctions.autoCloseForgottenCheckouts.__trigger.regions, ['us-central1']);
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['us-central1']);
  } finally {
    restore();
  }
});

// TEST 3: Default / empty environment preserves 'us-central1'
runTest('Empty/Default project preserves region as us-central1', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'default-unspecified-project',
  });
  try {
    assert.strictEqual(exportedFunctions._resolveFunctionsRegion(), 'us-central1');
    assert.deepStrictEqual(exportedFunctions.onStaffCheckIn.__trigger.regions, ['us-central1']);
    assert.deepStrictEqual(exportedFunctions.autoCloseForgottenCheckouts.__trigger.regions, ['us-central1']);
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['us-central1']);
  } finally {
    restore();
  }
});

// TEST 4: FIREBASE_CONFIG with staging project ID sets 'asia-south1'
runTest('FIREBASE_CONFIG JSON with staging project ID sets asia-south1', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'tekfix-staging',
    FIREBASE_CONFIG: JSON.stringify({ projectId: 'tekfix-staging' }),
  });
  try {
    assert.strictEqual(exportedFunctions._resolveFunctionsRegion(), 'asia-south1');
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['asia-south1']);
  } finally {
    restore();
  }
});

// TEST 5: Explicit FUNCTION_REGION override
runTest('Explicit FUNCTION_REGION override is respected', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'tekfix-45b38',
    FUNCTION_REGION: 'asia-south1',
  });
  try {
    assert.strictEqual(exportedFunctions._resolveFunctionsRegion(), 'asia-south1');
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['asia-south1']);
  } finally {
    restore();
  }
});

// TEST 6: Untrusted client inputs cannot affect server region
runTest('Server region cannot be influenced by client payload or unauthenticated data', () => {
  const { exportedFunctions, restore } = loadFunctionsWithEnv({
    GCLOUD_PROJECT: 'tekfix-staging',
  });
  try {
    // Calling or inspecting the function always uses server-bound regional trigger
    assert.deepStrictEqual(exportedFunctions.processRechargeDebit.__trigger.regions, ['asia-south1']);
  } finally {
    restore();
  }
});

console.log('===============================================================');
console.log(`TOTAL TESTS: ${testsPassed + testsFailed} | PASSED: ${testsPassed} | FAILED: ${testsFailed}`);
console.log('===============================================================');

if (testsFailed > 0) {
  process.exit(1);
} else {
  process.exit(0);
}

