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
    return out;
  } catch (err) {
    return (err.stdout ? err.stdout.toString() : '') + (err.stderr ? err.stderr.toString() : '') + err.message;
  } finally {
    try { fs.unlinkSync(tempFile); } catch (_) {}
  }
}

console.log('--- WALLETS FOR SHOP TEKFIX ---');
console.log(query("SELECT shop_id, wallet_id, operator, own_prepaid_balance_paise, distributor_credit_balance_paise, total_balance_paise, last_updated_at FROM public.recharge_wallets WHERE shop_id = 'tekfix' ORDER BY wallet_id;"));

console.log('--- ALL WALLETS WITH TOTAL_BALANCE > 0 ON STAGING ---');
console.log(query("SELECT shop_id, wallet_id, own_prepaid_balance_paise, distributor_credit_balance_paise, total_balance_paise, last_updated_at FROM public.recharge_wallets WHERE total_balance_paise > 0;"));

console.log('--- DEPOSITS FOR SHOP TEKFIX ---');
console.log(query("SELECT deposit_id, shop_id, wallet_id, amount_paise, source, reference_id, created_at FROM public.recharge_deposits WHERE shop_id = 'tekfix' ORDER BY created_at DESC LIMIT 10;"));

console.log('--- RECENT 10 DEPOSITS ON STAGING ---');
console.log(query("SELECT deposit_id, shop_id, wallet_id, amount_paise, reference_id, created_at FROM public.recharge_deposits ORDER BY created_at DESC LIMIT 10;"));
