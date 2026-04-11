# Detection stack — overview

This document is the architectural source of truth for the cameras section's detection pipeline: how events flow, which component owns what, and why the split looks the way it does. Subordinate design docs in this directory cover each subsystem in detail:

- [`face-recognition-design.md`](./face-recognition-design.md) — auto-clustering every face seen, forever; data model; enrollment.
- [`alpr-design.md`](./alpr-design.md) — plate detection, plate history, cross-clip correlation.
- [`vehicle-attributes-design.md`](./vehicle-attributes-design.md) — make / model / color extraction; trade-offs; deferred implementation.
- [`recording-retention-design.md`](./recording-retention-design.md) — two-tier storage (continuous 24/7 + triggered events), pre-roll, segment length, day-level protection, disk watchdog, "review this day" notification.
- [`social-enrichment-design.md`](./social-enrichment-design.md) — linked profiles, manual reverse-search helper, opt-in third-party stub.
- [`nvidia-gpu-passthrough.md`](./nvidia-gpu-passthrough.md) — passing the NVIDIA GPU to the Frigate VM.
- [`protect-api-notes.md`](./protect-api-notes.md) — historical library notes from the pre-Frigate design. Still useful for the UNVR RTSP URL format.
- [`rtsp-endpoints.md`](./rtsp-endpoints.md) — per-camera RTSP table + VLAN 10 reachability.

## Design goals (what this pipeline must do)

1. **Pull live video from all 7 cameras** (6x G5 Bullet + G4 Doorbell Pro) out of the UNVR on VLAN 10.
2. **Detect objects** (person, vehicle, package, animal) in real time using on-GPU inference.
3. **Record continuously 24/7** into day-level folders with ~30-minute segments, on a smart-retention policy: days with triggers are preserved indefinitely; days without triggers are eligible for cleanup when disk pressure hits. See [`recording-retention-design.md`](./recording-retention-design.md).
4. **Capture triggered events separately** into a "Triggered Events" archive, with 60 seconds of pre-roll before the trigger and continued recording + tail until the tracked object leaves. Kept for 365 days, never deleted by the disk watchdog.
5. **Recognize faces** and cluster every face seen — even strangers — into stable person IDs over time, with retention forever.
6. **Recognize license plates** and maintain cross-clip plate history ("this plate has been seen 14 times across 6 weeks").
7. **Extract vehicle attributes** (make, model, color) from vehicle crops to enrich plate sightings.
8. **Push notifications** to a phone via self-hosted ntfy whenever a detection of interest fires, plus a one-shot "review this day" notification the first time a new day accumulates a trigger.
9. **Enrich known people** with social handles the operator links during enrollment. Optionally surface a one-click manual reverse-image search helper for unknown people. Optionally call an opt-in third-party face-search service the operator configures with their own API key.
10. **Serve a web UI** for browsing events, enrolling people, confirming or merging auto-generated person clusters, and reviewing plate/vehicle history.
11. **Stay entirely local.** Zero cloud services in the default configuration. No subscriptions. Privacy-oriented by default.

## Non-goals (explicitly not in scope)

- **Automated social-media scraping against face matches.** Violates platform ToS, potentially violates the CFAA, and conflicts with the "zero cloud / zero subscription" posture. Only an opt-in stub for a paid third-party face-search service is provided, and it ships disabled.
- **Replacing the UNVR archive.** The UNVR Instant continues to run its own UniFi Protect 24/7 recording on its WD Purple HDD with its own retention policy — that's independent of anything in this repo. Frigate's 24/7 recording on Proxmox storage is **additional** (a second, smarter archive with day-level protection and triggered-event metadata). Both run in parallel.
- **Real-time cloud ML.** No calls out to OpenAI / Google / AWS / Anthropic / any cloud inference service.
- **Running Frigate in Docker inside an LXC with `nesting=1`.** The cross-cutting best-practices doc bans Docker-in-LXC; Frigate runs in a **VM** instead (see below).
- **Subscribing to UniFi Protect's WebSocket event stream.** Frigate takes over as the source of truth for "what happened when" — we stop consuming Protect events directly. Protect still owns its own independent long-term recording, but its event model is replaced by Frigate's.

## Component overview

The detection stack is **five LXC containers + one VM**, all inside the `cameras/` section:

| # | Component | Runtime | Role |
|---|-----------|---------|------|
| 1 | `homesec-cameras-go2rtc` | LXC 200 | Pulls RTSP from the UNVR on VLAN 10, re-serves on VLAN 1 as a stable source. |
| 2 | `homesec-cameras-ntfy` | LXC 201 | Self-hosted push notifications. Receives alerts from the analyzer. |
| 3 | `homesec-cameras-mqtt` | LXC 202 | Mosquitto MQTT broker. Central event bus between Frigate and the analyzer. |
| 4 | `homesec-cameras-frigate` | **VM 210** | Detection + face rec + ALPR + short-clip recording. **Coral USB TPU** (24/7 object detection) **+ NVIDIA GPU** (face embeddings + ALPR OCR) via PCIe passthrough. |
| 5 | `homesec-cameras-analyzer` | LXC 203 | Python service: cross-clip face clustering, plate history, vehicle attributes, alert dispatch, social enrichment, REST API for the frontend. |
| 6 | `homesec-cameras-frontend` | LXC 204 | Web UI: event browser, face enrollment, cluster review, plate/vehicle history, social-handles editor. |

**Why Frigate is a VM, not an LXC.** Frigate is distributed as a Docker image. Running it natively in an LXC requires either building from source (fragile) or enabling `nesting=1` and running Docker inside the LXC (banned by our best-practices doc). VMs are first-class citizens in Proxmox, NVIDIA PCIe passthrough to a VM is the officially supported path, and Docker inside a VM is perfectly normal. The trade-off (slightly higher resource overhead than LXC) is worth the cleaner security boundary and policy alignment. See [`../../docs/proxmox-vm-best-practices.md`](../../docs/proxmox-vm-best-practices.md) for when we reach for a VM instead of an LXC.

**Why two accelerators in one VM.** The Coral Edge TPU and the NVIDIA GPU do complementary work and combine cleanly:

- **Coral Edge TPU (USB or M.2)** handles Frigate's 24/7 object-detection hot loop. Frigate's MobileDet / SSDLite models are compiled for int8 Edge TPU execution and run at ~400 inferences/sec at ~2 W. Dedicated, efficient, and designed exactly for this workload.
- **NVIDIA GPU (Tesla P40 or RTX 3060 or similar)** handles the heavier event-triggered inference — Frigate's face recognition (ArcFace-family embeddings) and license plate OCR (typically a CRNN or Transformer model). These fire only on detection events, not 24/7, so the GPU can idle most of the time.

This split keeps the continuous hot loop on specialized low-power silicon and reserves the GPU for the spiky heavy work. Frigate supports running object detection on one accelerator and face / ALPR on another — it's configured as two separate backends in `frigate.yml`. See [`nvidia-gpu-passthrough.md`](./nvidia-gpu-passthrough.md) for the passthrough mechanics and [`../app/vm/frigate/README.md`](../app/vm/frigate/README.md) for the VM provisioning details, including USB passthrough for the Coral.

**Why MQTT.** Frigate's primary event-publication mechanism is MQTT. We already committed to running a broker for this; the analyzer subscribes to the `frigate/events` topic for every detection. MQTT also gives us a clean integration point for future HomeSec sections — the `network-security/` dashboard or the `nvr/` disk-health monitor could publish to the same broker.

## Event flow

```
                        VLAN 10 (no internet)
┌────────────────────────────────────────────────────────────┐
│                                                            │
│   ┌────────────────┐                                       │
│   │ UNVR Instant   │   RTSP :7441                          │
│   │ (UniFi Protect)│◄──────────────┐                       │
│   └────────────────┘               │                       │
│                                    │                       │
└────────────────────────────────────┼───────────────────────┘
                                     │
                                     │ VLAN 10 NIC
                                     │
                   ┌─────────────────▼─────────────────┐
                   │ homesec-cameras-go2rtc            │
                   │ LXC 200 • VLAN 1 + VLAN 10        │
                   │ Pass-through RTSP on VLAN 1       │
                   └─────────────────┬─────────────────┘
                                     │ RTSP on VLAN 1
                                     │
          ┌──────────────────────────▼──────────────────────────┐
          │ homesec-cameras-frigate (VM 210)                    │
          │ VLAN 1 • Coral USB + NVIDIA GPU passthrough         │
          │  - Object detection     → Coral Edge TPU (24/7)     │
          │  - Face recognition     → NVIDIA GPU (event-driven) │
          │  - License plate OCR    → NVIDIA GPU (event-driven) │
          │  - Short event clips + thumbnails to /media         │
          └──────┬─────────────────────────────────────┬────────┘
                 │ MQTT publish                        │ HTTP REST
                 │ (frigate/events, ...)               │ (/api/events, ...)
                 ▼                                     │
        ┌─────────────────────┐                        │
        │ homesec-cameras-mqtt│                        │
        │ (LXC 202)           │                        │
        │ Mosquitto broker    │                        │
        └──────────┬──────────┘                        │
                   │ MQTT subscribe                    │
                   │                                   │
                   ▼                                   │
        ┌──────────────────────────────────────────────▼───┐
        │ homesec-cameras-analyzer (LXC 203)               │
        │ Python 3.12 + FastAPI + SQLModel + InsightFace   │
        │  - Cross-clip face clustering (HDBSCAN/cosine)   │
        │  - Plate history DB                              │
        │  - Vehicle attribute inference                   │
        │  - Social enrichment router                      │
        │  - Alert dispatcher → ntfy                       │
        │  - REST API for the frontend                     │
        └───────┬──────────────────────────────┬───────────┘
                │ HTTP POST                    │ HTTP GET/POST
                │                              │
                ▼                              ▼
   ┌───────────────────────┐       ┌──────────────────────────┐
   │ homesec-cameras-ntfy  │       │ homesec-cameras-frontend │
   │ (LXC 201)             │       │ (LXC 204)                │
   │ Push → 📱 phone       │       │ Web UI, LAN-only         │
   └───────────────────────┘       └──────────────────────────┘
```

**Key invariants:**

- UNVR stays on VLAN 10. Only go2rtc reaches VLAN 10 (via its second NIC with `tag=10`). Everything downstream stays on VLAN 1.
- Frigate does not talk to the UNVR directly; it pulls from go2rtc on VLAN 1. This keeps only one component VLAN-multihomed.
- The analyzer never talks directly to cameras. It consumes Frigate's events over MQTT and pulls snapshots/clips over Frigate's REST API.
- Alerts go one way: analyzer → ntfy → phone. The analyzer owns the alert decision logic (which events fire, dedup, quiet hours, etc.), not Frigate.
- The frontend is LAN-only. It is never exposed to the internet. Off-home access goes through Tailscale or WireGuard back into the LAN.

## What Frigate owns vs what the analyzer owns

A clear split matters — otherwise we duplicate work.

| Concern | Owned by |
|---|---|
| Pulling RTSP from go2rtc | Frigate |
| Object detection (person/vehicle/…) | Frigate |
| **Continuous 24/7 recording in 30-min segments** | **Frigate** |
| **Triggered event clips with 60s pre-roll + post-roll** | **Frigate** |
| Per-event face detection | Frigate |
| Per-event face match against enrolled gallery | Frigate (built-in) |
| Per-event ALPR text recognition | Frigate (built-in 0.16+) |
| Web UI for live view + raw event browsing | Frigate's built-in UI (available but secondary) |
| **Cross-clip face clustering** of unknown people | **Analyzer** |
| **Stable person IDs across clips** (`Unknown #14`) | **Analyzer** |
| **Cross-clip plate history** ("seen 14 times in 6 weeks") | **Analyzer** |
| **Plate → vehicle correlation** | **Analyzer** |
| **Vehicle attribute extraction** (make / model / color) | **Analyzer** |
| **Person ↔ plate correlation** (this person usually arrives in this vehicle) | **Analyzer** |
| **Day-level protection sweep** (mark days as protected or cleanup-eligible) | **Analyzer** |
| **Disk watchdog** (delete oldest eligible days when disk > 80%) | **Analyzer** |
| **First-trigger-of-day notification** (one per new day) | **Analyzer** |
| **Per-event alert dispatch to ntfy** (dedup, quiet hours, severity) | **Analyzer** |
| **Social enrichment** (linked profiles, reverse-search helper) | **Analyzer** |
| **Face enrollment UX** (naming a cluster, merging clusters, linking profiles) | **Frontend** → writes to Analyzer REST API |
| **Independent 24/7 archive on UNVR HDD** | **UniFi Protect on UNVR** (parallel, unchanged) |

The rule of thumb: **Frigate owns "what just happened in this clip"**. The **analyzer owns "what does this clip mean in the context of everything we've ever seen, and how do we keep the storage sane"**. The **UNVR owns its own independent UniFi Protect archive in parallel**.

## Runtime dependencies summary

- **go2rtc** depends on: UNVR reachable on VLAN 10.
- **ntfy** depends on: nothing internal (it's called into, not out of).
- **mqtt** depends on: nothing internal.
- **Frigate VM** depends on: go2rtc (for streams), mqtt (for event publishing), NVIDIA host drivers, `/var/lib/frigate/media` persistent volume.
- **Analyzer** depends on: mqtt (subscribe), Frigate REST API (for snapshots), ntfy (push), its own SQLite DB under `/var/lib/homesec-cameras-analyzer/`.
- **Frontend** depends on: analyzer REST API.

## Installation order

When standing this up for the first time:

1. `homesec-cameras-go2rtc` (LXC 200) — already scaffolded.
2. `homesec-cameras-ntfy` (LXC 201) — already scaffolded.
3. `homesec-cameras-mqtt` (LXC 202) — new; scaffolded in this PR.
4. `homesec-cameras-frigate` (VM 210) — new; scaffolded in this PR. Requires GPU passthrough preflight on the Proxmox host ([`nvidia-gpu-passthrough.md`](./nvidia-gpu-passthrough.md)).
5. `homesec-cameras-analyzer` (LXC 203) — scaffold only in this PR; Python implementation deferred.
6. `homesec-cameras-frontend` (LXC 204) — placeholder only in this PR; implementation deferred.

Each step is independently verifiable. Do not skip ahead; Frigate won't work until go2rtc is serving, the analyzer won't work until Frigate and MQTT are both up, etc.
