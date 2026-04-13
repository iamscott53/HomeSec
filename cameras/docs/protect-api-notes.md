# UniFi Protect API notes

Ubiquiti does not publish an official, stable API for UniFi Protect event streams. Two community libraries are mature enough to build on, and both are actively used in production by large projects. The HomeSec cameras app will pick one of them for the backend.

## Candidates

### 1. `unifi-protect` (Node.js / TypeScript)

- **Repo:** https://github.com/hjdhjd/unifi-protect
- **Language:** TypeScript, runs under Node.js.
- **Used by:** `homebridge-unifi-protect` (the reference Homebridge plugin).
- **Strengths:**
  - Handles the undocumented WebSocket event stream cleanly, including the binary frame format for motion + smart-detect events.
  - Actively maintained by the same author as the Homebridge plugin, so bug fixes land fast.
  - Good TypeScript types.
  - Single language end-to-end if we also use Node for the backend and React for the frontend.

### 2. `pyunifiprotect` (Python)

- **Repo:** https://github.com/briis/pyunifiprotect (or forks — the canonical location has moved a couple of times)
- **Language:** Python 3.
- **Used by:** the official Home Assistant UniFi Protect integration.
- **Strengths:**
  - If we ever want to integrate with Home Assistant, this is the path of least resistance.
  - Large test surface thanks to Home Assistant's CI.
- **Caveats:**
  - Has had some maintenance churn (forks, renames). Pin a specific version when we adopt it.

## Decision: deferred

Language pick for the cameras backend is deferred until we start building the backend. The rest of the cameras scaffold (go2rtc, ntfy, docker-compose, docs) is language-agnostic.

## What both libraries give us

- Authenticate to the UNVR Instant with a local admin account (no cloud account required).
- Enumerate cameras and fetch their metadata (id, name, RTSP URLs, state).
- Subscribe to the WebSocket event stream to receive AI detection events: `smartDetectZone` and `smartDetectLine` updates with `smartDetectTypes` like `person`, `vehicle`, `package`, `animal`.
- Download snapshots for a given event.
- Read recording timelines.

## What neither library does (we'll write ourselves)

- Event deduplication (Protect emits multiple update events per detection; we want one alert per real-world event).
- Event filtering rules per camera (e.g., "person alerts only for doorbell, vehicle alerts only for front-center").
- Alert dispatch to ntfy (simple HTTP POST).
- Snapshot attachment to alerts (pull snapshot URL from the event, POST it to ntfy as an attachment).

## Reference endpoints we'll need

These are the URLs the chosen library will call under the hood. Documented here so we can reason about firewall rules without reading library source:

- `POST https://UNVR_IP/api/auth/login` — local auth, returns a cookie + CSRF token.
- `GET https://UNVR_IP/proxy/protect/api/bootstrap` — full system state dump.
- `GET wss://UNVR_IP/proxy/protect/ws/updates` — event stream (binary framed).
- `GET https://UNVR_IP/proxy/protect/api/cameras/<id>/snapshot` — snapshot JPEG for a camera.
- `rtsp://UNVR_IP:7441/<streamKey>` — per-camera RTSP stream (see `rtsp-endpoints.md`).

All of these are HTTPS / WSS with a self-signed cert by default. The backend will need to trust the UNVR's cert or be configured to skip verification (acceptable for a LAN-only deployment with no DNS-based cert authority).
