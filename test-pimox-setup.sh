#!/usr/bin/env bash
# test-pimox-setup.sh — test harness for pimox-setup.sh
#
# Two modes:
#   Static-only  (--validate-only)  – syntax checks and source-content checks.
#                                     Works anywhere with bash. No root needed.
#   Mock integration (default)      – runs pimox-setup.sh with PIMOX_TEST_ROOT
#                                     to redirect all writes to a temp directory.
#                                     Validates every generated file.
#                                     No root required. Works on macOS and Linux.
#
# Usage:
#   ./test-pimox-setup.sh [options]
#
# Options:
#   --validate-only   Run syntax and source-content checks only; skip mock run
#   --check-urls      Make live HTTP requests to verify mirror URLs are reachable
#   --keep            Leave the test root directory after the test
#   --work-dir DIR    Scratch dir (default: auto temp, auto-cleaned)
#   --hostname NAME   Hostname to use in the mock run (default: pimox-test)
#   --ip ADDR         Static IP to use in the mock run (default: 192.168.1.100)
#   --gateway ADDR    Gateway to use in the mock run (default: 192.168.1.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIMOX_SCRIPT="$SCRIPT_DIR/pimox-setup.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[info]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ ok ]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $*"; }
step()  { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()   { echo -e "${RED}[err]${RESET}   $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
VALIDATE_ONLY=false
CHECK_URLS=false
KEEP=false
WORK_DIR=""
TEST_HOSTNAME="pimox-test"
TEST_IP="192.168.1.100"
TEST_GATEWAY="192.168.1.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --check-urls)    CHECK_URLS=true;    shift ;;
    --keep)          KEEP=true;          shift ;;
    --work-dir)      WORK_DIR="$2";      shift 2 ;;
    --hostname)      TEST_HOSTNAME="$2"; shift 2 ;;
    --ip)            TEST_IP="$2";       shift 2 ;;
    --gateway)       TEST_GATEWAY="$2";  shift 2 ;;
    -h|--help) grep '^#' "$0" | head -30 | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ── Work dir ──────────────────────────────────────────────────────────────────
AUTO_WORK_DIR=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR=$(mktemp -d /tmp/pimox-test-XXXXX)
  AUTO_WORK_DIR=true
fi
mkdir -p "$WORK_DIR"

cleanup() {
  if [[ "$AUTO_WORK_DIR" == "true" && "$KEEP" == "false" ]]; then
    rm -rf "$WORK_DIR"
  elif [[ "$KEEP" == "true" ]]; then
    info "Test root preserved: $WORK_DIR"
  fi
}
trap cleanup EXIT

# ── Results tracking ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0

record() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) echo -e "  ${GREEN}[PASS]${RESET} $name"; PASS=$((PASS + 1)) ;;
    FAIL) echo -e "  ${RED}[FAIL]${RESET} $name${detail:+: $detail}"; FAIL=$((FAIL + 1)) ;;
    SKIP) echo -e "  ${YELLOW}[SKIP]${RESET} $name${detail:+: $detail}"; SKIP=$((SKIP + 1)) ;;
  esac
}

check_contains() {
  local name="$1" pattern="$2" file="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "pattern '${pattern}' not found in $(basename "$file")"
  fi
}

check_exists() {
  local name="$1" file="$2"
  if [[ -e "$file" ]]; then
    record PASS "$name"
  else
    record FAIL "$name" "not found: $file"
  fi
}

check_executable() {
  local name="$1" file="$2"
  if [[ -x "$file" ]]; then
    record PASS "$name"
  else
    record FAIL "$name" "not executable: $file"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Static checks (no root, no special env)
# ─────────────────────────────────────────────────────────────────────────────
step "Static checks"

[[ -f "$PIMOX_SCRIPT" ]] || die "pimox-setup.sh not found at $PIMOX_SCRIPT"

# Syntax
if bash -n "$PIMOX_SCRIPT" 2>/dev/null; then
  record PASS "bash syntax valid"
else
  record FAIL "bash syntax valid" "bash -n failed"
fi

# Help exits 0
if "$PIMOX_SCRIPT" --help &>/dev/null; then
  record PASS "--help exits 0"
else
  record FAIL "--help exits 0"
fi

# Unknown flag exits non-zero
if ! "$PIMOX_SCRIPT" --this-flag-does-not-exist 2>/dev/null; then
  record PASS "unknown flag exits non-zero"
else
  record FAIL "unknown flag exits non-zero"
fi

# Source-content checks — grep the script itself for required strings
check_contains "pimox-install.sh installs proxmox-ve"           "proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64" "$PIMOX_SCRIPT"
check_contains "pimox-install.sh sets DEBIAN_FRONTEND"          "DEBIAN_FRONTEND=noninteractive"              "$PIMOX_SCRIPT"
check_contains "pimox-install.sh pre-seeds postfix debconf"     "postfix/main_mailer_type"                    "$PIMOX_SCRIPT"
check_contains "pimox-install.sh self-disables service"         "systemctl disable pimox-install.service"     "$PIMOX_SCRIPT"
check_contains "pimox-install.sh logs to /var/log"              "pimox-install.log"                           "$PIMOX_SCRIPT"
check_contains "service: After=network-online.target"           "After=network-online.target"                 "$PIMOX_SCRIPT"
check_contains "service: Wants=network-online.target"           "Wants=network-online.target"                 "$PIMOX_SCRIPT"
check_contains "service: ExecStart points to install script"    "ExecStart=/usr/local/sbin/pimox-install.sh"  "$PIMOX_SCRIPT"
check_contains "service: WantedBy=multi-user.target"            "WantedBy=multi-user.target"                  "$PIMOX_SCRIPT"
check_contains "service: Type=oneshot"                          "Type=oneshot"                                "$PIMOX_SCRIPT"
check_contains "repo URL is pxcloud/pxvirt"                     "mirrors.lierfang.com/pxcloud/pxvirt"         "$PIMOX_SCRIPT"
check_contains "GPG key from mirrors.lierfang.com/pxcloud"      "https://mirrors.lierfang.com/pxcloud"        "$PIMOX_SCRIPT"
check_contains "cloud.cfg.d: preserve_hostname"                 "preserve_hostname: true"                     "$PIMOX_SCRIPT"
check_contains "cloud.cfg.d: manage_etc_hosts false"            "manage_etc_hosts: false"                     "$PIMOX_SCRIPT"
check_contains "interfaces: vmbr0 bridge config"                "iface vmbr0 inet static"                     "$PIMOX_SCRIPT"
check_contains "interfaces: bridge-stp off"                     "bridge-stp off"                              "$PIMOX_SCRIPT"
check_contains "interfaces: bridge-fd 0"                        "bridge-fd 0"                                 "$PIMOX_SCRIPT"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — URL reachability (--check-urls only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$CHECK_URLS" == "true" ]]; then

step "URL reachability checks"

check_url() {
  local name="$1" url="$2"
  local code
  code=$(curl -fsSL -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    record PASS "$name (HTTP $code)"
  else
    record FAIL "$name" "HTTP ${code:-000} from $url"
  fi
}

check_url "GPG key URL reachable"                    "https://mirrors.lierfang.com/pxcloud/lierfang.gpg"
check_url "Repo Release file reachable (bookworm)"   "https://mirrors.lierfang.com/pxcloud/pxvirt/dists/bookworm/Release"
check_url "Repo Release file reachable (trixie)"     "https://mirrors.lierfang.com/pxcloud/pxvirt/dists/trixie/Release"

else
  info "Skipping URL checks (pass --check-urls to enable)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Mock integration (PIMOX_TEST_ROOT redirects all file writes)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  info "Skipping mock integration (--validate-only)"
else

step "Mock integration run"

TR="$WORK_DIR/test-root"

info "Running pimox-setup.sh with PIMOX_TEST_ROOT=$TR ..."
PIMOX_TEST_ROOT="$TR" \
  "$PIMOX_SCRIPT" \
    -y \
    --hostname   "$TEST_HOSTNAME" \
    --ip         "$TEST_IP" \
    --gateway    "$TEST_GATEWAY" \
    --netmask    24 \
    --dns        1.1.1.1 \
    --iface      eth0 \
    --root-password testpass \
    --skip-upgrade 2>&1 | sed 's/^/    /'

echo

step "Validating generated files"

# /etc/hosts
check_exists    "/etc/hosts exists"                  "${TR}/etc/hosts"
check_contains  "/etc/hosts has static IP → hostname" "${TEST_IP}    ${TEST_HOSTNAME}" "${TR}/etc/hosts"

# /etc/network/interfaces
check_exists    "/etc/network/interfaces exists"     "${TR}/etc/network/interfaces"
check_contains  "interfaces: has vmbr0 stanza"       "iface vmbr0 inet static"         "${TR}/etc/network/interfaces"
check_contains  "interfaces: has static IP/prefix"   "${TEST_IP}/24"                   "${TR}/etc/network/interfaces"
check_contains  "interfaces: has gateway"            "gateway ${TEST_GATEWAY}"         "${TR}/etc/network/interfaces"
check_contains  "interfaces: bridge-ports eth0"      "bridge-ports eth0"               "${TR}/etc/network/interfaces"
check_contains  "interfaces: bridge-stp off"         "bridge-stp off"                  "${TR}/etc/network/interfaces"
check_contains  "interfaces: auto ${IFACE:-eth0}"    "auto eth0"                       "${TR}/etc/network/interfaces"

# pimox-install.sh
INSTALL="${TR}/usr/local/sbin/pimox-install.sh"
check_exists      "pimox-install.sh exists"                "$INSTALL"
check_executable  "pimox-install.sh is executable"         "$INSTALL"
check_contains    "pimox-install.sh: installs proxmox-ve"  "proxmox-ve"                 "$INSTALL"
check_contains    "pimox-install.sh: DEBIAN_FRONTEND set"  "DEBIAN_FRONTEND"            "$INSTALL"
check_contains    "pimox-install.sh: self-disables"        "systemctl disable"          "$INSTALL"
check_contains    "pimox-install.sh: logs to file"         "pimox-install.log"          "$INSTALL"

# pimox-install.service
SERVICE="${TR}/etc/systemd/system/pimox-install.service"
check_exists    "pimox-install.service exists"             "$SERVICE"
check_contains  "service: After=network-online.target"     "After=network-online.target"            "$SERVICE"
check_contains  "service: ExecStart correct"               "ExecStart=/usr/local/sbin/pimox-install" "$SERVICE"
check_contains  "service: Type=oneshot"                    "Type=oneshot"                            "$SERVICE"
check_contains  "service: WantedBy=multi-user.target"      "WantedBy=multi-user.target"              "$SERVICE"

# APT repo
REPO="${TR}/etc/apt/sources.list.d/pveport.list"
check_exists    "pveport.list exists"                      "$REPO"
check_contains  "pveport.list: mirrors.lierfang.com URL"   "mirrors.lierfang.com"       "$REPO"
check_contains  "pveport.list: pxcloud/pxvirt"              "pxcloud/pxvirt"             "$REPO"

# GPG key placeholder
GPG_FILE="${TR}/usr/share/keyrings/lierfang.gpg"
check_exists    "GPG keyrings directory exists"            "${TR}/usr/share/keyrings"
check_exists    "GPG key file (lierfang.gpg) written"      "$GPG_FILE"

# cloud-init drop-in
DROPIN="${TR}/etc/cloud/cloud.cfg.d/99-pimox-hostname.cfg"
check_exists    "99-pimox-hostname.cfg exists"             "$DROPIN"
check_contains  "99-pimox-hostname.cfg: preserve_hostname" "preserve_hostname: true"    "$DROPIN"
check_contains  "99-pimox-hostname.cfg: manage_etc_hosts"  "manage_etc_hosts: false"    "$DROPIN"

fi  # end mock integration

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
printf "${BOLD}  Results: ${GREEN}%d passed${RESET}  ${RED}%d failed${RESET}  ${YELLOW}%d skipped${RESET}\n" $PASS $FAIL $SKIP
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo

[[ $FAIL -eq 0 ]]
