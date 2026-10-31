import 'dart:convert';

import 'package:flutter/services.dart';

/// Talks to the gateway's setup hotspot. The phone joins that hotspot from
/// its own Wi-Fi settings; the native side sends only gateway traffic over it.
class Esp32Service {
  static const gatewayChannel = MethodChannel(
    'com.noxbrainsolarmonitoring/wifi_scanner',
  );

  /// Common setup-hotspot password, also shown on the web flasher page.
  static const hotspotPassword = '85208136';
  String? setupToken;

  Esp32Service();

  static Future<void> openWifiSettings() =>
      gatewayChannel.invokeMethod<void>('openWifiSettings');

  Future<Map<String, dynamic>> setupRequest(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final response = await gatewayChannel.invokeMapMethod<String, dynamic>(
      'gatewayRequest',
      {
        'path': path,
        'method': body == null ? 'GET' : 'POST',
        if (body != null) 'body': jsonEncode(body),
        if (setupToken != null) 'token': setupToken,
      },
    );
    if (response == null) throw Exception('No response from the gateway.');
    final decoded = jsonDecode(response['body'] as String);
    if ((response['status'] as num).toInt() >= 400) {
      throw Exception(
        decoded is Map
            ? decoded['message'] ?? 'Gateway request failed.'
            : 'Gateway request failed.',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// Joining the hotspot is the pairing step; this only opens a session.
  Future<void> pair() async {
    final data = await setupRequest('/api/pair', body: {});
    setupToken = data['token'] as String;
  }
}
