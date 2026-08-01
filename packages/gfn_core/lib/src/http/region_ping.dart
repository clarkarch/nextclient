import 'dart:io' show Socket;

import '../models/catalog.dart' show StreamRegion;

// Port of services/regionPing.ts

class PingResult {
  final String url;
  final int? pingMs;
  final String? error;

  const PingResult({required this.url, this.pingMs, this.error});
}

/// Port of tcpPing — measure TCP connect latency to host:port.
Future<int?> tcpPing(
  String hostname,
  int port, {
  int timeoutMs = 3000,
}) async {
  try {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(hostname, port,
        timeout: Duration(milliseconds: timeoutMs));
    await socket.close();
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

/// Port of pingRegions — warm-up + 3 measured TCP pings, averaged.
Future<List<PingResult>> pingRegions(List<StreamRegion> regions) async {
  final futures = regions.map((region) async {
    try {
      final uri = Uri.parse(region.url);
      final hostname = uri.host;
      final port = uri.scheme == 'https' ? 443 : 80;

      final validPings = <int>[];

      // Warm-up ping (discarded) to prime TCP path / DNS cache.
      await tcpPing(hostname, port);

      for (var i = 0; i < 3; i++) {
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final pingMs = await tcpPing(hostname, port);
        if (pingMs != null) validPings.add(pingMs);
      }

      if (validPings.isNotEmpty) {
        final avg = (validPings.reduce((a, b) => a + b) / validPings.length)
            .round();
        return PingResult(url: region.url, pingMs: avg);
      }
      return PingResult(url: region.url, error: 'All ping tests failed');
    } catch (_) {
      return PingResult(url: region.url, error: 'Invalid URL');
    }
  });

  return Future.wait(futures);
}