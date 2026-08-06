#!/usr/bin/env bash
# Capture redacted Jellyfin 10.9.x API fixtures for Hivefin compatibility tests.
#
# This script does NOT talk to a server by itself. It documents operator steps
# for proxy-based capture (mitmproxy / browser) and a light redaction helper.
#
# Usage:
#   ./scripts/capture_jellyfin_fixtures.sh              # print procedure
#   ./scripts/capture_jellyfin_fixtures.sh redact FILE  # strip secrets in-place-ish → stdout
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT/test/support/fixtures/jellyfin/web"
TV_DIR="$ROOT/test/support/fixtures/jellyfin/androidtv"

usage() {
  cat <<'EOF'
Jellyfin fixture capture (Hivefin)

Prerequisites
  - Jellyfin Server 10.9.x running (operator-provided)
  - Browser with DevTools, or mitmproxy

Recommended endpoints to save
  POST /Users/AuthenticateByName     → authenticate_by_name.json
  GET  /System/Info/Public           → system_info_public.json
  GET  /System/Info                  → system_info.json
  GET  /Users/{id}/Views             → views.json
  GET  /Users/{id}/Items?...         → items_list.json
  POST /Items/{id}/PlaybackInfo      → playback_info.json

Web client
  1. Point Jellyfin Web at the reference server.
  2. Capture the six responses above (Network tab or proxy).
  3. Save under: test/support/fixtures/jellyfin/web/
  4. Redact tokens/paths (see README + redact subcommand).

Android TV (Task 11)
  Live capture requires a device/emulator + proxy (e.g. mitmproxy with
  system CA). If unavailable, keep hand-authored androidtv/ shapes and
  complete the manual checklist in:
    test/support/fixtures/jellyfin/README.md

mitmproxy sketch
  mitmproxy -p 8080
  # Point client HTTP proxy at host:8080
  # Filter: ~u /Users/AuthenticateByName | ~u /System/Info | ~u /Views | ~u /Items | ~u PlaybackInfo
  # Export response bodies, then redact.

Redaction
  ./scripts/capture_jellyfin_fixtures.sh redact path/to/raw.json > cleaned.json

After update
  mix test test/hivefin_web/compat
EOF
}

redact() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "file not found: $file" >&2
    exit 1
  fi
  # Lightweight redaction via Python if available, else sed-ish jq.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import json, re, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

SECRET_KEYS = re.compile(
    r"(AccessToken|api_key|ApiKey|Password|Pw|Token)$", re.I
)
PATH_KEYS = re.compile(r"^Path$", re.I)

def walk(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if PATH_KEYS.match(k):
                continue  # drop filesystem paths
            if SECRET_KEYS.search(k) and isinstance(v, str):
                out[k] = "REDACTED_TOKEN"
            else:
                out[k] = walk(v)
        return out
    if isinstance(obj, list):
        return [walk(x) for x in obj]
    if isinstance(obj, str) and "api_key=" in obj:
        return re.sub(r"api_key=[^&]+", "api_key=REDACTED_TOKEN", obj)
    return obj

print(json.dumps(walk(data), indent=2))
print(file=sys.stderr, end="")
PY
  elif command -v jq >/dev/null 2>&1; then
    jq 'walk(
      if type == "object" then
        del(.Path) |
        with_entries(
          if (.key | test("AccessToken|api_key|ApiKey|Token$"; "i"))
             and (.value | type) == "string"
          then .value = "REDACTED_TOKEN"
          else . end
        )
      else . end
    )' "$file"
  else
    echo "need python3 or jq to redact" >&2
    exit 1
  fi
}

case "${1:-}" in
  "" | -h | --help | help)
    usage
    echo ""
    echo "Fixture dirs:"
    echo "  $WEB_DIR"
    echo "  $TV_DIR"
    ;;
  redact)
    shift
    if [[ $# -lt 1 ]]; then
      echo "usage: $0 redact FILE" >&2
      exit 1
    fi
    redact "$1"
    ;;
  *)
    echo "unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
