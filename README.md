# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

* ✅ Automatic VPN connection on boot (fastest region or selected region)
* ✅ Token renewal every 23 hours (silent, no VPN disconnection)
* ✅ Automatic port forwarding with firewall updates
* ✅ Survives suspend/resume with fresh port assignment
* ✅ Comprehensive metrics logging and analysis
* ✅ Health check script with detailed diagnostics
* ✅ **Cinnamon applet for easy server selection and VPN management**
* ✅ Atomic file writes to prevent race conditions
* ✅ Shared function library for maintainability
* ✅ Automatic log rotation (prevents unbounded growth)
* ✅ Lightweight (no official GUI client needed)

## Requirements

* Ubuntu/Debian-based Linux (tested on Linux Mint 22.2)
* Cinnamon desktop environment (for applet support)
* PIA subscription
* sudo access
* UFW (firewall) - for automatic port rule management

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

Add your PIA username and password:

```bash
PIA_USER="p1234567"
PIA_PASS="your_password_here"
PIA_PF="true"                    # Enable port forwarding
AUTOCONNECT="true"               # Auto-connect on boot
PREFERRED_REGION="none"          # Auto-select optimal region
DISABLE_IPV6="yes"               # Disable IPv6 to prevent leaks
PIA_NOTIFICATIONS="true"         # Enable desktop notifications (optional)
```

4. Reboot:

```bash
sudo reboot
```

## Usage

### Basic Commands

Check VPN status:

```bash
systemctl status pia-vpn.service
systemctl status pia-port-forward.service
```

View forwarded port:

```bash
sudo cat /var/lib/pia/forwarded_port
```

Manual VPN restart:

```bash
sudo systemctl restart pia-vpn.service
```

### Health Check

Run comprehensive diagnostics:

```bash
sudo /usr/local/bin/pia-health-check.sh
```

The health check validates:
- System configuration (packages, scripts, credentials)
- Systemd services status
- VPN connection and public IP
- DNS configuration and potential leaks
- Port forwarding (file, firewall, actual connectivity)
- Authentication token and renewal timer
- IPv6 configuration
- External connectivity

### Metrics and Statistics

View VPN usage statistics:

```bash
# Interactive dashboard
sudo /usr/local/bin/pia-stats.sh dashboard

# Recent events
sudo /usr/local/bin/pia-stats.sh recent 50

# View timeline (last 24 hours)
sudo /usr/local/bin/pia-stats.sh timeline

# Export metrics to CSV
sudo /usr/local/bin/pia-stats.sh export pia-metrics.csv

# Search events
sudo /usr/local/bin/pia-stats.sh search "PORT_CHANGED"
```

Metrics tracked:
- VPN connections/disconnections with region and IP
- Port forwarding changes
- Token renewals (success/failure)
- Suspend/resume events
- Region changes
- Connection failures

Metrics are stored in `/var/lib/pia/metrics/vpn-metrics.log` with automatic rotation (last 10,000 events).

## Services

* `pia-vpn.service` - Connects VPN on boot
* `pia-token-renew.timer` - Renews token every 23 hours
* `pia-port-forward.service` - Maintains port forwarding
* `pia-suspend.service` - Handles suspend/resume events

## Configuration Options

Edit `/etc/pia-credentials` to customize:

```bash
# Required
PIA_USER="p1234567"
PIA_PASS="your_password"

# Port Forwarding
PIA_PF="true"                    # Enable/disable port forwarding

# Connection Settings
AUTOCONNECT="true"               # Auto-connect on boot
PREFERRED_REGION="none"          # Specific region or "none" for auto-select
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
```

**For detailed configuration examples and scenarios**, see [CONFIGURATION.md](CONFIGURATION.md)

Available regions can be found by running:

```bash
curl -s "https://serverlist.piaservers.net/vpninfo/servers/v6" | \
  jq -r '.regions[] | select(.port_forward==true) | .id'
```

## Troubleshooting

### View Logs

```bash
# VPN service logs
journalctl -u pia-vpn.service -f

# Port forwarding logs
journalctl -u pia-port-forward.service -f

# Token renewal logs
journalctl -u pia-token-renew.service -f

# Suspend handler logs
journalctl -u pia-suspend.service -f
```

### Common Issues

**VPN not connecting:**
1. Run health check: `sudo /usr/local/bin/pia-health-check.sh`
2. Check credentials: `sudo xed /etc/pia-credentials`
3. Verify service status: `systemctl status pia-vpn.service`
4. Check logs: `journalctl -u pia-vpn.service -n 50`

**Port forwarding not working:**
1. Ensure `PIA_PF="true"` in `/etc/pia-credentials`
2. Check service: `systemctl status pia-port-forward.service`
3. Verify port file: `cat /var/lib/pia/forwarded_port`
4. Test port: Run health check or manually test at `https://www.slsknet.org/porttest.php?port=YOUR_PORT`
5. Check firewall: `sudo ufw status`

**Notifications not appearing:**
1. Notifications have been removed from this setup
2. Use the Cinnamon applet to monitor VPN status
3. Check metrics with: `sudo /usr/local/bin/pia-stats.sh dashboard`
4. View logs: `journalctl -u pia-vpn.service -f`

**After suspend/resume:**
The system automatically handles suspend/resume:
- Port forwarding service is stopped on suspend
- Fresh port is requested on resume
- New port is automatically configured in firewall

### Manual Testing

Test VPN connection manually:

```bash
cd /usr/local/bin/manual-connections
sudo ./run_setup.sh
```

## File Locations

```
/etc/pia-credentials                        # Configuration file
/usr/local/bin/pia-*.sh                     # Core scripts
/usr/local/bin/pia-common.sh                # Shared function library
/usr/local/bin/manual-connections/          # PIA connection scripts
/var/lib/pia/                               # Runtime data
  ├── token.txt                             # Authentication token
  ├── region.txt                            # Current region info
  ├── forwarded_port                        # Current forwarded port
  └── metrics/                              # Metrics and statistics
      ├── vpn-metrics.log                   # Event log (auto-rotated)
      └── stats.json                        # Statistics cache
/etc/systemd/system/pia-*.service           # Systemd services
/etc/logrotate.d/pia-vpn                    # Log rotation config
```

## Modified Scripts

The following PIA manual-connections scripts have been modified from the original:

* `port_forwarding.sh` - Updated permissions for forwarded_port file (644 instead of 600)
* `connect_to_wireguard_with_token.sh` - Added Network Manager applet reload

Additional improvements:
* Atomic token file writes to prevent race conditions
* Shared function library (`pia-common.sh`) for code reuse
* Enhanced error logging throughout

Original scripts: https://github.com/pia-foss/manual-connections

## Uninstallation

To remove the VPN setup:

```bash
# Stop and disable services
sudo systemctl stop pia-vpn.service pia-port-forward.service pia-token-renew.timer pia-suspend.service
sudo systemctl disable pia-vpn.service pia-port-forward.service pia-token-renew.timer pia-suspend.service

# Remove systemd files
sudo rm /etc/systemd/system/pia-*.service
sudo rm /etc/systemd/system/pia-*.timer
sudo systemctl daemon-reload

# Remove scripts
sudo rm -rf /usr/local/bin/pia-*.sh
sudo rm -rf /usr/local/bin/manual-connections

# Remove data and config
sudo rm -rf /var/lib/pia
sudo rm /etc/pia-credentials

# Remove VPN interface
sudo wg-quick down pia 2>/dev/null || true
```

## Credits

Setup created with assistance from Claude (Anthropic).
PIA manual-connections scripts: https://github.com/pia-foss/manual-connections

## Contributing

Found a bug or have a suggestion? Please open an issue or submit a pull request!

## Related Documentation

- [CONFIGURATION.md](CONFIGURATION.md) - Detailed configuration examples and scenarios
- [PIA Manual Connections](https://github.com/pia-foss/manual-connections) - Original PIA scripts

## License

This project uses scripts from the PIA manual-connections repository, which are subject to their original license terms.
