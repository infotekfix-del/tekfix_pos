/**
 * ============================================================================
 * TEKFIX ERP — PHASE 16.4.13: REAL STAGING END-TO-END VERIFICATION
 * Runs directly against live remote Supabase Staging (mwhsvidbrfkryuiwhnev)
 * ============================================================================
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const STAGING_REF = 'mwhsvidbrfkryuiwhnev';
const REPO_ROOT = path.resolve(__dirname, '../..');

function runStagingSql(sql) {
  const tempFile = path.join(REPO_ROOT, 'tools', 'staging', `_tmp_real_e2e_${Date.now()}_${Math.random().toString(36).substring(2, 6)}.sql`);
  fs.writeFileSync(tempFile, sql, 'utf8');
  try {
    const cmd = `npx.cmd supabase db query --remote=${STAGING_REF} --yes -f "${tempFile}"`;
    const out = execSync(cmd, { cwd: REPO_ROOT, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    return { success: true, output: out };
  } catch (err) {
    const errOut = (err.stdout ? err.stdout.toString() : '') + (err.stderr ? err.stderr.toString() : '') + err.message;
    return { success: false, output: errOut };
  } finally {
    try { fs.unlinkSync(tempFile); } catch (_) {}
  }
}

async function runRealStagingVerification() {
  console.log('================================================================================');
  console.log('TEKFIX ERP — PHASE 16.4.13 REAL STAGING E2E AUDIT');
  console.log('Target Database: Supabase Staging Remote (mwhsvidbrfkryuiwhnev)');
  console.log('Timestamp:', new Date().toISOString());
  console.log('================================================================================\n');

  const testShop = 'shop_e2e_' + Date.now();
  const testWallet = 'WALLET_VI';
  const testUtr = 'UTR_REAL_E2E_' + Date.now();

  // 1. Initialize Shop Wallets in Staging
  console.log('>>> [Step 1] Initializing wallets for test shop:', testShop);
  const initRes = runStagingSql(`SELECT public.recharge_initialize_shop_wallets('${testShop}');`);
  console.log('Init result:', initRes.success ? 'OK' : initRes.output);

  // 2. Real Top-Up Call
  console.log('\n>>> [Step 2] Executing Top-Up ₹50.00 (5000 paise)...');
  const topupRes1 = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 5000, 'bank', 'owner_real', 'Owner Real', '${testUtr}', 'Real Staging Top-Up', 'DEV_E2E_001'
    );
  `);
  console.log('Top-Up 1 Output:', topupRes1.output);
  const p1 = topupRes1.output.includes('"idempotent_replay": false') && topupRes1.output.includes('"own_prepaid_balance_paise": 5000');
  console.log('Step 2 Result:', p1 ? 'PASS (Fresh Top-Up Succeeded)' : 'FAIL');

  // 3. Real Idempotent Replay Call (Identical UTR)
  console.log('\n>>> [Step 3] Submitting Identical Request (Same UTR)...');
  const topupRes2 = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 5000, 'bank', 'owner_real', 'Owner Real', '${testUtr}', 'Real Staging Top-Up', 'DEV_E2E_001'
    );
  `);
  console.log('Top-Up 2 Output:', topupRes2.output);
  const p2 = topupRes2.output.includes('"idempotent_replay": true') && topupRes2.output.includes('"own_prepaid_balance_paise": 5000');
  console.log('Step 3 Result:', p2 ? 'PASS (Idempotent Replay Confirmed, Zero Double-Credit)' : 'FAIL');

  // 4. Real Conflict Rejection (Same UTR, Altered Amount)
  console.log('\n>>> [Step 4] Submitting Conflicting Request (Same UTR, 9999 paise)...');
  const topupRes3 = runStagingSql(`
    SELECT public.recharge_process_topup(
      '${testShop}', '${testWallet}', 9999, 'bank', 'owner_real', 'Owner Real', '${testUtr}', 'Altered Amount', 'DEV_E2E_001'
    );
  `);
  console.log('Top-Up 3 Output:', topupRes3.output);
  const p3 = !topupRes3.success && topupRes3.output.includes('Idempotency conflict');
  console.log('Step 4 Result:', p3 ? 'PASS (Conflict Rejected by PostgreSQL)' : 'FAIL');

  // 5. Immutability Trigger Verification
  console.log('\n>>> [Step 5] Testing Immutability Triggers (Attempting UPDATE)...');
  const updateRes = runStagingSql(`
    UPDATE public.recharge_float_deposits SET amount_paise = 999999 WHERE shop_id = '${testShop}';
  `);
  console.log('Update Output:', updateRes.output);
  const p4 = !updateRes.success && updateRes.output.includes('Immutability violation');
  console.log('Step 5 Result:', p4 ? 'PASS (Tampering Blocked by DB Trigger)' : 'FAIL');

  // 6. Verify Ledger State
  console.log('\n>>> [Step 6] Verifying Final Database Balances on Real Staging...');
  const verifyRes = runStagingSql(`
    SELECT wallet_id, own_prepaid_balance_paise, total_balance_paise 
    FROM public.recharge_wallets WHERE shop_id = '${testShop}';
  `);
  console.log('Final Balances:', verifyRes.output);

  const allPassed = p1 && p2 && p3 && p4;
  console.log('\n================================================================================');
  console.log('REAL STAGING VERIFICATION RESULT:', allPassed ? 'ALL PASS' : 'SOME FAILED');
  console.log('================================================================================');
}

runRealStagingVerification().catch(console.error);
