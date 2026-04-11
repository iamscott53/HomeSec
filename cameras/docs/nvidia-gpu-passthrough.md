# NVIDIA GPU + Coral USB passthrough — Frigate VM

This doc walks through passing both the NVIDIA GPU (P40 / 3060 / similar) and the Coral Edge TPU USB device to the `homesec-cameras-frigate` VM on Proxmox. It is the specific runbook for the Frigate VM; the general VM standards live in [`../../docs/proxmox-vm-best-practices.md`](../../docs/proxmox-vm-best-practices.md).

**Prerequisites:**
- Proxmox VE 8.x or newer on the host.
- The host has an NVIDIA GPU physically installed (P40, 3060, or equivalent).
- The host has a Coral USB Accelerator plugged in to one of its USB ports.
- The host CPU and motherboard support IOMMU (Intel VT-d or AMD-Vi).
- BIOS has IOMMU enabled.

## Part 1 — Host preflight

All commands in this section run on the Proxmox host, not inside the VM.

### 1. Enable IOMMU in the bootloader

For Intel CPUs, edit `/etc/default/grub` and append to `GRUB_CMDLINE_LINUX_DEFAULT`:

```
intel_iommu=on iommu=pt
```

For AMD:

```
amd_iommu=on iommu=pt
```

Then:

```bash
update-grub
reboot
```

After reboot, verify IOMMU is active:

```bash
dmesg | grep -e DMAR -e IOMMU
# expect lines like: "DMAR: IOMMU enabled"
```

And verify the GPU is in its own IOMMU group (it should be — any modern board separates the GPU):

```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=${d#*/iommu_groups/*}
  n=${n%%/*}
  printf 'IOMMU Group %s: ' "$n"
  lspci -nns "${d##*/}"
done | grep -i nvidia
```

If the GPU shares an IOMMU group with other critical devices (e.g., a SATA controller), that's a problem — passthrough will pull those devices away from the host. On a board where this happens, enable the `pcie_acs_override=downstream,multifunction` kernel parameter as a last resort (security caveat: relaxes PCIe isolation).

### 2. Blacklist the nvidia and nouveau drivers on the host

The host must not load any NVIDIA driver — the VM will own the card.

Create `/etc/modprobe.d/blacklist-nvidia.conf`:

```
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
```

### 3. Bind the GPU to vfio-pci

Find the GPU's PCI device IDs:

```bash
lspci -nn | grep -i nvidia
# e.g. 01:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:2504]
# e.g. 01:00.1 Audio device [0403]: NVIDIA Corporation ... [10de:228e]
```

Note both IDs — the GPU typically has a VGA function AND an audio function that must be passed together. For the P40, there's only the compute function (no audio/display).

Create `/etc/modprobe.d/vfio.conf`:

```
options vfio-pci ids=10de:2504,10de:228e
softdep nvidia pre: vfio-pci
```

Replace the IDs with what `lspci -nn` reported for your card.

Then:

```bash
update-initramfs -u
reboot
```

After reboot, verify:

```bash
lspci -k -s 01:00
# expect: "Kernel driver in use: vfio-pci"
```

### 4. Identify the Coral USB device

```bash
lsusb | grep -i -E 'google|coral'
# e.g. Bus 003 Device 004: ID 18d1:9302 Google Inc.
```

The Coral Accelerator shows up as two possible IDs depending on first-run state:

- **Before first use:** `1a6e:089a Global Unichip Corp.` — unprogrammed
- **After first use:** `18d1:9302 Google Inc.` — programmed

Frigate programs it on first load and it stays programmed. For USB passthrough to a VM, we pass by host bus+port (not by ID) so the rebinding doesn't matter.

Find the Coral's host:bus:port:

```bash
lsusb -t
# 2  Port 003: Dev 004, If 0, Class=, Driver=usbfs, 480M
```

Record the bus and port numbers. Proxmox's `qm set` supports both ID-based and host-based USB passthrough; host-based is more stable across reboots if you keep the Coral in the same port.

## Part 2 — Create the Frigate VM

Also on the Proxmox host. Adjust VMID, storage name, and SSH key path to your environment. Network tag is VLAN 1 (Frigate talks to go2rtc and mqtt on VLAN 1 only — no VLAN 10 NIC needed).

### Cloud-init Debian 12 template

If you don't already have a cloud-init Debian 12 template, create one first following the Proxmox community steps. The rest of this doc assumes a template named `debian-12-cloud` exists.

### Provision the VM

```bash
qm create 210 \
  --name homesec-cameras-frigate \
  --memory 8192 \
  --cores 4 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 local-lvm:0,format=raw \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0,tag=1,firewall=1 \
  --ipconfig0 ip=dhcp \
  --ostype l26 \
  --agent enabled=1 \
  --onboot 1

# Clone the OS disk from the Debian 12 cloud-init template
qm disk import 210 /path/to/debian-12-cloud.qcow2 local-lvm
qm set 210 --scsi0 local-lvm:vm-210-disk-0,cache=writeback,discard=on,iothread=1,ssd=1
qm set 210 --boot order=scsi0
qm set 210 --ide2 local-lvm:cloudinit
qm set 210 --sshkeys ~/.ssh/id_ed25519.pub

# Grow the root disk to 64 GB (Frigate clips need room)
qm resize 210 scsi0 +54G
```

### Attach the NVIDIA GPU

Replace `01:00` with the PCI address you found in `lspci`. Passing both functions (`.0` and `.1`) together:

```bash
qm set 210 --hostpci0 01:00,pcie=1,x-vga=0
```

- `pcie=1` tells Proxmox this is a PCIe (not legacy PCI) device.
- `x-vga=0` means we're NOT using this GPU as the VM's primary display (Frigate is headless; we'll use OVMF's built-in framebuffer for VM console). For a 3060 where you want to use the display, set `x-vga=1` — but that's unusual for a server workload.

### Attach the Coral USB

Pass by host+port so a Coral rebind after first-use doesn't break the mapping:

```bash
qm set 210 --usb0 host=3-3
# where 3-3 is bus 3, port 3 — from `lsusb -t` above
```

Alternatively, if the Coral is on a stable ID after first use:

```bash
qm set 210 --usb0 host=18d1:9302
```

The port-based path is more reliable across reboots.

### Start the VM

```bash
qm start 210
qm terminal 210   # or ssh in via the cloud-init-assigned IP
```

## Part 3 — Inside the VM: drivers and Docker

All commands in this section run inside the Debian 12 VM, not the host.

### 1. Verify the devices are visible

```bash
lspci | grep -i nvidia
# expect: "NVIDIA Corporation ..."

lsusb | grep -i -E 'google|coral|unichip'
# expect: "Google Inc." OR "Global Unichip Corp."
```

### 2. Install NVIDIA drivers

Add contrib and non-free-firmware to apt sources (Debian 12 ships with them off by default):

```bash
sudo sed -i 's|main$|main contrib non-free-firmware|' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install -y linux-headers-$(uname -r) nvidia-driver nvidia-smi
sudo reboot
```

After reboot:

```bash
nvidia-smi
# expect: a table listing your GPU, driver version, and "0 MiB / N MiB" VRAM usage
```

### 3. Install Docker

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

### 4. Install the NVIDIA Container Toolkit

This is what lets Docker containers use the GPU.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify:

```bash
sudo docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
# expect: the same GPU table you saw on the host-inside-VM
```

### 5. Coral runtime

For USB Coral, install libedgetpu:

```bash
echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-get update
sudo apt-get install -y libedgetpu1-std
```

Grant Docker access to the USB device. The cleanest way is to mount `/dev/bus/usb` into the Frigate container — the `docker-compose.yml` shipped under `cameras/app/vm/frigate/` handles this.

### 6. Deploy Frigate

Copy the scaffolded `cameras/app/vm/frigate/` directory onto the VM and run the install script. See [`../app/vm/frigate/README.md`](../app/vm/frigate/README.md).

## Troubleshooting

### `nvidia-smi` fails in the VM

- Confirm `lspci` shows the GPU at all. If not, the passthrough isn't working at the host level — recheck IOMMU and vfio-pci binding.
- If `lspci` shows the GPU but `nvidia-smi` can't talk to it, the driver version in the VM might be too old for the card. Use Debian backports or install a newer driver from NVIDIA directly.
- For Turing/Ampere cards (RTX 20/30 series), historical issues with "Error 43" may require the `hidden=1` flag in `qm set 210 --args '-cpu host,kvm=off'`. Not usually needed for compute-only workloads.

### Coral not found inside the VM

- `lsusb` should show the Coral. If it doesn't, the USB passthrough isn't working. Recheck the bus:port numbers and that you haven't hot-unplugged / re-plugged the Coral on a different port.
- `dmesg | grep -i usb` inside the VM will show attachment errors.

### Frigate container can't see the GPU

- Test with the `nvidia/cuda` sanity container (step 4 above). If that works and Frigate doesn't, the issue is in `docker-compose.yml` — verify `deploy.resources.reservations.devices` specifies `driver: nvidia`.

### Frigate container can't see the Coral

- The container needs `/dev/bus/usb` mounted and `privileged: false, device_cgroup_rules: ['c 189:* rmw']` set in compose. The scaffolded compose file includes this.

## Security notes

- Passing the GPU to a VM is a complete device handoff. The host will not see the GPU again until the VM releases it. Do not use the same card for anything else on the host (no transcoding, no ML in other guests).
- The Frigate VM has access to a hardware device that can run arbitrary GPU workloads. Treat it as a security boundary — don't expose its SSH port to the internet, and keep the VM on VLAN 1 behind pfSense.
- The Coral USB Accelerator has no persistent storage and cannot be "compromised" in a meaningful way, but USB passthrough does expose a physical bus to guest code. Keep other untrusted USB devices off that bus.
- Back up the Frigate VM with `vzdump` before any kernel or driver upgrade.
