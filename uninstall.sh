#!/bin/bash
set -e

echo "PIA VPN Setup Uninstaller"
echo "========================="
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./uninstall.sh)"
   exit 1
fi

# Confirmation
echo "WARNING: This will uninstall PIA VPN setup and disconnect the VPN."
echo "Your configuration files will be preserved in /etc/pia-credentials"
echo
read -p "Are you sure you want to continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
   echo "Cancelled."
   exit 0
fi

echo
echo "Starting uninstallation..."
echo

# Stop services
echo "Stopping services..."
systemctl stop pia-vpn.service 2>/dev/null || true
systemctl stop pia-port-forward.service 2>/dev/null || true
systemctl stop pia-token-renew.timer 2>/dev/null || true
systemctl stop pia-token-renew.service 2>/dev/null || true
systemctl stop pia-suspend.service 2>/dev/null || true
systemctl stop pia-port-forward.path 2>/dev/null || true
echo "✓ Services stopped"

# Disable services
echo "Disabling services..."
systemctl disable pia-vpn.service 2>/dev/null || true
systemctl disable pia-port-forward.service 2>/dev/null || true
systemctl disable pia-token-renew.timer 2>/dev/null || true
systemctl disable pia-token-renew.service 2>/dev/null || true
systemctl disable pia-suspend.service 2>/dev/null || true
systemctl disable pia-port-forward.path 2>/dev/null || true
echo "✓ Services disabled"

# Remove systemd units
echo "Removing systemd units..."
rm -f /etc/systemd/system/pia-vpn.service
rm -f /etc/systemd/system/pia-port-forward.service
rm -f /etc/systemd/system/pia-port-forward.path
rm -f /etc/systemd/system/pia-token-renew.service
rm -f /etc/systemd/system/pia-token-renew.timer
rm -f /etc/systemd/system/pia-suspend.service
systemctl daemon-reload
echo "✓ Systemd units removed"

# Disconnect VPN
echo "Disconnecting VPN..."
wg-quick down pia 2>/dev/null || true
echo "✓ VPN disconnected"

# Remove scripts
echo "Removing scripts..."
rm -f /usr/local/bin/pia-renew-and-connect-no-pf.sh
rm -f /usr/local/bin/pia-renew-token-only.sh
rm -f /usr/local/bin/pia-suspend-handler.sh
rm -f /usr/local/bin/update-firewall-for-port.sh
rm -f /usr/local/bin/pia-firewall-update-wrapper.sh
rm -f /usr/local/bin/pia-port-forward-wrapper.sh
rm -rf /usr/local/bin/manual-connections
echo "✓ Scripts removed"

# Remove Cinnamon applet
echo "Removing Cinnamon applet..."
rm -rf /usr/share/cinnamon/applets/pia-vpn@bezowski
echo "✓ Cinnamon applet removed"

# Remove sudoers file
echo "Removing sudoers configuration..."
rm -f /etc/sudoers.d/pia-vpn
echo "✓ Sudoers configuration removed"

# Clean up persistence directory
echo "Cleaning up data files..."
rm -f /var/lib/pia/token.txt
rm -f /var/lib/pia/token.txt.with-expiry
rm -f /var/lib/pia/forwarded_port
rm -f /var/lib/pia/region.txt
rm -f /var/lib/pia/current-region.txt
rmdir /var/lib/pia 2>/dev/null || true
echo "✓ Data files removed"

# Remove firewall rules
echo "Removing firewall rules..."
ufw delete allow 2240,2242/tcp 2>/dev/null || true
ufw delete allow 2240,2242 2>/dev/null || true
echo "✓ Firewall rules removed"

echo
echo "=== Uninstallation Complete ==="
echo
echo "The following were preserved:"
echo "  • /etc/pia-credentials - Your PIA credentials (not removed for safety)"
echo "  • Installed packages (wireguard-tools, curl, jq, etc.)"
echo
echo "To remove credentials file manually:"
echo "  sudo rm /etc/pia-credentials"
echo
echo "To remove installed packages:"
echo "  sudo apt remove wireguard-tools curl jq openresolv inotify-tools"
echo
echo "To remove the repository:"
echo "  rm -rf ~/projects/pia-vpn-setup"
echo
