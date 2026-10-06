#!/usr/bin/env bash
# Device detection and capture-mode selection.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
banner "detection"
fresh_scratch

out="$("$BIN/cameras" 2>&1 || true)"

# The Pi's ISP and decoder nodes must never be chosen.
assert_contains "$out" "not a camera (pispbe)"       "rejects pispbe ISP nodes"
assert_contains "$out" "not a camera (rpi-hevc-dec)" "rejects the HEVC decoder node"

if have_camera; then
  assert_contains "$out" "no Video Capture capability" "rejects the UVC metadata node"
  assert_contains "$out" "selected:"                   "selects a device"
  assert_contains "$out" "/dev/v4l/by-id/"             "reports a stable by-id path"
  assert_contains "$out" "MJPG"                        "prefers MJPG over raw"
else
  skip "no camera attached"
  assert_contains "$out" "No usable capture device found" "says so clearly when absent"
fi

# Mode selection is pure logic, so it is testable with canned v4l2 output.
canned="$SCRATCH/formats.txt"
cat > "$canned" <<'CANNED'
	[0]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 1920x1080
			Interval: Discrete 0.200s (5.000 fps)
	[1]: 'MJPG' (Motion-JPEG, compressed)
		Size: Discrete 1280x720
			Interval: Discrete 0.033s (30.000 fps)
			Interval: Discrete 0.200s (5.000 fps)
		Size: Discrete 1920x1080
			Interval: Discrete 0.033s (30.000 fps)
			Interval: Discrete 0.100s (10.000 fps)
			Interval: Discrete 0.200s (5.000 fps)
CANNED

pf="$ROOT/tools/pick_format.py"
assert_eq "MJPG 1920 1080 5"  "$(<"$canned" python3 "$pf" 1920 1080 0.1)" "picks MJPG 1080p at the lowest usable fps"
assert_eq "MJPG 1280 720 5"   "$(<"$canned" python3 "$pf" 1280 720 0.1)"  "honours a resolution cap"
assert_eq "MJPG 1920 1080 10" "$(<"$canned" python3 "$pf" 1920 1080 10)"  "raises fps when a short interval needs it"
assert_eq "MJPG 1920 1080 30" "$(<"$canned" python3 "$pf" 1920 1080 25)"  "falls back to the fastest mode offered"

finish
