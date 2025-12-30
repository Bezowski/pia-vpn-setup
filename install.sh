#!/bin/bash
set -e

echo "PIA VPN Setup Installer"
echo "======================="
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./install.sh)"
   exit 1
fi

# Check for required directories
if [ ! -d "scripts" ] || [ ! -d "manual-connections" ] || [ ! -d "systemd" ] || [ ! -d "applet" ]; then
    echo "Error: Required directories not found. Make sure you're running this from the pia-vpn-setup repo root."
    exit 1
fi

# Install dependencies
echo "Installing dependencies..."
apt update
apt install -y wireguard-tools curl jq inotify-tools

# Try to install openresolv if available (optional for some distros)
apt install -y openresolv 2>/dev/null || echo "⚠️  openresolv not available (optional)"

# Copy common library FIRST (so other scripts can use it)
echo "Installing common library..."
cp scripts/pia-common.sh /usr/local/bin/
chmod +x /usr/local/bin/pia-common.sh
echo "✓ Common library installed"

# Copy scripts
echo "Installing scripts..."
cp scripts/pia-renew-and-connect-no-pf.sh /usr/local/bin/
cp scripts/pia-renew-token-only.sh /usr/local/bin/
cp scripts/pia-suspend-handler.sh /usr/local/bin/
cp scripts/update-firewall-for-port.sh /usr/local/bin/
cp scripts/pia-port-forward-wrapper.sh /usr/local/bin/
cp scripts/pia-firewall-update-wrapper.sh /usr/local/bin/
cp scripts/pia-metrics.sh /usr/local/bin/
cp scripts/pia-stats.sh /usr/local/bin/
cp scripts/pia-notify.sh /usr/local/bin/
cp scripts/pia-health-check.sh /usr/local/bin/
chmod +x /usr/local/bin/pia-renew-and-connect-no-pf.sh
chmod +x /usr/local/bin/pia-renew-token-only.sh
chmod +x /usr/local/bin/pia-suspend-handler.sh
chmod +x /usr/local/bin/update-firewall-for-port.sh
chmod +x /usr/local/bin/pia-port-forward-wrapper.sh
chmod +x /usr/local/bin/pia-firewall-update-wrapper.sh
chmod +x /usr/local/bin/pia-metrics.sh
chmod +x /usr/local/bin/pia-stats.sh
chmod +x /usr/local/bin/pia-notify.sh
chmod +x /usr/local/bin/pia-health-check.sh

# Copy PIA manual connections scripts (with our modifications)
echo "Installing PIA manual-connections scripts..."
mkdir -p /usr/local/bin/manual-connections
cp -r manual-connections/* /usr/local/bin/manual-connections/
chmod +x /usr/local/bin/manual-connections/*.sh

# Copy systemd units
echo "Installing systemd units..."
cp systemd/pia-vpn.service /etc/systemd/system/
cp systemd/pia-token-renew.service /etc/systemd/system/
cp systemd/pia-token-renew.timer /etc/systemd/system/
cp systemd/pia-port-forward.service /etc/systemd/system/
cp systemd/pia-suspend.service /etc/systemd/system/

# Install Cinnamon applet
echo "Installing Cinnamon applet..."
APPLET_DIR="/usr/share/cinnamon/applets/pia-vpn@bezowski"
mkdir -p "$APPLET_DIR/icons"
cp applet/applet.js "$APPLET_DIR/"
cp applet/metadata.json "$APPLET_DIR/"
cp applet/settings-schema.json "$APPLET_DIR/"
cp applet/icons/connected.png "$APPLET_DIR/icons/"
cp applet/icons/disconnected.png "$APPLET_DIR/icons/"
chmod 644 "$APPLET_DIR/applet.js"
chmod 644 "$APPLET_DIR/metadata.json"
chmod 644 "$APPLET_DIR/settings-schema.json"
chmod 644 "$APPLET_DIR/icons"/*

# Setup credentials
echo
echo "Setting up credentials..."
if [ ! -f /etc/pia-credentials ]; then
    cp config/pia-credentials.example /etc/pia-credentials
    chmod 600 /etc/pia-credentials
    echo "Please edit /etc/pia-credentials with your PIA username and password"
    read -p "Press enter when ready..."
else
    echo "⚠️  /etc/pia-credentials already exists"
    read -p "Do you want to backup and replace it? (y/n): " replace_creds
    if [ "$replace_creds" = "y" ]; then
        cp /etc/pia-credentials /etc/pia-credentials.backup.$(date +%s)
        echo "✓ Backup created at /etc/pia-credentials.backup.*"
        cp config/pia-credentials.example /etc/pia-credentials
        chmod 600 /etc/pia-credentials
        echo "Please edit /etc/pia-credentials with your PIA username and password"
        read -p "Press enter when ready..."
    fi
fi

# Validate credentials format (basic check)
if [ -f /etc/pia-credentials ]; then
    if ! grep -q "PIA_USER=" /etc/pia-credentials || ! grep -q "PIA_PASS=" /etc/pia-credentials; then
        echo "⚠️  Warning: /etc/pia-credentials may be incomplete"
        echo "Please ensure it contains PIA_USER and PIA_PASS"
    fi
fi

# Create persistence directory
mkdir -p /var/lib/pia
chmod 0755 /var/lib/pia

# Create metrics directory
mkdir -p /var/lib/pia/metrics
chmod 0755 /var/lib/pia/metrics

# Configure sudoers for passwordless commands (IMPROVED SECURITY)
echo "Configuring sudoers for passwordless sudo..."
SUDOERS_FILE="/etc/sudoers.d/pia-vpn"

# Create secure sudoers content
cat > /tmp/pia-sudoers-tmp << 'EOF'
# PIA VPN Control - Specific Commands Only
# This file allows the Cinnamon applet to control PIA VPN without password prompts

# Define command aliases for better organization and security
Cmnd_Alias PIA_SED = /usr/bin/sed -i [!-]* /etc/pia-credentials
Cmnd_Alias PIA_SYSTEMCTL_START = /usr/bin/systemctl start pia-vpn.service, \
                                  /usr/bin/systemctl start pia-port-forward.service
Cmnd_Alias PIA_SYSTEMCTL_STOP = /usr/bin/systemctl stop pia-vpn.service, \
                                 /usr/bin/systemctl stop pia-port-forward.service
Cmnd_Alias PIA_SYSTEMCTL_RESTART = /usr/bin/systemctl restart pia-vpn.service, \
                                    /usr/bin/systemctl restart pia-port-forward.service
Cmnd_Alias PIA_SYSTEMCTL_STATUS = /usr/bin/systemctl status pia-vpn.service, \
                                   /usr/bin/systemctl status pia-port-forward.service, \
                                   /usr/bin/systemctl status pia-token-renew.service, \
                                   /usr/bin/systemctl status pia-token-renew.timer
Cmnd_Alias PIA_WG = /usr/bin/wg-quick up pia, \
                    /usr/bin/wg-quick down pia
Cmnd_Alias PIA_EDITOR = /usr/bin/xed /etc/pia-credentials
Cmnd_Alias PIA_CHMOD = /bin/chmod 644 /etc/pia-credentials, \
                       /bin/chmod 640 /etc/pia-credentials

# Allow sudo group to run these specific PIA commands without password
%sudo ALL=(ALL) NOPASSWD: PIA_SED, PIA_SYSTEMCTL_START, PIA_SYSTEMCTL_STOP, \
                          PIA_SYSTEMCTL_RESTART, PIA_SYSTEMCTL_STATUS, \
                          PIA_WG, PIA_EDITOR, PIA_CHMOD
EOF

# Validate sudoers syntax before installing
if visudo -c -f /tmp/pia-sudoers-tmp >/dev/null 2>&1; then
    mv /tmp/pia-sudoers-tmp "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    echo "✓ Sudoers configured successfully (restricted to specific commands)"
else
    echo "✗ Error: Invalid sudoers syntax. Aborting."
    rm -f /tmp/pia-sudoers-tmp
    exit 1
fi

# Ensure region.txt has correct permissions
echo "Setting up file permissions..."
if [ -f /var/lib/pia/region.txt ]; then
    chmod 644 /var/lib/pia/region.txt
fi

# Install logrotate configuration
echo "Installing logrotate configuration..."
if [ -f "config/pia-vpn" ]; then
    cp config/pia-vpn /etc/logrotate.d/
    chmod 644 /etc/logrotate.d/pia-vpn
    echo "✓ Logrotate configuration installed"
else
    echo "⚠️  config/pia-vpn not found, skipping logrotate configuration"
fi

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling services..."
systemctl enable pia-vpn.service
systemctl enable pia-token-renew.timer
systemctl enable pia-port-forward.service
systemctl enable pia-suspend.service

echo
echo "Installation complete!"
echo
echo "Next steps:"
echo "1. Edit /etc/pia-credentials with your PIA credentials"
echo "2. Set PIA_PF=\"true\" to enable port forwarding, or PIA_PF=\"false\" to disable"
echo "3. Reboot your system"
echo "4. Check status with: systemctl status pia-vpn.service"
echo "5. Add the PIA VPN applet to your Cinnamon panel:"
echo "   - Right-click the panel"
echo "   - Select 'Add applets to panel'"
echo "   - Find 'PIA VPN Control' and click to add"
echo
echo "To toggle port forwarding on/off later:"
echo "  sudo xed /etc/pia-credentials  (change PIA_PF setting)"
echo "  sudo systemctl restart pia-port-forward.service"
echo
echo "Security improvements applied:"
echo "  • Sudoers restricted to specific PIA commands only"
echo "  • Credentials backup created if file existed"
echo "  • All installed with validated syntax"
echo "  • Common library available for future script updates"
echo
echo "Applet location: $APPLET_DIR"
