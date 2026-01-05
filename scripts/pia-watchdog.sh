#!/bin/bash
# PIA VPN Watchdog
# Monitors VPN connection and auto-recovers if it fails

set -euo pipefail

# Configuration
CHECK_INTERVAL=60  # Check every 60 seconds
MAX_FAILURES=3     # Reconnect after 3 consecutive failures
FAILURE_COUNT=0
LAST_FAILURE_TIME=0
RECONNECT_COOLDOWN=300  # Wait 5 minutes before next reconnect attempt

# State file
STATE_DIR="/var/lib/pia"
STATE_FILE="$STATE_DIR/watchdog-state"
PAUSE_FILE="$STATE_DIR/watchdog-paused"
LOG_FILE="/var/log/pia-watchdog.log"

# Ensure directories exist
mkdir -p "$STATE_DIR"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Load state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    fi
}

# Save state
save_state() {
    cat > "$STATE_FILE" << EOF
FAILURE_COUNT=$FAILURE_COUNT
LAST_FAILURE_TIME=$LAST_FAILURE_TIME
EOF
}

# Check if VPN interface exists
check_interface() {
    if ip link show pia &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if VPN has an IP address
check_ip_address() {
    if ip addr show pia 2>/dev/null | grep -q "inet "; then
        return 0
    else
        return 1
    fi
}

# Check VPN connectivity (can we reach PIA DNS?)
check_connectivity() {
    if timeout 5 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check internet connectivity through VPN
check_internet() {
    if timeout 5 curl -s https://api.ipify.org &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Comprehensive health check
health_check() {
    local issues=()
    
    if ! check_interface; then
        issues+=("interface_missing")
    fi
    
    if ! check_ip_address; then
        issues+=("no_ip_address")
    fi
    
    if ! check_connectivity; then
        issues+=("no_pia_dns")
    fi
    
    if ! check_internet; then
        issues+=("no_internet")
    fi
    
    if [ ${#issues[@]} -eq 0 ]; then
        return 0
    else
        echo "${issues[@]}"
        return 1
    fi
}

# Attempt to recover VPN
# Attempt to recover VPN
recover_vpn() {
    log "Attempting VPN recovery..."
    
    # Check if kill switch is enabled
    local killswitch_was_on=false
    if nft list table inet pia_killswitch &>/dev/null; then
        log "Kill switch is on, temporarily disabling for reconnect..."
        killswitch_was_on=true
        /usr/local/bin/pia-killswitch.sh disable
        touch "$PERSIST_DIR/killswitch-was-enabled-watchdog"
        sleep 2
    fi
    
    # Stop port forwarding first
    systemctl stop pia-port-forward.service 2>/dev/null || true
    
    # Disconnect VPN
    wg-quick down pia 2>/dev/null || true
    sleep 2
    
    # Restart VPN service
    if systemctl restart pia-vpn.service; then
        log "✓ VPN service restarted"
        
        # Wait for VPN to come up (max 30 seconds)
        for i in {1..30}; do
            if check_interface && check_ip_address; then
                log "✓ VPN interface is up"
                
                # Wait a bit more for connectivity
                sleep 3
                
                if check_connectivity && check_internet; then
                    log "✓ VPN connectivity restored"
                    
                    # Re-enable kill switch if it was on
                    if [ "$killswitch_was_on" = true ]; then
                        log "Re-enabling kill switch..."
                        # Wait for VPN to be fully stable
                        sleep 2
                        if /usr/local/bin/pia-killswitch.sh enable; then
                            log "✓ Kill switch re-enabled"
                            rm -f "$PERSIST_DIR/killswitch-was-enabled-watchdog"
                        else
                            log "⚠️ Failed to re-enable kill switch, will retry"
                        fi
                    fi
                    
                    # Reset failure count
                    FAILURE_COUNT=0
                    save_state
                    
                    # Log metrics
                    /usr/local/bin/pia-metrics.sh log-vpn-connected "Auto-recovered" "Watchdog" 2>/dev/null || true
                    
                    return 0
                fi
            fi
            sleep 1
        done
        
        log_error "VPN interface came up but connectivity failed"
        return 1
    else
        log_error "Failed to restart VPN service"
        return 1
    fi
}

# Main monitoring loop
monitor() {
    log "PIA VPN Watchdog started (checking every ${CHECK_INTERVAL}s)"
    
    load_state
    
    while true; do
        # Check if watchdog is paused
        if [ -f "$PAUSE_FILE" ]; then
            if [ $FAILURE_COUNT -gt 0 ]; then
                log "Watchdog is paused, resetting failure count"
                FAILURE_COUNT=0
                save_state
            fi
            # Just sleep and check again
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Run health check
        if issues=$(health_check); then
            # VPN is healthy
            if [ $FAILURE_COUNT -gt 0 ]; then
                log "✓ VPN health restored (was failing)"
                FAILURE_COUNT=0
                save_state
            fi
        else
            # VPN has issues
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            log "✗ VPN health check failed ($FAILURE_COUNT/$MAX_FAILURES): $issues"
            save_state
            
            # Check if we should attempt recovery
            if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
                current_time=$(date +%s)
                time_since_last_attempt=$((current_time - LAST_FAILURE_TIME))
                
                if [ $time_since_last_attempt -lt $RECONNECT_COOLDOWN ]; then
                    log "Waiting for cooldown period (${time_since_last_attempt}s / ${RECONNECT_COOLDOWN}s)"
                else
                    log "Maximum failures reached, attempting recovery..."
                    LAST_FAILURE_TIME=$current_time
                    save_state
                    
                    if recover_vpn; then
                        log "✓ Recovery successful"
                    else
                        log_error "Recovery failed, will retry after cooldown"
                    fi
                fi
            fi
        fi
        
        # Wait before next check
        sleep $CHECK_INTERVAL
    done
}

# Check if already running
check_if_running() {
    local pidfile="/var/run/pia-watchdog.pid"
    
    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Watchdog is already running (PID: $pid)"
            return 0
        else
            rm -f "$pidfile"
        fi
    fi
    return 1
}

# Start watchdog
start_watchdog() {
    if check_if_running; then
        exit 0
    fi
    
    # Save PID
    echo $$ > /var/run/pia-watchdog.pid
    
    # Run monitor loop
    monitor
}

# Stop watchdog
stop_watchdog() {
    local pidfile="/var/run/pia-watchdog.pid"
    
    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping watchdog (PID: $pid)"
            kill "$pid"
            rm -f "$pidfile"
            echo "Watchdog stopped"
        else
            echo "Watchdog is not running"
            rm -f "$pidfile"
        fi
    else
        echo "Watchdog is not running"
    fi
}

# Show status
show_status() {
    local pidfile="/var/run/pia-watchdog.pid"
    
    echo "PIA VPN Watchdog Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            echo "✓ Watchdog is running (PID: $pid)"
            
            # Check if paused
            if [ -f "$PAUSE_FILE" ]; then
                echo "  Status: PAUSED (manual disconnect detected)"
            else
                echo "  Status: ACTIVE (monitoring)"
            fi
            
            # Show current state
            if [ -f "$STATE_FILE" ]; then
                load_state
                echo "  Failure count: $FAILURE_COUNT / $MAX_FAILURES"
                if [ $LAST_FAILURE_TIME -gt 0 ]; then
                    echo "  Last failure: $(date -d @$LAST_FAILURE_TIME '+%Y-%m-%d %H:%M:%S')"
                fi
            fi
        else
            echo "✗ Watchdog PID file exists but process is dead"
            rm -f "$pidfile"
        fi
    else
        echo "✗ Watchdog is not running"
    fi
    
    echo
    echo "Configuration:"
    echo "  Check interval: ${CHECK_INTERVAL}s"
    echo "  Max failures before recovery: $MAX_FAILURES"
    echo "  Reconnect cooldown: ${RECONNECT_COOLDOWN}s"
    
    echo
    echo "Recent log entries:"
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE"
    else
        echo "  (no log file yet)"
    fi
}

# Main
case "${1:-start}" in
    start)
        start_watchdog
        ;;
    stop)
        stop_watchdog
        ;;
    restart)
        stop_watchdog
        sleep 2
        start_watchdog
        ;;
    status)
        show_status
        ;;
    check)
        # One-time health check
        if issues=$(health_check); then
            echo "✓ VPN is healthy"
            exit 0
        else
            echo "✗ VPN has issues: $issues"
            exit 1
        fi
        ;;
    pause)
        # Pause watchdog (for manual disconnects)
        touch "$PAUSE_FILE"
        log "Watchdog paused (manual disconnect)"
        echo "✓ Watchdog paused - will not auto-reconnect"
        echo "  Resume with: sudo $0 resume"
        ;;
    resume)
        # Resume watchdog
        rm -f "$PAUSE_FILE"
        log "Watchdog resumed"
        echo "✓ Watchdog resumed - auto-reconnect enabled"
        ;;
    *)
        echo "PIA VPN Watchdog"
        echo
        echo "Usage: $0 {start|stop|restart|status|check|pause|resume}"
        echo
        echo "Commands:"
        echo "  start    - Start watchdog (monitors VPN continuously)"
        echo "  stop     - Stop watchdog"
        echo "  restart  - Restart watchdog"
        echo "  status   - Show watchdog status"
        echo "  check    - Run one-time health check"
        echo "  pause    - Pause auto-reconnect (for manual disconnects)"
        echo "  resume   - Resume auto-reconnect"
        echo
        echo "Examples:"
        echo "  sudo $0 start    # Start monitoring"
        echo "  sudo $0 pause    # Before manual disconnect"
        echo "  sudo $0 resume   # After manual reconnect"
        echo "  sudo $0 status   # Check if running"
        exit 1
        ;;
esac
