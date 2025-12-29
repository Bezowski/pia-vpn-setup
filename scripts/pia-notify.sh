#!/bin/bash
# PIA VPN Notification Helper
# Sends desktop notifications for VPN events

# Get the real user (not root when running via sudo)
get_real_user() {
    if [ -n "${SUDO_USER}" ]; then
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
    elif [ -n "${DBUS_SESSION_BUS_ADDRESS}" ]; then
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

# Send notification
send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"
    local icon="${4:-network-vpn}"
    
    local user=$(get_real_user)
    
    if [ -z "$user" ]; then
        echo "Warning: Could not determine user for notification" >&2
        return 1
    fi
    
    local dbus_addr=$(get_dbus_address "$user")
    local uid=$(id -u "$user")
    local display=":0"
    
    # Try to send notification
    if command -v notify-send >/dev/null 2>&1; then
        sudo -u "$user" \
            DISPLAY="$display" \
            DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
            notify-send \
            --urgency="$urgency" \
            --icon="$icon" \
            --app-name="PIA VPN" \
            "$title" \
            "$message"
    else
        echo "Warning: notify-send not available" >&2
        return 1
    fi
}

# Notification types
notify_vpn_connected() {
    local region="${1:-Unknown}"
    local ip="${2:-Unknown}"
    send_notification \
        "VPN Connected" \
        "Connected to $region\nPublic IP: $ip" \
        "normal" \
        "network-vpn"
}

notify_vpn_disconnected() {
    local reason="${1:-Manual disconnect}"
    send_notification \
        "VPN Disconnected" \
        "$reason" \
        "normal" \
        "network-vpn-disconnected"
}

notify_vpn_failed() {
    local reason="${1:-Connection failed}"
    send_notification \
        "VPN Connection Failed" \
        "$reason" \
        "critical" \
        "dialog-error"
}

notify_port_changed() {
    local old_port="${1:-Unknown}"
    local new_port="${2:-Unknown}"
    send_notification \
        "Port Forwarding Updated" \
        "Port changed: $old_port → $new_port" \
        "normal" \
        "network-transmit-receive"
}

notify_port_failed() {
    local reason="${1:-Port forwarding failed}"
    send_notification \
        "Port Forwarding Failed" \
        "$reason" \
        "critical" \
        "dialog-warning"
}

notify_token_renewed() {
    send_notification \
        "Token Renewed" \
        "Authentication token renewed successfully" \
        "low" \
        "security-high"
}

notify_token_failed() {
    send_notification \
        "Token Renewal Failed" \
        "Could not renew authentication token" \
        "critical" \
        "dialog-error"
}

notify_suspend() {
    send_notification \
        "VPN Suspend" \
        "Port forwarding paused for suspend" \
        "low" \
        "system-suspend"
}

notify_resume() {
    local port="${1:-Unknown}"
    send_notification \
        "VPN Resumed" \
        "Fresh port assigned: $port" \
        "normal" \
        "system-resume"
}

# Main function - parse command line arguments
main() {
    local action="$1"
    shift
    
    case "$action" in
        vpn-connected)
            notify_vpn_connected "$@"
            ;;
        vpn-disconnected)
            notify_vpn_disconnected "$@"
            ;;
        vpn-failed)
            notify_vpn_failed "$@"
            ;;
        port-changed)
            notify_port_changed "$@"
            ;;
        port-failed)
            notify_port_failed "$@"
            ;;
        token-renewed)
            notify_token_renewed
            ;;
        token-failed)
            notify_token_failed
            ;;
        suspend)
            notify_suspend
            ;;
        resume)
            notify_resume "$@"
            ;;
        test)
            # Test notification
            send_notification "PIA VPN Test" "Notifications are working!" "normal" "dialog-information"
            ;;
        *)
            echo "Usage: $0 <action> [args...]"
            echo
            echo "Actions:"
            echo "  vpn-connected <region> <ip>"
            echo "  vpn-disconnected [reason]"
            echo "  vpn-failed [reason]"
            echo "  port-changed <old_port> <new_port>"
            echo "  port-failed [reason]"
            echo "  token-renewed"
            echo "  token-failed"
            echo "  suspend"
            echo "  resume <port>"
            echo "  test"
            exit 1
            ;;
    esac
}

# Run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
