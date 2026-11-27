// ============================================================================
// TEKFIX ERP - PHASE 15.2.2: PRODUCTION AUTHORIZATION HARDENING AUDIT SUITE
// Tests all 10+ production Firestore authorization conditions & fail-closed logic
// Replicates the exact verifyShopOwner logic from recharge-bridge/index.ts
// ============================================================================

const assert = require('assert');

// Pure isolated implementation of production verifyShopOwner for automated unit testing
async function verifyProductionShopOwner({
  shopId,
  callerUid,
  tokenRole,
  rawToken = 'valid_token',
  firebaseProjectId = 'tekfix-45b38',
  mockFetch,
}) {
  // STRICT OWNER ROLE VALIDATION: If token carries a role claim, it MUST be strictly "owner"
  if (tokenRole && tokenRole.toLowerCase() !== "owner") {
    return false;
  }

  if (!firebaseProjectId) {
    return false;
  }

  // Condition 1: Fetch and verify Shop document
  const firestoreShopUrl = `https://firestore.googleapis.com/v1/projects/${firebaseProjectId}/databases/(default)/documents/shops/${shopId}`;
  const shopResponse = await mockFetch(firestoreShopUrl, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!shopResponse.ok) {
    return false;
  }

  const shopDoc = await shopResponse.json();
  const shopOwnerUid = shopDoc.fields?.ownerUid?.stringValue;

  // STRICT REQUIREMENT: shops/{shopId}.ownerUid MUST explicitly match callerUid
  if (!shopOwnerUid || shopOwnerUid !== callerUid) {
    return false;
  }

  // Condition 2: Fetch and verify live User document under shops/{shopId}/users/{callerUid}
  const userUrl = `${firestoreShopUrl}/users/${callerUid}`;
  const userRes = await mockFetch(userUrl, {
    headers: { Authorization: `Bearer ${rawToken}` },
  });

  if (!userRes.ok) {
    return false;
  }

  const userDoc = await userRes.json();
  if (!userDoc || !userDoc.fields) {
    return false;
  }

  // Condition 3: User role must strictly equal "owner"
  const userRole = userDoc.fields?.role?.stringValue?.toLowerCase();
  if (userRole !== "owner") {
    return false;
  }

  // Condition 4 & 5: active and approved must EXPLICITLY be true
  const isActive = userDoc.fields?.active?.booleanValue === true;
  const isApproved = userDoc.fields?.approved?.booleanValue === true;

  if (!isActive || !isApproved) {
    return false;
  }

  // Condition 6: If token carries role claim, it must match Firestore role ("owner")
  if (tokenRole && tokenRole.toLowerCase() !== userRole) {
    return false;
  }

  return true;
}

async function runProductionAuthSuite() {
  console.log('🧪 Starting Phase 15.2.2 Production Authorization Hardening Suite...\n');

  let passed = 0;
  let failed = 0;

  function test(num, description, condition) {
    if (condition) {
      console.log(`  ✅ [Auth Vector ${num}] PASS: ${description}`);
      passed++;
    } else {
      console.error(`  ❌ [Auth Vector ${num}] FAIL: ${description}`);
      failed++;
    }
  }

  const validCaller = 'owner_uid_123';
  const testShop = 'shop_test_100';

  // 1. Valid owner with active=true and approved=true
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      if (url.endsWith(`/users/${validCaller}`)) {
        return {
          ok: true,
          json: async () => ({
            fields: {
              role: { stringValue: 'owner' },
              active: { booleanValue: true },
              approved: { booleanValue: true },
            },
          }),
        };
      }
      return { ok: false, status: 404 };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      tokenRole: 'owner',
      mockFetch,
    });
    test(1, 'Valid owner with active=true, approved=true, and tokenRole=owner is AUTHORIZED', res === true);
  }

  // 2. ownerUid matches but user document is missing (404)
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return { ok: false, status: 404 }; // User doc missing
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(2, 'ownerUid matches in shop doc but user document is missing fails closed', res === false);
  }

  // 3. ownerUid matches but user role is admin
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'admin' },
            active: { booleanValue: true },
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(3, 'ownerUid matches but user role is admin is strictly DENIED (Admin rejected)', res === false);
  }

  // 4. ownerUid matches but active=false
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            active: { booleanValue: false },
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(4, 'ownerUid matches but active=false fails closed', res === false);
  }

  // 5. ownerUid matches but approved=false
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            active: { booleanValue: true },
            approved: { booleanValue: false },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(5, 'ownerUid matches but approved=false fails closed', res === false);
  }

  // 6. ownerUid mismatch (shop doc ownerUid !== callerUid)
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: 'different_owner_uid' } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            active: { booleanValue: true },
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(6, 'ownerUid mismatch in shop document fails closed immediately', res === false);
  }

  // 7. Deleted/revoked owner (shop fetch fails 404 or 500)
  {
    const mockFetch = async () => ({ ok: false, status: 404 });
    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(7, 'Deleted or revoked shop document (HTTP 404) fails closed', res === false);
  }

  // 8. Missing role in user document
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            active: { booleanValue: true },
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(8, 'Missing role in user document fails closed', res === false);
  }

  // 9. Every non-owner role (manager, cashier, staff, viewer)
  {
    const nonOwnerRoles = ['manager', 'cashier', 'staff', 'viewer', 'accountant', 'guest'];
    let allDenied = true;
    for (const r of nonOwnerRoles) {
      const mockFetch = async (url) => {
        if (url.endsWith(`/shops/${testShop}`)) {
          return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
        }
        return {
          ok: true,
          json: async () => ({
            fields: {
              role: { stringValue: r },
              active: { booleanValue: true },
              approved: { booleanValue: true },
            },
          }),
        };
      };

      const res = await verifyProductionShopOwner({
        shopId: testShop,
        callerUid: validCaller,
        mockFetch,
      });
      if (res !== false) {
        allDenied = false;
        break;
      }
    }
    test(9, 'Every non-owner role (manager, cashier, staff, viewer, etc.) is strictly DENIED', allDenied);
  }

  // 10. Token role and Firestore role mismatch
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            active: { booleanValue: true },
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      tokenRole: 'cashier', // Mismatch!
      mockFetch,
    });
    test(10, 'Token role and Firestore role mismatch fails closed immediately', res === false);
  }

  // 11. Missing active field (does not silently default to true)
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            // active field completely missing!
            approved: { booleanValue: true },
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(11, 'Missing active field in user document fails closed (does not default to true)', res === false);
  }

  // 12. Missing approved field (does not silently default to true)
  {
    const mockFetch = async (url) => {
      if (url.endsWith(`/shops/${testShop}`)) {
        return { ok: true, json: async () => ({ fields: { ownerUid: { stringValue: validCaller } } }) };
      }
      return {
        ok: true,
        json: async () => ({
          fields: {
            role: { stringValue: 'owner' },
            active: { booleanValue: true },
            // approved field completely missing!
          },
        }),
      };
    };

    const res = await verifyProductionShopOwner({
      shopId: testShop,
      callerUid: validCaller,
      mockFetch,
    });
    test(12, 'Missing approved field in user document fails closed (does not default to true)', res === false);
  }

  console.log('\n==================================================');
  console.log(`Production Auth Hardening Suite: ${passed} Passed, ${failed} Failed`);
  console.log('==================================================\n');

  if (failed > 0) {
    process.exit(1);
  }
}

runProductionAuthSuite().catch(err => {
  console.error('Test execution failed:', err);
  process.exit(1);
});

