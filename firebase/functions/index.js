const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { FieldValue } = require("@google-cloud/firestore");

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

/**
 * Region Configuration for Cloud Functions (Phase 13.0.8):
 *
 * - Staging ('tekfix-staging'): Explicitly pins all Cloud Functions to 'asia-south1' (Mumbai).
 * - Production ('tekfix-45b38'): Preserves existing legacy default 'us-central1' (Iowa).
 *
 * Security & Isolation Rules:
 * 1. Resolved exclusively from trusted server-level environment variables:
 *    - FUNCTION_REGION or FIREBASE_FUNCTIONS_REGION (deployment/process environment)
 *    - GCLOUD_PROJECT / FIREBASE_CONFIG.projectId (injected by Google Cloud / Firebase)
 * 2. Never accepts or derives region from runtime client/user payload data.
 */
function resolveFunctionsRegion() {
  const explicitRegion = process.env.FUNCTION_REGION || process.env.FIREBASE_FUNCTIONS_REGION;
  if (explicitRegion) {
    return explicitRegion.trim().toLowerCase();
  }

  let projectId = process.env.GCLOUD_PROJECT || "";
  if (!projectId && process.env.FIREBASE_CONFIG) {
    try {
      const parsed = typeof process.env.FIREBASE_CONFIG === "string"
        ? JSON.parse(process.env.FIREBASE_CONFIG)
        : process.env.FIREBASE_CONFIG;
      projectId = parsed.projectId || "";
    } catch (_) {}
  }

  projectId = projectId.trim().toLowerCase();
  if (projectId === "tekfix-staging" || projectId.includes("staging")) {
    return "asia-south1";
  }

  // Production (tekfix-45b38) or default preserves legacy us-central1
  return "us-central1";
}

const FUNCTIONS_REGION = resolveFunctionsRegion();
const regionalFunctions = functions.region(FUNCTIONS_REGION);

// Exported for internal verification test suites
exports._resolveFunctionsRegion = resolveFunctionsRegion;

/**
 * Trigger: On Staff Check-in
 * Sends an FCM push notification to the shop owner alerting them of the check-in.
 */
exports.onStaffCheckIn = regionalFunctions.firestore
  .document("shops/{shopId}/attendance/{attendanceId}")
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const { shopId } = context.params;
    const staffName = data.staffName || "Staff Member";
    const isLate = data.isLate === true;
    const checkInTime = data.checkIn ? new Date(data.checkIn.toDate()).toLocaleTimeString("en-IN", { timeZone: "Asia/Kolkata" }) : "";

    try {
      // Find shop owner's FCM tokens
      const usersSnap = await db
        .collection("shops")
        .doc(shopId)
        .collection("users")
        .where("role", "==", "owner")
        .where("active", "==", true)
        .get();

      const tokens = [];
      usersSnap.forEach((doc) => {
        const u = doc.data();
        if (u.fcmToken) {
          tokens.push(u.fcmToken);
        }
        if (Array.isArray(u.fcmTokens)) {
          tokens.push(...u.fcmTokens);
        }
      });

      if (tokens.length === 0) {
        console.log(`No owner FCM tokens found for shop ${shopId}`);
        return null;
      }

      const title = isLate ? `⚠️ Late Check-In: ${staffName}` : `✅ Staff Check-In: ${staffName}`;
      const body = `${staffName} clocked in at ${checkInTime}.${isLate ? " (Late Arrival)" : ""} Tap to review and approve.`;

      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          click_action: "FLUTTER_NOTIFICATION_CLICK",
          shopId: shopId,
          type: "ATTENDANCE_CHECKIN",
          attendanceId: context.params.attendanceId,
        },
      };

      const response = await admin.messaging().sendToDevice(tokens, payload);
      console.log(`Successfully sent check-in notification:`, response);
      return response;
    } catch (err) {
      console.error("Error sending check-in push notification:", err);
      return null;
    }
  });

/**
 * Scheduled Cron: Auto-close Forgotten Check-outs at 23:45 IST
 * Marks unclosed shifts as "Needs review" with calculated worked hours.
 */
exports.autoCloseForgottenCheckouts = regionalFunctions.pubsub
  .schedule("45 23 * * *")
  .timeZone("Asia/Kolkata")
  .onRun(async (context) => {
    const today = new Date();
    const yyyy = today.getFullYear();
    const mm = String(today.getMonth() + 1).padStart(2, "0");
    const dd = String(today.getDate()).padStart(2, "0");
    const todayStr = `${yyyy}${mm}${dd}`;

    console.log(`Running auto-close for unclosed checkouts on ${todayStr}`);

    const shopsSnap = await db.collection("shops").get();

    for (const shopDoc of shopsSnap.docs) {
      const shopId = shopDoc.id;
      const attRef = db.collection("shops").doc(shopId).collection("attendance");

      const unclosedSnap = await attRef
        .where("date", "==", todayStr)
        .where("checkOut", "==", null)
        .get();

      if (unclosedSnap.empty) continue;

      const batch = db.batch();

      unclosedSnap.forEach((doc) => {
        const data = doc.data();
        const checkIn = data.checkIn ? data.checkIn.toDate() : null;
        let workedHours = 0;
        if (checkIn) {
          workedHours = Math.max(0, (today.getTime() - checkIn.getTime()) / (1000 * 3600));
        }

        batch.update(doc.ref, {
          checkOut: admin.firestore.FieldValue.serverTimestamp(),
          status: "Needs review",
          dutyStage: "Needs review",
          workedHours: parseFloat(workedHours.toFixed(2)),
          autoClosed: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      await batch.commit();
      console.log(`Auto-closed ${unclosedSnap.size} attendance documents for shop ${shopId}`);
    }

    return null;
  });

/**
 * Helper: Asia/Kolkata Business Date (yyyy-MM-dd) with optional day offset
 */
function getAsiaKolkataDateString(offsetDays = 0) {
  const d = new Date();
  if (offsetDays !== 0) {
    d.setDate(d.getDate() + offsetDays);
  }
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Kolkata",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return formatter.format(d);
}

/**
 * Helper: Validates strict YYYY-MM-DD calendar date
 */
function isValidDateFormat(dateStr) {
  if (typeof dateStr !== "string") return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) return false;
  const parts = dateStr.split("-").map(Number);
  const year = parts[0];
  const month = parts[1];
  const day = parts[2];
  if (year < 2020 || year > 2050 || month < 1 || month > 12 || day < 1 || day > 31) return false;
  const d = new Date(Date.UTC(year, month - 1, day));
  return d.getUTCFullYear() === year && d.getUTCMonth() === month - 1 && d.getUTCDate() === day;
}

/**
 * Helper: Verify Staff, Admin & Owner Membership & Permissions in Requested Shop
 * Strictly validates against live Firestore documents (Zero-Trust Live Lookup).
 */
async function verifyShopMembership(dbInstance, shopId, uid) {
  if (!uid || !shopId || typeof shopId !== "string" || shopId.trim() === "") {
    return false;
  }

  // 1. Authoritative shop existence check
  const shopDoc = await dbInstance.collection("shops").doc(shopId).get();
  if (!shopDoc.exists) {
    return false;
  }

  const sData = shopDoc.data() || {};
  if (sData.active === false) {
    return false; // Inactive or suspended shop
  }
  if (sData.isMaintenanceMode === true) {
    return false; // Shop is under maintenance
  }

  // 2. Authoritative live user document lookup in shops/{shopId}/users/{uid}
  const userDoc = await dbInstance
    .collection("shops")
    .doc(shopId)
    .collection("users")
    .doc(uid)
    .get();

  if (!userDoc.exists) {
    return false; // Deleted, revoked, or non-existent account
  }

  const uData = userDoc.data() || {};

  // Verify active and approved status (applies to owner, admin, and staff)
  if (uData.active === false || uData.approved === false) {
    return false;
  }

  const role = uData.role;

  // Phase 13.3.0 OWNER-ONLY RECHARGE POLICY:
  // Recharge Accounting is Owner-only. Verify ownerUid and authenticated UID.
  // Reject staff accounts from all recharge operations.
  // Verify direct shop ownership or authoritative owner role:
  const isDirectOwner = (sData.ownerUid && sData.ownerUid === uid);
  const isOwnerRole = (role === "owner");

  if (isDirectOwner || isOwnerRole) {
    // Explicit recharge permission check if defined
    if (uData.canRecharge === false) {
      return false;
    }
    return true;
  }

  // Reject all staff and non-owner accounts from recharge operations
  return false;
}

/**
 * Callable Function: processRechargeDebit
 * Production-grade trusted server-side wallet debit operation.
 */
exports.processRechargeDebit = regionalFunctions.https.onCall(async (data, context) => {
  // 1. Verify authenticated user
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Authentication required: Caller is not an authenticated Firebase user."
    );
  }

  const callerUid = context.auth.uid;
  const callerEmail = context.auth.token ? context.auth.token.email : "";
  const callerName = (context.auth.token && context.auth.token.name) || callerEmail || callerUid;

  const {
    shopId,
    walletId,
    rechargeId,
    idempotencyKey,
    operator,
    amountPaise,
    fundingType,
    businessDate: clientBusinessDate,
    rechargeData,
    deviceId,
    deviceSignature,
    nonce,
  } = data || {};

  // 2. Validate required arguments presence
  if (!shopId || typeof shopId !== "string" || shopId.trim() === "") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invalid argument: shopId is required."
    );
  }

  const txnKey = idempotencyKey || rechargeId;
  if (!txnKey || typeof txnKey !== "string" || txnKey.trim() === "") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invalid argument: rechargeId / idempotencyKey is required."
    );
  }

  if (!operator || typeof operator !== "string") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invalid argument: operator is required."
    );
  }

  const operatorLower = operator.toLowerCase().trim();
  const validOperators = ["jio", "airtel", "vi", "bsnl"];
  if (!validOperators.includes(operatorLower)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Invalid operator: ${operator}. Must be one of: jio, airtel, vi, bsnl.`
    );
  }

  // Validate amount using positive safe integer in paise
  if (
    typeof amountPaise !== "number" ||
    !Number.isSafeInteger(amountPaise) ||
    amountPaise <= 0
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Invalid amount: ${amountPaise}. Must be a strictly positive safe integer in paise.`
    );
  }

  // Validate fundingType
  const validFundingTypes = ["ownMoney", "distributorCredit"];
  if (fundingType !== undefined && fundingType !== null && !validFundingTypes.includes(fundingType)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Invalid fundingType: "${fundingType}". Must be one of: "ownMoney", "distributorCredit".`
    );
  }
  const funding = fundingType === "distributorCredit" ? "distributorCredit" : "ownMoney";
  const isOwnMoney = funding === "ownMoney";

  // Validate wallet ID (format: WALLET_<OPERATOR> or wallet_<operator>)
  const expectedWalletIdUpper = `WALLET_${operatorLower.toUpperCase()}`;
  const targetWalletId = walletId || expectedWalletIdUpper;

  // 3. Strict business date validation in Asia/Kolkata
  const todayAsiaKolkata = getAsiaKolkataDateString(0);
  const yesterdayAsiaKolkata = getAsiaKolkataDateString(-1);

  let businessDate = todayAsiaKolkata;
  if (clientBusinessDate !== undefined && clientBusinessDate !== null && clientBusinessDate !== "") {
    if (!isValidDateFormat(clientBusinessDate)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        `Invalid businessDate format: "${clientBusinessDate}". Expected YYYY-MM-DD.`
      );
    }
    // Only current business date or yesterday's business date (for offline sync) are permitted
    if (clientBusinessDate > todayAsiaKolkata) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Future businessDate "${clientBusinessDate}" is rejected. Server Asia/Kolkata date is ${todayAsiaKolkata}.`
      );
    }
    if (clientBusinessDate < yesterdayAsiaKolkata) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Expired businessDate "${clientBusinessDate}" is rejected. Only current date (${todayAsiaKolkata}) or yesterday (${yesterdayAsiaKolkata}) are allowed.`
      );
    }
    businessDate = clientBusinessDate;
  }

  // 4. Firestore Document References for Atomic Financial Transaction
  const shopRef = db.collection("shops").doc(shopId);
  const membershipRef = db.collection("shops").doc(shopId).collection("users").doc(callerUid);
  const reconRef = db.collection("shops").doc(shopId).collection("recharge_daily_reconciliation").doc(businessDate);
  const walletRef = db.collection("shops").doc(shopId).collection("recharge_wallets").doc(targetWalletId);
  const txnRef = db.collection("shops").doc(shopId).collection("recharge_transactions").doc(txnKey);
  const logRef = db.collection("shops").doc(shopId).collection("recharge_wallet_logs").doc(`TXN_${txnKey}`);

  try {
    const txResult = await db.runTransaction(async (transaction) => {
      // --- READ PHASE: All authoritative reads strictly precede any writes ---
      // 1. Read shop document
      const shopSnap = await transaction.get(shopRef);

      // 2. Read caller membership document
      const userSnap = await transaction.get(membershipRef);

      // 3. Read daily reconciliation document
      const reconSnap = await transaction.get(reconRef);

      // 4. Read existing recharge transaction document (for idempotency check)
      const existingTxnSnap = await transaction.get(txnRef);

      // 5. Read target operator wallet document
      const walletSnap = await transaction.get(walletRef);

      // --- VALIDATION PHASE ---
      // Validate shop existence and active status
      if (!shopSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          `Shop not found: ${shopId}`
        );
      }
      const sData = shopSnap.data() || {};
      if (sData.active === false) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Shop ${shopId} is inactive or suspended.`
        );
      }
      // Phase 1: Maintenance Mode Check (Atomic & Race-Condition Free)
      if (sData.isMaintenanceMode === true) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Shop is currently under maintenance. Recharge transactions are suspended."
        );
      }

      // Validate caller membership, approval, active status, and recharge permissions (Atomic & Race-Condition Free)
      if (!userSnap.exists) {
        throw new functions.https.HttpsError(
          "permission-denied",
          `Permission denied: User ${callerUid} is not an authorized staff or owner member of shop ${shopId}.`
        );
      }
      const uData = userSnap.data() || {};
      if (uData.active === false || uData.approved === false) {
        throw new functions.https.HttpsError(
          "permission-denied",
          `Permission denied: User ${callerUid} is not an authorized staff or owner member of shop ${shopId}.`
        );
      }

      const role = uData.role;
      let isAuthorized = false;
      // Phase 13.3.3 Owner-Only Recharge Policy: Reject all non-owner roles
      if (sData.ownerUid === callerUid || role === "owner") {
        if (uData.canRecharge === false) {
          throw new functions.https.HttpsError(
            "permission-denied",
            `Permission denied: User ${callerUid} does not have recharge permissions.`
          );
        }
        isAuthorized = true;
      }
      if (!isAuthorized) {
        throw new functions.https.HttpsError(
          "permission-denied",
          `Permission denied: User ${callerUid} is not the verified shop owner. Staff accounts are strictly forbidden from recharge operations.`
        );
      }

      // -------------------------------------------------------------
      // Phase 13.3.5 Hardened: Mandatory Trusted Device Authorization (CRIT-13-01)
      // -------------------------------------------------------------
      if (!deviceId || typeof deviceId !== "string" || deviceId.trim() === "") {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Trusted Device Required: Every recharge debit must originate from an authorized owner mobile or laptop (deviceId is missing or empty)."
        );
      }

      const deviceRef = db
        .collection("shops")
        .doc(shopId)
        .collection("trusted_devices")
        .doc(deviceId);
      const deviceSnap = await transaction.get(deviceRef);

      if (!deviceSnap.exists) {
        throw new functions.https.HttpsError(
          "permission-denied",
          `Trusted Device Error: Device ${deviceId} is not registered for shop ${shopId}.`
        );
      }

      const devData = deviceSnap.data() || {};
      if (devData.isActive !== true || devData.isRevoked === true) {
        throw new functions.https.HttpsError(
          "permission-denied",
          `Trusted Device Error: Device ${deviceId} has been revoked or is inactive.`
        );
      }

      if (devData.ownerUid !== callerUid) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Trusted Device Error: Device ownership mismatch with caller UID."
        );
      }

      // Cryptographic Signature & Challenge Nonce Verification (HIGH-13-02)
      if (nonce || deviceSignature) {
        if (!nonce || !deviceSignature) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Trusted Device Error: Both challenge nonce and deviceSignature must be provided."
          );
        }

        const nonceRef = db
          .collection("shops")
          .doc(shopId)
          .collection("device_challenges")
          .doc(nonce);
        const nonceSnap = await transaction.get(nonceRef);

        if (!nonceSnap.exists) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Trusted Device Error: Challenge nonce is invalid or already consumed (Replay blocked)."
          );
        }

        const nData = nonceSnap.data() || {};
        const nowMs = Date.now();
        const expiresAtMs = nData.expiresAt ? nData.expiresAt.toMillis() : 0;

        if (nowMs > expiresAtMs) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Trusted Device Error: Challenge nonce has expired. Re-authentication required."
          );
        }

        if (nData.deviceId !== deviceId || nData.ownerUid !== callerUid) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Trusted Device Error: Challenge nonce does not match current device and owner context."
          );
        }

        // Asymmetric ECDSA P-256 verification (HIGH-13-02)
        const canonicalPayload = `${shopId}:${callerUid}:${deviceId}:${nonce}`;
        const publicKeyPem = devData.publicKeyPem;

        if (!publicKeyPem) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Trusted Device Error: Missing registered public key for device."
          );
        }

        try {
          const verifier = crypto.createVerify("SHA256");
          verifier.update(canonicalPayload);
          const isSignatureValid = verifier.verify(publicKeyPem, deviceSignature, "hex");

          if (!isSignatureValid) {
            throw new functions.https.HttpsError(
              "permission-denied",
              "Trusted Device Error: Cryptographic signature verification failed. Invalid key or altered payload."
            );
          }
        } catch (sigErr) {
          if (sigErr instanceof functions.https.HttpsError) throw sigErr;
          throw new functions.https.HttpsError(
            "permission-denied",
            `Trusted Device Error: Signature validation failed: ${sigErr.message}`
          );
        }

        // Consume nonce atomically to prevent replay attacks
        transaction.delete(nonceRef);
      }

      // Update lastVerifiedAt on trusted device
      transaction.update(deviceRef, {
        lastVerifiedAt: FieldValue.serverTimestamp(),
        lastActiveAt: FieldValue.serverTimestamp(),
      });

      // Validate daily morning opening balance
      if (!reconSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Daily morning opening balance has not been recorded for date ${businessDate}. Please complete morning opening balance before processing recharges.`
        );
      }
      const reconData = reconSnap.data() || {};
      if (reconData.shopId && reconData.shopId !== shopId) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Reconciliation record belongs to another shop."
        );
      }
      if (reconData.openingStatus !== "completed") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Morning opening balance is not completed (current status: ${reconData.openingStatus || "pending"}).`
        );
      }
      const opRecon = reconData.operators && reconData.operators[operatorLower];
      if (!opRecon || opRecon.isOpeningCompleted !== true) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Morning opening balance is incomplete for operator: ${operatorLower}.`
        );
      }

      // Validate idempotency & reversed transaction replay
      if (existingTxnSnap.exists) {
        const existingTxn = existingTxnSnap.data() || {};
        if (existingTxn.walletDebited === true) {
          // Strict Idempotency Consistency: Missing required stored fields must fail closed
          if (
            !existingTxn.shopId ||
            !existingTxn.walletId ||
            existingTxn.amountPaise === undefined ||
            !existingTxn.operator ||
            !existingTxn.fundingType
          ) {
            throw new functions.https.HttpsError(
              "already-exists",
              `Corrupted or incomplete existing transaction document for rechargeId ${txnKey}. Replay rejected.`
            );
          }

          // Strict field comparisons without unsafe fallback expressions
          const isSameShop = existingTxn.shopId === shopId;
          const isSameWallet = existingTxn.walletId === targetWalletId;
          const isSameAmount = existingTxn.amountPaise === amountPaise;
          const isSameOperator = (existingTxn.operator || "").toLowerCase() === operatorLower;
          const isSameFunding = existingTxn.fundingType === funding;
          const existingDate = existingTxn.dateString || existingTxn.businessDate;
          const isSameDate = !businessDate || existingDate === businessDate;

          if (!isSameShop || !isSameWallet || !isSameAmount || !isSameOperator || !isSameFunding || !isSameDate) {
            throw new functions.https.HttpsError(
              "already-exists",
              `Idempotency violation: rechargeId ${txnKey} was already processed with different parameters. ` +
              `Original: [Shop: ${existingTxn.shopId}, Wallet: ${existingTxn.walletId}, Operator: ${existingTxn.operator}, Amount: ${existingTxn.amountPaise} paise, Funding: ${existingTxn.fundingType}, Date: ${existingDate}], ` +
              `Attempted: [Shop: ${shopId}, Wallet: ${targetWalletId}, Operator: ${operatorLower}, Amount: ${amountPaise} paise, Funding: ${funding}, Date: ${businessDate}].`
            );
          }

          // Phase 4: Reversed Transaction Replay Check
          if (
            existingTxn.status === "reversed" ||
            existingTxn.reversed === true ||
            existingTxn.isReversed === true
          ) {
            throw new functions.https.HttpsError(
              "failed-precondition",
              `Transaction ${txnKey} was already reversed. Replay rejected.`
            );
          }

          // Safe identical idempotent replay: return existing state without duplicate debit or log
          const wData = walletSnap.exists ? walletSnap.data() || {} : {};
          const liveOwn = Number.isSafeInteger(wData.ownPrepaidBalancePaise) ? wData.ownPrepaidBalancePaise : 0;
          const liveDist = Number.isSafeInteger(wData.distributorCreditBalancePaise) ? wData.distributorCreditBalancePaise : 0;
          return {
            success: true,
            idempotentReplay: true,
            rechargeId: txnKey,
            walletId: targetWalletId,
            operator: operatorLower,
            amountPaise: amountPaise,
            balanceBeforePaise: isOwnMoney ? liveOwn : liveDist,
            balanceAfterPaise: isOwnMoney ? liveOwn : liveDist,
            totalBalancePaise: liveOwn + liveDist,
            businessDate: existingDate || businessDate,
            message: "Recharge debit already processed idempotently.",
          };
        }
      }

      // Validate operator wallet document
      if (!walletSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          `Operator wallet not initialized: ${targetWalletId}`
        );
      }

      const walletData = walletSnap.data() || {};
      const liveOwn = walletData.ownPrepaidBalancePaise;
      const liveDist = walletData.distributorCreditBalancePaise;

      if (
        !Number.isSafeInteger(liveOwn) || liveOwn < 0 ||
        !Number.isSafeInteger(liveDist) || liveDist < 0
      ) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Corrupted wallet balances for wallet ${targetWalletId}. Balances must be non-negative safe integers in paise.`
        );
      }

      const currentBalancePaise = isOwnMoney ? liveOwn : liveDist;

      // Verify sufficient balance
      if (currentBalancePaise < amountPaise) {
        const availRs = (currentBalancePaise / 100).toFixed(2);
        const reqRs = (amountPaise / 100).toFixed(2);
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Insufficient wallet balance: Available ₹${availRs}, Required ₹${reqRs}.`
        );
      }

      // Compute updated balances
      const newBalancePaise = currentBalancePaise - amountPaise;
      if (!Number.isSafeInteger(newBalancePaise) || newBalancePaise < 0) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Calculated wallet balance is invalid or negative."
        );
      }

      const updatedOwn = isOwnMoney ? newBalancePaise : liveOwn;
      const updatedDist = isOwnMoney ? liveDist : newBalancePaise;
      const updatedTotal = updatedOwn + updatedDist;

      if (!Number.isSafeInteger(updatedTotal) || updatedTotal < 0) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Total wallet balance overflow or invalid calculation."
        );
      }

      // Update wallet atomically
      transaction.set(
        walletRef,
        {
          walletId: targetWalletId,
          shopId: shopId,
          operator: operatorLower,
          ownPrepaidBalancePaise: updatedOwn,
          distributorCreditBalancePaise: updatedDist,
          totalBalancePaise: updatedTotal,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // Create or update recharge transaction document with all mandatory immutable fields
      const txnRecord = {
        rechargeId: txnKey,
        shopId: shopId,
        walletId: targetWalletId,
        operator: operatorLower,
        amount: amountPaise / 100,
        amountPaise: amountPaise,
        fundingType: funding,
        walletDebited: true,
        staffId: callerUid,
        staffName: callerName,
        status: "pending",
        businessDate: businessDate,
        dateString: businessDate,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };

      if (rechargeData && typeof rechargeData === "object") {
        Object.assign(txnRecord, rechargeData, {
          rechargeId: txnKey,
          shopId: shopId,
          walletId: targetWalletId,
          operator: operatorLower,
          walletDebited: true,
          amountPaise: amountPaise,
          fundingType: funding,
          businessDate: businessDate,
          dateString: businessDate,
        });
      }
      transaction.set(txnRef, txnRecord, { merge: true });

      // Create immutable wallet ledger log
      transaction.set(logRef, {
        txnId: `TXN_${txnKey}`,
        shopId: shopId,
        walletId: targetWalletId,
        operator: operatorLower,
        fundingType: funding,
        entryType: "RECHARGE_DEBIT",
        amount: amountPaise / 100,
        amountPaise: amountPaise,
        balanceBeforePaise: currentBalancePaise,
        balanceAfterPaise: newBalancePaise,
        referenceId: txnKey,
        description: `Recharge ${operatorLower.toUpperCase()} - Debit ₹${(amountPaise / 100).toFixed(2)}`,
        staffId: callerUid,
        staffName: callerName,
        timestamp: FieldValue.serverTimestamp(),
        businessDate: businessDate,
      });

      return {
        success: true,
        idempotentReplay: false,
        rechargeId: txnKey,
        walletId: targetWalletId,
        operator: operatorLower,
        amountPaise: amountPaise,
        balanceBeforePaise: currentBalancePaise,
        balanceAfterPaise: newBalancePaise,
        totalBalancePaise: updatedTotal,
        businessDate: businessDate,
      };
    });

    return txResult;
  } catch (err) {
    if (err instanceof functions.https.HttpsError) {
      throw err;
    }
    console.error(`[processRechargeDebit] Transaction error for ${txnKey}:`, err);
    throw new functions.https.HttpsError("internal", err.message || "Financial transaction failed.");
  }
});

// ============================================================================
// PHASE 13.3.3: OWNER TRUSTED DEVICE MANAGEMENT FUNCTIONS
// ============================================================================

/**
 * Callable: registerTrustedDevice
 * Enrolls an owner's trusted mobile or laptop. Enforces maximum 2 active devices.
 */
exports.registerTrustedDevice = regionalFunctions.https.onCall(async (data, context) => {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Authentication required: Caller is not authenticated.");
  }

  const callerUid = context.auth.uid;
  const { shopId, deviceId, deviceType, platform, deviceModel, publicKeyPem } = data || {};

  if (!shopId || !deviceId || !deviceType || !publicKeyPem) {
    throw new functions.https.HttpsError("invalid-argument", "Missing mandatory device registration parameters.");
  }

  if (!["mobile", "laptop"].includes(deviceType)) {
    throw new functions.https.HttpsError("invalid-argument", "Invalid deviceType. Must be 'mobile' or 'laptop'.");
  }

  // 1. Verify caller is authoritative shop owner
  const shopDoc = await db.collection("shops").doc(shopId).get();
  if (!shopDoc.exists) {
    throw new functions.https.HttpsError("not-found", `Shop ${shopId} does not exist.`);
  }

  const sData = shopDoc.data() || {};
  if (sData.ownerUid !== callerUid) {
    throw new functions.https.HttpsError("permission-denied", "Unauthorized: Only the shop owner can register trusted devices.");
  }

  const trustedRef = db.collection("shops").doc(shopId).collection("trusted_devices");

  // 2. Transaction: Enforce maximum 2 devices & one per category (mobile / laptop)
  return await db.runTransaction(async (transaction) => {
    const activeSnap = await transaction.get(
      trustedRef.where("isActive", "==", true).where("isRevoked", "==", false)
    );

    // If device is already registered and active, update lastVerifiedAt
    const targetDocRef = trustedRef.doc(deviceId);
    const existingTargetSnap = await transaction.get(targetDocRef);

    if (existingTargetSnap.exists) {
      const exData = existingTargetSnap.data() || {};
      if (exData.isActive && !exData.isRevoked) {
        transaction.update(targetDocRef, {
          lastVerifiedAt: FieldValue.serverTimestamp(),
          deviceModel: deviceModel || exData.deviceModel,
        });
        return { success: true, message: `Device ${deviceId} is already active.` };
      }
    }

    if (activeSnap.size >= 2) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Device quota exceeded: Maximum 2 active devices allowed (1 mobile + 1 laptop). Revoke an existing device first."
      );
    }

    const sameTypeExisting = activeSnap.docs.find((d) => d.data().deviceType === deviceType && d.id !== deviceId);
    if (sameTypeExisting) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `A trusted ${deviceType} is already registered (${sameTypeExisting.data().deviceModel || sameTypeExisting.id}). Revoke or replace it first.`
      );
    }

    transaction.set(targetDocRef, {
      deviceId,
      ownerUid: callerUid,
      deviceType,
      platform: platform || "unknown",
      deviceModel: deviceModel || "Unknown Device",
      publicKeyPem,
      isActive: true,
      isRevoked: false,
      createdAt: FieldValue.serverTimestamp(),
      lastVerifiedAt: FieldValue.serverTimestamp(),
    });

    return {
      success: true,
      message: `Trusted ${deviceType} (${deviceId}) registered successfully.`,
      deviceId,
    };
  });
});

/**
 * Callable: requestDeviceChallenge
 * Issues a short-lived cryptographic challenge nonce (valid for 300 seconds).
 */
exports.requestDeviceChallenge = regionalFunctions.https.onCall(async (data, context) => {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Authentication required.");
  }

  const callerUid = context.auth.uid;
  const { shopId, deviceId } = data || {};

  if (!shopId || !deviceId) {
    throw new functions.https.HttpsError("invalid-argument", "shopId and deviceId are required.");
  }

  // Verify device is registered and active
  const deviceSnap = await db.collection("shops").doc(shopId).collection("trusted_devices").doc(deviceId).get();
  if (!deviceSnap.exists || !deviceSnap.data().isActive || deviceSnap.data().isRevoked) {
    throw new functions.https.HttpsError("permission-denied", "Device is not registered or has been revoked.");
  }

  const devData = deviceSnap.data() || {};
  if (devData.ownerUid !== callerUid) {
    throw new functions.https.HttpsError("permission-denied", "Device owner mismatch.");
  }

  const nonce = `NONCE_${Date.now()}_${crypto.randomBytes(16).toString("hex")}`;
  const expiresAtMs = Date.now() + 300 * 1000; // 5 minutes TTL

  await db.collection("shops").doc(shopId).collection("device_challenges").doc(nonce).set({
    nonce,
    shopId,
    deviceId,
    ownerUid: callerUid,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: admin.firestore.Timestamp.fromMillis(expiresAtMs),
  });

  return {
    success: true,
    nonce,
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
});

/**
 * Callable: revokeTrustedDevice
 * Revokes an existing trusted device. Owner only.
 */
exports.revokeTrustedDevice = regionalFunctions.https.onCall(async (data, context) => {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Authentication required.");
  }

  const callerUid = context.auth.uid;
  const { shopId, deviceId, reason } = data || {};

  if (!shopId || !deviceId) {
    throw new functions.https.HttpsError("invalid-argument", "shopId and deviceId are required.");
  }

  const shopDoc = await db.collection("shops").doc(shopId).get();
  if (!shopDoc.exists || shopDoc.data().ownerUid !== callerUid) {
    throw new functions.https.HttpsError("permission-denied", "Unauthorized: Only shop owner can revoke devices.");
  }

  const targetDocRef = db.collection("shops").doc(shopId).collection("trusted_devices").doc(deviceId);
  const snap = await targetDocRef.get();

  if (!snap.exists) {
    throw new functions.https.HttpsError("not-found", `Device ${deviceId} not found.`);
  }

  await targetDocRef.update({
    isActive: false,
    isRevoked: true,
    revokedAt: FieldValue.serverTimestamp(),
    revokedBy: callerUid,
    revocationReason: reason || "Revoked by owner",
  });

  return { success: true, message: `Device ${deviceId} revoked successfully.` };
});

