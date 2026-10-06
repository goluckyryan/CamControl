# heliosMoving — plan, as built

> **Superseded in part (2026-09-30).** Stream mode and all calibration were
> removed. Capture now opens the camera once per frame, writes the fixed
> `FIX_*` values from `config.sh`, streams `SHOT_SETTLE_SEC` so they take hold,
> and keeps the last frame. Everything below about holding one ffmpeg open for
> the session, auto-convergence, warmup frames, the supervisor and re-locking
> describes code that no longer exists. The hardware findings still hold, and
> findings 12 and 13 are why the current design works the way it does.

Time-lapse rig: photograph **Helios** (a machine that moves) from a USB webcam at a
user-configurable interval, then assemble the stills into a movie.

This document is the approved plan with implementation findings folded in. Where
building it contradicted the plan, the plan is corrected and the correction noted.
Day-to-day usage lives in `README.md`.

## Decisions

- **Subject:** a mechanical object, not the sun. No solar math, no daylight filtering.
  Consistency between frames is what matters, so exposure / white balance / focus are
  locked for the duration of a run.
- **Run mode:** on-demand sessions. No systemd unit, no boot integration, no pruning.
- **Interval:** a setting, not a constant. 10 s is the default; 20 s or any value
  `>= 1 s` needs no code change.
- **Every still is kept.** Frames shot before the exposure lock are moved aside, never
  deleted.

## Hardware (measured, not assumed)

**Logitech C920e**, serial `6BD1F69F`, `uvcvideo`, USB 2.0.

| | |
|---|---|
| capture node | `/dev/video0` |
| metadata node | `/dev/video1` — no `Video Capture` cap, must be skipped |
| stable path | `/dev/v4l/by-id/usb-046d_Logi_Webcam_C920e_6BD1F69F-video-index0` |
| MJPG | 1920x1080 @ 5 / 7.5 / 10 / 15 / 20 / 24 / 30 fps |
| YUYV | 2304x1536 max, but only 5 fps at 1080p — USB 2.0 bound, so unused |
| time to first usable frame | **~16 s**, and independent of capture framerate |

Host: Raspberry Pi 5, Debian 13, 105 GB free. ffmpeg 7.1.4, Python 3.13 + Pillow,
`v4l2-ctl`. No apt, pip or venv needed.

The camera was unplugged and replugged mid-development. The `by-id` path was
unchanged across the replug, which is the reason capture addresses the device that
way rather than by `/dev/video0`.

## Design

### Capture

One long-lived ffmpeg holds the camera open for the whole session. Re-opening per
tick would burn 1–3 s of every interval on warmup and land each frame on a different
settling result.

```sh
ffmpeg -nostdin -loglevel warning \
  -f v4l2 -input_format mjpeg -video_size "${W}x${H}" -framerate "$CAP_FPS" \
  -i "$DEV" -vf "fps=1/${INTERVAL_SEC}" -q:v 2 \
  -strftime 1 -atomic_writing 1 "$FRAMES/%Y%m%d-%H%M%S.jpg"
```

- `-strftime` names frames by wall clock: chronological, and survives a supervisor
  restart without overwriting (a `%06d` counter would restart at 1 and clobber).
- `-atomic_writing` means `make-movie` never sees a half-written JPEG, so a movie can
  be built from a session that is still running.
- `$CAP_FPS` is the lowest advertised rate `>= 1/INTERVAL_SEC` (5 fps here), so ffmpeg
  is not decoding 30 fps of 1080p only to discard it.

A supervisor restarts ffmpeg if it exits unexpectedly and counts the restarts;
`dmesg` showed the camera taking a USB reset on plug-in, so this is not theoretical.

### Interval

`INTERVAL_SEC` in `config.sh`, overridable with `--interval`, recorded in
`session.json`, and read from there by every downstream tool — so a session captured
at 20 s still reports correctly after the default changes.

Rejected below 1 s and warned below 2 s: frame filenames have one-second resolution,
so two frames in the same second would collide and one would be lost.

### Exposure locking

Let the camera's auto modes converge, read back what they chose, pin it. Order is
mandatory: the value controls report `flags=inactive` and are unwritable until their
auto counterparts are cleared.

Controls on this camera are the modern names (`auto_exposure`,
`exposure_time_absolute`, `white_balance_automatic`, `white_balance_temperature`,
`focus_automatic_continuous`, `focus_absolute`, `gain`), with legacy fallbacks probed
for portability. Also set: `exposure_dynamic_framerate=0` (it was on, against a
default of 0, and would otherwise stretch exposure by dropping framerate in dim
light) and `power_line_frequency=2`.

### Movie assembly

`libx264`, software — the Pi 5 has no hardware H.264 encoder, and the four hardware
encoders ffmpeg advertises all fail at runtime here. Output is explicitly converted
to limited-range `yuv420p`. Gaps beyond `1.5 x INTERVAL_SEC` are reported before
encoding. `--timestamp` burns an overlay generated as ASS subtitles, so the JPEGs are
never rewritten.

### Arbitrary folders

`bin/folder-movie` converts any directory of images, independent of sessions. It
stages them as a symlinked numbered sequence, which fixes ordering (natural sort, so
`img2` precedes `img10`) and lets one decoder read the lot. Folders mixing codecs are
normalised to PNG once, losslessly.

## Corrections found while building

**1. A verification expectation in the plan was simply wrong.** The plan said "check
the 20 s movie is half the length of the 10 s one." It is not: video length is
`frames / fps`, independent of interval. Both produced 5.0 s from 120 frames. The
interval sets how much *real time* those frames span. Holding wall-clock span
constant instead — 20 min at 10 s vs 20 s — correctly gives 5.0 s vs 2.5 s.

**2. The warmup was locking controls mid-convergence.** A fixed 4 s timer fired before
the camera had produced any frame at all, freezing focus at whatever it was passing
through: 40, 10, then 0 across three runs. Replaced with: wait for the first real
frame, then poll the controls until three consecutive reads match. Now repeatable
(`exposure=77, focus=0, WB=4087` on consecutive runs).

**3. Time-to-first-frame is ~16 s and does not depend on capture framerate** (measured
16.7 s at 5 fps, 16.0 s at 30 fps). So it is the camera initialising, not a buffer
backlog — which confirms the 5 fps choice costs nothing in startup latency.

**4. The concat demuxer silently dropped images.** It picks one decoder from the first
entry, so a folder mixing JPEG and PNG lost frames: 10 of 12 survived. Replaced with
staged sequence + normalisation. All 12 now, in the right order.

**5. Storage was overestimated ~2.5x.** Measured 170–186 kB per 1080p frame at
`-q:v 2`, not the 300–500 kB assumed. So ~65 MB/hour at 10 s, not 150 MB. The tight
spread of those file sizes is also evidence the exposure lock is holding.

**6. Three ordinary bugs**, each caught by a test rather than by reading:
`ffprobe -of csv=p=0:s=' '` is rejected for the space separator (latent in
`make-movie` too, on a path that had never run); `--out` with a relative path broke
because assembly `cd`s into the session; output was tagged `yuvj420p` rather than
`yuv420p`.

**7. Background sessions discarded their supervisor output**, including restart
warnings, because the detached re-exec sent everything to `/dev/null`. Now
`sessions/<id>/supervisor.log`.

**8. Warmup frames are moved, not deleted** (`warmup/`), so a session folder holds
every image the camera produced.

**9. Restart recovery restored the stream but not the camera.** The supervisor
relaunched ffmpeg and left it there. Controls survive an ordinary device close
(verified: they still read back locked minutes after capture exits), so a plain
crash was harmless — but a USB reset, the very thing the supervisor exists for,
restores `auto_exposure=3`, `white_balance_automatic=1`,
`focus_automatic_continuous=1`, silently returning the rest of the session to
the flicker the lock exists to prevent.

The first attempt at a fix re-applied the controls *before* relaunching ffmpeg,
and that does not work: see finding 12. A restart now clears the auto flags at
once, waits for the new stream to deliver a frame, and only then restores the
values from `controls.json`, confirming with two agreeing reads a second apart.
The count lands in `session.json` as `relocks`. Verified against a real reset:
with the camera shoved back to auto mid-session and ffmpeg killed, exposure,
white balance and focus were all back at their locked values and still there
70 s later.

**12. Two hardware behaviours the lock has to work around**, both found while
testing finding 9 and neither previously known:

- *Opening a stream resets `exposure_time_absolute`* — to 77 here — even when
  `auto_exposure` is already Manual. A value written while the device is closed
  is therefore discarded by the next stream open, which is why the re-lock has
  to wait for a live frame. It also means `cam_lock_intact`, which reads only
  the auto flag, can report the lock healthy while the value has been wiped;
  a restart now re-applies unconditionally rather than trusting that check.
- *Exposure is quantised to a ladder of the camera's own*, and the requested
  value keeps reading back for about a second before it settles: 500 becomes
  312, 200 becomes 156. `_cam_lock_pair` read back immediately, so
  `controls.json` could record a number the camera never used — and with
  `FIX_EXPOSURE` set, every later comparison against it was measured against a
  fiction. The readback now happens after the value settles.

**10. `session.json` was built by pasting shell values into Python source.** A
`--name` holding a quote produced a `SyntaxError` — and it did so before the
cleanup trap was installed, leaving a half-built folder, a stale `capture.pid`
and a `current` symlink aimed at the wreck. Values are passed as arguments now,
names are restricted to path-safe characters, and the traps are armed before
anything that can fail.

**11. `set -e` made two commands fail silently.** `iv="$(session_get ...)"` is a
bare assignment, so a missing `session.json` key aborted the script before the
default on the same line could apply: `bin/status` and `bin/make-movie` both
exited 1 with no output whatsoever. `make-movie` even had an ffprobe fallback
for exactly this case, permanently unreachable. Every such capture is guarded.

**13. Controls written to an idle camera are discarded.** Measured with nine
identical shots: settings pinned while the device was closed, then a grab.
Brightness ranged 16.2 to 117.2 and exposure read back as 83, 312, 38 or 77 —
the camera re-meters on every stream open. So a still has to be taken *while*
streaming, with the values written after the stream is up. Writing them once at
a fixed moment is still a gamble, because how soon the camera starts listening
after a cold open varies; they are written three times across the early window.
With that, four cold shots a minute apart held to a spread of 11 (6% of mean).

**14. Software brightness correction does not rescue inconsistent frames.**
Normalising those nine shots to a common mean equalises brightness but not what
is underneath: tonal levels left ranged 49-256 against 115-124 for a consistent
session, and frame-to-frame noise spread was 10.7 against 0.9. Frames needing
4-5x gain kept only ~50 grey levels and blew 12-14% of pixels to clipping. The
fix belongs at capture time, not afterwards.

## Verification performed

Without the camera:

- `bin/cameras` rejects all 17 `pispbe`/`rpi-hevc-dec` nodes and `/dev/video1` as
  metadata, selects `/dev/video0`, reports the `by-id` path. Also verified for real
  with the camera unplugged: clean "no usable capture device found".
- Interval validation: `0.5` rejected, `abc` and `-5` rejected, `1.5` warns.
- Synthetic sessions at 10 s and 20 s via `test/make-session.sh`, with a
  deliberate gap; gap detected at the right place and scaled to each interval.
- `ffprobe` on outputs: `yuv420p`, correct fps, correct duration.
- `bin/status` / `bin/stop` with no sessions: clean messages.
- A session stripped of its `session.json`: `bin/status` still reports, and
  `bin/make-movie` still builds by reading the size back with ffprobe.
- Hostile `--name` values (quote, backslash, `../`, space, leading dash) are
  refused, and leave behind neither a folder nor a `current` symlink.
- Re-lock ordering, with the v4l2 calls stubbed: the auto flags are cleared
  before any value is written, and every recorded control is restored.
- The lock records the settled value, not the requested one (stubbed readback).
- A real mid-session reset: camera forced back to auto and ffmpeg killed, three
  times over, with `FIX_EXPOSURE` both unset and set to a value the camera
  clamps. Every control returned to its recorded value and held; `session.json`
  recorded `restarts: 1, relocks: 1`.
- `folder-movie` on a deliberately awkward folder (8 JPEG + 4 PNG, mixed sizes, names
  that text-sort wrongly): contact sheet confirms all 12 present in order `img1`…`img12`.
  Empty folder, single image, missing folder, and `--recursive` all handled cleanly.

With the camera:

- `bin/preview` — sharp, correctly exposed 1080p still.
- `bin/capture --duration 120` at 10 s → **12 frames**; at 20 s → **6 frames**. The
  interval is honoured end to end and recorded in `session.json`.
- All 12 frames of a run decoded cleanly at 1920x1080 (Pillow `verify()` + `load()`),
  despite ffmpeg logging corrupt USB buffers throughout — it discards them before they
  become files.
- Controls confirmed locked and repeatable across runs.
- Background capture, `status` while running, `stop`, and `supervisor.log` all work;
  the `current` symlink is cleaned up on exit.
- Real movie built with `--timestamp`; overlay verified correct (frame 3 at 10 s
  reads `+00:30`).

## Known behaviour, not bugs

- `Dequeued v4l2 buffer contains corrupted data` fills `capture.log` on a C920e.
  ffmpeg drops those buffers; saved stills are unaffected.
- `--duration` cuts mid-interval, so the final frame can be closer to its predecessor
  than the interval.
- Locked exposure is dimmer than what auto would pick for a moment-to-moment view.
  That is the tradeoff for consistency; `FIX_EXPOSURE` in `config.sh` overrides it.
