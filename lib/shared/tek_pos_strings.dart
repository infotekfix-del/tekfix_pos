/// Centralized bilingual (Malayalam + English) string constants for TekFix POS & Attendance.
class TekStrings {
  TekStrings._();

  // App & Shop
  static const appTitle = 'TEKFIX ERP & POS';
  static const shopName = 'TEKFIX MOBILE HUB';

  // Navigation
  static const tabAttendance = 'ഹാജർ (Attendance)';
  static const tabRepairs = 'സർവീസ് (Repairs)';
  static const tabAlerts = 'അറിയിപ്പുകൾ (Alerts)';
  static const tabPos = 'സെയിൽസ് (Sales / POS)';
  static const tabApprovals = 'അറ്റൻഡൻസ് അംഗീകാരം (Approvals)';

  // Gating & Lock Banner
  static const posLockedTitle = 'പി.ഒ.എസ് ലോക്ക് ചെയ്തിരിക്കുന്നു (POS Locked)';
  static const posLockedBanner =
      'ഡ്യൂട്ടി ആരംഭിക്കാൻ ദയവായി അറ്റൻഡൻസ് രേഖപ്പെടുത്തുക (Please Check-In to Access POS)';
  static const posLockedSub =
      'സെയിൽസ്, ബില്ലിംഗ് എന്നിവ ഉപയോഗിക്കാൻ ഇന്നത്തെ ചെക്ക്-ഇൻ പൂർത്തിയാക്കുക.';
  static const btnCheckInNow = 'ചെക്ക്-ഇൻ ചെയ്യുക (Check In Now)';

  // Attendance Badges
  static const badgePendingApproval = 'അറ്റൻഡൻസ് രേഖപ്പെടുത്തി (Pending Owner Approval)';
  static const badgeApproved = '✔ അറ്റൻഡൻസ് അംഗീകരിച്ചു (Approved)';
  static const badgeRejected = '✖ അറ്റൻഡൻസ് നിരസിച്ചു (Rejected)';
  static const badgeAdjusted = '✎ സമയം തിരുത്തി (Adjusted)';

  // Shift & Duty Stages
  static const shiftStarted = 'ഷിഫ്റ്റ് ആരംഭിച്ചു (Shift Started)';
  static const dutyFull = 'പൂർണ്ണ ഡ്യൂട്ടി (Full Duty Completed)';
  static const dutyHalf = 'ഹാഫ് ഡേ ഡ്യൂട്ടി (Half Duty / Half Day)';
  static const dutyShort = 'പൂർണ്ണമല്ലാത്ത ഡ്യൂട്ടി (Incomplete / Short Duty)';
  static const dutyNeedsReview = 'പരിശോധന ആവശ്യമാണ് (Needs Review)';
  static const lateArrival = 'വൈകിയെത്തി (Late Arrival)';
  static const onTimeArrival = 'കൃത്യസമയത്ത് (On Time)';

  // Cash Register & Shift End
  static const cashRegisterTitle = 'ഷിഫ്റ്റ്-എൻഡ് ക്യാഷ് രജിസ്റ്റർ (Shift-End Cash Register)';
  static const cashRegisterDesc =
      'ഡ്യൂട്ടി അവസാനിപ്പിക്കുന്നതിന് മുമ്പ് ഡ്രോയറിലുള്ള തുക എണ്ണി തിട്ടപ്പെടുത്തുക.';
  static const labelShiftSales = 'ഷിഫ്റ്റിലെ ആകെ വിൽപ്പന (Shift Sales Total)';
  static const labelExpectedCash = 'പ്രതീക്ഷിക്കുന്ന ക്യാഷ് (Expected Cash in Drawer)';
  static const labelClosingCash = 'ഡ്രോയറിലുള്ള ക്യാഷ് (Counted Closing Cash)';
  static const labelDifference = 'വ്യത്യാസം (Difference)';
  static const labelMismatch = '⚠ തുകയിൽ വ്യത്യാസമുണ്ട് (Cash Mismatch Detected)';
  static const labelMatched = '✔ തുക കൃത്യമാണ് (Cash Matched)';
  static const btnConfirmCheckOut = 'ചെക്ക്-ഔട്ട് സ്ഥിരീകരിക്കുക (Confirm Check-Out)';

  // Pricing & Price Floor
  static const errPriceBelowFloor =
      'വില ₹{min}-ൽ താഴെ നൽകാൻ കഴിയില്ല (Cannot sell below floor price)';
  static const btnRequestOwnerApproval =
      'ഉടമസ്ഥന്റെ അനുമതി ചോദിക്കുക (Request Owner Approval / PIN)';
  static const pinApprovalTitle = 'ഉടമസ്ഥന്റെ പിൻ നൽകുക (Owner PIN Approval)';
  static const pinApprovalSub =
      'ഫ്ലോർ വിലയേക്കാൾ കുറഞ്ഞ നിരക്കിൽ വിൽക്കാൻ ഉടമസ്ഥന്റെ 4-അക്ക പിൻ നൽകുക.';
  static const errInvalidPin = 'തെറ്റായ പിൻ (Invalid PIN. Attempts remaining: {left})';
  static const errPinLocked = '3 തവണ തെറ്റായ പിൻ നൽകി. 15 മിനിറ്റ് കാത്തിരിക്കുക (PIN Locked)';

  // Catalog & Cart
  static const searchItems = 'സാധനങ്ങൾ തിരയുക (Search by Name, Barcode, SKU)...';
  static const inStock = 'സ്റ്റോക്കുണ്ട് (In Stock)';
  static const lowStock = 'കുറഞ്ഞ സ്റ്റോക്ക് (Low Stock)';
  static const outOfStock = 'സ്റ്റോക്കില്ല (Out of Stock)';
  static const addToCart = 'കാർട്ടിലേക്ക് ചേർക്കുക (Add to Cart)';
  static const cartTitle = 'ഷോപ്പിംഗ് കാർട്ട് (Cart)';
  static const emptyCart = 'കാർട്ട് ശൂന്യമാണ് (Cart is Empty)';
  static const subtotal = 'ഉപതുക (Subtotal)';
  static const discount = 'ഡിസ്കൗണ്ട് (Discount)';
  static const grandTotal = 'ആകെ തുക (Grand Total)';
  static const customerDetails = 'കസ്റ്റമർ വിവരങ്ങൾ (Customer Details - Optional)';
  static const customerName = 'പേര് (Customer Name)';
  static const customerPhone = 'ഫോൺ നമ്പർ (Phone Number)';

  // Payment
  static const paymentMode = 'പേയ്‌മെന്റ് രീതി (Payment Method)';
  static const payCash = 'ക്യാഷ് (Cash)';
  static const payUpi = 'യു.പി.ഐ / ക്യു.ആർ (UPI / QR)';
  static const payCard = 'കാർഡ് (Card)';
  static const paySplit = 'സ്പ്ലിറ്റ് (Split Payment)';
  static const cashReceived = 'ലഭിച്ച തുക (Cash Received)';
  static const changeDue = 'തിരികെ നൽകേണ്ട തുക (Change Due)';
  static const upiScanPrompt = 'ക്യു.ആർ കോഡ് സ്കാൻ ചെയ്ത് പണമടയ്ക്കുക (Scan & Pay)';
  static const btnPaymentReceived = 'പണം ലഭിച്ചു എന്ന് സ്ഥിരീകരിക്കുക (Payment Received)';
  static const btnCompleteSale = 'വിൽപ്പന പൂർത്തിയാക്കുക (Complete Sale)';

  // Receipt & Print
  static const saleSuccessTitle = 'വിൽപ്പന പൂർത്തിയായി (Sale Completed)';
  static const invoiceNo = 'ഇൻവോയ്സ് നമ്പർ (Invoice No)';
  static const btnShareWhatsApp = 'വാട്സാപ്പിൽ അയക്കുക (WhatsApp Share)';
  static const btnPrintThermal = 'പ്രിന്റ് ചെയ്യുക (Print Receipt)';
  static const btnNewSale = 'പുതിയ വിൽപ്പന (New Sale)';

  // Approvals (Owner)
  static const approvalsTitle = 'അറ്റൻഡൻസ് അംഗീകാരങ്ങൾ (Attendance Approvals)';
  static const pendingApprovalsCount = '{count} അംഗീകാരം കാത്തിരിക്കുന്നു';
  static const btnApproveAll = 'എല്ലാം അംഗീകരിക്കുക (Approve All Pending)';
  static const btnApprove = 'മാറ്റങ്ങൾ വരുത്താതെ അംഗീകരിക്കുക (Approve)';
  static const btnAdjustOrReject = 'സമയം തിരുത്തുകയോ നിരസിക്കുകയോ ചെയ്യുക (Adjust / Reject)';
  static const adjustDialogTitle = 'സമയം തിരുത്തുക (Adjust Attendance Times)';
  static const rejectDialogTitle = 'അറ്റൻഡൻസ് നിരസിക്കുക (Reject Attendance)';
  static const labelAdjustReason = 'തിരുത്തലിനുള്ള കാരണം (Reason for Adjustment - Required)';
  static const labelRejectReason = 'നിരസിക്കാനുള്ള കാരണം (Reason for Rejection - Required)';
  static const labelOriginalTime = 'യഥാർത്ഥ സമയം (Original Time)';
  static const labelAdjustedTime = 'പുതിയ സമയം (Adjusted Time)';
  static const revokeAccessPrompt = 'സ്റ്റാഫിന്റെ സെയിൽസ് ആക്സസ് ഇപ്പോൾ തന്നെ ബ്ലോക്ക് ചെയ്യണോ? (Revoke POS Access)';
  static const pendingMoreThan24h = '⚠ 24 മണിക്കൂറിലധികം ബാക്കി (Pending > 24h)';

  // Payroll
  static const payrollPendingWarning =
      'ശ്രദ്ധിക്കുക: {count} ദിവസത്തെ ഹാജർ ഉടമസ്ഥൻ അംഗീകരിക്കാൻ ബാക്കിയുണ്ട് (Pending: {count} days, not counted in payroll yet)';
}
