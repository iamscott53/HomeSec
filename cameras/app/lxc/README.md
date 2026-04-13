# cameras/app/lxc — Proxmox LXC layout for the cameras app

The cameras app runs as **one LXC per service** on Proxmox. This is Proxmox best practice: separate containers snapshot, back up, upgrade, and rollback independently, and a compromise in one service cannot move laterally into another.

All four containers are unprivileged Debian 12 LXCs. None of them run Docker. Services run directly via systemd inside each container.

See also: [`../../../docs/proxmox-lxc-best-practices.md`](../../../docs/proxmox-lxc-best-practices.md) — cross-cutting LXC standards for every HomeSec section.

## The four cameras containers

| Container | CTID (suggested) | Purpose | VLANs | Scaffolded today? |
|-----------|------------------|---------|-------|--------------------|
| `homesec-cameras-go2rtc` | 200 | RTSP → WebRTC/HLS re-mux. Pulls from the UNVR, serves WebRTC to the frontend. | VLAN 1 (serve) + VLAN 10 (pull RTSP) | ✅ yes — see [`go2rtc/`](./go2rtc) |
| `homesec-cameras-ntfy` | 201 | Self-hosted push notification server. Receives AI alerts from the backend, pushes to your phone via the ntfy mobile app. | VLAN 1 only | ✅ yes — see [`ntfy/`](./ntfy) |
| `homesec-cameras-backend` | 202 | Subscribes to the UniFi Protect WebSocket event stream, filters AI events (person/vehicle/package/animal), POSTs to ntfy. Language deferred (Node/TS or Python). | VLAN 1 (egress to ntfy) + VLAN 10 (Protect API) | ❌ not yet — language pick pending |
| `homesec-cameras-frontend` | 203 | LAN-only web UI: 7-tile grid + event feed. Consumes WebRTC from go2rtc and event data from the backend. | VLAN 1 only | ❌ not yet — language pick pending |

The CTIDs are suggestions following the numbering convention in the Proxmox best-practices doc (cameras = 200–219). Adjust if they collide with your existing containers.

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

## How provisioning works

For each container that has a directory in here (e.g. `go2rtc/`, `ntfy/`):

1. Provision a fresh unprivileged Debian 12 LXC on Proxmox following `docs/proxmox-lxc-best-practices.md`.
2. Attach the NICs it needs (VLAN 1 always; VLAN 10 only for `go2rtc` and `backend`).
3. Start the container, log in as root.
4. Copy the contents of this directory into the container (`scp`, `pct push`, or mount a shared dir).
5. Run `./install.sh` inside the container.
6. Edit the config file (`/etc/go2rtc/go2rtc.yaml`, `/etc/ntfy/server.yml`, etc.) with real values — see each container's README for what to fill in.
7. `systemctl start <service>` and check `systemctl status <service>` + `journalctl -u <service>`.

No containers get internet egress they don't strictly need. `go2rtc` and `backend` need temporary internet only during install (to pull binaries); shut that down via pfSense rules afterward if you want to be strict.

## What's NOT here

- No Terraform, no Ansible, no cloud-init — overkill for 4 containers you'll provision once.
- No Proxmox-API-based bootstrap script — `pct create` from the Proxmox shell is a couple of lines, documented in the best-practices doc.
- No Docker. Do not enable nesting on these containers.
