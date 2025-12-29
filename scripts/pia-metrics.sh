#!/bin/bash
# PIA VPN Metrics Logger
# Logs VPN events and metrics for analysis and troubleshooting

METRICS_DIR="/var/lib/pia/metrics"
METRICS_FILE="$METRICS_DIR/vpn-metrics.log"
STATS_FILE="$METRICS_DIR/stats.json"

# Ensure metrics directory exists
mkdir -p "$METRICS_DIR"
chmod 755 "$METRICS_DIR"

# Log format: TIMESTAMP,EVENT_TYPE,DATA...
log_event() {
    local event_type="$1"
    shift
    local data="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "$timestamp,$event_type,$data" >> "$METRICS_FILE"
    
    # Keep last 10000 lines only (prevent unbounded growth)
    if [ $(wc -l < "$METRICS_FILE" 2>/dev/null || echo 0) -gt 10000 ]; then
        tail -10000 "$METRICS_FILE" > "$METRICS_FILE.tmp"
        mv "$METRICS_FILE.tmp" "$METRICS_FILE"
    fi
}

# Event types
log_vpn_connected() {
    local region="${1:-Unknown}"
    local ip="${2:-Unknown}"
    log_event "VPN_CONNECTED" "region=$region,ip=$ip"
}

log_vpn_disconnected() {
    local reason="${1:-Manual}"
    log_event "VPN_DISCONNECTED" "reason=$reason"
}

log_vpn_failed() {
    local reason="${1:-Unknown}"
    log_event "VPN_FAILED" "reason=$reason"
}

log_port_changed() {
    local old_port="${1:-Unknown}"
    local new_port="${2:-Unknown}"
    log_event "PORT_CHANGED" "old=$old_port,new=$new_port"
}

log_token_renewed() {
    log_event "TOKEN_RENEWED" ""
}

log_token_failed() {
    log_event "TOKEN_FAILED" ""
}

log_suspend() {
    log_event "SUSPEND" ""
}

log_resume() {
    local port="${1:-Unknown}"
    log_event "RESUME" "port=$port"
}

log_region_changed() {
    local old_region="${1:-Unknown}"
    local new_region="${2:-Unknown}"
    log_event "REGION_CHANGED" "old=$old_region,new=$new_region"
}

# Generate statistics
generate_stats() {
    if [ ! -f "$METRICS_FILE" ]; then
        echo "{\"error\": \"No metrics data available\"}"
        return
    fi
    
    # Count events
    local total_events=$(wc -l < "$METRICS_FILE")
    local vpn_connects=$(grep -c "VPN_CONNECTED" "$METRICS_FILE" 2>/dev/null || true); vpn_connects=${vpn_connects:-0}
    local vpn_disconnects=$(grep -c "VPN_DISCONNECTED" "$METRICS_FILE" 2>/dev/null || true); vpn_disconnects=${vpn_disconnects:-0}
    local vpn_failures=$(grep -c "VPN_FAILED" "$METRICS_FILE" 2>/dev/null || true); vpn_failures=${vpn_failures:-0}
    local port_changes=$(grep -c "PORT_CHANGED" "$METRICS_FILE" 2>/dev/null || true); port_changes=${port_changes:-0}
    local token_renewals=$(grep -c "TOKEN_RENEWED" "$METRICS_FILE" 2>/dev/null || true); token_renewals=${token_renewals:-0}
    local suspends=$(grep -c "SUSPEND" "$METRICS_FILE" 2>/dev/null || true); suspends=${suspends:-0}
    local resumes=$(grep -c "RESUME" "$METRICS_FILE" 2>/dev/null || true); resumes=${resumes:-0}
    
    # Get date range
    local first_event=$(head -1 "$METRICS_FILE" | cut -d',' -f1)
    local last_event=$(tail -1 "$METRICS_FILE" | cut -d',' -f1)
    
    # Get most common region
    local most_common_region=$(grep "VPN_CONNECTED" "$METRICS_FILE" | \
        grep -oP 'region=\K[^,]+' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || echo "Unknown")
    
    # Calculate uptime (rough estimate based on connects/disconnects)
    local uptime_hours="N/A"
    if [ "$vpn_connects" -gt 0 ]; then
        uptime_hours=$(echo "scale=1; $vpn_connects * 24 / 7" | bc 2>/dev/null || echo "N/A")
    fi
    
    # Generate JSON
    cat > "$STATS_FILE" << EOF
{
  "generated_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "period": {
    "first_event": "$first_event",
    "last_event": "$last_event"
  },
  "events": {
    "total": $total_events,
    "vpn_connects": $vpn_connects,
    "vpn_disconnects": $vpn_disconnects,
    "vpn_failures": $vpn_failures,
    "port_changes": $port_changes,
    "token_renewals": $token_renewals,
    "suspends": $suspends,
    "resumes": $resumes
  },
  "insights": {
    "most_common_region": "$most_common_region",
    "estimated_uptime_hours": "$uptime_hours",
    "average_connects_per_day": $(echo "scale=1; $vpn_connects / 7" | bc 2>/dev/null || echo "0")
  }
}
EOF
    
    cat "$STATS_FILE"
}

# Show recent events
show_recent() {
    local count="${1:-20}"
    
    if [ ! -f "$METRICS_FILE" ]; then
        echo "No metrics data available"
        return
    fi
    
    echo "=== Recent VPN Events (last $count) ==="
    echo
    tail -"$count" "$METRICS_FILE" | while IFS=',' read -r timestamp event_type data; do
        printf "%-19s  %-20s  %s\n" "$timestamp" "$event_type" "$data"
    done
}

# Search events
search_events() {
    local search_term="$1"
    
    if [ ! -f "$METRICS_FILE" ]; then
        echo "No metrics data available"
        return
    fi
    
    echo "=== Events matching: $search_term ==="
    echo
    grep -i "$search_term" "$METRICS_FILE" | while IFS=',' read -r timestamp event_type data; do
        printf "%-19s  %-20s  %s\n" "$timestamp" "$event_type" "$data"
    done
}

# Export metrics for analysis
export_metrics() {
    local output_file="${1:-pia-metrics-export.csv}"
    
    if [ ! -f "$METRICS_FILE" ]; then
        echo "No metrics data available"
        return 1
    fi
    
    # Add header
    echo "timestamp,event_type,data" > "$output_file"
    cat "$METRICS_FILE" >> "$output_file"
    
    echo "Metrics exported to: $output_file"
    echo "Total events: $(wc -l < "$METRICS_FILE")"
}

# Clear old metrics
clear_metrics() {
    local confirm="$1"
    
    if [ "$confirm" != "yes" ]; then
        echo "This will delete all metrics data!"
        echo "Run with: $0 clear yes"
        return 1
    fi
    
    rm -f "$METRICS_FILE"
    rm -f "$STATS_FILE"
    echo "Metrics cleared"
}

# Main function
main() {
    local action="$1"
    shift
    
    case "$action" in
        log-vpn-connected)
            log_vpn_connected "$@"
            ;;
        log-vpn-disconnected)
            log_vpn_disconnected "$@"
            ;;
        log-vpn-failed)
            log_vpn_failed "$@"
            ;;
        log-port-changed)
            log_port_changed "$@"
            ;;
        log-token-renewed)
            log_token_renewed
            ;;
        log-token-failed)
            log_token_failed
            ;;
        log-suspend)
            log_suspend
            ;;
        log-resume)
            log_resume "$@"
            ;;
        log-region-changed)
            log_region_changed "$@"
            ;;
        stats)
            generate_stats
            ;;
        recent)
            show_recent "$@"
            ;;
        search)
            search_events "$@"
            ;;
        export)
            export_metrics "$@"
            ;;
        clear)
            clear_metrics "$@"
            ;;
        *)
            echo "Usage: $0 <action> [args...]"
            echo
            echo "Logging actions:"
            echo "  log-vpn-connected <region> <ip>"
            echo "  log-vpn-disconnected [reason]"
            echo "  log-vpn-failed [reason]"
            echo "  log-port-changed <old_port> <new_port>"
            echo "  log-token-renewed"
            echo "  log-token-failed"
            echo "  log-suspend"
            echo "  log-resume <port>"
            echo "  log-region-changed <old_region> <new_region>"
            echo
            echo "Analysis actions:"
            echo "  stats                    - Generate statistics"
            echo "  recent [count]           - Show recent events (default: 20)"
            echo "  search <term>            - Search events"
            echo "  export [file]            - Export to CSV"
            echo "  clear yes                - Clear all metrics"
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
