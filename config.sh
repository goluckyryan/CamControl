#!/usr/bin/env bash
# heliosMoving configuration. Every value here can also be overridden on the
# command line; see `bin/capture --help`.

# --- capture cadence -------------------------------------------------------
# Seconds between frames. Minimum 16 (twice SHOT_SETTLE_SEC).
INTERVAL_SEC=300

# Stop automatically after this many seconds. 0 = run until stopped.
DURATION_SEC=0

# Seconds of streaming per shot before the frame is kept.
# Measured on a C920e: a pinned exposure does not take hold until roughly
# seven seconds of streaming, so anything under that re-meters per frame.
SHOT_SETTLE_SEC=8

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

# Seconds to let the camera's own auto-exposure/WB/focus converge before those
# values are read back and locked for the rest of the session.
WARMUP_SEC=4

# Pin a control outright instead of auto-calibrating it. Empty = calibrate.
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

# Digital framing, applied before warmup. Empty = leave alone.
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
