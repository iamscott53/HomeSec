# cameras

Local, privacy-oriented camera app for the seven-camera Ubiquiti Protect deployment: 6x G5 Bullet (2K, PoE, on-device AI detection) + 1x G4 Doorbell Pro. All cameras and the UNVR Instant live on VLAN 10 with **zero internet access** — every byte of footage, metadata, and event data stays on the LAN.

## What this app does

1. **Object detection across all 7 cameras** 24/7 on a Google Coral Edge TPU — person, vehicle, package, dog/cat, etc.
2. **Facial recognition** against every face the cameras see, with cross-clip clustering into stable person identities. Enrolled people (family, frequent visitors) get names; unknown people get stable `Unknown #N` labels and are grouped across all their appearances. Retained forever per operator policy.
3. **License plate recognition** with cross-clip plate history — every plate, every sighting, tracked over time. Plates get normalized (confusable chars, state format) and fuzzy-merged for OCR noise.
4. **Vehicle attributes** — make, model, color, body type — inferred from vehicle crops and correlated with plate sightings.
5. **Live streaming** of the 7-camera grid in a browser on the LAN.
6. **Two-tier smart recording** — continuous 24/7 footage in day-level folders with 30-minute segments, plus a separate "Triggered Events" archive of motion-triggered clips with 60 seconds of pre-roll and post-roll. Days with triggers are preserved; days with no triggers are eligible for cleanup when disk pressure hits. See [`docs/recording-retention-design.md`](./docs/recording-retention-design.md).
7. **Push notifications** to a phone via self-hosted ntfy: per-event alerts for interesting detections, plus a one-shot "review this day" notification the first time a new day accumulates a trigger.
8. **Social enrichment** — linked profiles on enrolled people, optional manual reverse-image-search helper, optional opt-in third-party face-search stub. Defaults are the most restrictive mode; see [`docs/social-enrichment-design.md`](./docs/social-enrichment-design.md).

Everything runs on your network. No cloud. No subscriptions. No phoning home.

## Design docs

Start with the overview, then the specific subsystem you care about:

- **[`docs/detection-stack-overview.md`](./docs/detection-stack-overview.md)** — architecture, event flow, component responsibilities. Read this first.
- **[`docs/face-recognition-design.md`](./docs/face-recognition-design.md)** — auto-clustering, data model, enrollment, retention policy.
- **[`docs/alpr-design.md`](./docs/alpr-design.md)** — plate pipeline, normalization, cross-clip history.
- **[`docs/vehicle-attributes-design.md`](./docs/vehicle-attributes-design.md)** — make/model/color options and trade-offs.
- **[`docs/recording-retention-design.md`](./docs/recording-retention-design.md)** — two-tier recording, pre-roll + post-roll, segment length, day-level protection, disk watchdog, "review this day" notification.
- **[`docs/social-enrichment-design.md`](./docs/social-enrichment-design.md)** — the three enrichment modes, legal posture, what the analyzer refuses to do.
- **[`docs/nvidia-gpu-passthrough.md`](./docs/nvidia-gpu-passthrough.md)** — passing the NVIDIA GPU and Coral USB to the Frigate VM.
- **[`docs/rtsp-endpoints.md`](./docs/rtsp-endpoints.md)** — per-camera RTSP table + VLAN 10 reachability.
- **[`docs/protect-api-notes.md`](./docs/protect-api-notes.md)** — historical library notes from the pre-Frigate design.

## Runtime: Proxmox LXC + one VM

HomeSec runs on **Proxmox**. Most of this app lives in **unprivileged LXC containers** (one LXC per service, native systemd, no Docker, no nesting) per [`../docs/proxmox-lxc-best-practices.md`](../docs/proxmox-lxc-best-practices.md). The one exception is **Frigate itself**, which ships as a Docker image and needs heavy hardware passthrough (NVIDIA GPU + Coral USB), so it runs as a full Proxmox VM per [`../docs/proxmox-vm-best-practices.md`](../docs/proxmox-vm-best-practices.md).

### The six components

| # | Component | Runtime | Role | VLANs | Scaffolded today? |
|---|-----------|---------|------|-------|--------------------|
| 1 | `homesec-cameras-go2rtc`   | LXC 200 | RTSP pass-through: pulls from UNVR on VLAN 10, serves to Frigate on VLAN 1. | VLAN 1 + VLAN 10 | ✅ |
| 2 | `homesec-cameras-ntfy`     | LXC 201 | Self-hosted push notifications. | VLAN 1 | ✅ |
| 3 | `homesec-cameras-mqtt`     | LXC 202 | Mosquitto broker — event bus between Frigate and the analyzer. | VLAN 1 | ✅ |
| 4 | `homesec-cameras-analyzer` | LXC 203 | Python service: cross-clip clustering, plate history, vehicle attributes, alerts, social enrichment, REST API. CPU-only. | VLAN 1 | 🟡 scaffold only (language locked in, code deferred) |
| 5 | `homesec-cameras-frontend` | LXC 204 | LAN-only web UI. | VLAN 1 | 🟡 placeholder only |
| 6 | `homesec-cameras-frigate`  | **VM 210** | Detection + face rec + ALPR + short-clip recording. **Coral USB** (24/7 object detection) + **NVIDIA GPU** (face rec + ALPR OCR). | VLAN 1 | ✅ |

All provisioning details, install scripts, systemd units, and component-specific READMEs live under [`app/lxc/`](./app/lxc) and [`app/vm/`](./app/vm).

## Architecture

```
                        VLAN 10 (no internet)
┌────────────────────────────────────────────────────────────┐
│   ┌────────────────┐                                       │
│   │ UNVR Instant   │   RTSP :7441                          │
│   │ (UniFi Protect)│◄──────────────┐                       │
│   └────────────────┘               │                       │
└────────────────────────────────────┼───────────────────────┘
                                     │
                                     │ VLAN 10 NIC
                                     │
                   ┌─────────────────▼─────────────────┐
                   │ homesec-cameras-go2rtc            │
                   │ LXC 200 • VLAN 1 + VLAN 10        │
                   └─────────────────┬─────────────────┘
                                     │ RTSP on VLAN 1
                                     │
          ┌──────────────────────────▼──────────────────────────┐
          │ homesec-cameras-frigate (VM 210)                    │
          │ VLAN 1 • Coral USB + NVIDIA GPU passthrough         │
          │  - Object detection     → Coral Edge TPU (24/7)     │
          │  - Face recognition     → NVIDIA GPU (event-driven) │
          │  - License plate OCR    → NVIDIA GPU (event-driven) │
          │  - Short event clips + thumbnails                   │
          └──────┬─────────────────────────────────────┬────────┘
                 │ MQTT publish                        │ HTTP REST
                 │ frigate/events                      │ /api/events, /api/.../snapshot
                 ▼                                     │
        ┌─────────────────────┐                        │
        │ homesec-cameras-mqtt│                        │
        │ (LXC 202)           │                        │
        │ Mosquitto broker    │                        │
        └──────────┬──────────┘                        │
                   │ MQTT subscribe                    │
                   ▼                                   │
        ┌──────────────────────────────────────────────▼───┐
        │ homesec-cameras-analyzer (LXC 203)               │
        │ Python 3.12 + FastAPI + SQLModel                 │
        │  - Cross-clip face clustering                    │
        │  - Plate history DB                              │
        │  - Vehicle attribute inference                   │
        │  - Social enrichment router                      │
        │  - Alert dispatcher → ntfy                       │
        │  - REST API for the frontend                     │
        └───────┬──────────────────────────────┬───────────┘
                │ HTTP POST                    │ HTTP GET/POST
                ▼                              ▼
   ┌───────────────────────┐       ┌──────────────────────────┐
   │ homesec-cameras-ntfy  │       │ homesec-cameras-frontend │
   │ (LXC 201)             │       │ (LXC 204)                │
   │ Push → 📱 phone       │       │ Web UI, LAN-only         │
   └───────────────────────┘       └──────────────────────────┘
```

## What's scaffolded today

- **`app/lxc/go2rtc/`** — install.sh, hardened systemd unit, go2rtc.yaml.
- **`app/lxc/ntfy/`** — install.sh, secure-defaults server.yml.
- **`app/lxc/mqtt/`** — install.sh, mosquitto.conf. _(new in detection stack pass)_
- **`app/lxc/analyzer/README.md`** — scaffold only. Language locked in: Python 3.12. Code deferred. _(new)_
- **`app/lxc/frontend/README.md`** — placeholder only. _(new)_
- **`app/vm/README.md`** — VM inventory + provisioning index. _(new)_
- **`app/vm/frigate/`** — install.sh, docker-compose.yml, frigate.yml, README. Frigate image tag still needs to be pinned before first install. _(new)_
- **`docs/detection-stack-overview.md`** + five subsystem design docs + the NVIDIA passthrough runbook. _(new)_

## What's NOT scaffolded yet

- **Analyzer code.** Only the README and scaffold directory exist. The Python package, install script, systemd unit, and schema migrations land in a follow-up PR after the Frigate VM is stood up on real hardware.
- **Frontend code.** Only the README exists.
- **Real RTSP stream keys, UNVR VLAN 10 IP, MQTT passwords, Frigate image version.** All placeholders until hardware is up.
- **Vehicle attribute inference.** Designed but not implemented in the analyzer; even when the analyzer lands it'll start with color-only and add make/model later.

## Provisioning order (once hardware is up)

1. Read [`../docs/proxmox-lxc-best-practices.md`](../docs/proxmox-lxc-best-practices.md) and [`../docs/proxmox-vm-best-practices.md`](../docs/proxmox-vm-best-practices.md) top to bottom.
2. Proxmox host preflight for GPU passthrough: IOMMU, vfio-pci binding, blacklist nvidia/nouveau. See [`docs/nvidia-gpu-passthrough.md`](./docs/nvidia-gpu-passthrough.md) Part 1.
3. Create the VLAN-aware bridge on the host if it doesn't exist.
4. Provision **`homesec-cameras-go2rtc`** (LXC 200) per [`app/lxc/go2rtc/README.md`](./app/lxc/go2rtc/README.md).
5. Provision **`homesec-cameras-ntfy`** (LXC 201) per [`app/lxc/ntfy/README.md`](./app/lxc/ntfy/README.md).
6. Provision **`homesec-cameras-mqtt`** (LXC 202) per [`app/lxc/mqtt/README.md`](./app/lxc/mqtt/README.md). Create admin + frigate + analyzer MQTT users.
7. Provision **`homesec-cameras-frigate`** (VM 210) per [`app/vm/frigate/README.md`](./app/vm/frigate/README.md). Pin a real Frigate version in `docker-compose.yml` first.
8. Fill in real RTSP stream tokens, MQTT creds, and camera entries in the Frigate config. Snapshot.
9. Verify events show up on the MQTT broker (`mosquitto_sub -t 'frigate/#'`).
10. Provision the analyzer LXC (deferred to follow-up PR once its code exists).
11. Provision the frontend LXC (deferred to a later PR).

Each step is independently verifiable; don't skip ahead.

## Hard constraint: VLAN 10 reachability

Cameras and the UNVR have no internet. **Only `homesec-cameras-go2rtc` (LXC 200) is multi-homed** onto VLAN 10 — everything else stays on VLAN 1. Frigate reaches the cameras via go2rtc's VLAN 1 proxy. See [`docs/rtsp-endpoints.md`](./docs/rtsp-endpoints.md) for the reasoning and the `pct create` flags.

## Hard constraint: no Docker-in-LXC, no cloud, no subscriptions

- Frigate runs in a VM because its Docker dependency plus GPU passthrough makes it a natural fit for a VM. Every other component is a plain LXC with systemd services.
- No cloud inference services are called from any component.
- The only service in the entire stack that has a paid-subscription path is the **opt-in Mode C** social enrichment stub, which ships **disabled** and requires explicit operator configuration. Everything else is free + local.
