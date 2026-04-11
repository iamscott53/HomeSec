# homesec-cameras-analyzer (LXC 203)

Proxmox LXC that runs the **HomeSec cameras analyzer** — the custom Python service that sits between Frigate (in the VM) and the operator. It consumes Frigate's events, does the cross-clip work Frigate doesn't, and dispatches alerts.

- **Suggested CTID:** 203
- **Hostname:** `homesec-cameras-analyzer`
- **Template:** Debian 12 standard
- **Unprivileged:** yes
- **Nesting:** no
- **NICs:** one — `eth0` on VLAN 1 only
- **Resources:** 2 cores, 1 GB RAM, 16 GB disk (DB + face/plate crops grow over time)
- **GPU:** none — the analyzer is CPU-only (see below)

## Status: scaffold only

This directory is a **scaffold placeholder** for v0.1. The code doesn't exist yet. What v0.1 commits is the design (in [`../../docs/`](../../docs/)), this README stating the language and dependencies are locked in, and the CTID reservation.

**Language is locked in: Python 3.12.** This is the first concrete language commitment in the repo. The decision is driven by:

1. Every face / ALPR / object-detection library in the relevant open-source ecosystem ships as Python (InsightFace, OpenCV, ONNX Runtime, PaddleOCR, EasyOCR, etc.).
2. Frigate is a Python application and its developer community writes integrations in Python.
3. `paho-mqtt` and `asyncio-mqtt` are mature and stable.
4. FastAPI + SQLModel + uvicorn are the modern path for a small REST service.
5. We'd otherwise need to use `node-insightface` (doesn't exist at production quality) or write our own face encoding, which is not worth it.

## What this container does (per the design docs)

1. **Subscribes to Frigate events** via MQTT (`frigate/events`, `frigate/#`). See [`../mqtt/README.md`](../mqtt/README.md).
2. **Pulls event snapshots and clips** from Frigate's REST API (`http://homesec-cameras-frigate:5000/api/events/<id>/...`).
3. **Cross-clip face clustering** — incremental centroid-based clustering of ArcFace embeddings into stable `persons` records. Every unknown face gets `Unknown #N` until the operator labels the cluster. See [`../../docs/face-recognition-design.md`](../../docs/face-recognition-design.md).
4. **Plate history** — normalizes, dedupes, and tracks license plate sightings over time. See [`../../docs/alpr-design.md`](../../docs/alpr-design.md).
5. **Vehicle attributes** — extracts make/model/color from vehicle crops. Deferred implementation; scaffold only in v0.1. See [`../../docs/vehicle-attributes-design.md`](../../docs/vehicle-attributes-design.md).
6. **Day-level recording protection sweep** — runs daily at 03:00 local via a systemd timer. Walks `/media/frigate/recordings/`, marks each day directory as `.protected` if any events occurred that date or `.cleanup-eligible` otherwise. See [`../../docs/recording-retention-design.md`](../../docs/recording-retention-design.md).
7. **Disk watchdog** — runs hourly via a separate systemd timer. Threshold chain (see [`../../docs/storage-management-design.md`](../../docs/storage-management-design.md) for the full doc):
   - **≥ 75%**: delete oldest `.cleanup-eligible` day directories until < 70% or none remain + emit a warning notification (max one per 24h).
   - **≥ 90%**: emit an urgent critical notification (max one per 24h).
   - **≥ 95%**: automatically downgrade the recording quality preset one step (High → Medium → Low → Lowest) and restart Frigate with the new preset, max one downgrade per 12h. No automatic upgrade afterwards.
   - **No more `.cleanup-eligible` days AND used > 90%**: enter the "recording will stop" state — fire a red urgent notification every hour until the operator acts.
   - **NEVER deletes `.protected` days**, under any disk condition. Protected days are inviolable under automation.
   - **NEVER touches `/media/frigate/clips/`.**
8. **First-trigger-of-day notification** — when the analyzer sees the first event of a new local-time date, fires a one-shot ntfy alert telling the operator to review the entire day in the frontend. Dedup'd per-day.
9. **Storage management REST API** for the Storage and Settings pages in the frontend:
   - `GET  /api/storage/status` — current disk usage %, oldest day date, number of `.cleanup-eligible` days, number of `.protected` days, current quality preset, current recording state.
   - `GET  /api/storage/days` — paginated, sortable list of day directories with size, camera count, status, trigger count.
   - `POST /api/storage/download-prepare` — returns `{total_bytes, estimated_seconds}` for a proposed day list.
   - `POST /api/storage/download` — streams a single zip (Python `zipfile.ZipFile` + `StreamingResponse`, `ZIP_STORED` since video is already compressed) containing the selected day directories. Rate-limited to 1 concurrent download. Writes to `storage_audit`.
   - `DELETE /api/storage/days` — deletes selected day directories. For `.protected` days, requires a `confirmed_download_hash` matching a recent entry in `storage_audit` within the last 10 minutes, OR an explicit `force: true` flag with operator identifier. Writes to `storage_audit`.
   - `GET  /api/storage/quality-preset` — current preset + history.
   - `PUT  /api/storage/quality-preset` — change preset manually. Calls the Frigate VM's helper (SSH-based symlink swap + `docker compose restart frigate`). Writes to `quality_preset_changes`.
   - `POST /api/storage/ack-full-warning` — operator acknowledges the "recording will stop" state, which temporarily silences the hourly red notification. Does not suppress future escalations if disk keeps climbing.
   - `GET  /api/storage/audit` — paginated view of the `storage_audit` table for the frontend's audit log view.
10. **Quality preset manager** — keeps the four preset config files on the Frigate VM in sync with what the analyzer thinks is active, symlinks to the currently active preset, and handles the "restart Frigate" dance. See the quality preset section of [`../../docs/storage-management-design.md`](../../docs/storage-management-design.md).
11. **Alert dispatcher** — decides which per-event alerts fire a phone alert via ntfy, applies dedup windows, quiet hours, and severity mapping.
12. **Social enrichment router** — Mode A (linked profiles), Mode B (manual reverse-search helper), Mode C (opt-in third-party stub). See [`../../docs/social-enrichment-design.md`](../../docs/social-enrichment-design.md).
13. **REST API for the rest of the frontend** — FastAPI app that also exposes MQTT event replay, day summaries, per-person/per-plate detail views, and a small admin interface for the operator.

### Mount requirement for recording retention

The daily sweep and the disk watchdog need read + sentinel-write access to the Frigate VM's recording volume. In the current design, this is done by NFS- or SMB-mounting `/media/frigate/recordings/` from the Frigate VM into the analyzer LXC at the same path (`/media/frigate/recordings/`).

The LXC needs write access ONLY to create / delete the `.protected` and `.cleanup-eligible` sentinel files and to delete day directories; it should NOT be able to modify individual recording files. If the Frigate VM exports the share with sub-directory-level permission control, grant the analyzer `rwx` on the top-level `recordings/` directory (so it can `rmdir` day directories) and optionally `ro` on individual files within days (so the analyzer can't tamper with the footage itself).

This is a small security compromise for a significant operational win. The alternative — running the cleanup job inside the Frigate VM — would split the analyzer across two runtimes, which adds complexity without buying much.

## Hardware placement: CPU only

Cross-clip clustering is pure arithmetic on 512-dim embeddings. No GPU needed. The **Frigate VM** owns the GPU and does the actual face encoding and plate OCR; this LXC just consumes the outputs and does cluster-membership math.

This keeps the LXC lightweight (unprivileged, no PCIe passthrough, no nesting) and keeps the GPU's attention on inference, not on clustering.

If a future Frigate version stops exposing raw face embeddings via its API, the analyzer would need either GPU access or a sidecar inference service. The [`../../docs/face-recognition-design.md`](../../docs/face-recognition-design.md) doc covers that contingency.

## Planned tech stack

None of this is committed to code yet — it's the stack I plan to implement in the next PR. Subject to revision when implementation starts.

- **Python:** 3.12 from Debian 12 backports (or pyenv if backports are stale)
- **Package manager:** [`uv`](https://github.com/astral-sh/uv) — fast, reproducible, pinned via `uv.lock`
- **Web framework:** [`FastAPI`](https://fastapi.tiangolo.com) + `uvicorn`
- **ORM / DB:** [`SQLModel`](https://sqlmodel.tiangolo.com) on SQLite for v0 (upgrade to Postgres if we outgrow it)
- **MQTT:** [`asyncio-mqtt`](https://github.com/sbtinstruments/asyncio-mqtt)
- **Face embeddings:** [`insightface`](https://github.com/deepinsight/insightface) `buffalo_l` model — but **only if Frigate stops exposing embeddings**; in the happy path we consume Frigate's embeddings and never load insightface at all
- **Vector math:** `numpy` for centroid math, `scikit-learn` (DBSCAN/HDBSCAN) for offline re-clustering only
- **Validation:** `pydantic` v2
- **HTTP client:** `httpx`
- **Logging:** stdlib `logging` → journald via systemd's `StandardOutput=journal`

No heavy ML frameworks (PyTorch, TensorFlow) are needed in the analyzer itself — all the inference is in the Frigate VM. That keeps the LXC install small.

## Files in this directory (planned, not yet created)

| File | Purpose |
|---|---|
| `install.sh` | Provision Python + uv inside the LXC, clone the app code, install deps, wire systemd. |
| `analyzer.service` | Hardened systemd unit (NoNewPrivileges, ProtectSystem=strict, etc.) |
| `config.example.yaml` | Config template. Operator copies to `/etc/homesec-cameras-analyzer/config.yaml` and fills in MQTT broker host, creds env-var name, Frigate API URL, ntfy URL, enrichment mode toggles. |
| `src/` | Python package. Module layout is a follow-up PR. |
| `pyproject.toml` + `uv.lock` | Pin dependencies. |
| `alembic/` | DB schema migrations. |

## Provisioning from the Proxmox shell (once files exist)

```bash
pct create 203 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homesec-cameras-analyzer \
  --unprivileged 1 \
  --features nesting=0,keyctl=0 \
  --cores 2 \
  --memory 1024 \
  --swap 0 \
  --rootfs local-lvm:16 \
  --net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1 \
  --onboot 1 \
  --start 1 \
  --ssh-public-keys /root/.ssh/authorized_keys
```

## Not yet implemented

Literally all of it. This README reserves the CTID, locks in the language, names the stack, and documents the intent. The implementation — `install.sh`, the Python package, the REST API, the clustering logic, the alert dispatcher, the social enrichment router — comes in a follow-up PR after the Frigate VM is stood up on real hardware and we've verified the end-to-end event flow.

## Do not

- Do not start writing the analyzer code in another language — Python is the pick.
- Do not add GPU passthrough to this container. Keep it unprivileged and CPU-only.
- Do not commit any MQTT passwords, Frigate API tokens, ntfy passwords, or third-party face-search API keys to this repo. They live in a secrets manager and are read via environment variables at runtime.
