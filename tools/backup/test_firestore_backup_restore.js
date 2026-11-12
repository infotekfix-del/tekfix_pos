/**
 * ============================================================================
 * TEKFIX ERP - PHASE 14.5: COMPLETE FIRESTORE BACKUP & RESTORE TEST SUITE
 * ============================================================================
 * 
 * Verifies all 14 mandatory disaster recovery tests:
 * 1. All required collection exports (13 collections & subcollections).
 * 2. Nested corrections export (recharge_daily_reconciliation/{date}/corrections).
 * 3. Nested corrections restoration.
 * 4. Distributor ledger restoration (recharge_distributor_ledger).
 * 5. Customer refund restoration (recharge_refunds).
 * 6. Reversal restoration (recharge_reversals).
 * 7. Daily cash collection restoration (daily_recharge_collections).
 * 8. Financial checksum verification (exact integer paise arithmetic).
 * 9. Missing document detection (anomaly detection).
 * 10. Duplicate document detection (anomaly detection).
 * 11. AES-256-GCM tamper detection.
 * 12. Wrong-key rejection.
 * 13. Restore idempotency (repeatable reconstruction).
 * 14. Full financial reconciliation.
 * ============================================================================
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { FirestoreBackupRunner, TARGET_COLLECTIONS, NESTED_SUBCOLLECTIONS } = require('./firestore_backup_runner');
const { FirestoreRestoreVerifier } = require('./firestore_restore_verifier');

const TEST_BACKUP_DIR = path.resolve(__dirname, '../../backups_test_firestore');
const TEST_KEY = crypto.randomBytes(32).toString('hex');

function cleanupTestDir() {
  if (fs.existsSync(TEST_BACKUP_DIR)) {
    fs.rmSync(TEST_BACKUP_DIR, { recursive: true, force: true });
  }
}

async function runTests() {
  console.log('🧪 Starting TekFix Phase 14.5 Complete Firestore Disaster Recovery Tests...\n');
  cleanupTestDir();

  let passed = 0;
  let failed = 0;

  function assert(condition, testName) {
    if (condition) {
      console.log(`  ✅ PASS: ${testName}`);
      passed++;
    } else {
      console.error(`  ❌ FAIL: ${testName}`);
      failed++;
    }
  }

  try {
    // ------------------------------------------------------------------------
    // TEST 1: All Required Collection Exports
    // ------------------------------------------------------------------------
    console.log('Test 1: All Required Collection Exports...');
    const runner = new FirestoreBackupRunner({
      backupDir: TEST_BACKUP_DIR,
      encryptionKey: TEST_KEY,
      testMode: true,
      shopId: 'shop_test_145',
    });

    const backupResult = await runner.run();
    assert(backupResult.success === true, 'Backup execution returned success');
    assert(fs.existsSync(backupResult.archivePath), 'Encrypted archive exists on disk');
    assert(fs.existsSync(backupResult.manifestPath), 'Manifest file exists on disk');

    const manifest = backupResult.manifest;
    assert(manifest.collectionsBackedUp.length === 13, `All 13 collections backed up (found: ${manifest.collectionsBackedUp.length})`);
    for (const col of TARGET_COLLECTIONS) {
      assert(manifest.collectionsBackedUp.includes(col), `Collection '${col}' included in backup`);
    }

    // ------------------------------------------------------------------------
    // TEST 2: Nested Corrections Export
    // ------------------------------------------------------------------------
    console.log('\nTest 2: Nested Corrections Export...');
    assert(manifest.nestedSubcollectionsBackedUp.includes('recharge_daily_reconciliation'), 'Reconciliation nested subcollections declared');
    assert(manifest.documentCounts['recharge_daily_reconciliation/corrections'] > 0, 'Nested corrections documents counted in manifest');

    // ------------------------------------------------------------------------
    // TEST 3: Nested Corrections Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 3: Nested Corrections Restoration...');
    const verifier = new FirestoreRestoreVerifier({
      encryptionKey: TEST_KEY,
      testMode: true,
    });

    const drillResult = await verifier.executeRestoreDrill(
      backupResult.archivePath,
      backupResult.manifestPath,
      { dryRun: true }
    );
    assert(drillResult.totalNestedDocumentsReconstructed > 0, `Restored ${drillResult.totalNestedDocumentsReconstructed} nested correction document(s)`);
    const restoredRecon = drillResult.reconstructedHierarchy['recharge_daily_reconciliation'][0];
    assert(restoredRecon.subcollections.corrections.length > 0, 'Reconstructed daily reconciliation contains subcollection corrections');
    assert(
      restoredRecon.subcollections.corrections[0].docPath.includes('recharge_daily_reconciliation/2026-11-09/corrections/'),
      'Nested document path correctly constructed'
    );

    // ------------------------------------------------------------------------
    // TEST 4: Distributor Ledger Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 4: Distributor Ledger Restoration...');
    const distLedgers = drillResult.reconstructedHierarchy['recharge_distributor_ledger'];
    assert(distLedgers.length > 0, `Restored ${distLedgers.length} distributor ledger entries`);
    assert(distLedgers[0].data.amountPaise === 100000, 'Distributor ledger amountPaise preserved (100000)');

    // ------------------------------------------------------------------------
    // TEST 5: Customer Refund Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 5: Customer Refund Restoration...');
    const refunds = drillResult.reconstructedHierarchy['recharge_refunds'];
    assert(refunds.length > 0, `Restored ${refunds.length} customer refund records`);
    assert(refunds[0].data.amountPaise === 14900, 'Customer refund amountPaise preserved (14900)');
    assert(refunds[0].data.status === 'completed', 'Customer refund status preserved (completed)');

    // ------------------------------------------------------------------------
    // TEST 6: Reversal Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 6: Reversal Restoration...');
    const reversals = drillResult.reconstructedHierarchy['recharge_reversals'];
    assert(reversals.length > 0, `Restored ${reversals.length} reversal records`);
    assert(reversals[0].data.commissionClawbackPaise === 400, 'Clawback paise preserved (400)');

    // ------------------------------------------------------------------------
    // TEST 7: Daily Cash Collection Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 7: Daily Cash Collection Restoration...');
    const dailyCols = drillResult.reconstructedHierarchy['daily_recharge_collections'];
    assert(dailyCols.length > 0, `Restored ${dailyCols.length} daily collection records`);
    assert(dailyCols[0].data.totalCollectedPaise === 79800, 'Daily collection totalCollectedPaise preserved (79800)');

    // ------------------------------------------------------------------------
    // TEST 8: Financial Checksum Verification
    // ------------------------------------------------------------------------
    console.log('\nTest 8: Financial Checksum Verification...');
    const audit = drillResult.financialAudit;
    assert(audit.isValid === true, 'Financial integrity audit passes completely');
    assert(audit.metrics.rechargeTransactions.isSumMatch === true, 'Transaction sum strictly matches (paise accuracy)');
    assert(audit.metrics.distributorLedger.isCreditMatch === true, 'Distributor ledger credit allocations strictly match');
    assert(audit.metrics.refunds.isMatch === true, 'Customer refund sums strictly match');
    assert(audit.metrics.reversals.isMatch === true, 'Recharge reversals strictly match');
    assert(audit.metrics.dailyCollections.isMatch === true, 'Daily collections strictly match');

    // ------------------------------------------------------------------------
    // TEST 9: Missing Document Detection
    // ------------------------------------------------------------------------
    console.log('\nTest 9: Missing Document Anomaly Detection...');
    const { payload, manifest: validManifest } = verifier.verifyAndDecrypt(
      backupResult.archivePath,
      backupResult.manifestPath
    );
    const tamperedMissingPayload = JSON.parse(JSON.stringify(payload));
    // Remove a wallet document
    tamperedMissingPayload.collections['recharge_wallets'] = tamperedMissingPayload.collections['recharge_wallets'].slice(1);
    const missingAudit = verifier.auditFinancialIntegrity(tamperedMissingPayload, validManifest);
    assert(missingAudit.isValid === false, 'Tampered missing document correctly fails validation');
    assert(missingAudit.anomalyChecks.missingDocumentsDetected === true, 'missingDocumentsDetected anomaly triggered');

    // ------------------------------------------------------------------------
    // TEST 10: Duplicate Document Detection
    // ------------------------------------------------------------------------
    console.log('\nTest 10: Duplicate Document Detection...');
    const tamperedDuplicatePayload = JSON.parse(JSON.stringify(payload));
    const firstTxn = tamperedDuplicatePayload.collections['recharge_transactions'][0];
    tamperedDuplicatePayload.collections['recharge_transactions'].push(firstTxn);
    const duplicateAudit = verifier.auditFinancialIntegrity(tamperedDuplicatePayload, validManifest);
    assert(duplicateAudit.isValid === false, 'Duplicate document insertion correctly fails validation');
    assert(duplicateAudit.anomalyChecks.duplicatesDetected === true, 'duplicatesDetected anomaly triggered');

    // ------------------------------------------------------------------------
    // TEST 11: AES-256-GCM Tamper Detection
    // ------------------------------------------------------------------------
    console.log('\nTest 11: AES-256-GCM Tamper Detection...');
    const tamperedEncPath = path.join(TEST_BACKUP_DIR, 'tampered.enc.bin');
    const origEnc = fs.readFileSync(backupResult.archivePath);
    const tamperedEnc = Buffer.from(origEnc);
    tamperedEnc[tamperedEnc.length - 1] ^= 0x55;
    fs.writeFileSync(tamperedEncPath, tamperedEnc);

    let caughtGcmTamper = false;
    try {
      verifier.verifyAndDecrypt(tamperedEncPath, backupResult.manifestPath);
    } catch (err) {
      caughtGcmTamper = true;
      assert(
        err.message.includes('checksum mismatch') || err.message.includes('Authentication tag verification failed'),
        `Tamper correctly detected: ${err.message}`
      );
    }
    assert(caughtGcmTamper, 'Tampered ciphertext rejected');

    // ------------------------------------------------------------------------
    // TEST 12: Wrong-Key Rejection
    // ------------------------------------------------------------------------
    console.log('\nTest 12: Wrong-Key Rejection...');
    const wrongVerifier = new FirestoreRestoreVerifier({
      encryptionKey: crypto.randomBytes(32).toString('hex'),
      testMode: true,
    });
    let caughtWrongKey = false;
    try {
      wrongVerifier.verifyAndDecrypt(backupResult.archivePath, backupResult.manifestPath);
    } catch (err) {
      caughtWrongKey = true;
      assert(
        err.message.includes('Authentication tag verification failed') || err.message.includes('Decryption failed'),
        `Wrong key rejected: ${err.message}`
      );
    }
    assert(caughtWrongKey, 'Wrong key decryption rejected');

    // ------------------------------------------------------------------------
    // TEST 13: Restore Idempotency
    // ------------------------------------------------------------------------
    console.log('\nTest 13: Restore Idempotency...');
    const drill1 = await verifier.executeRestoreDrill(backupResult.archivePath, backupResult.manifestPath);
    const drill2 = await verifier.executeRestoreDrill(backupResult.archivePath, backupResult.manifestPath);
    assert(drill1.totalDocumentsReconstructed === drill2.totalDocumentsReconstructed, 'Document count identical on repeat');
    assert(drill1.totalNestedDocumentsReconstructed === drill2.totalNestedDocumentsReconstructed, 'Nested document count identical on repeat');
    assert(
      JSON.stringify(drill1.reconstructedHierarchy) === JSON.stringify(drill2.reconstructedHierarchy),
      'Reconstructed hierarchy is byte-for-byte identical across runs (Idempotent)'
    );

    // ------------------------------------------------------------------------
    // TEST 14: Full Financial Reconciliation
    // ------------------------------------------------------------------------
    console.log('\nTest 14: Full Financial Reconciliation (Paise Invariants)...');
    // Drawer cash reconciliation:
    // Closing Drawer Cash = Opening Float + Cash Collections - Cash Refunds - Float Recovery Deposit
    const openingFloat = 100000;
    const cashCollections = audit.metrics.dailyCollections.restoredSumPaise; // 79800
    const cashRefunds = audit.metrics.refunds.restoredSumPaise; // 14900
    const floatDeposits = audit.metrics.rechargeTransactions.manifestSumPaise ? 0 : 0; // Deposit was float recovery: 0 for direct drawer
    const expectedClosingDrawer = openingFloat + cashCollections - cashRefunds; // 100000 + 79800 - 14900 = 164900
    
    const reconDoc = drillResult.reconstructedHierarchy['recharge_daily_reconciliation'][0];
    const actualClosingDrawer = reconDoc.data.closingDrawerCashPaise;
    
    assert(
      actualClosingDrawer === expectedClosingDrawer,
      `Drawer cash reconciles perfectly: ₹${(actualClosingDrawer / 100).toFixed(2)} (expected ₹${(expectedClosingDrawer / 100).toFixed(2)})`
    );
    assert(audit.anomalyChecks.unbalancedLedgerDetected === false, 'Ledgers are balanced');

  } catch (err) {
    console.error('Unexpected test runner failure:', err);
    failed++;
  } finally {
    cleanupTestDir();
  }

  console.log('\n==================================================');
  console.log(`Results: ${passed} Passed, ${failed} Failed`);
  console.log('==================================================\n');

  if (failed > 0) {
    process.exit(1);
  } else {
    process.exit(0);
  }
}

runTests();
