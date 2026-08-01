# Implementation Plan: Pure-Dart GFN Core + Flutter Debug Shell

Date: 2026-08-01
Based on: `docs/superpowers/specs/2026-08-01-gfn-core-flutter-client-design.md`

## CRITICAL: Fidelity to OpenNOW

NVIDIA's GFN API is proprietary — every header, endpoint, auth flow, request shape,
error code, and wire value was reverse-engineered by OpenNOW. Small deviations will
cause silent rejects. **Every module below references the exact OpenNOW source file
you must port from.** Keep the TS implementation open in a split editor and translate
to Dart line by line for any protocol-critical logic.

All dev work: `dart analyze packages/gfn_core/` (must be clean) and
`flutter analyze` (must be clean). No tests per user's decision; manual live
verification only.

---

## File layout & workspace setup

```
/home/clark/Projects/vibecoded/dart/next_client/
  pubspec.yaml                         # Flutter app (existing) — add path dep on gfn_core
  lib/                                 # App shell
  packages/
    gfn_core/
      pubspec.yaml                     # pure-Dart package
      lib/
        gfn_core.dart                  # barrel
        src/
          ports.dart                   # TokenStorage, BrowserLauncher, Clock, Random
          logging.dart                 # Logger + LogSink
          http/
            client.dart                # GfnHttpClient (port of request.ts + clientHeaders.ts)
            errors.dart                # SessionError + error mappings
          models/
            auth.dart                  # AuthTokens, AuthSession, AuthUser, etc.
            catalog.dart               # CatalogGame, AppVariant, Panel, Section, etc.
            session.dart               # SessionInfo, StreamSettings, ActiveSessionInfo, etc.
            cloudmatch_types.dart      # CloudMatchRequest, CloudMatchResponse, etc.
            signaling_types.dart        # SignalingOffer, IceCandidatePayload, etc.
            subscription.dart          # SubscriptionInfo, StreamRegion, etc.
            printed_waste.dart         # PrintedWasteQueueData, PrintedWasteServerMapping
            device.dart               # GfnDeviceIdentity, GfnDeviceOs, etc.
          auth/
            constants.dart            # CLIENT_ID, AUTH_ENDPOINT, TOKEN_ENDPOINT, etc.
            oauth_flow.dart           # PKCE, auth URL, code exchange — port of auth/oauthFlow.ts
            device_login.dart         # Device-code login — port of auth/deviceLogin.ts
            token_refresh.dart        # Token refresh — port of auth/tokenRefresh.ts
            provider_discovery.dart   # Provider discovery — port of auth/providerDiscovery.ts
            auth_service.dart         # AuthService — port of auth.ts (main auth orchestration)
            helpers.dart              # Port of auth/helpers.ts: generateDeviceId, etc.
            persisted_state.dart      # Port of auth/persistedAccountState.ts
          catalog/
            catalog_service.dart      # Port of games.ts + catalogBrowse.ts + publicGames.ts + libraryGames.ts
            graphql.dart              # Port of lcarsGraphql.ts
            app_mapper.dart           # Port of gameAppMapper.ts
            features.dart             # Port of gameFeatures.ts
          cloudmatch/
            cloudmatch_service.dart   # Port of cloudmatch.ts (orchestration)
            session_request.dart      # Port of cloudmatchSessionRequest.ts
            session_parsing.dart      # Port of cloudmatchSessionParsing.ts
            transport.dart            # Port of cloudmatchTransport.ts
            signaling.dart            # Port of cloudmatchSignaling.ts
            features.dart             # Port of cloudmatchFeatures.ts
            types.dart                # Port of types.ts
          session/
            lifecycle.dart            # Session lifecycle state machine
          signaling/
            signaling_client.dart     # WebSocket signaling — port of signaling.ts
          printedwaste/
            printed_waste_service.dart # Port of services/printedWaste.ts
          subscription/
            subscription_service.dart  # Port of subscription.ts
      test/
```

---

## Phase 1: gfn_core scaffolding + ports + logging

### Task 1.1 — Create `packages/gfn_core/pubspec.yaml`

```yaml
name: gfn_core
version: 0.1.0
publish_to: none
environment:
  sdk: ^3.12.2
dependencies:
  http: ^1.2.0
  web_socket_channel: ^3.0.0
  crypto: ^3.0.6
```

### Task 1.2 — Create `ports.dart`

**Source fidelity:** OpenNOW's auth layer depends on node:crypto (randomBytes, createHash),
node:http (local callback server), os (hostname), electron (shell for URL opening),
and Electron session/persist. In Dart these become **ports** — interfaces the core
defines and the Flutter app provides.

Ports to define (place in `packages/gfn_core/lib/src/ports.dart`):

```dart
abstract class TokenStorage {
  Future<Map<String, String>?> readTokens();
  Future<void> writeTokens(Map<String, String> tokens);
  Future<void> clearTokens();
}

abstract class BrowserLauncher {
  Future<void> openUrl(String url);
}

abstract class Clock {
  int nowMillis(); // equivalent to DateTime.now().millisecondsSinceEpoch
}

abstract class RandomSource {
  List<int> nextBytes(int count); // for PKCE verifier
}
```

Also define a `Future<String> generateDeviceId()` helper port. In OpenNOW,
`generateDeviceId()` uses `createHash('sha256').update(hostname + username + salt)`.
The salt is `'opennow-stable'`. Port faithfully:
```dart
// Port of auth/helpers.ts:generateDeviceId
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart' show sha256;
String generateDeviceId() {
  final host = Platform.hostname;
  final username = Platform.environment['USER'] ?? 'unknown';
  return sha256.convert('$host:$username:opennow-stable'.codeUnits).toString();
}
```

### Task 1.3 — Create `logging.dart`

Simple logger with levels (debug, info, warn, error), message-category style, and
**automatic token redaction** (match `GFNJWT`, `Bearer`, `access_token` patterns and
replace with `[REDACTED]`). `LogSink` interface so the app can wire a console logger
and an in-memory ring buffer for the on-screen log viewer.

```dart
enum LogLevel { debug, info, warn, error }

abstract class LogSink {
  void log(LogLevel level, String category, String message);
}

class TokenRedactingLogger implements LogSink {
  final LogSink inner;
  final RegExp _tokenPattern = RegExp(r'(GFNJWT|Bearer)\s+\S+');
  TokenRedactingLogger(this.inner);
  
  @override
  void log(LogLevel level, String category, String message) {
    final safe = message.replaceAll(_tokenPattern, '$1 [REDACTED]');
    inner.log(level, category, safe);
  }
}
```

### Task 1.4 — Create barrel `gfn_core.dart`

Exports all public types (models, ports, services). Initially re-export as modules
are added.

### Task 1.5 — Wire path dependency in root `pubspec.yaml`

Add under `dependencies:`
```yaml
  gfn_core:
    path: packages/gfn_core
```
Run `dart pub get`.

---

## Phase 2: Models (DTOs)

### Task 2.1 — Auth models (`models/auth.dart`)

**Source fidelity:** Port EXACTLY from `shared/gfn/auth.ts`, `shared/gfn/api.ts`
(AuthSession, AuthTokens, AuthUser, LoginProvider, SavedAccount, AuthLoginRequest,
AuthDeviceLoginChallenge, AuthDeviceLoginPollResult, AuthDeviceLoginPollStatus).

Key types (hand-written fromJson/toJson — no codegen):
```dart
class LoginProvider {
  final String idpId;
  final String code;
  final String displayName;
  final String streamingServiceUrl;
  final int priority;
  // fromJson/toJson maps each field exactly
}

class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final int expiresAt;
  final String? authClientId;
  final String? clientToken;
  final int? clientTokenExpiresAt;
  final int? clientTokenLifetimeMs;
  // fromJson/toJson
}

class AuthSession {
  final LoginProvider provider;
  final AuthTokens tokens;
  final AuthUser user;
  // fromJson/toJson
}
// ... replicate all types from shared/gfn/auth.ts exactly
```

### Task 2.2 — Session models (`models/session.dart`)

**Source fidelity:** Port `shared/gfn/session.ts` exactly — StreamSettings (with CloudGsyncResolution, GameLanguage, KeyboardLayout, NativeStreamerBackendPreference, StreamTransportMode, etc.) and ActiveSessionInfo.

Key constants from OpenNOW to capture exactly:
```dart
const defaultStreamSettingsResolution = '1920x1080';
const defaultStreamSettingsFps = 60;
const defaultStreamSettingsMaxBitrateMbps = 50;
const defaultStreamSettingsCodec = 'H264';
const defaultColorQuality = ColorQuality(bitDepth: 8, chromaFormat: 0);
```

### Task 2.3 — Catalog models (`models/catalog.dart`)

**Source fidelity:** Port from shared/gfn/catalog.ts, games.ts GraphQL responses:
- CatalogGame: id, title, images (TV_BANNER, HERO_IMAGE, BOX_ART, etc.), variants[], itemMetadata
- AppVariant: id, shortName, appStore, supportedControls, minimumSizeInBytes, gfn (with library status, playStatus, etc.)
- Panel, Section, FilterGroup, SortOrder, etc. from GraphQL response shapes

### Task 2.4 — Cloudmatch models (`models/cloudmatch_types.ts`)

**Source fidelity:** Port the types from `main/platforms/gfn/types.ts` which define
CloudMatchRequest, CloudMatchResponse, GetSessionsResponse, etc.

### Task 2.5 — Device models (`models/device.dart`)

**Source fidelity:** Port from `main/platforms/gfn/deviceIdentity.ts`:
```dart
enum GfnDeviceOs { windows, macOS, android, iOS }

class GfnDeviceIdentity {
  final GfnDeviceOs deviceOs;
  final String deviceType;
  final String deviceMake;
  final String deviceModel;
  // ...
}
```

### Task 2.6 — Subscription models (`models/subscription.dart`)

**Source fidelity:** Port from `main/platforms/gfn/subscription.ts` response shape.

### Task 2.7 — PrintedWaste models (`models/printed_waste.dart`)

**Source fidelity:** Port from `shared/gfn/printedWaste.ts`:
```dart
class PrintedWasteQueueData {
  final Map<String, PrintedWasteZoneData> zones;
}

class PrintedWasteZoneData {
  final int? queuePosition;
  final String? lastUpdated;
  // ...
}
```

---

## Phase 3: http layer + error mapping

### Task 3.1 — `http/errors.dart`

**Source fidelity:** Port from `main/platforms/gfn/errorCodes.ts`. The SessionError
class and error code mapping. The exact error code numeric values (port the
GFN_ERROR_CODES, gfnErrorMessages, and SessionError class faithfully — these were
reverse-engineered by OpenNOW and must match exactly).

Create `SessionError` with: `code`, `statusCode`, `message`, `category`, and
a `fromHttpResponse` factory that maps NVIDIA's HTTP error bodies to typed errors.

### Task 3.2 — `http/client.dart`

**Source fidelity:** Port the request building and header logic from:
- `clientHeaders.ts` — exact client ID `ec7e38d4-03af-4b58-b131-cfb0495903ab`,
  user agent, origin, referer, auth header construction (`GFNJWT ` prefix vs `Bearer `)
- `request.ts` — `readCloudMatchJson`, `throwIfCloudMatchResponseError`,
  `fetchWithOptionalProxy` (omit proxy for v0.01 — just use plain http.Client)
- `deviceIdentity.ts` — `resolveGfnDeviceIdentity` logic
- `deviceId.ts` — stable device ID generation

**Critical exact constants (port verbatim):**
```dart
const gfnWindowsUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173';
const gfnClientVersion = '2.0.80.173';
const lcarsClientId = 'ec7e38d4-03af-4b58-b131-cfb0495903ab';
const gfnPlayOrigin = 'https://play.geforcenow.com';
const gfnPlayReferer = 'https://play.geforcenow.com/';
const nvidiaFileOrigin = 'https://nvfile';
const nvidiaFileReferer = 'https://nvfile/';
```

Authorization methods (port exactly):
```dart
String gfnJwtAuthorization(String token) => 'GFNJWT $token';
String bearerAuthorization(String token) => 'Bearer $token';
```

BuildGfnLcarsHeaders, buildGfnCloudMatchHeaders, buildNvidiaAuthHeaders — each
must match the exact header map in clientHeaders.ts.

---

## Phase 4: Auth module

### Task 4.1 — `auth/constants.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/constants.ts`.

Exact constants (port verbatim — these are the real NVIDIA OAuth endpoints):
```dart
const authEndpoint = 'https://login.nvgs.nvidia.com/v1/oauth2/authorize';
const tokenEndpoint = 'https://login.nvgs.nvidia.com/v1/oauth2/token';
const clientId = 'e4c2f3b0-2f0f-4e6d-9d5e-3b2f0a8c4e6d';
const deviceCodeEndpoint = 'https://login.nvgs.nvidia.com/v1/oauth2/device/code';
const providerDiscoveryEndpoint = 'https://api.gfn.cf.aws.nvidia.com/provider';
const redirectPorts = [8951, 8961, 8971, 8981, 8991];
const scopes = 'openid profile email offline_access';
const steamDeckClientId = 'd1b8cb7c-5b1f-4b7f-9a5d-2e5e6f8c0d4a';
const steamDeckUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 GFN-SteamDeck/2.0.80.173';
```

### Task 4.2 — `auth/helpers.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/helpers.ts`.

Functions: `toExpiresAt(expiresInSeconds, defaultSeconds = 86400)`,
`isExpired(expiresAt)`, `isNearExpiry(expiresAt, windowMs)`,
`generateDeviceId()` (sha256 of `host:user:opennow-stable`),
`buildAuthHeadersForClient(authClientId, options)`.

### Task 4.3 — `auth/oauth_flow.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/oauthFlow.ts`.

1. **PKCE generation:** `generatePkce()` — exactly replicate the base64url
   (no padding, `-` instead of `+`, `_` instead of `/`) SHA-256 challenge.
   ```dart
   import 'dart:convert' show base64Url;
   import 'package:crypto/crypto' show sha256;
   
   ({String verifier, String challenge}) generatePkce(RandomSource random) {
     final verifierBytes = random.nextBytes(64);
     var verifier = base64Url.encode(verifierBytes).substring(0, 86);
     var challenge = base64Url.encode(sha256.convert(verifier.codeUnits).bytes)
       .replaceAll('=', '');
     return (verifier: verifier, challenge: challenge);
   }
   ```

2. **Auth URL:** `buildAuthUrl(provider, challenge, port)` — construct URL with
   exact params: response_type=code, device_id, scope, client_id, redirect_uri,
   ui_locales=en_US, nonce, prompt=select_account, code_challenge, code_challenge_method=S256, idp_id.

3. **Local callback server:** In OpenNOW this uses node:http to start a local
   server on one of the redirect ports to catch the OAuth redirect. In Dart,
   use `dart:io` `HttpServer`:
   ```dart
   Future<String> waitForAuthorizationCode(int port, {
     required Clock clock,
     Duration timeout = const Duration(minutes: 5),
   }) async {
     final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
     // Wait for GET request with ?code= param, extract code, return it
     // Response with "Authentication complete" HTML, close server
   }
   ```

4. **Code exchange:** Exchange auth code for tokens at `TOKEN_ENDPOINT`:
   ```dart
   Future<AuthTokens> exchangeAuthorizationCode(
     String code, String verifier, int port, String? authClientId
   ) async {
     // POST to tokenEndpoint with form-url-encoded body:
     // grant_type=authorization_code, code, redirect_uri, client_id, code_verifier
     // Parse response -> AuthTokens
   }
   ```

### Task 4.4 — `auth/device_login.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/deviceLogin.ts`.

1. `requestDeviceAuthorization(provider)` — start device code flow.
   POST to `DEVICE_CODE_ENDPOINT` with form body `client_id`, `scope`, `idp_id`.
   Response has device_code, user_code, verification_uri, verification_uri_complete,
   expires_in, interval.

2. `exchangeDeviceCode(attemptId, deviceCode, provider)` — poll for token.
   POST to `TOKEN_ENDPOINT` with `grant_type=device_code`, `device_code`, `client_id`.
   Handle poll statuses: `authorization_pending` -> retry, `slow_down` -> increase interval,
   `expired_token` -> fail, `access_denied` -> fail.

### Task 4.5 — `auth/provider_discovery.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/providerDiscovery.ts`.

Fetch login providers from `PROVIDER_DISCOVERY_ENDPOINT`. Parse provider list,
normalize names. Map to `LoginProvider` list.

### Task 4.6 — `auth/token_refresh.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/tokenRefresh.ts`.

Implement `refreshAuthTokens(session, config)` and `refreshClientTokens(session)`.
POST to `TOKEN_ENDPOINT` with `grant_type=refresh_token`, `client_id`, `refresh_token`.
Handle expired/invalid refresh tokens gracefully.

### Task 4.7 — `auth/persisted_state.dart`

**Source fidelity:** Port from `main/platforms/gfn/auth/persistedAccountState.ts`.

The `PersistedAccountState` manages multiple saved accounts (one active, curated
list of previously-logged-in accounts). It uses `TokenStorage` port to serialize
accounts as JSON. Maps directly to shared_preferences via the port.

### Task 4.8 — `auth/auth_service.dart`

**Source fidelity:** Port of `main/platforms/gfn/auth.ts` (the main AuthService).

Orchestrates all sub-modules: provider discovery, OAuth flow, device login,
token refresh, session validity. Key operations:
- `authenticate(provider, mode)` — starts OAuth or device-code flow
- `getSession(userId?)` — returns current session, auto-refresh if near expiry
- `listSavedAccounts()` — returns saved accounts from persisted state
- `switchAccount(userId)` — switches active account
- `logout()` — clears session state

---

## Phase 5: Catalog

### Task 5.1 — `catalog/graphql.dart`

**Source fidelity:** Port from `main/platforms/gfn/lcarsGraphql.ts`.

Exact endpoint URLs:
```dart
const lcarsGraphqlUrl = 'https://apps.gxn.nvidia.com/graphql';
const lcarsCdnGraphqlUrl = 'https://games.geforce.com/graphql';
```

The GraphQL queries (exact query strings from OpenNOW — these are the real NVIDIA
catalog queries). Port each query: GAME_SECTION_QUERY, PUBLIC_GAMES_QUERY,
LIBRARY_GAMES_QUERY, SEARCH_QUERY. Each must match the OpenNOW TS query string
character-for-character — NVIDIA rejects malformed GraphQL.

Define `fetchGraphQl(endpoint, query, variables, token)` and
`fetchGraphQlPost(endpoint, query, variables, token)`.

### Task 5.2 — `catalog/catalog_service.dart`

**Source fidelity:** Port from `main/platforms/gfn/games.ts`, `catalogBrowse.ts`,
`publicGames.ts`, `libraryGames.ts`.

Key operations:
- `fetchMainGames(vpcId, locale)` — calls Lcars query for front page panels
- `fetchPublicGames(vpcId, locale, filterIds, sortOrderId)` — paginated catalog browse
- `fetchLibraryGames(libraryPages)` — user's library (requires auth)
- `fetchAppData(appId)` — single game details

### Task 5.3 — `catalog/app_mapper.dart`

**Source fidelity:** Port from `main/platforms/gfn/gameAppMapper.ts`.

Maps VPC IDs to region endpoints. Contains the exact VPC ID constants. Key:
- `resolveVpcIdForRegion(region)` — maps stream region to VPC ID
- `getStreamRegionGamesUrl(region)` or normalize VPC -> base URL

### Task 5.4 — `catalog/features.dart`

**Source fidelity:** Port from `main/platforms/gfn/gameFeatures.ts`.

Parses the GFN server response for game features: supported controls, streaming
features, cloud saves, etc.

---

## Phase 6: Cloudmatch + Session + Signaling + PrintedWaste

### Task 6.1 — `cloudmatch/types.dart`

Port the CloudMatch request/response types from `main/platforms/gfn/types.ts`.

### Task 6.2 — `cloudmatch/features.dart`

**Source fidelity:** Port from `cloudmatchFeatures.ts`:

```dart
const appLaunchModeWireValues = {'default': 1, 'gamepadFriendly': 2, 'touchFriendly': 3};
```

Functions: `appLaunchModeWireValue(mode)`, `buildRequestedStreamingFeatures(settings)`,
`shouldRequestReflex(settings)`, `shouldEnableInGameSettingsPersistence(settings)`.

### Task 6.3 — `cloudmatch/session_request.dart`

**Source fidelity:** Port from `cloudmatchSessionRequest.ts`.

Functions: `buildSessionRequestBody(settings, gameId, region)`,
`buildClaimRequestBody(sessionInfo, settings)`,
`createNetworkTestSession(vpcId)`. 

Build the exact `CloudMatchRequest` JSON body format including:
- `sessionRequestData`: clientVersion, deviceInfo, gpuInfo, requestedStreamingFeatures
- `appLaunch` configuration: mode, settings, gameId, features, HID devices
- `userPreferences`: keyboard layout, game language, gamepad mapper

### Task 6.4 — `cloudmatch/transport.dart`

**Source fidelity:** Port from `cloudmatchTransport.ts`.

Functions for constructing cloudmatch API URLs:
- `normalizeCloudMatchBaseUrl(baseUrl)`
- `resolveCreateSessionBase(baseUrl)`
- `resolvePollStopBase(baseUrl)`
- `resolveStreamingBaseUrl(baseUrl)`
- `isZoneHostname(hostname)`
- `fetchCloudMatch(url, body, token)` — POST to cloudmatch endpoint
- `extractServerInfoRegionBases(serverInfo)`

And the cloudmatch API endpoints pattern: `https://{zone}.cloudmatch.gfn.{env}.nvidia.com/...`

### Task 6.5 — `cloudmatch/signaling.dart`

**Source fidelity:** Port from `cloudmatchSignaling.ts`.

Functions for processing signaling responses:
- `resolveSignaling(cloudMatchResponse)` — extracts signaling URL/connection info
- `normalizeIceServers(iceServers)` — normalizes ICE server list
- `isReadySessionStatus(sessionStatus)` — checks if session is ready
- `streamingServerIp(serverInfo, serverPools)` — resolves streaming server IP

### Task 6.6 — `cloudmatch/session_parsing.dart`

**Source fidelity:** Port from `cloudmatchSessionParsing.ts`.

Functions:
- `toSessionInfo(cloudMatchResponse, gameInfo, settings)` — extracts SessionInfo from CM response
- `extractQueuePosition(response)` — parses queue ETA/position
- `extractSessionQueuePosition(response)` — session-specific queue info
- `extractNegotiatedStreamProfile(response)` — what the server negotiated for streaming
- `extractAdState(response)` — ad/reward state
- `echoedSessionAppLaunchMode(response)` — what mode the server echoed
- `normalizeStreamingFeatures(response)` — parse server-returned streaming features

### Task 6.7 — `cloudmatch/cloudmatch_service.dart`

**Source fidelity:** Port of `cloudmatch.ts`.

The main cloudmatch orchestration:
- `requestSession(gameId, settings, region)` — creates a new session request,
  returns session queue info
- `pollSession(sessionId)` — polls for session readiness, returns SessionInfo
- `claimSession(sessionId)` — claims the allocated session
- `getActiveSessions()` — returns list of currently active sessions

### Task 6.8 — `session/lifecycle.dart`

**Source fidelity:** Port the session lifecycle from the session management in
`cloudmatch.ts` (session conflict handling, resume), `gameAppMapper.ts` (VPC),
and `shared/gfn/session.ts` types.

Session state machine:
```
Idle -> Requesting -> Queued -> Allocating -> Ready -> Streaming (future)
  |         |            |           |            |
  +-> Error  +-> Cancel  +-> Cancel  +-> Cancel   +-> Stop
```

States (enum `SessionState`): idle, requesting, queued, allocating, ready, error.

### Task 6.9 — `signaling/signaling_client.dart`

**Source fidelity:** Port from `renderer/src/platforms/gfn/signaling.ts` (the
signaling WebSocket client) and shared signaling types.

Key operations:
- `connect(signalingUrl, sessionId)` — WebSocket connect to signaling endpoint
- `sendIceCandidate(candidate)` — send ICE candidate to signaling server
- `sendAnswer(sdp)` — send SDP answer to signaling server
- `receiveOffer(callback)` — listen for incoming SDP offer
- `close()` — disconnect

Use `WebSocketChannel` from `web_socket_channel` package. Port exact message
format from OpenNOW's signaling.ts (JSON message types).

The WebSocket endpoint is derived from the cloudmatch response: `resolveSignaling`
extracts the signaling URL. Message format matches NVIDIA's proprietary signaling
protocol that OpenNOW reverse-engineered — replicate the message shapes exactly.

### Task 6.10 — `printedwaste/printed_waste_service.dart`

**Source fidelity:** Port from `main/services/printedWaste.ts`.

Exact endpoints:
```dart
const printedWasteQueueUrl = 'https://api.printedwaste.com/gfn/queue/';
const printedWasteServerMappingUrl = 'https://remote.printedwaste.com/config/GFN_SERVERID_TO_REGION_MAPPING';
```

Functions: `fetchPrintedWasteQueue()`, `fetchPrintedWasteServerMapping()`.
Response parsing: the queue returns `{status: bool, data: {zoneId: {QueuePosition, "Last Updated", ...}}}`.
Server mapping returns `{status: bool, data: {serverId: {key, value, displayName, ...}}}`.
User-Agent header uses app version.

---

## Phase 7: Debug shell app

### Task 7.1 — `lib/main.dart`

Wire ports with `shared_preferences` and `url_launcher`:
```dart
void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget { ... }
```

Implement `TokenStorage` using shared_preferences:
```dart
class _PrefsTokenStorage implements TokenStorage {
  static const _key = 'gfn_tokens';
  late SharedPreferences _prefs;
  
  Future<void> init() async { _prefs = await SharedPreferences.getInstance(); }
  
  @override
  Future<Map<String, String>?> readTokens() async {
    final json = _prefs.getString(_key);
    if (json == null) return null;
    return Map<String, String>.from(jsonDecode(json));
  }
  
  @override
  Future<void> writeTokens(Map<String, String> tokens) async {
    await _prefs.setString(_key, jsonEncode(tokens));
  }
  
  @override
  Future<void> clearTokens() async {
    await _prefs.remove(_key);
  }
}
```

Implement `BrowserLauncher` using url_launcher:
```dart
class _UrlLauncherBrowser implements BrowserLauncher {
  @override
  Future<void> openUrl(String url) async {
    await launchUrl(Uri.parse(url));
  }
}
```

### Task 7.2 — `lib/app.dart`

Master `MaterialApp` with dark theme. `Navigator` for page routing (no go_router).
App bar always shows a "Log viewer" action (pushes log viewer page).

### Task 7.3 — `lib/pages/log_viewer_page.dart`

A `ScrollingListView` of log entries. Each entry shows level badge, category,
message, timestamp. Level filter at top. Copy button.

The app should hold an in-memory `LogSink` implementation that collects the last
~500 entries (ring buffer) and exposes them as a `ValueNotifier<List<LogEntry>>`
so the log viewer is reactive.

### Task 7.4 — `lib/pages/login_page.dart`

Two sections:
1. **OAuth login** — "Login with browser" button that calls
   `authService.authenticate(provider, 'oauth')`, which opens the browser.
   Status text shows "Waiting for browser redirect..." then "Authenticated!".

2. **Device code login** — "Device code login" button calls
   `authService.authenticate(provider, 'device_code')`. Shows QR code
   (`qr_flutter` widget) with the `verificationUri`, polling status
   ("Scan code on phone", "Approved!", "Expired", etc.).

After successful login, navigates to the main page.

### Task 7.5 — `lib/pages/session_status_page.dart`

Shows current account info:
- Display name, email, membership tier
- Token expiry countdown
- "Refresh session" button
- "Logout" button
- List of saved accounts with switch button for each

### Task 7.6 — `lib/pages/catalog_page.dart`

Simple grid/list of catalog games:
- Fetch catalog from `catalogService.fetchMainGames(...)`
- Show game title + thumbnail (use NetworkImage)
- Tap to see game_detail_page.dart with JSON dump of selected game
- Fetch library with toggle between "All" and "My Library"

### Task 7.7 — `lib/pages/queue_page.dart`

Shows PrintedWaste data:
- Queue wait times per region (zone ID, queue position, last updated)
- Server-to-region mapping (server ID -> region name, "nuked" status)
- Raw JSON toggle button

### Task 7.8 — `lib/pages/session_page.dart`

Session lifecycle viewer:
- "Launch Game" button (shows text field or picks from catalog)
- State machine display: current state highlighted, transitions logged
- Queue ETA counter if queued
- "Stop session" button
- Signaling connection status
- All transition events logged in a scrollable timeline

### Task 7.9 — `lib/shared/api_dump.dart`

Generic widget:
```dart
class ApiDumpWidget extends StatelessWidget {
  final String title;
  final AsyncSnapshot<dynamic>? snapshot;
  final Map<String, dynamic>? data;
  // Renders title + pretty-printed JSON
}
```

Used by game_detail_page, queue_page, and session_page for raw data inspection.

---

## Build & verify

```bash
# After each phase:
dart analyze packages/gfn_core/      # Must be clean
flutter analyze                       # Must be clean
```

No build/compile/run steps — analysis only, per user preference.

## Phase order (dependency chain)

1. Scaffolding + ports + logging  (Tasks 1.1-1.5)
2. Models (Tasks 2.1-2.7)
3. HTTP layer + errors (Tasks 3.1-3.2)
4. Auth (Tasks 4.1-4.8) — can start testing device login live
5. Catalog (Tasks 5.1-5.4) — needs auth
6. Cloudmatch + Session + Signaling + PrintedWaste (Tasks 6.1-6.10) — needs auth
7. Debug shell app (Tasks 7.1-7.9) — wraps everything

---

## OpenNOW source file index (for faithful porting)

| Module | OpenNOW source to port from |
|--------|---------------------------|
| HTTP headers | `main/platforms/gfn/clientHeaders.ts` |
| Device identity | `main/platforms/gfn/deviceIdentity.ts` |
| Device ID | `main/platforms/gfn/deviceId.ts` |
| Auth constants | `main/platforms/gfn/auth/constants.ts` |
| Auth helpers | `main/platforms/gfn/auth/helpers.ts` |
| OAuth flow | `main/platforms/gfn/auth/oauthFlow.ts` |
| Device login | `main/platforms/gfn/auth/deviceLogin.ts` |
| Token refresh | `main/platforms/gfn/auth/tokenRefresh.ts` |
| Provider discovery | `main/platforms/gfn/auth/providerDiscovery.ts` |
| Auth service | `main/platforms/gfn/auth.ts` |
| Account manager | `main/platforms/gfn/auth/accountManager.ts` |
| Persisted account state | `main/platforms/gfn/auth/persistedAccountState.ts` |
| Session validity | `main/platforms/gfn/auth/sessionValidity.ts` |
| User info | `main/platforms/gfn/auth/userInfo.ts` |
| Enrichment caches | `main/platforms/gfn/auth/enrichmentCaches.ts` |
| Subscription | `main/platforms/gfn/subscription.ts` |
| GFN GraphQL | `main/platforms/gfn/lcarsGraphql.ts` |
| Games | `main/platforms/gfn/games.ts` |
| Catalog browse | `main/platforms/gfn/catalogBrowse.ts` |
| Public games | `main/platforms/gfn/publicGames.ts` |
| Library games | `main/platforms/gfn/libraryGames.ts` |
| Game app mapper | `main/platforms/gfn/gameAppMapper.ts` |
| Game features | `main/platforms/gfn/gameFeatures.ts` |
| Cloudmatch request | `main/platforms/gfn/cloudmatchSessionRequest.ts` |
| Cloudmatch parsing | `main/platforms/gfn/cloudmatchSessionParsing.ts` |
| Cloudmatch transport | `main/platforms/gfn/cloudmatchTransport.ts` |
| Cloudmatch signaling | `main/platforms/gfn/cloudmatchSignaling.ts` |
| Cloudmatch features | `main/platforms/gfn/cloudmatchFeatures.ts` |
| Cloudmatch types | `main/platforms/gfn/types.ts` |
| Cloudmatch | `main/platforms/gfn/cloudmatch.ts` |
| Error codes | `main/platforms/gfn/errorCodes.ts` |
| HTTP request | `main/platforms/gfn/request.ts` |
| PrintedWaste | `main/services/printedWaste.ts` |
| Shared auth types | `shared/gfn/auth.ts` |
| Shared session types | `shared/gfn/session.ts` |
| Shared catalog types | `shared/gfn/catalog.ts` |
| Shared stream types | `shared/gfn/stream.ts` |
| Shared API types | `shared/gfn/api.ts` |
| Shared subscription types | `shared/gfn/subscription.ts` |
| Shared printedWaste types | `shared/gfn/printedWaste.ts` |
| Shared keyboard types | `shared/gfn/keyboard.ts` |
| Shared device types | `shared/gfn/device.ts` |
| Shared native streamer | `shared/gfn/nativeStreamer.ts` |
| Shared overall keyboard | `shared/gfn/keyboard.ts` |
| Shared endpoints | `shared/gfn/endpoints.ts` |
| Cloud G-Sync | `shared/cloudGsync.ts` |
| Keyboard layout | `shared/gfn/keyboard.ts` |

## Final verification

After all phases complete:
```bash
dart analyze packages/gfn_core/
flutter analyze
```

Manual acceptance per spec:
- Device-code login: QR shown -> user approves -> session persisted -> relaunch restores
- OAuth: browser opens NVIDIA -> redirect back -> authenticated
- Catalog + library load real data
- PrintedWaste queue + server map load
- Launch game -> full state machine visible (request->queue->allocate->ready)
- Signaling connected, session at "ready" (no video renders)