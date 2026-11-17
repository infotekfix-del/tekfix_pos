const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const STAGING_REF = 'mwhsvidbrfkryuiwhnev';
const REPO_ROOT = path.resolve(__dirname, '../..');

const sql = `
  SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args,
         p.prosecdef as is_security_definer,
         array_to_string(p.proacl, ', ') as grants
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'recharge_process_topup';

  SELECT indexname, indexdef 
  FROM pg_indexes 
  WHERE tablename = 'recharge_float_deposits';

  SELECT tgname, pg_get_triggerdef(oid)
  FROM pg_trigger
  WHERE tgrelid = 'public.recharge_float_deposits'::regclass;
`;

const temp = path.join(REPO_ROOT, 'tools/staging/_tmp_audit_pg.sql');
fs.writeFileSync(temp, sql, 'utf8');
try {
  const out = execSync(`npx.cmd supabase db query --remote=${STAGING_REF} --yes -f "${temp}"`, { cwd: REPO_ROOT, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
  console.log(out);
} finally {
  try { fs.unlinkSync(temp); } catch (_) {}
}
