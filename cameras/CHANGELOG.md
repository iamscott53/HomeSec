# Changelog — cameras

Scoped changelog for the `cameras/` section only. Repo-wide history is in [`../CHANGELOG.md`](../CHANGELOG.md).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html). Tag convention: `cameras/vX.Y.Z`.

## [Unreleased]

### Added

- **Detection stack architecture.** The cameras section is now a six-component stack designed around Frigate: `homesec-cameras-go2rtc` (LXC 200, existing), `homesec-cameras-ntfy` (LXC 201, existing), `homesec-cameras-mqtt` (LXC 202, new — Mosquitto broker), `homesec-cameras-analyzer` (LXC 203, scaffold only — Python service), `homesec-cameras-frontend` (LXC 204, placeholder), and `homesec-cameras-frigate` (**VM 210**, new — the detection engine with Coral USB + NVIDIA GPU passthrough).
- **`app/vm/`** directory introduces the VM-runtime track for the cameras section. `vm/README.md` documents the cameras VM inventory and provisioning index. `vm/frigate/` ships a full scaffold: `README.md`, `docker-compose.yml` (single Frigate service with `runtime: nvidia`, Coral USB device access via `/dev/bus/usb`, hardened `cap_drop` + `no-new-privileges`, Docker secrets for the RTSP password, healthcheck), `frigate.yml` (7-camera template with placeholder MQTT creds and go2rtc stream URIs; `face_recognition: enabled: true`; `lpr: enabled: true`; `detectors: coral: edgetpu`; `record.retain.days: 7`), and `install.sh` (idempotent; verifies NVIDIA + Coral presence before any installs; installs Debian NVIDIA driver, Docker CE, NVIDIA Container Toolkit, libedgetpu1-std from Google's apt; lays out `/var/lib/frigate/{config,media,db,secrets}`; refuses to run if `docker-compose.yml` still has `PIN_ME_BEFORE_INSTALL`).
- **`app/lxc/mqtt/`** — new Mosquitto LXC scaffold. `install.sh` (idempotent; installs `mosquitto` + `mosquitto-clients` from Debian stable; drops the config template at both `/etc/mosquitto/conf.d/homesec.conf` and `/etc/mosquitto/conf.d/99-homesec-default.conf` for diff-against-default; creates empty `passwd` + `acl` template files with correct perms), `mosquitto.conf` (`allow_anonymous false`, password + ACL files required, persistence, journald logging, rate and size limits), `README.md` (CTID 202 provisioning, first-time user setup for admin/frigate/analyzer users, ACL template, sanity test commands).
- **`app/lxc/analyzer/README.md`** — scaffold reserving CTID 203. **Locks in Python 3.12 as the analyzer language** — the first concrete language commitment in the repo. Documents the planned stack (FastAPI, SQLModel on SQLite, asyncio-mqtt, InsightFace buffalo_l as a fallback, uv package manager, pydantic v2). Captures CPU-only hardware stance — the analyzer does clustering math on embeddings Frigate already computed on its GPU. Explicitly notes the contingency where Frigate stops exposing raw embeddings (then a VM 211 inference sidecar becomes necessary). **Documents the daily sweep, hourly disk watchdog (with updated 75/90/95% thresholds, no protected-day deletion, and "recording will stop" escalation), first-trigger-of-day notification, Storage page REST API, quality preset manager, and Storage audit API as analyzer responsibilities.** Records the mount requirement (read + sentinel-write access to `/media/frigate/recordings/` shared from the Frigate VM).
- **`app/lxc/frontend/README.md`** — placeholder reserving CTID 204. Tech stack still TBD. **Responsibilities updated** to include the Storage page (checkbox day list, Download-as-ZIP over HTTPS with post-download delete modal, storage audit log view) and the Settings → Cameras → Recording quality section (four preset radio group + auto-downgrade toggle). Four critical UX rules locked in: (1) never auto-delete a `.protected` day, (2) always show the recording-will-stop banner on every page when active, (3) never compress video on the zip download (`ZIP_STORED`), (4) never delete a just-downloaded day without explicit operator confirmation.
- **`docs/detection-stack-overview.md`** — architectural source of truth. Event flow diagram, component responsibilities, "what Frigate owns vs what the analyzer owns" split table, installation order, why Frigate is in a VM not an LXC, why two accelerators (Coral hot-loop + GPU event-triggered).
- **`docs/face-recognition-design.md`** — auto-cluster every face forever, incremental centroid clustering with cosine distance `MATCH_THRESHOLD = 0.4`, ArcFace `buffalo_l` 512-d embeddings, SCRFD face detector, quality gating, full SQLite schema (`persons`, `face_embeddings`, `person_aliases`, `person_cluster_centroids`), enrollment + merge + split flows, alert rules, legal/ethical posture for "retain forever".
- **`docs/alpr-design.md`** — plate pipeline, normalization rules (uppercase, strip, length, FL-specific confusable-char rules for `I/O/Q`), Levenshtein fuzzy-merge within a time window, full SQLite schema (`plates`, `plate_sightings`, `vehicles`), correlation with faces and vehicles, storage estimate (~90k sightings / 5 years = ~45 MB DB + ~1.8 GB plate crops).
- **`docs/vehicle-attributes-design.md`** — make/model/color extraction design. Four model options (YOLO classification, CLIP zero-shot, VLM, color-only). Recommendation for v0.1 implementation: start with color-only (Option D), then add YOLOv8 fine-tune (Option A). Full `vehicles` + `vehicle_sightings` schema. 14-value controlled color vocabulary. Implementation deferred.
- **`docs/recording-retention-design.md`** — two-tier storage design. **Tier 1 (continuous 24/7)**: Frigate records to `/media/frigate/recordings/YYYY-MM-DD/HH/<camera>/*.mp4` in 30-minute segments (`-segment_time 1800` in `ffmpeg.output_args.record`; tunable to 10/20/60 minutes). Day is the top-level partition — "each day in its own folder with the full date" is native to Frigate's path layout. **Tier 2 (triggered events)**: Frigate records to `/media/frigate/clips/` with `record.events.pre_capture: 60` (60s pre-roll) and `record.events.post_capture: 30` (30s tail after object leaves), retained 365 days. **Day-level protection** (custom, analyzer LXC): daily 03:00 sweep marks each day directory with `.protected` (had events) or `.cleanup-eligible` (no events); hourly disk watchdog thresholds documented in `storage-management-design.md`. Watchdog never touches clips directory. **First-trigger-of-day notification** fires one-shot ntfy alert the first time a new local date accumulates a trigger. Storage budget tables (1 TB recommended for ~13 days of 24/7). Sentinel-file contract locked in.
- **`docs/storage-management-design.md`** — the complete disk-pressure management design.
    - **New thresholds:** warnings at 75%, critical at 90%, automatic quality downgrade at 95%. Replaces the earlier 80% single-threshold model.
    - **Protected days are now inviolable under automation.** The earlier ">95% delete oldest protected day" fallback has been removed. The only way a `.protected` day leaves the disk is an operator-initiated, audited download-then-delete action in the frontend.
    - **"Recording will stop" escalation:** when `.cleanup-eligible` days are exhausted and pressure keeps climbing, the analyzer fires a red urgent ntfy notification every hour until the operator adds storage or downloads + deletes days.
    - **Four quality presets (High / Medium / Low / Lowest)** swapped via symlink + Frigate container restart by the analyzer. Exact `ffmpeg.output_args.record` strings locked in per preset with GPU-accelerated `h264_nvenc` re-encode at decreasing bitrates and framerates. Storage budget per preset (75 → 45 → 30 → 15 GB/day for 7 cameras).
    - **Automatic downgrade at 95%:** steps preset one level down, restarts Frigate, emits a notification. Max one downgrade per 12h. **No automatic re-upgrade** — operator decides when to go back up, to avoid thrash.
    - **User-friendly download UX:** Storage page in the frontend shows oldest days first with a checkbox per day, "Download selected as ZIP" button (streams a `ZIP_STORED` zip via HTTPS from the analyzer's `StreamingResponse`), and a post-download "Delete from server?" modal with a 10-minute confirmation window. Deletion of `.protected` days requires matching a download hash from `storage_audit` within that window.
    - **SFTP fallback:** optional chroot'd read-only SFTP on port 2222 for operators who prefer a standard SFTP client. Ships disabled.
    - **Two new analyzer tables:** `storage_audit` (append-only ledger of every download, delete, quality change, watchdog action) and `quality_preset_changes` (denormalized view of preset history).
    - **Notification severity ladder** mapped to ntfy priorities: info (3), warning (4), urgent (5 + red tags for recording-will-stop).
    - Explicit "what the operator can do from the phone" click-through mapping on every storage notification.
- **`docs/social-enrichment-design.md`** — the three enrichment modes: (A) linked profiles on enrolled people — default enabled, trivial; (B) manual reverse-search helper opening Google Lens / Bing Visual Search in a new browser tab — default disabled, operator toggles; (C) opt-in stub for a paid third-party face-search API with its own API key — ships disabled and unconfigured, explicit conflict with "zero subscriptions" and "zero cloud" documented inline. Hard-coded refusals: no scraping of Facebook / Instagram / X / LinkedIn / TikTok / Threads / Mastodon etc., no automated Mode B or Mode C calls, no sharing between installations. Full audit table schema (`social_enrichment_audit`, `third_party_search_results`).
- **`docs/nvidia-gpu-passthrough.md`** — step-by-step host preflight (IOMMU, vfio-pci binding, driver blacklist), VM creation with `qm create` including `--hostpci0` and `--usb0` flags, in-VM driver install, Docker + NVIDIA Container Toolkit + libedgetpu install, troubleshooting for common failure modes.
- **`../docs/proxmox-vm-best-practices.md`** — new cross-cutting standards doc covering VM use in HomeSec: when to use a VM instead of an LXC, VMID range per section (cameras 210-219, etc.), machine type / BIOS / CPU / disk / NIC defaults, PCIe passthrough pattern, USB passthrough pattern (bus+port over vendor:product), snapshot + backup policy, security do-not list.

### Changed

- **`README.md`** — rewritten to cover the detection stack. New "What this app does" list now covers face rec, ALPR, vehicle attributes, live grid, **two-tier smart recording (24/7 + Triggered Events with pre-roll and day-level protection)**, **user-friendly storage management (download-as-ZIP, post-download delete prompt, four quality presets with auto-downgrade, "recording will stop" escalation)**, per-event + first-trigger-of-day + storage-pressure notifications, and social enrichment. New component table (5 LXCs + 1 VM). New architecture diagram. New "Design docs" index (now includes `recording-retention-design.md` and `storage-management-design.md`). New provisioning order. Keeps the VLAN 10 reachability constraint and the no-Docker-in-LXC / no-cloud / no-subscriptions constraints prominent.
- **`app/vm/frigate/frigate.yml`** — updated `record` block to the two-tier model: `record.retain.days: 365` + `record.retain.mode: all` (Frigate's native retention set generously; real retention is handled by the analyzer's day-level cleanup), `record.events.pre_capture: 60`, `record.events.post_capture: 30`, `record.events.retain.default: 365`. Added `ffmpeg.output_args.record` with `-segment_time 1800` for 30-minute continuous-recording segments. Inline comments document the tunable alternatives (10/20/60 minutes), the tradeoff with event clip extraction, **and the quality preset symlink mechanism**: the analyzer maintains four config files at `/var/lib/frigate/config/config.<preset>.yml` and symlinks the active one; auto-downgrade at 95% swaps the symlink and restarts the container; manual override lives in Settings. Exact `ffmpeg.output_args.record` strings per preset are documented in `storage-management-design.md`.
- **`docs/detection-stack-overview.md`** — added `recording-retention-design.md` to the subordinate-doc index. Expanded the "design goals" list to explicitly cover continuous 24/7 recording with day-level protection, triggered event clips with pre-roll, and the first-trigger-of-day notification. Updated the "who owns what" split table to include the day-level sweep, disk watchdog, and first-trigger notification as analyzer responsibilities. Revised the UNVR-related non-goal to clarify that the UNVR runs its own independent UniFi Protect archive in parallel; Frigate's 24/7 recording is additional, not a replacement.
- **`app/lxc/README.md`** — rewritten: four-container list → five-LXC list with mqtt, analyzer, frontend added and backend removed. New section explaining that Frigate lives in `../vm/frigate/`, not here. Updated architecture diagram.
- **`../docs/proxmox-lxc-best-practices.md`** — brief update adding a "LXC is the default, see VM best practices for exceptions" pointer at the top.
- **`../docs/README.md`** — links the new `proxmox-vm-best-practices.md`.

### Policy decisions locked in

- **Frigate is the detection engine.** Build on it rather than rolling our own inference pipeline from scratch.
- **Frigate runs in a Proxmox VM**, not an LXC, to honor the "no Docker-in-LXC" rule and use Proxmox's first-class PCIe passthrough for the NVIDIA GPU.
- **Dual-accelerator hardware split:** Coral USB Accelerator for 24/7 object detection, NVIDIA GPU (P40 or 3060) for event-triggered face rec and ALPR OCR.
- **Face recognition scope:** auto-cluster every face seen, retain forever. Unknown clusters get stable `Unknown #N` identities until the operator labels them.
- **Two-tier recording + inviolable protected days.** Continuous 24/7 with day-level protection, plus a separate Triggered Events archive with pre-roll. `.protected` days are NEVER deleted by automation. When disk pressure can't be resolved by deleting `.cleanup-eligible` days, the system fires a red "recording will stop" notification and waits for the operator, rather than losing interesting footage. Documented in `recording-retention-design.md` + `storage-management-design.md`.
- **Storage pressure thresholds:** 75% = warning + delete eligible, 90% = critical, 95% = automatic quality downgrade one level. No automatic upgrade.
- **Social enrichment:** Mode A (linked profiles) default on; Mode B (manual reverse-search helper) default off; Mode C (third-party API stub) default off and unconfigured. No automated social-media scraping, ever.
- **Analyzer language:** Python 3.12. This is the first concrete language commitment in the repo and supersedes the earlier "deferred" posture.

### Not yet implemented

- Analyzer Python code (only the README + scaffold directory exist).
- Frontend code (only a README).
- Real Frigate version pin in `docker-compose.yml` (still `PIN_ME_BEFORE_INSTALL`).
- Real RTSP stream tokens, UNVR VLAN 10 IP, MQTT passwords, Frigate image version.
- Vehicle attribute inference (designed, not implemented).
- First end-to-end test on real hardware.

## [0.1.0] — 2026-04-11

First tagged release of the cameras section. Scaffolds the Proxmox LXC stack with pinned upstream dependencies for the two services that already exist. Backend and frontend containers are not in this release.

### Added

- **Section README** (`README.md`) — purpose, four-container LXC architecture diagram, VLAN 10 reachability note, provisioning order, pointer to the best-practices doc.
- **LXC layout overview** (`app/lxc/README.md`) — the four planned containers (`homesec-cameras-go2rtc` 200, `homesec-cameras-ntfy` 201, future `homesec-cameras-backend` 202, future `homesec-cameras-frontend` 203), which VLANs each needs, which are scaffolded today.
- **go2rtc container scaffold** (`app/lxc/go2rtc/`):
    - `install.sh` — idempotent, pinned version with per-arch SHA256 verification, dedicated unprivileged `go2rtc` system user with `/usr/sbin/nologin`, `mktemp` + trap cleanup, refuses to run if any pinning placeholder has not been filled in, preserves existing config on re-run.
    - `go2rtc.service` — hardened systemd unit: `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `PrivateDevices=true`, `ProtectKernelTunables/Modules/Logs=true`, `ProtectControlGroups=true`, `LockPersonality=true`, `MemoryDenyWriteExecute=true`, `RestrictNamespaces/Realtime/SUIDSGID=true`, `SystemCallArchitectures=native`, `SystemCallFilter=@system-service` minus the common dangerous sets, empty `CapabilityBoundingSet` and `AmbientCapabilities`, explicit `ReadWritePaths=/var/lib/go2rtc`.
    - `go2rtc.yaml` — 7 stream entries (`doorbell`, `front-left`, `front-right`, `front-center`, `rear-left`, `rear-right`, `rear-center`) with placeholder RTSP URLs to fill in after camera install. Listeners bound to `:port` (all interfaces inside the LXC) since the container itself is the trust boundary.
    - `README.md` — full `pct create` command, provisioning steps, sanity checks, upgrade flow, do-not list.
- **ntfy container scaffold** (`app/lxc/ntfy/`):
    - `install.sh` — idempotent, pinned `.deb` with per-arch SHA256 verification (from upstream `checksums.txt`), preserves existing config on re-run, ships a `server.yml.homesec-default` marker so operators can diff their live config against the scaffold default.
    - `server.yml` — secure defaults: `auth-default-access: deny-all`, no signup, rate limits (60 burst, 10s replenish, 2000/day), attachment caps (1G total, 20M per file), JSON logs, `behind-proxy: false`, no web push keys.
    - `README.md` — full `pct create` command, first-time user setup (admin user + scoped backend user), phone setup, upgrade flow.
- **Documentation** (`docs/`):
    - `protect-api-notes.md` — reference for the UniFi Protect library choices (`unifi-protect` for Node, `pyunifiprotect` for Python).
    - `rtsp-endpoints.md` — per-camera RTSP table (to fill in post-install) and the VLAN 10 reachability note recommending LXC multi-homing (a second NIC with `tag=10`) over a pfSense hole-punch.
- **Versioning.** This changelog; the cameras section is tagged `cameras/v0.1.0` at the same commit as the repo-level `v0.1.0` tag.
- **Pinned upstream versions:**
    - `go2rtc v1.9.14` (released 2026-01-19)
    - `ntfy v2.21.0` (released 2026-03-30)

### Changed

- **Runtime migrated from Docker to Proxmox LXC** between the initial scaffold commit and the v0.1.0 tag. The original scaffold had a `docker-compose.yml` with `go2rtc` and `ntfy` services; it was deleted and replaced with one LXC per service (native systemd, no nesting, unprivileged). `go2rtc.yaml` listener binds changed from `127.0.0.1` to `:port` accordingly.

### Removed

- `app/docker-compose.yml` — superseded by the LXC scaffold.

### Not yet implemented

- `homesec-cameras-backend` (LXC 202) — event subscriber + alert dispatcher. Language deferred.
- `homesec-cameras-frontend` (LXC 203) — browser UI. Language deferred.
- Real RTSP stream keys and VLAN 10 IPs — requires physical camera install.

[Unreleased]: https://github.com/iamscott53/homesec/compare/cameras/v0.1.0...HEAD
[0.1.0]: https://github.com/iamscott53/homesec/releases/tag/cameras/v0.1.0
