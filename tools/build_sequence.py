#!/usr/bin/env python3
"""Stage a folder of images as a numbered sequence ffmpeg can read in order.

usage: build_sequence.py FOLDER WORKDIR [-recursive] [-times FILE]
prints: count=N pattern=PATH first=PATH ordered_by=... normalized=0|1

Flags take one dash, like every other command in this repo.

Why not a concat list or a glob:
  - the concat demuxer picks one decoder from the first entry, so a folder
    mixing JPEG and PNG loses the odd ones out, silently;
  - a glob sorts as text, so img10 lands before img2.
Symlinking into a zero-padded sequence fixes the ordering and costs nothing.
When the folder really does mix codecs, the images are converted to PNG once
(lossless) so a single decoder covers them all.
"""
import argparse
import datetime
import pathlib
import re
import shutil
import sys

EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp", ".gif"}
FAMILY = {".jpg": "jpeg", ".jpeg": "jpeg", ".png": "png", ".bmp": "bmp",
          ".tif": "tiff", ".tiff": "tiff", ".webp": "webp", ".gif": "gif"}

TIME_PATTERNS = ["%Y%m%d-%H%M%S", "%Y%m%d_%H%M%S", "%Y-%m-%d_%H-%M-%S",
                 "%Y-%m-%d_%H%M%S", "%Y%m%d%H%M%S", "%Y-%m-%dT%H-%M-%S"]


def parse_time(stem):
    for pat in TIME_PATTERNS:
        try:
            return datetime.datetime.strptime(stem, pat)
        except ValueError:
            pass
    m = re.search(r"(\d{8}[-_]?\d{6})", stem)
    if m:
        try:
            return datetime.datetime.strptime(
                m.group(1).replace("-", "").replace("_", ""), "%Y%m%d%H%M%S")
        except ValueError:
            pass
    return None


def natural_key(path):
    return [int(t) if t.isdigit() else t.lower()
            for t in re.split(r"(\d+)", path.name)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=pathlib.Path)
    ap.add_argument("workdir", type=pathlib.Path)
    ap.add_argument("-recursive", action="store_true")
    ap.add_argument("-times", type=pathlib.Path)
    a = ap.parse_args()

    it = a.folder.rglob("*") if a.recursive else a.folder.glob("*")
    images = [p for p in it if p.is_file() and p.suffix.lower() in EXTS]
    if not images:
        sys.exit(f"no images found in {a.folder}"
                 f"{' (searched recursively)' if a.recursive else ''}")

    stamps = {p: parse_time(p.stem) for p in images}
    if all(v is not None for v in stamps.values()):
        images.sort(key=lambda p: (stamps[p], natural_key(p)))
        ordered_by = "timestamp"
    else:
        images.sort(key=natural_key)
        ordered_by = "name"
        for p in images:
            if stamps[p] is None:
                stamps[p] = datetime.datetime.fromtimestamp(p.stat().st_mtime)

    families = {FAMILY[p.suffix.lower()] for p in images}
    stage = a.workdir / "seq"
    stage.mkdir(parents=True, exist_ok=True)

    if len(families) == 1:
        ext = images[0].suffix.lower()
        normalized = 0
        for i, p in enumerate(images, 1):
            (stage / f"{i:06d}{ext}").symlink_to(p.resolve())
    else:
        # Mixed codecs: one decoder cannot read them all, so normalise once.
        try:
            from PIL import Image
        except ImportError:
            sys.exit(f"folder mixes {', '.join(sorted(families))}; "
                     "Pillow is needed to normalise them")
        ext, normalized = ".png", 1
        print(f"mixed formats ({', '.join(sorted(families))}); "
              f"converting {len(images)} images to PNG", file=sys.stderr)
        for i, p in enumerate(images, 1):
            dst = stage / f"{i:06d}.png"
            if FAMILY[p.suffix.lower()] == "png":
                shutil.copy2(p, dst)
            else:
                with Image.open(p) as im:
                    im.convert("RGB").save(dst)

    if a.times:
        with open(a.times, "w") as f:
            for p in images:
                f.write(f"{p.name}\t{stamps[p].isoformat()}\n")

    print(f"count={len(images)}")
    print(f"pattern={stage}/%06d{ext}")
    # Named outright so the caller never has to run the pattern through
    # printf, where a '%' in the staging path would be read as a directive.
    print(f"first={stage}/{1:06d}{ext}")
    print(f"ordered_by={ordered_by}")
    print(f"normalized={normalized}")


if __name__ == "__main__":
    main()
