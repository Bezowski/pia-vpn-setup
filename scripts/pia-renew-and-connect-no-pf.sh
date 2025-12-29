#!/bin/bash
# Connect to PIA VPN on boot, testing all regions to find the fastest
set -euo pipefail

# Notification wrapper
notify_if_enabled() {
    local notifications_enabled="true"
    if [ -f /etc/pia-credentials ]; then
        source /etc/pia-credentials
        notifications_enabled=${PIA_NOTIFICATIONS:-"true"}
    fi
    if [ "$notifications_enabled" = "true" ]; then
        /usr/local/bin/pia-notify.sh "$@" 2>/dev/null || true
    fi
}

LOCKFILE=/var/lock/pia-renew-and-connect.lock
mkdir -p /var/lock
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"
PERSIST_DIR=/var/lib/pia
REGION_CACHE="$PERSIST_DIR/current-region.txt"

# Source AND export credentials
if [ -f "$CRED_FILE" ]; then
  set +u
  source "$CRED_FILE"
  set -u
fi

# Export credentials for subprocesses
export PIA_USER PIA_PASS DIP_TOKEN

: "${PIA_USER:?PIA_USER must be set in $CRED_FILE}"
: "${PIA_PASS:?PIA_PASS must be set in $CRED_FILE}"
: "${PREFERRED_REGION:=none}"
: "${PIA_PF:=true}"
: "${AUTOCONNECT:=true}"
: "${VPN_PROTOCOL:=wireguard}"
: "${DISABLE_IPV6:=yes}"
: "${PIA_DNS:=true}"

cd "$MANUAL_CONN_DIR"
[ -f ca.rsa.4096.crt ] || wget -qO ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

export PREFERRED_REGION PIA_PF AUTOCONNECT VPN_PROTOCOL DISABLE_IPV6 PIA_DNS MAX_LATENCY

region_changed() {
  if [ ! -f "$REGION_CACHE" ]; then
    return 0
  fi
  local cached_region=$(cat "$REGION_CACHE" 2>/dev/null || echo "")
  [ "$cached_region" != "$PREFERRED_REGION" ]
}

disconnect_vpn() {
  echo "Disconnecting current VPN connection..."
  wg-quick down pia 2>/dev/null || true
  notify_if_enabled vpn-disconnected "Reconnecting to new region"
  sleep 2
}

save_current_region() {
  mkdir -p "$PERSIST_DIR"
  echo "$PREFERRED_REGION" > "$REGION_CACHE"
}

get_and_persist_token() {
  echo "Getting authentication token..."
  if ./get_token.sh 2>&1 | tee /tmp/get_token_output.log | grep -q "OK"; then
    echo "✓ get_token.sh succeeded"
  else
    echo "⚠️  get_token.sh had issues, checking for token file..."
  fi
  
  if [ -f /opt/piavpn-manual/token ]; then
    echo "  Token file found in /opt/piavpn-manual/token"
    mkdir -p "$PERSIST_DIR"
    head -1 /opt/piavpn-manual/token > "$PERSIST_DIR/token.txt"
    chmod 644 "$PERSIST_DIR/token.txt"
    echo "  ✓ Token persisted to $PERSIST_DIR/token.txt"
    return 0
  else
    echo "  ✗ Token file not found"
    notify_if_enabled token-failed
    return 1
  fi
}

# Check existing connection
if ip link show pia &>/dev/null && ip addr show pia | grep -q "inet "; then
  if region_changed || [ "$AUTOCONNECT" = "true" ]; then
    echo "Region preference changed, reconnecting..."
    disconnect_vpn
  else
    echo "VPN already connected, renewing token..."
    if get_and_persist_token; then
      echo "✅ Token renewed"
    else
      echo "⚠️  Token renewal failed"
    fi
    systemctl kill pia-port-forward.service 2>/dev/null || true
    sleep 1
    systemctl start pia-port-forward.service &
    touch /var/lib/pia/region.txt
    exit 0
  fi
fi

echo "Connecting to VPN..."
if [ "$AUTOCONNECT" = "true" ]; then
  PREFERRED_REGION=none
fi
export PREFERRED_REGION AUTOCONNECT

REGION_OUTPUT=$(./get_region.sh 2>&1)
echo "$REGION_OUTPUT"
export WG_HOSTNAME=$(echo "$REGION_OUTPUT" | grep -oP 'WG_HOSTNAME=\K[^ \\]+' | head -1)

# Persist region data
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
fi

printf 'hostname=%s\ngateway=%s\n' "${HOSTNAME:-}" "${GATEWAY:-}" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PERSIST_DIR/region.txt"
chmod 644 "$PERSIST_DIR/region.txt"

save_current_region

if get_and_persist_token; then
  echo "✅ Token obtained"
else
  echo "⚠️  Token persistence failed"
fi

systemctl kill pia-port-forward.service 2>/dev/null || true
sleep 1
systemctl start pia-port-forward.service &

echo "✅ VPN connected"
REGION=$(awk -F= '/^hostname=/ {print $2}' "$PERSIST_DIR/region.txt" 2>/dev/null || echo "Unknown")
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "Unknown")
notify_if_enabled vpn-connected "$REGION" "$PUBLIC_IP"

echo "Port forwarding managed by pia-port-forward.service"
systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew || true
