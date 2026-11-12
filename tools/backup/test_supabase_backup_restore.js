/**
 * ============================================================================
 * TEKFIX ERP - PHASE 14.9: SUPABASE POSTGRESQL DISASTER RECOVERY TEST SUITE
 * ============================================================================
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { SupabaseBackupRunner, TARGET_TABLES } = require('./supabase_backup_runner');
const { SupabaseRestoreVerifier } = require('./supabase_restore_verifier');

const TEST_BACKUP_DIR = path.resolve(__dirname, '../../backups_test_supabase');
const TEST_KEY = crypto.randomBytes(32).toString('hex');

function cleanupTestDir() {
  if (fs.existsSync(TEST_BACKUP_DIR)) {
    fs.rmSync(TEST_BACKUP_DIR, { recursive: true, force: true });
  }
}

const mockTestData = {
  recharge_wallets: [
    { shop_id: 'shop_test_149', wallet_id: 'WALLET_AIRTEL', operator: 'airtel', own_prepaid_balance_paise: 50000, distributor_credit_balance_paise: 25000 },
    { shop_id: 'shop_test_149', wallet_id: 'WALLET_JIO', operator: 'jio', own_prepaid_balance_paise: 80000, distributor_credit_balance_paise: 0 },
  ],
  recharge_transactions: [
    { shop_id: 'shop_test_149', txn_key: 'TXN_001', wallet_id: 'WALLET_AIRTEL', amount_paise: 29900, funding_type: 'ownPrepaid', status: 'completed' },
    { shop_id: 'shop_test_149', txn_key: 'TXN_002', wallet_id: 'WALLET_JIO', amount_paise: 19900, funding_type: 'ownPrepaid', status: 'completed' },
  ],
  recharge_wallet_logs: [
    { shop_id: 'shop_test_149', log_id: 'LOG_001', wallet_id: 'WALLET_AIRTEL', amount_paise: 29900, entry_type: 'debit', balance_before_paise: 79900, balance_after_paise: 50000 },
  ],
  recharge_distributors: [
    { shop_id: 'shop_test_149', distributor_id: 'DIST_AIRTEL_KERALA', name: 'Airtel Calicut Agency', phone: '9847012345', outstanding_balance_paise: 25000 },
  ],
  recharge_distributor_ledger: [
    { shop_id: 'shop_test_149', entry_id: 'DLE_001', distributor_id: 'DIST_AIRTEL_KERALA', amount_paise: 25000, entry_type: 'credit_extended' },
  ],
  recharge_float_deposits: [
    { shop_id: 'shop_test_149', deposit_id: 'DEP_001', wallet_id: 'WALLET_AIRTEL', amount_paise: 100000, source: 'bank' },
  ],
  recharge_commissions: [
    { shop_id: 'shop_test_149', commission_id: 'COMM_001', txn_key: 'TXN_001', commission_paise: 897, operator: 'airtel' },
  ],
  recharge_refunds: [
    { shop_id: 'shop_test_149', refund_id: 'REF_001', txn_key: 'TXN_OLD', amount_paise: 14900, status: 'completed' },
  ],
  recharge_reversals: [
    { shop_id: 'shop_test_149', reversal_id: 'REV_001', txn_key: 'TXN_REV', amount_paise: 40000, commission_clawback_paise: 1200 },
  ],
  daily_recharge_collections: [
    { shop_id: 'shop_test_149', business_date: '2026-11-09', total_sales_paise: 49800, cash_collected_paise: 49800 },
  ],
  recharge_daily_reconciliation: [
    { shop_id: 'shop_test_149', recon_id: 'REC_001', business_date: '2026-11-09', calculated_balance_paise: 155000, actual_physical_balance_paise: 155000, discrepancy_paise: 0, status: 'balanced' },
  ],
  reconciliation_corrections: [
    { shop_id: 'shop_test_149', correction_id: 'CORR_001', recon_id: 'REC_001', correction_amount_paise: 0, reason: 'No correction needed' },
  ],
  recharge_trusted_devices: [
    { shop_id: 'shop_test_149', device_id: 'DEV_TECNO_KM9', device_type: 'mobile', platform: 'android', is_active: true, is_revoked: false },
    { shop_id: 'shop_test_149', device_id: 'DEV_HP_WIN11', device_type: 'laptop', platform: 'windows', is_active: true, is_revoked: false },
  ],
  recharge_audit_logs: [
    { shop_id: 'shop_test_149', audit_id: 'AUDIT_001', event_type: 'debit', actor_uid: 'UID_OWNER', device_id: 'DEV_TECNO_KM9', entity_id: 'TXN_001' },
  ],
};

async function runTests() {
  console.log('🧪 Starting TekFix Phase 14.9 Supabase PostgreSQL Disaster Recovery Tests...\n');
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
    // TEST 1: Full Table Export
    // ------------------------------------------------------------------------
    console.log('Test 1: All 14 Persistent PostgreSQL Tables Backup...');
    const runner = new SupabaseBackupRunner({
      backupDir: TEST_BACKUP_DIR,
      encryptionKey: TEST_KEY,
      testMode: true,
      shopId: 'shop_test_149',
      mockData: mockTestData,
    });

    const backupResult = await runner.run();
    assert(backupResult.success === true, 'Backup returned success');
    assert(fs.existsSync(backupResult.archivePath), 'Encrypted archive created');
    assert(fs.existsSync(backupResult.manifestPath), 'Manifest file created');
    assert(backupResult.manifest.totalTables === 14, 'All 14 persistent tables included');

    for (const tbl of TARGET_TABLES) {
      assert(backupResult.manifest.tableCounts[tbl] !== undefined, `Table ${tbl} tracked in manifest`);
    }

    // ------------------------------------------------------------------------
    // TEST 2: Verified Restoration
    // ------------------------------------------------------------------------
    console.log('\nTest 2: Verified Decryption & Table Reconstruction...');
    const verifier = new SupabaseRestoreVerifier({
      encryptionKey: TEST_KEY,
      testMode: true,
    });

    const restoreResult = await verifier.verifyAndRestore(backupResult.archivePath, backupResult.manifestPath);
    assert(restoreResult.success === true, 'Restoration and verification success');
    assert(restoreResult.totalRecords === backupResult.totalRecords, 'Total record count identical');
    assert(restoreResult.restoredTables.recharge_wallets.length === 2, 'Wallets restored');
    assert(restoreResult.restoredTables.recharge_trusted_devices.length === 2, 'Trusted devices restored');

    // ------------------------------------------------------------------------
    // TEST 3: Integer Paise Invariants
    // ------------------------------------------------------------------------
    console.log('\nTest 3: Integer Paise Financial Invariant Verification...');
    const expectedWalletsOwn = '130000'; // 50000 + 80000
    const expectedTxnSum = '49800'; // 29900 + 19900
    assert(restoreResult.integerPaiseSums.wallets_own_prepaid_paise === expectedWalletsOwn, `Prepaid sum exact: ${expectedWalletsOwn} paise`);
    assert(restoreResult.integerPaiseSums.transactions_total_paise === expectedTxnSum, `Txn sum exact: ${expectedTxnSum} paise`);

    // ------------------------------------------------------------------------
    // TEST 4: Tamper Detection (Bit-Flip Protection)
    // ------------------------------------------------------------------------
    console.log('\nTest 4: Tamper Detection (Bit-Flip Defense)...');
    const encryptedBuf = fs.readFileSync(backupResult.archivePath);
    encryptedBuf[encryptedBuf.length - 10] ^= 0xFF; // Flip byte in ciphertext
    const tamperedPath = path.join(TEST_BACKUP_DIR, 'tampered.enc');
    fs.writeFileSync(tamperedPath, encryptedBuf);

    let caughtTamper = false;
    try {
      await verifier.verifyAndRestore(tamperedPath, backupResult.manifestPath);
    } catch (e) {
      caughtTamper = true;
      assert(true, `Tampered archive rejected: ${e.message}`);
    }
    assert(caughtTamper, 'Tamper verification successfully caught corruption');

    // ------------------------------------------------------------------------
    // TEST 5: Wrong Encryption Key Rejection
    // ------------------------------------------------------------------------
    console.log('\nTest 5: Wrong Encryption Key Rejection...');
    const wrongVerifier = new SupabaseRestoreVerifier({
      encryptionKey: crypto.randomBytes(32).toString('hex'),
      testMode: true,
    });

    let caughtWrongKey = false;
    try {
      await wrongVerifier.verifyAndRestore(backupResult.archivePath, backupResult.manifestPath);
    } catch (e) {
      caughtWrongKey = true;
      assert(true, `Wrong key rejected: ${e.message}`);
    }
    assert(caughtWrongKey, 'Wrong key decryption failed safely');

  } catch (err) {
    console.error('Test execution failed:', err);
    failed++;
  } finally {
    cleanupTestDir();
  }

  console.log(`\n==================================================`);
  console.log(`Phase 14.9 Supabase DR Results: ${passed} Passed, ${failed} Failed`);
  console.log(`==================================================\n`);

  if (failed > 0) process.exit(1);
}

runTests();

