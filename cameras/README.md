# cameras

Local, privacy-oriented camera app for the seven-camera Ubiquiti Protect deployment: 6x G5 Bullet (2K, PoE, on-device AI detection) + 1x G4 Doorbell Pro. All cameras and the UNVR Instant live on VLAN 10 with **zero internet access** — every byte of footage, metadata, and event data stays on the LAN.

## What this app does

1. **AI alerts** — subscribes to the UniFi Protect event stream on the UNVR Instant, filters for AI detections (person, vehicle, package, animal), and POSTs each event to a self-hosted notification service so you get a push on your phone.
2. **Live streaming** — serves a grid of low-latency tiles (one per camera) in a browser on the LAN.

Everything runs on your network. No cloud. No subscriptions. No phoning home.

## Runtime: Proxmox LXC (not Docker)

HomeSec runs on **Proxmox**, and every service in this app runs in its own **unprivileged LXC container** — one LXC per service. No Docker, no docker-compose, no nesting. Services run natively via systemd.

See the cross-cutting standards doc before provisioning any container:

**→ [`../docs/proxmox-lxc-best-practices.md`](../docs/proxmox-lxc-best-practices.md)**

### The four containers

| Container | CTID | Role | VLANs | Scaffolded today? |
|-----------|------|------|-------|--------------------|
| `homesec-cameras-go2rtc` | 200 | RTSP → WebRTC re-mux. Pulls from UNVR, serves to frontend. | VLAN 1 + VLAN 10 | ✅ |
| `homesec-cameras-ntfy` | 201 | Self-hosted push notifications. Receives alerts, pushes to phone. | VLAN 1 | ✅ |
| `homesec-cameras-backend` | 202 | Subscribes to Protect WS, filters AI events, POSTs to ntfy. | VLAN 1 + VLAN 10 | ❌ language TBD |
| `homesec-cameras-frontend` | 203 | LAN-only web UI: grid + event feed. | VLAN 1 | ❌ language TBD |

All provisioning details, install scripts, systemd units, and container-specific READMEs live under [`app/lxc/`](./app/lxc).

## Architecture

```
┌────────────────────┐                VLAN 10
│ UNVR Instant       │    (no internet, local only)
│  UniFi Protect     │
└─────────┬──────────┘
          │ RTSP (port 7441) + WSS (port 443) on VLAN 10
          │
          ├────────────────────────────┐
          │                            │
          ▼                            ▼
┌─────────────────────────┐  ┌──────────────────────────┐
│ homesec-cameras-go2rtc  │  │ homesec-cameras-backend  │
│ (LXC 200)               │  │ (LXC 202) — lang TBD     │
│ VLAN 1 + VLAN 10        │  │ VLAN 1 + VLAN 10         │
└────────────┬────────────┘  └─────────────┬────────────┘
             │ WebRTC                      │ HTTP POST
             │ (VLAN 1)                    │ (VLAN 1)
             ▼                             ▼
┌─────────────────────────┐  ┌──────────────────────────┐
│ homesec-cameras-        │  │ homesec-cameras-ntfy     │
│ frontend                │  │ (LXC 201)                │
│ (LXC 203) — lang TBD    │  │ VLAN 1                   │
│ VLAN 1                  │  └─────────────┬────────────┘
└─────────────────────────┘                │ push
                                           ▼
                                       📱 phone
```

## What's scaffolded today

- [`app/lxc/README.md`](./app/lxc/README.md) — LXC layout overview.
- [`app/lxc/go2rtc/`](./app/lxc/go2rtc) — `install.sh`, `go2rtc.service` (hardened systemd unit), `go2rtc.yaml` (7 streams, placeholder URLs), container `README.md`.
- [`app/lxc/ntfy/`](./app/lxc/ntfy) — `install.sh`, `server.yml` (secure defaults, `auth-default-access: deny-all`), container `README.md`.
- [`docs/protect-api-notes.md`](./docs/protect-api-notes.md) — library options for talking to UniFi Protect.
- [`docs/rtsp-endpoints.md`](./docs/rtsp-endpoints.md) — per-camera RTSP table + the critical VLAN 10 reachability gotcha.

## What's NOT scaffolded yet

- **`homesec-cameras-backend`** — language is deferred (Node/TypeScript with `unifi-protect` or Python with `pyunifiprotect`). No code, no LXC directory, no install script yet.
- **`homesec-cameras-frontend`** — same.
- **Real RTSP URLs** — cameras aren't installed yet; fill these in from the UniFi Protect web UI post-install.

## Provisioning order (once hardware is up)

1. Read `docs/proxmox-lxc-best-practices.md` top to bottom.
2. On the Proxmox host, create the VLAN-aware bridge if it doesn't exist (see the best-practices doc for the `/etc/network/interfaces` stanza).
3. Provision `homesec-cameras-go2rtc` per `app/lxc/go2rtc/README.md`.
4. Provision `homesec-cameras-ntfy` per `app/lxc/ntfy/README.md`.
5. Fill in RTSP URLs from UniFi Protect into `/etc/go2rtc/go2rtc.yaml` inside the go2rtc container.
6. Snapshot both containers (`pct snapshot <ctid> post-install`).
7. Pick a backend language, then come back and scaffold containers 202 and 203.

## Hard constraint: VLAN 10 reachability

Cameras and the UNVR have no internet. Containers that need to talk to them (`homesec-cameras-go2rtc` and the eventual `homesec-cameras-backend`) are **multi-homed** — they have a second LXC NIC with `tag=10`. See [`docs/rtsp-endpoints.md`](./docs/rtsp-endpoints.md) and the best-practices doc for the exact `pct create` flags and the reasoning behind them.
