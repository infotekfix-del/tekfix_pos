// Single balance per operator: each recharge picks the pocket that can pay.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_dialog.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';

void main() {
  test('own money first, then distributor credit, else null', () {
    expect(autoFundingPocket(ownPaise: 50000, creditPaise: 0, amountPaise: 34900),
        RechargeFundingType.ownMoney);
    expect(autoFundingPocket(ownPaise: 32900, creditPaise: 100000, amountPaise: 34900),
        RechargeFundingType.distributorCredit);
    expect(autoFundingPocket(ownPaise: 32900, creditPaise: 0, amountPaise: 34900), isNull);
    expect(autoFundingPocket(ownPaise: 20000, creditPaise: 20000, amountPaise: 34900), isNull);
    expect(autoFundingPocket(ownPaise: 34900, creditPaise: 0, amountPaise: 34900),
        RechargeFundingType.ownMoney);
  });
}
