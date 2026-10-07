#!/usr/bin/env bash
# heliosMoving configuration. Every value here can also be overridden on the
# command line; see `bin/capture -help`.

# --- where things go ---------------------------------------------------------
# Folder for sessions (frames, logs, movies). Default: sessions/ in the repo.
# Absolute, or relative to the repo. The env overrides the file, so a one-off
# run can write elsewhere without editing anything:
#   SESSIONS_DIR=/mnt/usb/sessions ./run.sh -t 5m
SESSIONS_DIR="${SESSIONS_DIR:-$HELIOS_ROOT/sessions}"

# --- capture cadence -------------------------------------------------------
# Seconds between frames. Minimum 16 (twice SHOT_SETTLE_SEC).
INTERVAL_SEC=300

# Stop automatically after this time: a number with s, m or h (e.g. 8h),
# a bare number is seconds. 0 = run until stopped.
DURATION_SEC=0

# Seconds of streaming per shot before the frame is kept.
# Measured on a C920e: a pinned exposure does not take hold until roughly
# seven seconds of streaming, so anything under that re-meters per frame.
SHOT_SETTLE_SEC=8

# --- motion ------------------------------------------------------------------
# bin/capture -motion also watches for motion between the scheduled frames
# and takes an extra still when something moves. MOTION=1 turns it on for
# every session instead. The watcher owns the camera only inside the idle
# window between shots (the device is exclusive), at a small mode.
MOTION=0
MOTION_ONLY=0             # 1 = shoot ONLY on motion; no timed frames at all
MOTION_SENS=2             # percent of the picture that must change to trigger
MOTION_COOLDOWN_SEC=5     # minimum spacing between any two frames from
                          # motion. 5 s suits hot capture, where a frame
                          # costs a file move; with -no-hot each motion
                          # frame is a full reopen+settle (~10 s), and a
                          # busy scene will outrun the camera — raise it
                          # there (20 was the old hot-era default)
MOTION_MAX_WIDTH=640      # watcher runs the largest mode under this cap
MOTION_MAX_HEIGHT=360
MOTION_WARMUP_SEC=2       # ignored at each watch start: the camera re-meters
                          # on open and the fixed controls land a second or
                          # two in; either step reads as global motion.
                          # 2 is enough on the SPL6418 (manual exposure); a
                          # C920e takes longer to settle — raise if windows
                          # fire on the watcher's own exposure change.
MOTION_WINDOW_SEC=600     # longest a single watching stream stays open.
                          # Every reopen is blind for open+warmup (~3 s), so
                          # windows are long by design; the reopen also
                          # re-writes the FIX_* controls
MOTION_SETTLE_SEC="${MOTION_SETTLE_SEC:-}"   # streaming time for a motion-triggered frame;
                          # empty = SHOT_SETTLE_SEC (identical settle to
                          # timed frames). Only used by non-hot watchers —
                          # a hot frame is the frame itself, no settle
MOTION_DELAY_SEC="${MOTION_DELAY_SEC:-1}"    # after motion, keep watching N
                          # seconds and save the frame from THEN — the
                          # subject walks into shot instead of triggering
                          # from the edge of frame with a sleeve. 1 s suits a
                          # walking subject; 0 = save the triggering frame
                          # itself, and any other value is at least 0.1. Hot
                          # mode holds the live frame; without it, the delay
                          # simply postpones the reopen+settle. The hold never
                          # runs past the end of a watch window, so a
                          # scheduled shot is never late
MOTION_HOT="${MOTION_HOT:-}"        # empty = auto: on for motion-only, off for
                          # -motion. On: the watcher streams at the shot
                          # mode and keeps the newest frame's JPEG on
                          # /dev/shm, so a trigger is a file move (~0.1 s)
                          # instead of reopen+settle; costs continuous 4K
                          # decode/encode CPU while watching

# --- image -----------------------------------------------------------------
# Upper bound on frame size; the largest mode the camera offers at or below
# this is chosen automatically, so this is a ceiling and not a demand. A 1080p
# camera stays at 1080p with the cap set here.
MAX_WIDTH=3840
MAX_HEIGHT=2160

# ffmpeg -q:v for the stills. 2 = best, 31 = worst.
JPEG_QUALITY=2

# --- camera ----------------------------------------------------------------
# Leave empty to auto-detect. Otherwise a device path, ideally a stable
# /dev/v4l/by-id/... symlink.
DEVICE=""

# Seconds `bin/preview` streams before it keeps a frame, so the picture it
# writes is a settled one and not the corrupt first buffer this camera emits
# on open. Capture does not use it: every recorded shot settles on
# SHOT_SETTLE_SEC instead.
WARMUP_SEC=4

# Pin a control to a fixed value so every frame of a session is exposed the
# same way. Empty = do not write it, which leaves the control on auto where the
# camera has an auto mode (the SPL6418 has none for exposure: it is manual
# whether or not it is pinned here). Nothing is measured or calibrated.
#
# The ranges below are per-camera, not universal: `v4l2-ctl -d DEVICE
# --list-ctrls-menus` prints the real ones, and a control the camera does not
# have at all is skipped. An out-of-range value is clamped by the driver with
# no error, so capture warns when one is written -- see cam_set_checked.
FIX_EXPOSURE="350"     # exposure_time_absolute; 3..2047 C920e, 1..12287 SPL6418
FIX_WB=""              # white_balance_temperature; Kelvin 2000..6500 on a
                       # C920e, but an index 1..5 on the SPL6418 -- not Kelvin
FIX_FOCUS=""           # focus_absolute, 0..250 step 5; absent on the SPL6418
FIX_GAIN=""            # gain, 0..255

# Digital framing, written on every camera open together with the controls
# below. Empty = leave alone.
ZOOM=""                # zoom_absolute, 100..500
PAN=""                 # pan_absolute, -36000..36000 step 3600
TILT=""                # tilt_absolute, -36000..36000 step 3600

# Mains frequency, to avoid banding under artificial light. 1 = 50Hz, 2 = 60Hz.
POWER_LINE_FREQ=2

# --- movie -----------------------------------------------------------------
OUT_FPS=24             # playback rate; speedup = INTERVAL_SEC * OUT_FPS
CRF=18                 # libx264 quality, lower = better
PRESET=medium          # libx264 speed/size tradeoff

# --- safety ----------------------------------------------------------------
MIN_FREE_MB=2048       # refuse to start a session below this much free space
