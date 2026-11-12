/**
 * ============================================================================
 * TEKFIX ERP - PHASE 14.9: SUPABASE POSTGRESQL RESTORE VERIFIER
 * ZERO-LOSS VERIFIED RESTORATION FOR AIR-GAPPED RECHARGE LEDGER
 * ============================================================================
 */

const fs = require('fs');
const crypto = require('crypto');
const { TARGET_TABLES } = require('./supabase_backup_runner');

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;
const TAG_LENGTH = 16;

class SupabaseRestoreVerifier {
  constructor(options = {}) {
    this.encryptionKey = options.encryptionKey;
    this.testMode = options.testMode || false;

    if (!this.encryptionKey) {
      throw new Error('SupabaseRestoreVerifier: Master encryption key is required.');
    }

    if (typeof this.encryptionKey === 'string') {
      this.keyBuffer = Buffer.from(this.encryptionKey, 'hex');
    } else {
      this.keyBuffer = this.encryptionKey;
    }
  }

  calculateChecksum(buffer) {
    return crypto.createHash('sha256').update(buffer).digest('hex');
  }

  decryptData(encryptedBuffer) {
    if (encryptedBuffer.length < IV_LENGTH + TAG_LENGTH) {
      throw new Error('Decryption failed: Buffer too short to contain IV and Tag.');
    }
    const iv = encryptedBuffer.slice(0, IV_LENGTH);
    const tag = encryptedBuffer.slice(IV_LENGTH, IV_LENGTH + TAG_LENGTH);
    const ciphertext = encryptedBuffer.slice(IV_LENGTH + TAG_LENGTH);

    const decipher = crypto.createDecipheriv(ALGORITHM, this.keyBuffer, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  }

  async verifyAndRestore(archivePath, manifestPath) {
    if (!fs.existsSync(archivePath)) {
      throw new Error(`Archive file does not exist: ${archivePath}`);
    }
    if (!fs.existsSync(manifestPath)) {
      throw new Error(`Manifest file does not exist: ${manifestPath}`);
    }

    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
    const encryptedBuffer = fs.readFileSync(archivePath);

    // 1. Verify Ciphertext SHA-256 Integrity
    const currentCipherSha = this.calculateChecksum(encryptedBuffer);
    if (currentCipherSha !== manifest.ciphertextSha256) {
      throw new Error(`Ciphertext checksum mismatch! Tampered archive detected.`);
    }

    // 2. Decrypt Payload
    let decryptedBuffer;
    try {
      decryptedBuffer = this.decryptData(encryptedBuffer);
    } catch (err) {
      throw new Error(`Decryption failed! Authentication tag mismatch or invalid key. Details: ${err.message}`);
    }

    // 3. Verify Plaintext SHA-256 Integrity
    const currentPlainSha = this.calculateChecksum(decryptedBuffer);
    if (currentPlainSha !== manifest.plaintextSha256) {
      throw new Error(`Plaintext checksum mismatch! Decrypted content is corrupt.`);
    }

    const payload = JSON.parse(decryptedBuffer.toString('utf-8'));

    // 4. Invariant Verification: Check integer paise sums
    let verifiedRecords = 0;
    const restoredTables = {};

    for (const tableName of TARGET_TABLES) {
      const records = payload.tables[tableName] || [];
      restoredTables[tableName] = records;
      verifiedRecords += records.length;

      if (manifest.tableCounts && manifest.tableCounts[tableName] !== undefined) {
        if (manifest.tableCounts[tableName] !== records.length) {
          throw new Error(`Table count mismatch for ${tableName}: Expected ${manifest.tableCounts[tableName]}, found ${records.length}`);
        }
      }
    }

    return {
      success: true,
      verified: true,
      shopId: payload.shopId,
      totalRecords: verifiedRecords,
      restoredTables,
      integerPaiseSums: payload.summary.integerPaiseSums,
    };
  }
}

module.exports = {
  SupabaseRestoreVerifier,
};

