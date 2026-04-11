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

### Version bump is mandatory on every merge to `main`

Every merge from `dev` into `main` **must** include a version bump. This is a hard rule:

- **Patch bump** (`v0.1.0 → v0.1.1`) when the merge is fixes-only: bug fixes, doc typos, install-script tweaks, `.gitignore` cleanups.
- **Minor bump** (`v0.1.0 → v0.2.0`) when any section gains new features or new substantive documentation: adding a new component, a new design doc, a new LXC/VM scaffold, a new `install.sh`, a new piece of functionality in an existing component.
- **Major bump** (`v0.1.0 → v1.0.0`) when there's a breaking change: removing a component, renaming a section in a way that breaks existing deployments, changing the VLAN layout, incompatible schema migrations in the analyzer DB.

The bump applies to **both** the repo-level tag AND any per-section scoped tag for sections whose content changed in that merge. Unchanged sections keep their existing scoped tag. In practice:

1. Before clicking **Merge** on the `dev → main` PR, pull `dev` locally.
2. Decide the bump level (patch / minor / major).
3. Update every `CHANGELOG.md` that had an `[Unreleased]` section: move those entries into a new `[X.Y.Z] — YYYY-MM-DD` section and add a fresh empty `[Unreleased]` header at the top.
4. Commit the changelog updates on `dev` with a message like `chore: bump repo v0.1.0 → v0.2.0, cameras v0.1.0 → v0.2.0`.
5. Push `dev`, wait for the PR auto-update, then merge to `main`.
6. Immediately after the merge lands on `main`, create the annotated tags pointing at the merge commit:
   ```bash
   git checkout main && git pull
   git tag -a v0.2.0 -m "HomeSec v0.2.0 — see CHANGELOG.md"
   git tag -a cameras/v0.2.0 -m "cameras v0.2.0 — see cameras/CHANGELOG.md"
   # ...any other per-section tags for sections that changed
   git push origin --tags
   ```

**An unbumped merge into `main` is a mistake that must be corrected by the next commit**: add the missing version bump as a follow-up commit and tag accordingly. Do not rewrite history on `main`.
