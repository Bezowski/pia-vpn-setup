#!/bin/bash
# PIA VPN Split Tunnel - route specific traffic outside the WireGuard tunnel
# Selector: a dedicated Linux user (default: novpn). Run bypass apps as:
#   sudo -u novpn -- <command>
#
# Usage: pia-split-tunnel.sh {setup|status|teardown}

set -euo pipefail

BYPASS_TABLE=200
BYPASS_MARK="0x200"
BYPASS_USER="${PIA_BYPASS_USER:-novpn}"
STATE_DIR="/var/lib/pia"
GATEWAY_FILE="$STATE_DIR/bypass-gateway"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: run as root (sudo $0 $1)" >&2
        exit 1
    fi
}

detect_physical_iface() {
    # Interface used for the physical default route (i.e. not 'pia')
    ip route show table main | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep -v '^pia$' | head -1
}

detect_physical_gateway() {
    local iface=$1
    ip route show table main | awk -v ifc="$iface" '/^default/ && $0 ~ ifc {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1
}

setup() {
    require_root setup

    echo "Setting up split tunnel bypass for user: $BYPASS_USER"

    if ! id "$BYPASS_USER" &>/dev/null; then
        echo "Creating user $BYPASS_USER..."
        useradd -r -s /usr/sbin/nologin -m "$BYPASS_USER"
    fi

    IFACE=$(detect_physical_iface)
    if [ -z "$IFACE" ]; then
        echo "Error: could not detect physical interface. Is a non-VPN default route present?" >&2
        exit 1
    fi
    GATEWAY=$(detect_physical_gateway "$IFACE")
    if [ -z "$GATEWAY" ]; then
        echo "Error: could not detect physical gateway for $IFACE." >&2
        exit 1
    fi

    echo "Physical interface: $IFACE"
    echo "Physical gateway:   $GATEWAY"

    mkdir -p "$STATE_DIR"
    echo "$IFACE $GATEWAY" > "$GATEWAY_FILE"

    # Routing table for bypass traffic -> goes out the physical gateway
    ip route flush table $BYPASS_TABLE 2>/dev/null || true
    ip route add default via "$GATEWAY" dev "$IFACE" table $BYPASS_TABLE

    # Rule for marked packets - priority 50 is checked BEFORE wg-quick's rules
    # (wg-quick typically installs its rules around priority 32764-32766)
    ip rule del fwmark $BYPASS_MARK table $BYPASS_TABLE 2>/dev/null || true
    ip rule add fwmark $BYPASS_MARK table $BYPASS_TABLE priority 50

    # Mark all traffic from the bypass user EXCEPT DNS.
    # DNS must keep going through the tunnel because PIA's DNS server
    # (10.0.0.243) is only reachable inside the VPN.
    for chain_del in \
        "-p udp --dport 53 -j RETURN" \
        "-p tcp --dport 53 -j RETURN" \
        "-j MARK --set-mark $BYPASS_MARK"; do
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$BYPASS_USER" $chain_del 2>/dev/null || true
    done

    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p udp --dport 53 -j RETURN
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p tcp --dport 53 -j RETURN
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -j MARK --set-mark $BYPASS_MARK

    # Allow bypass traffic through the kill switch, if it's active
    if nft list table inet pia_killswitch &>/dev/null; then
        nft add rule inet pia_killswitch output meta mark $BYPASS_MARK accept 2>/dev/null || true
        echo "✓ Kill switch updated to allow bypass traffic"
    fi

    echo
    echo "✓ Split tunnel ready."
    echo "Run any app outside the VPN with:"
    echo "  sudo -u $BYPASS_USER -- <command>"
}

status() {
    echo "Bypass user:    $BYPASS_USER"
    if [ -f "$GATEWAY_FILE" ]; then
        read -r IFACE GATEWAY < "$GATEWAY_FILE"
        echo "Physical iface: $IFACE"
        echo "Physical gw:    $GATEWAY"
    else
        echo "(not set up yet)"
    fi
    echo
    echo "ip rule:"
    ip rule show | grep "$BYPASS_TABLE" || echo "  (not set)"
    echo
    echo "Route table $BYPASS_TABLE:"
    ip route show table $BYPASS_TABLE 2>/dev/null || echo "  (empty)"
    echo
    echo "iptables mangle rules for $BYPASS_USER:"
    iptables -t mangle -S OUTPUT | grep "$BYPASS_USER" || echo "  (none)"
    echo
    if nft list table inet pia_killswitch &>/dev/null; then
        echo "Kill switch bypass rule:"
        nft list table inet pia_killswitch | grep "$BYPASS_MARK" || echo "  (missing! re-run setup)"
    fi
}

teardown() {
    require_root teardown
    ip rule del fwmark $BYPASS_MARK table $BYPASS_TABLE 2>/dev/null || true
    ip route flush table $BYPASS_TABLE 2>/dev/null || true
    for chain_del in \
        "-p udp --dport 53 -j RETURN" \
        "-p tcp --dport 53 -j RETURN" \
        "-j MARK --set-mark $BYPASS_MARK"; do
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$BYPASS_USER" $chain_del 2>/dev/null || true
    done
    echo "✓ Split tunnel rules removed (user $BYPASS_USER was left in place)"
}

case "${1:-}" in
    setup) setup ;;
    status) status ;;
    teardown) teardown ;;
    *)
        echo "PIA VPN Split Tunnel"
        echo
        echo "Usage: $0 {setup|status|teardown}"
        echo
        echo "Commands:"
        echo "  setup     - Create bypass user + routing rules + killswitch exception"
        echo "  status    - Show current split-tunnel configuration"
        echo "  teardown  - Remove routing rules (keeps the bypass user)"
        exit 1
        ;;
esac
