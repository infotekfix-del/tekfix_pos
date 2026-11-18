// Phase 6: who may do what in the Customer CRM. Pure Dart (unit-testable).
//
//   Staff / Biller : look up customers, see history, bill them, send ONE
//                    WhatsApp/call from the history screen, edit a customer.
//   Owner / Admin  : everything, incl. export, bulk send (campaigns),
//                    segments, templates, automations, migration, repair.

enum CrmAction {
  lookup,
  viewHistory,
  messageOne,
  editCustomer,
  export,
  bulkSend,
  editSegments,
  editTemplates,
  toggleAutomations,
  runMigration,
  rebuildIndexes,
}

const Set<CrmAction> kStaffCrmActions = {
  CrmAction.lookup,
  CrmAction.viewHistory,
  CrmAction.messageOne,
  CrmAction.editCustomer,
};

/// [manager] = owner or admin. Not signed in = nothing.
bool crmAllowed(CrmAction a, {required bool signedIn, required bool manager}) {
  if (!signedIn) return false;
  if (manager) return true;
  return kStaffCrmActions.contains(a);
}

/// Bilingual message for a blocked action.
const String kCrmDenied =
    'ഉടമ / അഡ്മിന് മാത്രം (Owner / Admin only)';
