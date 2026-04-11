# Face recognition — design

This doc covers the face recognition subsystem: how faces are detected, embedded, clustered, enrolled, matched, and retained. It is the detailed design behind the `homesec-cameras-analyzer` service's face-handling code, which will live at `cameras/app/lxc/analyzer/` when implementation lands.

Policy decisions from the [detection stack overview](./detection-stack-overview.md):

- **Scope:** auto-cluster every face the cameras see, retain forever.
- **Enrollment:** operator can attach a name and optional social handles to any cluster, at any time.
- **Unknown faces stay tracked:** they get a stable `Unknown #N` identity until labeled.

## Why this is a custom service (not just Frigate)

Frigate 0.14+ has built-in face recognition. It does two things well:

1. Per-event face detection (finds face regions in a clip).
2. Per-event face match against an **enrolled gallery** (if you've registered "Alice", it'll tag clips that contain Alice).

It does **not**:

- Cluster unknown faces across clips into stable identities.
- Assign persistent IDs like `Unknown #14` that survive restarts and grow over time.
- Merge clusters when the operator says "these two Unknown Ns are actually the same person".
- Notify the operator "you've seen this person before" on the second and subsequent sightings.
- Maintain cross-clip statistics (sighting count, first seen, last seen, time-of-day distribution).

Those gaps are what the analyzer fills.

## Pipeline

```
Frigate event fires
        │
        │ MQTT: frigate/events
        ▼
Analyzer consumes event
        │
        │ HTTP GET Frigate REST API
        │   /api/events/<id>/snapshot.jpg
        │   /api/events/<id>/clip.mp4 (on demand)
        ▼
Face detection + alignment
        │ (InsightFace RetinaFace or SCRFD)
        │
        │ Typically 0-3 faces per event
        ▼
Face embedding
        │ (InsightFace ArcFace buffalo_l: 512-d vector)
        │
        │ One vector per face, plus a quality score
        ▼
Quality filter
        │ (reject embeddings below quality threshold —
        │  low res, heavy occlusion, extreme angles)
        ▼
Cluster assignment
        │ - For each new embedding, find nearest cluster
        │   centroid by cosine distance
        │ - If distance < MATCH_THRESHOLD → assign to cluster
        │ - Else → create new cluster (new Unknown #N)
        ▼
Update DB + emit internal event
        │
        ├─► if cluster is enrolled (has a name) → fire recognition alert
        ├─► if cluster has been seen >1 time → fire "seen before" alert
        └─► always → increment cluster.sighting_count
```

## Hardware placement

Face detection and embedding run inside the **Frigate VM** on the **NVIDIA GPU** (see [`detection-stack-overview.md`](./detection-stack-overview.md) for the two-accelerator split). The analyzer (`homesec-cameras-analyzer`) is **CPU-only** — it consumes embeddings Frigate has already computed and does pure vector-arithmetic clustering.

This split assumes Frigate exposes the raw face embeddings (not just a matched name) via its MQTT event payload or REST API. If a future Frigate version removes that surface area, we'd need a sidecar inference service on the GPU to re-embed face crops the analyzer pulls from Frigate's `/api/events/<id>/face.jpg` endpoint. Flag this during the first end-to-end test; if we have to add a sidecar, the cameras layout grows by one VM (`homesec-cameras-inference`, VM 211) and the analyzer gains an HTTP client for it.

## Model choices (locked in)

| Stage | Model | Why |
|---|---|---|
| Face detection | **SCRFD** (InsightFace default) | Fast, accurate, handles small faces well, ships in the `insightface` pip package. RetinaFace is fine too. |
| Face alignment | **5-point landmarks** from SCRFD | Standard; feeds straight into ArcFace. |
| Face embedding | **ArcFace `buffalo_l`** (512-d) | The de-facto open-source face recognition model. Good accuracy, well-characterized. |
| Clustering | **Incremental centroid-based** with cosine distance | HDBSCAN offline is better, but for online ingestion centroid-based is simpler, faster, and easier to reason about. Periodic offline HDBSCAN refit can re-partition later if needed. |
| Quality metric | **ArcFace confidence** from SCRFD + face-size heuristic | Reject faces smaller than `MIN_FACE_PX` (e.g., 64px) and confidence < `MIN_FACE_CONF` (e.g., 0.6). |

Distance threshold for matching is the most sensitive hyperparameter. Starting point:

- **`MATCH_THRESHOLD = 0.4` cosine distance** (≈ 0.6 similarity). Tune during early operation by reviewing cluster-merge suggestions in the frontend.

## Data model

Four tables in the analyzer's SQLite DB (`/var/lib/homesec-cameras-analyzer/analyzer.db`):

### `persons`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | `person_<ulid>`. Stable across DB exports/imports. |
| `display_name` | TEXT NULL | `NULL` until operator enrolls. When NULL, frontend shows `Unknown #<ordinal>`. |
| `ordinal` | INTEGER | Monotonic counter per `display_name IS NULL`. Becomes the `Unknown #N` label. |
| `social_handles_json` | TEXT NULL | JSON blob: `[{"platform":"instagram","handle":"@...","url":"https://..."}]`. Operator-editable via frontend. Never populated automatically. |
| `notes` | TEXT NULL | Free-text operator notes. |
| `first_seen_at` | TIMESTAMP | |
| `last_seen_at` | TIMESTAMP | Index for "recent activity" queries. |
| `sighting_count` | INTEGER | Denormalized counter, updated on every event. |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |

### `face_embeddings`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | ULID. |
| `person_id` | TEXT FK → persons.id | |
| `event_id` | TEXT | Frigate event ID. |
| `embedding` | BLOB | 512 float32 values, 2048 bytes. Raw binary, not base64. |
| `quality` | REAL | Range 0.0-1.0. |
| `captured_at` | TIMESTAMP | From the Frigate event timestamp, not wall clock. |
| `camera` | TEXT | Which camera saw this face. |
| `snapshot_path` | TEXT NULL | Path to the face crop on disk under `/var/lib/homesec-cameras-analyzer/faces/`. |

Index on `(person_id, captured_at)` for per-person history queries.

### `person_aliases`

For tracking cluster merges. When the operator says "Unknown #14 is actually Alice", we write a row here, then merge the clusters.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | |
| `from_person_id` | TEXT | The cluster that was merged away. |
| `to_person_id` | TEXT | The cluster that absorbed it. |
| `merged_at` | TIMESTAMP | |
| `merged_by` | TEXT | Operator identifier (for audit). |

### `person_cluster_centroids`

Pre-computed centroids, updated incrementally on every new embedding. Stored separately so clustering doesn't have to scan every embedding per event.

| Column | Type |
|---|---|
| `person_id` | TEXT PRIMARY KEY FK → persons.id |
| `centroid` | BLOB (512 float32 = 2048 bytes) |
| `embedding_count` | INTEGER |
| `updated_at` | TIMESTAMP |

## Enrollment flow (frontend → analyzer REST)

1. Operator opens the frontend, goes to "People → Unknown", sees a grid of `Unknown #N` clusters with best-face thumbnails and sighting counts.
2. Clicks `Unknown #14`. Sees a page of face thumbnails across all clips, all events, all cameras. Plays a few clips.
3. Clicks "Enroll" → modal:
   - **Display name:** `Alice`
   - **Social handles (optional):** `instagram: @alice_handle`, `linkedin: in/alice`
   - **Notes (optional):** `my sister`
4. Frontend POSTs `{display_name, social_handles, notes}` to `PATCH /api/persons/<id>`.
5. Analyzer updates `persons.display_name`, nulls out the ordinal, stores social handles.
6. All past and future events referencing `person_id` now display as "Alice".

**Merging clusters.** If the operator clicks "this is the same person as Alice" on `Unknown #22`, the frontend POSTs `POST /api/persons/merge` with `{from_id, to_id}`. Analyzer:

1. Re-parents every `face_embeddings` row from `from_id` → `to_id`.
2. Re-computes the centroid for `to_id`.
3. Writes an audit row to `person_aliases`.
4. Deletes the `from_id` row from `persons`.

**Splitting clusters.** Rare but possible when two different people were accidentally fused. Operator picks a subset of faces and clicks "split into new person". Analyzer creates a new `persons` row and re-parents the selected embeddings. Centroids recomputed for both sides.

## Retention (forever)

Per operator decision: **auto-cluster everyone, retain forever.** Embeddings are small (2 KB each), DB overhead is negligible, face crops are the main storage cost (say 10-50 KB per crop, dozens of crops per cluster). Back-of-envelope: 10,000 faces × 30 KB = 300 MB. Non-issue on modern storage.

**However,** the legal posture of "identifying every stranger who walks past a private residence, forever" deserves an honest note:

- Florida has no biometric privacy statute comparable to Illinois BIPA, Texas CUBI, or Washington HB 1493.
- Recording on your own property for personal use is generally legal in FL.
- Retaining and automatically identifying people (even strangers) from that recording is legally fuzzier and jurisdiction-dependent. Nothing here rises to "illegal" for personal use in FL as of the 2025 baseline, but the posture is meaningfully different from "ring doorbell clip uploaded to a shared Ring feed", which has been the subject of ongoing litigation.
- **The analyzer must never expose its face DB or face crops outside the LAN.** No cloud sync, no backup to a third-party, no sharing a link with anyone not physically on the home network. Tailscale / WireGuard back into the LAN is acceptable; exposing `:80` on the WAN is not.

This posture is enforced operationally (pfSense rules, LAN-only frontend) and documented, not technically guaranteed. The operator is responsible for not accidentally defeating it.

## Alert behavior

When a new embedding is assigned to a cluster, the analyzer decides whether to fire an alert. Rules:

| Condition | Alert? | Severity |
|---|---|---|
| Cluster is enrolled (has `display_name`) and seen for the 1st time today | ✅ | info |
| Cluster is enrolled and seen N+1 time today | ❌ (dedup within a window) | — |
| Cluster is unknown and has been seen before | ✅ | info — "Unknown #14 is back" |
| Cluster is unknown and this is the 1st sighting ever | ⚠️ configurable | info or quiet |
| Face detected but no match assigned (should never happen with incremental clustering) | ❌ | — |

Dedup window and severity mapping live in `/etc/homesec-cameras-analyzer/config.yaml`. The alert payload includes the display name (or `Unknown #N`), the camera, a snapshot URL (served by Frigate), and, for enrolled people, their first social handle.

## What gets deferred

Not in v0:

- **Age/gender estimation.** InsightFace supports it via genderage model; we're not shipping it in v0 because (a) it's inaccurate on low-res crops, (b) it adds attack surface, and (c) nothing in the operator workflow needs it.
- **Emotion/expression detection.** Same.
- **Liveness/anti-spoof.** Not needed for a home system.
- **Face re-identification across seasons.** ArcFace is reasonably robust to lighting and angle but can drift for the same person over years. Periodic offline re-clustering will handle drift.
- **Federated learning / model fine-tuning.** We use the stock buffalo_l weights forever.
