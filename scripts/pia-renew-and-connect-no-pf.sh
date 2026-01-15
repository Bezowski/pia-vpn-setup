#!/bin/bash
# Connect to PIA VPN on boot, testing all regions to find the fastest
set -euo pipefail

# Metrics logging wrapper
log_metric() {
    /usr/local/bin/pia-metrics.sh "$@" 2>/dev/null || true
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
  log_metric log-vpn-disconnected "Reconnecting to new region"
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
    log_metric log-token-failed
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

# Function to get server list (with caching)
get_server_list() {
    local CACHE_FILE="$PERSIST_DIR/server-list-cache.json"
    local CACHE_MAX_AGE=86400  # 24 hours
    local now=$(date +%s)
    
    # Check if cache exists and is fresh
    if [ -f "$CACHE_FILE" ]; then
        local cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        local cache_age=$((now - cache_mtime))
        
        if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
            echo "Using cached server list (age: ${cache_age}s)" >&2
            cat "$CACHE_FILE"
            return 0
        else
            echo "Cache expired (age: ${cache_age}s), fetching fresh list..." >&2
        fi
    else
        echo "No cache found, fetching server list..." >&2
    fi
    
    # Fetch fresh list with timeout
    local server_list=$(timeout 10 curl -s --max-time 5 \
        "https://serverlist.piaservers.net/vpninfo/servers/v7" 2>/dev/null | head -1)
    
    if [ -n "$server_list" ] && [ ${#server_list} -gt 1000 ]; then
        # Valid response (should be large JSON)
        echo "✓ Fetched fresh server list (${#server_list} bytes)" >&2
        
        # Save to cache atomically
        local tmp_cache=$(mktemp "${CACHE_FILE}.XXXX" 2>/dev/null || echo "${CACHE_FILE}.tmp")
        echo "$server_list" > "$tmp_cache"
        mv -f "$tmp_cache" "$CACHE_FILE"
        chmod 0644 "$CACHE_FILE"
        
        echo "$server_list"
        return 0
    else
        echo "Failed to fetch server list (timeout or invalid response)" >&2
        
        # If we have an old cache, use it as fallback
        if [ -f "$CACHE_FILE" ]; then
            echo "Using stale cache as fallback" >&2
            cat "$CACHE_FILE"
            return 0
        fi
        
        return 1
    fi
}

# Persist region data
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
TMP="$PERSIST_DIR/region.txt.tmp"
HOSTNAME=""
GATEWAY=""
REGION_ID=""

if [ -f /etc/wireguard/pia.conf ]; then
  GATEWAY=$(grep "^Endpoint" /etc/wireguard/pia.conf 2>/dev/null | awk '{print $3}' | cut -d: -f1 || true)
fi

if [ -n "${WG_HOSTNAME:-}" ]; then
  HOSTNAME="$WG_HOSTNAME"
fi

# Determine the actual region ID
if [ "$AUTOCONNECT" != "true" ] && [ "$PREFERRED_REGION" != "none" ]; then
  # Manual selection - use what was set
  REGION_ID="$PREFERRED_REGION"
  echo "Using manually selected region: $REGION_ID"
else
  # Autoconnect or need to look up region from gateway IP
  if [ -n "$GATEWAY" ]; then
    echo "Looking up region from gateway IP: $GATEWAY"
    
    # Get server list (cached or fresh)
    SERVER_LIST=$(get_server_list)
    
    if [ -n "$SERVER_LIST" ]; then
      # Look up region by gateway IP
      REGION_ID=$(echo "$SERVER_LIST" | \
        jq -r --arg ip "$GATEWAY" \
        '.regions[] | select(.servers.wg[]?.ip == $ip) | .id' 2>/dev/null | head -1)
      
      if [ -n "$REGION_ID" ] && [ "$REGION_ID" != "null" ]; then
        echo "✓ Matched gateway to region: $REGION_ID"
      else
        # Fallback to PREFERRED_REGION if lookup fails
        REGION_ID="$PREFERRED_REGION"
        echo "Could not match gateway, using PREFERRED_REGION: $REGION_ID"
      fi
    else
      REGION_ID="$PREFERRED_REGION"
      echo "Failed to fetch server list, using PREFERRED_REGION: $REGION_ID"
    fi
  else
    REGION_ID="$PREFERRED_REGION"
    echo "No gateway found, using PREFERRED_REGION: $REGION_ID"
  fi
fi

printf 'hostname=%s\ngateway=%s\nregion_id=%s\n' "${HOSTNAME:-}" "${GATEWAY:-}" "${REGION_ID:-}" > "$TMP"
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
log_metric log-vpn-connected "$REGION" "$PUBLIC_IP"

echo "Port forwarding managed by pia-port-forward.service"
systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew || true
