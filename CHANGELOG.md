# Changelog

All notable changes to HomeSec are tracked here. This file is the big-picture history for the whole repo. Each section that has its own app (currently `cameras/`, `docs/`, `rack/`) also keeps a scoped `CHANGELOG.md` in its own folder for narrower changes. Stub sections (`iot/`, `network-security/`, `nvr/`, `switch/`, `wifi/`) do not yet have their own changelogs — the repo-level entries here and their git tags are sufficient until they grow real content.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the repo adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Tag conventions:
- **Repo-level releases** use unscoped tags: `v0.1.0`, `v0.2.0`, ...
- **Per-section releases** use scoped tags: `cameras/v0.1.0`, `rack/v0.1.0`, ...
- Annotated tags only (`git tag -a`), never lightweight.

## [Unreleased]

### Added

- **Cameras detection stack.** Major expansion of the cameras section from a 4-LXC stub to a 5-LXC + 1-VM Frigate-based pipeline with facial recognition, license plate recognition, vehicle attribute extraction, cross-clip person clustering, and opt-in social enrichment. All local, no cloud, no subscriptions in the default configuration. See [`cameras/CHANGELOG.md`](./cameras/CHANGELOG.md) for the full section-scoped change list.
- **Cameras two-tier recording design.** Continuous 24/7 recording in day-level folders with 30-minute segments, plus a separate "Triggered Events" archive of motion-triggered clips with 60 seconds of pre-roll. Day-level protection: days with any triggers get `.protected`, days without get `.cleanup-eligible`. Hourly disk watchdog deletes eligible days first when disk pressure hits. One-shot "review this day" notification fires the first time a new date accumulates a trigger. Documented in `cameras/docs/recording-retention-design.md`; implementation landing with the analyzer code in a follow-up PR.
- **Cameras storage management design.** Full disk-pressure management for the cameras recording archive: threshold chain at 75% (warning + delete eligible days), 90% (critical), 95% (automatic quality downgrade). Four recording quality presets (High / Medium / Low / Lowest) with GPU-accelerated h264_nvenc re-encode per preset and a storage budget ladder (75 → 45 → 30 → 15 GB/day for 7 cameras). **Protected days are now inviolable under automation** — the earlier "delete oldest protected day at >95%" fallback has been removed. When eligible days are exhausted and disk pressure keeps climbing, the system fires a red urgent "recording will stop" notification every hour until the operator adds storage or downloads + deletes old days. **User-friendly download UX** via a new Storage page in the frontend: checkbox list of oldest days, one-click "Download selected as ZIP" over HTTPS (streaming `ZIP_STORED` via the analyzer's `StreamingResponse`), post-download "Delete from server?" modal, 10-minute download-hash confirmation window for deleting protected days. Optional SFTP fallback (chroot'd read-only, off by default). Manual quality preset override in Settings. Documented in `cameras/docs/storage-management-design.md`.
- **`docs/proxmox-vm-best-practices.md`** — cross-cutting standards for Proxmox VMs in HomeSec. LXC remains the default runtime; VMs are used only for narrow cases (Docker-only upstream images, heavy PCIe passthrough, non-Linux guests). Documents VMID numbering per section, PCIe + USB passthrough patterns, and the when-to-use-a-VM rubric.

### Changed

- **`docs/proxmox-lxc-best-practices.md`** — added a pointer at the top to the new VM best-practices doc. LXC is still the default; the pointer just makes the exception cases discoverable.
- **`docs/README.md`** — links the new VM best-practices doc.

### Policy decisions locked in

- **Python 3.12 for the cameras analyzer service.** First concrete language commitment in the repo. Driven by the Python-only open-source ecosystem for face recognition (InsightFace), Frigate's own developer community, and mature async MQTT / FastAPI / SQLModel support.
- **Frigate runs in a Proxmox VM (VM 210)**, not an LXC, to keep the "no Docker-in-LXC" rule intact.
- **Dual-accelerator camera AI:** Coral Edge TPU (24/7 object detection) + NVIDIA GPU (event-triggered face rec + ALPR OCR), both passed through to the same Frigate VM.
- **Auto-cluster every face forever.** Operator policy, legal posture documented in `cameras/docs/face-recognition-design.md`.
- **Two-tier cameras recording.** Continuous 24/7 (day-level protection, cleanup when space is low) + separate "Triggered Events" archive (60s pre-roll, kept 365 days). 30-minute segment length by default. Documented in `cameras/docs/recording-retention-design.md`.
- **Social enrichment defaults to the most restrictive mode.** Mode A (linked profiles) on; Mode B (manual reverse-search helper) off; Mode C (paid third-party API stub) off and unconfigured. No automated scraping of social media platforms, ever.
- **Version bump is mandatory on every merge to `main`.** Every `dev` → `main` merge MUST bump at least one semver component (repo-level `vX.Y.Z` tag plus any per-section tags for sections that changed). Patch bump for fixes-only merges, minor bump when any section gains new features, major bump for breaking changes. The operator is responsible for running the bump before clicking Merge. Documented in the Versioning section of the root README.

## [0.1.0] — 2026-04-11

First tagged release. Establishes the repo structure, lands the network installation spec, scaffolds the cameras LXC stack with pinned upstream dependencies, and documents the Proxmox LXC standards that every future section will follow. Nothing in this release is functional end-to-end — the cameras app backend and frontend are still deferred pending a language decision — but every non-code asset is in its final location.

### Added

- **Repo organization.** Eight top-level focus-area folders: `cameras/`, `docs/`, `iot/`, `network-security/`, `nvr/`, `rack/`, `switch/`, `wifi/`. Each has a `README.md` (stub for sections without an app yet). Kebab-case for multi-word names.
- **`rack/INSTALLATION-SPEC.md`** — the full home network + security installation spec verbatim: equipment list, VLAN architecture, camera placement, cable run schedule, rack layout, and low-voltage technician notes.
- **`docs/proxmox-lxc-best-practices.md`** — the cross-cutting standards every HomeSec section follows when running services: unprivileged containers, Debian 12 template, nesting off, VLAN-aware bridge + per-NIC tagging, naming / CTID convention per section, hardened systemd units, snapshot and backup policy, narrow internet egress, secrets handling, and a do-not list.
- **`cameras/` LXC scaffold** — one unprivileged Debian 12 LXC per service, native systemd, no Docker:
    - `cameras/app/lxc/README.md` — four-container layout overview (`homesec-cameras-go2rtc`, `homesec-cameras-ntfy`, future `homesec-cameras-backend`, future `homesec-cameras-frontend`).
    - `cameras/app/lxc/go2rtc/` — idempotent `install.sh` (pinned version, SHA256-verified download, dedicated unprivileged system user), hardened `go2rtc.service` systemd unit (full sandbox profile, empty `CapabilityBoundingSet`, narrow `SystemCallFilter`, explicit `ReadWritePaths`), `go2rtc.yaml` with 7 stream entries.
    - `cameras/app/lxc/ntfy/` — idempotent `install.sh` (pinned `.deb` from GitHub releases with SHA256 verify), `server.yml` with secure defaults (`auth-default-access: deny-all`, rate limits, attachment caps, `enable-signup: false`).
    - `cameras/docs/protect-api-notes.md` — UniFi Protect library options reference.
    - `cameras/docs/rtsp-endpoints.md` — per-camera RTSP table (to fill in post-install) plus the VLAN 10 reachability gotcha with LXC multi-homing guidance.
- **`.gitignore`** — wide-net secret/credential exclusions, camera recording/snapshot exclusions, pfSense config backup exclusions, language/build artifact exclusions for Node.js and Python.
- **Versioning infrastructure** — this file, per-section changelogs for substantive sections (`cameras/`, `docs/`, `rack/`), and annotated semver git tags (repo-level + scoped per-section).
- **Pinned upstream dependencies** (cameras section):
    - go2rtc `v1.9.14` (released 2026-01-19). SHA256 verified for `linux_amd64` and `linux_arm64` assets.
    - ntfy `v2.21.0` (released 2026-03-30). SHA256 verified for `linux_amd64.deb` and `linux_arm64.deb` from the upstream `checksums.txt`.

### Changed

- **Cameras runtime.** Originally scaffolded for Docker + docker-compose; switched to Proxmox LXC (one LXC per service, unprivileged, native systemd) to match the host environment and the "no Docker-in-LXC" rule in the best-practices doc. The `go2rtc.yaml` listener binds changed from `127.0.0.1:port` (Docker host-network assumption) to `:port` (the LXC container is itself the trust boundary).

### Removed

- `cameras/app/docker-compose.yml` — replaced by the LXC scaffold.

### Security

- Two full security audits (one per commit before this tag). No secrets, keys, tokens, PEM blocks, or JWTs in any tracked file. The street address from the user-provided installation spec is redacted. All IPs in the repo are RFC1918 documentation examples. Install scripts use `set -euo pipefail`, quoted variables, `sha256sum --check --strict`, `curl --fail --location`, `mktemp` + trap cleanup, and refuse to run if pinning placeholders have not been filled in. The go2rtc systemd unit ships with a full sandbox profile.

### Known limitations (not blockers for v0.1.0)

- **Cameras backend / frontend** are not yet scaffolded — language pick (Node/TS vs Python) is deferred.
- **Real RTSP URLs and VLAN 10 IPs** are placeholders until cameras are physically installed.
- **No CI** yet — nothing to build or test.
- **No UPS** in the rack layout — Section 6 of the installation spec reserves 7U-9U for future UPS, but it's not on the BOM.

[Unreleased]: https://github.com/iamscott53/homesec/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/iamscott53/homesec/releases/tag/v0.1.0
