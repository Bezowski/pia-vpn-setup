# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

- ✅ Automatic VPN connection on boot
- ✅ Tests all regions on boot, connects to fastest
- ✅ Token renewal every 23 hours (silent, no VPN disconnection)
- ✅ Automatic port forwarding with firewall updates
- ✅ Survives suspend/resume (maintains port)
- ✅ Lightweight (no GUI client needed)

## Suspend/Resume Support ✅

Port forwarding now **survives suspend/resume** with zero manual intervention!

**How it works:**
- Suspend handler stops port-forward before sleep
- On resume, it deletes the old port file
- Fresh port is assigned from PIA (no signature mismatches)
- Nicotine+ plugin detects port change within 30 seconds
- Nicotine+ automatically reconnects to new port
- External port test passes immediately

**Testing:**
Watch Nicotine+ logs for "Listening on port:" confirmation, then test:
```bash
PORT=$(cat /var/lib/pia/forwarded_port | awk '{print $1}')
curl -s "https://www.slsknet.org/porttest.php?port=$PORT"
```

**Optional: Port Health Monitoring**
Enable the port monitor to auto-reset on failures:
```bash
sudo systemctl enable pia-port-monitor.timer
sudo systemctl start pia-port-monitor.timer
```
Runs every 30 minutes, checks port health, auto-resets if needed.

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
- **pia-port-forward.service** - Maintains port forwarding by running PIA's `port_forwarding.sh` script with environment variables (`PF_GATEWAY`, `PF_HOSTNAME`, `PIA_TOKEN`) automatically extracted from your VPN connection. Requests forwarded ports from PIA and refreshes bindings every 15 minutes to keep them active.
- **pia-suspend.service** - Handles suspend/resume, pauses port forwarding during sleep and resumes with same port number

## How Port Forwarding Works

Port forwarding allows incoming connections on your forwarded port to reach applications like Nicotine+ running behind the VPN. Here's the flow:

1. **On startup**: `pia-port-forward.service` extracts your VPN gateway IP and hostname from `/var/lib/pia/region.txt`
2. **Gets a port**: Contacts PIA's API to request a forwarded port and receives a signature
3. **Binds the port**: Uses the signature to bind the port on PIA's servers
4. **Every 15 minutes**: Refreshes the binding to keep the port active (PIA ports expire after ~2 months if not refreshed)
5. **Stores the port**: Writes the port number to `/var/lib/pia/forwarded_port` for use by applications and firewall rules

The forwarded port is automatically added to your UFW firewall rules by `update-firewall-for-port.sh`, making it accessible from the internet.

## Port Forwarding Limitations

- **Application binding**: Some applications (like Nicotine+) may bind to specific interface IPs instead of all interfaces. This requires either:
  - Using iptables NAT rules to redirect traffic (included in setup)
  - Or configuring the application to listen on all interfaces (0.0.0.0)
- **Port changes**: If you need a new forwarded port, stop and restart the service:
  ```bash
  sudo systemctl stop pia-port-forward.service
  sudo rm /var/lib/pia/forwarded_port
  sudo systemctl start pia-port-forward.service
  ```

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
