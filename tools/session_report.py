#!/usr/bin/env python3
"""Frame statistics and gap detection for one session.

usage: session_report.py FRAMES_DIR INTERVAL [--json]

The gap threshold is derived from the session's own interval, so a session
captured at 20s is not reported as gappy just because another used 10s.
"""
import json
import sys

from frames import find_gaps, list_frames


def build(frames_dir, interval):
    frames = list_frames(frames_dir)
    rep = {
        "count": len(frames),
        "interval_sec": interval,
        "first": None, "last": None, "span_sec": 0,
        "bytes": sum(p.stat().st_size for p, _ in frames),
        "gaps": [],
    }
    if frames:
        rep["first"] = frames[0][1].isoformat(sep=" ")
        rep["last"] = frames[-1][1].isoformat(sep=" ")
        rep["span_sec"] = round((frames[-1][1] - frames[0][1]).total_seconds(), 1)
        rep["gaps"] = find_gaps(frames, interval)
    rep["missed_total"] = sum(g["missed"] for g in rep["gaps"])
    return rep


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    rep = build(args[0], float(args[1]))

    if "--json" in sys.argv[1:]:
        json.dump(rep, sys.stdout, indent=2)
        print()
        return

    print(f"frames    : {rep['count']}")
    print(f"size      : {rep['bytes'] / 1e6:.1f} MB")
    if rep["count"]:
        print(f"first     : {rep['first']}")
        print(f"last      : {rep['last']}")
        print(f"span      : {rep['span_sec'] / 60:.1f} min")
    if rep["gaps"]:
        print(f"gaps      : {len(rep['gaps'])} "
              f"(~{rep['missed_total']} frames missed)")
        for g in rep["gaps"][:10]:
            print(f"    {g['seconds']:.0f}s after {g['after']} "
                  f"(~{g['missed']} frames)")
        if len(rep["gaps"]) > 10:
            print(f"    ... and {len(rep['gaps']) - 10} more")
    else:
        print("gaps      : none")


if __name__ == "__main__":
    main()
