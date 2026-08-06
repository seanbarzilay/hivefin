# Hivefin

Jellyfin-compatible media server written in Elixir. Hivefin speaks enough of the Jellyfin client API for stock clients (Web + TV) while keeping a domain-first OTP architecture: libraries, items, users, and playback sessions are native Elixir models; Jellyfin HTTP is a translation adapter.

Design overview: [docs/superpowers/specs/2026-08-06-hivefin-design.md](docs/superpowers/specs/2026-08-06-hivefin-design.md)

## Requirements

| Tool | Notes |
|------|--------|
| **Elixir** | 1.17+ (see `.tool-versions`) |
| **OTP / Erlang** | 26+ |
| **PostgreSQL** | 16+ recommended |
| **FFmpeg** | Required for playback/transcode (later tasks) |

## Setup

```bash
# Install deps, create DB, run migrations, build assets
mix setup

# Start the server
mix phx.server
# or
iex -S mix phx.server
```

Health check (no auth):

```bash
curl -s http://127.0.0.1:4000/healthz
# => ok
```

## Development

```bash
mix test
mix precommit   # compile --warnings-as-errors, format, test
```

## Project status

v1 is under active construction. Current skeleton: Phoenix + Bandit + Ecto/Postgres OTP app with `GET /healthz`.
