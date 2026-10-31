import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'providers/solar_provider.dart';
import 'services/weather_service.dart';
import 'ui/theme.dart';
import 'web/web_link.dart';
import 'web/web_navigation.dart';
import 'web/web_solar_provider.dart';

/// Web view entry point (flutter build web -t lib/main_web.dart). The
/// Android app starts from main.dart and never uses this file.
final webMessenger = GlobalKey<ScaffoldMessengerState>();

/// The app's phone width: a wide browser shows the mobile layout centred.
const double _columnWidth = 430;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The home weather would come from the viewer's own location, not the
  // system's: it stays off on the web.
  await WeatherService.setEnabled(false);
  final link = await _resolveLink(PlatformDispatcher.instance.defaultRouteName);
  runApp(
    link == null
        ? const _WebShell(child: _NoLink())
        : ChangeNotifierProvider<SolarProvider>(
            create: (_) => WebSolarProvider(link)
              ..onNotice = (message) => webMessenger.currentState?.showSnackBar(
                SnackBar(content: Text(message)),
              ),
            child: const _WebShell(child: WebNavigation()),
          ),
  );
}

Future<Map<String, dynamic>> _json(String path) async {
  try {
    final r = await http
        .get(Uri.base.resolve(path))
        .timeout(const Duration(seconds: 8));
    final data = r.statusCode == 200 ? jsonDecode(r.body) : null;
    return data is Map ? Map<String, dynamic>.from(data) : {};
  } catch (_) {
    return {};
  }
}

/// Which system to show. A full link (`#/v/<id>?db=<host>`) works on any
/// host. On Firebase Hosting the site's own project fills in the database
/// and API key (Hosting serves them at `/__/firebase/init.json`), so
/// `#/v/<id>` is enough; and an optional `site.json` next to index.html,
/// `{"gateway_id": "..."}`, picks the system shown at the plain address.
/// Nothing owner-specific is part of the source.
Future<WebLink?> _resolveLink(String route) async {
  final given = Uri.tryParse(route.startsWith('/') ? route : '/$route');
  final segments =
      given?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
  final query = Map<String, String>.from(given?.queryParameters ?? const {});
  final fromLink = query['db'] != null;
  if (fromLink) {
    final link = WebLink.parse(route);
    if (link == null || link.apiKey.isNotEmpty) return link;
  }
  final init = await _json('__/firebase/init.json');
  final ownHost = Uri.tryParse('${init['databaseURL'] ?? ''}')?.host ?? '';
  final ownKey = '${init['apiKey'] ?? ''}';
  var id = segments.length == 2 && segments[0] == 'v' ? segments[1] : '';
  if (id.isEmpty && !fromLink) {
    id = '${(await _json('site.json'))['gateway_id'] ?? ''}';
  }
  final host = query['db'] ?? ownHost;
  final link = WebLink.parse(
    Uri(
      path: '/v/$id',
      queryParameters: {
        'db': host,
        'key': query['key'] ?? (host == ownHost ? ownKey : ''),
      },
    ).toString(),
  );
  return link;
}

class _WebShell extends StatelessWidget {
  const _WebShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoxBrain',
      scaffoldMessengerKey: webMessenger,
      debugShowCheckedModeBanner: false,
      theme: SolarTheme.darkTheme,
      // The link's own path (#/v/…) is not an app route: always this page,
      // under the link's name so the address bar keeps the full link.
      onGenerateInitialRoutes: (name) => [
        MaterialPageRoute<void>(
          settings: RouteSettings(name: name),
          builder: (_) => child,
        ),
      ],
      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
      builder: (context, app) {
        final media = MediaQuery.of(context);
        final width = math.min(media.size.width, _columnWidth);
        return ColoredBox(
          color: SolarTheme.background,
          child: Center(
            child: SizedBox(
              width: width,
              child: MediaQuery(
                data: media.copyWith(size: Size(width, media.size.height)),
                child: app!,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NoLink extends StatelessWidget {
  const _NoLink();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/logo.png', width: 96, height: 96),
              const SizedBox(height: 20),
              const Text(
                'NoxBrain Live View',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Open the full link shared by the system owner. It looks like …/#/v/<Gateway ID>?db=<Database host>',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: SolarTheme.textSecondary,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
