#!/bin/bash
set -euo pipefail

PERSIST_DIR=/var/lib/pia
CRED_FILE="/etc/pia-credentials"

# Check if port forwarding is enabled
if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

# Default to disabled if not set
PIA_PF=${PIA_PF:-"false"}

# Exit cleanly if port forwarding is disabled
if [ "$PIA_PF" != "true" ]; then
  echo "Port forwarding disabled (PIA_PF=$PIA_PF)"
  exit 0
fi

# Read region data (hostname and gateway saved by pia-renew-and-connect.sh)
if [ ! -s "$PERSIST_DIR/region.txt" ]; then
    echo "Error: No region data found. Run pia-renew-and-connect.sh first." >&2
    exit 1
fi

# Extract hostname and gateway
PF_HOSTNAME=$(awk -F= '/^hostname=/ {print $2; exit}' "$PERSIST_DIR/region.txt")
PF_GATEWAY=$(awk -F= '/^gateway=/ {print $2; exit}' "$PERSIST_DIR/region.txt")

if [ -z "$PF_HOSTNAME" ] || [ -z "$PF_GATEWAY" ]; then
    echo "Error: Could not extract hostname or gateway from region.txt" >&2
    exit 1
fi

# Export for port_forwarding.sh (it will read PIA_TOKEN from /var/lib/pia/token.txt itself)
export PF_HOSTNAME PF_GATEWAY

# The script will read token from $PERSIST_DIR/token.txt automatically
cd /usr/local/bin/manual-connections
exec ./port_forwarding.sh
