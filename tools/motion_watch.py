#!/usr/bin/env python3
"""Motion trigger over a raw 8-bit grayscale video stream on stdin.

usage: motion_watch.py WIDTH HEIGHT SENS_PCT FPS [WARMUP_SEC [HOLD_SEC]]

CamControl owns the camera and decides when this runs; this only decides
whether what it saw was motion. A frame counts as changed when it differs
from BOTH the previous frame and the one before that by more than a small
noise floor on at least SENS_PCT percent of its pixels, and motion is
called when MIN_CONSEC frames in a row count as changed. The two-frame
comparison is what a one-frame glitch cannot survive: a spike differs
from its neighbours, but the frame after the spike matches the frame
before it, so the streak breaks and no shot is fired for it.

The first WARMUP_SEC seconds are ignored: the camera re-meters each time
the stream opens and the fixed controls land a second or two in, and
either brightness step would otherwise read as the whole scene moving.

On a trigger with HOLD_SEC > 0, the decision is made but this reader stays
alive draining frames for that long before exiting 0: it is the reader
that keeps the writer (ffmpeg, and CamControl's RAM-held hot frame)
alive. A trigger that exits instantly freezes the hot frame at the
trigger instant; a held one lets it advance, so the picture CamControl
saves shows the scene HOLD_SEC after the motion started — long enough for
a walking subject to reach the middle of the frame. EOF (the window's own
deadline) ends the hold early; a scheduled shot must never wait on one.

Exit codes: 0 motion, 2 stream ended without motion, 1 error; a SIGTERM
leaves the default 143.
Diagnostics go to stderr. The no-motion line appears only when the peak
got within half the trigger level, so capture.log stays quiet in normal
operation but shows how close a still scene came once something almost
moves it.
"""
import sys
import time

NOISE_FLOOR = 12   # per-pixel absolute difference not counted as change
MIN_CONSEC = 2     # frames that must agree before a trigger is believed


def read_frame(stream, n):
    """One frame of exactly n bytes, or None at end of stream."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def pct_changed(a, b):
    """Percent of pixels differing by more than the noise floor."""
    diff = sum(1 for x, y in zip(a, b) if abs(x - y) > NOISE_FLOOR)
    return 100.0 * diff / len(a)


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    try:
        w, h = int(sys.argv[1]), int(sys.argv[2])
        sens = float(sys.argv[3])
        fps = float(sys.argv[4])
        warmup_sec = float(sys.argv[5]) if len(sys.argv) > 5 else 3.0
        hold_sec = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
    except ValueError:
        sys.exit("WIDTH HEIGHT must be integers; SENS_PCT FPS WARMUP_SEC HOLD_SEC numbers")
    if w <= 0 or h <= 0 or fps <= 0:
        sys.exit("WIDTH, HEIGHT and FPS must all be positive")

    n = w * h
    warmup = max(1, round(fps * warmup_sec))

    stream = sys.stdin.buffer
    prev = read_frame(stream, n)
    if prev is None:
        print("motion: no frames on stdin", file=sys.stderr)
        return 2

    prev2 = None
    seen, streak, peak = 1, 0, 0.0
    while True:
        cur = read_frame(stream, n)
        if cur is None:
            if peak >= sens / 2:
                print(f"motion: none ({seen} frames, peak {peak:.1f}%)", file=sys.stderr)
            return 2
        seen += 1
        if seen > warmup and prev2 is not None:
            against_prev = pct_changed(prev, cur)
            # The frame only counts as changed if it differs from both of its
            # predecessors; reporting the smaller share keeps the printed
            # percent honest about what actually persisted.
            pct = min(against_prev, pct_changed(prev2, cur))
            peak = max(peak, against_prev)
            if pct >= sens:
                streak += 1
                if streak >= MIN_CONSEC:
                    print(f"motion: {pct:.1f}% of pixels changed", file=sys.stderr)
                    if hold_sec > 0:
                        end = time.monotonic() + hold_sec
                        while time.monotonic() < end:
                            if read_frame(stream, n) is None:
                                break   # window ended; held for all it could get
                    return 0
            else:
                streak = 0
        prev2, prev = prev, cur


if __name__ == "__main__":
    sys.exit(main())
