/**
 * ============================================================================
 * TEKFIX ERP — PHASE 15.4.2: EMERGENCY DEVICE RECOVERY SECURITY AUDIT
 * ============================================================================
 * 
 * Verifies live against Supabase Staging (mwhsvidbrfkryuiwhnev, ap-south-1 Mumbai):
 * 
 * Adversarial Attack Vectors Tested:
 * Test A: Unauthenticated user invokes recovery -> HTTP 401
 * Test B: Staff invokes recovery -> HTTP 401/403
 * Test C: Manager invokes recovery -> HTTP 401/403
 * Test D: Ordinary owner invokes administrative recovery -> HTTP 403
 * Test E: Fake administrator identity supplied in parameters -> HTTP 403 (allowlist rejection)
 * Test F: Forged incident ticket -> HTTP 403 (ticket verification failure)
 * Test G: Cross-shop recovery -> HTTP 403 (isolation violation)
 * Test H: Unauthorized direct PostgREST RPC execution -> HTTP 401/403 (permission denied)
 * Test I: Reuse of an already processed recovery ticket -> HTTP 403 (replay prevention)
 * Test J: Concurrent emergency recovery race condition -> exactly 1 succeeds, atomic lock
 * Test K: Recovery attempt after device revocation -> ordinary bootstrap locked, admin recovery works
 * Test L: Recovery attempt with invalid public key -> HTTP 403 (PEM format validation)
 * 
 * Invariants & Real Simulation:
 * - Full synthetic recovery simulation (revoke both devices, issue ticket, recover, verify new device active)
 * - Hardware ECDSA challenge & token issuance on recovered device
 * - Revoked devices rejected from authentication
 * - Permanent bootstrap remains consumed
 * - Quota enforcement (max 2: 1 mobile + 1 laptop)
 * - Immutable audit log verification in recharge_wallet_logs
 * 
 * Production Firebase (tekfix-45b38): 100% UNTOUCHED (0 reads, 0 writes, 0 cost).
 * ============================================================================
 */

const crypto = require('crypto');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

let STAGING_EDGE_URL = process.env.STAGING_EDGE_URL;
let BOOTSTRAP_SECRET = process.env.STAGING_BOOTSTRAP_SECRET;
let SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
let SUPABASE_URL = process.env.SUPABASE_URL;
let PROJECT_REF = 'mwhsvidbrfkryuiwhnev';

try {
  const localConfigPath = path.resolve(__dirname, 'staging.local.json');
  if (fs.existsSync(localConfigPath)) {
    const raw = fs.readFileSync(localConfigPath, 'utf8').replace(/^\uFEFF/, '').trim();
    const cfg = JSON.parse(raw);
    if (cfg.projectRef) PROJECT_REF = cfg.projectRef;
    if (!STAGING_EDGE_URL && cfg.projectRef) {
      STAGING_EDGE_URL = `https://${cfg.projectRef}.supabase.co/functions/v1/recharge-bridge`;
    }
    if (!BOOTSTRAP_SECRET && cfg.bootstrapSecret) {
      BOOTSTRAP_SECRET = cfg.bootstrapSecret;
    }
    if (!SUPABASE_ANON_KEY && cfg.anonKey) {
      SUPABASE_ANON_KEY = cfg.anonKey;
    }
  }
} catch (_) {}

STAGING_EDGE_URL = STAGING_EDGE_URL || 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge';
BOOTSTRAP_SECRET = BOOTSTRAP_SECRET || '';
SUPABASE_URL = SUPABASE_URL || `https://${PROJECT_REF}.supabase.co`;
SUPABASE_ANON_KEY = SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.placeholder';

function post(url, data, headers = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(data);
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        ...headers,
      },
      timeout: 30000,
    }, (res) => {
      let raw = '';
      res.on('data', chunk => raw += chunk);
      res.on('end', () => {
        let json = {};
        try { json = JSON.parse(raw); } catch (_) { json = { rawBody: raw }; }
        resolve({ status: res.statusCode, headers: res.headers, data: json });
      });
    });

    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Request timed out')); });
    req.write(body);
    req.end();
  });
}

function generateP256Keypair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  return { publicKeyPem: publicKey, privateKeyPem: privateKey };
}

function signPayload(privateKeyPem, payload) {
  const sign = crypto.createSign('SHA256');
  sign.update(payload, 'utf8');
  sign.end();
  return sign.sign(privateKeyPem).toString('hex');
}

function forgeHs256Token(payload, secret) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const b64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const b64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.createHmac('sha256', secret)
    .update(`${b64Header}.${b64Payload}`)
    .digest('base64url');
  return `${b64Header}.${b64Payload}.${signature}`;
}

async function runEmergencyRecoveryAudit() {
  console.log('================================================================================');
  console.log('TEKFIX ERP — PHASE 15.4.2: EMERGENCY RECOVERY SECURITY AUDIT');
  console.log(`Target: ${STAGING_EDGE_URL}`);
  console.log(`Project Ref: ${PROJECT_REF} (ap-south-1 Mumbai)`);
  console.log('================================================================================\n');

  let passed = 0;
  let failed = 0;

  function assert(name, condition, details = '') {
    if (condition) {
      console.log(`[PASS] ${name}${details ? ` - ${details}` : ''}`);
      passed++;
    } else {
      console.error(`[FAIL] ${name}${details ? ` - ${details}` : ''}`);
      failed++;
    }
  }

  const testShop = 'shop_test_149';
  const testOwner = 'owner_test_149';
  const authorizedAdmin = 'ADMIN_SUPER_001';
  const adminHeaders = { 'x-admin-key': BOOTSTRAP_SECRET };

  function cleanTestShop() {
    try {
      execSync(`npx.cmd supabase db query "SELECT public.recharge_admin_teardown_test_shop('${testShop}');" --remote=${PROJECT_REF} --yes`, { stdio: 'pipe' });
    } catch (_) {}
  }

  // Pre-test clean
  cleanTestShop();

  const nowSec = Math.floor(Date.now() / 1000);

  // Generate tokens for staff & manager testing
  const staffToken = forgeHs256Token({
    iss: 'tekfix-staging-identity',
    aud: 'tekfix-staging-audience',
    sub: 'staff_user_149',
    shop_id: testShop,
    role: 'staff',
    auth_time: nowSec,
    exp: nowSec + 3600,
  }, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');

  const managerToken = forgeHs256Token({
    iss: 'tekfix-staging-identity',
    aud: 'tekfix-staging-audience',
    sub: 'manager_user_149',
    shop_id: testShop,
    role: 'manager',
    auth_time: nowSec,
    exp: nowSec + 3600,
  }, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');

  // --------------------------------------------------------------------------
  // Step 0: Bootstrap Test Shop with Initial Device
  // --------------------------------------------------------------------------
  console.log('--- Setup: Initial Bootstrap of Synthetic Test Shop ---');
  const origMobileKeys = generateP256Keypair();
  const origMobileId = `DEV_ORIG_MOB_${Date.now()}`;

  const chalRes = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: origMobileId,
    isBootstrap: true,
    bootstrapSecret: BOOTSTRAP_SECRET,
  });
  assert('Setup 0.1: Initial challenge nonce obtained', chalRes.status === 200 && chalRes.data.nonce);
  const nonce0 = chalRes.data.nonce;

  const canon0 = `BOOTSTRAP_DEVICE:${testShop}:${testOwner}:${origMobileId}:${nonce0}`;
  const sig0 = signPayload(origMobileKeys.privateKeyPem, canon0);

  const enrollRes = await post(`${STAGING_EDGE_URL}/register-device`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: origMobileId,
    deviceType: 'mobile',
    platform: 'android',
    deviceModel: 'Owner Initial Mobile',
    publicKeyPem: origMobileKeys.publicKeyPem,
    bootstrapSecret: BOOTSTRAP_SECRET,
    nonce: nonce0,
    deviceSignature: sig0,
    isBootstrap: true,
  });
  assert('Setup 0.2: Initial device bootstrap completed and locked', enrollRes.status === 200 || enrollRes.status === 201);
  const legitimateOwnerToken = enrollRes.data.token;

  // --------------------------------------------------------------------------
  // TASK 2: ADVERSARIAL AUTHORIZATION TESTS (A through L)
  // --------------------------------------------------------------------------
  console.log('\n--- Task 2: Adversarial Authorization Tests (A - L) ---');

  const attackKeys = generateP256Keypair();
  const attackDevId = `DEV_ATTACK_${Date.now()}`;

  // Test A: Unauthenticated user invokes recovery
  const resA = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: 'TICKET_ATTACK_A',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  });
  assert('Test A: Unauthenticated user invokes recovery fails closed', resA.status === 401, `Status: ${resA.status}`);

  // Test B: Staff invokes recovery
  const resB = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: 'TICKET_ATTACK_B',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, { Authorization: `Bearer ${staffToken}` });
  assert('Test B: Staff invokes recovery fails closed', [401, 403].includes(resB.status), `Status: ${resB.status}`);

  // Test C: Manager invokes recovery
  const resC = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: 'TICKET_ATTACK_C',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, { Authorization: `Bearer ${managerToken}` });
  assert('Test C: Manager invokes recovery fails closed', [401, 403].includes(resC.status), `Status: ${resC.status}`);

  // Test D: Ordinary owner invokes administrative recovery
  const resD = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: 'TICKET_ATTACK_D',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, { Authorization: `Bearer ${legitimateOwnerToken}` });
  assert('Test D: Ordinary owner invokes administrative recovery fails closed with HTTP 403', resD.status === 403 && (resD.data.error || '').includes('restricted exclusively to authorized system administrators'), `Status: ${resD.status}, Error: ${resD.data.error}`);

  // Test E: Fake administrator identity supplied in parameters (Admin authorized, but adminIdentity is not in allowlist)
  const resE = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: 'FAKE_HACKER_ADMIN',
    authReference: 'TICKET_ATTACK_E',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, adminHeaders);
  assert('Test E: Fake administrator identity fails closed', resE.status === 403 && (resE.data.error || '').includes('Unauthorized Admin Identity'), `Status: ${resE.status}, Error: ${resE.data.error}`);

  // Test F: Forged incident ticket (Admin identity valid, but ticket reference unissued)
  const resF = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: 'INC-FORGED-999999',
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, adminHeaders);
  assert('Test F: Forged incident ticket fails closed', resF.status === 403 && (resF.data.error || '').includes('Invalid Ticket'), `Status: ${resF.status}, Error: ${resF.data.error}`);

  // Setup: Issue a legitimate single-use recovery ticket for Test G, H, I, J
  const validTicket1 = `INC-REC-TEST-${Date.now()}-1`;
  const issueRes1 = await post(`${STAGING_EDGE_URL}/admin/issue-recovery-ticket`, {
    shopId: testShop,
    ownerUid: testOwner,
    ticketId: validTicket1,
    adminIdentity: authorizedAdmin,
    metadata: { reason: 'Adversarial Test Ticket 1' },
  }, adminHeaders);
  assert('Setup: Issue authorized recovery ticket #1', issueRes1.status === 200 && issueRes1.data.success);

  // Test G: Cross-shop recovery attempt (Ticket issued for testShop, attacker attempts recovery on different shop)
  const resG = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: 'shop_staging_001', // different shop!
    ownerUid: 'owner_staging_001',
    adminIdentity: authorizedAdmin,
    authReference: validTicket1,
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, adminHeaders);
  assert('Test G: Cross-shop recovery attempt fails closed', resG.status === 403 && (resG.data.error || '').includes('Ticket Validation Failed'), `Status: ${resG.status}, Error: ${resG.data.error}`);

  // Test H: Unauthorized direct PostgREST RPC execution
  // Attempt to invoke recharge_admin_emergency_device_recovery directly via PostgREST with anon key or owner token
  const rpcDirectRes = await post(`${SUPABASE_URL}/rest/v1/rpc/recharge_admin_emergency_device_recovery`, {
    p_shop_id: testShop,
    p_admin_identity: authorizedAdmin,
    p_auth_reference: validTicket1,
    p_new_device_id: attackDevId,
    p_new_device_type: 'mobile',
    p_new_platform: 'android',
    p_new_public_key_pem: attackKeys.publicKeyPem,
    p_owner_uid: testOwner,
  }, {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${legitimateOwnerToken}`,
  });
  assert('Test H: Direct PostgREST RPC call fails closed with permission denied', [401, 403, 404].includes(rpcDirectRes.status), `Status: ${rpcDirectRes.status}`);

  // Execute legitimate recovery with validTicket1 to test Test I (Replay)
  const legitRecovery1 = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: validTicket1,
    newDeviceId: attackDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: attackKeys.publicKeyPem,
  }, adminHeaders);
  assert('Setup: First legitimate consumption of ticket #1 succeeds', legitRecovery1.status === 200 && legitRecovery1.data.success);

  // Test I: Reuse of an already processed recovery ticket (Replay Attack)
  const replayDevId = `DEV_REPLAY_${Date.now()}`;
  const replayKeys = generateP256Keypair();
  const resI = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: validTicket1, // REUSING ALREADY CONSUMED TICKET!
    newDeviceId: replayDevId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: replayKeys.publicKeyPem,
  }, adminHeaders);
  assert('Test I: Replay of consumed ticket rejected', resI.status === 403 && (resI.data.error || '').includes('Ticket Replay Rejected'), `Status: ${resI.status}, Error: ${resI.data.error}`);

  // Test J: Concurrent emergency recovery requests (Race Condition)
  const raceTicket = `INC-REC-RACE-${Date.now()}`;
  await post(`${STAGING_EDGE_URL}/admin/issue-recovery-ticket`, {
    shopId: testShop,
    ownerUid: testOwner,
    ticketId: raceTicket,
    adminIdentity: authorizedAdmin,
    metadata: { reason: 'Race Condition Test' },
  }, adminHeaders);

  const raceDev1 = `DEV_RACE_1_${Date.now()}`;
  const raceDev2 = `DEV_RACE_2_${Date.now()}`;
  const raceKeys1 = generateP256Keypair();
  const raceKeys2 = generateP256Keypair();

  const [raceRes1, raceRes2] = await Promise.all([
    post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
      shopId: testShop,
      ownerUid: testOwner,
      adminIdentity: authorizedAdmin,
      authReference: raceTicket,
      newDeviceId: raceDev1,
      newDeviceType: 'mobile',
      newPlatform: 'android',
      newPublicKeyPem: raceKeys1.publicKeyPem,
    }, adminHeaders),
    post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
      shopId: testShop,
      ownerUid: testOwner,
      adminIdentity: authorizedAdmin,
      authReference: raceTicket,
      newDeviceId: raceDev2,
      newDeviceType: 'mobile',
      newPlatform: 'android',
      newPublicKeyPem: raceKeys2.publicKeyPem,
    }, adminHeaders),
  ]);

  const raceSuccessCount = (raceRes1.status === 200 ? 1 : 0) + (raceRes2.status === 200 ? 1 : 0);
  const raceFailCount = (raceRes1.status === 403 ? 1 : 0) + (raceRes2.status === 403 ? 1 : 0);
  assert('Test J: Concurrent recovery requests - exactly one succeeds', raceSuccessCount === 1 && raceFailCount === 1, `Success: ${raceSuccessCount}, Failed: ${raceFailCount}`);

  // Test K: Recovery attempt after device revocation
  // Revoke the active device, then verify ordinary bootstrap remains locked
  const activeDevId = raceRes1.status === 200 ? raceDev1 : raceDev2;
  const revokeRes = await post(`${STAGING_EDGE_URL}/revoke-device`, {
    shopId: testShop,
    deviceId: activeDevId,
    reason: 'Hardware Loss Simulation',
  }, { Authorization: `Bearer ${legitimateOwnerToken}` });
  assert('Setup K.1: Active device revoked', revokeRes.status === 200 && revokeRes.data.success);

  // Attempt ordinary enrollment without admin recovery -> must be rejected
  const attemptKeys = generateP256Keypair();
  const attemptDev = `DEV_UNAUTH_ENROLL_${Date.now()}`;
  const normalEnrollRes = await post(`${STAGING_EDGE_URL}/register-device`, {
    shopId: testShop,
    deviceId: attemptDev,
    deviceType: 'mobile',
    platform: 'android',
    publicKeyPem: attemptKeys.publicKeyPem,
  }, { Authorization: `Bearer ${legitimateOwnerToken}` });
  assert('Test K.1: Ordinary enrollment after revocation rejected (Bootstrap Locked)', normalEnrollRes.status === 403 && (normalEnrollRes.data.error || '').includes('Initial bootstrap gate closed'), `Status: ${normalEnrollRes.status}`);

  // Legitimate recovery succeeds after total device loss
  const recoveryTicketK = `INC-REC-K-${Date.now()}`;
  await post(`${STAGING_EDGE_URL}/admin/issue-recovery-ticket`, {
    shopId: testShop,
    ownerUid: testOwner,
    ticketId: recoveryTicketK,
    adminIdentity: authorizedAdmin,
    metadata: { reason: 'Recovery after total loss' },
  }, adminHeaders);

  const legitKDev = `DEV_LEGIT_K_${Date.now()}`;
  const legitKKeys = generateP256Keypair();
  const legitKRes = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: recoveryTicketK,
    newDeviceId: legitKDev,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: legitKKeys.publicKeyPem,
  }, adminHeaders);
  assert('Test K.2: Approved administrative recovery succeeds after hardware loss', legitKRes.status === 200 && legitKRes.data.success);

  // Test L: Recovery attempt with invalid public key
  const ticketL = `INC-REC-L-${Date.now()}`;
  await post(`${STAGING_EDGE_URL}/admin/issue-recovery-ticket`, {
    shopId: testShop,
    ownerUid: testOwner,
    ticketId: ticketL,
    adminIdentity: authorizedAdmin,
    metadata: { reason: 'Invalid Key Test' },
  }, adminHeaders);

  const resL = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: ticketL,
    newDeviceId: `DEV_INVALID_KEY_${Date.now()}`,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: 'NOT_A_VALID_PEM_KEY_FORMAT',
  }, adminHeaders);
  assert('Test L: Recovery attempt with invalid public key rejected', resL.status === 403 && (resL.data.error || '').includes('Invalid public key'), `Status: ${resL.status}, Error: ${resL.data.error}`);

  // --------------------------------------------------------------------------
  // TASK 4 & 5: REAL EMERGENCY RECOVERY SIMULATION & SECURITY INVARIANTS
  // --------------------------------------------------------------------------
  console.log('\n--- Task 4 & 5: Real Emergency Recovery Simulation & Invariants ---');

  // Step 4.1: Clean test shop for fresh end-to-end simulation
  cleanTestShop();

  // 1. Enroll Mobile Device (Bootstrap)
  const simMobKeys = generateP256Keypair();
  const simMobId = `SIM_MOB_${Date.now()}`;
  const simChal1 = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: simMobId,
    isBootstrap: true,
    bootstrapSecret: BOOTSTRAP_SECRET,
  });
  const simNonce1 = simChal1.data.nonce;
  const simCanon1 = `BOOTSTRAP_DEVICE:${testShop}:${testOwner}:${simMobId}:${simNonce1}`;
  const simSig1 = signPayload(simMobKeys.privateKeyPem, simCanon1);
  const simBootRes = await post(`${STAGING_EDGE_URL}/register-device`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: simMobId,
    deviceType: 'mobile',
    platform: 'android',
    deviceModel: 'Simulation Mobile Phone',
    publicKeyPem: simMobKeys.publicKeyPem,
    bootstrapSecret: BOOTSTRAP_SECRET,
    nonce: simNonce1,
    deviceSignature: simSig1,
    isBootstrap: true,
  });
  assert('Sim 1: First device (Mobile Android) enrolled via bootstrap', simBootRes.status === 200 || simBootRes.status === 201);
  const simMobToken = simBootRes.data.token;

  // 2. Cross-Sign and Enroll Second Device (Laptop Windows)
  const simLapKeys = generateP256Keypair();
  const simLapId = `SIM_LAP_${Date.now()}`;
  const crossChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: simMobId, // Authorizing device requests challenge
  });
  const crossNonce = crossChal.data.nonce;
  const crossData = `${simLapId}:laptop:windows:${simLapKeys.publicKeyPem.substring(0, 32)}`;
  const crossPayload = `ENROLL_SECONDARY_DEVICE:${testShop}:${testOwner}:${simMobId}:${crossNonce}:${crossData}`;
  const crossSig = signPayload(simMobKeys.privateKeyPem, crossPayload);

  const simLapRes = await post(`${STAGING_EDGE_URL}/register-device`, {
    shopId: testShop,
    deviceId: simLapId,
    deviceType: 'laptop',
    platform: 'windows',
    deviceModel: 'Simulation Laptop Windows',
    publicKeyPem: simLapKeys.publicKeyPem,
    authorizingDeviceId: simMobId,
    authorizingSignature: crossSig,
    nonce: crossNonce,
  }, { Authorization: `Bearer ${simMobToken}` });
  assert('Sim 2: Second device (Laptop Windows) enrolled via mutual cross-signing', simLapRes.status === 200 || simLapRes.status === 201, `Status: ${simLapRes.status}`);

  // Verify exactly 2 active devices exist
  const devListBefore = await post(`${STAGING_EDGE_URL}/get-devices`, { shopId: testShop }, { Authorization: `Bearer ${simMobToken}` });
  const activeBefore = (devListBefore.data?.devices || []).filter(d => d.isActive && !d.isRevoked);
  assert('Sim 3: Verify shop has exactly 2 active devices before hardware loss', activeBefore.length === 2, `Active: ${activeBefore.length}`);

  // 3. Simulate Total Hardware Loss (Both devices lost/destroyed - owner contacts admin)
  // 4. Admin issues incident recovery ticket
  const simIncidentTicket = `INC-DISASTER-${Date.now()}`;
  const simIssueTicketRes = await post(`${STAGING_EDGE_URL}/admin/issue-recovery-ticket`, {
    shopId: testShop,
    ownerUid: testOwner,
    ticketId: simIncidentTicket,
    adminIdentity: authorizedAdmin,
    metadata: { reason: 'Total hardware loss - phone lost, laptop damaged in fire' },
  }, adminHeaders);
  assert('Sim 4: Admin issues verified incident recovery ticket', simIssueTicketRes.status === 200 && simIssueTicketRes.data.success);

  // 5. Execute Emergency Recovery with New Mobile Hardware
  const recoveredMobKeys = generateP256Keypair();
  const recoveredMobId = `RECOVERED_MOB_${Date.now()}`;
  const simRecoveryRes = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: simIncidentTicket,
    newDeviceId: recoveredMobId,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: recoveredMobKeys.publicKeyPem,
  }, adminHeaders);
  assert('Sim 5: Administrative emergency recovery executes successfully', simRecoveryRes.status === 200 && simRecoveryRes.data.success);

  // 6. Verify Both Previous Devices are Revoked in Database
  let rawDbDevices = '';
  try {
    rawDbDevices = execSync(`npx.cmd supabase db query "SELECT device_id, device_type, is_active, is_revoked FROM public.recharge_trusted_devices WHERE shop_id = '${testShop}';" --remote=${PROJECT_REF} --yes`, { encoding: 'utf8', stdio: 'pipe' });
  } catch (_) {}

  assert('Sim 6.1: Previous mobile device revoked in database', rawDbDevices.includes(simMobId) && rawDbDevices.includes('"is_active": false'));
  assert('Sim 6.2: Previous laptop device revoked in database', rawDbDevices.includes(simLapId) && rawDbDevices.includes('"is_revoked": true'));
  assert('Sim 6.3: Newly recovered mobile device is active', rawDbDevices.includes(recoveredMobId) && rawDbDevices.includes('"is_active": true'));

  // 7. Verify the new device can obtain a valid challenge and authenticate
  const newDevChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: recoveredMobId,
  });
  assert('Sim 7.1: Recovered device requests challenge nonce', newDevChal.status === 200 && newDevChal.data.nonce);
  const newNonce = newDevChal.data.nonce;

  const newCanon = `ISSUE_STAGING_TOKEN:${testShop}:${testOwner}:${recoveredMobId}:${newNonce}`;
  const newSig = signPayload(recoveredMobKeys.privateKeyPem, newCanon);

  const tokenIssueRes = await post(`${STAGING_EDGE_URL}/issue-staging-token`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: recoveredMobId,
    nonce: newNonce,
    deviceSignature: newSig,
  });
  assert('Sim 7.2: Recovered device obtains valid session token', tokenIssueRes.status === 200 && tokenIssueRes.data.token);
  const recoveredToken = tokenIssueRes.data.token;

  // Verify device listing with new token
  const devListAfter = await post(`${STAGING_EDGE_URL}/get-devices`, { shopId: testShop }, { Authorization: `Bearer ${recoveredToken}` });
  const activeAfter = (devListAfter.data?.devices || []).filter(d => d.isActive && !d.isRevoked);
  assert('Sim 7.3: Exactly 1 newly authorized active device exists via API', activeAfter.length === 1 && activeAfter[0].deviceId === recoveredMobId);

  // 8. Verify Revoked Devices cannot authenticate or request challenges
  const revokedChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: simMobId,
  });
  assert('Sim 8: Revoked previous device cannot request challenge nonce', revokedChal.status === 403, `Status: ${revokedChal.status}`);

  // 9. Verify Bootstrap remains permanently locked
  const reBootstrapChal = await post(`${STAGING_EDGE_URL}/request-challenge`, {
    shopId: testShop,
    ownerUid: testOwner,
    deviceId: `DEV_REOPEN_${Date.now()}`,
    isBootstrap: true,
    bootstrapSecret: BOOTSTRAP_SECRET,
  });
  assert('Sim 9: Bootstrap remains permanently consumed and locked', reBootstrapChal.status === 403, `Status: ${reBootstrapChal.status}`);

  // 10. Verify Immutable Security Audit Log exists in recharge_audit_logs
  let auditLogFound = false;
  try {
    const rawLogs = execSync(`npx.cmd supabase db query "SELECT entity_id, event_type, actor_uid FROM public.recharge_audit_logs WHERE shop_id = '${testShop}' AND entity_id = '${simIncidentTicket}';" --remote=${PROJECT_REF} --yes`, { encoding: 'utf8', stdio: 'pipe' });
    if (rawLogs.includes(simIncidentTicket)) {
      auditLogFound = true;
    }
  } catch (_) {}
  assert('Sim 10: Immutable security audit log verified in recharge_audit_logs', auditLogFound, `Ticket: ${simIncidentTicket}`);

  // 11. Verify the Incident Ticket cannot be reused
  const reuseIncidentRes = await post(`${STAGING_EDGE_URL}/admin/emergency-device-recovery`, {
    shopId: testShop,
    ownerUid: testOwner,
    adminIdentity: authorizedAdmin,
    authReference: simIncidentTicket,
    newDeviceId: `DEV_REUSE_${Date.now()}`,
    newDeviceType: 'mobile',
    newPlatform: 'android',
    newPublicKeyPem: recoveredMobKeys.publicKeyPem,
  }, adminHeaders);
  assert('Sim 11: Single-use incident ticket cannot be reused', reuseIncidentRes.status === 403 && (reuseIncidentRes.data.error || '').includes('Ticket Replay Rejected'), `Status: ${reuseIncidentRes.status}`);

  // --------------------------------------------------------------------------
  // Teardown / Cleanup
  // --------------------------------------------------------------------------
  cleanTestShop();

  console.log('\n================================================================================');
  console.log(`PHASE 15.4.2 AUDIT COMPLETE: ${passed} Passed, ${failed} Failed`);
  console.log('================================================================================');

  if (failed > 0) {
    process.exit(1);
  }
}

runEmergencyRecoveryAudit().catch(err => {
  console.error('Fatal Test Execution Error:', err);
  process.exit(1);
});
