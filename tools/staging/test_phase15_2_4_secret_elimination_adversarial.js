/**
 * ============================================================================
 * TEKFIX ERP — PHASE 15.2.4: SECRET ELIMINATION & SERVER-AUTHORITATIVE IDENTITY
 * ADVERSARIAL VERIFICATION & ROTATION TEST SUITE
 * ============================================================================
 */

const crypto = require('crypto');
const https = require('https');
const fs = require('fs');
const path = require('path');

const STAGING_EDGE_URL = process.env.STAGING_EDGE_URL || 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge';
const OLD_COMPROMISED_SECRET = 'e98b04a8c3d791244f77c862d31295e8a715fbc304671e35a92a2a0c7eb723f1';

function post(url, data, headers = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(data);
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        ...headers,
      },
    }, res => {
      let resBody = '';
      res.on('data', c => resBody += c);
      res.on('end', () => {
        let parsed = {};
        try { parsed = JSON.parse(resBody); } catch (_) { parsed = { raw: resBody }; }
        resolve({ status: res.statusCode, body: parsed });
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function generateForgedJwt(payloadOverrides = {}, secret = OLD_COMPROMISED_SECRET, alg = 'HS256') {
  const header = { alg, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: 'tekfix-staging-identity',
    aud: 'tekfix-staging-audience',
    auth_time: now,
    sub: 'owner_staging_001',
    shop_id: 'shop_staging_001',
    role: 'owner',
    iat: now,
    exp: now + 3600,
    ...payloadOverrides,
  };

  const b64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const b64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signInput = `${b64Header}.${b64Payload}`;

  if (alg === 'none') {
    return `${signInput}.`;
  }

  const hmac = crypto.createHmac('sha256', Buffer.from(secret));
  hmac.update(signInput);
  const sig = hmac.digest('base64url');
  return `${signInput}.${sig}`;
}

async function runAdversarialTests() {
  console.log('🧪 Starting Phase 15.2.4 Adversarial Security & Secret Elimination Suite...\n');
  console.log(`📡 Target Edge Function: ${STAGING_EDGE_URL}\n`);

  let passed = 0;
  let failed = 0;

  function assert(condition, num, name, detail = '') {
    if (condition) {
      console.log(`  ✅ [Adv Vector ${num}] PASS: ${name}`);
      passed++;
    } else {
      console.error(`  ❌ [Adv Vector ${num}] FAIL: ${name} - ${detail}`);
      failed++;
    }
  }

  // ==========================================================================
  // SECTION A: SECRET SCAN & SOURCE EXPOSURE AUDIT
  // ==========================================================================
  const libDir = path.resolve(__dirname, '../../lib');
  function scanDirForRegex(dir, regex) {
    let matches = [];
    const files = fs.readdirSync(dir, { withFileTypes: true });
    for (const file of files) {
      const fullPath = path.join(dir, file.name);
      if (file.isDirectory()) {
        matches = matches.concat(scanDirForRegex(fullPath, regex));
      } else if (file.isFile() && file.name.endsWith('.dart')) {
        const content = fs.readFileSync(fullPath, 'utf8');
        if (regex.test(content)) {
          matches.push(fullPath);
        }
      }
    }
    return matches;
  }

  const matchesOldSecret = scanDirForRegex(libDir, /e98b04a8c3d791244f77c862d31295e8a715fbc304671e35a92a2a0c7eb723f1/);
  assert(matchesOldSecret.length === 0, 1, 'Client lib/ directory is 100% free of compromised secret', matchesOldSecret.join(', '));

  const matchesStagingSecretEnv = scanDirForRegex(libDir, /STAGING_JWT_SECRET/);
  assert(matchesStagingSecretEnv.length === 0, 2, 'Client lib/ directory contains zero STAGING_JWT_SECRET references', matchesStagingSecretEnv.join(', '));

  const stagingServiceContent = fs.readFileSync(path.resolve(__dirname, '../../lib/security/staging_identity_service.dart'), 'utf8');
  const hasClientHmac = stagingServiceContent.includes('Hmac') || stagingServiceContent.includes('crypto.dart');
  assert(!hasClientHmac, 3, 'Client StagingIdentityService contains zero cryptographic HMAC signing routines');

  // ==========================================================================
  // SECTION B: SERVER-AUTHORITATIVE TOKEN ISSUANCE & REVOCATION
  // ==========================================================================
  
  const testDevId = `DEV_ADV_1524_${Date.now()}`;
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  let bSecret = process.env.STAGING_BOOTSTRAP_SECRET || '';
  try {
    const localConfigPath = path.resolve(__dirname, 'staging.local.json');
    if (fs.existsSync(localConfigPath)) {
      const cfg = JSON.parse(fs.readFileSync(localConfigPath, 'utf8').replace(/^\uFEFF/, '').trim());
      if (cfg.bootstrapSecret) bSecret = cfg.bootstrapSecret;
    }
  } catch (_) {}

  // Enroll device on shop_test_149 if needed
  try {
    const { execSync } = require('child_process');
    execSync(`npx.cmd supabase db query "SELECT public.recharge_admin_teardown_test_shop('shop_test_149');" --remote=mwhsvidbrfkryuiwhnev --yes`, { stdio: 'pipe' });
  } catch (_) {}

  const bChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: 'shop_test_149',
    ownerUid: 'owner_test_149',
    deviceId: testDevId,
    isBootstrap: true,
    bootstrapSecret: bSecret,
  });

  let serverIssuedToken = '';
  if (bChal.status === 200 && bChal.body && bChal.body.nonce) {
    const bNonce = bChal.body.nonce;
    const sign = crypto.createSign('SHA256');
    sign.update(`BOOTSTRAP_DEVICE:shop_test_149:owner_test_149:${testDevId}:${bNonce}`);
    sign.end();
    const bSig = sign.sign(privateKey).toString('hex');

    const regRes = await post(`${STAGING_EDGE_URL}/register-device`, {
      shopId: 'shop_test_149',
      ownerUid: 'owner_test_149',
      deviceId: testDevId,
      deviceType: 'mobile',
      platform: 'android',
      deviceModel: 'AdvRunnerMobile',
      publicKeyPem,
      nonce: bNonce,
      deviceSignature: bSig,
      bootstrapSecret: bSecret,
      isBootstrap: true,
    });
    if (regRes.status === 200 && regRes.body && regRes.body.token) {
      serverIssuedToken = regRes.body.token;
    }
  }

  if (!serverIssuedToken) {
    const tChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId: 'shop_test_149',
      ownerUid: 'owner_test_149',
      deviceId: testDevId,
    });
    if (tChal.status === 200 && tChal.body && tChal.body.nonce) {
      const tNonce = tChal.body.nonce;
      const sign = crypto.createSign('SHA256');
      sign.update(`ISSUE_STAGING_TOKEN:shop_test_149:owner_test_149:${testDevId}:${tNonce}`);
      sign.end();
      const tSig = sign.sign(privateKey).toString('hex');
      const issueRes = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
        shopId: 'shop_test_149',
        ownerUid: 'owner_test_149',
        deviceId: testDevId,
        nonce: tNonce,
        deviceSignature: tSig,
      });
      if (issueRes.status === 200 && issueRes.body && issueRes.body.token) {
        serverIssuedToken = issueRes.body.token;
      }
    }
  }

  // Vector 4: Live server token issuance for whitelisted identity
  assert(
    typeof serverIssuedToken === 'string' && serverIssuedToken.split('.').length === 3,
    4,
    'Server successfully issues short-lived Option A JWT for whitelisted owner',
    serverIssuedToken ? 'Token acquired' : 'Failed to issue token'
  );

  // Vector 5: Live server token issuance rejection for unwhitelisted owner
  const unauthOwnerRes = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
    shopId: 'shop_staging_001',
    ownerUid: 'owner_attacker_fake',
    deviceId: testDevId,
    nonce: 'NONCE_mock_123',
    deviceSignature: '3045022100deadbeef',
  });
  assert(unauthOwnerRes.status === 403, 5, 'Server rejects unwhitelisted owner identity with HTTP 403', JSON.stringify(unauthOwnerRes.body));

  // Vector 6: Live server token issuance rejection for unknown shop
  const unauthShopRes = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
    shopId: 'shop_unregistered_xyz',
    ownerUid: 'owner_staging_001',
    deviceId: testDevId,
    nonce: 'NONCE_mock_123',
    deviceSignature: '3045022100deadbeef',
  });
  assert(unauthShopRes.status === 403, 6, 'Server rejects unwhitelisted shop ID with HTTP 403', JSON.stringify(unauthShopRes.body));

  // Vector 7: Old compromised secret revocation test
  const oldForgedToken = generateForgedJwt({}, OLD_COMPROMISED_SECRET);
  const oldSecretRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_staging_001',
  }, { 'Authorization': `Bearer ${oldForgedToken}` });
  assert(oldSecretRes.status === 401 && (oldSecretRes.body.error || '').includes('signature'), 7, 'Token signed with revoked secret is strictly rejected with HTTP 401 signature failure', JSON.stringify(oldSecretRes.body));

  // Vector 8: Valid server-issued token grants access to protected endpoints
  const validCallRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_test_149',
  }, { 'Authorization': `Bearer ${serverIssuedToken}` });
  assert(validCallRes.status === 200 && validCallRes.body.success === true, 8, 'Server-issued token successfully authorizes protected endpoint call', JSON.stringify(validCallRes.body));

  // Vector 9: Tampered payload on server-issued token fails closed
  const parts = serverIssuedToken.split('.');
  const tamperedPayload = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(parts[1], 'base64url').toString()), role: 'admin' })).toString('base64url');
  const tamperedToken = `${parts[0]}.${tamperedPayload}.${parts[2]}`;
  const tamperedRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_test_149',
  }, { 'Authorization': `Bearer ${tamperedToken}` });
  assert(tamperedRes.status === 401, 9, 'Tampered token payload is strictly rejected with HTTP 401', JSON.stringify(tamperedRes.body));

  // Vector 10: Algorithm confusion (alg: none) fails closed
  const noneToken = generateForgedJwt({}, OLD_COMPROMISED_SECRET, 'none');
  const noneRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_test_149',
  }, { 'Authorization': `Bearer ${noneToken}` });
  assert(noneRes.status === 401, 10, 'Unsigned token (alg: none) is strictly rejected with HTTP 401', JSON.stringify(noneRes.body));

  // Vector 11: Missing Authorization header fails closed
  const missingAuthRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_test_149',
  });
  assert(missingAuthRes.status === 401, 11, 'Request without Authorization header fails closed with HTTP 401', JSON.stringify(missingAuthRes.body));

  // Vector 12: Production Firebase token presented to staging fails closed
  const prodTokenHeader = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'fake_prod_kid' })).toString('base64url');
  const prodTokenPayload = Buffer.from(JSON.stringify({
    iss: 'https://securetoken.google.com/tekfix-45b38',
    aud: 'tekfix-45b38',
    sub: 'owner_test_149',
  })).toString('base64url');
  const prodFakeToken = `${prodTokenHeader}.${prodTokenPayload}.fakesig`;
  const prodTokenRes = await post(`${STAGING_EDGE_URL}/get-devices`, {
    shopId: 'shop_test_149',
  }, { 'Authorization': `Bearer ${prodFakeToken}` });
  assert(prodTokenRes.status === 401, 12, 'Production Firebase token is rejected on staging with algorithm/signature mismatch', JSON.stringify(prodTokenRes.body));

  // Vector 13: Financial modification without hardware ECDSA signature fails closed
  const unverifiedDebitRes = await post(`${STAGING_EDGE_URL}/process-debit`, {
    shopId: 'shop_test_149',
    walletId: 'WALLET_AIRTEL',
    amountPaise: 1000,
  }, { 'Authorization': `Bearer ${serverIssuedToken}` });
  assert(unverifiedDebitRes.status === 403 || unverifiedDebitRes.status === 400, 13, 'Financial debit without hardware signature fails closed before PostgreSQL ledger write', JSON.stringify(unverifiedDebitRes.body));

  // Cleanup test device
  await post(`${STAGING_EDGE_URL}/revoke-device`, {
    shopId: 'shop_test_149',
    deviceId: testDevId,
    reason: 'Test Cleanup',
  }, { 'Authorization': `Bearer ${serverIssuedToken}` });

  console.log(`\n==================================================`);
  console.log(`Phase 15.2.4 Adversarial Suite: ${passed} Passed, ${failed} Failed`);
  console.log(`==================================================\n`);

  if (failed > 0) process.exit(1);
}

runAdversarialTests().catch(err => {
  console.error('Fatal execution error in adversarial suite:', err);
  process.exit(1);
});

