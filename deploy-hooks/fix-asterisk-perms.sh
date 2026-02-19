#!/bin/bash
# Fix permissions so Asterisk can read TLS certs for WebSocket
chmod 755 /etc/letsencrypt/live/
chmod 755 /etc/letsencrypt/archive/
chmod 755 /etc/letsencrypt/archive/callbakz.ddns.net/
chown root:asterisk /etc/letsencrypt/archive/callbakz.ddns.net/privkey*.pem
chmod 640 /etc/letsencrypt/archive/callbakz.ddns.net/privkey*.pem
# Reload Asterisk HTTP to pick up renewed cert
asterisk -rx "module reload http" 2>/dev/null
