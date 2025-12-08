# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

- ✅ Automatic VPN connection on boot
- ✅ Token renewal every 23 hours
- ✅ Automatic port forwarding with firewall updates
- ✅ Toggle port forwarding on/off via config file
- ✅ Survives suspend/resume
- ✅ Lightweight (no GUI client needed)

## Requirements

- Ubuntu/Debian-based Linux (tested on Linux Mint)
- PIA subscription
- sudo access

## Installation

1. Clone this repository:
```bash
git clone https://github.com/Bezowski/pia-vpn-setup.git
cd pia-vpn-setup
```

2. Run the installer:
```bash
sudo ./install.sh
```

3. Edit credentials:
```bash
sudo nano /etc/pia-credentials
```

Add your PIA username, password, and set `PIA_PF="true"` to enable port forwarding (or `"false"` to disable).

4. Reboot:
```bash
sudo reboot
```

## Usage

Check VPN status:
```bash
systemctl status pia-vpn.service
systemctl status pia-port-forward.service
```

View forwarded port:
```bash
sudo cat /var/lib/pia/forwarded_port
```

## Configuration

Edit `/etc/pia-credentials` to customize your setup:

```bash
PIA_USER="p1234567"              # Your PIA username
PIA_PASS="your_password"         # Your PIA password
PREFERRED_REGION="aus"           # Server region (aus, us-east, uk, etc.)
AUTOCONNECT="false"              # Auto-select fastest server
VPN_PROTOCOL="wireguard"         # wireguard or openvpn
DISABLE_IPV6="yes"               # Disable IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS
PIA_PF="true"                    # Enable port forwarding (true/false)
```

## Port Forwarding

Enable/disable port forwarding by editing `/etc/pia-credentials`:

**Enable port forwarding:**
```bash
PIA_PF="true"
sudo systemctl restart pia-port-forward.service
```

**Disable port forwarding:**
```bash
PIA_PF="false"
sudo systemctl restart pia-port-forward.service
```

The service will respect your setting and either start or stop port forwarding accordingly.

## Services

- `pia-vpn.service` - Connects VPN on boot
- `pia-renew.timer` - Renews token every 23 hours
- `pia-port-forward.service` - Maintains port forwarding (controlled by PIA_PF setting)
- `pia-reconnect.path` - Auto-resets port forwarding on reconnect

## Troubleshooting

View logs:
```bash
# VPN service
journalctl -u pia-vpn.service -f

# Port forwarding service
journalctl -u pia-port-forward.service -f

# All PIA-related logs
journalctl -g pia -f
```

Manual VPN restart:
```bash
sudo systemctl restart pia-vpn.service
```

Check if port forwarding is enabled:
```bash
sudo journalctl -u pia-port-forward.service -n 5
# Look for "Port forwarding setting: PIA_PF=true" or "PIA_PF=false"
```

## Architecture

The setup uses several components working together:

- **pia-renew-and-connect.sh** - Renews token and connects to WireGuard VPN
- **pia-port-forward-check.sh** - Checks `PIA_PF` setting before starting port forwarding
- **pia-port-forward-wrapper.sh** - Wraps port forwarding script to read persistent region data
- **port_forwarding.sh** - Handles the actual port forwarding with the PIA API
- **pia-reconnect.path** - Watches for WireGuard config changes and resets port forwarding

## Modified Scripts

The following PIA manual-connections scripts have been modified from the original:

- `port_forwarding.sh` - Updated to persist forwarded port and token
- `connect_to_wireguard_with_token.sh` - Added Network Manager applet reload
- `pia-renew-and-connect.sh` - Separated port forwarding from VPN renewal

Original scripts: https://github.com/pia-foss/manual-connections

## Credits

Setup created with assistance from Claude (Anthropic).
PIA manual-connections scripts: https://github.com/pia-foss/manual-connections
