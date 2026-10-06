#!/usr/bin/env bash
# Movie assembly from a session: ordering, speedup, gaps, pixel format.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
banner "assembly (synthetic sessions, no camera)"
fresh_scratch

s10="asm10_$$"; s20="asm20_$$"
cleanup() { rm -rf "$ROOT/sessions/$s10" "$ROOT/sessions/$s20"; }
trap cleanup EXIT

# Same 20 minutes of real time, sampled at 10s and at 20s.
"$ROOT/test/make-session.sh" --interval 10 --frames 120 --no-gap --name "$s10" >/dev/null 2>&1
"$ROOT/test/make-session.sh" --interval 20 --frames 60  --no-gap --name "$s20" >/dev/null 2>&1

o10="$("$BIN/make-movie" "$s10" 2>&1)"
o20="$("$BIN/make-movie" "$s20" 2>&1)"

assert_contains "$o10" "240x speedup" "10s at 24fps is 240x"
assert_contains "$o20" "480x speedup" "20s at 24fps is 480x"

m10="$ROOT/sessions/$s10/helios_$s10.mp4"
m20="$ROOT/sessions/$s20/helios_$s20.mp4"
assert_file "$m10" "10s session produced a movie"
assert_file "$m20" "20s session produced a movie"

# Same wall-clock span at double the interval is half the frames, so half the film.
d10="$(probe format=duration "$m10")"; d20="$(probe format=duration "$m20")"
assert_eq "5.000000" "$d10" "20 min at 10s -> 5.0s of video"
assert_eq "2.500000" "$d20" "20 min at 20s -> 2.5s of video"

assert_eq "yuv420p" "$(probe stream=pix_fmt "$m10")" "output is yuv420p, not deprecated yuvj420p"
assert_eq "24/1"    "$(probe stream=r_frame_rate "$m10")" "output framerate is as asked"

# --fps pulls a long-interval session back to a watchable length.
"$BIN/make-movie" "$s20" --fps 12 --out "$SCRATCH/slow.mp4" >/dev/null 2>&1
assert_eq "5.000000" "$(probe format=duration "$SCRATCH/slow.mp4")" "--fps 12 doubles the 20s film"

# A gap must be reported against the session's own interval.
sg="asmgap_$$"
"$ROOT/test/make-session.sh" --interval 10 --frames 40 --name "$sg" >/dev/null 2>&1
og="$("$BIN/make-movie" "$sg" 2>&1)"
assert_contains "$og" "discontinuities" "reports a gap"
rm -rf "$ROOT/sessions/$sg"

# Overlay, relative --out, and deflicker all on at once.
"$BIN/make-movie" "$s10" --timestamp --deflicker --out "$SCRATCH/stamped.mp4" >/dev/null 2>&1
assert_file "$SCRATCH/stamped.mp4" "--timestamp --deflicker --out(relative) works together"
assert_file "$ROOT/sessions/$s10/overlay.ass" "overlay is generated as subtitles"
assert_eq "120" "$(grep -c '^Dialogue' "$ROOT/sessions/$s10/overlay.ass")" "one stamp per frame"

assert_fails "refuses a session that does not exist" "$BIN/make-movie" no_such_session_$$

finish
