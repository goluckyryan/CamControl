#!/usr/bin/env bash
# Session bookkeeping: hostile names, incomplete sessions, and the control
# re-lock that a mid-session USB reset depends on.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
banner "session handling"
fresh_scratch

# --- a session name is a directory name and a JSON value -------------------
for bad in 'ev"il' 'back\slash' '../escape' 'has space' '-leading'; do
  out="$("$BIN/capture" --name "$bad" --duration 1 2>&1 || true)"
  assert_contains "$out" "--name may contain only" "rejects --name '$bad'"
done
assert_not_contains "$(ls "$ROOT/sessions" 2>&1)" "escape" "a rejected name creates no directory"
assert_eq "" "$(readlink "$ROOT/sessions/current" 2>/dev/null || true)" \
  "a rejected name leaves no dangling 'current' symlink"

# --- the interval floor ----------------------------------------------------
# Each shot streams SHOT_SETTLE_SEC before keeping a frame, so a short interval
# would leave the camera never switched off.
out="$("$BIN/capture" --interval 10 --duration 1 2>&1 || true)"
assert_contains "$out" "interval must be at least" "rejects an interval below twice the settle"

# --- a session missing its metadata must still be usable -------------------
# An interrupted run can leave frames with no session.json. Both readers used
# to abort under `set -e` here and print absolutely nothing.
s="nojson_$$"
cleanup() { rm -rf "$ROOT/sessions/$s"; }
trap cleanup EXIT
"$ROOT/test/make-session.sh" --interval 10 --frames 6 --no-gap --name "$s" >/dev/null 2>&1
rm -f "$ROOT/sessions/$s/session.json"

out="$("$BIN/status" "$s" 2>&1)"; rc=$?
assert_eq "0" "$rc"              "status survives a session with no session.json"
assert_contains "$out" "frames"  "status still reports frames without metadata"

"$BIN/make-movie" "$s" --out "$SCRATCH/nojson.mp4" >/dev/null 2>&1
assert_file "$SCRATCH/nojson.mp4" "make-movie falls back to ffprobe for the frame size"

# --- the fixed parameters actually reach the camera ------------------------
# cam_apply_fixed pins only the controls that have a FIX_* value; anything left
# blank stays on auto rather than being frozen at whatever it was showing.
applied="$(
  source "$ROOT/lib/common.sh" >/dev/null 2>&1
  source "$ROOT/lib/camera.sh"
  FIX_EXPOSURE=700; FIX_WB=4500; FIX_FOCUS=""; FIX_GAIN=""
  cam_pick_ctrl()   { printf '%s\n' "$2"; }
  cam_ctrl_exists() { return 0; }
  cam_set()         { printf '%s=%s\n' "$2" "$3"; }
  cam_apply_static(){ return 0; }
  cam_apply_fixed d
)"
assert_contains "$applied" "auto_exposure=1"             "clears auto exposure before writing a value"
assert_contains "$applied" "exposure_time_absolute=700"  "writes the configured exposure"
assert_contains "$applied" "white_balance_automatic=0"   "clears auto white balance when FIX_WB is set"
assert_contains "$applied" "white_balance_temperature=4500" "writes the configured white balance"
assert_not_contains "$applied" "focus_automatic_continuous" "leaves focus on auto when FIX_FOCUS is blank"
assert_not_contains "$applied" "gain="                   "leaves gain alone when FIX_GAIN is blank"

# --- an out-of-range value is a warning, not a silent clamp ----------------
# The driver clamps without erroring and without a non-zero exit, and the
# ranges are not even the same kind of number between cameras: white balance
# is Kelvin (2000..6500) on a C920e but an index (1..5) on an SPL6418. A value
# carried from one camera to the other has to be caught here or it shows up
# only as a wrong picture.
ctrls="$SCRATCH/ctrls.txt"
cat > "$ctrls" <<'CTRLS'
                     brightness 0x00980900 (int)    : min=0 max=10 step=1 default=5 value=5
        white_balance_automatic 0x0098090c (bool)   : default=1 value=1
      white_balance_temperature 0x0098091a (int)    : min=1 max=5 step=1 default=4 value=4
         exposure_time_absolute 0x009a0902 (int)    : min=1 max=12287 step=1 default=78 value=350
CTRLS

camrange() {
  (
    source "$ROOT/lib/common.sh" >/dev/null 2>&1
    source "$ROOT/lib/camera.sh"
    eval "v4l2-ctl() { cat '$ctrls'; }"
    cam_ctrl_range d "$1"
  )
}
assert_eq "1 5"     "$(camrange white_balance_temperature)" "reads a control's advertised range"
assert_eq "1 12287" "$(camrange exposure_time_absolute)"    "reads a wide range"
assert_eq ""        "$(camrange white_balance_automatic)"   "reports no range for a bool"
assert_eq ""        "$(camrange nosuchcontrol)"             "reports no range for a control the camera lacks"

camset() {
  (
    source "$ROOT/lib/common.sh" >/dev/null 2>&1
    source "$ROOT/lib/camera.sh"
    eval "v4l2-ctl() { cat '$ctrls'; }"
    cam_set() { printf 'set %s=%s\n' "$2" "$3"; }
    cam_set_checked d "$1" "$2" 2>&1
  )
}
in_range="$(camset white_balance_temperature 3)"
assert_contains     "$in_range" "set white_balance_temperature=3" "writes an in-range value"
assert_not_contains "$in_range" "warning"                         "and says nothing about it"

kelvin="$(camset white_balance_temperature 4500)"
assert_contains "$kelvin" "warning"                            "warns when Kelvin is written to an index control"
assert_contains "$kelvin" "1..5"                               "names the range the camera really has"
assert_contains "$kelvin" "set white_balance_temperature=4500" "still writes, so the clamp stays the driver's call"

assert_not_contains "$(camset white_balance_automatic 0)" "warning" "no warning for a control with no advertised range"
assert_not_contains "$(camset nosuchcontrol 7)"           "warning" "no warning for a control the camera lacks"

# v4l2-ctl prints "1 (Manual Mode)" for some controls and a bare "2" for
# others, so the numeric value has to be taken off the front.
stubget() {
  (
    source "$ROOT/lib/common.sh" >/dev/null 2>&1
    source "$ROOT/lib/camera.sh"
    eval "cam_get() { printf '%s\n' '$1'; }"
    cam_get_num d c
  )
}
assert_eq "1"   "$(stubget '1 (Manual Mode)')" "cam_get_num strips a menu label"
assert_eq "312" "$(stubget '312')"             "cam_get_num passes a plain integer through"

# --- metadata is written as data, not as program text ----------------------
if have_camera; then
  s2="dots.and-dashes_$$"
  "$BIN/capture" --name "$s2" --duration 1 >/dev/null 2>&1 || true
  assert_ok "session.json is valid JSON for a punctuated name" \
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ROOT/sessions/$s2/session.json"
  assert_eq "$s2" "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" \
    "$ROOT/sessions/$s2/session.json" 2>/dev/null || true)" "the name round-trips into session.json"
  rm -rf "$ROOT/sessions/$s2"

  # A real shot, end to end: the fixed values are written to the camera and a
  # frame lands. Nothing else in the suite opens the camera for real.
  note "the next check takes a real shot (~15s)"
  s3="shot_$$"
  "$BIN/capture" --name "$s3" --interval 20 --duration 12 >/dev/null 2>&1 || true
  assert_count 1 "$ROOT/sessions/$s3/frames" '*.jpg' "a real session writes a frame"
  assert_file "$ROOT/sessions/$s3/controls.json" "and records the configured controls"
  rm -rf "$ROOT/sessions/$s3"
else
  skip "no camera attached; session.json round-trip and the live lock not exercised"
fi

finish
