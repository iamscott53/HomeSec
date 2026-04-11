# Storage management — design

This doc covers how the cameras detection stack manages its own storage over time: threshold-based warnings, automatic quality downgrades, the absolute protection rule for days that had triggers, the user-friendly download-and-delete UX, and the quality preset system.

It is the companion to [`recording-retention-design.md`](./recording-retention-design.md). That doc covers **how** recordings are written and partitioned; this doc covers **what happens when disk fills up** and **what the operator can do about it**.

## The absolute protection rule

**A day directory marked `.protected` is never deleted by any automated process.** Ever.

This supersedes the earlier "at >95% disk usage, the watchdog may delete the oldest protected day" escape hatch, which has been removed. The tradeoff — potentially running out of disk — is handled by the escalation chain below, not by discarding historically significant footage.

The only way a `.protected` day leaves the disk is:

1. **The operator downloads it and explicitly confirms deletion** through the frontend's Storage page.
2. **The operator deletes it by hand** via ssh / SFTP / the file manager on the Frigate VM.

In both cases it's a deliberate human action, never an automated sweep.

## Threshold-based escalation

The `homesec-cameras-analyzer` disk watchdog checks `/media/frigate/recordings/` every hour and takes action based on the current used-percent.

| Threshold | Action |
|---|---|
| **< 75%** | Nothing. Normal operation. |
| **≥ 75%** — warning | Emit a `warning` ntfy notification: _"Cameras disk at N%. Review oldest days: http://homesec-cameras-frontend.lan/storage"._ Max one warning per 24 hours. Also: delete the oldest `.cleanup-eligible` day directory (days with no triggers). Repeat until either < 70% or no more eligible days remain. |
| **≥ 90%** — major | Emit an `urgent` ntfy notification: _"CAMERAS DISK CRITICAL at N%. Download and delete oldest days NOW: http://homesec-cameras-frontend.lan/storage"._ Max one per 24 hours unless the percentage keeps climbing by 2+ points. Continue deleting any remaining `.cleanup-eligible` days. |
| **≥ 95%** — quality downgrade | Step the recording quality preset down by one level (see below), restart the Frigate container with the new preset, and emit a notification: _"Cameras disk at N%. Recording quality downgraded from <previous> to <new>."_ Max one quality downgrade per 12 hours to prevent thrashing. |
| **No more `.cleanup-eligible` days AND used > 90%** | Emit a **"recording will stop"** urgent notification (see below). |
| **Disk write failures detected** in Frigate logs | Recording has stopped. Emit an urgent red notification once per hour until resolved. |

**The watchdog NEVER deletes a `.protected` day, regardless of disk pressure.** It also never deletes anything from `/media/frigate/clips/` (the Triggered Events archive).

### Hysteresis

All the cleanup thresholds have built-in hysteresis to prevent oscillation:

- Cleanup triggered at ≥ 75% keeps deleting until used < 70%.
- Warning notifications fire at most once per 24 hours per threshold crossing.
- Quality downgrades fire at most once per 12 hours.
- There is **no automatic quality upgrade** when the disk drops below 95% later. Upgrading the preset after an auto-downgrade is a manual operator action via the Settings page. Rationale: auto-upgrading would defeat the point — if the disk is back down because of an upgrade, automatically bumping quality back up puts us right back into pressure. The operator can see the current situation and decide.

## "Recording will stop" escalation

When the watchdog finds that disk usage is ≥ 90% and there are no `.cleanup-eligible` days remaining to delete, it transitions into **"recording will stop" mode**:

1. Emit an urgent notification tagged **red** and **urgent** in ntfy with the title `CAMERAS: RECORDING WILL STOP`. Body: _"All days without triggers have been deleted. All remaining days are protected. Disk is at N%. You must either (1) add more storage to the Frigate VM, (2) download and delete the oldest protected days through the Storage page, or (3) accept a quality downgrade — which has already happened if you're at 95%."_
2. Fire this notification **every hour** until one of:
   - Disk drops below 85%.
   - The operator explicitly acknowledges via an API call (`POST /api/storage/ack-full-warning`).
3. If disk reaches 98% or Frigate starts logging write errors, the notification body escalates to: _"RECORDING HAS STOPPED OR WILL STOP WITHIN MINUTES. No new footage is being saved. Live view still works. Act now."_
4. The watchdog never deletes anything — not `.protected` days, not anything in `/media/frigate/clips/`. The operator is the only deleter of protected data.

The cost of this policy is that the system is willing to **stop recording** rather than lose historically significant footage. That matches the operator's stated preference: "never delete a protected day."

## User-friendly download + optional delete (Storage page)

The frontend's **Storage** page is the operator's one-stop interface for managing retention. Layout:

### Header: status

- Current disk used %, with color bar (green < 75, yellow 75-90, orange 90-95, red > 95).
- Days free of `.cleanup-eligible` (fallback capacity remaining).
- Current recording quality preset and whether the last change was manual or automatic.
- Direct links to the Settings page and to the notification history.

### Main body: day list

A paginated, sortable list of day directories with one row per day. Default sort: oldest first.

| Checkbox | Date | Size | Cameras | Status | Trigger count | Actions |
|---|---|---|---|---|---|---|
| ☐ | 2026-04-01 | 72.3 GB | 7/7 | 🟢 `.cleanup-eligible` | 0 | [Preview] |
| ☐ | 2026-04-02 | 81.1 GB | 7/7 | 🟡 `.protected` | 14 | [Preview] |
| ☐ | 2026-04-03 | 68.7 GB | 7/7 | 🟡 `.protected` | 3 | [Preview] |

### Actions

Two buttons at the bottom of the list that act on the checkbox selection:

**[ Download selected as ZIP ]** — initiates an HTTPS streaming download of a single zip file containing the selected day directories. The analyzer streams the zip directly from disk without buffering it all in memory.

**[ Delete selected ]** — Greyed out unless either:
- The rows are all `.cleanup-eligible` (safe to delete).
- OR a post-download confirmation is active: the frontend remembers which days the operator recently downloaded and permits deletion of those within a 10-minute window.

### Post-download prompt

After a successful download finishes (detected client-side by the browser's download completion event, with a fallback timer), the frontend shows a modal:

> **Download complete.**
>
> You downloaded: 2026-04-01, 2026-04-02, 2026-04-03 (222.1 GB total).
>
> Would you like to remove these days from the server now?
>
> - **Yes, delete them** — removes all three day directories from `/media/frigate/recordings/`.
> - **No, keep them** — leaves everything in place.
> - **Let me verify first** — opens the default download folder.

The "Yes, delete them" button is the only path in the UI through which a `.protected` day can be deleted. Every deletion writes an audit row to the analyzer's `storage_audit` table with operator identity, timestamp, day_date, action, and (for downloads) a hash of the zip payload.

## Download implementation (streaming zip over HTTPS)

The analyzer exposes:

```
POST /api/storage/download
  body: { days: ["2026-04-01", "2026-04-02", "2026-04-03"], cameras: "all" }
  response: application/zip (streamed)
            Content-Disposition: attachment; filename="homesec-cameras-2026-04-01_to_2026-04-03.zip"
```

Implementation notes (for the future analyzer code — not built in this PR):

- Use Python's `zipfile.ZipFile` in streaming mode (`zipfile.ZIP_STORED`, no compression — video files are already compressed, re-compressing wastes CPU for near-zero size savings).
- Stream from disk directly into the response body; never buffer the whole zip in memory.
- FastAPI's `StreamingResponse` wraps a generator that yields chunks.
- Add a `/api/storage/download-prepare` endpoint that returns `{ total_bytes, estimated_seconds }` so the frontend can show a progress estimate before starting.
- Rate-limit concurrent downloads to 1 (these are huge; parallel downloads would murder disk I/O).
- Require authentication via a bearer token the analyzer issues to the frontend session. No anonymous downloads, even on LAN.

### Day deletion endpoint

```
DELETE /api/storage/days
  body: { days: ["2026-04-01", "2026-04-02"],
          confirmed_download_hash: "<sha256-of-previous-download>",
          force: false }
  response: { deleted: [...], failed: [...], freed_bytes: N }
```

- `confirmed_download_hash` must match a recent download recorded in the `storage_audit` table within the last 10 minutes. Without it, deletion of `.protected` days is refused with 403.
- `force: true` bypasses the confirmation requirement. Requires an explicit operator identifier and writes an extra "force" flag to the audit row.
- The analyzer removes the day directories only after a fsync on the parent directory to ensure the unlink is durable.
- After successful deletion, the watchdog re-runs immediately to update its state.

## Quality presets

The analyzer controls Frigate's recording quality by swapping out the `ffmpeg.output_args.record` line in `/var/lib/frigate/config/config.yml` on the Frigate VM, then restarting the Frigate container.

Four presets are defined. Each differs only in how it re-encodes (or doesn't) the continuous 24/7 recording stream. **Triggered event clips always use the current preset** — operators cannot have high-quality events and low-quality 24/7.

The source streams from the UNVR are unchanged regardless of preset. Re-encoding happens between source stream and disk, using the NVIDIA GPU's `h264_nvenc` encoder. The GPU has cycles to spare because face rec and ALPR are event-triggered, not continuous.

### Preset table

| Preset | `ffmpeg.output_args.record` | File size per camera per 30-min segment (approx) | Visual quality |
|---|---|---|---|
| **High (default)** | `preset-record-generic-audio-copy -f segment -segment_time 1800 -segment_format mp4 -reset_timestamps 1 -strftime 1 -c copy` | ~500-900 MB | Lossless (stream-copy) |
| **Medium** | `-f segment -segment_time 1800 -segment_format mp4 -reset_timestamps 1 -strftime 1 -c:v h264_nvenc -preset p4 -b:v 600k -maxrate 700k -bufsize 1200k -c:a aac -b:a 64k` | ~300-540 MB | Mild softening, clear |
| **Low** | `-f segment -segment_time 1800 -segment_format mp4 -reset_timestamps 1 -strftime 1 -c:v h264_nvenc -preset p3 -b:v 400k -maxrate 500k -bufsize 800k -r 3 -c:a aac -b:a 48k` | ~200-360 MB | Visible compression, 3 FPS |
| **Lowest** | `-f segment -segment_time 1800 -segment_format mp4 -reset_timestamps 1 -strftime 1 -c:v h264_nvenc -preset p2 -b:v 200k -maxrate 300k -bufsize 400k -r 2 -vf scale=1280:720 -c:a aac -b:a 32k` | ~90-180 MB | Crude, identifiable but not detailed, 2 FPS, scaled to 720p |

**Storage budget per preset** (7 cameras, 24 hours, rough numbers):

| Preset | ~GB/day total | Days on a 1 TB disk |
|---|---|---|
| High | ~75 GB | ~13 days |
| Medium | ~45 GB | ~22 days |
| Low | ~30 GB | ~33 days |
| Lowest | ~15 GB | ~66 days |

### Auto-downgrade mechanism

When the watchdog trips the 95% threshold and auto-downgrade is enabled, it:

1. Reads the current preset from the analyzer's config.
2. Finds the next lower preset. If already at Lowest, skips the downgrade and emits the "recording will stop" notification instead.
3. Calls the Frigate VM's REST-over-SSH (or a small helper daemon on the VM) with the new preset name.
4. The Frigate VM's helper swaps `/var/lib/frigate/config/config.yml` → `/var/lib/frigate/config/config.<new-preset>.yml`, then `docker compose restart frigate`.
5. Writes a `quality_preset_changes` audit row.
6. Emits the notification: _"Cameras disk at N%. Recording quality downgraded from <previous> to <new>. Downgrades happen at most once per 12 hours; manual upgrade is available in Settings."_

The Frigate VM must carry all four preset files under `/var/lib/frigate/config/`, one per preset. The analyzer creates them during initial provisioning from the base `frigate.yml` template (see `cameras/app/vm/frigate/README.md` — TODO note to be added when the analyzer code lands).

### Manual quality control (Settings → Cameras → Recording quality)

The frontend's Settings page exposes:

- **Recording quality preset:** radio group of High / Medium / Low / Lowest. Changing this immediately POSTs to `PUT /api/storage/quality-preset { preset: "low" }`, which kicks off the same Frigate-restart process as auto-downgrade.
- **Auto-downgrade on disk pressure:** toggle (default on). When off, the 95% threshold still fires a notification but does not change the preset automatically.
- **Show change history:** link to the `quality_preset_changes` audit view.

## Data model additions

Two new tables in the analyzer's SQLite DB:

### `storage_audit`

Records every deletion, download, and quality preset change.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | |
| `event_type` | TEXT | `download`, `delete`, `quality_change`, `watchdog_delete_eligible`, `watchdog_noop_protected` |
| `occurred_at` | TIMESTAMP | |
| `actor` | TEXT | Operator identifier from the frontend session, or `watchdog` for automated actions. |
| `subject` | TEXT | Day date (`2026-04-01`), preset name (`high`/`medium`/`low`/`lowest`), or `storage_full` |
| `details_json` | TEXT | Free-form details: bytes, downloaded hash, old/new preset, etc. |
| `result` | TEXT | `ok`, `refused`, `failed_with_error` |

Append-only. Never deleted.

### `quality_preset_changes`

Denormalized view of `storage_audit` for the common "what's the recording quality history" query.

| Column | Type |
|---|---|
| `id` | INTEGER PRIMARY KEY |
| `changed_at` | TIMESTAMP |
| `actor` | TEXT |
| `from_preset` | TEXT |
| `to_preset` | TEXT |
| `reason` | TEXT — `manual`, `auto_downgrade_95pct`, `fresh_install` |
| `disk_used_pct_at_change` | REAL |

Written alongside the storage_audit row for any quality preset change.

## SFTP fallback

The analyzer LXC can optionally expose an SFTP endpoint chroot'd to `/media/frigate/recordings/` for operators who prefer a standard SFTP client over the browser UI. Details:

- Runs on a separate port (2222 by default) to avoid conflicting with host sshd.
- Read-only by default.
- Authenticated with SSH keys only (no passwords).
- Uses OpenSSH's built-in `ChrootDirectory` + `ForceCommand internal-sftp` pattern — no custom SFTP server implementation.
- Not exposed to WAN, ever. LAN-only.
- Enabled by operator in Settings; ships disabled.
- Does not interact with the `.protected` sentinel files — SFTP is read-only. To delete via SFTP, the operator must still use the HTTPS download + delete flow in the frontend (where the audit log catches it) or SSH into the VM directly.

This is a "last resort" path for operators who don't trust the browser UI for huge downloads. Default install ships with it off.

## Notification severity mapping

All notifications go through the existing ntfy integration in the analyzer. Severities map to ntfy priorities:

| HomeSec severity | ntfy priority | Color/tag | Used for |
|---|---|---|---|
| info | 3 | default | First-trigger-of-day, cleanup of eligible days |
| warning | 4 | yellow | ≥ 75% threshold, auto-downgrade notice |
| urgent | 5 + `urgent` tag | red | ≥ 90% threshold, recording-will-stop, recording-has-stopped, force-deletion-of-protected |

All urgent-priority notifications also get `tags=rotating_light,red_circle` in ntfy so they render in red and vibrate the phone continuously until acknowledged.

## What the operator can do from the phone (ntfy click-through)

Every storage notification includes a `click:` action that opens the relevant page in the frontend:

- Warning at 75% → opens the Storage page sorted oldest-first.
- Major at 90% → opens the Storage page with the oldest eligible days pre-checked.
- Quality downgrade → opens the Settings → Recording quality page.
- Recording will stop → opens the Storage page with all `.protected` days visible and a banner at the top reiterating the recording-will-stop state.
- Recording has stopped → opens a dedicated emergency page with a big button "I have added storage / downloaded days — re-check disk now".

## Not implemented in this PR

Same as the rest of the analyzer work: everything in this doc is **design-only**. The analyzer Python code, the frontend Storage and Settings pages, the quality preset swapper on the Frigate VM, the SFTP service — all of it lands in follow-up PRs after the analyzer stack is standing on real hardware.

What **does** land in this PR:

- This design doc.
- A cross-reference from `recording-retention-design.md` that removes the old "delete protected day at >95%" fallback.
- Documentation updates in the analyzer README and the frontend README so the scope of those containers reflects the new responsibilities.
- Inline documentation in `cameras/app/vm/frigate/frigate.yml` pointing at the preset system.
- Updated thresholds (75 / 90 / 95) in the recording-retention-design doc.

## Summary: what changed from the previous design

| Previous | New |
|---|---|
| ≥80% triggers cleanup of eligible days | ≥75% triggers cleanup + warning |
| ≥95% allowed deletion of oldest `.protected` day as a fallback | **Never. Protected days are inviolable.** |
| No quality downgrade | Automatic preset downgrade at 95%, with manual override in Settings |
| No user-facing storage UX | Storage page with download-as-ZIP + optional delete + quality preset picker |
| No "recording will stop" escalation | Red urgent notification loop when eligible days are exhausted and pressure persists |
| Watchdog decides deletion of anything | Watchdog only deletes `.cleanup-eligible`; every protected-day deletion requires a human download-confirmed action |
