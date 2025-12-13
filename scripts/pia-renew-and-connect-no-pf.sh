#!/bin/bash
# Connect to PIA VPN on boot, testing all regions to find the fastest
# Then maintain that connection and just renew the token every 23 hours
# Updated to support region changes
set -euo pipefail

LOCKFILE=/var/lock/pia-renew-and-connect.lock
mkdir -p /var/lock
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"
PERSIST_DIR=/var/lib/pia
REGION_CACHE="$PERSIST_DIR/current-region.txt"

if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

: "${PIA_USER:?PIA_USER must be set}"
: "${PIA_PASS:?PIA_PASS must be set}"
: "${PREFERRED_REGION:=none}"
: "${PIA_PF:=true}"
: "${AUTOCONNECT:=true}"
: "${VPN_PROTOCOL:=wireguard}"
: "${DISABLE_IPV6:=yes}"
: "${PIA_DNS:=true}"
: #"${MAX_LATENCY:=1}"

cd "$MANUAL_CONN_DIR"

[ -f ca.rsa.4096.crt ] || wget -qO ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

export PIA_USER PIA_PASS PREFERRED_REGION PIA_PF AUTOCONNECT VPN_PROTOCOL DISABLE_IPV6 PIA_DNS MAX_LATENCY

# Function to check if region changed
region_changed() {
  if [ ! -f "$REGION_CACHE" ]; then
    return 0  # No cache, consider it changed (first run)
  fi
  
  local cached_region=$(cat "$REGION_CACHE" 2>/dev/null || echo "")
  [ "$cached_region" != "$PREFERRED_REGION" ]
}

# Function to disconnect VPN
disconnect_vpn() {
  echo "Disconnecting current VPN connection..."
  wg-quick down pia 2>/dev/null || true
  sleep 2
}

# Function to save current region
save_current_region() {
  mkdir -p "$PERSIST_DIR"
  echo "$PREFERRED_REGION" > "$REGION_CACHE"
}

# Check if we already have a working VPN connection
if ip link show pia &>/dev/null && ip addr show pia | grep -q "inet "; then
  
  # VPN is connected - check if region changed OR if AUTOCONNECT is enabled
  if region_changed || [ "$AUTOCONNECT" = "true" ]; then
    echo "Region preference changed from $(cat "$REGION_CACHE" 2>/dev/null || echo "auto") to $PREFERRED_REGION"
    echo "Reconnecting to new region..."
    disconnect_vpn
    # Fall through to reconnect with new region
  else
    # Same region, just renew token
    echo "VPN already connected to $PREFERRED_REGION, just renewing token..."
    ./get_token.sh > /dev/null 2>&1
    echo "✅ Token renewed"
    echo "Port forwarding is managed by pia-port-forward.service (PIA_PF=$PIA_PF)"
    echo "📅 Token renewal: Every 23 hours (no VPN disconnection)"
    systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew || true
    exit 0
  fi
fi

# If we get here, we need to connect (either first run or region changed)
echo "No VPN connection found, testing regions to find the fastest..."

# If AUTOCONNECT is enabled, force auto-select (ignore PREFERRED_REGION)
if [ "$AUTOCONNECT" = "true" ]; then
  echo "AUTOCONNECT is enabled, will connect to fastest region..."
  PREFERRED_REGION=none
fi
export PREFERRED_REGION
export PREFERRED_REGION AUTOCONNECT

# Get region details and connect
REGION_OUTPUT=$(./get_region.sh 2>&1)
echo "$REGION_OUTPUT"

# Extract WG_HOSTNAME from the output
export WG_HOSTNAME=$(echo "$REGION_OUTPUT" | grep -oP 'WG_HOSTNAME=\K[^ \\]+' | head -1)

# --- persist region (hostname + gateway) for pia-port-forward ---
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
TMP="$PERSIST_DIR/region.txt.tmp"
HOSTNAME=""
GATEWAY=""

if [ -f /etc/wireguard/pia.conf ]; then
  GATEWAY=$(grep "^Endpoint" /etc/wireguard/pia.conf 2>/dev/null | awk '{print $3}' | cut -d: -f1 || true)
fi

if [ -n "${WG_HOSTNAME:-}" ]; then
  HOSTNAME="$WG_HOSTNAME"
else
  HOSTNAME=$(grep "WG_HOSTNAME=" "$MANUAL_CONN_DIR"/region.txt 2>/dev/null | cut -d= -f2 || true)
fi

if [ -z "$HOSTNAME" ]; then
  HOSTNAME=$(journalctl -u pia-vpn.service -n 20 --no-pager 2>/dev/null | \
    grep "WG_HOSTNAME=" | tail -1 | sed 's/.*WG_HOSTNAME=\([^ ]*\).*/\1/' || true)
fi

printf 'hostname=%s\ngateway=%s\n' "${HOSTNAME:-}" "${GATEWAY:-}" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PERSIST_DIR/region.txt"
chmod 644 "$PERSIST_DIR/region.txt"

# Save the region we just connected to
save_current_region

echo "✅ VPN connected to fastest region"
echo "Port forwarding is managed by pia-port-forward.service (PIA_PF=$PIA_PF)"
echo "📅 Token renewal: Every 23 hours (no VPN disconnection)"
systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew || true
