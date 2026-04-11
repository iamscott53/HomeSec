# docs

Cross-cutting documentation for HomeSec that doesn't belong to a single section. Architecture overviews, operational standards, threat model, glossary, and any future write-ups that span multiple sections land here.

## Documents

- **[proxmox-lxc-best-practices.md](./proxmox-lxc-best-practices.md)** — LXC container standards, naming / numbering, VLAN NIC rules, systemd hardening, backup policy, and the do-not list. LXC is the default runtime for every HomeSec service.
- **[proxmox-vm-best-practices.md](./proxmox-vm-best-practices.md)** — VM standards for the narrow cases where LXC isn't the right fit (Docker-only images, heavy PCIe passthrough, non-Linux guests). Covers VMID numbering, the PCIe passthrough pattern, USB passthrough, and the when-to-use-a-VM rubric.

## External source of truth

The canonical hardware / network reference lives in the rack section, not here:

- **[../rack/INSTALLATION-SPEC.md](../rack/INSTALLATION-SPEC.md)** — equipment list, VLAN architecture, camera placement, cable run schedule, rack layout, technician notes.
