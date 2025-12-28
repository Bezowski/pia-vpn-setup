#!/bin/bash
# PIA Port Forwarding Wrapper - Improved with better error handling
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
    echo "Error: No region data found at $PERSIST_DIR/region.txt" >&2
    echo "This usually means the VPN hasn't connected yet." >&2
    echo "Run pia-renew-and-connect.sh first or wait for pia-vpn.service to start." >&2
    exit 1
fi

# Extract hostname and gateway with improved validation
PF_HOSTNAME=$(awk -F= '/^hostname=/ {print $2; exit}' "$PERSIST_DIR/region.txt" | tr -d '[:space:]')
PF_GATEWAY=$(awk -F= '/^gateway=/ {print $2; exit}' "$PERSIST_DIR/region.txt" | tr -d '[:space:]')

# Validate that values are not empty or null
if [ -z "$PF_HOSTNAME" ] || [ "$PF_HOSTNAME" == "null" ]; then
    echo "Error: Invalid or empty hostname in region.txt" >&2
    echo "Content of $PERSIST_DIR/region.txt:" >&2
    cat "$PERSIST_DIR/region.txt" >&2
    exit 1
fi

if [ -z "$PF_GATEWAY" ] || [ "$PF_GATEWAY" == "null" ]; then
    echo "Error: Invalid or empty gateway in region.txt" >&2
    echo "Content of $PERSIST_DIR/region.txt:" >&2
    cat "$PERSIST_DIR/region.txt" >&2
    exit 1
fi

# Validate hostname format (should be a domain name)
if ! echo "$PF_HOSTNAME" | grep -qE '^[a-z0-9.-]+\.[a-z]{2,}$'; then
    echo "Warning: Hostname '$PF_HOSTNAME' doesn't look like a valid domain name" >&2
fi

# Validate gateway is an IP address
if ! echo "$PF_GATEWAY" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "Error: Gateway '$PF_GATEWAY' is not a valid IP address" >&2
    exit 1
fi

echo "Port forwarding enabled for:"
echo "  Hostname: $PF_HOSTNAME"
echo "  Gateway:  $PF_GATEWAY"

# Read and export token
if [ ! -f "$PERSIST_DIR/token.txt" ]; then
    echo "Error: No token found at $PERSIST_DIR/token.txt" >&2
    echo "Token file is missing. This should have been created by pia-renew-and-connect.sh" >&2
    exit 1
fi

PIA_TOKEN=$(head -1 "$PERSIST_DIR/token.txt" 2>/dev/null || echo "")

if [ -z "$PIA_TOKEN" ]; then
    echo "Error: Token file exists but is empty" >&2
    exit 1
fi

# Validate token format (should be base64-ish)
if ! echo "$PIA_TOKEN" | grep -qE '^[A-Za-z0-9+/=_-]{20,}$'; then
    echo "Warning: Token doesn't look like a valid PIA token" >&2
fi

echo "  Token:    ${PIA_TOKEN:0:20}... ($(echo -n "$PIA_TOKEN" | wc -c) chars)"

# Export for port_forwarding.sh
export PF_HOSTNAME PF_GATEWAY PIA_TOKEN

# Delete old port file to force fresh assignment
# This ensures we get a new port when the service restarts
rm -f "$PERSIST_DIR/forwarded_port"
echo "Deleted old port file (forcing fresh port assignment)"

# Verify we can access the PIA certificate
CERT_PATH="/usr/local/bin/manual-connections/ca.rsa.4096.crt"
if [ ! -f "$CERT_PATH" ]; then
    echo "Error: PIA certificate not found at $CERT_PATH" >&2
    exit 1
fi

# Change to manual-connections directory
cd /usr/local/bin/manual-connections || {
    echo "Error: Cannot access /usr/local/bin/manual-connections" >&2
    exit 1
}

# Verify port_forwarding.sh exists and is executable
if [ ! -x ./port_forwarding.sh ]; then
    echo "Error: port_forwarding.sh not found or not executable" >&2
    exit 1
fi

echo "Starting port forwarding script..."
echo "---"

# Execute the port forwarding script
exec ./port_forwarding.sh
