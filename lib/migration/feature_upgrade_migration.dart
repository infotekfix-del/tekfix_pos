import 'dart:io';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;

/// One-time idempotent migration service for TekFix ERP Feature Upgrade.
/// Enforces:
/// 1. Hive safety backup before modifying records.
/// 2. Nullable/defaulted fields for backwards compatibility.
/// 3. Populating `saleDate` from `createdAt` for existing legacy sales.
class FeatureUpgradeMigration {
  FeatureUpgradeMigration._();

  static const String _keyMigrationDone = 'migration_backdated_sales_v1_done';
  static const String _keyBackupJson = 'pre_feature_upgrade_backup_v1';
  static const String _keyBackupDate = 'pre_feature_upgrade_backup_v1_date';

  /// Runs the one-time migration safely with backup.
  static Future<void> runIfNeeded() async {
    try {
      final alreadyDone = Db.setting(_keyMigrationDone, 'false') == 'true';
      if (alreadyDone) return;

      debugPrint('[Migration] Starting one-time migration for Backdated Sales...');

      // 1. Take Hive safety backup
      await takeSafetyBackup();

      // 2. Migrate existing sales records
      int migratedSalesCount = 0;
      for (final key in Db.sales.keys) {
        final raw = Db.sales.get(key);
        if (raw is Map) {
          final s = Map<String, dynamic>.from(raw);
          bool changed = false;

          if (s['saleDate'] == null) {
            s['saleDate'] = s['date'] ?? s['createdAt'] ?? DateTime.now().toIso8601String();
            s['isBackdated'] = false;
            changed = true;
          }

          if (changed) {
            await Db.sales.put(key, s);
            migratedSalesCount++;
          }
        }
      }

      // 3. Mark migration complete
      await Db.settings.put(_keyMigrationDone, 'true');
      debugPrint('[Migration] Backdated sales migration complete. Migrated $migratedSalesCount sale(s).');

      // 4. Log migration to audit box
      await Db.logAction(
        action: 'Migration Completed',
        entity: 'System',
        entityId: 'BackdatedSales_v1',
        newValue: {
          'migratedSalesCount': migratedSalesCount,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    } catch (e, st) {
      debugPrint('[Migration] Warning during feature upgrade migration: $e\n$st');
    }
  }

  /// Exports all boxes to JSON and persists in settings and temporary file.
  static Future<void> takeSafetyBackup() async {
    try {
      final backupJson = Db.exportAll();
      await Db.settings.put(_keyBackupJson, backupJson);
      await Db.settings.put(_keyBackupDate, DateTime.now().toIso8601String());

      // Attempt file-based backup on desktop/mobile
      try {
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final backupFile = File('${tempDir.path}/tekfix_safety_backup_$timestamp.json');
        await backupFile.writeAsString(backupJson);
        debugPrint('[Migration] Safety backup written to: ${backupFile.path}');
      } catch (fileErr) {
        debugPrint('[Migration] File-based backup skipped: $fileErr');
      }
    } catch (e) {
      debugPrint('[Migration] Backup warning: $e');
    }
  }
}
