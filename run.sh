#!/usr/bin/env bash
# Start the camera and record a time-lapse.
#
#   ./run.sh -t 10s        a frame every ten seconds
#   ./run.sh -t 11m        a frame every eleven minutes
#   ./run.sh -t 1h         a frame every hour
#
# Anything else is passed straight through to bin/capture, so --duration,
# --name, --device and -b behave exactly as they do there.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<USAGE
usage: ./run.sh -t <interval> [capture options]

  -t, --time <interval>  time between frames: a number with a unit,
                         s (seconds), m (minutes) or h (hours).
                         A bare number is read as seconds.
                         Default: ${INTERVAL_SEC}s, from config.sh
  -ss, --single-shot     take one still with the config.sh FIX_* values and stop
                         (optionally: ./run.sh -ss myshot.jpg)
  -n, --dry-run          print the capture command instead of running it
  -h, --help             this text

examples:
  ./run.sh -t 10s                       a frame every ten seconds
  ./run.sh -t 11m                       a frame every eleven minutes
  ./run.sh -t 1h  --duration 28800      hourly, for eight hours
  ./run.sh -t 30s -b                    every thirty seconds, in the background

Stop a run with Ctrl-C, or bin/stop for a background one.
Turn the frames into a movie with bin/make-movie.
USAGE
}

# "10s" / "11m" / "1h" / "1.5m" / "90" -> a number of seconds.
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

TSPEC=""; DRYRUN=0; SINGLE=0; PASS=()
while (( $# )); do
  case "$1" in
    -t|--time|--interval)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "-t needs a value, e.g. -t 10s"
      TSPEC="$2"; shift 2 ;;
    -n|--dry-run)         DRYRUN=1; shift ;;
    -ss|--single-shot)    SINGLE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    PASS+=("$1"); shift ;;
  esac
done

# One picture, now, with the configured parameters. No interval involved.
if (( SINGLE )); then
  exec "$HELIOS_ROOT/bin/shot" ${PASS[@]+"${PASS[@]}"}
fi

if [[ -n "$TSPEC" ]]; then
  SECS="$(to_seconds "$TSPEC")" \
    || die "cannot read '$TSPEC' as a time: use a number with s, m or h (e.g. 10s, 11m, 1h)"
  # Only worth saying when the unit actually changed the number: "10s = 10s"
  # tells nobody anything.
  if [[ "${TSPEC,,}" != "${SECS}s" && "$TSPEC" != "$SECS" ]]; then
    info "interval  : $TSPEC = ${SECS}s"
  fi
else
  SECS="$INTERVAL_SEC"
fi

CMD=("$HELIOS_ROOT/bin/capture" --interval "$SECS" ${PASS[@]+"${PASS[@]}"})
if (( DRYRUN )); then
  printf '%s\n' "${CMD[*]}"
  exit 0
fi
exec "${CMD[@]}"
