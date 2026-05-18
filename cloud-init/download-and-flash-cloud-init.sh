#!/usr/bin/env bash
# download-and-flash-cloud-init.sh — Flash a Raspberry Pi SD card using cloud-init.
# Targets RPi OS Bookworm+ (which ships with cloud-init built in).
# Generates user-data, meta-data, and updates cmdline.txt + config.txt from scratch.
#
# Usage:
#   ./download-and-flash-cloud-init.sh [options]
#
# Options:
#   --device DEV           SD card device (e.g. /dev/disk4; auto-list if omitted)
#   --distro ID            Distro key or menu number (skips interactive menu)
#   --hostname NAME        Pi hostname (default: raspberrypi)
#   --pi-user USER         Username to create on the Pi (default: beartums)
#   --pi-password PASS     Password for that user (prompt if omitted)
#   --timezone TZ          Timezone (default: America/New_York)
#   --no-ssh               Disable SSH
#   --wifi-ssid SSID       WiFi network name
#   --wifi-password PASS   WiFi password
#   --cache-dir DIR        Image cache directory (default: ~/.pi-images)
#   --no-cache             Force re-download even if cached image exists
#   --nas-host HOST        NAS hostname or IP
#   --nas-share NAME       NAS share name (default: grifData)
#   --nas-user USER        CIFS username
#   --nas-password PASS    CIFS password
#   --nas-creds FILE       Path to CIFS credentials file
#   --docker-user USER     User to add to docker group (default: same as --pi-user)
#   --skip-nas             Skip NAS mount setup
#   --skip-docker          Skip Docker setup
#   --skip-display         Skip ssd1306 OLED display setup
#   --pimox                Install Proxmox VE (two-phase; Pi reboots after first boot)
#   --patch-nag            Remove the Proxmox "no valid subscription" nag from the web UI
#   --root-password PASS   Proxmox root password ('same' to reuse --pi-password; default: prompt)
#   --pimox-ip ADDR        Static IP for Proxmox bridge (default: auto-detect)
#   --pimox-gateway ADDR   Default gateway (default: auto-detect)
#   --pimox-netmask MASK   CIDR prefix length, e.g. 24 (default: auto-detect)
#   --pimox-dns ADDR       DNS server (default: auto-detect)
#   --pimox-iface NAME     Network interface to bridge (default: auto-detect)
#   --ssh-pubkey KEY       SSH public key to add to the user's authorized_keys
#                          (accepts a key string or a path to a .pub file)
#   --boot-path DIR        Skip download+flash; write cloud-init files directly to DIR
#                          (use with a mounted SD card or a temp dir for testing)
#   -y, --yes              Auto-approve non-destructive prompts

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()  { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; exit 1; }

confirm() {
  [[ "$AUTO_YES" == "true" ]] && return 0
  read -rp "$(echo -e "${YELLOW}${1:-Continue?} [y/N]${RESET} ")" ans < /dev/tty
  [[ "${ans,,}" == "y" ]]
}

# ─── Distros ───────────────────────────────────────────────────────────────────
# RPi OS Bookworm+ is required for native cloud-init support.
# Ubuntu images have had cloud-init support since 20.04.
DISTROS=(
  "rpios-lite-64|Raspberry Pi OS Lite 64-bit (recommended)|https://downloads.raspberrypi.com/raspios_lite_arm64_latest|~500 MB|rpios"
  "rpios-desktop-64|Raspberry Pi OS Desktop 64-bit|https://downloads.raspberrypi.com/raspios_arm64_latest|~1.2 GB|rpios"
  "ubuntu-2404|Ubuntu Server 24.04 LTS 64-bit|https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-preinstalled-server-arm64+raspi.img.xz|~1.1 GB|ubuntu"
  "ubuntu-2204|Ubuntu Server 22.04 LTS 64-bit|https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-preinstalled-server-arm64+raspi.img.xz|~700 MB|ubuntu"
)

distro_field() { echo "${DISTROS[$1]}" | cut -d'|' -f"$2"; }

# ─── Defaults ──────────────────────────────────────────────────────────────────
DEVICE=""
DISTRO_ARG=""
PI_HOSTNAME="raspberrypi"
PI_USER="beartums"
PI_PASSWORD=""
TIMEZONE="America/New_York"
ENABLE_SSH=true
WIFI_SSID=""
WIFI_PASSWORD=""
CACHE_DIR="$HOME/.pi-images"
NO_CACHE=false
NAS_HOST=""
NAS_SHARE="grifData"
NAS_USER=""
NAS_PASSWORD=""
NAS_CREDS=""
DOCKER_USER=""
SKIP_NAS=false
SKIP_DOCKER=false
SKIP_DISPLAY=false
PIMOX=false
PATCH_NAG=false
PIMOX_IP=""
PIMOX_GATEWAY=""
PIMOX_NETMASK=""
PIMOX_DNS=""
PIMOX_IFACE=""
ROOT_PASSWORD=""
HASHED_ROOT_PASS=""
BOOT_PATH_ARG=""
SSH_PUBKEY=""
AUTO_YES=false

# ─── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)        DEVICE="$2";        shift 2 ;;
    --distro)        DISTRO_ARG="$2";    shift 2 ;;
    --hostname)      PI_HOSTNAME="$2";   shift 2 ;;
    --pi-user)       PI_USER="$2";       shift 2 ;;
    --pi-password)   PI_PASSWORD="$2";   shift 2 ;;
    --timezone)      TIMEZONE="$2";      shift 2 ;;
    --no-ssh)        ENABLE_SSH=false;   shift ;;
    --wifi-ssid)     WIFI_SSID="$2";     shift 2 ;;
    --wifi-password) WIFI_PASSWORD="$2"; shift 2 ;;
    --cache-dir)     CACHE_DIR="$2";     shift 2 ;;
    --no-cache)      NO_CACHE=true;      shift ;;
    --nas-host)      NAS_HOST="$2";      shift 2 ;;
    --nas-share)     NAS_SHARE="$2";     shift 2 ;;
    --nas-user)      NAS_USER="$2";      shift 2 ;;
    --nas-password)  NAS_PASSWORD="$2";  shift 2 ;;
    --nas-creds)     NAS_CREDS="$2";     shift 2 ;;
    --docker-user)   DOCKER_USER="$2";   shift 2 ;;
    --skip-nas)      SKIP_NAS=true;      shift ;;
    --skip-docker)   SKIP_DOCKER=true;   shift ;;
    --skip-display)  SKIP_DISPLAY=true;  shift ;;
    --pimox)         PIMOX=true;         shift ;;
    --patch-nag)     PATCH_NAG=true;     shift ;;
    --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
    --pimox-ip)      PIMOX_IP="$2";      shift 2 ;;
    --pimox-gateway) PIMOX_GATEWAY="$2"; shift 2 ;;
    --pimox-netmask) PIMOX_NETMASK="$2"; shift 2 ;;
    --pimox-dns)     PIMOX_DNS="$2";     shift 2 ;;
    --pimox-iface)   PIMOX_IFACE="$2";   shift 2 ;;
    --ssh-pubkey)    SSH_PUBKEY="$2";     shift 2 ;;
    --boot-path)     BOOT_PATH_ARG="$2";  shift 2 ;;
    -y|--yes)        AUTO_YES=true;         shift ;;
    -h|--help) grep '^#' "$0" | head -35 | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$DOCKER_USER" ]] && DOCKER_USER="$PI_USER"

# --pimox implies skip-docker and skip-display (Proxmox manages its own containers)
if [[ "$PIMOX" == "true" ]]; then
  SKIP_DOCKER=true
  SKIP_DISPLAY=true
fi

# Resolve --ssh-pubkey to a key string (accept either a literal key or a path to a .pub file)
if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then
  SSH_PUBKEY=$(cat "$SSH_PUBKEY")
fi

HOST_OS=$(uname -s)
[[ "$HOST_OS" == "Darwin" || "$HOST_OS" == "Linux" ]] \
  || die "Unsupported host OS: $HOST_OS"

# ─── Dependencies ──────────────────────────────────────────────────────────────
step "Checking dependencies"
MISSING=()
for cmd in curl dd openssl; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
command -v xz &>/dev/null || MISSING+=("xz")
[[ ${#MISSING[@]} -eq 0 ]] || die "Missing required tools: ${MISSING[*]}"
ok "All dependencies present"

# ─── Credentials ───────────────────────────────────────────────────────────────
# Collected before any device work — needed in both normal and boot-path modes.
step "Pi user credentials"

if [[ -z "$PI_PASSWORD" ]]; then
  read -rsp "$(echo -e "${YELLOW}Password for '${PI_USER}':${RESET} ")" PI_PASSWORD < /dev/tty; echo
  read -rsp "$(echo -e "${YELLOW}Confirm password:${RESET} ")" PI_PASS2 < /dev/tty; echo
  [[ "$PI_PASSWORD" == "$PI_PASS2" ]] || die "Passwords do not match"
fi
HASHED_PASS=$(openssl passwd -6 "$PI_PASSWORD")
ok "Password hashed (SHA-512)"

NAS_CREDS_CONTENT=""
if [[ "$SKIP_NAS" == "false" && -n "$NAS_HOST" ]]; then
  if [[ -n "$NAS_CREDS" ]]; then
    [[ -f "$NAS_CREDS" ]] || die "Credentials file not found: $NAS_CREDS"
    NAS_CREDS_CONTENT=$(cat "$NAS_CREDS")
    ok "NAS credentials: $NAS_CREDS"
  elif [[ -n "$NAS_USER" ]]; then
    if [[ -z "$NAS_PASSWORD" ]]; then
      read -rsp "$(echo -e "${YELLOW}NAS password for ${NAS_USER}:${RESET} ")" NAS_PASSWORD < /dev/tty; echo
    fi
    NAS_CREDS_CONTENT="username=${NAS_USER}
password=${NAS_PASSWORD}"
  else
    read -rp  "$(echo -e "${YELLOW}NAS username:${RESET} ")" NAS_USER < /dev/tty
    read -rsp "$(echo -e "${YELLOW}NAS password:${RESET} ")" NAS_PASSWORD < /dev/tty; echo
    NAS_CREDS_CONTENT="username=${NAS_USER}
password=${NAS_PASSWORD}"
  fi
elif [[ "$SKIP_NAS" == "false" && -z "$NAS_HOST" ]]; then
  info "No --nas-host provided — skipping NAS setup"
  SKIP_NAS=true
fi

# ─── Proxmox root password ─────────────────────────────────────────────────────
if [[ "$PIMOX" == "true" ]]; then
  step "Proxmox root password"
  if [[ "$ROOT_PASSWORD" == "same" ]]; then
    ROOT_PASSWORD="$PI_PASSWORD"
    ok "Root password: reusing pi-user password"
  elif [[ -z "$ROOT_PASSWORD" ]]; then
    read -rsp "$(echo -e "${YELLOW}Proxmox root password [Enter to reuse pi-user password]:${RESET} ")" ROOT_PASSWORD < /dev/tty; echo
    if [[ -z "$ROOT_PASSWORD" ]]; then
      ROOT_PASSWORD="$PI_PASSWORD"
      ok "Root password: reusing pi-user password"
    else
      ok "Root password: set (custom)"
    fi
  else
    ok "Root password: provided via --root-password"
  fi
  HASHED_ROOT_PASS=$(openssl passwd -6 "$ROOT_PASSWORD")
  ok "Root password hashed (SHA-512)"
fi

# ─── Boot-path mode vs normal flash mode ───────────────────────────────────────
BOOT_PATH=""
DISTRO_LABEL=""

if [[ -n "$BOOT_PATH_ARG" ]]; then

  # ── Boot-path mode: skip download and flash, write directly to provided dir ──
  step "Boot-path mode (skipping download and flash)"
  [[ -d "$BOOT_PATH_ARG" ]]             || die "Boot path not found: $BOOT_PATH_ARG"
  [[ -f "$BOOT_PATH_ARG/cmdline.txt" ]] || die "cmdline.txt not found in $BOOT_PATH_ARG — is this a Pi boot partition?"
  BOOT_PATH="$BOOT_PATH_ARG"
  DISTRO_LABEL="(boot-path mode)"
  ok "Using provided boot path: $BOOT_PATH"

else

  # ── Normal mode: distro selection → download → flash → mount ─────────────────
  step "Distribution"

  DISTRO_IDX=-1
  if [[ -n "$DISTRO_ARG" ]]; then
    if [[ "$DISTRO_ARG" =~ ^[0-9]+$ ]]; then
      DISTRO_IDX=$(( DISTRO_ARG - 1 ))
    else
      for i in "${!DISTROS[@]}"; do
        [[ "$(distro_field $i 1)" == "$DISTRO_ARG" ]] && { DISTRO_IDX=$i; break; }
      done
    fi
    [[ $DISTRO_IDX -ge 0 && $DISTRO_IDX -lt ${#DISTROS[@]} ]] \
      || die "Unknown distro: $DISTRO_ARG  (use a number 1-${#DISTROS[@]} or a key)"
  else
    echo
    echo "  Available distributions:"
    echo
    for i in "${!DISTROS[@]}"; do
      KEY=$(distro_field $i 1); LABEL=$(distro_field $i 2); SIZE=$(distro_field $i 4)
      DEFAULT=""; [[ "$KEY" == "rpios-lite-64" ]] && DEFAULT=" ${GREEN}← default${RESET}"
      printf "  ${BOLD}%d)${RESET} %-45s %s%b\n" "$((i+1))" "$LABEL" "$SIZE" "$DEFAULT"
    done
    echo
    read -rp "$(echo -e "${YELLOW}Choose a distro [1]:${RESET} ")" CHOICE < /dev/tty
    CHOICE="${CHOICE:-1}"
    [[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalid selection"
    DISTRO_IDX=$(( CHOICE - 1 ))
    [[ $DISTRO_IDX -ge 0 && $DISTRO_IDX -lt ${#DISTROS[@]} ]] || die "Selection out of range"
  fi

  DISTRO_KEY=$(distro_field $DISTRO_IDX 1)
  DISTRO_LABEL=$(distro_field $DISTRO_IDX 2)
  DISTRO_URL=$(distro_field $DISTRO_IDX 3)
  ok "Selected: $DISTRO_LABEL"

  # ── Image download ────────────────────────────────────────────────────────────
  step "Image download"

  mkdir -p "$CACHE_DIR"
  CACHE_FILE="$CACHE_DIR/${DISTRO_KEY}.img.xz"
  IMG_FILE="$CACHE_DIR/${DISTRO_KEY}.img"

  if [[ "$NO_CACHE" == "false" && -f "$CACHE_FILE" ]]; then
    AGE_DAYS=$(( ( $(date +%s) - $(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0) ) / 86400 ))
    if [[ $AGE_DAYS -lt 7 ]]; then
      ok "Using cached image (${AGE_DAYS}d old): $CACHE_FILE"
    else
      warn "Cached image is ${AGE_DAYS} days old — re-downloading"
      rm -f "$CACHE_FILE" "$IMG_FILE"
    fi
  fi

  if [[ ! -f "$CACHE_FILE" ]]; then
    info "Downloading $DISTRO_LABEL..."
    curl -L --progress-bar -o "$CACHE_FILE" "$DISTRO_URL"
    ok "Download complete: $CACHE_FILE"
  fi

  if [[ ! -f "$IMG_FILE" ]]; then
    info "Decompressing image..."
    xz -dk "$CACHE_FILE"
    XZ_OUT="${CACHE_FILE%.xz}"
    [[ "$XZ_OUT" != "$IMG_FILE" ]] && mv "$XZ_OUT" "$IMG_FILE"
    ok "Decompressed: $IMG_FILE"
  else
    info "Decompressed image already exists: $IMG_FILE"
  fi

  # ── Device selection ──────────────────────────────────────────────────────────
  step "SD card device"

  if [[ -z "$DEVICE" ]]; then
    echo
    if [[ "$HOST_OS" == "Darwin" ]]; then
      echo "  Detected external disks:"; echo
      diskutil list external physical 2>/dev/null | grep -E "^/dev/disk|SIZE|GB|MB" | \
        awk '/^\/dev\/disk/{dev=$1} /GB|MB/{printf "  %-12s %s %s\n", dev, $1, $2}' | sort -u || \
        diskutil list external physical 2>/dev/null | head -30
      echo
      read -rp "$(echo -e "${YELLOW}Enter device (e.g. /dev/disk4):${RESET} ")" DEVICE < /dev/tty
    else
      echo "  Detected removable/SD devices:"; echo
      lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -E "usb|sd[a-z]$|mmcblk" || \
        lsblk -d -o NAME,SIZE,MODEL | tail -n +2
      echo
      read -rp "$(echo -e "${YELLOW}Enter device (e.g. /dev/sdb):${RESET} ")" DEVICE < /dev/tty
    fi
  fi

  [[ -n "$DEVICE" ]] || die "No device specified"

  if [[ "$HOST_OS" == "Darwin" ]]; then
    IS_INTERNAL=$(diskutil info "$DEVICE" 2>/dev/null | grep -i "internal" | grep -i "yes" || true)
    [[ -z "$IS_INTERNAL" ]] || die "Device $DEVICE appears to be an internal disk — aborting"
    DEVICE_INFO=$(diskutil info "$DEVICE" 2>/dev/null | grep -E "Device Node|Media Name|Total Size" | sed 's/^[[:space:]]*//')
  else
    [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
    DEVICE_INFO=$(lsblk -d -o NAME,SIZE,MODEL "$DEVICE" 2>/dev/null || echo "$DEVICE")
  fi

  echo
  warn "About to flash ${BOLD}${DEVICE}${RESET}${YELLOW} with ${DISTRO_LABEL}"
  echo -e "  $DEVICE_INFO"
  echo
  read -rp "$(echo -e "${RED}Type 'yes' to confirm (this will erase the device):${RESET} ")" CONFIRM_DEV < /dev/tty
  [[ "$CONFIRM_DEV" == "yes" ]] || die "Aborted"

  # ── Flash ─────────────────────────────────────────────────────────────────────
  step "Flashing"

  if [[ "$HOST_OS" == "Darwin" ]]; then
    DISK_NUM=$(echo "$DEVICE" | grep -oE '[0-9]+$')
    RAW_DEV="/dev/rdisk${DISK_NUM}"
    diskutil unmountDisk "$DEVICE" || true
    info "Writing to $RAW_DEV (this will take a few minutes)..."
    sudo dd if="$IMG_FILE" of="$RAW_DEV" bs=4m status=progress 2>&1 || \
      sudo dd if="$IMG_FILE" of="$RAW_DEV" bs=4m
    sync
    ok "Flash complete"
    info "Mounting partitions..."
    diskutil mountDisk "$DEVICE" 2>/dev/null || true
    sleep 2
    BOOT_PATH=$(find /Volumes -maxdepth 2 -name "cmdline.txt" 2>/dev/null | head -1 | xargs -I{} dirname {} || true)
  else
    info "Writing to $DEVICE (this will take a few minutes)..."
    sudo dd if="$IMG_FILE" of="$DEVICE" bs=4M status=progress conv=fsync
    sync
    ok "Flash complete"
    sudo partprobe "$DEVICE" 2>/dev/null || true
    sleep 2
    BOOT_PART="${DEVICE}1"
    [[ -b "${DEVICE}p1" ]] && BOOT_PART="${DEVICE}p1"
    BOOT_PATH="/mnt/pi-boot-$$"
    sudo mkdir -p "$BOOT_PATH"
    sudo mount "$BOOT_PART" "$BOOT_PATH"
  fi

  [[ -n "$BOOT_PATH" && -d "$BOOT_PATH" ]] || die "Could not find/mount boot partition"
  [[ -f "$BOOT_PATH/cmdline.txt" ]]         || die "cmdline.txt not found in $BOOT_PATH"
  ok "Boot partition at: $BOOT_PATH"

fi  # end boot-path / normal mode

# ─── Cloud-init file generation ────────────────────────────────────────────────
step "Generating cloud-init configuration"

INSTANCE_ID="pi-provisioner-$(date +%s)"
info "Instance ID: $INSTANCE_ID"

USER_DATA="$BOOT_PATH/user-data"

# wd: append one line to user-data
wd() { printf '%s\n' "$*" >> "$USER_DATA"; }
# ws: append one script line with 6-space YAML indent (for write_files literal block)
ws() { printf '%s\n' "      $*" >> "$USER_DATA"; }

: > "$USER_DATA"

info "Writing user-data..."

# ── Header ─────────────────────────────────────────────────────────────────────
wd "#cloud-config"
wd "# Generated by download-and-flash-cloud-init.sh"
wd "# Instance: ${INSTANCE_ID}  |  Generated: $(date -Iseconds 2>/dev/null || date)"
wd ""
wd "manage_resolv_conf: false"
wd ""

# ── Hostname ───────────────────────────────────────────────────────────────────
wd "hostname: ${PI_HOSTNAME}"
wd "manage_etc_hosts: true"
wd ""

# ── apt ────────────────────────────────────────────────────────────────────────
# preserve_sources_list: keeps RPi's custom apt sources intact.
# Check-Date false: prevents apt failures from clock skew on fresh boots.
wd "apt:"
wd "  preserve_sources_list: true"
wd "  conf: |"
wd "    Acquire {"
wd "      Check-Date \"false\";"
wd "    };"
wd ""

# ── Locale ─────────────────────────────────────────────────────────────────────
wd "timezone: ${TIMEZONE}"
wd ""
wd "keyboard:"
wd "  model: pc105"
wd "  layout: \"us\""
wd ""

# ── User ───────────────────────────────────────────────────────────────────────
wd "users:"
wd "  - name: ${PI_USER}"
wd "    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo"
wd "    shell: /bin/bash"
wd "    sudo: ALL=(ALL) NOPASSWD:ALL"
wd "    lock_passwd: false"
wd "    passwd: \"${HASHED_PASS}\""
if [[ -n "$SSH_PUBKEY" ]]; then
  wd "    ssh_authorized_keys:"
  wd "      - ${SSH_PUBKEY}"
fi
wd ""
wd "chpasswd:"
wd "  expire: false"
wd ""

# ── SSH ────────────────────────────────────────────────────────────────────────
wd "enable_ssh: $([[ "$ENABLE_SSH" == true ]] && echo true || echo false)"
wd "ssh_pwauth: $([[ "$ENABLE_SSH" == true ]] && echo true || echo false)"
wd ""

# ── RPi hardware interfaces ────────────────────────────────────────────────────
wd "rpi:"
wd "  interfaces:"
wd "    serial: true"
wd "    i2c: true"
wd ""

# ── Packages ───────────────────────────────────────────────────────────────────
wd "packages:"
wd "  - avahi-daemon"
wd "  - i2c-tools"
[[ "$SKIP_NAS" == "false" ]] && wd "  - cifs-utils"
wd ""
wd "package_update: true"
wd "package_upgrade: false"
wd ""

# ── write_files ────────────────────────────────────────────────────────────────
wd "write_files:"

# NAS credentials (written early so they're on disk before provisioning script runs)
if [[ "$SKIP_NAS" == "false" ]]; then
  wd "  - path: /etc/cifs-credentials"
  wd "    owner: root:root"
  wd "    permissions: '0600'"
  wd "    content: |"
  while IFS= read -r line; do
    wd "      ${line}"
  done <<< "$NAS_CREDS_CONTENT"
fi

# ssd1306 display config (pre-seeded so installer doesn't overwrite it)
if [[ "$SKIP_DISPLAY" == "false" ]]; then
  wd "  - path: /etc/ssd1306.conf"
  wd "    owner: root:root"
  wd "    permissions: '0644'"
  wd "    content: |"
  wd "      # ssd1306 display config — pre-seeded by download-and-flash-cloud-init.sh"
  wd "      show_temperature=1"
  wd "      show_memory=1"
  wd "      show_disk=1"
  wd "      show_ip=1"
  wd "      show_hostname=1"
  wd "      show_clock=1"
  wd "      show_uptime=1"
  [[ "$SKIP_DOCKER" == "false" ]] && wd "      show_docker=1" || wd "      show_docker=0"
  wd "      show_network=0"
  wd "      show_wifi=0"
  wd "      show_gpu_temp=0"
  wd "      show_cpu_freq=0"
  wd "      temp_unit=fahrenheit"
  wd "      load_display=percent"
  wd "      screen_time=3"
  wd "      top_line=hostname"
  wd "      network_interfaces=eth0,wlan0"
fi

# ── Pimox static files ────────────────────────────────────────────────────────
if [[ "$PIMOX" == "true" ]]; then
  # Phase 2 installer (runs on first reboot via pimox-install.service)
  wd "  - path: /usr/local/sbin/pimox-install.sh"
  wd "    permissions: '0755'"
  wd "    owner: root:root"
  wd "    content: |"
  wd '      #!/usr/bin/env bash'
  wd '      set -euo pipefail'
  wd '      exec >> /var/log/pimox-install.log 2>&1'
  wd '      echo "[$(date -Iseconds)] Starting Proxmox VE installation..."'
  wd '      export DEBIAN_FRONTEND=noninteractive'
  wd '      echo "postfix postfix/main_mailer_type select Local only"   | debconf-set-selections'
  wd '      echo "postfix postfix/mailname           string $(hostname)" | debconf-set-selections'
  wd '      apt-get install -y proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64'
  wd '      echo "[$(date -Iseconds)] Proxmox VE installation complete."'
  if [[ "$PATCH_NAG" == "true" ]]; then
    wd '      /usr/local/sbin/pve-nag-patch.sh'
    wd '      echo "[$(date -Iseconds)] Subscription nag patched."'
  fi
  wd '      systemctl disable pimox-install.service'
  wd ""
  # Systemd service (enables itself on first reboot, then self-disables after install)
  wd "  - path: /etc/systemd/system/pimox-install.service"
  wd "    owner: root:root"
  wd "    permissions: '0644'"
  wd "    content: |"
  wd "      [Unit]"
  wd "      Description=PiMox -- Install Proxmox VE after reboot"
  wd "      After=network-online.target"
  wd "      Wants=network-online.target"
  wd "      ConditionPathExists=/usr/local/sbin/pimox-install.sh"
  wd "      "
  wd "      [Service]"
  wd "      Type=oneshot"
  wd "      ExecStart=/usr/local/sbin/pimox-install.sh"
  wd "      RemainAfterExit=yes"
  wd "      StandardOutput=journal"
  wd "      StandardError=journal"
  wd "      "
  wd "      [Install]"
  wd "      WantedBy=multi-user.target"
  wd ""
  # cloud-init drop-in: prevent cloud-init from overwriting pimox hostname on subsequent boots
  wd "  - path: /etc/cloud/cloud.cfg.d/99-pimox-hostname.cfg"
  wd "    owner: root:root"
  wd "    permissions: '0644'"
  wd "    content: |"
  wd "      preserve_hostname: true"
  wd "      manage_etc_hosts: false"
  if [[ "$PATCH_NAG" == "true" ]]; then
    wd ""
    wd "  - path: /usr/local/sbin/pve-nag-patch.sh"
    wd "    permissions: '0755'"
    wd "    owner: root:root"
    wd "    content: |"
    wd '      #!/usr/bin/env bash'
    wd '      JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js'
    wd '      [[ -f "$JS" ]] || exit 0'
    wd '      sed -Ezi.bak "s/(Ext.Msg.show\(\{[^}]*title: gettext\('"'"'No valid sub)/void(\({ \/\/\1/g" "$JS"'
    wd ""
    wd "  - path: /etc/apt/apt.conf.d/86pve-nag-buster"
    wd "    owner: root:root"
    wd "    permissions: '0644'"
    wd "    content: |"
    wd '      DPkg::Post-Invoke { "/usr/local/sbin/pve-nag-patch.sh || true"; };'
  fi
fi

# ── Provisioning script ────────────────────────────────────────────────────────
# Written to the Pi's root filesystem (not FAT boot partition) so it's executable.
# Called from runcmd after all packages are installed.
wd "  - path: /usr/local/sbin/pi-provision.sh"
wd "    permissions: '0755'"
wd "    owner: root:root"
wd "    content: |"

ws "#!/bin/bash"
ws "set -euo pipefail"
ws ""
ws "# ── Configuration (embedded at flash time) ──────────────────────────────────"
ws "PI_USER=\"${PI_USER}\""
ws "TIMEZONE=\"${TIMEZONE}\""
ws "SKIP_NAS=${SKIP_NAS}"
ws "NAS_HOST=\"${NAS_HOST}\""
ws "NAS_SHARE=\"${NAS_SHARE}\""
ws "SKIP_DOCKER=${SKIP_DOCKER}"
ws "DOCKER_USER=\"${DOCKER_USER}\""
ws "SKIP_DISPLAY=${SKIP_DISPLAY}"
ws "PI_HOSTNAME=\"${PI_HOSTNAME}\""
ws "PIMOX=${PIMOX}"
if [[ "$PIMOX" == "true" ]]; then
  ws "PIMOX_IP=\"${PIMOX_IP}\""
  ws "PIMOX_GATEWAY=\"${PIMOX_GATEWAY}\""
  ws "PIMOX_NETMASK=\"${PIMOX_NETMASK}\""
  ws "PIMOX_DNS=\"${PIMOX_DNS}\""
  ws "PIMOX_IFACE=\"${PIMOX_IFACE}\""
  ws "HASHED_ROOT_PASS=\"${HASHED_ROOT_PASS}\""
fi
ws ""
ws "# ── Logging setup ───────────────────────────────────────────────────────────"
ws "LOG=/var/log/pi-provisioning.log"
ws "exec >> \"\$LOG\" 2>&1"
ws ""
ws 'ts()   { date -Iseconds 2>/dev/null || date; }'
ws 'log()  { echo "[$(ts)] $*"; }'
ws 'ok()   { echo "[$(ts)] [ OK ] $*"; }'
ws 'fail() { echo "[$(ts)] [FAIL] $*"; }'
ws 'step() { echo "[$(ts)] ──────────────────────────────────────────────────"; echo "[$(ts)] $*"; }'
ws ""
ws 'step "pi-provision.sh starting"'
ws 'log "Hostname    : $(hostname)"'
ws 'log "Kernel      : $(uname -r)"'
ws 'log "Uptime      : $(uptime -p 2>/dev/null || uptime)"'
ws "log \"Pi user     : ${PI_USER}\""
ws "log \"Timezone    : ${TIMEZONE}\""
ws "log \"Skip NAS    : ${SKIP_NAS}\""
ws "log \"Skip Docker : ${SKIP_DOCKER}\""
ws "log \"Skip Display: ${SKIP_DISPLAY}\""
ws 'log "Free disk   : $(df -h / | awk '"'"'NR==2{print $4}'"'"') available"'
ws 'log "Memory      : $(free -h | awk '"'"'/^Mem/{print $2}'"'"') total"'
ws ""
ws "# ── Wait for apt lock ───────────────────────────────────────────────────────"
ws 'step "Waiting for apt lock"'
ws 'MAX_WAIT=36  # 3 minutes max'
ws 'for i in $(seq 1 $MAX_WAIT); do'
ws '  if flock -w 1 /var/lib/dpkg/lock-frontend true 2>/dev/null; then'
ws '    ok "apt lock acquired after $i attempt(s)"'
ws '    break'
ws '  fi'
ws '  log "Waiting for dpkg lock... ($i/$MAX_WAIT)"'
ws '  sleep 5'
ws 'done'
ws ""
ws "# ── WiFi unblock ────────────────────────────────────────────────────────────"
ws 'step "WiFi unblock"'
ws 'rfkill unblock wifi 2>/dev/null && log "rfkill unblock wifi: done" || log "rfkill not available (skipping)"'
ws 'UNBLOCKED=0'
ws 'for f in /var/lib/systemd/rfkill/*:wlan; do'
ws '  if [ -f "$f" ]; then'
ws '    echo 0 > "$f"'
ws '    log "Cleared rfkill state: $f"'
ws '    UNBLOCKED=$(( UNBLOCKED + 1 ))'
ws '  fi'
ws 'done'
ws '[ "$UNBLOCKED" -gt 0 ] && ok "Cleared $UNBLOCKED rfkill state file(s)" || log "No rfkill state files found"'

# ── NAS / CIFS ────────────────────────────────────────────────────────────────
ws ""
ws "# ── NAS / CIFS mount ────────────────────────────────────────────────────────"
ws 'if [[ "$SKIP_NAS" == "false" ]]; then'
ws '  step "NAS CIFS mount"'
ws '  log "Target: //${NAS_HOST}/${NAS_SHARE} → /mnt/${NAS_SHARE}"'
ws '  MOUNT_POINT="/mnt/${NAS_SHARE}"'
ws '  mkdir -p "$MOUNT_POINT"'
ws '  log "Mount point ready: $MOUNT_POINT"'
ws '  if [ -f /etc/cifs-credentials ]; then'
ws '    log "Credentials file: /etc/cifs-credentials ($(stat -c %a /etc/cifs-credentials) perms)"'
ws '  else'
ws '    fail "Credentials file not found: /etc/cifs-credentials"'
ws '  fi'
ws '  FSTAB_LINE="//${NAS_HOST}/${NAS_SHARE}  ${MOUNT_POINT}  cifs  credentials=/etc/cifs-credentials,iocharset=utf8,vers=3.0,_netdev,nofail  0  0"'
ws '  if grep -qF "$MOUNT_POINT" /etc/fstab; then'
ws '    log "fstab entry already present — skipping"'
ws '  else'
ws '    printf '"'"'\n# pi-provision: %s\n%s\n'"'"' "$MOUNT_POINT" "$FSTAB_LINE" >> /etc/fstab'
ws '    ok "fstab entry added for $MOUNT_POINT"'
ws '    log "Entry: $FSTAB_LINE"'
ws '  fi'
ws '  log "Attempting mount..."'
ws '  if mount "$MOUNT_POINT" 2>/dev/null || mountpoint -q "$MOUNT_POINT" 2>/dev/null; then'
ws '    ok "Mounted //${NAS_HOST}/${NAS_SHARE} → $MOUNT_POINT"'
ws '    log "Contents (first 5): $(ls "$MOUNT_POINT" 2>/dev/null | head -5 | tr '"'"'\n'"'"' '"'"' '"'"' || echo "(empty or unreadable)")"'
ws '  else'
ws '    fail "Mount failed — NAS may not be reachable yet"'
ws '    log "Hint: retry manually with: mount $MOUNT_POINT"'
ws '    log "Hint: check credentials with: smbclient -L //${NAS_HOST} -U <user>"'
ws '  fi'
ws 'fi'

# ── Docker ────────────────────────────────────────────────────────────────────
ws ""
ws "# ── Docker installation ─────────────────────────────────────────────────────"
ws 'if [[ "$SKIP_DOCKER" == "false" ]]; then'
ws '  step "Docker"'
ws '  if command -v docker &>/dev/null; then'
ws '    ok "Docker already installed: $(docker --version)"'
ws '  else'
ws '    log "Downloading Docker install script from get.docker.com..."'
ws '    curl -fsSL https://get.docker.com | sh'
ws '    ok "Docker installed: $(docker --version)"'
ws '  fi'
ws '  if docker compose version &>/dev/null 2>&1; then'
ws '    ok "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"'
ws '  else'
ws '    log "Docker Compose plugin missing — installing..."'
ws '    apt-get install -y -qq docker-compose-plugin || fail "docker-compose-plugin install failed (non-fatal)"'
ws '    ok "Docker Compose plugin install attempted"'
ws '  fi'
ws '  if id "$DOCKER_USER" &>/dev/null; then'
ws '    usermod -aG docker "$DOCKER_USER" || fail "usermod -aG docker $DOCKER_USER failed (non-fatal)"'
ws '    ok "$DOCKER_USER added to docker group"'
ws '  else'
ws '    fail "User $DOCKER_USER not found — docker group assignment skipped"'
ws '  fi'
ws 'fi'

# ── ssd1306 display ───────────────────────────────────────────────────────────
ws ""
ws "# ── ssd1306 OLED display (beartums/U6143_ssd1306) ──────────────────────────"
ws 'if [[ "$SKIP_DISPLAY" == "false" ]]; then'
ws '  step "ssd1306 OLED display"'
ws '  log "Checking i2c bus..."'
ws '  i2cdetect -y 1 2>/dev/null && log "i2cdetect complete" || log "i2cdetect failed — i2c may not be ready yet"'
ws '  log "Downloading install script from beartums/U6143_ssd1306..."'
ws '  curl -fsSL https://raw.githubusercontent.com/beartums/U6143_ssd1306/master/install.sh -o /tmp/ssd1306-install.sh'
ws '  log "Running installer (SUDO_USER=${PI_USER})..."'
ws '  SUDO_USER="$PI_USER" bash /tmp/ssd1306-install.sh'
ws '  rm -f /tmp/ssd1306-install.sh'
ws '  log "ssd1306 install script finished"'
ws '  if systemctl is-active --quiet ssd1306-display 2>/dev/null; then'
ws '    ok "ssd1306-display service is running"'
ws '  else'
ws '    log "ssd1306-display service not running yet — may need a reboot"'
ws '    log "Check status: systemctl status ssd1306-display"'
ws '    log "Check logs:   journalctl -u ssd1306-display -n 50"'
ws '  fi'
ws '  log "i2c bus after install:"'
ws '  i2cdetect -y 1 2>/dev/null || log "i2cdetect not available"'
ws 'fi'

ws ""
ws "# ── Pimox Phase 1 ───────────────────────────────────────────────────────────"
ws 'if [[ "$PIMOX" == "true" ]]; then'
ws '  step "Pimox Phase 1"'
ws ""
ws "  # Network auto-detection"
ws '  PIFACE="$PIMOX_IFACE"'
ws '  [[ -z "$PIFACE" ]] && PIFACE=$(ip -4 route show default 2>/dev/null | awk '"'"'/^default/{print $5;exit}'"'"')'
ws '  [[ -n "$PIFACE" ]] || { fail "Could not detect network interface"; exit 1; }'
ws '  log "Interface: $PIFACE"'
ws ""
ws '  SIP="$PIMOX_IP"'
ws '  [[ -z "$SIP" ]] && SIP=$(ip -4 addr show "$PIFACE" 2>/dev/null | awk '"'"'/inet /{split($2,a,"/");print a[1];exit}'"'"')'
ws '  [[ -n "$SIP" ]] || { fail "Could not detect IP on $PIFACE"; exit 1; }'
ws '  log "Static IP: $SIP"'
ws ""
ws '  NM="$PIMOX_NETMASK"'
ws '  [[ -z "$NM" ]] && NM=$(ip -4 addr show "$PIFACE" 2>/dev/null | awk '"'"'/inet /{split($2,a,"/");print a[2];exit}'"'"')'
ws '  NM="${NM:-24}"'
ws '  log "Netmask: /$NM"'
ws ""
ws '  GW="$PIMOX_GATEWAY"'
ws '  [[ -z "$GW" ]] && GW=$(ip -4 route show default 2>/dev/null | awk '"'"'/^default/{print $3;exit}'"'"')'
ws '  [[ -n "$GW" ]] || { fail "Could not detect gateway"; exit 1; }'
ws '  log "Gateway: $GW"'
ws ""
ws '  PDNS="$PIMOX_DNS"'
ws '  [[ -z "$PDNS" ]] && PDNS=$(awk '"'"'/^nameserver/{print $2;exit}'"'"' /etc/resolv.conf 2>/dev/null || true)'
ws '  PDNS="${PDNS:-1.1.1.1}"'
ws '  log "DNS: $PDNS"'
ws ""
ws '  CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-bookworm}" || echo "bookworm")'
ws '  log "OS codename: $CODENAME"'
ws ""
ws "  # Update /etc/hosts with static IP → hostname mapping"
ws '  log "Updating /etc/hosts..."'
ws '  sed -i "/\b${PI_HOSTNAME}\b/d" /etc/hosts'
ws '  echo "${SIP}    ${PI_HOSTNAME}" >> /etc/hosts'
ws '  ok "Added ${SIP} -> ${PI_HOSTNAME} in /etc/hosts"'
ws ""
ws "  # Set root password (chpasswd -e accepts pre-hashed password)"
ws '  echo "root:${HASHED_ROOT_PASS}" | chpasswd -e'
ws '  ok "Root password set"'
ws ""
ws "  # Add PiMox GPG key"
ws '  log "Adding PiMox GPG key..."'
ws '  curl -L "https://mirrors.lierfang.com/pxcloud/lierfang.gpg" | tee /usr/share/keyrings/lierfang.gpg > /dev/null'
ws '  ok "PiMox GPG key added"'
ws ""
ws "  # Add PiMox repository and refresh"
ws '  echo "deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt ${CODENAME} main" \'
ws '    > /etc/apt/sources.list.d/pveport.list'
ws '  apt-get update -y -qq'
ws '  ok "PiMox apt repository added"'
ws ""
ws "  # Disable NetworkManager (conflicts with Proxmox bridge networking)"
ws '  if systemctl is-active --quiet NetworkManager 2>/dev/null; then'
ws '    systemctl disable --now NetworkManager && systemctl mask NetworkManager'
ws '    ok "NetworkManager disabled and masked"'
ws '  else'
ws '    log "NetworkManager not active — skipping"'
ws '  fi'
ws ""
ws "  # Install ifupdown2 (Debian-native networking, required by Proxmox)"
ws '  log "Installing ifupdown2..."'
ws '  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ifupdown2'
ws '  ok "ifupdown2 installed"'
ws ""
ws "  # Configure vmbr0 Linux bridge"
ws '  log "Configuring /etc/network/interfaces (vmbr0 bridge)..."'
ws '  [[ -f /etc/network/interfaces ]] && cp /etc/network/interfaces /etc/network/interfaces.pimox-backup'
ws '  cat > /etc/network/interfaces <<NETEOF'
ws "# Generated by pi-provision.sh (pimox mode)"
ws "auto lo"
ws "iface lo inet loopback"
ws ""
ws 'auto ${PIFACE}'
ws 'iface ${PIFACE} inet manual'
ws ""
ws "auto vmbr0"
ws "iface vmbr0 inet static"
ws '    address ${SIP}/${NM}'
ws '    gateway ${GW}'
ws '    dns-nameservers ${PDNS}'
ws '    bridge-ports ${PIFACE}'
ws "    bridge-stp off"
ws "    bridge-fd 0"
ws 'NETEOF'
ws '  ok "vmbr0 bridge: ${PIFACE} -> vmbr0 @ ${SIP}/${NM}, gw ${GW}"'
ws ""
ws '  step "Pimox Phase 1 complete"'
ws '  log "Proxmox VE will install on next boot via pimox-install.service"'
ws '  log "Phase 2 log: /var/log/pimox-install.log"'
ws '  log "Proxmox web UI: https://${SIP}:8006  (after Phase 2 completes)"'
ws 'fi'
ws ""
ws 'step "pi-provision.sh complete"'
ws 'log "Provisioning log : $LOG"'
ws 'log "Cloud-init log   : /var/log/cloud-init-output.log"'
ws 'log "Cloud-init status: /run/cloud-init/status.json"'

# ── runcmd ─────────────────────────────────────────────────────────────────────
wd ""
wd "runcmd:"
wd "  - [ bash, /usr/local/sbin/pi-provision.sh ]"
if [[ "$PIMOX" == "true" ]]; then
  wd "  - [ systemctl, daemon-reload ]"
  wd "  - [ systemctl, enable, pimox-install.service ]"
fi

if [[ "$PIMOX" == "true" ]]; then
  wd ""
  wd "power_state:"
  wd "  mode: reboot"
  wd "  delay: '+1'"
  wd "  message: Rebooting to complete Pimox setup and install Proxmox VE"
fi

ok "user-data written: $USER_DATA"

# ─── meta-data ─────────────────────────────────────────────────────────────────
META_DATA="$BOOT_PATH/meta-data"
info "Writing meta-data..."
printf 'instance-id: %s\n' "$INSTANCE_ID" > "$META_DATA"
ok "meta-data written (instance-id: ${INSTANCE_ID})"

# ─── cmdline.txt — update or add ds=nocloud instance-id ───────────────────────
info "Updating cmdline.txt..."
CMDLINE_FILE="$BOOT_PATH/cmdline.txt"
CMDLINE=$(tr -d '\n' < "$CMDLINE_FILE")

if echo "$CMDLINE" | grep -q "ds=nocloud"; then
  CMDLINE=$(echo "$CMDLINE" | sed "s|ds=nocloud;i=[^ ]*|ds=nocloud;i=${INSTANCE_ID}|")
  ok "Updated instance-id in cmdline.txt → ${INSTANCE_ID}"
else
  CMDLINE="${CMDLINE} ds=nocloud;i=${INSTANCE_ID}"
  ok "Added ds=nocloud;i=${INSTANCE_ID} to cmdline.txt"
fi
printf '%s\n' "$CMDLINE" > "$CMDLINE_FILE"

# When --pimox: add cgroup params required for LXC container memory reporting
if [[ "$PIMOX" == "true" ]]; then
  CMDLINE=$(tr -d '\n' < "$CMDLINE_FILE")
  for PARAM in "cgroup_enable=cpuset" "cgroup_enable=memory" "cgroup_memory=1"; do
    if ! echo "$CMDLINE" | grep -qF "$PARAM"; then
      CMDLINE="${CMDLINE} ${PARAM}"
    fi
  done
  printf '%s\n' "$CMDLINE" > "$CMDLINE_FILE"
  ok "Added cgroup params to cmdline.txt for PiMox LXC memory reporting"
fi

# ─── config.txt — enable i2c ──────────────────────────────────────────────────
CONFIG_FILE="$BOOT_PATH/config.txt"
if [[ -f "$CONFIG_FILE" ]]; then
  info "Enabling i2c in config.txt..."
  if grep -q "^#dtparam=i2c_arm=on" "$CONFIG_FILE"; then
    if [[ "$HOST_OS" == "Darwin" ]]; then
      sed -i '' "s/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/" "$CONFIG_FILE"
    else
      sed -i "s/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/" "$CONFIG_FILE"
    fi
    ok "i2c uncommented in config.txt"
  elif grep -q "^dtparam=i2c_arm=on" "$CONFIG_FILE"; then
    info "i2c already enabled in config.txt"
  else
    printf '\n# Added by download-and-flash-cloud-init.sh\ndtparam=i2c_arm=on\n' >> "$CONFIG_FILE"
    ok "i2c appended to config.txt"
  fi
else
  warn "config.txt not found — skipping i2c config.txt update"
fi

# When --pimox: set kernel=kernel8.img for 4K page size (required by PXVirt)
if [[ "$PIMOX" == "true" && -f "$CONFIG_FILE" ]]; then
  if grep -q "^kernel=kernel8.img" "$CONFIG_FILE"; then
    info "kernel=kernel8.img already set in config.txt"
  else
    grep -v "^kernel=" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    printf '\nkernel=kernel8.img\n' >> "$CONFIG_FILE"
    ok "Set kernel=kernel8.img in config.txt (4K page size required by PXVirt)"
  fi
fi

# ─── network-config ────────────────────────────────────────────────────────────
NET_CONFIG="$BOOT_PATH/network-config"
info "Writing network-config..."
{
  printf '# network-config — generated by download-and-flash-cloud-init.sh\n'
  printf '# netplan v2 format; applied by cloud-init on first boot only.\n'
  printf '\n'
  if [[ -n "$WIFI_SSID" ]]; then
    printf 'network:\n'
    printf '  version: 2\n'
    printf '  ethernets:\n'
    printf '    eth0:\n'
    printf '      dhcp4: true\n'
    printf '      optional: true\n'
    printf '  wifis:\n'
    printf '    wlan0:\n'
    printf '      dhcp4: true\n'
    printf '      optional: true\n'
    printf '      regulatory-domain: US\n'
    printf '      access-points:\n'
    printf '        "%s":\n' "$WIFI_SSID"
    [[ -n "$WIFI_PASSWORD" ]] && printf '          password: "%s"\n' "$WIFI_PASSWORD"
  else
    printf '# Uncomment and edit to configure networking:\n'
    printf '#network:\n'
    printf '#  version: 2\n'
    printf '#  ethernets:\n'
    printf '#    eth0:\n'
    printf '#      dhcp4: true\n'
    printf '#      optional: true\n'
    printf '#  wifis:\n'
    printf '#    wlan0:\n'
    printf '#      dhcp4: true\n'
    printf '#      optional: true\n'
    printf '#      access-points:\n'
    printf '#        "myssid":\n'
    printf '#          password: "mypassword"\n'
  fi
} > "$NET_CONFIG"
ok "network-config written"

# ─── Unmount ───────────────────────────────────────────────────────────────────
if [[ -z "$BOOT_PATH_ARG" ]]; then
  step "Unmounting"
  if [[ "$HOST_OS" == "Darwin" ]]; then
    diskutil unmountDisk "$DEVICE" 2>/dev/null || true
    ok "Unmounted — safe to eject"
  else
    sudo umount "$BOOT_PATH" 2>/dev/null || true
    sudo rmdir "$BOOT_PATH"  2>/dev/null || true
    sudo eject "$DEVICE"     2>/dev/null || true
    ok "Unmounted and ejected"
  fi
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  SD card ready — cloud-init provisioning             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
info "Distro      : $DISTRO_LABEL"
info "Hostname    : $PI_HOSTNAME"
info "User        : $PI_USER"
info "Timezone    : $TIMEZONE"
info "SSH         : $([[ "$ENABLE_SSH" == true ]] && echo "enabled (password auth)" || echo "disabled")"
info "i2c         : enabled (config.txt + rpi.interfaces)"
[[ -n "$WIFI_SSID" ]]          && info "WiFi        : $WIFI_SSID"
[[ "$SKIP_NAS"     == "false" ]] && info "NAS         : //${NAS_HOST}/${NAS_SHARE} → /mnt/${NAS_SHARE}"
[[ "$SKIP_DOCKER"  == "false" ]] && info "Docker      : will install for '${DOCKER_USER}'"
[[ "$SKIP_DISPLAY" == "false" ]] && info "Display     : ssd1306 OLED (beartums/U6143_ssd1306)"
if [[ "$PIMOX" == "true" ]]; then
  info "Pimox       : enabled"
  info "  Phase 1   : runs on first boot (hostname, bridge, GPG key, repo)"
  info "  Phase 2   : runs after auto-reboot (installs proxmox-ve)"
  info "  Web UI    : https://${PIMOX_IP:-<auto-detected-ip>}:8006  (after Phase 2)"
fi
info "Instance ID : $INSTANCE_ID"
echo
info "On first boot, cloud-init will run /usr/local/sbin/pi-provision.sh"
info "Provisioning log : /var/log/pi-provisioning.log      (on the Pi)"
info "Cloud-init log   : /var/log/cloud-init-output.log    (on the Pi)"
echo
