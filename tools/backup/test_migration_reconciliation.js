/**
 * ============================================================================
 * TEKFIX ERP - PHASE 14.9.2: AIR-GAPPED RECHARGE MIGRATION TEST RUNNER
 * VERIFIES ETL FIDELITY ACROSS ALL 14 PERSISTENT ENTITIES
 * ============================================================================
 */

const { RechargeMigrationTool } = require('./recharge_migration_tool');

async function testMigration() {
  console.log('🧪 Starting Phase 14.9.2 Complete 14-Entity Migration & Reconciliation Test...\n');

  const mockFirestoreSource = {
    recharge_wallets: {
      WALLET_AIRTEL: { operator: 'airtel', ownPrepaidBalancePaise: 45000, distributorCreditBalancePaise: 15000, updatedAt: '2026-11-09T10:00:00Z' },
      WALLET_JIO: { operator: 'jio', ownPrepaidBalancePaise: 92000, distributorCreditBalancePaise: 0, updatedAt: '2026-11-09T10:00:00Z' },
    },
    recharge_transactions: {
      TXN_101: { walletId: 'WALLET_AIRTEL', amountPaise: 29900, fundingType: 'ownPrepaid', operator: 'airtel', status: 'completed' },
      TXN_102: { walletId: 'WALLET_JIO', amountPaise: 66600, fundingType: 'ownPrepaid', operator: 'jio', status: 'completed' },
    },
    recharge_wallet_logs: {
      LOG_01: { walletId: 'WALLET_AIRTEL', txnKey: 'TXN_101', entryType: 'debit', amountPaise: 29900, balanceBeforePaise: 74900, balanceAfterPaise: 45000 },
    },
    recharge_distributors: {
      DIST_01: { name: 'Airtel Calicut', phone: '9847012345', creditLimitPaise: 100000, outstandingBalancePaise: 15000 },
    },
    recharge_distributor_ledger: {
      DLE_01: { distributorId: 'DIST_01', walletId: 'WALLET_AIRTEL', amountPaise: 15000, entryType: 'credit_extended' },
    },
    recharge_float_deposits: {
      DEP_01: { walletId: 'WALLET_AIRTEL', amountPaise: 50000, source: 'bank' },
    },
    recharge_commissions: {
      COMM_01: { txnKey: 'TXN_101', operator: 'airtel', rechargeAmountPaise: 29900, commissionPaise: 897 },
    },
    recharge_refunds: {
      REF_01: { txnKey: 'TXN_OLD', customerPhone: '9847000000', amountPaise: 14900, refundMode: 'cash', reason: 'Failed' },
    },
    recharge_reversals: {
      REV_01: { txnKey: 'TXN_REV', walletId: 'WALLET_AIRTEL', amountPaise: 40000, commissionClawbackPaise: 1200 },
    },
    daily_recharge_collections: {
      '2026-11-09': { totalSalesCount: 2, totalSalesPaise: 96500, cashCollectedPaise: 96500 },
    },
    recharge_daily_reconciliation: {
      REC_01: { businessDate: '2026-11-09', calculatedBalancePaise: 152000, actualPhysicalBalancePaise: 152000, discrepancyPaise: 0 },
    },
    reconciliation_corrections: {
      CORR_01: { reconId: 'REC_01', correctionAmountPaise: 0, reason: 'Matched' },
    },
    recharge_trusted_devices: {
      DEV_ANDROID: { ownerUid: 'UID_OWNER', deviceType: 'mobile', platform: 'android', isActive: true },
    },
    recharge_audit_logs: {
      AUDIT_01: { eventType: 'debit', actorUid: 'UID_OWNER', entityId: 'TXN_101' },
    },
  };

  const tool = new RechargeMigrationTool({ shopId: 'shop_test_149' });
  const transformed = tool.transformRecords(mockFirestoreSource);
  const recon = tool.generateReconciliationReport(mockFirestoreSource, transformed);

  console.log('Reconciliation Report:');
  console.log(JSON.stringify(recon, null, 2));

  let passed = true;
  for (const [entity, count] of Object.entries(recon.entityCounts)) {
    if (count === 0) {
      console.error(`❌ FAIL: Entity ${entity} has 0 records! Mapping failed.`);
      passed = false;
    }
  }

  if (recon.verdict === 'RECONCILIATION_PASS' && passed) {
    console.log('\n✅ PASS: Complete 14-Entity Integer Paise Reconciliation Verified with 0 Discrepancy!');
    process.exit(0);
  } else {
    console.error('\n❌ FAIL: Discrepancy or missing entity detected during migration!');
    process.exit(1);
  }
}

testMigration();
