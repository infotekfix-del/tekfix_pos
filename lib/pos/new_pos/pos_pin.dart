// Customer View exit PIN: 4-6 digits set by the owner, stored only as a
// salted SHA-256 hash in the local settings box (never the PIN itself).
import 'dart:convert';

import 'package:crypto/crypto.dart';

const String kPosViewPinSetting = 'pos_view_pin_hash';

bool posValidPinFormat(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

String posPinHash(String pin) =>
    sha256.convert(utf8.encode('tekfix-pos-customer-view:$pin')).toString();

bool posPinMatches(String? storedHash, String pin) =>
    storedHash != null &&
    storedHash.isNotEmpty &&
    posValidPinFormat(pin) &&
    posPinHash(pin) == storedHash;
