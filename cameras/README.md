# cameras

Local, privacy-oriented camera app for the seven-camera Ubiquiti Protect deployment: 6x G5 Bullet (2K, PoE, on-device AI detection) + 1x G4 Doorbell Pro. All cameras and the UNVR Instant live on VLAN 10 with **zero internet access** — every byte of footage, metadata, and event data stays on the LAN.

## What this app does

1. **AI alerts** — subscribes to the UniFi Protect event stream on the UNVR Instant, filters for AI detections (person, vehicle, package, animal), and POSTs each event to a self-hosted notification service so you get a push on your phone.
2. **Live streaming** — serves a grid of low-latency tiles (one per camera) in a browser on the LAN.

Everything runs on your network. No cloud. No subscriptions. No phoning home.

## Architecture (planned)

```
┌──────────────────┐
│  UNVR Instant    │  VLAN 10, no internet
│  UniFi Protect   │
└────────┬─────────┘
         │ RTSP streams + WS event feed
         ▼
┌──────────────────┐   AI events    ┌──────────────┐
│  backend (TBD)   │ ─────────────▶ │  ntfy        │ ─▶ phone push
│  language TBD    │                └──────────────┘
└────────┬─────────┘
         │ RTSP pull
         ▼
┌──────────────────┐   WebRTC       ┌──────────────┐
│  go2rtc          │ ─────────────▶ │  frontend    │ ─▶ browser grid
└──────────────────┘                └──────────────┘
```

Four services in `app/docker-compose.yml`:

| Service | Image | Role |
|---------|----------------------------|------|
| `backend` | *(deferred — language TBD)* | subscribes to Protect WS, filters AI events, posts to ntfy |
| `frontend` | *(deferred — language TBD)* | LAN-only grid UI consuming go2rtc streams |
| `go2rtc` | `alexxit/go2rtc` | RTSP → WebRTC/HLS, one config file, LAN-bound |
| `ntfy` | `binwiederhier/ntfy` | self-hosted push notifications, zero cloud |

## What's scaffolded today

- `app/go2rtc/go2rtc.yaml` — 7 stream entries with placeholder RTSP URLs, LAN-bound listeners.
- `app/docker-compose.yml` — `go2rtc` and `ntfy` services wired up. `backend` and `frontend` are commented placeholders.
- `docs/protect-api-notes.md` — library options for talking to UniFi Protect.
- `docs/rtsp-endpoints.md` — table for per-camera RTSP URLs and the critical VLAN 10 reachability gotcha.

## What is explicitly NOT scaffolded yet

- Backend code (language is deferred — picking between Node/TypeScript with `unifi-protect` and Python with `pyunifiprotect`).
- Frontend code.
- Real RTSP URLs (cameras aren't installed yet — fill these in from the UniFi Protect web UI after install).

## Running (once a backend is picked)

From `cameras/app/`:

```
docker compose up
```

…which will start `go2rtc` and `ntfy`. The backend and frontend services will be added to the compose file once the language is picked and scaffolded.

## Hard constraint: VLAN 10 reachability

Cameras and the UNVR have no internet. The host running this app must either sit on VLAN 10 directly (multi-homed interface) or be reachable from VLAN 10 via a narrow pfSense rule that allows **mgmt → VLAN 10 on Protect API + RTSP ports only**. See `docs/rtsp-endpoints.md` for details — this is the #1 installation trap.
