import { readFileSync } from 'node:fs';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, setDoc, updateDoc, writeBatch, getDoc } from 'firebase/firestore';

const rules = readFileSync(process.argv[2], 'utf8');
const env = await initializeTestEnvironment({
  projectId: 'tekfix-rules-test',
  firestore: { rules, host: '127.0.0.1', port: 8085 },
});

await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, 'shops/S1'), { ownerUid: 'own', name: 'Shop' });
  await setDoc(doc(db, 'shops/S1/users/own'), { role: 'owner', active: true, approved: true });
  await setDoc(doc(db, 'shops/S1/users/st'), { role: 'staff', active: true, approved: true, name: 'Anu' });
  await setDoc(doc(db, 'shops/S2'), { ownerUid: 'own2', name: 'Shop 2' });
  await setDoc(doc(db, 'shops/S2/users/own2'), { role: 'owner', active: true, approved: true });

  await setDoc(doc(db, 'app_config/version'), { version: '1.0.0' });
  await setDoc(doc(db, 'app_config/admins'), { uids: ['adminUid'] });

  await setDoc(doc(db, 'purchase_bills/pb1'), { shopId: 'S1', total: 500 });
  await setDoc(doc(db, 'purchase_bills/pb_no_shop'), { total: 500 });
  await setDoc(doc(db, 'products/p1'), { shopId: 'S1', name: 'Screen' });
});

const as = (uid) => env.authenticatedContext(uid).firestore();
let pass = 0, fail = 0;
async function check(name, p) {
  try { await p; pass++; console.log('PASS', name); }
  catch (e) { fail++; console.log('FAIL', name, '-', e.message.split('\n')[0]); }
}

// 1. Stranger makes himself owner of an existing shop
await check('stranger cannot self-create owner in existing shop',
  assertFails(setDoc(doc(as('evil'), 'shops/S1/users/evil'), { role: 'owner', active: true, approved: true })));
await check('stranger cannot self-create staff in existing shop',
  assertFails(setDoc(doc(as('evil'), 'shops/S1/users/evil'), { role: 'staff', active: true, approved: true })));
// 2. Registration of a brand-new shop (same batch)
{
  const db = as('newOwner');
  const b = writeBatch(db);
  b.set(doc(db, 'shops/NEW'), { ownerUid: 'newOwner', createdAt: 1 });
  b.set(doc(db, 'shops/NEW/users/newOwner'), { role: 'owner', active: true, approved: true, name: 'N' });
  await check('new shop registration still works', assertSucceeds(b.commit()));
}
// 3. Shop document
await check('staff cannot take ownerUid',
  assertFails(updateDoc(doc(as('st'), 'shops/S1'), { ownerUid: 'st' })));
await check('staff cannot edit shop doc',
  assertFails(updateDoc(doc(as('st'), 'shops/S1'), { name: 'X' })));
await check('owner can edit shop doc',
  assertSucceeds(updateDoc(doc(as('own'), 'shops/S1'), { name: 'Shop 2' })));
await check('owner cannot move ownerUid from the client',
  assertFails(updateDoc(doc(as('own'), 'shops/S1'), { ownerUid: 'st' })));
// 4. Users records
await check('staff cannot raise own role',
  assertFails(updateDoc(doc(as('st'), 'shops/S1/users/st'), { role: 'owner' })));
await check('staff can edit own name',
  assertSucceeds(updateDoc(doc(as('st'), 'shops/S1/users/st'), { name: 'Anu K' })));
await check('staff cannot edit another user',
  assertFails(updateDoc(doc(as('st'), 'shops/S1/users/own'), { name: 'hacked' })));
await check('owner creates staff',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/users/st2'), { role: 'staff', active: true, approved: true })));
await check('owner deactivates staff',
  assertSucceeds(updateDoc(doc(as('own'), 'shops/S1/users/st'), { active: false, approved: false })));
await check('deactivated staff cannot re-approve self',
  assertFails(updateDoc(doc(as('st'), 'shops/S1/users/st'), { approved: true, active: true })));
await check('active staff cannot change own approval flag',
  assertFails(updateDoc(doc(as('st2'), 'shops/S1/users/st2'), { approved: false })));
await check('staff reads users list',
  assertSucceeds(getDoc(doc(as('st2'), 'shops/S1/users/own'))));

// 5. Catch-all must not override owner-only collections
await check('staff cannot write settings',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/settings/main'), { gstOn: false })));
await check('staff cannot write salary_payments',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/salary_payments/p1'), { amount: 99999 })));
await check('staff cannot write trusted_devices',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/trusted_devices/d1'), { pub: 'x' })));
await check('staff cannot read campaigns',
  assertFails(getDoc(doc(as('st2'), 'shops/S1/campaigns/c1'))));
await check('owner writes settings',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/settings/main'), { gstOn: true })));
// 6. Staff sync keeps working for allowed collections, owner-only push restricted
await check('deactivated staff loses access',
  assertFails(setDoc(doc(as('st'), 'shops/S1/sales/s9'), { total: 1 })));
await check('staff sync: sales',
  assertSucceeds(setDoc(doc(as('st2'), 'shops/S1/sales/s1'), { total: 100 })));
await check('staff cannot write staff box',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/staff/st2'), { name: 'Anu' })));
await check('owner writes staff box',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/staff/st2'), { name: 'Anu' })));
await check('staff cannot write message_templates',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/message_templates/t1'), { text: 'hi' })));
await check('owner writes message_templates',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/message_templates/t1'), { text: 'hi' })));
await check('staff cannot write crm_settings',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/crm_settings/s1'), { autoSend: true })));
await check('owner writes crm_settings',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/crm_settings/s1'), { autoSend: true })));
await check('staff cannot write campaigns',
  assertFails(setDoc(doc(as('st2'), 'shops/S1/campaigns/c1'), { title: 'Offer' })));
await check('owner writes campaigns',
  assertSucceeds(setDoc(doc(as('own'), 'shops/S1/campaigns/c1'), { title: 'Offer' })));
await check('staff sync: unknown collection (returns)',
  assertSucceeds(setDoc(doc(as('st2'), 'shops/S1/returns/r1'), { amount: 10 })));
await check('stranger cannot read shop sales',
  assertFails(getDoc(doc(as('evil'), 'shops/S1/sales/s1'))));

// 7. Global app_config
await check('signed-in user can read app_config/version',
  assertSucceeds(getDoc(doc(as('st2'), 'app_config/version'))));
await check('non-admin user cannot write app_config/version',
  assertFails(setDoc(doc(as('st2'), 'app_config/version'), { version: '2.0.0' })));
await check('admin user can write app_config/version',
  assertSucceeds(setDoc(doc(as('adminUid'), 'app_config/version'), { version: '2.0.0' })));

// 8. Root fallback collections (Restricted & Scoped)
await check('stranger cannot read root purchase_bills',
  assertFails(getDoc(doc(as('evil'), 'purchase_bills/pb1'))));
await check('stranger cannot write root purchase_bills',
  assertFails(setDoc(doc(as('evil'), 'purchase_bills/pb1'), { total: 100 })));
await check('stranger cannot write root products',
  assertFails(setDoc(doc(as('evil'), 'products/p1'), { name: 'Hacked' })));
await check('owner cannot write root purchase_bills',
  assertFails(setDoc(doc(as('own'), 'purchase_bills/pb1'), { total: 100 })));
await check('shop member can read root purchase_bills with their shopId',
  assertSucceeds(getDoc(doc(as('own'), 'purchase_bills/pb1'))));
await check('other shop member cannot read root purchase_bills of another shop',
  assertFails(getDoc(doc(as('own2'), 'purchase_bills/pb1'))));
await check('cannot read root purchase_bills without shopId',
  assertFails(getDoc(doc(as('own'), 'purchase_bills/pb_no_shop'))));

console.log(`\n${pass} passed, ${fail} failed`);
await env.cleanup();
process.exit(fail ? 1 : 0);
