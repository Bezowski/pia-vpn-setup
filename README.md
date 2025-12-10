# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

- ✅ Automatic VPN connection on boot
- ✅ Tests all regions on boot, connects to fastest
- ✅ Token renewal every 23 hours (silent, no VPN disconnection)
- ✅ Automatic port forwarding with firewall updates
- ✅ Survives suspend/resume (maintains port)
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
sudo xed /etc/pia-credentials
```

Add your PIA username, password, and desired settings.

4. Reboot:
```bash
sudo reboot
```

## Configuration

Edit `/etc/pia-credentials` to customize your setup:

```bash
PIA_USER="p1234567"              # Your PIA username
PIA_PASS="your_password"         # Your PIA password
PREFERRED_REGION=none            # Set to region code or 'none' for auto-select
AUTOCONNECT=true                 # Auto-select fastest region (true/false)
MAX_LATENCY=0.2                  # Max latency in seconds for region testing
VPN_PROTOCOL="wireguard"         # wireguard or openvpn
DISABLE_IPV6="yes"               # Disable IPv6 leaks (yes/no)
PIA_DNS="true"                   # Use PIA DNS (true/false)
PIA_PF="true"                    # Enable port forwarding (true/false)
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

View logs:
```bash
journalctl -u pia-vpn.service -f
journalctl -u pia-port-forward.service -f
journalctl -u pia-token-renew.service -f
```

## Services

- **pia-vpn.service** - Connects to fastest PIA region on boot, detects existing connections to avoid reconnecting
- **pia-token-renew.timer** - Renews authentication token every 23 hours (no VPN disconnection)
- **pia-token-renew.service** - Silent token renewal service
- **pia-port-forward.service** - Maintains port forwarding by running PIA's port_forwarding.sh with proper environment variables (PF_GATEWAY, PF_HOSTNAME, PIA_TOKEN). Automatically gets and refreshes forwarded ports every 15 minutes.
- **pia-suspend.service** - Handles suspend/resume, pauses port forwarding during sleep and resumes with same port

## How It Works

### On Boot
1. Checks if VPN is already connected
2. If not connected, tests all regions with `MAX_LATENCY` tolerance
3. Connects to the fastest responding region
4. Starts port forwarding (if `PIA_PF=true`)

### Every 23 Hours
1. Token renewal timer triggers
2. Silently renews token without disconnecting VPN
3. VPN remains active with no downtime
4. Port forwarding automatically refreshes binding

### On Suspend/Resume
1. Before suspend: Port forwarding pauses (VPN stays connected)
2. After resume: Port forwarding resumes with same port number

## Port Forwarding

Enable/disable port forwarding by editing `/etc/pia-credentials`:

```bash
PIA_PF="true"   # Enable port forwarding
PIA_PF="false"  # Disable port forwarding
```

Then restart the port forwarding service:
```bash
sudo systemctl restart pia-port-forward.service
```

The forwarded port is stored in `/var/lib/pia/forwarded_port`:
```bash
sudo cat /var/lib/pia/forwarded_port
# Output: PORT_NUMBER EXPIRY_TIMESTAMP
```

## Troubleshooting

**VPN not connecting:**
```bash
sudo systemctl status pia-vpn.service
journalctl -u pia-vpn.service -f
```

**Port forwarding not working:**
```bash
sudo systemctl status pia-port-forward.service
journalctl -u pia-port-forward.service -f
```

**Manual VPN restart:**
```bash
sudo systemctl restart pia-vpn.service
```

**Check token renewal schedule:**
```bash
sudo systemctl list-timers pia-token-renew.timer
journalctl -u pia-token-renew.service --no-pager | tail -10
```

**Test VPN connection:**
```bash
# Check WireGuard interface
ip link show pia

# Check your VPN IP
curl -s https://api.ipify.org && echo
```

## Modified Scripts

The following PIA manual-connections scripts have been modified from the original:

- `connect_to_wireguard_with_token.sh` - Added Network Manager applet reload on connect

Original scripts: https://github.com/pia-foss/manual-connections

## Credits

Setup created with assistance from Claude (Anthropic).
PIA manual-connections scripts: https://github.com/pia-foss/manual-connections
