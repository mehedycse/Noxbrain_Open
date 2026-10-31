import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Current weather from Open-Meteo (free, no account) at the phone's
/// approximate location. The location stays on the phone apart from this
/// request, rounded to about 1 km; it is never sent to Firebase.
class WeatherService {
  static const _keyEnabled = 'home_weather_enabled';
  // Last location, rounded to about 1 km and kept only on this phone, so the
  // weather still works while the phone's Location is switched off.
  static const _keyLat = 'home_weather_lat', _keyLon = 'home_weather_lon';

  /// The user's "Show weather" choice: null until they have been asked once
  /// (the explanation is shown before Android's location prompt).
  static final ValueNotifier<bool?> enabled = ValueNotifier<bool?>(null);

  // Texts of current() when no weather could be shown (worth a retry soon).
  static const locationOff = 'Weather: location off';
  static const unavailable = 'Weather unavailable';
  static bool isFailure(String text) =>
      text == locationOff || text == unavailable;

  static Future<bool?> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_keyEnabled);
    return enabled.value;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
    if (!value) {
      await prefs.remove(_keyLat);
      await prefs.remove(_keyLon);
    }
    enabled.value = value;
  }

  /// Asks Android for approximate location; only called right after the
  /// user chose to show weather. Returns whether permission is granted.
  static Future<bool> requestPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return false;
    }
    return permission != LocationPermission.denied;
  }

  /// Short weather text, or a hint explaining why it is unavailable. Never
  /// asks for permission itself (the periodic refresh must not re-ask).
  /// Location only has to be on once; after that the saved one is used.
  static Future<String> current() async {
    final prefs = await SharedPreferences.getInstance();
    double? lat, lon;
    // A fresh location when Location is on and allowed; otherwise the saved one.
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever &&
        await Geolocator.isLocationServiceEnabled()) {
      try {
        Position? position = await Geolocator.getLastKnownPosition();
        position ??= await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 15),
          ),
        );
        lat = double.parse(position.latitude.toStringAsFixed(2));
        lon = double.parse(position.longitude.toStringAsFixed(2));
        await prefs.setDouble(_keyLat, lat);
        await prefs.setDouble(_keyLon, lon);
      } catch (_) {
        // No fix right now: fall back to the saved location below.
      }
    }
    lat ??= prefs.getDouble(_keyLat);
    lon ??= prefs.getDouble(_keyLon);
    if (lat == null || lon == null) return locationOff;
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat.toStringAsFixed(2),
      'longitude': lon.toStringAsFixed(2),
      'current': 'temperature_2m,weather_code,is_day',
      'timezone': 'auto',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return unavailable;
    final current = (jsonDecode(r.body) as Map)['current'] as Map?;
    final temp = (current?['temperature_2m'] as num?)?.round();
    final code = (current?['weather_code'] as num?)?.toInt();
    if (temp == null || code == null) return unavailable;
    // Open-Meteo: is_day = 1 in daylight, 0 at night at this location.
    final isDay = (current?['is_day'] as num?)?.toInt() != 0;
    return '${_describe(code, isDay)} $temp°C';
  }

  /// WMO weather codes as used by Open-Meteo.
  static String _describe(int code, bool isDay) {
    if (code == 0) return isDay ? '☀️ Sunny' : '🌙 Clear';
    if (code <= 2) return isDay ? '🌤️ Partly cloudy' : '☁️ Partly cloudy';
    if (code == 3) return '☁️ Overcast';
    if (code == 45 || code == 48) return '🌫️ Fog';
    if (code >= 51 && code <= 67) return '🌧️ Rain';
    if (code >= 71 && code <= 77) return '❄️ Snow';
    if (code >= 80 && code <= 82) return '🌦️ Showers';
    if (code >= 95) return '⛈️ Thunderstorm';
    return '🌥️ Cloudy';
  }
}
