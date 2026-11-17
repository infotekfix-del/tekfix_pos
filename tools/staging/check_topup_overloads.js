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

console.log('--- RECHARGE_PROCESS_TOPUP OVERLOADS ON STAGING ---');
console.log(query(`
  SELECT p.proname, pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as res
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'recharge_process_topup';
`));
