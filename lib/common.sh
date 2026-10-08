#!/usr/bin/env bash
# Shared helpers: paths, logging, config, validation.

HELIOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
[[ -f "$HELIOS_ROOT/config.sh" ]] && source "$HELIOS_ROOT/config.sh"

# The session folder: config.sh may point it elsewhere (an external disk),
# and because config.sh keeps an already-set environment value, a one-off
# run can too: SESSIONS_DIR=/mnt/usb/sessions ./run.sh -t 5m. A relative
# value is taken against the repo, never the caller's cwd — bin/capture and
# bin/status must agree on the folder no matter where they are run from.
: "${SESSIONS_DIR:=$HELIOS_ROOT/sessions}"
[[ "$SESSIONS_DIR" == /* ]] || SESSIONS_DIR="$HELIOS_ROOT/$SESSIONS_DIR"
CURRENT_LINK="$SESSIONS_DIR/current"

: "${INTERVAL_SEC:=10}"
: "${DURATION_SEC:=0}"
: "${MAX_WIDTH:=1920}"
: "${MAX_HEIGHT:=1080}"
: "${JPEG_QUALITY:=2}"
: "${DEVICE:=}"
: "${WARMUP_SEC:=4}"
: "${SHOT_SETTLE_SEC:=8}"
: "${MOTION:=0}"
: "${MOTION_ONLY:=0}"
: "${MOTION_SENS:=2}"
: "${MOTION_COOLDOWN_SEC:=5}"
: "${MOTION_DELAY_SEC:=1}"    # hold the hot frame this long after a trigger
: "${MOTION_MAX_WIDTH:=640}"
: "${MOTION_MAX_HEIGHT:=360}"
: "${MOTION_WARMUP_SEC:=2}"
: "${MOTION_WINDOW_SEC:=600}"  # longest one watching stream stays open
: "${MOTION_SETTLE_SEC:=}"     # empty = use SHOT_SETTLE_SEC for motion frames
: "${MOTION_HOT:=}"            # empty = auto (on for motion-only, off for hybrid)
: "${MOTION_MIN_FPS:=5}"   # internal: lowest framerate the differ is given
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

info() { printf '%s\n' "$*" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found; install it and retry"; }

# Every flag in this rig takes ONE dash: -motion, -duration, -fps. The two-dash
# GNU form is not accepted anywhere, so anyone who types it by habit gets the
# rule and the spelling they meant rather than a bare "unknown option".
die_opt() {
  case "$1" in
    --?*) die "unknown option '$1'; flags here take a single dash, not two (try -h)" ;;
    *)    die "unknown option '$1' (try -h)" ;;
  esac
}

# Compare two decimals without bc: fcmp A OP B, OP in lt le gt ge
fcmp() {
  awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if (op=="lt") exit !(a<b); if (op=="le") exit !(a<=b);
    if (op=="gt") exit !(a>b); if (op=="ge") exit !(a>=b);
    exit 1 }'
}

# "10s" / "11m" / "1h" / "1.5m" / "90" -> a number of seconds.
# Shared by run.sh (-t) and bin/capture (-duration), which both speak it.
to_seconds() {
  local v="$1" n u
  [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)([sSmMhH]?)$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[3]}"
  case "${u,,}" in
    ""|s) awk -v n="$n" 'BEGIN{printf "%.10g", n}'        ;;
    m)    awk -v n="$n" 'BEGIN{printf "%.10g", n * 60}'   ;;
    h)    awk -v n="$n" 'BEGIN{printf "%.10g", n * 3600}' ;;
  esac
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
  [[ "$pid" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Pids are recycled, and on a small board they recycle fast: without this
  # tiebreaker a finished session can look alive forever through whatever
  # process inherited its number, and -resume refuses to take over. When
  # procfs cannot be read, fail open — that is what the bare kill -0 did.
  if [[ -r "/proc/$pid/cmdline" ]]; then
    grep -qa 'bin/capture' "/proc/$pid/cmdline" || return 1
  fi
}
