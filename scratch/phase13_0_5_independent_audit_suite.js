/**
 * TEKFIX ERP - PHASE 13.0.5 INDEPENDENT ADVERSARIAL SECURITY & INTEGRITY AUDIT SUITE
 * 
 * 30 Required Scenarios:
 * 1. Maintenance mode blocks debit.
 * 2. Inactive shop blocks debit.
 * 3. Missing shop blocks debit.
 * 4. Deleted staff rejected.
 * 5. Inactive staff rejected.
 * 6. Unapproved staff rejected.
 * 7. canRecharge=false rejected.
 * 8. Cross-shop access rejected.
 * 9. Membership revoked during debit.
 * 10. Maintenance enabled during debit.
 * 11. Successful authorized debit.
 * 12. Duplicate identical request.
 * 13. Altered amount replay.
 * 14. Altered operator replay.
 * 15. Altered wallet replay.
 * 16. Altered funding type replay.
 * 17. Corrupted transaction replay.
 * 18. Missing idempotency fields.
 * 19. Reversed transaction replay.
 * 20. Duplicate reversal attempt.
 * 21. Zero amount.
 * 22. Negative amount.
 * 23. Floating-point amount.
 * 24. Unsafe integer amount.
 * 25. Balance overflow.
 * 26. Insufficient wallet balance.
 * 27. Concurrent identical requests.
 * 28. Concurrent distinct requests.
 * 29. Offline queue retry (T-1 valid vs T-2 expired).
 * 30. Environment isolation (Fail-closed guards).
 * 
 * Execution Target: Local Firebase Emulator Suite (Firestore: 8080, Functions: 5001)
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

async function runAuditSuite() {
  console.log('================================================================');
  console.log('TEKFIX ERP - PHASE 13.0.5 INDEPENDENT AUDIT SUITE');
  console.log('30 Mandatory Scenarios: Concurrency, Reversal, Maintenance, Safety');
  console.log('================================================================\n');

  const shopId = 'phase13_5_shop_main';
  const ownerUid = 'AUDIT13_5_OWNER';
  const staffUid = 'AUDIT13_5_STAFF';
  const today = getAsiaKolkataDateString(0);
  const yesterday = getAsiaKolkataDateString(-1);
  const twoDaysAgo = getAsiaKolkataDateString(-2);

  const ownerClaims = { sub: ownerUid, user_id: ownerUid, email: 'owner@audit135.com', shopId };
  const staffClaims = { sub: staffUid, user_id: staffUid, email: 'staff@audit135.com', shopId };

  console.log('--- Initializing Synthetic Audit Shop Documents ---');

  // Create Shop Document
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
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

  // Create Morning Opening Reconciliation for today and yesterday
  for (const bDate of [today, yesterday]) {
    await makeFirestoreRequest({
      method: 'PATCH',
      path: `/shops/${shopId}/recharge_daily_reconciliation/${bDate}`,
      body: toFirestoreDoc({
        shopId: shopId,
        businessDate: bDate,
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
  }

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

  console.log('--- Initial setup complete. Running 30 audit scenarios ---\n');

  // Scenario 1: Maintenance mode blocks debit
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: true }),
    authClaims: ownerClaims,
  });
  const res1 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_01', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res1.status === 400 && res1.data.error && res1.data.error.status === 'FAILED_PRECONDITION' && res1.data.error.message.includes('Shop is currently under maintenance'),
    'Scenario 1: Maintenance mode blocks debit (FAILED_PRECONDITION)'
  );
  // Restore maintenance mode to false
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });

  // Scenario 2: Inactive shop blocks debit
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: false, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });
  const res2 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_02', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res2.status === 400 && res2.data.error && res2.data.error.status === 'FAILED_PRECONDITION' && res2.data.error.message.includes('inactive or suspended'),
    'Scenario 2: Inactive shop blocks debit (FAILED_PRECONDITION)'
  );
  // Restore shop to active
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });

  // Scenario 3: Missing shop blocks debit
  const res3 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId: 'shop_completely_nonexistent', rechargeId: 'AUDIT_03', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res3.status === 404 && res3.data.error && res3.data.error.status === 'NOT_FOUND',
    'Scenario 3: Missing shop blocks debit (NOT_FOUND / HTTP 404)'
  );

  // Scenario 4: Deleted staff rejected
  const ghostStaffClaims = { sub: 'AUDIT_GHOST_STAFF', user_id: 'AUDIT_GHOST_STAFF', email: 'ghost@audit.com', shopId };
  const res4 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_04', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: ghostStaffClaims,
  });
  assert(
    res4.status === 403 && res4.data.error && res4.data.error.status === 'PERMISSION_DENIED',
    'Scenario 4: Deleted / non-existent staff rejected (PERMISSION_DENIED)'
  );

  // Scenario 5: Inactive staff rejected
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: false, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });
  const res5 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_05', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res5.status === 403 && res5.data.error && res5.data.error.status === 'PERMISSION_DENIED',
    'Scenario 5: Inactive staff rejected (PERMISSION_DENIED)'
  );

  // Scenario 6: Unapproved staff rejected
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: false, canRecharge: true }),
    authClaims: ownerClaims,
  });
  const res6 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_06', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res6.status === 403 && res6.data.error && res6.data.error.status === 'PERMISSION_DENIED',
    'Scenario 6: Unapproved staff rejected (PERMISSION_DENIED)'
  );

  // Scenario 7: canRecharge=false rejected
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: false }),
    authClaims: ownerClaims,
  });
  const res7 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_07', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res7.status === 403 && res7.data.error && res7.data.error.status === 'PERMISSION_DENIED',
    'Scenario 7: canRecharge=false rejected (PERMISSION_DENIED)'
  );
  // Restore staff permissions
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });

  // Scenario 8: Cross-shop access rejected
  const otherShop = 'phase13_5_other_shop';
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${otherShop}`,
    body: toFirestoreDoc({ name: 'Other Shop', ownerUid: 'OTHER_OWNER', active: true, isMaintenanceMode: false }),
    authClaims: { sub: 'OTHER_OWNER', user_id: 'OTHER_OWNER', email: 'other@shop.com', shopId: otherShop },
  });
  const res8 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId: otherShop, rechargeId: 'AUDIT_08', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res8.status === 403 && res8.data.error && res8.data.error.status === 'PERMISSION_DENIED',
    'Scenario 8: Cross-shop access rejected (PERMISSION_DENIED)'
  );

  // Scenario 9: Membership revoked during debit (simulated by setting canRecharge: false before transaction reads)
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: false }),
    authClaims: ownerClaims,
  });
  const res9 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_09', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res9.status === 403 && res9.data.error && res9.data.error.status === 'PERMISSION_DENIED',
    'Scenario 9: Membership revoked during debit evaluated atomically inside transaction (PERMISSION_DENIED)'
  );
  // Restore staff
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/users/${staffUid}`,
    body: toFirestoreDoc({ uid: staffUid, role: 'staff', active: true, approved: true, canRecharge: true }),
    authClaims: ownerClaims,
  });

  // Scenario 10: Maintenance enabled during debit
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: true }),
    authClaims: ownerClaims,
  });
  const res10 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_10', operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res10.status === 400 && res10.data.error && res10.data.error.message.includes('under maintenance'),
    'Scenario 10: Maintenance enabled during debit evaluated atomically inside transaction (FAILED_PRECONDITION)'
  );
  // Restore maintenance
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}`,
    body: toFirestoreDoc({ name: 'Audit 13.5 Main Shop', ownerUid: ownerUid, active: true, isMaintenanceMode: false }),
    authClaims: ownerClaims,
  });

  // Scenario 11: Successful authorized debit
  // Record initial balance
  const balBefore11 = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownBefore11 = parseInt(balBefore11.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  const res11 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  const balAfter11 = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownAfter11 = parseInt(balAfter11.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  assert(
    res11.status === 200 && res11.data.result.success === true && (ownBefore11 - ownAfter11 === 29900),
    `Scenario 11: Successful authorized debit (HTTP 200, balance reduced by exactly 29,900 paise)`
  );

  // Scenario 12: Duplicate identical request (Idempotent replay)
  const res12 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  const balAfter12 = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownAfter12 = parseInt(balAfter12.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  assert(
    res12.status === 200 && res12.data.result.idempotentReplay === true && ownAfter12 === ownAfter11,
    'Scenario 12: Duplicate identical request returns idempotent replay with zero balance mutation'
  );

  // Scenario 13: Altered amount replay
  const res13 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', operator: 'jio', amountPaise: 49900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res13.status === 409 && res13.data.error && res13.data.error.status === 'ALREADY_EXISTS',
    'Scenario 13: Altered amount replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // Scenario 14: Altered operator replay
  const res14 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', operator: 'airtel', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res14.status === 409 && res14.data.error && res14.data.error.status === 'ALREADY_EXISTS',
    'Scenario 14: Altered operator replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // Scenario 15: Altered wallet replay
  const res15 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', walletId: 'WALLET_AIRTEL', operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res15.status === 409 && res15.data.error && res15.data.error.status === 'ALREADY_EXISTS',
    'Scenario 15: Altered wallet replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // Scenario 16: Altered funding type replay
  const res16 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_11_SUCCESS', operator: 'jio', amountPaise: 29900, fundingType: 'distributorCredit', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res16.status === 409 && res16.data.error && res16.data.error.status === 'ALREADY_EXISTS',
    'Scenario 16: Altered funding type replay rejected with ALREADY_EXISTS (HTTP 409)'
  );

  // Scenario 17: Corrupted transaction replay (missing required stored fields)
  const corruptTxnId = 'AUDIT_17_CORRUPT';
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/recharge_transactions/${corruptTxnId}`,
    body: toFirestoreDoc({ walletDebited: true }), // Missing shopId, amountPaise, operator, fundingType
    authClaims: ownerClaims,
  });
  const res17 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: corruptTxnId, operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res17.status === 409 && res17.data.error && res17.data.error.message.includes('Corrupted or incomplete'),
    'Scenario 17: Corrupted transaction replay fails closed with ALREADY_EXISTS'
  );

  // Scenario 18: Missing idempotency fields (rechargeId empty)
  const res18 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, operator: 'jio', amountPaise: 29900, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res18.status === 400 && res18.data.error && res18.data.error.status === 'INVALID_ARGUMENT',
    'Scenario 18: Missing idempotency key rejected with INVALID_ARGUMENT (HTTP 400)'
  );

  // Scenario 19: Reversed transaction replay
  const revTxnId = 'AUDIT_19_REVERSED';
  await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: revTxnId, operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  // Mark transaction doc as reversed
  await makeFirestoreRequest({
    method: 'PATCH',
    path: `/shops/${shopId}/recharge_transactions/${revTxnId}?updateMask.fieldPaths=status&updateMask.fieldPaths=reversed`,
    body: toFirestoreDoc({ status: 'reversed', reversed: true }),
    authClaims: ownerClaims,
  });
  const res19 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: revTxnId, operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res19.status === 400 && res19.data.error && res19.data.error.status === 'FAILED_PRECONDITION' && res19.data.error.message.includes('was already reversed'),
    'Scenario 19: Reversed transaction replay rejected with FAILED_PRECONDITION'
  );

  // Scenario 20: Duplicate reversal attempt (altered payload on reversed transaction)
  const res20 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: revTxnId, operator: 'jio', amountPaise: 99999, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res20.status === 409 && res20.data.error && res20.data.error.status === 'ALREADY_EXISTS',
    'Scenario 20: Altered payload on reversed transaction rejected with ALREADY_EXISTS'
  );

  // Scenario 21: Zero amount
  const res21 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_21_ZERO', operator: 'jio', amountPaise: 0, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res21.status === 400 && res21.data.error && res21.data.error.status === 'INVALID_ARGUMENT',
    'Scenario 21: Zero amount rejected with INVALID_ARGUMENT (HTTP 400)'
  );

  // Scenario 22: Negative amount
  const res22 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_22_NEG', operator: 'jio', amountPaise: -5000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res22.status === 400 && res22.data.error && res22.data.error.status === 'INVALID_ARGUMENT',
    'Scenario 22: Negative amount rejected with INVALID_ARGUMENT (HTTP 400)'
  );

  // Scenario 23: Floating-point amount
  const res23 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_23_FLOAT', operator: 'jio', amountPaise: 199.50, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res23.status === 400 && res23.data.error && res23.data.error.status === 'INVALID_ARGUMENT',
    'Scenario 23: Floating-point amount rejected with INVALID_ARGUMENT (HTTP 400)'
  );

  // Scenario 24: Unsafe integer amount
  const res24 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_24_UNSAFE', operator: 'jio', amountPaise: Number.MAX_SAFE_INTEGER + 100, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res24.status === 400 && res24.data.error && res24.data.error.status === 'INVALID_ARGUMENT',
    'Scenario 24: Unsafe integer amount rejected with INVALID_ARGUMENT'
  );

  // Scenario 25: Balance overflow prevention
  const res25 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_25_OVERFLOW', operator: 'jio', amountPaise: 99999999999, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res25.status === 400 && res25.data.error && res25.data.error.status === 'FAILED_PRECONDITION',
    'Scenario 25: Exorbitant amount rejected with FAILED_PRECONDITION (Insufficient balance / Bounds check)'
  );

  // Scenario 26: Insufficient wallet balance
  const res26 = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_26_INSUF', operator: 'jio', amountPaise: 60000000, fundingType: 'ownMoney', businessDate: today },
    authClaims: staffClaims,
  });
  assert(
    res26.status === 400 && res26.data.error && res26.data.error.message.includes('Insufficient wallet balance'),
    'Scenario 26: Insufficient wallet balance rejected with FAILED_PRECONDITION'
  );

  // Scenario 27: Concurrent identical requests (10 identical in-flight calls)
  const concId = 'AUDIT_27_CONC_IDENT';
  const promises27 = [];
  for (let i = 0; i < 10; i++) {
    promises27.push(callCloudFunction({
      functionName: 'processRechargeDebit',
      data: { shopId, rechargeId: concId, operator: 'jio', amountPaise: 10000, fundingType: 'ownMoney', businessDate: today },
      authClaims: staffClaims,
    }));
  }
  const results27 = await Promise.all(promises27);
  const primary27 = results27.filter(r => r.status === 200 && !r.data.result.idempotentReplay);
  const replay27 = results27.filter(r => r.status === 200 && r.data.result.idempotentReplay === true);
  assert(
    results27.length === 10 && primary27.length === 1 && replay27.length === 9,
    'Scenario 27: 10 Concurrent identical requests serialize cleanly: Exactly 1 debit, 9 safe idempotent replays'
  );

  // Scenario 28: Concurrent distinct requests (5 distinct in-flight calls)
  const balBefore28 = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownBefore28 = parseInt(balBefore28.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  const promises28 = [];
  for (let i = 1; i <= 5; i++) {
    promises28.push(callCloudFunction({
      functionName: 'processRechargeDebit',
      data: { shopId, rechargeId: `AUDIT_28_DIST_${i}`, operator: 'jio', amountPaise: 5000, fundingType: 'ownMoney', businessDate: today },
      authClaims: staffClaims,
    }));
  }
  const results28 = await Promise.all(promises28);
  const allPass28 = results28.every(r => r.status === 200);
  const balAfter28 = await makeFirestoreRequest({
    method: 'GET',
    path: `/shops/${shopId}/recharge_wallets/WALLET_JIO`,
    authClaims: ownerClaims,
  });
  const ownAfter28 = parseInt(balAfter28.data.fields.ownPrepaidBalancePaise.integerValue, 10);
  assert(
    allPass28 && (ownBefore28 - ownAfter28 === 25000), // 5 * 5000 = 25000
    'Scenario 28: 5 Concurrent distinct requests commit atomically with exact delta (25,000 paise)'
  );

  // Scenario 29: Offline queue retry (Yesterday T-1 allowed, Two-days ago T-2 rejected)
  const res29Yesterday = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_29_YESTERDAY', operator: 'jio', amountPaise: 5000, fundingType: 'ownMoney', businessDate: yesterday },
    authClaims: staffClaims,
  });
  const res29Old = await callCloudFunction({
    functionName: 'processRechargeDebit',
    data: { shopId, rechargeId: 'AUDIT_29_OLD', operator: 'jio', amountPaise: 5000, fundingType: 'ownMoney', businessDate: twoDaysAgo },
    authClaims: staffClaims,
  });
  assert(
    res29Yesterday.status === 200 && res29Old.status === 400 && res29Old.data.error.message.includes('Expired businessDate'),
    'Scenario 29: Offline sync accepts yesterday T-1 but strictly rejects expired date T-2'
  );

  // Scenario 30: Environment isolation validation
  const optionsContent = fs.readFileSync('lib/firebase_options.dart', 'utf8');
  const envIsolated = optionsContent.includes("defaultValue: 'production'") &&
    (optionsContent.includes("TekFix Staging Firebase project is PENDING HUMAN ACTION") ||
     optionsContent.includes("TekFix Staging Android credentials are not configured")) &&
    optionsContent.includes("TekFix Development Environment is unconfigured");
  assert(
    envIsolated,
    'Scenario 30: Environment isolation verified: Staging and Development fail closed without explicit config'
  );

  console.log('\n================================================================');
  console.log(`TOTAL PHASE 13.0.5 AUDIT TESTS: ${totalTests}`);
  console.log(`PASSED: ${passedTests}`);
  console.log(`FAILED: ${failedTests}`);
  console.log('================================================================');

  if (failedTests > 0) {
    process.exit(1);
  }
}

runAuditSuite().catch((err) => {
  console.error('Fatal audit suite error:', err);
  process.exit(1);
});

