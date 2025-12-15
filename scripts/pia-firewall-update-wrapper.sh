#!/bin/bash
# Wrapper for firewall updates - only runs if port forwarding is enabled
# and a port file exists

set -euo pipefail

CRED_FILE="/etc/pia-credentials"
PORT_FILE="/var/lib/pia/forwarded_port"

# Check if port forwarding is enabled
if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

PIA_PF=${PIA_PF:-"false"}

# Exit cleanly if port forwarding is disabled
if [ "$PIA_PF" != "true" ]; then
  echo "Port forwarding disabled - skipping firewall update"
  exit 0
fi

# Exit cleanly if port file doesn't exist (non-PF server)
if [ ! -f "$PORT_FILE" ]; then
  echo "No forwarded port found - skipping firewall update"
  exit 0
fi

# Run the firewall update script
/usr/local/bin/update-firewall-for-port.sh
