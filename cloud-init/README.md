# cloud-init provisioning

Flash and fully provision a Raspberry Pi SD card in one command using cloud-init.
Requires **RPi OS Bookworm or newer** (cloud-init is built in). Ubuntu images are also supported.

All provisioning config is generated from scratch at flash time — no Raspberry Pi Imager
needed, no firstrun script injection, no `cmdline.txt` patching. The Pi boots directly
into cloud-init, which handles everything.

---

## Quick start

```bash
# Minimal — prompts for password, skips NAS
./download-and-flash-cloud-init.sh --hostname mypi

# Full example
./download-and-flash-cloud-init.sh \
  --hostname mypi \
  --distro rpios-lite-64 \
  --device /dev/disk4 \
  --pi-user beartums --pi-password secret \
  --timezone America/New_York \
  --nas-host 192.168.1.10 --nas-user eric --nas-password secret \
  --wifi-ssid MyNetwork --wifi-password wifipass
```

### Windows

Run the PowerShell script from an **administrator** terminal. It downloads the image, flashes
the SD card, and writes the cloud-init config in one step:

```powershell
# Interactive (prompts for distro, disk, password)
.\download-and-flash-cloud-init.ps1 -Hostname mypi

# Fully specified
.\download-and-flash-cloud-init.ps1 -Hostname mypi -Distro rpios-lite-64 -Disk 1 `
  -PiUser beartums -Timezone America/New_York `
  -NasHost 192.168.1.10 -NasUser eric `
  -WifiSsid MyNetwork -WifiPassword wifipass

# Already-flashed card — skip download and flash, write config only
.\download-and-flash-cloud-init.ps1 -BootDrive E: -Hostname mypi
```

Requires:
- **Administrator** PowerShell (right-click → "Run as administrator") for SD card write
- **WSL2** (preferred) or **Python 3.12** for SHA-512 password hashing — `wsl --install`
- **7-Zip** or WSL2 for image decompression — [7-zip.org](https://www.7-zip.org/)

---

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--device DEV` | SD card device (e.g. `/dev/disk4`, `/dev/sdb`) | Interactive list |
| `--distro ID` | Distro key or menu number | Interactive menu |
| `--hostname NAME` | Pi hostname | `raspberrypi` |
| `--pi-user USER` | Username to create | `beartums` |
| `--pi-password PASS` | User password | Prompt |
| `--timezone TZ` | Timezone (e.g. `America/New_York`) | `America/New_York` |
| `--no-ssh` | Disable SSH | — |
| `--wifi-ssid SSID` | WiFi network name | — |
| `--wifi-password PASS` | WiFi password | — |
| `--cache-dir DIR` | Image cache directory | `~/.pi-images` |
| `--no-cache` | Force re-download | — |
| `--nas-host HOST` | NAS hostname or IP | — |
| `--nas-share NAME` | NAS share name | `grifData` |
| `--nas-user USER` | CIFS username | Prompt |
| `--nas-password PASS` | CIFS password | Prompt |
| `--nas-creds FILE` | Path to existing CIFS credentials file | — |
| `--docker-user USER` | User to add to docker group | same as `--pi-user` |
| `--skip-nas` | Skip NAS mount setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `--skip-display` | Skip ssd1306 OLED display setup | — |
| `-y`, `--yes` | Auto-approve non-destructive prompts | — |

> The device confirmation always requires typing `yes` — it is never auto-skipped.

---

## Available distros

| Key | Description | Size |
|-----|-------------|------|
| `rpios-lite-64` | Raspberry Pi OS Lite 64-bit **(default)** | ~500 MB |
| `rpios-desktop-64` | Raspberry Pi OS Desktop 64-bit | ~1.2 GB |
| `ubuntu-2404` | Ubuntu Server 24.04 LTS 64-bit | ~1.1 GB |
| `ubuntu-2204` | Ubuntu Server 22.04 LTS 64-bit | ~700 MB |

Images are cached in `~/.pi-images/` and reused if less than 7 days old.

---

## What the script does

### At flash time (on your Mac/Linux machine)

1. Downloads and decompresses the selected image
2. Flashes it to the SD card with `dd`
3. Generates the following files on the boot partition:

| File | Purpose |
|------|---------|
| `user-data` | Full cloud-init config — user, SSH, packages, provisioning script |
| `meta-data` | Fresh instance-id to ensure cloud-init runs on first boot |
| `cmdline.txt` | Updated `ds=nocloud;i=<id>` to match meta-data |
| `config.txt` | `dtparam=i2c_arm=on` uncommented to enable i2c |
| `network-config` | WiFi config (if `--wifi-ssid` passed), otherwise a commented template |

### On first boot (automatic, no SSH needed)

Cloud-init runs in stages. By the time `runcmd` fires, packages are already installed.

**cloud-init config stage:**
- Sets hostname and `/etc/hosts`
- Creates user with full RPi OS group membership (`gpio`, `spi`, `i2c`, `render`, etc.)
- Enables SSH (if not `--no-ssh`)
- Sets timezone and keyboard layout
- Enables i2c via `rpi.interfaces`
- Installs packages: `avahi-daemon`, `i2c-tools`, `cifs-utils` (if NAS enabled)
- Writes `/etc/cifs-credentials` (if NAS enabled)
- Writes `/etc/ssd1306.conf` with default display config (if display enabled)
- Writes `/usr/local/sbin/pi-provision.sh`

**cloud-init final stage (runcmd):**
- Calls `/usr/local/sbin/pi-provision.sh`, which:
  1. Waits for apt lock (up to 3 minutes)
  2. Unblocks WiFi via rfkill
  3. Adds NAS fstab entry and tests mount (if enabled)
  4. Installs Docker via `get.docker.com`, adds user to docker group (if enabled)
  5. Installs ssd1306 OLED display driver from `beartums/U6143_ssd1306` (if enabled)

---

## ssd1306 OLED display

The script installs the [beartums/U6143_ssd1306](https://github.com/beartums/U6143_ssd1306)
display driver, which shows system stats on a small OLED screen over i2c.

i2c is enabled in two ways for redundancy: `config.txt` (`dtparam=i2c_arm=on`) at flash time,
and `rpi.interfaces.i2c: true` in cloud-init.

A default `/etc/ssd1306.conf` is pre-seeded at flash time:

```ini
show_temperature=1   show_memory=1     show_disk=1
show_ip=1            show_hostname=1   show_clock=1
show_uptime=1        show_docker=1     # (0 if --skip-docker)
temp_unit=fahrenheit  screen_time=3    top_line=hostname
```

Edit `/etc/ssd1306.conf` on the Pi and restart the service to change what's displayed:
```bash
sudo nano /etc/ssd1306.conf
sudo systemctl restart ssd1306-display
```

---

## Logs

Both logs are on the Pi after first boot:

| Log | Contents |
|-----|----------|
| `/var/log/pi-provisioning.log` | Timestamped output from `pi-provision.sh` |
| `/var/log/cloud-init-output.log` | Full cloud-init output including package installs |

```bash
# Follow provisioning in real time after first boot
ssh beartums@mypi.local 'tail -f /var/log/pi-provisioning.log'
```

---

## Security note

NAS credentials are written to `user-data` on the FAT32 boot partition at flash time and
moved to `/etc/cifs-credentials` (chmod 600) by cloud-init during first boot. They are
readable by anyone with physical access to the SD card until the Pi has completed its
first boot. Fine for a home network — keep the card secure until booted.

---

## Testing

`test-cloud-init.sh` validates the generated config and optionally boots a QEMU VM to verify
provisioning end-to-end. It does not touch any SD card or real hardware.

### Static validation — any platform

Generates a test config and runs 16 checks (YAML validity, cmdline.txt, user, sudo, SSH key,
packages, Docker, NAS, display). Requires `bash` and `python3`.

```bash
./test-cloud-init.sh --validate-only --skip-display
```

**Windows**: run in WSL2 or Git Bash (both include bash and python3).

### Full QEMU boot test — macOS or Linux ARM64

Downloads an Ubuntu 24.04 ARM64 cloud image (~600 MB, cached), boots it in QEMU, runs
cloud-init, SSHes in, and checks Docker install, NAS fstab, sudo, and credentials.

```bash
./test-cloud-init.sh --skip-display
```

| Platform | Acceleration | First SSH |
|----------|-------------|-----------|
| macOS Apple Silicon | HVF (auto-detected) | ~30–60 s |
| Linux ARM64 with KVM | KVM (auto-detected) | ~30–60 s |
| Linux x86_64 | TCG (emulated) | Very slow — not recommended |
| Windows | Not supported natively | Use WSL2 |

### Install prerequisites

**macOS**:
```bash
brew install qemu
```

**Ubuntu / Debian**:
```bash
sudo apt install qemu-system-arm qemu-utils ovmf xorriso
```

**Fedora**:
```bash
sudo dnf install qemu-system-aarch64 qemu-img edk2-aarch64 xorriso
```

---

## reference/

Sample files captured from a card prepared by Raspberry Pi Imager, kept here for reference.
These informed the from-scratch generation approach used by `download-and-flash-cloud-init.sh`.
The script does **not** read or merge these files — it generates everything independently.
