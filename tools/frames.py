#!/usr/bin/env python3
"""Shared frame-listing logic: filenames are the authoritative timestamps."""
import datetime as _dt
import pathlib

PATTERN = "%Y%m%d-%H%M%S"


def frame_time(path):
    """Parse the capture time out of a frame filename, or None."""
    try:
        return _dt.datetime.strptime(pathlib.Path(path).stem, PATTERN)
    except ValueError:
        return None


def list_frames(frames_dir):
    """Sorted [(path, datetime)] for every parseable frame."""
    out = []
    for p in sorted(pathlib.Path(frames_dir).glob("*.jpg")):
        t = frame_time(p)
        if t is not None:
            out.append((p, t))
    out.sort(key=lambda it: it[1])
    return out


def find_gaps(frames, interval, factor=1.5):
    """Runs where the spacing exceeded factor x the configured interval."""
    threshold = interval * factor
    gaps = []
    for (pa, ta), (pb, tb) in zip(frames, frames[1:]):
        delta = (tb - ta).total_seconds()
        if delta > threshold:
            gaps.append({
                "after": pa.name,
                "before": pb.name,
                "seconds": round(delta, 1),
                "missed": max(0, int(round(delta / interval)) - 1),
            })
    return gaps
