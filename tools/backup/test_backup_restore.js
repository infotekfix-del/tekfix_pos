/**
 * ============================================================================
 * TEKFIX ERP - PHASE 14.1: BACKUP & RESTORE INTEGRATION TEST SUITE
 * ============================================================================
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { BackupRunner, RETENTION_DAYS } = require('./backup_runner');
const { RestoreVerifier } = require('./restore_verifier');

async function runTests() {
  console.log('🧪 Starting Backup & Restore Integration Test Suite...\n');

  const testBackupDir = path.resolve(__dirname, '../../test_backups_temp');
  if (fs.existsSync(testBackupDir)) {
    fs.rmSync(testBackupDir, { recursive: true, force: true });
  }
  fs.mkdirSync(testBackupDir, { recursive: true });

  const testKey = crypto.randomBytes(32).toString('hex');
  let passedTests = 0;

  try {
    // -------------------------------------------------------------------------
    // TEST 1: Backup creation, AES-256-GCM encryption & manifest generation
    // -------------------------------------------------------------------------
    console.log('Test 1: Running BackupRunner...');
    const runner = new BackupRunner({
      backupDir: testBackupDir,
      encryptionKey: testKey,
      testMode: true,
    });

    const backupResult = await runner.run();
    if (!backupResult.success) throw new Error('BackupRunner reported failure');
    if (!fs.existsSync(backupResult.archivePath)) throw new Error('Encrypted archive not found on disk');
    if (!fs.existsSync(backupResult.manifestPath)) throw new Error('Manifest file not found on disk');

    // Confirm unencrypted raw SQL dump is NOT left on disk
    const unencryptedDump = backupResult.archivePath.replace('.enc.bin', '.sql');
    if (fs.existsSync(unencryptedDump)) {
      throw new Error('Security Violation: Unencrypted SQL dump was left on disk!');
    }

    console.log('  ✅ Test 1 Passed: Encrypted archive created, unencrypted dump destroyed.');
    passedTests++;

    // -------------------------------------------------------------------------
    // TEST 2: RestoreVerifier valid decryption drill
    // -------------------------------------------------------------------------
    console.log('Test 2: Running RestoreVerifier on clean backup...');
    const verifier = new RestoreVerifier({
      encryptionKey: testKey,
    });

    const verifyResult = verifier.verifyAndDecrypt(backupResult.archivePath, backupResult.manifestPath);
    if (!verifyResult.success) throw new Error('RestoreVerifier failed on valid archive');
    if (!verifyResult.encryptedChecksumValid) throw new Error('Encrypted checksum invalid');
    if (!verifyResult.authTagValid) throw new Error('Auth tag invalid');
    if (!verifyResult.plainChecksumValid) throw new Error('Plaintext checksum invalid');
    if (!verifyResult.structureChecks.hasRechargeWallets) throw new Error('Missing recharge_wallets in SQL');

    console.log('  ✅ Test 2 Passed: Full restore drill verified with exact SHA-256 & Auth Tag match.');
    passedTests++;

    // -------------------------------------------------------------------------
    // TEST 3: Tamper Detection - Bit flipped in ciphertext
    // -------------------------------------------------------------------------
    console.log('Test 3: Testing Tamper Detection (Bit modification in ciphertext)...');
    const tamperedArchivePath = path.join(testBackupDir, 'tampered.enc.bin');
    const rawArchive = fs.readFileSync(backupResult.archivePath);
    // Tamper the 50th byte
    rawArchive[50] = rawArchive[50] ^ 0xFF;
    fs.writeFileSync(tamperedArchivePath, rawArchive);

    let caughtTamper = false;
    try {
      verifier.verifyAndDecrypt(tamperedArchivePath, backupResult.manifestPath);
    } catch (err) {
      caughtTamper = true;
      console.log(`  Expected Rejection: ${err.message}`);
    }

    if (!caughtTamper) {
      throw new Error('Security Violation: Tampered archive was not rejected!');
    }
    console.log('  ✅ Test 3 Passed: Tampered archive rejected immediately.');
    passedTests++;

    // -------------------------------------------------------------------------
    // TEST 4: Wrong Encryption Key Rejection
    // -------------------------------------------------------------------------
    console.log('Test 4: Testing Wrong Encryption Key Rejection...');
    const wrongKey = crypto.randomBytes(32).toString('hex');
    const wrongVerifier = new RestoreVerifier({ encryptionKey: wrongKey });

    let caughtWrongKey = false;
    try {
      wrongVerifier.verifyAndDecrypt(backupResult.archivePath, backupResult.manifestPath);
    } catch (err) {
      caughtWrongKey = true;
      console.log(`  Expected Rejection: ${err.message}`);
    }

    if (!caughtWrongKey) {
      throw new Error('Security Violation: Archive decrypted with incorrect key!');
    }
    console.log('  ✅ Test 4 Passed: Wrong key rejected by AES-256-GCM authentication tag.');
    passedTests++;

    // -------------------------------------------------------------------------
    // TEST 5: Retention Pruning (>30 days vs <=30 days)
    // -------------------------------------------------------------------------
    console.log('Test 5: Testing 30-Day Retention Pruning...');
    // Create a dummy 45-day old backup file
    const oldFileName = path.join(testBackupDir, 'tekfix_backup_2026-09-01T00-00-00-000Z.enc.bin');
    fs.writeFileSync(oldFileName, 'dummy-old-data');
    const pastTime = (Date.now() - (45 * 24 * 60 * 60 * 1000)) / 1000;
    fs.utimesSync(oldFileName, pastTime, pastTime);

    // Create a fresh 5-day old backup file
    const recentFileName = path.join(testBackupDir, 'tekfix_backup_2026-11-04T00-00-00-000Z.enc.bin');
    fs.writeFileSync(recentFileName, 'dummy-recent-data');
    const recentTime = (Date.now() - (5 * 24 * 60 * 60 * 1000)) / 1000;
    fs.utimesSync(recentFileName, recentTime, recentTime);

    const pruned = runner.pruneOldBackups();
    if (!pruned.includes(path.basename(oldFileName))) {
      throw new Error('Old backup (>30 days) was NOT pruned!');
    }
    if (fs.existsSync(oldFileName)) {
      throw new Error('Old backup file still exists on disk!');
    }
    if (!fs.existsSync(recentFileName)) {
      throw new Error('Recent backup (<30 days) was incorrectly deleted!');
    }

    console.log(`  ✅ Test 5 Passed: 45-day archive pruned; 5-day archive safely retained.`);
    passedTests++;

    console.log(`\n🎉 All ${passedTests} Backup & Restore Integration Tests PASSED successfully!`);
  } finally {
    if (fs.existsSync(testBackupDir)) {
      try { fs.rmSync(testBackupDir, { recursive: true, force: true }); } catch (_) {}
    }
  }
}

runTests().catch((err) => {
  console.error('\n❌ Backup & Restore Integration Test Failed:', err);
  process.exit(1);
});

