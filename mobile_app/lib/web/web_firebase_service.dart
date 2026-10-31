import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../services/firebase_auth_session.dart';
import '../services/firebase_service.dart';

/// The web view's reads. Without sign-in only the four public parts of the
/// gateway are read, with no auth (the additive read rule); after the owner
/// signs in every read goes through the app's normal authenticated path.
class WebFirebaseService extends FirebaseService {
  WebFirebaseService(super.config, this.signedIn);

  final bool Function() signedIn;

  static const publicPaths = {'live', 'summary', 'lifetime', 'history'};

  @override
  Future<dynamic> read(String path) async {
    final data = signedIn() ? await super.read(path) : await _publicRead(path);
    if (path == 'live' && data is Map) _followBatteryMode(data);
    return data;
  }

  Future<dynamic> _publicRead(String path) async {
    if (!publicPaths.contains(path)) {
      throw Exception('Sign in to Settings for this.');
    }
    final base = FirebaseAuthSession.validateDatabaseUrl(
      config.firebaseDatabaseUrl,
    );
    final r = await http
        .get(Uri.parse('$base/devices/${config.deviceId}/$path.json'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const WebViewNotShared();
    }
    if (r.statusCode != 200) {
      throw Exception('Firebase read failed (${r.statusCode}).');
    }
    return jsonDecode(r.body);
  }

  /// The browser has none of the phone's saved choices: the battery mode the
  /// gateway reports decides whether BMS values are shown, as in the app.
  void _followBatteryMode(Map data) {
    final mode = data['battery_mode']?.toString();
    if (mode == AppConfig.modeControllerBms ||
        mode == AppConfig.modeControllerOnly) {
      config.batteryMode = mode!;
    }
    final bms = data['bms_enabled'];
    config.isBmsEnabled = bms is bool
        ? bms && mode != AppConfig.modeControllerOnly
        : mode == AppConfig.modeControllerBms;
  }
}

/// The database does not allow reading this gateway without sign-in: the
/// owner has not published the web-view read rule (or the link is wrong).
class WebViewNotShared implements Exception {
  const WebViewNotShared();
  @override
  String toString() =>
      'This system is not shared for web viewing. The owner must publish the web-view read rule in Firebase, or check the link.';
}
