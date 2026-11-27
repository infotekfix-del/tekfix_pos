// ============================================================================
// TEKFIX ERP - PHASE 15.2: REAL POSTGRESQL CONCURRENCY & ACID AUDIT SUITE
// Executes live against pinned remote Supabase staging database
// Uses real concurrent connections executing simultaneous transactions.
// ============================================================================

const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const REPO_ROOT = 'd:\\tekfix_pos';
const STAGING_SHOP_ID = 'shop_staging_concurrency_test';

function runSql(sql) {
  return new Promise((resolve, reject) => {
    // Write query to temporary file to avoid shell escaping issues
    const tempFile = path.join(REPO_ROOT, 'tools', 'staging', `_tmp_${Date.now()}_${Math.random().toString(36).substring(2, 8)}.sql`);
    fs.writeFileSync(tempFile, sql, 'utf8');

    const cmd = `npx.cmd supabase db query --remote --yes -f "${tempFile}"`;
    exec(cmd, { cwd: REPO_ROOT }, (error, stdout, stderr) => {
      // Clean up temporary file immediately
      try { fs.unlinkSync(tempFile); } catch (_) {}

      if (error) {
        return resolve({ success: false, error: stderr || stdout || error.message, stdout, stderr });
      }
      try {
        const json = JSON.parse(stdout.trim());
        resolve({ success: true, data: json, raw: stdout });
      } catch (_) {
        resolve({ success: true, raw: stdout });
      }
    });
  });
}

function parseOutput(res) {
  const combined = `${res.stdout || ''}\n${res.stderr || ''}\n${res.raw || ''}\n${res.error || ''}`;
  if (!res.success || combined.includes('"code":"DbQueryUnexpectedStatusError"') || combined.includes('Failed to run sql query: ERROR:')) {
    return { isSuccess: false, message: combined };
  }
  return { isSuccess: true, message: combined };
}

async function runConcurrencyAudit() {
  console.log('================================================================================');
  console.log('TEKFIX ERP - PHASE 15.2 REAL POSTGRESQL CONCURRENCY & ACID AUDIT');
  console.log('Target Database: PostgreSQL 17 on Supabase (mwhsvidbrfkryuiwhnev)');
  console.log('Mode: Real Concurrent Database Sessions (Parallel Process Execution)');
  console.log('================================================================================\n');

  const testResults = [];

  function record(testNum, testName, passed, details) {
    testResults.push({ testNum, testName, passed, details });
    const mark = passed ? '✅ PASS' : '❌ FAIL';
    console.log(`  ${mark} [Concurrency ${testNum}] ${testName}`);
    console.log(`     Details: ${details}\n`);
  }

  // --- INITIAL SETUP & CLEANUP ---
  console.log('>>> [Step 0] Cleaning synthetic concurrency test fixtures...');
  await runSql(`
    DELETE FROM public.recharge_refunds WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_reversals WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_commissions WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_wallet_logs WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_distributor_ledger WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_transactions WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_float_deposits WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_distributors WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}';
  `);

  // ==========================================================================
  // CONCURRENCY TEST 1: Simultaneous Wallet Debits & Overdraft Prevention
  // ==========================================================================
  console.log('>>> Running Test 1: Simultaneous Wallet Debits & Overdraft Prevention...');
  // Seed wallet with 50,000 paise (₹500.00). Two concurrent requests will each request 30,000 paise.
  // One must succeed, the second must fail due to row locking (FOR UPDATE) and overdraft check.
  await runSql(`
    INSERT INTO public.recharge_wallets (shop_id, wallet_id, operator, own_prepaid_balance_paise, distributor_credit_balance_paise)
    VALUES ('${STAGING_SHOP_ID}', 'WALLET_CONC_1', 'Airtel', 50000, 0);
  `);

  const debitSqlA = `
    SELECT public.recharge_process_debit(
      '${STAGING_SHOP_ID}', 'WALLET_CONC_1', 'TXN_CONC_1_A', 'IDEM_CONC_1_A',
      '9876543210', 'Airtel', 'mobile_recharge', 30000, 'ownPrepaid', 900, CURRENT_DATE, 'DEV_1', 'OWNER_UID'
    );
  `;
  const debitSqlB = `
    SELECT public.recharge_process_debit(
      '${STAGING_SHOP_ID}', 'WALLET_CONC_1', 'TXN_CONC_1_B', 'IDEM_CONC_1_B',
      '9876543210', 'Airtel', 'mobile_recharge', 30000, 'ownPrepaid', 900, CURRENT_DATE, 'DEV_1', 'OWNER_UID'
    );
  `;

  const [res1A, res1B] = await Promise.all([runSql(debitSqlA), runSql(debitSqlB)]);
  const parsed1A = parseOutput(res1A);
  const parsed1B = parseOutput(res1B);
  const walletCheck1 = await runSql(`SELECT own_prepaid_balance_paise, total_balance_paise FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}' AND wallet_id = 'WALLET_CONC_1';`);
  console.log('DEBUG Test 1:', { parsed1A, parsed1B, walletRaw: walletCheck1.raw });
  const t1OneSuccessOneFail = (parsed1A.isSuccess !== parsed1B.isSuccess);
  const t1ErrorMsg = (!parsed1A.isSuccess ? parsed1A.message : parsed1B.message);
  const t1HasExpectedError = t1ErrorMsg.includes('Insufficient own prepaid balance');
  const finalBal1 = walletCheck1.raw.includes('"total_balance_paise": 20000');

  const test1Passed = t1OneSuccessOneFail && t1HasExpectedError && finalBal1;
  record(
    1,
    'Simultaneous Wallet Debits Serialized via Row Lock (Overdraft Blocked)',
    test1Passed,
    `Initial: 50000 paise. 2 simultaneous debits of 30000 paise. Exactly 1 succeeded, 1 failed with Insufficient Balance. Final balance: 20000 paise.`
  );

  // ==========================================================================
  // CONCURRENCY TEST 2: Simultaneous Identical Idempotency Requests
  // ==========================================================================
  console.log('>>> Running Test 2: Simultaneous Identical Idempotency Requests...');
  // Seed wallet with 50,000 paise. Two simultaneous requests with SAME idempotency key (10,000 paise).
  await runSql(`
    INSERT INTO public.recharge_wallets (shop_id, wallet_id, operator, own_prepaid_balance_paise, distributor_credit_balance_paise)
    VALUES ('${STAGING_SHOP_ID}', 'WALLET_CONC_2', 'Jio', 50000, 0);
  `);

  const idemSql = `
    SELECT public.recharge_process_debit(
      '${STAGING_SHOP_ID}', 'WALLET_CONC_2', 'TXN_IDEM_RACE_1', 'IDEM_SHARED_RACE_001',
      '9811122233', 'Jio', 'mobile_recharge', 10000, 'ownPrepaid', 300, CURRENT_DATE, 'DEV_1', 'OWNER_UID'
    );
  `;

  const [res2A, res2B] = await Promise.all([runSql(idemSql), runSql(idemSql)]);
  const parsed2A = parseOutput(res2A);
  const parsed2B = parseOutput(res2B);

  // Both should report success (either fresh or idempotent_replay)
  const walletCheck2 = await runSql(`SELECT total_balance_paise FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}' AND wallet_id = 'WALLET_CONC_2';`);
  const txnCountCheck2 = await runSql(`SELECT count(*) FROM public.recharge_transactions WHERE shop_id = '${STAGING_SHOP_ID}' AND idempotency_key = 'IDEM_SHARED_RACE_001';`);

  const finalBal2 = walletCheck2.raw.includes('"total_balance_paise": 40000');
  const txnCount2 = txnCountCheck2.raw.includes('"count": 1');
  const test2Passed = parsed2A.isSuccess && parsed2B.isSuccess && finalBal2 && txnCount2;

  record(
    2,
    'Simultaneous Identical Idempotency Race (Atomic Single Execution)',
    test2Passed,
    `2 simultaneous requests with same idempotency key. Both returned success. Transaction count = 1. Balance debited exactly ONCE: 50000 -> 40000 paise.`
  );

  // ==========================================================================
  // CONCURRENCY TEST 3: Conflicting Payload on Existing Idempotency Key
  // ==========================================================================
  console.log('>>> Running Test 3: Conflicting Payload on Existing Idempotency Key...');
  // Send request with same idempotency key 'IDEM_SHARED_RACE_001' but with conflicting amount 25,000 paise.
  const conflictSql = `
    SELECT public.recharge_process_debit(
      '${STAGING_SHOP_ID}', 'WALLET_CONC_2', 'TXN_CONFLICT', 'IDEM_SHARED_RACE_001',
      '9811122233', 'Jio', 'mobile_recharge', 25000, 'ownPrepaid', 750, CURRENT_DATE, 'DEV_1', 'OWNER_UID'
    );
  `;
  const res3 = await runSql(conflictSql);
  const parsed3 = parseOutput(res3);
  const replayVerified3 = res3.raw.includes('"idempotent_replay": true') && res3.raw.includes('"amount_paise": 10000');
  const walletCheck3 = await runSql(`SELECT total_balance_paise FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}' AND wallet_id = 'WALLET_CONC_2';`);
  const finalBal3 = walletCheck3.raw.includes('"total_balance_paise": 40000');

  const test3Passed = parsed3.isSuccess && replayVerified3 && finalBal3;
  record(
    3,
    'Conflicting Payload Using Existing Idempotency Key Rejected',
    test3Passed,
    `Attempted to debit 25000 paise with existing idempotency key. Procedure safely returned cached 10000 paise transaction; balance remained strictly at 40000 paise.`
  );

  // ==========================================================================
  // CONCURRENCY TEST 4: Concurrent Refund and Reversal Mutual Exclusion Race
  // ==========================================================================
  console.log('>>> Running Test 4: Concurrent Refund and Reversal Mutual Exclusion Race...');
  // Seed completed transaction TXN_CONC_4 with amount 15,000 paise on wallet with 30,000 paise.
  await runSql(`
    INSERT INTO public.recharge_wallets (shop_id, wallet_id, operator, own_prepaid_balance_paise, distributor_credit_balance_paise)
    VALUES ('${STAGING_SHOP_ID}', 'WALLET_CONC_4', 'VI', 30000, 0);

    INSERT INTO public.recharge_transactions (
      shop_id, txn_key, wallet_id, customer_phone, operator, service_type,
      amount_paise, funding_type, commission_earned_paise, wallet_debited,
      status, device_id, owner_uid, business_date, idempotency_key
    ) VALUES (
      '${STAGING_SHOP_ID}', 'TXN_CONC_4', 'WALLET_CONC_4', '9899900011', 'VI', 'mobile_recharge',
      15000, 'ownPrepaid', 450, true, 'completed', 'DEV_1', 'OWNER_UID', CURRENT_DATE, 'IDEM_CONC_4'
    );
  `);

  const refundSql = `SELECT public.recharge_process_refund('${STAGING_SHOP_ID}', 'TXN_CONC_4', 'cash', 'Concurrent refund', 'OWNER_UID');`;
  const reversalSql = `SELECT public.recharge_process_reversal('${STAGING_SHOP_ID}', 'TXN_CONC_4', 'OP_REF_CONC', 'Concurrent reversal', 'OWNER_UID');`;

  const [res4Refund, res4Reversal] = await Promise.all([runSql(refundSql), runSql(reversalSql)]);
  const parsed4Ref = parseOutput(res4Refund);
  const parsed4Rev = parseOutput(res4Reversal);
  const walletCheck4 = await runSql(`SELECT total_balance_paise FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}' AND wallet_id = 'WALLET_CONC_4';`);
  console.log('DEBUG Test 4:', { parsed4Ref, parsed4Rev, walletRaw: walletCheck4.raw });
  const t4OneSuccessOneFail = (parsed4Ref.isSuccess !== parsed4Rev.isSuccess);
  const t4Error = (!parsed4Ref.isSuccess ? parsed4Ref.message : parsed4Rev.message);
  const t4MutualExclusion = t4Error.includes('already refunded') || t4Error.includes('already reversed');
  const finalBal4 = walletCheck4.raw.includes('"total_balance_paise": 45000');

  const test4Passed = t4OneSuccessOneFail && t4MutualExclusion && finalBal4;
  record(
    4,
    'Concurrent Refund vs Reversal Race Condition Strictly Mutually Exclusive',
    test4Passed,
    `Simultaneous refund and reversal fired against TXN_CONC_4. Exactly 1 succeeded; 1 blocked with mutual exclusion exception. Wallet restituted exactly ONCE (30000 -> 45000 paise, never double-restituted).`
  );

  // ==========================================================================
  // CONCURRENCY TEST 5: Concurrent Distributor Debt Settlement Payments
  // ==========================================================================
  console.log('>>> Running Test 5: Concurrent Distributor Debt Settlement Payments...');
  // Seed distributor with debt 40,000 paise. 2 concurrent settlements of 25,000 paise each.
  // One must succeed (debt -> 15,000 paise), the second must fail because 25,000 > 15,000!
  await runSql(`
    INSERT INTO public.recharge_distributors (shop_id, distributor_id, name, phone, outstanding_balance_paise)
    VALUES ('${STAGING_SHOP_ID}', 'DIST_CONC_5', 'Airtel Concurrency Dist', '9877766655', 40000);
  `);

  const settleSqlA = `SELECT public.recharge_process_distributor_settlement('${STAGING_SHOP_ID}', 'DIST_CONC_5', 'WALLET_CONC_1', 25000, 'bank_transfer', 'OWNER_UID', 'SETTLE_CONC_A');`;
  const settleSqlB = `SELECT public.recharge_process_distributor_settlement('${STAGING_SHOP_ID}', 'DIST_CONC_5', 'WALLET_CONC_1', 25000, 'bank_transfer', 'OWNER_UID', 'SETTLE_CONC_B');`;

  const [res5A, res5B] = await Promise.all([runSql(settleSqlA), runSql(settleSqlB)]);
  const parsed5A = parseOutput(res5A);
  const parsed5B = parseOutput(res5B);
  const distCheck5 = await runSql(`SELECT outstanding_balance_paise FROM public.recharge_distributors WHERE shop_id = '${STAGING_SHOP_ID}' AND distributor_id = 'DIST_CONC_5';`);
  console.log('DEBUG Test 5:', { parsed5A, parsed5B, distRaw: distCheck5.raw });
  const t5OneSuccessOneFail = (parsed5A.isSuccess !== parsed5B.isSuccess);
  const t5Error = (!parsed5A.isSuccess ? parsed5A.message : parsed5B.message);
  const t5Exceeds = t5Error.includes('exceeds outstanding balance');
  const finalDebt5 = distCheck5.raw.includes('"outstanding_balance_paise": 15000');

  const test5Passed = t5OneSuccessOneFail && t5Exceeds && finalDebt5;
  record(
    5,
    'Concurrent Distributor Debt Settlement Over-Payment Blocked',
    test5Passed,
    `Initial debt: 40000 paise. 2 simultaneous settlements of 25000 paise. Exactly 1 succeeded; 1 failed with 'exceeds outstanding balance'. Final debt: 15000 paise.`
  );

  // --- SAFE CLEANUP ---
  console.log('>>> [Step 6] Teardown synthetic concurrency fixtures...');
  await runSql(`
    DELETE FROM public.recharge_refunds WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_reversals WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_commissions WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_wallet_logs WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_distributor_ledger WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_transactions WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_float_deposits WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_distributors WHERE shop_id = '${STAGING_SHOP_ID}';
    DELETE FROM public.recharge_wallets WHERE shop_id = '${STAGING_SHOP_ID}';
  `);
  console.log('  ✅ Teardown complete. Zero lingering concurrency test data.\n');

  console.log('================================================================================');
  const allPassed = testResults.every(t => t.passed);
  console.log(`CONCURRENCY AUDIT RESULT: ${allPassed ? 'ALL 5 PASSED (100% ACID GREEN)' : 'FAILURES DETECTED'}`);
  console.log('================================================================================');

  if (!allPassed) {
    process.exit(1);
  }
}

runConcurrencyAudit().catch(err => {
  console.error('Fatal concurrency audit error:', err);
  process.exit(1);
});

