import 'package:flutter/foundation.dart';
import 'supabase_recharge_bridge_client.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 13.6: RECHARGE BACKEND BRIDGE
/// ZERO-COST BACKEND ROUTER FOR RECHARGE ACCOUNTING & TRUSTED DEVICES
/// ============================================================================

enum RechargeBackendMode {
  supabaseEdgeFunction,
  firebaseCloudFunction,
  localTestMock,
}

class RechargeBackendBridge {
  static RechargeBackendMode _mode = RechargeBackendMode.supabaseEdgeFunction;
  static SupabaseRechargeBridgeClient? _supabaseClient;

  static RechargeBackendMode get mode => _mode;
  static bool get isSupabaseMode => _mode == RechargeBackendMode.supabaseEdgeFunction;
  static bool get isFirebaseMode => _mode == RechargeBackendMode.firebaseCloudFunction;
  static SupabaseRechargeBridgeClient? get supabaseClient => _supabaseClient;

  /// Configure the global Recharge Backend Bridge
  static void configure({
    required RechargeBackendMode mode,
    SupabaseRechargeBridgeClient? supabaseClient,
  }) {
    _mode = mode;
    _supabaseClient = supabaseClient;
    debugPrint('[RechargeBackendBridge] Configured mode: ${_mode.name}');
  }

  /// Reset to default mode for tests or teardown
  @visibleForTesting
  static void reset() {
    _mode = RechargeBackendMode.supabaseEdgeFunction;
    _supabaseClient = null;
  }
}

