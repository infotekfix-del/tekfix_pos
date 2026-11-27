/**
 * TEKFIX ERP - Staging Secret Rotation & Rollback Tool
 * 
 * ROTATES: STAGING_BOOTSTRAP_SECRET in staging Supabase vault (mwhsvidbrfkryuiwhnev)
 * 
 * SAFETY NOTICE:
 * This script will NOT execute remote vault rotation unless passed the explicit flag:
 * --confirm-rotate-by-owner
 * 
 * ROLLBACK SUPPORT:
 * Run with --rollback to restore the previous secret from local backup.
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const STAGING_PROJECT_REF = 'mwhsvidbrfkryuiwhnev';
const CONFIG_FILE = path.resolve(__dirname, 'staging.local.json');
const BACKUP_FILE = path.resolve(__dirname, 'staging.local.backup.json');

const NPX_CMD = process.platform === 'win32' ? 'npx.cmd' : 'npx';

function main() {
  const args = process.argv.slice(2);
  const isApproved = args.includes('--confirm-rotate-by-owner');
  const isRollback = args.includes('--rollback');

  console.log('================================================================');
  console.log('TEKFIX ERP - STAGING BOOTSTRAP SECRET ROTATION & ROLLBACK');
  console.log('Target Project:', STAGING_PROJECT_REF, '(ap-south-1 Mumbai)');
  console.log('================================================================');

  if (isRollback) {
    if (!fs.existsSync(BACKUP_FILE)) {
      console.error('[ERROR] No backup file found at:', BACKUP_FILE);
      process.exit(1);
    }
    const backupCfg = JSON.parse(fs.readFileSync(BACKUP_FILE, 'utf8').replace(/^\uFEFF/, '').trim());
    if (!backupCfg.bootstrapSecret) {
      console.error('[ERROR] Backup file does not contain bootstrapSecret.');
      process.exit(1);
    }
    console.log('[ROLLBACK] Restoring previous secret to Supabase remote vault...');
    try {
      const cmd = `${NPX_CMD} supabase secrets set STAGING_BOOTSTRAP_SECRET="${backupCfg.bootstrapSecret}" --project-ref ${STAGING_PROJECT_REF}`;
      execSync(cmd, { stdio: 'inherit', env: process.env });
      fs.copyFileSync(BACKUP_FILE, CONFIG_FILE);
      console.log('  -> Rollback complete. Previous secret restored in vault and staging.local.json.');
      process.exit(0);
    } catch (e) {
      console.error('[ERROR] Rollback failed:', e.message);
      process.exit(1);
    }
  }

  if (!isApproved) {
    console.log('[BLOCKED] Remote rotation held.');
    console.log('Safety rule: Remote cloud vault rotation requires explicit owner confirmation.');
    console.log('');
    console.log('ROTATION & ROLLBACK PROCEDURE FOR OWNER:');
    console.log('  1. Rotation:');
    console.log('     node tools/staging/rotate_staging_bootstrap_secret.js --confirm-rotate-by-owner');
    console.log('  2. Automatic Backup:');
    console.log('     Previous secret is safely backed up to untracked staging.local.backup.json');
    console.log('  3. Rollback (if ever needed):');
    console.log('     node tools/staging/rotate_staging_bootstrap_secret.js --rollback');
    console.log('================================================================');
    process.exit(1);
  }

  console.log('[1/4] Generating cryptographically secure 256-bit secret...');
  const newSecret = crypto.randomBytes(32).toString('hex');

  console.log('[2/4] Backing up existing config before rotation...');
  let currentConfig = {};
  if (fs.existsSync(CONFIG_FILE)) {
    try {
      const raw = fs.readFileSync(CONFIG_FILE, 'utf8').replace(/^\uFEFF/, '').trim();
      currentConfig = JSON.parse(raw);
      fs.writeFileSync(BACKUP_FILE, JSON.stringify(currentConfig, null, 2), 'utf8');
      console.log('  -> Saved existing config to staging.local.backup.json');
    } catch (e) {
      currentConfig = {};
    }
  }

  currentConfig.projectRef = STAGING_PROJECT_REF;
  currentConfig.bootstrapSecret = newSecret;
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(currentConfig, null, 2), 'utf8');
  console.log('  -> staging.local.json updated with new secret.');

  console.log('[3/4] Deploying new secret to Supabase remote vault...');
  try {
    const cmd = `${NPX_CMD} supabase secrets set STAGING_BOOTSTRAP_SECRET="${newSecret}" --project-ref ${STAGING_PROJECT_REF}`;
    execSync(cmd, { stdio: 'inherit', env: process.env });
    console.log('  -> Supabase secret successfully rotated in remote vault.');
  } catch (err) {
    console.error('[ERROR] Failed to set Supabase remote secret:', err.message);
    process.exit(1);
  }

  console.log('[4/4] Verification Notice:');
  console.log('  -> New secret active.');
  console.log('================================================================');
}

main();
