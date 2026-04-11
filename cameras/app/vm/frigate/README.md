# homesec-cameras-frigate (VM 210)

Proxmox VM that runs **Frigate** — the open-source local NVR with AI detection, face recognition, and license plate recognition. Frigate ships as a Docker image and needs both a Coral Edge TPU (for 24/7 object detection) and an NVIDIA GPU (for face recognition + ALPR OCR), so it runs in a VM instead of an LXC to keep the "no Docker-in-LXC" rule intact.

- **VMID:** 210
- **Hostname:** `homesec-cameras-frigate`
- **OS:** Debian 12 (cloud-init)
- **Machine:** `q35`, `ovmf` (UEFI)
- **CPU:** 4 cores, `host` type
- **Memory:** 8 GB, no ballooning
- **Disk:** 64 GB SCSI, `virtio-scsi-single`, `iothread=1,ssd=1,discard=on`
- **NICs:** one — `net0` on VLAN 1 (Frigate talks to go2rtc, mqtt, analyzer; never VLAN 10 directly)
- **Passthrough:** NVIDIA GPU (PCIe) + Coral USB Accelerator
- **Firewall:** `firewall=1` on the NIC
- **Agent:** qemu-guest-agent enabled

## Files in this directory

| File | Purpose |
|---|---|
| `docker-compose.yml` | Single service: `frigate`. `runtime: nvidia`, `device_cgroup_rules` for the Coral USB, bind-mounts for config/media/db, restart policy, network mode. |
| `frigate.yml` | Frigate config: mqtt, detectors (coral + nvidia), go2rtc streams (7 cameras), detection zones, face rec config, ALPR config, retention settings. Filled with placeholders that need real values after the VM is up. |
| `install.sh` | Runs inside the VM. Verifies NVIDIA + Coral are visible, installs Docker + nvidia-container-toolkit + libedgetpu, copies config files into `/var/lib/frigate/`, starts the container. |

## Provisioning

**Host preflight is mandatory** — the NVIDIA GPU must be bound to `vfio-pci` and the host driver blacklisted before the VM is created. See [`../../../docs/nvidia-gpu-passthrough.md`](../../../docs/nvidia-gpu-passthrough.md) Part 1 for the host setup.

Once host preflight is done, provision the VM from the Proxmox shell:

```bash
# Create the VM shell (adjust storage, template, SSH key path)
qm create 210 \
  --name homesec-cameras-frigate \
  --memory 8192 --balloon 0 \
  --cores 4 --cpu host \
  --machine q35 --bios ovmf \
  --efidisk0 local-lvm:0,format=raw \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0,tag=1,firewall=1 \
  --ipconfig0 ip=dhcp \
  --ostype l26 \
  --agent enabled=1 \
  --onboot 1

# Clone the OS disk from your Debian 12 cloud-init template
qm disk import 210 /path/to/debian-12-genericcloud.qcow2 local-lvm
qm set 210 --scsi0 local-lvm:vm-210-disk-0,cache=writeback,discard=on,iothread=1,ssd=1
qm set 210 --boot order=scsi0
qm set 210 --ide2 local-lvm:cloudinit
qm set 210 --sshkeys ~/.ssh/id_ed25519.pub
qm resize 210 scsi0 +54G

# Attach NVIDIA GPU (replace 01:00 with your lspci address)
qm set 210 --hostpci0 01:00,pcie=1,x-vga=0

# Attach Coral USB (replace 3-3 with your lsusb -t bus-port)
qm set 210 --usb0 host=3-3

# First boot
qm start 210
```

Then SSH into the VM (the cloud-init DHCP lease shows up in `qm guest cmd 210 network-get-interfaces`) and run the installer:

```bash
scp -r cameras/app/vm/frigate/ debian@<vm-ip>:~/frigate/
ssh debian@<vm-ip>
cd ~/frigate
sudo ./install.sh
```

The installer will:

1. Verify `nvidia-smi` works (confirms GPU passthrough and driver install).
2. Verify the Coral shows up in `lsusb`.
3. Install Docker CE + Compose plugin from the official Docker apt repo.
4. Install the NVIDIA Container Toolkit from NVIDIA's apt repo.
5. Install `libedgetpu1-std` from Google's apt repo.
6. Create `/var/lib/frigate/{config,media,db}` owned by the service user.
7. Copy `frigate.yml` → `/var/lib/frigate/config/config.yml`.
8. Copy `docker-compose.yml` → `/var/lib/frigate/docker-compose.yml`.
9. `docker compose up -d` from `/var/lib/frigate/`.
10. Print the Frigate web UI URL.

## After install

1. Snapshot the VM: `qm snapshot 210 post-install`.
2. Edit `/var/lib/frigate/config/config.yml` inside the VM — fill in real values for:
   - `mqtt.host` → the LAN IP of `homesec-cameras-mqtt` (LXC 202)
   - `mqtt.user` / `mqtt.password` → the Frigate-specific MQTT credentials you created in the mqtt LXC (never commit these)
   - `go2rtc.streams.*` → the go2rtc stream names that match your cameras (front-left, doorbell, etc.)
   - `cameras.*` → uncomment and adjust the 7 camera entries
3. Restart Frigate: `docker compose -f /var/lib/frigate/docker-compose.yml restart`.
4. Tail logs: `docker compose -f /var/lib/frigate/docker-compose.yml logs -f frigate`.
5. Browse to `http://<vm-ip>:5000` from a workstation on VLAN 1. You should see the Frigate web UI with all 7 cameras listed.
6. Verify detectors:
   - Go to **System → General** in the Frigate UI.
   - The **Detectors** section should list `edgetpu` (Coral) as active.
   - For face rec / ALPR, the **AI Models** section should list the NVIDIA device as available.

## Pinned version

This scaffold does not yet pin a specific Frigate version. **TODO before first install:** look up the latest stable Frigate release at https://github.com/blakeblackshear/frigate/releases, pin `ghcr.io/blakeblackshear/frigate:<version>` in `docker-compose.yml`, and record the version in `cameras/CHANGELOG.md`.

Do NOT use `:latest` or `:stable` — pin to a specific version tag. Frigate's model updates and schema migrations can be breaking between major versions.

## Internet egress

Frigate needs internet **only during install** (Docker image pull, NVIDIA toolkit packages, libedgetpu packages, eventual `apt upgrade` runs). In steady-state operation, Frigate only talks to:

- go2rtc on VLAN 1 (inbound RTSP pulls)
- mqtt on VLAN 1 (outbound event publishing)
- analyzer on VLAN 1 (inbound REST API queries for snapshots/clips)
- frontend / operator browser on VLAN 1 (inbound web UI)

Add a pfSense rule after install that denies WAN egress from the VM's IP except for explicit Debian security update hosts, if you want maximum lockdown. The rule template lives in `network-security/` once that section has content.

## Upgrades

1. Snapshot: `qm snapshot 210 pre-frigate-upgrade`.
2. Edit `docker-compose.yml` on your workstation, bump the Frigate image tag.
3. Update `cameras/CHANGELOG.md` with the version change.
4. Copy the updated `docker-compose.yml` into the VM, re-run `docker compose pull && docker compose up -d`.
5. Tail logs for schema migration messages.
6. If anything is off, `qm rollback 210 pre-frigate-upgrade`.

## Do not

- Do not enable the GPU on the Proxmox host (no `nvidia-driver` install on the host). The host must stay clean; only the VM has the driver.
- Do not pass the same GPU to a second VM. It will not work.
- Do not run more than one Frigate container in the VM. One container per Frigate config; scale up resources instead.
- Do not expose port 5000 to WAN. LAN-only. Remote access via Tailscale / WireGuard.
- Do not commit real `mqtt.password`, `auth.public_key`, or cloud-init user-data with secrets.
- Do not delete `/var/lib/frigate/db` lightly — it holds the face/plate embeddings DB. Back it up before any schema-breaking upgrade.
