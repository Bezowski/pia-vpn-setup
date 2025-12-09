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

# Install dependencies
echo "Installing dependencies..."
apt update
apt install -y wireguard-tools curl jq openresolv

# Copy scripts
echo "Installing scripts..."
cp scripts/pia-renew-and-connect.sh /usr/local/bin/
cp scripts/pia-port-forward-wrapper.sh /usr/local/bin/
cp scripts/update-firewall-for-port.sh /usr/local/bin/
chmod +x /usr/local/bin/pia-renew-and-connect.sh
chmod +x /usr/local/bin/pia-port-forward-wrapper.sh
chmod +x /usr/local/bin/update-firewall-for-port.sh

# Create and install port forwarding check script
echo "Creating port forwarding check script..."
cat > /usr/local/bin/pia-port-forward-check.sh << 'EOF'
#!/bin/bash
# Wrapper script to check PIA_PF setting before running port forwarding

set -euo pipefail

CRED_FILE="/etc/pia-credentials"

# Source the credentials file
if [ -f "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
fi

# Default to false if not set
: "${PIA_PF:=false}"

echo "Port forwarding setting: PIA_PF=$PIA_PF"

if [ "$PIA_PF" = "true" ]; then
    echo "Starting port forwarding..."
    exec /usr/local/bin/pia-port-forward-wrapper.sh
else
    echo "Port forwarding disabled (PIA_PF=$PIA_PF)"
    # Keep the service alive so it doesn't restart constantly
    sleep infinity
fi
EOF
chmod +x /usr/local/bin/pia-port-forward-check.sh

# Copy PIA manual connections scripts (with our modifications)
echo "Installing PIA manual-connections scripts..."
mkdir -p /usr/local/bin/manual-connections
cp -r manual-connections/* /usr/local/bin/manual-connections/
chmod +x /usr/local/bin/manual-connections/*.sh

# Copy systemd units
echo "Installing systemd units..."
cp systemd/pia-vpn.service /etc/systemd/system/
cp systemd/pia-renew.service /etc/systemd/system/
cp systemd/pia-renew.timer /etc/systemd/system/
cp systemd/pia-port-forward.service /etc/systemd/system/
cp systemd/pia-reconnect.service /etc/systemd/system/
cp systemd/pia-reconnect.path /etc/systemd/system/

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

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling services..."
systemctl enable pia-vpn.service
systemctl enable pia-renew.timer
systemctl enable pia-port-forward.service
systemctl enable pia-reconnect.path

echo
echo "Installation complete!"
echo
echo "Next steps:"
echo "1. Edit /etc/pia-credentials with your PIA credentials"
echo "2. Set PIA_PF=\"true\" to enable port forwarding, or PIA_PF=\"false\" to disable"
echo "3. Reboot your system"
echo "4. Check status with: systemctl status pia-vpn.service"
echo
echo "To toggle port forwarding on/off later:"
echo "  sudo nano /etc/pia-credentials  (change PIA_PF setting)"
echo "  sudo systemctl restart pia-port-forward.service"
