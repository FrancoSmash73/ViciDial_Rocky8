#!/bin/bash
################################################################################
# ViciDial ULTIMATE Installation - Part 1 v1.3
# Foundation: Dependencies, Database, Web Server, Perl Modules
#
# Created: February 16, 2026
# Updated: 2026-02-25
# Author: Frank Mac + Claude (Anthropic)
# Target: Rocky Linux 10.x / AlmaLinux 10.x
#
# FEATURES:
# ✅ Native perl-DBD-MariaDB (NOT perl-DBD-MySQL)
# ✅ MariaDB 10.11 from native Rocky repos
# ✅ PHP 8.3 from Remi repository
# ✅ Progress tracking with resume capability
# ✅ Comprehensive error handling
# ✅ Security hardening
# ✅ Complete verification suite
# ✅ NO sketchy downloads or untrusted sources
#
# CHANGELOG v1.3 (2026-02-25):
# ✅ Version sync with Part 2 v11.2 release
# ✅ Fixed header version mismatch (header said v1.1, code was v1.2)
# ℹ️  No AGI/DBI changes needed in Part 1 — Part 1 runs on Server 1 (DB/Web)
#    DBI:MariaDB safety-net patch lives in Part 2 (Asterisk server)
#
# CHANGELOG v1.1 (2026-02-17):
# ✅ Fixed MariaDB installation (use native Rocky packages)
# ✅ Fixed MariaDB root password setting on fresh install
# ✅ Fixed bash arithmetic for buffer calculation (no bc required)
# ✅ Fixed CPAN module installation (use cpanm)
# ✅ Fixed String::CRC incompatibility (use String::CRC32)
# ✅ Fixed DBD::MariaDB build (add Devel::CheckLib)
# ✅ Added credential persistence for verification
#
# CHANGELOG v1.2 (2026-02-18):
# ✅ Added perl-MIME-tools (fixes AST_inbound_email_parser.pl MIME::Decoder error)
# ✅ Fixed chrony makestep 1.0 -1 (clock steps immediately after reboot)
# ✅ Added chronyd auto-restart drop-in (prevents NTP drift after stop)
# ✅ Added tuned install + latency-performance profile (VoIP optimization)
# ✅ Added fail2ban install + SSH/Asterisk/Apache jail config (security)
# ✅ Added vici-status.sh server health check script
################################################################################

set -euo pipefail

# Error handler
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

handle_error() {
    echo -e "\n${RED}╔═════════════════════════════════════${NC}"
    echo -e "${RED}║  ERROR on line $1                     ${NC}"
    echo -e "${RED}║  Command: $2                          ${NC}"
    echo -e "${RED}║  Installation failed!                 ${NC}"
    echo -e "${RED}╚═════════════════════════════════════${NC}\n"
    exit 1
}

################################################################################
# CONFIGURATION
################################################################################

VERSION="1.3"
SCRIPT_NAME="ViciDial ULTIMATE Part 1"
START_TIME=$(date +%s)

# Load shared version config (PHP_VERSION, ASTERISK_VICI_VERSION) — falls back
# to known-good defaults if this script was copied out on its own.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$SCRIPT_DIR/configs/versions.conf" ]; then
    # shellcheck source=configs/versions.conf
    source "$SCRIPT_DIR/configs/versions.conf"
else
    echo "[WARNING] configs/versions.conf not found — using built-in defaults" >&2
    PHP_VERSION="8.3"
fi

# Progress tracking
PROGRESS_FILE="/root/.vicidial_ultimate_part1_progress"
INSTALL_MARKER="/root/vicidial_ultimate_install.conf"
CREDS_FILE="/root/.vicidial_ultimate_credentials"

# Parallel compilation
CPU_CORES=$(nproc)
MAKE_JOBS=$((CPU_CORES > 1 ? CPU_CORES : 2))

# Logging
LOG_FILE="/var/log/vicidial_ultimate_part1.log"
exec > >(tee -a "$LOG_FILE") 2>&1

################################################################################
# COLORS & LOGGING
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

section() {
    echo -e "\n${BLUE}${BOLD}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║ $1${NC}"
    echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════╝${NC}\n"
}

################################################################################
# PROGRESS TRACKING FUNCTIONS
################################################################################

init_progress() {
    if [ ! -f "$PROGRESS_FILE" ]; then
        touch "$PROGRESS_FILE"
    fi
    if [ ! -f "$INSTALL_MARKER" ]; then
        echo "INSTALL_START_TIME=$(date +%s)" > "$INSTALL_MARKER"
        echo "SCRIPT_VERSION=$VERSION" >> "$INSTALL_MARKER"
    fi
}

mark_complete() {
    local section=$1
    if ! grep -q "^${section}=COMPLETE$" "$PROGRESS_FILE" 2>/dev/null; then
        echo "${section}=COMPLETE" >> "$PROGRESS_FILE"
    fi
}

is_complete() {
    local section=$1
    grep -q "^${section}=COMPLETE$" "$PROGRESS_FILE" 2>/dev/null
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Wait for service to be active
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

# Generate secure random password
generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
}


################################################################################
# BANNER
################################################################################

clear
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                                                           ║"
echo "║        ViciDial ULTIMATE Installation - Part 1            ║"
echo "║          Foundation & Dependencies Setup                  ║"
echo "║                                                           ║"
echo "║       Version $VERSION - Rocky/AlmaLinux 10.x                  ║"
echo "║                                                           ║"
echo "║  NO sketchy downloads | NO hardcoded passwords            ║"
echo "║  Native MariaDB driver | Professional security            ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

################################################################################
# PRE-FLIGHT CHECKS
################################################################################

section "PRE-FLIGHT SYSTEM CHECKS"

# Root check
if [ "$EUID" -ne 0 ]; then
    error "Please run as root (use: sudo su -)"
fi

# OS Check
if [ ! -f /etc/os-release ]; then
    error "Cannot detect OS: /etc/os-release not found"
fi

source /etc/os-release

if [[ "$ID" != "rocky" && "$ID" != "almalinux" ]]; then
    error "This script requires Rocky Linux or AlmaLinux 10.x (Detected: $PRETTY_NAME)"
fi

if [[ ! "$VERSION_ID" =~ ^10\. ]]; then
    error "This script requires Rocky/AlmaLinux 10.x (Detected: $VERSION_ID)"
fi

OS_NAME="$NAME"
OS_VERSION="$VERSION_ID"
success "OS Check: $OS_NAME $OS_VERSION"

# Internet check
if ! ping -c 1 8.8.8.8 &> /dev/null; then
    error "No internet connection detected"
fi
success "Internet connectivity OK"

# Disk space check (need at least 20GB free)
FREE_SPACE=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$FREE_SPACE" -lt 20 ]; then
    error "Insufficient disk space. Need 20GB free, have ${FREE_SPACE}GB"
fi
success "Disk space OK: ${FREE_SPACE}GB free"

# RAM check (need at least 4GB)
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 4 ]; then
    warning "Low RAM detected: ${TOTAL_RAM}GB (8GB+ recommended)"
else
    success "RAM OK: ${TOTAL_RAM}GB"
fi

# CPU check
CPU_CORES=$(nproc)
success "CPU cores: $CPU_CORES"

################################################################################
# USER INPUT
################################################################################

section "CONFIGURATION"

# Get server IP
if [ -z "${SERVER_IP:-}" ]; then
    DEFAULT_IP=$(hostname -I | awk '{print $1}')
    while true; do
        read -p "Enter server IP address [$DEFAULT_IP]: " SERVER_IP </dev/tty
        SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"
        if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "Invalid IP. Please enter a valid IPv4 address."
        fi
    done
fi

echo "SERVER_IP=$SERVER_IP" >> "$INSTALL_MARKER"
success "Server IP: $SERVER_IP"

# Installation mode
if [ -z "${INSTALL_MODE:-}" ]; then
    echo ""
    echo "Installation Mode:"
    echo "  [1] Standalone (single server)"
    echo "  [2] Cluster (multi-server environment)"
    while true; do
        read -p "Select mode [1]: " MODE_CHOICE </dev/tty
        MODE_CHOICE="${MODE_CHOICE:-1}"
        if [[ "$MODE_CHOICE" == "1" || "$MODE_CHOICE" == "2" ]]; then
            break
        else
            echo "Invalid choice. Enter 1 or 2."
        fi
    done
    if [ "$MODE_CHOICE" == "2" ]; then
        INSTALL_MODE="cluster"
    else
        INSTALL_MODE="standalone"
    fi
fi

echo "INSTALL_MODE=$INSTALL_MODE" >> "$INSTALL_MARKER"
success "Installation mode: $INSTALL_MODE"

# Cluster: get Asterisk server IP
if [ "$INSTALL_MODE" == "cluster" ]; then
    while true; do
        read -p "Enter Asterisk server IP address (e.g. 172.235.34.224): " ASTERISK_SERVER_IP </dev/tty
        if [[ "$ASTERISK_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "Invalid IP address. Please enter a valid IPv4 address."
        fi
    done
    echo "ASTERISK_SERVER_IP=$ASTERISK_SERVER_IP" >> "$INSTALL_MARKER"
    echo "ASTERISK_SERVER_IP=$ASTERISK_SERVER_IP" >> "$CREDS_FILE"
    success "Asterisk server IP: $ASTERISK_SERVER_IP"
fi

# MariaDB bind IP
if [ "$INSTALL_MODE" == "cluster" ]; then
    MARIADB_BIND_IP="0.0.0.0"
    warning "Cluster mode: MariaDB will listen on all interfaces (0.0.0.0)"
else
    MARIADB_BIND_IP="127.0.0.1"
    info "Standalone mode: MariaDB will listen on localhost only"
fi

echo "MARIADB_BIND_IP=$MARIADB_BIND_IP" >> "$INSTALL_MARKER"

################################################################################
# PASSWORD GENERATION
################################################################################
section "CREDENTIAL GENERATION"
# Generate secure passwords
MYSQL_ROOT_PASSWORD=$(generate_password)
DB_PASSWORD=$(generate_password)
CUSTOM_DB_PASSWORD=$(generate_password)
ASTERISK_SERVER_IP=${ASTERISK_SERVER_IP:-}

# Secure credential storage
cat > "$CREDS_FILE" << EOF
# ViciDial ULTIMATE Credentials
# Generated: $(date)
# KEEP THIS FILE SECURE!
# MariaDB Root
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
# ViciDial Database Users
DB_USER=cron
DB_PASSWORD=$DB_PASSWORD
DB_NAME=asterisk
CUSTOM_DB_USER=custom
CUSTOM_DB_PASSWORD=$CUSTOM_DB_PASSWORD
# Server Info
SERVER_IP=$SERVER_IP
INSTALL_MODE=$INSTALL_MODE
EOF
chmod 600 "$CREDS_FILE"

echo "INSTALL_MODE=$INSTALL_MODE" >> "$INSTALL_MARKER"
if [ "$INSTALL_MODE" == "cluster" ]; then
    read -p "Enter Asterisk server IP address: " ASTERISK_SERVER_IP
    echo "ASTERISK_SERVER_IP=$ASTERISK_SERVER_IP" >> "$INSTALL_MARKER"
    echo "ASTERISK_SERVER_IP=$ASTERISK_SERVER_IP" >> "$CREDS_FILE"
fi

success "Credentials generated and stored securely: $CREDS_FILE"
warning "SAVE THESE CREDENTIALS! File: $CREDS_FILE"
init_progress

################################################################################
# STEP 1: SYSTEM UPDATE & BASE PACKAGES
################################################################################

section "STEP 1/10: SYSTEM UPDATE"

if ! is_complete "SYSTEM_UPDATE"; then
    log "Updating system packages..."
    dnf update -y
    
    log "Installing EPEL release..."
    dnf install -y epel-release
    
    mark_complete "SYSTEM_UPDATE"
    success "System updated"
fi

################################################################################
# STEP 2: DEVELOPMENT TOOLS
################################################################################

section "STEP 2/10: DEVELOPMENT TOOLS"

if ! is_complete "DEV_TOOLS"; then
    log "Installing Development Tools..."
    dnf groupinstall "Development Tools" -y
    
    log "Installing essential build packages..."
    dnf install -y \
        gcc gcc-c++ make automake autoconf libtool \
        kernel-devel kernel-headers \
        openssl-devel zlib-devel wget curl git \
        tar bzip2 unzip patch pkgconfig \
        glibc-headers glibc-devel
    
    mark_complete "DEV_TOOLS"
    success "Development tools installed"
fi

################################################################################
# STEP 3: PHP 8.3 FROM REMI
################################################################################

section "STEP 3/10: PHP 8.3 INSTALLATION"

if ! is_complete "PHP_INSTALL"; then
    log "Adding Remi repository..."
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm
    
    log "Enabling CRB (CodeReady Builder) repository..."
    dnf config-manager --set-enabled crb
    
    log "Enabling PHP 8.3 module from Remi..."
    dnf module reset php -y
    dnf module enable "php:remi-${PHP_VERSION}" -y
    
    log "Installing PHP 8.3 and extensions..."
    dnf install -y \
        php php-cli php-common php-fpm \
        php-devel php-gd php-mbstring php-mysqlnd \
        php-xml php-opcache php-process php-pear \
        php-curl php-ldap php-zip php-fileinfo \
        php-imap php-odbc php-soap php-bcmath \
        php-intl php-json
    
    # Configure PHP for ViciDial
    log "Configuring PHP for ViciDial..."
    cat > /etc/php.d/99-vicidial.ini << 'EOF'
error_reporting = E_ALL & ~E_NOTICE
memory_limit = 448M
short_open_tag = On
max_execution_time = 3330
max_input_time = 3360
post_max_size = 448M
upload_max_filesize = 442M
default_socket_timeout = 3360
date.timezone = UTC
max_input_vars = 50000
mysqli.default_socket = /var/lib/mysql/mysql.sock
mysqli.reconnect = On
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.revalidate_freq = 60
display_errors = Off
log_errors = On
error_log = /var/log/php-fpm/error.log
EOF
    
    PHP_VERSION=$(php -v | head -1 | awk '{print $2}')
    success "PHP $PHP_VERSION installed and configured"
    mark_complete "PHP_INSTALL"
fi

################################################################################
# STEP 4: APACHE WEB SERVER
################################################################################

section "STEP 4/10: APACHE WEB SERVER"

if ! is_complete "APACHE_INSTALL"; then
    log "Installing Apache..."
    dnf install -y httpd mod_ssl
    
    # Security hardening
    log "Hardening Apache configuration..."
    cat >> /etc/httpd/conf/httpd.conf << 'EOF'

# ViciDial Ultimate Apache Configuration
ServerTokens Prod
ServerSignature Off
TraceEnable Off
CustomLog /dev/null common

# ViciDial specific aliases
Alias /RECORDINGS/MP3 "/var/spool/asterisk/monitorDONE/MP3/"
<Directory "/var/spool/asterisk/monitorDONE/MP3/">
    Options Indexes MultiViews
    AllowOverride None
    Require all granted
</Directory>
EOF
    
    systemctl enable httpd
    systemctl start httpd
    wait_for_service httpd
    
    mark_complete "APACHE_INSTALL"
    success "Apache installed and running"
fi

################################################################################
# STEP 5: MARIADB 10.11 INSTALLATION (NATIVE ROCKY PACKAGES)
################################################################################

section "STEP 5/10: MARIADB 10.11"

if ! is_complete "MARIADB_INSTALL"; then
    log "Installing MariaDB 10.11 from native Rocky repositories..."
    
    # Remove any existing MariaDB official repo if present
    rm -f /etc/yum.repos.d/mariadb.repo
    
    # Clean DNF cache to ensure we're using Rocky repos only
    dnf clean all
    
    # Install MariaDB from Rocky's native repositories
    dnf install -y mariadb-server mariadb mariadb-devel
    
    systemctl enable mariadb
    systemctl start mariadb
    wait_for_service mariadb
    
    mark_complete "MARIADB_INSTALL"
    success "MariaDB 10.11 installed"
fi

################################################################################
# STEP 6: MARIADB SECURITY & CONFIGURATION
################################################################################

section "STEP 6/10: MARIADB SECURITY"

if ! is_complete "MARIADB_SECURE"; then
    log "Securing MariaDB installation..."
    
    # Set root password (fresh install has no password)
    mysql -u root -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASSWORD}');"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"
    
    # Remove anonymous users
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';"
    
    # Remove remote root
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    
    # Drop test database
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    
    # Flush privileges
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"
    
    success "MariaDB secured"
    mark_complete "MARIADB_SECURE"
fi

################################################################################
# STEP 7: MARIADB OPTIMIZATION
################################################################################

section "STEP 7/10: MARIADB OPTIMIZATION"

if ! is_complete "MARIADB_CONFIG"; then
    log "Creating optimized MariaDB configuration..."
    
    # Backup original
    cp /etc/my.cnf /etc/my.cnf.original
    
    # Calculate RAM-based settings using bash arithmetic (no bc required)
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    INNODB_BUFFER=$((TOTAL_RAM_MB * 40 / 100))  # 40% of RAM
    
    cat > /etc/my.cnf.d/vicidial.cnf << EOF
[mariadb]
# Connection Settings (optimized for ViciDial)
max_connections = 400
max_allowed_packet = 32M
connect_timeout = 10
wait_timeout = 300
interactive_timeout = 300
max_connect_errors = 100000

# Character Set
character_set_server = utf8mb4
collation_server = utf8mb4_general_ci

# Storage Engine
default_storage_engine = InnoDB

# SQL Mode (ViciDial compatible)
sql_mode = "ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"

# Logging
log_error = /var/log/mariadb/mariadb.log
log_warnings = 2
slow_query_log = 1
slow_query_log_file = /var/log/mariadb/slow-queries.log
long_query_time = 1

# InnoDB Settings (optimized for ${TOTAL_RAM_MB}MB RAM)
innodb_buffer_pool_size = ${INNODB_BUFFER}M
innodb_log_file_size = 512M
innodb_log_buffer_size = 32M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# MyISAM Settings (legacy ViciDial tables)
key_buffer_size = 256M
myisam_sort_buffer_size = 64M

# Table Cache
table_open_cache = 2048
table_definition_cache = 1024

# Temporary Tables
tmp_table_size = 128M
max_heap_table_size = 128M

# Query Cache (disabled in MariaDB 10.11)
# query_cache_type = 0
# query_cache_size = 0

# Full-Text Search
ft_min_word_len = 3
ft_max_word_len = 84

# Bind Address
bind-address = ${MARIADB_BIND_IP}

[client]
port = 3306
socket = /var/lib/mysql/mysql.sock
default-character-set = utf8mb4
EOF
    
    # Create log directories
    mkdir -p /var/log/mariadb
    chown -R mysql:mysql /var/log/mariadb
    chmod 750 /var/log/mariadb
    
    # Restart with new config
    systemctl restart mariadb
    wait_for_service mariadb
    
    success "MariaDB optimized for ViciDial"
    mark_complete "MARIADB_CONFIG"
fi

################################################################################
# STEP 8: VICIDIAL DATABASE SETUP
################################################################################

if ! is_complete "VICIDIAL_DB"; then
    log "Creating asterisk database..."
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e \
        "CREATE DATABASE IF NOT EXISTS asterisk DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    log "Creating cron user and syncing password..."
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" << EOF
CREATE USER IF NOT EXISTS 'cron'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'cron'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'cron'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'cron'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON asterisk.* TO 'cron'@'127.0.0.1';
GRANT RELOAD ON *.* TO 'cron'@'127.0.0.1';
GRANT ALL PRIVILEGES ON asterisk.* TO 'cron'@'localhost';
GRANT RELOAD ON *.* TO 'cron'@'localhost';

CREATE USER IF NOT EXISTS 'custom'@'localhost' IDENTIFIED BY '${CUSTOM_DB_PASSWORD}';
ALTER USER 'custom'@'localhost' IDENTIFIED BY '${CUSTOM_DB_PASSWORD}';
GRANT SELECT,INSERT,UPDATE,DELETE ON asterisk.* TO 'custom'@'localhost';

FLUSH PRIVILEGES;
EOF

    # Cluster mode — add remote grants for Asterisk server
    if [ "$INSTALL_MODE" == "cluster" ] && [ -n "${ASTERISK_SERVER_IP:-}" ]; then
        log "Adding cluster grants for Asterisk server ${ASTERISK_SERVER_IP}..."
        mysql -u root -p"${MYSQL_ROOT_PASSWORD}" << EOF
CREATE USER IF NOT EXISTS 'cron'@'${ASTERISK_SERVER_IP}' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'cron'@'${ASTERISK_SERVER_IP}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON asterisk.* TO 'cron'@'${ASTERISK_SERVER_IP}';
GRANT RELOAD ON *.* TO 'cron'@'${ASTERISK_SERVER_IP}';

CREATE USER IF NOT EXISTS 'custom'@'${ASTERISK_SERVER_IP}' IDENTIFIED BY '${CUSTOM_DB_PASSWORD}';
ALTER USER 'custom'@'${ASTERISK_SERVER_IP}' IDENTIFIED BY '${CUSTOM_DB_PASSWORD}';
GRANT SELECT,INSERT,UPDATE,DELETE ON asterisk.* TO 'custom'@'${ASTERISK_SERVER_IP}';

FLUSH PRIVILEGES;
EOF
    fi

    # Verify connectivity
    if mysql -u cron -p"${DB_PASSWORD}" -e "SELECT VERSION();" asterisk >/dev/null 2>&1; then
        success "Database users created and verified"
    else
        error "Database user creation failed!"
    fi

    mark_complete "VICIDIAL_DB"
fi

################################################################################
# STEP 9: PERL MODULES (NATIVE MARIADB DRIVER)
################################################################################

section "STEP 9/10: PERL MODULES (Native MariaDB)"

if ! is_complete "PERL_MODULES"; then
    log "Installing Perl base packages..."
    dnf install -y \
        perl perl-core perl-devel perl-CPAN \
        perl-ExtUtils-MakeMaker perl-ExtUtils-Manifest \
        perl-DBI perl-libwww-perl perl-Time-HiRes \
        perl-Digest-MD5 perl-Digest-SHA perl-IO-Socket-SSL \
        perl-LWP-Protocol-https perl-Text-CSV_XS \
        perl-Spreadsheet-ParseExcel perl-Archive-Zip \
        perl-HTML-Parser perl-HTML-Tree perl-MailTools \
        perl-Net-Server perl-Compress-Raw-Zlib \
        perl-MIME-tools \
	perl-DBD-MariaDB

    
    
    log "Configuring CPAN for non-interactive use..."
    # Auto-configure CPAN on first run
    (echo y; echo o conf prerequisites_policy follow; echo o conf commit) | cpan
    
    log "Installing CPAN modules..."
    # Use cpanm for better non-interactive installation
    dnf install -y perl-App-cpanminus || cpan App::cpanminus

    log "Installing NATIVE DBD::MariaDB driver from source..."
    cd /usr/src
    rm -rf DBD-mariadb 2>/dev/null || true
    git clone https://github.com/perl5-dbi/DBD-mariadb.git
    cd DBD-mariadb
    export MYSQL_CONFIG=/usr/bin/mariadb_config

    cpanm --notest Spreadsheet::Read Spreadsheet::WriteExcel Spreadsheet::XLSX \
                Spreadsheet::ReadSXC OLE::Storage_Lite Text::CSV Text::CSV_PP \
                Net::Telnet Mail::Sendmail Mail::POP3Client Mail::IMAPClient \
                Mail::Message HTML::Entities HTML::Strip HTML::FormatText \
                Net::Address::IP::Local Net::Address::IPv4::Local String::CRC32 \
                Proc::ProcessTable File::Temp Scalar::Util IO::Scalar DBD::MariaDB \
                Switch

    # DBD::mysql v5.x fails to compile against MariaDB headers — pin to 4.052
    cpanm --notest DBD::mysql@4.052

    # Asterisk::AGI required for ViciDial survey/IVR AGI scripts
    cpanm --notest Asterisk::AGI

    # Install build dependencies first
    cpanm --notest Devel::CheckLib

    perl Makefile.PL --mysql_config=/usr/bin/mariadb_config
    make
    make install

    # Verify installation
    if perl -MDBD::MariaDB -e 'print "DBD::MariaDB version: $DBD::MariaDB::VERSION\n"'; then
        success "Native DBD::MariaDB installed successfully"
    else
        error "DBD::MariaDB installation failed!"
    fi

    # ---------------------------------------------------------------------------
    # DBD::mysql 4.052 — required for ViciDial AGI scripts on Rocky Linux 10
    # ViciDial AGI scripts (agi-VDAD_ALL_outbound.agi, agi-VDAD_local_optimize.agi,
    # etc.) use DBI:mysql: directly. DBD::mysql v5.x fails to compile against
    # MariaDB client headers (missing MySQL-only symbols like
    # mysql_real_escape_string_quote, MYSQL_OPT_SSL_MODE, etc.).
    # v4.052 compiles cleanly and coexists safely with DBD::MariaDB.
    # Without this, AGI scripts silently fail at DB connect → no call routing.
    # ---------------------------------------------------------------------------
    log "Installing DBD::mysql 4.052 for ViciDial AGI script compatibility..."
    cpanm --notest DVEEDEN/DBD-mysql-4.052.tar.gz && \
        success "DBD::mysql 4.052 installed" || \
        warning "DBD::mysql 4.052 install failed — AGI scripts may fail if not patched to MariaDB"

    mark_complete "PERL_MODULES"
fi

################################################################################
# STEP 10: SYSTEM CONFIGURATION
################################################################################

section "STEP 10/10: SYSTEM CONFIGURATION"

if ! is_complete "SYSTEM_CONFIG"; then
    # SELinux
    log "Disabling SELinux (required for ViciDial)..."
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    
    # Firewall
    log "Configuring firewall..."
    systemctl enable firewalld
    systemctl start firewalld
    
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=5060/udp  # SIP
    firewall-cmd --permanent --add-port=10000-20000/udp  # RTP
    firewall-cmd --permanent --add-port=446/tcp  # ViciDial
    firewall-cmd --reload
    
    # System limits
    log "Configuring system limits..."
    cat > /etc/security/limits.d/asterisk.conf << 'EOF'
asterisk soft nofile 65536
asterisk hard nofile 65536
asterisk soft nproc 32768
asterisk hard nproc 32768
* soft nofile 20000
* hard nofile 20000
EOF
    
    # Sysctl tuning
    log "Tuning kernel parameters..."
    cat > /etc/sysctl.d/99-vicidial.conf << 'EOF'
# Network tuning for VoIP
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Connection tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# Kernel tuning
kernel.shmmax = 67108864
kernel.shmall = 4294967296
EOF
    
    sysctl -p /etc/sysctl.d/99-vicidial.conf >/dev/null 2>&1
    
    # Create web directories
    log "Creating web directories..."
    mkdir -p /var/www/html/vicidial
    mkdir -p /var/www/html/agc
    chown -R apache:apache /var/www/html

    # Chrony: always step-correct clock on large offset (fixes health page red after reboot)
    log "Configuring chrony for immediate clock correction..."
    if [ -f /etc/chrony.conf ]; then
        sed -i 's/^makestep.*/makestep 1.0 -1/' /etc/chrony.conf
        success "chrony makestep set to 1.0 -1 (always steps on offset > 1s)"
    fi

    # Chronyd auto-restart drop-in (prevents clock drift if chronyd stops)
    log "Adding chronyd auto-restart drop-in..."
    mkdir -p /etc/systemd/system/chronyd.service.d/
    cat > /etc/systemd/system/chronyd.service.d/restart.conf << 'EOF'
[Service]
Restart=always
RestartSec=30
EOF
    systemctl daemon-reload
    systemctl restart chronyd
    success "chronyd configured with Restart=always"

    # Tuned: latency-performance profile for VoIP
    log "Installing tuned for VoIP latency optimization..."
    dnf install -y tuned
    systemctl enable --now tuned
    tuned-adm profile latency-performance
    success "tuned active with latency-performance profile"

    # Fail2ban: SSH, Asterisk, Apache protection
    log "Installing fail2ban for security hardening..."
    dnf install -y fail2ban fail2ban-systemd
    cat > /etc/fail2ban/jail.d/vicidial.conf << 'EOF'
[sshd]
enabled  = true
maxretry = 5
bantime  = 3600
findtime = 600

[asterisk]
enabled  = true
maxretry = 5
bantime  = 86400
findtime = 600
logpath  = /var/log/asterisk/messages

[apache-auth]
enabled  = true
maxretry = 5
bantime  = 3600
findtime = 600
EOF
    systemctl enable --now fail2ban
    success "fail2ban installed with SSH/Asterisk/Apache jails"

    # ViciDial server status script
    log "Creating vici-status.sh health check script..."
    cat > /usr/local/bin/vici-status.sh << 'EOF'
#!/bin/bash
echo "========================================="
echo "  VICIDIAL SERVER STATUS - $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="

# Asterisk runs in a GNU screen session on this install, NOT systemd --
# asterisk.service is intentionally masked (Part 2) to prevent a second
# instance from binding UDP 5060 alongside the screen-managed process.
# `systemctl is-active asterisk` will ALWAYS show inactive/masked here even
# when Asterisk is perfectly healthy, so check the screen session + a live
# CLI response instead.
if screen -ls 2>/dev/null | grep -q '\.asterisk\b' && asterisk -rx "core show version" 2>/dev/null | grep -q "^Asterisk "; then
    printf "  %-35s [\e[32m OK \e[0m]\n" "asterisk"
else
    printf "  %-35s [\e[31mFAIL\e[0m] (not running in screen session)\n" "asterisk"
fi

services=(
    "mariadb"
    "httpd"
    "php-fpm"
    "dahdi"
    "chronyd"
    "rc-local"
    "vicidial-keepalive.timer"
    "vicidial-process-monitor"
    "tuned"
    "fail2ban"
)
for svc in "${services[@]}"; do
    status=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$status" = "active" ]; then
        printf "  %-35s [\e[32m OK \e[0m]\n" "$svc"
    else
        printf "  %-35s [\e[31mFAIL\e[0m] ($status)\n" "$svc"
    fi
done
echo "========================================="
EOF
    chmod +x /usr/local/bin/vici-status.sh
    # Add to login profile so it shows on every SSH session
    echo '/usr/local/bin/vici-status.sh' > /etc/profile.d/vici-status.sh
    chmod +x /etc/profile.d/vici-status.sh
    success "vici-status.sh installed — runs automatically on SSH login"

    mark_complete "SYSTEM_CONFIG"
    success "System configured"
fi

################################################################################
# VERIFICATION
################################################################################

section "POST-INSTALL VERIFICATION"

# Load credentials for verification
if [ -f "$CREDS_FILE" ]; then
    source "$CREDS_FILE"
else
    error "Credentials file not found! Cannot verify installation."
fi

ERRORS=0

# Test MariaDB
if systemctl is-active --quiet mariadb; then
    success "✅ MariaDB service running"
else
    error "❌ MariaDB not running!"
fi

# Test Apache
if systemctl is-active --quiet httpd; then
    success "✅ Apache service running"
else
    error "❌ Apache not running!"
fi

# Test PHP
if php -v >/dev/null 2>&1; then
    PHP_VERSION=$(php -v | head -1 | awk '{print $2}')
    success "✅ PHP $PHP_VERSION installed"
else
    error "❌ PHP not working!"
fi

# Test Perl DBI
if perl -MDBI -e 'exit 0' 2>/dev/null; then
    success "✅ Perl DBI module OK"
else
    error "❌ Perl DBI module failed!"
fi

# Test DBD::MariaDB (CRITICAL!)
if perl -MDBD::MariaDB -e 'exit 0' 2>/dev/null; then
    DBD_VERSION=$(perl -MDBD::MariaDB -e 'print $DBD::MariaDB::VERSION')
    success "✅ Perl DBD::MariaDB $DBD_VERSION OK (Native driver!)"
else
    error "❌ Perl DBD::MariaDB module failed!"
fi

# Test database connectivity
if mysql -u cron -p"${DB_PASSWORD}" -e "SELECT VERSION();" asterisk >/dev/null 2>&1; then
    MYSQL_VER=$(mysql -u cron -p"${DB_PASSWORD}" -e "SELECT VERSION();" asterisk 2>/dev/null | tail -1)
    success "✅ Database auth working (cron user) - MariaDB $MYSQL_VER"
else
    error "❌ Database authentication failed (cron user)!"
fi

if [ $ERRORS -gt 0 ]; then
    error "Verification found $ERRORS error(s)!"
fi

success "All critical verification tests passed!"

################################################################################
# COMPLETION
################################################################################

section "PART 1 INSTALLATION COMPLETE"

echo "PART_1_COMPLETE=YES" >> "$INSTALL_MARKER"
echo "END_TIME=$(date +%s)" >> "$INSTALL_MARKER"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║  ✅  PART 1 INSTALLATION COMPLETED SUCCESSFULLY       ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

info "Installation Summary:"
info "- OS: $OS_NAME $OS_VERSION"
info "- Mode: $INSTALL_MODE"
info "- MariaDB 10.11: Running (bind: $MARIADB_BIND_IP)"
info "- PHP 8.3: Installed"
info "- Apache: Running"
info "- ⭐ Perl DBD::MariaDB: Installed & Verified (Native driver!)"
info "- Firewall: Configured"
info "- Time: ${MINUTES}m ${SECONDS}s"

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DATABASE CREDENTIALS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Saved: $CREDS_FILE${NC}"
echo -e "${RED}  COPY THESE CREDENTIALS NOW!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  NEXT STEPS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. Save credentials:"
echo "     ${YELLOW}cat $CREDS_FILE${NC}"
echo ""
echo "  2. Run Part 2:"
echo "     ${GREEN}./ViciDial_ULTIMATE_Part2.sh${NC}"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

success "Marker: $INSTALL_MARKER"
success "Credentials: $CREDS_FILE"
success "Log: $LOG_FILE"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete! Ready for Part 2          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

exit 0
