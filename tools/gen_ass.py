#!/usr/bin/env python3
"""Build an ASS subtitle track stamping each image with its capture time.

usage: gen_ass.py FPS WIDTH HEIGHT OUT_ASS (--frames DIR | --list FILE)

  --frames DIR   a session frames/ directory (times come from the filenames)
  --list FILE    "name<TAB>isotime" lines, as written by build_sequence.py

Times come from the images themselves, so the overlay stays truthful at any
interval and tells the truth across gaps. The images are never modified, which
is why rendering again without the overlay costs nothing.
"""
import argparse
import datetime
import sys

from frames import list_frames

HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: {w}
PlayResY: {h}
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: stamp,DejaVu Sans Mono,{fs},&H00FFFFFF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,{ol},1,1,{m},{m},{m},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def ts(seconds):
    seconds = max(0.0, seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h)}:{int(m):02d}:{s:05.2f}"


def elapsed_label(delta):
    total = int(delta)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fps", type=float)
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("out")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--frames")
    g.add_argument("--list")
    a = ap.parse_args()

    if a.frames:
        times = [t for _p, t in list_frames(a.frames)]
    else:
        times = []
        with open(a.list) as f:
            for line in f:
                if "\t" in line:
                    times.append(datetime.datetime.fromisoformat(line.rstrip("\n").split("\t", 1)[1]))
    if not times:
        sys.exit("no timestamped images found")

    t0 = times[0]
    fs = max(14, round(a.height / 30))          # scale type to the frame
    lines = [HEADER.format(w=a.width, h=a.height, fs=fs,
                           ol=max(1, round(a.height / 540)), m=round(a.height / 40))]

    for i, t in enumerate(times):
        text = f"{t:%Y-%m-%d %H:%M:%S}   +{elapsed_label((t - t0).total_seconds())}"
        lines.append(
            f"Dialogue: 0,{ts(i / a.fps)},{ts((i + 1) / a.fps)},stamp,,0,0,0,,{text}\n"
        )

    with open(a.out, "w") as fh:
        fh.writelines(lines)
    print(f"{len(times)} stamps -> {a.out}")


if __name__ == "__main__":
    main()
