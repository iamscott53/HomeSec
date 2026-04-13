# Proxmox LXC best practices for HomeSec

Cross-cutting rules for every LXC container in this repo. Applies to `cameras/`, `network-security/`, `switch/`, `nvr/`, `iot/`, `wifi/` — every section that grows an app runs that app in one or more Proxmox LXC containers, not in Docker.

> **Why not Docker-in-LXC?**
> It works, but it requires `nesting=1`, which widens the LXC attack surface, breaks some of Proxmox's AppArmor profiles, and complicates backup/restore. For services that ship as a single binary or a plain .deb (go2rtc, ntfy, pfSense exporters, most Python/Node apps), running them natively in LXC is simpler, faster to start, and easier to reason about. HomeSec is a home lab, not a Kubernetes cluster — keep it boring.

---

## 1. Container standards

Every HomeSec LXC must meet all of these:

| Setting | Value | Why |
|---|---|---|
| Privileged | **No** (unprivileged) | UID mapping means root-in-container is NOT root-on-host. |
| OS template | **Debian 12 standard** | Stable, small, long security-update window. Only deviate for a specific reason. |
| Nesting | **Off** (`features: nesting=0`) | No Docker-in-LXC. No reason to need it. |
| Keyctl | **Off** unless a service explicitly requires it | Narrows kernel attack surface. |
| Fuse / mount | **Off** unless required | Same. |
| Swap | **0 MB** (`swap=0`) | Avoids surprises when Proxmox host memory is tight; LXC should be sized to fit. |
| AppArmor | **Default profile on** | Do not disable AppArmor on individual containers. |
| SSH | Keys only, no password auth, no root login | Standard hardening. |
| Apt unattended upgrades | **On** for security updates | `apt install unattended-upgrades` in every container. |

## 2. Naming + numbering

### Hostnames

Format: `homesec-<section>-<service>`

Examples:

- `homesec-cameras-go2rtc`
- `homesec-cameras-ntfy`
- `homesec-cameras-backend`
- `homesec-cameras-frontend`
- `homesec-network-security-dashboard` (future)
- `homesec-nvr-health` (future)

This makes `pct list` readable and makes DNS/hostfiles self-documenting.

### CTIDs

Reserve a range per section so CTIDs correlate to what a container does at a glance.

| Section | CTID range |
|---|---|
| `cameras/` | 200 – 219 |
| `network-security/` | 220 – 239 |
| `switch/` | 240 – 259 |
| `nvr/` | 260 – 279 |
| `iot/` | 280 – 299 |
| `wifi/` | 300 – 319 |
| Reserved (infra: syslog, backup, monitoring) | 320 – 399 |

This is a convention, not a hard rule — if a CTID already exists on your Proxmox host, pick the next free one in the section's range.

## 3. Networking

### Bridge

Use a **VLAN-aware Linux bridge** on the Proxmox host (typically `vmbr0`) with every HomeSec VLAN tag allowed. Example `/etc/network/interfaces` stanza:

```
auto vmbr0
iface vmbr0 inet static
    address 10.0.1.2/24
    gateway 10.0.1.1
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 1 10 20 30
```

### Per-container NICs

Attach NICs with the right VLAN tag. Multi-VLAN containers get one NIC per VLAN.

```bash
# Single-VLAN container (VLAN 1)
--net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1

# Multi-VLAN container (VLAN 1 for serving + VLAN 10 for camera access)
--net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1
--net1 name=eth1,bridge=vmbr0,tag=10,ip=dhcp,firewall=1
```

`firewall=1` turns on the Proxmox datacenter firewall for that NIC — do NOT skip it. pfSense still enforces VLAN boundaries, but the Proxmox firewall adds a second layer of defense per container.

### Static IPs

Give every HomeSec container a **static** IP from a DHCP reservation on pfSense (by MAC). Debugging, firewall rules, and systemd unit configs all get easier when IPs do not move.

### DNS

Use an internal DNS entry (or hostfile) for each container: `homesec-cameras-go2rtc.lan`, `homesec-cameras-ntfy.lan`, etc. Never reference containers by IP in config files where a hostname would work — it makes re-IPing a container trivial.

## 4. Resource limits

Set sensible caps so one runaway service cannot exhaust the Proxmox host:

```bash
--cores 2
--memory 512   # MiB
--swap 0
--rootfs <storage>:<size-GB>
```

Reasonable defaults for the cameras stack:

| Container | Cores | Memory | Disk |
|---|---|---|---|
| `homesec-cameras-go2rtc` | 2 | 512 MB | 8 GB |
| `homesec-cameras-ntfy` | 1 | 256 MB | 4 GB |
| `homesec-cameras-backend` | 2 | 512 MB | 4 GB |
| `homesec-cameras-frontend` | 1 | 256 MB | 4 GB |

Bump these later if you actually see resource pressure — don't guess upward.

## 5. Service standards inside each container

Every application service inside an LXC must:

- Run as a **dedicated system user**, never as root. Install scripts in this repo create one per service (`go2rtc`, `ntfy`, etc.).
- Be managed by **systemd**. No nohup, no tmux, no screen, no cron-at-boot hacks.
- Use a **hardened systemd unit** with at least these directives:
  - `NoNewPrivileges=true`
  - `ProtectSystem=strict`
  - `ProtectHome=true`
  - `PrivateTmp=true`
  - `ProtectKernelTunables=true`
  - `ProtectKernelModules=true`
  - `ProtectControlGroups=true`
  - `CapabilityBoundingSet=` (empty unless a specific capability is required)
  - `ReadWritePaths=<explicit list>`
- Log to **journald**, not to a flat file. `journalctl -u <service>` must show application logs.
- Install **from a pinned upstream release** with **checksum verification**. No `curl | bash`. No `:latest`.

The cameras scaffold in this repo (`cameras/app/lxc/go2rtc/` and `cameras/app/lxc/ntfy/`) is the reference implementation — every future service should look like it.

## 6. Secrets handling

- **Never commit secrets to this repo.** The `.gitignore` at the repo root covers `.env*`, `*.key`, `*.pem`, `credentials*`, `token*`, `api_key*`, and private keys, but the rule of "never commit secrets" is always stronger than the filter.
- **Per-service users in each app** with narrowly-scoped access. (Example: the cameras backend gets a `homesec-cameras-backend` ntfy user with write access to exactly one topic, not admin.)
- **Secrets manager, not git.** Bitwarden, 1Password, pass, KeePassXC — pick one and keep passwords / API tokens / auth files there.
- **Rotation:** rotate any password or API token the moment you suspect a container was compromised. Snapshots mean re-provisioning is cheap.

## 7. Backup + snapshots

### Before every change

```bash
pct snapshot <CTID> pre-<what-youre-about-to-do>
```

Before running an `install.sh`, editing a config file, or applying apt upgrades. Rollback with `pct rollback <CTID> <snapshot>` if anything breaks.

### Daily backups

Use Proxmox Backup Server (best) or `vzdump` to a local NAS (fine for a home lab). Suggested retention: **7 daily, 4 weekly, 6 monthly**.

### Treat containers as rebuildable

The source of truth is the install script + config file in this repo, not the running container. If a container is hopelessly broken, wipe it and re-provision from scratch — that should be a 5-minute operation, not a research project.

## 8. Internet egress

Most HomeSec LXCs only need internet during install (to download a pinned binary or .deb from GitHub). After install, revoke internet access per container via pfSense rules:

- `cameras/` containers: WAN denied after install. They only talk to each other on VLAN 1 and to the UNVR on VLAN 10.
- `network-security/` containers: depends per container. Most deny WAN.
- `iot/` containers: may legitimately need WAN (for cloud-dependent IoT APIs that cannot be avoided); scope narrowly.

The VLAN 10 no-internet rule is non-negotiable — cameras and the UNVR **never** get WAN.

## 9. Observability

- **Logs** → journald inside each container. Future: forward to a central `homesec-syslog` LXC.
- **Metrics** → optional. A small Prometheus + Grafana stack in LXC is fine later, but do not build it on day one.
- **Alerts** → ntfy for high-signal events (AI detections, disk-full, link-down). Low-signal goes to logs, nothing else.

## 10. Do-not list

- Do not enable `nesting=1` unless a specific service genuinely requires it. Document why in that container's README if you do.
- Do not run containers as **privileged** in HomeSec.
- Do not disable AppArmor on a container.
- Do not expose any HomeSec service directly to WAN. Remote access goes through Tailscale or WireGuard back into the LAN.
- Do not commit secrets.
- Do not install `:latest` tags or run `curl | sudo bash` — always pin and verify.
- Do not skip snapshots before risky operations.
- Do not manage services via cron, nohup, or tmux — systemd or nothing.
- Do not hand-edit files in a container without also updating the canonical version in this repo. If the repo drifts from reality, the repo is wrong — fix it.
