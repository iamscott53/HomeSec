#!/usr/bin/env bash
#
# install.sh — provision Frigate inside the homesec-cameras-frigate VM.
#
# This script runs inside the Debian 12 VM, NOT on the Proxmox host. It
# assumes the host has already completed the GPU + Coral USB passthrough
# steps in cameras/docs/nvidia-gpu-passthrough.md Part 1 and Part 2, and
# that the VM has been booted with both devices attached.
#
# Idempotent: safe to re-run for upgrades. Snapshot the VM before running:
#     qm snapshot 210 pre-frigate-upgrade
#
# Run as root (or via sudo) from the directory containing this script,
# docker-compose.yml, and frigate.yml.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root inside the VM." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for required in docker-compose.yml frigate.yml; do
  if [[ ! -f "${SCRIPT_DIR}/${required}" ]]; then
    echo "ERROR: ${required} not found next to install.sh." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Verify passthrough devices are visible before we start installing anything.
# Failing fast here saves 20 minutes of Docker installs on a broken VM.
# ---------------------------------------------------------------------------
echo ">> Verifying NVIDIA GPU is visible to the VM..."
if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
  echo "ERROR: no NVIDIA GPU found in 'lspci'. PCIe passthrough is not working." >&2
  echo "       See cameras/docs/nvidia-gpu-passthrough.md for host preflight steps." >&2
  exit 1
fi
echo "   NVIDIA GPU present."

echo ">> Verifying Coral USB Accelerator is visible to the VM..."
if ! lsusb 2>/dev/null | grep -qi -E 'google|coral|unichip'; then
  echo "ERROR: no Coral USB Accelerator found in 'lsusb'. USB passthrough is not working." >&2
  echo "       Check 'qm set 210 --usb0 host=BUS-PORT' on the Proxmox host." >&2
  exit 1
fi
echo "   Coral present."

# ---------------------------------------------------------------------------
# Base dependencies
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  qemu-guest-agent unattended-upgrades

# ---------------------------------------------------------------------------
# NVIDIA driver (Debian 12 repo).
# Skip if already installed (idempotent).
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo ">> Installing NVIDIA driver from Debian contrib/non-free-firmware..."
  sed -i 's|main$|main contrib non-free-firmware|' /etc/apt/sources.list
  apt-get update
  apt-get install -y "linux-headers-$(uname -r)" nvidia-driver firmware-misc-nonfree
  echo ">> NVIDIA driver installed. REBOOT REQUIRED before continuing."
  echo "   After reboot, re-run this script."
  exit 0
fi

echo ">> Verifying nvidia-smi works..."
if ! nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi installed but can't talk to the GPU." >&2
  echo "       Try rebooting the VM. If still broken, see the Troubleshooting" >&2
  echo "       section of cameras/docs/nvidia-gpu-passthrough.md." >&2
  exit 1
fi
echo "   nvidia-smi OK."

# ---------------------------------------------------------------------------
# Docker CE from the official apt repo.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo ">> Installing Docker CE from docker.com apt repo..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod 0644 /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# ---------------------------------------------------------------------------
# NVIDIA Container Toolkit (lets Docker containers see the GPU).
# ---------------------------------------------------------------------------
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  echo ">> Installing NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

# ---------------------------------------------------------------------------
# Smoke-test the GPU inside a container before deploying Frigate.
# ---------------------------------------------------------------------------
echo ">> Testing GPU access from a throwaway container..."
if ! docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "WARNING: GPU smoke test failed. Check 'docker run --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi' manually." >&2
  echo "         Proceeding anyway, but Frigate will fail to use the GPU." >&2
fi

# ---------------------------------------------------------------------------
# Coral runtime (libedgetpu from Google's apt repo).
# ---------------------------------------------------------------------------
if ! dpkg -l | grep -q libedgetpu1-std; then
  echo ">> Installing libedgetpu1-std from Google Coral apt repo..."
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/coral-edgetpu.gpg
  echo "deb [signed-by=/etc/apt/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" \
    > /etc/apt/sources.list.d/coral-edgetpu.list
  apt-get update
  apt-get install -y libedgetpu1-std
fi

# ---------------------------------------------------------------------------
# Frigate directory layout + config install
# ---------------------------------------------------------------------------
install -d -m 0755 /var/lib/frigate
install -d -m 0755 /var/lib/frigate/config
install -d -m 0755 /var/lib/frigate/media
install -d -m 0755 /var/lib/frigate/db
install -d -m 0700 /var/lib/frigate/secrets

install -m 0644 "${SCRIPT_DIR}/docker-compose.yml" /var/lib/frigate/docker-compose.yml
if [[ ! -f /var/lib/frigate/config/config.yml ]]; then
  install -m 0640 "${SCRIPT_DIR}/frigate.yml" /var/lib/frigate/config/config.yml
  echo ">> Installed default /var/lib/frigate/config/config.yml — edit it with real values before starting Frigate."
else
  echo ">> Leaving existing /var/lib/frigate/config/config.yml untouched."
fi

# ---------------------------------------------------------------------------
# RTSP password placeholder file for the docker-compose secret.
# NEVER put the real password in git or in this script. The operator drops
# the real value into this file after running install.sh.
# ---------------------------------------------------------------------------
if [[ ! -f /var/lib/frigate/secrets/rtsp_password ]]; then
  umask 0077
  echo "PLACEHOLDER_EDIT_ME" > /var/lib/frigate/secrets/rtsp_password
  chmod 0600 /var/lib/frigate/secrets/rtsp_password
  echo ">> Wrote placeholder RTSP password at /var/lib/frigate/secrets/rtsp_password"
  echo "   Edit it with the real value before starting Frigate."
fi

# ---------------------------------------------------------------------------
# Check that the image tag in docker-compose.yml has been pinned. Refuse
# to pull if it still says PIN_ME_BEFORE_INSTALL.
# ---------------------------------------------------------------------------
if grep -q 'PIN_ME_BEFORE_INSTALL' /var/lib/frigate/docker-compose.yml; then
  echo
  echo "NOTE: docker-compose.yml has PIN_ME_BEFORE_INSTALL placeholder."
  echo "      Edit /var/lib/frigate/docker-compose.yml and pin a real Frigate version"
  echo "      from https://github.com/blakeblackshear/frigate/releases,"
  echo "      then run: docker compose -f /var/lib/frigate/docker-compose.yml up -d"
  echo
  exit 0
fi

echo ">> Pulling Frigate image..."
(cd /var/lib/frigate && docker compose pull)

echo ">> Starting Frigate..."
(cd /var/lib/frigate && docker compose up -d)

echo
echo "Frigate installed and started."
echo "Next steps:"
echo "  1. Tail logs:      docker compose -f /var/lib/frigate/docker-compose.yml logs -f"
echo "  2. Web UI:         http://<vm-ip>:5000"
echo "  3. Fill in real values in /var/lib/frigate/config/config.yml and restart."
echo "  4. Snapshot the VM from the Proxmox host: qm snapshot 210 post-install"
