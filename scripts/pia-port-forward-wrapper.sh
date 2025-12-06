#!/bin/bash
set -euo pipefail

PERSIST_DIR=/var/lib/pia

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
