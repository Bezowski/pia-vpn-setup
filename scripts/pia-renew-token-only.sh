#!/bin/bash
# Renew PIA token silently without touching the VPN connection
# Token is only used during connection initialization, not for active connections
set -euo pipefail

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"
PERSIST_DIR=/var/lib/pia

if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

: "${PIA_USER:?PIA_USER must be set}"
: "${PIA_PASS:?PIA_PASS must be set}"

cd "$MANUAL_CONN_DIR"

# Ensure we have the CA certificate
[ -f ca.rsa.4096.crt ] || wget -qO ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

echo "Renewing PIA token..."

# Get a fresh token
export PIA_USER PIA_PASS
./get_token.sh > /dev/null 2>&1

# Extract the new token from the file it creates
if [ -f /opt/piavpn-manual/token ]; then
  NEW_TOKEN=$(awk 'NR == 1' /opt/piavpn-manual/token)
  EXPIRY_DATE=$(awk 'NR == 2' /opt/piavpn-manual/token)
  
  # Calculate expiry timestamp (24 hours from now)
  EXPIRY_TIMESTAMP=$(($(date +%s) + 86400))
  
  # Save token and expiry to the persistence directory
  mkdir -p "$PERSIST_DIR"
  
  # Format: TOKEN_STRING\nEXPIRY_UNIX_TIMESTAMP
  {
    echo "$NEW_TOKEN"
    echo "$EXPIRY_TIMESTAMP"
  } > "$PERSIST_DIR/pia_token_expiry.txt"
  
  chmod 0600 "$PERSIST_DIR/pia_token_expiry.txt"
  
  log_msg="Token renewed at $(date '+%Y-%m-%d %H:%M:%S'), expires at $EXPIRY_DATE"
  echo "$log_msg"
  
  # Log to syslog for monitoring
  logger -t pia-token-renew "$log_msg"
  
else
  echo "Error: Failed to renew token" >&2
  logger -t pia-token-renew "ERROR: Token renewal failed"
  exit 1
fi
