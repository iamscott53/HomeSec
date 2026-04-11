# Changelog — docs

Scoped changelog for the cross-cutting `docs/` section. Repo-wide history is in [`../CHANGELOG.md`](../CHANGELOG.md).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html). Tag convention: `docs/vX.Y.Z`.

## [Unreleased]

(nothing yet)

## [0.1.0] — 2026-04-11

First tagged release of the `docs/` section. The Proxmox LXC best-practices doc is now the operational standard for every HomeSec section that grows an app.

### Added

- **`README.md`** — section index and a pointer to the canonical hardware/network reference in `../rack/INSTALLATION-SPEC.md`.
- **`proxmox-lxc-best-practices.md`** — the cross-cutting runtime standards every HomeSec section follows:
    - Container standards: unprivileged, Debian 12 standard template, nesting off, keyctl off, swap 0, default AppArmor profile, SSH keys only.
    - Naming (`homesec-<section>-<service>`) and CTID ranges per section (cameras 200-219, network-security 220-239, switch 240-259, nvr 260-279, iot 280-299, wifi 300-319, infra 320-399).
    - Networking: VLAN-aware Linux bridge (`bridge-vlan-aware yes`, `bridge-vids 1 10 20 30`), per-NIC VLAN tagging, static IPs via pfSense DHCP reservations.
    - Resource limits: sensible defaults for each cameras container, swap disabled.
    - Service standards: dedicated system user per service, systemd with full hardening directives, journald logging, pinned upstream releases with checksum verification.
    - Secrets handling (secrets manager, never git).
    - Backup: snapshot-before-every-change, daily backups with retention, containers treated as rebuildable from the repo.
    - Internet egress: revoke WAN per container after install.
    - Do-not list: no Docker-in-LXC, no privileged containers, no AppArmor disable, no WAN exposure, no `curl | bash`, no `:latest`.
- **Versioning.** This changelog; the docs section is tagged `docs/v0.1.0` at the same commit as the repo-level `v0.1.0` tag.

### Not yet present (future expansion)

- Architecture overview spanning all sections.
- Threat model.
- Operator runbooks (incident response, snapshot restore, credential rotation).
- Glossary (UniFi / pfSense / Proxmox / networking terminology).

[Unreleased]: https://github.com/iamscott53/homesec/compare/docs/v0.1.0...HEAD
[0.1.0]: https://github.com/iamscott53/homesec/releases/tag/docs/v0.1.0
