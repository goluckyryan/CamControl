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
      cam_set "$dev" "$ctrl" "$FIX_EXPOSURE"
  fi
  if [[ -n "${FIX_WB:-}" ]]; then
    ctrl="$(cam_pick_ctrl "$dev" white_balance_automatic white_balance_temperature_auto)" &&
      cam_set "$dev" "$ctrl" 0
    cam_ctrl_exists "$dev" white_balance_temperature &&
      cam_set "$dev" white_balance_temperature "$FIX_WB"
  fi
  if [[ -n "${FIX_FOCUS:-}" ]]; then
    ctrl="$(cam_pick_ctrl "$dev" focus_automatic_continuous focus_auto)" &&
      cam_set "$dev" "$ctrl" 0
    cam_ctrl_exists "$dev" focus_absolute &&
      cam_set "$dev" focus_absolute "$FIX_FOCUS"
  fi
  if [[ -n "${FIX_GAIN:-}" ]]; then
    cam_ctrl_exists "$dev" gain && cam_set "$dev" gain "$FIX_GAIN"
  fi
  return 0
}
