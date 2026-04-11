# homesec-cameras-mqtt (LXC 202)

Proxmox LXC that runs **Mosquitto**, the MQTT broker that acts as the central event bus between Frigate (publisher) and the analyzer (subscriber). It's also available for any future HomeSec section that wants to publish or consume events locally.

- **Suggested CTID:** 202
- **Hostname:** `homesec-cameras-mqtt`
- **Template:** Debian 12 standard
- **Unprivileged:** yes
- **Nesting:** no
- **NICs:** one — `eth0` on VLAN 1 only
- **Resources:** 1 core, 256 MB RAM, 4 GB disk

## Files in this directory

| File | Purpose |
|---|---|
| `install.sh` | Idempotent install of Mosquitto from Debian's apt repo; installs the hardened `mosquitto.conf` and wires systemd. |
| `mosquitto.conf` | Restrictive broker config: auth required, no anonymous, password_file, acl_file, persistence, journald logging. |

No SHA256 pinning on this one — Mosquitto is installed from the Debian stable apt repo, which is signed by Debian's archive key. That's a different (and entirely acceptable) trust root than the GitHub-release-with-manual-SHA256 pattern used by go2rtc and ntfy.

## Provisioning from the Proxmox shell

```bash
pct create 202 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homesec-cameras-mqtt \
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
pct push 202 mosquitto.conf /root/mosquitto.conf
pct push 202 install.sh     /root/install.sh
pct exec 202 -- bash -c 'cd /root && chmod +x install.sh && ./install.sh'
```

## First-time user setup

Mosquitto's config ships with `allow_anonymous false` and requires a password file. After install, create users inside the container:

```bash
# Admin user (for the operator to inspect topics)
sudo mosquitto_passwd -c /etc/mosquitto/passwd homesec-admin

# Frigate publisher (used in cameras/app/vm/frigate/frigate.yml → mqtt.user)
sudo mosquitto_passwd /etc/mosquitto/passwd frigate

# Analyzer subscriber (used by cameras/app/lxc/analyzer when implemented)
sudo mosquitto_passwd /etc/mosquitto/passwd homesec-cameras-analyzer

# Restart to pick up the new users
sudo systemctl restart mosquitto
```

Then write the ACL file `/etc/mosquitto/acl` to limit who can publish / subscribe to what. Template:

```
# homesec-admin has read+write to everything, for operator debugging.
user homesec-admin
topic readwrite #

# frigate publishes only under frigate/* and its own LWT.
user frigate
topic write frigate/#
topic read frigate/available

# analyzer subscribes to frigate/* and publishes to homesec/cameras/alerts.
user homesec-cameras-analyzer
topic read frigate/#
topic write homesec/cameras/alerts/#
```

Reload after editing:

```bash
sudo systemctl restart mosquitto
```

Save the passwords to a secrets manager (NOT this repo). The analyzer's config file will reference an env var holding its password, not the password itself.

## Test from inside the container

```bash
# Terminal A — subscribe to all frigate events
mosquitto_sub -h 127.0.0.1 -u homesec-admin -P <password> -t 'frigate/#' -v

# Terminal B — publish a test
mosquitto_pub -h 127.0.0.1 -u frigate -P <password> -t frigate/test -m '{"hello":"world"}'
```

Terminal A should print the message immediately.

## Internet egress

Mosquitto needs internet **only during install** (apt update, package pull). Everything in steady-state stays on VLAN 1. Deny WAN egress from the container in pfSense after install.

## Upgrades

```bash
pct snapshot 202 pre-mosquitto-upgrade
pct exec 202 -- apt-get update
pct exec 202 -- apt-get install --only-upgrade mosquitto mosquitto-clients
pct exec 202 -- systemctl restart mosquitto
```

## Do not

- Do not enable `allow_anonymous true`. Anyone on VLAN 1 could inject events and spoof Frigate.
- Do not expose port 1883 to WAN. MQTT has no transport encryption in this config; TLS is a future improvement.
- Do not share passwords across users. Each service gets its own.
- Do not commit the `passwd` or `acl` files to this repo — they live only inside the container.
- Do not run additional services inside this container. Mosquitto is the whole point of this LXC.
