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
# PIN ME on upgrade. ntfy publishes a checksums.txt file next to each
# release — fetch it and extract the line matching the .deb for your arch:
#   curl -sL https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/checksums.txt | grep "_linux_${NTFY_ARCH}.deb"
#
# The HomeSec CHANGELOG (cameras/CHANGELOG.md) records the currently pinned
# version — keep them in sync.
# ---------------------------------------------------------------------------
NTFY_VERSION="2.21.0"                        # released 2026-03-30
NTFY_ARCH="amd64"                            # amd64 | arm64

# Pinned SHA256 per architecture. Add a new case arm when you add an arch.
case "${NTFY_ARCH}" in
  amd64)
    NTFY_SHA256="c55e26251eb0e86bd7dd59d8e09b86c6770d7c2efce2473e832d8f00e48331ec"
    ;;
  arm64)
    NTFY_SHA256="5e7ed61e0c53ad5c2e6dcb419c1bf3a1adbfcf91580780c9732c74d3c8759eba"
    ;;
  *)
    echo "ERROR: no pinned SHA256 for NTFY_ARCH='${NTFY_ARCH}'." >&2
    echo "       Supported arches: amd64, arm64." >&2
    echo "       To add another, fetch checksums.txt from the release and" >&2
    echo "       add a case arm in install.sh." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root inside the LXC." >&2
  exit 1
fi

# Sanity check that the version and SHA256 both look real (in case an edit
# leaves one half-updated). Versions are semver-ish, SHA256 is 64 hex chars.
if [[ ! "${NTFY_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: NTFY_VERSION='${NTFY_VERSION}' does not look like a semver string." >&2
  exit 1
fi
if [[ ! "${NTFY_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: NTFY_SHA256 is not a 64-char lowercase hex string. Did you forget to update it after bumping the version?" >&2
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
