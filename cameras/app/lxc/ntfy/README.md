# homesec-cameras-ntfy

Proxmox LXC container that runs **ntfy** — a self-hosted push notification server. The cameras backend POSTs an AI-detection alert here, and ntfy pushes it to your phone via the ntfy mobile app. Fully local, no cloud relay.

- **Suggested CTID:** 201
- **Hostname:** `homesec-cameras-ntfy`
- **Template:** Debian 12 standard
- **Unprivileged:** yes
- **Nesting:** no
- **NICs:** one — `eth0` on VLAN 1 (no VLAN 10 access needed; ntfy doesn't talk to cameras)
- **Resources:** 1 core, 256 MB RAM, 4 GB disk

## Files in this directory

| File | Purpose |
|------|---------|
| `install.sh` | Idempotent install script. Downloads + verifies the pinned ntfy .deb from GitHub releases, installs it (which drops in the upstream systemd unit), and installs our `server.yml` to `/etc/ntfy/server.yml`. |
| `server.yml` | ntfy server config. Secure defaults: `auth-default-access: deny-all`, local auth file, local cache, attachment limits. No anonymous writes. |

> Note: we do NOT ship a custom systemd unit for ntfy. The upstream .deb installs one that's already correct. We just install the config and restart the service.

## Provisioning from the Proxmox shell

Create the LXC on the Proxmox host (adjust bridge, storage, CTID, SSH key):

```bash
pct create 201 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homesec-cameras-ntfy \
  --unprivileged 1 \
  --features nesting=0,keyctl=0 \
  --cores 1 \
  --memory 256 \
  --swap 0 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,tag=1,ip=dhcp,firewall=1 \
  --onboot 1 \
  --start 1 \
  --ssh-public-keys /root/.ssh/authorized_keys
```

Then push the files and run the installer:

```bash
pct push 201 server.yml /root/server.yml
pct push 201 install.sh /root/install.sh
pct exec 201 -- bash -c 'cd /root && chmod +x install.sh && ./install.sh'
```

## First-time user setup

ntfy's `auth-default-access: deny-all` means nothing works until you create at least one user. Do this inside the container:

```bash
# Create an admin user (interactive password prompt)
sudo ntfy user add --role=admin homesec-admin

# Create a write-only user for the cameras backend to post alerts
sudo ntfy user add homesec-cameras-backend

# Grant it write access to the `homesec-cameras` topic only
sudo ntfy access homesec-cameras-backend "homesec-cameras" write

# Grant the admin user read access to subscribe from the ntfy mobile app
sudo ntfy access homesec-admin "homesec-cameras" read
```

Save the `homesec-cameras-backend` password in a secrets manager (NOT in this repo). The cameras backend LXC will need it to authenticate when POSTing alerts.

## Phone setup

1. Install the ntfy app (iOS App Store / F-Droid / Google Play).
2. Add a new subscription pointing at `http://<ntfy-container-ip>/homesec-cameras`.
3. Log in with the `homesec-admin` user.
4. Send a test: `curl -u homesec-admin:PASSWORD -d "test" http://<ntfy-container-ip>/homesec-cameras`.

## Internet egress

`ntfy` needs internet **only during install** (to download the .deb from GitHub). After install it only receives POSTs from the cameras backend on VLAN 1 and serves subscriptions from your phone on VLAN 1. Deny WAN egress from this LXC in pfSense after install.

## Upgrades

Bump `NTFY_VERSION` in `install.sh`, snapshot the container, re-push and re-run. The script stops the service, installs the new .deb, reinstalls the config (preserving edits — it skips if the file already exists), and restarts.

## Do not

- Do not enable `nesting=1`.
- Do not expose the ntfy port to WAN. Phone push notifications work fine over LAN when you're home; for off-home pushes, use Tailscale / WireGuard, NOT a public exposure.
- Do not set `auth-default-access: read-write`. Anyone on VLAN 1 could then spam your phone.
- Do not commit the actual ntfy user passwords to this repo. They live in a secrets manager.
