# Hivefin Design Document

**Date:** 2026-08-06  
**Status:** Draft for review  
**Codename:** Hivefin — Jellyfin-compatible media server in Elixir

## 1. Summary

Hivefin is a single-node, self-hosted media server written in Elixir that speaks enough of the **Jellyfin client API** for official clients to work against it. Internally it is a domain-first Elixir system: libraries, items, users, and playback sessions are native domain models; Jellyfin HTTP (and later WebSocket) is a **translation adapter**, not the core architecture.

**v1 product slice**

| Dimension | Choice |
|-----------|--------|
| Compatibility | Stock Jellyfin clients (not a custom protocol) |
| Media types | Movies + TV only |
| Deployment | Single-node self-host |
| Database | PostgreSQL |
| Playback | Direct play / remux first; FFmpeg transcode when needed |
| Transcode hardware | HW encode in v1 (NVENC / VAAPI / VideoToolbox) with CPU fallback |
| Golden clients | Jellyfin Web + one TV client (default: Android TV Jellyfin) |
| Primary motivation | Reliability and ops: BEAM supervision, failure isolation, observability |

**Non-goals (v1)**

- Multi-node BEAM clustering or distributed library storage
- Music, photos, books, live TV / DVR
- Full Jellyfin admin / plugin / dashboard feature parity
- LDAP / SSO / parental controls
- First-party custom client (stock Jellyfin apps only)
- Plugin marketplace

## 2. Goals and success criteria

### Goals

1. **Client-compatible:** Jellyfin Web and the chosen TV client can authenticate, browse movies/TV, play (direct or transcode), and resume.
2. **Reliable under failure:** A failed library scan, metadata provider timeout, or single FFmpeg crash must not take down HTTP or other streams.
3. **Operable:** Config via env/runtime, health endpoints, structured logs, optional Prometheus metrics, graceful shutdown of transcoder children.
4. **Honest scope:** Prefer a smaller API surface that works over claiming full Jellyfin version parity.

### Success criteria (v1 exit)

- [ ] Admin user can be bootstrapped; Web login works.
- [ ] Movie and TV libraries can be added and scanned from local paths.
- [ ] Web browses libraries, series/season/episode trees, and item detail with images.
- [ ] Playback works: direct play when possible; HW-accelerated transcode when required; progress/resume persists.
- [ ] Chosen TV client completes the same core loop.
- [ ] Process isolation demonstrated: kill a transcode session or fail a scan without restarting the node for other traffic.
- [ ] Compatibility fixture tests cover critical DTO shapes for tiers 0–2 endpoints.

## 3. Architecture

### 3.1 High-level diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Clients: Jellyfin Web · TV app (Android TV / similar)       │
└────────────────────────────┬────────────────────────────────┘
                             │ HTTP (+ WebSocket later)
┌────────────────────────────▼────────────────────────────────┐
│  Phoenix edge (Bandit)                                       │
│  Auth plugs · Jellyfin route adapter · Static / HLS / stream │
└────────────────────────────┬────────────────────────────────┘
                             │ domain API (Elixir modules)
┌────────────────────────────▼────────────────────────────────┐
│  Domain core                                                 │
│  Library · Identity/metadata · Users · Playback sessions     │
└───┬─────────────────┬──────────────────┬────────────────────┘
    │                 │                  │
┌───▼────┐     ┌──────▼──────┐    ┌──────▼──────┐
│ Scanner │     │  Metadata  │    │  Playback   │
│ (files) │     │  providers │    │  + FFmpeg   │
│ OTP     │     │  (TMDB…)   │    │  Port/OS    │
└───┬────┘     └──────┬──────┘    └──────┬──────┘
    │                 │                  │
    └────────────┬────┴──────────────────┘
                 ▼
         Ecto + PostgreSQL          media on local filesystem
```

### 3.2 Approach

**Domain-first core + Jellyfin adapter**, with compatibility fixtures guiding which endpoints ship first.

- Domain owns identity, library graph, user data, and playback policy.
- `Hivefin.Jellyfin` maps domain structs → Jellyfin JSON (`BaseItemDto`, `PlaybackInfo`, etc.).
- Controllers never return raw Ecto schemas.

### 3.3 Supervision and failure isolation

| Area | Responsibility | Failure mode |
|------|----------------|--------------|
| `HivefinWeb` | HTTP, auth | Restart listeners only |
| `Hivefin.Library` | Items, queries | DB errors isolated |
| `Hivefin.Scanner` | Walks, probe enqueue | Job fails; library remains consistent |
| `Hivefin.Metadata` | Provider fetch/cache | Soft-fail to unidentified |
| `Hivefin.Playback` | Sessions, remux/transcode | One FFmpeg dies; others continue |
| `Hivefin.MediaInfo` | ffprobe cache | Regenerable |

Application startup verifies: Postgres connectivity, configured media roots (warn if missing), `ffmpeg`/`ffprobe` on `PATH` (or configured paths), and HW encoder probe results (log available accelerators).

### 3.4 Technology baseline

| Layer | Choice |
|-------|--------|
| Language / runtime | Elixir on BEAM |
| HTTP | Phoenix + Bandit |
| DB | PostgreSQL via Ecto |
| Jobs | Start with supervised tasks + DB-backed job rows; introduce Oban if durability/retry UX demands it |
| Probe / transcode | ffprobe + FFmpeg as OS processes under OTP |
| Password hashing | argon2 |
| Images | Local cache directory on disk |

## 4. Domain model

### 4.1 Entities

| Entity | Role |
|--------|------|
| **Library** | Root with path(s), type (`movies` \| `tv`), scan options |
| **Item** | Polymorphic node: `movie`, `series`, `season`, `episode` |
| **MediaSource** | File binding: path, container, size, mtime, streams |
| **MediaStream** | Video / audio / subtitle stream metadata from probe |
| **Person** / **ItemPerson** | Cast/crew with role |
| **Image** | Poster/backdrop/primary; local path and/or remote URL |
| **User** | Local account; password hash; admin flag |
| **UserData** | Per-user played flag, position ticks, rating, etc. |
| **Session** | Client device session (Jellyfin device headers) |
| **PlaybackSession** | Active stream: method, quality, FFmpeg child ref |
| **ScanJob** | Scan progress, errors, last completed_at |
| **AccessToken** | Opaque token bound to user + device |

### 4.2 Hierarchy

```
Series
 └── Season (index)
      └── Episode (index) ── MediaSource(s)
Movie ── MediaSource(s)
```

- Primary keys are **Hivefin UUIDs**.
- Jellyfin API `Id` fields use those UUIDs (string form clients already expect).
- External IDs (TMDB, IMDB, TVDB) are secondary attributes for matching, not PKs.

### 4.3 Mapping boundary

```
Ecto / domain structs  →  Hivefin.Jellyfin.Dto  →  JSON
```

DTO modules own PascalCase field names and Jellyfin-specific nesting (`UserData`, `ImageTags`, `MediaSources`, `ProviderIds`).

### 4.4 Multi-version media

v1 supports **multiple MediaSources per item** when discovered (e.g. two files for one movie), exposed via Jellyfin `MediaSources` on `PlaybackInfo`. Rich “editions” UX is not a separate product feature beyond what clients already show from MediaSources.

## 5. Library scanning

### 5.1 Pipeline

1. Walk library roots with configurable ignore patterns.
2. Classify paths using Jellyfin-like layout conventions:
   - **Movies:** `Movie Name (Year)/...` or single-file movie folders.
   - **TV:** `Series/Season NN/Episode files` (and common variants documented in implementation).
3. Upsert `MediaSource` by absolute path; if size/mtime changed → re-probe.
4. Attach or create `Item` graph (series/season/episode or movie).
5. Enqueue metadata refresh for new or unmatched items.
6. Mark missing sources when files disappear; retain `UserData` until an explicit cleanup policy runs (default: soft-missing, no immediate hard delete).

### 5.2 Concurrency and control

- One active **full scan** per library (or a global concurrency limit).
- Scans are **cancellable** (GenServer / pipeline token).
- Probe work is bounded (worker pool) so a huge library cannot starve the VM.
- Scanner never holds multi-minute DB transactions; batch upserts.

### 5.3 Probe

- `ffprobe` JSON → `MediaStream` rows (codec, language, channels, default/forced flags, resolution, hdr signals when available).
- Results cached; invalidated on file mtime/size change.

## 6. Metadata

| Piece | v1 behavior |
|-------|-------------|
| Primary provider | TMDB (API key via config) |
| Matching | Folder/file heuristics → provider search → optional manual fix later |
| Images | Download poster/backdrop into image cache; serve via Jellyfin image routes |
| NFO | Read basic NFO when present to seed title/year/provider IDs; no write-back in v1 |
| Rate limits | Per-provider token bucket; cache provider payloads in Postgres |
| Failure | Best-effort; scan completes even if metadata fails |

## 7. Jellyfin API compatibility

### 7.1 Adapter layout

```
lib/hivefin_web/              # Phoenix endpoint, router, Jellyfin controllers/plugs
lib/hivefin/jellyfin/         # DTOs, auth header parsing, field maps (no I/O)
lib/hivefin/                  # domain: library, playback, accounts, scanner, metadata
```

### 7.2 Auth

- Parse Jellyfin/Emby-style authorization headers (`MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…`).
- `POST /Users/AuthenticateByName` → access token bound to **user + device**.
- Tokens stored server-side (revocable) or equivalent secure scheme; prefer revocable DB tokens in v1 for ops simplicity.
- Bootstrap: first admin via env (`HIVEFIN_ADMIN_USER` / `HIVEFIN_ADMIN_PASSWORD`) or documented first-run path.
- Out of scope: LDAP, SSO, forgotten password, public users, parental controls.

### 7.3 Endpoint tiers

**Tier 0 — login and shell**

- `System/Info`, `System/Info/Public` (and related stubs clients require)
- `Users/AuthenticateByName`, `Users/Me`
- Minimal sessions listing / capabilities
- Branding / public config stubs as needed by Web

**Tier 1 — library browse**

- `Users/{id}/Views`
- `Items` queries (parent, recursive, include types, fields)
- `Users/{id}/Items/{id}`
- Image routes `Items/{id}/Images/...`
- `Shows/*/Seasons`, `Shows/*/Episodes` (or equivalent Items queries Web uses)
- Search if required by golden clients early

**Tier 2 — playback**

- `Items/{id}/PlaybackInfo`
- Stream URLs (progressive and/or HLS) consistent with PlaybackInfo
- Progress: `Sessions/Playing`, `Sessions/Playing/Progress`, `Sessions/Playing/Stopped` (exact paths per client capture)
- `UserData` updates

**Tier 3 — polish**

- Resume / continue watching rows
- Next up (TV)
- Genres, people pages as clients demand
- Library scan triggers and basic library admin

### 7.4 Compatibility engineering

- **Fixture pack:** capture Web + TV traffic against reference Jellyfin 10.9.x (adjust pin after first capture); commit redacted fixtures under `test/support/fixtures/jellyfin/`.
- **Shape tests:** assert required fields and types on DTOs; expand when a client breaks.
- **Version string:** report a clear product name (`Hivefin`) and a documented **client-compatibility target** (e.g. clients built for Jellyfin 10.9.x)—do not impersonate upstream build hashes.
- **WebSocket:** not Tier 0. Session domain remains source of truth; WS added when golden clients require live session events. Design Session updates as pubsub-friendly from day one (`Phoenix.PubSub`).

### 7.5 API non-goals (v1)

Plugin APIs, live TV, SyncPlay, full activity/dashboard parity, every admin settings page.

## 8. Playback and transcoding

### 8.1 Decision flow

```
PlaybackInfo request
  → resolve Item + MediaSource (+ optional audio/sub stream choice)
  → compare source streams to client Profile / DeviceProfile
  → DirectPlay | DirectStream (remux) | Transcode
  → return MediaSources with TranscodingUrl / DirectStreamUrl as appropriate
```

### 8.2 Play methods

| Method | Behavior |
|--------|----------|
| **DirectPlay** | Client reads file (or byte-range) in original form |
| **DirectStream** | FFmpeg remux to a client-friendly container (e.g. MPEG-TS / fMP4) without re-encode when codecs are acceptable |
| **Transcode** | FFmpeg re-encodes video and/or audio; may burn or convert subs |

### 8.3 Hardware encoding (v1 requirement)

On application start and on config change, **probe** available encoders:

| Platform | Preference (auto) |
|----------|-------------------|
| macOS | VideoToolbox |
| Linux + NVIDIA | NVENC |
| Linux + VAAPI-capable GPU | VAAPI |
| Else | libx264 / libopus or aac (CPU) |

Configuration:

- `HIVEFIN_HW_ACCEL=auto|videotoolbox|nvenc|vaapi|none`
- Encoder init failure → log + fall back to CPU for that session (or fail session if CPU disabled by policy—default: allow CPU fallback).

FFmpeg argument builders are pure modules (`Hivefin.Playback.FFmpeg.Args`) so encoder choice is testable without spawning processes.

### 8.4 Session lifecycle

1. Client obtains `PlaybackInfo` and starts HTTP stream or HLS playlist.
2. `PlaybackSession` registered under a DynamicSupervisor.
3. For remux/transcode: start FFmpeg via Port or `Exile`/`MuonTrap`-style wrapper; stream stdout or write to a session temp directory for HLS.
4. Progress reports update `UserData.playback_position_ticks`.
5. On stop, error, or idle timeout: terminate FFmpeg (SIGTERM then SIGKILL), delete session temp files, mark session closed.

### 8.5 Resource limits

- Max concurrent transcodes (config, default conservative e.g. 2–3 on typical NAS-class hardware).
- Excess requests: 503 or Jellyfin-like error the client surfaces; never unbounded FFmpeg spawn.
- Disk: bound HLS segment directories per session; clean on terminate.

### 8.6 Subtitles

- Soft subs: pass through or convert to a client-supported format when DirectPlay/DirectStream allows.
- Image-based or unsupported subs: burn-in during Transcode when the client profile requires it (implement when golden clients demand; stub otherwise).

## 9. Persistence (PostgreSQL)

### 9.1 Core tables (logical)

- `libraries`, `items` (type, parent_id, names, dates, provider_ids JSONB, overview, …)
- `media_sources`, `media_streams`
- `people`, `item_people`, `images`
- `users`, `user_data` (unique `user_id + item_id`)
- `access_tokens`, `sessions` (device metadata)
- `scan_jobs`
- `provider_cache` (optional but recommended)

### 9.2 Indexes (minimum)

- Unique `media_sources.path`
- `items(parent_id)`, `items(type)`, `items(library_id)`
- `user_data(user_id, item_id)` unique
- GIN or side table for provider id lookups (`tmdb`, `imdb`)

### 9.3 Migrations

All schema changes via Ecto migrations; no hand-edited prod schema.

## 10. Operations and reliability

### 10.1 Configuration (env / runtime)

Examples (final names fixed at implementation):

- `DATABASE_URL`
- `HIVEFIN_HTTP_IP` / `HIVEFIN_HTTP_PORT`
- `HIVEFIN_MEDIA_PATHS` or library rows in DB
- `HIVEFIN_TMDB_API_KEY`
- `HIVEFIN_FFMPEG_PATH` / `HIVEFIN_FFPROBE_PATH`
- `HIVEFIN_HW_ACCEL`
- `HIVEFIN_MAX_TRANSCODES`
- `HIVEFIN_ADMIN_USER` / `HIVEFIN_ADMIN_PASSWORD` (bootstrap)
- `HIVEFIN_IMAGE_CACHE_DIR`
- `HIVEFIN_TRANSCODE_DIR`

### 10.2 Health

- **Liveness:** process up
- **Readiness:** Postgres reachable and `ffmpeg`/`ffprobe` discoverable. Missing media roots are **degraded** (logged warning) but still ready so the API can run for setup.

### 10.3 Observability

- Structured logging for auth failures, scan summaries, playback start/stop, FFmpeg exit codes
- `:telemetry` events: HTTP duration, scan duration, probe duration, transcode start/stop, HW vs CPU encode
- Optional `/metrics` Prometheus exporter behind config flag

### 10.4 Shutdown

1. Stop accepting new playback sessions.
2. SIGTERM active FFmpeg children; wait bounded time; SIGKILL remainder.
3. Flush in-flight UserData writes.
4. Stop HTTP endpoint.

### 10.5 Backup

- PostgreSQL dump
- Image cache directory
- Config / secrets
- Media files remain on user-managed storage

## 11. Repository layout

Single Mix application for v1 (not an umbrella unless complexity forces it):

```
hivefin/
  lib/
    hivefin/
      application.ex
      library/
      scanner/
      metadata/
      playback/
      accounts/
      media_info/
      jellyfin/          # DTOs + auth header parsing (pure-ish)
        dto/
        auth.ex
    hivefin_web/
      endpoint.ex
      router.ex
      jellyfin/          # HTTP controllers / plugs only
  test/
    support/fixtures/jellyfin/
  config/
  priv/repo/migrations/
  docs/superpowers/specs/
```

Keep a single OTP app. Split the Jellyfin mapper into a separate package only if the adapter becomes large enough to justify that boundary.

## 12. Testing strategy

| Layer | What |
|-------|------|
| Unit | DTO mappers, FFmpeg arg builders, path matchers, device profile decisions |
| Integration | Ecto + Postgres (SQL sandbox), scan against fixture file trees |
| Compatibility | HTTP tests replaying fixture expectations for Tier 0–2 |
| Manual golden path | Web + Android TV against a dev library |
| Chaos smoke | Kill FFmpeg mid-stream; cancel scan; assert node serves other clients |

No requirement to fork or vendor Jellyfin source; API behavior is defined by fixtures + documented quirks.

## 13. Security (v1 baseline)

- Bind address configurable; default recommend loopback or LAN, not `0.0.0.0` without operator intent.
- TLS: terminate at reverse proxy in v1 (Caddy/nginx); document recommended setup.
- Path traversal: media paths must resolve under configured library roots.
- Auth on all non-public routes; image routes require token or short-lived signed URL pattern consistent with clients.
- No arbitrary FFmpeg filter strings from clients—only allowlisted profile-derived options.

## 14. Build order (implementation phases)

Each phase should leave the system bootable and testable.

1. **Skeleton** — Mix app, Postgres, config, health, supervision tree.
2. **Accounts + Jellyfin auth** — users, tokens, System/Info, AuthenticateByName.
3. **Libraries + movie scan** — paths, items, media_sources, probe.
4. **Jellyfin browse DTOs** — Views/Items/Images so Web lists movies.
5. **TV hierarchy** — series/season/episode scan + browse.
6. **PlaybackInfo + DirectPlay/Remux** — progressive/stream path.
7. **Transcode + HW selection** — FFmpeg sessions, limits, fallbacks.
8. **UserData / resume / progress** — continue watching.
9. **TV client gap-fix** — sessions quirks, WS if required.
10. **Metadata polish** — TMDB matching, image cache quality, rate limits.
11. **Hardening** — metrics, scan cancel, docs (backup, reverse proxy, HW setup).

## 15. Key decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Compatibility model | Client API compatible | Reuse entire Jellyfin client ecosystem |
| Architecture | Domain-first + Jellyfin adapter | Reliability/ops focus; avoid Emby-shaped core |
| Scope | Movies + TV | Smallest useful home-theater surface |
| Deploy | Single-node | Avoid distributed FS and cluster complexity |
| DB | PostgreSQL | Operator familiarity, robust concurrency, JSONB for provider ids |
| Playback | Direct first + FFmpeg | Real-world client diversity |
| HW encode | In v1 | Living-room multi-stream CPU cost; reliability includes “streams don’t melt the NAS CPU” |
| Golden clients | Web + Android TV | Forces both browser and lean TV API paths |
| SQLite rejected | — | Operator chose Postgres for v1 |
| WebSocket deferred | Until clients require | Session domain + PubSub keep option open |
| Umbrella deferred | Single app | YAGNI until module boundaries hurt |

## 16. Open questions

Defaults below apply unless revised during implementation planning.

| # | Question | Default |
|---|----------|---------|
| 1 | Exact Jellyfin server version for fixture capture | 10.9.x latest stable at capture time |
| 2 | TV client of record | Official Jellyfin Android TV |
| 3 | HLS vs progressive-first for transcode delivery | Prefer what Web + Android TV request in PlaybackInfo; implement both if they diverge |
| 4 | Library admin UX | Config + minimal API until Web admin endpoints are required |
| 5 | Oban vs lightweight jobs | Lightweight first; Oban if retries/visibility become painful |
| 6 | Signed image URLs vs token header only | Match whatever golden clients send in captures |

## 17. PR Plan

Incremental, reviewable PRs. Each PR should leave `mix test` green.

| PR | Title | Components | Depends on | Description |
|----|-------|------------|------------|-------------|
| 1 | chore: mix app skeleton and supervision | `mix.exs`, `application.ex`, config, CI basics | — | Phoenix/Bandit app, empty supervision tree, README |
| 2 | feat: Postgres + users + bootstrap admin | Ecto, migrations, accounts | 1 | User schema, argon2, env bootstrap |
| 3 | feat: Jellyfin auth and System/Info | `Hivefin.Jellyfin`, web plugs, tokens | 2 | AuthenticateByName, token plug, public/system info |
| 4 | feat: libraries and movie scanner | library, scanner, media_info | 2 | Library CRUD internal API, walk + probe movies |
| 5 | feat: Jellyfin Items browse (movies) | DTO mappers, Items controllers, images stub | 3, 4 | Web can list and open movies |
| 6 | feat: TV series hierarchy scan + browse | scanner rules, item parent graph, Shows endpoints | 5 | Seasons/episodes in API |
| 7 | feat: PlaybackInfo and direct/remux streaming | playback domain, stream controllers | 5 | DeviceProfile decision, DirectPlay/DirectStream |
| 8 | feat: FFmpeg transcode sessions + HW accel | playback supervisor, encoder probe, limits | 7 | Transcode path with NVENC/VAAPI/VT/CPU |
| 9 | feat: playback progress and UserData | user_data, Sessions/Playing\* | 7 | Resume positions |
| 10 | test: Jellyfin fixture pack Web + Android TV | fixtures, compatibility tests | 3–9 | Capture-driven regression suite |
| 11 | feat: TV client gap-fix | sessions, optional WS | 9, 10 | Fix whatever Android TV still needs |
| 12 | feat: TMDB metadata pipeline | metadata app, image cache | 4 | Match + artwork |
| 13 | chore: ops hardening | metrics, health, docs | 8+ | Prometheus optional, backup/HW docs, graceful shutdown polish |

## 18. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Jellyfin API is large and underspecified | Golden clients + fixtures define “done”; tiered endpoints |
| FFmpeg/HW variance across machines | Probe at runtime; CPU fallback; document matrix |
| DTO field sprawl | Emit only fields clients need; expand on failure |
| Scan thundering herd | Concurrency limits, cancellable jobs |
| Scope creep toward full Jellyfin | Written non-goals; PR plan gated on tiers |

## 19. Future work (post-v1)

- Music libraries
- WebSocket-heavy remote control parity
- Plugin or script hooks (Elixir behaviours)
- Optional native non-Jellyfin API
- Multi-node workers (only if single-node limits are proven)
- Live TV / hardware tuners
- Richer admin UI via remaining Jellyfin endpoints

---

*This document is the product of collaborative design for the empty `hivefin` repository. Implementation should follow a separate plan derived from Section 17 after this spec is approved.*
