import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app.dart';
import 'state/session_controller.dart';
import 'state/user_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DebugShellApp());
}

/// App-scoped service container. Built once, held by the root widget.
class AppServices {
  final AuthService auth;
  final CatalogService catalog;
  final CloudMatchService cloudMatch;
  final PrintedWasteService printedWaste;
  final SubscriptionService subscription;
  final UserSettings settings;
  final SessionController session;
  final RingBufferLogSink logSink;
  final SharedPreferences prefs;

  SubscriptionInfo? _subscription;

  AppServices._({
    required this.auth,
    required this.catalog,
    required this.cloudMatch,
    required this.printedWaste,
    required this.subscription,
    required this.settings,
    required this.session,
    required this.logSink,
    required this.prefs,
  });

  /// Fetch the user's GFN subscription (tier, hours, entitled resolutions),
  /// caching it for the lifetime of the app.
  Future<SubscriptionInfo?> loadSubscription() async {
    final cached = _subscription;
    if (cached != null) return cached;
    try {
      final session = await auth.ensureValidSession();
      if (session == null) return null;
      final token = session.tokens.idToken ?? session.tokens.accessToken;
      final info = await subscription.fetchSubscription(
        token: token,
        userId: session.user.userId,
      );
      _subscription = info;
      return info;
    } catch (e) {
      debugPrint('[subscription] load failed: $e');
      return null;
    }
  }

  static Future<AppServices> create() async {
    final prefs = await SharedPreferences.getInstance();
    final logSink = RingBufferLogSink(maxEntries: 500);

    final client = _LoggingHttpClient(logSink: logSink);

    final storage = _PrefsTokenStorage(prefs);
    final browser = _UrlLauncherBrowser();
    final clock = _SystemClock();
    final random = _SecureRandom();
    final isMac = Platform.isMacOS;

    final auth = AuthService(
      deps: AuthServiceDeps(
        httpClient: client,
        tokenStorage: storage,
        browserLauncher: browser,
        clock: clock,
        random: random,
        hostname: Platform.localHostname,
        username: Platform.environment['USER'] ?? 'unknown',
        isMac: isMac,
      ),
    );
    await auth.initialize();

    final catalog = CatalogService(client: client, isMac: isMac);
    final cloudMatch = CloudMatchService(
      client: client,
      isMac: isMac,
      stableDeviceId: () => _stableDeviceId(prefs),
    );
    final printedWaste = PrintedWasteService(
      client: client,
      appVersion: '0.5.3',
    );
    final subscription = SubscriptionService(client: client, isMac: isMac);

    final settings = UserSettings(prefs);
    final session = SessionController(
      cloudMatch: cloudMatch,
      getToken: () => auth.resolveJwtToken(),
    );

    return AppServices._(
      auth: auth,
      catalog: catalog,
      cloudMatch: cloudMatch,
      printedWaste: printedWaste,
      subscription: subscription,
      settings: settings,
      session: session,
      logSink: logSink,
      prefs: prefs,
    );
  }

  static String _stableDeviceId(SharedPreferences prefs) {
    final persisted = prefs.getString('gfn-device-id');
    if (persisted != null && persisted.isNotEmpty) return persisted;
    final generated = generateDeviceId(
      hostname: Platform.localHostname,
      username: Platform.environment['USER'] ?? 'unknown',
    );
    prefs.setString('gfn-device-id', generated);
    return generated;
  }
}

class _PrefsTokenStorage implements TokenStorage {
  static const _key = 'gfn_tokens';
  final SharedPreferences prefs;

  _PrefsTokenStorage(this.prefs);

  @override
  Future<Map<String, String>?> readTokens() async {
    final json = prefs.getString(_key);
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded.map((k, v) => MapEntry(k, v.toString()));
  }

  @override
  Future<void> writeTokens(Map<String, String> tokens) async {
    await prefs.setString(_key, jsonEncode(tokens));
  }

  @override
  Future<void> clearTokens() async {
    await prefs.remove(_key);
  }
}

class _UrlLauncherBrowser implements BrowserLauncher {
  @override
  Future<void> openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

class _SystemClock implements Clock {
  @override
  int nowMillis() => DateTime.now().millisecondsSinceEpoch;
}

class _SecureRandom implements RandomSource {
  final _random = Random.secure();

  @override
  List<int> nextBytes(int count) {
    return List<int>.generate(count, (_) => _random.nextInt(256));
  }
}

/// HTTP client wrapper that logs requests/responses to the ring buffer.
class _LoggingHttpClient extends http.BaseClient {
  final RingBufferLogSink logSink;
  final _inner = http.Client();

  _LoggingHttpClient({required this.logSink});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final started = DateTime.now();
    logSink.log(LogLevel.debug, 'http', '${request.method} ${request.url}');
    final response = await _inner.send(request);
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    logSink.log(
      LogLevel.info,
      'http',
      '${request.method} ${request.url} -> ${response.statusCode} (${elapsed}ms)',
    );
    return response;
  }
}
