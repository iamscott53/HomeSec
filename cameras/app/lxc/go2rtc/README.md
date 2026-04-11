# homesec-cameras-go2rtc

Proxmox LXC container that runs **go2rtc** — a small Go binary that pulls RTSP streams from the UNVR and re-serves them to the frontend as WebRTC (low-latency browser playback with no plugins).

- **Suggested CTID:** 200
- **Hostname:** `homesec-cameras-go2rtc`
- **Template:** Debian 12 standard
- **Unprivileged:** yes
- **Nesting:** no
- **NICs:** two — `eth0` on VLAN 1 (serves WebRTC to the frontend), `eth1` on VLAN 10 (pulls RTSP + WSS from the UNVR)
- **Resources:** 2 cores, 512 MB RAM, 8 GB disk

## Files in this directory

| File | Purpose |
|------|---------|
| `install.sh` | Idempotent install script. Creates a `go2rtc` system user, downloads + verifies the pinned release binary, installs the systemd unit and config. Run once after LXC provisioning, safe to re-run for upgrades. |
| `go2rtc.service` | Hardened systemd unit file (NoNewPrivileges, ProtectSystem=strict, etc.). Installed to `/etc/systemd/system/go2rtc.service`. |
| `go2rtc.yaml` | The streams + listener config. Installed to `/etc/go2rtc/go2rtc.yaml`. Contains placeholder RTSP URLs that you must fill in from UniFi Protect after camera install. |

## Provisioning from the Proxmox shell

Create the LXC on the Proxmox host (adjust bridge name, storage, password, SSH key, and CTID to your environment):

```bash
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homesec-cameras-go2rtc \
  --unprivileged 1 \
  --features nesting=0,keyctl=0 \
  --cores 2 \
  --memory 512 \
  --swap 0 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1 \
  --net1 name=eth1,bridge=vmbr0,tag=10,ip=dhcp,firewall=1 \
  --onboot 1 \
  --start 1 \
  --ssh-public-keys /root/.ssh/authorized_keys
```

Then copy this directory into the container and run the installer:

```bash
pct push 200 go2rtc.service /root/go2rtc.service
pct push 200 go2rtc.yaml    /root/go2rtc.yaml
pct push 200 install.sh     /root/install.sh
pct exec 200 -- bash -c 'cd /root && chmod +x install.sh && ./install.sh'
```

## After install

1. Snapshot the container: `pct snapshot 200 post-install`.
2. Edit `/etc/go2rtc/go2rtc.yaml` inside the container and replace every `STREAM_KEY_PLACEHOLDER` with the real RTSP stream key from UniFi Protect. See `../../../docs/rtsp-endpoints.md` for where to find these.
3. Replace `UNVR_IP` with the UNVR Instant's VLAN 10 IP address.
4. `systemctl start go2rtc` and watch the logs: `journalctl -u go2rtc -f`.
5. From another host on VLAN 1, browse to `http://<go2rtc-container-ip>:1984` — you should see the go2rtc web UI with each stream listed as `online`.

## Internet egress

`go2rtc` needs internet **only during install** (to download the binary from GitHub). After install, it only talks to the UNVR on VLAN 10 and the frontend on VLAN 1 — both local. Add a pfSense rule to deny WAN egress from this container after install if you want to be strict.

## Upgrades

Bump `GO2RTC_VERSION` in `install.sh`, re-push it to the container, re-run. The script stops the service, replaces the binary, verifies the checksum, and restarts. Snapshot before upgrading.

## Do not

- Do not enable `nesting=1` on this container. go2rtc is a single Go binary; it does not need Docker.
- Do not expose port 1984, 8554, or 8555 to WAN. These are LAN-only.
- Do not run go2rtc as root — the install script creates and uses a `go2rtc` system user with no shell.
