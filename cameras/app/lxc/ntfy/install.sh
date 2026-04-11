#!/usr/bin/env bash
#
# install.sh — install / upgrade ntfy inside the homesec-cameras-ntfy LXC.
#
# Idempotent: safe to re-run for upgrades. Snapshot the LXC before running:
#     pct snapshot <CTID> pre-ntfy-upgrade
#
# Run as root inside the target LXC, from the directory containing this
# script along with server.yml.

set -euo pipefail

# ---------------------------------------------------------------------------
# PIN ME: bump on upgrade. Verify the SHA256 against the release page
# (GitHub automatically attaches sha256 sums to the release assets page):
#   https://github.com/binwiederhier/ntfy/releases
# ---------------------------------------------------------------------------
NTFY_VERSION="REPLACE_WITH_VERSION"          # e.g. 2.11.0
NTFY_ARCH="amd64"                            # amd64 | arm64 | armv7
NTFY_SHA256="REPLACE_WITH_SHA256"            # sha256 of the .deb file

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root inside the LXC." >&2
  exit 1
fi

if [[ "${NTFY_VERSION}" == "REPLACE_WITH_VERSION" || "${NTFY_SHA256}" == "REPLACE_WITH_SHA256" ]]; then
  echo "ERROR: edit install.sh and set NTFY_VERSION + NTFY_SHA256 before running." >&2
  echo "       Get them from: https://github.com/binwiederhier/ntfy/releases" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/server.yml" ]]; then
  echo "ERROR: server.yml not found next to install.sh." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates

# ---------------------------------------------------------------------------
# Download + verify the .deb
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

DEB_NAME="ntfy_${NTFY_VERSION}_linux_${NTFY_ARCH}.deb"
DEB_URL="https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/${DEB_NAME}"

echo "Downloading ${DEB_URL}"
curl --fail --location --show-error --silent --output "${TMP}/${DEB_NAME}" "${DEB_URL}"

echo "${NTFY_SHA256}  ${TMP}/${DEB_NAME}" | sha256sum --check --strict -
echo "SHA256 verified."

# ---------------------------------------------------------------------------
# Stop the service before replacing (no-op on first install)
# ---------------------------------------------------------------------------
if systemctl is-active --quiet ntfy 2>/dev/null; then
  systemctl stop ntfy
fi

# ---------------------------------------------------------------------------
# Install. dpkg -i handles both first install and upgrade.
# ---------------------------------------------------------------------------
dpkg -i "${TMP}/${DEB_NAME}"

# ---------------------------------------------------------------------------
# Config — only install if not already present (preserves operator edits)
# ---------------------------------------------------------------------------
install -d -o root -g root -m 0755 /etc/ntfy
if [[ ! -f /etc/ntfy/server.yml.homesec-default ]] || ! cmp -s "${SCRIPT_DIR}/server.yml" /etc/ntfy/server.yml.homesec-default; then
  # Always refresh the "default" marker copy so operators can see what this
  # installer would have written, without clobbering their edits to the
  # live config.
  install -m 0640 -o root -g ntfy "${SCRIPT_DIR}/server.yml" /etc/ntfy/server.yml.homesec-default
fi
if [[ ! -f /etc/ntfy/server.yml ]]; then
  install -m 0640 -o root -g ntfy "${SCRIPT_DIR}/server.yml" /etc/ntfy/server.yml
  echo "Installed default /etc/ntfy/server.yml."
else
  echo "Leaving existing /etc/ntfy/server.yml untouched."
  echo "The shipped default is at /etc/ntfy/server.yml.homesec-default for diffing."
fi

# ---------------------------------------------------------------------------
# Ensure state dirs exist with correct ownership
# ---------------------------------------------------------------------------
install -d -o ntfy -g ntfy -m 0750 /var/lib/ntfy
install -d -o ntfy -g ntfy -m 0750 /var/lib/ntfy/attachments

# ---------------------------------------------------------------------------
# Start + enable
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable ntfy
systemctl restart ntfy

echo
echo "ntfy ${NTFY_VERSION} installed."
echo "Next steps:"
echo "  1. Create an admin user:"
echo "       sudo ntfy user add --role=admin homesec-admin"
echo "  2. Create a write-only user for the cameras backend:"
echo "       sudo ntfy user add homesec-cameras-backend"
echo "       sudo ntfy access homesec-cameras-backend homesec-cameras write"
echo "       sudo ntfy access homesec-admin homesec-cameras read"
echo "  3. Save the passwords in your secrets manager (NOT in git)."
echo "  4. Send a test:"
echo "       curl -u homesec-admin:PASSWORD -d \"test\" http://localhost/homesec-cameras"
