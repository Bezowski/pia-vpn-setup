#!/bin/bash
set -euo pipefail

LOCKFILE=/var/lock/pia-renew-and-connect.lock
mkdir -p /var/lock
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"

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

cd "$MANUAL_CONN_DIR"

[ -f ca.rsa.4096.crt ] || wget -qO ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

export PIA_USER PIA_PASS PREFERRED_REGION PIA_PF AUTOCONNECT VPN_PROTOCOL DISABLE_IPV6 PIA_DNS

echo "=== PIA VPN Renewal ==="
echo "Starting at: $(date)"
echo

# Disconnect existing VPN if it's running (needed for latency testing)
echo "Step 1: Disconnecting existing VPN..."
if ip link show pia &>/dev/null; then
  echo "  Disconnecting WireGuard interface 'pia'..."
  wg-quick down pia || echo "  Warning: Failed to disconnect, but continuing..."
  sleep 2
  echo "  ✓ Disconnected"
else
  echo "  No existing VPN connection found"
fi

echo
echo "Step 2: Testing latency and selecting fastest server..."

# Refresh region and connect to VPN
# When AUTOCONNECT=true, get_region.sh will:
#   1. Call get_token.sh to get a token
#   2. Call connect_to_wireguard_with_token.sh to establish the connection
REGION_OUTPUT=$(./get_region.sh 2>&1)
echo "$REGION_OUTPUT"

# Extract WG_HOSTNAME from the output for persistence
export WG_HOSTNAME=$(echo "$REGION_OUTPUT" | grep -oP 'WG_HOSTNAME=\K[^ \\]+' | head -1)

# If AUTOCONNECT is false, we need to manually get a token
if [ "${AUTOCONNECT,,}" = "false" ]; then
  ./get_token.sh
fi

echo
echo "Step 3: Persisting region data for port forwarding..."

# --- persist region (hostname + gateway) for pia-port-forward ---
PERSIST_DIR=/var/lib/pia
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
  HOSTNAME=$(journalctl -u pia-vpn.service -u pia-renew.service -n 20 --no-pager 2>/dev/null | \
    grep "WG_HOSTNAME=" | tail -1 | sed 's/.*WG_HOSTNAME=\([^ ]*\).*/\1/' || true)
fi

printf 'hostname=%s\ngateway=%s\n' "${HOSTNAME:-}" "${GATEWAY:-}" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PERSIST_DIR/region.txt"

echo "  ✓ Region data saved"
echo "  Hostname: $HOSTNAME"
echo "  Gateway: $GATEWAY"

echo
echo "Step 4: Scheduling next renewal..."

# Schedule next renewal for 23 hours from now
NEXT_RUN=$(date -d "+23 hours" "+%Y-%m-%d %H:%M:%S")

cat > /etc/systemd/system/pia-renew.timer <<EOF
[Unit]
Description=Run PIA token renew every 23 hours

[Timer]
OnCalendar=$NEXT_RUN
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl restart pia-renew.timer

echo "  ✓ Next renewal scheduled for: $NEXT_RUN"

echo
echo "Port forwarding is managed by pia-port-forward.service (PIA_PF=$PIA_PF)"
echo
echo "=== PIA VPN Renewal Complete ==="
echo "Finished at: $(date)"
