const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

/**
 * Trigger: On Staff Check-in
 * Sends an FCM push notification to the shop owner alerting them of the check-in.
 */
exports.onStaffCheckIn = functions.firestore
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
exports.autoCloseForgottenCheckouts = functions.pubsub
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
