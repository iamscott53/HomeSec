# cameras/app/vm — VM-based services for the cameras section

This directory holds provisioning artifacts for services in the cameras section that run as **full Proxmox VMs** instead of LXC containers. See the cross-cutting [`docs/proxmox-vm-best-practices.md`](../../../docs/proxmox-vm-best-practices.md) for the "when to use a VM" rubric.

LXC is still the default for the rest of the cameras section — `go2rtc`, `ntfy`, `mqtt`, `analyzer`, and `frontend` all live under [`../lxc/`](../lxc/). Only services that need Docker + heavy PCIe passthrough land here.

## VM inventory

| VMID | Name | Reason for VM | Scaffolded? |
|---|---|---|---|
| 210 | `homesec-cameras-frigate` | Frigate ships as Docker; needs NVIDIA GPU + Coral USB passthrough | ✅ [`frigate/`](./frigate) |
| 211 | `homesec-cameras-inference` (reserved) | Possible future sidecar if Frigate ever stops exposing raw face embeddings to the analyzer. | ❌ not planned for v0.1 |

v0.1 ships **one VM** (Frigate). The reserved 211 slot is a safety valve — see [`../../docs/face-recognition-design.md`](../../docs/face-recognition-design.md) for the contingency under which it becomes necessary.

## Provisioning order

If this is a fresh install, stand the VMs up in this order:

1. **Proxmox host preflight** — IOMMU, vfio-pci binding, blacklist host NVIDIA drivers. See [`../../docs/nvidia-gpu-passthrough.md`](../../docs/nvidia-gpu-passthrough.md) Part 1.
2. **Debian 12 cloud-init template** on the Proxmox host, if one doesn't exist.
3. **Frigate VM** — see [`frigate/README.md`](./frigate/README.md) for the exact `qm create` flags, PCIe + USB passthrough, driver install, Docker install, and Frigate deployment.

The VM depends on:

- `homesec-cameras-go2rtc` (LXC 200) being up — Frigate pulls its streams from go2rtc, not directly from the UNVR.
- `homesec-cameras-mqtt` (LXC 202) being up — Frigate publishes events to MQTT.

Stand up those two LXCs first, then the VM.

## VMID range

VMIDs for the cameras section are reserved in the range **210-219** (see [`docs/proxmox-vm-best-practices.md`](../../../docs/proxmox-vm-best-practices.md) for the full per-section table). The 210 slot is taken by Frigate; 211 is held for the possible inference sidecar; 212-219 are free for future expansion.

## What this directory does NOT contain

- LXC scaffolds — those live under [`../lxc/`](../lxc/).
- Proxmox host config (grub, modprobe, network bridges) — that's host-level and belongs in a future `infra/` or `proxmox/` section, not here. For now, the relevant host bits are inline in [`../../docs/nvidia-gpu-passthrough.md`](../../docs/nvidia-gpu-passthrough.md).
- Cloud-init user-data templates — keep them out of git. Secrets-in-cloud-init is a known foot-gun.
