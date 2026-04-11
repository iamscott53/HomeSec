# Camera RTSP endpoints

This file is the per-camera reference for everything stream-related: the VLAN 10 IP, the RTSP URL from UniFi Protect, and any per-camera notes. **Fill it in after the hardware install**, when the UNVR and cameras are physically up and reachable.

## ⚠️ VLAN 10 reachability — read this first

Cameras and the UNVR Instant sit on **VLAN 10**, which has **zero internet access and zero LAN reachability from VLAN 1** by default. This is the #1 trap when building this app:

> The LXC containers that need to talk to cameras (`homesec-cameras-go2rtc` and `homesec-cameras-backend`) cannot reach the UNVR at all unless they are physically attached to VLAN 10. The Proxmox host itself is irrelevant — what matters is the container's NICs.

You have two options. **Option A is strongly recommended.**

### Option A — Multi-homed LXC (recommended)

Give the LXC container a **second NIC** with `tag=10` on the same VLAN-aware bridge. This puts the container directly on VLAN 10 with its own IP there, alongside its VLAN 1 IP. No firewall rules needed, no routing gymnastics, and VLAN 10 stays fully internet-isolated.

Example `pct create` snippet (see `docs/proxmox-lxc-best-practices.md` for the full command):

```bash
--net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1   # VLAN 1 — serves frontend
--net1 name=eth1,bridge=vmbr0,tag=10,ip=dhcp,firewall=1  # VLAN 10 — talks to UNVR
```

The container sees both networks natively. No NAT, no routing, no extra rules. The Proxmox host's own networking is not involved in the VLAN 10 path.

Only the containers that genuinely need to read from the UNVR get the VLAN 10 NIC:

- ✅ `homesec-cameras-go2rtc` — pulls RTSP
- ✅ `homesec-cameras-backend` — subscribes to Protect WebSocket + fetches snapshots
- ❌ `homesec-cameras-ntfy` — does NOT need VLAN 10
- ❌ `homesec-cameras-frontend` — does NOT need VLAN 10

### Option B — Narrow pfSense rule (fallback, not recommended)

If for some reason you cannot multi-home a container, add a pfSense rule on the VLAN 1 interface:

- **Source:** the specific LXC container's VLAN 1 IP (a single host, never a subnet).
- **Destination:** the UNVR Instant IP on VLAN 10.
- **Destination ports:** TCP 443 (Protect API + WSS) and TCP 7441 (RTSP).
- **Action:** pass.

This works, but it punches a hole in the VLAN boundary. Multi-homing is cleaner because VLAN 10 traffic never touches VLAN 1 at all.

Do **not** allow VLAN 10 → VLAN 1 (in either option). Do **not** allow VLAN 10 → WAN ever. The flow is one-way: cameras-capable container → UNVR, full stop.

### What NOT to do

- Do not dual-home the **cameras themselves** onto VLAN 1. Cameras stay on VLAN 10, period.
- Do not allow VLAN 10 → internet "just for firmware updates." Update cameras through the UniFi Protect UI, which proxies updates through the UNVR and your management VLAN.
- Do not open port 443 on the WAN side for Protect. There is zero reason to expose the UNVR to the internet.
- Do not enable `nesting=1` on the cameras LXC containers to run Docker. If you find yourself wanting that, re-read `docs/proxmox-lxc-best-practices.md`.

## Camera RTSP table

Fill in after the install. Get each RTSP URL from **UniFi Protect → camera → Settings → Advanced → RTSP**. Enable the high-quality stream; disable the low stream unless you explicitly need it.

| # | Name          | Device              | VLAN 10 IP | RTSP URL |
|---|---------------|---------------------|------------|----------|
| 1 | doorbell      | G4 Doorbell Pro     | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 2 | front-left    | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 3 | front-right   | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 4 | front-center  | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 5 | rear-left     | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 6 | rear-right    | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |
| 7 | rear-center   | G5 Bullet           | TBD        | `rtsp://UNVR_IP:7441/STREAM_KEY` |

After filling these in, mirror the values into `../app/lxc/go2rtc/go2rtc.yaml` (replacing the `STREAM_KEY_PLACEHOLDER` lines) and then copy the updated config into the `homesec-cameras-go2rtc` LXC.

## Sanity checks post-install

Once the table is filled in and `homesec-cameras-go2rtc` is running, from inside the container:

- `ping UNVR_IP` — must succeed (proves the VLAN 10 NIC is up and VLAN 10 routing is sane).
- `curl -k https://UNVR_IP/` — must return the UniFi OS login page (proves port 443 is reachable on VLAN 10).
- `ffprobe rtsp://UNVR_IP:7441/<streamKey>` for one camera — must report a video stream (proves RTSP is reachable and credentials are not required because Protect RTSP tokens are embedded in the URL).

Then from any workstation on VLAN 1:

- Browse to `http://<go2rtc-container-ip>:1984/` — the go2rtc web UI should list each stream as `online`.

If any of those fail, the problem is almost always:

1. The `tag=10` NIC on the LXC wasn't added, or the bridge isn't VLAN-aware.
2. pfSense is blocking the container's VLAN 10 IP (check the VLAN 10 firewall logs).
3. The RTSP stream key in `go2rtc.yaml` is wrong or the stream is disabled in Protect.
