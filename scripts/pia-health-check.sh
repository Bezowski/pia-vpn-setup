#!/bin/bash
# PIA VPN Health Check Script
# Validates VPN connection, DNS, port forwarding, and system configuration

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

print_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# Check if running with appropriate permissions
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        if ! sudo -n true 2>/dev/null; then
            echo -e "${RED}This script needs sudo access for some checks.${NC}"
            echo "Please run with sudo or configure passwordless sudo."
            exit 1
        fi
    fi
}

# 1. System Configuration Checks
check_system_config() {
    print_header "System Configuration"
    
    # Check wireguard (package name varies by distro)
    if dpkg-query -W -f='${Status}' wireguard-tools 2>/dev/null | grep -q "install ok installed"; then
        print_pass "wireguard-tools is installed"
    elif dpkg-query -W -f='${Status}' wireguard 2>/dev/null | grep -q "install ok installed"; then
        print_pass "wireguard is installed"
    else
        print_fail "wireguard is NOT installed"
        print_info "Install with: sudo apt install wireguard-tools"
    fi

    # Check other packages
    local required_packages=("curl" "jq" "inotify-tools")
    for pkg in "${required_packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            print_pass "$pkg is installed"
        else
            print_fail "$pkg is NOT installed"
            print_info "Install with: sudo apt install $pkg"
        fi
    done
    
    # Check if scripts exist
    local scripts=(
        "/usr/local/bin/pia-renew-and-connect-no-pf.sh"
        "/usr/local/bin/pia-renew-token-only.sh"
        "/usr/local/bin/pia-suspend-handler.sh"
        "/usr/local/bin/manual-connections/port_forwarding.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [ -x "$script" ]; then
            print_pass "$(basename "$script") exists and is executable"
        else
            print_fail "$(basename "$script") missing or not executable"
            print_info "Path: $script"
        fi
    done
    
    # Check credentials file
    if [ -f /etc/pia-credentials ]; then
        print_pass "Credentials file exists"
        
        # Check if it has required variables
        if grep -q "PIA_USER=" /etc/pia-credentials && \
           grep -q "PIA_PASS=" /etc/pia-credentials; then
            print_pass "Credentials file has required variables"
        else
            print_fail "Credentials file missing PIA_USER or PIA_PASS"
        fi
        
        # Check permissions
        local perms=$(stat -c %a /etc/pia-credentials)
        if [ "$perms" = "600" ] || [ "$perms" = "640" ]; then
            print_pass "Credentials file has secure permissions ($perms)"
        else
            print_warn "Credentials file permissions are $perms (should be 600 or 640)"
        fi
    else
        print_fail "Credentials file missing at /etc/pia-credentials"
    fi
}

# 2. Systemd Service Checks
check_services() {
    print_header "Systemd Services"
    
    local services=(
        "pia-vpn.service"
        "pia-token-renew.timer"
        "pia-port-forward.service"
        "pia-suspend.service"
    )
    
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            print_pass "$service is enabled"
            
            if systemctl is-active "$service" &>/dev/null; then
                print_pass "$service is active"
            else
                print_warn "$service is enabled but not active"
                print_info "Start with: sudo systemctl start $service"
            fi
        else
            print_fail "$service is not enabled"
            print_info "Enable with: sudo systemctl enable $service"
        fi
    done
}

# 3. VPN Connection Checks
check_vpn_connection() {
    print_header "VPN Connection"
    
    # Check if interface exists
    if ip link show pia &>/dev/null; then
        print_pass "VPN interface 'pia' exists"
        
        # Check if interface has an IP
        if ip addr show pia | grep -q "inet "; then
            local vpn_ip=$(ip addr show pia | grep "inet " | awk '{print $2}')
            print_pass "VPN interface has IP: $vpn_ip"
        else
            print_fail "VPN interface exists but has no IP address"
        fi
    else
        print_fail "VPN interface 'pia' does not exist"
        print_info "VPN is not connected. Start with: sudo systemctl start pia-vpn.service"
        return
    fi
    
    # Check public IP (to verify we're using VPN)
    local public_ip=$(curl -s --max-time 5 https://api.ipify.org || echo "")
    if [ -n "$public_ip" ]; then
        print_pass "Public IP: $public_ip"
        
        # Check if it's a PIA IP (basic heuristic - check if it's different from local IP)
        print_info "Verify this is a PIA IP at: https://www.privateinternetaccess.com/pages/whats-my-ip"
    else
        print_fail "Could not determine public IP"
    fi
    
    # Check current region
    if [ -f /var/lib/pia/region.txt ]; then
        local region_hostname=$(grep "^hostname=" /var/lib/pia/region.txt | cut -d= -f2)
        if [ -n "$region_hostname" ]; then
            print_pass "Connected region: $region_hostname"
        fi
    fi
}

# 4. DNS Checks
check_dns() {
    print_header "DNS Configuration"
    
    # Check if PIA DNS is reachable
    if timeout 3 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
        print_pass "PIA DNS server (10.0.0.243) is reachable"
    else
        print_fail "Cannot reach PIA DNS server"
    fi
    
    # Check DNS resolution
    if nslookup google.com &>/dev/null; then
        print_pass "DNS resolution is working"
    else
        print_fail "DNS resolution is NOT working"
    fi
    
    # Check for DNS leaks
    print_info "For comprehensive DNS leak test, visit: https://dnsleaktest.com"
}

# 5. Port Forwarding Checks
check_port_forwarding() {
    print_header "Port Forwarding"
    
    # Check if port forwarding is enabled
    local pf_enabled="false"
    if [ -f /etc/pia-credentials ]; then
        source /etc/pia-credentials
        pf_enabled=${PIA_PF:-"false"}
    fi
    
    if [ "$pf_enabled" = "true" ]; then
        print_pass "Port forwarding is enabled in configuration"
        
        # Check if port file exists
        if [ -f /var/lib/pia/forwarded_port ]; then
            local port=$(awk '{print $1}' /var/lib/pia/forwarded_port)
            local expiry=$(awk '{print $2}' /var/lib/pia/forwarded_port)
            
            print_pass "Port file exists: $port"
            
            # Check if port is expired
            if [ -n "$expiry" ]; then
                local current_time=$(date +%s)
                if [ "$expiry" -gt "$current_time" ]; then
                    local days_left=$(( ($expiry - $current_time) / 86400 ))
                    print_pass "Port expires in $days_left days"
                else
                    print_warn "Port has expired!"
                fi
            fi
            
            # Check firewall rules
            if command -v ufw &>/dev/null; then
                if sudo ufw status | grep -q "$port"; then
                    print_pass "Firewall rule exists for port $port"
                else
                    print_fail "No firewall rule found for port $port"
                    print_info "Run: sudo /usr/local/bin/pia-firewall-update-wrapper.sh"
                fi
            fi
            
            # Test if port is actually open
            print_info "Testing if port $port is open (this takes a few seconds)..."
            local port_test=$(curl -s --max-time 10 "https://www.slsknet.org/porttest.php?port=$port" | grep -oP 'Port: \d+/tcp \K[A-Z]+' || echo "UNKNOWN")
            
            if [ "$port_test" = "open" ]; then
                print_pass "Port $port is OPEN and accessible from the internet"
            elif [ "$port_test" = "CLOSED" ]; then
                print_fail "Port $port is CLOSED"
                print_info "Wait 30 seconds and try again, or restart: sudo systemctl restart pia-port-forward.service"
            else
                print_warn "Could not test port (service may be unavailable)"
            fi
            
        else
            print_fail "Port file does not exist at /var/lib/pia/forwarded_port"
            print_info "Check service: sudo systemctl status pia-port-forward.service"
        fi
        
        # Check port forwarding service
        if systemctl is-active pia-port-forward.service &>/dev/null; then
            print_pass "Port forwarding service is running"
        else
            print_fail "Port forwarding service is NOT running"
            print_info "Start with: sudo systemctl start pia-port-forward.service"
        fi
        
    else
        print_info "Port forwarding is disabled in configuration"
        print_info "Enable by setting PIA_PF=\"true\" in /etc/pia-credentials"
    fi
}

# 6. Token Checks
check_token() {
    print_header "Authentication Token"
    
    if [ -f /var/lib/pia/token.txt ]; then
        print_pass "Token file exists"
        
        local token=$(cat /var/lib/pia/token.txt)
        local token_length=${#token}
        
        if [ "$token_length" -gt 20 ]; then
            print_pass "Token appears valid (${token_length} characters)"
        else
            print_warn "Token seems short (${token_length} characters)"
        fi
        
        # Check token renewal timer
        if systemctl is-active pia-token-renew.timer &>/dev/null; then
            print_pass "Token renewal timer is active"
            
            # Get next renewal time
            local next_run=$(systemctl list-timers pia-token-renew.timer --no-pager | grep pia-token-renew | awk '{print $1, $2, $3}')
            if [ -n "$next_run" ]; then
                print_info "Next token renewal: $next_run"
            fi
        else
            print_fail "Token renewal timer is NOT active"
        fi
    else
        print_fail "Token file missing at /var/lib/pia/token.txt"
    fi
}

# 7. IPv6 Leak Check
check_ipv6() {
    print_header "IPv6 Configuration"
    
    local ipv6_disabled_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "")
    local ipv6_disabled_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "")
    
    if [ "$ipv6_disabled_all" = "1" ] && [ "$ipv6_disabled_default" = "1" ]; then
        print_pass "IPv6 is disabled (no leak risk)"
    else
        print_warn "IPv6 is enabled (potential leak risk)"
        print_info "Disable with: sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1"
        print_info "              sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1"
    fi
}

# 8. Connectivity Tests
check_connectivity() {
    print_header "Connectivity Tests"
    
    # Test external connectivity
    if timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
        print_pass "Can reach external DNS (1.1.1.1)"
    else
        print_fail "Cannot reach external DNS"
    fi
    
    # Test HTTPS connectivity
    if curl -s --max-time 5 https://www.google.com &>/dev/null; then
        print_pass "HTTPS connectivity is working"
    else
        print_fail "HTTPS connectivity is NOT working"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════╗"
    echo "║   PIA VPN Health Check                ║"
    echo "║   $(date +'%Y-%m-%d %H:%M:%S')              ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_permissions
    check_system_config
    check_services
    check_vpn_connection
    check_dns
    check_port_forwarding
    check_token
    check_ipv6
    check_connectivity
    
    # Summary
    print_header "Summary"
    echo -e "${GREEN}Passed:${NC}   $PASSED"
    echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "${RED}Failed:${NC}   $FAILED"
    echo
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All critical checks passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some checks failed. Review the output above for details.${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
