#!/bin/bash
# PIA VPN Kill Switch
# Blocks all non-VPN traffic to prevent leaks if VPN drops

set -euo pipefail

# Configuration
KILLSWITCH_ENABLED_FILE="/var/lib/pia/killswitch-enabled"
LOCAL_NETWORK="10.234.225.0/24"  # Your local network - will be auto-detected
TAILSCALE_NETWORK="100.64.0.0/10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Auto-detect local network
detect_local_network() {
    local default_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$default_iface" ]; then
        local local_ip=$(ip -4 addr show "$default_iface" | grep -oP 'inet \K[\d.]+')
        if [ -n "$local_ip" ]; then
            # Calculate network from IP (assumes /24 subnet)
            local network_prefix=$(echo "$local_ip" | cut -d. -f1-3)
            LOCAL_NETWORK="${network_prefix}.0/24"
            echo "Detected local network: $LOCAL_NETWORK"
        fi
    fi
}

# Enable kill switch
enable_killswitch() {
    echo "Enabling PIA VPN Kill Switch..."
    
    # Auto-detect local network
    detect_local_network
    
    # Create nftables ruleset
    cat > /tmp/pia-killswitch.nft << 'EOF'
#!/usr/sbin/nft -f

# Flush existing PIA kill switch rules
table inet pia_killswitch
delete table inet pia_killswitch

# Create new table
table inet pia_killswitch {
    chain output {
        type filter hook output priority -100; policy drop;
        
        # Allow loopback
        oif "lo" accept
        
        # Allow established/related connections
        ct state established,related accept
        
        # Allow local network (LAN access)
        ip daddr LOCAL_NETWORK accept
        
        # Allow Tailscale network
        ip daddr TAILSCALE_NETWORK accept
        
        # Allow VPN interface
        oif "pia" accept
        
        # Allow DNS to VPN gateway (before VPN is up)
        udp dport 53 accept
        
        # Allow DHCP
        udp sport 68 udp dport 67 accept
        
        # Allow connection to PIA servers (for initial connection)
        # PIA uses these IP ranges for WireGuard servers
        ip daddr 173.239.192.0/18 accept  # PIA WireGuard servers
        ip daddr 154.16.0.0/12 accept     # PIA WireGuard servers
        
        # Drop everything else
        log prefix "PIA-KILLSWITCH-DROP: " drop
    }
    
    chain forward {
        type filter hook forward priority -100; policy drop;
        
        # Allow VPN forwarding
        iif "pia" accept
        oif "pia" accept
        
        # Drop everything else
        drop
    }
}
EOF

    # Replace placeholders
    sed -i "s|LOCAL_NETWORK|$LOCAL_NETWORK|g" /tmp/pia-killswitch.nft
    sed -i "s|TAILSCALE_NETWORK|$TAILSCALE_NETWORK|g" /tmp/pia-killswitch.nft
    
    # Apply rules
    if nft -f /tmp/pia-killswitch.nft; then
        print_status "Kill switch enabled"
        touch "$KILLSWITCH_ENABLED_FILE"
        
        # Verify VPN is up
        if ! ip link show pia &>/dev/null; then
            print_warning "VPN is not connected! All traffic is now blocked."
            print_warning "Connect to VPN: sudo systemctl start pia-vpn.service"
        else
            print_status "VPN is connected, traffic flowing through VPN only"
        fi
        
        rm -f /tmp/pia-killswitch.nft
        return 0
    else
        print_error "Failed to enable kill switch"
        rm -f /tmp/pia-killswitch.nft
        return 1
    fi
}

# Disable kill switch
disable_killswitch() {
    echo "Disabling PIA VPN Kill Switch..."
    
    if nft delete table inet pia_killswitch 2>/dev/null; then
        print_status "Kill switch disabled"
        rm -f "$KILLSWITCH_ENABLED_FILE"
        print_status "Normal traffic flow restored"
        return 0
    else
        print_warning "Kill switch was not active"
        rm -f "$KILLSWITCH_ENABLED_FILE"
        return 0
    fi
}

# Check kill switch status
status_killswitch() {
    echo "PIA VPN Kill Switch Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if nft list table inet pia_killswitch &>/dev/null; then
        print_status "Kill switch is ENABLED"
        
        if ip link show pia &>/dev/null; then
            print_status "VPN is connected"
            
            # Test connectivity
            if timeout 2 curl -s https://api.ipify.org &>/dev/null; then
                print_status "Internet connectivity working through VPN"
            else
                print_warning "No internet connectivity"
            fi
        else
            print_warning "VPN is NOT connected - all traffic blocked!"
        fi
        
        echo
        echo "Current rules:"
        nft list table inet pia_killswitch
    else
        print_error "Kill switch is DISABLED"
        print_warning "Traffic can leak if VPN drops!"
    fi
    
    if [ -f "$KILLSWITCH_ENABLED_FILE" ]; then
        echo
        echo "Kill switch is configured to start on boot"
    fi
}

# Test kill switch
test_killswitch() {
    echo "Testing PIA VPN Kill Switch..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! nft list table inet pia_killswitch &>/dev/null; then
        print_error "Kill switch is not enabled"
        echo "Enable it with: sudo $0 enable"
        return 1
    fi
    
    # Test 1: Check if VPN is connected
    echo
    echo "Test 1: VPN Connection"
    if ip link show pia &>/dev/null; then
        print_status "VPN interface exists"
    else
        print_error "VPN interface does not exist"
        print_warning "All traffic should be blocked"
    fi
    
    # Test 2: Check internet connectivity
    echo
    echo "Test 2: Internet Connectivity"
    if timeout 3 curl -s https://api.ipify.org &>/dev/null; then
        local public_ip=$(timeout 3 curl -s https://api.ipify.org)
        print_status "Can reach internet: $public_ip"
    else
        print_error "Cannot reach internet (expected if VPN is down)"
    fi
    
    # Test 3: Check local network access
    echo
    echo "Test 3: Local Network Access"
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ]; then
        if timeout 2 ping -c 1 "$gateway" &>/dev/null; then
            print_status "Can reach local gateway: $gateway"
        else
            print_warning "Cannot reach local gateway"
        fi
    fi
    
    # Test 4: Check Tailscale access
    echo
    echo "Test 4: Tailscale Access"
    if ip link show tailscale0 &>/dev/null; then
        local tailscale_ip=$(ip -4 addr show tailscale0 | grep -oP 'inet \K[\d.]+' | head -1)
        if [ -n "$tailscale_ip" ]; then
            print_status "Tailscale interface: $tailscale_ip"
            # Try to ping another Tailscale device if one exists
            local ts_peer=$(tailscale status --json 2>/dev/null | jq -r '.Peer | keys[0]' 2>/dev/null)
            if [ -n "$ts_peer" ] && [ "$ts_peer" != "null" ]; then
                local peer_ip=$(tailscale status --json 2>/dev/null | jq -r ".Peer[\"$ts_peer\"].TailscaleIPs[0]" 2>/dev/null)
                if [ -n "$peer_ip" ] && [ "$peer_ip" != "null" ]; then
                    if timeout 2 ping -c 1 "$peer_ip" &>/dev/null; then
                        print_status "Can reach Tailscale peer: $peer_ip"
                    else
                        print_warning "Cannot reach Tailscale peer (may be offline)"
                    fi
                fi
            fi
        fi
    else
        print_warning "Tailscale interface not found"
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test complete"
}

# Main
case "${1:-}" in
    enable)
        enable_killswitch
        ;;
    disable)
        disable_killswitch
        ;;
    status)
        status_killswitch
        ;;
    test)
        test_killswitch
        ;;
    *)
        echo "PIA VPN Kill Switch"
        echo
        echo "Usage: $0 {enable|disable|status|test}"
        echo
        echo "Commands:"
        echo "  enable   - Enable kill switch (blocks all non-VPN traffic)"
        echo "  disable  - Disable kill switch (restore normal traffic)"
        echo "  status   - Show kill switch status and rules"
        echo "  test     - Test kill switch functionality"
        echo
        echo "Examples:"
        echo "  sudo $0 enable    # Enable kill switch"
        echo "  sudo $0 status    # Check if active"
        echo "  sudo $0 test      # Run diagnostics"
        echo "  sudo $0 disable   # Disable kill switch"
        exit 1
        ;;
esac
