#!/bin/bash
# PIA VPN Split Tunnel - route specific traffic outside the WireGuard tunnel
# Selector: a dedicated Linux user (default: novpn). Run bypass apps as:
#   sudo -u novpn -- <command>
#
# Usage: pia-split-tunnel.sh {setup|status|teardown}

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/pia-common.sh"

BYPASS_TABLE=200
BYPASS_MARK="0x200"
# Must beat wg-quick's own auto-added rules (observed at priority 8: "from
# all lookup main suppress_prefixlength 0", and priority 9: "not fwmark
# ... lookup 51820"). Priority 8's suppress_prefixlength 0 only suppresses
# a match against the literal 0.0.0.0/0 route; wg-quick's two /1 split-
# default routes (0.0.0.0/1 + 128.0.0.0/1, both via the VPN interface) have
# prefix length 1 and are NOT suppressed, so they match every destination
# and win the lookup before our rule is ever reached - regardless of
# fwmark - unless ours has a lower priority number. 1 is the lowest
# available slot after "from all lookup local" (priority 0, must stay
# first). wg-quick's auto-assigned priorities aren't guaranteed to stay at
# 8/9 forever, but nothing legitimate needs 1-7, so this leaves headroom.
BYPASS_RULE_PRIORITY=1
BYPASS_USER="${PIA_BYPASS_USER:-novpn}"
STATE_DIR="/var/lib/pia"
GATEWAY_FILE="$STATE_DIR/bypass-gateway"

# Prints which subcommand needs root, unlike pia-common.sh's generic
# require_root() - kept under a distinct name (rather than redefining
# require_root here, which would silently shadow the sourced one and trap
# a future maintainer editing pia-common.sh's version expecting it to
# apply here too).
require_root_for_command() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: run as root (sudo $0 $1)" >&2
        exit 1
    fi
}

# RTM_DELRULE removes one matching rule per call, not every matching rule -
# so a single "ip rule del fwmark ... table ..." can leave an old duplicate
# behind (e.g. one added at a stale priority by a previous version of this
# script). Loop until none match.
del_bypass_rule() {
    while ip rule del fwmark $BYPASS_MARK table $BYPASS_TABLE 2>/dev/null; do :; done
}

# Adds the kill switch bypass exception if it's missing, under a file lock
# shared with pia-killswitch.sh's enable/disable (PIA_KILLSWITCH_LOCK_FILE,
# from pia-common.sh) - without that, this script's own setup()/watch()
# calls would be serialized against each other but not against
# pia-killswitch.sh independently deleting and recreating the whole table,
# leaving a narrower but still-real window for the add to silently fail
# against a table that just vanished underneath it.
#
# setup() (invoked by pia-vpn.service's reapply on every VPN reconnect) and
# watch()'s ensure_killswitch() (polling every 3s, plus reacting to ip rule
# deletions) run as separate processes and can otherwise both observe the
# rule "missing" at the same instant and both add it - recreating the very
# duplicate-rule bug fixed elsewhere in this script, just via a race
# instead of deterministically. Returns 0 only if it just added the rule
# AND that add actually succeeded, 1 otherwise (already present, table
# doesn't exist, lock timed out, or the add itself failed - the last case
# is logged to stderr since callers can no longer tell it apart from
# "already present" just from the exit code).
add_killswitch_exception_if_missing() {
    mkdir -p "$STATE_DIR"
    (
        flock -w 5 9 || exit 1
        local current
        current=$(nft list table inet pia_killswitch 2>/dev/null) || exit 1
        echo "$current" | grep -qE "$(nft_mark_accept_pattern "$BYPASS_MARK")" && exit 1
        if ! nft add rule inet pia_killswitch output meta mark $BYPASS_MARK accept; then
            echo "$(date '+%F %T'): add_killswitch_exception_if_missing: nft add rule failed" >&2
            exit 1
        fi
        exit 0
    ) 9>>"$PIA_KILLSWITCH_LOCK_FILE"
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
    require_root_for_command setup

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

    # Rule for marked packets - see BYPASS_RULE_PRIORITY above for why this
    # must be checked before wg-quick's own rules.
    #
    # We route by fwmark, not uidrange. uidrange initially seemed better -
    # it fixed a separate source-address bug (see MASQUERADE note below) by
    # resolving the correct table at the very first route lookup. But if
    # Tailscale is installed, tailscaled's netlink route monitor can't parse
    # the FRA_UID_RANGE attribute a uidrange rule uses, logs a parse error,
    # and deletes the rule outright within seconds of it being added. fwmark
    # uses a far older, universally-supported attribute and doesn't trigger
    # this.
    del_bypass_rule
    ip rule add fwmark $BYPASS_MARK table $BYPASS_TABLE priority $BYPASS_RULE_PRIORITY

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
        add_killswitch_exception_if_missing || true
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
        nft list table inet pia_killswitch | grep -E "$(nft_mark_accept_pattern "$BYPASS_MARK")" || echo "  (missing! re-run setup)"
    fi
}

teardown() {
    require_root_for_command teardown
    del_bypass_rule
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

# Self-healing watchdog.
#  1. The ip rule - tailscaled's netlink route monitor removes this within
#     seconds (confirmed via direct on/off testing), regardless of whether
#     it's a fwmark or uidrange rule. Handled via "ip monitor rule" for
#     near-instant reaction, since a 2-3s polling gap is enough for a whole
#     curl attempt to fail before the next check would even notice.
#  2. The iptables mangle marking rule and the MASQUERADE rule can in
#     principle be removed by something external too (no confirmed trigger
#     seen so far), so they're checked on the same poll as a backstop.
#     Handled via periodic polling since there's no equivalent event stream
#     for iptables/nft changes to react to instantly.
#  Note: an earlier version of ensure_killswitch() below matched the mark
#  with a plain `grep "$BYPASS_MARK"` (e.g. "0x200"), but nft normalizes
#  mark values to zero-padded hex when printing (e.g. "0x00000200"), which
#  never matches - so it looked like the kill switch exception was
#  "disappearing" constantly when actually the check itself was just always
#  wrong, silently appending a duplicate accept rule every poll forever.
#  The regex now tolerates the padding, and the check-then-add is wrapped
#  in add_killswitch_exception_if_missing() (see above) under a flock,
#  since this poll runs as a separate process from setup()'s own
#  check-then-add and the two could otherwise race each other into adding
#  a duplicate the same way.
watch() {
    echo "$(date '+%F %T'): watchdog started"

    ensure_rule() {
        if ! ip rule show | grep -q "^${BYPASS_RULE_PRIORITY}:.*fwmark $BYPASS_MARK lookup $BYPASS_TABLE"; then
            # Clean up any stale copy at the wrong priority first (e.g. left
            # over from before BYPASS_RULE_PRIORITY was fixed to beat
            # wg-quick's own rules) - having both would still leave the
            # wrong (higher-numbered) one shadowed and useless, but it's
            # dead weight and confusing to find during debugging.
            del_bypass_rule
            ip rule add fwmark $BYPASS_MARK table $BYPASS_TABLE priority $BYPASS_RULE_PRIORITY 2>/dev/null || true
            echo "$(date '+%F %T'): ip rule missing or at wrong priority, re-added"
        fi
    }

    # `iptables -C` (check) is unreliable on this system's iptables-nft
    # backend (v1.8.10) - confirmed empirically: `iptables -t mangle -C
    # OUTPUT -m owner --uid-owner novpn -j MARK --set-mark 0x200` returned
    # exit 0 (success, "rule exists") even though `iptables -t mangle -S
    # OUTPUT` showed no such rule at all, and traffic from that user was
    # genuinely failing. This means ensure_mangle()'s (and, by the same
    # backend-level mechanism, ensure_masquerade()'s) check never actually
    # detected the rule going missing, so it could never be re-added -
    # likely the real explanation behind the "disappears on some
    # unidentified trigger" symptom this watchdog was originally written
    # to guard against. status() below already used a listing-based grep
    # instead of -C and correctly reflected reality throughout this same
    # incident, so both checks here now match that approach.
    ensure_mangle() {
        if ! iptables -t mangle -S OUTPUT | grep -q "$BYPASS_USER"; then
            echo "$(date '+%F %T'): mangle marking missing, re-adding"
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p udp --dport 53 -j RETURN 2>/dev/null || true
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -p tcp --dport 53 -j RETURN 2>/dev/null || true
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$BYPASS_USER" -j MARK --set-mark $BYPASS_MARK 2>/dev/null || true
        fi
    }

    ensure_masquerade() {
        if [ -f "$GATEWAY_FILE" ]; then
            local iface
            read -r iface _ < "$GATEWAY_FILE"
            if [ -n "$iface" ] && ! iptables -t nat -S POSTROUTING | grep -q "$BYPASS_MARK"; then
                echo "$(date '+%F %T'): MASQUERADE rule missing, re-adding"
                iptables -t nat -A POSTROUTING -o "$iface" -m mark --mark $BYPASS_MARK -j MASQUERADE 2>/dev/null || true
            fi
        fi
    }

    ensure_killswitch() {
        if nft list table inet pia_killswitch &>/dev/null; then
            if add_killswitch_exception_if_missing; then
                echo "$(date '+%F %T'): kill switch exception missing, re-adding"
            fi
        fi
    }

    ensure_all() {
        ensure_rule
        ensure_mangle
        ensure_masquerade
        ensure_killswitch
    }

    ensure_all

    # Fast path: react within milliseconds to ip rule deletions specifically
    ( stdbuf -oL ip monitor rule 2>/dev/null | while read -r line; do
        case "$line" in
            Deleted*) ensure_rule ;;
        esac
    done ) &
    MONITOR_PID=$!
    trap 'kill $MONITOR_PID 2>/dev/null || true' EXIT

    # Slow path: poll everything (including the ip rule again, as a backstop
    # in case the monitor subshell above ever dies) every few seconds
    while true; do
        sleep 3
        ensure_all
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
