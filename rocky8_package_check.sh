#!/bin/bash
################################################################################
# rocky8_package_check.sh — one-command package availability check
#
# Run this on a fresh Rocky/AlmaLinux 8.10 box BEFORE Part 1. It checks every
# dnf package the installer asks for (Parts 1-4, dynportal, Asterisk build
# deps) and prints only what's missing, so there's nothing to copy and paste.
#
# It adds the same repos Part 1 adds (EPEL, PowerTools, Remi), because many
# packages only exist there. That's harmless: Part 1 does exactly the same.
# Nothing else is installed or changed.
#
# Usage:  bash rocky8_package_check.sh
################################################################################

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
source /etc/os-release
echo "OS: $PRETTY_NAME"
if [[ ! "$VERSION_ID" =~ ^8\.([0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" -lt 10 ]; then
    echo -e "${YELLOW}WARNING: this build targets 8.10+; you have $VERSION_ID. Run 'dnf update' and reboot first.${NC}"
fi

echo "Setting up repos (same as Part 1)..."
dnf install -y -q epel-release dnf-plugins-core || echo -e "${RED}epel-release / dnf-plugins-core install failed (see above)${NC}"
dnf config-manager --set-enabled powertools || echo -e "${RED}could not enable powertools (see above)${NC}"
rpm -q remi-release >/dev/null 2>&1 || \
    dnf install -y -q https://rpms.remirepo.net/enterprise/remi-release-8.rpm || \
    echo -e "${RED}remi-release-8 install failed (see above)${NC}"
dnf makecache || echo -e "${RED}dnf makecache failed (see above)${NC}"

# Every repo the installer pulls from must be enabled, or packages that only
# live there would show up as "missing" for the wrong reason.
MISSING_REPOS=()
_enabled=$(dnf -q repolist --enabled 2>/dev/null | awk 'NR>1 {print $1}')
for r in baseos appstream powertools epel remi-safe remi-modular; do
    grep -qx "$r" <<<"$_enabled" || MISSING_REPOS+=("$r")
done
if [ ${#MISSING_REPOS[@]} -gt 0 ]; then
    echo -e "${RED}Repos not enabled: ${MISSING_REPOS[*]} - results below will be incomplete${NC}"
fi

# Sanity check: if dnf can't even find bash, every lookup below would come
# back empty and the "missing" list would be meaningless. Show the real error
# and stop instead.
_q() { dnf -q repoquery --disable-modular-filtering --latest-limit 1 --whatprovides "$1"; }
if ! _sanity=$(_q bash 2>&1) || ! grep -q '^bash-' <<<"$_sanity"; then
    echo ""
    echo -e "${RED}dnf can't query the repos, so this check can't run. dnf said:${NC}"
    echo "$_sanity"
    echo ""
    echo "Enabled repos:"
    dnf repolist
    echo ""
    echo "Paste everything above back to Claude."
    exit 1
fi

# Module streams the installer enables
echo ""
echo "Module streams:"
for want in "mariadb 10.11" "php remi-8.3" "perl-App-cpanminus "; do
    mod="${want%% *}"; stream="${want#* }"
    if dnf -q module list "$mod" 2>/dev/null | grep -qE "^${mod}\s+${stream}"; then
        echo -e "  ${GREEN}OK${NC}       ${mod}:${stream:-default}"
    else
        echo -e "  ${RED}MISSING${NC}  ${mod}:${stream:-default}"
    fi
done

# Every package name the installer passes to dnf (Parts 1-4 + dynportal) plus
# what Asterisk 20's install_prereq pulls on RHEL-family systems.
PKGS=(
  # Part 1 — base / build
  gcc gcc-c++ make automake autoconf libtool kernel-devel kernel-headers
  openssl-devel zlib-devel wget curl git tar bzip2 unzip patch pkgconfig
  glibc-headers glibc-devel python3 dnf-plugins-core
  # Part 1 — PHP (Remi 8.3)
  php php-cli php-common php-fpm php-devel php-gd php-mbstring php-mysqlnd
  php-xml php-opcache php-process php-pear php-curl php-ldap php-zip
  php-fileinfo php-imap php-odbc php-soap php-bcmath php-intl php-json
  # Part 1 — web / DB
  httpd mod_ssl mariadb-server mariadb mariadb-devel mariadb-connector-c-devel
  # Part 1 — Perl (dnf; Part 1 falls back to cpanm for the optional ones)
  perl perl-devel perl-CPAN perl-ExtUtils-MakeMaker perl-ExtUtils-Manifest
  perl-DBI perl-libwww-perl perl-Time-HiRes perl-Digest-MD5 perl-Digest-SHA
  perl-IO-Socket-SSL perl-LWP-Protocol-https perl-Archive-Zip perl-HTML-Parser
  perl-MailTools perl-Compress-Raw-Zlib perl-App-cpanminus
  perl-core perl-Text-CSV_XS perl-Spreadsheet-ParseExcel perl-HTML-Tree
  perl-Net-Server perl-MIME-tools perl-Mail-Sendmail
  # Part 1 — system
  tuned fail2ban fail2ban-systemd chrony firewalld
  # Part 2 — tools
  subversion patch screen libtool-ltdl-devel
  # Asterisk 20 install_prereq (RHEL family)
  libedit-devel jansson-devel libuuid-devel sqlite-devel libxml2-devel
  ncurses-devel newt-devel libsrtp-devel unixODBC-devel libcurl-devel
  speex-devel speexdsp-devel libogg-devel libvorbis-devel opus-devel
  net-snmp-devel libical-devel spandsp-devel uriparser-devel
  # Part 4 — WebRTC / TLS
  certbot python3-certbot-apache
  # dynportal
  ipset conntrack-tools sqlite
)

echo ""
echo "Checking ${#PKGS[@]} packages..."
MISSING=()
for p in "${PKGS[@]}"; do
    # --whatprovides so names that are virtual on Rocky 8 still count
    # (pkgconfig -> pkgconf-pkg-config, python3 -> python36).
    if ! _q "$p" 2>/dev/null | grep -q . \
       && ! rpm -q --whatprovides "$p" >/dev/null 2>&1; then
        MISSING+=("$p")
    fi
done

echo ""
if [ ${#MISSING[@]} -eq 0 ]; then
    echo -e "${GREEN}All ${#PKGS[@]} packages are available.${NC}"
else
    echo -e "${RED}${#MISSING[@]} of ${#PKGS[@]} packages not found:${NC}"
    printf '  %s\n' "${MISSING[@]}"
    echo ""
    echo "Paste just the lines above back to Claude."
fi
if [ ${#MISSING_REPOS[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}INCOMPLETE: these repos were not enabled, so packages from them may be listed as missing: ${MISSING_REPOS[*]}${NC}"
    echo "Paste the repo errors from the top of the output too."
    exit 1
fi
