import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';
import 'daily_register_models.dart';

class CashDenominationCalculator extends StatefulWidget {
  final CashDenominations initialDenominations;
  final ValueChanged<CashDenominations> onChanged;

  const CashDenominationCalculator({
    super.key,
    required this.initialDenominations,
    required this.onChanged,
  });

  @override
  State<CashDenominationCalculator> createState() =>
      _CashDenominationCalculatorState();
}

class _CashDenominationCalculatorState
    extends State<CashDenominationCalculator> {
  late int _c500;
  late int _c200;
  late int _c100;
  late int _c50;
  late int _c20;
  late int _c10;
  late int _c5;
  late double _coins;

  late final TextEditingController _ctrl500;
  late final TextEditingController _ctrl200;
  late final TextEditingController _ctrl100;
  late final TextEditingController _ctrl50;
  late final TextEditingController _ctrl20;
  late final TextEditingController _ctrl10;
  late final TextEditingController _ctrl5;
  late final TextEditingController _ctrlCoins;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDenominations;
    _c500 = d.count500;
    _c200 = d.count200;
    _c100 = d.count100;
    _c50 = d.count50;
    _c20 = d.count20;
    _c10 = d.count10;
    _c5 = d.count5;
    _coins = d.coinsValue;

    _ctrl500 = TextEditingController(text: _c500 > 0 ? '$_c500' : '');
    _ctrl200 = TextEditingController(text: _c200 > 0 ? '$_c200' : '');
    _ctrl100 = TextEditingController(text: _c100 > 0 ? '$_c100' : '');
    _ctrl50 = TextEditingController(text: _c50 > 0 ? '$_c50' : '');
    _ctrl20 = TextEditingController(text: _c20 > 0 ? '$_c20' : '');
    _ctrl10 = TextEditingController(text: _c10 > 0 ? '$_c10' : '');
    _ctrl5 = TextEditingController(text: _c5 > 0 ? '$_c5' : '');
    _ctrlCoins =
        TextEditingController(text: _coins > 0 ? _coins.toStringAsFixed(0) : '');
  }

  @override
  void dispose() {
    _ctrl500.dispose();
    _ctrl200.dispose();
    _ctrl100.dispose();
    _ctrl50.dispose();
    _ctrl20.dispose();
    _ctrl10.dispose();
    _ctrl5.dispose();
    _ctrlCoins.dispose();
    super.dispose();
  }

  CashDenominations _buildModel() {
    return CashDenominations(
      count500: _c500,
      count200: _c200,
      count100: _c100,
      count50: _c50,
      count20: _c20,
      count10: _c10,
      count5: _c5,
      coinsValue: _coins,
    );
  }

  void _notify() {
    widget.onChanged(_buildModel());
  }

  void _clearAll() {
    setState(() {
      _c500 = 0;
      _c200 = 0;
      _c100 = 0;
      _c50 = 0;
      _c20 = 0;
      _c10 = 0;
      _c5 = 0;
      _coins = 0.0;
      _ctrl500.clear();
      _ctrl200.clear();
      _ctrl100.clear();
      _ctrl50.clear();
      _ctrl20.clear();
      _ctrl10.clear();
      _ctrl5.clear();
      _ctrlCoins.clear();
    });
    _notify();
  }

  Widget _denomRow({
    required String label,
    required Color color,
    required TextEditingController controller,
    required int quantity,
    required double subtotal,
    required ValueChanged<String> onChanged,
    required VoidCallback onAdd1,
    required VoidCallback onAdd5,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: TekColors.bgSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: quantity > 0
              ? color.withValues(alpha: 0.5)
              : TekColors.border.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Currency Tag
          Container(
            width: 68,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12.5,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 8),

          const Text('×',
              style: TextStyle(color: TekColors.textMuted, fontSize: 14)),
          const SizedBox(width: 8),

          // Qty Input
          SizedBox(
            width: 70,
            height: 36,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: TekColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: '0',
                hintStyle:
                    const TextStyle(color: TekColors.textMuted, fontSize: 13),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                fillColor: TekColors.bgCard,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: TekColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: color, width: 1.5),
                ),
              ),
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 6),

          // Increment helper pills (+1, +5)
          InkWell(
            onTap: onAdd1,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: TekColors.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: TekColors.border),
              ),
              child: const Text('+1',
                  style: TextStyle(fontSize: 10, color: TekColors.textSecondary)),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onAdd5,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: TekColors.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: TekColors.border),
              ),
              child: const Text('+5',
                  style: TextStyle(fontSize: 10, color: TekColors.textSecondary)),
            ),
          ),

          const Spacer(),

          // Subtotal
          Text(
            '= ₹${subtotal.toStringAsFixed(0)}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: subtotal > 0 ? TekColors.textPrimary : TekColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _buildModel();
    final total = d.totalCash;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.calculate_rounded,
                      size: 18, color: TekColors.secondary),
                  SizedBox(width: 8),
                  Text(
                    'Cash Denomination Calculator (നോട്ടുകൾ എണ്ണുക)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                ],
              ),
              if (!d.isEmpty)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _clearAll,
                  icon: const Icon(Icons.clear_all_rounded,
                      size: 14, color: TekColors.error),
                  label: const Text('Clear',
                      style:
                          TextStyle(color: TekColors.error, fontSize: 11.5)),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // ₹500
          _denomRow(
            label: '₹500',
            color: const Color(0xFF6366F1),
            controller: _ctrl500,
            quantity: _c500,
            subtotal: d.subtotal500,
            onChanged: (v) {
              setState(() => _c500 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c500++;
                _ctrl500.text = '$_c500';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c500 += 5;
                _ctrl500.text = '$_c500';
              });
              _notify();
            },
          ),

          // ₹200
          _denomRow(
            label: '₹200',
            color: const Color(0xFFF59E0B),
            controller: _ctrl200,
            quantity: _c200,
            subtotal: d.subtotal200,
            onChanged: (v) {
              setState(() => _c200 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c200++;
                _ctrl200.text = '$_c200';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c200 += 5;
                _ctrl200.text = '$_c200';
              });
              _notify();
            },
          ),

          // ₹100
          _denomRow(
            label: '₹100',
            color: const Color(0xFF10B981),
            controller: _ctrl100,
            quantity: _c100,
            subtotal: d.subtotal100,
            onChanged: (v) {
              setState(() => _c100 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c100++;
                _ctrl100.text = '$_c100';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c100 += 5;
                _ctrl100.text = '$_c100';
              });
              _notify();
            },
          ),

          // ₹50
          _denomRow(
            label: '₹50',
            color: const Color(0xFF06B6D4),
            controller: _ctrl50,
            quantity: _c50,
            subtotal: d.subtotal50,
            onChanged: (v) {
              setState(() => _c50 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c50++;
                _ctrl50.text = '$_c50';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c50 += 5;
                _ctrl50.text = '$_c50';
              });
              _notify();
            },
          ),

          // ₹20
          _denomRow(
            label: '₹20',
            color: const Color(0xFFEC4899),
            controller: _ctrl20,
            quantity: _c20,
            subtotal: d.subtotal20,
            onChanged: (v) {
              setState(() => _c20 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c20++;
                _ctrl20.text = '$_c20';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c20 += 5;
                _ctrl20.text = '$_c20';
              });
              _notify();
            },
          ),

          // ₹10
          _denomRow(
            label: '₹10',
            color: const Color(0xFF8B5CF6),
            controller: _ctrl10,
            quantity: _c10,
            subtotal: d.subtotal10,
            onChanged: (v) {
              setState(() => _c10 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c10++;
                _ctrl10.text = '$_c10';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c10 += 5;
                _ctrl10.text = '$_c10';
              });
              _notify();
            },
          ),

          // ₹5
          _denomRow(
            label: '₹5',
            color: const Color(0xFFEAB308),
            controller: _ctrl5,
            quantity: _c5,
            subtotal: d.subtotal5,
            onChanged: (v) {
              setState(() => _c5 = int.tryParse(v.trim()) ?? 0);
              _notify();
            },
            onAdd1: () {
              setState(() {
                _c5++;
                _ctrl5.text = '$_c5';
              });
              _notify();
            },
            onAdd5: () {
              setState(() {
                _c5 += 5;
                _ctrl5.text = '$_c5';
              });
              _notify();
            },
          ),

          // Coins / നാണയങ്ങൾ
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: TekColors.bgSecondary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _coins > 0
                    ? Colors.amber.withValues(alpha: 0.5)
                    : TekColors.border.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 68,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'Coins',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                      color: Colors.amber,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Value:',
                    style: TextStyle(color: TekColors.textMuted, fontSize: 13)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  height: 36,
                  child: TextField(
                    controller: _ctrlCoins,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                      hintText: '0',
                      hintStyle: const TextStyle(
                          color: TekColors.textMuted, fontSize: 13),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      fillColor: TekColors.bgCard,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: TekColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: Colors.amber, width: 1.5),
                      ),
                    ),
                    onChanged: (v) {
                      setState(() => _coins = double.tryParse(v.trim()) ?? 0.0);
                      _notify();
                    },
                  ),
                ),
                const Spacer(),
                Text(
                  '= ₹${_coins.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color:
                        _coins > 0 ? TekColors.textPrimary : TekColors.textMuted,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Total Physical Cash Display
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF6366F1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TOTAL PHYSICAL CASH',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF818CF8),
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      'എണ്ണിയെടുത്ത ആകെ പണം',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
                Text(
                  '₹${total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

