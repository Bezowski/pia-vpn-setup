# PIA VPN Auto-Setup for Linux

Automated PIA VPN setup with WireGuard, port forwarding, and systemd integration.

## Features

- ✅ Automatic VPN connection on boot
- ✅ Token renewal every 23 hours
- ✅ Automatic port forwarding with firewall updates
- ✅ Survives suspend/resume
- ✅ Lightweight (no GUI client needed)

## Requirements

- Ubuntu/Debian-based Linux (tested on Linux Mint)
- PIA subscription
- sudo access

## Installation

1. Clone this repository:
```bash
   git clone https://github.com/YOUR_USERNAME/pia-vpn-setup.git
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

## Services

- `pia-vpn.service` - Connects VPN on boot
- `pia-renew.timer` - Renews token every 23 hours
- `pia-port-forward.service` - Maintains port forwarding
- `pia-reconnect.path` - Auto-resets port forwarding on reconnect

## Troubleshooting

View logs:
```bash
journalctl -u pia-vpn.service -f
journalctl -u pia-port-forward.service -f
```

Manual VPN restart:
```bash
sudo systemctl restart pia-vpn.service
```

## Credits

Setup created with assistance from Claude (Anthropic).
PIA manual-connections scripts: https://github.com/pia-foss/manual-connections
