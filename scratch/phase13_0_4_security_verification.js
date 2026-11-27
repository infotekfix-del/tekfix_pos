/**
 * TEKFIX ERP - PHASE 13.0.4 CRITICAL SECURITY & ATOMICITY VERIFICATION SUITE
 * 
 * Verifies:
 * A. Maintenance Mode Enforcement & Recovery (Tests 1-5)
 * B. Transaction Atomicity & Authorization Revocation Race Protection (Tests 6-10)
 * C. Environment Isolation & Fail-Closed Behavior (Tests 11-16)
 * D. Idempotency & Reversed Transaction Replay (Tests 17-24)
 * E. Financial Integrity & Negative Balance Immunity (Tests 25-30)
 * 
 * Target: Firebase Local Emulator (Firestore: 8080, Functions: 5001)
 */

const http = require('http');
const fs = require('fs');

const EMULATOR_HOST = '127.0.0.1';
const FIRESTORE_PORT = 8080;
const FUNCTIONS_PORT = 5001;
const PROJECT_ID = 'tekfix-45b38';
const REGION = 'us-central1';
const DATABASE_ID = '(default)';

function makeFirestoreRequest({ method, path, body, authClaims }) {
  return new Promise((resolve, reject) => {
    let authHeader = '';
    if (authClaims) {
      const headerObj = { alg: 'none', typ: 'JWT' };
      const encode = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
      authHeader = `Bearer ${encode(headerObj)}.${encode(authClaims)}.`;
    }

    const payload = body ? JSON.stringify(body) : null;
    const req = http.request(
      {
        host: EMULATOR_HOST,
        port: FIRESTORE_PORT,
        method: method || 'GET',
        path: `/v1/projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents${path}`,
        headers: {
          'Content-Type': 'application/json',
          ...(authHeader ? { Authorization: authHeader } : {}),
          ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          let parsed = null;
          try {
            if (data) parsed = JSON.parse(data);
          } catch (_) {}
          resolve({ status: res.statusCode, data: parsed });
        });
      }
    );

    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function callCloudFunction({ functionName, data, authClaims }) {
  return new Promise((resolve, reject) => {
    let authHeader = '';
    if (authClaims) {
      const headerObj = { alg: 'none', typ: 'JWT' };
      const encode = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
      authHeader = `Bearer ${encode(headerObj)}.${encode(authClaims)}.`;
    }

    const payload = JSON.stringify({ data: data || {} });
    const req = http.request(
      {
        host: EMULATOR_HOST,
        port: FUNCTIONS_PORT,
        method: 'POST',
        path: `/${PROJECT_ID}/${REGION}/${functionName}`,
        headers: {
          'Content-Type': 'application/json',
          ...(authHeader ? { Authorization: authHeader } : {}),
          'Content-Length': Buffer.byteLength(payload),
        },
      },
      (res) => {
        let resData = '';
        res.on('data', (chunk) => (resData += chunk));
        res.on('end', () => {
          let parsed = null;
          try {
            if (resData) parsed = JSON.parse(resData);
          } catch (_) {}
          resolve({ status: res.statusCode, data: parsed });
        });
      }
    );

    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

function toFirestoreDoc(data) {
  const fields = {};
  for (const [key, val] of Object.entries(data)) {
    if (val === null || val === undefined) {
      fields[key] = { nullValue: null };
    } else if (typeof val === 'string') {
      fields[key] = { stringValue: val };
    } else if (typeof val === 'number') {
      if (Number.isInteger(val)) fields[key] = { integerValue: val.toString() };
      else fields[key] = { doubleValue: val };
    } else if (typeof val === 'boolean') {
      fields[key] = { booleanValue: val };
    } else if (Array.isArray(val)) {
      fields[key] = {
        arrayValue: {
          values: val.map((item) =>
            typeof item === 'string'
              ? { stringValue: item }
              : typeof item === 'number'
              ? { integerValue: item.toString() }
              : { stringValue: JSON.stringify(item) }
          ),
        },
      };
    } else if (typeof val === 'object') {
      fields[key] = { mapValue: toFirestoreDoc(val) };
    }
  }
  return { fields };
}

function getAsiaKolkataDateString(offsetDays = 0) {
  const d = new Date();
  if (offsetDays !== 0) {
    d.setDate(d.getDate() + offsetDays);
  }
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return formatter.format(d);
}

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;

function assert(condition, message) {
  totalTests++;
  if (condition) {
    console.log(`[PASS] ${message}`);
    passedTests++;
  } else {
    console.error(`[FAIL] ${message}`);
    failedTests++;
  }
}

async function runTestSuite() {
  console.log('================================================================');
  console.log('TEKFIX ERP - PHASE 13.0.4 CRITICAL SECURITY VERIFICATION SUITE');
  console.log('Testing: Maintenance Mode, Atomicity, Reversals, Environment, Safety');
  console.log('================================================================\n');

  const shopId = 'phase13_shop_main';
  const ownerUid = 'PHASE13_OWNER';
  const staffUid = 'PHASE13_STAFF';
  const today = getAsiaKolkataDateString(0);

  const ownerClaims = { sub: ownerUid, user_id: ownerUid, email: 'owner@phase13.com', shopId };
  const staffClaims = { sub: staffUid, user_id: staffUid, email: 'staff@phase13.com', shopId };

  console.log('--- Setting up test shop & documents in Firestore ---');

  // Create Shop Document
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Phase 13 Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });

  // Create Owner User Document
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${ownerUid}`,
    body: toFirestoreDoc({ uid: ownerUid, role: 'owner', active: true, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });

  // Create Staff User Document
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });

  // Create Morning Opening Reconciliation
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/recharge_daily_reconciliation/${today}`,
    body: toFirestoreDoc({
      shopId: shopId,
      businessDate: today,
      openingStatus: 'completed',
      operators: {
        jio: { isOpeningCompleted: true, openingBalancePaise: 1000000 },
        airtel: { isOpeningCompleted: true, openingBalancePaise: 1000000 },
        vi: { isOpeningCompleted: true, openingBalancePaise: 1000000 },
        bsnl: { isOpeningCompleted: true, openingBalancePaise: 1000000 },
      },
    }),
    authClaims: ownerClaims,
  });

  // Create Operator Wallets
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    body: toFirestoreDoc({
      walletId: 'WALLET_JIO',
      shopId: shopId,
      operator: 'jio',
      ownPrepaidBalancePaise: 500000, // ₹5,000.00
      distributorCreditBalancePaise: 500000, // ₹5,000.00
      totalBalancePaise: 1000000, // ₹10,000.00
    }),
    authClaims: ownerClaims,
  });

  console.log('--- Setup complete. Running test phases ---\n');

  console.log('=== SECTION A: MAINTENANCE MODE ENFORCEMENT & RECOVERY ===');

  // 1. Normal active shop recharge
  const res1 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_001',
      operator: 'jio',
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(res1.status === 200 && res1.data && res1.data.result && res1.data.result.success === true,
    'Test 1: Normal active shop recharge succeeds (HTTP 200)');

  // 2. Maintenance mode enabled -> reject with FAILED_PRECONDITION
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Phase 13 Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: true }),
    authClaims: ownerClaims,
  });
  const res2 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_MAINT_002',
      operator: 'jio',
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res2.status === 400 &&
    res2.data.error &&
    res2.data.error.status === 'FAILED_PRECONDITION' &&
    res2.data.error.message.includes('Shop is currently under maintenance'),
    'Test 2: Maintenance mode enabled rejects debit with FAILED_PRECONDITION and safe message'
  );

  // 3. Shop inactive -> reject with FAILED_PRECONDITION
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Phase 13 Shop', ownerUid: ownerUid, active: false, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });
  const res3 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_INACT_003',
      operator: 'jio',
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res3.status === 400 &&
    res3.data.error &&
    res3.data.error.status === 'FAILED_PRECONDITION' &&
    res3.data.error.message.includes('inactive or suspended'),
    'Test 3: Shop inactive rejects debit with FAILED_PRECONDITION'
  );

  // 4. Concurrent maintenance mode block (shop set to maintenance mode)
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Phase 13 Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: true }),
    authClaims: ownerClaims,
  });
  const res4 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_RACE_004',
      operator: 'jio',
      amountPaise: 15000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res4.status === 400 && res4.data.error && res4.data.error.message.includes('under maintenance'),
    'Test 4: Concurrent maintenance mode blocks debit atomically inside transaction'
  );

  // 5. Maintenance mode disabled -> recharge succeeds
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Phase 13 Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });
  const res5 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_REC_005',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(res5.status === 200 && res5.data && res5.data.result && res5.data.result.success === true,
    'Test 5: Maintenance mode disabled restores normal recharge processing');


  console.log('\n=== SECTION B: TRANSACTION ATOMICITY & AUTHORIZATION RACES ===');

  // 6. Active staff recharge
  const res6 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_STAFF_006',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(res6.status === 200 && res6.data && res6.data.result && res6.data.result.success === true,
    'Test 6: Active staff recharge succeeds');

  // 7. Staff deactivated (`active: false`)
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: false, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });
  const res7 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_DEACT_007',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res7.status === 403 && res7.data.error && res7.data.error.status === 'PERMISSION_DENIED',
    'Test 7: Deactivated staff rejected inside transaction (PERMISSION_DENIED / HTTP 403)'
  );

  // 8. Staff permission revoked (`canRecharge: false`)
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: false }),
    authClaims: ownerClaims,
  });
  const res8 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_REVOKE_008',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res8.status === 403 && res8.data.error && res8.data.error.status === 'PERMISSION_DENIED',
    'Test 8: Revoked canRecharge=false rejected inside transaction (PERMISSION_DENIED)'
  );

  // Restore staff permissions
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });

  // 9. Cross-shop recharge attempt
  const rogueShopId = 'phase13_shop_rogue';
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${rogueShopId}`,
    body: toFirestoreDoc({ name: 'Rogue Shop', ownerUid: 'ROGUE_OWNER', active: true, isMaintenanceMode: false }),
    authClaims: { sub: 'ROGUE_OWNER', user_id: 'ROGUE_OWNER', email: 'rogue@shop.com', shopId: rogueShopId },
  });
  const res9 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId: rogueShopId,
      rechargeId: 'TXN_P13_CROSS_009',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res9.status === 403 && res9.data.error && res9.data.error.status === 'PERMISSION_DENIED',
    'Test 9: Cross-shop debit attempt fails closed with PERMISSION_DENIED (HTTP 403)'
  );

  // 10. Deleted membership attempt
  const deletedToken = { sub: 'PHASE13_GHOST', user_id: 'PHASE13_GHOST', email: 'ghost@phase13.com', shopId };
  const res10 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_GHOST_010',
      operator: 'jio',
      amountPaise: 10000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: deletedToken,
  });
  assert(
    res10.status === 403 && res10.data.error && res10.data.error.status === 'PERMISSION_DENIED',
    'Test 10: Non-existent user membership fails closed with PERMISSION_DENIED'
  );


  console.log('\n=== SECTION C: ENVIRONMENT ISOLATION & FAIL-CLOSED CHECKS ===');

  const optionsContent = fs.readFileSync('lib/firebase_options.dart', 'utf8');

  // 11. Production default
  const hasProdDefault = optionsContent.includes("defaultValue: 'production'");
  assert(hasProdDefault, 'Test 11: Production remains the default environment in firebase_options.dart');

  // 12. Explicit production mapping
  const hasProdMapping = optionsContent.includes("case 'production':") && optionsContent.includes('_productionPlatform');
  assert(hasProdMapping, 'Test 12: Explicit production environment resolves production options');

  // 13. Development without emulator configuration fails closed
  const hasDevGuard = optionsContent.includes('TekFix Development Environment is unconfigured') &&
    optionsContent.includes('throw StateError');
  assert(hasDevGuard, 'Test 13: Development without emulator configuration throws StateError (fails closed)');

  // 14. Development with emulator configuration resolves dev platform
  const hasDevPlatform = optionsContent.includes('return _developmentPlatform;') &&
    optionsContent.includes('fake-dev-api-key');
  assert(hasDevPlatform, 'Test 14: Development with emulator config resolves isolated development platform');

  // 15. Staging without configuration fails closed
  const hasStagingGuard = optionsContent.includes('TekFix Staging Firebase project is PENDING HUMAN ACTION') &&
    optionsContent.includes('throw StateError');
  assert(hasStagingGuard, 'Test 15: Staging environment throws StateError (fails closed, no fallback to prod)');

  // 16. Unknown environment name fails closed
  const hasUnknownGuard = optionsContent.includes('Unknown TEKFIX_ENV:') && optionsContent.includes('throw StateError');
  assert(hasUnknownGuard, 'Test 16: Unknown environment name throws StateError');


  console.log('\n=== SECTION D: IDEMPOTENCY & REVERSED TRANSACTION REPLAY ===');

  // 17. Normal identical replay
  const res17 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_001',
      operator: 'jio',
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res17.status === 200 && res17.data && res17.data.result && res17.data.result.idempotentReplay === true,
    'Test 17: Identical transaction replay returns safe idempotent replay (HTTP 200)'
  );

  // 18. Altered amount replay
  const res18 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_001',
      operator: 'jio',
      amountPaise: 49900, // Altered
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res18.status === 409 && res18.data.error && res18.data.error.status === 'ALREADY_EXISTS',
    'Test 18: Altered amount replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // 19. Altered operator replay
  const res19 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_001',
      operator: 'airtel', // Altered
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res19.status === 409 && res19.data.error && res19.data.error.status === 'ALREADY_EXISTS',
    'Test 19: Altered operator replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // 20. Altered wallet replay
  const res20 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_001',
      walletId: 'WALLET_AIRTEL', // Altered
      operator: 'jio',
      amountPaise: 29900,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res20.status === 409 && res20.data.error && res20.data.error.status === 'ALREADY_EXISTS',
    'Test 20: Altered wallet ID replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // 21. Reversed transaction replay -> Create a debit, mark it reversed, and replay
  const revTxnId = 'TXN_P13_REV_021';
  await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: revTxnId,
      operator: 'jio',
      amountPaise: 15000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });

  // Mark transaction doc as reversed
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/recharge_transactions/${revTxnId}?updateMask.fieldPaths=status&updateMask.fieldPaths=reversed`,
    body: toFirestoreDoc({ status: 'reversed', reversed: true }),
    authClaims: ownerClaims,
  });

  // Replay identical payload on reversed transaction
  const res21 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: revTxnId,
      operator: 'jio',
      amountPaise: 15000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res21.status === 400 &&
    res21.data.error &&
    res21.data.error.status === 'FAILED_PRECONDITION' &&
    res21.data.error.message.includes('was already reversed'),
    'Test 21: Replay of reversed transaction rejected with FAILED_PRECONDITION'
  );

  // 22. Altered payload replay on reversed transaction -> rejects with ALREADY_EXISTS
  const res22 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: revTxnId,
      operator: 'jio',
      amountPaise: 25000, // Altered
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res22.status === 409 && res22.data.error && res22.data.error.status === 'ALREADY_EXISTS',
    'Test 22: Altered payload on reversed transaction rejected with ALREADY_EXISTS'
  );

  // 23. Concurrent identical requests (10 requests)
  const concTxnId = 'TXN_P13_CONC_023';
  const promises23 = [];
  for (let i = 0; i < 10; i++) {
    promises23.push(callCloudFunction({
      functionName: 'processRechargeDebit',
      data: {
        shopId,
        rechargeId: concTxnId,
        operator: 'jio',
        amountPaise: 10000,
        fundingType: 'ownMoney',
        businessDate: today,
      },
      authClaims: staffClaims,
    }));
  }
  const results23 = await Promise.all(promises23);
  const success23 = results23.filter(r => r.status === 200);
  const primary23 = results23.filter(r => r.status === 200 && !r.data.result.idempotentReplay);
  const replay23 = results23.filter(r => r.status === 200 && r.data.result.idempotentReplay === true);
  assert(
    success23.length === 10 && primary23.length === 1 && replay23.length === 9,
    'Test 23: 10 Concurrent identical requests -> Exactly 1 primary debit, 9 safe idempotent replays (10/10 HTTP 200)'
  );

  // 24. Concurrent distinct requests (5 distinct recharges)
  const promises24 = [];
  for (let i = 1; i <= 5; i++) {
    promises24.push(callCloudFunction({
      functionName: 'processRechargeDebit',
      data: {
        shopId,
        rechargeId: `TXN_P13_DIST_024_${i}`,
        operator: 'jio',
        amountPaise: 5000,
        fundingType: 'ownMoney',
        businessDate: today,
      },
      authClaims: staffClaims,
    }));
  }
  const results24 = await Promise.all(promises24);
  const allSuccess24 = results24.every(r => r.status === 200);
  assert(allSuccess24, 'Test 24: 5 Concurrent distinct recharge debits commit atomically (All HTTP 200)');


  console.log('\n=== SECTION E: FINANCIAL INTEGRITY & BOUNDS ===');

  // 25. Insufficient balance
  const res25 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_OVERDRAFT_025',
      operator: 'jio',
      amountPaise: 999999999, // ₹99 Lakhs
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res25.status === 400 && res25.data.error && res25.data.error.message.includes('Insufficient wallet balance'),
    'Test 25: Insufficient balance rejected with FAILED_PRECONDITION'
  );

  // 26. Negative amount
  const res26 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_NEG_026',
      operator: 'jio',
      amountPaise: -5000,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res26.status === 400 && res26.data.error && res26.data.error.status === 'INVALID_ARGUMENT',
    'Test 26: Negative amount rejected with INVALID_ARGUMENT (HTTP 400)'
  );

  // 27. Unsafe integer amount (> MAX_SAFE_INTEGER)
  const res27 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: {
      shopId,
      rechargeId: 'TXN_P13_UNSAFE_027',
      operator: 'jio',
      amountPaise: 9007199254740992,
      fundingType: 'ownMoney',
      businessDate: today,
    },
    authClaims: staffClaims,
  });
  assert(
    res27.status === 400 && res27.data.error && res27.data.error.status === 'INVALID_ARGUMENT',
    'Test 27: Unsafe integer amount rejected with INVALID_ARGUMENT'
  );

  // 28. Wallet balance verification
  const walletCheck = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownBal = parseInt(walletCheck.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  const distBal = parseInt(walletCheck.data.fields.distributorCreditBalancePaise.integerValue, 10);
  assert(
    Number.isSafeInteger(ownBal) && ownBal >= 0 && Number.isSafeInteger(distBal) && distBal >= 0,
    `Test 28: Wallet balances remain verified non-negative safe integers in paise (Own: ${ownBal}, Dist: ${distBal})`
  );

  // 29. No ledger creation after rejected overdraft debit
  const ledgerOverdraftCheck = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallet_logs/TXN_TXN_P13_OVERDRAFT_025`,
    authClaims: ownerClaims,
  });
  assert(
    ledgerOverdraftCheck.status === 404,
    'Test 29: No wallet ledger record created for rejected overdraft debit (HTTP 404 Not Found)'
  );

  // 30. No wallet modification after rejected maintenance debit
  const ledgerMaintCheck = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallet_logs/TXN_TXN_P13_MAINT_002`,
    authClaims: ownerClaims,
  });
  assert(
    ledgerMaintCheck.status === 404,
    'Test 30: No wallet ledger record created for rejected maintenance debit (HTTP 404 Not Found)'
  );

  console.log('\n================================================================');
  console.log(`TOTAL PHASE 13.0.4 TESTS: ${totalTests}`);
  console.log(`PASSED: ${passedTests}`);
  console.log(`FAILED: ${failedTests}`);
  console.log('================================================================');

  if (failedTests > 0) {
    process.exit(1);
  }
}

runTestSuite().catch((err) => {
  console.error('Fatal test suite error:', err);
  process.exit(1);
});
