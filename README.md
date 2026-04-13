# HomeSec

Privacy-oriented home security and home networking for a new-construction home in Jacksonville, FL. Hardware, configuration, and the small apps that run on top of it all live in one repo, organized by focus area.

## Hard requirements

- **All local storage.** No cloud recording, no cloud event logs, no cloud anything.
- **Zero subscriptions.** If it needs a monthly bill to work, it's out.
- **No Chinese-manufactured hardware.** Cameras, NVR, switch, firewall, rack — all US-headquartered vendors.
- **Privacy-oriented by default.** VLAN 10 (cameras) has no internet access at all. Guest WiFi has no LAN access at all.
- **Proxmox LXC, not Docker.** Every app in this repo runs as one or more unprivileged LXC containers on Proxmox — one LXC per service, natively via systemd, no Docker-in-LXC. See [`docs/proxmox-lxc-best-practices.md`](./docs/proxmox-lxc-best-practices.md) for the standards every section follows.

## Sections

Each top-level folder is a focus area. Most will grow a small app over time; today most are documentation stubs.

| Section | What's in it |
|---|---|
| [`cameras/`](./cameras) | UniFi Protect live-view grid + AI detection alerts (6x G5 Bullet + G4 Doorbell Pro, UNVR Instant). |
| [`network-security/`](./network-security) | pfSense on a Netgate 2100, four-VLAN architecture, firewall rules. |
| [`switch/`](./switch) | Ubiquiti USW-Lite-16-PoE — port map, VLAN tagging, PoE budget. |
| [`nvr/`](./nvr) | UNVR Instant + WD Purple 4TB — disk health, retention, backups. |
| [`iot/`](./iot) | VLAN 20 smart-home devices, firmware tracking, rogue-traffic detection. |
| [`wifi/`](./wifi) | Main WiFi security (WPA3, SSID hardening, rogue-AP detection) and the VLAN 30 guest network. |
| [`rack/`](./rack) | Physical install: 9U wall-mount rack, cable runs, low-voltage tech notes. |
| [`docs/`](./docs) | Cross-cutting documentation that spans multiple sections. |

## Source of truth: installation spec

The canonical reference for everything hardware, cabling, VLAN, and rack-layout lives in one place:

**→ [`rack/INSTALLATION-SPEC.md`](./rack/INSTALLATION-SPEC.md)**

Equipment list, signal path, VLAN architecture, camera placement (7 cameras, overlapping 360° coverage), full cable run schedule (14 runs), rack layout, and technician notes. Start there.

## Branch policy

- `main` — stable, reviewed.
- `dev` — integration branch. All feature branches merge into `dev` before `dev` merges into `main`.
- `claude/*` and other feature branches — work branches, PR target is always `dev`, never `main`.

## Versioning

HomeSec uses [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) and [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) at two granularities:

- **Repo-wide** releases are tracked in [`CHANGELOG.md`](./CHANGELOG.md) and tagged with unscoped tags like `v0.1.0`.
- **Per-section** releases are tracked in each substantive section's own `CHANGELOG.md` (currently [`cameras/`](./cameras/CHANGELOG.md), [`docs/`](./docs/CHANGELOG.md), [`rack/`](./rack/CHANGELOG.md)) and tagged with scoped tags like `cameras/v0.1.0`. Stub sections get a scoped tag but no changelog until they grow real content.

Tags are always annotated (`git tag -a`), never lightweight. The current pinned upstream dependencies for each section's apps are recorded in that section's CHANGELOG — keep them in sync when bumping versions in install scripts.
