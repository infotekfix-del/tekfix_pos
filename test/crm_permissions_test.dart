// Phase 6: CRM role matrix.

import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/crm/crm_permissions.dart';

void main() {
  test('staff/biller: lookup + history + single message only', () {
    bool staff(CrmAction a) => crmAllowed(a, signedIn: true, manager: false);
    expect(staff(CrmAction.lookup), isTrue);
    expect(staff(CrmAction.viewHistory), isTrue);
    expect(staff(CrmAction.messageOne), isTrue);
    expect(staff(CrmAction.editCustomer), isTrue);
    for (final a in [
      CrmAction.export,
      CrmAction.bulkSend,
      CrmAction.editSegments,
      CrmAction.editTemplates,
      CrmAction.toggleAutomations,
      CrmAction.runMigration,
      CrmAction.rebuildIndexes,
    ]) {
      expect(staff(a), isFalse, reason: '$a');
    }
  });

  test('owner/admin: everything', () {
    for (final a in CrmAction.values) {
      expect(crmAllowed(a, signedIn: true, manager: true), isTrue);
    }
  });

  test('signed out: nothing', () {
    for (final a in CrmAction.values) {
      expect(crmAllowed(a, signedIn: false, manager: true), isFalse);
      expect(crmAllowed(a, signedIn: false, manager: false), isFalse);
    }
  });
}
