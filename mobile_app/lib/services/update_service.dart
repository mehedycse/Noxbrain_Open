import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/app_config.dart';

/// Public release feeds. Nothing personal: these are the product's own sites.
class UpdateSources {
  /// Firmware OTA list (e.g. hosted on GitHub Pages).
  /// Can be overridden at build time via:
  /// `--dart-define=OTA_UPDATE_URL=https://your-domain.com/ota.json`
  static const firmwareList = String.fromEnvironment(
    'OTA_UPDATE_URL',
    defaultValue: 'https://mehedycse.github.io/noxbrain_espupdate/ota.json',
  );

  /// App release list for APK self-update.
  /// Can be overridden at build time via:
  /// `--dart-define=APP_UPDATE_URL=https://your-domain.com/app.json`
  static const appList = String.fromEnvironment(
    'APP_UPDATE_URL',
    defaultValue: 'https://noxbrain.com/solarapp/app.json',
  );
}

class FirmwareBuild {
  const FirmwareBuild(this.url, this.size, this.sha256);
  final String url, sha256;
  final int size;
}

class FirmwareRelease {
  const FirmwareRelease(this.version, this.changelog, this.builds);
  final String version, changelog;
  final Map<String, FirmwareBuild> builds; // keyed by chip family

  static FirmwareRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final builds = <String, FirmwareBuild>{};
    final raw = json['builds'];
    if (raw is Map) {
      raw.forEach((chip, b) {
        if (b is Map && b['url'] is String && b['sha256'] is String) {
          builds[chip.toString()] = FirmwareBuild(
            b['url'] as String,
            (b['size'] as num?)?.toInt() ?? 0,
            b['sha256'] as String,
          );
        }
      });
    }
    final version = json['version']?.toString() ?? '';
    if (version.isEmpty || builds.isEmpty) return null;
    return FirmwareRelease(version, _changelog(json['changelog']), builds);
  }
}

class AppRelease {
  const AppRelease(
    this.version,
    this.versionCode,
    this.changelog,
    this.apkUrl,
    this.size,
    this.sha256,
    this.minFirmwareVersion,
  );
  final String version, changelog, apkUrl, sha256;
  final int versionCode, size;

  /// Set only when firmware and app are released together: the gateway must
  /// run at least this firmware before the app may be updated.
  final String? minFirmwareVersion;

  static AppRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['apk_url']?.toString() ?? '';
    final sha = json['sha256']?.toString() ?? '';
    final code = (json['version_code'] as num?)?.toInt() ?? 0;
    if (url.isEmpty || sha.length != 64 || code <= 0) return null;
    final minFw = json['min_firmware_version']?.toString() ?? '';
    return AppRelease(
      json['version']?.toString() ?? '',
      code,
      _changelog(json['changelog']),
      url,
      (json['size'] as num?)?.toInt() ?? 0,
      sha,
      minFw.isEmpty ? null : minFw,
    );
  }
}

String _changelog(Object? value) => value is List
    ? value.map((line) => '• $line').join('\n')
    : value?.toString() ?? '';

class UpdateService {
  static const _channel = MethodChannel(
    'com.noxbrainsolarmonitoring/wifi_scanner',
  );

  /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }

  static Future<Object?> _getJson(String url) async {
    final r = await http
        .get(Uri.parse(url), headers: {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    return jsonDecode(r.body);
  }

  static Future<FirmwareRelease?> latestFirmware() async {
    try {
      return FirmwareRelease.fromJson(
        await _getJson(UpdateSources.firmwareList),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<AppRelease?> latestApp() async {
    try {
      return AppRelease.fromJson(await _getJson(UpdateSources.appList));
    } catch (_) {
      return null;
    }
  }

  /// Downloads the APK, verifies its size and SHA-256, then opens Android's
  /// own installer. The user still confirms the installation there.
  static Future<void> downloadAndInstall(
    AppRelease release,
    void Function(double progress) onProgress,
  ) async {
    if (AppConfig.playStoreBuild) {
      throw Exception('App updates come from Google Play.');
    }
    if (!release.apkUrl.startsWith('https://noxbrain.com/solarapp/')) {
      throw Exception('The APK can only be downloaded from the official address.');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/update.apk');
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(release.apkUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('APK download failed (${response.statusCode}).');
      }
      final total = response.contentLength ?? release.size;
      final sink = file.openWrite();
      var received = 0;
      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
      hasher.close();
      if ((release.size > 0 && received != release.size) ||
          digest.events.single.toString() != release.sha256.toLowerCase()) {
        await file.delete();
        throw Exception('APK check failed (size/SHA-256 mismatch). Not installed.');
      }
    } finally {
      client.close();
    }
    await _channel.invokeMethod('installApk', {'path': file.path});
  }
}

/// Collects the single digest produced by a chunked hash conversion.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}
