#!/usr/bin/env bash
# Fabricate a session with no camera, so the assembly path can be tested.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need ffmpeg

IV=10; N=120; GAP=1; NAME=""; W=640; H=360
while (( $# )); do
  case "$1" in
    --interval) IV="${2:?}"; shift 2 ;;
    --frames)   N="${2:?}"; shift 2 ;;
    --name)     NAME="${2:?}"; shift 2 ;;
    --size)     W="${2%%x*}"; H="${2##*x}"; shift 2 ;;
    --no-gap)   GAP=0; shift ;;
    -h|--help)  echo "usage: test/make-session.sh [--interval N] [--frames N] [--size WxH] [--no-gap] [--name NAME]"; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

SID="${NAME:-test-iv${IV}-$(date '+%H%M%S')}"
SDIR="$SESSIONS_DIR/$SID"
[[ -e "$SDIR" ]] && die "session '$SID' already exists"
mkdir -p "$SDIR/frames"

info "generating $N frames at ${W}x${H} ..."
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=${W}x${H}:rate=1:duration=${N}" \
  -frames:v "$N" -q:v 3 "$SDIR/frames/seq_%05d.jpg"

# Rename to the strftime-style names real capture produces, so the assembly
# path sees exactly the same input shape it will see in production.
python3 - "$SDIR" "$IV" "$GAP" <<'PY'
import datetime, json, pathlib, sys

sdir, iv, gap = pathlib.Path(sys.argv[1]), float(sys.argv[2]), sys.argv[3] == "1"
seq = sorted((sdir / "frames").glob("seq_*.jpg"))
start = datetime.datetime.now().replace(microsecond=0) - datetime.timedelta(
    seconds=iv * len(seq) + (30 * iv if gap else 0))

t = start
for i, p in enumerate(seq):
    # A deliberate outage halfway through, to prove gap detection works.
    if gap and i == len(seq) // 2:
        t += datetime.timedelta(seconds=30 * iv)
    p.rename(p.with_name(t.strftime("%Y%m%d-%H%M%S") + ".jpg"))
    t += datetime.timedelta(seconds=iv)

json.dump({
    "id": sdir.name, "device": "synthetic", "card": "testsrc2",
    "format": "MJPG", "interval_sec": iv, "duration_sec": 0, "jpeg_quality": 3,
    "started": start.isoformat(sep=" ", timespec="seconds"),
    "ended": t.isoformat(sep=" ", timespec="seconds"),
    "frames": len(seq), "restarts": 0, "controls": {}, "gaps": [],
    "synthetic": True,
}, open(sdir / "session.json", "w"), indent=2, sort_keys=True)
print(f"{len(seq)} frames at {iv}s" + (f", with a {int(30*iv)}s gap" if gap else ""))
PY

python3 "$HELIOS_ROOT/tools/session_update.py" "$SDIR/session.json" \
  --set "width=$W" --set "height=$H" --report
ok "created $SDIR"
