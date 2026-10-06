#!/usr/bin/env bash
# Shared helpers: paths, logging, config, validation.

HELIOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSIONS_DIR="$HELIOS_ROOT/sessions"
CURRENT_LINK="$SESSIONS_DIR/current"

# shellcheck source=/dev/null
[[ -f "$HELIOS_ROOT/config.sh" ]] && source "$HELIOS_ROOT/config.sh"

: "${INTERVAL_SEC:=10}"
: "${DURATION_SEC:=0}"
: "${MAX_WIDTH:=1920}"
: "${MAX_HEIGHT:=1080}"
: "${JPEG_QUALITY:=2}"
: "${DEVICE:=}"
: "${WARMUP_SEC:=4}"
: "${SHOT_SETTLE_SEC:=8}"
: "${POWER_LINE_FREQ:=2}"
: "${OUT_FPS:=24}"
: "${CRF:=18}"
: "${PRESET:=medium}"
: "${MIN_FREE_MB:=2048}"

if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found; install it and retry"; }

# Compare two decimals without bc: fcmp A OP B, OP in lt le gt ge
fcmp() {
  awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if (op=="lt") exit !(a<b); if (op=="le") exit !(a<=b);
    if (op=="gt") exit !(a>b); if (op=="ge") exit !(a>=b);
    exit 1 }'
}

# Frame filenames carry one-second resolution, so two frames inside the same
# second would collide and one would be silently lost.
validate_interval() {
  local iv="$1"
  [[ "$iv" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "interval must be a positive number, got '$iv'"
  fcmp "$iv" gt 0 || die "interval must be greater than zero"
  fcmp "$iv" ge 1 || die "interval must be at least 1 second (frame filenames have one-second resolution, so a shorter interval would overwrite frames); got ${iv}s"
  if fcmp "$iv" lt 2; then
    warn "interval ${iv}s is close to the 1s filename resolution; timing jitter could put two frames in the same second and lose one"
  fi
}

# Lowest capture framerate that can still feed the requested interval.
min_capture_fps() { awk -v iv="$1" 'BEGIN{ printf "%.4f", 1.0/iv }'; }

free_mb() { df -Pm "$1" | awk 'NR==2{print $4}'; }

check_space() {
  local dir="$1" free
  free="$(free_mb "$dir")"
  (( free >= MIN_FREE_MB )) || die "only ${free} MB free under $dir, need ${MIN_FREE_MB} MB (lower MIN_FREE_MB in config.sh to override)"
}

human_secs() {
  local s=${1%.*}
  printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# Resolve a session argument: empty/"current" -> active or newest, a name under
# sessions/, or a path. Prints the absolute directory.
resolve_session() {
  local arg="${1:-}"
  if [[ -z "$arg" || "$arg" == "current" ]]; then
    if [[ -L "$CURRENT_LINK" && -d "$CURRENT_LINK" ]]; then
      readlink -f "$CURRENT_LINK"; return 0
    fi
    local newest
    newest="$(find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)"
    [[ -n "$newest" ]] || return 1
    printf '%s\n' "$SESSIONS_DIR/$newest"; return 0
  fi
  if [[ -d "$arg" ]]; then readlink -f "$arg"; return 0; fi
  if [[ -d "$SESSIONS_DIR/$arg" ]]; then printf '%s\n' "$SESSIONS_DIR/$arg"; return 0; fi
  return 1
}

# Read one key out of a session.json without needing jq.
session_get() {
  python3 -c '
import json,sys
try:
    with open(sys.argv[1]) as f: d=json.load(f)
except Exception: sys.exit(1)
v=d
for k in sys.argv[2].split("."):
    if not isinstance(v,dict) or k not in v: sys.exit(1)
    v=v[k]
print("" if v is None else v)' "$1" "$2" 2>/dev/null
}

session_is_running() {
  local dir="$1" pid
  [[ -f "$dir/capture.pid" ]] || return 1
  pid="$(cat "$dir/capture.pid" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}
