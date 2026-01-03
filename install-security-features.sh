#!/bin/bash
# Install PIA VPN Security Features (Kill Switch + Watchdog)

set -e

echo "PIA VPN Security Features Installer"
echo "===================================="
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./install-security-features.sh)"
   exit 1
fi

# Check for nftables
echo "Checking dependencies..."
if ! command -v nft &>/dev/null; then
    echo "Installing nftables..."
    apt update
    apt install -y nftables
fi
echo "✓ nftables is installed"

# Install kill switch script
echo
echo "Installing kill switch..."
if [ -f "scripts/pia-killswitch.sh" ]; then
    cp scripts/pia-killswitch.sh /usr/local/bin/
    chmod +x /usr/local/bin/pia-killswitch.sh
    echo "✓ Kill switch script installed"
else
    echo "✗ scripts/pia-killswitch.sh not found"
    echo "Run this script from the pia-vpn-setup repository root"
    exit 1
fi

# Install watchdog script
echo
echo "Installing watchdog..."
if [ -f "scripts/pia-watchdog.sh" ]; then
    cp scripts/pia-watchdog.sh /usr/local/bin/
    chmod +x /usr/local/bin/pia-watchdog.sh
    echo "✓ Watchdog script installed"
else
    echo "✗ scripts/pia-watchdog.sh not found"
    exit 1
fi

# Install watchdog systemd service
echo
echo "Installing systemd service..."
if [ -f "systemd/pia-watchdog.service" ]; then
    cp systemd/pia-watchdog.service /etc/systemd/system/
    systemctl daemon-reload
    echo "✓ Watchdog service installed"
else
    echo "✗ systemd/pia-watchdog.service not found"
    exit 1
fi

# Ask user about kill switch
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Kill Switch Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "The kill switch blocks ALL non-VPN traffic to prevent leaks."
echo
echo "Exceptions (these will still work):"
echo "  • Local network (LAN) access"
echo "  • Tailscale connections"
echo "  • VPN traffic"
echo
echo "WARNING: If enabled and VPN is down, you will have NO internet!"
echo

read -p "Enable kill switch now? (yes/no): " enable_killswitch

if [ "$enable_killswitch" = "yes" ]; then
    echo
    echo "Enabling kill switch..."
    if /usr/local/bin/pia-killswitch.sh enable; then
        echo "✓ Kill switch enabled"
    else
        echo "✗ Failed to enable kill switch"
    fi
fi

# Ask user about watchdog
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Watchdog Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "The watchdog monitors VPN health and auto-reconnects if it fails."
echo
echo "Features:"
echo "  • Checks VPN every 60 seconds"
echo "  • Auto-reconnects after 3 consecutive failures"
echo "  • 5-minute cooldown between reconnect attempts"
echo "  • Logs all activity"
echo

read -p "Enable watchdog service? (yes/no): " enable_watchdog

if [ "$enable_watchdog" = "yes" ]; then
    echo
    echo "Enabling watchdog..."
    systemctl enable pia-watchdog.service
    systemctl start pia-watchdog.service
    sleep 2
    systemctl status pia-watchdog.service --no-pager
    echo "✓ Watchdog enabled and started"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if [ "$enable_killswitch" = "yes" ]; then
    echo "Kill Switch Commands:"
    echo "  sudo pia-killswitch.sh status    - Check status"
    echo "  sudo pia-killswitch.sh test      - Run diagnostics"
    echo "  sudo pia-killswitch.sh disable   - Disable (if needed)"
    echo
fi

if [ "$enable_watchdog" = "yes" ]; then
    echo "Watchdog Commands:"
    echo "  sudo systemctl status pia-watchdog    - Check status"
    echo "  sudo pia-watchdog.sh status           - Detailed status"
    echo "  tail -f /var/log/pia-watchdog.log     - View live log"
    echo
fi

echo "Testing Commands:"
echo "  sudo pia-killswitch.sh test       - Test kill switch"
echo "  sudo pia-watchdog.sh check        - Check VPN health"
echo

echo "Next steps:"
echo "1. Test kill switch: sudo pia-killswitch.sh test"
echo "2. Check watchdog: sudo systemctl status pia-watchdog"
echo "3. Monitor logs: tail -f /var/log/pia-watchdog.log"
echo

if [ "$enable_killswitch" = "yes" ]; then
    echo "⚠️  IMPORTANT: Kill switch is ACTIVE"
    echo "   If VPN disconnects, you will have NO internet until:"
    echo "   - VPN reconnects (automatic with watchdog), or"
    echo "   - You disable kill switch: sudo pia-killswitch.sh disable"
    echo
fi
