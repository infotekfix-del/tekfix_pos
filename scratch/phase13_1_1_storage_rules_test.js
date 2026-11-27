/**
 * Phase 13.1.1 Storage Rules, Configuration & Environment Validation Suite
 *
 * Verifies:
 * 1. Storage security rules structure, default deny, and cross-service Firestore lookups.
 * 2. Whitelisted subfolders (expense_receipts, purchase_invoices, rent_receipts) and payload limits.
 * 3. Android build flavors isolation in build.gradle.kts (prod vs staging applicationIdSuffix).
 * 4. .firebaserc project alias preservation and staging registration.
 * 5. Production configuration immutability.
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`[PASS] ${name}`);
    passed++;
  } catch (err) {
    console.error(`[FAIL] ${name}:`, err.message);
    failed++;
  }
}

console.log('===============================================================');
console.log('TEKFIX ERP - PHASE 13.1.1 STORAGE RULES & CONFIGURATION TESTS');
console.log('===============================================================');

// 1. .firebaserc validation
test('1. .firebaserc preserves default and registers staging alias', () => {
  const rcPath = path.resolve(__dirname, '../.firebaserc');
  const rc = JSON.parse(fs.readFileSync(rcPath, 'utf8'));
  assert.strictEqual(rc.projects.default, 'tekfix-45b38', 'Default must be tekfix-45b38');
  assert.strictEqual(rc.projects.staging, 'tekfix-staging', 'Staging must be tekfix-staging');
});

// 2. firebase.json storage registration
test('2. firebase.json registers storage rules file', () => {
  const jsonPath = path.resolve(__dirname, '../firebase.json');
  const fbJson = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  assert.ok(fbJson.storage, 'storage stanza must exist');
  assert.strictEqual(fbJson.storage.rules, 'firebase/storage.rules');
});

// 3. Storage rules content and security
test('3. firebase/storage.rules enforces rules_version 2 and service firebase.storage', () => {
  const rulesPath = path.resolve(__dirname, '../firebase/storage.rules');
  const rules = fs.readFileSync(rulesPath, 'utf8');
  assert.ok(rules.includes("rules_version = '2';"), 'Must use rules_version 2');
  assert.ok(rules.includes('service firebase.storage'), 'Must declare service firebase.storage');
});

test('4. Storage rules enforces global default-deny', () => {
  const rules = fs.readFileSync(path.resolve(__dirname, '../firebase/storage.rules'), 'utf8');
  assert.ok(rules.includes('match /{allPaths=**} {\n      allow read, write: if false;\n    }'), 'Must default-deny all paths');
});

test('5. Storage rules cross-service Firestore lookups match authoritative schema', () => {
  const rules = fs.readFileSync(path.resolve(__dirname, '../firebase/storage.rules'), 'utf8');
  // Check shop owner Firestore path
  assert.ok(rules.includes('firestore.exists(/databases/(default)/documents/shops/$(shopId))'), 'Must check shop exists');
  assert.ok(rules.includes('firestore.get(/databases/(default)/documents/shops/$(shopId)).data.ownerUid == request.auth.uid'), 'Must verify ownerUid');
  // Check staff Firestore path
  assert.ok(rules.includes('firestore.exists(/databases/(default)/documents/shops/$(shopId)/users/$(request.auth.uid))'), 'Must check staff exists in users collection');
  assert.ok(rules.includes('.data.active != false'), 'Must verify active != false');
  assert.ok(rules.includes('.data.approved != false'), 'Must verify approved != false');
});

test('6. Storage rules explicitly whitelists only the 3 designated business folders', () => {
  const rules = fs.readFileSync(path.resolve(__dirname, '../firebase/storage.rules'), 'utf8');
  assert.ok(rules.includes('match /shops/{shopId}/expense_receipts/{fileName}'), 'expense_receipts allowed');
  assert.ok(rules.includes('match /shops/{shopId}/purchase_invoices/{fileName}'), 'purchase_invoices allowed');
  assert.ok(rules.includes('match /shops/{shopId}/rent_receipts/{fileName}'), 'rent_receipts allowed');

  // Verify generic wildcards are NOT permitted under /shops/{shopId}/
  assert.ok(!rules.includes('match /shops/{shopId}/{allPaths=**}'), 'Generic wildcards under shop must be denied');
});

test('7. Storage rules enforces 10MB limit and restricts MIME types to images and PDF', () => {
  const rules = fs.readFileSync(path.resolve(__dirname, '../firebase/storage.rules'), 'utf8');
  assert.ok(rules.includes('request.resource.size < 10 * 1024 * 1024'), 'Must enforce 10MB limit');
  assert.ok(rules.includes("request.resource.contentType.matches('image/.*')"), 'Must allow images');
  assert.ok(rules.includes("request.resource.contentType == 'application/pdf'"), 'Must allow application/pdf');
});

test('8. lib/storage.rules is synchronized byte-for-byte with firebase/storage.rules', () => {
  const fbRules = fs.readFileSync(path.resolve(__dirname, '../firebase/storage.rules'), 'utf8');
  const libRules = fs.readFileSync(path.resolve(__dirname, '../lib/storage.rules'), 'utf8');
  assert.strictEqual(fbRules, libRules, 'lib/storage.rules must mirror firebase/storage.rules exactly');
});

// 9. Android product flavors verification
test('9. android/app/build.gradle.kts defines prod and staging product flavors', () => {
  const gradlePath = path.resolve(__dirname, '../android/app/build.gradle.kts');
  const gradle = fs.readFileSync(gradlePath, 'utf8');
  assert.ok(gradle.includes('flavorDimensions += "environment"'), 'Must define flavor dimension environment');
  assert.ok(gradle.includes('create("prod")'), 'Must define prod flavor');
  assert.ok(gradle.includes('applicationId = "com.example.tekfix_pos"'), 'Prod flavor must preserve com.example.tekfix_pos');
  assert.ok(gradle.includes('create("staging")'), 'Must define staging flavor');
  assert.ok(gradle.includes('applicationIdSuffix = ".staging"'), 'Staging flavor must use .staging suffix');
});

// 10. Financial logic and recharge immutability
test('10. Recharge service and functions continue using integer paise', () => {
  const fnPath = path.resolve(__dirname, '../firebase/functions/index.js');
  const fnCode = fs.readFileSync(fnPath, 'utf8');
  assert.ok(fnCode.includes('Number.isSafeInteger(amountPaise)'), 'amountPaise safe integer validation intact');
  assert.ok(fnCode.includes('amountPaise <= 0'), 'amountPaise positive integer validation intact');
});

console.log('===============================================================');
console.log(`TOTAL CONFIG & SECURITY TESTS: ${passed + failed} | PASSED: ${passed} | FAILED: ${failed}`);
console.log('===============================================================');

if (failed > 0) process.exit(1);
else process.exit(0);

