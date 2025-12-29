#!/bin/bash
# Improved token renewal script - direct API call, no dependencies on get_token.sh
# This script renews the PIA token silently without touching the VPN connection

set -euo pipefail

# Metrics logging wrapper
log_metric() {
    /usr/local/bin/pia-metrics.sh "$@" 2>/dev/null || true
}

CRED_FILE="/etc/pia-credentials"
PERSIST_DIR=/var/lib/pia
TOKEN_FILE="$PERSIST_DIR/token.txt"

# Load credentials
if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

# Validate credentials are set
if [ -z "${PIA_USER:-}" ] || [ -z "${PIA_PASS:-}" ]; then
  >&2 echo "ERROR: PIA_USER and PIA_PASS must be set in $CRED_FILE"
  log_metric log-token-failed
  exit 1
fi

# Ensure persistence directory exists
mkdir -p "$PERSIST_DIR"

# Function to get new token directly from PIA API
get_new_token() {
  local response
  
  response=$(curl -s --location --request POST \
    'https://www.privateinternetaccess.com/api/client/v2/token' \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
  
  # Extract token from JSON response
  echo "$response" | jq -r '.token // empty' 2>/dev/null
}

# Attempt to get new token
echo "Renewing PIA authentication token..."

NEW_TOKEN=$(get_new_token)

if [ -z "$NEW_TOKEN" ]; then
  >&2 echo "ERROR: Failed to obtain new token from PIA API"
  >&2 echo "Possible causes:"
  >&2 echo "  - Invalid username/password in $CRED_FILE"
  >&2 echo "  - PIA account has no active subscription"
  >&2 echo "  - PIA API is unreachable"
  log_metric log-token-failed
  exit 1
fi

# ATOMIC WRITE: Save the new token using temporary file + atomic move
TMP_TOKEN=$(mktemp "${TOKEN_FILE}.XXXX")
echo "$NEW_TOKEN" > "$TMP_TOKEN"
chmod 0600 "$TMP_TOKEN"
mv -f "$TMP_TOKEN" "$TOKEN_FILE"

# Log success
EXPIRY_DATE=$(date -d '24 hours' '+%Y-%m-%d %H:%M:%S')
LOG_MSG="Token renewed successfully at $(date '+%Y-%m-%d %H:%M:%S'), expires $EXPIRY_DATE"

echo "$LOG_MSG"
logger -t pia-token-renew "$LOG_MSG"
log_metric log-token-renewed

# ATOMIC WRITE: Optional expiry timestamp file
EXPIRY_UNIX=$(($(date +%s) + 86400))
TMP_EXPIRY=$(mktemp "${TOKEN_FILE}.with-expiry.XXXX")
echo "$NEW_TOKEN $EXPIRY_UNIX" > "$TMP_EXPIRY"
chmod 0600 "$TMP_EXPIRY"
mv -f "$TMP_EXPIRY" "${TOKEN_FILE}.with-expiry"

exit 0
