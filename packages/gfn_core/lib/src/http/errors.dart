import 'dart:convert' show jsonDecode;

/// Port of OpenNOW gfnErrorCodeEnum.ts — these numeric codes are
/// reverse-engineered from NVIDIA's proprietary CloudMatch API.
/// DO NOT change any value.
class GfnErrorCode {
  static const int success = 15859712;

  static const int invalidOperation = 3237085186;
  static const int networkError = 3237089282;
  static const int getActiveSessionServerError = 3237089283;
  static const int authTokenNotUpdated = 3237093377;
  static const int sessionFinishedState = 3237093378;
  static const int responseParseFailure = 3237093379;
  static const int invalidServerResponse = 3237093381;
  static const int putOrPostInProgress = 3237093382;
  static const int gridServerNotInitialized = 3237093383;
  static const int domExceptionInSessionControl = 3237093384;
  static const int invalidAdStateTransition = 3237093386;
  static const int authTokenUpdateTimeout = 3237093387;

  static const int sessionServerErrorBegin = 3237093632;
  static const int requestForbidden = 3237093634;
  static const int serverInternalTimeout = 3237093635;
  static const int serverInternalError = 3237093636;
  static const int serverInvalidRequest = 3237093637;
  static const int serverInvalidRequestVersion = 3237093638;
  static const int sessionListLimitExceeded = 3237093639;
  static const int invalidRequestDataMalformed = 3237093640;
  static const int invalidRequestDataMissing = 3237093641;
  static const int requestLimitExceeded = 3237093642;
  static const int sessionLimitExceeded = 3237093643;
  static const int invalidRequestVersionOutOfDate = 3237093644;
  static const int sessionEntitledTimeExceeded = 3237093645;
  static const int authFailure = 3237093646;
  static const int invalidAuthenticationMalformed = 3237093647;
  static const int invalidAuthenticationExpired = 3237093648;
  static const int invalidAuthenticationNotFound = 3237093649;
  static const int entitlementFailure = 3237093650;
  static const int invalidAppIdNotAvailable = 3237093651;
  static const int invalidAppIdNotFound = 3237093652;
  static const int invalidSessionIdMalformed = 3237093653;
  static const int invalidSessionIdNotFound = 3237093654;
  static const int eulaUnAccepted = 3237093655;
  static const int maintenanceStatus = 3237093656;
  static const int serviceUnAvailable = 3237093657;
  static const int steamGuardRequired = 3237093658;
  static const int steamLoginRequired = 3237093659;
  static const int steamGuardInvalid = 3237093660;
  static const int steamProfilePrivate = 3237093661;
  static const int invalidCountryCode = 3237093662;
  static const int invalidLanguageCode = 3237093663;
  static const int missingCountryCode = 3237093664;
  static const int missingLanguageCode = 3237093665;
  static const int sessionNotPaused = 3237093666;
  static const int emailNotVerified = 3237093667;
  static const int invalidAuthenticationUnsupportedProtocol = 3237093668;
  static const int invalidAuthenticationUnknownToken = 3237093669;
  static const int invalidAuthenticationCredentials = 3237093670;
  static const int sessionNotPlaying = 3237093671;
  static const int invalidServiceResponse = 3237093672;
  static const int appPatching = 3237093673;
  static const int gameNotFound = 3237093674;
  static const int notEnoughCredits = 3237093675;
  static const int invitationOnlyRegistration = 3237093676;
  static const int regionNotSupportedForRegistration = 3237093677;
  static const int sessionTerminatedByAnotherClient = 3237093678;
  static const int deviceIdAlreadyUsed = 3237093679;
  static const int serviceNotExist = 3237093680;
  static const int sessionExpired = 3237093681;
  static const int sessionLimitPerDeviceReached = 3237093682;
  static const int forwardingZoneOutOfCapacity = 3237093683;
  static const int regionNotSupportedIndefinitely = 3237093684;
  static const int regionBanned = 3237093685;
  static const int regionOnHoldForFree = 3237093686;
  static const int regionOnHoldForPaid = 3237093687;
  static const int appMaintenanceStatus = 3237093688;
  static const int resourcePoolNotConfigured = 3237093689;
  static const int insufficientVmCapacity = 3237093690;
  static const int insufficientRouteCapacity = 3237093691;
  static const int insufficientScratchSpaceCapacity = 3237093692;
  static const int requiredSeatInstanceTypeNotSupported = 3237093693;
  static const int serverSessionQueueLengthExceeded = 3237093694;
  static const int regionNotSupportedForStreaming = 3237093695;
  static const int sessionForwardRequestAllocationTimeExpired = 3237093696;
  static const int sessionForwardGameBinariesNotAvailable = 3237093697;
  static const int gameBinariesNotAvailableInRegion = 3237093698;
  static const int uekRetrievalFailed = 3237093699;
  static const int entitlementFailureForResource = 3237093700;
  static const int sessionInQueueAbandoned = 3237093701;
  static const int memberTerminated = 3237093702;
  static const int sessionRemovedFromQueueMaintenance = 3237093703;
  static const int zoneMaintenanceStatus = 3237093704;
  static const int guestModeCampaignDisabled = 3237093705;
  static const int regionNotSupportedAnonymousAccess = 3237093706;
  static const int instanceTypeNotSupportedInSingleRegion = 3237093707;
  static const int invalidZoneForQueuedSession = 3237093710;
  static const int sessionWaitingAdsTimeExpired = 3237093711;
  static const int userCancelledWatchingAds = 3237093712;
  static const int streamingNotAllowedInLimitedMode = 3237093713;
  static const int forwardRequestJPMFailed = 3237093714;
  static const int maxSessionNumberLimitExceeded = 3237093715;
  static const int guestModePartnerCapacityDisabled = 3237093716;
  static const int sessionRejectedNoCapacity = 3237093717;
  static const int sessionInsufficientPlayabilityLevel = 3237093718;
  static const int forwardRequestLOFNFailed = 3237093719;
  static const int invalidTransportRequest = 3237093720;
  static const int userStorageNotAvailable = 3237093721;
  static const int gfnStorageNotAvailable = 3237093722;
  static const int appNotAllowedToStream = 3237093723;
  static const int sessionServerErrorEnd = 3237093887;

  static const int sessionSetupCancelled = 15867905;
  static const int sessionSetupCancelledDuringQueuing = 15867906;
  static const int requestCancelled = 15867907;
  static const int systemSleepDuringSessionSetup = 15867909;
  static const int noInternetDuringSessionSetup = 15868417;

  static const int socketError = 3237101580;
  static const int addressResolveFailed = 3237101581;
  static const int connectFailed = 3237101582;
  static const int sslError = 3237101583;
  static const int connectionTimeout = 3237101584;
  static const int dataReceiveTimeout = 3237101585;
  static const int peerNoResponse = 3237101586;
  static const int unexpectedHttpRedirect = 3237101587;
  static const int dataSendFailure = 3237101588;
  static const int dataReceiveFailure = 3237101589;
  static const int certificateRejected = 3237101590;
  static const int dataNotAllowed = 3237101591;
  static const int networkErrorUnknown = 3237101592;

  static const Map<String, int> _entries = {
    'Success': success,
    'InvalidOperation': invalidOperation,
    'NetworkError': networkError,
    'GetActiveSessionServerError': getActiveSessionServerError,
    'AuthTokenNotUpdated': authTokenNotUpdated,
    'SessionFinishedState': sessionFinishedState,
    'ResponseParseFailure': responseParseFailure,
    'InvalidServerResponse': invalidServerResponse,
    'PutOrPostInProgress': putOrPostInProgress,
    'GridServerNotInitialized': gridServerNotInitialized,
    'DOMExceptionInSessionControl': domExceptionInSessionControl,
    'InvalidAdStateTransition': invalidAdStateTransition,
    'AuthTokenUpdateTimeout': authTokenUpdateTimeout,
    'RequestForbidden': requestForbidden,
    'ServerInternalTimeout': serverInternalTimeout,
    'ServerInternalError': serverInternalError,
    'ServerInvalidRequest': serverInvalidRequest,
    'ServerInvalidRequestVersion': serverInvalidRequestVersion,
    'SessionListLimitExceeded': sessionListLimitExceeded,
    'InvalidRequestDataMalformed': invalidRequestDataMalformed,
    'InvalidRequestDataMissing': invalidRequestDataMissing,
    'RequestLimitExceeded': requestLimitExceeded,
    'SessionLimitExceeded': sessionLimitExceeded,
    'InvalidRequestVersionOutOfDate': invalidRequestVersionOutOfDate,
    'SessionEntitledTimeExceeded': sessionEntitledTimeExceeded,
    'AuthFailure': authFailure,
    'InvalidAuthenticationMalformed': invalidAuthenticationMalformed,
    'InvalidAuthenticationExpired': invalidAuthenticationExpired,
    'InvalidAuthenticationNotFound': invalidAuthenticationNotFound,
    'EntitlementFailure': entitlementFailure,
    'InvalidAppIdNotAvailable': invalidAppIdNotAvailable,
    'InvalidAppIdNotFound': invalidAppIdNotFound,
    'InvalidSessionIdMalformed': invalidSessionIdMalformed,
    'InvalidSessionIdNotFound': invalidSessionIdNotFound,
    'EulaUnAccepted': eulaUnAccepted,
    'MaintenanceStatus': maintenanceStatus,
    'ServiceUnAvailable': serviceUnAvailable,
    'SteamGuardRequired': steamGuardRequired,
    'SteamLoginRequired': steamLoginRequired,
    'SteamGuardInvalid': steamGuardInvalid,
    'SteamProfilePrivate': steamProfilePrivate,
    'InvalidCountryCode': invalidCountryCode,
    'InvalidLanguageCode': invalidLanguageCode,
    'MissingCountryCode': missingCountryCode,
    'MissingLanguageCode': missingLanguageCode,
    'SessionNotPaused': sessionNotPaused,
    'EmailNotVerified': emailNotVerified,
    'InvalidAuthenticationUnsupportedProtocol':
        invalidAuthenticationUnsupportedProtocol,
    'InvalidAuthenticationUnknownToken': invalidAuthenticationUnknownToken,
    'InvalidAuthenticationCredentials': invalidAuthenticationCredentials,
    'SessionNotPlaying': sessionNotPlaying,
    'InvalidServiceResponse': invalidServiceResponse,
    'AppPatching': appPatching,
    'GameNotFound': gameNotFound,
    'NotEnoughCredits': notEnoughCredits,
    'InvitationOnlyRegistration': invitationOnlyRegistration,
    'RegionNotSupportedForRegistration': regionNotSupportedForRegistration,
    'SessionTerminatedByAnotherClient': sessionTerminatedByAnotherClient,
    'DeviceIdAlreadyUsed': deviceIdAlreadyUsed,
    'ServiceNotExist': serviceNotExist,
    'SessionExpired': sessionExpired,
    'SessionLimitPerDeviceReached': sessionLimitPerDeviceReached,
    'ForwardingZoneOutOfCapacity': forwardingZoneOutOfCapacity,
    'RegionNotSupportedIndefinitely': regionNotSupportedIndefinitely,
    'RegionBanned': regionBanned,
    'RegionOnHoldForFree': regionOnHoldForFree,
    'RegionOnHoldForPaid': regionOnHoldForPaid,
    'AppMaintenanceStatus': appMaintenanceStatus,
    'ResourcePoolNotConfigured': resourcePoolNotConfigured,
    'InsufficientVmCapacity': insufficientVmCapacity,
    'InsufficientRouteCapacity': insufficientRouteCapacity,
    'InsufficientScratchSpaceCapacity': insufficientScratchSpaceCapacity,
    'RequiredSeatInstanceTypeNotSupported':
        requiredSeatInstanceTypeNotSupported,
    'ServerSessionQueueLengthExceeded': serverSessionQueueLengthExceeded,
    'RegionNotSupportedForStreaming': regionNotSupportedForStreaming,
    'SessionForwardRequestAllocationTimeExpired':
        sessionForwardRequestAllocationTimeExpired,
    'SessionForwardGameBinariesNotAvailable':
        sessionForwardGameBinariesNotAvailable,
    'GameBinariesNotAvailableInRegion': gameBinariesNotAvailableInRegion,
    'UekRetrievalFailed': uekRetrievalFailed,
    'EntitlementFailureForResource': entitlementFailureForResource,
    'SessionInQueueAbandoned': sessionInQueueAbandoned,
    'MemberTerminated': memberTerminated,
    'SessionRemovedFromQueueMaintenance': sessionRemovedFromQueueMaintenance,
    'ZoneMaintenanceStatus': zoneMaintenanceStatus,
    'GuestModeCampaignDisabled': guestModeCampaignDisabled,
    'RegionNotSupportedAnonymousAccess': regionNotSupportedAnonymousAccess,
    'InstanceTypeNotSupportedInSingleRegion':
        instanceTypeNotSupportedInSingleRegion,
    'InvalidZoneForQueuedSession': invalidZoneForQueuedSession,
    'SessionWaitingAdsTimeExpired': sessionWaitingAdsTimeExpired,
    'UserCancelledWatchingAds': userCancelledWatchingAds,
    'StreamingNotAllowedInLimitedMode': streamingNotAllowedInLimitedMode,
    'ForwardRequestJPMFailed': forwardRequestJPMFailed,
    'MaxSessionNumberLimitExceeded': maxSessionNumberLimitExceeded,
    'GuestModePartnerCapacityDisabled': guestModePartnerCapacityDisabled,
    'SessionRejectedNoCapacity': sessionRejectedNoCapacity,
    'SessionInsufficientPlayabilityLevel': sessionInsufficientPlayabilityLevel,
    'ForwardRequestLOFNFailed': forwardRequestLOFNFailed,
    'InvalidTransportRequest': invalidTransportRequest,
    'UserStorageNotAvailable': userStorageNotAvailable,
    'GfnStorageNotAvailable': gfnStorageNotAvailable,
    'AppNotAllowedToStream': appNotAllowedToStream,
    'SessionSetupCancelled': sessionSetupCancelled,
    'SessionSetupCancelledDuringQueuing': sessionSetupCancelledDuringQueuing,
    'RequestCancelled': requestCancelled,
    'SystemSleepDuringSessionSetup': systemSleepDuringSessionSetup,
    'NoInternetDuringSessionSetup': noInternetDuringSessionSetup,
    'SocketError': socketError,
    'AddressResolveFailed': addressResolveFailed,
    'ConnectFailed': connectFailed,
    'SslError': sslError,
    'ConnectionTimeout': connectionTimeout,
    'DataReceiveTimeout': dataReceiveTimeout,
    'PeerNoResponse': peerNoResponse,
    'UnexpectedHttpRedirect': unexpectedHttpRedirect,
    'DataSendFailure': dataSendFailure,
    'DataReceiveFailure': dataReceiveFailure,
    'CertificateRejected': certificateRejected,
    'DataNotAllowed': dataNotAllowed,
    'NetworkErrorUnknown': networkErrorUnknown,
  };
}

typedef ErrorMessageEntry = ({String title, String description});

/// Port of OpenNOW gfnErrorMessages.ts ERROR_MESSAGES map.
/// These are user-friendly messages for the reverse-engineered error codes.
const Map<int, ErrorMessageEntry> errorMessages = {
  15859712: (title: 'Success', description: 'Session started successfully.'),
  3237085186: (
    title: 'Invalid Operation',
    description: 'The requested operation is not valid at this time.',
  ),
  3237089282: (
    title: 'Network Error',
    description:
        'A network error occurred. Please check your internet connection.',
  ),
  3237093377: (
    title: 'Authentication Required',
    description: 'Your session has expired. Please log in again.',
  ),
  3237093379: (
    title: 'Server Response Error',
    description: 'Failed to parse server response. Please try again.',
  ),
  3237093381: (
    title: 'Invalid Server Response',
    description: 'The server returned an invalid response.',
  ),
  3237093384: (
    title: 'Session Error',
    description: 'An error occurred during session setup.',
  ),
  3237093387: (
    title: 'Authentication Timeout',
    description: 'Authentication token update timed out. Please log in again.',
  ),
  3237093634: (
    title: 'Access Forbidden',
    description: 'Access to this service is forbidden.',
  ),
  3237093635: (
    title: 'Server Timeout',
    description: 'The server timed out. Please try again.',
  ),
  3237093636: (
    title: 'Server Error',
    description: 'An internal server error occurred. Please try again later.',
  ),
  3237093637: (
    title: 'Invalid Request',
    description: 'The request was invalid.',
  ),
  3237093639: (
    title: 'Too Many Sessions',
    description:
        'You have too many active sessions. Please close some sessions and try again.',
  ),
  3237093643: (
    title: 'Session Limit Exceeded',
    description:
        'You have reached your session limit. Another session may already be running on your account.',
  ),
  3237093645: (
    title: 'Session Time Exceeded',
    description: 'Your session time has been exceeded.',
  ),
  3237093646: (
    title: 'Authentication Failed',
    description: 'Authentication failed. Please log in again.',
  ),
  3237093648: (
    title: 'Session Expired',
    description: 'Your authentication has expired. Please log in again.',
  ),
  3237093650: (
    title: 'Entitlement Error',
    description: "You don't have access to this game or service.",
  ),
  3237093651: (
    title: 'Game Not Available',
    description: 'This game is not currently available.',
  ),
  3237093652: (
    title: 'Game Not Found',
    description: 'This game was not found in the library.',
  ),
  3237093655: (
    title: 'EULA Required',
    description: 'You must accept the End User License Agreement to continue.',
  ),
  3237093656: (
    title: 'Under Maintenance',
    description:
        'The service is currently under maintenance. Please try again later.',
  ),
  3237093657: (
    title: 'Service Unavailable',
    description:
        'The service is temporarily unavailable. Please try again later.',
  ),
  3237093658: (
    title: 'Steam Guard Required',
    description:
        'Steam Guard authentication is required. Please complete Steam Guard verification.',
  ),
  3237093659: (
    title: 'Steam Login Required',
    description: 'You need to link your Steam account to play this game.',
  ),
  3237093660: (
    title: 'Steam Guard Invalid',
    description: 'Steam Guard code is invalid. Please try again.',
  ),
  3237093661: (
    title: 'Steam Profile Private',
    description:
        'Your Steam profile is private. Please make it public or friends-only.',
  ),
  3237093667: (
    title: 'Email Not Verified',
    description: 'Please verify your email address to continue.',
  ),
  3237093673: (
    title: 'Game Updating',
    description:
        'This game is currently being updated. Please try again later.',
  ),
  3237093674: (
    title: 'Game Not Found',
    description: 'This game was not found.',
  ),
  3237093675: (
    title: 'Insufficient Credits',
    description: "You don't have enough credits for this session.",
  ),
  3237093678: (
    title: 'Session Taken Over',
    description: 'Your session was taken over by another device.',
  ),
  3237093681: (
    title: 'Session Expired',
    description: 'Your session has expired.',
  ),
  3237093682: (
    title: 'Device Limit Reached',
    description: 'You have reached the session limit for this device.',
  ),
  3237093683: (
    title: 'Region At Capacity',
    description:
        'Your region is currently at capacity. Please try again later.',
  ),
  3237093684: (
    title: 'Region Not Supported',
    description: 'The service is not available in your region.',
  ),
  3237093685: (
    title: 'Region Banned',
    description: 'The service is not available in your region.',
  ),
  3237093686: (
    title: 'Free Tier On Hold',
    description: 'Free tier is temporarily unavailable in your region.',
  ),
  3237093687: (
    title: 'Paid Tier On Hold',
    description: 'Paid tier is temporarily unavailable in your region.',
  ),
  3237093688: (
    title: 'Game Maintenance',
    description: 'This game is currently under maintenance.',
  ),
  3237093690: (
    title: 'No Capacity',
    description:
        'No gaming rigs are available right now. Please try again later or join the queue.',
  ),
  3237093694: (
    title: 'Queue Full',
    description: 'The queue is currently full. Please try again later.',
  ),
  3237093695: (
    title: 'GeForce NOW Unavailable in Your Region',
    description:
        'GeForce NOW has restricted streaming in your region. This is not a NEXTCLIENT issue — NVIDIA has blocked access from your location. You may need to use a VPN or check GeForce NOW supported countries list.',
  ),
  3237093698: (
    title: 'Game Not Available',
    description: 'This game is not available in your region.',
  ),
  3237093701: (
    title: 'Queue Abandoned',
    description: 'Your session in queue was abandoned.',
  ),
  3237093702: (
    title: 'Account Terminated',
    description: 'Your account has been terminated.',
  ),
  3237093703: (
    title: 'Queue Maintenance',
    description: 'The queue was cleared due to maintenance.',
  ),
  3237093704: (
    title: 'Zone Maintenance',
    description: 'This server zone is under maintenance.',
  ),
  3237093711: (
    title: 'Ads Timeout',
    description:
        'Session expired while waiting for ads. Free tier users must watch ads to play. Please start a new session.',
  ),
  3237093712: (
    title: 'Ads Cancelled',
    description:
        'Session cancelled because ads were skipped. Free tier users must watch ads to play.',
  ),
  3237093713: (
    title: 'Limited Mode',
    description: 'Streaming is not allowed in limited mode.',
  ),
  3237093715: (
    title: 'Session Limit',
    description: 'Maximum number of sessions reached.',
  ),
  3237093717: (
    title: 'No Capacity',
    description: 'No gaming rigs are available. Please try again later.',
  ),
  3237093718: (
    title: 'Membership Upgrade Required',
    description:
        'Your current GeForce NOW membership is not high enough to play this game. Upgrade to a higher tier and try again.',
  ),
  3237093721: (
    title: 'Storage Unavailable',
    description: 'User storage is not available.',
  ),
  3237093722: (
    title: 'Storage Error',
    description: 'Service storage is not available.',
  ),
  3237093723: (
    title: 'Streaming Not Allowed',
    description:
        'This app is not allowed to stream on your current GeForce NOW account or region.',
  ),
  15867905: (
    title: 'Session Cancelled',
    description: 'Session setup was cancelled.',
  ),
  15867906: (title: 'Queue Cancelled', description: 'You left the queue.'),
  15867907: (
    title: 'Request Cancelled',
    description: 'The request was cancelled.',
  ),
  15867909: (
    title: 'System Sleep',
    description: 'Session setup was interrupted by system sleep.',
  ),
  15868417: (
    title: 'No Internet',
    description: 'No internet connection during session setup.',
  ),
  3237101580: (
    title: 'Socket Error',
    description: 'A socket error occurred. Please check your network.',
  ),
  3237101581: (
    title: 'DNS Error',
    description: 'Failed to resolve server address. Please check your network.',
  ),
  3237101582: (
    title: 'Connection Failed',
    description: 'Failed to connect to the server. Please check your network.',
  ),
  3237101583: (
    title: 'SSL Error',
    description: 'A secure connection error occurred.',
  ),
  3237101584: (
    title: 'Connection Timeout',
    description: 'Connection timed out. Please check your network.',
  ),
  3237101585: (
    title: 'Receive Timeout',
    description: 'Data receive timed out. Please check your network.',
  ),
  3237101586: (
    title: 'No Response',
    description: 'Server not responding. Please try again.',
  ),
  3237101590: (
    title: 'Certificate Error',
    description: 'Server certificate was rejected.',
  ),
};

class SessionErrorInfo {
  final int httpStatus;
  final int statusCode;
  final String? statusDescription;
  final int? unifiedErrorCode;
  final int? sessionErrorCode;
  final int gfnErrorCode;
  final String title;
  final String description;

  const SessionErrorInfo({
    required this.httpStatus,
    required this.statusCode,
    this.statusDescription,
    this.unifiedErrorCode,
    this.sessionErrorCode,
    required this.gfnErrorCode,
    required this.title,
    required this.description,
  });
}

/// Port of OpenNOW errorCodes.ts SessionError.
class SessionError implements Exception {
  final int httpStatus;
  final int statusCode;
  final String? statusDescription;
  final int? unifiedErrorCode;
  final int? sessionErrorCode;
  final int gfnErrorCode;
  final String title;
  final String description;

  const SessionError({
    required this.httpStatus,
    required this.statusCode,
    this.statusDescription,
    this.unifiedErrorCode,
    this.sessionErrorCode,
    required this.gfnErrorCode,
    required this.title,
    required this.description,
  });

  String get message => description;

  @override
  String toString() => 'SessionError[$errorType]: $description';

  String get errorType {
    for (final entry in GfnErrorCode._entries.entries) {
      if (entry.value == gfnErrorCode) return entry.key;
    }
    if (statusCode > 0) return 'StatusCode$statusCode';
    return 'UnknownError';
  }

  /// Port of SessionError.fromResponse — parse CloudMatch error JSON.
  factory SessionError.fromResponse(int httpStatus, String responseBody) {
    Map<String, dynamic> json = {};
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}

    final requestStatus = json['requestStatus'];
    final statusCode = requestStatus is Map
        ? (requestStatus['statusCode'] as num?)?.toInt() ?? 0
        : 0;
    final statusDescription = requestStatus is Map
        ? requestStatus['statusDescription'] as String?
        : null;
    final unifiedErrorCode = requestStatus is Map
        ? (requestStatus['unifiedErrorCode'] as num?)?.toInt()
        : null;

    final session = json['session'];
    final sessionErrorCode = session is Map
        ? (session['errorCode'] as num?)?.toInt()
        : null;

    final gfnErrorCode = computeErrorCode(statusCode, unifiedErrorCode);
    final errorMessage = getErrorMessage(
      gfnErrorCode,
      statusDescription,
      httpStatus,
    );

    return SessionError(
      httpStatus: httpStatus,
      statusCode: statusCode,
      statusDescription: statusDescription,
      unifiedErrorCode: unifiedErrorCode,
      sessionErrorCode: sessionErrorCode,
      gfnErrorCode: gfnErrorCode,
      title: errorMessage.title,
      description: errorMessage.description,
    );
  }

  /// Port of SessionError.computeErrorCode
  static int computeErrorCode(int statusCode, int? unifiedErrorCode) {
    int errorCode = GfnErrorCode.sessionServerErrorBegin;
    if (statusCode == 1) {
      errorCode = GfnErrorCode.success;
    } else if (statusCode > 0 && statusCode < 255) {
      errorCode = GfnErrorCode.sessionServerErrorBegin + statusCode;
    }

    if (unifiedErrorCode != null) {
      switch (errorCode) {
        case GfnErrorCode.sessionServerErrorBegin:
        case GfnErrorCode.serverInternalError:
        case GfnErrorCode.invalidServerResponse:
          errorCode = unifiedErrorCode;
      }
    }

    return errorCode;
  }

  /// Port of SessionError.getErrorMessage
  static ErrorMessageEntry getErrorMessage(
    int errorCode,
    String? statusDescription,
    int httpStatus,
  ) {
    final known = errorMessages[errorCode];
    if (known != null) return known;

    if (statusDescription != null && statusDescription.isNotEmpty) {
      final descUpper = statusDescription.toUpperCase();

      if (descUpper.contains('INSUFFICIENT_PLAYABILITY')) {
        return (
          title: 'Membership Upgrade Required',
          description:
              'Your current GeForce NOW membership is not high enough to play this game. Upgrade to a higher tier and try again.',
        );
      }
      if (descUpper.contains('SESSION_LIMIT')) {
        return (
          title: 'Session Limit Exceeded',
          description:
              'You have reached your maximum number of concurrent sessions.',
        );
      }
      if (descUpper.contains('MAINTENANCE')) {
        return (
          title: 'Under Maintenance',
          description:
              'The service is currently under maintenance. Please try again later.',
        );
      }
      if (descUpper.contains('CAPACITY') || descUpper.contains('QUEUE')) {
        return (
          title: 'No Capacity Available',
          description:
              'All gaming rigs are currently in use. Please try again later.',
        );
      }
      if (descUpper.contains('AUTH') || descUpper.contains('TOKEN')) {
        return (
          title: 'Authentication Error',
          description: 'Please log in again.',
        );
      }
      if (descUpper.contains('ENTITLEMENT')) {
        return (
          title: 'Access Denied',
          description: "You don't have access to this game or service.",
        );
      }
    }

    switch (httpStatus) {
      case 401:
        return (title: 'Unauthorized', description: 'Please log in again.');
      case 403:
        return (
          title: 'Access Denied',
          description: 'Access to this resource was denied.',
        );
      case 404:
        return (
          title: 'Not Found',
          description: 'The requested resource was not found.',
        );
      case 429:
        return (
          title: 'Too Many Requests',
          description: 'Please wait a moment and try again.',
        );
    }

    if (httpStatus >= 500 && httpStatus < 600) {
      return (
        title: 'Server Error',
        description: 'A server error occurred. Please try again later.',
      );
    }

    return (
      title: 'Error',
      description: 'An error occurred (HTTP $httpStatus).',
    );
  }

  bool isSessionConflict() {
    const conflictCodes = {
      GfnErrorCode.sessionLimitExceeded,
      GfnErrorCode.sessionLimitPerDeviceReached,
      GfnErrorCode.maxSessionNumberLimitExceeded,
    };
    return conflictCodes.contains(gfnErrorCode);
  }

  bool isRetryable() {
    const retryableCodes = {
      GfnErrorCode.networkError,
      GfnErrorCode.serverInternalTimeout,
      GfnErrorCode.serverInternalError,
      GfnErrorCode.forwardingZoneOutOfCapacity,
      GfnErrorCode.insufficientVmCapacity,
      GfnErrorCode.sessionRejectedNoCapacity,
      GfnErrorCode.connectionTimeout,
      GfnErrorCode.dataReceiveTimeout,
      GfnErrorCode.peerNoResponse,
    };
    return retryableCodes.contains(gfnErrorCode);
  }

  bool needsReauth() {
    const reauthCodes = {
      GfnErrorCode.authTokenNotUpdated,
      GfnErrorCode.authTokenUpdateTimeout,
      GfnErrorCode.authFailure,
      GfnErrorCode.invalidAuthenticationMalformed,
      GfnErrorCode.invalidAuthenticationExpired,
      GfnErrorCode.invalidAuthenticationNotFound,
      GfnErrorCode.invalidAuthenticationUnsupportedProtocol,
      GfnErrorCode.invalidAuthenticationUnknownToken,
      GfnErrorCode.invalidAuthenticationCredentials,
    };
    if (reauthCodes.contains(gfnErrorCode)) return true;
    return httpStatus == 401;
  }

  SessionErrorInfo toInfo() {
    return SessionErrorInfo(
      httpStatus: httpStatus,
      statusCode: statusCode,
      statusDescription: statusDescription,
      unifiedErrorCode: unifiedErrorCode,
      sessionErrorCode: sessionErrorCode,
      gfnErrorCode: gfnErrorCode,
      title: title,
      description: description,
    );
  }
}

bool isSessionError(Object error) => error is SessionError;

SessionError parseCloudMatchError(int httpStatus, String responseBody) {
  return SessionError.fromResponse(httpStatus, responseBody);
}
