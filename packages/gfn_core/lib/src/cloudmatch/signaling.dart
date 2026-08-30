import '../models/cloudmatch_types.dart';
import '../models/session.dart';
import '../http/client.dart' show isZoneHostname;

// Port of cloudmatchSignaling.ts

const _readySessionStatuses = {2, 3};

bool isReadySessionStatus(int status) => _readySessionStatuses.contains(status);

/// Port of streamingServerIp — priority chain:
/// 1. connectionInfo[usage==14].ip
/// 2. host from connectionInfo[usage==14].resourcePath
/// 3. sessionControlInfo.ip
String? streamingServerIp(CloudMatchResponse response) {
  final connections = response.session.connectionInfo;
  CloudMatchConnectionInfo? sigConn;
  for (final conn in connections) {
    if (conn.usage == 14) {
      sigConn = conn;
      break;
    }
  }

  if (sigConn != null) {
    final directIp = sigConn.ip;
    if (directIp != null && directIp.isNotEmpty) return directIp;
    final resourcePath = sigConn.resourcePath;
    if (resourcePath != null) {
      final host = extractHostFromUrl(resourcePath);
      if (host != null) return host;
    }
  }

  final controlIp = response.session.serverIp;
  if (controlIp != null && controlIp.isNotEmpty) return controlIp;

  return null;
}

/// Port of extractHostFromUrl
String? extractHostFromUrl(String url) {
  const prefixes = ['rtsps://', 'rtsp://', 'wss://', 'https://'];
  String? afterProto;
  for (final prefix in prefixes) {
    if (url.startsWith(prefix)) {
      afterProto = url.substring(prefix.length);
      break;
    }
  }
  if (afterProto == null) return null;

  final host = afterProto.split(':').first.split('/').first;
  if (host.isEmpty || host.startsWith('.')) return null;
  return host;
}

class ResolvedSignaling {
  final String serverIp;
  final String signalingServer;
  final String signalingUrl;
  final MediaConnectionInfo? mediaConnectionInfo;
  final List<String> rtspsEndpoints;

  const ResolvedSignaling({
    required this.serverIp,
    required this.signalingServer,
    required this.signalingUrl,
    this.mediaConnectionInfo,
    this.rtspsEndpoints = const [],
  });
}

/// Port of resolveSignaling
ResolvedSignaling resolveSignaling(CloudMatchResponse response) {
  final connections = response.session.connectionInfo;

  CloudMatchConnectionInfo? signalingConnection;
  for (final conn in connections) {
    if (conn.usage == 14 && conn.ip != null) {
      signalingConnection = conn;
      break;
    }
  }
  signalingConnection ??= connections.isNotEmpty ? connections.first : null;

  final serverIp = streamingServerIp(response);
  if (serverIp == null) {
    throw StateError('CloudMatch response did not include a signaling host');
  }

  final resourcePath = signalingConnection?.resourcePath ?? '/nvst/';
  final built = buildSignalingUrl(resourcePath, serverIp);

  final effectiveHost = built.signalingHost ?? serverIp;
  final signalingServer = effectiveHost.contains(':')
      ? effectiveHost
      : '$effectiveHost:443';

  String? rtspsHost;
  for (final conn in connections) {
    final path = conn.resourcePath;
    if (path != null) {
      final host = extractHostFromUrl(path);
      if (host != null) {
        rtspsHost = host;
        break;
      }
    }
  }
  rtspsHost ??= built.signalingHost;
  rtspsHost ??= isZoneHostname(serverIp) ? null : serverIp;

  final rtspsEndpoints = _collectRtspsEndpoints(connections, rtspsHost);

  return ResolvedSignaling(
    serverIp: serverIp,
    signalingServer: signalingServer,
    signalingUrl: built.signalingUrl,
    mediaConnectionInfo:
        resolveMediaConnectionInfo(connections, serverIp),
    rtspsEndpoints: rtspsEndpoints,
  );
}

/// Port of buildSignalingUrl
({String signalingUrl, String? signalingHost}) buildSignalingUrl(
  String raw,
  String serverIp,
) {
  if (raw.startsWith('rtsps://') || raw.startsWith('rtsp://')) {
    final withoutScheme = raw.startsWith('rtsps://')
        ? raw.substring('rtsps://'.length)
        : raw.substring('rtsp://'.length);
    final host = withoutScheme.split(':').first.split('/').first;
    if (host.isNotEmpty && !host.startsWith('.')) {
      return (signalingUrl: 'wss://$host/nvst/', signalingHost: host);
    }
    return (signalingUrl: 'wss://$serverIp:443/nvst/', signalingHost: null);
  }

  if (raw.startsWith('wss://')) {
    final withoutScheme = raw.substring('wss://'.length);
    final host = withoutScheme.split('/').first;
    return (
      signalingUrl: _normalizeSignalingPort(raw),
      signalingHost: _normalizeHostPort(host),
    );
  }

  if (raw.startsWith('/')) {
    return (signalingUrl: 'wss://$serverIp:443$raw', signalingHost: null);
  }

  return (signalingUrl: 'wss://$serverIp:443/nvst/', signalingHost: null);
}

/// NVIDIA's beta CloudMatch sometimes places port `0` in the signaling
/// resourcePath as a placeholder meaning "use the default port" (443 for wss).
/// A client can never connect to port 0, so rewrite it to 443.
String _normalizeSignalingPort(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasPort || uri.port != 0) return url;
  return uri.replace(port: 443).toString();
}

/// Strips a trailing `:0` placeholder port from a host string so derived
/// `signalingServer` values don't carry the unconnectable port.
String? _normalizeHostPort(String host) {
  if (host.isEmpty) return null;
  if (host.endsWith(':0')) {
    final stripped = host.substring(0, host.length - 2);
    return stripped.isEmpty ? null : stripped;
  }
  return host;
}

/// Port of resolveMediaConnectionInfo — priority chain:
/// 1. usage=2 (primary UDP)
/// 2. usage=17 (alt)
/// 3. usage=14 highest port (alliance fallback)
MediaConnectionInfo? resolveMediaConnectionInfo(
  List<CloudMatchConnectionInfo> connections,
  String serverIp,
) {
  String? extractIp(CloudMatchConnectionInfo conn) {
    final directIp = conn.ip;
    if (directIp != null && directIp.isNotEmpty) return directIp;
    final path = conn.resourcePath;
    if (path != null) {
      final host = extractHostFromUrl(path);
      if (host != null) return host;
    }
    return null;
  }

  int extractPort(CloudMatchConnectionInfo conn) {
    if (conn.port > 0) return conn.port;
    final path = conn.resourcePath;
    if (path != null) {
      try {
        final uri = Uri.parse(
          path.replaceFirst('rtsps://', 'https://').replaceFirst('rtsp://', 'http://'),
        );
        final portStr = uri.hasPort ? uri.port.toString() : '';
        if (portStr.isNotEmpty) return int.tryParse(portStr) ?? 0;
      } catch (_) {}
    }
    return 0;
  }

  CloudMatchConnectionInfo? primary;
  for (final conn in connections) {
    if (conn.usage == 2) {
      primary = conn;
      break;
    }
  }
  if (primary != null) {
    final ip = extractIp(primary);
    final port = extractPort(primary);
    if (ip != null && port > 0) {
      return MediaConnectionInfo(ip: ip, port: port, usage: primary.usage);
    }
  }

  CloudMatchConnectionInfo? alt;
  for (final conn in connections) {
    if (conn.usage == 17) {
      alt = conn;
      break;
    }
  }
  if (alt != null) {
    final ip = extractIp(alt);
    final port = extractPort(alt);
    if (ip != null && port > 0) {
      return MediaConnectionInfo(ip: ip, port: port, usage: alt.usage);
    }
  }

  final alliance = connections
      .where((c) => c.usage == 14)
      .toList()
    ..sort((a, b) => b.port.compareTo(a.port));
  for (final conn in alliance) {
    final ip = extractIp(conn) ?? serverIp;
    final port = extractPort(conn);
    if (ip.isNotEmpty && port > 0) {
      return MediaConnectionInfo(ip: ip, port: port, usage: conn.usage);
    }
  }

  return null;
}

List<String> _collectRtspsEndpoints(
  List<CloudMatchConnectionInfo> connections,
  String? rtspsHost,
) {
  // Port of OpenNOW collectRtspsEndpoints (native-streamer-v2): any full
  // rtsps:// URL resourcePath is kept; otherwise synthesize from a
  // usage==16 / protocol==6 (Bifrost RTSP) connection. The caller then
  // prefers the :322 endpoint.
  final endpoints = <String>[];
  final seen = <String>{};
  for (final conn in connections) {
    final path = conn.resourcePath?.trim() ?? '';
    if (path.startsWith('rtsps://') || path.startsWith('rtsp://')) {
      if (!seen.contains(path)) {
        seen.add(path);
        endpoints.add(path);
      }
      continue;
    }
    final isNvst = conn.usage == 16 || conn.protocol == 6;
    if (!isNvst || rtspsHost == null || conn.port == 0) continue;
    final synthesized = 'rtsps://$rtspsHost:${conn.port}';
    if (!seen.contains(synthesized)) {
      seen.add(synthesized);
      endpoints.add(synthesized);
    }
  }
  return endpoints;
}

/// Port of OpenNOW selectPrimaryRtspsEndpoint — prefers :322 for NVST probe.
String? selectPrimaryRtspsEndpoint(List<String> endpoints) {
  final normalized = endpoints
      .map((e) => e.trim())
      .where((e) => e.startsWith('rtsps://') || e.startsWith('rtsp://'))
      .toList();
  if (normalized.isEmpty) return null;
  for (final url in normalized) {
    if (RegExp(r':322(?:\/|$)').hasMatch(url)) return url;
  }
  return normalized.first;
}