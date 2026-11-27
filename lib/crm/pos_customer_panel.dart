// POS customer panel: type a phone number -> instant customer card.
//
// Performance (low-end Android): the lookup runs only after a 250 ms pause
// and only when the number normalises to 10 digits; it is 2-3 Hive gets
// (phone index -> stats -> party) plus up to 3 sale gets. No box scans.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../main.dart' show rs, Pill, AppCard;
import 'customer_crm.dart';
import 'customer_models.dart';
import 'phone_utils.dart';

final _day = DateFormat('dd MMM yyyy');

String _dayOf(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  return d == null ? '-' : _day.format(d.toLocal());
}

String _rsPaise(int paise) => rs(paise / 100);

/// Holds the POS customer state so it survives bottom-sheet rebuilds.
/// Owns no controllers: it listens to the POS's existing name/phone fields.
class PosCustomerController extends ChangeNotifier {
  PosCustomerController({
    required this.name,
    required this.phone,
    this.onLinked,
  }) {
    phone.addListener(_onPhone);
  }

  final TextEditingController name, phone;

  /// Called with the matched customer (or null when the match is gone) and
  /// the id that was linked before.
  final void Function(CrmCustomer? customer, String? previousId)? onLinked;

  CrmCustomer? found;
  List<MapEntry<dynamic, Map<String, dynamic>>> recent = const [];
  bool nameLocked = false;
  bool whatsappOptIn = true;
  String? phoneErr;
  Timer? _debounce;
  String _lastText = '';
  String? _autoName; // name we filled in, cleared again if number changes

  String? get normalized => normalizePhone(phone.text);
  bool get hasPhone => phoneDigits(phone.text).isNotEmpty;
  bool get isNewCustomer => found == null && normalized != null;

  /// A customer will be attached to the bill (found, or created on save).
  bool get willHaveCustomer => found != null || normalized != null;

  void _onPhone() {
    if (phone.text == _lastText) return; // selection/focus changes
    _lastText = phone.text;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), lookupNow);
  }

  /// Runs the lookup immediately (also used after the debounce).
  void lookupNow() {
    _debounce?.cancel();
    final ph = normalized;
    final crm = CustomerCrm.maybeInstance;
    final digits = phoneDigits(phone.text).length;
    phoneErr = digits >= 10 && ph == null ? phoneError(phone.text) : null;
    final prev = found;
    final c = ph == null || crm == null ? null : crm.lookupByPhone(ph);
    if (c?.id == prev?.id && c != null) return;
    found = c;
    if (c != null) {
      recent = crm!.salesOf(c.id, limit: 3);
      name.text = c.name;
      _autoName = c.name;
      nameLocked = true;
    } else {
      recent = const [];
      nameLocked = false;
      if (_autoName != null && name.text == _autoName) name.clear();
      _autoName = null;
    }
    onLinked?.call(c, prev?.id);
    notifyListeners();
  }

  void unlockName() {
    nameLocked = false;
    notifyListeners();
  }

  void setOptIn(bool v) {
    whatsappOptIn = v;
    notifyListeners();
  }

  /// At bill save: the customer for this bill (creating it if the number is
  /// new), or null for a walk-in. Throws [FormatException] on a bad number.
  Future<CrmCustomer?> resolveForBill() async {
    final crm = CustomerCrm.maybeInstance;
    if (crm == null || !hasPhone) return null;
    return crm.resolveForBill(
      phoneRaw: phone.text,
      name: name.text,
      whatsappOptIn: whatsappOptIn,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    phone.removeListener(_onPhone);
    super.dispose();
  }
}

class PosCustomerPanel extends StatelessWidget {
  const PosCustomerPanel({
    super.key,
    required this.controller,
    this.onChanged,
    this.onFullHistory,
  });

  final PosCustomerController controller;
  final VoidCallback? onChanged;
  final void Function(CrmCustomer c)? onFullHistory;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller.found;
        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: controller.phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\- ]')),
                  LengthLimitingTextInputFormatter(16),
                ],
                onChanged: (_) => onChanged?.call(),
                onSubmitted: (_) => controller.lookupNow(),
                decoration: InputDecoration(
                  labelText: 'മൊബൈൽ നമ്പർ (Mobile number — optional)',
                  prefixIcon: const Icon(Icons.phone_rounded, size: 20),
                  errorText: controller.phoneErr,
                  suffixIcon: c != null
                      ? Icon(Icons.verified_rounded, color: Colors.green.shade600)
                      : controller.isNewCustomer
                          ? Icon(Icons.person_add_alt_1_rounded, color: cs.primary)
                          : null,
                ),
              ),
            ),
            if (c != null) _card(context, c),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextField(
                controller: controller.name,
                readOnly: controller.nameLocked,
                onChanged: (_) => onChanged?.call(),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: controller.isNewCustomer
                      ? 'പുതിയ കസ്റ്റമർ പേര് (New customer name)'
                      : 'കസ്റ്റമർ പേര് (Customer name)',
                  helperText: controller.isNewCustomer
                      ? 'ബിൽ സേവ് ചെയ്യുമ്പോൾ കസ്റ്റമറെ ചേർക്കും (Customer is saved with the bill)'
                      : null,
                  prefixIcon: const Icon(Icons.person_rounded, size: 20),
                  suffixIcon: controller.nameLocked
                      ? TextButton(
                          onPressed: controller.unlockName,
                          child: const Text('Edit'),
                        )
                      : null,
                ),
              ),
            ),
            if (controller.isNewCustomer)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: controller.whatsappOptIn,
                onChanged: (v) => controller.setOptIn(v ?? false),
                title: const Text(
                    'WhatsApp ഓഫറുകൾ അയക്കാം (Customer agrees to WhatsApp offers)',
                    style: TextStyle(fontSize: 13)),
              ),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context, CrmCustomer c) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget stat(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: muted)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14, color: color)),
            ],
          ),
        );
    return AppCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CircleAvatar(radius: 16, child: Icon(Icons.person, size: 18)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              Pill('${c.billCount} bills', Colors.indigo),
            ],
          ),
          const SizedBox(height: 10),
          Row(children: [
            stat('ആകെ (Total spent)', _rsPaise(c.totalSpentPaise)),
            stat('അവസാനം (Last visit)', _dayOf(c.lastPurchaseAt?.toIso8601String())),
            if (c.balancePaise > 0)
              stat('ബാക്കി (Pending)', _rsPaise(c.balancePaise),
                  color: Colors.red.shade600),
          ]),
          if (controller.recent.isNotEmpty) ...[
            const Divider(height: 18),
            for (final e in controller.recent) _saleRow(context, e.value),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onFullHistory == null ? null : () => onFullHistory!(c),
              icon: const Icon(Icons.history_rounded, size: 18),
              label: const Text('Full history (മുഴുവൻ ഹിസ്റ്ററി)'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _saleRow(BuildContext context, Map<String, dynamic> s) {
    final items = (s['items'] as List?) ?? const [];
    final first = items.isEmpty ? '-' : '${(items.first as Map)['name'] ?? '-'}';
    final more = items.length > 1 ? ' +${items.length - 1}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text('$first$more',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          Text(_dayOf(saleWhen(s)),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          Text(_rsPaise(toPaise(s['total'])),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      ),
    );
  }
}
