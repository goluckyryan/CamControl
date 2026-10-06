# heliosMoving

Time-lapse rig for watching **Helios** move: take a still every few minutes with
fixed camera settings, then turn the stills into a movie.

Built and tested on a Raspberry Pi 5 (Debian 13) with a **Logitech C920e**.
Nothing needs installing — it uses ffmpeg, v4l2-ctl and Python 3, all already present.

## Quickstart

```sh
./bin/cameras                # what will be used, and why
./run.sh -ss                 # one still, with your settings; check the aim
./run.sh -t 5m -b            # record a frame every 5 minutes, in the background
./bin/status                 # how it is going
./bin/stop                   # stop it
./bin/make-movie             # newest session -> mp4
```

## How a frame is taken

Every frame is taken the same way, and there is no calibration anywhere:

1. open the camera
2. write the `FIX_*` values from `config.sh`
3. stream for `SHOT_SETTLE_SEC` (8 s) so those values take hold
4. keep the last frame, close the camera

The settle in step 3 is not optional and not calibration. **Controls written to
an idle camera are silently discarded** — this camera re-meters whenever a
stream opens — so the values have to go in while it is running, and they need a
few seconds to take. The values are written several times across that window,
because how soon the camera starts listening after a cold open varies.

Because nothing is inferred per frame, every frame of every run uses identical
settings. A brightness change across a long run is the scene changing, not the
camera changing its mind.

## Setting the exposure

Pin it in `config.sh`:

```sh
FIX_EXPOSURE="700"     # higher is brighter, 3..2047 on a C920e
FIX_WB="4500"          # optional; blank leaves white balance on auto
FIX_FOCUS="0"          # optional; blank leaves focus on auto
FIX_GAIN=""            # optional
```

A blank value is left on **auto** rather than frozen, so setting only
`FIX_EXPOSURE` pins exposure and leaves the rest alone.

To find a value, take single shots and look at them:

```sh
./run.sh -ss                 # -> shot-<timestamp>.jpg here
./run.sh -ss try.jpg         # -> a filename you choose
```

`bin/preview` is different: it stays on **auto**, to show what the camera would
pick for itself. `-ss` shows what *you* have picked.

**The camera quantises exposure to its own ladder** (…156, 312, 624, 1250…) and
snaps to the nearest rung, so asking for 700 gives 624 and 1024 gives 1250.
`bin/shot` prints the value the camera actually ran at. It is the same value on
every frame, which is what matters.

If no `FIX_*` value is set at all, capture warns and the camera meters every
shot itself — brightness will then vary frame to frame by roughly 7x, which no
amount of post-processing repairs.

## The interval

Give `run.sh` a time with a unit — `s`, `m` or `h`:

```sh
./run.sh -t 30s
./run.sh -t 5m
./run.sh -t 1h --duration 28800     # hourly, for eight hours
./run.sh -t 5m -b                   # detached; stop with bin/stop
./run.sh -t 5m -n                   # print the command instead of running it
```

**Minimum 16 seconds** — twice `SHOT_SETTLE_SEC`, since each shot spends 8 s
streaming. The default lives in `INTERVAL_SEC` in `config.sh`, and is recorded
in each session's `session.json`, which every other tool reads — so old
sessions keep reporting correctly if you change the default later.

Shots fire on a schedule anchored to the session start, so the time each shot
takes cannot accumulate into drift over days.

Longer intervals make **shorter** films from the same wall-clock run:

| interval | speedup at 24 fps | 1 h becomes | 24 h becomes |
|---|---|---|---|
| 30 s | 720x | 5 s | 2 min |
| 5 min | 7200x | 0.5 s | 12 s |
| 1 h | 86400x | — | 1 s |

Use `--fps` to pull a long-interval session back to a watchable length:
`./bin/make-movie --fps 8`.

Storage, measured at 1080p `-q:v 2` (~180 kB per frame):

| interval | frames/day | per day | per week | per month |
|---|---|---|---|---|
| 30 s | 2880 | ~520 MB | ~3.6 GB | ~15 GB |
| 5 min | 288 | ~52 MB | ~0.36 GB | ~1.6 GB |
| 1 h | 24 | ~4 MB | ~30 MB | ~130 MB |

## Commands

| | |
|---|---|
| `run.sh -t <time>` | record; `30s`, `5m`, `1h` |
| `run.sh -ss [out.jpg]` | one still with your fixed settings |
| `bin/cameras` | list video devices, show which is chosen and why |
| `bin/preview [out.jpg]` | one still on **auto**, to check framing |
| `bin/shot [out.jpg]` | one still with your **fixed** settings (same as `-ss`) |
| `bin/capture` | run a session (`run.sh` is the friendlier front door) |
| `bin/stop [session]` | stop a running session |
| `bin/status [session]` | frames, gaps, capture rate, disk |
| `bin/make-movie [session]` | session frames -> mp4 |
| `bin/folder-movie FOLDER` | **any** folder of images -> mp4 |

`bin/capture` takes `--interval N`, `--duration N`, `--device PATH`, `--name NAME`
and `-b`. `bin/make-movie` takes `--fps N`, `--timestamp`, `--deflicker`,
`--preset P`, `--crf N`, `--out PATH`.

## A session

```
sessions/2026-09-30_112400/
├── frames/20260930-112412.jpg ...   # the movie is built from these
├── session.json                     # device, interval, settings, gaps
├── controls.json                    # what the camera was configured with
├── capture.log                      # ffmpeg output
└── helios_<id>.mp4
```

Frames are named by wall clock, so they sort chronologically and a restart
cannot overwrite one. Nothing is ever deleted.

## Turning any folder of images into a movie

`bin/folder-movie` is independent of sessions — point it at any directory:

```sh
./bin/folder-movie ~/Pictures/screenshots --fps 12 --timestamp
./bin/folder-movie ./shots --recursive --deflicker --out demo.mp4
```

It handles the things that break a naive `ffmpeg -pattern_type glob`:

- **Ordering.** If every filename contains a timestamp it sorts by that; otherwise
  it uses a natural sort, so `img2` comes before `img10` rather than after it.
- **Mixed formats.** A folder holding both JPEG and PNG cannot be read by one
  decoder, and the concat demuxer silently drops the odd ones out. Mixed folders
  are converted to PNG once, losslessly, before encoding.
- **Mixed sizes.** Images are scaled and padded to the first one's size, so nothing
  is cropped.

Accepts jpg, jpeg, png, bmp, tif, tiff, webp, gif.

## Troubleshooting

**"No usable capture device found"** — this Pi has 17 video nodes that are not
cameras (the ISP and HEVC decoder), plus the webcam's own metadata node.
`bin/cameras` lists every one with the reason it was rejected. If the webcam is
missing from that list it is not enumerating: check `lsusb` for it.

**Frames too dark or too bright** — that is `FIX_EXPOSURE`. Take a `-ss` shot,
adjust, repeat. Remember the camera snaps to its own ladder.

**`misses` in `bin/status`** — a shot that produced no frame in its 8 s window,
usually the camera being slow to start or busy. The next interval just tries
again; `capture.log` has the ffmpeg output.

**`Dequeued v4l2 buffer contains corrupted data` in `capture.log`** — normal for a
C920e. ffmpeg discards those buffers before they become files.

**Gaps in the video** — `bin/status` and `bin/make-movie` both report any gap
larger than 1.5x the interval, with the timestamp.

## Layout

```
run.sh                    front door: -t for an interval, -ss for one shot
config.sh                 all defaults, including the FIX_* camera settings
lib/common.sh             paths, logging, interval validation, disk guard
lib/camera.sh             device detection, format probe, applying fixed controls
bin/                      the commands above
tools/pick_format.py      choose a capture mode from the camera's advertised list
tools/frames.py           frame listing and gap detection
tools/session_report.py   frame stats
tools/session_update.py   update session.json
tools/gen_ass.py          timestamp overlay as subtitles (images never rewritten)
tools/build_sequence.py   stage an arbitrary folder as an ordered sequence
test/run-all.sh           run every test file and sum the failures
test/make-session.sh      fabricate a session with no camera, for testing
test/make-messy-folder.sh fabricate an awkward image folder, for testing
test/test_*.sh            interval, detection, assembly, session handling
```

Run the tests with `./test/run-all.sh`. They pass with or without a camera
attached; the camera-only checks report as skipped when it is unplugged.

Encoding is software `libx264`: the Pi 5 has **no** hardware H.264 encoder. ffmpeg
lists `h264_v4l2m2m`, `h264_vaapi`, `h264_nvenc` and `h264_vulkan`, but none has
backing hardware on this board and all fail at runtime.
