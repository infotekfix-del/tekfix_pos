// Service job intake actions: print the device sticker and message the
// customer (WhatsApp or SMS) when a job is created or marked Ready.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../barcode/barcode_label_service.dart';
import '../crm/phone_utils.dart';
import '../main.dart' show Db, toast;
import '../pos/whatsapp_invoice_message.dart';
import '../reminders/reminder_service.dart';
import 'job_intake.dart';

/// How the customer is told about the job.
enum JobNotify { whatsapp, sms, none }

const _kNotifySetting = 'job_notify_channel';
const _kLabelSetting = 'job_print_label';

/// SMS straight from the app needs an Android phone (SIM). On Windows only
/// WhatsApp is offered.
bool get jobSmsSupported => !kIsWeb && Platform.isAndroid;

JobNotify jobNotifyDefault() {
  final v = '${Db.setting(_kNotifySetting, 'whatsapp')}';
  final n = JobNotify.values.firstWhere((e) => e.name == v,
      orElse: () => JobNotify.whatsapp);
  return n == JobNotify.sms && !jobSmsSupported ? JobNotify.whatsapp : n;
}

bool jobPrintLabelDefault() =>
    '${Db.setting(_kLabelSetting, 'true')}' != 'false';

Future<void> saveJobIntakeDefaults(JobNotify n, bool printLabel) async {
  await Db.settings.put(_kNotifySetting, n.name);
  await Db.settings.put(_kLabelSetting, '$printLabel');
}

// ------------------------------------------------------------------ label

/// Prints the device sticker on the barcode label printer. Returns null on
/// success, otherwise a message for the user.
Future<String?> printJobLabel(Map job, {int copies = 1}) async {
  final svc = BarcodeLabelService.instance;
  try {
    await svc.initialize();
  } catch (_) {}
  final c = svc.config;
  try {
    if (!kIsWeb && Platform.isWindows && c.useDirectRaw) {
      if (c.printerName.trim().isEmpty) {
        return 'ലേബൽ പ്രിന്റർ തിരഞ്ഞെടുത്തിട്ടില്ല (Select the label printer in Barcode Print settings)';
      }
      final r = await WindowsRawPrinter.instance.sendRawTspl(
        printerName: c.printerName,
        tsplCommand: jobLabelTspl(job,
            widthMm: c.widthMm,
            heightMm: c.heightMm,
            gapMm: c.gapMm,
            referenceX: c.referenceXDots,
            referenceY: c.referenceYDots,
            density: c.darkness,
            speed: c.speed,
            copies: copies),
        docName: 'TekFix Job ${job['jobId']}',
        labelsCount: copies,
      );
      return r.success ? null : 'ലേബൽ പ്രിന്റ് ആയില്ല: ${r.message}';
    }
    // PDF fallback (Android / no raw printing).
    final doc = pw.Document();
    final format = PdfPageFormat(
        c.widthMm * PdfPageFormat.mm, c.heightMm * PdfPageFormat.mm,
        marginAll: 1.5 * PdfPageFormat.mm);
    final lines = jobLabelLines(job, maxChars: (c.widthMm * 0.9).round());
    for (var i = 0; i < copies; i++) {
      doc.addPage(pw.Page(
        pageFormat: format,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              pw.Text(l, maxLines: 1, style: const pw.TextStyle(fontSize: 5.5)),
            pw.Spacer(),
            pw.Center(
              child: pw.BarcodeWidget(
                barcode: pw.Barcode.code128(),
                data: labelText('${job['jobId']}'),
                height: 7 * PdfPageFormat.mm,
                textStyle: const pw.TextStyle(fontSize: 5.5),
              ),
            ),
          ],
        ),
      ));
    }
    final bytes = await doc.save();
    await Printing.layoutPdf(
        name: 'Job ${job['jobId']}', format: format, onLayout: (_) => bytes);
    return null;
  } catch (e) {
    return 'ലേബൽ പ്രിന്റ് ആയില്ല: $e';
  }
}

// --------------------------------------------------------------- messages

Future<bool> _whatsApp(String phone, String msg) async {
  try {
    return await launchUrl(whatsAppInvoiceUri(phone, msg),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<bool> _sms(String phone, String msg) async {
  final p = normalizePhone(phone) ?? phone;
  try {
    if (await ReminderService.instance.sendSilentSms(p, msg)) return true;
  } catch (_) {
    // No SEND_SMS permission yet: fall back to the SMS app.
  }
  try {
    return await ReminderService.instance.openSmsIntent(p, msg);
  } catch (_) {
    return false;
  }
}

/// Sends [kind] ('received' or 'ready') for [job] by [via].
/// Returns null when sent/opened, otherwise a message for the user.
Future<String?> sendJobMessage(Map job, JobNotify via,
    {String kind = 'received'}) async {
  if (via == JobNotify.none) return null;
  final phone = '${job['phone'] ?? ''}';
  if (!isValidPhone(phone)) {
    return 'ഫോൺ നമ്പർ ശരിയല്ല, മെസ്സേജ് അയച്ചില്ല';
  }
  final ready = kind == 'ready';
  final ok = via == JobNotify.sms
      ? await _sms(phone, ready ? jobReadySms(job) : jobReceivedSms(job))
      : await _whatsApp(
          phone, ready ? jobReadyMessage(job) : jobReceivedMessage(job));
  if (!ok) {
    return via == JobNotify.sms
        ? 'SMS അയക്കാൻ പറ്റിയില്ല'
        : 'WhatsApp തുറക്കാൻ പറ്റിയില്ല';
  }
  await Db.logAction(
      action: ready ? 'Service Ready Message' : 'Service Received Message',
      entity: 'Service Job',
      entityId: '${job['jobId']}',
      newValue: via.name);
  return null;
}

/// After a new job is saved: sticker first (the device is still on the
/// counter), then the customer message.
Future<void> runJobIntakeActions(BuildContext context, Map job,
    {required JobNotify notify, required bool printLabel}) async {
  if (printLabel) {
    final e = await printJobLabel(job);
    if (e != null && context.mounted) toast(context, e, error: true);
  }
  final e = await sendJobMessage(job, notify);
  if (e != null && context.mounted) toast(context, e, error: true);
}

/// Asks whether to tell the customer the device is ready.
Future<void> offerReadyMessage(BuildContext context, Map job) async {
  if (!isValidPhone('${job['phone'] ?? ''}')) return;
  final via = await showDialog<JobNotify>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ready മെസ്സേജ് അയക്കണോ? (Notify customer)'),
      content: Text(
          '${job['customerName'] ?? ''} – ${jobDeviceName(job)}\n'
          'റിപ്പയർ കഴിഞ്ഞു, വന്ന് വാങ്ങാം എന്ന് അറിയിക്കാം.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, JobNotify.none),
            child: const Text('വേണ്ട (No)')),
        if (jobSmsSupported)
          OutlinedButton.icon(
              onPressed: () => Navigator.pop(ctx, JobNotify.sms),
              icon: const Icon(Icons.sms_rounded, size: 16),
              label: const Text('SMS')),
        FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, JobNotify.whatsapp),
            icon: const Icon(Icons.chat_rounded, size: 16),
            label: const Text('WhatsApp')),
      ],
    ),
  );
  if (via == null || via == JobNotify.none) return;
  final e = await sendJobMessage(job, via, kind: 'ready');
  if (e != null && context.mounted) toast(context, e, error: true);
}

/// Options shown in the New Job Card form.
class JobIntakeOptions extends StatelessWidget {
  final JobNotify notify;
  final bool printLabel;
  final ValueChanged<JobNotify> onNotify;
  final ValueChanged<bool> onPrintLabel;
  const JobIntakeOptions({
    super.key,
    required this.notify,
    required this.printLabel,
    required this.onNotify,
    required this.onPrintLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('കസ്റ്റമർക്ക് അറിയിപ്പ് (Notify customer)',
          style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      SegmentedButton<JobNotify>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(
              value: JobNotify.whatsapp,
              icon: Icon(Icons.chat_rounded, size: 16),
              label: Text('WhatsApp')),
          if (jobSmsSupported)
            const ButtonSegment(
                value: JobNotify.sms,
                icon: Icon(Icons.sms_rounded, size: 16),
                label: Text('SMS')),
          const ButtonSegment(value: JobNotify.none, label: Text('വേണ്ട')),
        ],
        selected: {notify},
        onSelectionChanged: (s) => onNotify(s.first),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: printLabel,
        onChanged: (v) => onPrintLabel(v ?? false),
        title: const Text('ബാർകോഡ് സ്റ്റിക്കർ പ്രിന്റ് ചെയ്യുക (Print device label)'),
      ),
    ]);
  }
}
