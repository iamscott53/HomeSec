# Vehicle attributes — design

This doc covers vehicle attribute extraction: turning a "car" or "truck" detection from Frigate into a structured record of `{make, model, year_range, color, body_type}`. It is deliberately less prescriptive than the face / ALPR docs because the open-source landscape for vehicle make-and-model classification is less mature, and several approaches have meaningful trade-offs.

**Status for v0: scaffolded, not implemented.** The analyzer's vehicle table is defined and the integration point is documented, but no inference code ships in v0. Enabling vehicle attributes is a follow-up PR.

## Why the analyzer, not Frigate

Frigate does not natively classify vehicle make/model/color at the granularity we want. It emits:

- `label: car | truck | motorcycle | bicycle | bus`
- Bounding box, crop, confidence

That's enough to know "a vehicle was here". Turning that into "a **blue 2018 Toyota Tacoma**" requires additional inference — and different inference at that — against models trained for fine-grained vehicle classification. Those models don't ship with Frigate.

So the analyzer is the right home: it already consumes Frigate's vehicle events, it already pulls crops from the REST API, and its output feeds directly into the same DB that holds plate and event history.

## Hardware placement

Vehicle attribute inference is **event-triggered** (only runs when Frigate reports a vehicle detection) and is a good candidate for the **NVIDIA GPU** already passed through to the Frigate VM. Two paths:

1. **Run inference inside the Frigate VM.** Add a small sidecar container in the Frigate VM's Docker compose that exposes a tiny HTTP endpoint: `POST /classify-vehicle { image_bytes } → { make, model, year_range, color, body_type }`. The analyzer calls it whenever a vehicle event arrives. Model loaded into GPU memory once at VM start.
2. **Run inference in the analyzer LXC.** The analyzer is CPU-only in v0 (see [`face-recognition-design.md`](./face-recognition-design.md)). CPU inference for fine-grained vehicle classification is slow but functional (~1-2 sec per vehicle on a modern CPU). This is fine given the event-triggered cadence.

**Recommendation: start with path 2 (CPU in the analyzer)** for the simplest possible first implementation. If latency turns out to matter or batch throughput is needed, move to path 1 later — the data model stays the same.

## Model options (none locked in)

This is the hardest part of the detection stack to get right from off-the-shelf components. Candidates, in rough order of how I'd actually try them:

### Option A — YOLO-based vehicle classifier (recommended first try)

Fine-tune a YOLOv8 classification head on a labeled vehicle dataset. Ultralytics ships tools for this; training runs in a few hours on a 3060.

- **Pros:** Same family as Frigate's object detection (familiar tooling), fast inference, MIT-licensed, integrates cleanly.
- **Cons:** Requires a training dataset. The public options (Stanford Cars, CompCars, BoxCars116k) are older (2013-2016 vintage), so "make+model" classification is biased toward older vehicles and US-market skew.

### Option B — CLIP + zero-shot prompts

Use OpenAI CLIP (or OpenCLIP) with prompts like `"a photo of a blue 2020 Toyota Tacoma"` and pick the highest-scoring label from a known gallery.

- **Pros:** No training required. Flexible — you can add new labels at runtime. MIT-licensed open weights.
- **Cons:** Accuracy degrades for fine-grained distinctions (Camry vs Corolla). Requires a hand-curated gallery of make/model/year combinations to score against.

### Option C — Vision-language model (LLaVA-NeXT, InternVL, Moondream)

Run a local VLM and ask it "describe the make, model, year, and color of the vehicle in this image".

- **Pros:** Zero training. Flexible. Descriptive output (e.g., "silver early-2010s Honda Civic sedan, aftermarket rims").
- **Cons:** Slower than dedicated classifiers (hundreds of ms to seconds per image on a GPU). Hallucinates model/year. Output is free-text and needs parsing.

### Option D — Color classification only (cheapest)

Skip make/model entirely in v0. Use a small CNN or even k-means on the crop pixels to extract dominant color. Attach color to the plate only.

- **Pros:** Trivially simple. Works on CPU. No dataset needed.
- **Cons:** No make/model. Limited operator value ("red car" vs "2018 Mazda CX-5").

**Recommendation for v0.1 (when we start implementing):** Option D (color only) as a first pass to prove the integration path, then Option A (YOLOv8 fine-tune) to add make/model. Treat B and C as fallback experiments if A's training dataset turns out to be too stale.

## Data model

The analyzer's SQLite DB gets one new table (already referenced from [`alpr-design.md`](./alpr-design.md)):

### `vehicles`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | `vehicle_<ulid>` |
| `make` | TEXT NULL | `Toyota`, `Ford`, ... — NULL until an inference run produces a value. |
| `model` | TEXT NULL | `Tacoma`, `F-150`, ... |
| `year_range` | TEXT NULL | Range string: `2018-2020`, `early-2010s`, etc. Not an integer because models often span multiple years and we won't nail a specific year. |
| `color` | TEXT NULL | `blue`, `silver`, `white`, ... Controlled vocabulary (see below). |
| `body_type` | TEXT NULL | `sedan`, `pickup`, `suv`, `hatchback`, `minivan`, `motorcycle`, `bicycle`, `unknown`. |
| `confidence` | REAL NULL | 0-1, reported by the classifier. |
| `first_seen_at` | TIMESTAMP | |
| `last_seen_at` | TIMESTAMP | |
| `sighting_count` | INTEGER | |
| `notes` | TEXT NULL | Operator free-text. |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |

And a link table to keep vehicle history separate from single-event readings:

### `vehicle_sightings`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | |
| `vehicle_id` | TEXT FK → vehicles.id | |
| `event_id` | TEXT | Frigate event. |
| `camera` | TEXT | |
| `crop_path` | TEXT NULL | |
| `plate_id` | TEXT FK → plates.id NULL | Set if a plate was read in the same event. |
| `captured_at` | TIMESTAMP | |

Index on `(vehicle_id, captured_at)`.

## Color vocabulary

To keep the DB searchable, `vehicles.color` uses a controlled vocabulary rather than RGB or hex:

```
white, black, silver, gray, red, blue, green, yellow, orange,
brown, tan, gold, purple, other
```

14 values, case-sensitive, lowercase. The classifier emits one of these. Multi-color vehicles (e.g., two-tone pickups) pick the dominant one; operator can edit in the frontend.

## Integration with plates

Correlation happens at sighting time: when a Frigate event has **both** a plate reading and a vehicle detection in the same frame window, the analyzer:

1. Creates or updates the `plates` row.
2. Creates or updates the `vehicles` row using the attribute inference.
3. Sets `plates.vehicle_id` if this is the first time we've linked them.
4. Emits a `vehicle_sighting` row with both FKs.

Over time this builds two views:

- **`plate → vehicle`**: what car usually carries this plate.
- **`vehicle → plates`**: what plates have been seen on this vehicle (cars sometimes change plates).

If a plate's inferred vehicle attributes drift over time (say, a blue Tacoma was logged last month and now it's reading as a red Tacoma), the frontend flags the mismatch for operator review. This is a useful signal — plate swapping is unusual and worth a look.

## Deferred for future PRs

- Fine-grained year resolution (we settle for year ranges).
- Trim-level classification (XSE vs SE, etc.).
- Damage / modification detection.
- Aftermarket wheel / roof rack / ladder rack detection.
- Electric vs gas (would require reading plate text or badge detection).
- Commercial vehicle sub-classification (delivery truck brand, etc.).
