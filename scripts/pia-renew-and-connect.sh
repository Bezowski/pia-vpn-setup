#!/bin/bash
set -euo pipefail

LOCKFILE=/var/lock/pia-renew-and-connect.lock
mkdir -p /var/lock
exec 200>"$LOCKFILE"
flock -n 200 || exit 0   # exit if another instance is running; remove -n to wait

CRED_FILE="/etc/pia-credentials"
MANUAL_CONN_DIR="/usr/local/bin/manual-connections"

if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
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

# refresh region and token
# Capture output from get_region.sh to extract hostname
REGION_OUTPUT=$(./get_region.sh 2>&1)
echo "$REGION_OUTPUT"

# Extract WG_HOSTNAME from the output
export WG_HOSTNAME=$(echo "$REGION_OUTPUT" | grep -oP 'WG_HOSTNAME=\K[^ \\]+' | head -1)

./get_token.sh
# bring up WireGuard if desired/available
if [ -x ./connect_to_wireguard_with_token.sh ] && [ "${AUTOCONNECT,,}" != "false" ]; then
  ./connect_to_wireguard_with_token.sh
fi

# --- persist region (hostname + gateway) for pia-port-forward ---
PERSIST_DIR=/var/lib/pia
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
TMP="$PERSIST_DIR/region.txt.tmp"
HOSTNAME=""
GATEWAY=""

# Extract gateway from WireGuard config
if [ -f /etc/wireguard/pia.conf ]; then
  GATEWAY=$(grep "^Endpoint" /etc/wireguard/pia.conf 2>/dev/null | awk '{print $3}' | cut -d: -f1 || true)
fi

# Extract hostname from the environment variables set by get_region.sh
# These are available if get_region.sh was just run
if [ -n "${WG_HOSTNAME:-}" ]; then
  HOSTNAME="$WG_HOSTNAME"
else
  # Fallback: try to get from the most recent execution in this shell
  # by sourcing the region selection output
  HOSTNAME=$(grep "WG_HOSTNAME=" "$MANUAL_CONN_DIR"/region.txt 2>/dev/null | cut -d= -f2 || true)
fi

# If still empty, try to extract from recent journal logs of this service
if [ -z "$HOSTNAME" ]; then
  HOSTNAME=$(journalctl -u pia-vpn.service -u pia-renew.service -n 20 --no-pager 2>/dev/null | \
    grep "WG_HOSTNAME=" | tail -1 | sed 's/.*WG_HOSTNAME=\([^ ]*\).*/\1/' || true)
fi

# Write file (always create file even if values empty)
printf 'hostname=%s\ngateway=%s\n' "${HOSTNAME:-}" "${GATEWAY:-}" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PERSIST_DIR/region.txt"
# --- end persist block ---


# Schedule next renewal for 23 hours from now
NEXT_RUN=$(date -d "+23 hours" "+%Y-%m-%d %H:%M:%S")

# Update the timer configuration
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
echo "Next PIA renewal scheduled for: $NEXT_RUN"
