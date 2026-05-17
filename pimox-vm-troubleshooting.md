# PiMox VM Troubleshooting Checklist

ARM64-specific gotchas for creating and booting VMs on a Proxmox node running on a Raspberry Pi.

---

## 1. Image / OS selection

- [ ] **Use a generic ARM64 image** — not Raspberry Pi OS. RPi OS uses the Pi's VideoCore GPU bootloader and has no EFI partition. It cannot boot in a VM.
- [ ] **Confirm the image is ARM64 (aarch64)** — x86/amd64 images will not run (no emulation layer at useful speed).
- [ ] **Prefer cloud images** (`.qcow2`) over installation ISOs — they boot faster and skip the installer entirely.
  - Debian: `https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2`
  - Ubuntu: `https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img`
- [ ] **If using an ISO**, confirm it has a proper EFI System Partition — in the UEFI boot manager, "Boot from file" should let you browse folders (`EFI/BOOT/BOOTAA64.EFI`), not prompt you to create files.

---

## 2. VM hardware configuration

These settings must be changed from Proxmox defaults — the defaults are x86-specific.

| Setting | Wrong (x86 default) | Correct for ARM64 |
|---------|--------------------|--------------------|
| Machine type | `q35` or `i440fx` | **`virt`** |
| BIOS | SeaBIOS | **OVMF (UEFI)** |
| CPU type | `kvm64` or `x86-64-v2` | **`host`** |
| SCSI controller | LSI or MegaRAID | **VirtIO SCSI** or **VirtIO SCSI single** |
| Display | `std` VGA or SPICE/QXL | **VirtIO-GPU** or **Serial terminal** |

- [ ] Machine type is `virt`
- [ ] BIOS is OVMF (UEFI)
- [ ] An EFI disk is attached (Proxmox prompts for this when you select OVMF)
- [ ] CPU type is `host`
- [ ] SCSI controller is VirtIO SCSI or VirtIO SCSI single (not LSI/MegaRAID)
- [ ] Display is VirtIO-GPU or Serial terminal — **SPICE/QXL does not work on ARM64**

---

## 3. Storage and disks

- [ ] **EFI disk is on local storage** (local-lvm, local dir) — NFS-backed EFI disks cause silent failures where UEFI can write but boot entries don't persist across reboots.
- [ ] **EFI disk is at least 4 MB** — create with `efitype=4m`:
  ```bash
  qm set <vmid> -efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
  ```
- [ ] **VM disk is attached as SCSI** (scsi0), not IDE or VirtIO block.
- [ ] **Boot order is set** to the correct disk — check under Options → Boot Order.
- [ ] **For cloud images**: after `qm importdisk`, the disk starts as "unused" — go to Hardware → unused disk → Edit to attach it as scsi0.

---

## 4. UEFI / boot manager

- [ ] If "No bootable device found": open the UEFI boot manager (Proxmox console → boot → any key or Esc during POST).
- [ ] **Boot from file** should show a browsable folder tree (`EFI → BOOT → BOOTAA64.EFI`). If it only shows a raw device path and asks you to create files, the EFI partition is unreadable — wrong image type or disk not attached correctly.
- [ ] To boot manually: Boot Manager → Boot from file → navigate to `EFI\BOOT\BOOTAA64.EFI`.
- [ ] If boot entries don't persist after OS install: EFI disk is likely on NFS (see storage section).
- [ ] Secure Boot: set `pre-enrolled-keys=0` to disable — unsigned ARM64 bootloaders will be silently blocked otherwise.

---

## 5. Console / display

- [ ] **VirtIO-GPU**: works in the Proxmox noVNC web console. Set under Hardware → Display.
- [ ] **Serial console** (most reliable for cloud images):
  1. Hardware → Add → Serial Port → 0
  2. Hardware → Display → Serial terminal 0
  3. Or connect from Proxmox shell: `qm terminal <vmid>` (exit with `Ctrl+O`)
- [ ] **SPICE/QXL**: not supported on ARM64 `virt` machine type — use VirtIO-GPU instead.
- [ ] If the console shows nothing: display type is probably set to `std` VGA — change to VirtIO-GPU or Serial.

---

## 6. Cloud image first boot

Cloud images have no password and no SSH keys by default. They need cloud-init to configure access.

- [ ] **Add a CloudInit drive**: Hardware → Add → CloudInit Drive (pick any storage).
- [ ] **Set credentials**: Cloud-Init tab → User, Password, SSH public key.
- [ ] **Click "Regenerate Image"** after changing any Cloud-Init values.
- [ ] Reboot after regenerating — cloud-init only runs on first boot (or when the instance-id changes).
- [ ] Default username on Debian cloud images is **`debian`**, not `root`.
- [ ] **Use `sudo -i`** for root access — root has no password on cloud images, so `su` will always fail.
- [ ] If SSH responds but rejects keys: cloud-init may not have run yet — use the serial console to check `/var/log/cloud-init-output.log`.

---

## 7. Quick diagnostic commands

Run these from the Proxmox node shell:

```bash
# Check VM status and config
qm status <vmid>
qm config <vmid>

# Connect to serial console
qm terminal <vmid>

# View VM logs (QEMU output, including early boot errors)
journalctl -u pve-qemu-server@<vmid> -n 50

# Check if EFI disk is local or NFS
pvesm status
qm config <vmid> | grep efidisk
```

---

## 8. Known working baseline config

```bash
qm create 100 \
  --name debian-arm64 \
  --machine virt \
  --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host \
  --cores 2 --memory 2048 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --scsi0 <storage>:0,import-from=/path/to/debian-12-genericcloud-arm64.qcow2 \
  --serial0 socket \
  --vga serial0 \
  --boot order=scsi0
```

Add cloud-init drive and credentials after creation:
```bash
qm set 100 --ide2 local-lvm:cloudinit
qm set 100 --ciuser debian --cipassword <pass> --sshkeys ~/.ssh/id_rsa.pub
qm cloudinit update 100
```
