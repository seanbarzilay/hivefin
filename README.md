# Hivefin

Jellyfin-compatible media server written in Elixir. Hivefin speaks enough of the Jellyfin client API for stock clients (Web + TV) while keeping a domain-first OTP architecture: libraries, items, users, and playback sessions are native Elixir models; Jellyfin HTTP is a translation adapter.

- Design overview: [docs/superpowers/specs/2026-08-06-hivefin-design.md](docs/superpowers/specs/2026-08-06-hivefin-design.md)
- **Operations** (backup, TLS, HW accel, readiness, shutdown): [docs/ops.md](docs/ops.md)

## Requirements

| Tool | Notes |
|------|--------|
| **Elixir** | 1.17+ (see `.tool-versions`) |
| **OTP / Erlang** | 26+ |
| **PostgreSQL** | 16+ recommended |
| **FFmpeg** | Required for probe/playback/transcode (`ffmpeg` + `ffprobe` on `PATH` or via env) |

## Setup

```bash
# Install deps, create DB, run migrations, build assets
mix setup

# Start the server
mix phx.server
# or
iex -S mix phx.server
```

Health / readiness (no auth):

```bash
curl -s http://127.0.0.1:4000/healthz
# => ok

curl -s http://127.0.0.1:4000/readyz
# => {"status":"ready","checks":{"database":true,"ffmpeg":true,"ffprobe":true}}
```

## Environment variables (summary)

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | Postgres URL (required in prod) |
| `SECRET_KEY_BASE` | Phoenix secret (required in prod) |
| `PORT` / `PHX_HOST` / `PHX_SERVER` | HTTP port, public host, enable server in releases |
| `HIVEFIN_HTTP_IP` / `PHX_IP` | Prod bind address (default `127.0.0.1`; set `0.0.0.0` only if intentional) |
| `HIVEFIN_ADMIN_USER` / `HIVEFIN_ADMIN_PASSWORD` | Bootstrap first admin when DB has no users |
| `HIVEFIN_FFMPEG_PATH` / `HIVEFIN_FFPROBE_PATH` | Override media binaries |
| `HIVEFIN_HW_ACCEL` | `auto`, `videotoolbox`, `nvenc`, `vaapi`, or `none` |
| `HIVEFIN_MAX_TRANSCODES` | Max concurrent FFmpeg sessions (default 2) |
| `HIVEFIN_TRANSCODE_DIR` | Temp dir for remux/transcode sessions |
| `HIVEFIN_SESSION_IDLE_MS` | Idle session teardown (default 60000) |
| `HIVEFIN_ALLOW_CPU_FALLBACK` | Retry HW encode failures with libx264 |
| `HIVEFIN_TMDB_API_KEY` | Metadata provider |
| `HIVEFIN_IMAGE_CACHE_DIR` | Cached posters/backdrops |
| `HIVEFIN_TMDB_RATE_LIMIT` | TMDB requests per second |

Full matrix, backups, reverse proxy TLS, and graceful shutdown: **[docs/ops.md](docs/ops.md)**.

## Docker deploy (app + Postgres)

```bash
cp .env.example .env
# set SECRET_KEY_BASE, HIVEFIN_ADMIN_PASSWORD, POSTGRES_PASSWORD,
# PHX_HOST, HIVEFIN_LOCAL_ADDRESS, MEDIA_HOST_PATH

docker compose up -d --build
curl -sS http://127.0.0.1:4000/readyz
# Admin: http://HOST:4000/admin
```

Details: [docs/ops.md](docs/ops.md#docker-compose-deploy).

## Development

```bash
mix test
mix precommit   # compile --warnings-as-errors, format, test
```

## Project status

v1: Phoenix + Bandit + Ecto/Postgres, Jellyfin-compatible API surface for Web/Android TV, library scan, direct play / HW-aware FFmpeg sessions, TMDB metadata, `/healthz` + `/readyz`, admin UI, Docker Compose stack.
