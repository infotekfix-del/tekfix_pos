const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

/**
 * Trigger: On New Order Created
 * Sends push notifications to all active Administrators.
 */
exports.onOrderCreated = functions.firestore
  .document("orders/{orderId}")
  .onCreate(async (snap, context) => {
    const order = snap.data();
    const orderId = context.params.orderId;
    const staffName = order.staffName || "Staff Member";
    const totalTypes = order.totalTypes || 0;
    const totalQuantity = order.totalQuantity || 0;

    try {
      // Find all admin tokens
      const adminUsers = await db.collection("users")
        .where("role", "==", "admin")
        .where("active", "==", true)
        .get();

      const tokens = [];
      adminUsers.forEach((doc) => {
        const u = doc.data();
        if (u.fcmToken) tokens.push(u.fcmToken);
        if (Array.isArray(u.fcmTokens)) tokens.push(...u.fcmTokens);
      });

      if (tokens.length === 0) {
        console.log("No admin FCM tokens found for order notification.");
        return null;
      }

      const payload = {
        notification: {
          title: `📦 New Order: ${orderId}`,
          body: `${staffName} created an order with ${totalTypes} types (${totalQuantity} items). Tap to review.`,
        },
        data: {
          click_action: "FLUTTER_NOTIFICATION_CLICK",
          type: "NEW_ORDER",
          orderId: orderId,
        },
      };

      const res = await admin.messaging().sendToDevice(tokens, payload);
      console.log(`Sent new order push notification for ${orderId}:`, res);
      return res;
    } catch (err) {
      console.error("Error sending order push notification:", err);
      return null;
    }
  });

/**
 * Trigger: On Order Status Updated
 * Notifies the staff member when their order status is updated by the Admin.
 */
exports.onOrderStatusUpdated = functions.firestore
  .document("orders/{orderId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    if (before.status === after.status) return null;

    const orderId = context.params.orderId;
    const staffId = after.staffId;
    const newStatus = after.status;

    try {
      const userDoc = await db.collection("users").doc(staffId).get();
      if (!userDoc.exists) return null;

      const user = userDoc.data();
      const token = user.fcmToken;
      if (!token) return null;

      const payload = {
        notification: {
          title: `Order Update: ${orderId}`,
          body: `Your order status has been updated to "${newStatus}".`,
        },
        data: {
          type: "ORDER_STATUS_UPDATE",
          orderId: orderId,
          newStatus: newStatus,
        },
      };

      const res = await admin.messaging().sendToDevice(token, payload);
      console.log(`Sent order status update notification to staff ${staffId}:`, res);
      return res;
    } catch (err) {
      console.error("Error sending status notification to staff:", err);
      return null;
    }
  });
