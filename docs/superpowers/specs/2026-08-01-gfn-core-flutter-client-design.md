# Design: OpenNOW-derived GFN client — pure-Dart core + Flutter debug shell (v0.01)

Date: 2026-08-01

## Purpose

Build a new, serious Flutter-based client for NVIDIA GeForce NOW (GFN) that reuses the
protocol logic OpenNOW already figured out, but with our own opinionated UI and features
(it is NOT a UI/feature port of OpenNOW). v0.01 covers the full GFN *server-side* surface;
video streaming, input capture, and client-side post-processing are explicitly out of scope
and deferred to a later version.

The goal for v0.01 is a working, live-tested GFN backend layer plus a barebone debug shell
that exercises it end-to-end — NOT a polished product UI.

## Out of scope (v0.01)

- Video streaming / WebRTC playback, input capture, video post-processing shaders
- Android/iOS (Linux desktop only for now; architecture must stay portable)
- Polished/opinionated product UI
- Automated tests (manual verification only; user explicitly declined for v0.01)
- Discord RPC, telemetry/PostHog, auto-updater, native Rust streamer integration

## Decisions (from brainstorming)

- **Build order:** Approach 1 — pure-Dart core package first, then barebone debug shell UI.
- **Login:** both OAuth (browser PKCE) and device-code (QR) — both are server-side flows.
- **Platform:** Linux only for v1; structure keeps Windows/macOS/mobile open.
- **Storage:** `shared_preferences` only. `flutter_secure_storage` was researched and is
  still unreliable on Linux (open issue #778 — locked/unavailable keyring on SSH, headless,
  WSL2, KDE/KWallet, Hyprland, CI/Docker), so it was explicitly rejected.
- **Development loop:** live-first debugging against real NVIDIA endpoints, with verbose
  logging and an on-screen log viewer. No mocks/fixtures harness.
- **Dependency budget (strict):** no build_runner, no Riverpod/Bloc/Provider, no codegen
  (even in the finished app). Plain StatefulWidget + setState + ValueNotifier if needed.
- **Tests:** skipped for v0.01 by explicit user choice (LLM hallucination risk, manual test).

## Architecture

```
next_client/                      (repo root = Flutter app / debug shell)
├── lib/                          app shell
├── packages/
│   └── gfn_core/                 PURE DART — zero Flutter imports
│       ├── lib/
│       │   ├── gfn_core.dart     (barrel)
│       │   └── src/
│       │       ├── auth/         OAuth PKCE, device-code, token refresh,
│       │       │                 provider discovery, persisted state
│       │       ├── catalog/      catalog browse, public/library games, app mapper
│       │       ├── cloudmatch/   session request, queue + session parsing
│       │       ├── session/      session lifecycle state machine, conflict, selection
│       │       ├── signaling/    WebSocket signaling client
│       │       ├── printedwaste/ PrintedWaste queue + server mapping
│       │       ├── http/         HTTP client wrapper, headers, device identity, errors
│       │       ├── models/       DTOs + hand-written JSON (fromJson/toJson)
│       │       ├── logging/      LogSink, levels, token redaction
│       │       └── ports.dart    TokenStorage, BrowserLauncher, Clock, Random
│       └── test/
```

### Dependencies (total 6)

- `gfn_core`: `http`, `web_socket_channel`, `crypto` (PKCE SHA-256) — nothing else
- App: `shared_preferences`, `url_launcher`, `qr_flutter`

No codegen, no state-management framework, no DI framework, no router package (plain
`Navigator`).

### Ports (ports.dart)

Platform-specific behavior is behind interfaces so the core is headless-testable and
portable:
- `TokenStorage` — read/write/delete tokens (app implements with shared_preferences)
- `BrowserLauncher` — open a URL in the system browser (OAuth flow)
- `Clock` — time source (token expiry math)
- `Random` — secure randomness (PKCE)

## Data flow (server-side surface, in build order)

1. **auth/** — OAuth PKCE browser flow + device-code login. Produces tokens, persisted via
   `TokenStorage`. Handles refresh + session validity.
2. **http/** — one client injecting NVIDIA client headers + auth header, builds endpoints,
   maps failures to typed `SessionError` (mirrors OpenNOW `gfnErrorMessages`/`errorCodes`).
3. **catalog/** — auth'd HTTP client → catalog browse, public games, library.
4. **cloudmatch/** — session request → queue/ETA → session allocation. PrintedWaste is a
   separate public API (no auth) for queue + server-to-region mapping.
5. **session/** — lifecycle state machine: requested → queued → allocated → ready. Consumes
   cloudmatch results; handles conflicts.
6. **signaling/** — WebSocket client; connects session, sends SDP answer (reusing OpenNOW's
   SDP-munging logic), receives ICE candidates. Ends at "session ready" — no video/input.

Error handling: every network/protocol failure → typed `SessionError` with OpenNOW's GFN
error-code mapping, surfaced to UI + logged with context.

Logging: `logging/` with `LogSink` interface; app wires console + on-screen viewer. Tokens
and auth headers are auto-redacted in every log line and on screen.

## App shell (debug harness, not product UI)

Plain Navigator + StatefulWidget + setState:

```
lib/
├── main.dart                 wires ports (shared_preferences, url_launcher), boots logger
├── app.dart                  MaterialApp, dark theme, single Navigator
├── logging/log_viewer_page.dart    on-screen scrolling log, level filter, copy
├── auth/login_page.dart           choose OAuth or device-code (show QR)
├── auth/session_status_page.dart  account, token validity, refresh state
├── catalog/catalog_page.dart      barebone grid/list of games
├── catalog/game_detail_page.dart  JSON dump of selected game
├── queue/queue_page.dart          PrintedWaste queue + server map, raw JSON toggle
├── session/session_page.dart      state machine viewer + timings + stop button
└── shared/api_dump.dart           generic JSON pretty-printer widget
```

Log viewer reachable from every page (app-bar action).

## v0.01 acceptance criteria (manual verification)

1. Device-code login: QR shown → user approves → session persisted → relaunch restores it
2. OAuth: browser opens NVIDIA → redirect back → authenticated
3. Catalog + library load real NVIDIA data
4. PrintedWaste queue + server map load
5. Launch a game → full state machine visible (request → queue with ETA → allocated →
   ready) with logged timings
6. Signaling connected, session reaches "ready" — no video renders (correct for v0.01)

## Verification

- `dart analyze` on `gfn_core` — zero warnings (free compiler safety; not a test suite)
- `flutter analyze` on the app shell
- Manual live smoke test per acceptance list above
