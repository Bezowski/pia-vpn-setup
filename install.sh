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
mkdir -p /etc/systemd/system/bluetooth.service.d
cp -r systemd/bluetooth.service.d/* /etc/systemd/system/bluetooth.service.d/

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

# Copy Bluetooth config
echo "Configuring Bluetooth..."
cp config/main.conf /etc/bluetooth/main.conf

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling services..."
systemctl enable pia-vpn.service
systemctl enable pia-renew.timer
systemctl enable pia-port-forward.service
systemctl enable pia-reconnect.path

# Restart Bluetooth
systemctl restart bluetooth

echo
echo "Installation complete!"
echo
echo "Next steps:"
echo "1. Edit /etc/pia-credentials with your PIA credentials"
echo "2. Reboot your system"
echo "3. Check status with: systemctl status pia-vpn.service"
