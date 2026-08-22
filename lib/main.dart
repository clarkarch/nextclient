import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show File, Platform;
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show WebRTC;
import 'package:fvp/fvp.dart' as fvp;
import 'package:gfn_core/gfn_core.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointer_lock/pointer_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'state/session_controller.dart';
import 'state/user_settings.dart';
import 'theme/neon.dart';

/// Set by the stream page while a stream is live. Invoked when the OS asks
/// the window to close (Alt+F4 / WM close / title-bar X) so the cloud session,
/// transports, pointer lock and OS fullscreen are torn down while the engine
/// is still alive — closing the window under the active native video stack
/// crashes the Linux engine (SIGSEGV, corrupted double-linked list).
Future<void> Function()? appCloseHook;

/// Opaque owner token for [appCloseHook]: only the page that installed the
/// hook clears it, so a popped page can't clobber a newer page's hook.
Object? appCloseOwner;

/// True once a window-close is being handled, so the "close" event re-emitted
/// by [WindowManager.destroy] (Linux/Windows re-fire it while the window goes
/// away) can't re-enter the handler.
bool _windowClosing = false;

/// Listens for the native window close request (Alt+F4 / WM close / X) and
/// runs the app's teardown before the engine dies.
final _closeWindowListener = _WindowCloseListener();

class _WindowCloseListener with WindowListener {
  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }
}

Future<void> _handleWindowClose() async {
  if (_windowClosing) return;
  _windowClosing = true;
  try {
    // Tear the stream down (stop session, dispose transports, leave
    // fullscreen + pointer lock). Capped so a hung server call can't keep
    // the window open forever.
    final hook = appCloseHook;
    if (hook != null) {
      await Future.any<void>([
        hook(),
        Future<void>.delayed(const Duration(seconds: 3)),
      ]);
    }
  } catch (_) {
    // Never let a teardown failure keep the window open.
  } finally {
    windowManager.removeListener(_closeWindowListener);
    try {
      await windowManager.destroy();
    } catch (_) {
      // The engine is going down regardless.
    }
  }
}

/// Intercepts the native window close so the app's teardown runs before the
/// engine dies. Must be called after [WindowManager.ensureInitialized].
Future<void> installWindowCloseHandler() async {
  await windowManager.setPreventClose(true);
  windowManager.addListener(_closeWindowListener);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use the fvp (libmdk) backend for video_player so ads/creative play on
  // Windows, Linux, macOS, iOS. Official video_player has no desktop
  // implementation; fvp supplies it. On Android the platform plugin already
  // handles video_player natively — registering fvp there just loads the
  // libmdk .so for no gain and adds cold-start / memory overhead.
  if (!Platform.isAndroid) {
    fvp.registerWith();
  }
  // Desktop-only plugins (pointer lock, window management). Guarded so the
  // app boots on mobile/web where the plugins have no implementation — an
  // unguarded await throws MissingPluginException before runApp and the app
  // never renders.
  final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  if (isDesktop) {
    // Restores the OS cursor after a hot restart during development (pointer
    // lock plugin requirement).
    await pointerLock.ensureInitialized();
    // Desktop window management (hide title bar). No-op on unsupported
    // platforms.
    await windowManager.ensureInitialized();
    // Intercept window close (Alt+F4 / WM close / title-bar X) so the cloud
    // session and native transports are torn down gracefully BEFORE the
    // window actually closes. Closing the window mid-stream destroys the
    // engine under the live native video stack, which crashes on Linux
    // (SIGSEGV / corrupted double-linked list).
    await installWindowCloseHandler();
  } else {
    // Solid system bars (Android/iOS): the app content never renders behind
    // the status bar / nav bar. The stream page flips to immersive
    // (true fullscreen, bars hidden) while in-game and restores them after.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Neon.bgA,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Neon.bgA,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
  }
  // Android streaming: initialize the WebRTC plugin explicitly so field
  // trials apply before any PeerConnectionFactory exists. ZeroPlayoutDelay
  // (opt-in, Settings > Performance) renders frames the moment they decode
  // when the server advertises the playout-delay extension — lowest render
  // delay, at the cost of some smoothing under bursty jitter.
  if (Platform.isAndroid) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final zeroPlayoutDelay =
          prefs.getBool(UserSettings.zeroPlayoutDelayPrefKey) ?? false;
      await WebRTC.initialize(
        options: {
          'fieldTrials': zeroPlayoutDelay
              ? 'WebRTC-ZeroPlayoutDelay/Enabled/'
              : '',
        },
      );
    } catch (_) {
      // Plugin self-initializes with defaults on failure.
    }
  }
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
  final CompositeLogSink logSink;
  final SharedPreferences prefs;

  /// The file log path, when file logging is available (otherwise null).
  final String? logFilePath;

  /// The file sink inside [logSink], used to flush on app exit.
  final FileLogSink? _fileLogSink;

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
    this.logFilePath,
    this._fileLogSink,
  });

  /// Flushes the disk log file (used at app exit so the tail is persisted).
  Future<void> flushLogs() => _fileLogSink?.flush() ?? Future.value();

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
      logSink.log(
        LogLevel.info,
        'subscription',
        'Subscription loaded: tier=${info.membershipTier}',
      );
      return info;
    } catch (e) {
      debugPrint('[subscription] load failed: $e');
      logSink.log(LogLevel.warn, 'subscription', 'Load failed: $e');
      return null;
    }
  }

  static Future<AppServices> create() async {
    final prefs = await SharedPreferences.getInstance();
    final (logSink, fileLogSink, logFilePath) = await _buildLogSink();

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
    // Drive verbose logging from the Performance setting so the toggle applies
    // from launch (all sinks — memory, file, terminal — stay in sync).
    // Max-performance forces logs off regardless of the persisted toggle.
    logSink.setEnabledForAll(settings.effectiveLogsEnabled);
    // Keep the sink in sync when max-performance is toggled mid-run (the
    // toggle flips effectiveLogs without touching the raw persisted value).
    settings.addListener(() {
      logSink.setEnabledForAll(settings.effectiveLogsEnabled);
    });
    final session = SessionController(
      cloudMatch: cloudMatch,
      getToken: () => auth.resolveJwtToken(),
      log: logSink,
    );

    logSink.log(
      LogLevel.info,
      'app',
      'AppServices ready — session ${session.state.name}, '
          'background ${settings.effectiveBackgroundStyle.label}, '
          'logs ${settings.effectiveLogsEnabled ? 'enabled' : 'disabled'}'
          '${settings.maxPerformanceMode ? ' · max-performance ENGAGED' : ''}',
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
      logFilePath: logFilePath,
      fileLogSink: fileLogSink,
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

  /// Builds the log pipeline: an in-memory ring buffer (for the Logs viewer),
  /// a terminal sink (stdout), and a file sink (persisted to disk).
  ///
  /// Returns the composite sink plus the file sink/path (null when file
  /// logging is unavailable, e.g. the platform can't provide a directory).
  static Future<(CompositeLogSink, FileLogSink?, String?)>
  _buildLogSink() async {
    final ring = RingBufferLogSink(maxEntries: 500);
    final sinks = <LogSink>[ring, TerminalLogSink()];
    FileLogSink? fileSink;
    String? logPath;

    try {
      final dir = await getApplicationSupportDirectory();
      final logFile = File('${dir.path}/next_client.log');
      fileSink = FileLogSink(logFile);
      logPath = logFile.path;
      sinks.add(fileSink);
      ring.log(LogLevel.info, 'app', 'Log file: $logPath');
    } catch (e) {
      ring.log(
        LogLevel.warn,
        'app',
        'File logging unavailable (logging to memory + terminal only): $e',
      );
    }

    return (CompositeLogSink(sinks), fileSink, logPath);
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
///
/// Only method + a scrubbed URL are recorded: sensitive query parameters
/// (user/session/device identifiers) are replaced with explicit redaction
/// markers so copied logs never leak them.
class _LoggingHttpClient extends http.BaseClient {
  final CompositeLogSink logSink;
  final _inner = http.Client();

  _LoggingHttpClient({required this.logSink});

  /// Query parameters whose values are never logged.
  static const _sensitiveQueryParams = {
    'token',
    'access_token',
    'refresh_token',
    'id_token',
    'code',
    'userId',
    'huId',
    'vpcId',
    'sessionId',
    'session_id',
    'pairing_id',
    'peer_id',
    'deviceId',
    'device_id',
    'clientId',
    'client_id',
    'subSessionId',
    'uuid',
  };

  static String _scrubUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.queryParameters.isEmpty) return raw;
    final scrubbed = <String, String>{
      for (final entry in uri.queryParameters.entries)
        if (_sensitiveQueryParams.contains(entry.key.toLowerCase()))
          entry.key: '[REDACTED]'
        else
          entry.key: entry.value,
    };
    return uri.replace(queryParameters: scrubbed).toString();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final started = DateTime.now();
    final url = _scrubUrl(request.url.toString());
    logSink.log(LogLevel.debug, 'http', '${request.method} $url');
    final response = await _inner.send(request);
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    logSink.log(
      LogLevel.info,
      'http',
      '${request.method} $url -> ${response.statusCode} (${elapsed}ms)',
    );
    return response;
  }
}
