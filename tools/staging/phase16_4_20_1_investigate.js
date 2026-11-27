const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');

const STAGING_REF = 'mwhsvidbrfkryuiwhnev';
const PROJECT_ID = 'tekfix-staging';
const SHOP_ID = 'shop_staging_001';
const REPO_ROOT = 'd:\\tekfix_pos';

function getServiceAccountToken() {
  const configPath = 'C:\\Users\\acer\\.config\\configstore\\firebase-tools.json';
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  return config.tokens.access_token;
}

function makeRequest(urlStr, options = {}, body = null) {
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

function queryPostgres(sql) {
  const tempFile = path.join(REPO_ROOT, 'tools', 'staging', `_tmp_inv_${Date.now()}.sql`);
  fs.writeFileSync(tempFile, sql, 'utf8');
  try {
    const out = execSync(`npx.cmd supabase db query --remote=${STAGING_REF} --yes -f "${tempFile}"`, {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    });
    return JSON.parse(out.substring(out.indexOf('{')));
  } catch (err) {
    return { error: err.stdout || err.stderr || err.message };
  } finally {
    try { fs.unlinkSync(tempFile); } catch (_) {}
  }
}

async function runInvestigation() {
  console.log('=== PHASE 16.4.20.1 FINANCIAL INVESTIGATION & RECONCILIATION ===');
  console.log('Timestamp:', new Date().toISOString());
  console.log('Shop:', SHOP_ID);
  console.log('Project:', PROJECT_ID, '| Supabase:', STAGING_REF);

  const token = getServiceAccountToken();

  // 1. Firestore Bank Balance
  console.log('\n--- 1. FIRESTORE BANK BALANCE ---');
  const bankUrl = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/shops/${SHOP_ID}/bank/bank_balance`;
  const bankRes = await makeRequest(bankUrl, { headers: { Authorization: `Bearer ${token}` } });
  console.log('Bank Balance Doc Status:', bankRes.status);
  console.log('Bank Balance Doc Content:', JSON.stringify(bankRes.data, null, 2));

  // 2. Firestore Accounting Cash Bank Vouchers
  console.log('\n--- 2. FIRESTORE ACCOUNTING CASH BANK VOUCHERS ---');
  const vouchersUrl = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/shops/${SHOP_ID}/accounting_cash_bank`;
  const vouchersRes = await makeRequest(vouchersUrl, { headers: { Authorization: `Bearer ${token}` } });
  console.log('Vouchers Collection Status:', vouchersRes.status);
  if (vouchersRes.data?.documents) {
    console.log(`Found ${vouchersRes.data.documents.length} vouchers:`);
    for (const doc of vouchersRes.data.documents) {
      console.log('----------------------------------------------------');
      console.log('Name:', doc.name);
      console.log('Fields:', JSON.stringify(doc.fields, null, 2));
      console.log('Update Time:', doc.updateTime);
    }
  } else {
    console.log('No vouchers found or empty collection:', vouchersRes.data);
  }

  // 3. Supabase Recharge Wallets
  console.log('\n--- 3. SUPABASE RECHARGE WALLETS ---');
  const wallets = queryPostgres(`
    SELECT wallet_id, own_prepaid_balance_paise, distributor_credit_balance_paise, total_balance_paise, last_updated_at
    FROM public.recharge_wallets
    WHERE shop_id = '${SHOP_ID}'
    ORDER BY wallet_id;
  `);
  console.log('Wallets:', JSON.stringify(wallets, null, 2));

  // 4. Supabase Recharge Float Deposits
  console.log('\n--- 4. SUPABASE RECHARGE FLOAT DEPOSITS ---');
  const deposits = queryPostgres(`
    SELECT deposit_id, wallet_id, amount_paise, source, reference_no, deposited_by, device_id, created_at
    FROM public.recharge_float_deposits
    WHERE shop_id = '${SHOP_ID}'
    ORDER BY created_at ASC;
  `);
  console.log('Deposits:', JSON.stringify(deposits, null, 2));

  // 5. Supabase Recharge Wallet Logs
  console.log('\n--- 5. SUPABASE RECHARGE WALLET LOGS ---');
  const logs = queryPostgres(`
    SELECT log_id, wallet_id, entry_type, amount_paise, balance_before_paise, balance_after_paise, reference_no, created_at
    FROM public.recharge_wallet_logs
    WHERE shop_id = '${SHOP_ID}'
    ORDER BY created_at ASC;
  `);
  console.log('Wallet Logs:', JSON.stringify(logs, null, 2));

  // 6. Supabase Recharge Reversals
  console.log('\n--- 6. SUPABASE RECHARGE REVERSALS ---');
  const reversals = queryPostgres(`
    SELECT reversal_id, txn_key, wallet_id, amount_paise, reason, processed_by, created_at
    FROM public.recharge_reversals
    WHERE shop_id = '${SHOP_ID}'
    ORDER BY created_at ASC;
  `);
  console.log('Reversals:', JSON.stringify(reversals, null, 2));

  // 7. Supabase Challenges & Nonces
  console.log('\n--- 7. SUPABASE CHALLENGES ---');
  const challenges = queryPostgres(`
    SELECT nonce, device_id, owner_uid, consumed, expires_at, created_at
    FROM public.recharge_device_challenges
    WHERE shop_id = '${SHOP_ID}'
    ORDER BY created_at DESC
    LIMIT 10;
  `);
  console.log('Challenges (Last 10):', JSON.stringify(challenges, null, 2));

  // 8. Edge Function Deployment info
  console.log('\n--- 8. DEPLOYED EDGE FUNCTION STATUS ---');
  try {
    const fnList = execSync(`npx.cmd supabase functions list --remote=${STAGING_REF}`, {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    });
    console.log(fnList);
  } catch (err) {
    console.log('Functions list error:', err.stdout || err.stderr || err.message);
  }
}

runInvestigation().catch(console.error);
