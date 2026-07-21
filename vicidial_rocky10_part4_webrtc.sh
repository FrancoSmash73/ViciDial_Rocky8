#!/usr/bin/env bash
# =============================================================================
# ViciDial Rocky Linux 10 — Part 4: WebRTC, SSL & HulkPhone Webphone
# =============================================================================
# Run AFTER Part 2 and Part 3.
#
# What this script does:
#   1. Configures Asterisk HTTP server for WSS (port 8088 plain, 8089 TLS)
#   2. Adds transport-wss to pjsip.conf
#   3. Obtains a Let's Encrypt certificate for your domain (certbot)
#   4. Installs an Asterisk cert-renewal deploy hook
#   5. Updates Apache SSL vhost to use the Let's Encrypt cert
#   6. Deploys the HulkPhone WebRTC softphone as a live git clone (updatable
#      in place with `git -C /var/www/html/hulkphone pull`), plus its
#      deny-.git / no-directory-listing / fail2ban-loopback hardening
#   7. Opens firewall ports 8088/8089
#   8. Reloads/restarts services
#
# Prerequisites:
#   - A public domain pointing at this server's IP (DNS must resolve)
#   - Apache httpd running and serving /var/www/html
#   - Asterisk running (Parts 1-3 completed)
#   - This script run as root
#
# Usage:
#   bash vicidial_rocky10_part4_webrtc.sh --domain yourdomain.example.com
#   bash vicidial_rocky10_part4_webrtc.sh --domain yourdomain.example.com --skip-certbot
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DOMAIN=""
SKIP_CERTBOT=false
SKIP_AUDIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2"; shift 2 ;;
        --skip-certbot) SKIP_CERTBOT=true; shift ;;
        --skip-audit) SKIP_AUDIT=true; shift ;;
        *) error "Unknown argument: $1" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -z "$DOMAIN" ] && error "Usage: $0 --domain your.domain.com [--skip-certbot]"
[ "$(id -u)" -ne 0 ] && error "Must be run as root"

# ── Derived paths ─────────────────────────────────────────────────────────────
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
AST_KEYS_DIR="/etc/asterisk/keys"
AST_HTTP_CONF="/etc/asterisk/http.conf"
AST_PJSIP_CONF="/etc/asterisk/pjsip.conf"
APACHE_SSL_CONF="/etc/httpd/conf.d/ssl.conf"
HULKPHONE_DIR="/var/www/html/hulkphone"

echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ViciDial Part 4 — WebRTC / SSL / HulkPhone         ║"
echo "║   Domain: ${DOMAIN}"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# STEP 1: Let's Encrypt certificate
# =============================================================================
section "STEP 1: Let's Encrypt SSL Certificate"

if [ "$SKIP_CERTBOT" = true ]; then
    warning "Skipping certbot — using existing cert at ${CERT_DIR}"
    [ ! -f "${CERT_DIR}/fullchain.pem" ] && error "No cert found at ${CERT_DIR}/fullchain.pem — run without --skip-certbot"
else
    if [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
        log "Installing certbot..."
        dnf install -y certbot python3-certbot-apache 2>/dev/null || \
        dnf install -y certbot 2>/dev/null || \
        error "Failed to install certbot — install manually: dnf install -y certbot"

        log "Requesting certificate for ${DOMAIN} (webroot method)..."
        systemctl is-active --quiet httpd || systemctl start httpd
        certbot certonly --webroot -w /var/www/html \
            -d "${DOMAIN}" \
            --non-interactive --agree-tos \
            --email "admin@${DOMAIN}" \
            --no-eff-email || \
        error "certbot failed. Ensure ${DOMAIN} resolves to this server and port 80 is open."
        success "Certificate obtained: ${CERT_DIR}/fullchain.pem"
    else
        success "Certificate already exists at ${CERT_DIR}"
    fi
fi

# =============================================================================
# STEP 2: Copy cert into Asterisk keys directory
# =============================================================================
section "STEP 2: Asterisk TLS Keys"

mkdir -p "${AST_KEYS_DIR}"

# Build combined PEM (cert + key) for Asterisk's tlscertfile
DOMAIN_SAFE="${DOMAIN//./_}"
COMBINED_PEM="${AST_KEYS_DIR}/${DOMAIN_SAFE}.pem"
PRIVKEY_COPY="${AST_KEYS_DIR}/${DOMAIN_SAFE}.key"

cat "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" > "${COMBINED_PEM}"
cp -f "${CERT_DIR}/privkey.pem" "${PRIVKEY_COPY}"
chmod 600 "${COMBINED_PEM}" "${PRIVKEY_COPY}"
chown root:root "${COMBINED_PEM}" "${PRIVKEY_COPY}"
success "Asterisk TLS cert: ${COMBINED_PEM}"

# =============================================================================
# STEP 3: Asterisk HTTP server (http.conf) for WebSocket
# =============================================================================
section "STEP 3: Asterisk HTTP Server (WSS on :8089)"

if grep -q '^enabled=yes' "${AST_HTTP_CONF}" 2>/dev/null && \
   grep -q 'tlsbindaddr.*8089' "${AST_HTTP_CONF}" 2>/dev/null; then
    success "http.conf already configured for WSS"
else
    cp -f "${AST_HTTP_CONF}" "${AST_HTTP_CONF}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cat > "${AST_HTTP_CONF}" << HTTPCONF
[general]
servername=Asterisk
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=${COMBINED_PEM}
tlsprivatekey=${PRIVKEY_COPY}
HTTPCONF
    success "http.conf written — Asterisk will serve WSS on port 8089"
fi

# =============================================================================
# STEP 4: PJSIP transport-wss (pjsip.conf)
# =============================================================================
section "STEP 4: PJSIP WebSocket Transport"

if grep -q 'webrtc_template' "${AST_PJSIP_CONF}" 2>/dev/null; then
    # A webrtc_template section exists, but earlier versions of this script
    # (and hand-built configs) omitted webrtc=yes / dtls_auto_generate_cert=yes,
    # which silently breaks WebRTC registration (endpoint shows "webrtc: no",
    # empty dtls_cert_file) without any error at reload time. Self-heal it
    # in place rather than trusting section-presence as "already correct".
    if grep -A20 '^\[webrtc_template\]' "${AST_PJSIP_CONF}" | grep -q '^webrtc=yes'; then
        success "pjsip.conf already has webrtc_template (webrtc=yes confirmed)"
    else
        warning "webrtc_template found but missing webrtc=yes/dtls_auto_generate_cert=yes — patching in place"
        cp -f "${AST_PJSIP_CONF}" "${AST_PJSIP_CONF}.backup.$(date +%Y%m%d%H%M%S)"
        sed -i '/^\[webrtc_template\](!)/,/^$/ {
            /^allow=alaw/a\
webrtc=yes\
dtls_auto_generate_cert=yes
        }' "${AST_PJSIP_CONF}"
        if grep -A20 '^\[webrtc_template\]' "${AST_PJSIP_CONF}" | grep -q '^webrtc=yes'; then
            success "pjsip.conf: webrtc_template patched with webrtc=yes/dtls_auto_generate_cert=yes"
        else
            error "Failed to patch webrtc_template automatically — add webrtc=yes and dtls_auto_generate_cert=yes to [webrtc_template] in ${AST_PJSIP_CONF} manually"
        fi
    fi
else
    cp -f "${AST_PJSIP_CONF}" "${AST_PJSIP_CONF}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    # ViciDial's stock pjsip.conf sample already ships a bare [transport-wss]
    # stanza, so only add it here if it's genuinely missing — a duplicate
    # section would be redundant/confusing in the config.
    if ! grep -q '^\[transport-wss\]' "${AST_PJSIP_CONF}" 2>/dev/null; then
        cat >> "${AST_PJSIP_CONF}" << 'PJSIPTRANSPORT'

[transport-wss]
type                            = transport
protocol                        = wss
bind                            = 0.0.0.0
PJSIPTRANSPORT
    fi

    # Add webrtc_template and the agents-conf include
    cat >> "${AST_PJSIP_CONF}" << 'PJSIPWSS'

; --- WebRTC/HulkPhone endpoint template ---
[webrtc_template](!)
type=endpoint
transport=transport-wss
context=default
disallow=all
allow=opus
allow=ulaw
allow=alaw
webrtc=yes
dtls_auto_generate_cert=yes
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
    success "pjsip.conf: transport-wss and webrtc_template added"
fi

# Create pjsip-webrtc-agents.conf if it doesn't exist
AGENTS_CONF="/etc/asterisk/pjsip-webrtc-agents.conf"
if [ ! -f "${AGENTS_CONF}" ]; then
    cat > "${AGENTS_CONF}" << 'AGENTSCONF'
; HulkPhone WebRTC Agent Extensions
; Managed manually — add one block per agent using the template below.
;
; [83XX](webrtc_template)
; auth=auth83XX
; aors=83XX
; callerid="Agent Name" <83XX>
; context=default
;
; [auth83XX]
; type=auth
; auth_type=userpass
; username=83XX
; password=YOURPASSWORD
;
; [83XX]
; type=aor
; max_contacts=1
; remove_existing=yes
AGENTSCONF
    success "Created ${AGENTS_CONF} (empty — add agents manually or via bulk script)"
fi

# =============================================================================
# STEP 5: sip.conf — websocket_enabled=false
# =============================================================================
section "STEP 5: sip.conf websocket_enabled Fix"

SIP_CONF="/etc/asterisk/sip.conf"
if [ -f "$SIP_CONF" ]; then
    if grep -q 'websocket_enabled=true' "$SIP_CONF"; then
        sed -i 's/websocket_enabled=true/websocket_enabled=false/' "$SIP_CONF"
        success "sip.conf: websocket_enabled=false (res_pjsip WebRTC fix applied)"
    elif grep -q 'websocket_enabled=false' "$SIP_CONF"; then
        success "sip.conf: websocket_enabled already false"
    else
        sed -i '/^\[general\]/a websocket_enabled=false' "$SIP_CONF"
        success "sip.conf: websocket_enabled=false added to [general]"
    fi
else
    warning "sip.conf not found — skipping"
fi

# =============================================================================
# STEP 6: Apache SSL vhost — point to Let's Encrypt cert
# =============================================================================
section "STEP 6: Apache SSL Certificate"

if [ -f "${APACHE_SSL_CONF}" ]; then
    cp -f "${APACHE_SSL_CONF}" "${APACHE_SSL_CONF}.backup.$(date +%Y%m%d%H%M%S)"
    # Update ServerName
    if grep -q 'ServerName' "${APACHE_SSL_CONF}"; then
        sed -i "s|ServerName .*|ServerName ${DOMAIN}:443|" "${APACHE_SSL_CONF}"
    fi
    # Update cert paths
    sed -i "s|SSLCertificateFile .*|SSLCertificateFile ${CERT_DIR}/fullchain.pem|" "${APACHE_SSL_CONF}"
    sed -i "s|SSLCertificateKeyFile .*|SSLCertificateKeyFile ${CERT_DIR}/privkey.pem|" "${APACHE_SSL_CONF}"
    # Remove SSLCertificateChainFile if present (fullchain.pem includes the chain)
    sed -i 's|^SSLCertificateChainFile|#SSLCertificateChainFile|' "${APACHE_SSL_CONF}"
    success "Apache ssl.conf updated to use Let's Encrypt cert for ${DOMAIN}"
else
    warning "${APACHE_SSL_CONF} not found — install mod_ssl: dnf install -y mod_ssl"
fi

# =============================================================================
# STEP 7: Certbot renewal deploy hook — keep Asterisk cert in sync
# =============================================================================
section "STEP 7: Certbot Renewal Hook for Asterisk"

DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/asterisk-cert.sh"
mkdir -p "$(dirname "${DEPLOY_HOOK}")"
cat > "${DEPLOY_HOOK}" << DEPLOYHOOK
#!/bin/bash
# Auto-renew Asterisk TLS keys when Let's Encrypt renews the cert
DOMAIN="${DOMAIN}"
CERT_DIR="/etc/letsencrypt/live/\${DOMAIN}"
AST_KEYS_DIR="${AST_KEYS_DIR}"
COMBINED_PEM="${COMBINED_PEM}"
PRIVKEY_COPY="${PRIVKEY_COPY}"

cat "\${CERT_DIR}/fullchain.pem" "\${CERT_DIR}/privkey.pem" > "\${COMBINED_PEM}"
cp -f "\${CERT_DIR}/privkey.pem" "\${PRIVKEY_COPY}"
chmod 600 "\${COMBINED_PEM}" "\${PRIVKEY_COPY}"

# Reload Asterisk TLS (graceful — no calls dropped)
if asterisk -rx "module reload res_crypto.so" 2>/dev/null; then
    asterisk -rx "module reload res_tls.so" 2>/dev/null || true
    asterisk -rx "http restart" 2>/dev/null || true
    logger -t certbot-deploy "Asterisk TLS cert renewed for \${DOMAIN}"
else
    logger -t certbot-deploy "WARNING: Asterisk not running — cert files updated but Asterisk not reloaded"
fi
systemctl reload httpd 2>/dev/null || true
DEPLOYHOOK
chmod +x "${DEPLOY_HOOK}"
success "Certbot deploy hook installed: ${DEPLOY_HOOK}"

# =============================================================================
# STEP 8: HulkPhone WebRTC Softphone
# =============================================================================
section "STEP 8: HulkPhone WebRTC Softphone"

# Primary source of truth: FrancoSmash73/Hulk- — the maintained repo with the
# real hulkphone.v2.js/hulkphone.css and a deploy/ folder of hardening this
# installer used to have no equivalent for at all. Deployed as a LIVE git
# clone (not a clone-to-tempdir-then-copy-then-discard snapshot): the .git
# stays in place so a fix landed upstream can be picked up later with
# `git -C ${HULKPHONE_DIR} pull` instead of re-running this whole script, and
# so deploy/'s hardening (deny .git, no directory listing, fail2ban loopback
# exemption, verify.sh) ships and applies automatically from the same clone.
# Falls back to a bundled inline copy only if cloning isn't possible at all
# (offline install) — see the fallback branch below.
HULK_REPO="https://github.com/FrancoSmash73/Hulk-.git"
HULKPHONE_SOURCED_FROM_REPO=false

# Same repo can legitimately be cloned via https:// or git@ (SSH) — an exact
# string match against one hardcoded protocol would treat an existing SSH
# clone as "not ours" and back up/re-clone a perfectly good deployment
# (and, worse, lose whatever config.local.php it left behind in the process:
# TURN credentials etc. aren't seeded back in on a fresh clone). Compare
# owner/repo identity instead of the full URL.
repo_slug() { echo "$1" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##'; }
HULK_REPO_SLUG="$(repo_slug "${HULK_REPO}")"
EXISTING_REMOTE="$(git -C "${HULKPHONE_DIR}" remote get-url origin 2>/dev/null || true)"

if [ -d "${HULKPHONE_DIR}/.git" ] && [ -n "${EXISTING_REMOTE}" ] && \
   [ "$(repo_slug "${EXISTING_REMOTE}")" = "${HULK_REPO_SLUG}" ]; then
    log "HulkPhone already git-deployed (${EXISTING_REMOTE}) — updating in place..."
    if git -C "${HULKPHONE_DIR}" fetch --depth 1 origin main 2>/dev/null && \
       git -C "${HULKPHONE_DIR}" reset --hard origin/main 2>/dev/null; then
        HULKPHONE_SOURCED_FROM_REPO=true
        success "HulkPhone updated in place (git pull) from ${HULK_REPO}"
    else
        warning "git update failed (offline?) — leaving existing deployment as-is"
        HULKPHONE_SOURCED_FROM_REPO=true   # already deployed, just couldn't refresh
    fi
elif command -v git &>/dev/null; then
    if [ -e "${HULKPHONE_DIR}" ] && [ -n "$(ls -A "${HULKPHONE_DIR}" 2>/dev/null)" ]; then
        # Something's there already but it isn't our git checkout — an old
        # vendored-copy install, or manual content. Move it aside rather
        # than silently overwrite or lose it; `git clone` refuses a
        # non-empty target anyway.
        BK="${HULKPHONE_DIR}.pre-git-$(date +%Y%m%d-%H%M%S)"
        mv "${HULKPHONE_DIR}" "${BK}"
        warning "Existing non-git HulkPhone deployment moved to ${BK}"
    fi
    if git clone --depth 1 --branch main "${HULK_REPO}" "${HULKPHONE_DIR}" &>/dev/null; then
        HULKPHONE_SOURCED_FROM_REPO=true
        success "HulkPhone cloned from ${HULK_REPO}"
    else
        warning "Could not clone ${HULK_REPO} (offline install?) — falling back to bundled copy"
        rm -rf "${HULKPHONE_DIR}"
    fi
else
    warning "git not available — falling back to bundled copy"
fi

if [ "${HULKPHONE_SOURCED_FROM_REPO}" = true ]; then
    # Root owns the checkout — the web server user gets read-only access via
    # world-readable bits, not ownership, so a compromised PHP/Apache process
    # can't modify its own served files or the .git history underneath them.
    chown -R root:root "${HULKPHONE_DIR}"
    find "${HULKPHONE_DIR}" -type d -exec chmod 755 {} +
    find "${HULKPHONE_DIR}" -type f -exec chmod 644 {} +
    find "${HULKPHONE_DIR}" -name "*.sh" -exec chmod 755 {} +

    # config.local.php holds per-install SIP/TURN settings (gitignored, so a
    # `git reset --hard` above never touches it). Create it once, seeded with
    # the domain this script already knows about; never touch its CONTENT
    # again once it exists, so manual edits (TURN creds, etc.) survive every
    # re-run. Its 640/root:apache permissions are re-applied unconditionally
    # every run, though — the bulk chmod 644 above would otherwise clobber
    # them back to world-readable on every re-run after the first.
    HULK_CFG="${HULKPHONE_DIR}/config.local.php"
    if [ ! -f "${HULK_CFG}" ] && [ -f "${HULKPHONE_DIR}/config.local.example.php" ]; then
        cp "${HULKPHONE_DIR}/config.local.example.php" "${HULK_CFG}"
        sed -i "s/'sip_domain'  => '',/'sip_domain'  => '${DOMAIN}',/" "${HULK_CFG}"
        success "config.local.php created (sip_domain=${DOMAIN})"
    else
        success "config.local.php already present — left untouched"
    fi
    if [ -f "${HULK_CFG}" ]; then
        chown root:apache "${HULK_CFG}"
        chmod 640 "${HULK_CFG}"
    fi

    # Hardening from the repo's own deploy/ folder — always ships with the
    # clone, so it can't drift from what Hulk- actually recommends.
    HULK_DEPLOY_DIR="${HULKPHONE_DIR}/deploy"
    if [ -d "${HULK_DEPLOY_DIR}" ]; then
        # HulkPhone is served under the global DocumentRoot (/var/www/html),
        # not its own Alias block, so the noindex config is always the right
        # case here (see deploy/README.md for the Alias alternative).
        cp -f "${HULK_DEPLOY_DIR}/apache/deny-git.conf"          /etc/httpd/conf.d/deny-git.conf 2>/dev/null || \
            warning "deploy/apache/deny-git.conf missing from clone — .git will NOT be blocked from the web"
        cp -f "${HULK_DEPLOY_DIR}/apache/hulkphone-noindex.conf" /etc/httpd/conf.d/hulkphone-noindex.conf 2>/dev/null || \
            warning "deploy/apache/hulkphone-noindex.conf missing from clone — directory listing will NOT be disabled"
        if apachectl configtest &>/dev/null; then
            systemctl reload httpd 2>/dev/null || true
            success "Apache hardening applied (.git denied, directory listing off)"
        else
            warning "apachectl configtest failed after installing HulkPhone Apache hardening — check /etc/httpd/conf.d/deny-git.conf and hulkphone-noindex.conf"
        fi

        if command -v fail2ban-client &>/dev/null && [ -f "${HULK_DEPLOY_DIR}/fail2ban/zzz-ignoreip.local" ]; then
            cp -f "${HULK_DEPLOY_DIR}/fail2ban/zzz-ignoreip.local" /etc/fail2ban/jail.d/zzz-ignoreip.local
            if fail2ban-client -t &>/dev/null; then
                fail2ban-client reload &>/dev/null || true
                success "fail2ban loopback exemption applied (127.0.0.0/8, ::1)"
            else
                warning "fail2ban-client -t failed after installing zzz-ignoreip.local — check /etc/fail2ban/jail.d/"
            fi
        fi

        # Loopback only — verify.sh deliberately requests paths Apache must
        # deny, and running it against a public URL risks fail2ban banning
        # the caller (see deploy/README.md). Non-fatal: a failure here is a
        # signal to look, not a reason to abort the rest of Part 4.
        if [ -x "${HULK_DEPLOY_DIR}/verify.sh" ]; then
            log "Running HulkPhone deploy verification (loopback only)..."
            bash "${HULK_DEPLOY_DIR}/verify.sh" http://127.0.0.1 || \
                warning "HulkPhone verify.sh reported failures — review above before considering this step done"
        fi
    fi
else

mkdir -p "${HULKPHONE_DIR}/js" "${HULKPHONE_DIR}/css" "${HULKPHONE_DIR}/sounds"

# Download SIP.js 0.20.1 if not already present
SIPJS="${HULKPHONE_DIR}/js/sip.js"
if [ ! -f "${SIPJS}" ]; then
    log "Downloading SIP.js 0.20.1..."
    curl -fsSL \
        "https://github.com/onsip/SIP.js/releases/download/0.20.1/sip-0.20.1.min.js" \
        -o "${SIPJS}" 2>/dev/null || \
    curl -fsSL \
        "https://cdn.jsdelivr.net/npm/sip.js@0.20.1/dist/sip.js" \
        -o "${SIPJS}" 2>/dev/null || \
    warning "Could not download SIP.js — copy sip.js manually to ${SIPJS}"
    [ -f "${SIPJS}" ] && success "SIP.js downloaded" || true
else
    success "SIP.js already present"
fi

# Write hulkphone.php (PHP config injector + HTML shell)
# FALLBACK ONLY — used when the Hulk- repo can't be cloned (offline install).
# This inline copy has no SESSION/AUTOANSWER call-auto-dial polish beyond the
# basics and does not ship hulkphone.v2.js/hulkphone.css (see NOTE below) —
# it exists so the install doesn't hard-fail without network access, not as
# a maintained alternative to the real repo.
cat > "${HULKPHONE_DIR}/hulkphone.php" << 'HULKPHP'
<?php
/**
 * HulkPhone - ViciDial WebRTC Softphone
 * Parameters passed by ViciDial (base64) or directly via GET:
 *   phone_login / phone_pass / server_ip / options / callerid
 *   ext / pass / server_ip / conf_exten / ws_port / ws_path
 *   auto_answer / language / stun_server
 */
function safe($key, $default = '') {
    return isset($_GET[$key]) ? htmlspecialchars(trim($_GET[$key]), ENT_QUOTES, 'UTF-8') : $default;
}

// ViciDial base64 parameter mode
if (!empty($_GET['phone_login'])) {
    $ext         = base64_decode($_GET['phone_login']);
    $pass        = base64_decode($_GET['phone_pass'] ?? '');
    $server_ip   = $_SERVER['HTTP_HOST'] ?? $_SERVER['SERVER_NAME'];
    $callerid    = base64_decode($_GET['callerid'] ?? $ext);
    $conf_exten  = '';
    $ws_port     = '8089';
    $ws_path     = '/ws';
    $auto_answer = '1';
    $language    = 'en';
    $stun_server = 'stun.l.google.com:19302';
} else {
    $server_ip   = safe('server_ip',   $_SERVER['HTTP_HOST'] ?? '');
    $ext         = safe('ext',         '');
    $pass        = safe('pass',        '');
    $user        = safe('user',        '');
    $conf_exten  = safe('conf_exten',  '');
    $ws_port     = safe('ws_port',     '8089');
    $ws_path     = safe('ws_path',     '/ws');
    $callerid    = safe('callerid',    $ext);
    $auto_answer = safe('auto_answer', '1');
    $language    = safe('language',    'en');
    $stun_server = safe('stun_server', 'stun.l.google.com:19302');
}

// Parse ViciDial options (SESSION + AUTOANSWER)
if (!empty($_GET['options'])) {
    $opts = base64_decode($_GET['options']);
    if (preg_match('/SESSION(\d+)/', $opts, $m)) {
        $conf_exten = '2' . $m[1];
    }
    if (preg_match('/AUTOANSWER_Y/', $opts)) {
        $auto_answer = '1';
    }
}

// Always WSS when served over HTTPS
$ws_protocol = 'wss';

$t = [
    'title'        => 'HulkPhone',
    'status_unreg' => 'NOT REGISTERED',
    'status_reg'   => 'REGISTERED',
    'status_call'  => 'IN CALL',
    'status_ring'  => 'RINGING...',
    'status_hold'  => 'ON HOLD',
    'status_conn'  => 'CONNECTING...',
    'btn_call'     => 'CALL',
    'btn_hangup'   => 'HANG UP',
    'btn_mute'     => 'MUTE',
    'btn_unmute'   => 'UNMUTE',
    'btn_hold'     => 'HOLD',
    'btn_unhold'   => 'RESUME',
    'btn_transfer' => 'XFER',
    'ext_label'    => 'Extension:',
    'server_label' => 'Server:',
];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HulkPhone</title>
<script src="/hulkphone/js/sip.js?v=2"></script>
<link rel="stylesheet" href="/hulkphone/css/hulkphone.css">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;600;700&family=Share+Tech+Mono&display=swap" rel="stylesheet">
</head>
<body>
<div id="hulkphone-wrapper">
  <div id="hp-header">
    <div id="hp-logo"><span class="hp-logo-icon">☎</span><span class="hp-logo-text">HULK<em>PHONE</em></span></div>
    <div id="hp-status-dot" class="status-dot unregistered"></div>
  </div>
  <div id="hp-status-bar"><span id="hp-status-text">NOT REGISTERED</span></div>
  <div id="hp-info-row">
    <div class="hp-info-item"><span class="hp-info-label">EXT</span><span class="hp-info-value" id="hp-ext-display"><?= htmlspecialchars($ext ?: '----') ?></span></div>
    <div class="hp-info-item"><span class="hp-info-label">SERVER</span><span class="hp-info-value" id="hp-server-display"><?= htmlspecialchars($server_ip ?: '---') ?></span></div>
    <div class="hp-info-item"><span class="hp-info-label">TIMER</span><span class="hp-info-value" id="hp-timer">00:00</span></div>
  </div>
  <div id="hp-dial-display-wrap">
    <input type="text" id="hp-dial-input" placeholder="Enter number..." autocomplete="off" maxlength="20">
    <button id="hp-clear-btn" onclick="HulkPhone.clearInput()">⌫</button>
  </div>
  <div id="hp-dialpad">
    <?php foreach([['1',''],['2','ABC'],['3','DEF'],['4','GHI'],['5','JKL'],['6','MNO'],['7','PQRS'],['8','TUV'],['9','WXYZ'],['*',''],['0','+'],['#','']] as $k): ?>
    <button class="hp-key" onclick="HulkPhone.dialKey('<?= $k[0] ?>')">
      <span class="hp-key-num"><?= $k[0] ?></span><?php if($k[1]) echo '<span class="hp-key-alpha">'.$k[1].'</span>'; ?>
    </button>
    <?php endforeach; ?>
  </div>
  <div id="hp-controls">
    <button id="hp-call-btn"  class="hp-ctrl-btn green" onclick="HulkPhone.callAction()"><span class="hp-ctrl-icon">📞</span><span class="hp-ctrl-label" id="hp-call-label">CALL</span></button>
    <button id="hp-mute-btn"  class="hp-ctrl-btn amber" onclick="HulkPhone.toggleMute()"><span class="hp-ctrl-icon">🎙</span><span class="hp-ctrl-label" id="hp-mute-label">MUTE</span></button>
    <button id="hp-hold-btn"  class="hp-ctrl-btn blue"  onclick="HulkPhone.toggleHold()"><span class="hp-ctrl-icon">⏸</span><span class="hp-ctrl-label" id="hp-hold-label">HOLD</span></button>
  </div>
  <div id="hp-transfer-row">
    <input type="text" id="hp-xfer-input" placeholder="Transfer to..." autocomplete="off">
    <button class="hp-xfer-btn blind"  onclick="HulkPhone.blindTransfer()">XFER (Blind)</button>
    <button class="hp-xfer-btn warm"   onclick="HulkPhone.warmTransfer()">Warm</button>
  </div>
  <div id="hp-volume-row">
    <span class="hp-vol-label">🔊</span>
    <input type="range" id="hp-volume" min="0" max="1" step="0.05" value="0.8" oninput="HulkPhone.setVolume(this.value)">
  </div>
  <div id="hp-footer"><span id="hp-version">HulkPhone v1.0 | ViciDial WebRTC</span></div>
</div>
<audio id="hp-remote-audio" autoplay></audio>
<audio id="hp-ring-audio" loop><source src="/hulkphone/sounds/ring.mp3" type="audio/mpeg"></audio>

<script>
var HP_CONFIG = {
    server_ip:   "<?= htmlspecialchars($server_ip) ?>",
    ext:         "<?= htmlspecialchars($ext) ?>",
    pass:        "<?= htmlspecialchars($pass) ?>",
    conf_exten:  "<?= htmlspecialchars($conf_exten) ?>",
    ws_url:      "<?= $ws_protocol ?>://<?= htmlspecialchars($server_ip) ?>:<?= htmlspecialchars($ws_port . $ws_path) ?>",
    callerid:    "<?= htmlspecialchars($callerid) ?>",
    auto_answer: <?= ($auto_answer === '1') ? 'true' : 'false' ?>,
    stun:        "<?= htmlspecialchars($stun_server) ?>"
};
</script>
<script src="/hulkphone/js/hulkphone.v2.js?v=7"></script>
</body>
</html>
HULKPHP

chown -R apache:apache "${HULKPHONE_DIR}" 2>/dev/null || chown -R www-data:www-data "${HULKPHONE_DIR}" 2>/dev/null || true
chmod -R 755 "${HULKPHONE_DIR}"
success "HulkPhone deployed to ${HULKPHONE_DIR}"

cat << 'HULKNOTE'
  NOTE: hulkphone.v2.js and hulkphone.css are NOT included in this repo
  (they contain the SIP.js integration logic and styling).
  Copy them from your working server:
    scp root@<working-server>:/var/www/html/hulkphone/js/hulkphone.v2.js  <here>
    scp root@<working-server>:/var/www/html/hulkphone/css/hulkphone.css   <here>
  Or place them in configs/hulkphone/ and this script will copy them automatically.
HULKNOTE

# Auto-copy from configs/ if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/configs/hulkphone/hulkphone.v2.js" ]; then
    cp "${SCRIPT_DIR}/configs/hulkphone/hulkphone.v2.js" "${HULKPHONE_DIR}/js/"
    success "hulkphone.v2.js copied from configs/"
fi
if [ -f "${SCRIPT_DIR}/configs/hulkphone/hulkphone.css" ]; then
    cp "${SCRIPT_DIR}/configs/hulkphone/hulkphone.css" "${HULKPHONE_DIR}/css/"
    success "hulkphone.css copied from configs/"
fi

fi   # end fallback path (HULKPHONE_SOURCED_FROM_REPO = false)

# =============================================================================
# STEP 8b: Point ViciDial at HulkPhone (system_settings.webphone_url)
# =============================================================================
# This is the field vicidial.php's agent screen actually reads to build the
# webphone iframe src (agc/vicidial.php: "SELECT webphone_url FROM
# system_settings"). It is NOT phones.VICIDIAL_web_URL — that's an unrelated
# call-event webhook field. Leaving this unset is silent: no error anywhere,
# the phone panel just never renders. Set it here automatically instead of
# only mentioning it in the post-install notes, since that's exactly the gap
# that caused a webphone-not-appearing incident on a prior install.
section "STEP 8b: system_settings.webphone_url"

DB_HOST=$(grep  '^VARDB_server ' /etc/astguiclient.conf 2>/dev/null | awk '{print $3}')
DB_USER=$(grep  '^VARDB_user '   /etc/astguiclient.conf 2>/dev/null | awk '{print $3}')
DB_PASS=$(grep  '^VARDB_pass '   /etc/astguiclient.conf 2>/dev/null | awk '{print $3}')
DB_NAME=$(grep  '^VARDB_database ' /etc/astguiclient.conf 2>/dev/null | awk '{print $3}')
DB_HOST=${DB_HOST:-127.0.0.1}
DB_NAME=${DB_NAME:-asterisk}

if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -e "UPDATE system_settings SET webphone_url='https://${DOMAIN}/hulkphone/hulkphone.php';" \
        2>/dev/null \
    && success "system_settings.webphone_url set to https://${DOMAIN}/hulkphone/hulkphone.php" \
    || warning "Could not update system_settings.webphone_url — set it manually via Admin > System Settings"
else
    warning "Could not read DB credentials from /etc/astguiclient.conf — set system_settings.webphone_url manually"
fi

# =============================================================================
# STEP 9: Firewall — open ports 8088 and 8089
# =============================================================================
section "STEP 9: Firewall Rules (8088/8089)"

if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    for PORT in 8088 8089; do
        if ! firewall-cmd --query-port="${PORT}/tcp" --permanent &>/dev/null; then
            firewall-cmd --permanent --add-port="${PORT}/tcp"
            success "Opened port ${PORT}/tcp"
        else
            info "Port ${PORT}/tcp already open"
        fi
    done
    firewall-cmd --reload
    success "Firewall reloaded"
else
    warning "firewalld not active — open ports 8088/8089 manually"
fi

# =============================================================================
# STEP 10: Reload services
# =============================================================================
section "STEP 10: Reloading Services"

log "Reloading Apache..."
systemctl reload httpd && success "Apache reloaded" || warning "Apache reload failed — check: systemctl status httpd"

log "Restarting Asterisk HTTP server (requires full restart for http.conf changes)..."
asterisk -rx "core restart now" 2>/dev/null &
sleep 12
if asterisk -rx "core show version" 2>/dev/null | grep -q Asterisk; then
    success "Asterisk restarted"
    asterisk -rx "module show like res_pjsip_transport_websocket" 2>/dev/null
else
    warning "Asterisk may still be restarting — check: asterisk -r"
fi

# =============================================================================
# DONE
# =============================================================================
echo -e "\n${BOLD}${GREEN}═══ Part 4 Complete ═══${NC}"
echo ""
echo -e "  ${CYAN}HulkPhone URL:${NC}  https://${DOMAIN}/hulkphone/hulkphone.php"
echo -e "  ${CYAN}Test with ext:${NC}  https://${DOMAIN}/hulkphone/hulkphone.php?ext=8300&pass=YOURPASS&server_ip=${DOMAIN}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Add WebRTC agent phones to /etc/asterisk/pjsip-webrtc-agents.conf"
echo -e "     (system_settings.webphone_url was already set for you above)"
echo -e "  2. Set phones.is_webphone = 'Y' and phones.conf_secret = phones.pass"
echo -e "     for each WebRTC phone in the ViciDial DB (HulkPhone auths with"
echo -e "     conf_secret, so it must match the PJSIP auth password)"
echo -e "  3. Verify: asterisk -rx \"module show like res_pjsip_transport_websocket\""
echo ""

# =============================================================================
# STEP 11: Automatic post-install audit
# =============================================================================
if [ "$SKIP_AUDIT" = true ]; then
    info "Skipping post-install audit (--skip-audit)"
elif [ -f "$SCRIPT_DIR/vicidial_rocky10_audit.sh" ]; then
    section "STEP 11: Post-Install Audit"
    warning "This audit checks for mariadb/httpd/asterisk/process-monitor together."
    warning "On a multi-server cluster, FAILs for services that don't belong on"
    warning "THIS node's role (e.g. 'mariadb FAIL' on an Asterisk-only box) are"
    warning "expected — read results in context of what this specific node runs."
    bash "$SCRIPT_DIR/vicidial_rocky10_audit.sh" || warning "Audit reported issues above — review before considering this node done"
else
    warning "vicidial_rocky10_audit.sh not found next to this script — skipping automatic audit"
    info "Run it manually later: bash vicidial_rocky10_audit.sh"
fi
