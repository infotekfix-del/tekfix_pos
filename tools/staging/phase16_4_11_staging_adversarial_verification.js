/**
 * ============================================================================
 * TEKFIX ERP — PHASE 16.4.11: STAGING ADVERSARIAL VERIFICATION SUITE
 * STRICT READ-ONLY ON PRODUCTION; EXECUTES ADVERSARIAL PROBES ON STAGING
 * ============================================================================
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const STAGING_REF = 'mwhsvidbrfkryuiwhnev';
const REPO_ROOT = path.resolve(__dirname, '../..');

function runStagingSql(sql) {
  const tempFile = path.join(REPO_ROOT, 'tools', 'staging', `_tmp_adv_${Date.now()}_${Math.random().toString(36).substring(2, 6)}.sql`);
  fs.writeFileSync(tempFile, sql, 'utf8');
  try {
    const cmd = `npx.cmd supabase db query --remote=${STAGING_REF} --yes -f "${tempFile}"`;
    const out = execSync(cmd, { cwd: REPO_ROOT, encoding: 'utf8' });
    return { success: true, output: out };
  } catch (err) {
    return { success: false, output: err.stdout || err.stderr || err.message };
  } finally {
    try { fs.unlinkSync(tempFile); } catch (_) {}
  }
}

async function runAdversarialAudit() {
  console.log('================================================================================');
  console.log('TEKFIX ERP — PHASE 16.4.11 STAGING ADVERSARIAL AUDIT');
  console.log('Target Database: Supabase Staging (mwhsvidbrfkryuiwhnev)');
  console.log('================================================================================\n');

  const testShop = 'shop_adv_test_' + Date.now();
  const testWallet = 'WALLET_VI';

  // --- Step 0: Initialize Shop Wallets in Staging ---
  console.log('>>> [Setup] Initializing test shop wallets...');
  const setupRes = runStagingSql(`SELECT public.recharge_initialize_shop_wallets('${testShop}');`);
  console.log('Setup result:', setupRes.success ? 'OK' : setupRes.output);

  // --- TEST A: Valid Top-Up Execution ---
  console.log('\n--- TEST A: Valid Top-Up Execution ---');
  const topupRes1 = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 5000, 'bank', 'owner_1', 'Owner Test', 'UTR_ADV_001', 'Test Deposit 1', 'DEV_MOB_001'
    );
  `);
  const tA_passed = topupRes1.success && topupRes1.output.includes('"idempotent_replay": false') && topupRes1.output.includes('"own_prepaid_balance_paise": 5000');
  console.log('Test A (Valid Top-Up):', tA_passed ? 'PASS' : 'FAIL', topupRes1.output);

  // --- TEST B: Duplicate UTR Same Request Retry (Deterministic Idempotency) ---
  console.log('\n--- TEST B: Same Request Replay ---');
  const topupResRetry = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 5000, 'bank', 'owner_1', 'Owner Test', 'UTR_ADV_001', 'Test Deposit 1', 'DEV_MOB_001'
    );
  `);
  const tB_passed = topupResRetry.success && topupResRetry.output.includes('"idempotent_replay": true') && topupResRetry.output.includes('"own_prepaid_balance_paise": 5000');
  console.log('Test B (Same Request Retry):', tB_passed ? 'PASS' : 'FAIL', topupResRetry.output);

  // --- TEST C: Duplicate UTR with Different Amount (Conflict Rejection) ---
  console.log('\n--- TEST C: Same UTR Different Amount Conflict ---');
  const topupResConflict = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 10000, 'bank', 'owner_1', 'Owner Test', 'UTR_ADV_001', 'Altered amount', 'DEV_MOB_001'
    );
  `);
  const tC_passed = !topupResConflict.success && topupResConflict.output.includes('Idempotency conflict');
  console.log('Test C (Altered Amount Conflict):', tC_passed ? 'PASS' : 'FAIL', topupResConflict.output);

  // --- TEST D: Normalized Case-Insensitive & Whitespace UTR Duplicate Rejection ---
  console.log('\n--- TEST D: Normalized UTR Duplicate Detection ---');
  const topupResNormalized = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 5000, 'bank', 'owner_1', 'Owner Test', '  utr_adv_001  ', 'Whitespace lowercase test', 'DEV_MOB_001'
    );
  `);
  const tD_passed = topupResNormalized.success && topupResNormalized.output.includes('"idempotent_replay": true') && topupResNormalized.output.includes('"own_prepaid_balance_paise": 5000');
  console.log('Test D (Normalized UTR Duplicate):', tD_passed ? 'PASS' : 'FAIL', topupResNormalized.output);

  // --- TEST E: Immutability - UPDATE Rejection on recharge_float_deposits ---
  console.log('\n--- TEST E: Immutability - UPDATE on recharge_float_deposits ---');
  const updateRes1 = runStagingSql(`
    UPDATE public.recharge_float_deposits
    SET amount_paise = 999999
    WHERE shop_id = '${testShop}';
  `);
  const tE_passed = !updateRes1.success && updateRes1.output.includes('Immutability violation');
  console.log('Test E (UPDATE Rejection on deposits):', tE_passed ? 'PASS' : 'FAIL', updateRes1.output);

  // --- TEST F: Immutability - DELETE Rejection on recharge_float_deposits ---
  console.log('\n--- TEST F: Immutability - DELETE on recharge_float_deposits ---');
  const deleteRes1 = runStagingSql(`
    DELETE FROM public.recharge_float_deposits
    WHERE shop_id = '${testShop}';
  `);
  const tF_passed = !deleteRes1.success && deleteRes1.output.includes('Immutability violation');
  console.log('Test F (DELETE Rejection on deposits):', tF_passed ? 'PASS' : 'FAIL', deleteRes1.output);

  // --- TEST G: Immutability - UPDATE Rejection on recharge_wallet_logs ---
  console.log('\n--- TEST G: Immutability - UPDATE on recharge_wallet_logs ---');
  const updateRes2 = runStagingSql(`
    UPDATE public.recharge_wallet_logs
    SET amount_paise = 999999
    WHERE shop_id = '${testShop}';
  `);
  const tG_passed = !updateRes2.success && updateRes2.output.includes('Immutability violation');
  console.log('Test G (UPDATE Rejection on logs):', tG_passed ? 'PASS' : 'FAIL', updateRes2.output);

  // --- TEST H: Immutability - DELETE Rejection on recharge_wallet_logs ---
  console.log('\n--- TEST H: Immutability - DELETE on recharge_wallet_logs ---');
  const deleteRes2 = runStagingSql(`
    DELETE FROM public.recharge_wallet_logs
    WHERE shop_id = '${testShop}';
  `);
  const tH_passed = !deleteRes2.success && deleteRes2.output.includes('Immutability violation');
  console.log('Test H (DELETE Rejection on logs):', tH_passed ? 'PASS' : 'FAIL', deleteRes2.output);

  // --- Summary ---
  console.log('\n================================================================================');
  console.log('STAGING ADVERSARIAL AUDIT SUMMARY:');
  console.log(`Test A (Valid Top-Up):               ${tA_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test B (Same Request Retry):         ${tB_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test C (Altered Amount Conflict):    ${tC_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test D (Normalized UTR Duplicate):   ${tD_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test E (UPDATE Blocked on Deposits): ${tE_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test F (DELETE Blocked on Deposits): ${tF_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test G (UPDATE Blocked on Logs):     ${tG_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log(`Test H (DELETE Blocked on Logs):     ${tH_passed ? '✅ PASS' : '❌ FAIL'}`);
  console.log('================================================================================\n');

  if (tA_passed && tB_passed && tC_passed && tD_passed && tE_passed && tF_passed && tG_passed && tH_passed) {
    console.log('ALL ADVERSARIAL STAGING AUDITS PASSED WITH ZERO VIOLATIONS.');
  } else {
    console.error('ONE OR MORE ADVERSARIAL AUDITS FAILED.');
    process.exit(1);
  }
}

runAdversarialAudit().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
