# Changelog — cameras

Scoped changelog for the `cameras/` section only. Repo-wide history is in [`../CHANGELOG.md`](../CHANGELOG.md).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html). Tag convention: `cameras/vX.Y.Z`.

## [Unreleased]

(nothing yet)

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
