import 'dart:convert' show jsonDecode;

import 'package:http/http.dart' as http;

import '../http/client.dart'
    show
        GfnCloudMatchHeadersOptions,
        buildGfnCloudMatchHeaders,
        normalizeCloudMatchBaseUrl;

// Port of cloudmatchTransport.ts

const cloudmatchRequestTimeoutMs = 30000;
const cloudmatchGetRetries = 2;
const cloudmatchRetryDelaysMs = [250, 750];
const cloudmatchRetryStatuses = {408, 425, 429, 500, 502, 503, 504};

/// Port of cloudmatchTransport.ts fetchCloudMatch — GET retry + timeout.
Future<http.Response> fetchCloudMatch({
  required http.Client client,
  required String url,
  required String method,
  required Map<String, String> headers,
  String? body,
  int? timeoutMs,
  int? retries,
}) async {
  final effectiveMethod = method.toUpperCase();
  final effectiveRetries =
      retries ?? (effectiveMethod == 'GET' ? cloudmatchGetRetries : 0);
  final effectiveTimeout = timeoutMs ?? cloudmatchRequestTimeoutMs;

  Object? lastError;
  for (var attempt = 0; attempt <= effectiveRetries; attempt++) {
    try {
      final future = () {
        switch (effectiveMethod) {
          case 'GET':
            return client.get(Uri.parse(url), headers: headers);
          case 'POST':
            return client.post(
              Uri.parse(url),
              headers: headers,
              body: body,
            );
          case 'PUT':
            return client.put(Uri.parse(url), headers: headers, body: body);
          case 'DELETE':
            return client.delete(Uri.parse(url), headers: headers);
          default:
            return client.post(Uri.parse(url), headers: headers, body: body);
        }
      }();

      final response = await future.timeout(Duration(milliseconds: effectiveTimeout));

      if (attempt < effectiveRetries &&
          cloudmatchRetryStatuses.contains(response.statusCode)) {
        final retryDelay = cloudmatchRetryDelaysMs[
            attempt < cloudmatchRetryDelaysMs.length
                ? attempt
                : cloudmatchRetryDelaysMs.length - 1];
        await Future<void>.delayed(Duration(milliseconds: retryDelay));
        continue;
      }
      return response;
    } catch (error) {
      lastError = error;
      if (attempt >= effectiveRetries) rethrow;
      final delay = cloudmatchRetryDelaysMs[
          attempt < cloudmatchRetryDelaysMs.length
              ? attempt
              : cloudmatchRetryDelaysMs.length - 1];
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  throw lastError ?? StateError('CloudMatch request failed');
}

/// Port of cloudmatchTransport.ts resolveCreateSessionBase — if the base is the
/// default streaming service, discover the local region via /v2/serverInfo.
Future<String> resolveCreateSessionBase({
  required http.Client client,
  required String base,
  required String token,
  required String clientId,
  required String deviceId,
  required bool isMac,
}) async {
  if (!_isDefaultStreamingServiceBase(base)) return base;

  try {
    final response = await fetchCloudMatch(
      client: client,
      url: '$base/v2/serverInfo',
      method: 'GET',
      headers: buildGfnCloudMatchHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
          includeOrigin: false,
        ),
        isMac: isMac,
      ),
    );
    if (response.statusCode != 200) return base;

    final decoded = jsonDecode(response.body);
    final bases = extractServerInfoRegionBases(decoded);
    if (bases.isEmpty || bases.first == base) return base;
    return bases.first;
  } catch (_) {
    return base;
  }
}

/// Port of cloudmatchTransport.ts extractServerInfoRegionBases
List<String> extractServerInfoRegionBases(Map<String, dynamic> payload) {
  final metadata = payload['metaData'];
  if (metadata is! List) return const [];

  final byKey = <String, String>{};
  for (final entry in metadata) {
    if (entry is! Map) continue;
    final key = entry['key'];
    final value = entry['value'];
    if (key is String && value is String) byKey[key] = value;
  }

  final regionNames = (byKey['gfn-regions'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final localRegionName = byKey['local-region']?.trim();
  final orderedRegionNames = [
    if (localRegionName != null && localRegionName.isNotEmpty) localRegionName,
    ...regionNames,
  ];

  final bases = <String>[];
  final seen = <String>{};
  for (final regionName in orderedRegionNames) {
    final regionUrl = byKey[regionName];
    if (regionUrl == null || !regionUrl.startsWith('http')) continue;
    final normalized = normalizeCloudMatchBaseUrl(regionUrl);
    if (!seen.contains(normalized)) {
      seen.add(normalized);
      bases.add(normalized);
    }
  }
  return bases;
}

bool _isDefaultStreamingServiceBase(String baseUrl) {
  try {
    final hostname = Uri.parse(baseUrl).host.toLowerCase();
    return hostname == 'prod.cloudmatchbeta.nvidiagrid.net' ||
        (hostname.startsWith('prod.') &&
            hostname.endsWith('.nvidiagrid.net'));
  } catch (_) {
    return false;
  }
}