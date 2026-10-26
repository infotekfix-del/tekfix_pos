import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show EmptyState, toast;
import '../ui/sync_status_icon.dart';
import 'staff_tracking_view.dart' show RoleBadge;

/// Owner creates / disables staff logins. (Salary & attendance stay in the
/// existing "Staff & Attendance" module.)
class StaffAccountsView extends StatelessWidget {
  const StaffAccountsView({super.key});

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController(), email = TextEditingController(), pass = TextEditingController();
    String? err;
    final a = context.read<AuthController>();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New staff login (പുതിയ സ്റ്റാഫ്)'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                border: Border.all(color: Colors.amber.shade400),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: Colors.amber.shade900),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'പുതിയ ക്രെഡൻഷ്യൽ വിവരങ്ങൾ infotekfix@gmail.com ലേക്ക് അയക്കപ്പെടും.\n(Notice is sent to infotekfix@gmail.com).',
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                    ),
                  ),
                ],
              ),
            ),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 8),
            TextField(controller: pass, decoration: const InputDecoration(labelText: 'Password (min 6)'), obscureText: true),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || email.text.trim().isEmpty || pass.text.length < 6) {
                  set(() => err = 'എല്ലാം ശരിയായി നൽകുക (Fill all fields)');
                  return;
                }
                final e = await a.createStaff(name.text, email.text, pass.text);
                if (e == null) {
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('സ്റ്റാഫ് അക്കൗണ്ട് ചേർത്തു. മുന്നറിയിപ്പ് infotekfix@gmail.com ലേക്ക് അയച്ചു. (Warning sent to infotekfix@gmail.com)')),
                    );
                  }
                } else {
                  set(() => err = e);
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    name.dispose(); email.dispose(); pass.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = context.watch<AuthController>();
    if (!a.isOwner) return const Scaffold(body: EmptyState(Icons.lock_rounded, 'Owner only'));
    return Scaffold(
      appBar: const TekAppBar(title: Text('Staff Logins & Authorizations (സ്റ്റാഫ് അക്കൗണ്ടുകൾ)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.person_add),
        label: const Text('Add Staff Account'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('shops/${a.shopId}/users').snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('സ്റ്റാഫ് അക്കൗണ്ടുകൾ ചേർത്തിട്ടില്ല (No staff accounts)'));
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final d in docs) ...[
                Builder(builder: (context) {
                  final data = d.data();
                  final isOwnerRole = data['role'] == 'owner';
                  final bool isApproved = data['active'] != false && data['approved'] != false;
                  final email = '${data['email'] ?? ''}'.trim().toLowerCase();

                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isOwnerRole
                              ? Colors.indigo.shade100
                              : (isApproved ? Colors.green.shade100 : Colors.red.shade100),
                          child: Icon(
                            isOwnerRole ? Icons.admin_panel_settings : Icons.badge_rounded,
                            color: isOwnerRole
                                ? Colors.indigo.shade800
                                : (isApproved ? Colors.green.shade800 : Colors.red.shade800),
                          ),
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '${data['name']}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                            ),
                            const SizedBox(width: 8),
                            RoleBadge(owner: isOwnerRole),
                            if (!isOwnerRole) ...[
                              const SizedBox(width: 6),
                              Chip(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                                label: Text(
                                  isApproved ? '✓ Approved' : '✕ Revoked',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isApproved ? Colors.green.shade900 : Colors.red.shade900,
                                  ),
                                ),
                                backgroundColor: isApproved ? Colors.green.shade50 : Colors.red.shade50,
                                side: BorderSide(
                                  color: isApproved ? Colors.green.shade300 : Colors.red.shade300,
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            email.isNotEmpty ? email : 'No email address registered',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                        trailing: isOwnerRole
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: isApproved,
                                    onChanged: (v) async {
                                      await a.setStaffActive(d.id, v, email: email);
                                      if (context.mounted) {
                                        toast(context, v ? 'Staff Approved & Allowed' : 'Staff Access Revoked');
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                    tooltip: 'Delete Staff Login',
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('സ്റ്റാഫ് അക്കൗണ്ട് നീക്കം ചെയ്യണോ?'),
                                          content: Text('\'${data['name']}\' ($email) അക്കൗണ്ട് പൂർണ്ണമായും നീക്കം ചെയ്യണോ?'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(ctx, false),
                                              child: const Text('വേണ്ട (Cancel)'),
                                            ),
                                            FilledButton(
                                              onPressed: () => Navigator.pop(ctx, true),
                                              style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                              child: const Text('ഡിലീറ്റ് (Delete)'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok == true) {
                                        await a.deleteStaffAccount(d.id, email: email);
                                        if (context.mounted) {
                                          toast(context, 'Staff account removed');
                                        }
                                      }
                                    },
                                  ),
                                ],
                              ),
                      ),
                    ),
                  );
                }),
              ],
            ],
          );
        },
      ),
    );
  }
}
