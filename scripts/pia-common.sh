#!/bin/bash
# PIA VPN Common Library
# Shared functions used across multiple PIA scripts

# Constants
readonly MAX_WAIT_NETWORK=30
readonly MAX_WAIT_VPN_INTERFACE=60
readonly MAX_RETRIES=5
readonly BASE_RETRY_SLEEP=2

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

# Notification wrapper - only sends if enabled in config
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
