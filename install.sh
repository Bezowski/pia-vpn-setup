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
apt install -y wireguard-tools curl jq openresolv inotify-tools

# Copy scripts
echo "Installing scripts..."
cp scripts/pia-renew-and-connect-no-pf.sh /usr/local/bin/
cp scripts/pia-renew-token-only.sh /usr/local/bin/
cp scripts/pia-suspend-handler.sh /usr/local/bin/
cp scripts/update-firewall-for-port.sh /usr/local/bin/
chmod +x /usr/local/bin/pia-renew-and-connect-no-pf.sh
chmod +x /usr/local/bin/pia-renew-token-only.sh
chmod +x /usr/local/bin/pia-suspend-handler.sh
chmod +x /usr/local/bin/update-firewall-for-port.sh

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
fi

# Create persistence directory
mkdir -p /var/lib/pia
chmod 0755 /var/lib/pia

# Configure sudoers for passwordless commands
echo "Configuring sudoers for passwordless sudo..."
SUDOERS_LINE="%sudo ALL=(ALL) NOPASSWD: /usr/bin/sed, /usr/bin/systemctl, /bin/chmod, /bin/rm, /usr/bin/wg-quick"
SUDOERS_FILE="/etc/sudoers.d/pia-vpn"

# Check if line already exists
if ! grep -q "NOPASSWD: /usr/bin/sed" "$SUDOERS_FILE" 2>/dev/null; then
    # Create temporary file and validate syntax
    echo "$SUDOERS_LINE" > /tmp/pia-sudoers-tmp
    
    # Validate sudoers syntax
    if visudo -c -f /tmp/pia-sudoers-tmp >/dev/null 2>&1; then
        mv /tmp/pia-sudoers-tmp "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        echo "✓ Sudoers configured successfully"
    else
        echo "✗ Error: Invalid sudoers syntax. Aborting."
        rm -f /tmp/pia-sudoers-tmp
        exit 1
    fi
else
    echo "✓ Sudoers already configured"
fi

# Ensure region.txt has correct permissions
echo "Setting up file permissions..."
if [ -f /var/lib/pia/region.txt ]; then
    chmod 644 /var/lib/pia/region.txt
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
echo "   - Find 'PIA VPN' and click to add"
echo
echo "To toggle port forwarding on/off later:"
echo "  sudo xed /etc/pia-credentials  (change PIA_PF setting)"
echo "  sudo systemctl restart pia-port-forward.service"
echo
echo "Applet location: $APPLET_DIR"
