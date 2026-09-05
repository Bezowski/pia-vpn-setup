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

    # Rule for marked packets - MUST be checked before wg-quick's own rules
    # (observed on this system at priority 48-49; wg-quick's rule "not fwmark
    # 0xca6c lookup 51820" matches ANY mark other than its own loop-prevention
    # mark, so a rule numerically higher would never get reached).
    #
    # We route by fwmark, not uidrange. uidrange initially seemed better -
    # it fixed a separate source-address bug (see MASQUERADE note below) by
    # resolving the correct table at the very first route lookup. But if
    # Tailscale is installed, tailscaled's netlink route monitor can't parse
    # the FRA_UID_RANGE attribute a uidrange rule uses, logs a parse error,
    # and deletes the rule outright within seconds of it being added. fwmark
    # uses a far older, universally-supported attribute and doesn't trigger
    # this.
    ip rule del fwmark $BYPASS_MARK table $BYPASS_TABLE 2>/dev/null || true
    ip rule add fwmark $BYPASS_MARK table $BYPASS_TABLE priority 10

    # Mark all traffic from the bypass user EXCEPT DNS.
    # DNS is exempted from the mark: PIA's DNS server (10.0.0.243) is only
    # reachable inside the VPN, so anything explicitly querying it directly
    # (rather than via the local systemd-resolved stub) needs to keep going
    # through the tunnel.
    for chain_del in \
        "-p udp --dport 53 -j RETURN" \
        "-p tcp --dport 53 -j RETURN" \
        "-j MARK --set-mark $BYPASS_MARK"; do
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$BYPASS_USER" $chain_del 2>/dev/null || true
    done

    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p udp --dport 53 -j RETURN
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p tcp --dport 53 -j RETURN
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -j MARK --set-mark $BYPASS_MARK

    # Fix the source address on the way out. A fwmark set in mangle OUTPUT
    # only takes effect *after* the kernel's original (unmarked) route lookup
    # for the socket - for some socket types (e.g. ping's ICMP dgram socket)
    # that original lookup already picked the source address, and marking
    # doesn't reliably force it to be re-picked. That leaves packets going
    # out the physical interface but still carrying the VPN's internal tunnel
    # address as their source, which no router can return a reply to.
    # MASQUERADE in POSTROUTING unconditionally rewrites the source address
    # to whatever the egress interface's current address actually is,
    # regardless of what got baked in earlier - sidesteps the problem instead
    # of depending on route-reselection behaving consistently.
    iptables -t nat -D POSTROUTING -o "$IFACE" -m mark --mark $BYPASS_MARK -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$IFACE" -m mark --mark $BYPASS_MARK -j MASQUERADE

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
    echo "ip rule (fwmark -> table $BYPASS_TABLE):"
    ip rule show | grep "lookup $BYPASS_TABLE" || echo "  (not set)"
    echo
    echo "Route table $BYPASS_TABLE:"
    ip route show table $BYPASS_TABLE 2>/dev/null || echo "  (empty)"
    echo
    echo "iptables mangle rules for $BYPASS_USER:"
    iptables -t mangle -S OUTPUT | grep "$BYPASS_USER" || echo "  (none)"
    echo
    echo "iptables MASQUERADE rule (fixes source address):"
    iptables -t nat -S POSTROUTING | grep "$BYPASS_MARK" || echo "  (missing! re-run setup)"
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
    if [ -f "$GATEWAY_FILE" ]; then
        read -r IFACE _ < "$GATEWAY_FILE" 2>/dev/null || true
        if [ -n "${IFACE:-}" ]; then
            iptables -t nat -D POSTROUTING -o "$IFACE" -m mark --mark $BYPASS_MARK -j MASQUERADE 2>/dev/null || true
        fi
    fi
    echo "✓ Split tunnel rules removed (user $BYPASS_USER was left in place)"
}

# Re-apply the split tunnel automatically, but ONLY if it was already
# configured at least once before (i.e. this machine has opted in). This is
# what pia-vpn.service's ExecStartPost calls on every VPN connect/reconnect
# (boot, suspend/resume, watchdog recovery, manual reconnect from the applet)
# - the ip rule/route table don't survive any of those, but the physical
# gateway can also change between them, so a full re-run of setup() each time
# is what keeps things correct rather than just "did it once at boot".
reapply() {
    if [ -f "$GATEWAY_FILE" ] || id "$BYPASS_USER" &>/dev/null; then
        setup
    fi
}

# Launch a GUI app as the bypass user. Handles the X11 access grant so the
# app actually gets a window - "sudo -u novpn some-gui-app" on its own will
# fail because novpn has no X access by default. Run this as your normal
# user (not root); it does NOT need sudo itself, only the exec inside does.
launch() {
    if ! id "$BYPASS_USER" &>/dev/null; then
        echo "Error: bypass user '$BYPASS_USER' doesn't exist yet." >&2
        echo "Run 'sudo $0 setup' first." >&2
        exit 1
    fi
    if [ $# -eq 0 ]; then
        echo "Usage: $0 launch <command> [args...]" >&2
        echo "Example: $0 launch microsoft-edge-stable" >&2
        exit 1
    fi
    # Grant X access by UID over the local socket - no XAUTHORITY juggling needed
    xhost "+SI:localuser:$BYPASS_USER" >/dev/null 2>&1 || true
    exec sudo -u "$BYPASS_USER" env DISPLAY="${DISPLAY:-:0}" "$@"
}

# Self-healing watchdog: tailscaled's netlink route monitor removes our ip
# rule (confirmed via direct on/off testing - stopping tailscaled makes the
# rule stay put indefinitely; starting it, the rule is gone within seconds,
# every time, regardless of whether the rule uses fwmark or uidrange
# selectors). This is a bug in tailscaled's route cleanup logic, not
# something fixable from our side.
#
# A polling loop checking every few seconds isn't fast enough - once
# tailscaled deletes the rule, a curl attempt can retry for its entire
# timeout window (5+ seconds) before the next poll would even notice.
# Instead, use "ip monitor rule" to react the instant a delete happens,
# typically within milliseconds - fast enough that it shouldn't cost more
# than a single dropped packet, if that.
watch() {
    echo "$(date '+%F %T'): watchdog started (event-driven via ip monitor)"

    ensure_rule() {
        if ! ip rule show | grep -q "fwmark $BYPASS_MARK lookup $BYPASS_TABLE"; then
            ip rule add fwmark $BYPASS_MARK table $BYPASS_TABLE priority 10 2>/dev/null || true
            echo "$(date '+%F %T'): rule missing, re-added"
        fi
    }

    ensure_rule

    # "ip monitor rule" streams every rule add/delete on the system. Filter
    # for delete events, then re-check regardless of which table was
    # mentioned (parsing the line reliably across ip/iproute2 versions is
    # fragile - a redundant check-and-add is cheap and always safe).
    stdbuf -oL ip monitor rule 2>/dev/null | while read -r line; do
        case "$line" in
            Deleted*) ensure_rule ;;
        esac
    done

    # If "ip monitor rule" itself ever exits (shouldn't under normal
    # operation), fall back to polling rather than leaving nothing running.
    echo "$(date '+%F %T'): ip monitor rule exited unexpectedly, falling back to polling"
    while true; do
        ensure_rule
        sleep 2
    done
}

case "${1:-}" in
    setup) setup ;;
    status) status ;;
    teardown) teardown ;;
    reapply) reapply ;;
    launch) shift; launch "$@" ;;
    watch) watch ;;
    *)
        echo "PIA VPN Split Tunnel"
        echo
        echo "Usage: $0 {setup|status|teardown|reapply|launch <cmd>|watch}"
        echo
        echo "Commands:"
        echo "  setup     - Create bypass user + routing rules + killswitch exception"
        echo "  status    - Show current split-tunnel configuration"
        echo "  teardown  - Remove routing rules (keeps the bypass user)"
        echo "  reapply   - Re-run setup only if already configured before"
        echo "              (used automatically by pia-vpn.service on reconnect)"
        echo "  launch    - Run a GUI app as the bypass user, e.g.:"
        echo "                $0 launch microsoft-edge-stable"
        echo "  watch     - Foreground loop that re-adds the ip rule if"
        echo "              something else removes it (run as a service)"
        exit 1
        ;;
esac
