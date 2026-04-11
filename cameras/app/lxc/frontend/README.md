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
- **Storage page** — the central disk management UX. See [`../../docs/storage-management-design.md`](../../docs/storage-management-design.md) for the full design.
    - Header with current disk used% (color-coded: green < 75, yellow 75-90, orange 90-95, red > 95), days free of `.cleanup-eligible` (fallback capacity remaining), current quality preset, and current recording state.
    - Sortable, paginated day list sorted oldest-first by default. Per-row: checkbox, date, size, camera count, status (🟢 eligible / 🟡 protected), trigger count, preview link.
    - **"Download selected as ZIP"** button — streams a zip of the selected day directories over HTTPS. Calls `POST /api/storage/download-prepare` first to show an estimated size + duration, then `POST /api/storage/download` which the analyzer streams directly to the browser using `StreamingResponse`.
    - **"Delete selected"** button — greyed out unless the selection is either all-`.cleanup-eligible` or the operator has recently downloaded those days (within a 10-minute window, verified by matching a download hash in the post-download modal).
    - **Post-download modal** — after a successful download finishes, prompts: _"You downloaded these days. Delete from the server now?"_ with three options: Yes / No / Let me verify first. Deleting via this path is the only automated route to removing a `.protected` day.
    - **Storage audit log viewer** — paginated view of every download, delete, quality change, and watchdog action, from the analyzer's `storage_audit` table.
- **Settings → Cameras → Recording quality** — radio group of High / Medium / Low / Lowest presets. Changing this POSTs to `PUT /api/storage/quality-preset`, which swaps the Frigate config symlink and restarts the Frigate container. Also exposes an "Auto-downgrade on disk pressure" toggle (default on) and a link to the preset change history. Full preset details in [`../../docs/storage-management-design.md`](../../docs/storage-management-design.md).
- **Settings → Cameras → other toggles** — dedup windows, quiet hours, social enrichment mode toggles (Mode B and Mode C), audit log viewer.

### Critical UX rules for the Storage page

1. **Never auto-delete** a `.protected` day. The UI must make it impossible to delete a protected day without first downloading it and confirming via the post-download modal.
2. **Always show the recording-will-stop banner** if the analyzer reports that state. Red, sticky, across every page — not just the Storage page. It must feel like an emergency because it is.
3. **Never compress video** when zipping for download (`ZIP_STORED`, not `ZIP_DEFLATED`). Video files are already compressed and re-compressing wastes huge amounts of CPU for ~0% savings.
4. **Never delete a day the user just downloaded** without an explicit "Yes, delete them" click. The post-download modal is a hard gate.

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
