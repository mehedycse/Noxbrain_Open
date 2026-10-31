/// The shared web-view link: `https://<site>/#/v/<gatewayId>?db=<host>`
/// with an optional `&key=<Firebase Web API key>` for the owner's sign-in.
/// The owner takes Gateway ID and Database host from the app's
/// Diagnostics & Feedback report.
class WebLink {
  const WebLink(this.deviceId, this.dbHost, this.apiKey);
  final String deviceId;
  final String dbHost;
  final String apiKey;

  String get databaseUrl => 'https://$dbHost';

  static final _id = RegExp(r'^[A-Za-z0-9_-]{6,64}$');

  /// [route] is the part after `#` (Flutter's initial route). Null when it
  /// is not a valid web-view link.
  static WebLink? parse(String route) {
    if (route.isEmpty) return null;
    if (!route.startsWith('/')) route = '/$route';
    final uri = Uri.tryParse(route);
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments[0] != 'v') return null;
    final id = segments[1];
    final host = (uri.queryParameters['db'] ?? '').trim().toLowerCase();
    final validHost =
        RegExp(r'^[a-z0-9.-]+$').hasMatch(host) &&
        (host.endsWith('.firebaseio.com') ||
            host.endsWith('.firebasedatabase.app'));
    if (!_id.hasMatch(id) || !validHost) return null;
    return WebLink(id, host, (uri.queryParameters['key'] ?? '').trim());
  }
}
