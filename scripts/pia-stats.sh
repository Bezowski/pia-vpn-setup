#!/bin/bash
# PIA VPN Statistics Viewer
# Easy-to-use interface for viewing VPN metrics

print_header() {
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║            PIA VPN Statistics & Metrics                   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo
}

show_dashboard() {
    print_header
    
    # Get stats
    local stats=$(/usr/local/bin/pia-metrics.sh stats 2>/dev/null)
    
    if [ -z "$stats" ]; then
        echo "No metrics data available yet."
        echo "Metrics are logged automatically as you use the VPN."
        return
    fi
    
    # Parse and display
    echo "📊 Overview"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Period: \(.period.first_event) to \(.period.last_event)",
        "  Total Events: \(.events.total)",
        ""
    '
    
    echo "🔌 Connections"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Connects: \(.events.vpn_connects)",
        "  Disconnects: \(.events.vpn_disconnects)",
        "  Failures: \(.events.vpn_failures)",
        "  Average connects/day: \(.insights.average_connects_per_day)",
        ""
    '
    
    echo "🔄 Port Forwarding"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Port changes: \(.events.port_changes)",
        ""
    '
    
    echo "🔑 Authentication"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Token renewals: \(.events.token_renewals)",
        ""
    '
    
    echo "💤 Suspend/Resume"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Suspends: \(.events.suspends)",
        "  Resumes: \(.events.resumes)",
        ""
    '
    
    echo "🌍 Insights"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$stats" | jq -r '
        "  Most common region: \(.insights.most_common_region)",
        "  Estimated uptime: \(.insights.estimated_uptime_hours) hours",
        ""
    '
}

show_recent() {
    print_header
    echo "📋 Recent Events"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    /usr/local/bin/pia-metrics.sh recent "${1:-20}"
}

show_timeline() {
    print_header
    echo "📅 Connection Timeline (Last 24 Hours)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Get events from last 24 hours
    local since=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')
    /usr/local/bin/pia-metrics.sh search "VPN_CONNECTED\|VPN_DISCONNECTED" | \
        awk -F',' -v since="$since" '$1 >= since {
            gsub(/VPN_CONNECTED/, "🟢 Connected", $2);
            gsub(/VPN_DISCONNECTED/, "🔴 Disconnected", $2);
            printf "%-19s  %s\n", $1, $2
        }'
}

show_help() {
    print_header
    echo "Usage: pia-stats [command]"
    echo
    echo "Commands:"
    echo "  dashboard          Show complete statistics dashboard (default)"
    echo "  recent [n]         Show last n events (default: 20)"
    echo "  timeline           Show 24-hour connection timeline"
    echo "  export [file]      Export metrics to CSV file"
    echo "  search <term>      Search for specific events"
    echo "  help               Show this help message"
    echo
    echo "Examples:"
    echo "  pia-stats"
    echo "  pia-stats recent 50"
    echo "  pia-stats timeline"
    echo "  pia-stats export ~/vpn-metrics.csv"
    echo "  pia-stats search PORT_CHANGED"
}

# Main
case "${1:-dashboard}" in
    dashboard|stats)
        show_dashboard
        ;;
    recent)
        show_recent "$2"
        ;;
    timeline)
        show_timeline
        ;;
    export)
        /usr/local/bin/pia-metrics.sh export "$2"
        ;;
    search)
        if [ -z "$2" ]; then
            echo "Usage: pia-stats search <term>"
            exit 1
        fi
        print_header
        /usr/local/bin/pia-metrics.sh search "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'pia-stats help' for usage information"
        exit 1
        ;;
esac
