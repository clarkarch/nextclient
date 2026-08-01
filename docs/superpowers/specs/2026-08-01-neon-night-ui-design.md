# Neon Night — next_client UI Design

Date: 2026-08-01
Status: Approved (ASCII mockups reviewed)

## Vision

Gaming dark theme with an electric blue neon aesthetic. Modern launcher look
(Battle.net / Riot family), explicitly **not** Material Design and **not** GFN's
teal-green identity. Zero new runtime dependencies (no riverpod/bloc/codegen).

## Constraints

- Only features that touch the NVIDIA server or community services
  (printedwaste) are in scope. No client-side features.
- Minimize dependencies: use only what `pubspec.yaml` already has
  (`http`, `shared_preferences`, `url_launcher`, `qr_flutter`).
- Plain `ChangeNotifier` + `ListenableBuilder` for shared state. No codegen.

## Palette

| Token            | Value      | Use                                   |
| ---------------- | ---------- | ------------------------------------- |
| bg-a / bg-b      | #08080d / #0d0d14 | layered background                 |
| card             | #12121c    | cards / panels                        |
| ink / ink-soft   | #f2f7ff / #9fb0c9 | text hierarchy                  |
| ink-muted        | #5c6b85    | captions                              |
| accent (blue)    | #00d9ff    | primary neon, focus, glow             |
| accent-violet    | #8b5cf6    | secondary accent, gradients           |
| success          | #34d399    | owned / ready (kept cool, no GFN green accent) |
| warning          | #fbbf24    | queue / warnings                      |
| error            | #f87171    | errors                                |

Cards use layered dark shadows + a soft blue glow on hover/focus. Radii 12-20px.

## Architecture

- `AppServices` container (existing) gains `UserSettings` (ChangeNotifier) and
  `SessionController` (ChangeNotifier wrapping `SessionLifecycle`).
- `lib/theme/neon.dart` — palette + `ThemeData` override.
- `lib/widgets/` — reusable kit: `NeonButton`, `NeonCard`, `NeonChip`,
  `SectionHeader`, `GameArt`, `GameCard`, `NeonRail`.
- `lib/pages/` — Login, Home, RecentlyPlayed, Library, GameDetails, Launcher,
  PrintedWaste modal, Stream, Settings (+ category sub-screens).
- Navigation: persistent left neon rail (Home / Library / Settings) +
  `Navigator.push` for details, launcher, settings sub-screens, stream surface.

## Screens

1. **Login** — neon-branded panel; OAuth browser login + device-code QR
   (`qr_flutter`).
2. **Home** —
   - Featured carousel: `PageView`, 16:9, `MARQUEE_HERO_IMAGE`, auto-advance,
     dots, title overlay + Play.
   - Recently Played: sliding 16:9 row, See All → grid page.
   - All Games: responsive 16:9 grid (all fetched, no sliding / no see-all).
3. **Library** — 16:9 grid of owned games.
4. **Game Details** — 16:9 hero, title, publisher, tier badge, description +
   screenshots (via `fetchGameDetails`), glowing Play.
5. **Launcher** — game header, region selector (name/url), stream quality
   summary, Launch.
6. **PrintedWaste** — free-tier queue-server picker (queue position / ETA,
   nuked flag, 4080/5080 badges), confirm → launch.
7. **Stream** — full-screen: lifecycle progress (requesting → queued w/ position
   → allocating → ready) then "now playing" surface (server IP, session id,
   GPU, Stop). Session-ready only — no video render yet.
8. **Settings** — category list → nested screens: **Stream Quality** (res/fps/
   bitrate/codec/color/L4S/G-Sync), **Region**, **Language & Input**, **Account**
   (user info + logout). Only options the backend touches NVIDIA with.

## Backend additions (gfn_core, NVIDIA-touching)

- `GameDetails` model + `CatalogService.fetchGameDetails(appId)` using the
  existing `appDataForAppId` persisted query (description, genres, screenshots,
  box art, developer).
- `CatalogService.fetchRecentlyPlayed()` — LIBRARY panel with
  `withLibraryTime: true`, sorted by `lastPlayedDate`, null-filtered.
- Image URL helpers — pick first landscape key
  (`MARQUEE_HERO_IMAGE → HERO_IMAGE → TV_BANNER → KEY_ART`), append
  `;f=webp;w=` optimization for `img.nvidiagrid.net`.

## Data flow

App start → `AppServices.create()` → auth gate: shell if `getSession() != null`,
else Login. Home fetches featured + main games in parallel; Library fetches on
entry. Launch: build `StreamSettings` from `UserSettings` → optional
printedwaste picker (free tier) → `SessionController.launch()` → Stream surface.

## Verification

- `flutter analyze` clean.
- `flutter test` green — widget tests for `GameCard`, `GameArt`, carousel,
  settings sub-screens; gfn_core unit tests for image helpers + parsers.
