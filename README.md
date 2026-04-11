# HomeSec

Privacy-oriented home security and home networking for a new-construction home in Jacksonville, FL. Hardware, configuration, and the small apps that run on top of it all live in one repo, organized by focus area.

## Hard requirements

- **All local storage.** No cloud recording, no cloud event logs, no cloud anything.
- **Zero subscriptions.** If it needs a monthly bill to work, it's out.
- **No Chinese-manufactured hardware.** Cameras, NVR, switch, firewall, rack — all US-headquartered vendors.
- **Privacy-oriented by default.** VLAN 10 (cameras) has no internet access at all. Guest WiFi has no LAN access at all.

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
