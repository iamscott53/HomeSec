# docs

Cross-cutting documentation for HomeSec that doesn't belong to a single section. Architecture overviews, operational standards, threat model, glossary, and any future write-ups that span multiple sections land here.

## Documents

- **[proxmox-lxc-best-practices.md](./proxmox-lxc-best-practices.md)** — LXC container standards, naming / numbering, VLAN NIC rules, systemd hardening, backup policy, and the do-not list. Every HomeSec section that grows an app runs that app in Proxmox LXC containers following this doc.

## External source of truth

The canonical hardware / network reference lives in the rack section, not here:

- **[../rack/INSTALLATION-SPEC.md](../rack/INSTALLATION-SPEC.md)** — equipment list, VLAN architecture, camera placement, cable run schedule, rack layout, technician notes.
