# heliosMoving

Time-lapse rig for watching **Helios** move: take a still every few minutes with
fixed camera settings, then turn the stills into a movie.

Built and tested on a Raspberry Pi 5 (Debian 13) with a **Logitech C920e** and a
**4K SPL6418** (a Philips 4000-series unit; it enumerates as `XIFT SPL6418`).
Nothing needs installing — it uses ffmpeg, v4l2-ctl and Python 3, all already present.

Capture resolution is not configured per camera: `MAX_WIDTH`/`MAX_HEIGHT` in
`config.sh` are a **ceiling**, and the largest mode at or below it is chosen. The
default is 3840x2160, so the SPL6418 shoots 4K and the C920e still shoots 1080p
without changing anything.

## Quickstart

Every flag in this rig takes **one** dash, long names included: `-motion`, not
`--motion`.

```sh
./bin/cameras                # what will be used, and why
./run.sh -ss                 # one still, with your settings; check the aim
./run.sh -t 5m -b            # record a frame every 5 minutes, in the background
./run.sh -t 5m -motion       # ...plus one whenever something moves
./run.sh -motion-only        # ...and nothing unless something moves
./run.sh -t 5m -I            # ...and type 'shot' / 'status' / 'stop' at it
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
`FIX_EXPOSURE` pins exposure and leaves the rest alone — where the camera has an
auto mode to leave it in. The SPL6418 has none for exposure: it reports
`auto_exposure` as Manual Mode only and rejects every other setting, so on that
camera exposure is always manual whether or not you pin it.

### The ranges differ between cameras

They are not even the same *kind* of number. Run
`v4l2-ctl -d /dev/video0 --list-ctrls-menus` for the camera actually attached:

| control | C920e | SPL6418 |
|---|---|---|
| `exposure_time_absolute` | 3..2047 | 1..12287, but only moves the image over roughly **1..30**; flat above that |
| `white_balance_temperature` | 2000..6500, in Kelvin | **1..5, an index** — not Kelvin |
| `focus_absolute` | 0..250 step 5 | **absent**; focus is fixed and `FIX_FOCUS` is ignored |
| `gain` | 0..255 | 0..255 |
| `auto_exposure` | auto or manual | **manual only** |

The white balance row is the one that bites. A driver **clamps an out-of-range
value silently** — no error, no non-zero exit — so `FIX_WB="4500"` written to an
SPL6418 becomes `5` and shows up only as a wrong-looking picture. Capture now
warns when it writes a value the camera will clamp:

```
warning: white_balance_temperature=4500 is outside this camera's range 1..5
and will be clamped; run 'v4l2-ctl -d ... --list-ctrls-menus' for the real ranges
```

The value is still written — the clamp stays the driver's decision, not ours.

To find a value, take single shots and look at them:

```sh
./run.sh -ss                 # -> shot-<timestamp>.jpg here
./run.sh -ss try.jpg         # -> a filename you choose
```

`bin/preview` is different: it stays on **auto**, to show what the camera would
pick for itself. `-ss` shows what *you* have picked. On a camera with no auto
exposure mode, such as the SPL6418, the two differ only by the other `FIX_*`
values — preview cannot put exposure back on auto because there is no auto.

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
./run.sh -t 1h -duration 8h         # hourly, for eight hours
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

Use `-fps` to pull a long-interval session back to a watchable length:
`./bin/make-movie -fps 8`.

Storage, measured at 1080p `-q:v 2` (~180 kB per frame):

| interval | frames/day | per day | per week | per month |
|---|---|---|---|---|
| 30 s | 2880 | ~520 MB | ~3.6 GB | ~15 GB |
| 5 min | 288 | ~52 MB | ~0.36 GB | ~1.6 GB |
| 1 h | 24 | ~4 MB | ~30 MB | ~130 MB |

At 4K a frame measures ~560 kB, so roughly 3x that:

| interval | frames/day | per day | per week | per month |
|---|---|---|---|---|
| 30 s | 2880 | ~1.6 GB | ~11 GB | ~48 GB |
| 5 min | 288 | ~160 MB | ~1.1 GB | ~4.8 GB |
| 1 h | 24 | ~13 MB | ~94 MB | ~400 MB |

A 30-second interval at 4K fills a disk in a way a 5-minute one does not; check
`df -h` before committing to a long fast run. `MIN_FREE_MB` refuses to start
below 2 GB free, which is a floor, not a budget for the run ahead.

## Motion-triggered frames

`-motion` also watches the scene between the scheduled frames and takes an
extra still when something moves. `MOTION=1` in `config.sh` turns it on for
every session instead, so you do not have to remember the flag:

```sh
./run.sh -t 5m -motion
./bin/capture -interval 300 -motion -sensitivity 1.5 -cooldown 30
```

The capture device belongs to whoever has it open, so there is no background
watcher. In the idle gap between scheduled frames, `bin/capture` opens the
camera's *small* mode — the largest one at or below
`MOTION_MAX_WIDTH`/`MOTION_MAX_HEIGHT` — pipes the frames, scaled down and
greyscaled, through `tools/motion_watch.py`, and closes again. A trigger is
`MOTION_SENS` percent of the picture changing **against
both** of the two previous frames: that is what a one-frame sensor glitch
cannot survive, and what a lamp switching on does not qualify as (a step is
a change of scene, not motion). The shutter also never fires off the watcher
alone twice in a hurry: `MOTION_COOLDOWN_SEC` spaces motion frames.

Motion frames go into the same `frames/` folder through exactly the shot
path described above — same fixed settings, same settle — so in the movie
they are indistinguishable from timed frames except that they arrive off
the grid. The grid itself never moves for a motion frame. (`-hot` changes
only *how fast* the frame is saved, and defaults on for `-motion-only`,
off for `-motion`; see below.)

Things worth knowing:

- Watching only happens in an idle gap of `SHOT_SETTLE_SEC + 5` (13 s) or
  more; below that the camera is in a shot or in the handover back from the
  watcher. A shot also streams `SHOT_SETTLE_SEC`, so an interval under ~29 s
  leaves no window at all and `bin/capture` says so at startup — a 30 s
  interval clears the floor by a second or two, a 5 m one spends almost the
  whole gap watching. Motion-only sessions watch for the entire session, so
  no interval can starve them.
- The watcher re-writes the `FIX_*` controls on every open (the camera
  re-meters when a stream starts, and a brightness step reads as the whole
  scene moving) and ignores the first `MOTION_WARMUP_SEC` seconds of each
  window while that lands.
- Tuning signal: when a watch window ends with its peak change above half
  the trigger level, the watcher prints `motion: none (N frames, peak
  P%)`. It goes to the terminal, or to `supervisor.log` in a background
  session. Wind-blown foliage and night headlights are the classic false
  triggers; raise `MOTION_SENS` when the log says the scene "almost" moves.
  Measured the other way: with `FIX_EXPOSURE` set, the differ's own noise
  floor is ~0.003% (one stray pixel per frame at worst), so dropping to
  `-sensitivity 0.5` or `0.2` for a dim or distant subject carries a
  thirty-fold safety margin against noise-only triggers.
- `session.json` records `motion: {enabled, timed, sensitivity,
  cooldown_sec, triggered}` and `bin/status` prints a one-line summary.

### Motion only

`-motion-only` drops the clock entirely: **no frames are recorded unless
something moves.** It implies `-motion`, ignores `-t` — there are no timed
frames, the value only travels into `session.json` — and follows the same
cooldown and settle rules. `MOTION_ONLY=1` in `config.sh` makes it the default.

```sh
./run.sh -motion-only                    # until stopped
./run.sh -motion-only -duration 8h -b    # eight hours of watching, detached
```

The watcher runs in bounded windows (`MOTION_WINDOW_SEC`, default 600 s)
rather than one endless stream, so the camera is released periodically and
the `FIX_*` values are re-written. Note what that costs: **every reopen is
blind for about 3 s** (stream open plus `MOTION_WARMUP_SEC`), so motion in
the first seconds of a session or window cannot be seen — windows are long
by default precisely to make those blind moments rare.

By default `-motion-only` also watches in *hot* mode (`-hot`, or
`MOTION_HOT=1`): the stream runs at full shot resolution and ffmpeg keeps the
newest frame's JPEG in RAM (`/dev/shm`) the whole time — the camera's MJPEG
frames ARE JPEGs, so this is a packet copy, not a re-encode, and the held
frame is exactly what the camera saw. A trigger then saves that frame with a
file move: **sub-second, and it shows the scene at the moment of the
trigger**, not 8 s after it — the one-second hold below is what pushes that
moment slightly later. The cost is continuous CPU (about one core while
watching); `-no-hot` (`MOTION_HOT=0`) goes back to the small watcher and the
slow reopen, and is what `-motion` uses by default — there a timed frame is
always due soon anyway, and motion frames deliberately stay pixel-identical to
timed ones. Leaving `MOTION_HOT` empty in `config.sh` is what picks hot for
motion-only and cold for `-motion`.

A hot trigger is also *held back* for a moment: the shipped `MOTION_DELAY_SEC`
of 1 keeps the watch stream open a second after the trigger and saves the
frame from that moment — the walking subject has reached the frame instead of
having just entered its edge. The hold never runs past the end of the watch
window, so a scheduled shot is never late; the frame it saves is simply the
one at deadline. `-delaySec 0` saves the triggering frame itself. Set the
hold by how fast the subject is: a car is gone again inside a second, so it
wants 0 or close to it, while someone walking is only properly in shot a
second or two after they first trip the differ.

Without hot mode a motion-triggered frame is still a full shot: the
watcher hands the camera to `take_shot`, which streams `SHOT_SETTLE_SEC`
before keeping the frame, so the picture is several seconds old when it
lands. For a fixed scene that is free; for a moving subject it means the
person may be gone from the frame. `MOTION_SETTLE_SEC` shortens just the
motion frames' settle (minimum 2 s; it applies to non-hot watchers only,
since a hot frame is a frame already watched rather than one still to be
settled). The hold above still applies here — it just postpones the reopen
instead of advancing a held frame.

After a real trigger, `capture.log` shows `Broken pipe` lines from ffmpeg —
it was writing to the watcher when the decision was made. That is the
trigger path working, not a fault (same for the odd `overread 8` line when
the camera's final frame is cut short). An empty scene means an empty
session — that is the feature, not a failure; `bin/status` will not nag about
overdue frames in this mode, and it measures the capture rate from the frames
that actually arrived instead of projecting from a cadence. Beware before
committing to a long run: with no interval to lean on, disk use is entirely up
to the scene, and a busy street at `-sensitivity 1` is not the same bargain
as a still bedroom. The movie's "speedup" number also stops meaning much —
motion-only sequences have no uniform speed to describe.

## Commands

| | |
|---|---|
| `run.sh -t <time>` | record; `30s`, `5m`, `1h` — add `-motion` to also shoot on movement, `-motion-only` to shoot *only* on movement, `-I` to type commands at it while it runs |
| `run.sh -ss [out.jpg]` | one still with your fixed settings |
| `bin/cameras` | list video devices, show which is chosen and why |
| `bin/preview [out.jpg]` | one still on **auto**, to check framing |
| `bin/shot [out.jpg]` | one still with your **fixed** settings (same as `-ss`) |
| `bin/capture` | run a session (`run.sh` is the friendlier front door) |
| `bin/stop [session]` | stop a running session |
| `bin/status [session]` | frames, gaps, capture rate, disk |
| `bin/make-movie [session]` | session frames -> mp4 |
| `bin/folder-movie FOLDER` | **any** folder of images -> mp4 |

`run.sh` takes `-t` / `-time`, `-ss` / `-single-shot`, `-n` / `-dry-run` and
`-h` / `-help`; everything else is passed straight through to `bin/capture`.

`bin/capture` takes `-i` / `-interval N`, `-d` / `-duration N`, `-device PATH`,
`-name NAME`, `-b` / `-background`, `-I` / `-interactive` (see
[Talking to a session while it runs](#talking-to-a-session-while-it-runs)),
and `-motion` / `-motion-only` /
`-no-motion` with `-sensitivity N` (percent, 0–100), `-cooldown N`
(seconds), `-delaySec N` (save the frame N seconds after the trigger, min
0.1), and `-hot` / `-no-hot` (save the watched frame directly, or reopen
and settle).

`bin/make-movie` takes `-fps N`, `-timestamp`, `-deflicker`,
`-preset P`, `-crf N`, `-out PATH`. `bin/folder-movie` takes the same
options plus `-size WxH` and `-recursive`.

Every default these flags override lives in `config.sh`; all of them are
listed in [Every value config.sh controls](#every-value-configsh-controls).

## Talking to a session while it runs

`-I` (or `-interactive`) makes a session read commands from your terminal
while it captures. It is a way to change your mind mid-run, not to change what
the run *is*: timed, motion, and motion-only each decide their own cadence and
none of them can be switched into another. `-I` therefore stays in the
foreground — `-b` is ignored, because a detached session has no terminal left
to type into.

```sh
./run.sh -t 5m -I                      # frames every 5 min, and you have the wheel
./run.sh -motion-only -I               # nothing recorded unless something moves
```

| command | what it does |
|---|---|
| `shot` | take a frame now |
| `delay N` | motion hold, as `-delaySec` |
| `sens N` | motion sensitivity, as `-sensitivity` |
| `cooldown N` | motion spacing, as `-cooldown` |
| `quality N` | JPEG quality of later frames |
| `exposure N` `wb N` `focus N` `gain N` | the `FIX_*` value, for later frames |
| `more T` | end `T` later than planned (`30m`, `8h`) |
| `never` | drop the `-duration` end time |
| `status` | frames, next shot, when it ends |
| `stop` | stop, same as Ctrl-C |

Type `help` for that list. `#` starts a comment, so a line can be
`delay 3  # it was too eager`.

Two things about the timing are worth knowing, both because the camera can
only be held by one thing at a time:

A **`shot` lands on the schedule, it does not become the schedule.** In a timed
run the grid stays anchored to the session start, so taking one at 2 minutes
past does not move the 5-minute frame; in a motion-only run there is no grid to
disturb. Either way it counts as a frame for the cooldown, which is what keeps
the watcher from firing again a second later on the same movement.

A **watcher value takes effect one window later**, so ending the window in
progress is the cheapest way to make that "later" mean now. You pay a camera
reopen — the same handover that happens at every window boundary anyway. A
frame already streaming is never thrown away: `status` while a shot is in
flight waits for it, because the alternative is losing a frame to a question.

`quality` and the `FIX_*` commands change how later frames look, so a session
driven that way is deliberately not uniform end to end. Whatever the session
ended up using is what `session.json` records — retuned values overwrite the
ones at startup, and a run extended with `more` records the longer duration —
so the movie and `bin/status` describe the frames you have rather than the
plan you started with.

The commands go through a folder of one-line files under the session
(`cmd/`), not a pipe the session polls: the process spends its waiting time
asleep or inside the watcher, both of which have to be woken rather than read
from. A command is written, the session is poked, and the command is carried
out at the top of the loop that owns the camera. That is why a command lands
between actions rather than in the middle of one, and it is why a session is
still obedient when typed at from the other side of an ssh session that
dropped — if the terminal goes away, the session says so and carries on
recording.

## Every value config.sh controls

Defaults are the ones shipped; a command-line flag overrides the file for one
run. Only `SESSIONS_DIR`, `MOTION_SETTLE_SEC`, `MOTION_DELAY_SEC` and
`MOTION_HOT` look at the environment first — the rest are plain assignments, so
an exported variable of the same name is overwritten by the file.

| | default | meaning | flag |
|---|---|---|---|
| **Cadence** | | | |
| `INTERVAL_SEC` | 300 | seconds between frames; minimum twice `SHOT_SETTLE_SEC` | `-t` in `run.sh`, `-i` in `bin/capture` |
| `DURATION_SEC` | 0 | stop after this long (s/m/h suffix ok); 0 = until stopped | `-duration` |
| `SHOT_SETTLE_SEC` | 8 | streaming seconds per shot before the frame is kept | — |
| **Motion** | | | |
| `MOTION` | 0 | 1 = watch for motion in **every** session, not only `-motion` ones | `-motion`, `-no-motion` |
| `MOTION_ONLY` | 0 | 1 = shoot only on motion; no timed frames | `-motion-only` |
| `MOTION_SENS` | 2 | percent of the picture that must change to trigger (0 < N ≤ 100) | `-sensitivity` |
| `MOTION_COOLDOWN_SEC` | 5 | minimum spacing between two motion frames | `-cooldown` |
| `MOTION_DELAY_SEC` | 1 | after a trigger, keep watching this long and save the frame from then (min 0.1; 0 saves the triggering frame) | `-delaySec` |
| `MOTION_HOT` | empty | 1/0 = save the watched frame directly / reopen and settle; empty chooses per mode (on for motion-only, off for `-motion`) | `-hot`, `-no-hot` |
| `MOTION_MAX_WIDTH`<br>`MOTION_MAX_HEIGHT` | 640×360 | ceiling for the small watching mode — the largest the camera offers at or below it. Non-hot watching only: hot mode streams at the shot mode | — |
| `MOTION_WARMUP_SEC` | 2 | seconds ignored at the start of every watch window, while the re-written `FIX_*` values land | — |
| `MOTION_WINDOW_SEC` | 600 | longest one watching stream stays open before the camera is released and reopened | — |
| `MOTION_SETTLE_SEC` | empty | settle for a motion-triggered frame, empty = `SHOT_SETTLE_SEC` (min 2); non-hot watchers only | — |
| **Image** | | | |
| `MAX_WIDTH` × `MAX_HEIGHT` | 3840×2160 | **ceiling** on frame size; the largest mode at or below it is used | — |
| `JPEG_QUALITY` | 2 | ffmpeg `-q:v` for the stills: 2 best, 31 worst | — |
| **Camera** | | | |
| `DEVICE` | empty | device path, ideally a `/dev/v4l/by-id/...` symlink; empty = auto-detect | `-device` |
| `FIX_EXPOSURE` | 350 | `exposure_time_absolute`; 3..2047 on a C920e, effectively 1..30 on the SPL6418 | — |
| `FIX_WB` | empty | `white_balance_temperature`; Kelvin on a C920e, an index 1..5 on the SPL6418 | — |
| `FIX_FOCUS` | empty | `focus_absolute`, 0..250 step 5; the control is absent on the SPL6418 | — |
| `FIX_GAIN` | empty | `gain`, 0..255 | — |
| `ZOOM` | empty | `zoom_absolute`, 100..500 | — |
| `PAN` / `TILT` | empty | `pan_absolute` / `tilt_absolute`, −36000..36000 step 3600 | — |
| `POWER_LINE_FREQ` | 2 | anti-banding under artificial light: 1 = 50 Hz, 2 = 60 Hz | — |
| `WARMUP_SEC` | 4 | seconds `bin/preview` streams before it keeps a frame; capture does not use it — every shot settles on `SHOT_SETTLE_SEC` | — |
| **Movie** | | | |
| `OUT_FPS` | 24 | playback rate; speedup = interval × fps | `-fps` |
| `CRF` | 18 | libx264 quality, lower is better | `-crf` |
| `PRESET` | medium | libx264 speed/size tradeoff | `-preset` |
| **Paths and safety** | | | |
| `SESSIONS_DIR` | `sessions/` | where sessions are written; absolute, or relative to the repo | env only |
| `MIN_FREE_MB` | 2048 | refuse to start a session below this much free space | — |

`ZOOM`, `PAN`, `TILT` and `POWER_LINE_FREQ` go in on every camera open, just
before the `FIX_*` values, and a control the camera does not have is skipped —
as is `FIX_FOCUS` on the SPL6418, which has none. `exposure_dynamic_framerate`
is always turned off where it exists: left on, the camera stretches exposure
by quietly dropping framerate, and both the cadence and the look drift
mid-run. The watcher's lowest framerate, `MOTION_MIN_FPS`, is internal to
`lib/common.sh` and is not in `config.sh`.

## A session

Sessions live under `sessions/` in the repo — change `SESSIONS_DIR` in
`config.sh` to put them on another disk (absolute path, or relative to
the repo; a background run follows it too). An env override wins over
the file for a one-off: `SESSIONS_DIR=/mnt/usb/sessions ./run.sh -t 5m`.
Whatever the setting is, all commands (`capture`, `status`, `stop`,
`make-movie`) read the same folder, so point every command at the same
place or none will find the other's sessions.

```
sessions/2026-09-30_112400/
├── frames/20260930-112412.jpg ...   # the movie is built from these
├── session.json                     # device, interval, settings, gaps
├── controls.json                    # what the camera was configured with
├── capture.log                      # ffmpeg output
├── cmd/                             # only while an -I session runs: typed commands
└── helios_<id>.mp4
```

Frames are named by wall clock, so they sort chronologically and a restart
cannot overwrite one. Nothing is ever deleted.

## Turning any folder of images into a movie

`bin/folder-movie` is independent of sessions — point it at any directory:

```sh
./bin/folder-movie ~/Pictures/screenshots -fps 12 -timestamp
./bin/folder-movie ./shots -recursive -deflicker -out demo.mp4
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

**Changing `FIX_EXPOSURE` does nothing** — on an SPL6418 the control only moves
the image over roughly 1..30, and is flat from there to its advertised maximum of
12287. A value like 350 sits well inside that plateau, so large changes to it
look like no change at all. Work in the low end.

**`FIX_FOCUS` seems ignored** — the SPL6418 exposes no focus control at all, so
there is nothing to write; `bin/cameras` and `v4l2-ctl --list-ctrls-menus` show
what the attached camera actually has.

**`misses` in `bin/status`** — a shot that produced no frame in its 8 s window,
usually the camera being slow to start or busy. The next interval just tries
again; `capture.log` has the ffmpeg output.

**`Dequeued v4l2 buffer contains corrupted data` in `capture.log`** — normal for a
C920e. ffmpeg discards those buffers before they become files.

**`unable to decode APP fields` while capturing** — the SPL6418 writes private
APP metadata into every MJPEG frame. ffmpeg's decoder errors on those fields
but decodes the image itself, so the frame is fine and the capture succeeds;
it is the last of the metadata that failed, not the picture. `bin/shot`,
`bin/capture` and `bin/preview` drop exactly these lines for cameras whose
card name matches (the C920e does not produce them); any other ffmpeg output
still shows. See `cam_hush_stderr` in `lib/camera.sh`.

**Gaps in the video** — `bin/status` and `bin/make-movie` both report any gap
larger than 1.5x the interval, with the timestamp.

## Layout

```
run.sh                    front door: -t for an interval, -ss for one shot
config.sh                 all defaults, including the FIX_* camera settings
lib/common.sh             paths, logging, interval validation, disk guard
lib/camera.sh             device detection, format probe, applying fixed controls,
                          range-checking a value before the driver clamps it,
                          silencing one camera's per-frame metadata noise
lib/motion.sh             opening/closing the watching stream and killing it
tools/motion_watch.py     the frame differ that decides whether something moved
bin/                      the commands above
tools/pick_format.py      choose a capture mode from the camera's advertised list
tools/frames.py           frame listing and gap detection
tools/session_report.py   frame stats
tools/session_update.py   update session.json
tools/gen_ass.py          timestamp overlay as subtitles (images never rewritten)
tools/build_sequence.py   stage an arbitrary folder as an ordered sequence
```

Encoding is software `libx264`: the Pi 5 has **no** hardware H.264 encoder. ffmpeg
lists `h264_v4l2m2m`, `h264_vaapi`, `h264_nvenc` and `h264_vulkan`, but none has
backing hardware on this board and all fail at runtime.

That is slow but not prohibitive at 4K: measured ~2.6 frames/s at `crf 18 preset
medium`, so a 288-frame day encodes in under two minutes and a 2880-frame day in
about twenty. Drop to `-preset fast` if that matters.
