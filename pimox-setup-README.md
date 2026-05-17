# pimox-setup.sh

Automates the two-phase installation of Proxmox VE on a Raspberry Pi (ARM64) running Debian/Raspberry Pi OS Bookworm.

Based on: https://pimylifeup.com/raspberry-pi-proxmox/

---

## Requirements

- Raspberry Pi 4 or 5 running **64-bit Debian / Raspberry Pi OS (Bookworm or Trixie)**
- Network access to `mirrors.lierfang.com`
- Static IP assignment on your network (DHCP reservation or manual)

---

## Quick start (one-liner)

No need to clone the repo. Pipe directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/beartums/pi-provisioning/main/pimox-setup.sh \
  | sudo bash -s -- --hostname pimox01
```

Pass any options after `--`:

```bash
curl -fsSL https://raw.githubusercontent.com/beartums/pi-provisioning/main/pimox-setup.sh \
  | sudo bash -s -- --hostname pimox01 --ip 192.168.1.50 --gateway 192.168.1.1 -y
```

Network settings (IP, gateway, netmask, DNS, interface) are auto-detected if not provided.

---

## Usage (if you have the repo)

```bash
sudo ./pimox-setup.sh --hostname <name> [options]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--hostname NAME` | Hostname to assign **(required)** | — |
| `--ip ADDR` | Static IP address | Auto-detect from current interface |
| `--gateway ADDR` | Default gateway | Auto-detect from routing table |
| `--netmask MASK` | CIDR prefix length (e.g. `24`) | Auto-detect |
| `--dns ADDR` | DNS server | Auto-detect from `/etc/resolv.conf` |
| `--iface NAME` | Network interface to bridge | Auto-detect default route interface |
| `--root-password PWD` | Root password | Prompt interactively |
| `--skip-upgrade` | Skip `apt update/upgrade` (faster re-runs) | — |
| `-y`, `--yes` | Auto-approve all prompts | — |

### Example

```bash
sudo ./pimox-setup.sh --hostname pimox01 --ip 192.168.1.50 --gateway 192.168.1.1
```

---

## What the script does

### Phase 1 (runs immediately)

1. **Preflight** — Verifies running as root and on `aarch64`; detects OS codename
2. **Network detection** — Auto-detects interface, IP, prefix, gateway, and DNS if not provided; shows summary and prompts for confirmation
3. **System update** — `apt update && apt upgrade`, installs `curl`
4. **Set hostname** — `hostnamectl set-hostname <name>`; codename is validated against known supported releases (bookworm, trixie) with a warning if unrecognised
5. **Update `/etc/hosts`** — Removes old hostname entries, adds `<static-ip>  <hostname>`; backs up original to `/etc/hosts.pimox-backup-*`
6. **Disable cloud-init hostname management** — Writes `/etc/cloud/cloud.cfg.d/99-pimox-hostname.cfg` (`preserve_hostname: true`, `manage_etc_hosts: false`) and comments out `set_hostname`, `update_hostname`, and `update_etc_hosts` modules in the main `cloud.cfg`, so cloud-init cannot overwrite the hostname or `/etc/hosts` on subsequent boots
7. **Set root password** — Uses `--root-password` if provided (via `chpasswd`, suitable for automation); otherwise prompts interactively. Required for Proxmox web UI login
8. **Add PiMox GPG key** — Fetches and dearmors the release key from `mirrors.lierfang.com` into `/etc/apt/trusted.gpg.d/`
9. **Add PiMox apt repository** — Writes the `pve-no-subscription` repo to `/etc/apt/sources.list.d/pveport.list`; refreshes apt cache
10. **Disable NetworkManager** — Stops, disables, and masks `NetworkManager` (conflicts with Proxmox's bridge networking)
11. **Install ifupdown2** — Installs the Debian-native network interface manager used by Proxmox
12. **Configure network bridge** — Writes `/etc/network/interfaces` setting up `vmbr0` as a Linux bridge over the detected interface with the static IP; backs up original
13. **Register post-reboot installer service** — Creates `/usr/local/sbin/pimox-install.sh` and a one-shot systemd service (`pimox-install.service`) that runs once on the next boot to complete Phase 2

### Phase 2 (runs automatically on first reboot)

The `pimox-install.service` systemd unit fires after `network-online.target` and:

- Pre-seeds `debconf` for `postfix` (local-only, non-interactive)
- Installs: `proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64`
- Removes the "no valid subscription" nag from the web UI and installs a dpkg hook (`86pve-nag-buster`) so the patch re-applies automatically after upgrades
- Logs all output to `/var/log/pimox-install.log`
- Disables itself so it does not run again on subsequent reboots

---

## After installation

Access the Proxmox web UI at:

```
https://<your-ip>:8006
```

Log in as `root` with the password set in Step 7.

### Optional cleanup

```bash
# Remove enterprise repo (causes apt warnings without a subscription)
rm -f /etc/apt/sources.list.d/pve-enterprise.list
apt-get update
```

The "no valid subscription" nag is removed automatically during Phase 2.

---

## Monitoring Phase 2

If Phase 2 is still running or you want to check the result:

```bash
# Live log tail
tail -f /var/log/pimox-install.log

# Systemd journal
journalctl -u pimox-install.service -f

# Service status
systemctl status pimox-install.service
```
