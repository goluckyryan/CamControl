#!/usr/bin/env python3
"""Choose a capture mode from `v4l2-ctl --list-formats-ext` output on stdin.

usage: pick_format.py MAXW MAXH MIN_FPS
prints: FORMAT WIDTH HEIGHT CAPTURE_FPS

MJPG is preferred over raw formats: at 1080p a USB 2.0 link cannot carry raw
YUYV at a useful rate. The capture framerate is the *lowest* the camera offers
that still keeps up with MIN_FPS (= 1/interval), so ffmpeg decodes as few
frames as possible before the fps filter discards them.
"""
import re
import sys

PREFERRED = ["MJPG", "YUYV", "YUY2", "NV12", "H264"]


def parse(text):
    formats, fmt, size = {}, None, None
    for line in text.splitlines():
        m = re.search(r"\[\d+\]:\s*'(\w+)'", line)
        if m:
            fmt = m.group(1)
            formats.setdefault(fmt, {})
            size = None
            continue
        m = re.search(r"Size:\s*Discrete\s+(\d+)x(\d+)", line)
        if m and fmt:
            size = (int(m.group(1)), int(m.group(2)))
            formats[fmt].setdefault(size, [])
            continue
        m = re.search(r"\(([\d.]+)\s*fps\)", line)
        if m and fmt and size:
            formats[fmt][size].append(float(m.group(1)))
    return {f: s for f, s in formats.items() if s}


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    maxw, maxh, min_fps = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])

    formats = parse(sys.stdin.read())
    if not formats:
        sys.exit("no pixel formats found")

    order = [f for f in PREFERRED if f in formats] + sorted(
        f for f in formats if f not in PREFERRED
    )
    fmt = order[0]
    sizes = formats[fmt]

    fitting = [s for s in sizes if s[0] <= maxw and s[1] <= maxh]
    # If nothing fits the cap, take the smallest mode rather than failing.
    size = (max(fitting, key=lambda s: s[0] * s[1]) if fitting
            else min(sizes, key=lambda s: s[0] * s[1]))

    rates = sorted(sizes[size])
    if not rates:
        fps = max(1.0, min_fps)
    else:
        usable = [r for r in rates if r >= min_fps]
        fps = usable[0] if usable else rates[-1]

    fps_str = str(int(fps)) if float(fps).is_integer() else f"{fps:g}"
    print(f"{fmt} {size[0]} {size[1]} {fps_str}")


if __name__ == "__main__":
    main()
