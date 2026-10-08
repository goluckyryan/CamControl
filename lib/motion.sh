#!/usr/bin/env bash
# Motion watching between scheduled shots. Sourced after lib/camera.sh.
#
# The capture device is exclusively owned, so there is no background watcher:
# motion_watch opens a small-mode stream, pipes it to tools/motion_watch.py,
# and closes everything the moment a decision exists. It is meant to fill the
# idle window of a session, ending early enough that the scheduled shot still
# gets the camera to itself.
#
# With MOTION_HOT=1 the stream instead runs at the SHOT mode (IFMT/W/H/CAPFPS
# and JPEG_QUALITY, which bin/capture defines) and keeps a second output, a
# continuously-updated JPEG of the newest frame. The trigger path is then a
# file copy — sub-second — instead of a camera reopen plus settle.
#
# The hot frame lives on /dev/shm (RAM): at shot resolution ffmpeg rewrites
# it every frame, and putting that write storm on an SD card wears it out for
# a file that is almost always thrown away.

# Frame size the decision is made at, whatever the camera's small mode is.
MOTION_SCAN_W=320
MOTION_SCAN_H=180

MOTION_FFPID=""; MOTION_PYPID=""; MOTION_FIFO=""
MOTION_HOT_DIR=""; MOTION_HOT_FILE=""

# "FMT W H FPS" for the watcher: the largest mode under the MOTION_MAX_* cap,
# at the lowest framerate that still gives the differ enough frames.
cam_motion_mode() {
  cam_formats "$1" | "$HELIOS_ROOT/tools/pick_format.py" "$MOTION_MAX_WIDTH" "$MOTION_MAX_HEIGHT" "$MOTION_MIN_FPS"
}

# Watch for motion until DEADLINE (epoch seconds). Returns 0 the moment a
# frame pair triggers, non-zero for "deadline reached, interrupted, or the
# watcher itself failed" — every non-zero is "no motion shot", so a broken
# watcher degrades into the plain timed session rather than breaking it.
#
# On a successful return with MOTION_HOT=1, MOTION_HOT_FILE names the JPEG
# of the frame that triggered — ffmpeg is already dead and waited, so the
# file is final and the caller can simply move it into the frames folder.
motion_watch() {
  local dev="$1" deadline="$2"
  local left=$(( deadline - $(date +%s) ))
  (( left >= 3 )) || return 4

  local card mfmt mw mh mfps mifmt rc
  local hot=0 hot_dir=""
  card="$(cam_card "$dev")"
  if [[ "${MOTION_HOT:-0}" == "1" ]]; then
    # Shot mode, so the held frame IS shot-quality: the differ's gray frames
    # and the hot JPEG are two views of the same decoded stream. mktemp can
    # still fail (no /dev/shm); degrade to the small watcher, do not fail.
    hot_dir="$(mktemp -d /dev/shm/helios-hot.XXXXXX 2>/dev/null)" || hot_dir=""
    if [[ -n "$hot_dir" ]]; then
      hot=1
      mfmt="$FMT"; mw="$W"; mh="$H"; mfps="$CAPFPS"; mifmt="$IFMT"
      MOTION_HOT_DIR="$hot_dir"
      MOTION_HOT_FILE="$hot_dir/latest.jpg"
    fi
  fi
  if (( ! hot )); then
    read -r mfmt mw mh mfps < <(cam_motion_mode "$dev") || {
      warn "motion: no small capture mode on $dev; raising MOTION_MAX_WIDTH/HEIGHT may help"
      return 4
    }
    case "$mfmt" in
      MJPG) mifmt=mjpeg ;;
      YUYV|YUY2) mifmt=yuyv422 ;;
      *) mifmt="$(printf '%s' "$mfmt" | tr '[:upper:]' '[:lower:]')" ;;
    esac
  fi

  # A fifo rather than a pipeline so each child has its own pid to kill:
  # the trigger path stops the watcher while ffmpeg is still mid-frame.
  # It must survive until both sides have opened it — ffmpeg only creates
  # its output once the input is up, a second or two after these jobs
  # start, and an unlinked path would make it O_CREAT a second fifo that
  # the reader never sees. That is why the signal handlers call
  # motion_stop_kill and leave this path to the exit below.
  local fifo; fifo="$(mktemp -u "${TMPDIR:-/tmp}/helios-motion.XXXXXX")"
  mkfifo "$fifo" || return 4
  MOTION_FIFO="$fifo"

  # -t is the deadline — but as an OUTPUT option on both outputs: with it on
  # the input, a two-output ffmpeg never finalizes and hangs past its -t.
  # ffmpeg stops by itself, the watcher sees end of stream, and there is no
  # second timer to keep in step with the schedule. The card-name hush from
  # cam_run_ffmpeg applies here too.
  #
  # The hot output copies the camera's MJPEG packets instead of re-encoding
  # (-c:v copy): the camera's frames ARE JPEGs, so this both saves a 4K
  # encode (311% CPU continuous becomes ~90%) and loses no generation —
  # the saved frame is exactly what the camera saw, not ffmpeg's q:v guess.
  local -a hot_out=()
  if (( hot )); then
    if [[ "$mifmt" == "mjpeg" ]]; then
      hot_out=( -map 0:v -c:v copy -update 1 -t "$left" "$MOTION_HOT_FILE" )
    else
      # Uncompressed input has no JPEG to copy; encode the hot frame at the
      # configured quality instead (this is what a take_shot frame gets too).
      hot_out=( -update 1 -q:v "$JPEG_QUALITY" -t "$left" "$MOTION_HOT_FILE" )
    fi
  fi
  cam_exec_ffmpeg "$card" ffmpeg -nostdin -loglevel error -y \
    -f v4l2 -input_format "$mifmt" -video_size "${mw}x${mh}" -framerate "$mfps" \
    -i "$dev" \
    -vf "scale=${MOTION_SCAN_W}:${MOTION_SCAN_H},format=gray" \
    -f rawvideo -t "$left" "$fifo" "${hot_out[@]}" >/dev/null 2>>"${LOG:-/dev/stderr}" &
  MOTION_FFPID=$!
  "$HELIOS_ROOT/tools/motion_watch.py" \
    "$MOTION_SCAN_W" "$MOTION_SCAN_H" "$MOTION_SENS" "$mfps" "$MOTION_WARMUP_SEC" \
    "${MOTION_DELAY_SEC:-1}" \
    <"$fifo" &
  MOTION_PYPID=$!

  # The controls have to be re-written for this stream too: the camera
  # re-meters on every open, and a brightness step reads as global motion.
  # Written at half-second intervals — three writes, all inside the first
  # second, so the whole warmup window is spent under the configured values
  # and the watcher goes live sooner. (The shot path writes across a longer
  # window because its frames must be settled; the watcher only needs its
  # frames to be *stable relative to each other*.)
  local i
  for i in 1 2 3; do
    (( ${CMD_PENDING:-0} )) && break
    sleep 0.5
    if ! kill -0 "$MOTION_FFPID" 2>/dev/null; then
      # ffmpeg is gone. The watcher either just saw end of stream and is
      # finishing on its own, or it never got a writer on the fifo and is
      # stuck in open() forever. Give it a moment to be the former.
      sleep 0.3
      kill -0 "$MOTION_PYPID" 2>/dev/null && kill "$MOTION_PYPID" 2>/dev/null || true
      break
    fi
    cam_apply_fixed "$dev" || true
  done

  # A signal or typed command can arrive while the two children above are still
  # being created: the handler runs with no pid to signal, so it ends nothing —
  # and the wait below would then hold the session (ffmpeg still holding the
  # camera) for the rest of the window. Now that the pids exist, re-run the
  # stop; the flags are what say "someone is waiting for this window to end".
  if (( ${CMD_PENDING:-0} )) || (( ${STOP:-0} )); then
    motion_stop_kill
  fi

  # The pids are empty when a signal handler has already reaped the watcher,
  # and 'wait ""' prints an error rather than doing nothing; the 2>/dev/null is
  # for the handler that lands between the check and the wait.
  rc=1
  if [[ -n "$MOTION_PYPID" ]]; then
    wait "$MOTION_PYPID" 2>/dev/null; rc=$?
  fi

  # Post-trigger hold (-delaySec) lives in tools/motion_watch.py, not
  # here: the hot frame advances only while someone drains the fifo, and
  # the moment python exits ffmpeg takes a broken pipe and the held frame
  # freezes. Python keeps reading for the hold, ffmpeg keeps writing, and
  # the freeze below captures "trigger + delay" — or the window deadline,
  # whichever comes first, so a scheduled shot is never late.

  # Killing ffmpeg here, and waiting for it, is what freezes the hot frame:
  # the caller gets a file that can no longer change under its hands. Both pids
  # are empty when a signal handler has already ended the watcher, and 'wait ""'
  # prints an error rather than doing nothing, so they are checked; motion_stop_kill
  # is what makes sure the kill lands even when ffmpeg is stuck in a syscall.
  motion_stop_kill
  [[ -n "$MOTION_FFPID" ]] && wait "$MOTION_FFPID" 2>/dev/null || true
  [[ -n "$MOTION_PYPID"  ]] && wait "$MOTION_PYPID"  2>/dev/null || true
  rm -f "$fifo"
  MOTION_FFPID=""; MOTION_PYPID=""; MOTION_FIFO=""
  # The hot frame is the prize of a triggered watch; on any other outcome
  # the newest frame is worthless and the tmpdir goes with it.
  if [[ -n "$MOTION_HOT_DIR" && "$rc" != 0 ]]; then
    rm -rf "$MOTION_HOT_DIR"
    MOTION_HOT_DIR=""; MOTION_HOT_FILE=""
  fi
  return "$rc"
}

# Everything motion_watch leaves behind, for a caller's signal/cleanup trap.
# It deliberately does *not* clear the pids and does not touch the fifo: the
# trap fires in the middle of motion_watch, which still has to reap both
# children, and unlinking the path out from under it lets ffmpeg O_CREAT a
# plain file there that nothing ever removes.
motion_stop_kill() {
  local ff="$MOTION_FFPID" py="$MOTION_PYPID"
  [[ -n "$ff" ]] && kill -TERM "$ff" 2>/dev/null || true
  [[ -n "$py" ]] && kill -TERM "$py"  2>/dev/null || true
  # A watcher stopped under its feet does not always take the hint. When python
  # dies first, ffmpeg is usually still opening the camera; it then blocks in
  # open() on the fifo with no reader left, retrying the interrupt it gets there,
  # so the flag its TERM handler sets is never looked at. Left at that it holds
  # the camera until its own -t runs out — and with the device busy, every
  # window after it fails. Brief grace for the case that does listen, then the
  # device is taken back.
  [[ -n "$ff$py" ]] && sleep 0.3
  [[ -n "$ff" ]] && kill -KILL "$ff" 2>/dev/null || true
  [[ -n "$py" ]] && kill -KILL "$py"  2>/dev/null || true
  # Reaped here, not by the caller: a job that dies while the shell is waiting on
  # something else prints a "Killed" notice into the session's output, and this is
  # the last place that still knows which processes they were. The caller's own
  # waits then come back empty-handed, which reads as "the watcher did not
  # trigger" — the right answer on every path that kills a watcher.
  [[ -n "$ff" ]] && wait "$ff" 2>/dev/null || true
  [[ -n "$py" ]] && wait "$py"  2>/dev/null || true
  return 0
}

# Stop the watcher for good, and take its files with it: called when no watch is
# in progress (finalize), where nothing is left to return to. The reaping happens
# before the unlink on purpose — ffmpeg that had not opened the fifo yet would
# otherwise create a plain file at a path nothing ever removes again.
motion_stop() {
  motion_stop_kill
  [[ -n "$MOTION_FFPID" ]] && wait "$MOTION_FFPID" 2>/dev/null || true
  [[ -n "$MOTION_PYPID"  ]] && wait "$MOTION_PYPID"  2>/dev/null || true
  [[ -n "${MOTION_FIFO:-}" ]] && rm -f "$MOTION_FIFO" || true
  [[ -n "${MOTION_HOT_DIR:-}" ]] && rm -rf "$MOTION_HOT_DIR" || true
  MOTION_FIFO=""; MOTION_FFPID=""; MOTION_PYPID=""
  MOTION_HOT_DIR=""; MOTION_HOT_FILE=""
}
