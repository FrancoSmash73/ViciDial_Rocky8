#!/bin/bash
# Reload Asterisk TLS/crypto modules after cert renewal
# Runs AFTER fix-asterisk-perms.sh (alphabetical order)
asterisk -rx 'module reload res_crypto' 2>/dev/null
asterisk -rx 'module reload res_http_websocket' 2>/dev/null
asterisk -rx 'http reload' 2>/dev/null
