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

console.log('--- RECENT DEPOSITS IN recharge_float_deposits ---');
console.log(query("SELECT deposit_id, shop_id, wallet_id, amount_paise, source, reference_no, normalized_ref, device_id, created_at FROM public.recharge_float_deposits ORDER BY created_at DESC LIMIT 15;"));

console.log('--- DEPOSITS FOR SHOP tekfix ---');
console.log(query("SELECT deposit_id, shop_id, wallet_id, amount_paise, source, reference_no, normalized_ref, created_at FROM public.recharge_float_deposits WHERE shop_id = 'tekfix' ORDER BY created_at DESC;"));
