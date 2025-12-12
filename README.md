# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

- ✅ Automatic VPN connection on boot (fastest region)
- ✅ Token renewal every 23 hours (silent, no VPN disconnection)
- ✅ Automatic port forwarding with firewall updates
- ✅ Survives suspend/resume seamlessly (fresh ports, zero manual intervention)
- ✅ Prevents port/signature mismatches
- ✅ Lightweight (no GUI client needed)

## Suspend/Resume Support ✅

Port forwarding now **survives suspend/resume** with zero manual intervention!

**How it works:**
- Before suspend: Port forwarding pauses (VPN stays connected)
- On resume: Gets fresh port from PIA to prevent binding failures
- Nicotine+ plugin detects port change within 30 seconds
- Nicotine+ automatically reconnects to new port
- External port test passes immediately

**Why fresh ports?**
PIA's API binds each signature to a specific port. When you resume and request a new signature, you get a different port. Fresh ports ensure signature and port always match - preventing binding failures.

**Testing:**
Watch Nicotine+ logs for "Listening on port:" confirmation, then test:
```bash
PORT=$(cat /var/lib/pia/forwarded_port | awk '{print $1}')
curl -s "https://www.slsknet.org/porttest.php?port=$PORT"
```

## Requirements

- Ubuntu/Debian-based Linux (tested on Linux Mint)
- PIA subscription
- sudo access
- UFW (firewall) - for automatic port rule management

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

Add your PIA username and password.

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

- **pia-vpn.service** - Connects to fastest PIA region on boot
- **pia-token-renew.timer** - Renews authentication token every 23 hours (no VPN disconnection)
- **pia-token-renew.service** - Silent token renewal service
- **pia-port-forward.service** - Maintains port forwarding:
  - Deletes old port file on each start (forces fresh assignment)
  - Requests forwarded ports from PIA via API
  - Refreshes bindings every 15 minutes (keepalive)
  - Automatically updates UFW firewall rules
- **pia-suspend.service** - Handles suspend/resume, gets fresh ports to prevent binding failures

## How Port Forwarding Works

Port forwarding allows incoming connections on your forwarded port to reach applications like Nicotine+ running behind the VPN. Here's the flow:

1. **Service start**: Deletes old port file (forces fresh assignment)
2. **Gets gateway info**: Extracts VPN gateway IP and hostname
3. **Requests port**: Contacts PIA's API for a forwarded port and signature
4. **Binds port**: Uses the signature to bind the port on PIA's servers
5. **Updates firewall**: Removes old port rules, adds new port rule (keeps Samba/Nicotine base ports)
6. **Every 15 minutes**: Refreshes the binding with PIA to keep port active
7. **Stores port**: Writes port number to `/var/lib/pia/forwarded_port`

The forwarded port is automatically added to your UFW firewall rules, making it accessible from the internet.

## Port Forwarding Details

### Fresh Ports on Resume

When you suspend/resume:
- System disconnects from network
- Old signature becomes stale
- On resume, new signature is requested from PIA
- **Each signature is bound to a specific port**
- Service deletes port file, gets fresh port and signature
- Port and signature are now in sync ✅

### Firewall Auto-Updates

The firewall is automatically synchronized with port changes:
- When service starts: `update-firewall-for-port.sh` runs
- Old port rules are removed
- New port rule is added (with Samba/Nicotine base ports: 2240, 2242)
- Both IPv4 and IPv6 rules are updated

### Port Expiry

- Ports remain active for ~2 months
- Service refreshes binding every 15 minutes (keepalive)
- Expiry timestamp stored in `/var/lib/pia/forwarded_port`

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

**Port test shows CLOSED:**
1. Wait 30+ seconds for port assignment
2. Check service is running: `sudo systemctl status pia-port-forward.service`
3. Check firewall rule: `sudo ufw status | grep 2240,2242`
4. Check port is listening: `sudo netstat -tlnp | grep $(cat /var/lib/pia/forwarded_port | awk '{print $1}')`
5. Restart port-forward service: `sudo systemctl restart pia-port-forward.service`

**Manual VPN restart:**
```bash
sudo systemctl restart pia-vpn.service
```

**Check token renewal:**
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

**Test forwarded port:**
```bash
PORT=$(cat /var/lib/pia/forwarded_port | awk '{print $1}')
echo "Testing port $PORT..."
curl -s "https://www.slsknet.org/porttest.php?port=$PORT" | grep "open\|CLOSED"
```

## Modified Scripts

The PIA manual-connections scripts have been customized for this automated setup:

- `connect_to_wireguard_with_token.sh` - Added Network Manager applet reload

Original scripts: https://github.com/pia-foss/manual-connections

## What's Included

Core scripts:
- `connect_to_wireguard_with_token.sh` - WireGuard connection
- `get_region.sh` - Find fastest region
- `get_token.sh` - Get authentication token
- `port_forwarding.sh` - Maintain port forwarding with PIA

System scripts:
- `pia-renew-and-connect-no-pf.sh` - Boot connection with region selection
- `pia-renew-token-only.sh` - Silent token renewal
- `update-firewall-for-port.sh` - Auto-update firewall rules

Systemd services and timers for automation.

## Credits

Setup created with assistance from Claude (Anthropic).
PIA manual-connections scripts: https://github.com/pia-foss/manual-connections
