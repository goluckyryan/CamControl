#!/usr/bin/env bash
# Build a deliberately awkward image folder: mixed codecs, mixed sizes, and
# names that sort wrongly as plain text (img10 before img2). Each image is
# labelled with its own name so the output order can be checked by eye.
set -euo pipefail
OUT="${1:?usage: test/make-messy-folder.sh DIR [COUNT]}"
N="${2:-12}"
mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
  if (( i % 3 == 0 )); then ext=png; sz=800x600; else ext=jpg; sz=640x480; fi
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=${sz}:rate=1:duration=1" -frames:v 1 \
    -vf "drawtext=text='img${i}':fontsize=90:fontcolor=white:x=(w-tw)/2:y=(h-th)/2" \
    "$OUT/img${i}.${ext}"
done
echo "$N images in $OUT (mixed jpg/png, mixed sizes, non-padded names)"
