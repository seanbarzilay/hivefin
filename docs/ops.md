# Hivefin operations

## Health and readiness

| Endpoint | Meaning |
|----------|---------|
| `GET /healthz` | Liveness — process is up (`200` / body `ok`). |
| `GET /readyz` | Readiness — Postgres `SELECT 1` succeeds **and** `ffmpeg` / `ffprobe` binaries are discoverable. |

Missing library media roots do **not** fail readiness: Hivefin logs a degraded warning so you can finish admin/setup while disks are unmounted. Clients should treat `503` on `/readyz` as “do not route traffic yet.”

```bash
curl -sS http://127.0.0.1:4000/healthz
curl -sS http://127.0.0.1:4000/readyz
```

## Graceful shutdown

On SIGTERM / `Application.stop(:hivefin)`:

1. **`Application.prep_stop/1`** — `Hivefin.Playback.Supervisor.drain/0` rejects new sessions (`:draining`) and stops active sessions.
2. Each **`Hivefin.Playback.Session`** `terminate/2` SIGTERM then SIGKILL FFmpeg (via `Runner.kill/1`) and removes session temp dirs under `HIVEFIN_TRANSCODE_DIR`.
3. Root supervisor stops children reverse-start order: **Endpoint** (HTTP), **Playback.Supervisor** (drain again), workers, Repo.
4. Session child `shutdown: 5_000` bounds wait for FFmpeg exit.

**Reverse proxy tip:** stop sending new connections (or wait for `/readyz` failures), then SIGTERM the BEAM release. Prefer a short drain window (e.g. 10–30s) over hard kill so encodes can stop cleanly.

## Telemetry

Hivefin emits (in addition to Phoenix/Ecto/VM metrics):

| Event | Measurements | Metadata (selected) |
|-------|--------------|---------------------|
| `[:hivefin, :scan, :stop]` | `duration` (native) | `library_id`, `library_type`, `status`, `items_found`, `items_added` |
| `[:hivefin, :playback, :start]` | `system_time` | `session_id`, `mode`, `encoder`, `format` |
| `[:hivefin, :playback, :stop]` | `duration` (native) | `session_id`, `mode`, `encoder`, `reason` |
| `[:hivefin, :ffmpeg, :encoder]` | `system_time` | `encoder`, `session_id`, `mode` (and `fallback: true` on CPU retry) |

Metrics definitions live in `HivefinWeb.Telemetry.metrics/0`. A poller publishes `[:hivefin, :playback, :sessions]` with `active` session count every 10s.

### Optional Prometheus `/metrics`

No Prometheus exporter is wired by default (keeps the release light). To expose scrape metrics:

1. Add `{:telemetry_metrics_prometheus_core, "~> 1.1"}` (or `telemetry_metrics_prometheus`) to `mix.exs`.
2. Start the reporter under `HivefinWeb.Telemetry` with `metrics: HivefinWeb.Telemetry.metrics()`.
3. Mount a Plug route (e.g. `GET /metrics`) behind a config flag such as `HIVEFIN_METRICS=true` and network ACLs — do not expose publicly without auth.

Until then, attach a `Telemetry.Metrics.ConsoleReporter` in dev or use `:telemetry.attach/4` handlers for custom sinks.

## Hardware acceleration matrix

Configured via `HIVEFIN_HW_ACCEL` (or `config :hivefin, :hw_accel`):

| Value | Encoder atom | Typical platform | Notes |
|-------|--------------|------------------|--------|
| `auto` (default) | first available HW, else `libx264` if CPU fallback allowed | all | Probes `ffmpeg -encoders` |
| `videotoolbox` / `vt` | `:videotoolbox` | macOS (Apple Silicon / Intel + VT) | Install ffmpeg with VideoToolbox |
| `nvenc` | `:nvenc` | NVIDIA GPU + drivers | Needs `h264_nvenc` in ffmpeg build |
| `vaapi` | `:vaapi` | Linux Intel/AMD | Device nodes, render group; ffmpeg VAAPI build |
| `none` / `cpu` / `libx264` | `:libx264` | any | Software encode |

Related env:

- `HIVEFIN_ALLOW_CPU_FALLBACK` — if HW encode fails mid-session, retry once with `libx264` (default true).
- `HIVEFIN_MAX_TRANSCODES` — concurrent FFmpeg sessions (default `2`).
- `HIVEFIN_FFMPEG_PATH` / `HIVEFIN_FFPROBE_PATH` — pin binaries when not on `PATH`.

## Reverse proxy and TLS

Hivefin binds HTTP (Bandit). **Production default bind is loopback** (`127.0.0.1`)
so the app is not exposed on all interfaces unless you opt in.

| Variable | Default (prod) | Notes |
|----------|----------------|-------|
| `HIVEFIN_HTTP_IP` or `PHX_IP` | `127.0.0.1` | Dotted IPv4/IPv6. Use `0.0.0.0` / `any` only when you intentionally listen on all interfaces (prefer reverse-proxy on the same host instead). |
| `PORT` | `4000` | HTTP port |

Terminate TLS at the proxy in production.

Example **Caddy**:

```caddy
media.example.com {
  reverse_proxy 127.0.0.1:4000
}
```

Example **nginx** (snippet):

```nginx
location / {
  proxy_pass http://127.0.0.1:4000;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  # Long-lived video streams
  proxy_buffering off;
  proxy_read_timeout 3600s;
}
```

Set `PHX_HOST` / Endpoint URL to the public hostname so generated links match. Prefer proxy TLS over configuring Bandit `https:` unless you have a reason for end-to-end TLS.

## Backup

| Asset | How |
|-------|-----|
| **PostgreSQL** | `pg_dump` / managed snapshots of `DATABASE_URL`. Required for users, library rows, progress, tokens. |
| **Image cache** | Directory from `HIVEFIN_IMAGE_CACHE_DIR` (default under system temp). Rebuildable from TMDB if lost; backup if you want warm caches. |
| **Transcode temp** | `HIVEFIN_TRANSCODE_DIR` — ephemeral; safe to wipe when no sessions run. |
| **Config / secrets** | `DATABASE_URL`, `SECRET_KEY_BASE`, `HIVEFIN_ADMIN_*`, `HIVEFIN_TMDB_API_KEY`, ffmpeg paths, HW settings. Store outside the repo. |
| **Media files** | User-managed storage (library root paths). Not written by Hivefin; back up with your NAS/OS tooling. |

Restore order: secrets + config → Postgres → start app → confirm `/readyz` → optional image cache restore → media mounts → scan if DB was empty.

## Docker Compose deploy

Hivefin ships with a multi-stage `Dockerfile` (mix release + FFmpeg) and
`docker-compose.yml` (app + Postgres).

### One-time setup on the server

```bash
git clone <your-repo-url> hivefin && cd hivefin
cp .env.example .env
# Edit .env:
#   SECRET_KEY_BASE      → openssl rand -base64 48
#   HIVEFIN_ADMIN_PASSWORD
#   POSTGRES_PASSWORD
#   PHX_HOST / HIVEFIN_LOCAL_ADDRESS  → server LAN IP or hostname
#   MEDIA_HOST_PATH                   → host directory with movies/tv trees
```

### Build and run

```bash
docker compose up -d --build
docker compose ps
curl -sS http://127.0.0.1:4000/readyz
```

- **Admin UI:** `http://SERVER:4000/admin` (bootstrap user from `.env`)
- **Jellyfin clients:** add server `http://SERVER:4000`
- **Libraries:** in admin, use container paths under the media mount, e.g. `/media/movies`

Migrations run automatically on container start (`Hivefin.Release.migrate/0`).

### Useful commands

```bash
docker compose logs -f hivefin
docker compose exec hivefin bin/hivefin remote   # IEx on the release
docker compose down                               # stop stack (keeps volumes)
docker compose down -v                            # stop + wipe Postgres/cache volumes
```

### Volumes

| Volume / mount | Purpose |
|----------------|---------|
| `hivefin_pgdata` | Postgres data |
| `hivefin_image_cache` | TMDB/artwork cache |
| `hivefin_transcode` | Ephemeral remux/transcode work |
| `${MEDIA_HOST_PATH}:/media:ro` | Your media (read-only) |

### TLS / reverse proxy

Default compose uses **plain HTTP** (`HIVEFIN_FORCE_SSL=false`) for LAN simplicity.
In front of Caddy/nginx with TLS, set:

```env
HIVEFIN_FORCE_SSL=true
PHX_SCHEME=https
PHX_URL_PORT=443
PHX_HOST=media.example.com
HIVEFIN_LOCAL_ADDRESS=https://media.example.com
```

and proxy to `127.0.0.1:4000` with `X-Forwarded-Proto` and `X-Forwarded-For`.

### Updating

```bash
git pull
docker compose up -d --build
```

## Environment variables (summary)

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | Postgres (required in prod) |
| `SECRET_KEY_BASE` | Phoenix secrets (required in prod) |
| `PHX_HOST` / `PORT` / `PHX_SERVER` | Public host, port, release server flag |
| `HIVEFIN_HTTP_IP` / `PHX_IP` | Prod listen address (default loopback) |
| `HIVEFIN_ADMIN_USER` / `HIVEFIN_ADMIN_PASSWORD` | Bootstrap first admin |
| `HIVEFIN_FFMPEG_PATH` / `HIVEFIN_FFPROBE_PATH` | Media binaries |
| `HIVEFIN_HW_ACCEL` | `auto` \| `videotoolbox` \| `nvenc` \| `vaapi` \| `none` |
| `HIVEFIN_MAX_TRANSCODES` | Concurrent encode sessions |
| `HIVEFIN_TRANSCODE_DIR` | FFmpeg session temp |
| `HIVEFIN_SESSION_IDLE_MS` | Idle session reap (default 60000) |
| `HIVEFIN_ALLOW_CPU_FALLBACK` | HW → libx264 retry |
| `HIVEFIN_TMDB_API_KEY` | Metadata |
| `HIVEFIN_IMAGE_CACHE_DIR` | Poster/backdrop cache |
| `HIVEFIN_TMDB_RATE_LIMIT` | TMDB requests/sec |
