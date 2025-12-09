#!/bin/bash
# Connect to PIA VPN on boot, testing all regions to find the fastest
# Then maintain that connection and just renew the token every 23 hours
set -euo pipefail

LOCKFILE=/var/lock/pia-renew-and-connect.lock
mkdir -p /var/lock
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"
PERSIST_DIR=/var/lib/pia

if [ -f "$CRED_FILE" ]; then
  source "$CRED_FILE"
fi

: "${PIA_USER:?PIA_USER must be set}"
: "${PIA_PASS:?PIA_PASS must be set}"
: "${PREFERRED_REGION:=aus}"
: "${PIA_PF:=false}"
: "${AUTOCONNECT:=false}"
: "${VPN_PROTOCOL:=wireguard}"
: "${DISABLE_IPV6:=yes}"
: "${PIA_DNS:=true}"
: "${MAX_LATENCY:=1}"

cd "$MANUAL_CONN_DIR"

[ -f ca.rsa.4096.crt ] || wget -qO ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

export PIA_USER PIA_PASS PREFERRED_REGION PIA_PF AUTOCONNECT VPN_PROTOCOL DISABLE_IPV6 PIA_DNS MAX_LATENCY

# Check if we already have a working VPN connection
if ip link show pia &>/dev/null && ip addr show pia | grep -q "inet "; then
  echo "VPN already connected, just renewing token..."
  # Just get a fresh token without reconnecting
  ./get_token.sh > /dev/null 2>&1
  echo "✅ Token renewed"
else
  # No VPN connection yet, test regions and connect to the fastest
  echo "No VPN connection found, testing regions to find the fastest..."
  
  # Set up for region testing
  PREFERRED_REGION=none
  AUTOCONNECT=true
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
  
  echo "✅ VPN connected to fastest region"
fi

echo "Port forwarding is managed by pia-port-forward.service (PIA_PF=$PIA_PF)"
echo "📅 Token renewal: Every 23 hours (no VPN disconnection)"
systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew || true
