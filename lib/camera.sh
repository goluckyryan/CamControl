#!/usr/bin/env bash
# Camera discovery and control. Sourced after lib/common.sh.

# This Pi exposes 17 video nodes that are not cameras (the ISP and the HEVC
# decoder), so a capture device has to be identified, never assumed.
CAM_DENY_DRIVERS='^(pispbe|rpi-hevc-dec|bcm2835-.*|rpivid|unicam)$'

V4L2_CAP_VIDEO_CAPTURE=0x00000001

cam_info()   { v4l2-ctl -d "$1" --info 2>/dev/null; }
cam_driver() { cam_info "$1" | awk -F': *' '/Driver name/{print $2; exit}'; }
cam_card()   { cam_info "$1" | awk -F': *' '/Card type/{print $2; exit}'; }

# Device Caps is a bitmask; bit 0 is VIDEO_CAPTURE. A UVC camera's metadata
# node reports META_CAPTURE (0x00800000) with bit 0 clear, which is exactly how
# /dev/video1 gets excluded here.
cam_caps_hex() { cam_info "$1" | awk '/Device Caps/{print $NF; exit}'; }

cam_is_capture() {
  local caps; caps="$(cam_caps_hex "$1")"
  [[ "$caps" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  (( (caps & V4L2_CAP_VIDEO_CAPTURE) != 0 ))
}

cam_formats() { v4l2-ctl -d "$1" --list-formats-ext 2>/dev/null; }

# One TSV row per node: dev, driver, card, ok, reason
cam_enumerate() {
  local dev driver card
  for dev in /dev/video*; do
    [[ -c "$dev" ]] || continue
    driver="$(cam_driver "$dev")"; [[ -n "$driver" ]] || driver="?"
    card="$(cam_card "$dev")";     [[ -n "$card" ]] || card="?"
    if [[ "$driver" =~ $CAM_DENY_DRIVERS ]]; then
      printf '%s\t%s\t%s\t0\t%s\n' "$dev" "$driver" "$card" "not a camera (${driver})"
    elif ! cam_is_capture "$dev"; then
      printf '%s\t%s\t%s\t0\t%s\n' "$dev" "$driver" "$card" "no Video Capture capability (metadata node)"
    elif [[ -z "$(cam_formats "$dev" | grep -o "Size: Discrete" | head -1)" ]]; then
      printf '%s\t%s\t%s\t0\t%s\n' "$dev" "$driver" "$card" "advertises no pixel formats"
    else
      printf '%s\t%s\t%s\t1\t%s\n' "$dev" "$driver" "$card" "usable"
    fi
  done
}

# Best usable capture device, or empty.
cam_detect() {
  local best="" best_score=-1
  while IFS=$'\t' read -r dev driver card ok _reason; do
    [[ "$ok" == "1" ]] || continue
    local score=0 num
    [[ "$driver" == "uvcvideo" ]] && score=$((score + 100))
    cam_formats "$dev" | grep -q "'MJPG'" && score=$((score + 50))
    num="${dev##*/video}"
    score=$((score * 1000 + (999 - num)))
    if (( score > best_score )); then best_score=$score; best="$dev"; fi
  done < <(cam_enumerate)
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# Prefer a serial-number-stable /dev/v4l/by-id path so node renumbering across
# reboots cannot silently point a run at a different device.
cam_stable_path() {
  local dev target link
  target="$(readlink -f "$1")"
  for link in /dev/v4l/by-id/*; do
    [[ -e "$link" ]] || continue
    [[ "$(readlink -f "$link")" == "$target" ]] && { printf '%s\n' "$link"; return 0; }
  done
  printf '%s\n' "$target"
}

cam_ctrl_exists() { v4l2-ctl -d "$1" --list-ctrls 2>/dev/null | grep -qE "^[[:space:]]+$2 0x"; }

cam_get() {
  local out; out="$(v4l2-ctl -d "$1" --get-ctrl "$2" 2>/dev/null)" || return 1
  [[ "$out" == *:* ]] || return 1
  printf '%s\n' "${out##*: }"
}

cam_set() { v4l2-ctl -d "$1" --set-ctrl "$2=$3" >/dev/null 2>&1; }

# "MIN MAX" for a control, or nothing when it advertises no range (bools, and
# menus on some drivers). Parsed off the --list-ctrls line, e.g.
#   exposure_time_absolute 0x009a0902 (int) : min=1 max=12287 step=1 default=78
cam_ctrl_range() {
  v4l2-ctl -d "$1" --list-ctrls 2>/dev/null | awk -v n="$2" '
    $1 == n {
      min = ""; max = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^min=/) min = substr($i, 5)
        if ($i ~ /^max=/) max = substr($i, 5)
      }
      if (min != "" && max != "") print min, max
      exit
    }'
}

# Write a control, warning first if the camera would clamp the value.
#
# The driver clamps out-of-range values silently: no error, no non-zero exit,
# just a different picture. The ranges are not even the same kind of number
# between cameras -- white_balance_temperature is Kelvin (2000..6500) on a
# C920e but an index (1..5) on an SPL6418, so a value carried over from one
# camera lands on the other as 5 and nothing says so.
#
# Controls are written several times per shot, so the same complaint would
# otherwise land once per write and then once per frame all session long.
_CAM_RANGE_WARNED=""

cam_set_checked() {
  local dev="$1" name="$2" val="$3" range min max
  range="$(cam_ctrl_range "$dev" "$name")" || true
  if [[ -n "$range" && "$val" =~ ^-?[0-9]+$ ]]; then
    min="${range%% *}"; max="${range##* }"
    if (( val < min || val > max )) && [[ " $_CAM_RANGE_WARNED " != *" $name=$val "* ]]; then
      _CAM_RANGE_WARNED+=" $name=$val"
      warn "$name=$val is outside this camera's range ${min}..${max} and will be clamped; run 'v4l2-ctl -d $dev --list-ctrls-menus' for the real ranges"
    fi
  fi
  cam_set "$dev" "$name" "$val"
}

# First control name that exists, so modern and legacy kernels both work.
cam_pick_ctrl() {
  local dev="$1"; shift
  local n
  for n in "$@"; do cam_ctrl_exists "$dev" "$n" && { printf '%s\n' "$n"; return 0; }; done
  return 1
}

# Controls that must be set before the warmup, because they change how the
# camera behaves while converging.
cam_apply_static() {
  local dev="$1"

  cam_ctrl_exists "$dev" power_line_frequency && cam_set "$dev" power_line_frequency "$POWER_LINE_FREQ"

  # Left on, the camera stretches exposure by quietly dropping framerate in dim
  # light, so both the cadence and the look drift mid-session.
  cam_ctrl_exists "$dev" exposure_dynamic_framerate && cam_set "$dev" exposure_dynamic_framerate 0

  [[ -n "${ZOOM:-}" ]] && cam_ctrl_exists "$dev" zoom_absolute && cam_set "$dev" zoom_absolute "$ZOOM"
  [[ -n "${PAN:-}"  ]] && cam_ctrl_exists "$dev" pan_absolute  && cam_set "$dev" pan_absolute  "$PAN"
  [[ -n "${TILT:-}" ]] && cam_ctrl_exists "$dev" tilt_absolute && cam_set "$dev" tilt_absolute "$TILT"
  return 0
}

# v4l2-ctl appends a menu label to some controls ("1 (Manual Mode)") and not to
# others ("2"), so the numeric value has to be taken off the front.
cam_get_num() {
  local v; v="$(cam_get "$1" "$2")" || return 1
  v="${v%% *}"
  [[ "$v" =~ ^-?[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

# --- per-camera stderr filtering ---------------------------------------------
#
# The XIFT/SPL6418 embeds private APP segments in every MJPEG frame. ffmpeg's
# mjpeg decoder cannot parse them and logs one error per frame, even though
# the image data itself decodes fine and the frame is written correctly:
#
#   [mjpeg @ 0x...] unable to decode APP fields: Invalid data found ...
#       Last message repeated N times
#   ioctl(VIDIOC_QBUF): Bad file descriptor   (benign teardown race at -t cutoff)
#
# Other cameras (the C920e) do not do this, so the silence is keyed to the
# card name and only these exact lines disappear; any other ffmpeg output
# still gets through.

CAM_NOISY_CARD_RE='XIFT|SPL6418'

cam_is_noisy() { [[ "$1" =~ $CAM_NOISY_CARD_RE ]]; }

# stdin->stdout filter. The "Last message repeated" follow-up is dropped only
# when it directly follows the noise, so it stays visible for any real error.
cam_hush_stderr() {
  awk '
    /unable to decode APP fields/                  { last = 1; next }
    last && /Last message repeated [0-9]+ times/   { next }
    /ioctl\(VIDIOC_QBUF\): Bad file descriptor/    { last = 0; next }
    { last = 0; print; fflush() }'
}

# Run "$@" with stderr filtered when $1 (the camera's card string) says so.
# Caller-level redirections apply to this function, and the filter inherits
# them, so `... >> log 2>&1` keeps logging both streams to the same file.
cam_run_ffmpeg() {
  local card="$1"; shift
  if cam_is_noisy "$card"; then
    "$@" 2> >(cam_hush_stderr >&2)
  else
    "$@"
  fi
}

# Same, for the callers that background the job and keep $! to kill it later.
# The filtered form above cannot be used there: the process substitution is a
# redirection, so bash runs ffmpeg in a *child* of the job and $! becomes a shell
# that dies first — the real ffmpeg is orphaned, keeps the camera open, and
# finishes writing to a path its parent has already deleted (creating it back as
# a plain file). Here the job shell replaces itself with ffmpeg, so the pid the
# caller holds IS the process the kill has to reach. Only safe where the command
# is backgrounded: exec does not return, so a foreground caller would not come
# back to its next line (bin/preview is why both forms exist).
cam_exec_ffmpeg() {
  local card="$1"; shift
  cam_is_noisy "$card" && exec 2> >(cam_hush_stderr >&2)
  exec "$@"
}

# Apply the fixed parameters from config.sh. No calibration, no readback: what
# is configured is what is written. A control with no FIX_* value is left on
# auto rather than frozen at whatever it happened to be showing, so setting
# only FIX_EXPOSURE pins exposure and leaves the rest alone.
cam_apply_fixed() {
  local dev="$1" ctrl
  cam_apply_static "$dev" || true

  if [[ -n "${FIX_EXPOSURE:-}" ]]; then
    ctrl="$(cam_pick_ctrl "$dev" auto_exposure exposure_auto)" &&
      cam_set "$dev" "$ctrl" 1
    ctrl="$(cam_pick_ctrl "$dev" exposure_time_absolute exposure_absolute)" &&
      cam_set_checked "$dev" "$ctrl" "$FIX_EXPOSURE"
  fi
  if [[ -n "${FIX_WB:-}" ]]; then
    ctrl="$(cam_pick_ctrl "$dev" white_balance_automatic white_balance_temperature_auto)" &&
      cam_set "$dev" "$ctrl" 0
    cam_ctrl_exists "$dev" white_balance_temperature &&
      cam_set_checked "$dev" white_balance_temperature "$FIX_WB"
  fi
  if [[ -n "${FIX_FOCUS:-}" ]]; then
    ctrl="$(cam_pick_ctrl "$dev" focus_automatic_continuous focus_auto)" &&
      cam_set "$dev" "$ctrl" 0
    cam_ctrl_exists "$dev" focus_absolute &&
      cam_set_checked "$dev" focus_absolute "$FIX_FOCUS"
  fi
  if [[ -n "${FIX_GAIN:-}" ]]; then
    cam_ctrl_exists "$dev" gain && cam_set_checked "$dev" gain "$FIX_GAIN"
  fi
  return 0
}
