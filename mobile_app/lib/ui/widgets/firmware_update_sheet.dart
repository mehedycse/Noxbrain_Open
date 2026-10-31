import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_config.dart';
import '../../providers/solar_provider.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/update_service.dart';
import '../theme.dart';

/// Shows the changelog of an available firmware or app release; the update
/// runs only when the user taps Update. Never automatic.
class UpdateSheet extends StatefulWidget {
  final bool firmware;
  const UpdateSheet({super.key, required this.firmware});

  static Future<void> show(BuildContext context, {required bool firmware}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: SolarTheme.surface,
        builder: (_) => UpdateSheet(firmware: firmware),
      );

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> {
  bool _busy = false;
  String _status = '';
  // Status colour: progress text teal, success green, error red.
  Color _statusColor = SolarTheme.solarAmber;
  double? _progress;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
      _statusColor = SolarTheme.solarAmber;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = FirebaseAuthSession.message(e);
          _statusColor = SolarTheme.batteryDischarging;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateFirmware(SolarProvider provider) async {
    await provider.updateFirmware(
      (text) => mounted ? setState(() => _status = text) : null,
    );
    if (mounted) {
      setState(() {
        _status = 'Firmware updated and the new version confirmed.';
        _statusColor = SolarTheme.batteryGreen;
      });
    }
  }

  Future<void> _updateApp(AppRelease release) async {
    setState(() {
      _status = 'Downloading and checking the APK…';
      _progress = 0;
    });
    await UpdateService.downloadAndInstall(
      release,
      (p) => mounted ? setState(() => _progress = p) : null,
    );
    if (mounted) {
      setState(() {
        _progress = null;
        _status = 'The Android installer is open. Tap Install there.';
        _statusColor = SolarTheme.batteryGreen;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SolarProvider>();
    final fw = provider.firmwareRelease;
    final app = provider.appRelease;
    final available = widget.firmware
        ? provider.firmwareUpdateAvailable
        : provider.appUpdateAvailable;
    final blocked = widget.firmware ? null : provider.appUpdateBlockedReason;
    final current = widget.firmware
        ? provider.live.esp32FirmwareVersion
        : AppConfig.appVersion;
    final latest = widget.firmware ? fw?.version : app?.version;
    final changelog = widget.firmware ? fw?.changelog : app?.changelog;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.firmware ? 'Gateway Firmware Update' : 'App Update',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Installed: v$current · Latest: ${latest == null ? 'not available' : 'v$latest'}',
                style: const TextStyle(color: SolarTheme.textSecondary),
              ),
              if (changelog != null && changelog.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'What\'s New',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  changelog,
                  style: const TextStyle(
                    color: SolarTheme.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (!available)
                const Text(
                  'No new update.',
                  style: TextStyle(color: SolarTheme.textMuted),
                )
              else if (blocked != null) ...[
                Text(blocked, style: const TextStyle(color: SolarTheme.solarAmber)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          UpdateSheet.show(context, firmware: true);
                        },
                  child: const Text('Update the Firmware First'),
                ),
              ] else ...[
                if (widget.firmware)
                  const Text(
                    'Monitoring pauses for a few minutes during the update. If the new firmware cannot reach Firebase within 10 minutes, the gateway goes back to the previous firmware by itself.',
                    style: TextStyle(color: SolarTheme.textMuted),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          widget.firmware
                              ? () => _updateFirmware(provider)
                              : () => _updateApp(app!),
                        ),
                  child: const Text('Update'),
                ),
              ],
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(value: _progress),
                ),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: _statusColor,
                      fontWeight: _statusColor == SolarTheme.solarAmber
                          ? FontWeight.normal
                          : FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
