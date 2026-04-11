# Recording & retention — design

This doc is the detailed design behind the two-tier recording model for the cameras section. It covers:

- How continuous 24/7 footage is stored and retained.
- How motion-triggered clips are captured with pre-roll and stored separately.
- How file sizes are kept manageable (segment length).
- How day-level protection works: days with triggers are preserved; days with no triggers are eligible for deletion when disk pressure hits.
- How the operator is notified to review a day that had triggers.

It is the source of truth for the recording config in [`../app/vm/frigate/frigate.yml`](../app/vm/frigate/frigate.yml) and for the cleanup / watchdog / notification logic that will live in the `homesec-cameras-analyzer` LXC (see [`../app/lxc/analyzer/README.md`](../app/lxc/analyzer/README.md)).

## Goals

1. **Record everything, 24/7, across all 7 cameras** — don't lose the context around a trigger.
2. **Keep triggered moments forever** (or effectively forever) in their own archive separate from the rolling 24/7 buffer.
3. **Keep boring days only as long as disk allows** — delete them first when space gets tight.
4. **Keep interesting days indefinitely** — a day with even one trigger is preserved as a whole-day unit until disk pressure is severe.
5. **Manageable file sizes.** No multi-GB single files. Files split into 30-minute chunks by default (tunable).
6. **Notify the operator** when a day first accumulates a trigger so it can be reviewed as a full day, not just as isolated clips.

## Two-tier storage model

### Tier 1 — Continuous 24/7 recording

- **Location on the Frigate VM:** `/media/frigate/recordings/YYYY-MM-DD/HH/<camera>/<MM.SS>.mp4`
- **What goes here:** every camera, every hour, 24/7, segmented into ~30-minute chunks.
- **Who manages it:** Frigate writes it; the analyzer's cleanup job deletes old day directories when disk pressure hits.
- **Purpose:** context for triggered events (what happened just before and after), debugging unusual days, and the "review the whole day" UX when an interesting day is flagged.

Frigate's native path scheme already partitions by day as the top-level directory name, which is exactly the "each day has its own folder with the full date" behavior the operator asked for. **No post-processing is needed to produce daily folders.** The `YYYY-MM-DD/` directory is the unit that gets protected or deleted.

### Tier 2 — "Triggered Events"

- **Location on the Frigate VM:** `/media/frigate/clips/YYYY-MM-DD/<camera>/<event_id>.mp4`
- **What goes here:** motion- and AI-triggered event clips, each with pre-roll and post-roll, one file per event.
- **Who manages it:** Frigate writes it; retention is handled by Frigate's own `record.events.retain` setting (set long, e.g. 365 days). The cleanup job in the analyzer **never touches this directory**.
- **Purpose:** the interesting moments. The permanent record of things that happened. Always worth keeping.

This directory is what the operator mentally labels "Triggered Events". We optionally bind-mount it as `/media/frigate/triggered-events/` on the host side for clarity — the Frigate docker-compose volume line handles this rename.

## Pre-roll and post-roll

Every triggered event clip in Tier 2 includes:

- **60 seconds before the trigger** — `record.events.pre_capture: 60` in `frigate.yml`.
- **Post-roll:** Frigate continues recording until the tracked object is gone, then adds 30 more seconds as a tail — `record.events.post_capture: 30`.

So a clip from "person walks up to the door, rings bell, lingers 30s, walks away" will include: 60s of the yard before they appeared, the approach, the ring, the linger, the departure, and another 30s after they're out of frame. Complete context in a single file.

Pre-roll comes from the Tier 1 ring buffer — Frigate keeps recent segments readable even as the 24/7 archive rolls over. This is why the 24/7 recording must be enabled even for cameras where the operator only cares about events: pre-roll needs a source.

## File sizes and segment length

### Default: 30-minute segments

Frigate's native recording layer writes continuous segments at a configurable interval. The default is short (10 seconds) for reasons of precise event clip extraction. We override it to **30 minutes** to keep file sizes manageable for the operator's primary use case (browsing recordings directly, archiving, playing back specific chunks).

At 2K (2688×1520) / 5 FPS / H.264 with a reasonable bitrate, a 30-minute segment is approximately **500-900 MB per camera**. That's large enough to represent a real chunk of footage and small enough to copy, archive, or play individually without fuss.

### Configurable to 10 / 20 / 60 minutes

The segment length is a single ffmpeg argument. To change it, edit `frigate.yml`:

```yaml
ffmpeg:
  output_args:
    record: preset-record-generic-audio-copy -f segment -segment_time 1800 -segment_format mp4 -reset_timestamps 1 -strftime 1
```

Replace `1800` with the desired seconds:

| Segment | Seconds | Rough file size per camera (2K @ 5 FPS) |
|---|---|---|
| 10 min | 600 | ~170-300 MB |
| 20 min | 1200 | ~330-600 MB |
| **30 min (default)** | **1800** | **~500-900 MB** |
| 60 min | 3600 | ~1-1.8 GB |

### Tradeoff: event clip extraction

Frigate extracts event clips (for Tier 2) by pulling frames from the Tier 1 segments and stitching them together. With short (10s) segments, stitching is nearly free — concatenate relevant segments, done. With long (30 min) segments, Frigate has to either:

1. Extract a subrange from within a segment, which requires re-encoding if the event doesn't start on a keyframe.
2. Snap the event clip to segment boundaries, giving it slightly ragged edges.

At 30-minute segments on an NVIDIA GPU, the re-encoding cost per event is ~10-20 seconds of inference time. The GPU has cycles to spare between events, so this is acceptable. If event cadence ever gets extreme (say, 100+ events per day), this may need to be revisited.

## Day-level protection logic (custom — lives in the analyzer LXC)

Frigate's native retention is per-day for Tier 1 (configurable via `record.retain.days`). What it does NOT do is the "preserve the whole day if any trigger fired" semantic the operator asked for. We implement that logic ourselves in the analyzer.

### Daily sweep

A script runs as a systemd timer inside the `homesec-cameras-analyzer` LXC at **03:00 local time** daily. For each day directory older than 24 hours under `/media/frigate/recordings/`:

1. Query the analyzer's SQLite DB for any events with `captured_at::date = day_date`.
2. If events > 0:
   - `touch /media/frigate/recordings/<day>/.protected`
3. Else:
   - `touch /media/frigate/recordings/<day>/.cleanup-eligible`
4. Emit a summary log line to journald: `"day 2026-04-12 protected" / "day 2026-04-11 eligible"`.

Sentinel files are used instead of a database column because they travel with the directory — if the analyzer's DB is ever restored from a backup that's out of sync with disk, the sentinel files in the filesystem are the authoritative marker.

### Disk watchdog

A separate systemd timer runs **hourly**. For each run:

1. Check `df` on the filesystem holding `/media/frigate/recordings/`.
2. If used% > **80**:
   - Find the oldest day directory containing `.cleanup-eligible` (and NOT `.protected`).
   - `rm -rf` that directory.
   - Repeat until used% < **75** or there are no more eligible days.
3. If used% > **95** AND only `.protected` days remain:
   - Delete the oldest `.protected` day.
   - POST an **elevated** notification to ntfy: _"Low disk — had to delete a protected day: YYYY-MM-DD. Remaining free: N%."_
   - Stop after one deletion per watchdog run; re-check on the next run.
4. Log every action to journald with structured fields `action`, `day_date`, `reason`, `free_before`, `free_after`.

Hysteresis (80% / 75% upper/lower) prevents thrashing when disk is hovering near the limit.

**The watchdog NEVER touches `/media/frigate/clips/`.** Triggered events are always kept. If the clips directory ever grows enough to threaten the disk on its own, a separate "clips retention" policy kicks in — shrink `record.events.retain.default` or expand the disk.

### First-trigger-of-day notification

Completely separate from the cleanup logic. When the analyzer's MQTT subscriber receives a new Frigate event, before dispatching the per-event alert it checks:

1. Compute `event_date = event.started_at.date()` (in local time).
2. Check the analyzer's DB: has any event with that `event_date` been seen before?
3. If **no** — this is the first trigger of this day — POST a one-shot notification to ntfy:
   > Day 2026-04-12 has triggers. Tap to review: http://homesec-cameras-frontend.lan/days/2026-04-12
4. Then continue with the normal per-event alert logic.

Dedup by day keeps the operator from being spammed. At most one "review this day" notification per day per installation.

## Storage budget

Rough numbers for sizing the Frigate VM's recording disk. 7 cameras × 2K @ 5 FPS × H.264 at ~1 Mbps sustained works out to:

| Disk | Days of 24/7 before cleanup activates (no triggers case) |
|---|---|
| 100 GB | ~1.3 days — too tight for the 80% threshold to give any breathing room |
| 500 GB | ~6 days — OK if triggers are rare |
| **1 TB** | **~13 days** — recommended starting point |
| 2 TB | ~26 days — comfortable for a busy household |
| 4 TB | ~52 days — generous; only useful if you want a long 24/7 window |

Starting recommendation: size the Frigate VM disk to **1 TB** (`qm resize 210 scsi0 +950G`). This gives ~13 days of 24/7 headroom plus plenty of room for triggered clips to accumulate. Grow later if needed.

**Triggered event clips are additional on top of this.** At ~30 MB per event (1 minute pre-roll + 1-3 minute event at moderate bitrate) and ~20 events per day, that's 600 MB/day of clips — 365 days = ~220 GB for a year of triggered events. Budget that on top of the 24/7 budget.

## Relationship to the UNVR archive

The UNVR Instant already holds its own independent UniFi Protect 24/7 recording on its WD Purple HDD, managed by UniFi's native retention policy (oldest-first overwrite when full). That archive is NOT replaced by anything in this doc.

Frigate's 24/7 recording is **additional** — a second, smarter archive on Proxmox storage with:

- Day-level protection semantics the UNVR doesn't do.
- Triggered event extraction with metadata (face IDs, plate text, vehicle attributes) the UNVR can't produce.
- A cleaner operator UX ("show me interesting days") that Protect's UI lacks.

Storage cost roughly doubles because two archives exist in parallel. That's the price of the smart-retention + metadata layer. For a home security system where storage is cheap and detection quality matters, it's the right tradeoff.

## Sentinel file contract (the code will enforce this)

The cleanup sweep and the disk watchdog must agree on the sentinel file names and semantics. Both live in the analyzer LXC. Locking it in here:

| File | Meaning | Set by | Read by | Mutated? |
|---|---|---|---|---|
| `.protected` | This day has at least one triggered event. Do not delete unless there is NO `.cleanup-eligible` day remaining AND disk is > 95% full. | daily sweep | disk watchdog | Immutable after creation. Deleted only when the day dir itself is deleted. |
| `.cleanup-eligible` | This day had zero triggers. Safe to delete when disk pressure hits. | daily sweep | disk watchdog | Immutable after creation. |

Precedence: if both files somehow exist in the same directory (data race between DB queries and filesystem state), `.protected` wins. The watchdog MUST refuse to delete a directory that has `.protected`, even if `.cleanup-eligible` is also present.

## Implementation status

- ✅ Frigate config updated with `pre_capture`, `post_capture`, `events.retain.default`, 30-min segments, Tier 2 clips path.
- ✅ This design doc (recording-retention-design.md).
- ✅ Analyzer README updated to list daily sweep, disk watchdog, and first-trigger notification as analyzer responsibilities.
- ❌ Daily sweep script — not yet implemented (deferred to analyzer implementation PR).
- ❌ Disk watchdog script — not yet implemented.
- ❌ First-trigger notification — not yet implemented.
- ❌ Cleanup audit log and end-to-end test on real storage.

All three deferred items are small scripts (Python or bash, low complexity) that will land together with the rest of the analyzer code. The Frigate-side config is ready today.
