import 'package:flutter/material.dart';
import 'audit/hardware_audit_screen.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 14.7.1: STANDALONE HARDWARE SECURITY AUDIT ENTRYPOINT
/// ============================================================================
/// 
/// Standalone runner targeting purely local Android Keystore hardware APIs.
/// Zero Firebase dependencies, zero production connections, zero billing impact.
/// ============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TekFixHardwareAuditApp());
}

class TekFixHardwareAuditApp extends StatelessWidget {
  const TekFixHardwareAuditApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TekFix Hardware Security Audit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const HardwareAuditScreen(),
    );
  }
}

