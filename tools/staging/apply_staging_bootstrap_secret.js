// Safe script to apply the already‑generated bootstrap secret to Supabase
// No new secret is generated; the secret is read from staging.local.json
// The Supabase CLI requires explicit consent (--yes) when mutating a secret.
// All output is suppressed to avoid leaking the secret value.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const CONFIG_FILE = path.resolve(__dirname, 'staging.local.json');
const STAGING_PROJECT_REF = 'mwhsvidbrfkryuiwhnev';
const NPX_CMD = process.platform === 'win32' ? 'npx.cmd' : 'npx';

function main() {
  if (!fs.existsSync(CONFIG_FILE)) {
    console.error('[ERROR] staging.local.json not found');
    process.exit(1);
  }
  const cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  const secret = cfg.bootstrapSecret;
  if (!secret) {
    console.error('[ERROR] bootstrapSecret missing in staging.local.json');
    process.exit(1);
  }
  // Deploy the secret to Supabase with explicit consent
  const cmd = `${NPX_CMD} supabase secrets set STAGING_BOOTSTRAP_SECRET=\"${secret}\" --project-ref ${STAGING_PROJECT_REF} --yes`;
  try {
    // Suppress stdout/stderr to keep the secret out of logs
    execSync(cmd, { stdio: 'ignore', env: process.env });
    console.log('=== Remote bootstrap secret applied successfully ===');
  } catch (err) {
    console.error('[ERROR] Failed to set remote secret:', err.message);
    process.exit(1);
  }
}

main();

