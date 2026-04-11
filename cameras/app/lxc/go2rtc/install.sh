#!/usr/bin/env bash
#
# install.sh — install / upgrade go2rtc inside the homesec-cameras-go2rtc LXC.
#
# Idempotent: safe to re-run for upgrades. Snapshot the LXC before running:
#     pct snapshot <CTID> pre-go2rtc-upgrade
#
# Run as root inside the target LXC, from the directory containing this
# script along with go2rtc.service and go2rtc.yaml.

set -euo pipefail

# ---------------------------------------------------------------------------
# PIN ME: bump these on upgrade. Verify the SHA256 against the official
# checksums.txt on the GitHub release page before committing a change.
#   https://github.com/AlexxIT/go2rtc/releases
# ---------------------------------------------------------------------------
GO2RTC_VERSION="REPLACE_WITH_VERSION"        # e.g. 1.9.2
GO2RTC_ARCH="linux_amd64"                    # linux_amd64 | linux_arm64 | linux_armv7
GO2RTC_SHA256="REPLACE_WITH_SHA256"          # from checksums.txt on the release page

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root inside the LXC." >&2
  exit 1
fi

if [[ "${GO2RTC_VERSION}" == "REPLACE_WITH_VERSION" || "${GO2RTC_SHA256}" == "REPLACE_WITH_SHA256" ]]; then
  echo "ERROR: edit install.sh and set GO2RTC_VERSION + GO2RTC_SHA256 before running." >&2
  echo "       Get them from: https://github.com/AlexxIT/go2rtc/releases" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required in go2rtc.service go2rtc.yaml; do
  if [[ ! -f "${SCRIPT_DIR}/${required}" ]]; then
    echo "ERROR: ${required} not found next to install.sh." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Dependencies (minimal)
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates

# ---------------------------------------------------------------------------
# System user (unprivileged, no shell, no home login)
# ---------------------------------------------------------------------------
if ! id -u go2rtc >/dev/null 2>&1; then
  useradd --system --home /var/lib/go2rtc --shell /usr/sbin/nologin go2rtc
fi
install -d -o go2rtc -g go2rtc -m 0750 /var/lib/go2rtc
install -d -o root   -g go2rtc -m 0750 /etc/go2rtc

# ---------------------------------------------------------------------------
# Download + verify the binary
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

BIN_URL="https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_${GO2RTC_ARCH}"
echo "Downloading ${BIN_URL}"
curl --fail --location --show-error --silent --output "${TMP}/go2rtc" "${BIN_URL}"

echo "${GO2RTC_SHA256}  ${TMP}/go2rtc" | sha256sum --check --strict -
echo "SHA256 verified."

# ---------------------------------------------------------------------------
# Stop the service before replacing the binary (no-op if not installed yet)
# ---------------------------------------------------------------------------
if systemctl is-active --quiet go2rtc 2>/dev/null; then
  systemctl stop go2rtc
fi

install -m 0755 -o root -g root "${TMP}/go2rtc" /usr/local/bin/go2rtc

# ---------------------------------------------------------------------------
# Config — only install if not already present (never overwrite edits)
# ---------------------------------------------------------------------------
if [[ ! -f /etc/go2rtc/go2rtc.yaml ]]; then
  install -m 0640 -o root -g go2rtc "${SCRIPT_DIR}/go2rtc.yaml" /etc/go2rtc/go2rtc.yaml
  echo "Installed default /etc/go2rtc/go2rtc.yaml — edit it with your real RTSP URLs."
else
  echo "Leaving existing /etc/go2rtc/go2rtc.yaml untouched."
fi

# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------
install -m 0644 -o root -g root "${SCRIPT_DIR}/go2rtc.service" /etc/systemd/system/go2rtc.service
systemctl daemon-reload
systemctl enable go2rtc

echo
echo "go2rtc ${GO2RTC_VERSION} installed."
echo "Next steps:"
echo "  1. Edit /etc/go2rtc/go2rtc.yaml (fill in UNVR_IP and STREAM_KEY_PLACEHOLDER values)."
echo "  2. systemctl start go2rtc"
echo "  3. journalctl -u go2rtc -f"
