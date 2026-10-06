#!/usr/bin/env python3
"""Update a session.json in place.

usage: session_update.py SESSION_JSON [--set k=v]... [--controls FILE] [--report]

--report recomputes frame stats and gaps using the interval already recorded in
the file, so the numbers always match how that session was actually captured.
"""
import json
import os
import sys

from session_report import build


def typed(v):
    for cast in (int, float):
        try:
            return cast(v)
        except ValueError:
            pass
    return {"true": True, "false": False, "null": None}.get(v, v)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path) as f:
        data = json.load(f)

    args = sys.argv[2:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--set":
            k, _, v = args[i + 1].partition("=")
            data[k] = typed(v)
            i += 2
        elif a == "--controls":
            cf = args[i + 1]
            if os.path.exists(cf):
                with open(cf) as f:
                    data["controls"] = json.load(f)
            i += 2
        elif a == "--report":
            frames = os.path.join(os.path.dirname(os.path.abspath(path)), "frames")
            rep = build(frames, float(data.get("interval_sec") or 10))
            data["frames"] = rep["count"]
            data["bytes"] = rep["bytes"]
            data["first_frame"] = rep["first"]
            data["last_frame"] = rep["last"]
            data["span_sec"] = rep["span_sec"]
            data["gaps"] = rep["gaps"]
            i += 1
        else:
            sys.exit(f"unknown argument: {a}")

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
