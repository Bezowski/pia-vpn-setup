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

# Stop the watchdog and split-tunnel watchdog FIRST, before touching the
# kill switch or the VPN - otherwise they'll try to "self-heal" the very
# things this script is about to remove.
echo "Stopping security-feature services..."
systemctl stop pia-watchdog.service 2>/dev/null || true
systemctl stop pia-split-tunnel-watch.service 2>/dev/null || true
systemctl disable pia-watchdog.service 2>/dev/null || true
systemctl disable pia-split-tunnel-watch.service 2>/dev/null || true
rm -f /etc/systemd/system/pia-watchdog.service
rm -f /etc/systemd/system/pia-split-tunnel-watch.service
echo "✓ Watchdog services stopped, disabled, and removed"

# Disable the kill switch BEFORE stopping/disconnecting the VPN below -
# its default-drop policy has no exception for "VPN is down for an
# uninstall," so doing this in the other order would leave the user with
# no internet at all for the rest of the uninstall (and until they
# noticed and disabled it manually). Fall back to a direct nft delete if
# the script is already gone from a previous partial uninstall attempt.
echo "Disabling kill switch..."
if [ -x /usr/local/bin/pia-killswitch.sh ]; then
    /usr/local/bin/pia-killswitch.sh disable 2>/dev/null || true
else
    nft delete table inet pia_killswitch 2>/dev/null || true
fi
echo "✓ Kill switch disabled"

# Remove split-tunnel routing rules (ip rule/route table, iptables mangle
# and MASQUERADE rules) - this intentionally leaves the novpn user itself
# in place, matching pia-split-tunnel.sh's own teardown command.
echo "Removing split-tunnel routing rules..."
if [ -x /usr/local/bin/pia-split-tunnel.sh ]; then
    /usr/local/bin/pia-split-tunnel.sh teardown 2>/dev/null || true
    echo "✓ Split-tunnel routing rules removed (novpn user left in place)"
else
    echo "  (pia-split-tunnel.sh not installed, skipping)"
fi

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
rm -f /usr/local/bin/pia-killswitch.sh
rm -f /usr/local/bin/pia-watchdog.sh
rm -f /usr/local/bin/pia-split-tunnel.sh
rm -f /usr/local/bin/pia-set-credential.sh
rm -f /usr/local/bin/pia-metrics.sh
rm -f /usr/local/bin/pia-stats.sh
rm -f /usr/local/bin/pia-health-check.sh
rm -f /usr/local/bin/pia-common.sh
rm -rf /usr/local/bin/manual-connections
echo "✓ Scripts removed"

# Remove Cinnamon applet. install.sh installs this per-user, under the
# real (non-root) user's home directory - not the system-wide
# /usr/share/cinnamon/applets path this step used to target, which
# install.sh never actually writes to (so that rm was always a no-op).
echo "Removing Cinnamon applet..."
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(who | awk '{print $1}' | grep -v root | head -n1)
fi
if [ -n "$REAL_USER" ]; then
    REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    rm -rf "$REAL_USER_HOME/.local/share/cinnamon/applets/pia-vpn@bezowski"
    echo "✓ Cinnamon applet removed"
else
    echo "⚠️  Could not detect non-root user, skipping applet removal"
    echo "  Remove manually: rm -rf ~/.local/share/cinnamon/applets/pia-vpn@bezowski"
fi

# Remove sudoers file
echo "Removing sudoers configuration..."
rm -f /etc/sudoers.d/pia-vpn
echo "✓ Sudoers configuration removed"

# Clean up persistence directory. Removed wholesale rather than an
# enumerated per-file list - /var/lib/pia is entirely owned by this
# project's own scripts (per README's File Locations section), and a
# hardcoded list of "known" files here would only drift out of sync as
# new state/cache/lock files get added elsewhere in the codebase, leaving
# an incomplete, silently-partial cleanup instead of an obvious error.
echo "Cleaning up data files..."
rm -rf /var/lib/pia
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
