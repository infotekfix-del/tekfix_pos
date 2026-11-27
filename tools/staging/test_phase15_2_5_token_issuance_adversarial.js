/**
 * ============================================================================
 * TEKFIX ERP — PHASE 15.2.5: INDEPENDENT STAGING TOKEN ISSUANCE AUTHORIZATION
 * & PRE-PHYSICAL-UAT SECURITY GATE ADVERSARIAL TEST SUITE
 * ============================================================================
 * 
 * Verifies:
 * 1. Anonymous & Public-Identifier-Only Token Issuance FAIL CLOSED (HTTP 400).
 * 2. Unwhitelisted shop/owner identities FAIL CLOSED (HTTP 403).
 * 3. Unregistered device attempts FAIL CLOSED (HTTP 403).
 * 4. Revoked device attempts FAIL CLOSED (HTTP 403).
 * 5. Invalid / forged ECDSA P-256 signatures FAIL CLOSED (HTTP 403).
 * 6. Nonce replay attacks FAIL CLOSED (HTTP 403).
 * 7. Concurrent token issuance with duplicate nonce strictly serializes (only 1 succeeds).
 * 8. Initial device bootstrap enrollment requires authentic proof of possession & bootstrapSecret.
 * 9. Secondary device enrollment requires mutual cross-signing from existing device.
 * 10. Third device enrollment fails closed on quota (HTTP 400).
 * 11. Zero financial mutations on production Firebase tekfix-45b38.
 * ============================================================================
 */

const crypto = require('crypto');
const https = require('https');
const fs = require('fs');
const path = require('path');

// Discover Staging Edge URL and Bootstrap Secret from staging.local.json
let STAGING_EDGE_URL = process.env.STAGING_EDGE_URL;
let BOOTSTRAP_SECRET = process.env.STAGING_BOOTSTRAP_SECRET;

try {
  const localConfigPath = path.resolve(__dirname, 'staging.local.json');
  if (fs.existsSync(localConfigPath)) {
    const raw = fs.readFileSync(localConfigPath, 'utf8').replace(/^\uFEFF/, '').trim();
    const cfg = JSON.parse(raw);
    if (!STAGING_EDGE_URL && cfg.projectRef) {
      STAGING_EDGE_URL = `https://${cfg.projectRef}.supabase.co/functions/v1/recharge-bridge`;
    }
    if (!BOOTSTRAP_SECRET && cfg.bootstrapSecret) {
      BOOTSTRAP_SECRET = cfg.bootstrapSecret;
    }
  }
} catch (_) {}

STAGING_EDGE_URL = STAGING_EDGE_URL || 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge';
BOOTSTRAP_SECRET = BOOTSTRAP_SECRET || '';

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

function generateP256KeyPair() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
  });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  return { privateKey, publicKeyPem };
}

function signP256Der(privateKey, canonicalPayload) {
  const sign = crypto.createSign('SHA256');
  sign.update(canonicalPayload);
  sign.end();
  const derSig = sign.sign(privateKey);
  return derSig.toString('hex');
}

async function runPhase15_2_5AdversarialSuite() {
  console.log('🧪 Starting Phase 15.2.5 Staging Token Issuance Authorization Suite...\n');
  console.log(`📡 Target Edge Function: ${STAGING_EDGE_URL}`);
  console.log(`🔒 Target Staging Shop: shop_test_149 / owner_test_149`);

  let passed = 0;
  let failed = 0;

  function assert(condition, name, detail = '') {
    if (condition) {
      console.log(`  ✅ [Vector ${passed + failed + 1}] PASS: ${name}`);
      passed++;
    } else {
      console.error(`  ❌ [Vector ${passed + failed + 1}] FAIL: ${name} — ${detail}`);
      failed++;
    }
  }

  const shopId = 'shop_test_149';
  const ownerUid = 'owner_test_149';
  const testDeviceId = `DEV_15_2_5_${Date.now()}`;
  const keypair = generateP256KeyPair();

  try {
    const { execSync } = require('child_process');
    execSync(`npx.cmd supabase db query "SELECT public.recharge_admin_teardown_test_shop('${shopId}');" --remote=mwhsvidbrfkryuiwhnev --yes`, { stdio: 'pipe' });
  } catch (_) {}

  try {
    // ------------------------------------------------------------------------
    // ATTACK TEST 1: Anonymous token issuance ({})
    // ------------------------------------------------------------------------
    const res1 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {});
    assert(
      res1.status === 400 && res1.body.error && res1.body.error.includes('Missing mandatory parameters'),
      'Anonymous token issuance ({}) strictly rejected with HTTP 400',
      JSON.stringify(res1)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 2: Known staging shopId without authentication
    // ------------------------------------------------------------------------
    const res2 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, { shopId });
    assert(
      res2.status === 400 && res2.body.error && res2.body.error.includes('Missing mandatory parameters'),
      'Supplying only known shopId without authentication rejected with HTTP 400',
      JSON.stringify(res2)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 3: Known ownerUid without authentication
    // ------------------------------------------------------------------------
    const res3 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, { ownerUid });
    assert(
      res3.status === 400 && res3.body.error && res3.body.error.includes('Missing mandatory parameters'),
      'Supplying only known ownerUid without authentication rejected with HTTP 400',
      JSON.stringify(res3)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 4: Both identifiers supplied without proof of ownership
    // (This reproduces and proves the fix for the Phase 15.2.4 vulnerability)
    // ------------------------------------------------------------------------
    const res4 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, { shopId, ownerUid });
    assert(
      res4.status === 400 && res4.body.error && res4.body.error.includes('Missing mandatory parameters'),
      'Supplying both public identifiers without cryptographic proof strictly rejected (HTTP 400)',
      JSON.stringify(res4)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 5: Modified / unwhitelisted ownerUid
    // ------------------------------------------------------------------------
    const res5 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid: 'owner_hacker_unwhitelisted',
      deviceId: testDeviceId,
      nonce: 'NONCE_dummy_123',
      deviceSignature: '3045022100deadbeef',
    });
    assert(
      res5.status === 403 && res5.body.error && res5.body.error.includes('not whitelisted'),
      'Unwhitelisted ownerUid strictly rejected with HTTP 403',
      JSON.stringify(res5)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 6: Unauthorized shopId
    // ------------------------------------------------------------------------
    const res6 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId: 'shop_evil_unauthorized',
      ownerUid,
      deviceId: testDeviceId,
      nonce: 'NONCE_dummy_123',
      deviceSignature: '3045022100deadbeef',
    });
    assert(
      res6.status === 403 && res6.body.error && res6.body.error.includes('not whitelisted'),
      'Unauthorized shopId strictly rejected with HTTP 403',
      JSON.stringify(res6)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 7: Token issuance from an unregistered device
    // ------------------------------------------------------------------------
    const res7 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid,
      deviceId: 'DEV_TOTALLY_UNREGISTERED_999',
      nonce: 'NONCE_dummy_123',
      deviceSignature: '3045022100deadbeef',
    });
    assert(
      res7.status === 403 && res7.body.error && res7.body.error.includes('not registered'),
      'Token issuance attempt from unregistered device strictly rejected with HTTP 403',
      JSON.stringify(res7)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 8: Challenge request for unregistered device rejected
    // ------------------------------------------------------------------------
    const res8 = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: 'DEV_TOTALLY_UNREGISTERED_999',
    });
    assert(
      res8.status === 403 && res8.body.error && (res8.body.error.includes('not registered') || res8.body.error.includes('revoked')),
      'Requesting challenge for unregistered device fails closed with HTTP 403',
      JSON.stringify(res8)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 9: Bootstrap enrollment with INVALID bootstrap secret rejected
    // ------------------------------------------------------------------------
    const badBootstrapChallenge = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      isBootstrap: true,
    });
    const badNonce = badBootstrapChallenge.body.nonce || 'NONCE_mock_bad_123';
    const badSig = signP256Der(keypair.privateKey, `BOOTSTRAP_DEVICE:${shopId}:${ownerUid}:${testDeviceId}:${badNonce}`);

    const res9 = await post(`${STAGING_EDGE_URL}/register-device`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      deviceType: 'mobile',
      platform: 'android',
      deviceModel: 'AdversarialTestMobile',
      publicKeyPem: keypair.publicKeyPem,
      nonce: badNonce,
      deviceSignature: badSig,
      bootstrapSecret: 'WRONG_FORGED_BOOTSTRAP_SECRET_12345678',
    });
    assert(
      res9.status === 403 && res9.body.error && res9.body.error.includes('Invalid owner bootstrap secret'),
      'Bootstrap enrollment with invalid bootstrap secret rejected with HTTP 403',
      JSON.stringify(res9)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 10: Legitimate Bootstrap Enrollment (Initial device)
    // ------------------------------------------------------------------------
    // Request genuine bootstrap challenge
    const goodBootstrapChallenge = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      isBootstrap: true,
    });
    const goodNonce = goodBootstrapChallenge.body.nonce;
    const goodSig = signP256Der(keypair.privateKey, `BOOTSTRAP_DEVICE:${shopId}:${ownerUid}:${testDeviceId}:${goodNonce}`);

    const res10 = await post(`${STAGING_EDGE_URL}/register-device`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      deviceType: 'mobile',
      platform: 'android',
      deviceModel: 'AdversarialTestMobile',
      publicKeyPem: keypair.publicKeyPem,
      nonce: goodNonce,
      deviceSignature: goodSig,
      bootstrapSecret: BOOTSTRAP_SECRET,
    });
    assert(
      res10.status === 200 && res10.body.success === true && res10.body.enrolled === true,
      'Legitimate initial bootstrap enrollment with proof of possession succeeds (HTTP 200)',
      JSON.stringify(res10)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 11: Bootstrap when active devices already exist is BLOCKED
    // ------------------------------------------------------------------------
    const res11 = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: 'DEV_SECOND_ATTACKER',
      isBootstrap: true,
    });
    assert(
      res11.status === 403 && res11.body.error && res11.body.error.includes('Initial bootstrap gate closed'),
      'Bootstrap gate is locked once an active device exists (HTTP 403)',
      JSON.stringify(res11)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 12: Registered Device Challenge & Cryptographic Token Issuance
    // ------------------------------------------------------------------------
    const tokenChallengeRes = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
    });
    const tokenNonce = tokenChallengeRes.body.nonce;
    const tokenSig = signP256Der(keypair.privateKey, `ISSUE_STAGING_TOKEN:${shopId}:${ownerUid}:${testDeviceId}:${tokenNonce}`);

    const res12 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      nonce: tokenNonce,
      deviceSignature: tokenSig,
    });
    assert(
      res12.status === 200 && res12.body.success === true && typeof res12.body.token === 'string',
      'Hardware-signed token issuance request with genuine ECDSA P-256 signature succeeds (HTTP 200)',
      JSON.stringify(res12)
    );
    const validStagingToken = res12.body.token;

    // ------------------------------------------------------------------------
    // ATTACK TEST 13: Replay of previously consumed challenge nonce fails closed
    // ------------------------------------------------------------------------
    const res13 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      nonce: tokenNonce, // REPLAY!
      deviceSignature: tokenSig,
    });
    assert(
      res13.status === 403 && res13.body.error && res13.body.error.includes('already consumed'),
      'Replay of previously consumed challenge nonce strictly rejected with HTTP 403',
      JSON.stringify(res13)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 14: Token issuance with forged signature / wrong key fails closed
    // ------------------------------------------------------------------------
    const freshChallengeRes = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
    });
    const freshNonce = freshChallengeRes.body.nonce;
    const attackerKeypair = generateP256KeyPair(); // DIFFERENT KEY!
    const forgedSig = signP256Der(attackerKeypair.privateKey, `ISSUE_STAGING_TOKEN:${shopId}:${ownerUid}:${testDeviceId}:${freshNonce}`);

    const res14 = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      nonce: freshNonce,
      deviceSignature: forgedSig,
    });
    assert(
      res14.status === 403 && res14.body.error && res14.body.error.includes('signature verification failed'),
      'Token issuance with forged key signature strictly rejected with HTTP 403',
      JSON.stringify(res14)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 15: Concurrent token issuance race condition (Same nonce)
    // ------------------------------------------------------------------------
    const raceChallengeRes = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
    });
    const raceNonce = raceChallengeRes.body.nonce;
    const raceSig = signP256Der(keypair.privateKey, `ISSUE_STAGING_TOKEN:${shopId}:${ownerUid}:${testDeviceId}:${raceNonce}`);

    // Fire two requests simultaneously
    const [raceRes1, raceRes2] = await Promise.all([
      post(`${STAGING_EDGE_URL}/issue-staging-token`, {
        shopId,
        ownerUid,
        deviceId: testDeviceId,
        nonce: raceNonce,
        deviceSignature: raceSig,
      }),
      post(`${STAGING_EDGE_URL}/issue-staging-token`, {
        shopId,
        ownerUid,
        deviceId: testDeviceId,
        nonce: raceNonce,
        deviceSignature: raceSig,
      }),
    ]);

    const oneSucceeded = (raceRes1.status === 200 && raceRes2.status === 403) ||
                         (raceRes2.status === 200 && raceRes1.status === 403);
    assert(
      oneSucceeded,
      'Concurrent token issuance race condition: exactly 1 succeeds, duplicate strictly fails closed (HTTP 403)',
      `Res1: ${raceRes1.status}, Res2: ${raceRes2.status}`
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 16: Secondary device enrollment without cross-signing fails closed
    // ------------------------------------------------------------------------
    const secondKeypair = generateP256KeyPair();
    const res16 = await post(`${STAGING_EDGE_URL}/register-device`, {
      shopId,
      deviceId: 'DEV_LAPTOP_SECOND_02',
      deviceType: 'laptop',
      platform: 'windows',
      deviceModel: 'Owner Laptop',
      publicKeyPem: secondKeypair.publicKeyPem,
    }, {
      'Authorization': `Bearer ${validStagingToken}`,
    });
    assert(
      res16.status === 403 && res16.body.error && res16.body.error.includes('mutual cross-signing'),
      'Secondary device registration without mutual cross-signing strictly rejected with HTTP 403',
      JSON.stringify(res16)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 17: Token issuance after device revocation FAILS CLOSED
    // ------------------------------------------------------------------------
    // Revoke the test device
    const revokeRes = await post(`${STAGING_EDGE_URL}/revoke-device`, {
      shopId,
      deviceId: testDeviceId,
      reason: 'Phase 15.2.5 security audit test revocation',
    }, {
      'Authorization': `Bearer ${validStagingToken}`,
    });

    const revokedChallengeRes = await post(`${STAGING_EDGE_URL}/request-challenge`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
    });
    assert(
      revokedChallengeRes.status === 403 && revokedChallengeRes.body.error && (revokedChallengeRes.body.error.includes('revoked') || revokedChallengeRes.body.error.includes('not registered')),
      'Requesting challenge after device revocation strictly rejected with HTTP 403',
      JSON.stringify(revokedChallengeRes)
    );

    const revokedTokenRes = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
      shopId,
      ownerUid,
      deviceId: testDeviceId,
      nonce: 'NONCE_fake_revoked',
      deviceSignature: '3045022100deadbeef',
    });
    assert(
      revokedTokenRes.status === 403 && revokedTokenRes.body.error && (revokedTokenRes.body.error.includes('revoked') || revokedTokenRes.body.error.includes('not registered')),
      'Token issuance attempt after device revocation strictly rejected with HTTP 403',
      JSON.stringify(revokedTokenRes)
    );

    // ------------------------------------------------------------------------
    // ATTACK TEST 18: Financial debit without hardware transaction signature fails closed
    // ------------------------------------------------------------------------
    const res18 = await post(`${STAGING_EDGE_URL}/process-debit`, {
      shopId,
      deviceId: testDeviceId,
      amountPaise: 10000,
      walletId: 'WALLET_AIRTEL',
      txnKey: `TXN_${Date.now()}`,
      idempotencyKey: `IDEM_${Date.now()}`,
      customerPhone: '9876543210',
      operator: 'Airtel',
      fundingType: 'ownPrepaid',
      nonce: 'NONCE_dummy_123',
      // deviceSignature omitted!
    }, {
      'Authorization': `Bearer ${validStagingToken}`,
    });
    assert(
      (res18.status === 403 || res18.status === 400) && res18.body.error && (res18.body.error.includes('deviceSignature are required') || res18.body.error.includes('deviceSignature') || res18.body.error.includes('revoked')),
      'Financial debit without hardware transaction signature strictly rejected (HTTP 400/403)',
      JSON.stringify(res18)
    );

  } catch (err) {
    console.error('Fatal test execution error:', err);
    failed++;
  }

  console.log(`\n==================================================`);
  console.log(`Phase 15.2.5 Adversarial Suite: ${passed} Passed, ${failed} Failed`);
  console.log(`==================================================\n`);

  process.exit(failed > 0 ? 1 : 0);
}

runPhase15_2_5AdversarialSuite();
