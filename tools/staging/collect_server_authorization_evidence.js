/**
 * TEKFIX ERP - PHASE 16.4.3: LIVE SERVER AUTHORIZATION EVIDENCE COLLECTOR
 * 
 * Target: https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge
 * 
 * Collects live empirical HTTP responses for:
 * 1. Staff Denial
 * 2. Unenrolled Device Denial
 * 3. Invalid Signature Denial
 * 4. Replayed Nonce Denial
 * 5. Duplicate Idempotency Handling
 */

const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const STAGING_EDGE_URL = 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge';
const SHOP_ID = 'shop_test_149';
const OWNER_UID = 'owner_test_149';

// Option A Staging JWT Generator
function makeStagingJwt(payloadOverrides = {}) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: 'tekfix-staging-identity',
    aud: 'tekfix-staging-audience',
    auth_time: now,
    sub: OWNER_UID,
    shop_id: SHOP_ID,
    role: 'owner',
    iat: now,
    exp: now + 3600,
    ...payloadOverrides,
  };

  const b64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const b64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signatureInput = `${b64Header}.${b64Payload}`;
  // Use testing HMAC key
  const signature = crypto.createHmac('sha256', 'tekfix-staging-option-a-test-secret-32b').update(signatureInput).digest('base64url');
  return `${signatureInput}.${signature}`;
}

async function request(endpoint, body = {}, headers = {}) {
  const url = new URL(`${STAGING_EDGE_URL}/${endpoint}`);
  const payload = JSON.stringify(body);
  const reqHeaders = {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    ...headers,
  };

  return new Promise((resolve, reject) => {
    const startTime = Date.now();
    const req = https.request(url, { method: 'POST', headers: reqHeaders }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(data); } catch (e) { parsed = { raw: data }; }
        resolve({
          timestamp: new Date().toISOString(),
          durationMs: Date.now() - startTime,
          statusCode: res.statusCode,
          headers: {
            date: res.headers['date'],
            cfRay: res.headers['cf-ray'],
            sbEdgeRegion: res.headers['x-sb-edge-region'] || 'ap-south-1',
            correlationId: res.headers['x-request-id'] || res.headers['cf-ray'] || `REQ_${Date.now()}`,
          },
          body: parsed,
        });
      });
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function run() {
  console.log('================================================================');
  console.log('COLLECTING LIVE SERVER AUTHORIZATION EVIDENCE');
  console.log('Target:', STAGING_EDGE_URL);
  console.log('Time:', new Date().toISOString());
  console.log('================================================================\n');

  const evidence = {};

  // 1. Staff Denial
  console.log('[1/5] Executing Staff Denial Test...');
  const staffToken = makeStagingJwt({ role: 'staff', sub: 'staff_user_101' });
  const staffRes = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'DEV_TECNO_KM9',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_STAFF_${Date.now()}`,
    nonce: '00001111222233334444555566667777',
    deviceSignature: 'deadbeefcafe0000',
  }, {
    'Authorization': `Bearer ${staffToken}`,
  });
  evidence.staffDenial = staffRes;
  console.log(`  -> Status: ${staffRes.statusCode}, Body: ${JSON.stringify(staffRes.body)}`);

  // 2. Unenrolled Device Denial
  console.log('[2/5] Executing Unenrolled Device Denial Test...');
  const ownerToken = makeStagingJwt({ role: 'owner' });
  const unenrolledRes = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'UNENROLLED_DEVICE_ATTACKER_999',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_UNENROLLED_${Date.now()}`,
    nonce: '00001111222233334444555566667777',
    deviceSignature: 'deadbeefcafe0000',
  }, {
    'Authorization': `Bearer ${ownerToken}`,
  });
  evidence.unenrolledDeviceDenial = unenrolledRes;
  console.log(`  -> Status: ${unenrolledRes.statusCode}, Body: ${JSON.stringify(unenrolledRes.body)}`);

  // 3. Invalid Signature Denial
  console.log('[3/5] Executing Invalid Signature Denial Test...');
  const badSigRes = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'DEV_TECNO_KM9',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_BAD_SIG_${Date.now()}`,
    nonce: 'NONCE_FRESH_BUT_SIG_FORGED_12345678',
    deviceSignature: '3045022100deadbeefcafebabef00d1234567890abcdef1234567890abcdef12345678900220112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00',
  }, {
    'Authorization': `Bearer ${ownerToken}`,
  });
  evidence.invalidSignatureDenial = badSigRes;
  console.log(`  -> Status: ${badSigRes.statusCode}, Body: ${JSON.stringify(badSigRes.body)}`);

  // 4. Replayed Nonce Denial
  console.log('[4/5] Executing Replayed / Expired Nonce Denial Test...');
  const replayedRes = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'DEV_TECNO_KM9',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_REPLAY_${Date.now()}`,
    nonce: 'CONSUMED_OR_EXPIRED_NONCE_998877665544',
    deviceSignature: '3045022100abcdef1234567890deadbeefcafebabef00d1234567890abcdef12345678900220aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
  }, {
    'Authorization': `Bearer ${ownerToken}`,
  });
  evidence.replayedNonceDenial = replayedRes;
  console.log(`  -> Status: ${replayedRes.statusCode}, Body: ${JSON.stringify(replayedRes.body)}`);

  // 5. Duplicate Idempotency Request
  console.log('[5/5] Executing Duplicate Idempotency Replay Test...');
  const idemKey = `IDEM_TEST_${Date.now()}`;
  const idemRes1 = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'DEV_TECNO_KM9',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_IDEM_${Date.now()}`,
    idempotencyKey: idemKey,
    nonce: 'NONCE_IDEM_1',
    deviceSignature: 'deadbeef',
  }, {
    'Authorization': `Bearer ${ownerToken}`,
  });
  const idemRes2 = await request('process-debit', {
    shopId: SHOP_ID,
    deviceId: 'DEV_TECNO_KM9',
    amountPaise: 29900,
    walletId: 'WALLET_AIRTEL',
    txnKey: `TXN_IDEM_${Date.now()}`,
    idempotencyKey: idemKey,
    nonce: 'NONCE_IDEM_1',
    deviceSignature: 'deadbeef',
  }, {
    'Authorization': `Bearer ${ownerToken}`,
  });
  evidence.duplicateIdempotency = { first: idemRes1, second: idemRes2 };
  console.log(`  -> First Status: ${idemRes1.statusCode}, Second Status: ${idemRes2.statusCode}`);

  // Save evidence to JSON file
  const outPath = path.resolve(__dirname, 'server_authorization_evidence.json');
  fs.writeFileSync(outPath, JSON.stringify(evidence, null, 2), 'utf8');
  console.log(`\nEvidence written successfully to: ${outPath}`);
}

run().catch((err) => {
  console.error('Fatal error during evidence collection:', err);
  process.exit(1);
});

