#!/bin/bash
# Install secure PIA VPN sudoers configuration

set -e

if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo $0)"
   exit 1
fi

echo "Installing secure PIA VPN sudoers configuration..."
echo

# Create the sudoers file
cat > /tmp/pia-vpn-sudoers << 'SUDOERS_EOF'
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

Cmnd_Alias PIA_WATCHDOG = /usr/local/bin/pia-watchdog.sh pause, \
                          /usr/local/bin/pia-watchdog.sh resume, \
                          /usr/local/bin/pia-watchdog.sh status, \
                          /usr/local/bin/pia-watchdog.sh check

Cmnd_Alias PIA_KILLSWITCH = /usr/local/bin/pia-killswitch.sh enable, \
                            /usr/local/bin/pia-killswitch.sh disable, \
                            /usr/local/bin/pia-killswitch.sh status

Cmnd_Alias NFT_LIST = /usr/sbin/nft list tables

Cmnd_Alias PIA_MARKER = /usr/bin/touch /var/lib/pia/killswitch-was-enabled, \
                        /bin/rm -f /var/lib/pia/killswitch-was-enabled

%sudo ALL=(ALL) NOPASSWD: PIA_SED, PIA_SYSTEMCTL_START, PIA_SYSTEMCTL_STOP, \
                          PIA_SYSTEMCTL_RESTART, PIA_SYSTEMCTL_STATUS, \
                          PIA_WG, PIA_EDITOR, PIA_CHMOD, PIA_WATCHDOG, \
                          PIA_KILLSWITCH, NFT_LIST, PIA_MARKER
SUDOERS_EOF

# Validate syntax
echo "Validating sudoers syntax..."
if visudo -c -f /tmp/pia-vpn-sudoers; then
    echo "✓ Syntax is valid"
else
    echo "✗ Invalid sudoers syntax! Aborting."
    rm -f /tmp/pia-vpn-sudoers
    exit 1
fi

# Backup existing file if it exists
if [ -f /etc/sudoers.d/pia-vpn ]; then
    BACKUP_FILE="/etc/sudoers.d/pia-vpn.backup.$(date +%s)"
    cp /etc/sudoers.d/pia-vpn "$BACKUP_FILE"
    echo "✓ Backed up existing file to $BACKUP_FILE"
fi

# Install the new file
mv /tmp/pia-vpn-sudoers /etc/sudoers.d/pia-vpn
chmod 0440 /etc/sudoers.d/pia-vpn
chown root:root /etc/sudoers.d/pia-vpn

echo "✓ Installed new sudoers file"

# Final validation
echo
echo "Final validation of complete sudoers configuration..."
if visudo -c; then
    echo "✓ All sudoers files are valid"
else
    echo "✗ Error in sudoers configuration!"
    exit 1
fi

echo
echo "✅ Secure sudoers configuration installed successfully!"
echo
echo "The following commands can now run without password:"
echo "  • sudo systemctl {start|stop|restart|status} pia-vpn.service"
echo "  • sudo systemctl {start|stop|restart|status} pia-port-forward.service"
echo "  • sudo wg-quick {up|down} pia"
echo "  • sudo sed -i ... /etc/pia-credentials"
echo "  • sudo xed /etc/pia-credentials"
echo "  • sudo chmod 644 /etc/pia-credentials"
echo
echo "All other sudo commands will still require a password."
echo
echo "Test with: sudo -n systemctl status pia-vpn.service"
