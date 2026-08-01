class CloudMatchRequestSessionData {
  final String appId;
  final String clientVersion;
  final String deviceInfo;
  final String gpuInfo;
  final Map<String, dynamic> requestedStreamingFeatures;
  final Map<String, dynamic> userPreferences;
  final Map<String, dynamic> appLaunch;

  const CloudMatchRequestSessionData({
    required this.appId,
    required this.clientVersion,
    required this.deviceInfo,
    required this.gpuInfo,
    required this.requestedStreamingFeatures,
    required this.userPreferences,
    required this.appLaunch,
  });

  Map<String, dynamic> toJson() {
    return {
      'appId': appId,
      'clientVersion': clientVersion,
      'deviceInfo': deviceInfo,
      'gpuInfo': gpuInfo,
      'requestedStreamingFeatures': requestedStreamingFeatures,
      'userPreferences': userPreferences,
      'appLaunch': appLaunch,
    };
  }
}

class CloudMatchRequest {
  final CloudMatchRequestSessionData sessionRequestData;

  const CloudMatchRequest({required this.sessionRequestData});

  Map<String, dynamic> toJson() {
    return {'sessionRequestData': sessionRequestData.toJson()};
  }
}

class RequestStatus {
  final int statusCode;
  final String? statusDescription;
  final String? serverId;
  final int? unifiedErrorCode;

  const RequestStatus({
    required this.statusCode,
    this.statusDescription,
    this.serverId,
    this.unifiedErrorCode,
  });

  factory RequestStatus.fromJson(Map<String, dynamic> json) {
    return RequestStatus(
      statusCode: (json['statusCode'] as num).toInt(),
      statusDescription: json['statusDescription'] as String?,
      serverId: json['serverId'] as String?,
      unifiedErrorCode: (json['unifiedErrorCode'] as num?)?.toInt(),
    );
  }
}

class CloudMatchResponseSession {
  final String sessionId;
  final int status;
  final int? queuePosition;
  final String? gpuType;
  final List<CloudMatchConnectionInfo> connectionInfo;
  final List<IceServerConfig> iceServers;
  final Map<String, dynamic>? sessionRequestData;
  final String? serverIp;

  const CloudMatchResponseSession({
    required this.sessionId,
    required this.status,
    this.queuePosition,
    this.gpuType,
    this.connectionInfo = const [],
    this.iceServers = const [],
    this.sessionRequestData,
    this.serverIp,
  });

  factory CloudMatchResponseSession.fromJson(Map<String, dynamic> json) {
    return CloudMatchResponseSession(
      sessionId: json['sessionId'] as String,
      status: (json['status'] as num).toInt(),
      queuePosition: (json['queuePosition'] as num?)?.toInt(),
      gpuType: json['gpuType'] as String?,
      connectionInfo: (json['connectionInfo'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((c) => CloudMatchConnectionInfo.fromJson(c))
          .toList(),
      iceServers: _parseIceServers(json),
      sessionRequestData: json['sessionRequestData'] as Map<String, dynamic>?,
      serverIp: (json['sessionControlInfo'] as Map<String, dynamic>?)?['ip'] as String?,
    );
  }

  static List<IceServerConfig> _parseIceServers(Map<String, dynamic> json) {
    final config = json['iceServerConfiguration'];
    if (config is! Map<String, dynamic>) return const [];
    final raw = config['iceServers'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((s) => IceServerConfig.fromJson(s))
        .toList();
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'status': status,
      'queuePosition': queuePosition,
      'gpuType': gpuType,
      'connectionInfo': connectionInfo.map((c) => {
            'usage': c.usage,
            'ip': c.ip,
            'port': c.port,
            'resourcePath': c.resourcePath,
            'protocol': c.protocol,
          }).toList(),
      'iceServerConfiguration': {
        'iceServers': iceServers.map((s) => {
              'urls': s.urls,
              'username': s.username,
              'credential': s.credential,
            }).toList(),
      },
      'sessionRequestData': sessionRequestData,
      'sessionControlInfo': {'ip': serverIp},
    };
  }
}

class CloudMatchConnectionInfo {
  final int usage;
  final String? ip;
  final int port;
  final String? resourcePath;
  final int? protocol;

  const CloudMatchConnectionInfo({
    required this.usage,
    this.ip,
    required this.port,
    this.resourcePath,
    this.protocol,
  });

  factory CloudMatchConnectionInfo.fromJson(Map<String, dynamic> json) {
    return CloudMatchConnectionInfo(
      usage: (json['usage'] as num).toInt(),
      ip: json['ip'] as String?,
      port: (json['port'] as num).toInt(),
      resourcePath: json['resourcePath'] as String?,
      protocol: (json['protocol'] as num?)?.toInt(),
    );
  }
}

class IceServerConfig {
  final List<String> urls;
  final String? username;
  final String? credential;

  const IceServerConfig({required this.urls, this.username, this.credential});

  factory IceServerConfig.fromJson(Map<String, dynamic> json) {
    final raw = json['urls'];
    final urls = raw is List ? raw.cast<String>() : <String>[raw as String];
    return IceServerConfig(
      urls: urls,
      username: json['username'] as String?,
      credential: json['credential'] as String?,
    );
  }
}

class CloudMatchResponse {
  final RequestStatus requestStatus;
  final CloudMatchResponseSession session;

  const CloudMatchResponse({required this.requestStatus, required this.session});

  factory CloudMatchResponse.fromJson(Map<String, dynamic> json) {
    return CloudMatchResponse(
      requestStatus: RequestStatus.fromJson(
          json['requestStatus'] as Map<String, dynamic>),
      session: CloudMatchResponseSession.fromJson(
          json['session'] as Map<String, dynamic>),
    );
  }
}