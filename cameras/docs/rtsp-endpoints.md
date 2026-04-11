# Camera RTSP endpoints

This file is the per-camera reference for everything stream-related: the VLAN 10 IP, the RTSP URL from UniFi Protect, and any per-camera notes. **Fill it in after the hardware install**, when the UNVR and cameras are physically up and reachable.

## ⚠️ VLAN 10 reachability — read this first

Cameras and the UNVR Instant sit on **VLAN 10**, which has **zero internet access and zero LAN reachability from VLAN 1** by default. This is the #1 trap when building this app:

> Your dev/run host (where docker-compose runs) is almost certainly on VLAN 1, so it cannot reach `UNVR_IP` at all without a firewall rule.

You have two options:

### Option A — Multi-homed host (recommended)

Put a physical NIC or tagged sub-interface of the app host directly on VLAN 10. The host ends up with an IP on both VLAN 1 (for management, updates, etc.) and VLAN 10 (for Protect + RTSP). No firewall rules needed, no routing gymnastics, and VLAN 10 stays internet-isolated.

### Option B — Narrow pfSense rule

On pfSense, add a firewall rule on the VLAN 1 interface:

- **Source:** the app host's VLAN 1 IP (a single host, not the whole subnet).
- **Destination:** the UNVR Instant IP on VLAN 10.
- **Destination ports:** TCP 443 (Protect API + WebSocket) and TCP 7441 (RTSP).
- **Action:** pass.

Do **not** allow VLAN 10 → VLAN 1, and do **not** allow VLAN 10 → WAN. The rule is unidirectional from the app host to the UNVR only. Everything else on VLAN 10 stays offline.

### What NOT to do

- Do not dual-home the cameras themselves onto VLAN 1. Cameras stay on VLAN 10, period.
- Do not allow VLAN 10 → internet "just for firmware updates." Update cameras through the UniFi Protect UI, which proxies updates through the UNVR and the management VLAN.
- Do not open port 443 on the WAN side for Protect. There is zero reason to expose the UNVR to the internet.

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

After filling these in, mirror the values into `../app/go2rtc/go2rtc.yaml` (replacing the `STREAM_KEY_PLACEHOLDER` lines).

## Sanity checks post-install

Once the table is filled in and go2rtc is running:

- `ping UNVR_IP` from the app host — must succeed (proves VLAN 10 reachability).
- `curl -k https://UNVR_IP/` — must return the UniFi OS login page (proves port 443).
- `ffprobe rtsp://UNVR_IP:7441/<streamKey>` for one camera — must report a video stream (proves RTSP).
- Browse to `http://127.0.0.1:1984/` (go2rtc web UI) — each stream should show as `online`.

If any of those fail, the problem is almost always the firewall rule or a missing VLAN 10 interface on the host.
