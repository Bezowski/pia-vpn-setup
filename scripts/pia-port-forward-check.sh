#!/bin/bash
# Wrapper script to check PIA_PF setting before running port forwarding

set -euo pipefail

CRED_FILE="/etc/pia-credentials"

# Source the credentials file
if [ -f "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
fi

# Default to false if not set
: "${PIA_PF:=false}"

echo "Port forwarding setting: PIA_PF=$PIA_PF"

if [ "$PIA_PF" = "true" ]; then
    echo "Starting port forwarding..."
    exec /usr/local/bin/pia-port-forward-wrapper.sh
else
    echo "Port forwarding disabled (PIA_PF=$PIA_PF)"
    # Keep the service alive so it doesn't restart constantly
    sleep infinity
fi
