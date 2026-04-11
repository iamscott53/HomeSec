# Proxmox VM best practices for HomeSec

Cross-cutting standards for **full virtual machines** in HomeSec. LXC is the default runtime for every HomeSec service (see [`proxmox-lxc-best-practices.md`](./proxmox-lxc-best-practices.md)); this doc covers the narrow set of cases where we reach for a VM instead.

> **Rule of thumb:** if the service runs as a single binary or a plain .deb package, use LXC. If the service needs Docker, a specific kernel module not available to the host kernel, heavy hardware passthrough (GPU, TPU-via-PCIe, capture cards), or a non-Linux OS, use a VM.

## When to use a VM instead of an LXC

Use an LXC by default. Use a VM if **any** of the following is true:

| Situation | Why VM |
|---|---|
| Service ships only as a Docker image and re-packaging it is fragile (e.g., Frigate) | Avoids the "no Docker-in-LXC" rule |
| Service needs NVIDIA GPU access with the full proprietary stack | Proxmox supports PCIe passthrough to VMs as a first-class operation; LXC GPU passthrough requires nesting and custom device bind-mounts |
| Service needs a specific kernel version different from the host | LXC shares the host kernel; VMs don't |
| Service needs a non-Linux OS (Windows, BSD) | Obvious |
| Service needs a PCIe device that does not cleanly expose to LXC (capture cards, some NICs in SR-IOV mode, some NVMe drives) | PCIe passthrough is a VM feature |
| Threat model requires a stronger isolation boundary than the shared kernel | VM gives you a separate kernel, separate page tables, hypervisor-enforced isolation |

If none of the above apply, use an LXC.

## Current VM inventory in HomeSec

| Section | VMID | Name | Reason for VM |
|---|---|---|---|
| `cameras/` | 210 | `homesec-cameras-frigate` | Frigate ships as Docker; needs NVIDIA GPU + Coral USB passthrough |

That's it for v0.1. Every other HomeSec service is an LXC.

## VM standards

Every HomeSec VM must meet all of these:

| Setting | Value | Why |
|---|---|---|
| Hypervisor | Proxmox VE 8.x or newer | Baseline |
| OS template | **Debian 12 cloud-init** unless a specific service demands otherwise | Stable, small, long security window, predictable tooling |
| Machine type | `q35` | Modern; supports PCIe passthrough cleanly |
| BIOS | `ovmf` (UEFI) | Required for modern PCIe passthrough in most cases |
| CPU type | `host` | Best performance; the VM is pinned to the host CPU anyway |
| `agent` | `enabled=1` with `qemu-guest-agent` installed in the VM | Lets Proxmox issue clean shutdowns, quiesced backups, and see the VM's IP |
| `onboot` | `1` | HomeSec VMs should come up with the host after a reboot |
| SSH | Keys only, no password auth, no root login | Standard hardening |
| Unattended-upgrades | Enabled in the VM | Security patches without manual intervention |
| Backup | Included in `vzdump` schedule | Daily with retention |

## VMID numbering

Reserve VMID ranges per section, parallel to the LXC CTID convention:

| Section | VMID range |
|---|---|
| `cameras/` | 210 – 219 |
| `network-security/` | 220 – 229 |
| `switch/` | 240 – 249 |
| `nvr/` | 260 – 269 |
| `iot/` | 280 – 289 |
| `wifi/` | 300 – 309 |
| Infra (backup, monitoring, gateways) | 320 – 399 |

This keeps LXC and VM numbering from colliding at a glance. An LXC in the 200s and a VM in the 210s clearly belong to the same section.

## Naming

Same convention as LXC: `homesec-<section>-<service>`. A section that has both LXCs and a VM for the same service uses a disambiguating suffix (e.g., `homesec-cameras-frigate` for the VM vs. `homesec-cameras-frigate-worker` for a hypothetical LXC sidecar).

## Networking

### VLANs

Same rules as LXC (see the LXC best-practices doc):

- Use a **VLAN-aware Linux bridge** on the host (`vmbr0` with `bridge-vlan-aware yes`).
- Attach VM NICs with the right `tag=<vlan>`.
- Multi-VLAN VMs get multiple NICs.
- Static IPs from pfSense DHCP reservations.
- Internal DNS entries for every VM.

```bash
# Single-VLAN VM (VLAN 1)
--net0 virtio,bridge=vmbr0,tag=1,firewall=1

# Multi-VLAN VM (VLAN 1 + VLAN 10)
--net0 virtio,bridge=vmbr0,tag=1,firewall=1
--net1 virtio,bridge=vmbr0,tag=10,firewall=1
```

### Proxmox firewall

`firewall=1` on every NIC. pfSense enforces VLAN boundaries at the network layer; the Proxmox firewall adds a per-VM filter as defense-in-depth. Do not skip it.

## Resource sizing

Be conservative and bump up when real load proves the need. Defaults for HomeSec VMs:

| Component | Default |
|---|---|
| `memory` | 4096-8192 MB depending on workload |
| `cores` | 2-4 |
| `balloon` | 0 (disabled) for GPU-using VMs — memory ballooning interacts poorly with GPU drivers |
| `cpu` | `host` |
| `scsihw` | `virtio-scsi-single` |
| Disk bus | `scsi` with `iothread=1,ssd=1,discard=on` |
| Disk size | Size to the workload, grow later if needed |
| Swap | None inside the VM by default (rely on host swap) |

For the Frigate VM specifically: 8 GB RAM, 4 cores, 64 GB disk. The GPU driver reserves VRAM separately; no ballooning.

## PCIe passthrough

This is the main reason we use VMs at all. The runbook lives per-service (e.g., [`../cameras/docs/nvidia-gpu-passthrough.md`](../cameras/docs/nvidia-gpu-passthrough.md) for the Frigate VM). The host-level prerequisites are always the same:

1. IOMMU enabled in BIOS and on the kernel command line (`intel_iommu=on iommu=pt` or `amd_iommu=on iommu=pt`).
2. The target device is in its own IOMMU group (if not, use `pcie_acs_override=downstream,multifunction` as a last resort — security caveat, relaxes PCIe isolation).
3. The host's stock driver for the device is blacklisted (e.g., `nouveau`, `nvidia` for an NVIDIA GPU).
4. The device is bound to `vfio-pci` via `/etc/modprobe.d/vfio.conf`.
5. The VM has `--hostpci0 <bus>:<slot>,pcie=1` set.
6. `qm start` brings the VM up with the device attached.

Once the host is prepared, adding a second VM that passes the same device class (say, a second GPU) is just another `--hostpciX` line.

**Caveat:** A device that's passed to one VM cannot be simultaneously used by the host or another VM. Plan your passthrough list accordingly.

## USB passthrough

Unlike PCIe, USB passthrough is hot-pluggable and doesn't require host-side driver blacklisting. Prefer **host bus + port** addressing over **vendor:product ID** addressing for stability:

```bash
qm set 210 --usb0 host=3-3    # bus 3, port 3 — stable across device re-programming
```

vs

```bash
qm set 210 --usb0 host=18d1:9302   # vendor:product — stable only if device ID doesn't change
```

The Coral USB Accelerator re-programs itself on first use (changing vendor IDs), so bus+port is the right choice for it.

## Snapshots + backups

### Snapshots before any risky change

```bash
qm snapshot 210 pre-upgrade
```

Before kernel upgrades, driver upgrades, Docker container pulls, or config changes to anything GPU-adjacent. Rollback with `qm rollback 210 pre-upgrade`.

### Daily `vzdump`

Add every HomeSec VM to the Proxmox backup schedule (same schedule as LXCs). Suggested retention: 7 daily, 4 weekly, 6 monthly.

### What not to back up inside the VM

`/var/lib/frigate/media/` (short event clips) is regenerated from live camera feeds. Exclude it from application-level backups to keep the image small. The host-level vzdump will still capture the block device, but at least the VM doesn't also push clips to a file-level backup.

## Security

- **No direct internet exposure.** HomeSec VMs are LAN-only. Remote access = Tailscale / WireGuard back into the LAN.
- **Unattended-upgrades on.**
- **`firewall=1` on every NIC.**
- **qemu-guest-agent installed** so `vzdump` can do quiesced backups.
- **No shared filesystems between VMs** unless a specific service requires it.
- **No secrets in the VM image.** VMs are cattle — rebuild from the scaffold in this repo if anything goes wrong.
- **Snapshot before, verify after.** Always have a rollback point for anything touching drivers or passthrough config.

## Do-not list

- Do not pass the same PCIe device to multiple VMs. It will not work and will corrupt state.
- Do not disable `firewall=1` on the NIC.
- Do not run HomeSec VMs in `privileged` mode (there's no such toggle for VMs, but don't set `--args` with anything that relaxes hypervisor isolation).
- Do not share a disk with another VM or LXC.
- Do not install the NVIDIA driver on the Proxmox host while a VM is using the GPU. The host must stay clean; only the VM has the driver.
- Do not put secrets in the cloud-init user-data. Use a secrets manager and pull values at runtime inside the VM.
- Do not `curl | bash` an installer. Pin and verify, same as the LXC scripts.

## See also

- [`proxmox-lxc-best-practices.md`](./proxmox-lxc-best-practices.md) — the default runtime standards.
- [`../cameras/docs/nvidia-gpu-passthrough.md`](../cameras/docs/nvidia-gpu-passthrough.md) — the runbook for the Frigate VM's GPU + Coral passthrough.
- [`../cameras/app/vm/README.md`](../cameras/app/vm/README.md) — the cameras section's VM inventory and provisioning index.
