import 'package:hive/hive.dart';

double tekD(dynamic v) {
  final value = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return value != null && value.isFinite ? value : 0.0;
}

int tekI(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
double tekR2(double v) => (v * 100).round() / 100;
DateTime tekDt(dynamic v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.now();

Map<String, dynamic> tekM(dynamic v) {
  if (v is Map) {
    return Map<String, dynamic>.fromEntries(
      v.entries.where((e) => e.key is String).map(
            (e) => MapEntry(e.key as String, e.value),
          ),
    );
  }
  return <String, dynamic>{};
}

List<MapEntry<dynamic, Map<String, dynamic>>> entriesOf(Box b) =>
    [for (final k in b.keys) MapEntry(k, tekM(b.get(k)))];

bool isSaleReturned(Map s) =>
    s['returned'] == true || '${s['status'] ?? ''}'.toUpperCase() == 'RETURNED';

double d(dynamic v) => tekD(v);
int i(dynamic v) => tekI(v);
Map<String, dynamic> m(dynamic v) => tekM(v);
DateTime dt(dynamic v) => tekDt(v);
double r2(double v) => tekR2(v);
bool isReturned(Map s) => isSaleReturned(s);
