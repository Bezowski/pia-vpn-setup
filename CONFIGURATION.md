# PIA VPN Configuration Examples

This document provides common configuration scenarios for different use cases.

## Configuration File Location

All settings are in `/etc/pia-credentials`. Edit with:
```bash
sudo xed /etc/pia-credentials
```

## Common Scenarios

### 1. Maximum Privacy (No Port Forwarding)

**Use Case**: General browsing, streaming, maximum simplicity

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="false"                   # Disable port forwarding
AUTOCONNECT="true"               # Auto-connect to fastest server
PREFERRED_REGION="none"          # Let PIA choose
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS servers
PIA_NOTIFICATIONS="true"         # Desktop notifications
```

**Benefits:**
- Simplest setup
- Fastest connection (auto-selects optimal server)
- No firewall configuration needed
- Works in all countries

---

### 2. Torrenting Setup (Port Forwarding Required)

**Use Case**: BitTorrent, Nicotine+/Soulseek, any P2P application

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="true"                    # Enable port forwarding
AUTOCONNECT="true"               # Auto-connect to PF-enabled server
PREFERRED_REGION="none"          # Let PIA choose (PF-enabled only)
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS servers
PIA_NOTIFICATIONS="true"         # Desktop notifications
```

**Important Notes:**
- Port forwarding is **disabled in the United States**
- AUTOCONNECT will automatically select a PF-enabled region
- Check your port: `cat /var/lib/pia/forwarded_port`
- Verify port is open: https://www.slsknet.org/porttest.php

**Firewall:**
```bash
# Port is automatically added to UFW
sudo ufw status | grep 2240,2242
```

---

### 3. Specific Region (e.g., Streaming, Gaming)

**Use Case**: Access region-specific content, reduce latency for gaming

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="false"                   # Usually not needed for streaming
AUTOCONNECT="false"              # Use specific region
PREFERRED_REGION="uk_london"     # Your chosen region
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS servers
PIA_NOTIFICATIONS="true"         # Desktop notifications
```

**Available Regions:**

To see all available regions:
```bash
curl -s "https://serverlist.piaservers.net/vpninfo/servers/v7" | \
  jq -r '.regions[] | "\(.id)\t\(.name)"' | sort
```

**Popular Regions:**
- `us_east` - US East
- `us_west` - US West  
- `uk_london` - UK London
- `ca_toronto` - Canada Toronto
- `au_sydney` - Australia Sydney
- `de_frankfurt` - Germany Frankfurt
- `japan` - Japan
- `singapore` - Singapore

**For Port Forwarding Regions:**
```bash
curl -s "https://serverlist.piaservers.net/vpninfo/servers/v7" | \
  jq -r '.regions[] | select(.port_forward==true) | "\(.id)\t\(.name)"' | sort
```

---

### 4. Development/Testing Setup

**Use Case**: Frequent region switching, testing VPN configurations

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="false"                   # Enable only if testing P2P
AUTOCONNECT="false"              # Manual control
PREFERRED_REGION="au_sydney"     # Change as needed
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS servers
PIA_NOTIFICATIONS="true"         # Get feedback on connections
```

**Quick Region Switching:**

Use the Cinnamon applet:
1. Click PIA VPN icon in panel
2. Select Server → Choose region
3. VPN reconnects automatically

Or via command line:
```bash
# Edit region
sudo sed -i 's/^PREFERRED_REGION=.*/PREFERRED_REGION=uk_london/' /etc/pia-credentials
sudo systemctl restart pia-vpn.service
```

---

### 5. Server/Headless Setup (No Notifications)

**Use Case**: Raspberry Pi, home server, NAS, headless system

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="true"                    # Usually needed for servers
AUTOCONNECT="true"               # Auto-connect on boot
PREFERRED_REGION="none"          # Auto-select
DISABLE_IPV6="yes"               # Prevent IPv6 leaks
PIA_DNS="true"                   # Use PIA DNS servers
PIA_NOTIFICATIONS="false"        # No desktop notifications
```

**Monitoring:**
```bash
# Check status
systemctl status pia-vpn.service

# View metrics
sudo /usr/local/bin/pia-stats.sh dashboard

# Check logs
journalctl -u pia-vpn.service -f
```

---

### 6. Maximum Security/Privacy

**Use Case**: Sensitive work, maximum privacy requirements

```bash
PIA_USER="p1234567"
PIA_PASS="your_password"
PIA_PF="false"                   # Disable for simplicity
AUTOCONNECT="true"               # Auto-connect always
PREFERRED_REGION="none"          # Let PIA choose
DISABLE_IPV6="yes"               # CRITICAL: Prevent leaks
PIA_DNS="true"                   # CRITICAL: Use PIA DNS only
PIA_NOTIFICATIONS="true"         # Monitor connections
```

**Additional Security Measures:**

1. **Verify DNS is not leaking:**
```bash
# Check DNS servers
resolvectl status pia

# Online test
firefox https://dnsleaktest.com
```

2. **Verify IPv6 is disabled:**
```bash
# Should show 1 (disabled)
sysctl net.ipv6.conf.all.disable_ipv6
sysctl net.ipv6.conf.default.disable_ipv6
```

3. **Run health check:**
```bash
sudo /usr/local/bin/pia-health-check.sh
```

4. **Enable kill switch (optional):**
```bash
# Prevent all traffic if VPN drops
sudo ufw default deny outgoing
sudo ufw default deny incoming
sudo ufw allow out on pia
sudo ufw enable
```

---

## Advanced Settings

### Custom DNS Servers

To use custom DNS instead of PIA DNS:

```bash
PIA_DNS="false"
```

Then configure manually in `/etc/wireguard/pia.conf`:
```ini
[Interface]
DNS = 1.1.1.1, 1.0.0.1  # Cloudflare
# DNS = 8.8.8.8, 8.8.4.4  # Google
# DNS = 9.9.9.9, 149.112.112.112  # Quad9
```

Restart VPN after changes:
```bash
sudo systemctl restart pia-vpn.service
```

### Change Token Renewal Frequency

Default is every 23 hours. To change:

```bash
sudo systemctl edit pia-token-renew.timer
```

Add:
```ini
[Timer]
OnBootSec=12h
OnUnitActiveSec=12h
```

Reload:
```bash
sudo systemctl daemon-reload
sudo systemctl restart pia-token-renew.timer
```

---

## Troubleshooting Configuration Issues

### VPN Won't Connect

1. **Check credentials:**
```bash
sudo xed /etc/pia-credentials
# Verify PIA_USER and PIA_PASS are correct
```

2. **Test credentials:**
```bash
cd /usr/local/bin/manual-connections
sudo PIA_USER="p1234567" PIA_PASS="xxx" ./get_token.sh
```

### Wrong Region Connecting

1. **Check current setting:**
```bash
grep PREFERRED_REGION /etc/pia-credentials
```

2. **Force specific region:**
```bash
sudo sed -i 's/^PREFERRED_REGION=.*/PREFERRED_REGION=au_sydney/' /etc/pia-credentials
sudo sed -i 's/^AUTOCONNECT=.*/AUTOCONNECT=false/' /etc/pia-credentials
sudo systemctl restart pia-vpn.service
```

### Port Forwarding Not Working

1. **Verify it's enabled:**
```bash
grep PIA_PF /etc/pia-credentials
# Should show: PIA_PF="true"
```

2. **Check you're not in the US:**
```bash
# Port forwarding is disabled on US servers
curl -s https://ipapi.co/json/ | jq -r '.country_name'
```

3. **Check port file:**
```bash
cat /var/lib/pia/forwarded_port
# Should show: PORT EXPIRY_TIMESTAMP
```

4. **Test port:**
```bash
PORT=$(cat /var/lib/pia/forwarded_port | awk '{print $1}')
firefox "https://www.slsknet.org/porttest.php?port=$PORT"
```

---

## Configuration Best Practices

1. **Always use strong, unique password** for PIA account
2. **Enable IPv6 disable** (`DISABLE_IPV6="yes"`)
3. **Use PIA DNS** unless you have specific reason not to
4. **Enable notifications** to catch connection issues
5. **Run health check** after configuration changes
6. **Backup configuration** before making changes:
   ```bash
   sudo cp /etc/pia-credentials /etc/pia-credentials.backup
   ```

---

## Configuration Changes Without Downtime

To change settings without losing VPN connection:

```bash
# 1. Edit configuration
sudo xed /etc/pia-credentials

# 2. If changing region or protocol:
sudo systemctl restart pia-vpn.service

# 3. If changing port forwarding only:
sudo systemctl restart pia-port-forward.service

# 4. If changing notifications only:
# No restart needed - takes effect on next event
```

---

## See Also

- [README.md](README.md) - Main documentation
- [Troubleshooting Guide](README.md#troubleshooting) - Common issues
- [PIA Regions List](https://www.privateinternetaccess.com/pages/network) - Official server list
