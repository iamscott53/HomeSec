# homesec-cameras-frontend (LXC 204)

Proxmox LXC that will serve the **HomeSec cameras operator UI** — a LAN-only web app for browsing events, enrolling people, reviewing auto-generated face clusters, browsing plate and vehicle history, and toggling the social enrichment features.

- **Suggested CTID:** 204
- **Hostname:** `homesec-cameras-frontend`
- **Template:** Debian 12 standard
- **Unprivileged:** yes
- **Nesting:** no
- **NICs:** one — `eth0` on VLAN 1 only
- **Resources:** 1 core, 512 MB RAM, 4 GB disk

## Status: placeholder only

Nothing is scaffolded here yet beyond this README. The frontend implementation depends on the analyzer's REST API being defined, and the analyzer itself is a scaffold placeholder in v0.1. Implementation lands in a follow-up PR after the analyzer is at least partially running.

## What the frontend will do (per the design docs)

- **Live grid** — thumbnails of all 7 cameras, WebRTC streams via go2rtc (existing scaffold).
- **Event browser** — chronological list of Frigate events with faces, plates, and vehicle annotations. Click through to play the clip (served by Frigate's `/api/events/<id>/clip.mp4`).
- **People list** — shows enrolled people + `Unknown #N` clusters sorted by sighting count. Click a person to see all events, all clips, the best face thumbnail, first/last seen, and any linked social profiles (Mode A enrichment). See [`../../docs/face-recognition-design.md`](../../docs/face-recognition-design.md).
- **Enrollment modal** — attach a name, social handles, and notes to a cluster. Merge / split clusters that were wrongly fused or split.
- **Plates list** — sorted by sighting count or last-seen, with click-through to the sighting history and associated vehicle attributes.
- **Vehicles list** — once the vehicle-attribute service is running, shows make/model/color with sighting count and associated plates. See [`../../docs/vehicle-attributes-design.md`](../../docs/vehicle-attributes-design.md).
- **Reverse-search helper** (Mode B, off by default) — per-face button that opens Google Lens / Bing Visual Search in a new browser tab with the face crop pre-uploaded. Operator-initiated, per-face, no automation. See [`../../docs/social-enrichment-design.md`](../../docs/social-enrichment-design.md).
- **Third-party face-search panel** (Mode C, off by default and unconfigured) — only visible if the operator has explicitly enabled and configured it.
- **Admin / settings** — dedup windows, quiet hours, enrichment mode toggles, audit log viewer.

## Planned tech stack

Not yet committed — picking will happen when implementation starts.

| Area | Candidates | Notes |
|---|---|---|
| Framework | React + Vite OR SvelteKit OR plain HTMX | Lean toward React + Vite for familiarity |
| UI library | Tailwind CSS + Radix UI, or shadcn/ui | Modern, maintainable |
| Live video | go2rtc's WebRTC snippet | Already available from go2rtc LXC |
| API client | Generated from the analyzer's FastAPI OpenAPI schema | `openapi-typescript-codegen` or similar |
| Web server in LXC | `nginx` serving static build + reverse-proxying API to analyzer | Simple, well-understood |
| Package manager | `pnpm` if React/Svelte, none if HTMX | |
| Build output | Static files under `/var/www/homesec-cameras-frontend/` | |

The frontend is a **LAN-only** service. No auth in v0 beyond pfSense-enforced LAN isolation. For remote access use Tailscale or WireGuard back into the LAN — **never** expose this port to WAN.

## Files that will eventually live here

| File | Purpose |
|---|---|
| `install.sh` | Provision nginx inside the LXC, deploy a build artifact, wire systemd. |
| `nginx.conf` | Minimal nginx config: serve static, reverse-proxy `/api/` to the analyzer. |
| `homesec-cameras-frontend.service` | Placeholder; nginx's own systemd unit handles runtime. |
| `src/` | Frontend source code. |
| `dist/` or `build/` | Compiled static assets. Build output goes in `.gitignore`. |

## Provisioning (once files exist)

```bash
pct create 204 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homesec-cameras-frontend \
  --unprivileged 1 \
  --features nesting=0,keyctl=0 \
  --cores 1 \
  --memory 512 \
  --swap 0 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1 \
  --onboot 1 \
  --start 1 \
  --ssh-public-keys /root/.ssh/authorized_keys
```

## Do not

- Do not expose this LXC's HTTP port to WAN. LAN-only, always.
- Do not build auth into the frontend beyond what's needed for basic per-user audit (operator identifier for the enrichment audit log). pfSense + VPN handles perimeter.
- Do not add client-side face search or inference. All ML runs in the Frigate VM or the analyzer.
- Do not commit build artifacts (`dist/`, `build/`, `node_modules/`) to this repo. The `.gitignore` already covers these patterns.
