import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/app_config.dart';
import '../../providers/solar_provider.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/firebase_service.dart';
import '../theme.dart';
import '../widgets/save_notice.dart';

/// Collects everything needed to explain a problem, writes it to a file on
/// the phone and lets the user read it before sending it anywhere.
///
/// The gateway keeps its diagnostic lines in memory but only ever printed
/// them to its serial port, which needs a computer wired to the device. With
/// the gateway often far away, that made faults impossible to investigate;
/// the `get_logs` command brings the same lines back through the cloud.
///
/// Nothing secret is collected: no Firebase key, e-mail, password or token,
/// and no Wi-Fi password. The file is shown in full before it is shared, so
/// the user can see exactly what is about to leave the phone.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _busy = false;
  String _report = '';
  File? _file;

  Future<void> _collect(SolarProvider provider) async {
    if (_busy) return;
    setState(() => _busy = true);
    final lines = <String>[];
    void section(String title) {
      lines..add('')..add('--- $title ---');
    }

    final now = DateTime.now();
    lines.add('NoxBrain diagnostic report');
    lines.add('Taken: ${now.toIso8601String()}');

    section('App');
    lines.add('App version: ${AppConfig.appVersion} (${AppConfig.appVersionCode})');
    lines.add('Play build: ${AppConfig.playStoreBuild}');
    lines.add('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');

    section('Gateway identity');
    final config = provider.config;
    lines.add('Gateway ID: ${config.deviceId}');
    // Host only: the key, the e-mail and the password are never collected.
    lines.add('Database host: ${Uri.tryParse(config.firebaseDatabaseUrl)?.host ?? "not set"}');
    lines.add('Setup complete: ${config.isSetupCompleted}');
    lines.add('Battery mode: ${config.batteryMode.isEmpty ? "not set" : config.batteryMode}');

    section('Last reading seen by the app');
    final live = provider.live;
    lines.add('Gateway online: ${live.connected}');
    lines.add('Controller connected: ${live.controllerConnected}');
    lines.add('Firmware: ${live.esp32FirmwareVersion}');
    lines.add('Gateway time: ${live.timestamp?.toIso8601String() ?? "never"}');
    if (live.loadCalLearned != null) {
      lines.add('Load meter correction: ${live.loadCalLearned! ? "learned, ratio ${live.loadCalRatio?.toStringAsFixed(4)}" : "not learned yet"}'
          '${live.loadRawPower != null ? " (controller reading ${live.loadRawPower!.toStringAsFixed(1)} W, shown ${live.loadPower.toStringAsFixed(1)} W)" : ""}');
    }
    if (provider.errorMessage != null) {
      lines.add('Last app error: ${provider.errorMessage}');
    }

    section('Gateway diagnostics');
    try {
      final data = await FirebaseService(config).fetchGatewayLogs();
      final kept = data.remove('lines');
      for (final entry in data.entries) {
        lines.add('${entry.key}: ${entry.value}');
      }
      lines.add('');
      if (kept is List && kept.isNotEmpty) {
        lines.addAll(kept.map((line) => line.toString()));
      } else {
        lines.add('(the gateway has kept no diagnostic lines yet)');
      }
    } catch (e) {
      // A gateway that cannot be reached is itself the most useful finding,
      // so the report is still written rather than abandoned.
      lines.add('Could not reach the gateway: ${FirebaseAuthSession.message(e)}');
      lines.add('A gateway needs firmware 1.1.29 or newer to send its log.');
    }

    final report = lines.join('\n');
    File? file;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      file = File('${dir.path}/noxbrain-log-$stamp.txt');
      await file.writeAsString(report);
    } catch (e) {
      file = null;
    }
    if (!mounted) return;
    setState(() {
      _report = report;
      _file = file;
      _busy = false;
    });
    showSaveNotice(
      context,
      file == null
          ? 'Report ready, but it could not be saved to a file.'
          : 'Report ready and saved on this phone.',
      success: file != null,
    );
  }

  Future<void> _share() async {
    final file = _file;
    if (file == null) return;
    // Same call the energy export already uses, so both behave alike.
    await Share.shareXFiles([
      XFile(file.path),
    ], subject: 'NoxBrain diagnostic report', text: 'NoxBrain diagnostic report attached.');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SolarProvider>();
    return Scaffold(
      backgroundColor: SolarTheme.background,
      appBar: AppBar(
        backgroundColor: SolarTheme.surface,
        foregroundColor: SolarTheme.textPrimary,
        title: const Text('Diagnostics'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card('What this collects', [
            const Text(
              'App and gateway versions, what the gateway is connected to, and '
              'the last few things it did. Passwords, keys and login details '
              'are never included.\n\nThe report is saved on this phone first '
              'so you can read it below before sending it to anyone.',
              style: TextStyle(
                fontSize: 12,
                color: SolarTheme.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            _button(
              _busy ? 'Collecting…' : 'Collect report',
              Icons.troubleshoot_rounded,
              _busy ? null : () => _collect(provider),
            ),
          ]),
          if (_report.isNotEmpty)
            _card('Report', [
              if (_file != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Saved as ${_file!.path.split(Platform.pathSeparator).last}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: SolarTheme.textMuted,
                    ),
                  ),
                ),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 340),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: SolarTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SolarTheme.border),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _report,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.45,
                      fontFamily: 'monospace',
                      color: SolarTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _button(
                'Send report',
                Icons.send_rounded,
                _file == null ? null : _share,
              ),
            ]),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SolarTheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SolarTheme.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: SolarTheme.textPrimary,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );

  Widget _button(String label, IconData icon, VoidCallback? onPressed) =>
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: SolarTheme.solarAmber,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: Icon(icon, size: 18),
          label: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          onPressed: onPressed,
        ),
      );
}
