#!/usr/bin/env bash
# pimox-setup.sh — Prepare a Raspberry Pi (ARM64) for Proxmox VE (PiMox)
# Based on: https://pimylifeup.com/raspberry-pi-proxmox/
#
# Usage:
#   sudo ./pimox-setup.sh [options]
#
# Options:
#   --hostname NAME     Hostname to assign (default: current hostname)
#   --ip ADDR           Static IP address (default: auto-detect)
#   --gateway ADDR      Default gateway (default: auto-detect)
#   --netmask MASK      Netmask in CIDR or dotted notation (default: auto-detect)
#   --dns ADDR          DNS server (default: auto-detect from /etc/resolv.conf)
#   --iface NAME        Network interface (default: auto-detect)
#   --root-password PWD Root password (default: prompt interactively)
#   --codename NAME     Override OS codename (default: auto-detect)
#   --patch-nag         Remove the Proxmox "no valid subscription" nag from the web UI
#   --skip-log2ram      Skip log2ram install (default: installed to reduce SD card writes)
#   --skip-upgrade      Skip apt update/upgrade (faster re-runs)
#   -y, --yes           Auto-approve all prompts

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()  { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; exit 1; }

# macOS requires 'sed -i ""'; Linux accepts 'sed -i' only
_sed_i() { [[ "$(uname -s)" == "Darwin" ]] && sed -i '' "$@" || sed -i "$@"; }

confirm() {
  [[ "$AUTO_YES" == "true" ]] && return 0
  local prompt="${1:-Continue?}"
  # Read from /dev/tty so prompts work when stdin is a pipe (curl | bash)
  read -rp "$(echo -e "${YELLOW}${prompt} [y/N]${RESET} ")" ans < /dev/tty
  [[ "${ans,,}" == "y" ]]
}

# ─── Argument parsing ────────────────────────────────────────────────────────
NEW_HOSTNAME=""
STATIC_IP=""
GATEWAY=""
NETMASK=""
DNS=""
IFACE=""
CODENAME=""
PATCH_NAG=false
LOG2RAM=true
SKIP_UPGRADE=false
AUTO_YES=false
ROOT_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)      NEW_HOSTNAME="$2";   shift 2 ;;
    --ip)            STATIC_IP="$2";      shift 2 ;;
    --gateway)       GATEWAY="$2";        shift 2 ;;
    --netmask)       NETMASK="$2";        shift 2 ;;
    --dns)           DNS="$2";            shift 2 ;;
    --iface)         IFACE="$2";          shift 2 ;;
    --codename)      CODENAME="$2";       shift 2 ;;
    --patch-nag)     PATCH_NAG=true;      shift ;;
    --skip-log2ram)  LOG2RAM=false;       shift ;;
    --root-password) ROOT_PASSWORD="$2";  shift 2 ;;
    --skip-upgrade)  SKIP_UPGRADE=true;   shift ;;
    -y|--yes)        AUTO_YES=true;       shift ;;
    -h|--help)
      grep '^#' "$0" | grep -E '^\s*#\s+' | head -20 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ─── Test-mode setup ─────────────────────────────────────────────────────────
# Set PIMOX_TEST_ROOT=<dir> to run without root/ARM64 and redirect all file
# writes to that directory. Used by test-pimox-setup.sh.
TR="${PIMOX_TEST_ROOT:-}"
if [[ -n "$TR" ]]; then
  mkdir -p "${TR}/etc/apt/sources.list.d"  "${TR}/etc/cloud/cloud.cfg.d" \
           "${TR}/etc/network"            "${TR}/etc/systemd/system" \
           "${TR}/usr/local/sbin"         "${TR}/usr/share/keyrings" \
           "${TR}/boot/firmware"
  : > "${TR}/etc/hosts"
  : > "${TR}/etc/cloud/cloud.cfg"
  : > "${TR}/etc/network/interfaces"
  : > "${TR}/boot/firmware/config.txt"
  : > "${TR}/boot/firmware/cmdline.txt"
  apt-get()    { true; }
  curl()       { local _o=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { _o="$2"; shift 2; } || shift; done; [[ -n "$_o" ]] && touch "$_o" || true; }
  gpg()        { local _o=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { _o="$2"; shift 2; } || shift; done; [[ -n "$_o" ]] && cat > "$_o" || cat > /dev/null; }
  hostnamectl(){ true; }
  systemctl()  { true; }
  passwd()     { true; }
  chpasswd()   { cat > /dev/null; }
  reboot()     { true; }
fi

# ─── Preflight checks ────────────────────────────────────────────────────────
step "Preflight"

if [[ -n "$TR" ]]; then
  info "Test mode: redirecting file writes to $TR"
  ARCH="aarch64"
else
  [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo ./pimox-setup.sh ...)"
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" ]] || die "PiMox requires an ARM64 (aarch64) system. Detected: $ARCH"
fi
ok "Architecture: $ARCH"

# Detect OS (skipped when --codename is passed explicitly)
if [[ -n "$CODENAME" ]]; then
  info "Codename: $CODENAME (from --codename)"
elif [[ -f /etc/os-release ]]; then
  . /etc/os-release
  info "OS: $PRETTY_NAME"
  CODENAME="${VERSION_CODENAME:-bookworm}"
else
  warn "Could not detect OS; assuming Debian Bookworm"
  CODENAME="bookworm"
fi

REPO_BASE="https://mirrors.lierfang.com/pxcloud/pxvirt"
if curl -fsSL --max-time 5 "${REPO_BASE}/dists/${CODENAME}/Release" -o /dev/null 2>/dev/null; then
  ok "OS codename: ${CODENAME} (confirmed available on mirror)"
else
  warn "Codename '${CODENAME}' not found on mirror — falling back to 'bookworm'"
  CODENAME="bookworm"
fi

[[ -n "$NEW_HOSTNAME" ]] || NEW_HOSTNAME=$(hostname)

# ─── Auto-detect network values ──────────────────────────────────────────────
step "Network detection"

if [[ -z "$IFACE" ]]; then
  IFACE=$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [[ -n "$IFACE" ]] || die "Could not detect default network interface. Pass --iface"
  info "Detected interface: $IFACE"
fi

if [[ -z "$STATIC_IP" ]]; then
  STATIC_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
  [[ -n "$STATIC_IP" ]] || die "Could not detect IP on $IFACE. Pass --ip"
  info "Detected IP: $STATIC_IP"
fi

if [[ -z "$NETMASK" ]]; then
  NETMASK=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[2]; exit}')
  [[ -n "$NETMASK" ]] || NETMASK="24"
  info "Detected prefix length: /$NETMASK"
fi

if [[ -z "$GATEWAY" ]]; then
  GATEWAY=$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')
  [[ -n "$GATEWAY" ]] || die "Could not detect default gateway. Pass --gateway"
  info "Detected gateway: $GATEWAY"
fi

if [[ -z "$DNS" ]]; then
  DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  DNS="${DNS:-1.1.1.1}"
  info "Using DNS: $DNS"
fi

echo
info "Configuration summary:"
info "  Hostname  : $NEW_HOSTNAME"
info "  Interface : $IFACE"
info "  IP        : $STATIC_IP/$NETMASK"
info "  Gateway   : $GATEWAY"
info "  DNS       : $DNS"
echo
confirm "Proceed with these settings?" || die "Aborted."

# ─── Step 1: System update ───────────────────────────────────────────────────
step "Step 1: System update & install packages"

if [[ "$SKIP_UPGRADE" == "true" ]]; then
  warn "Skipping apt update/upgrade (--skip-upgrade)"
else
  apt-get update -y
  apt-get upgrade -y
fi
apt-get install -y curl
ok "System updated"

if [[ "$LOG2RAM" == "true" ]]; then
  apt-get install -y log2ram
  ok "log2ram installed (buffers /var/log in RAM, reduces SD card write wear)"
else
  info "Skipping log2ram (--skip-log2ram)"
fi

# ─── Step 2: Set hostname ────────────────────────────────────────────────────
step "Step 2: Configure hostname"

OLD_HOSTNAME=$(hostname)
hostnamectl set-hostname "$NEW_HOSTNAME"
ok "Hostname set to: $NEW_HOSTNAME"

# ─── Step 3: Update /etc/hosts ───────────────────────────────────────────────
step "Step 3: Update /etc/hosts"

# Remove old 127.0.x.x entries for the hostname, then add static IP entry
HOSTS_FILE="${TR}/etc/hosts"
HOSTS_BACKUP="${TR}/etc/hosts.pimox-backup-$(date +%s)"
cp "$HOSTS_FILE" "$HOSTS_BACKUP"
info "Backed up /etc/hosts → $HOSTS_BACKUP"

# Remove any existing entries for old or new hostname
_sed_i "/\b${OLD_HOSTNAME}\b/d" "$HOSTS_FILE"
_sed_i "/\b${NEW_HOSTNAME}\b/d" "$HOSTS_FILE"

# Append the static IP → hostname mapping
echo "${STATIC_IP}    ${NEW_HOSTNAME}" >> "$HOSTS_FILE"
ok "Added: ${STATIC_IP} → ${NEW_HOSTNAME}"

# ─── Step 4: Disable cloud-init hostname management ─────────────────────────
step "Step 4: Disable cloud-init hostname management"

# Drop-in override — survives cloud.cfg package updates
CLOUD_DROPIN_DIR="${TR}/etc/cloud/cloud.cfg.d"
if [[ -d "$CLOUD_DROPIN_DIR" ]]; then
  cat > "${CLOUD_DROPIN_DIR}/99-pimox-hostname.cfg" <<'EOF'
# Prevent cloud-init from overwriting the hostname and /etc/hosts
# configured by pimox-setup.sh on every boot.
preserve_hostname: true
manage_etc_hosts: false
EOF
  ok "Cloud-init drop-in written: ${CLOUD_DROPIN_DIR}/99-pimox-hostname.cfg"
else
  info "No $CLOUD_DROPIN_DIR found — skipping drop-in"
fi

# Also comment out all hostname-related modules in the main cloud.cfg
CLOUD_CFG="${TR}/etc/cloud/cloud.cfg"
if [[ -f "$CLOUD_CFG" ]]; then
  for module in set_hostname update_hostname update_etc_hosts; do
    _sed_i "s/^\(\s*\)- ${module}\b/\1# - ${module}/" "$CLOUD_CFG"
  done
  ok "Commented out hostname modules (set_hostname, update_hostname, update_etc_hosts) in $CLOUD_CFG"
else
  info "No $CLOUD_CFG found — skipping"
fi

# ─── Step 5: Set root password ───────────────────────────────────────────────
step "Step 5: Set root password"

if [[ -n "$ROOT_PASSWORD" ]]; then
  echo "root:${ROOT_PASSWORD}" | chpasswd
  ok "Root password set from --root-password"
else
  while true; do
    read -rsp "$(echo -e "${YELLOW}Root password (for Proxmox web UI):${RESET} ")" ROOT_PASSWORD < /dev/tty; echo
    read -rsp "$(echo -e "${YELLOW}Confirm root password:${RESET} ")" ROOT_PASS2 < /dev/tty; echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASS2" ]] && break
    warn "Passwords do not match — try again"
  done
  echo "root:${ROOT_PASSWORD}" | chpasswd
  ok "Root password set"
fi

# ─── Step 6: Add PiMox GPG key ───────────────────────────────────────────────
step "Step 6: Add PiMox GPG key"

GPG_OUT="${TR}/usr/share/keyrings/lierfang.gpg"
GPG_PRIMARY="https://mirrors.lierfang.com/pxcloud/pxvirt/pveport.gpg"
GPG_FALLBACK="https://mirrors.lierfang.com/pxcloud/lierfang.gpg"
if curl -fsSL --max-time 10 "$GPG_PRIMARY" -o "$GPG_OUT" 2>/dev/null; then
  ok "GPG key fetched: $GPG_PRIMARY"
elif curl -fsSL --max-time 10 "$GPG_FALLBACK" -o "$GPG_OUT" 2>/dev/null; then
  warn "Primary GPG URL unavailable — used fallback: $GPG_FALLBACK"
else
  die "Failed to fetch PXVirt GPG key from primary ($GPG_PRIMARY) and fallback ($GPG_FALLBACK)"
fi

# ─── Step 7: Add PiMox repository ────────────────────────────────────────────
step "Step 7: Add PiMox apt repository"

REPO_FILE="${TR}/etc/apt/sources.list.d/pveport.list"
cat > "$REPO_FILE" <<EOF
deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt ${CODENAME} main
EOF
ok "Repository added: $REPO_FILE"

apt-get update -y
ok "apt cache refreshed"

# ─── Step 8: Disable NetworkManager ──────────────────────────────────────────
step "Step 8: Disable NetworkManager"

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  systemctl disable --now NetworkManager
  systemctl mask NetworkManager
  ok "NetworkManager disabled and masked"
else
  info "NetworkManager is not active — skipping"
fi

# ─── Step 9: Install ifupdown2 ───────────────────────────────────────────────
step "Step 9: Install ifupdown2"

DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown2
ok "ifupdown2 installed"

# ─── Step 10: Configure network bridge (vmbr0) ───────────────────────────────
step "Step 10: Configure /etc/network/interfaces (vmbr0 bridge)"

NETIF_FILE="${TR}/etc/network/interfaces"
NETIF_BACKUP="${TR}/etc/network/interfaces.pimox-backup-$(date +%s)"
[[ -f "$NETIF_FILE" ]] && cp "$NETIF_FILE" "$NETIF_BACKUP" \
  && info "Backed up existing interfaces → $NETIF_BACKUP"

cat > "$NETIF_FILE" <<EOF
# Generated by pimox-setup.sh on $(date -Iseconds)
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${STATIC_IP}/${NETMASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS}
    bridge-ports ${IFACE}
    bridge-stp off
    bridge-fd 0
EOF
ok "/etc/network/interfaces written"
info "Bridge vmbr0 → ${IFACE}, ${STATIC_IP}/${NETMASK}, gw ${GATEWAY}"

# ─── Step 11: Create post-reboot service for Proxmox VE install ──────────────
step "Step 11: Register post-reboot Proxmox VE installer service"

SERVICE_FILE="${TR}/etc/systemd/system/pimox-install.service"
INSTALL_SCRIPT="${TR}/usr/local/sbin/pimox-install.sh"

cat > "$INSTALL_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec >> /var/log/pimox-install.log 2>&1
echo "[$(date -Iseconds)] Starting Proxmox VE installation..."

# Pre-answer postfix debconf so it doesn't block on "no terminal"
export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/main_mailer_type select Local only"  | debconf-set-selections
echo "postfix postfix/mailname           string $(hostname)" | debconf-set-selections

apt-get install -y proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64

echo "[$(date -Iseconds)] Proxmox VE installation complete."
SCRIPT

if [[ "$PATCH_NAG" == "true" ]]; then
  cat >> "$INSTALL_SCRIPT" <<'NAGPATCH'

# Remove the "No valid subscription" nag from the web UI.
# A dpkg hook re-applies this patch after every proxmox-widget-toolkit upgrade.
cat > /usr/local/sbin/pve-nag-patch.sh <<'EOF'
#!/usr/bin/env bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[[ -f "$JS" ]] || exit 0
sed -Ezi.bak "s/(Ext.Msg.show\(\{[^}]*title: gettext\('No valid sub)/void(\({ \/\/\1/g" "$JS"
EOF
chmod +x /usr/local/sbin/pve-nag-patch.sh

cat > /etc/apt/apt.conf.d/86pve-nag-buster <<'EOF'
DPkg::Post-Invoke { "/usr/local/sbin/pve-nag-patch.sh || true"; };
EOF

/usr/local/sbin/pve-nag-patch.sh
echo "[$(date -Iseconds)] Subscription nag patched."
NAGPATCH
  ok "Subscription nag patch queued for Phase 2"
fi

# Always runs last so the service disables itself after all work is done
cat >> "$INSTALL_SCRIPT" <<'SCRIPT'

# Disable this service so it doesn't run again on next boot
systemctl disable pimox-install.service
SCRIPT

chmod +x "$INSTALL_SCRIPT"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PiMox – Install Proxmox VE after reboot
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/pimox-install.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pimox-install.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pimox-install.service
ok "Service registered: pimox-install.service (runs once on next boot)"
info "Installation log will be written to: /var/log/pimox-install.log"

# ─── Step 12: Configure boot parameters for PiMox ───────────────────────────
step "Step 12: Configure boot parameters"

BOOT_CONFIG="${TR}/boot/firmware/config.txt"
BOOT_CMDLINE="${TR}/boot/firmware/cmdline.txt"

# config.txt: 4K pagesize kernel — required by PXVirt (docs.pxvirt.lierfang.com)
if [[ -f "$BOOT_CONFIG" ]]; then
  if grep -q "^kernel=kernel8.img" "$BOOT_CONFIG"; then
    info "kernel=kernel8.img already set in config.txt"
  else
    _sed_i '/^kernel=/d' "$BOOT_CONFIG"
    printf '\nkernel=kernel8.img\n' >> "$BOOT_CONFIG"
    ok "Set kernel=kernel8.img in config.txt (4K page size required by PXVirt)"
  fi
else
  warn "/boot/firmware/config.txt not found — skipping kernel page size config"
fi

# cmdline.txt: cgroup params required for LXC container memory reporting
if [[ -f "$BOOT_CMDLINE" ]]; then
  CMDLINE=$(tr -d '\n' < "$BOOT_CMDLINE")
  CGROUP_ADDED=""
  for PARAM in "cgroup_enable=cpuset" "cgroup_enable=memory" "cgroup_memory=1"; do
    if ! echo "$CMDLINE" | grep -qF "$PARAM"; then
      CMDLINE="${CMDLINE} ${PARAM}"
      CGROUP_ADDED="${CGROUP_ADDED} ${PARAM}"
    fi
  done
  if [[ -n "$CGROUP_ADDED" ]]; then
    printf '%s\n' "$CMDLINE" > "$BOOT_CMDLINE"
    ok "Added cgroup params to cmdline.txt:${CGROUP_ADDED}"
  else
    info "cgroup params already present in cmdline.txt"
  fi
else
  warn "/boot/firmware/cmdline.txt not found — skipping cgroup config"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Phase 1 complete — ready to reboot                 ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
info "On next boot, the system will automatically install Proxmox VE."
info "After installation, access the web UI at:"
info "  https://${STATIC_IP}:8006"
echo
warn "After Proxmox VE installs you may also want to:"
warn "  • Remove the enterprise repo if not subscribed:"
warn "    rm -f /etc/apt/sources.list.d/pve-enterprise.list"
warn "  • Remove the 'no valid subscription' nag (optional)"
echo

confirm "Reboot now?" && reboot || info "Reboot when ready: sudo reboot"
