import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db;
import '../security/device_security_service.dart';
import '../theme/tek_tokens.dart';
import 'recharge_backend_bridge.dart';
import 'recharge_recovery_engine.dart';

/// Modal dialog for recording instant mobile, utility, and DTH recharges
/// with full cash flow accounting and margin/profit tracking.
class QuickRechargeDialog extends StatefulWidget {
  const QuickRechargeDialog({super.key});

  static Future<void> show(BuildContext context) {
    if (!AuthController.instance.isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recharge is restricted to Shop Owner.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return Future.value();
    }
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const QuickRechargeDialog(),
    );
  }

  static String _maskPhone(String phone) {
    final clean = phone.trim();
    if (clean.length < 5) return '***';
    return '${clean.substring(0, 2)}*****${clean.substring(clean.length - 2)}';
  }

  /// Core server-authoritative accounting logic for executing a recharge transaction.
  /// Enforces:
  /// 1. Owner authorization & Enrolled hardware device (1 mobile + 1 laptop).
  /// 2. Cryptographic challenge nonce & Hardware ECDSA P-256 signature.
  /// 3. Server-side atomic PostgreSQL wallet debit & idempotency.
  /// 4. Synchronizing customer payment cash flow (Cash, Bank, Customer Due) ONLY post-confirmation.
  static Future<Map<String, dynamic>> recordRecharge({
    required String mobile,
    required String operator,
    required String serviceType,
    required double retailAmount,
    required double costPrice,
    required String paymentMode,
    dynamic partyKey,
    String partyName = '',
    String notes = '',
    String? customIdempotencyKey,
  }) async {
    // 1. Role-based Authorization: Must be authenticated Shop Owner
    debugPrint('[RECHARGE_SAVE] OWNER_AUTH_CHECK');
    final auth = AuthController.instance;
    if (!auth.isOwner) {
      debugPrint('[RECHARGE_SAVE] OWNER_AUTH_CHECK_FAILED: signedIn=${auth.signedIn}, isStaff=${auth.isStaffLoggedIn}, role=${auth.role}');
      throw StateError('Owner authorization required for recharge transactions');
    }
    debugPrint('[RECHARGE_SAVE] OWNER_AUTH_CHECK_PASSED: uid=${auth.uid}, shop=${auth.shopId}');

    // 2. Hardware Device Security: Must be an enrolled trusted device (1 mobile + 1 laptop)
    debugPrint('[RECHARGE_SAVE] DEVICE_SECURITY_CHECK');
    final sec = DeviceSecurityService.instance;
    if (!sec.isEnrolledLocally) {
      debugPrint('[RECHARGE_SAVE] DEVICE_SECURITY_CHECK_FAILED: deviceId=${sec.deviceId}, isEnrolled=false');
      throw StateError('Trusted device enrollment required: This device is not authorized for recharge transactions.');
    }
    debugPrint('[RECHARGE_SAVE] DEVICE_SECURITY_CHECK_PASSED: deviceId=${sec.deviceId}');

    // 2.1 Fast Client-Side Duplicate Tap Prevention (60-second safety window)
    if (customIdempotencyKey == null) {
      final sixtySecsAgo = DateTime.now().subtract(const Duration(seconds: 60));
      for (final key in Db.recharges.keys) {
        final raw = Db.recharges.get(key);
        if (raw is Map) {
          final existingMobile = raw['mobile']?.toString();
          final existingAmount = (raw['retailAmount'] as num?)?.toDouble() ?? (raw['amount'] as num?)?.toDouble() ?? 0.0;
          final rawDate = raw['createdAt']?.toString() ?? raw['date']?.toString();
          if (existingMobile == mobile && (existingAmount - retailAmount).abs() < 0.01 && rawDate != null) {
            final dt = DateTime.tryParse(rawDate);
            if (dt != null && dt.isAfter(sixtySecsAgo)) {
              debugPrint('[RECHARGE_SAVE] DUPLICATE_BLOCKED: ₹$retailAmount for ${_maskPhone(mobile)} within 60s');
              throw StateError('Duplicate transaction detected: A recharge of ₹$retailAmount was already processed within the last 60 seconds.');
            }
          }
        }
      }
    }

    // 3. Generate or validate UUIDv4 idempotency key
    final idempotencyKey = customIdempotencyKey ?? const Uuid().v4();
    final now = DateTime.now();
    final shopId = auth.shopId.isNotEmpty ? auth.shopId : Db.setting('shop_id', 'shop_staging_001');
    final ownerUid = auth.uid.isNotEmpty ? auth.uid : 'owner_staging_001';
    final devId = sec.deviceId;

    // 3.1 Pre-Commit Write-Ahead Journaling (Guarantees crash recovery without lost debit)
    await RechargeRecoveryEngine.recordPendingIntent(
      idempotencyKey: idempotencyKey,
      shopId: shopId,
      ownerUid: ownerUid,
      deviceId: devId,
      mobile: mobile,
      operator: operator,
      serviceType: serviceType,
      retailAmount: retailAmount,
      costPrice: costPrice,
      paymentMode: paymentMode,
      partyKey: partyKey,
      partyName: partyName,
      notes: notes,
    );

    final retailPaise = (retailAmount * 100).round();
    final costPaise = (costPrice * 100).round();
    final profit = retailAmount - costPrice;
    final commissionPaise = ((retailAmount - costPrice) * 100).round();
    final targetWalletId = 'WALLET_${operator.toUpperCase()}';
    const fundingType = 'ownPrepaid';

    // 4. Server-Authoritative Execution via Supabase Recharge Bridge
    final client = RechargeBackendBridge.supabaseClient;
    if (client == null) {
      debugPrint('[RECHARGE_SAVE] BACKEND_CLIENT_UNCONFIGURED: Supabase client is null');
      await RechargeRecoveryEngine.markFailed(idempotencyKey, 'Backend client unconfigured');
      throw StateError('Authoritative recharge backend client unconfigured. Local commits strictly prohibited.');
    }

    // 4.1 Request cryptographic single-use challenge nonce (300s TTL)
    final challenge = await client.requestChallenge(
      shopId: shopId,
      deviceId: devId,
      ownerUid: ownerUid,
    );

    // 4.2 Generate Hardware ECDSA P-256 signature over canonical payload
    debugPrint('[RECHARGE_SAVE] SIGNING_STARTED');
    final debitAmountPaise = costPaise > 0 ? costPaise : retailPaise;
    final canonicalData = '$targetWalletId:$idempotencyKey:$debitAmountPaise:$fundingType';
    final canonicalPayload = 'PROCESS_DEBIT:$shopId:$ownerUid:$devId:${challenge.nonce}:$canonicalData';
    final signature = await sec.signRawPayload(canonicalPayload);
    debugPrint('[RECHARGE_SAVE] SIGNING_COMPLETED');

    // 4.3 Execute atomic server-side wallet debit
    debugPrint('[RECHARGE_SAVE] BACKEND_REQUEST_STARTED');
    final res = await client.processDebit(
      shopId: shopId,
      walletId: targetWalletId,
      rechargeId: idempotencyKey,
      idempotencyKey: idempotencyKey,
      customerPhone: mobile,
      operator: operator,
      serviceType: serviceType,
      amountPaise: debitAmountPaise,
      amount: retailAmount,
      fundingType: fundingType,
      commissionEarnedPaise: commissionPaise,
      businessDate: DateFormat('yyyy-MM-dd').format(now),
      deviceId: devId,
      deviceSignature: signature,
      nonce: challenge.nonce,
      notes: notes,
      paymentMode: paymentMode,
      retailAmountPaise: retailPaise,
      costPricePaise: costPaise,
      partyKey: partyKey,
      partyName: partyName,
    );
    debugPrint('[RECHARGE_SAVE] BACKEND_RESPONSE_RECEIVED: success=${res['success']}');

    if (res['success'] != true) {
      final errMsg = res['error']?.toString() ?? 'Server rejected recharge transaction.';
      await RechargeRecoveryEngine.markFailed(idempotencyKey, errMsg);
      throw StateError(errMsg);
    }

    // Step 4.4 Mark server debit confirmed in durable outbox journal
    await RechargeRecoveryEngine.markServerConfirmed(
      idempotencyKey,
      res['txn_key'] ?? idempotencyKey,
    );

    final bool isIdempotentReplay = res['idempotentReplay'] == true;

    // 5. Customer Settlement & Local Non-Authoritative Cache (ONLY after server success)
    // Avoid double counting if this was an idempotent replay of an already processed transaction
    if (!isIdempotentReplay || !Db.recharges.containsKey(idempotencyKey)) {
      if (paymentMode == 'Cash') {
        if (!RechargeRecoveryEngine.hasMoneyMoved(idempotencyKey)) {
          await Db.moveMoney('Cash', retailAmount, 'Recharge Sale: $operator $mobile (Txn: $idempotencyKey)');
          await RechargeRecoveryEngine.markMoneySettled(idempotencyKey);
        }
      } else if (paymentMode == 'UPI') {
        if (!RechargeRecoveryEngine.hasMoneyMoved(idempotencyKey)) {
          await Db.moveMoney('Bank', retailAmount, 'Recharge UPI: $operator $mobile (Txn: $idempotencyKey)');
          await RechargeRecoveryEngine.markMoneySettled(idempotencyKey);
        }
      } else if (paymentMode == 'Credit / Due') {
        if (partyKey == null || !Db.parties.containsKey(partyKey)) {
          // Rule: Never silently redirect customer debt to general receivables
          await RechargeRecoveryEngine.markManualReviewRequired(
            idempotencyKey,
            'Identified customer party record missing/deleted (partyKey: $partyKey, name: $partyName). Debt must be manually reviewed.',
          );
          throw StateError('MANUAL_REVIEW_REQUIRED: Identified customer party record missing or deleted. Debt held for owner review.');
        }
        await Db.adjustParty(partyKey, retailAmount);
        await RechargeRecoveryEngine.markPartySettled(idempotencyKey);
      }
    }

    final entry = {
      'id': idempotencyKey,
      'rechargeId': idempotencyKey,
      'serverTxnKey': res['txn_key'] ?? idempotencyKey,
      'date': now.toIso8601String(),
      'createdAt': now.toIso8601String(),
      'mobile': mobile,
      'customerMobile': mobile,
      'operator': operator,
      'operatorName': operator,
      'serviceType': serviceType,
      'retailAmount': retailAmount,
      'amount': retailAmount,
      'amountPaise': retailPaise,
      'costPrice': costPrice,
      'costPricePaise': costPaise,
      'commission': profit,
      'commissionEarnedPaise': commissionPaise,
      'paymentMode': paymentMode,
      'partyKey': partyKey,
      'partyName': partyName,
      'notes': notes,
      'status': 'SUCCESS',
      'serverConfirmed': true,
      'idempotentReplay': isIdempotentReplay,
      'walletBalanceAfterPaise': res['balanceAfterPaise'] ?? res['totalBalancePaise'],
    };

    // Save non-authoritative read cache to Hive
    await Db.recharges.put(idempotencyKey, entry);
    debugPrint('[RECHARGE_SAVE] TRANSACTION_PERSISTED: id=$idempotencyKey');

    // Step 5.1 Mark completely settled and purge from pending outbox journal
    await RechargeRecoveryEngine.markSettled(idempotencyKey);

    // Audit log
    await Db.logAction(
      action: 'Recharge Sale (Server Authoritative)',
      entity: 'Recharge',
      entityId: idempotencyKey,
      newValue: entry,
    );

    return entry;
  }

  @override
  State<QuickRechargeDialog> createState() => _QuickRechargeDialogState();
}

class _QuickRechargeDialogState extends State<QuickRechargeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _mobileController = TextEditingController();
  final _amountController = TextEditingController();
  final _costController = TextEditingController();
  final _notesController = TextEditingController();

  String _operator = 'Jio';
  String _serviceType = 'Prepaid';
  String _paymentMode = 'Cash'; // Cash, UPI, Credit / Due
  dynamic _selectedPartyKey;
  String _selectedPartyName = '';
  bool _isCustomCost = false;
  bool _isSubmitting = false;
  String? _dialogError;

  final Map<String, double> _defaultMargins = {
    'Jio': 0.030, // 3.0%
    'Airtel': 0.028, // 2.8%
    'Vi': 0.035, // 3.5%
    'BSNL': 0.040, // 4.0%
    'Other / DTH': 0.030, // 3.0%
  };

  final List<int> _quickAmounts = [199, 239, 299, 666, 719, 859, 2999];

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountChanged);
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountChanged);
    _mobileController.dispose();
    _amountController.dispose();
    _costController.dispose();
    _notesController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    if (_isCustomCost) return;
    final amt = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (amt > 0) {
      final margin = _defaultMargins[_operator] ?? 0.03;
      final cost = amt * (1.0 - margin);
      _costController.text = cost.toStringAsFixed(2);
    } else {
      _costController.clear();
    }
    setState(() {});
  }

  void _onOperatorChanged(String op) {
    setState(() {
      _operator = op;
      _isCustomCost = false;
    });
    _onAmountChanged();
  }

  double get _retailAmount => double.tryParse(_amountController.text.trim()) ?? 0.0;
  double get _costPrice => double.tryParse(_costController.text.trim()) ?? 0.0;
  double get _commission => (_retailAmount > 0 && _costPrice > 0)
      ? (_retailAmount - _costPrice)
      : 0.0;

  void _pickCustomer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: TekColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final parties = Db.parties.values.toList();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.people_alt_rounded, color: TekColors.electricCyan),
                    const SizedBox(width: 10),
                    const Text(
                      'കസ്റ്റമറെ തിരഞ്ഞെടുക്കുക (Select Customer)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(color: TekColors.border, height: 1),
              Expanded(
                child: parties.isEmpty
                    ? const Center(
                        child: Text(
                          'കസ്റ്റമർമാർ ലഭ്യമല്ല (No customers found)',
                          style: TextStyle(color: TekColors.textMuted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: parties.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: TekColors.border, height: 1),
                        itemBuilder: (ctx, i) {
                          final p = parties[i];
                          if (p is! Map) return const SizedBox.shrink();
                          final name = (p['name'] ?? 'Unknown').toString();
                          final phone = (p['phone'] ?? '').toString();
                          final balance = double.tryParse(p['balance']?.toString() ?? '0') ?? 0.0;
                          final key = Db.parties.keyAt(i);

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: TekColors.primaryBlue.withAlpha(40),
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: TekColors.electricCyan),
                              ),
                            ),
                            title: Text(name, style: const TextStyle(color: Colors.white)),
                            subtitle: Text(
                              phone.isNotEmpty ? phone : 'No phone',
                              style: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                            ),
                            trailing: Text(
                              'Due: ₹${balance.toStringAsFixed(0)}',
                              style: TextStyle(
                                color: balance > 0 ? const Color(0xFFEF4444) : TekColors.textMuted,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            onTap: () {
                              setState(() {
                                _selectedPartyKey = key;
                                _selectedPartyName = name;
                                if (phone.isNotEmpty) {
                                  // Clean digits
                                  final digits = phone.replaceAll(RegExp(r'\D'), '');
                                  if (digits.length >= 10) {
                                    _mobileController.text = digits.substring(digits.length - 10);
                                  } else {
                                    _mobileController.text = digits;
                                  }
                                }
                              });
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitRecharge() async {
    debugPrint('[RECHARGE_SAVE] BUTTON_PRESSED');
    if (_isSubmitting) {
      debugPrint('[RECHARGE_SAVE] SUBMISSION_ALREADY_IN_PROGRESS: duplicate tap ignored');
      return;
    }

    setState(() {
      _dialogError = null;
    });

    debugPrint('[RECHARGE_SAVE] VALIDATION_STARTED');
    final formValid = _formKey.currentState?.validate() ?? false;
    if (!formValid) {
      final mLen = _mobileController.text.trim().length;
      final aText = _amountController.text.trim();
      debugPrint('[RECHARGE_SAVE] VALIDATION_FAILED: Form invalid (mobile length: $mLen, amount: "$aText")');
      setState(() {
        _dialogError = 'ദയവായി ആവശ്യമായ വിവരങ്ങൾ കൃത്യമായി നൽകുക (Please enter valid 10-digit number & amount)';
      });
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
      return;
    }

    if (_paymentMode == 'Credit / Due' && _selectedPartyKey == null) {
      debugPrint('[RECHARGE_SAVE] VALIDATION_FAILED: Customer not selected for Credit / Due');
      setState(() {
        _dialogError = 'കടത്തിന് കസ്റ്റമറെ തിരഞ്ഞെടുക്കണം (Select customer for Due)';
      });
      return;
    }

    debugPrint('[RECHARGE_SAVE] VALIDATION_PASSED');
    setState(() => _isSubmitting = true);

    try {
      final mobile = _mobileController.text.trim();
      final retail = _retailAmount;
      final cost = _costPrice > 0 ? _costPrice : (retail * (1.0 - (_defaultMargins[_operator] ?? 0.03)));
      final profit = retail - cost;

      await QuickRechargeDialog.recordRecharge(
        mobile: mobile,
        operator: _operator,
        serviceType: _serviceType,
        retailAmount: retail,
        costPrice: cost,
        paymentMode: _paymentMode,
        partyKey: _selectedPartyKey,
        partyName: _selectedPartyName,
        notes: _notesController.text.trim(),
      );

      debugPrint('[RECHARGE_SAVE] UI_SUCCESS');

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '₹${retail.toStringAsFixed(0)} റീചാർജ് രേഖപ്പെടുത്തി! ലാഭം: ₹${profit.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1E293B),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('[RECHARGE_SAVE] ERROR: $e');
      debugPrint('[RECHARGE_SAVE] STACK: $stack');
      if (mounted) {
        final cleanMsg = e.toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('Bad state: ', '')
            .replaceFirst('StateError: ', '');
        setState(() {
          _isSubmitting = false;
          _dialogError = cleanMsg;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('റീചാർജ് പരാജയപ്പെട്ടു: $cleanMsg'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 700;

    return Dialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: TekColors.border, width: 1.2),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? 580 : 420,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                decoration: const BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  border: Border(bottom: BorderSide(color: TekColors.border)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: TekColors.electricCyan.withAlpha(30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.phone_android_rounded,
                        color: TekColors.electricCyan,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quick Recharge (റീചാർജ്)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Mobile, DTH & Utility Payment',
                            style: TextStyle(color: TekColors.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              // Scrollable Form Content
              Flexible(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Operator Selection Chips
                      const Text(
                        'ഓപ്പറേറ്റർ (Operator)',
                        style: TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ['Jio', 'Airtel', 'Vi', 'BSNL', 'Other / DTH'].map((op) {
                          final selected = _operator == op;
                          return ChoiceChip(
                            label: Text(op),
                            selected: selected,
                            onSelected: (_) => _onOperatorChanged(op),
                            selectedColor: TekColors.primaryBlue,
                            backgroundColor: TekColors.mainBg,
                            labelStyle: TextStyle(
                              color: selected ? Colors.white : TekColors.textSecondary,
                              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                color: selected ? TekColors.primaryBlue : TekColors.border,
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 16),

                      // 2. Service Type
                      const Text(
                        'സേവന തരം (Service Type)',
                        style: TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: ['Prepaid', 'Postpaid', 'DTH'].map((type) {
                          final selected = _serviceType == type;
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InkWell(
                                onTap: () => setState(() => _serviceType = type),
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? TekColors.electricCyan.withAlpha(40)
                                        : TekColors.mainBg,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: selected
                                          ? TekColors.electricCyan
                                          : TekColors.border,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    type,
                                    style: TextStyle(
                                      color: selected ? Colors.white : TekColors.textSecondary,
                                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 16),

                      // 3. Mobile Number Field + Contact Picker
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _mobileController,
                              keyboardType: TextInputType.phone,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(10),
                              ],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2,
                              ),
                              decoration: InputDecoration(
                                labelText: _serviceType == 'DTH'
                                    ? 'സബ്‌സ്‌ക്രൈബർ ഐഡി / നമ്പർ'
                                    : 'മൊബൈൽ നമ്പർ (10 Digits)',
                                labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
                                prefixIcon: const Icon(Icons.call_rounded, color: TekColors.electricCyan, size: 20),
                                hintText: '9876543210',
                                hintStyle: const TextStyle(color: TekColors.textMuted),
                                filled: true,
                                fillColor: TekColors.mainBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: TekColors.border),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: TekColors.border),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: TekColors.electricCyan, width: 1.5),
                                ),
                              ),
                              validator: (val) {
                                if (val == null || val.trim().isEmpty) {
                                  return 'മൊബൈൽ നമ്പർ നൽകുക';
                                }
                                if (_serviceType != 'DTH' && val.trim().length != 10) {
                                  return '10 അക്ക മൊബൈൽ നമ്പർ വേണം';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: 'Select Customer (കസ്റ്റമർ തിരഞ്ഞെടുക്കുക)',
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: TekColors.elevatedSurface,
                                foregroundColor: TekColors.electricCyan,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: const BorderSide(color: TekColors.border),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
                              ),
                              onPressed: _pickCustomer,
                              child: const Icon(Icons.contacts_rounded, size: 22),
                            ),
                          ),
                        ],
                      ),

                      if (_selectedPartyName.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.person_rounded, size: 14, color: TekColors.electricCyan),
                            const SizedBox(width: 4),
                            Text(
                              'Selected: $_selectedPartyName',
                              style: const TextStyle(color: TekColors.electricCyan, fontSize: 11.5),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => setState(() {
                                _selectedPartyKey = null;
                                _selectedPartyName = '';
                              }),
                              child: const Text(
                                'Clear',
                                style: TextStyle(color: Colors.redAccent, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 16),

                      // 4. Amount Field & Fast Amount Chips
                      TextFormField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                        ],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          labelText: 'റീചാർജ് തുക (Retail Amount)',
                          labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
                          prefixIcon: const Icon(Icons.currency_rupee_rounded, color: Colors.greenAccent, size: 22),
                          hintText: '299',
                          hintStyle: const TextStyle(color: TekColors.textMuted),
                          filled: true,
                          fillColor: TekColors.mainBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: TekColors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: TekColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Colors.greenAccent, width: 1.5),
                          ),
                        ),
                        validator: (val) {
                          final amt = double.tryParse(val?.trim() ?? '');
                          if (amt == null || amt <= 0) {
                            return 'സാധുവായ തുക നൽകുക';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _quickAmounts.map((amt) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                label: Text('₹$amt'),
                                backgroundColor: TekColors.elevatedSurface,
                                labelStyle: const TextStyle(color: Colors.white, fontSize: 11.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: const BorderSide(color: TekColors.border),
                                ),
                                onPressed: () {
                                  _amountController.text = amt.toString();
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // 5. Cost Price & Live Profit Display
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _costController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                              ],
                              onChanged: (_) => _isCustomCost = true,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                labelText: 'യഥാർത്ഥ ചിലവ് (Cost Price)',
                                labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                                prefixText: '₹ ',
                                prefixStyle: const TextStyle(color: TekColors.textSecondary),
                                filled: true,
                                fillColor: TekColors.mainBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: TekColors.border),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Profit Badge
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withAlpha(25),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF10B981).withAlpha(100)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'കമ്മീഷൻ / ലാഭം',
                                    style: TextStyle(color: Colors.white70, fontSize: 10.5),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '₹${_commission.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Color(0xFF34D399),
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // 6. Payment Modes
                      const Text(
                        'പണമിടപാട് രീതി (Payment Mode)',
                        style: TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _buildPaymentModeOption('Cash', Icons.payments_rounded, const Color(0xFF10B981)),
                          const SizedBox(width: 8),
                          _buildPaymentModeOption('UPI', Icons.qr_code_rounded, const Color(0xFF3B82F6)),
                          const SizedBox(width: 8),
                          _buildPaymentModeOption('Credit / Due', Icons.history_edu_rounded, const Color(0xFFF59E0B)),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Notes
                      TextFormField(
                        controller: _notesController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'കുറിപ്പ് (Notes - Optional)',
                          labelStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12),
                          filled: true,
                          fillColor: TekColors.mainBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: TekColors.border),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Action Buttons Footer
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
                  border: Border(top: BorderSide(color: TekColors.border)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_dialogError != null) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.withAlpha(40),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.redAccent.withAlpha(160)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _dialogError!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
                          child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: Colors.white70)),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: _isSubmitting
                                  ? TekColors.primaryBlue.withAlpha(160)
                                  : TekColors.primaryBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: _isSubmitting ? null : _submitRecharge,
                            icon: _isSubmitting
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                : const Icon(Icons.check_rounded, size: 18),
                            label: Text(
                              _isSubmitting ? 'സേവ് ചെയ്യുന്നു...' : 'സേവ് ചെയ്യുക (Save)',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentModeOption(String mode, IconData icon, Color color) {
    final selected = _paymentMode == mode;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _paymentMode = mode;
            if (mode == 'Credit / Due' && _selectedPartyKey == null) {
              _pickCustomer();
            }
          });
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color.withAlpha(40) : TekColors.mainBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : TekColors.border,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, color: selected ? color : TekColors.textMuted, size: 20),
              const SizedBox(height: 4),
              Text(
                mode,
                style: TextStyle(
                  color: selected ? Colors.white : TekColors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

