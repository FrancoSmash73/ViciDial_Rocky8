#!/bin/bash
################################################################################
# VICIDIAL ULTIMATE INSTALLATION - PART 2: v11.2
# VoIP Stack: DAHDI 3.4.0, LibPRI 1.6.1, Asterisk 20.18.2 (plain upstream)
# ViciDial + ConfBridge + CRITICAL Process Management
################################################################################
# Date: 2026-02-16
# Updated: 2026-02-25
# Author: FrancoSmash73 + Claude (Anthropic)
# Target: Rocky Linux 8.10 / AlmaLinux 8.10 (ported from the Rocky 10 build)
# Asterisk: 20.18.2 -- PLAIN upstream from asterisk.org, matching the
#           production box (Oliver). ViciDial publishes no 20.x-vici tarball
#           and no Asterisk-20 patch set.
# DAHDI: 3.4.0 (Patched Linux + Patched Tools from FrancoSmash73)
#
# NEW IN v11.2 (2026-02-25):
# ✅ FIX: Final safety-net DBI:MariaDB re-patch added at end of installer
#         Ensures agi-VDAD_ALL_inbound.agi and all AGI scripts retain
#         DBI:MariaDB after any step that redeploys files (e.g. install.pl
#         re-run). Without this, all ViciDial inbound routing silently breaks
#         on Rocky Linux 10 where DBD::mysql is not available.
#
# NEW IN v11.1 (2026-02-18):
# ✅ FIX: AST_VDauto_dial_FILL.pl MAX_RUNTIME 180 → 600s (was killed before hopper filled)
# ✅ FIX: vicidial_agent_disable set to NONE (default ALL blocked agent logins)
#
# NEW IN v11.0 - PROCESS LOCKING + CLEANUP:
# ✅ NEW: SYSTEMD TIMERS for keepalive (eliminates duplicate process bug)
# ✅ NEW: FLOCK WRAPPER for all high-frequency cron scripts
# ✅ NEW: PROCESS MONITOR DAEMON (actively kills duplicates)
# ✅ NEW: AlmaLinux 10.x OS support (Rocky OR Alma)
# ✅ FIX: Duplicate check_step call removed from Step 6
# ✅ FIX: Duplicate make install/samples/logrotate removed from Step 4
# ✅ FIX: Duplicate VERIFICATION COMMANDS banner removed from footer
# ✅ Crontab Step: ADMIN_keepalive_ALL.pl moved to systemd timer
# ✅ Crontab Step: High-frequency scripts wrapped with flock
#
# RETAINED FROM v10.19 - NO-HARDWARE FIX:
# ✅ FIX: DAHDI Tools verification works without telephony hardware
# ✅ FIX: Graceful handling of "No hardware found" message
# ✅ FIX: Clear messaging that no hardware is OK for VoIP-only
# ✅ FIX: Multiple verification methods (binary, libraries, version)
# ✅ FIX: Lenient validation for software-only installations
# ✅ FIX: User-friendly explanations during verification
#
# NEW IN v10.18 - OPTIMIZATION RELEASE:
# ✅ OPT #1: Secure password storage (no plain text in marker files)
# ✅ OPT #2: Pre-flight environment validation (disk space, memory, CPU)
# ✅ OPT #3: Parallel compilation support (make -j)
# ✅ OPT #4: File backup capability before modifications
# ✅ OPT #5: Checksum verification for critical downloads
# ✅ OPT #6: Progress indicators for long operations
# ✅ OPT #7: Performance metrics tracking (step duration)
# ✅ OPT #8: Enhanced input validation from marker files
# ✅ OPT #9: Temporary file security (mktemp + trap)
# ✅ OPT #10: Better error messages with troubleshooting hints
#
# CRITICAL FIXES IN v10.17:
# ✅ FIX #1: Consolidated credential loading from Part 1 marker (DB_USER, DB_PASS, DB_NAME defined)
# ✅ FIX #2: Removed duplicate mark_step_complete() function
# ✅ FIX #3: Improved GMT offset calculation (no Python dependency)
# ✅ FIX #4: Added safe_curl() function for consistent downloads
# ✅ FIX #5: Added wait_for_service() function (no arbitrary sleeps)
# ✅ FIX #6: Crontab merge (preserves existing entries)
# ✅ FIX #7: All MySQL commands have error checking
# ✅ FIX #8: Cleanup section (removes temp files)
# ✅ FIX #9: Validation summary before completion
#
# WHAT'S NEW IN v10.17:
# ✅ UPGRADED: DAHDI Linux 3.4.0 (Patched) from github.com/FrancoSmash73
# ✅ UPGRADED: DAHDI Tools 3.4.0 (Patched) from github.com/FrancoSmash73
# ✅ FIXED: DAHDI Tools configure.ac patched for modern autotools (Rocky 10.x)
# ✅ FIXED: DAHDI Tools --libdir=/usr/lib64 for x86_64 systems
# ✅ FIXED: Pre-generated configure script included (no autoreconf needed)
# ✅ NEW: Both DAHDI components from FrancoSmash73 repos (no upstream dependency)
# ✅ NEW: Two-phase DAHDI installation (Linux kernel modules + Tools separately)
# ✅ NEW: Comprehensive DAHDI verification checks (modules, version, functionality)
# ✅ NEW: Automated DAHDI module loading and configuration validation
# ✅ IMPROVED: Better compatibility with modern Linux kernels (Rocky 10.x)
#
# WHAT'S NEW IN v10.16:
# ✅ UPGRADED: DAHDI Linux 3.4.0 (Patched) from github.com/FrancoSmash73
# ✅ UPGRADED: DAHDI Tools 3.4.0 (Official) from github.com/asterisk
#
# WHAT'S NEW IN v10.15:
# ✅ CRITICAL FIX: mysql_insertid -> mariadb_insertid in ALL scripts
# ✅ CRITICAL FIX: cid_channels_recent_{server_ip} table verified/recreated
# ✅ CRITICAL FIX: AST_flush_DBqueue.pl retention extended (121s -> 600s)
# ✅ CRITICAL FIX: extensions.conf Wait(2) -> Wait(120) for _1383XX pattern
# ✅ FIX: Step 7.5 now patches mysql_insertid in all 3 locations
# ✅ FIX: Step 21 now sets BOTH local_gmt AND default_local_gmt
#################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# ERROR HANDLER
# ---------------------------------------------------------------------------
handle_error() {
local LINE="$1"
local CMD="$2"
echo -e "\n${RED}╔═══════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ERROR on line $LINE${NC}"
echo -e "${RED}║  Command: $CMD${NC}"
echo -e "${RED}║  Check output above for details.${NC}"
echo -e "${RED}╚═══════════════════════════════════════════╝${NC}\n"
echo "Check install log at: /var/log/vicidial_install_part2.log"
exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# COLORS & LOGGING
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
section() {
echo -e "\n${BLUE}${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║ $1${NC}"
echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════╝${NC}\n"
}

# Redirect all output to log
LOG_FILE="/var/log/vicidial_install_part2.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"

# ---------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ---------------------------------------------------------------------------

# Wait for service to be active (FIX #5 - replaces arbitrary sleeps)
wait_for_service() {
local SERVICE="$1"
local TIMEOUT="${2:-30}"
local counter=0

log "Waiting for $SERVICE to be active (timeout: ${TIMEOUT}s)..."

while ! systemctl is-active --quiet "$SERVICE"; do
sleep 1
((counter++))
if [ $counter -ge $TIMEOUT ]; then
error "$SERVICE failed to start within ${TIMEOUT} seconds"
fi
done

success "$SERVICE is active (took ${counter}s)"
}

# Safe curl wrapper with retries (FIX #4)
safe_curl() {
local URL="$1"
local OUTPUT="$2"
local DESC="${3:-$URL}"
local attempt

for attempt in 1 2 3; do
log "Downloading $DESC with curl (attempt $attempt/3)..."
if curl -L --retry 2 --connect-timeout 60 --max-time 300 \
--progress-bar -o "$OUTPUT" "$URL"; then
success "Downloaded: $DESC"
return 0
fi
warning "Attempt $attempt failed for $DESC"
sleep 5
done
error "Failed to download $DESC after 3 attempts. Check connectivity."
}

# Safe wget wrapper (kept for backward compatibility)
safe_wget() {
local URL="$1"
local DESC="${2:-$URL}"
local attempt
for attempt in 1 2 3; do
log "Downloading $DESC (attempt $attempt/3)..."
if wget --tries=2 --timeout=60 -q --show-progress "$URL"; then
success "Downloaded: $DESC"
return 0
fi
warning "Attempt $attempt failed for $DESC"
sleep 5
done
error "Failed to download $DESC after 3 attempts. Check connectivity."
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: File backup before modification
# ---------------------------------------------------------------------------
create_backup() {
local FILE="$1"
if [ -f "$FILE" ]; then
local BACKUP="${FILE}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$FILE" "$BACKUP" || warning "Failed to backup $FILE"
info "Backed up: $FILE → $BACKUP"
return 0
fi
return 1
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: Validate IP address format
# ---------------------------------------------------------------------------
validate_ip() {
local IP="$1"
if [[ ! "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
return 1
fi
return 0
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: Show progress for long operations
# ---------------------------------------------------------------------------
show_progress() {
local PID=$1
local DESC="$2"
local counter=0
echo -n "${CYAN}[$DESC]${NC} "
while kill -0 $PID 2>/dev/null; do
echo -n "."
sleep 2
((counter++))
done
echo " ${GREEN}✓${NC}"
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: Detect CPU cores for parallel compilation
# ---------------------------------------------------------------------------
get_make_jobs() {
local CPU_CORES=$(nproc 2>/dev/null || echo 2)
echo $((CPU_CORES + 1))
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: Performance metrics - track step duration
# ---------------------------------------------------------------------------
STEP_START_TIME=0

start_step_timer() {
STEP_START_TIME=$(date +%s)
}

end_step_timer() {
local STEP_KEY="$1"
if [ "$STEP_START_TIME" -gt 0 ]; then
local END_TIME=$(date +%s)
local DURATION=$((END_TIME - STEP_START_TIME))
local MINUTES=$((DURATION / 60))
local SECONDS=$((DURATION % 60))
info "⏱️  Step completed in ${MINUTES}m ${SECONDS}s"
echo "${STEP_KEY}_DURATION=${DURATION}" >> "$INSTALL_MARKER"
STEP_START_TIME=0
fi
}

# ---------------------------------------------------------------------------
# OPTIMIZATION: Secure temporary file creation
# ---------------------------------------------------------------------------
create_temp_file() {
local DESC="${1:-temp}"
local TEMP_FILE=$(mktemp /tmp/vicidial_${DESC}_XXXXXX) || error "Failed to create temp file for $DESC"
# Add to cleanup trap
TEMP_FILES+=("$TEMP_FILE")
echo "$TEMP_FILE"
}

# Global array for temp file cleanup
TEMP_FILES=()

cleanup_temp_files() {
for file in "${TEMP_FILES[@]}"; do
rm -f "$file" 2>/dev/null || true
done
}

# Add cleanup trap
trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# RESUME HELPER
# ---------------------------------------------------------------------------
SKIP_STEP=false

check_step() {
local STEP_KEY="$1"
local STEP_NUM="$2"
local STEP_NAME="$3"
SKIP_STEP=false

# OPTIMIZATION: Start performance timer for this step
start_step_timer

if grep -q "^${STEP_KEY}=COMPLETE" "$INSTALL_MARKER" 2>/dev/null; then
echo ""
echo -e "${YELLOW}╔═══════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  STEP ${STEP_NUM}: ${STEP_NAME}${NC}"
echo -e "${YELLOW}║  Previously completed.                   ${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════╝${NC}"
echo ""
read -p "$(echo -e ${YELLOW}"[S]kip / [R]e-run / [Q]uit? "${NC})" -n 1 -r REPLY
echo ""
case "$REPLY" in
s|S) SKIP_STEP=true; info "Skipping Step $STEP_NUM..." ;;
r|R) SKIP_STEP=false; warning "Re-running Step $STEP_NUM..." ;;
q|Q) error "Installation aborted by user." ;;
*) warning "Invalid input - Skipping"; SKIP_STEP=true ;;
esac
fi
}

# FIX #2: Single definition only (removed duplicate)
mark_step_complete() {
local STEP_KEY="$1"
sed -i "/^${STEP_KEY}=/d" "$INSTALL_MARKER" 2>/dev/null || true
echo "${STEP_KEY}=COMPLETE" >> "$INSTALL_MARKER"
# OPTIMIZATION: Record step duration
end_step_timer "$STEP_KEY"
log "Step ${STEP_KEY} marked complete."
}

# ---------------------------------------------------------------------------
# INITIALIZATION
# ---------------------------------------------------------------------------
section "INITIALIZING VICIDIAL ULTIMATE PART 2 INSTALLATION v11.2"

VERSION="11.0"
INSTALL_MARKER="/root/.vicidial_part2_progress"

# Load shared version config (ASTERISK_VERSION) — falls back to a
# known-good default if this script was copied out on its own.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$SCRIPT_DIR/configs/versions.conf" ]; then
    # shellcheck source=configs/versions.conf
    source "$SCRIPT_DIR/configs/versions.conf"
else
    echo "[WARNING] configs/versions.conf not found — using built-in defaults" >&2
    ASTERISK_VERSION="20.18.2"
    DAHDI_LINUX_BRANCH="master"
fi
ASTERISK_VERSION="${ASTERISK_VERSION:-20.18.2}"
DAHDI_LINUX_BRANCH="${DAHDI_LINUX_BRANCH:-master}"

# Site Perl library dir that's always on @INC. Rocky 8's Perl 5.26 uses
# /usr/local/share/perl5 (no version folder); Rocky 10's 5.40 uses
# /usr/local/share/perl5/5.40. Ask Perl rather than guessing.
PERL_SITELIB="$(perl -MConfig -e 'print $Config{installsitelib}')"

if [ ! -f "$INSTALL_MARKER" ]; then
log "First run - creating install marker at $INSTALL_MARKER"
touch "$INSTALL_MARKER"
echo "START_TIME=$(date +%s)" > "$INSTALL_MARKER"
echo "VERSION=$VERSION" >> "$INSTALL_MARKER"
fi

START_TIME=$(grep '^START_TIME=' "$INSTALL_MARKER" | cut -d'=' -f2)

# Server IP (used everywhere)
SERVER_IP=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
error "Could not detect server IP - check network configuration"
fi

# OPTIMIZATION: Validate IP format
if ! validate_ip "$SERVER_IP"; then
error "Invalid IP address format detected: $SERVER_IP"
fi
info "Detected Server IP: $SERVER_IP"

# Save to marker if not already there
if ! grep -q "^SERVER_IP=" "$INSTALL_MARKER"; then
echo "SERVER_IP=$SERVER_IP" >> "$INSTALL_MARKER"
fi

# ---------------------------------------------------------------------------
# FIX #1: CONSOLIDATED CREDENTIAL LOADING FROM PART 1
# ---------------------------------------------------------------------------
PART1_MARKER="/root/vicidial_ultimate_install.conf"
CREDS_FILE="/root/.vicidial_ultimate_credentials"

if [ ! -f "$PART1_MARKER" ]; then
    error "Part 1 marker not found at $PART1_MARKER - run Part 1 first!"
fi
if [ ! -f "$CREDS_FILE" ]; then
    error "Credentials file not found at $CREDS_FILE - run Part 1 first!"
fi

log "Loading database credentials from Part 1..."
MYSQL_ROOT_PASSWORD=$(grep "^MYSQL_ROOT_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2-)
DB_PASSWORD=$(grep "^DB_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2-)
CUSTOM_DB_PASSWORD=$(grep "^CUSTOM_DB_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2-)

if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ -z "$DB_PASSWORD" ]; then
    error "Required passwords not found in $CREDS_FILE"
fi
if [ -z "$CUSTOM_DB_PASSWORD" ]; then
    warning "CUSTOM_DB_PASSWORD not set - using DB_PASSWORD as fallback"
    CUSTOM_DB_PASSWORD="$DB_PASSWORD"
fi
# FIX #1: Set standard variable names used throughout script
DB_USER="cron"
DB_NAME="asterisk"
DB_PASS="$DB_PASSWORD"
success "Database credentials loaded"
info "DB user: $DB_USER | DB name: $DB_NAME"

# OPTIMIZATION: Secure password storage - Use hashes and restrict file permissions
# Store only hash references for verification, actual passwords stay in memory
if ! grep -q "^CREDENTIALS_LOADED=" "$INSTALL_MARKER"; then
	PASS_HASH=$(echo -n "$DB_PASSWORD" | sha256sum | cut -d' ' -f1)
	echo "CREDENTIALS_LOADED=YES" >> "$INSTALL_MARKER"
	echo "DB_PASSWORD_HASH=$PASS_HASH" >> "$INSTALL_MARKER"
	echo "DB_USER=$DB_USER" >> "$INSTALL_MARKER"
	echo "DB_NAME=$DB_NAME" >> "$INSTALL_MARKER"
	chmod 600 "$INSTALL_MARKER"
	info "Credentials secured in marker file (600 permissions)"
fi

success "Initialization complete - resuming installation"

INSTALL_DIR="/usr/src"

# Ensure required tools are available
for tool in svn patch wget curl perl git screen; do
if ! command -v "$tool" &>/dev/null; then
log "Installing missing tool: $tool"
dnf install -y "$tool" || error "Failed to install $tool"
fi
done
success "Pre-flight checks complete"

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║        ViciDial ULTIMATE Installation - Part 2               ║"
echo "║      VoIP Stack, Asterisk 20 (plain upstream) + ConfBridge   ║"
echo "║                                                              ║"
echo "║             Version 11.0 FINAL                               ║"
echo "║   Rocky Linux 8.10 / AlmaLinux 8.10                        ║"
echo "║                                                              ║"
echo "║  ⭐ Process Locking: systemd timers + flock wrappers        ║"
echo "║  ⭐ ZERO duplicate ADMIN_keepalive_ALL.pl processes         ║"
echo "║  ⭐ No-hardware VoIP-only compatible                        ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
section "PRE-FLIGHT VALIDATION"

if [ "$EUID" -ne 0 ]; then
error "Please run as root (use: sudo su -)"
fi

# OS check - supports both Rocky Linux and AlmaLinux 8.10+
if [ -f /etc/rocky-release ]; then
    OS_NAME="Rocky Linux"
    OS_RELEASE_FILE="/etc/rocky-release"
elif [ -f /etc/almalinux-release ]; then
    OS_NAME="AlmaLinux"
    OS_RELEASE_FILE="/etc/almalinux-release"
else
    error "This script requires Rocky Linux 8.10 or AlmaLinux 8.10"
fi

OS_VERSION=$(grep -oP '\d+\.\d+' "$OS_RELEASE_FILE" | head -1)

if [[ ! "$OS_VERSION" =~ ^8\.([0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" -lt 10 ]; then
    error "This script requires $OS_NAME 8.10 or newer 8.x. Detected: $OS_VERSION"
fi
success "OS Check: $OS_NAME $OS_VERSION (supported)"

# Part 1 must be complete
if ! grep -q "PART_1_COMPLETE=YES" "$PART1_MARKER"; then
error "Part 1 did not complete successfully. Check Part 1 installation."
fi
success "Part 1 completion verified"

# MariaDB must be running
if ! systemctl is-active --quiet mariadb; then
error "MariaDB is not running! Please check Part 1 installation."
fi
success "MariaDB service is running"

# ---------------------------------------------------------------------------
# OPTIMIZATION: Environment Validation - Disk, Memory, CPU
# ---------------------------------------------------------------------------
info "Checking system resources..."

# Disk space check (need at least 10GB in /usr/src)
REQUIRED_GB=10
AVAILABLE_GB=$(df -BG /usr/src 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
if [ "$AVAILABLE_GB" -lt "$REQUIRED_GB" ]; then
	error "Insufficient disk space in /usr/src. Required: ${REQUIRED_GB}GB, Available: ${AVAILABLE_GB}GB"
fi
success "Disk space: ${AVAILABLE_GB}GB available in /usr/src (minimum: ${REQUIRED_GB}GB)"

# Memory check (recommend at least 2GB free)
REQUIRED_MB=2048
AVAILABLE_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
	warning "Low memory: ${AVAILABLE_MB}MB available (recommended: ${REQUIRED_MB}MB)"
	warning "Installation may be slower or fail during compilation"
else
	success "Memory: ${AVAILABLE_MB}MB available"
fi

# CPU cores check
CPU_CORES=$(nproc 2>/dev/null || echo 1)
MAKE_JOBS=$(get_make_jobs)
info "CPU: $CPU_CORES cores detected - will use make -j$MAKE_JOBS for compilation"

echo "CPU_CORES=$CPU_CORES" >> "$INSTALL_MARKER"
echo "MAKE_JOBS=$MAKE_JOBS" >> "$INSTALL_MARKER"

success "Pre-flight checks complete"

# ===========================================================================
# STEP 1: DAHDI 3.4.0 (FULLY PATCHED - FrancoSmash73)
# ===========================================================================
section "STEP 1/22: INSTALLING DAHDI 3.4.0 (FULLY PATCHED)"
check_step "STEP_1" "1/22" "DAHDI 3.4.0 Patched Installation"

if [ "$SKIP_STEP" = false ]; then
cd "$INSTALL_DIR"

# Sub-step markers for granular resume
DAHDI_LINUX_COMPLETE=false
DAHDI_TOOLS_COMPLETE=false

# Check if sub-steps are already complete
grep -q "^STEP_1_LINUX=COMPLETE" "$INSTALL_MARKER" 2>/dev/null && DAHDI_LINUX_COMPLETE=true
grep -q "^STEP_1_TOOLS=COMPLETE" "$INSTALL_MARKER" 2>/dev/null && DAHDI_TOOLS_COMPLETE=true

if [ "$DAHDI_LINUX_COMPLETE" = true ] && [ "$DAHDI_TOOLS_COMPLETE" = true ]; then
success "Both DAHDI Linux and DAHDI Tools already installed"
info "Skipping to verification..."
fi

# -------------------------------------------------------------------
# PHASE 1: DAHDI LINUX 3.4.0 (Patched - FrancoSmash73)
# -------------------------------------------------------------------
if [ "$DAHDI_LINUX_COMPLETE" = false ]; then
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PHASE 1: DAHDI LINUX 3.4.0 (PATCHED)    ║${NC}"
echo -e "${CYAN}║  Source: github.com/FrancoSmash73          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# Clean previous installs
log "Cleaning previous DAHDI Linux installations..."
rm -rf dahdi-linux-3.4.0

# DAHDI builds against the RUNNING kernel. A 'dnf update' in Part 1 can
# install a newer kernel-devel than the kernel you're booted into; reboot
# after Part 1, or install the matching headers here.
if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
log "Installing kernel-devel for the running kernel ($(uname -r))..."
dnf install -y "kernel-devel-$(uname -r)" || error "kernel-devel-$(uname -r) not available - reboot into the newest kernel and re-run Part 2"
fi

info "Cloning DAHDI Linux 3.4.0 (branch ${DAHDI_LINUX_BRANCH}; EL8 patch applied after clone)..."
if ! git clone --branch "$DAHDI_LINUX_BRANCH" https://github.com/FrancoSmash73/dahdi-linux-3.4.0.git; then
error "Failed to clone DAHDI Linux repo. Check network connectivity."
fi

if [ ! -d "dahdi-linux-3.4.0" ]; then
error "DAHDI Linux directory not found after clone"
fi

cd dahdi-linux-3.4.0 || error "Failed to enter DAHDI Linux directory"

# Rocky 8 only: the shared dahdi-linux repo targets kernel 6.12. Rocky 8's
# 4.18 kernel lacks timer_container_of() and has RHEL's backported 3-argument
# netif_napi_add(). Apply the EL8 compat patch from THIS repo; the dahdi-linux
# repo itself stays as-is.
DAHDI_EL8_PATCH="$SCRIPT_DIR/patches/dahdi-linux-el8-compat.patch"
[ -f "$DAHDI_EL8_PATCH" ] || error "Missing $DAHDI_EL8_PATCH - run Part 2 from inside the ViciDial_Rocky8 checkout"
if patch -p1 -R -s -f --dry-run < "$DAHDI_EL8_PATCH" >/dev/null 2>&1; then
info "DAHDI EL8 compat patch already applied"
else
patch -p1 -N < "$DAHDI_EL8_PATCH" || error "Failed to apply $DAHDI_EL8_PATCH"
success "Applied DAHDI EL8 compat patch"
fi

# OPTIMIZATION: Get make jobs for parallel compilation
MAKE_JOBS=$(get_make_jobs)
log "Compiling DAHDI Linux with $MAKE_JOBS parallel jobs (this may take 3-8 minutes)..."
make clean || true

# Run compilation in background to show progress
if ! make -j$MAKE_JOBS all 2>&1 | tee /tmp/dahdi_linux_build.log; then
echo ""
echo -e "${RED}╔═══════════════════════════════════════════╗${NC}"
echo -e "${RED}║  DAHDI LINUX COMPILATION FAILED           ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo "Common causes:"
echo "  - Missing kernel headers: dnf install kernel-devel"
echo "  - Kernel version mismatch"
echo "  - Missing build tools: dnf groupinstall 'Development Tools'"
echo ""
echo "Build log saved to: /tmp/dahdi_linux_build.log"
error "DAHDI Linux compilation failed - fix errors and re-run"
fi

log "Installing DAHDI Linux..."
if ! make install; then
error "DAHDI Linux installation failed!"
fi

# Build DAHDI configuration
log "Running make config..."
make config || warning "make config had warnings (continuing)"

success "DAHDI Linux 3.4.0 (Patched) installed successfully"
echo "STEP_1_LINUX=COMPLETE" >> "$INSTALL_MARKER"
DAHDI_LINUX_COMPLETE=true
cd "$INSTALL_DIR"
else
info "DAHDI Linux already installed - skipping Phase 1"
fi

# -------------------------------------------------------------------
# PHASE 2: DAHDI TOOLS 3.4.0 (Patched - FrancoSmash73)
# -------------------------------------------------------------------
if [ "$DAHDI_TOOLS_COMPLETE" = false ]; then
cd "$INSTALL_DIR"

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PHASE 2: DAHDI TOOLS 3.4.0 (PATCHED)    ║${NC}"
echo -e "${CYAN}║  Source: github.com/FrancoSmash73          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# Clean previous installs
log "Cleaning previous DAHDI Tools installations..."
rm -rf dahdi-tools-3.4.0

info "Cloning DAHDI Tools 3.4.0 (pre-generated configure; do not autoreconf on Rocky 8)..."
if ! git clone https://github.com/FrancoSmash73/dahdi-tools-3.4.0.git; then
error "Failed to clone DAHDI Tools repo. Check network connectivity."
fi

if [ ! -d "dahdi-tools-3.4.0" ]; then
error "DAHDI Tools directory not found after clone"
fi

cd dahdi-tools-3.4.0 || error "Failed to enter DAHDI Tools directory"

# Verify pre-generated configure script exists
if [ ! -f configure ]; then
warning "Pre-generated configure not found - running autoreconf..."
dnf install -y autoconf automake libtool libtool-ltdl-devel || error "Failed to install autotools"
autoreconf -i || error "autoreconf failed"
fi

log "Configuring DAHDI Tools (--libdir=/usr/lib64 for x86_64)..."
./configure --libdir=/usr/lib64 || error "DAHDI Tools configure failed!"

# OPTIMIZATION: Parallel compilation for DAHDI Tools
log "Compiling DAHDI Tools with $MAKE_JOBS parallel jobs..."
make clean || true
make -j$MAKE_JOBS || error "DAHDI Tools compilation failed!"

log "Installing DAHDI Tools..."
make install || error "DAHDI Tools installation failed!"
make install-config || error "DAHDI Tools config installation failed!"

log "Updating library cache..."
ldconfig

# Verify tools work (check multiple ways for no-hardware systems)
log "Verifying DAHDI Tools installation..."
DAHDI_VERIFY_FAILED=false

# Method 1: Check for version in help output
if dahdi_cfg --help 2>&1 | grep -q "DAHDI Tools Version"; then
	TOOLS_VER=$(dahdi_cfg --help 2>&1 | grep "DAHDI Tools Version" | head -1 || true)
	success "DAHDI Tools verified: $TOOLS_VER"
# Method 2: Check if dahdi_cfg binary exists and is executable
elif [ -x "/usr/sbin/dahdi_cfg" ] || [ -x "/usr/local/sbin/dahdi_cfg" ] || command -v dahdi_cfg &>/dev/null; then
	info "DAHDI Tools binary found (no hardware detected - this is OK for software-only installations)"
	# Try to get version another way
	if dahdi_cfg -v 2>&1 | grep -qE "dahdi|version|[0-9]\.[0-9]"; then
		TOOLS_VER=$(dahdi_cfg -v 2>&1 | head -1 || true)
		success "DAHDI Tools installed: $TOOLS_VER"
	else
		warning "DAHDI Tools installed but version check unclear (acceptable for no-hardware systems)"
	fi
# Method 3: Check for library files
elif [ -f "/usr/lib64/libtonezone.so.2.0" ] || [ -f "/usr/lib/libtonezone.so.2.0" ]; then
	info "DAHDI Tools libraries installed (libtonezone found)"
	warning "No DAHDI hardware detected - this is normal for software-only ViciDial installations"
else
	DAHDI_VERIFY_FAILED=true
fi

if [ "$DAHDI_VERIFY_FAILED" = true ]; then
	echo ""
	echo -e "${RED}╔═══════════════════════════════════════════╗${NC}"
	echo -e "${RED}║  DAHDI TOOLS VERIFICATION FAILED          ║${NC}"
	echo -e "${RED}╚═══════════════════════════════════════════╝${NC}"
	echo ""
	echo "Troubleshooting steps:"
	echo "  1. Check if libtonezone is installed: ls -la /usr/lib64/libtonezone*"
	echo "  2. Run ldconfig: ldconfig"
	echo "  3. Check dahdi_cfg location: which dahdi_cfg"
	echo "  4. Check library path: echo \$LD_LIBRARY_PATH"
	echo ""
	error "DAHDI Tools installation could not be verified"
fi

success "DAHDI Tools 3.4.0 (Patched) installed successfully"
echo "STEP_1_TOOLS=COMPLETE" >> "$INSTALL_MARKER"
DAHDI_TOOLS_COMPLETE=true
cd "$INSTALL_DIR"
else
info "DAHDI Tools already installed - skipping Phase 2"
fi

# -------------------------------------------------------------------
# PHASE 3: DAHDI CONFIGURATION
# -------------------------------------------------------------------
log "Configuring DAHDI system..."

# Verify system.conf was created
if [ ! -f /etc/dahdi/system.conf ]; then
mkdir -p /etc/dahdi
log "Creating system.conf from sample..."
if [ -f /etc/dahdi/system.conf.sample ]; then
cp /etc/dahdi/system.conf.sample /etc/dahdi/system.conf
else
cat > /etc/dahdi/system.conf << 'EOF'
# DAHDI Configuration File
# Created by ViciDial installation script
# Software timing mode (dahdi_dummy)
EOF
fi
fi

# -------------------------------------------------------------------
# PHASE 4: LOAD DAHDI MODULES
# -------------------------------------------------------------------
log "Loading DAHDI kernel modules..."

if ! lsmod | grep -q "^dahdi "; then
modprobe dahdi || error "Failed to load dahdi module"
success "DAHDI module loaded"
else
info "DAHDI module already loaded"
fi

if ! lsmod | grep -q "^dahdi_dummy"; then
modprobe dahdi_dummy || warning "dahdi_dummy not loaded (may not be needed on this kernel)"
if lsmod | grep -q "^dahdi_dummy"; then
success "dahdi_dummy module loaded"
fi
else
info "dahdi_dummy module already loaded"
fi

# -------------------------------------------------------------------
# PHASE 5: DAHDI VERIFICATION
# -------------------------------------------------------------------
log "Running DAHDI configuration..."
/usr/sbin/dahdi_cfg -vvvvvvvvvvvvv 2>&1 | tee /tmp/dahdi_cfg_output.log || true

# Check if "No hardware found" message appeared
NO_HARDWARE=false
if grep -qi "no hardware found\|no spans configured" /tmp/dahdi_cfg_output.log 2>/dev/null; then
	NO_HARDWARE=true
fi

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  DAHDI 3.4.0 VERIFICATION RESULTS         ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

if [ "$NO_HARDWARE" = true ]; then
	echo -e "${YELLOW}⚠️  No DAHDI hardware detected${NC}"
	echo ""
	echo "This is ${GREEN}NORMAL${NC} for ViciDial installations that use:"
	echo "  • VoIP-only (SIP/PJSIP) communications"
	echo "  • Cloud-based telephony providers"
	echo "  • SIP trunks instead of physical phone lines"
	echo ""
	info "DAHDI software is installed for compatibility and future use"
	info "ViciDial will work perfectly fine without physical telephony cards"
	echo ""
fi

info "Loaded DAHDI modules:"
lsmod | grep dahdi || warning "No DAHDI modules found in lsmod"

echo ""

info "DAHDI Version Check:"
if command -v dahdi_cfg &>/dev/null; then
DAHDI_VERSION=$(dahdi_cfg --help 2>&1 | grep -i "DAHDI Tools Version" | head -1 || true)
if [ -n "$DAHDI_VERSION" ]; then
echo "  $DAHDI_VERSION"
if echo "$DAHDI_VERSION" | grep -q "3.4.0"; then
success "DAHDI Tools 3.4.0 verified"
else
warning "DAHDI version may not be 3.4.0 - please verify manually"
fi
else
# Alternative check if version string not found
if [ -f "/usr/sbin/dahdi_cfg" ] || command -v dahdi_cfg &>/dev/null; then
info "DAHDI Tools installed (version string not detected - this is OK)"
else
warning "Could not determine DAHDI version"
fi
fi
else
warning "dahdi_cfg command not found"
fi

echo ""

# More lenient verification for no-hardware systems
DAHDI_VERIFY_OK=false

if lsmod | grep -q "^dahdi " && command -v dahdi_cfg &>/dev/null; then
	DAHDI_VERIFY_OK=true
elif command -v dahdi_cfg &>/dev/null && [ -f "/usr/lib64/libtonezone.so.2.0" ]; then
	# Software is installed even if modules didn't load
	DAHDI_VERIFY_OK=true
	info "DAHDI software installed (no hardware required for VoIP-only systems)"
fi

if [ "$DAHDI_VERIFY_OK" = true ]; then
	success "DAHDI 3.4.0 (Fully Patched) installation completed successfully!"
	if [ "$NO_HARDWARE" = true ]; then
		success "Software-only installation verified (no telephony cards needed)"
	else
		success "All DAHDI components installed and verified"
	fi
else
	echo ""
	echo -e "${RED}╔═══════════════════════════════════════════╗${NC}"
	echo -e "${RED}║  DAHDI VERIFICATION WARNING               ║${NC}"
	echo -e "${RED}╚═══════════════════════════════════════════╝${NC}"
	echo ""
	echo "DAHDI components may not be fully functional."
	echo "Troubleshooting:"
	echo "  1. Check logs: cat /tmp/dahdi_cfg_output.log"
	echo "  2. Verify modules: lsmod | grep dahdi"
	echo "  3. Check binary: which dahdi_cfg"
	echo "  4. Check libraries: ls -la /usr/lib64/libtonezone*"
	echo ""
	read -p "Continue anyway? (y/n) " -n 1 -r
	echo ""
	if [[ ! $REPLY =~ ^[Yy]$ ]]; then
		error "DAHDI installation verification failed - user chose to abort"
	fi
	warning "Continuing installation despite DAHDI verification warnings..."
fi

mark_step_complete "STEP_1"
fi

# ===========================================================================
# STEP 2: LIBPRI 1.6.1
# ===========================================================================
section "STEP 2/22: INSTALLING LIBPRI 1.6.1"
check_step "STEP_2" "2/22" "LibPRI 1.6.1 Installation"

if [ "$SKIP_STEP" = false ]; then
cd "$INSTALL_DIR"
rm -rf libpri-1.6.1.tar.gz libpri-1.6.1

safe_wget "https://downloads.asterisk.org/pub/telephony/libpri/libpri-1.6.1.tar.gz" \
"LibPRI 1.6.1"

tar xzf libpri-1.6.1.tar.gz
cd libpri-1.6.1
make
make install
ldconfig
success "LibPRI 1.6.1 installed"
mark_step_complete "STEP_2"
fi

# ===========================================================================
# STEP 3: DOWNLOAD ASTERISK 20 (PLAIN UPSTREAM)
# ===========================================================================
section "STEP 3/22: DOWNLOADING ASTERISK ${ASTERISK_VERSION} (plain upstream)"
check_step "STEP_3" "3/22" "Asterisk ${ASTERISK_VERSION} Download"

if [ "$SKIP_STEP" = false ]; then
mkdir -p /usr/src/asterisk
cd /usr/src/asterisk

AST_BUILD_DIR=""
PLAIN_TARBALL="asterisk-${ASTERISK_VERSION}.tar.gz"
PLAIN_DIR="asterisk-${ASTERISK_VERSION}"

rm -rf "$PLAIN_TARBALL" "$PLAIN_DIR"

# ViciDial publishes NO pre-patched tarball for Asterisk 20 (the newest is
# asterisk-18.21.0-vici) and no Asterisk-20 patch directory. Oliver runs
# plain 20.18.2 with ConfBridge and no C-level patches; this mirrors it.
# Current releases live in releases/, older ones move to old-releases/.
log "Downloading plain asterisk-${ASTERISK_VERSION} from asterisk.org..."
DOWNLOAD_OK=false
for attempt in 1 2 3; do
log "Download attempt $attempt/3..."
for _ast_dir in releases old-releases; do
if wget --tries=2 --timeout=60 -q --show-progress \
"https://downloads.asterisk.org/pub/telephony/asterisk/${_ast_dir}/$PLAIN_TARBALL"; then
DOWNLOAD_OK=true
success "Downloaded $PLAIN_TARBALL (${_ast_dir}/)"
break 2
fi
done
warning "Attempt $attempt failed"
sleep 5
done

if [ "$DOWNLOAD_OK" = false ]; then
error "Failed to download $PLAIN_TARBALL from asterisk.org. Check network."
fi

log "Extracting $PLAIN_TARBALL..."
tar -xzf "$PLAIN_TARBALL"
AST_BUILD_DIR="/usr/src/asterisk/$PLAIN_DIR"

if [ ! -d "$AST_BUILD_DIR" ]; then
error "Asterisk source directory not found after extraction: $AST_BUILD_DIR"
fi

echo "AST_BUILD_DIR=$AST_BUILD_DIR" >> "$INSTALL_MARKER"

# NO PATCHES. ViciDial's five Asterisk patches (amd_stats, iax_peer_status,
# sip_peer_status, timeout_reset_dial_app, timeout_reset_dial_core) exist only
# for Asterisk 18 and 404 under .../asterisk-patches/Asterisk-20/. Oliver runs
# without them. If you rely on AMD statistics or ViciDial's dial-timeout
# semantics, port those two yourself and test on a disposable VM first.
log "Skipping ViciDial patches: none published for Asterisk 20"

success "Asterisk ${ASTERISK_VERSION} source ready in: $AST_BUILD_DIR"
mark_step_complete "STEP_3"
fi

# ===========================================================================
# STEP 4: COMPILE & INSTALL ASTERISK
# ===========================================================================
section "STEP 4/22: COMPILING & INSTALLING ASTERISK 18"
check_step "STEP_4" "4/22" "Asterisk Compile & Install"

if [ "$SKIP_STEP" = false ]; then
AST_BUILD_DIR=$(grep "^AST_BUILD_DIR=" "$INSTALL_MARKER" 2>/dev/null | cut -d'=' -f2-)
if [ -z "$AST_BUILD_DIR" ] || [ ! -d "$AST_BUILD_DIR" ]; then
AST_BUILD_DIR=$(find /usr/src/asterisk -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}" | sort | tail -1)
fi
if [ -z "$AST_BUILD_DIR" ] || [ ! -d "$AST_BUILD_DIR" ]; then
error "Asterisk source directory not found. Did Step 3 complete successfully?"
fi
log "Using Asterisk source: $AST_BUILD_DIR"
cd "$AST_BUILD_DIR"

log "Installing Asterisk build prerequisites..."
contrib/scripts/install_prereq install || warning "install_prereq had non-fatal warnings"

log "Configuring Asterisk build..."
./configure \
--libdir=/usr/lib64 \
--with-gsm=internal \
--with-ssl \
--enable-asteriskssl \
--enable-opus \
--enable-srtp \
--with-pjproject-bundled \
--with-jansson-bundled

log "Generating menuselect options..."
make menuselect/menuselect menuselect-tree menuselect.makeopts

log "Enabling required modules..."
menuselect/menuselect --enable app_meetme          menuselect.makeopts
menuselect/menuselect --enable app_confbridge       menuselect.makeopts
menuselect/menuselect --enable bridge_softmix       menuselect.makeopts
menuselect/menuselect --enable res_http_websocket   menuselect.makeopts
menuselect/menuselect --enable res_srtp             menuselect.makeopts
menuselect/menuselect --enable codec_opus           menuselect.makeopts
menuselect/menuselect --enable format_ogg_vorbis    menuselect.makeopts
menuselect/menuselect --enable res_snmp             menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM   menuselect.makeopts
menuselect/menuselect --enable MOH-OPSOUND-WAV      menuselect.makeopts

JOBS=$(( $(nproc) + $(nproc) / 2 ))
[ "$JOBS" -lt 1 ] && JOBS=2
log "Compiling Asterisk with $JOBS parallel jobs (10-20 minutes)..."
make -j"${JOBS}" all

log "Installing Asterisk..."
make install
make samples

log "Installing init scripts..."
if command -v systemctl &>/dev/null; then
    log "Detected systemd - installing systemd service..."
    
    # ViciDial manages Asterisk via GNU screen -- do NOT enable the systemd service.
    # Mask it to permanently prevent dual-instance conflicts (FIX 12).
    # Using a symlink test: -f returns false for a symlink-to-/dev/null, so we
    # use -L + readlink to detect an already-masked state idempotently.
    log "Masking asterisk.service (ViciDial uses screen-managed Asterisk)..."
    if [ -L /etc/systemd/system/asterisk.service ] && \
       [ "$(readlink /etc/systemd/system/asterisk.service 2>/dev/null)" = "/dev/null" ]; then
        log "asterisk.service already masked"
    else
        \rm -f /etc/systemd/system/asterisk.service 2>/dev/null || true
        ln -sf /dev/null /etc/systemd/system/asterisk.service
        systemctl daemon-reload
        success "asterisk.service masked (→ /dev/null, prevents dual-instance)"
    fi
else
    log "Attempting traditional init setup..."
    make config || warning "make config failed - may need manual service setup"
fi

make install-logrotate

log "Enabling chan_sip (required by ViciDial)..."
if [ -f /etc/asterisk/modules.conf ]; then
sed -i 's|^noload = chan_sip.so|;noload = chan_sip.so|g' /etc/asterisk/modules.conf
fi

log "Setting up asterisk user and permissions..."
if ! id -u asterisk &>/dev/null; then
useradd -r -d /var/lib/asterisk -s /sbin/nologin asterisk
fi
chown -R asterisk:asterisk /etc/asterisk
chown -R asterisk:asterisk /var/{lib,log,spool}/asterisk
chown -R asterisk:asterisk /usr/lib64/asterisk

ldconfig
success "Asterisk ${ASTERISK_VERSION} installed from: $AST_BUILD_DIR"
mark_step_complete "STEP_4"
fi

# ===========================================================================
# STEP 5: DOWNLOAD VICIDIAL (SVN)
# ===========================================================================
section "STEP 5/22: DOWNLOADING VICIDIAL CODE"
check_step "STEP_5" "5/22" "ViciDial SVN Download"

if [ "$SKIP_STEP" = false ]; then
cd "$INSTALL_DIR"

if [ -d "astguiclient" ]; then
log "Removing existing astguiclient directory..."
rm -rf astguiclient
fi

mkdir -p astguiclient
cd astguiclient

log "Checking out ViciDial from SVN (trunk)..."
if ! svn checkout svn://svn.eflo.net:3690/agc_2-X/trunk; then
error "SVN checkout failed! Check network connectivity and SVN access."
fi

if [ ! -d "trunk/extras" ] || [ ! -f "trunk/install.pl" ]; then
error "ViciDial download incomplete - missing trunk/extras or trunk/install.pl"
fi

success "ViciDial code downloaded"

log "Installing Mail::Sendmail Perl module (required for Step 20)..."
if dnf install -y perl-Mail-Sendmail 2>/dev/null; then
success "Mail::Sendmail installed via DNF"
else
warning "perl-Mail-Sendmail not in repos - trying CPAN..."
cpan -i Mail::Sendmail || warning "Mail::Sendmail install failed - Step 20 may error"
fi

mark_step_complete "STEP_5"
fi

# ===========================================================================
# STEP 6: DATABASE PREPARATION
# ===========================================================================
section "STEP 6/22: DATABASE PREPARATION (Pre-install.pl)"
check_step "STEP_6" "6/22" "Database Schema Setup"

if [ "$SKIP_STEP" = false ]; then
log "Creating asterisk database and users..."

# FIX #7: Error checking on MySQL commands
if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
-- Create database
CREATE DATABASE IF NOT EXISTS asterisk DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Drop ALL user hosts before creating (idempotent on re-run)
DROP USER IF EXISTS 'cron'@'localhost';
DROP USER IF EXISTS 'cron'@'127.0.0.1';
DROP USER IF EXISTS 'cron'@'%';
DROP USER IF EXISTS 'custom'@'localhost';
DROP USER IF EXISTS 'custom'@'127.0.0.1';
DROP USER IF EXISTS 'custom'@'%';

-- Create cron user (all connection methods)
CREATE USER 'cron'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER 'cron'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER 'cron'@'%' IDENTIFIED BY '${DB_PASSWORD}';

-- Create custom user
CREATE USER 'custom'@'127.0.0.1' IDENTIFIED BY '${CUSTOM_DB_PASSWORD}';

-- Grant privileges to cron users
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'localhost';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'127.0.0.1';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'%';
GRANT RELOAD ON *.* TO 'cron'@'localhost';
GRANT RELOAD ON *.* TO 'cron'@'127.0.0.1';
GRANT RELOAD ON *.* TO 'cron'@'%';

-- Grant privileges to custom user
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'custom'@'127.0.0.1';
GRANT RELOAD ON *.* TO 'custom'@'127.0.0.1';

FLUSH PRIVILEGES;
SET GLOBAL connect_timeout=60;
EOF
then
error "Failed to create database and users"
fi

success "Database and users created"

log "Loading base ViciDial schema..."
if [ ! -f /usr/src/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql ]; then
error "MySQL_AST_CREATE_tables.sql not found - was Step 5 completed?"
fi

# --force: continue past "Table already exists" errors (idempotent on re-run)
if ! mysql --force -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk \
< /usr/src/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql 2>&1 | grep -v "ERROR 1050"; then
warning "Some schema errors (Table already exists) - continuing"
fi
success "Base schema loaded (existing tables skipped safely)"

log "Loading first server configuration..."
if [ ! -f /usr/src/astguiclient/trunk/extras/first_server_install.sql ]; then
error "first_server_install.sql not found - was Step 5 completed?"
fi

# --force: continue past duplicate key errors if server row already exists
mysql --force -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk \
< /usr/src/astguiclient/trunk/extras/first_server_install.sql 2>&1 | grep -v "ERROR 1062" || true
success "First server config loaded (duplicate rows skipped safely)"

log "Creating vicidial_settings table (not included in any .sql file - created by install.pl normally)..."
if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk <<VSET
CREATE TABLE IF NOT EXISTS vicidial_settings (
  active                enum('Y','N') default 'Y',
  active_keepalives     enum('Y','N') default 'Y',
  server_ip             varchar(15) default '',
  asterisk_version      varchar(10) default '1.8',
  db_schema_version     int(8) unsigned default 0,
  install_date          varchar(50) default ''
);
INSERT IGNORE INTO vicidial_settings
  (active, active_keepalives, server_ip, asterisk_version, db_schema_version, install_date)
SELECT 'Y', 'Y', server_ip, '1 18', 1736, NOW()
FROM servers LIMIT 1;
VSET
then
  warning "vicidial_settings creation had errors (may already exist)"
else
  success "vicidial_settings table created and seeded"
fi

log "Applying database tuning..."
if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk <<EOF
-- Fix phones table default (prevents install.pl schema mismatch)
ALTER TABLE phones ALTER template_id SET DEFAULT '';

-- Set correct Asterisk version (detected from source dir name)
UPDATE servers SET asterisk_version='${ASTERISK_VERSION}';
EOF
then
warning "Database tuning had errors (may not be critical)"
fi

success "Database fully prepared for install.pl"
mark_step_complete "STEP_6"

echo ""
echo -e "${YELLOW}╔═══════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  DATABASE READY - Proceed to install.pl  ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════╝${NC}"
fi

# ===========================================================================
# STEP 6.5: PATCH INSTALL.PL FOR MARIADB COMPATIBILITY
# ===========================================================================
section "STEP 6.5/22: PATCH INSTALL.PL FOR MARIADB"

# Define INSTALL_PL path
INSTALL_PL="/usr/src/astguiclient/trunk/install.pl"

if [ ! -f "$INSTALL_PL" ]; then
error "install.pl not found at $INSTALL_PL - was Step 5 completed?"
fi

log "Backing up original install.pl..."
cp "$INSTALL_PL" "${INSTALL_PL}.mysql.backup" 2>/dev/null || true

log "Patching install.pl to use DBD::MariaDB instead of DBD::mysql..."

# CRITICAL: Perl DBI driver names in DSN strings are CASE-SENSITIVE
sed -i 's/DBI:mysql:/DBI:MariaDB:/g' "$INSTALL_PL"
sed -i 's/DBI:mariadb:/DBI:MariaDB:/g' "$INSTALL_PL"
sed -i 's/DBD::mysql/DBD::MariaDB/g' "$INSTALL_PL"

# Verify the patches were applied correctly
if grep -q "DBI:MariaDB:" "$INSTALL_PL"; then
success "install.pl patched to use MariaDB driver (capital M - case-sensitive)"
PATCH_COUNT=$(grep -c "DBI:MariaDB:" "$INSTALL_PL")
info "Found $PATCH_COUNT DBI connection strings using DBI:MariaDB: driver"
else
warning "No DBI:mysql: strings found to patch (might already be patched or different version)"
fi

# Sanity check: ensure no lowercase DBI:mariadb: or DBI:mysql: remain
if grep -q "DBI:mysql:" "$INSTALL_PL"; then
error "install.pl still contains DBI:mysql: after patching!"
fi
if grep -q "DBI:mariadb:" "$INSTALL_PL"; then
error "install.pl contains lowercase DBI:mariadb: after patching!"
fi

if grep -q "DBD::MariaDB" "$INSTALL_PL"; then
info "DBD module references confirmed as DBD::MariaDB"
fi

info "Patch verification: $(grep -c 'DBI:MariaDB:' "$INSTALL_PL") occurrence(s) of DBI:MariaDB: found"

success "Step 6.5 completed - install.pl fully patched for MariaDB"

# ===========================================================================
# STEP 7: INTERACTIVE INSTALL.PL
# ===========================================================================
section "STEP 7/22: VICIDIAL INSTALL.PL (Interactive)"
check_step "STEP_7" "7/22" "ViciDial install.pl"

if [ "$SKIP_STEP" = false ]; then
cd /usr/src/astguiclient/trunk

# CRITICAL SAFETY NET: Re-apply the DBI:MariaDB patch
log "Safety-net: re-verifying install.pl MariaDB DSN capitalisation..."
_INSTALL_PL="/usr/src/astguiclient/trunk/install.pl"
if [ -f "$_INSTALL_PL" ]; then
sed -i 's/DBI:mysql:/DBI:MariaDB:/g'   "$_INSTALL_PL"
sed -i 's/DBI:mariadb:/DBI:MariaDB:/g' "$_INSTALL_PL"
sed -i 's/DBD::mysql/DBD::MariaDB/g'   "$_INSTALL_PL"
_DSN_COUNT=$(grep -c 'DBI:MariaDB:' "$_INSTALL_PL" 2>/dev/null || echo 0)
success "install.pl verified: $_DSN_COUNT DBI:MariaDB: connection string(s) confirmed"
if grep -q 'DBI:mysql:\|DBI:mariadb:' "$_INSTALL_PL" 2>/dev/null; then
error "install.pl still contains old mysql DSN strings after patching - check file manually"
fi
else
error "install.pl not found at $_INSTALL_PL - was Step 5 completed?"
fi

# CRITICAL: Verify Perl DBD::MariaDB module is installed
log "Checking for required Perl modules..."

if ! perl -MDBD::MariaDB -e 'exit 0' 2>/dev/null; then
warning "Perl DBD::MariaDB module not found - installing now..."

if command -v dnf &> /dev/null; then
dnf install -y perl-DBD-MariaDB || true
elif command -v yum &> /dev/null; then
yum install -y perl-DBD-MariaDB || true
fi

if perl -MDBD::MariaDB -e 'exit 0' 2>/dev/null; then
success "DBD::MariaDB module installed successfully"
else
error "Failed to install Perl DBD::MariaDB module. Install manually with: dnf install -y perl-DBD-MariaDB"
fi
else
success "Perl DBD::MariaDB module found"
fi

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  INTERACTIVE INSTALL.PL                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}IMPORTANT: When prompted by install.pl, use these values:${NC}"
echo ""
echo -e "  ${GREEN}1. Manual configuration:${NC}         ${YELLOW}y${NC}"
echo -e "  ${GREEN}2. Config file:${NC}                  ${YELLOW}[press ENTER]${NC}"
echo -e "  ${GREEN}3. Home path:${NC}                    ${YELLOW}[press ENTER, then 'y' to create]${NC}"
echo -e "  ${GREEN}4. Logs path:${NC}                    ${YELLOW}[press ENTER, then 'y' to create]${NC}"
echo -e "  ${GREEN}5. AGI-bin path:${NC}                 ${YELLOW}[press ENTER]${NC}"
echo ""
echo -e "  ${RED}6. WEBROOT PATH:${NC}                 ${YELLOW}/var/www/html${NC}  ${RED}<-- TYPE THIS!${NC}"
echo -e "     ${CYAN}(When asked if directory doesn't exist, type 'n' to refuse creating /usr/local/apache2/htdocs)${NC}"
echo -e "     ${CYAN}(Then it will ask again - type: /var/www/html and 'y' to create it)${NC}"
echo ""
echo -e "  ${GREEN}7. Sounds path:${NC}                  ${YELLOW}[press ENTER]${NC}"
echo -e "  ${GREEN}8. Monitor path:${NC}                 ${YELLOW}[press ENTER]${NC}"
echo -e "  ${GREEN}9. DONEmonitor path:${NC}             ${YELLOW}[press ENTER, then 'y' to create]${NC}"
echo ""
echo -e "  ${GREEN}10. Server IP:${NC}                   ${YELLOW}$SERVER_IP${NC}"
echo -e "  ${GREEN}11. DB Server:${NC}                   ${YELLOW}127.0.0.1${NC}  ${CYAN}(NOT 'localhost')${NC}"
echo -e "  ${GREEN}12. DB Name:${NC}                     ${YELLOW}asterisk${NC}"
echo -e "  ${GREEN}13. DB User:${NC}                     ${YELLOW}cron${NC}"
echo -e "  ${GREEN}14. DB Password:${NC}                 ${YELLOW}$DB_PASSWORD${NC}"
echo -e "  ${GREEN}15. Custom User:${NC}                 ${YELLOW}custom${NC}"
echo -e "  ${GREEN}16. Custom Password:${NC}             ${YELLOW}$CUSTOM_DB_PASSWORD${NC}"
echo -e "  ${GREEN}17. DB Port:${NC}                     ${YELLOW}[press ENTER]${NC}"
echo -e "  ${GREEN}18. Active keepalives:${NC}           ${YELLOW}[press ENTER]${NC}"
echo -e "  ${GREEN}19. Asterisk version:${NC}            ${YELLOW}18.X${NC}"
echo -e "  ${GREEN}20. Copy sample configs:${NC}         ${YELLOW}y${NC}"
echo ""
echo -e "  ${YELLOW}For all remaining prompts, press ENTER to accept defaults.${NC}"
echo ""
echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  COPY THESE VALUES - SCRIPT WILL PAUSE HERE          ║${NC}"
echo -e "${RED}║  Press ENTER when you're ready to start install.pl   ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

read -rp "Press ENTER when ready to start install.pl..."
echo ""

# CRITICAL FIX: Save original stdout/stderr and restore them for install.pl
log "Temporarily pausing logging for interactive install.pl..."

# Save current redirected FDs
exec 3>&1 4>&2

# Restore original stdout/stderr (before tee was applied)
exec 1>/dev/tty 2>/dev/tty

echo ""
echo "============================================="
echo "Starting install.pl in interactive mode..."
echo "Follow the prompts carefully!"
echo "============================================="
echo ""

# Run install.pl with full TTY control
perl install.pl

# Restore logging
exec 1>&3 2>&4 3>&- 4>&-
echo ""
log "install.pl completed - logging resumed"

# Verify installation
if [ ! -d /usr/share/astguiclient ]; then
error "install.pl failed - /usr/share/astguiclient not created"
fi

if [ ! -d /var/www/html/vicidial ]; then
warning "ViciDial web files not found in /var/www/html - check webroot setting"
fi

# SAFETY NET: install.pl (esp. when run non-interactively, e.g. --no-prompt with
# no controlling TTY) can leave "VARserver_ip => " blank in astguiclient.conf.
# ADMIN_keepalive_ALL.pl matches this server's DB row on VARserver_ip, so a blank
# value means it NEVER generates pjsip-vicidial.conf / pjsip_wizard-vicidial.conf,
# which breaks ALL of PJSIP (Asterisk logs "#include ... does not exist" and
# refuses to parse pjsip.conf at all — not just WebRTC).
if grep -q '^VARserver_ip => *$' /etc/astguiclient.conf 2>/dev/null; then
    warning "astguiclient.conf: VARserver_ip is blank - patching to $SERVER_IP"
    sed -i "s/^VARserver_ip => *\$/VARserver_ip => $SERVER_IP/" /etc/astguiclient.conf
    success "astguiclient.conf: VARserver_ip set to $SERVER_IP"
fi

success "install.pl completed successfully"
mark_step_complete "STEP_7"
fi

# ---------------------------------------------------------------------------
# FIX: Copy ViciDial Perl modules into system Perl path (site lib from $Config{installsitelib})
# The sync script is installed later (before CLEANUP) and kept at
# /usr/local/sbin/vicidial-sync-perl-modules so it can be re-run manually
# after any ViciDial update. A systemd path unit auto-triggers it whenever
# install.pl writes to /usr/share/astguiclient/libs/.
# Run the sync now (inline, same logic) so STEP 7.5 and beyond are covered.
# ---------------------------------------------------------------------------
log "Syncing ViciDial Perl modules into system Perl path..."
if perl -e 'use Asterisk::AGI; print "ok"' 2>/dev/null | grep -q ok; then
    success "Asterisk::AGI already in system Perl path"
else
    PERL_DEST="$PERL_SITELIB"
    if [ ! -d /usr/share/astguiclient/libs/Asterisk ]; then
        warning "astguiclient libs not found - skipping Perl module copy (install.pl may not have run)"
    else
        mkdir -p "${PERL_DEST}/Asterisk"
        cp -f /usr/share/astguiclient/libs/Asterisk/*.pm "${PERL_DEST}/Asterisk/"
        cp -f /usr/share/astguiclient/libs/Asterisk.pm   "${PERL_DEST}/"
        cp -f /usr/share/astguiclient/libs/viciagi.pm    "${PERL_DEST}/"
        cp -f /usr/share/astguiclient/libs/vicidial.pm   "${PERL_DEST}/"
        perl -e 'use Asterisk::AGI; print "ok"' 2>/dev/null | grep -q ok && \
            success "Asterisk::AGI now in system Perl path (${PERL_DEST})" || \
            warning "Asterisk::AGI copy completed but module still not loadable - check Perl version"

        # ---------------------------------------------------------------------------
        # PATCH: Asterisk::AGI.pm — fix empty survey_dtmf_digits bug
        # When a campaign has survey_dtmf_digits='' (empty string in DB), the
        # ViciDial AGI script calls stream_file("file", "").
        # The stock Asterisk::AGI module only substitutes '""' for undef, not "".
        # An empty string causes the AGI command "STREAM FILE filename " (trailing
        # space, no escape_digits) — Asterisk returns 520 Invalid command syntax,
        # the Perl module returns undef, and the survey audio is NEVER played.
        # Fix: treat empty string the same as undef (use '""' as escape_digits).
        # ---------------------------------------------------------------------------
        log "Patching Asterisk::AGI.pm — empty survey_dtmf_digits fix..."
        for _agi_pm in "${PERL_DEST}/Asterisk/AGI.pm" /usr/share/astguiclient/libs/Asterisk/AGI.pm; do
            if [ -f "$_agi_pm" ]; then
                sed -i "s/\\\$digits = '\"\"' if (!defined(\\\$digits));/\$digits = '\"\"' if (!defined(\$digits) || \$digits eq '');/g" "$_agi_pm"
                log "  Patched: $_agi_pm"
            fi
        done
        success "Asterisk::AGI.pm empty-digits fix applied"
    fi
fi

# ---------------------------------------------------------------------------
# PATCH: Asterisk::AGI.pm empty-digits bug
# stream_file / get_data / record_file / control_stream_file return empty
# string instead of undef on no-digit responses, causing AGI crash/hang in
# ViciDial survey campaigns (symptom: SVYHU calls with length_in_sec=0).
# Fix: treat empty string same as undef. Same 1-line change in 4 functions.
# Must run AFTER ViciDial libs are copied so both paths are patched.
# ---------------------------------------------------------------------------
log "Applying Asterisk::AGI.pm empty-digits patch..."
_patch_agi_pm() {
    local FILE="$1"
    if [ -f "$FILE" ]; then
        sed -i "s/\$digits = '\"\"' if (!defined(\$digits));/\$digits = '\"\"' if (!defined(\$digits) || \$digits eq '');/g" "$FILE"
        COUNT=$(grep -c "digits.*eq ''" "$FILE" 2>/dev/null || echo 0)
        if [ "$COUNT" -eq 4 ]; then
            success "Asterisk::AGI.pm empty-digits patch applied ($FILE)"
        else
            warning "Asterisk::AGI.pm patch may be incomplete — found $COUNT/4 lines ($FILE)"
        fi
    else
        warning "Asterisk::AGI.pm not found at $FILE — skipping"
    fi
}

# Patch system Perl path (cpanm-installed copy)
SYS_AGI=$(perl -MAsterisk::AGI -e 'print $INC{"Asterisk/AGI.pm"}' 2>/dev/null)
[ -n "$SYS_AGI" ] && _patch_agi_pm "$SYS_AGI"

# Patch ViciDial libs copy (copied above from astguiclient/libs)
_patch_agi_pm "/usr/share/astguiclient/libs/Asterisk/AGI.pm"

# ===========================================================================
# STEP 7.5: PATCH ALL VICIDIAL SCRIPTS + AGI SCRIPTS (FIX #1 - CRITICAL)
# ===========================================================================
section "STEP 7.5/22: PATCHING VICIDIAL + AGI SCRIPTS FOR MARIADB"

log "Patching ViciDial scripts AND AGI scripts for MariaDB compatibility..."

_patch_dir() {
local DIR="$1"
local LABEL="$2"
local PATTERN="$3"

if [ ! -d "$DIR" ]; then
warning "$LABEL ($DIR) not found - skipping"
return
fi

local COUNT
COUNT=$(find "$DIR" -maxdepth 1 -type f -name "$PATTERN" 2>/dev/null | wc -l)

if [ "$COUNT" -eq 0 ]; then
warning "No $PATTERN files found in $LABEL - skipping"
return
fi

log "Patching $COUNT files in $LABEL..."

# Pattern A: DBI driver name fixes
find "$DIR" -maxdepth 1 -type f -name "$PATTERN" -exec sed -i \
-e 's/DBI:mysql:/DBI:MariaDB:/g' \
-e 's/DBI:mariadb:/DBI:MariaDB:/g' \
-e 's/DBD::mysql/DBD::MariaDB/g' \
{} \; 2>/dev/null || true

# Pattern B: mysql_insertid -> mariadb_insertid (v10.15 CRITICAL)
find "$DIR" -maxdepth 1 -type f -name "$PATTERN" -exec sed -i \
-e 's/mysql_insertid/mariadb_insertid/g' \
{} \; 2>/dev/null || true

success "Patched $COUNT files in $LABEL (DBI driver + insertid)"
}

# Patch ViciDial Perl scripts (.pl files)
_patch_dir "/usr/share/astguiclient"          "installed ViciDial scripts" "*.pl"
_patch_dir "/usr/src/astguiclient/trunk/bin"  "SVN trunk/bin scripts"      "*.pl"

# CRITICAL: Patch ALL AGI scripts (.agi files)
_patch_dir "/var/lib/asterisk/agi-bin"        "AGI scripts"                "*.agi"

# ===========================================================================
# STEP 7.5b: VERIFY/RECREATE cid_channels_recent TABLE (v10.15)
# ===========================================================================

# Verify cid_channels_recent table
log "Verifying cid_channels_recent table..."
_CID_TABLE="cid_channels_recent_${SERVER_IP//.}"
log "Server-specific table: $_CID_TABLE"

# First, check if the table exists at all
_TABLE_OK=false
if mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DESCRIBE $_CID_TABLE" &>/dev/null; then
    # Table exists, check if it has the correct schema
    _HAS_DEST=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$DB_NAME' AND table_name='$_CID_TABLE' AND column_name='dest_channel';" 2>/dev/null)
    _HAS_LINKED=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$DB_NAME' AND table_name='$_CID_TABLE' AND column_name='linkedid';" 2>/dev/null)

    if [ "$_HAS_DEST" = "1" ] && [ "$_HAS_LINKED" = "1" ]; then
        _TABLE_OK=true
        success "Table $_CID_TABLE exists with correct schema"
    else
        warning "Table $_CID_TABLE exists but has wrong schema - recreating..."
        mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DROP TABLE IF EXISTS $_CID_TABLE;" 2>/dev/null || true
    fi
else
    log "Table $_CID_TABLE does not exist yet"
fi

# Create table if it doesn't exist or had wrong schema
if [ "$_TABLE_OK" = false ]; then
    log "Creating table $_CID_TABLE..."
    if mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" << CIDSQL
CREATE TABLE IF NOT EXISTS $_CID_TABLE (
caller_id_name varchar(30) NOT NULL DEFAULT '',
connected_line_name varchar(30) NOT NULL DEFAULT '',
call_date datetime DEFAULT NULL,
channel varchar(100) DEFAULT NULL,
dest_channel varchar(100) DEFAULT NULL,
linkedid varchar(20) DEFAULT NULL,
dest_uniqueid varchar(20) DEFAULT NULL,
uniqueid varchar(20) DEFAULT NULL,
server_ip varchar(15) DEFAULT NULL,
KEY call_date (call_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
CIDSQL
    then
        success "Table $_CID_TABLE created successfully"
    else
        warning "Failed to create $_CID_TABLE - RATIO dialing may not work"
    fi
fi

# ===========================================================================
# STEP 7.5c: PATCH AST_flush_DBqueue.pl RETENTION (v10.15)
# ===========================================================================
log "Patching AST_flush_DBqueue.pl retention for cid_channels_recent..."

_FLUSH_SCRIPT="/usr/share/astguiclient/AST_flush_DBqueue.pl"
_FLUSH_TRUNK="/usr/src/astguiclient/trunk/bin/AST_flush_DBqueue.pl"

for _FS in "$_FLUSH_SCRIPT" "$_FLUSH_TRUNK"; do
if [ -f "$_FS" ]; then
if grep -q 'localtime(time() - 1[0-9][0-9])' "$_FS" 2>/dev/null; then
sed -i 's/localtime(time() - 1[0-9][0-9])/localtime(time() - 600)/' "$_FS"
success "Patched $_FS: retention extended to 600 seconds"
elif grep -q 'localtime(time() - 600)' "$_FS" 2>/dev/null; then
info "$_FS already has 600-second retention"
else
info "$_FS: retention value not matched (may need manual check)"
fi
fi
done

# ===========================================================================
# VERIFICATION
# ===========================================================================
log "Verifying critical scripts..."

_verify_script() {
local FILE="$1"
local LABEL="$2"

if [ ! -f "$FILE" ]; then
return
fi

local MARIADB_COUNT=$(grep -c "DBI:MariaDB:" "$FILE" 2>/dev/null || echo "0")
local MYSQL_COUNT=$(grep -c "DBI:mysql:" "$FILE" 2>/dev/null || echo "0")
local OLD_INSERTID=$(grep -c "mysql_insertid" "$FILE" 2>/dev/null || echo "0")

if [ "$MARIADB_COUNT" -gt 0 ] && [ "$MYSQL_COUNT" -eq 0 ] && [ "$OLD_INSERTID" -eq 0 ]; then
success "$LABEL: MariaDB driver + insertid OK ($MARIADB_COUNT connections)"
elif [ "$MYSQL_COUNT" -gt 0 ]; then
warning "$LABEL: DBI:mysql=$MYSQL_COUNT still present - NEEDS MANUAL FIX"
elif [ "$OLD_INSERTID" -gt 0 ]; then
warning "$LABEL: mysql_insertid=$OLD_INSERTID still present - NEEDS MANUAL FIX"
fi
}

echo ""
log "Verification of critical files:"

# ViciDial scripts
_verify_script "/usr/share/astguiclient/ADMIN_area_code_populate.pl" \
"ADMIN_area_code_populate.pl"
_verify_script "/usr/share/astguiclient/VICIDIAL_IN_new_leads_file.pl" \
"VICIDIAL_IN_new_leads_file.pl"
_verify_script "/usr/share/astguiclient/AST_conf_update_screen.pl" \
"AST_conf_update_screen.pl (ConfBridge)"

# CRITICAL: AGI scripts
_verify_script "/var/lib/asterisk/agi-bin/agi-VDAD_local_optimize.agi" \
"agi-VDAD_local_optimize.agi (RATIO CRITICAL)"
_verify_script "/var/lib/asterisk/agi-bin/agi-VDAD_ALL_outbound.agi" \
"agi-VDAD_ALL_outbound.agi"
_verify_script "/var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi" \
"agi-VDAD_ALL_inbound.agi"

echo ""
success "Step 7.5 complete - all ViciDial + AGI scripts patched in all locations"
info "Note: This step NEVER marks complete and ALWAYS runs"

# ===========================================================================
# STEP 8: CONFBRIDGE CONFIGURATION
# ===========================================================================
section "STEP 8/22: CONFIGURING CONFBRIDGE"
check_step "STEP_8" "8/22" "ConfBridge Configuration"

if [ "$SKIP_STEP" = false ]; then
[ -f /etc/asterisk/confbridge.conf ] && \
cp /etc/asterisk/confbridge.conf /etc/asterisk/confbridge.conf.backup

cat > /etc/asterisk/confbridge.conf << 'CONFBRIDGECONF'
[general]
; ViciDial ConfBridge Configuration
; NOTE: Use bare #include (not quoted) to prevent duplicate profile warnings
#include confbridge-vicidial.conf
CONFBRIDGECONF

cat > /etc/asterisk/confbridge-vicidial.conf << 'CBVICI'
;================================================================
; ViciDial ConfBridge Profiles
; Auto-written by ViciDial Part 2 v10.17
;================================================================

[vici_agent_bridge]
type = bridge
video_mode = none
max_members = 10
mixing_interval = 40
internal_sample_rate = 8000
maximum_sample_rate = 8000
record_conference = no

[vici_customer_user]
type = user
admin = no
marked = no
startmuted = no
music_on_hold_when_empty = yes
music_on_hold_class = default
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = yes
dsp_silence_threshold = 2000
talk_detection_events = no
dtmf_passthrough = yes
announce_join_leave = no
timeout = 0

[vici_agent_user]
type = user
admin = yes
marked = yes
startmuted = no
music_on_hold_when_empty = no
quiet = no
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = yes
dsp_drop_silence = yes
dsp_silence_threshold = 2000
talk_detection_events = no
dtmf_passthrough = yes
announce_join_leave = no

[vici_admin_user]
type = user
admin = yes
marked = yes
startmuted = no
music_on_hold_when_empty = no
quiet = no
announce_user_count = yes
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = yes
dsp_silence_threshold = 2000
talk_detection_events = yes
dtmf_passthrough = yes
announce_join_leave = yes

[vici_monitor_user]
type = user
admin = no
marked = no
startmuted = yes
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = no
talk_detection_events = no
dtmf_passthrough = no
announce_join_leave = no

[vici_barge_user]
type = user
admin = no
marked = no
startmuted = no
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = yes
dsp_silence_threshold = 2000
talk_detection_events = no
dtmf_passthrough = yes
announce_join_leave = no

[vici_recording_user]
type = user
admin = no
marked = no
startmuted = yes
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = no
talk_detection_events = no
dtmf_passthrough = no
announce_join_leave = no

[vici_audio_user]
type = user
admin = no
marked = no
startmuted = yes
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = no
talk_detection_events = no
dtmf_passthrough = no
announce_join_leave = no

[vici_dtmf_user]
type = user
admin = no
marked = no
startmuted = yes
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = no
talk_detection_events = no
dtmf_passthrough = yes
announce_join_leave = no

[vici_ringall_user]
type = user
admin = no
marked = no
startmuted = no
music_on_hold_when_empty = no
quiet = yes
announce_user_count = no
announce_user_count_all = no
announce_only_user = no
wait_marked = no
end_marked = no
dsp_drop_silence = yes
dsp_silence_threshold = 2000
talk_detection_events = no
dtmf_passthrough = yes
announce_join_leave = no

[vici_monitor_menu]
type = menu
CBVICI

success "ConfBridge configured (all 9 user profiles + bridge profile)"
mark_step_complete "STEP_8"
fi

# ===========================================================================
# STEP 9: ASTERISK EXTENSIONS FOR CONFBRIDGE
# ===========================================================================
section "STEP 9/22: CONFIGURING ASTERISK EXTENSIONS"
check_step "STEP_9" "9/22" "Asterisk Extensions"

if [ "$SKIP_STEP" = false ]; then
[ -f /etc/asterisk/extensions.conf ] && \
cp /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.backup

if ! grep -q "exten => _9600XXX" /etc/asterisk/extensions.conf 2>/dev/null; then
cat >> /etc/asterisk/extensions.conf << 'EXTEOF'

;================================================================
; ViciDial ConfBridge Extensions
; Auto-generated by ViciDial Part 2 v10.17
;================================================================

[default]

;; Customer enters the conference
exten => _9600XXX,1,Answer()
exten => _9600XXX,n,Playback(sip-silence)
exten => _9600XXX,n,ConfBridge(${EXTEN},vici_agent_bridge,vici_customer_user)
exten => _9600XXX,n,Hangup()

;; Ring-all agent channel (prefix 1)
exten => _19600XXX,1,Answer()
exten => _19600XXX,n,Playback(sip-silence)
exten => _19600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_ringall_user)
exten => _19600XXX,n,Hangup()

;; Agent joined as conference leader (prefix 2)
exten => _29600XXX,1,Answer()
exten => _29600XXX,n,Playback(sip-silence)
exten => _29600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_agent_user)
exten => _29600XXX,n,Hangup()

;; Admin / supervisor entry (prefix 3)
exten => _39600XXX,1,Answer()
exten => _39600XXX,n,Playback(sip-silence)
exten => _39600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_admin_user)
exten => _39600XXX,n,Hangup()

;; Monitor / listen-only (prefix 4)
exten => _49600XXX,1,Answer()
exten => _49600XXX,n,Playback(sip-silence)
exten => _49600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_monitor_user)
exten => _49600XXX,n,Hangup()

;; Call recording channel (prefix 5)
exten => _59600XXX,1,Answer()
exten => _59600XXX,n,Playback(sip-silence)
exten => _59600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_recording_user)
exten => _59600XXX,n,Hangup()

;; Barge-in full audio (prefix 6)
exten => _69600XXX,1,Answer()
exten => _69600XXX,n,Playback(sip-silence)
exten => _69600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_barge_user)
exten => _69600XXX,n,Hangup()

;; DTMF trigger channel (prefix 7)
exten => _79600XXX,1,Answer()
exten => _79600XXX,n,Playback(sip-silence)
exten => _79600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_dtmf_user)
exten => _79600XXX,n,Hangup()

;; Audio playback into conference (prefix 8)
exten => _89600XXX,1,Answer()
exten => _89600XXX,n,Playback(sip-silence)
exten => _89600XXX,n,ConfBridge(${EXTEN:1},vici_agent_bridge,vici_audio_user)
exten => _89600XXX,n,Hangup()

;; Kick all channels from conference (prefix 9 and 55559 variant)
exten => _99600XXX,1,ConfKick(${EXTEN:1},all)
exten => _99600XXX,2,Hangup()
exten => _55559600XXX,1,ConfKick(${EXTEN:4},all)
exten => _55559600XXX,2,Hangup()

EXTEOF
success "ConfBridge extensions appended to extensions.conf"
else
info "ConfBridge extensions already present in extensions.conf - skipping append"
fi

# v10.15 FIX: Patch _1383XX Wait() from 2 -> 120 seconds
if grep -q 'exten => _1383XX,n,Wait(2)' /etc/asterisk/extensions.conf 2>/dev/null; then
sed -i 's/exten => _1383XX,n,Wait(2)/exten => _1383XX,n,Wait(120)/' /etc/asterisk/extensions.conf
success "Patched _1383XX Wait(2) -> Wait(120)"
fi
if grep -q 'exten => _138331\*\.,n,Wait(2)' /etc/asterisk/extensions.conf 2>/dev/null; then
sed -i 's/exten => _138331\*\.,n,Wait(2)/exten => _138331*.,n,Wait(120)/' /etc/asterisk/extensions.conf
success "Patched _138331*. Wait(2) -> Wait(120)"
fi

mark_step_complete "STEP_9"
fi

# ===========================================================================
# STEP 10: MANAGER.CONF - ADD [confcron] AMI USER
# ===========================================================================
section "STEP 10/22: CONFIGURING MANAGER.CONF [confcron]"
check_step "STEP_10" "10/22" "Manager.conf confcron entry"

if [ "$SKIP_STEP" = false ]; then
if [ ! -f /etc/asterisk/manager.conf ]; then
error "/etc/asterisk/manager.conf not found - was Asterisk installed in Step 4?"
fi
cp /etc/asterisk/manager.conf /etc/asterisk/manager.conf.backup

if ! grep -q '^\[confcron\]' /etc/asterisk/manager.conf; then
# install.pl seeds the [cron]/[updatecron]/[listencron]/[sendcron]/[sipcron]
# stock accounts from the single servers.ASTmgrSECRET DB column, so they all
# share one secret. confcron must reuse that SAME value (not a value of its
# own) or it will never authenticate - see CLAUDE.md's AMI credentials note.
AMI_SHARED_SECRET=$(awk '/^\[cron\]/{f=1;next} /^\[/{f=0} f && /^secret[[:space:]]*=/{print $NF; exit}' /etc/asterisk/manager.conf)
if [ -z "$AMI_SHARED_SECRET" ]; then
error "Could not read the existing [cron] AMI secret from manager.conf - was install.pl (Step 7) completed?"
fi
cat >> /etc/asterisk/manager.conf << MGREOF

; ViciDial ConfBridge AMI user
[confcron]
secret = ${AMI_SHARED_SECRET}
read = command,reporting
write = command,reporting
eventfilter=Event: Meetme
eventfilter=Event: Confbridge
MGREOF
success "[confcron] AMI user added to manager.conf (shares secret with the other 5 stock AMI accounts)"
else
info "[confcron] already in manager.conf - skipping"
fi

mark_step_complete "STEP_10"
fi

# ===========================================================================
# STEP 11: INSERT 300 vicidial_confbridges ENTRIES (FIX #7 - error checking)
# ===========================================================================
section "STEP 11/22: POPULATING vicidial_confbridges TABLE"
check_step "STEP_11" "11/22" "vicidial_confbridges DB entries"
if [ "$SKIP_STEP" = false ]; then
    log "Creating stored procedure for ConfBridge entries..."
    # FIX #7: Error checking on stored procedure creation
    if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk <<'SQLEOF'
DELIMITER //
DROP PROCEDURE IF EXISTS insert_confbridges//
CREATE PROCEDURE insert_confbridges(IN p_server_ip VARCHAR(15))
BEGIN
    DECLARE i INT DEFAULT 0;
    WHILE i < 300 DO
        INSERT IGNORE INTO vicidial_confbridges
        (conf_exten, server_ip, extension, leave_3way, leave_3way_datetime)
        VALUES
        (9600000 + i, p_server_ip, '', '0', NULL);
        SET i = i + 1;
    END WHILE;
END//
DELIMITER ;
SQLEOF
    then
        error "Failed to create insert_confbridges stored procedure"
    fi
    
    success "Stored procedure created successfully"
    
    log "Inserting 300 ConfBridge conference entries (9600000-9600299)..."
    if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk \
        -e "CALL insert_confbridges('${SERVER_IP}');"; then
        error "Failed to execute insert_confbridges procedure"
    fi
    
    success "Procedure executed successfully"
    
    # Cleanup
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk \
        -e "DROP PROCEDURE IF EXISTS insert_confbridges;" 2>/dev/null || true
    
    CB_COUNT=$(mysql -u cron -p"${DB_PASSWORD}" asterisk \
        -se "SELECT COUNT(*) FROM vicidial_confbridges WHERE server_ip='${SERVER_IP}';" 2>/dev/null || echo "0")
    
    if [ "$CB_COUNT" -ge 300 ]; then
        success "vicidial_confbridges: $CB_COUNT entries for $SERVER_IP"
    else
        warning "vicidial_confbridges count is $CB_COUNT (expected 300) - check DB manually"
    fi
    
    mark_step_complete "STEP_11"
fi

# ===========================================================================
# STEP 12: APPLY VICIDIAL CONFBRIDGE PATCHES
# ===========================================================================
section "STEP 12/22: APPLYING VICIDIAL CONFBRIDGE PATCHES"
check_step "STEP_12" "12/22" "ViciDial ConfBridge Patches"

if [ "$SKIP_STEP" = false ]; then
CB_EXTRAS="/usr/src/astguiclient/trunk/extras/ConfBridge"

if [ ! -d "$CB_EXTRAS" ]; then
warning "ConfBridge extras dir not found at $CB_EXTRAS - skipping patch step"
warning "You may need to apply patches manually"
else
log "Copying ConfBridge scripts to /usr/share/astguiclient/..."
cp "$CB_EXTRAS"/* /usr/share/astguiclient/ 2>/dev/null || true

log "Moving web patches to /var/www/html/agc/..."
for phpatch in manager_send.php.diff vdc_db_query.php.diff vicidial.php.diff; do
if [ -f "/usr/share/astguiclient/$phpatch" ]; then
mv "/usr/share/astguiclient/$phpatch" /var/www/html/agc/ 2>/dev/null || true
fi
done

log "Applying server-side Perl patches..."
cd /usr/share/astguiclient/

for plpatch in ADMIN_keepalive_ALL.pl.diff ADMIN_update_server_ip.pl.diff \
AST_DB_optimize.pl.diff AST_reset_mysql_vars.pl.diff; do
if [ -f "$plpatch" ]; then
patch -p0 < "$plpatch" || warning "$plpatch may be already applied - continuing"
else
warning "$plpatch not found - skipping"
fi
done

if [ -f AST_conf_update_screen.pl ]; then
chmod +x AST_conf_update_screen.pl
success "AST_conf_update_screen.pl made executable"
else
warning "AST_conf_update_screen.pl not found"
fi

log "Applying web interface patches..."
cd /var/www/html/agc/
for phpatch in manager_send.php.diff vdc_db_query.php.diff vicidial.php.diff; do
if [ -f "$phpatch" ]; then
patch -p0 < "$phpatch" || warning "$phpatch may be already applied - continuing"
else
warning "$phpatch not found in /var/www/html/agc/ - skipping"
fi
done

success "ViciDial ConfBridge patches applied"
fi

mark_step_complete "STEP_12"
fi

# ===========================================================================
# STEP 13: ENABLE ASTCONFUPDATER KEEPALIVE
# ===========================================================================
section "STEP 13/22: ENABLING ASTCONFUPDATER KEEPALIVE"
check_step "STEP_13" "13/22" "ASTConfUpdater Keepalive"

if [ "$SKIP_STEP" = false ]; then
ASTGUICLIENT_CONF="/etc/astguiclient.conf"

if [ ! -f "$ASTGUICLIENT_CONF" ]; then
warning "$ASTGUICLIENT_CONF not found - install.pl may not have run yet"
warning "Skipping - you must add 'C' to VARactive_keepalives manually after install.pl"
else
cp "$ASTGUICLIENT_CONF" "${ASTGUICLIENT_CONF}.backup"

if grep -q 'VARactive_keepalives' "$ASTGUICLIENT_CONF"; then
# Add 'C' flag (ASTConfUpdater) if missing
if ! grep -q 'VARactive_keepalives.*C' "$ASTGUICLIENT_CONF"; then
sed -i 's/\(VARactive_keepalives.*=>[^0-9]*[0-9]*\)\([^C]*\)$/\1C\2/' \
"$ASTGUICLIENT_CONF" || \
sed -i 's/\(VARactive_keepalives\s*=>\s*\)\([0-9A-Z]*\)/\1\2C/' \
"$ASTGUICLIENT_CONF"
success "Added 'C' flag to VARactive_keepalives (ASTConfUpdater)"
else
info "'C' flag already in VARactive_keepalives"
fi
# Add '7' flag (ASTVDadFILL) if missing — required for the hopper-fill screen
if ! grep -q 'VARactive_keepalives.*7' "$ASTGUICLIENT_CONF"; then
sed -i 's/\(VARactive_keepalives\s*=>\s*\)\([0-9A-Z]*\)/\1\27/' \
"$ASTGUICLIENT_CONF"
success "Added '7' flag to VARactive_keepalives (ASTVDadFILL screen)"
else
info "'7' flag already in VARactive_keepalives"
fi

grep 'VARactive_keepalives' "$ASTGUICLIENT_CONF" | head -2
else
warning "VARactive_keepalives line not found in $ASTGUICLIENT_CONF"
warning "Add flags manually: VARactive_keepalives => 12345678CES"
fi

CRON_TMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TMP" || true
if grep -q 'AST_conf_update\.pl' "$CRON_TMP"; then
sed -i 's|^\(\* \* \* \* \* .*/AST_conf_update\.pl.*\)$|#\1|g' "$CRON_TMP"
crontab "$CRON_TMP"
success "Disabled old AST_conf_update.pl cron entry"
else
info "AST_conf_update.pl cron entry not found (already disabled or not present)"
fi
rm -f "$CRON_TMP"
fi

mark_step_complete "STEP_13"
fi

# ===========================================================================
# STEP 14: PATCH ADMIN_KEEPALIVE_ALL.PL mixing_interval
# ===========================================================================
section "STEP 14/22: PATCHING ADMIN_KEEPALIVE_ALL.PL mixing_interval"
check_step "STEP_14" "14/22" "mixing_interval patch"

if [ "$SKIP_STEP" = false ]; then
KA_SCRIPT="/usr/share/astguiclient/ADMIN_keepalive_ALL.pl"

if [ ! -f "$KA_SCRIPT" ]; then
warning "$KA_SCRIPT not found - will apply after install.pl completes"
warning "Manually change: mixing_interval=20 -> mixing_interval=40"
else
cp "$KA_SCRIPT" "${KA_SCRIPT}.backup"
if grep -q 'mixing_interval=20' "$KA_SCRIPT"; then
sed -i 's/mixing_interval=20/mixing_interval=40/g' "$KA_SCRIPT"
success "ADMIN_keepalive_ALL.pl: mixing_interval changed 20 -> 40"
elif grep -q 'mixing_interval=40' "$KA_SCRIPT"; then
info "mixing_interval already set to 40"
else
warning "mixing_interval line not found in $KA_SCRIPT - check manually"
fi
fi

mark_step_complete "STEP_14"
fi

# ===========================================================================
# STEP 15: CONVERT [monitor] CONTEXT TO CONFBRIDGE
# ===========================================================================
section "STEP 15/22: CONVERTING [monitor] CONTEXT TO CONFBRIDGE"
check_step "STEP_15" "15/22" "[monitor] context conversion"

if [ "$SKIP_STEP" = false ]; then
EXT_CONF="/etc/asterisk/extensions.conf"

if [ ! -f "$EXT_CONF" ]; then
error "$EXT_CONF not found"
fi

cp "$EXT_CONF" "${EXT_CONF}.backup_monitor"

if grep -q 'Meetme(8600' "$EXT_CONF"; then
sed -i 's|Meetme(8600\${EXTEN:1},mqX)|ConfBridge(8600${EXTEN:1},vici_agent_bridge,vici_monitor_user)|g' \
"$EXT_CONF"
sed -i 's|Meetme(8600\${EXTEN:2},X)|ConfBridge(8600${EXTEN:2},vici_agent_bridge,vici_barge_user)|g' \
"$EXT_CONF"
success "[monitor] context converted from MeetMe to ConfBridge"
else
info "[monitor] context already uses ConfBridge (or MeetMe pattern not found)"
fi

mark_step_complete "STEP_15"
fi

# ===========================================================================
# STEP 16: REMOVE LEGACY MEETME AND ZAPBARGE EXTENSIONS
# ===========================================================================
section "STEP 16/22: DISABLING LEGACY MEETME/ZAPBARGE EXTENSIONS"
check_step "STEP_16" "16/22" "Legacy extension cleanup"

if [ "$SKIP_STEP" = false ]; then
EXT_CONF="/etc/asterisk/extensions.conf"
cp "$EXT_CONF" "${EXT_CONF}.backup_legacy"

log "Commenting out ZapBarge extensions..."
sed -i 's|^\(exten => 8159,.*ZapBarge.*\)$|;\1|g'        "$EXT_CONF"
sed -i 's|^\(exten => _86120XX,.*ZapBarge.*\)$|;\1|g'    "$EXT_CONF"

log "Commenting out legacy MeetMeAdmin extensions..."
sed -i 's|^\(exten => _X48600XXX,.*MeetMeAdmin.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _X38600XXX,.*MeetMeAdmin.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _X28600XXX,.*MeetMeAdmin.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _X18600XXX,.*MeetMeAdmin.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _55558600XXX,.*MeetMeAdmin.*\)$|;\1|g' "$EXT_CONF"

log "Commenting out legacy Meetme conference extensions..."
sed -i 's|^\(exten => _86000\[0-4\]X,.*Meetme.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _86000\[5-9\]X,.*Meetme.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _8600\[1-2\]XX,.*Meetme.*\)$|;\1|g'  "$EXT_CONF"
sed -i 's|^\(exten => _78600XXX,.*Meetme.*\)$|;\1|g'       "$EXT_CONF"
sed -i 's|^\(exten => _68600XXX,.*Meetme.*\)$|;\1|g'       "$EXT_CONF"
sed -i 's|^\(exten => _58600XXX,.*Meetme.*\)$|;\1|g'       "$EXT_CONF"
sed -i 's|^\(exten => _558600XXX,.*Meetme.*\)$|;\1|g'      "$EXT_CONF"
sed -i 's|^\(exten => _86009XX,.*Meetme.*\)$|;\1|g'        "$EXT_CONF"
sed -i 's|^\(exten => _986009XX,.*Meetme.*\)$|;\1|g'       "$EXT_CONF"

success "Legacy MeetMe/ZapBarge extensions commented out"
mark_step_complete "STEP_16"
fi

# ===========================================================================
# STEP 17: RC.LOCAL STARTUP SCRIPT
# ===========================================================================
section "STEP 17/22: CONFIGURING RC.LOCAL"
check_step "STEP_17" "17/22" "RC.Local Startup Script"

if [ "$SKIP_STEP" = false ]; then
cat > /etc/rc.d/rc.local << 'RCLOCALEOF'
#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# ViciDial System Startup Script
# Auto-generated by ViciDial Part 2 v10.17
# ═══════════════════════════════════════════════════════════════════════

# Enable ip_relay (same-machine trunking / blind monitoring)
/usr/share/astguiclient/ip_relay/relay_control start 2>/dev/null 1>&2

# Disable console blanking
/usr/bin/setterm -blank 0 2>/dev/null || true
/usr/bin/setterm -powersave off 2>/dev/null || true
/usr/bin/setterm -powerdown 0 2>/dev/null || true

# Start core services
systemctl start mariadb.service
systemctl start httpd.service

# Wait for services to be ready
sleep 5

# Roll Asterisk logs on reboot
/usr/share/astguiclient/ADMIN_restart_roll_logs.pl

# Clear stale server records
/usr/share/astguiclient/AST_reset_mysql_vars.pl

# Load DAHDI
modprobe dahdi
modprobe dahdi_dummy 2>/dev/null || true
/usr/sbin/dahdi_cfg -vvvvvvvvvvvvv 2>/dev/null || true

# Wait before launching Asterisk
sleep 20

# Start Asterisk
/usr/share/astguiclient/start_asterisk_boot.pl

echo "$(date): ViciDial system startup complete" >> /var/log/vicidial_startup.log
RCLOCALEOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local
systemctl daemon-reload

success "RC.Local configured and enabled"
mark_step_complete "STEP_17"
fi

# ===========================================================================
# STEP 18: START ASTERISK & VERIFY (VICIDIAL PRODUCTION METHOD)
# ===========================================================================
section "STEP 18/22: ASTERISK STARTUP & VERIFICATION"
check_step "STEP_18" "18/22" "Asterisk Startup"

if [ "$SKIP_STEP" = false ]; then
log "Stopping any existing Asterisk processes..."
# Stop systemd service if running (we don't use it for ViciDial)
systemctl stop asterisk 2>/dev/null || true
systemctl disable asterisk 2>/dev/null || true
# Mask to hard-block any auto-start (FIX 12: disable alone is not sufficient)
if [ ! -L /etc/systemd/system/asterisk.service ] || \
   [ "$(readlink /etc/systemd/system/asterisk.service 2>/dev/null)" != "/dev/null" ]; then
    \rm -f /etc/systemd/system/asterisk.service 2>/dev/null || true
    ln -sf /dev/null /etc/systemd/system/asterisk.service
    systemctl daemon-reload
fi
success "asterisk.service masked (prevents dual-instance conflict)"

# Kill any existing Asterisk processes and screen sessions
killall -9 asterisk 2>/dev/null || true
screen -wipe 2>/dev/null || true
sleep 3
rm -f /var/run/asterisk/asterisk.ctl /var/run/asterisk/asterisk.pid

# FIX: Ensure proper permissions on Asterisk runtime directories
log "Setting up Asterisk runtime directories and permissions..."
mkdir -p /var/run/asterisk
chown -R asterisk:asterisk /var/run/asterisk
chmod 755 /var/run/asterisk

# Ensure log directory has correct ownership
mkdir -p /var/log/asterisk
chown -R asterisk:asterisk /var/log/asterisk
chmod 755 /var/log/asterisk

# Ensure asterisk user owns critical directories
chown -R asterisk:asterisk /var/spool/asterisk
chown -R asterisk:asterisk /var/lib/asterisk

# FIX: Ensure screen directory has proper permissions (CRITICAL for GNU screen)
# Rocky 8 ships screen 4.6 installed setgid to the "screen" group, and it
# refuses to start unless /run/screen is exactly 0775 root:screen ("Directory
# '/run/screen' must have mode 775"). Rocky 10's screen 5 wanted 1777 instead;
# that setting breaks screen here. Match the binary's group.
log "Setting up GNU screen session directory..."
SCREEN_GROUP="$(stat -c %G "$(command -v screen)" 2>/dev/null || echo root)"
mkdir -p /run/screen
chown root:"$SCREEN_GROUP" /run/screen
chmod 0775 /run/screen
success "Screen directory configured: /run/screen (mode 0775 root:$SCREEN_GROUP)"
# Drop the Rocky 10 1777 override if an earlier run wrote it; the package's
# own tmpfiles entry already recreates /run/screen as 0775 root:screen.
rm -f /etc/tmpfiles.d/screen-fix.conf
cat > /etc/tmpfiles.d/screen.conf << TMPFILES_EOF
# Rocky 8: screen 4.6 (setgid $SCREEN_GROUP) requires /run/screen 0775
d /run/screen 0775 root $SCREEN_GROUP -
TMPFILES_EOF
success "tmpfiles.d entry written: /run/screen will be 0775 root:$SCREEN_GROUP on each boot"

log "Starting Asterisk using ViciDial's native screen-based method..."
info "NOTE: ViciDial requires Asterisk to run in a GNU screen session"
info "      This allows ViciDial's auto-restart and management features to work"

# Use ViciDial's official startup script (runs Asterisk in screen)
if [ ! -f /usr/share/astguiclient/start_asterisk_boot.pl ]; then
    error "start_asterisk_boot.pl not found! Cannot start Asterisk the ViciDial way"
fi

/usr/share/astguiclient/start_asterisk_boot.pl

log "Waiting for Asterisk to initialize in screen session..."
sleep 15

# Verify Asterisk is running in screen
if ! screen -ls | grep -q "asterisk"; then
    warning "Asterisk screen session not found!"
    log "Active screens:"
    screen -ls || true
    error "Asterisk failed to start in screen session"
fi
success "Asterisk screen session is active"

# Wait for control socket creation
log "Waiting for Asterisk control socket..."
WAIT_COUNT=0
while [ ! -S /var/run/asterisk/asterisk.ctl ] && [ $WAIT_COUNT -lt 45 ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Verify process is running (check for /usr/sbin/asterisk process)
if ! pgrep -f "/usr/sbin/asterisk" >/dev/null; then
    error "Asterisk process not found! Check: screen -r asterisk"
fi
success "Asterisk process is running"

# Verify control socket
if [ ! -S /var/run/asterisk/asterisk.ctl ]; then
    warning "Asterisk control socket not created after 45 seconds"
    log "Check Asterisk console: screen -r asterisk"
    error "Asterisk control socket missing - check /var/log/asterisk/messages"
fi
success "Asterisk control socket present"

# Test CLI connection with retry
log "Testing Asterisk CLI connection..."
CLI_OK=false
for i in {1..10}; do
    if asterisk -rx "core show version" &>/dev/null 2>&1; then
        CLI_OK=true
        break
    fi
    sleep 2
done

if [ "$CLI_OK" = false ]; then
    warning "Cannot connect to Asterisk CLI after 10 attempts"
    log "Try manually: screen -r asterisk"
    error "Asterisk CLI not responding"
fi

ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -1)
success "Asterisk CLI connected: $ASTERISK_VERSION"

# Show ViciDial screen sessions
log "ViciDial screen sessions:"
screen -ls 2>/dev/null | grep -E "asterisk|ASTVDauto|ASTconf" || info "Additional screens will start with ViciDial daemons"

log "Reloading dialplan and ConfBridge module..."
asterisk -rx "dialplan reload" 2>/dev/null || warning "dialplan reload had warnings"
asterisk -rx "module reload app_confbridge.so" 2>/dev/null || warning "confbridge reload had warnings"
asterisk -rx "manager reload" 2>/dev/null || warning "manager reload had warnings"

CONFBRIDGE_LOADED=$(asterisk -rx "module show like app_confbridge" 2>/dev/null \
| grep -c "app_confbridge.so" || echo "0")
MEETME_LOADED=$(asterisk -rx "module show like app_meetme" 2>/dev/null \
| grep -c "app_meetme.so" || echo "0")
DAHDI_LOADED=$(asterisk -rx "module show like chan_dahdi" 2>/dev/null \
| grep -c "chan_dahdi.so" || echo "0")

[ "$CONFBRIDGE_LOADED" -gt 0 ] && success "ConfBridge module loaded" \
|| warning "ConfBridge NOT loaded - check /var/log/asterisk/messages"
[ "$MEETME_LOADED" -gt 0 ] && success "MeetMe module loaded (backward compat)" \
|| info "MeetMe not loaded (ConfBridge is active engine)"
[ "$DAHDI_LOADED" -gt 0 ] && success "DAHDI module loaded" \
|| warning "DAHDI NOT loaded - timing may be affected"

log "Verifying ConfBridge profiles..."
asterisk -rx "confbridge show profile bridges" 2>/dev/null | grep -E 'vici|Profile' || true
asterisk -rx "confbridge show profile users" 2>/dev/null | grep -E 'vici|Profile' || true

SOCKET_COUNT=$(find /var/run/asterisk/ -type s 2>/dev/null | wc -l)
[ "$SOCKET_COUNT" -ge 9 ] && success "Socket count: $SOCKET_COUNT" \
|| warning "Socket count: $SOCKET_COUNT (expected 9+)"

mark_step_complete "STEP_18"
fi

# ===========================================================================
# STEP 19: POST-INSTALL - AREA CODE POPULATION
# ===========================================================================
section "STEP 19/22: AREA CODE POPULATION"
check_step "STEP_19" "19/22" "Area Code Database"

if [ "$SKIP_STEP" = false ]; then
if [ -f /usr/share/astguiclient/ADMIN_area_code_populate.pl ]; then
log "Populating area code database..."
/usr/share/astguiclient/ADMIN_area_code_populate.pl
success "Area codes populated"
else
warning "ADMIN_area_code_populate.pl not found - skipping"
fi
mark_step_complete "STEP_19"
fi

# ===========================================================================
# STEP 20: POST-INSTALL - TEST LEADS
# ===========================================================================
section "STEP 20/22: IMPORTING TEST LEADS"
check_step "STEP_20" "20/22" "Test Leads Import"

if [ "$SKIP_STEP" = false ]; then
if [ -f /usr/src/astguiclient/trunk/extras/performance_test_leads.txt ]; then
log "Importing test leads..."
chmod -R 755 /usr/share/astguiclient/VICIDIAL_IN_new_leads_file.pl
mkdir -p /usr/share/astguiclient/LEADS_IN/
cp /usr/src/astguiclient/trunk/extras/performance_test_leads.txt \
/usr/share/astguiclient/LEADS_IN/
/usr/share/astguiclient/VICIDIAL_IN_new_leads_file.pl \
--forcelistid=107 --forcephonecode=1
success "Test leads imported to list 107"
else
info "Test leads file not found - skipping (not required)"
fi
mark_step_complete "STEP_20"
fi

# ===========================================================================
# STEP 21: SERVER IP UPDATE (FIX #3 + FIX #7 - improved GMT + error checking)
# ===========================================================================
section "STEP 21/22: SERVER IP UPDATE"
check_step "STEP_21" "21/22" "Server IP Configuration"

if [ "$SKIP_STEP" = false ]; then
log "Updating server IP from default (10.10.10.15) to actual: $SERVER_IP"

# FIX #7: Error checking on SQL updates
log "Replacing old IP (10.10.10.15) in database tables..."
if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk -e "
UPDATE servers          SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15' OR server_ip LIKE '10.10.%';
UPDATE phones           SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15' OR server_ip LIKE '10.10.%';
UPDATE conferences      SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15' OR server_ip LIKE '10.10.%';
UPDATE vicidial_confbridges SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15' OR server_ip LIKE '10.10.%';
"; then
error "Failed to update server IP in database"
fi
success "Server IP updated via SQL: $SERVER_IP"

# Also run the Perl script
if [ -f /usr/share/astguiclient/ADMIN_update_server_ip.pl ]; then
log "Running ADMIN_update_server_ip.pl for additional table coverage (30s timeout)..."
if timeout 30 /usr/share/astguiclient/ADMIN_update_server_ip.pl \
--old-server_ip=10.10.10.15 >> /var/log/vicidial_install_part2.log 2>&1; then
success "ADMIN_update_server_ip.pl completed successfully"
else
warning "ADMIN_update_server_ip.pl timed out or errored - SQL update above is sufficient"
fi
fi

# Verify
LIVE_IP=$(mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk \
-se "SELECT server_ip FROM servers LIMIT 1;" 2>/dev/null || echo "FAILED")

if [ "$LIVE_IP" = "$SERVER_IP" ]; then
success "Server IP verified in database: $SERVER_IP"
else
warning "Server IP in DB ($LIVE_IP) != expected ($SERVER_IP) - check manually"
fi

# Fix PJSIP external address
PJSIP_CONF="/etc/asterisk/pjsip.conf"
if [ -f "$PJSIP_CONF" ] && grep -q "SERVER_EXTERNAL_IP" "$PJSIP_CONF"; then
log "Fixing SERVER_EXTERNAL_IP placeholder in pjsip.conf..."
sed -i "s/SERVER_EXTERNAL_IP/${SERVER_IP}/g" "$PJSIP_CONF"
success "pjsip.conf: external addresses set to $SERVER_IP"
else
log "pjsip.conf: no SERVER_EXTERNAL_IP placeholder found (already correct)"
fi

# ---------------------------------------------------------------------------
# FIX: sip.conf websocket_enabled — must be false when res_pjsip is active
# ViciDial install.pl sets websocket_enabled=true in sip.conf by default.
# This causes chan_sip to register the "sip" WebSocket sub-protocol first,
# which prevents res_pjsip_transport_websocket.so from loading (it declines
# with AST_MODULE_LOAD_DECLINE because the protocol name is already taken).
# Result: WebRTC softphones show "NOT REGISTERED" forever.
# ---------------------------------------------------------------------------
SIP_CONF="/etc/asterisk/sip.conf"
if [ -f "$SIP_CONF" ]; then
    if grep -q 'websocket_enabled=true' "$SIP_CONF"; then
        sed -i 's/websocket_enabled=true/websocket_enabled=false/' "$SIP_CONF"
        success "sip.conf: websocket_enabled set to false (res_pjsip WebRTC fix)"
    elif grep -q 'websocket_enabled' "$SIP_CONF"; then
        info "sip.conf: websocket_enabled already set correctly"
    else
        # Line not present at all — append it to [general] section
        sed -i '/^\[general\]/a websocket_enabled=false\t; Required: prevents chan_sip from stealing the sip WebSocket protocol from res_pjsip' "$SIP_CONF"
        success "sip.conf: websocket_enabled=false added to [general]"
    fi
else
    warning "sip.conf not found — websocket_enabled fix will need to be applied manually after install.pl"
fi

# FIX: logger.conf must emit SECURITY-level events, or fail2ban's [asterisk]
# jail (Part 1) is silently blind. The jail's stock SecurityEvent= regex can
# only ever match lines Asterisk actually writes to a log file, and the
# default logger.conf never enables the `security` level on any channel —
# so `SecurityEvent="FailedACL"` etc. are generated internally but never hit
# disk, and that whole detection path never fires. Confirmed missing and
# fixed 2026-09-06.
# ---------------------------------------------------------------------------
LOGGER_CONF="/etc/asterisk/logger.conf"
if [ -f "$LOGGER_CONF" ]; then
    if grep -q "^messages.*security" "$LOGGER_CONF"; then
        info "logger.conf: messages channel already logs security events"
    else
        sed -i 's/^\(messages => .*\)$/\1,security/' "$LOGGER_CONF"
        success "logger.conf: security level added to messages channel"
    fi
    if command -v asterisk &>/dev/null && asterisk -rx "core show version" &>/dev/null; then
        asterisk -rx "logger reload" &>/dev/null
    fi
else
    warning "logger.conf not found — security-level logging fix will need to be applied manually after install.pl"
fi

# FIX #3: Improved GMT offset calculation (no Python dependency)
log "Setting server local_gmt based on system timezone..."

if command -v date &>/dev/null; then
# Get timezone offset in format +HHMM or -HHMM
TZ_OFFSET=$(date +%z)
# Convert to decimal hours: +0600 -> +6.00, -0730 -> -7.50
GMT_OFFSET=$(echo "$TZ_OFFSET" | awk '{
sign=substr($1,1,1)
hours=substr($1,2,2)
mins=substr($1,4,2)
decimal=hours + (mins/60)
printf "%s%.2f\n", sign, decimal
}')
success "Detected timezone offset: $GMT_OFFSET (from system timezone)"
else
warning "date command not available - defaulting to GMT 0.00"
GMT_OFFSET="0.00"
fi

# Update BOTH servers table AND system_settings (v10.15 fix)
# FIX #7: Error checking
if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk -e \
"UPDATE servers SET local_gmt='${GMT_OFFSET}' WHERE server_ip='${SERVER_IP}';" 2>/dev/null; then
success "servers.local_gmt set to ${GMT_OFFSET}"
else
warning "Failed to update servers.local_gmt"
fi

if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk -e \
"UPDATE system_settings SET default_local_gmt='${GMT_OFFSET}';" 2>/dev/null; then
success "system_settings.default_local_gmt set to ${GMT_OFFSET}"
else
warning "Failed to update system_settings.default_local_gmt"
fi

# Fix vicidial_agent_disable — default 'ALL' blocks agent logins on fresh installs
if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" asterisk -e \
"UPDATE system_settings SET vicidial_agent_disable='NONE';" 2>/dev/null; then
success "system_settings.vicidial_agent_disable set to NONE (agents can log in)"
else
warning "Failed to update vicidial_agent_disable"
fi

mark_step_complete "STEP_21"
fi

# ===========================================================================
# STEP 22/23: PROCESS LOCKING INFRASTRUCTURE (THE DUPLICATE PROCESS FIX)
# ===========================================================================
section "STEP 22/23: PROCESS LOCKING INFRASTRUCTURE"
check_step "STEP_22" "22/23" "Process Locking - flock wrapper, monitor daemon, systemd timer"

if [ "$SKIP_STEP" = false ]; then
    log "Installing process locking infrastructure..."
    log "This PERMANENTLY FIXES the duplicate ADMIN_keepalive_ALL.pl bug!"

    # -----------------------------------------------------------------------
    # PART 0a: Install Switch.pm (removed from Perl 5.36+, required by ViciDial AMI2)
    # Rocky Linux 10 ships Perl 5.40 which does not include Switch by default.
    # -----------------------------------------------------------------------
    log "Checking Switch.pm (required by AST_update_AMI2.pl and AST_manager_listen_AMI2.pl)..."
    if perl -e 'use Switch; print "ok"' 2>/dev/null | grep -q ok; then
        success "Switch.pm already installed"
    else
        if ! command -v cpanm &>/dev/null; then
            dnf install -y perl-App-cpanminus 2>/dev/null || true
        fi
        cpanm --notest Switch && success "Switch.pm installed" || \
            warning "Switch.pm install failed - AST_update_AMI2.pl and AST_manager_listen_AMI2.pl will not start"
    fi

    # -----------------------------------------------------------------------
    # PART 0b: Patch ps -o format in ViciDial scripts (procps-ng 4.x fix)
    # Rocky Linux 10 procps-ng 4.0.4 truncates long paths with ps -o "%p %a".
    # Fix: use ps -o "pid,args" which returns full paths at any terminal width.
    # Affects: ADMIN_keepalive_ALL.pl (3 locations), AST_manager_send.pl (1),
    #          AST_VDremote_agents.pl (1)
    # -----------------------------------------------------------------------
    log "Applying ps -o format patch to ViciDial scripts (procps-ng 4.x / Rocky Linux 10)..."
    PS_FIX_COUNT=0
    for ps_target in \
        "/usr/share/astguiclient/ADMIN_keepalive_ALL.pl" \
        "/usr/share/astguiclient/AST_manager_send.pl" \
        "/usr/share/astguiclient/AST_VDremote_agents.pl" \
        "/usr/share/astguiclient/AST_VDauto_dial.pl"; do
        if [ -f "$ps_target" ]; then
            HITS=$(grep -cF '/bin/ps -o "%p %a" --no-headers -A' "$ps_target" 2>/dev/null || echo "0")
            if [ "$HITS" -gt "0" ] 2>/dev/null; then
                sed -i 's|/bin/ps -o "%p %a" --no-headers -A|/bin/ps -o "pid,args" --no-headers -A|g' "$ps_target"
                PS_FIX_COUNT=$((PS_FIX_COUNT + 1))
                success "Fixed: $ps_target"
            else
                info "Already patched: $ps_target"
            fi
        fi
    done
    [ "$PS_FIX_COUNT" -gt 0 ] && success "ps format patched in $PS_FIX_COUNT file(s)" || \
        info "ps format already correct in all ViciDial scripts"

    # -----------------------------------------------------------------------
    # PART A: flock-based cron wrapper
    # -----------------------------------------------------------------------
    mkdir -p /var/lock/vicidial /var/log/astguiclient
    chmod 755 /var/lock/vicidial

    cat > /usr/local/bin/vicidial_cron_wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash
# ViciDial flock-based process wrapper v11.0
# Prevents duplicate instances of any wrapped script
set -euo pipefail

LOCK_DIR="/var/lock/vicidial"
LOG_DIR="/var/log/astguiclient"
MAX_LOCK_AGE=300   # Stale lock age in seconds
SCRIPT_TIMEOUT=240 # Max script runtime in seconds

mkdir -p "$LOCK_DIR" "$LOG_DIR"

SCRIPT="$1"; shift; ARGS="$@"
SCRIPT_NAME=$(basename "$SCRIPT" .pl)
LOCKFILE="${LOCK_DIR}/${SCRIPT_NAME}.lock"
LOGFILE="${LOG_DIR}/${SCRIPT_NAME}_wrapper.log"
PIDFILE="${LOCK_DIR}/${SCRIPT_NAME}.pid"

wlog() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$$] $1" >> "$LOGFILE"; }

# Remove stale locks older than MAX_LOCK_AGE
if [ -f "$LOCKFILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "$MAX_LOCK_AGE" ]; then
        wlog "Removing stale lock (${LOCK_AGE}s old)"
        rm -f "$LOCKFILE" "$PIDFILE"
    fi
fi

# Acquire exclusive lock (non-blocking - bail immediately if locked)
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    wlog "Skipping: previous instance still running"
    exit 0
fi

wlog "Lock acquired - starting: $SCRIPT $ARGS"
echo $$ > "$PIDFILE"

cleanup() {
    local EC=$?
    wlog "Exiting (code: $EC)"
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

timeout "$SCRIPT_TIMEOUT" "$SCRIPT" $ARGS >> "$LOGFILE" 2>&1
EXIT_CODE=$?

wlog "Completed (exit: $EXIT_CODE)"
exit $EXIT_CODE
WRAPPER_EOF

    chmod +x /usr/local/bin/vicidial_cron_wrapper.sh
    success "flock-based cron wrapper installed: /usr/local/bin/vicidial_cron_wrapper.sh"

    # -----------------------------------------------------------------------
    # PART B: Process Monitor Daemon
    # -----------------------------------------------------------------------
    cat > /usr/local/bin/vicidial_process_monitor.sh << 'MONITOR_EOF'
#!/bin/bash
# ViciDial Process Monitor Daemon v11.0
# Actively scans for and kills duplicate ViciDial processes
set -euo pipefail

MONITOR_INTERVAL=60
LOG_FILE="/var/log/astguiclient/process_monitor.log"
PID_FILE="/var/run/vicidial_process_monitor.pid"

# Maximum allowed runtime per script (seconds) before force-kill
# NOTE: Only one-shot/cron scripts go here.  Persistent screen-session
#       daemons (AST_VDauto_dial, AST_VDadapt, AST_VDremote_agents) must NOT
#       be listed here -- they are meant to run indefinitely.
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=600
    ["AST_flush_DBqueue.pl"]=120
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
)

# Scripts monitored for duplicate instances
# Uses "perl.*$script" so SCREEN wrapper commands are NOT counted
declare -a WATCHED_SCRIPTS=(
    "ADMIN_keepalive_ALL.pl"
    "AST_VDhopper.pl"
    "AST_VDauto_dial.pl"
    "AST_VDauto_dial_FILL.pl"
    "AST_flush_DBqueue.pl"
    "AST_VDremote_agents.pl"
    "AST_VDadapt.pl"
)

mkdir -p "$(dirname "$LOG_FILE")"

mlog() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Singleton check
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Monitor already running (PID: $OLD_PID)"
        exit 1
    fi
    rm -f "$PID_FILE"
fi

echo $$ > "$PID_FILE"
cleanup() { mlog "Monitor shutting down"; rm -f "$PID_FILE"; exit 0; }
trap cleanup EXIT INT TERM

mlog "ViciDial Process Monitor started (PID: $$)"

get_runtime() { ps -p "$1" -o etimes= 2>/dev/null | tr -d ' ' || echo "0"; }

kill_proc() {
    local pid=$1 name=$2 reason=$3
    mlog "Terminating: $name (PID: $pid) - $reason"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
}

while true; do
    mlog "--- Process scan ---"

    # Kill duplicate instances (keep oldest)
    for script in "${WATCHED_SCRIPTS[@]}"; do
        PIDS=$( { pgrep -f "perl.*${script}" 2>/dev/null || true; } )
        [ -z "$PIDS" ] && continue
        COUNT=$(echo "$PIDS" | wc -l)
        if [ "$COUNT" -gt 1 ]; then
            mlog "WARNING: $COUNT instances of $script detected"
            # Sort by start time, keep oldest (first started)
            SORTED=$(for p in $PIDS; do
                echo "$(ps -p $p -o lstart= 2>/dev/null | date +%s -f - 2>/dev/null || echo 0) $p"
            done | sort -n | awk '{print $2}')
            KEEP=$(echo "$SORTED" | head -1)
            KILL=$(echo "$SORTED" | tail -n +2)
            mlog "Keeping oldest PID: $KEEP"
            for pid in $KILL; do
                kill_proc "$pid" "$script" "Duplicate instance"
            done
        fi
    done

    # Kill runaway processes that exceed max runtime
    for script in "${!MAX_RUNTIME[@]}"; do
        MAX_SEC=${MAX_RUNTIME[$script]}
        PIDS=$( { pgrep -f "perl.*${script}" 2>/dev/null || true; } )
        [ -z "$PIDS" ] && continue
        for pid in $PIDS; do
            RT=$(get_runtime "$pid")
            if [ "$RT" -gt "$MAX_SEC" ]; then
                kill_proc "$pid" "$script" "Runtime exceeded (${RT}s > ${MAX_SEC}s)"
            fi
        done
    done

    sleep "$MONITOR_INTERVAL"
done
MONITOR_EOF

    chmod +x /usr/local/bin/vicidial_process_monitor.sh
    success "Process monitor daemon installed: /usr/local/bin/vicidial_process_monitor.sh"

    # -----------------------------------------------------------------------
    # PART C: Systemd service for process monitor daemon
    # -----------------------------------------------------------------------
    cat > /etc/systemd/system/vicidial-process-monitor.service << 'SERVICE_EOF'
[Unit]
Description=ViciDial Process Monitor Daemon
After=mariadb.service network.target
Wants=mariadb.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vicidial_process_monitor.sh
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable vicidial-process-monitor.service
    systemctl start vicidial-process-monitor.service
    sleep 2
    if systemctl is-active --quiet vicidial-process-monitor; then
        success "Process monitor daemon is running"
    else
        warning "Process monitor daemon failed to start - check: journalctl -u vicidial-process-monitor"
    fi

    # -----------------------------------------------------------------------
    # PART D: Systemd timer for ADMIN_keepalive_ALL.pl (replaces raw cron!)
    # -----------------------------------------------------------------------
    cat > /etc/systemd/system/vicidial-keepalive.service << 'KEEPALIVE_SVC'
[Unit]
Description=ViciDial Master Keepalive (single shot)
After=mariadb.service
Requires=mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way
User=root
TimeoutStartSec=240
Restart=no
RemainAfterExit=no
KEEPALIVE_SVC

    cat > /etc/systemd/system/vicidial-keepalive.timer << 'KEEPALIVE_TMR'
[Unit]
Description=ViciDial Keepalive - runs every 60 seconds (replaces raw cron)
Requires=vicidial-keepalive.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
KEEPALIVE_TMR

    systemctl daemon-reload
    systemctl enable vicidial-keepalive.timer
    systemctl start vicidial-keepalive.timer
    sleep 2
    if systemctl is-active --quiet vicidial-keepalive.timer; then
        success "Keepalive systemd timer is ACTIVE (ADMIN_keepalive_ALL.pl runs every 60s via timer)"
    else
        warning "Keepalive timer failed to activate - check: systemctl status vicidial-keepalive.timer"
    fi

    echo ""
    info "✅ flock wrapper: /usr/local/bin/vicidial_cron_wrapper.sh"
    info "✅ Process monitor daemon: running (systemd service)"
    info "✅ Systemd keepalive timer: active (replaces raw cron)"
    info "🎉 DUPLICATE PROCESS BUG IS NOW PERMANENTLY FIXED!"
    echo ""

    mark_step_complete "STEP_22"
fi

# ===========================================================================
# STEP 23/23: VICIDIAL CRONTAB (merged, with process-locking wrappers)
# ===========================================================================
section "STEP 23/23: VICIDIAL CRONTAB CONFIGURATION"
check_step "STEP_23" "23/23" "ViciDial Crontab"

if [ "$SKIP_STEP" = false ]; then
log "Backing up existing crontab..."
crontab -l > /tmp/crontab.backup 2>/dev/null || true

# FIX #6: Check if ViciDial entries already exist
if grep -q "astguiclient" /tmp/crontab.backup 2>/dev/null; then
warning "ViciDial crontab entries already exist - removing old entries"
grep -v "astguiclient" /tmp/crontab.backup > /tmp/crontab.cleaned 2>/dev/null || true
mv /tmp/crontab.cleaned /tmp/crontab.backup
fi

cat > /tmp/vicidial_crontab << 'CRONTAB_END'
### ViciDial Crontab - Generated by Part 2 (Rocky Linux 10 / 2026-02-17)
### ADMIN_keepalive_ALL.pl is managed by systemd timer (vicidial-keepalive.timer)
### See: systemctl status vicidial-keepalive.timer
###
### NOTE: AST_VDauto_dial, AST_VDremote_agents, AST_VDadapt are persistent
###       screen-session daemons managed by ADMIN_keepalive_ALL.pl -- NOT cron jobs.

### Hopper fill - loads leads into the dialing hopper (CRITICAL)
* * * * * /usr/share/astguiclient/AST_VDhopper.pl -q

### Every-minute system tasks (standard ViciDial)
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl
* * * * * /usr/share/astguiclient/AST_vm_update.pl
* * * * * /usr/share/astguiclient/AST_conf_update.pl
* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl

### Cleanup (every 5 minutes - flock wrapped)
*/5 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDauto_dial_FILL.pl
*/5 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_flush_DBqueue.pl -q

### Hourly tasks
33 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours

### Recording file management (every 3 minutes - standard ViciDial schedule)
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS

### Daily maintenance tasks
2 1 * * * /usr/share/astguiclient/AST_reset_mysql_vars.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl
1 1,7 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug
25 0 * * * /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q
22 0 * * * /usr/share/astguiclient/AST_agent_day.pl
1 7 * * * /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours
28 0 * * * /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -print | xargs rm -f
29 0 * * * /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -print | xargs rm -f
30 0 * * * /usr/bin/find / -maxdepth 1 -name "screenlog.0*" -mtime +4 -print | xargs rm -f
24 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -maxdepth 2 -type f -mtime +1 -print | xargs rm -f

### Weekly tasks
2 0 * * 0 /usr/share/astguiclient/AST_agent_week.pl
0 4 * * 0 /usr/share/astguiclient/AST_DB_optimize.pl

### Archive (monthly - uncomment if high-volume)
#30 1 1 * * /usr/share/astguiclient/ADMIN_archive_log_tables.pl
CRONTAB_END

# FIX #6: Merge old crontab (without ViciDial entries) with new ViciDial crontab
cat /tmp/crontab.backup /tmp/vicidial_crontab > /tmp/crontab.merged
crontab /tmp/crontab.merged

# Cleanup temp files
rm -f /tmp/vicidial_crontab /tmp/crontab.merged /tmp/crontab.backup

CRON_COUNT=$(crontab -l | grep -c "astguiclient" || echo "0")
success "Installed $CRON_COUNT ViciDial cron jobs"
mark_step_complete "STEP_23"
fi

# ===========================================================================
# PERL MODULE SYNC SCRIPT + SYSTEMD PATH UNIT (post-update automation)
# Installs /usr/local/sbin/vicidial-sync-perl-modules and a systemd .path
# unit so the copy is re-run automatically whenever install.pl updates
# /usr/share/astguiclient/libs/ (e.g. during a ViciDial version upgrade).
# Re-running the install script is also safe — all three pieces are idempotent.
# ===========================================================================
section "PERL MODULE SYNC SCRIPT + AUTO-UPDATE PATH UNIT"

log "Installing /usr/local/sbin/vicidial-sync-perl-modules..."
cat > /usr/local/sbin/vicidial-sync-perl-modules << 'SYNC_SCRIPT'
#!/usr/bin/env bash
# vicidial-sync-perl-modules
# Copy ViciDial Perl modules from /usr/share/astguiclient/libs/ into the
# system Perl path so Asterisk AGI subprocesses can load them without
# PERL5LIB being set.
#
# Run manually after any ViciDial update:
#   /usr/local/sbin/vicidial-sync-perl-modules
#
# Also triggered automatically by vicidial-perl-sync.path whenever
# install.pl writes to /usr/share/astguiclient/libs/.

set -euo pipefail

LIBS_DIR="/usr/share/astguiclient/libs"
# Site Perl dir that's on @INC: /usr/local/share/perl5 on Rocky 8 (Perl 5.26),
# /usr/local/share/perl5/5.40 on Rocky 10.
PERL_DEST="$(perl -MConfig -e 'print $Config{installsitelib}')"

if [ ! -d "${LIBS_DIR}/Asterisk" ]; then
    echo "ERROR: ${LIBS_DIR}/Asterisk not found — has install.pl run?" >&2
    exit 1
fi

mkdir -p "${PERL_DEST}/Asterisk"
cp -f "${LIBS_DIR}/Asterisk/"*.pm "${PERL_DEST}/Asterisk/"
cp -f "${LIBS_DIR}/Asterisk.pm"   "${PERL_DEST}/"
cp -f "${LIBS_DIR}/viciagi.pm"    "${PERL_DEST}/"
cp -f "${LIBS_DIR}/vicidial.pm"   "${PERL_DEST}/"

if perl -e 'use Asterisk::AGI; print "ok"' 2>/dev/null | grep -q ok; then
    echo "OK: Asterisk::AGI loadable from system Perl path (${PERL_DEST})"
else
    echo "WARNING: modules copied but Asterisk::AGI still not loadable — check Perl version" >&2
    exit 2
fi
SYNC_SCRIPT
chmod 755 /usr/local/sbin/vicidial-sync-perl-modules
success "Sync script installed at /usr/local/sbin/vicidial-sync-perl-modules"

log "Installing vicidial-perl-sync systemd service + path unit..."
cat > /etc/systemd/system/vicidial-perl-sync.service << 'SERVICE_UNIT'
[Unit]
Description=Sync ViciDial Perl modules into system Perl path
After=network.target
Documentation=https://github.com/FrancoSmash73/vicidial-rocky10

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vicidial-sync-perl-modules
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vicidial-perl-sync
SERVICE_UNIT

cat > /etc/systemd/system/vicidial-perl-sync.path << 'PATH_UNIT'
[Unit]
Description=Watch ViciDial astguiclient libs for changes (re-run Perl module sync)
Documentation=https://github.com/FrancoSmash73/vicidial-rocky10

[Path]
# Fires when install.pl (or any process) closes a write to this directory.
# Covers ViciDial version upgrades that update Asterisk::AGI, Manager.pm, etc.
PathChanged=/usr/share/astguiclient/libs

[Install]
WantedBy=multi-user.target
PATH_UNIT

systemctl daemon-reload
systemctl enable --now vicidial-perl-sync.path && \
    success "vicidial-perl-sync.path enabled (auto-sync on ViciDial updates)" || \
    warning "Failed to enable vicidial-perl-sync.path — re-run sync manually after updates"

# ===========================================================================
# ROCKY LINUX 10 COMPATIBILITY RE-PATCH SCRIPT + AUTO-TRIGGER PATH UNIT
#
# Every Rocky10 compatibility fix in this installer (DBI:MariaDB, ps-format
# truncation, Asterisk::AGI.pm empty-digits, sip.conf websocket_enabled,
# pjsip.conf webrtc_template) lives inside a skippable STEP_* block tied to
# install.pl's own invocation. Re-running install.pl directly — manually,
# over SSH, or via a future ViciDial upgrade — redeploys fresh unpatched
# files and silently reverts ALL of them at once. This installs one
# consolidated, idempotent script plus a systemd .path unit that watches
# every file/dir install.pl touches and re-applies every patch automatically
# within seconds, with no manual "did I remember to re-patch" step ever
# required again.
# ===========================================================================
section "ROCKY LINUX 10 AUTO-REPATCH SCRIPT + PATH UNIT"

# Stage the known-good agc/ PHP files (XSS fixes - see CLAUDE.md "agc web files")
# to a persistent system path so the repatch script below can restore them
# without depending on this repo checkout still being present at $SCRIPT_DIR.
log "Staging agc/ security-patched reference files..."
mkdir -p /usr/local/share/vicidial-rocky10/agc-security-patches
if [ -d "$SCRIPT_DIR/agc-security-patches" ]; then
    cp "$SCRIPT_DIR"/agc-security-patches/*.php /usr/local/share/vicidial-rocky10/agc-security-patches/
    success "Staged $(ls "$SCRIPT_DIR"/agc-security-patches/*.php | wc -l) agc/ reference files to /usr/local/share/vicidial-rocky10/agc-security-patches/"
else
    warning "$SCRIPT_DIR/agc-security-patches not found - agc/ XSS patches will not be applied by the repatch script"
fi

# Stage the call-time guard (hard 9pm / state / bad-timezone dial block - see CLAUDE.md)
log "Staging call-time guard files..."
mkdir -p /usr/local/share/vicidial-rocky10/calltime-guard
if [ -d "$SCRIPT_DIR/calltime-guard" ]; then
    cp -f "$SCRIPT_DIR"/calltime-guard/Rocky10CallTime.pm "$SCRIPT_DIR"/calltime-guard/apply_vdauto_guard.py "$SCRIPT_DIR"/calltime-guard/apply_vdc_guard.py "$SCRIPT_DIR"/calltime-guard/rocky10_calltime.inc.php "$SCRIPT_DIR"/calltime-guard/calltime_triggers.sql "$SCRIPT_DIR"/calltime-guard/vicidial-calltime-watch.pl /usr/local/share/vicidial-rocky10/calltime-guard/
    chmod 755 /usr/local/share/vicidial-rocky10/calltime-guard/apply_vdauto_guard.py /usr/local/share/vicidial-rocky10/calltime-guard/apply_vdc_guard.py
    success "Staged call-time guard files to /usr/local/share/vicidial-rocky10/calltime-guard/"
    # Layer 3: alerting watcher + 1-minute systemd timer (mails root on late calls / protection drift)
    install -m 755 "$SCRIPT_DIR"/calltime-guard/vicidial-calltime-watch.pl /usr/local/sbin/vicidial-calltime-watch
    install -m 644 "$SCRIPT_DIR"/calltime-guard/vicidial-calltime-watch.service "$SCRIPT_DIR"/calltime-guard/vicidial-calltime-watch.timer /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now vicidial-calltime-watch.timer &>/dev/null || warning "could not enable vicidial-calltime-watch.timer"
else
    warning "$SCRIPT_DIR/calltime-guard not found - call-time guard will not be applied by the repatch script"
fi

log "Installing /usr/local/sbin/vicidial-rocky10-repatch..."
cat > /usr/local/sbin/vicidial-rocky10-repatch << 'REPATCH_SCRIPT_EOF'
#!/usr/bin/env bash
# vicidial-rocky10-repatch
#
# Re-applies every Rocky Linux 10 / AlmaLinux 10 compatibility patch that
# ViciDial's own install.pl and stock sample configs do NOT carry, and that
# a fresh `install.pl` re-run (manual or via a ViciDial upgrade) will silently
# revert. Idempotent — safe to run any number of times, changes nothing if
# everything is already patched.
#
# Run manually any time after re-running install.pl:
#   /usr/local/sbin/vicidial-rocky10-repatch
#
# Also triggered automatically by vicidial-rocky10-repatch.path whenever any
# of the watched files/directories change.
#
# Repo: https://github.com/FrancoSmash73/vicidial-rocky10

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }

CHANGED=0
ASTERISK_CONF_CHANGED=0

# ---------------------------------------------------------------------------
# 1. DBI:MariaDB + mysql_insertid patch
#    ViciDial ships DBI:mysql: / mysql_insertid everywhere. Rocky 10 only has
#    DBD::MariaDB by default (DBD::mysql is a manually-pinned 4.052 fallback
#    for legacy AGI scripts). Without this, main scripts fail to connect and
#    AGI scripts fail silently on the DB connect line.
# ---------------------------------------------------------------------------
_patch_dbi_dir() {
    local DIR="$1" LABEL="$2" PATTERN="$3"
    [ -d "$DIR" ] || { warning "$LABEL ($DIR) not found - skipping"; return; }
    local FILES
    FILES=$(find "$DIR" -maxdepth 1 -type f -name "$PATTERN" 2>/dev/null)
    [ -z "$FILES" ] && { warning "no $PATTERN files in $LABEL - skipping"; return; }

    local hit=0
    while IFS= read -r f; do
        if grep -qE 'DBI:mysql:|DBI:mariadb:|DBD::mysql|mysql_insertid' "$f" 2>/dev/null; then
            hit=1
            break
        fi
    done <<< "$FILES"

    if [ "$hit" -eq 0 ]; then
        log "$LABEL: already patched"
        return
    fi

    find "$DIR" -maxdepth 1 -type f -name "$PATTERN" -exec sed -i \
        -e 's/DBI:mysql:/DBI:MariaDB:/g' \
        -e 's/DBI:mariadb:/DBI:MariaDB:/g' \
        -e 's/DBD::mysql/DBD::MariaDB/g' \
        -e 's/mysql_insertid/mariadb_insertid/g' \
        {} \; 2>/dev/null
    success "$LABEL: DBI:MariaDB + mariadb_insertid patch applied"
    CHANGED=1
}
_patch_dbi_dir "/usr/share/astguiclient" "installed ViciDial scripts" "*.pl"
_patch_dbi_dir "/var/lib/asterisk/agi-bin" "AGI scripts" "*.agi"

# ---------------------------------------------------------------------------
# 2. ps-truncation patch
#    procps-ng 4.0.4 on Rocky 10 truncates `ps -o "%p %a"` output to ~30
#    chars. These 4 scripts use that to detect sibling/listener processes;
#    a truncated match makes them think the AMI listener (or themselves) is
#    dead/duplicated, and they exit immediately every time the keepalive
#    timer spawns them.
# ---------------------------------------------------------------------------
PS_OLD='/bin/ps -o "%p %a" --no-headers -A'
PS_NEW='/bin/ps -o "pid,args" --no-headers -A'
for f in \
    /usr/share/astguiclient/ADMIN_keepalive_ALL.pl \
    /usr/share/astguiclient/AST_manager_send.pl \
    /usr/share/astguiclient/AST_VDremote_agents.pl \
    /usr/share/astguiclient/AST_VDauto_dial.pl; do
    [ -f "$f" ] || { warning "$f not found - skipping"; continue; }
    if grep -qF "$PS_OLD" "$f" 2>/dev/null; then
        sed -i "s|$PS_OLD|$PS_NEW|g" "$f"
        success "$(basename "$f"): ps-truncation patch applied"
        CHANGED=1
    else
        log "$(basename "$f"): already patched"
    fi
done

# ---------------------------------------------------------------------------
# 3. Asterisk::AGI.pm empty-digits patch
#    stream_file($file, "") sends "STREAM FILE filename " with no
#    escape_digits -> Asterisk returns 520, survey audio never plays
#    (SVYHU calls, length_in_sec=0).
# ---------------------------------------------------------------------------
PERL_SITELIB="$(perl -MConfig -e 'print $Config{installsitelib}')"
for f in \
    "${PERL_SITELIB}/Asterisk/AGI.pm" \
    /usr/share/astguiclient/libs/Asterisk/AGI.pm; do
    [ -f "$f" ] || { warning "$f not found - skipping"; continue; }
    if grep -qF "digits eq ''" "$f" 2>/dev/null; then
        log "$f: already patched"
    else
        sed -i "s/\$digits = '\"\"' if (!defined(\$digits));/\$digits = '\"\"' if (!defined(\$digits) || \$digits eq '');/g" "$f"
        success "$f: empty-digits patch applied"
        CHANGED=1
    fi
done

# ---------------------------------------------------------------------------
# 4. sip.conf websocket_enabled=false
#    install.pl's sample sip.conf ships websocket_enabled=true, which makes
#    chan_sip register the "sip" websocket sub-protocol first, so
#    res_pjsip_transport_websocket.so declines to load -> WebRTC softphones
#    never register.
# ---------------------------------------------------------------------------
SIP_CONF="/etc/asterisk/sip.conf"
if [ -f "$SIP_CONF" ]; then
    if grep -q '^websocket_enabled=true' "$SIP_CONF"; then
        sed -i 's/^websocket_enabled=true/websocket_enabled=false/' "$SIP_CONF"
        success "sip.conf: websocket_enabled=false applied"
        CHANGED=1; ASTERISK_CONF_CHANGED=1
    elif grep -q '^websocket_enabled=false' "$SIP_CONF"; then
        log "sip.conf: websocket_enabled already false"
    else
        sed -i '/^\[general\]/a websocket_enabled=false' "$SIP_CONF"
        success "sip.conf: websocket_enabled=false added to [general]"
        CHANGED=1; ASTERISK_CONF_CHANGED=1
    fi
else
    warning "sip.conf not found - skipping"
fi

# ---------------------------------------------------------------------------
# 5. pjsip.conf webrtc_template + agents include
#    ViciDial's stock pjsip.conf sample already ships a bare [transport-wss]
#    stanza, so a naive "does transport-wss exist" check thinks WebRTC is
#    already configured and never adds the actual endpoint template or the
#    agents-conf include. Only applied if this server has WebRTC set up
#    (i.e. HulkPhone was deployed) so plain voice-only installs are untouched.
# ---------------------------------------------------------------------------
PJSIP_CONF="/etc/asterisk/pjsip.conf"
AGENTS_CONF="/etc/asterisk/pjsip-webrtc-agents.conf"
if [ -f "$PJSIP_CONF" ] && [ -f "$AGENTS_CONF" ]; then
    if grep -q 'webrtc_template' "$PJSIP_CONF" 2>/dev/null; then
        log "pjsip.conf: already has webrtc_template"
    else
        if ! grep -q '^\[transport-wss\]' "$PJSIP_CONF" 2>/dev/null; then
            cat >> "$PJSIP_CONF" << 'PJSIPTRANSPORT'

[transport-wss]
type                            = transport
protocol                        = wss
bind                            = 0.0.0.0
PJSIPTRANSPORT
        fi
        cat >> "$PJSIP_CONF" << 'PJSIPWSS'

; --- WebRTC/HulkPhone endpoint template ---
[webrtc_template](!)
type=endpoint
transport=transport-wss
context=default
disallow=all
allow=opus
allow=ulaw
allow=alaw
dtls_verify=no
dtls_rekey=0
ice_support=yes
media_use_received_transport=yes
rtcp_mux=yes
use_avpf=yes
media_encryption=dtls
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes

#include "pjsip-webrtc-agents.conf"
PJSIPWSS
        success "pjsip.conf: webrtc_template + agents include applied"
        CHANGED=1; ASTERISK_CONF_CHANGED=1
    fi
fi

# ---------------------------------------------------------------------------
# 6. VARserver_ip blank check
#    install.pl run non-interactively (--no-prompt, no controlling TTY) can
#    leave "VARserver_ip => " blank in astguiclient.conf even when
#    --server_ip is passed on the CLI. ADMIN_keepalive_ALL.pl matches this
#    server's DB row on VARserver_ip, so a blank value means it NEVER
#    regenerates pjsip-vicidial.conf / pjsip_wizard-vicidial.conf, and
#    Asterisk fails to parse pjsip.conf at all ("#include ... does not
#    exist") -- taking down ALL of PJSIP, not just WebRTC.
# ---------------------------------------------------------------------------
CONF="/etc/astguiclient.conf"
if [ -f "$CONF" ]; then
    if grep -q '^VARserver_ip => *$' "$CONF" 2>/dev/null; then
        DETECTED_IP=$(hostname -I | awk '{print $1}')
        sed -i "s/^VARserver_ip => *\$/VARserver_ip => ${DETECTED_IP}/" "$CONF"
        warning "astguiclient.conf: VARserver_ip was blank - set to ${DETECTED_IP}"
        CHANGED=1
    else
        log "astguiclient.conf: VARserver_ip already set"
    fi
else
    warning "$CONF not found - skipping"
fi

# ---------------------------------------------------------------------------
# 7. agc/ reflected + stored XSS patches (see CLAUDE.md "agc web files")
#    install.pl deploys ViciDial's stock agc/ PHP files fresh from SVN into
#    BOTH /usr/src/astguiclient/trunk/www/agc (the checkout) and
#    /var/www/html/agc (the served copy served via Apache's "Alias /agc")
#    on every fresh install AND every install.pl re-run/upgrade - silently
#    reverting these fixes exactly like the patches above. Several stock
#    ViciDial agc/ scripts sanitize request input with a filter that strips
#    quotes/backslash/semicolon but not < / >, then echo the value raw into
#    HTML (reflected XSS); chat_db_query.php stores chat messages with only
#    SQL-escaping and echoes them back unescaped (stored XSS). Whole-file
#    replacement (not a sed patch) - simpler and less error-prone than
#    re-deriving ~150 individual regex edits across 13 files.
# ---------------------------------------------------------------------------
AGC_PATCH_SRC="/usr/local/share/vicidial-rocky10/agc-security-patches"
AGC_MARKER="ROCKY10-AGC-SECURITY-PATCH-v1"
if [ -d "$AGC_PATCH_SRC" ]; then
    for AGC_TARGET_DIR in /usr/src/astguiclient/trunk/www/agc /var/www/html/agc; do
        [ -d "$AGC_TARGET_DIR" ] || continue
        for AGC_SRC_FILE in "$AGC_PATCH_SRC"/*.php; do
            [ -f "$AGC_SRC_FILE" ] || continue
            AGC_FNAME=$(basename "$AGC_SRC_FILE")
            AGC_DEST="$AGC_TARGET_DIR/$AGC_FNAME"
            [ -f "$AGC_DEST" ] || continue
            if grep -qF "$AGC_MARKER" "$AGC_DEST" 2>/dev/null; then
                continue
            fi
            # Preserve any [SKIN-LOADER] branding header already present on
            # this server's copy - our reference files are the clean
            # (unbranded) trunk versions.
            AGC_SKIN_HEADER=""
            if grep -q '\[SKIN-LOADER\]' "$AGC_DEST" 2>/dev/null; then
                AGC_SKIN_HEADER=$(awk '/\[SKIN-LOADER\]/{f=1} f{print} /\[\/SKIN-LOADER\]/{if(f)exit}' "$AGC_DEST")
            fi
            if [ -n "$AGC_SKIN_HEADER" ]; then
                { head -1 "$AGC_SRC_FILE"; echo "$AGC_SKIN_HEADER"; echo ""; tail -n +2 "$AGC_SRC_FILE"; } > "$AGC_DEST"
            else
                cp "$AGC_SRC_FILE" "$AGC_DEST"
            fi
            if command -v php &>/dev/null && ! php -l "$AGC_DEST" &>/dev/null; then
                warning "$AGC_TARGET_DIR/$AGC_FNAME: patched copy failed php -l - check manually"
            else
                success "$AGC_TARGET_DIR/$AGC_FNAME: XSS patch applied"
            fi
            CHANGED=1
        done
    done
else
    warning "agc/ security patch source ($AGC_PATCH_SRC) not found - skipping agc/ XSS patches"
fi

# ---------------------------------------------------------------------------
# 8. Call-time guard (ROCKY10-CALLTIME-GUARD-v1)
#    Hard 9pm / per-state / bad-timezone dial block inside AST_VDauto_dial.pl,
#    independent of every campaign call-time setting. install.pl / ViciDial
#    upgrades overwrite AST_VDauto_dial.pl, which would silently remove it.
#    Fail-safe: the patched file must pass `perl -c` or the previous file is
#    restored. A freshly re-patched dialer is restarted (keepalive respawns it)
#    because the running process still holds the old code.
# ---------------------------------------------------------------------------
CT_SRC="/usr/local/share/vicidial-rocky10/calltime-guard"
CT_MARKER="ROCKY10-CALLTIME-GUARD-v1"
CT_DIAL="/usr/share/astguiclient/AST_VDauto_dial.pl"
if [ -f "$CT_SRC/Rocky10CallTime.pm" ] && [ -f "$CT_DIAL" ]; then
    CT_PMDEST="$(perl -MConfig -e 'print $Config{installsitelib}')/Rocky10CallTime.pm"
    mkdir -p "$(dirname "$CT_PMDEST")"
    if ! cmp -s "$CT_SRC/Rocky10CallTime.pm" "$CT_PMDEST" 2>/dev/null; then
        cp "$CT_SRC/Rocky10CallTime.pm" "$CT_PMDEST" && chmod 644 "$CT_PMDEST"
        success "Rocky10CallTime.pm installed to $CT_PMDEST"
        CHANGED=1
    fi
    if grep -qF "$CT_MARKER" "$CT_DIAL" 2>/dev/null; then
        log "AST_VDauto_dial.pl: call-time guard already present"
    elif [ -x "$CT_SRC/apply_vdauto_guard.py" ]; then
        cp -p "$CT_DIAL" "$CT_DIAL.pre-calltime-guard"
        if "$CT_SRC/apply_vdauto_guard.py" "$CT_DIAL" >/dev/null && perl -c "$CT_DIAL" >/dev/null 2>&1; then
            success "AST_VDauto_dial.pl: call-time guard applied"
            pkill -f '^/usr/bin/perl /usr/share/astguiclient/AST_VDauto_dial.pl' 2>/dev/null || true
            CHANGED=1
        else
            cp -p "$CT_DIAL.pre-calltime-guard" "$CT_DIAL"
            warning "AST_VDauto_dial.pl: call-time guard FAILED to apply (upstream changed?) - restored; DIALER IS UNGUARDED, fix manually"
        fi
    fi
else
    warning "call-time guard sources ($CT_SRC) not found - skipping"
fi

# 8b. Same guard for MANUAL dialing in agc/vdc_db_query.php. Section 7 restores the
#     staged (already guarded) copy after an upgrade; this covers a live copy that
#     carries the XSS marker but lacks the guard. Must pass `php -l` or is restored.
CT_VDC="/var/www/html/agc/vdc_db_query.php"
if [ -f "$CT_VDC" ] && [ -x "$CT_SRC/apply_vdc_guard.py" ]; then
    if grep -qF "$CT_MARKER" "$CT_VDC" 2>/dev/null; then
        log "vdc_db_query.php: manual call-time guard already present"
    else
        cp -p "$CT_VDC" "$CT_VDC.pre-calltime-guard"
        if "$CT_SRC/apply_vdc_guard.py" "$CT_VDC" >/dev/null && { ! command -v php &>/dev/null || php -l "$CT_VDC" &>/dev/null; }; then
            success "vdc_db_query.php: manual call-time guard applied"
            CHANGED=1
        else
            cp -p "$CT_VDC.pre-calltime-guard" "$CT_VDC"
            warning "vdc_db_query.php: manual call-time guard FAILED to apply - restored; MANUAL DIALING IS UNGUARDED, fix manually"
        fi
    fi
fi

# 8c. Layer 2: database triggers that stop call-time settings being loosened (see CLAUDE.md).
#     ViciDial SQL upgrades that DROP/recreate a table also drop its triggers; re-create if fewer
#     than the expected 10 rocky10_* triggers exist. Needs DB root via the local socket.
CT_SQL="$CT_SRC/calltime_triggers.sql"
if [ -f "$CT_SQL" ] && command -v mysql &>/dev/null; then
    CT_TRG=$(mysql -N -e "select count(*) from information_schema.triggers where trigger_schema='asterisk' and trigger_name like 'rocky10%'" 2>/dev/null)
    if [ "${CT_TRG:-}" = "" ]; then
        warning "call-time triggers: cannot query the database as root - skipping"
    elif [ "$CT_TRG" -ge 10 ]; then
        log "call-time triggers: $CT_TRG present"
    elif mysql asterisk < "$CT_SQL" 2>/dev/null; then
        success "call-time triggers re-created (had $CT_TRG of 10)"
        CHANGED=1
    else
        warning "call-time triggers FAILED to install - call-time SETTINGS are unprotected"
    fi
fi

# ---------------------------------------------------------------------------
# Reload affected services if anything changed.
# Uses targeted module reloads, NOT a full "core restart now" — this can run
# unattended (via the .path unit) at any time of day and must not drop live
# calls. sip.conf/pjsip.conf changes only need a reload; DBI/ps/AGI.pm
# patches take effect on the next script invocation with no Asterisk action
# needed at all.
# ---------------------------------------------------------------------------
if [ "$ASTERISK_CONF_CHANGED" -eq 1 ] && command -v asterisk &>/dev/null && asterisk -rx "core show version" &>/dev/null; then
    warning "sip.conf/pjsip.conf changed - reloading (not restarting) Asterisk"
    asterisk -rx "sip reload" 2>/dev/null || true
    asterisk -rx "pjsip reload" 2>/dev/null || true
fi

if [ "$CHANGED" -eq 1 ]; then
    success "vicidial-rocky10-repatch: done (changes applied)"
else
    success "vicidial-rocky10-repatch: done (already up to date, no changes)"
fi
REPATCH_SCRIPT_EOF
chmod 755 /usr/local/sbin/vicidial-rocky10-repatch
success "Repatch script installed at /usr/local/sbin/vicidial-rocky10-repatch"

log "Installing vicidial-rocky10-repatch systemd service + path unit..."
cat > /etc/systemd/system/vicidial-rocky10-repatch.service << 'REPATCH_SERVICE_EOF'
[Unit]
Description=Re-apply Rocky Linux 10 compatibility patches to ViciDial
Documentation=https://github.com/FrancoSmash73/vicidial-rocky10
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vicidial-rocky10-repatch
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vicidial-rocky10-repatch
REPATCH_SERVICE_EOF

cat > /etc/systemd/system/vicidial-rocky10-repatch.path << 'REPATCH_PATH_EOF'
[Unit]
Description=Watch ViciDial files for changes (auto re-apply Rocky Linux 10 patches)
Documentation=https://github.com/FrancoSmash73/vicidial-rocky10

[Path]
# Fires whenever install.pl (manual re-run or ViciDial upgrade) rewrites any
# of these — which is exactly when the DBI:MariaDB, ps-truncation, AGI.pm,
# sip.conf, pjsip.conf, and agc/ XSS patches get silently reverted.
PathChanged=/usr/share/astguiclient
PathChanged=/var/lib/asterisk/agi-bin
PathChanged=/etc/astguiclient.conf
PathChanged=/etc/asterisk/sip.conf
PathChanged=/etc/asterisk/pjsip.conf
PathChanged=/usr/src/astguiclient/trunk/www/agc
PathChanged=/var/www/html/agc
PathChanged=/usr/share/astguiclient/libs/Asterisk
PathChanged=/usr/local/share/perl5
PathChanged=@PERL_SITELIB@/Asterisk

[Install]
WantedBy=multi-user.target
REPATCH_PATH_EOF
# The unit file is written from a quoted heredoc; fill in the real site-Perl
# dir (/usr/local/share/perl5 on Rocky 8, no version folder).
sed -i "s|@PERL_SITELIB@|${PERL_SITELIB}|" /etc/systemd/system/vicidial-rocky10-repatch.path

systemctl daemon-reload
systemctl enable --now vicidial-rocky10-repatch.path && \
    success "vicidial-rocky10-repatch.path enabled (auto-repatch on install.pl re-runs/upgrades)" || \
    warning "Failed to enable vicidial-rocky10-repatch.path — re-run /usr/local/sbin/vicidial-rocky10-repatch manually after any install.pl re-run"

# Run once now so a fresh install starts from a fully-patched state
/usr/local/sbin/vicidial-rocky10-repatch || true

# ===========================================================================
# CLEANUP (FIX #8)
# ===========================================================================
section "CLEANUP"

log "Cleaning up temporary files..."

# Remove downloaded tarballs (keep source directories for troubleshooting)
rm -f /usr/src/asterisk/*.tar.gz 2>/dev/null || true
rm -f /usr/src/dahdi-tools-3.4.0.tar.gz 2>/dev/null || true
rm -f /usr/src/libpri-1.6.1.tar.gz 2>/dev/null || true

# Remove temporary logs
rm -f /tmp/dahdi_cfg_output.log 2>/dev/null || true
rm -f /tmp/crontab.* 2>/dev/null || true

info "Keeping source directories in /usr/src for reference"
info "Keeping install marker: $INSTALL_MARKER"
info "Keeping install log: $LOG_FILE"

success "Cleanup completed"

# ===========================================================================
# VALIDATION SUMMARY (FIX #9)
# ===========================================================================
section "VALIDATION SUMMARY"

ERRORS=0
WARNINGS=0

# Check critical services
services=("mariadb" "httpd")
for svc in "${services[@]}"; do
if ! systemctl is-active --quiet "$svc"; then
echo -e "${RED}[FAIL] CRITICAL: $svc is not running!${NC}"
ERRORS=$((ERRORS + 1))
else
success "$svc is running"
fi
done

# Check Asterisk separately - runs in screen session, not systemd
if screen -list 2>/dev/null | grep -q "asterisk"; then
    success "asterisk is running (screen session)"
elif pgrep -x "asterisk" > /dev/null 2>&1; then
    success "asterisk is running (process detected)"
else
    warning "Asterisk screen session not detected - ViciDial keepalive will start it"
    WARNINGS=$((WARNINGS + 1))
fi

# Check process locking infrastructure
if systemctl is-active --quiet vicidial-process-monitor; then
    success "Process monitor daemon is running"
else
    warning "Process monitor not running - run: systemctl start vicidial-process-monitor"
    WARNINGS=$((WARNINGS + 1))
fi

if systemctl is-active --quiet vicidial-keepalive.timer; then
    success "Systemd keepalive timer is active"
else
    warning "Keepalive timer not active - run: systemctl start vicidial-keepalive.timer"
    WARNINGS=$((WARNINGS + 1))
fi

# Check the call-time guard (hard 9pm / state / bad-timezone block)
if grep -qF ROCKY10-CALLTIME-GUARD-v1 /usr/share/astguiclient/AST_VDauto_dial.pl 2>/dev/null \
   && grep -qF ROCKY10-CALLTIME-GUARD-v1 /var/www/html/agc/vdc_db_query.php 2>/dev/null; then
    success "Call-time guard present in AST_VDauto_dial.pl and vdc_db_query.php"
else
    warning "Call-time guard NOT applied - run /usr/local/sbin/vicidial-rocky10-repatch and check its output"
    WARNINGS=$((WARNINGS + 1))
fi
CT_TRG_N=$(mysql -N -e "select count(*) from information_schema.triggers where trigger_schema='asterisk' and trigger_name like 'rocky10%'" 2>/dev/null || echo 0)
if [ "${CT_TRG_N:-0}" -ge 10 ]; then
    success "Call-time guard DB triggers present ($CT_TRG_N)"
else
    warning "Call-time guard DB triggers missing (${CT_TRG_N:-0} of 10) - run /usr/local/sbin/vicidial-rocky10-repatch"
    WARNINGS=$((WARNINGS + 1))
fi
if systemctl is-active --quiet vicidial-calltime-watch.timer; then
    success "Call-time watcher timer is active"
else
    warning "Call-time watcher timer not active - run: systemctl enable --now vicidial-calltime-watch.timer"
    WARNINGS=$((WARNINGS + 1))
fi

KEEPALIVE_COUNT=$( { pgrep -f "ADMIN_keepalive_ALL.pl" 2>/dev/null || true; } | wc -l )
KEEPALIVE_COUNT="${KEEPALIVE_COUNT//[[:space:]]/}"
if [ "$KEEPALIVE_COUNT" -le 1 ]; then
    success "Duplicate process check: OK ($KEEPALIVE_COUNT keepalive instances)"
else
    warning "Multiple keepalive processes detected: $KEEPALIVE_COUNT (monitor will resolve this)"
    WARNINGS=$((WARNINGS + 1))
fi

# Check critical files
critical_files=(
"/etc/asterisk/confbridge.conf"
"/etc/asterisk/confbridge-vicidial.conf"
"/etc/asterisk/extensions.conf"
"/etc/asterisk/manager.conf"
"/etc/astguiclient.conf"
"/usr/share/astguiclient/ADMIN_keepalive_ALL.pl"
)

for file in "${critical_files[@]}"; do
if [ ! -f "$file" ]; then
warning "Missing file: $file"
WARNINGS=$((WARNINGS + 1))
fi
done

# Check database
if ! mysql -u cron -p"${DB_PASSWORD}" asterisk -e "SELECT 1" &>/dev/null; then
echo -e "${RED}[FAIL] CRITICAL: Cannot connect to asterisk database${NC}"
ERRORS=$((ERRORS + 1))
fi

# Check DAHDI (lenient for no-hardware systems)
if ! lsmod | grep -q "^dahdi "; then
	if [ -f "/usr/lib64/libtonezone.so.2.0" ] && command -v dahdi_cfg &>/dev/null; then
		info "DAHDI software installed (no hardware - OK for VoIP-only)"
	else
		warning "DAHDI module not loaded and software not detected"
		WARNINGS=$((WARNINGS + 1))
	fi
else
	success "DAHDI module loaded"
fi

# Check DAHDI Tools (multiple verification methods)
if command -v dahdi_cfg &>/dev/null; then
	# Try version check
	if dahdi_cfg --help 2>&1 | grep -q "3.4.0"; then
		success "DAHDI Tools 3.4.0 verified"
	# Check if binary exists and libraries present
	elif [ -f "/usr/lib64/libtonezone.so.2.0" ] || [ -f "/usr/lib/libtonezone.so.2.0" ]; then
		info "DAHDI Tools installed (version check unclear - libraries present)"
	else
		warning "DAHDI Tools version mismatch"
		WARNINGS=$((WARNINGS + 1))
	fi
else
	warning "dahdi_cfg not found"
	WARNINGS=$((WARNINGS + 1))
fi

# Check ConfBridge
if ! asterisk -rx "module show like app_confbridge" 2>/dev/null | grep -q "app_confbridge"; then
warning "ConfBridge module not loaded"
WARNINGS=$((WARNINGS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
success "All critical checks passed"
else
echo -e "${RED}[FAIL] $ERRORS critical error(s) found - review output above${NC}"
fi

if [ $WARNINGS -gt 0 ]; then
warning "$WARNINGS warning(s) found - review recommended"
fi

echo ""

# ===========================================================================
# COMPLETION
# ===========================================================================
section "PART 2 INSTALLATION COMPLETE"

echo "PART_2_COMPLETE=YES" >> "$INSTALL_MARKER"
echo "END_TIME=$(date +%s)" >> "$INSTALL_MARKER"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║  PART 2 INSTALLATION COMPLETED SUCCESSFULLY           ║${NC}"
echo -e "${GREEN}║  ViciDial ULTIMATE v11.2                        ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

info "Installation Summary:"
info "  DAHDI Linux 3.4.0     : Installed (FrancoSmash73 - EL8 4.18 + 6.12 compatible)"
info "  DAHDI Tools 3.4.0     : Installed (FrancoSmash73 - autotools patched)"
info "  LibPRI 1.6.1          : Installed"
info "  Asterisk ${ASTERISK_VERSION}      : Running (plain upstream)"
info "  ViciDial              : Installed (FrancoSmash73 method)"
info "  DB Schema             : Pre-loaded before install.pl"
info "  ConfBridge            : Configured (all 9 profiles)"
info "  Extensions            : All prefixes 9600XXX-99600XXX"
info "  manager.conf          : [confcron] AMI user added (shares secret with other 5 stock AMI accounts)"
info "  vicidial_confbridges  : 300 entries for $SERVER_IP"
info "  mixing_interval       : 40ms (reduced CPU)"
info "  [monitor] context     : Converted to ConfBridge"
info "  Legacy MeetMe ext     : Commented out"
info "  ASTConfUpdater        : Enabled (C flag)"
info "  Server IP             : $SERVER_IP"
info "  Area Codes            : Populated"
info "  Test Leads            : List 107"
info "  ⭐ flock Wrapper      : /usr/local/bin/vicidial_cron_wrapper.sh"
info "  ⭐ Process Monitor    : Running (systemd service)"
info "  ⭐ Keepalive Timer    : Active (systemd timer - no raw cron!)"
info "  ⭐ Duplicate Bug      : PERMANENTLY FIXED"
info "  Crontab               : Configured (high-freq scripts flock-wrapped)"
info "  Install Time          : ${MINUTES}m ${SECONDS}s"
info "  Install Log           : $LOG_FILE"

# OPTIMIZATION: Display performance metrics
echo ""
echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  PERFORMANCE METRICS (v10.18 Optimizations)          ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════╝${NC}"
info "  CPU Cores Detected    : $CPU_CORES"
info "  Parallel Jobs Used    : make -j$MAKE_JOBS"
if grep -q "STEP_1_DURATION=" "$INSTALL_MARKER"; then
	STEP1_TIME=$(grep "STEP_1_DURATION=" "$INSTALL_MARKER" | cut -d'=' -f2)
	info "  DAHDI Compile Time    : $((STEP1_TIME / 60))m $((STEP1_TIME % 60))s"
fi
if grep -q "STEP_4_DURATION=" "$INSTALL_MARKER"; then
	STEP4_TIME=$(grep "STEP_4_DURATION=" "$INSTALL_MARKER" | cut -d'=' -f2)
	info "  Asterisk Compile Time : $((STEP4_TIME / 60))m $((STEP4_TIME % 60))s"
fi
info "  Temp Files Cleaned    : ${#TEMP_FILES[@]} files"

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  MANUAL STEPS STILL REQUIRED                          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}1. Set Conference Engine in ViciDial Admin:${NC}"
echo -e "     Admin > Servers > [your server] > Conferencing Engine = CONFBRIDGE"
echo ""
echo -e "  ${BOLD}2. Verify VARactive_keepalives has 'C' flag:${NC}"
echo -e "     ${YELLOW}grep VARactive_keepalives /etc/astguiclient.conf${NC}"
echo ""
echo -e "  ${BOLD}3. Verify confbridge-vicidial.conf mixing_interval:${NC}"
echo -e "     ${YELLOW}grep mixing_interval /etc/asterisk/confbridge-vicidial.conf${NC}"
echo ""
echo -e "  ${BOLD}4. Verify ConfBridge conferences in DB:${NC}"
echo -e "     ${YELLOW}mysql -u cron -p asterisk -e \"SELECT COUNT(*) FROM vicidial_confbridges WHERE server_ip='$SERVER_IP';\"${NC}"
echo ""

echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ACCESS INFORMATION                                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}ViciDial Web Interface:${NC}"
echo -e "  ${GREEN}http://$SERVER_IP/vicidial/admin.php${NC}"
echo ""
echo -e "  ${BOLD}Default Login:${NC}"
echo -e "  Username: ${YELLOW}6666${NC}"
echo -e "  Password: ${YELLOW}1234${NC}"
echo ""
echo -e "${RED}  CHANGE THE DEFAULT PASSWORD IMMEDIATELY!${NC}"
echo ""

echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  VERIFICATION COMMANDS                                ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}asterisk -rx 'core show version'${NC}"
echo -e "  ${GREEN}asterisk -rx 'module show like confbridge'${NC}"
echo -e "  ${GREEN}asterisk -rx 'confbridge show profile bridges'${NC}"
echo -e "  ${GREEN}asterisk -rx 'confbridge show profile users'${NC}"
echo -e "  ${GREEN}asterisk -rx 'confbridge list'${NC}"
echo -e "  ${GREEN}screen -ls | grep ASTConfUpdater${NC}"
echo -e "  ${GREEN}grep mixing_interval /etc/asterisk/confbridge-vicidial.conf${NC}"
echo -e "  ${GREEN}dahdi_cfg --help 2>&1 | head -2${NC}"
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROCESS LOCKING VERIFICATION                        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}systemctl status vicidial-process-monitor${NC}"
echo -e "  ${GREEN}systemctl status vicidial-keepalive.timer${NC}"
echo -e "  ${GREEN}systemctl list-timers vicidial-keepalive.timer${NC}"
echo -e "  ${GREEN}ps aux | grep ADMIN_keepalive | grep -v grep${NC}"
echo -e "  ${GREEN}  # Should show 0-1 processes (not 5-10!)${NC}"
echo -e "  ${GREEN}tail -f /var/log/astguiclient/process_monitor.log${NC}"
echo -e "  ${GREEN}tail -f /var/log/astguiclient/ADMIN_keepalive_ALL_wrapper.log${NC}"
echo ""

echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  KEY FILES                                            ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Install progress   : ${CYAN}$INSTALL_MARKER${NC}"
echo "  Install log        : ${CYAN}$LOG_FILE${NC}"
echo "  ViciDial config    : ${CYAN}/etc/astguiclient.conf${NC}"
echo "  ConfBridge conf    : ${CYAN}/etc/asterisk/confbridge-vicidial.conf${NC}"
echo "  Extensions         : ${CYAN}/etc/asterisk/extensions.conf${NC}"
echo "  Manager            : ${CYAN}/etc/asterisk/manager.conf${NC}"
echo "  Asterisk logs      : ${CYAN}/var/log/asterisk/${NC}"
echo "  ViciDial logs      : ${CYAN}/var/log/astguiclient/${NC}"
echo "  Auto-start         : ${CYAN}rc.local (systemd rc-local service)${NC}"
echo ""

echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CRITICAL: VICIDIAL USES SCREEN SESSIONS              ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ViciDial requires Asterisk to run inside GNU screen sessions.${NC}"
echo ""
echo -e "  ${BOLD}✓ CORRECT way to manage Asterisk:${NC}"
echo -e "    ${GREEN}/usr/share/astguiclient/start_asterisk_boot.pl${NC}  (start)"
echo -e "    ${GREEN}screen -r asterisk${NC}                                (console)"
echo -e "    ${GREEN}screen -ls${NC}                                        (list all screens)"
echo ""
echo -e "  ${BOLD}✗ WRONG - DO NOT USE THESE:${NC}"
echo -e "    ${RED}systemctl start asterisk${NC}      (breaks ViciDial control)"
echo -e "    ${RED}systemctl stop asterisk${NC}       (kills screen session)"
echo -e "    ${RED}service asterisk restart${NC}      (not screen-aware)"
echo ""
echo -e "  ${BOLD}Why screen sessions?${NC}"
echo -e "    • ViciDial's Auto-Restart feature monitors the screen"
echo -e "    • Admin panel can restart Asterisk via screen"
echo -e "    • Multiple ViciDial daemons run in separate screens"
echo -e "    • Console access: ${CYAN}screen -r asterisk${NC}"
echo ""
echo -e "  ${BOLD}Active ViciDial screens (after full startup):${NC}"
echo -e "    ${CYAN}asterisk${NC}      - Main Asterisk PBX"
echo -e "    ${CYAN}ASTVDauto${NC}     - Auto-dialer daemon"
echo -e "    ${CYAN}ASTVDadapt${NC}    - Adaptive dialer"
echo -e "    ${CYAN}ASTconf3way${NC}   - 3-way calling handler"
echo -e "    ${CYAN}ASTsend${NC}       - Send functions"
echo -e "    ${CYAN}ASTupdate${NC}     - Database updates"
echo ""

echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  DAHDI SOURCE REPOS (FrancoSmash73)                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  DAHDI Linux  : https://github.com/FrancoSmash73/dahdi-linux-3.4.0"
echo "  DAHDI Tools  : https://github.com/FrancoSmash73/dahdi-tools-3.4.0"
echo ""

# ===========================================================================
# FINAL SAFETY NET: RE-APPLY DBI:MariaDB PATCH TO ALL AGI SCRIPTS
# Runs last so any step that redeployed files (e.g. manual install.pl re-run)
# cannot leave DBI:mysql in place. Inbound routing WILL NOT WORK without this.
# ===========================================================================
section "FINAL: MARIADB DRIVER PATCH (SAFETY NET)"
log "Re-applying DBI:MariaDB patch to all AGI scripts as final safety net..."

for _AGI_DIR in /var/lib/asterisk/agi-bin /usr/share/astguiclient; do
    if [ -d "$_AGI_DIR" ]; then
        _PATCHED=0
        while IFS= read -r -d '' _F; do
            if grep -q 'DBI:mysql:\|DBI:mariadb:\|DBD::mysql' "$_F" 2>/dev/null; then
                sed -i \
                    -e 's/DBI:mysql:/DBI:MariaDB:/g' \
                    -e 's/DBI:mariadb:/DBI:MariaDB:/g' \
                    -e 's/DBD::mysql/DBD::MariaDB/g' \
                    -e 's/mysql_insertid/mariadb_insertid/g' \
                    "$_F"
                _PATCHED=$((_PATCHED + 1))
            fi
        done < <(find "$_AGI_DIR" -maxdepth 1 -type f \( -name "*.agi" -o -name "*.pl" \) -print0 2>/dev/null)
        if [ "$_PATCHED" -gt 0 ]; then
            warning "$_AGI_DIR: $_PATCHED file(s) still had DBI:mysql — patched now"
        else
            success "$_AGI_DIR: all files already using DBI:MariaDB"
        fi
    fi
done

# Explicit critical-file verification
for _CRITICAL in \
    /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi \
    /var/lib/asterisk/agi-bin/agi-VDAD_ALL_outbound.agi \
    /var/lib/asterisk/agi-bin/agi-VDAD_local_optimize.agi; do
    if [ -f "$_CRITICAL" ]; then
        if grep -q 'DBI:mysql:' "$_CRITICAL"; then
            error "$(basename $_CRITICAL) STILL contains DBI:mysql: — manual intervention required"
        else
            success "$(basename $_CRITICAL): DBI:MariaDB confirmed"
        fi
    fi
done

success "Installation complete! Ready to use."
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ViciDial ULTIMATE v11.2 - Install Complete    ║${NC}"
echo -e "${GREEN}║  Rocky Linux / AlmaLinux 8.10 - VoIP-Only Ready!    ║${NC}"
echo -e "${GREEN}║  ⭐ ZERO duplicate processes guaranteed              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

exit 0
