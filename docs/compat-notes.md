# Hivefin ↔ Jellyfin client compatibility notes

Target clients: **Jellyfin Web** and **official Jellyfin Android TV**, shapes aligned with Jellyfin **10.9.x**.

Discovery identity (required by `@jellyfin/sdk` / jellyfin-vue): `ProductName` is exactly `"Jellyfin Server"` and `Version` is a Jellyfin API compatibility string (default `12.0.0`). Display name remains `ServerName: "Hivefin"`. Real app version is `Hivefin.Jellyfin.SystemInfo.hivefin_version/0`.

## Live Android TV verification (operator)

There is **no physical Android TV or live Jellyfin proxy** in the automated CI environment.

**Live verification remains a manual operator step** when a device/emulator and a running Hivefin instance are available:

1. Point the official Jellyfin Android TV app at the Hivefin host (manual server entry).
2. Exercise the golden path below.
3. Log every 4xx / blank screen / crash and file a Task 11-style gap with a failing HTTP test first.

Until then, HTTP regression tests under `test/hivefin_web/controllers/jellyfin/android_tv_gaps_test.exs` and the fixture pack in `test/support/fixtures/jellyfin/` are the automated stand-in.

## Golden-path checklist (Android TV)

Operator checklist against a running Hivefin:

| Step | Expected | Hivefin status |
|------|----------|----------------|
| Server discovery / manual host | App accepts host:port | Manual |
| Login (`AuthenticateByName` + MediaBrowser headers) | Token + `SessionInfo` with `Id` | Automated |
| Post-login shell (`System/Info`, `DisplayPreferences`, `Sessions`, capabilities) | No 404 shell breakers | Automated |
| Library views (`Users/{id}/Views`) | Movies / TV roots | Automated (Task 5) |
| Browse movies / TV (`Items`, Seasons, Episodes) | Lists load | Automated (Tasks 5–6) |
| Item detail + images | Metadata/images when present | Partial (images/TMDB later) |
| Play (`PlaybackInfo` + stream) | Direct play or remux/transcode | Automated (Tasks 7–8) |
| Pause / progress (`Sessions/Playing*`) | UserData ticks update | Automated (Task 9) |
| Resume (`Users/{id}/Items/Resume`) | In-progress row when ticks &gt; 0 | Automated |
| Stop | Position persisted; stream ends | Automated |
| Next up (`Shows/NextUp`) | Empty list (no crash) | Stub (empty) |

## Known Hivefin gaps vs full Jellyfin clients

### Implemented for TV shell (Task 11)

| Endpoint | Behavior |
|----------|----------|
| `GET /Sessions` | Lists access-token device sessions as `SessionInfoDto[]` |
| `POST /Sessions/Capabilities` | 204 no-op |
| `POST /Sessions/Capabilities/Full` | 204 no-op |
| `GET /DisplayPreferences/{id}` | Default prefs + empty `CustomPrefs` (not 404) |
| `POST /DisplayPreferences/{id}` | 204 no-op |
| `GET /Users/{id}/Items/Resume` | QueryResult of in-progress items (or empty) |
| `GET /Shows/NextUp` | Empty QueryResult (stub) |
| `GET /System/Info` | Includes `StartupWizardCompleted`, `WebSocketPortNumber`, `HasUpdateAvailable`, etc. |

### Deferred / not implemented

| Area | Notes |
|------|-------|
| **WebSocket** | Not required for HTTP play/progress. Deferred until a golden client requires live session events. Session domain remains source of truth; no `Phoenix.Channel` yet. |
| Real NextUp / smart home rows | Empty list only; no series “continue episode” ranking |
| Remote control / cast | Sessions report `SupportsRemoteControl: false` |
| Live TV, plugins, SyncPlay | Non-goals |
| Full admin dashboard APIs | Non-goals |
| Search, genres, people | On demand if clients block on 404 |
| Quick Connect | Not implemented; use username/password |
| Branding images / splash | Not implemented |
| Persisted DisplayPreferences | Defaults only; POST is discarded |

### Domain vs adapter

- **Domain:** access tokens as device sessions; `UserData.list_resume/2` for continue watching.
- **Adapter:** DTO shaping, 204 capability/prefs stubs, empty NextUp QueryResult.
- Prefer adapter stubs when data is not required for play.

## Fixture pack

See `test/support/fixtures/jellyfin/README.md` for capture/redaction and shape tests (`Hivefin.JellyfinShape`). Android TV fixtures are hand-authored until live proxy capture is possible.

## Related tests

```bash
mix test test/hivefin_web/controllers/jellyfin/android_tv_gaps_test.exs
mix test test/hivefin_web/compat
```
