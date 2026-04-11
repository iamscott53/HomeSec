# cameras/app/lxc — Proxmox LXC containers for the cameras section

This directory holds the **LXC** containers for the cameras section. There is also **one VM** for Frigate specifically — see [`../vm/README.md`](../vm/README.md) for why and how.

All LXCs here are unprivileged Debian 12 containers, no nesting, native systemd. No Docker. See [`../../../docs/proxmox-lxc-best-practices.md`](../../../docs/proxmox-lxc-best-practices.md) for the cross-cutting LXC standards and [`../../README.md`](../../README.md) for the overall cameras architecture.

## The five LXC containers

| Container | CTID | Purpose | VLANs | Scaffolded today? |
|-----------|------|---------|-------|--------------------|
| `homesec-cameras-go2rtc`   | 200 | RTSP pass-through from UNVR (VLAN 10) to Frigate (VLAN 1). | VLAN 1 + VLAN 10 | ✅ [`go2rtc/`](./go2rtc) |
| `homesec-cameras-ntfy`     | 201 | Self-hosted push notifications. | VLAN 1 | ✅ [`ntfy/`](./ntfy) |
| `homesec-cameras-mqtt`     | 202 | Mosquitto broker — central event bus between Frigate and the analyzer. | VLAN 1 | ✅ [`mqtt/`](./mqtt) |
| `homesec-cameras-analyzer` | 203 | Python service: cross-clip face clustering, plate history, vehicle attributes, alerts, social enrichment, REST API. CPU-only. | VLAN 1 | 🟡 [`analyzer/`](./analyzer) — scaffold only; language locked in; code deferred |
| `homesec-cameras-frontend` | 204 | LAN-only web UI. | VLAN 1 | 🟡 [`frontend/`](./frontend) — placeholder only |

The CTIDs follow the numbering convention in the cross-cutting best-practices doc (cameras = 200–219). Adjust if they collide with your existing containers.

**Not here — lives in the VM directory:**

| Component | Runtime | Location |
|---|---|---|
| `homesec-cameras-frigate` (detection + face rec + ALPR) | VM 210 | [`../vm/frigate/`](../vm/frigate) |

Frigate needs Docker + NVIDIA GPU + Coral USB passthrough, which all fit cleanly in a Proxmox VM but would require `nesting=1` and complex device bind-mounts in an LXC. VM is the right tool for it.

## Architecture

For the full event-flow diagram see [`../../README.md`](../../README.md) or [`../../docs/detection-stack-overview.md`](../../docs/detection-stack-overview.md). Short version:

```
UNVR (VLAN 10)
   │
   ▼
homesec-cameras-go2rtc  ──RTSP──►  homesec-cameras-frigate (VM 210, GPU+Coral)
                                         │
                                         ├── MQTT publish ──► homesec-cameras-mqtt (LXC 202)
                                         │                         │
                                         │                         ▼
                                         │                   homesec-cameras-analyzer (LXC 203)
                                         │                         │
                                         └── REST API (on demand) ─┤
                                                                   │
                                                                   ├── POST ──► homesec-cameras-ntfy (LXC 201) ──► 📱
                                                                   │
                                                                   └── REST ──► homesec-cameras-frontend (LXC 204, LAN-only)
```

The cameras section is **one VLAN-10-aware component** (go2rtc) + **four VLAN-1 LXCs** + **one VLAN-1 VM**. That's the entire cameras detection stack.

## How provisioning works

For each LXC with a directory here (`go2rtc/`, `ntfy/`, `mqtt/`, eventually `analyzer/` and `frontend/`):

1. Provision a fresh unprivileged Debian 12 LXC on Proxmox following [`../../../docs/proxmox-lxc-best-practices.md`](../../../docs/proxmox-lxc-best-practices.md).
2. Attach the NICs it needs (VLAN 1 always; VLAN 10 only for `go2rtc`).
3. Start the container, log in as root.
4. Copy the contents of this directory into the container (`pct push` or `scp`).
5. Run `./install.sh` inside the container.
6. Edit the config file with real values — see each container's README.
7. `systemctl start <service>` and check `systemctl status` + `journalctl -u <service>`.

For the Frigate VM, provisioning is **different** — see [`../vm/frigate/README.md`](../vm/frigate/README.md) for the `qm create` flow.

No containers get internet egress they don't strictly need. Most need it only during install (apt + GitHub release downloads). Shut that down via pfSense rules afterward if you want to be strict. See each container's README for the egress notes.

## What's NOT here

- No Terraform, no Ansible, no cloud-init — overkill for 5 containers you'll provision once each.
- No Proxmox-API-based bootstrap script — `pct create` from the Proxmox shell is a few lines and is documented in the LXC best-practices doc.
- No Docker. Do not enable nesting on these containers.
- No Frigate. Frigate is in the VM directory — see above.
- No GPU passthrough into any LXC. The GPU lives in the Frigate VM only.
