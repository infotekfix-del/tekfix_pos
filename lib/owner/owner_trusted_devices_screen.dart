import 'package:flutter/material.dart';
import '../auth/auth_controller.dart';
import '../security/device_security_service.dart';
import '../security/trusted_device_controller.dart';
import '../theme/tek_tokens.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 13.3.3: OWNER TRUSTED DEVICE MANAGEMENT SCREEN
/// ============================================================================
///
/// OWNER-ONLY presentation screen for managing hardware-bound trusted devices.
/// Displays:
/// 1. Current Device Verification Status (Registered / Unregistered)
/// 2. Registered Mobile Phone (Device ID, Model, Enrolled Date)
/// 3. Registered Laptop (Device ID, Model, Enrolled Date)
/// 4. Register This Device CTA (Enforces maximum 2 devices quota)
/// 5. Revoke / Replace Device Actions
/// ============================================================================

class OwnerTrustedDevicesScreen extends StatefulWidget {
  const OwnerTrustedDevicesScreen({super.key});

  @override
  State<OwnerTrustedDevicesScreen> createState() => _OwnerTrustedDevicesScreenState();
}

class _OwnerTrustedDevicesScreenState extends State<OwnerTrustedDevicesScreen> {
  final _deviceModelController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final shopId = AuthController.instance.shopId;
    TrustedDeviceController.instance.loadDevices(shopId);
    _deviceModelController.text = DeviceSecurityService.instance.platformType == DevicePlatformType.android
        ? 'Owner Mobile Phone'
        : 'Owner POS Laptop';
  }

  @override
  void dispose() {
    _deviceModelController.dispose();
    super.dispose();
  }

  Future<void> _handleRegisterDevice() async {
    final shopId = AuthController.instance.shopId;
    final modelName = _deviceModelController.text.trim().isNotEmpty
        ? _deviceModelController.text.trim()
        : 'Registered Terminal';

    final success = await TrustedDeviceController.instance.registerCurrentDevice(
      shopId: shopId,
      deviceModelName: modelName,
    );

    if (!mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ ഈ ഉപകരണം വിജയകരമായി രജിസ്റ്റർ ചെയ്തു (Device registered successfully).'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      final err = TrustedDeviceController.instance.error ?? 'Unknown error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ രജിസ്ട്രേഷൻ പരാജയപ്പെട്ടു: $err'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _confirmRevoke(TrustedDeviceModel device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('ഉപകരണം റദ്ദാക്കുക (Revoke Device)?', style: TextStyle(color: Colors.white)),
        content: Text(
          'നിങ്ങൾ "${device.deviceModel}" (${device.deviceId}) റദ്ദാക്കാൻ ആഗ്രഹിക്കുന്നുണ്ടോ? '
          'റദ്ദാക്കിയ ശേഷം ഈ ഉപകരണത്തിൽ നിന്ന് റീച്ചാർജ് ഇടപാടുകൾ അനുവദിക്കില്ല.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('റദ്ദാക്കരുത് (Cancel)'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('റദ്ദാക്കുക (Revoke)'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final shopId = AuthController.instance.shopId;
      final ok = await TrustedDeviceController.instance.revokeDevice(
        shopId: shopId,
        targetDeviceId: device.deviceId,
      );

      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ ഉപകരണം വിജയകരമായി റദ്ദാക്കി (Device revoked successfully).'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthController.instance;

    // Strict non-owner guard
    if (!auth.isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Access Denied')),
        body: const Center(
          child: Text(
            '❌ ഉടമയ്ക്ക് മാത്രമേ വിശ്വസനീയ ഉപകരണങ്ങൾ നിയന്ത്രിക്കാൻ അനുവാദമുള്ളൂ (Owner only).',
            style: TextStyle(color: Colors.redAccent, fontSize: 16),
          ),
        ),
      );
    }

    final controller = TrustedDeviceController.instance;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final currentDeviceId = DeviceSecurityService.instance.deviceId;
        final isCurrentRegistered = controller.isCurrentDeviceRegistered;
        final registeredMobile = controller.registeredMobile;
        final registeredLaptop = controller.registeredLaptop;

        return Scaffold(
          backgroundColor: const Color(0xFF0B1120),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            elevation: 0,
            title: const Text(
              'വിശ്വസനീയ ഉപകരണങ്ങൾ (Owner Trusted Devices)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => controller.loadDevices(auth.shopId),
              ),
            ],
          ),
          body: controller.loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Card: Device Access Policy
                      _buildPolicyHeader(),
                      const SizedBox(height: 20),

                      // Current Device Status Card
                      _buildCurrentDeviceCard(currentDeviceId, isCurrentRegistered),
                      const SizedBox(height: 24),

                      const Text(
                        'അംഗീകൃത ഉപകരണങ്ങൾ (Registered Terminals)',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),

                      // Slot 1: Mobile Phone
                      _buildDeviceSlotCard(
                        categoryLabel: 'രജിസ്റ്റർ ചെയ്ത ഫോൺ (Owner Mobile)',
                        icon: Icons.smartphone_rounded,
                        device: registeredMobile,
                        expectedType: 'mobile',
                      ),
                      const SizedBox(height: 16),

                      // Slot 2: Laptop
                      _buildDeviceSlotCard(
                        categoryLabel: 'രജിസ്റ്റർ ചെയ്ത ലാപ്‌ടോപ്പ് (Owner Laptop)',
                        icon: Icons.laptop_chromebook_rounded,
                        device: registeredLaptop,
                        expectedType: 'laptop',
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _buildPolicyHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(Icons.shield_rounded, color: Colors.blueAccent, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'റീച്ചാർജ് അക്കൗണ്ടിംഗ് ഉടമയുടെ രജിസ്റ്റർ ചെയ്ത മൊബൈലിൽ നിന്നും ഒരു ലാപ്‌ടോപ്പിൽ നിന്നും മാത്രമേ പ്രവർത്തിക്കൂ (പരമാവധി 2 ഉപകരണങ്ങൾ). സ്റ്റാഫ് ഉപകരണങ്ങളിൽ നിന്ന് റീച്ചാർജ് അനുവദിക്കില്ല.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentDeviceCard(String currentDeviceId, bool isRegistered) {
    final devSec = DeviceSecurityService.instance;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isRegistered ? const Color(0x1F10B981) : const Color(0x1FEF4444),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isRegistered ? Colors.green.withOpacity(0.4) : Colors.redAccent.withOpacity(0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isRegistered ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: isRegistered ? Colors.greenAccent : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Text(
                isRegistered ? 'ഈ ഉപകരണം രജിസ്റ്റർ ചെയ്തിട്ടുണ്ട് (Active & Verified)' : 'ഈ ഉപകരണം രജിസ്റ്റർ ചെയ്തിട്ടില്ല (Unregistered)',
                style: TextStyle(
                  color: isRegistered ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Device ID: $currentDeviceId  |  Type: ${devSec.deviceType.toUpperCase()}  |  Platform: ${devSec.platformType.name.toUpperCase()}',
            style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace'),
          ),
          if (!isRegistered) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _deviceModelController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'ഉപകരണത്തിന്റെ പേര് (Device Model / Name)',
                labelStyle: TextStyle(color: Colors.white60),
                filled: true,
                fillColor: Color(0xFF0F172A),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TekColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onPressed: _handleRegisterDevice,
              icon: const Icon(Icons.add_moderator_rounded),
              label: const Text('ഈ ഉപകരണം രജിസ്റ്റർ ചെയ്യുക (Register This Device)'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceSlotCard({
    required String categoryLabel,
    required IconData icon,
    required TrustedDeviceModel? device,
    required String expectedType,
  }) {
    final isEnrolled = device != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isEnrolled ? Colors.blue.withOpacity(0.15) : Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: isEnrolled ? Colors.blueAccent : Colors.white38, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  categoryLabel,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                if (isEnrolled) ...[
                  Text(
                    '${device.deviceModel} (${device.deviceId})',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Platform: ${device.platform.toUpperCase()}  |  Active',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
                  ),
                ] else ...[
                  const Text(
                    'രജിസ്റ്റർ ചെയ്തിട്ടില്ല (Slot Available)',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (isEnrolled)
            IconButton(
              icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
              tooltip: 'റദ്ദാക്കുക (Revoke)',
              onPressed: () => _confirmRevoke(device),
            ),
        ],
      ),
    );
  }
}

