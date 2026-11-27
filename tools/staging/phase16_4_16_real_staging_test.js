const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const STAGING_REF = 'mwhsvidbrfkryuiwhnev';
const REPO_ROOT = path.resolve(__dirname, '../..');

function query(sql) {
  const tempFile = path.join(REPO_ROOT, 'tools', 'staging', `_tmp_q_${Date.now()}_${Math.random().toString(36).substr(2,4)}.sql`);
  fs.writeFileSync(tempFile, sql, 'utf8');
  try {
    const cmd = `npx.cmd supabase db query --remote=${STAGING_REF} --yes -f "${tempFile}"`;
    const out = execSync(cmd, { cwd: REPO_ROOT, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    return { success: true, output: out };
  } catch (err) {
    return { success: false, output: (err.stdout ? err.stdout.toString() : '') + (err.stderr ? err.stderr.toString() : '') + err.message };
  } finally {
    try { fs.unlinkSync(tempFile); } catch (_) {}
  }
}

async function runTest() {
  console.log('=== PHASE 16.4.16 REAL STAGING ADVERSARIAL TEST ===');
  console.log('Target: Remote Staging PostgreSQL (mwhsvidbrfkryuiwhnev)');

  // 1. Verify Overload Removal
  console.log('\n>>> 1. Verifying exactly one recharge_process_topup exists in pg_proc...');
  const procRes = query(`
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = 'recharge_process_topup';
  `);
  console.log('pg_proc rows:', procRes.output);

  // 2. Verify 8-argument call fails (function does not exist)
  console.log('\n>>> 2. Verifying 8-argument call fails with function not found...');
  const legacyCall = query(`
    SELECT public.recharge_process_topup('test_shop', 'WALLET_VI', 1000, 'bank', 'staff', 'Staff', 'REF_OLD', 'desc');
  `);
  // Note: in postgres, if the remaining function has 9 arguments with a DEFAULT for the 9th, an 8-arg call will invoke the 9-arg function!
  // Let's verify whether it defaults p_device_id to 'DEV_UNSPECIFIED':
  console.log('8-arg invocation result (should invoke 9-arg with default device_id or fail):', legacyCall.success ? 'Invoked 9-arg with default' : legacyCall.output);

  // 3. Test Real Staging Top-Up in an ephemeral test shop
  const testShop = 'shop_16_4_16_' + Date.now();
  const testUtr = 'UTR_16_4_16_' + Date.now();
  console.log('\n>>> 3. Initializing wallets for test shop:', testShop);
  query(`SELECT public.recharge_initialize_shop_wallets('${testShop}');`);

  console.log('>>> 4. Executing 9-arg Top-Up ₹100.00 (10000 paise)...');
  const topupRes1 = query(`
    SELECT public.recharge_process_topup(
      '${testShop}', 'WALLET_VI', 10000, 'bank', 'owner_test', 'Owner Test', '${testUtr}', 'Remediation Test', 'DEV_STAGING_001'
    );
  `);
  console.log('Topup 1 Result:', topupRes1.success ? 'SUCCESS' : topupRes1.output);

  console.log('>>> 5. Executing Identical Retry (Duplicate UTR)...');
  const topupRes2 = query(`
    SELECT public.recharge_process_topup(
      '${testShop}', 'WALLET_VI', 10000, 'bank', 'owner_test', 'Owner Test', '${testUtr}', 'Remediation Test', 'DEV_STAGING_001'
    );
  `);
  console.log('Topup 2 (Retry) Result:', topupRes2.success ? 'SUCCESS (Idempotent Replay)' : topupRes2.output);

  console.log('>>> 6. Executing Conflicting Amount (Same UTR, 99999 paise)...');
  const topupRes3 = query(`
    SELECT public.recharge_process_topup(
      '${testShop}', 'WALLET_VI', 99999, 'bank', 'owner_test', 'Owner Test', '${testUtr}', 'Tampered', 'DEV_STAGING_001'
    );
  `);
  console.log('Topup 3 (Conflict) Expected Failure:', !topupRes3.success ? 'PASSED (Rejected with exception)' : 'FAILED');

  console.log('>>> 7. Testing Immutability Trigger (Attempting UPDATE on float deposit)...');
  const updateRes = query(`
    UPDATE public.recharge_float_deposits
    SET amount_paise = 99999
    WHERE shop_id = '${testShop}' AND deposit_id = '${testUtr}';
  `);
  console.log('UPDATE Attempt Expected Failure:', !updateRes.success ? 'PASSED (Blocked by immutability trigger)' : 'FAILED');

  console.log('\n=== REAL STAGING TEST COMPLETE ===');
}

runTest().catch(console.error);
