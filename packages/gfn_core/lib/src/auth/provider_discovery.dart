import 'dart:convert' show JsonDecoder;

import 'package:http/http.dart' as http;

import '../models/auth.dart' show LoginProvider;
import '../ports.dart' show Clock;
import 'constants.dart' show defaultProvider, serviceUrlsEndpoint;

// Port of auth/providerDiscovery.ts

LoginProvider normalizeProvider(LoginProvider provider) {
  final url = provider.streamingServiceUrl.endsWith('/')
      ? provider.streamingServiceUrl
      : '${provider.streamingServiceUrl}/';
  return LoginProvider(
    idpId: provider.idpId,
    code: provider.code,
    displayName: provider.displayName,
    streamingServiceUrl: url,
    priority: provider.priority,
  );
}

class ProviderDiscovery {
  final http.Client client;
  final bool isMac;
  final Clock clock;
  List<LoginProvider>? _providers;
  int _lastFetchMs = 0;
  static const _cacheTtlMs = 5 * 60 * 1000;

  ProviderDiscovery({
    required this.client,
    required this.isMac,
    required this.clock,
  });

  Future<List<LoginProvider>> getProviders() async {
    final cached = _providers;
    if (cached != null && clock.nowMillis() - _lastFetchMs < _cacheTtlMs) {
      return cached;
    }

    try {
      final response = await client.get(
        Uri.parse(serviceUrlsEndpoint),
        headers: {
          'Accept': 'application/json',
          'User-Agent': _userAgent(),
        },
      );
      if (response.statusCode != 200) {
        return _fallback();
      }

      final decoded = const JsonDecoder().convert(response.body);
      final gfnServiceInfo =
          decoded is Map ? decoded['gfnServiceInfo'] : null;
      final endpoints = gfnServiceInfo is Map
          ? gfnServiceInfo['gfnServiceEndpoints']
          : null;
      if (endpoints is! List || endpoints.isEmpty) {
        return _fallback();
      }

      final providers = endpoints
          .whereType<Map<String, dynamic>>()
          .map((entry) {
            final code = entry['loginProviderCode'] as String? ?? '';
            return LoginProvider(
              idpId: entry['idpId'] as String? ?? '',
              code: code,
              displayName: code == 'BPC'
                  ? 'bro.game'
                  : entry['loginProviderDisplayName'] as String? ?? code,
              streamingServiceUrl: entry['streamingServiceUrl'] as String? ?? '',
              priority: (entry['loginProviderPriority'] as num?)?.toInt() ?? 0,
            );
          })
          .toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));
      for (var i = 0; i < providers.length; i++) {
        providers[i] = normalizeProvider(providers[i]);
      }

      _providers = providers.isNotEmpty ? providers : _fallback();
      _lastFetchMs = clock.nowMillis();
      return _providers!;
    } catch (_) {
      return _fallback();
    }
  }

  Future<LoginProvider> selectProvider({
    LoginProvider? selectedProvider,
    String? providerIdpId,
  }) async {
    final providers = await getProviders();
    LoginProvider? selected;
    if (providerIdpId != null) {
      for (final p in providers) {
        if (p.idpId == providerIdpId) {
          selected = p;
          break;
        }
      }
    }
    selected ??= selectedProvider;
    selected ??= providers.isNotEmpty ? providers[0] : null;
    selected ??= defaultProvider();
    return normalizeProvider(selected);
  }

  List<LoginProvider> _fallback() {
    final fallback = [defaultProvider()];
    _providers = fallback;
    _lastFetchMs = clock.nowMillis();
    return fallback;
  }

  String _userAgent() {
    return isMac
        ? 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173'
        : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 '
            'NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173';
  }
}