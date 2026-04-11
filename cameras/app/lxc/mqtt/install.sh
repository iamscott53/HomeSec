#!/usr/bin/env bash
#
# install.sh — install / upgrade Mosquitto inside homesec-cameras-mqtt LXC.
#
# Idempotent: safe to re-run. Snapshot the LXC before running:
#     pct snapshot 202 pre-mosquitto-upgrade
#
# Mosquitto comes from the Debian 12 main apt repo, which is signed by the
# Debian archive key. No manual SHA256 pinning needed — the apt trust root
# is the Debian Release file signature.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root inside the LXC." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/mosquitto.conf" ]]; then
  echo "ERROR: mosquitto.conf not found next to install.sh." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends mosquitto mosquitto-clients

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
install -d -m 0755 -o mosquitto -g mosquitto /var/lib/mosquitto
install -d -m 0755 -o root      -g mosquitto /etc/mosquitto
install -d -m 0755 -o root      -g mosquitto /etc/mosquitto/conf.d

# ---------------------------------------------------------------------------
# Config — only install if not already present (preserves operator edits).
# The shipped default is also dropped as a diff marker at conf.d/99-homesec-default.conf
# so operators can see what the installer would have written without
# clobbering their live config.
# ---------------------------------------------------------------------------
install -m 0644 -o root -g mosquitto "${SCRIPT_DIR}/mosquitto.conf" /etc/mosquitto/conf.d/99-homesec-default.conf
if [[ ! -f /etc/mosquitto/conf.d/homesec.conf ]]; then
  install -m 0644 -o root -g mosquitto "${SCRIPT_DIR}/mosquitto.conf" /etc/mosquitto/conf.d/homesec.conf
  echo ">> Installed default /etc/mosquitto/conf.d/homesec.conf"
else
  echo ">> Leaving existing /etc/mosquitto/conf.d/homesec.conf untouched."
  echo "   Shipped default is at /etc/mosquitto/conf.d/99-homesec-default.conf for diffing."
fi

# ---------------------------------------------------------------------------
# Password + ACL files — create empty placeholders if missing so mosquitto
# can start. The operator fills them in with `mosquitto_passwd` + editing.
# ---------------------------------------------------------------------------
if [[ ! -f /etc/mosquitto/passwd ]]; then
  touch /etc/mosquitto/passwd
  chmod 0640 /etc/mosquitto/passwd
  chown root:mosquitto /etc/mosquitto/passwd
  echo ">> Created empty /etc/mosquitto/passwd — add users with 'mosquitto_passwd /etc/mosquitto/passwd <username>'."
fi

if [[ ! -f /etc/mosquitto/acl ]]; then
  cat > /etc/mosquitto/acl <<'EOF'
# HomeSec Mosquitto ACL — edit before adding users.
# Anonymous access is denied by the shipped config; every user must match
# one of these rules. See README.md for the recommended user/topic layout.

# homesec-admin: read+write everything (for operator debugging).
# user homesec-admin
# topic readwrite #

# frigate: publishes frigate/*, reads its own LWT.
# user frigate
# topic write frigate/#
# topic read frigate/available

# homesec-cameras-analyzer: subscribes to frigate/*, publishes to
# homesec/cameras/alerts/*.
# user homesec-cameras-analyzer
# topic read frigate/#
# topic write homesec/cameras/alerts/#
EOF
  chmod 0640 /etc/mosquitto/acl
  chown root:mosquitto /etc/mosquitto/acl
  echo ">> Created /etc/mosquitto/acl template. Uncomment and adjust before adding users."
fi

# ---------------------------------------------------------------------------
# Start + enable
# ---------------------------------------------------------------------------
systemctl enable mosquitto
systemctl restart mosquitto

# Sanity check the broker is listening
sleep 1
if ! systemctl is-active --quiet mosquitto; then
  echo "ERROR: mosquitto failed to start. Check 'journalctl -u mosquitto -n 50'." >&2
  exit 1
fi

echo
echo "Mosquitto installed and running."
echo "Next steps:"
echo "  1. Create users:"
echo "       mosquitto_passwd -c /etc/mosquitto/passwd homesec-admin"
echo "       mosquitto_passwd    /etc/mosquitto/passwd frigate"
echo "       mosquitto_passwd    /etc/mosquitto/passwd homesec-cameras-analyzer"
echo "  2. Edit /etc/mosquitto/acl (uncomment the template rules)."
echo "  3. systemctl restart mosquitto"
echo "  4. Test with mosquitto_sub / mosquitto_pub (see README.md)."
