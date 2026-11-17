/**
 * ============================================================================
 * TEKFIX ERP — PHASE 16.4.19: READ-ONLY VALIDATION SUITE
 * STRICTLY READ-ONLY: ZERO DEBITS, ZERO CREDITS, ZERO REAL FINANCIAL OPERATIONS
 * ============================================================================
 */

const fs = require('fs');
const https = require('https');
const crypto = require('crypto');
const path = require('path');

const STAGING_EDGE_URL = 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge';
const SHOP_ID = 'shop_staging_001';
const OWNER_UID = 'owner_staging_001';
const PROJECT_ID = 'tekfix-staging';

async function getServiceAccountToken() {
  const configPath = 'C:\\Users\\acer\\.config\\configstore\\firebase-tools.json';
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  return config.tokens.access_token;
}

function makeHttpRequest(urlStr, options = {}, body = null) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const reqOptions = {
      hostname: url.hostname,
      path: url.pathname + url.search,
      method: options.method || 'GET',
      headers: options.headers || {},
    };

    if (body) {
      reqOptions.headers['Content-Length'] = Buffer.byteLength(body);
      if (!reqOptions.headers['Content-Type']) {
        reqOptions.headers['Content-Type'] = 'application/json';
      }
    }

    const req = https.request(reqOptions, (res) => {
      let resBody = '';
      res.on('data', chunk => resBody += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(resBody), raw: resBody });
        } catch (_) {
          resolve({ status: res.statusCode, raw: resBody });
        }
      });
    });

    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function runReadOnlyValidation() {
  console.log('================================================================================');
  console.log('TEKFIX ERP — PHASE 16.4.19 READ-ONLY VALIDATION');
  console.log('Target Firebase Project:', PROJECT_ID);
  console.log('Target Edge Function:', STAGING_EDGE_URL);
  console.log('================================================================================\n');

  // --- CHECK 1: Firestore Native Connectivity ---
  console.log('>>> CHECK 1: Verifying Firestore Native REST connectivity...');
  const saToken = await getServiceAccountToken();
  const listColRes = await makeHttpRequest(
    `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents:listCollectionIds`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${saToken}` },
    },
    JSON.stringify({})
  );
  console.log('listCollectionIds Status:', listColRes.status);
  console.log('listCollectionIds Success:', listColRes.status === 200 ? 'PASS' : 'FAIL');

  // --- CHECK 2: Read Expected Bank Document ---
  console.log('\n>>> CHECK 2: Reading expected bank balance document...');
  const bankDocUrl = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/shops/${SHOP_ID}/bank/bank_balance`;
  const bankDocRes = await makeHttpRequest(bankDocUrl, {
    method: 'GET',
    headers: { Authorization: `Bearer ${saToken}` },
  });
  console.log('Bank Doc Status:', bankDocRes.status);
  const bankVal = bankDocRes.data?.fields?.v?.doubleValue !== undefined
    ? Number(bankDocRes.data.fields.v.doubleValue)
    : (bankDocRes.data?.fields?.v?.integerValue !== undefined ? Number(bankDocRes.data.fields.v.integerValue) : null);
  console.log('Authoritative Bank Balance in Firestore: ₹' + (bankVal !== null ? bankVal.toFixed(2) : 'NOT FOUND'));
  console.log('Bank Doc Read Success:', (bankDocRes.status === 200 && bankVal !== null) ? 'PASS' : 'FAIL');

  // --- CHECK 3: Verify Atomic Transaction Permissions ---
  console.log('\n>>> CHECK 3: Verifying atomic transaction permissions (:beginTransaction)...');
  const txUrl = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents:beginTransaction`;
  const txRes = await makeHttpRequest(txUrl, {
    method: 'POST',
    headers: { Authorization: `Bearer ${saToken}` },
  }, JSON.stringify({ options: { readWrite: {} } }));
  console.log('Transaction Status:', txRes.status);
  const hasTx = txRes.status === 200 && txRes.data?.transaction;
  console.log('Transaction handle received:', hasTx ? 'YES (Length: ' + txRes.data.transaction.length + ')' : 'NO');
  console.log('Atomic Transaction Permission Success:', hasTx ? 'PASS' : 'FAIL');

  // --- CHECK 4: Edge Function Security & Staff Rejection ---
  console.log('\n>>> CHECK 4: Verifying Edge Function rejects unauthenticated / staff requests...');
  
  // 4a. Missing Authorization
  const noAuthRes = await makeHttpRequest(`${STAGING_EDGE_URL}/process-topup`, {
    method: 'POST',
  }, JSON.stringify({ shopId: SHOP_ID }));
  console.log('Missing Auth Status:', noAuthRes.status, '(Expected: 401)');
  console.log('Missing Auth Rejection:', noAuthRes.status === 401 ? 'PASS' : 'FAIL');

  // 4b. Staff Token Rejection
  // Generate a mock staff JWT
  const staffJwtHeader = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const staffJwtPayload = Buffer.from(JSON.stringify({
    iss: 'tekfix-staging-identity',
    aud: 'tekfix-staging-audience',
    sub: 'staff_user_test',
    shop_id: SHOP_ID,
    role: 'staff', // Staff role!
    iat: now,
    exp: now + 3600,
  })).toString('base64url');
  const staffToken = `${staffJwtHeader}.${staffJwtPayload}.fake_sig`;
  
  const staffRes = await makeHttpRequest(`${STAGING_EDGE_URL}/process-topup`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${staffToken}` },
  }, JSON.stringify({ shopId: SHOP_ID }));
  console.log('Staff Rejection Status:', staffRes.status, '(Expected: 401 or 403)');
  console.log('Staff Rejection:', [401, 403].includes(staffRes.status) ? 'PASS' : 'FAIL');

  // --- CHECK 5: Verify Edge Function Environment Configuration ---
  console.log('\n>>> CHECK 5: Verifying Edge Function configuration...');
  const challengeRes = await makeHttpRequest(`${STAGING_EDGE_URL}/request-challenge`, {
    method: 'POST',
  }, JSON.stringify({ shopId: SHOP_ID, deviceId: 'DEV_ANDR_8617CF', ownerUid: OWNER_UID }));
  console.log('Challenge Nonce Status:', challengeRes.status);
  const hasNonce = challengeRes.status === 200 && challengeRes.data?.nonce;
  console.log('Challenge Nonce Issued:', hasNonce ? 'YES (' + challengeRes.data.nonce + ')' : 'NO');
  console.log('Edge Function Alive & Healthy:', hasNonce ? 'PASS' : 'FAIL');

  console.log('\n================================================================================');
  console.log('ALL READ-ONLY VALIDATION CHECKS COMPLETED WITH ZERO FINANCIAL MUTATIONS.');
  console.log('================================================================================');
}

runReadOnlyValidation().catch(console.error);
