import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/app_config.dart';

/// One row of the read-only Firebase connection check: ok is null when the
/// item could not be checked yet.
class FirebaseCheck {
  const FirebaseCheck(this.label, this.ok, this.hint);
  final String label;
  final bool? ok;
  final String hint;
}

class _Session {
  _Session(this.token, this.refresh, this.uid, this.expires);
  final String token, refresh, uid;
  DateTime expires;
}

/// Tokens and the device login are never written to the ordinary app config.
/// Sessions are kept per Firebase project and email, so the app can talk to
/// the current and a new project at the same time (remote Firebase change).
class FirebaseAuthSession {
  static const _vault = MethodChannel(
    'com.noxbrainsolarmonitoring/credentials',
  );
  static final Map<String, _Session> _sessions = {};
  static final Map<String, Future<_Session>> _pending = {};
  static String _sessionKey(String project, String email) =>
      '$project|${email.trim()}';

  static String validateDatabaseUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path != '' && uri.path != '/') ||
        !(uri.host.endsWith('.firebaseio.com') ||
            uri.host.endsWith('.firebasedatabase.app'))) {
      throw const FormatException(
        'Enter the Firebase HTTPS Realtime Database URL.',
      );
    }
    return 'https://${uri.host}';
  }

  static String message(Object error) {
    final s = error.toString();
    if (s.contains('INVALID_LOGIN_CREDENTIALS') ||
        s.contains('INVALID_PASSWORD') ||
        s.contains('EMAIL_NOT_FOUND')) {
      return 'Firebase email or password is incorrect.';
    }
    if (s.contains('ADMIN_ONLY_OPERATION')) {
      return 'Keep new user sign-up enabled in Firebase Authentication; the gateway needs its own account.';
    }
    if (s.contains('OPERATION_NOT_ALLOWED')) {
      return 'Enable Email/Password in Firebase Authentication.';
    }
    if (s.contains('API_KEY_INVALID') || s.contains('INVALID_API_KEY')) {
      return 'The Firebase Web API Key is incorrect.';
    }
    if (s.contains('PERMISSION_DENIED') ||
        s.contains('Permission denied') ||
        s.contains('403')) {
      return 'The database rules do not allow this account.';
    }
    if (s.contains('TOO_MANY_ATTEMPTS')) {
      return 'Too many attempts. Try again in a little while.';
    }
    if (error is TimeoutException) {
      return 'Connection timed out. Check the internet and try again.';
    }
    if (isTransientNetworkError(error)) {
      return 'The phone\'s internet connection was interrupted. Stay on one network (Wi-Fi or mobile data) and try again.';
    }
    // Never show a login token or API key that a request URL may contain.
    return s
        .replaceFirst('Exception: ', '')
        .replaceFirst('FormatException: ', '')
        .replaceAll(RegExp(r'(auth|key|access_token)=[^&\s,)]+'), r'$1=…');
  }

  /// A brief network drop on the phone (Wi-Fi/mobile switch, weak signal),
  /// not a Firebase answer; the request may simply be repeated.
  static bool isTransientNetworkError(Object error) {
    if (error is TimeoutException) return true;
    final s = error.toString();
    return s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('HandshakeException') ||
        s.contains('Connection closed') ||
        s.contains('Connection reset');
  }

  static Future<Map<String, dynamic>> _decode(http.Response r) async {
    final decoded = jsonDecode(r.body);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(
        decoded is Map
            ? (decoded['error'] is Map
                  ? decoded['error']['message']
                  : decoded['error'])
            : 'Firebase ${r.statusCode}',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// Signs in. With [remember] false the login is kept only in memory until
  /// [rememberLogin] is called (used while a Firebase change is unconfirmed).
  static Future<void> signIn(
    AppConfig config,
    String email,
    String password, {
    bool remember = true,
  }) async {
    final project = validateDatabaseUrl(config.firebaseDatabaseUrl);
    if (config.firebaseApiKey.trim().isEmpty ||
        email.trim().isEmpty ||
        password.isEmpty) {
      throw Exception('Enter the API Key, email and password.');
    }
    final data = await _decode(
      await http
          .post(
            Uri.https(
              'identitytoolkit.googleapis.com',
              '/v1/accounts:signInWithPassword',
              {'key': config.firebaseApiKey.trim()},
            ),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email.trim(),
              'password': password,
              'returnSecureToken': true,
            }),
          )
          .timeout(const Duration(seconds: 15)),
    );
    _sessions[_sessionKey(project, email)] = _Session(
      data['idToken'] as String,
      data['refreshToken'] as String,
      data['localId'] as String,
      DateTime.now().add(
        Duration(seconds: int.parse(data['expiresIn'].toString()) - 60),
      ),
    );
    config.firebaseEmail = email.trim();
    if (remember) await rememberLogin(config);
  }

  /// Checks everything a user's own Firebase needs, one item at a time, and
  /// says what to fix. Read-only: nothing is written to the database and no
  /// account is created; the login stays in memory only.
  static Future<List<FirebaseCheck>> checkConnection(
    AppConfig config,
    String email,
    String password,
  ) async {
    final rows = <FirebaseCheck>[];
    final String base;
    try {
      base = validateDatabaseUrl(config.firebaseDatabaseUrl);
      rows.add(const FirebaseCheck('Database URL format', true, ''));
    } catch (_) {
      rows.add(
        const FirebaseCheck(
          'Database URL format',
          false,
          'Enter https://…firebaseio.com or https://…firebasedatabase.app (copy it from the Realtime Database page).',
        ),
      );
      return rows;
    }

    try {
      final r = await http
          .get(Uri.parse('$base/.json?shallow=true'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 401) {
        rows.add(
          const FirebaseCheck('Realtime Database found', true, ''),
        );
        rows.add(const FirebaseCheck('Closed to the public', true, ''));
      } else if (r.statusCode == 200) {
        rows.add(
          const FirebaseCheck('Realtime Database found', true, ''),
        );
        rows.add(
          const FirebaseCheck(
            'Closed to the public',
            false,
            'The database is open to everyone. Copy the rules from the setup guide and Publish them in the Rules tab.',
          ),
        );
      } else {
        rows.add(
          FirebaseCheck(
            'Realtime Database found',
            false,
            'Database not created or wrong URL (HTTP ${r.statusCode}). Copy the URL from Firebase Console → Realtime Database.',
          ),
        );
        return rows;
      }
    } catch (_) {
      rows.add(
        const FirebaseCheck(
          'Realtime Database found',
          false,
          'Could not reach the database. Check the internet and the URL.',
        ),
      );
      return rows;
    }

    final key = config.firebaseApiKey.trim();
    if (key.isEmpty || email.trim().isEmpty || password.isEmpty) {
      rows.add(
        const FirebaseCheck(
          'Web API Key and sign-in',
          false,
          'Enter the Web API Key, Authentication email and password.',
        ),
      );
      return rows;
    }
    final login = await http
        .post(
          Uri.https(
            'identitytoolkit.googleapis.com',
            '/v1/accounts:signInWithPassword',
            {'key': key},
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (login.statusCode != 200) {
      final error = login.body;
      if (error.contains('API_KEY_INVALID') ||
          error.contains('INVALID_API_KEY') ||
          error.contains('API key not valid')) {
        rows.add(
          const FirebaseCheck(
            'Web API Key',
            false,
            'Copy the apiKey from Project settings → General → Web app config.',
          ),
        );
      } else if (error.contains('OPERATION_NOT_ALLOWED')) {
        rows.add(const FirebaseCheck('Web API Key', true, ''));
        rows.add(
          const FirebaseCheck(
            'Email/Password sign-in enabled',
            false,
            'Enable Email/Password in Authentication → Sign-in method.',
          ),
        );
      } else if (error.contains('TOO_MANY_ATTEMPTS')) {
        rows.add(
          const FirebaseCheck(
            'Authentication login',
            false,
            'Too many attempts. Check again in a little while.',
          ),
        );
      } else {
        rows.add(const FirebaseCheck('Web API Key', true, ''));
        rows.add(
          const FirebaseCheck(
            'Authentication email and password',
            false,
            'Wrong email or password. Check that this account exists in Authentication → Users (not your Google login password).',
          ),
        );
      }
      return rows;
    }
    final data = Map<String, dynamic>.from(jsonDecode(login.body) as Map);
    final project = base;
    final session = _Session(
      data['idToken'] as String,
      data['refreshToken'] as String,
      data['localId'] as String,
      DateTime.now().add(
        Duration(seconds: int.parse(data['expiresIn'].toString()) - 60),
      ),
    );
    _sessions[_sessionKey(project, email)] = session;
    rows.add(const FirebaseCheck('Web API Key', true, ''));
    rows.add(const FirebaseCheck('Authentication email and password', true, ''));

    // The login token names its project; a default database URL names one too.
    String audience = '';
    try {
      final part = session.token.split('.')[1];
      audience =
          (jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(part))),
          ) as Map)['aud']?.toString() ??
          '';
    } catch (_) {}
    final instance = RegExp(r'^(.+)-default-rtdb\.')
        .firstMatch(Uri.parse(base).host)
        ?.group(1);
    if (instance == null || audience.isEmpty) {
      rows.add(
        const FirebaseCheck(
          'API Key and Database from the same project',
          null,
          'Custom-named database; could not be confirmed.',
        ),
      );
    } else if (instance != audience) {
      rows.add(
        FirebaseCheck(
          'API Key and Database from the same project',
          false,
          'The API Key is from project "$audience" but the Database is "$instance". Use details from one project.',
        ),
      );
      return rows;
    } else {
      rows.add(
        const FirebaseCheck('API Key and Database from the same project', true, ''),
      );
    }

    final owners = await http
        .get(
          Uri.parse('$base/gateway_owners/${config.deviceId}.json')
              .replace(queryParameters: {'auth': session.token}),
        )
        .timeout(const Duration(seconds: 10));
    if (owners.statusCode != 200) {
      rows.add(
        const FirebaseCheck(
          'NoxBrain database rules',
          false,
          'Copy the rules from the setup guide and Publish them in Firebase Console → Realtime Database → Rules.',
        ),
      );
      return rows;
    }
    rows.add(const FirebaseCheck('NoxBrain database rules', true, ''));
    if (jsonDecode(owners.body) == session.uid) {
      // gateway_devices_pending exists only in the latest rules (re-setup
      // keeps the working gateway account until the new one is confirmed).
      final devices = await http
          .get(
            Uri.parse('$base/gateway_devices_pending/${config.deviceId}.json')
                .replace(queryParameters: {'auth': session.token}),
          )
          .timeout(const Duration(seconds: 10));
      rows.add(
        FirebaseCheck(
          'Gateway device permission (latest rules)',
          devices.statusCode == 200,
          devices.statusCode == 200
              ? ''
              : 'Old rules are in use. Publish the latest rules from the setup guide.',
        ),
      );
    } else {
      rows.add(
        const FirebaseCheck(
          'Gateway device permission (latest rules)',
          null,
          'Checked when the gateway is added.',
        ),
      );
    }
    rows.add(
      const FirebaseCheck(
        'New user sign-up enabled',
        null,
        'Checked when the gateway\'s own account is created.',
      ),
    );
    return rows;
  }

  /// Keeps the new project's login across an app restart while a remote
  /// Firebase change is unconfirmed (refresh token only).
  static Future<void> rememberPendingLogin(AppConfig config) async {
    final project = validateDatabaseUrl(config.firebaseDatabaseUrl);
    final session = _sessions[_sessionKey(project, config.firebaseEmail)];
    if (session == null) throw Exception('Firebase sign-in required.');
    final saved = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    await _vault.invokeMethod('save', {
      ...saved,
      'pending_login': {
        'project': project,
        'email': config.firebaseEmail.trim(),
        'refresh_token': session.refresh,
      },
    });
  }

  /// The pending login becomes the saved one (change confirmed).
  static Future<void> promotePendingLogin(AppConfig config) async {
    await _session(config); // Renews from the pending login if needed.
    await rememberLogin(config);
    await dropPendingLogin();
  }

  static Future<void> dropPendingLogin() async {
    final saved = Map<String, dynamic>.from(
      await _vault.invokeMapMethod<String, dynamic>('load') ?? {},
    );
    if (saved.remove('pending_login') != null) {
      await _vault.invokeMethod('save', saved);
    }
  }

  /// Makes this project's in-memory login the saved one for app restarts.
  /// Only the refresh token is kept; the owner's password is never stored.
  static Future<void> rememberLogin(AppConfig config) async {
    final project = validateDatabaseUrl(config.firebaseDatabaseUrl);
    final session = _sessions[_sessionKey(project, config.firebaseEmail)];
    if (session == null) throw Exception('Firebase sign-in required.');
    final previous = Map<String, dynamic>.from(
      await _vault.invokeMapMethod<String, dynamic>('load') ?? {},
    )..remove('password'); // Older versions stored it; drop it.
    await _vault.invokeMethod('save', {
      ...previous,
      'project': project,
      'email': config.firebaseEmail.trim(),
      'refresh_token': session.refresh,
    });
  }

  /// Creates (or re-verifies) a separate Firebase account used only by this
  /// gateway, and registers it under gateway_devices/{id}. The owner's own
  /// login is never sent to the ESP32. Requires Internet.
  static Future<void> prepareDeviceAccount(AppConfig config) async {
    final project = validateDatabaseUrl(config.firebaseDatabaseUrl);
    final key = config.firebaseApiKey.trim();
    final saved = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    final accounts = Map<String, dynamic>.from(
      saved['device_accounts'] as Map? ?? {},
    );
    final existing = accounts[config.deviceId] is Map
        ? Map<String, dynamic>.from(accounts[config.deviceId] as Map)
        : null;
    String? uid;
    String email = '', password = '';
    if (existing != null && existing['project'] == project) {
      email = existing['email']?.toString() ?? '';
      password = existing['password']?.toString() ?? '';
      final r = await http
          .post(
            Uri.https(
              'identitytoolkit.googleapis.com',
              '/v1/accounts:signInWithPassword',
              {'key': key},
            ),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
              'returnSecureToken': true,
            }),
          )
          .timeout(const Duration(seconds: 15));
      // A deleted or disabled device account is simply replaced below.
      if (r.statusCode == 200) {
        uid = (jsonDecode(r.body) as Map)['localId']?.toString();
      }
    }
    if (uid == null) {
      final random = Random.secure();
      String hex(int n) =>
          List.generate(n, (_) => random.nextInt(16).toRadixString(16)).join();
      // example.com is reserved (RFC 2606); this address never receives mail.
      email = 'gw-${config.deviceId.toLowerCase()}-${hex(8)}@example.com';
      password = hex(40);
      final data = await _decode(
        await http
            .post(
              Uri.https(
                'identitytoolkit.googleapis.com',
                '/v1/accounts:signUp',
                {'key': key},
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'email': email,
                'password': password,
                'returnSecureToken': true,
              }),
            )
            .timeout(const Duration(seconds: 15)),
      );
      uid = data['localId'] as String;
    }
    // A gateway that already works keeps its registered account until the
    // new one is confirmed by the handover: the new account goes to
    // gateway_devices_pending first, so a failed re-setup never takes the
    // gateway offline. A new gateway (nothing registered) is registered
    // directly, as before.
    final current = await http
        .get(await databaseUri(config, '/gateway_devices/${config.deviceId}'))
        .timeout(const Duration(seconds: 10));
    if (current.statusCode != 200) {
      throw Exception(
        'The gateway permission could not be read. Publish the latest database rules from the setup guide.',
      );
    }
    final registered = jsonDecode(current.body);
    final pending = registered is String && registered.isNotEmpty && registered != uid;
    final r = await http
        .put(
          await databaseUri(
            config,
            pending
                ? '/gateway_devices_pending/${config.deviceId}'
                : '/gateway_devices/${config.deviceId}',
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(uid),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception(
        'The gateway device account was not given permission. Publish the latest database rules from the setup guide.',
      );
    }
    accounts[config.deviceId] = {
      'project': project,
      'email': email,
      'password': password,
      'uid': uid,
      // Set only when the gateway confirmed the handover with this account.
      'handover_confirmed': false,
    };
    final latest = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    await _vault.invokeMethod('save', {...latest, 'device_accounts': accounts});
  }

  /// Reads the gateway's own device login from the encrypted vault. Works
  /// offline, while the phone is joined to the gateway setup network.
  static Future<Map<String, String>> deviceCredentials(AppConfig config) async {
    final data = await _vault.invokeMapMethod<String, dynamic>('load');
    final account = (data?['device_accounts'] as Map?)?[config.deviceId];
    if (account is! Map ||
        account['project'] != validateDatabaseUrl(config.firebaseDatabaseUrl)) {
      throw Exception(
        'The gateway device account is not ready. Check the gateway permission again over the internet.',
      );
    }
    return {
      'email': account['email'].toString(),
      'password': account['password'].toString(),
    };
  }

  static Future<String> token(AppConfig config) async =>
      (await _session(config)).token;

  /// Firebase user ID of the signed-in owner for this project.
  static Future<String> uid(AppConfig config) async =>
      (await _session(config)).uid;

  static Future<_Session> _session(AppConfig config) async {
    final project = validateDatabaseUrl(config.firebaseDatabaseUrl);
    final key = _sessionKey(project, config.firebaseEmail);
    final current = _sessions[key];
    if (current != null && DateTime.now().isBefore(current.expires)) {
      return current;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _renew(config, project, key, current);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  static Future<_Session> _renew(
    AppConfig config,
    String project,
    String key,
    _Session? current,
  ) async {
    final saved = await _vault.invokeMapMethod<String, dynamic>('load');
    final savedHere =
        saved != null &&
        saved['project'] == project &&
        saved['email'] == config.firebaseEmail.trim();
    final pending = saved?['pending_login'];
    final pendingHere =
        pending is Map &&
        pending['project'] == project &&
        pending['email'] == config.firebaseEmail.trim();
    final refresh =
        current?.refresh ??
        (savedHere
            ? saved['refresh_token'] as String?
            : (pendingHere ? pending['refresh_token'] as String? : null));
    if (refresh == null) {
      throw Exception('Firebase sign-in required. Open setup and check it.');
    }
    final data = await _decode(
      await http
          .post(
            Uri.https('securetoken.googleapis.com', '/v1/token', {
              'key': config.firebaseApiKey.trim(),
            }),
            body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
          )
          .timeout(const Duration(seconds: 15)),
    );
    final session = _Session(
      data['id_token'] as String,
      data['refresh_token'] as String,
      data['user_id'] as String,
      DateTime.now().add(
        Duration(seconds: int.parse(data['expires_in'].toString()) - 60),
      ),
    );
    _sessions[key] = session;
    if (savedHere) {
      await _vault.invokeMethod('save', {
        ...saved,
        'refresh_token': session.refresh,
      });
    } else if (pendingHere) {
      await _vault.invokeMethod('save', {
        ...?saved,
        'pending_login': {...pending, 'refresh_token': session.refresh},
      });
    }
    return session;
  }

  /// Re-checks the owner's password for dangerous actions (gateway factory
  /// reset, deleting cloud data). Nothing is stored.
  static Future<void> verifyOwnerPassword(
    AppConfig config,
    String password,
  ) async {
    final r = await http
        .post(
          Uri.https(
            'identitytoolkit.googleapis.com',
            '/v1/accounts:signInWithPassword',
            {'key': config.firebaseApiKey.trim()},
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': config.firebaseEmail.trim(),
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final data = await _decode(r);
    if (data['localId'] != await uid(config)) {
      throw Exception('This account does not own this gateway.');
    }
  }

  /// Deletes the gateway's own Firebase Authentication account (used after
  /// all of its cloud data is deleted) and forgets its local copy.
  static Future<void> deleteDeviceAccount(AppConfig config) async {
    final saved = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    final accounts = Map<String, dynamic>.from(
      saved['device_accounts'] as Map? ?? {},
    );
    final account = accounts[config.deviceId];
    if (account is Map) {
      try {
        final login = await http
            .post(
              Uri.https(
                'identitytoolkit.googleapis.com',
                '/v1/accounts:signInWithPassword',
                {'key': config.firebaseApiKey.trim()},
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'email': account['email'],
                'password': account['password'],
                'returnSecureToken': true,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (login.statusCode == 200) {
          final token = (jsonDecode(login.body) as Map)['idToken'];
          await http
              .post(
                Uri.https(
                  'identitytoolkit.googleapis.com',
                  '/v1/accounts:delete',
                  {'key': config.firebaseApiKey.trim()},
                ),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'idToken': token}),
              )
              .timeout(const Duration(seconds: 15));
        }
      } catch (_) {
        // The account is already powerless without gateway_devices.
      }
      accounts.remove(config.deviceId);
      await _vault.invokeMethod('save', {
        ...saved,
        'device_accounts': accounts,
      });
    }
  }

  /// Full app reset / logout: forget every login, token and device account
  /// on this phone. Cloud data and the gateway are not touched.
  static Future<void> forgetEverything() async {
    _sessions.clear();
    _pending.clear();
    await _vault.invokeMethod('clear');
  }

  static void invalidate() {
    for (final session in _sessions.values) {
      session.expires = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  static Future<void> checkOwnershipAccess(AppConfig config) async {
    final r = await http
        .get(await databaseUri(config, '/gateway_owners/${config.deviceId}'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception(
        'Database access not confirmed. Check the rules from the setup guide.',
      );
    }
  }

  static Future<void> claimGateway(AppConfig config) async {
    final uri = await databaseUri(config, '/gateway_owners/${config.deviceId}');
    final r = await http
        .get(uri, headers: {'X-Firebase-ETag': 'true'})
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception(
        'Could not read the gateway ownership. Use the database rules from the setup guide.',
      );
    }
    final owner = jsonDecode(r.body);
    final me = await uid(config);
    if (owner == me) return;
    if (owner != null) {
      throw Exception(
        'This gateway ID belongs to another account. Set up with a new gateway ID.',
      );
    }
    final etag = r.headers['etag'];
    if (etag == null) throw Exception('Could not confirm the database ownership.');
    final write = await http
        .put(
          uri,
          headers: {'Content-Type': 'application/json', 'if-match': etag},
          body: jsonEncode(me),
        )
        .timeout(const Duration(seconds: 10));
    if (write.statusCode != 200) {
      throw Exception(
        'The gateway ownership was not saved. Check the rules or another account\'s claim.',
      );
    }
  }

  /// Records that the gateway confirmed the handover with this phone's
  /// device account (it saved those credentials), so promotion is allowed.
  static Future<void> markHandoverConfirmed(AppConfig config) async {
    final saved = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    final accounts = Map<String, dynamic>.from(
      saved['device_accounts'] as Map? ?? {},
    );
    final account = accounts[config.deviceId];
    if (account is! Map) return;
    accounts[config.deviceId] = {
      ...Map<String, dynamic>.from(account),
      'handover_confirmed': true,
    };
    await _vault.invokeMethod('save', {...saved, 'device_accounts': accounts});
  }

  /// After a confirmed handover: the gateway now runs with the account that
  /// was waiting in gateway_devices_pending, so make it the registered one
  /// and clear the pending slot. Safe to repeat; until it runs, the rules
  /// accept the pending account, so the gateway stays online either way.
  static Future<void> promotePendingDeviceAccount(AppConfig config) async {
    final pendingUri = await databaseUri(
      config,
      '/gateway_devices_pending/${config.deviceId}',
    );
    final pending = await http
        .get(pendingUri)
        .timeout(const Duration(seconds: 10));
    if (pending.statusCode != 200) return;
    final uid = jsonDecode(pending.body);
    if (uid is! String || uid.isEmpty) return;
    final saved = await _vault.invokeMapMethod<String, dynamic>('load') ?? {};
    final account = (saved['device_accounts'] as Map?)?[config.deviceId];
    // Only the account this phone handed to the gateway, and only after the
    // gateway confirmed the handover with it, is promoted.
    if (account is! Map ||
        account['uid'] != uid ||
        account['handover_confirmed'] != true) {
      return;
    }
    final set = await http
        .put(
          await databaseUri(config, '/gateway_devices/${config.deviceId}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(uid),
        )
        .timeout(const Duration(seconds: 10));
    if (set.statusCode != 200) return;
    await http.delete(pendingUri).timeout(const Duration(seconds: 10));
  }

  static Future<Uri> databaseUri(AppConfig config, String path) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(config.deviceId)) {
      throw Exception('Invalid gateway device ID.');
    }
    final base = validateDatabaseUrl(config.firebaseDatabaseUrl);
    return Uri.parse('$base$path.json')
        .replace(queryParameters: {'auth': await token(config)});
  }
}
