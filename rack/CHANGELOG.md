# Changelog — rack

Scoped changelog for the `rack/` section (physical install documentation and the network installation spec). Repo-wide history is in [`../CHANGELOG.md`](../CHANGELOG.md).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html). Tag convention: `rack/vX.Y.Z`.

## [Unreleased]

(nothing yet)

## [0.1.0] — 2026-04-11

First tagged release of the `rack/` section. The installation spec is now the canonical hardware / network reference for the whole repo, and the physical-install index README points to it.

### Added

- **`README.md`** — physical install index; points to the installation spec as the source of truth for hardware and cable runs.
- **`INSTALLATION-SPEC.md`** — the full `HOME NETWORK & SECURITY SYSTEM — INSTALLATION SPECIFICATION` document, committed verbatim from the user's source, covering:
    1. Equipment and shopping list (all US-headquartered vendors: Ubiquiti, Netgate, Eaton/Tripp Lite, Western Digital; zero subscriptions; zero Chinese-manufactured hardware).
    2. Network signal path (Comcast NID → modem → Netgate 2100 → USW-Lite-16-PoE → NVR and endpoints).
    3. VLAN architecture: VLAN 1 management/personal, VLAN 10 cameras (NO internet), VLAN 20 IoT, VLAN 30 guest WiFi.
    4. Camera placement for 360° coverage with 7 devices (4 front, 3 rear).
    5. Cable run schedule (14 runs: 9 required + 5 optional, all Cat6a with run numbers for labeling).
    6. Rack layout (Tripp Lite SRW9U 9U wall-mount, patch panel, firewall, switch, NVR, modem, power strip, reserved expansion U's).
    7. Technician notes (Cat6a-only, weatherproofing, labeling, cable testing, service loops).
- **Versioning.** This changelog; the rack section is tagged `rack/v0.1.0` at the same commit as the repo-level `v0.1.0` tag.

### Security

- Street address redacted from the spec committed here. The tracked content contains the general location (Jacksonville, FL) and the building specifics (single-story new construction, 2,264 SF, 4 bed / 3 bath, 2-car garage) but not the house number or street name.

### Not yet reflected in the spec (future revisions may add)

- UPS in the rack layout (Section 6 reserves U7-U9 for future expansion, but no specific UPS is on the BOM yet).
- Dedicated Proxmox host in the rack inventory (the server that runs the HomeSec LXC containers).
- Labor cost lines once actual quotes come in.
- Post-install photos and labeled patch-panel diagram.

[Unreleased]: https://github.com/iamscott53/homesec/compare/rack/v0.1.0...HEAD
[0.1.0]: https://github.com/iamscott53/homesec/releases/tag/rack/v0.1.0
