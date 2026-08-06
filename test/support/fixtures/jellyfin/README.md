# Jellyfin compatibility fixtures

Hand-authored **shape contracts** for Jellyfin **10.9.x** Tier 0–2 responses that Hivefin implements. Values are redacted placeholders; tests assert **required keys + types**, not byte-identical bodies.

| Client dir | Source |
|------------|--------|
| `web/` | Jellyfin Web client shape (primary golden client) |
| `androidtv/` | Official Jellyfin Android TV shape notes (hand-authored; **not** a live capture) |

Compatibility target: clients built for Jellyfin **10.9.x**. Hivefin reports `ProductName: "Hivefin"` and its own version — fixtures may show Jellyfin product strings as reference only.

## Endpoints covered (Tier 0–2)

| Fixture file | Method / path |
|--------------|---------------|
| `authenticate_by_name.json` | `POST /Users/AuthenticateByName` |
| `system_info_public.json` | `GET /System/Info/Public` |
| `system_info.json` | `GET /System/Info` |
| `views.json` | `GET /Users/{userId}/Views` |
| `items_list.json` | `GET /Users/{userId}/Items` |
| `playback_info.json` | `POST /Items/{itemId}/PlaybackInfo` |

## Capture procedure (when you have Jellyfin 10.9.x)

Do **not** commit live tokens, passwords, LAN IPs of private hosts, or filesystem paths.

### 1. Run reference Jellyfin 10.9.x

Pin a stable 10.9.x release. One movie library is enough.

### 2. Proxy Jellyfin Web

Options:

- Browser DevTools → Network → filter XHR/fetch
- Or mitmproxy / Charles (see `scripts/capture_jellyfin_fixtures.sh`)

Point Jellyfin Web at the reference server, then exercise:

1. Login (`AuthenticateByName`)
2. Home / library list (`Views`)
3. Open a library (`Items` with `ParentId`)
4. Play a title (`PlaybackInfo`)
5. Optional: `System/Info/Public` and authenticated `System/Info`

Save response **bodies** as JSON under `web/` using the filenames above.

### 3. Redact before commit

Replace with stable placeholders:

| Field | Redact to |
|-------|-----------|
| `AccessToken` / `api_key` query values | `REDACTED_TOKEN` |
| User / item / server UUIDs (optional) | fixed sample UUIDs |
| `LocalAddress` | `http://127.0.0.1:8096` |
| Absolute `Path` on media sources | **delete the key** (Hivefin never exposes paths) |
| Real display names if sensitive | generic names |

Keep **key names**, nesting, and **value types** (string / number / boolean / object / array).

### 4. Android TV (Task 11 manual checklist)

Live Android TV capture is **out of band** for this pack when no device/emulator is available.

Manual checklist for Task 11 (against Hivefin or reference Jellyfin):

- [ ] Server discovery / manual host entry
- [ ] Login (`AuthenticateByName` with Android TV `Client` / `Device` headers)
- [ ] Library views load
- [ ] Movie/TV browse and item detail
- [ ] Play starts (direct or transcode per `PlaybackInfo`)
- [ ] Pause / seek / resume
- [ ] Stop and progress persist

If capture is possible later:

1. Run Android TV app (or emulator) through a proxy to Jellyfin 10.9.x
2. Save the same six response shapes under `androidtv/`
3. Redact as above; note client header differences in commit message

Until then, `androidtv/*.json` files are **hand-authored** mirrors of the Web contracts with Android-TV-typical `SessionInfo` / client naming — not proof of a live capture.

### 5. Refresh tests

```bash
mix test test/hivefin_web/compat
```

Shape failures mean either Hivefin dropped a required key/type or the fixture contract needs an intentional update.

## assert_shape

See `test/support/jellyfin_shape.ex`:

- `load_fixture(client, name)` — load JSON
- `shape_from_sample/1` — map values → type atoms (`:string`, `:integer`, …)
- `assert_shape/2` — required keys present and types match
