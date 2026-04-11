# License plate recognition — design

This doc covers ALPR: how license plates are detected, read, correlated across clips, and linked to vehicle attributes and people. It is the detailed design behind the plate-handling code in `homesec-cameras-analyzer`.

## Policy decisions

- **All 7 cameras** are ALPR-eligible. The front center and doorbell positions are the highest-value angles for incoming vehicles.
- **Cross-clip history is retained forever** (same policy as face recognition). Plate text is small; storage is not a concern.
- **No third-party plate databases.** No cloud ALPR services. No Rekor / Flock / OpenALPR Cloud. Everything is local.
- **No integration with law enforcement, toll systems, or any public-records APIs.** This is a home security tool, not a license plate reader network.

## Why this is a custom service (not just Frigate)

Frigate 0.16+ has built-in ALPR. It handles per-event plate recognition well:

1. Detects vehicles.
2. Crops vehicle regions.
3. Runs a plate-region detector inside the vehicle crop.
4. Runs OCR on the plate region.
5. Emits `plate: {text: "ABC1234", confidence: 0.87}` on the event.

What Frigate does **not** do:

- Normalize plate reads (strip whitespace, resolve confusable characters like `O`/`0`, `I`/`1`, `S`/`5`).
- Track a plate across many sightings over weeks/months.
- Maintain a "this plate has been here 14 times" counter.
- Link a plate to a vehicle (make/model/color) or to a person (whoever is typically driving it).
- Surface a dashboard of "top 20 most-seen plates".
- Fire alerts on first-seen-in-N-days or unusual-hour sightings.

That's the analyzer's job.

## Hardware placement

Plate detection, plate-region cropping, and OCR all run inside the **Frigate VM** on the **NVIDIA GPU** (the same GPU that handles face embedding). The Coral Edge TPU is reserved for Frigate's 24/7 object-detection hot loop and does **not** run ALPR. The analyzer (`homesec-cameras-analyzer`) receives pre-computed plate text + confidence from Frigate via MQTT and does the cross-clip history / normalization / fuzzy-merge work on CPU — no GPU required in the analyzer.

## Pipeline

```
Frigate event with label=car/truck/motorcycle and a plate sub-object
        │
        │ MQTT: frigate/events
        ▼
Analyzer receives event
        │
        │ Read Frigate's already-computed plate:
        │   plate_text, plate_confidence, plate_crop_url
        ▼
Normalize plate text
        │ - Uppercase
        │ - Strip whitespace and hyphens
        │ - Apply confusable-character rules per state format if known
        │ - (FL plates: 6 chars, alphanumeric, no I / O / Q)
        ▼
Quality filter
        │ Reject reads where confidence < PLATE_MIN_CONF (default 0.70)
        │ Reject reads where text length is not in [4,8]
        ▼
Lookup or insert plate
        │ SELECT id FROM plates WHERE text = ?
        │ If found: increment sightings, update last_seen_at
        │ If not found: INSERT new plate row
        ▼
Maybe link to vehicle
        │ If Frigate or the analyzer's vehicle-attribute service
        │ produced a vehicle signature for this event, link it.
        ▼
Emit alert decision
        │ - First sighting ever        → info
        │ - Seen before, first today   → info
        │ - Seen 5+ times in 24h       → info "frequent vehicle"
        │ - Unusual hour (03:00-05:00) → elevated
        │ - Operator-flagged plate     → elevated
```

## Plate normalization rules

Raw OCR reads are noisy. We apply these rules before the DB lookup:

1. **Uppercase.** `abc1234` → `ABC1234`.
2. **Strip whitespace, hyphens, dots, slashes.**
3. **Length filter.** Anything < 4 or > 8 chars is thrown out.
4. **Confusable-character normalization** (optional, configurable per state). For FL plates specifically, the letters `I`, `O`, `Q` are never issued — reads containing them are likely OCR confusion. We re-run normalization with `I→1, O→0, Q→0`. This is lossy; we store BOTH the raw OCR read and the normalized text.
5. **Fuzzy merge.** When inserting a new plate, compute Levenshtein distance to the top-5 most recently seen plates. If distance ≤ 1 and both reads are within a short window, consider them the same plate with OCR noise. Flag for operator review in the frontend.

**We do NOT guess.** Every normalization is reversible (we keep the raw read in a separate column) and auditable in the frontend.

## Data model

### `plates`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | `plate_<ulid>` |
| `text_raw` | TEXT | The original OCR read, pre-normalization. |
| `text_normalized` | TEXT NOT NULL | What we match on. Indexed. |
| `state_guess` | TEXT NULL | Optional, populated from plate colors/format by vehicle attributes service. |
| `first_seen_at` | TIMESTAMP | |
| `last_seen_at` | TIMESTAMP | Indexed for "recent activity". |
| `sighting_count` | INTEGER | Denormalized counter. |
| `is_flagged` | BOOLEAN | Operator-flagged for elevated alerts. |
| `flag_reason` | TEXT NULL | |
| `notes` | TEXT NULL | Operator free-text. |
| `vehicle_id` | TEXT FK → vehicles.id NULL | Set when the vehicle attributes service links them. |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |

Unique index on `text_normalized`.

### `plate_sightings`

One row per reading. This is what drives the history view.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | |
| `plate_id` | TEXT FK → plates.id | |
| `event_id` | TEXT | Frigate event ID. |
| `confidence` | REAL | |
| `text_raw` | TEXT | The raw OCR read at this sighting — may vary across readings of the same plate. |
| `camera` | TEXT | |
| `captured_at` | TIMESTAMP | From the Frigate event timestamp. |
| `crop_path` | TEXT NULL | Path to the plate crop under `/var/lib/homesec-cameras-analyzer/plates/`. |

Index on `(plate_id, captured_at)` for per-plate history queries.

### `vehicles`

See [`vehicle-attributes-design.md`](./vehicle-attributes-design.md) for the full vehicles schema.

## Alert behavior

Same pattern as face recognition — the analyzer owns the decision, not Frigate. Default rules:

| Condition | Alert? | Severity |
|---|---|---|
| Plate's first sighting ever | ✅ | info — "new plate: ABC1234" |
| Plate seen before, first today | ✅ | info — "returning plate: Alice's car" |
| Plate seen 5+ times today | ❌ (dedup) | — |
| Operator-flagged plate | ✅ | elevated |
| Plate seen between 02:00-05:00 local | ✅ | elevated |
| OCR confidence < 0.80 and no fuzzy-merge hit | ❌ | — (don't noise up the operator with uncertain reads) |

Dedup windows are per-plate and per-severity. Config lives in `/etc/homesec-cameras-analyzer/config.yaml`.

## Correlation with faces and vehicles

Three kinds of correlation emerge from the data model:

1. **Plate ↔ vehicle.** The vehicle-attributes service produces a signature (make + model + color + body) per vehicle detection. When a plate and a vehicle signature show up in the same event, we link them (`plates.vehicle_id`). Over time this builds a `vehicle → plates` relationship (some vehicles carry the same plate, some don't).
2. **Plate ↔ person.** If a face is detected in the same event as a plate, and the face is consistently from the same cluster across multiple sightings of the same plate, we note the correlation. Not a hard link — rather, the frontend's plate detail view shows "seen with: Alice (12 times), Unknown #7 (3 times)".
3. **Person ↔ vehicle.** Derived from the above two. Shown on the person detail view.

These correlations are **suggested** in the UI, not automatic. The operator can confirm or dismiss them.

## What gets deferred

- **Partial plate matching.** If we only catch 4 of 6 characters, fuzzy merge above catches some of this, but a full "search by prefix" capability is a v0.2 feature.
- **Multi-state recognition.** We assume FL plates by default. Out-of-state plates work but don't get state-specific normalization.
- **Plate-to-owner lookup.** There is no legal way to do this from a private home system. We deliberately do not implement it.
- **Historical lookup via public records databases.** Same.
- **Integration with toll-road or traffic databases.** Same.

## Storage estimate

- A plate text row: ~500 bytes.
- A sighting row: ~500 bytes.
- A plate crop: ~20 KB compressed.

Budget for 5 years of operation at 50 sightings/day: ~90k sightings, ~45 MB DB + ~1.8 GB of plate crops. Fits on any SSD without effort.
