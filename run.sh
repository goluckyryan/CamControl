#!/usr/bin/env bash
# Start the camera and record a time-lapse.
#
#   ./run.sh -t 10s            a frame every ten seconds
#   ./run.sh -t 11m            a frame every eleven minutes
#   ./run.sh -t 1h             a frame every hour
#   ./run.sh -t 5m -motion     ...plus one whenever something moves
#   ./run.sh -motion-only      nothing unless something moves
#
# Every flag takes a single dash, long names included: -motion, not -motion.
# Anything that is not this script's own (-t, -ss, -n, -h) is passed straight
# through to bin/capture, so -duration, -name, -device, -b and the watcher
# flags behave exactly as they do there (./run.sh -h groups them by mode).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  # The interval rule quoted under "three flags..." below, in the same
  # arithmetic bin/capture uses: an interval has to pay for the shot's
  # SHOT_SETTLE_SEC of streaming, the SHOT_SETTLE_SEC + 5 a watch window needs
  # at minimum, and the ~8 s of hand-back between the two.
  local settle="${SHOT_SETTLE_SEC}s" window="$((SHOT_SETTLE_SEC + 5))s"
  local floor="$((SHOT_SETTLE_SEC * 2 + 13))s"
  cat <<USAGE
usage: ./run.sh [-t <interval>] [options]

Every flag takes ONE dash, long names included: -motion, -duration,
-delaySec. Options are grouped by what they apply to.

this script

  -t, -time <interval>   time between frames: a number with a unit,
                         s (seconds), m (minutes) or h (hours).
                         A bare number is read as seconds.
                         Default: ${INTERVAL_SEC}s, from config.sh
  -ss, -single-shot      take one still with the config.sh FIX_* values and stop
                         (optionally: ./run.sh -ss myshot.jpg)
  -n, -dry-run           print the capture command instead of running it
  -h, -help              this text

any session — passed straight through to bin/capture

  -b, -background        detach and return immediately (stop with bin/stop)
  -I, -interactive       type commands at the running session: a frame on
                         demand, new watcher values, a longer end time.
                         Stays in the foreground, so -b is ignored
  -d, -duration N        stop after N: 90, 30m, 8h (a bare number is seconds;
                         default DURATION_SEC in config.sh = until stopped)
      -device PATH       capture device (default DEVICE in config.sh: empty
                         = auto-detect)
      -name NAME         session folder name (default: timestamp)

turning motion on — needs one of the first two, and MOTION=1 or MOTION_ONLY=1
in config.sh says the same thing without a flag

      -motion            also shoot when something moves between the
                         timed frames
      -motion-only       shoot ONLY on motion: no timed frames at all
                         (stop with bin/stop, or use -duration)
      -no-motion         off, even if MOTION=1 is set in config.sh

tuning the watcher — meaningless without -motion or -motion-only; the
defaults are MOTION_SENS / MOTION_COOLDOWN_SEC / MOTION_DELAY_SEC /
MOTION_HOT in config.sh

      -sensitivity N     percent of the picture that must change to
                         trigger, 0 < N <= 100 (default ${MOTION_SENS})
      -cooldown N        minimum seconds between motion frames, whole
                         number (default ${MOTION_COOLDOWN_SEC})
      -delaySec N        after motion, keep watching N seconds and save the
                         frame from then — lets the subject walk into shot
                         (minimum 0.1 s; the default ${MOTION_DELAY_SEC} s suits a
                         walking subject; 0 saves the triggering frame)
      -hot, -no-hot      watch at full shot resolution and keep the newest
                         frame in RAM, so a trigger saves it with a file move
                         (sub-second, continuous CPU); -no-hot watches small
                         and reopens the camera on a trigger (slower, less
                         CPU)

three flags mean something different in each motion mode

  -t / -interval         -motion: sets how much idle time there is to watch
                         in — a shot streams ${settle} and a window needs ${window},
                         so under ${floor} no motion frame ever fires (capture
                         says so at startup).
                         -motion-only: ignored — with no timed frames the
                         value only travels into session.json
      -cooldown          -motion also mutes motion for one cooldown after
                         every timed frame; -motion-only has no timed
                         frames, so it only spaces motion frames
      -hot / -no-hot     the default is different: hot for -motion-only,
                         small-stream for -motion. Naming either one picks
                         it in both modes

examples:
  # timed frames
  ./run.sh -t 10s                        a frame every ten seconds
  ./run.sh -t 1h -duration 8h            hourly, for eight hours
  ./run.sh -t 30s -b                     every thirty seconds, in the background
  ./run.sh -t 5m -I                      ...and type 'shot' at it whenever

  # timed frames, plus one on movement
  ./run.sh -t 5m -motion                 watch between the scheduled frames
  ./run.sh -t 5m -motion -no-hot         ...cheaply, on the small stream

  # movement only — nothing is recorded unless something moves
  ./run.sh -motion-only                  until stopped
  ./run.sh -motion-only -duration 8h     eight hours of watching
  ./run.sh -motion-only -sensitivity 0.5 a dim or distant subject

Stop a run with Ctrl-C, or bin/stop for a background one.
Turn the frames into a movie with bin/make-movie.
USAGE
}

# "10s" / "11m" / "1h" / "1.5m" / "90" -> a number of seconds.
# (the function itself lives in lib/common.sh, shared with bin/capture)

TSPEC=""; DRYRUN=0; SINGLE=0; PASS=()
while (( $# )); do
  case "$1" in
    -t|-time|-interval)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "-t needs a value, e.g. -t 10s"
      TSPEC="$2"; shift 2 ;;
    -n|-dry-run)        DRYRUN=1; shift ;;
    -ss|-single-shot)   SINGLE=1; shift ;;
    -h|-help)           usage; exit 0 ;;
    # Nothing in this rig takes two dashes, and the pass-through below would
    # otherwise hand '-motion' to bin/capture and report *its* wording. Say
    # the rule here, where the flag was actually typed.
    --*)                die_opt "$1" ;;
    *)                  PASS+=("$1"); shift ;;
  esac
done

# One picture, now, with the configured parameters. No interval involved.
if (( SINGLE )); then
  for a in ${PASS[@]+"${PASS[@]}"}; do
    [[ "$a" == "-I" || "$a" == "-interactive" ]] &&
      die "there is nothing to talk to in a single shot: -I needs a session"
  done
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

CMD=("$HELIOS_ROOT/bin/capture" -interval "$SECS" ${PASS[@]+"${PASS[@]}"})
if (( DRYRUN )); then
  printf '%s\n' "${CMD[*]}"
  exit 0
fi
exec "${CMD[@]}"
