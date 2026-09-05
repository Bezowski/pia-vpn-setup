#!/bin/bash
# PIA VPN Common Library
# Shared functions used across multiple PIA scripts

# Constants
readonly MAX_WAIT_NETWORK=30
readonly MAX_WAIT_VPN_INTERFACE=60
readonly MAX_RETRIES=5
readonly BASE_RETRY_SLEEP=2

# Shared lock guarding the pia_killswitch nft table's bypass-exception rule.
# Both pia-split-tunnel.sh (setup()/watch()'s ensure_killswitch(), adding
# the exception) and pia-killswitch.sh (enable/disable, which delete and
# recreate the whole table) mutate this table from separate processes and
# must serialize on the same lock file to avoid racing each other.
#
# IMPORTANT: every caller opens this file with `9>>` (append), never `9>`
# (truncate) - nothing ever writes actual content to it (it's purely an
# flock target), but the Cinnamon applet runs
# `inotifywait -m -e modify,create /var/lib/pia/` and reacts to every
# event by refreshing its whole status display. `9>` truncates the file
# on every open even with zero bytes written, which is a real content
# modification and fires inotify's MODIFY - and watch()'s poll loop opens
# this file every 3 seconds regardless of whether anything was actually
# missing, so a `9>` here means the applet redraws (and reruns several
# subprocess spawns, including a ping) every 3 seconds forever. Verified
# empirically with inotifywait: `9>` on an existing file fires MODIFY
# every time; `9>>` fires nothing when no bytes are written.
readonly PIA_KILLSWITCH_LOCK_FILE="/var/lib/pia/killswitch-exception.lock"

# Get the real user (not root when running via sudo)
get_real_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "${SUDO_USER}"
    else
        # Fallback to who is logged in
        who | awk '{print $1}' | grep -v root | head -n1
    fi
}

# Get the user's DBUS session
get_dbus_address() {
    local user=$1
    local uid=$(id -u "$user")
    
    # Try multiple methods to find the DBUS address
    if [ -f "/run/user/$uid/bus" ]; then
        echo "unix:path=/run/user/$uid/bus"
    elif [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        echo "${DBUS_SESSION_BUS_ADDRESS}"
    else
        # Try to get it from any user process
        local pid=$(pgrep -u "$user" -x cinnamon 2>/dev/null | head -1)
        if [ -z "$pid" ]; then
            pid=$(pgrep -u "$user" -x gnome-session 2>/dev/null | head -1)
        fi
        if [ -z "$pid" ]; then
            pid=$(pgrep -u "$user" 2>/dev/null | head -1)
        fi
        
        if [ -n "$pid" ] && [ -f "/proc/$pid/environ" ]; then
            grep -z DBUS_SESSION_BUS_ADDRESS /proc/$pid/environ 2>/dev/null | cut -d= -f2- | tr -d '\0'
        fi
    fi
}


# Metrics logging wrapper
log_metric() {
    /usr/local/bin/pia-metrics.sh "$@" 2>/dev/null || true
}

# Wait for network to be ready
wait_for_network() {
    local max_wait=${1:-$MAX_WAIT_NETWORK}
    local wait_count=0
    
    echo "$(date): Waiting for network to be ready..."
    
    while [ $wait_count -lt $max_wait ]; do
        # Check if we can reach a DNS server
        if timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
            echo "$(date): ✓ Network is ready (after ${wait_count}s)"
            return 0
        fi
        
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    echo "$(date): ⚠️  Network not ready after ${max_wait}s, continuing anyway..."
    return 1
}

# Wait for VPN interface to be ready with IP
wait_for_vpn_interface() {
    local max_wait=${1:-$MAX_WAIT_VPN_INTERFACE}
    local wait_count=0
    
    echo "$(date): Waiting for VPN interface to have an IP address..."
    
    while [ $wait_count -lt $max_wait ]; do
        if ip link show pia >/dev/null 2>&1 && ip addr show pia 2>/dev/null | grep -q "inet "; then
            echo "$(date): ✓ VPN interface ready with IP (after ${wait_count}s)"
            return 0
        fi
        
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    echo "$(date): ✗ VPN interface not ready after ${max_wait}s"
    return 1
}

# Test VPN connectivity
test_vpn_connectivity() {
    echo "$(date): Testing VPN connectivity..."
    
    # Test 1: Can we reach PIA DNS server?
    if timeout 5 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
        echo "$(date): ✓ PIA DNS server responding"
        
        # Test 2: Can we reach external DNS through VPN?
        if timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
            echo "$(date): ✓ External connectivity through VPN working"
            return 0
        else
            echo "$(date): ✗ Cannot reach external DNS"
            return 1
        fi
    else
        echo "$(date): ✗ PIA DNS server not responding"
        return 1
    fi
}

# Generic retry function
# Usage: retry <max_retries> <base_sleep_seconds> <command> [args...]
retry() {
    local max_retries=$1; shift
    local base_sleep=$1; shift
    local n=0
    local rc=0
    
    while true; do
        if "$@"; then
            return 0
        else
            rc=$?
            n=$((n+1))
            if [ "$n" -ge "$max_retries" ]; then
                return $rc
            fi
            sleep $((base_sleep * n))
        fi
    done
}

# Atomic file write helper
# Usage: atomic_write <target_file> <content> [permissions]
atomic_write() {
    local target_file=$1
    local content=$2
    local perms=${3:-0644}
    
    local tmp_file=$(mktemp "${target_file}.XXXX")
    echo "$content" > "$tmp_file"
    chmod "$perms" "$tmp_file"
    mv -f "$tmp_file" "$target_file"
}

# Build the grep -E pattern for an nft "accept" rule matching a given meta
# mark. nft normalizes mark values to zero-padded hex when printing (e.g.
# 0x00000200), so a plain substring grep for "0x200" never matches - this
# tolerates the padding. Centralized here because split-tunnel bypass
# exception checks need the identical pattern in multiple scripts
# (pia-split-tunnel.sh and pia-killswitch.sh) and drifting out of sync
# already caused one bug (a watchdog that always thought the rule was
# missing and kept appending duplicates).
nft_mark_accept_pattern() {
    local mark_hex="$1"
    echo "meta mark 0x0*${mark_hex#0x} accept"
}

# Check if running as root or with sudo
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root or with sudo"
        exit 1
    fi
}

# Log to both stdout and syslog
log_info() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $msg"
    logger -t "pia-vpn" "$msg"
}

log_error() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: $msg" >&2
    logger -t "pia-vpn" -p user.err "$msg"
}

log_warn() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): WARNING: $msg" >&2
    logger -t "pia-vpn" -p user.warning "$msg"
}

# Trap handler for cleanup on error
setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO with exit code $?"' ERR
}
