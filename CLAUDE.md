# pia-vpn-setup

Automated PIA VPN setup for Linux (WireGuard + systemd), tested on Linux Mint 22.2 / Cinnamon. GitHub: `Bezowski/pia-vpn-setup`, pushed via SSH.

## Layout
- `install.sh`, `install-security-features.sh`, `install-secure-sudoers.sh`, `uninstall.sh` — top-level installers
- `scripts/` — core daemons/CLIs: `pia-common.sh` (shared function library), `pia-killswitch.sh`, `pia-watchdog.sh`, `pia-split-tunnel.sh`, `pia-health-check.sh`, `pia-metrics.sh`, `pia-stats.sh`, plus wrapper scripts for port-forward/firewall/suspend
- `manual-connections/` — vendored/modified scripts from upstream `pia-foss/manual-connections` (note the two documented deviations from upstream in README's "Modified Scripts" section)
- `systemd/` — unit files for `pia-vpn`, `pia-token-renew` (service+timer), `pia-port-forward`, `pia-suspend`, `pia-watchdog`, `pia-split-tunnel-watch`
- `applet/` — Cinnamon desktop applet (`applet.js`) for VPN control/region selection
- `config/` — `pia-credentials.example`, sudoers config
- `CONFIGURATION.md` — detailed config scenarios (read this for anything credential/region/option related)

## Key concepts
- Config lives at `/etc/pia-credentials` on the target machine (not in-repo); runtime state under `/var/lib/pia/`
- Security model: kill switch (nftables-based, `meta mark 0x200 accept` bypass), split tunneling via dedicated `novpn` user + fwmark policy routing, watchdog auto-reconnect
- Recent work has focused on hardening the `novpn` split-tunnel user (own runtime dir, PulseAudio/PipeWire socket access, XDG_RUNTIME_DIR handling) — see recent commit history before touching that area
- Metrics/logging: `/var/lib/pia/metrics/vpn-metrics.log`, rotated at 10,000 events

## Kill switch architecture (`scripts/pia-killswitch.sh`)
- nftables table `inet pia_killswitch`, default-deny egress. Exceptions: loopback, established/related, auto-detected LAN subnet, Tailscale (`100.64.0.0/10`), the `pia` interface, DNS, DHCP, and PIA's own WireGuard server IP ranges (needed to establish the tunnel in the first place).
- Commands: `enable`, `disable`, `status`, `test` (runs 5 diagnostic checks, including split-tunnel bypass verification).
- **Gotcha:** rules must use `oifname`/`iifname`, never `oif`/`iif`. `oif` resolves the interface name to a kernel ifindex at ruleset *load* time — if `pia` doesn't exist yet (the kill switch must load before the VPN comes up), the whole ruleset fails to load with "Interface does not exist". `oifname`/`iifname` match by name string dynamically.
- The split-tunnel bypass exception (`meta mark 0x00000200 accept`) is generated directly into the ruleset (not added at runtime via `nft add rule`), so it survives every enable/disable cycle.

## Split tunneling architecture (`scripts/pia-split-tunnel.sh`)
- Dedicated `novpn` user — anything run as that user bypasses the VPN. `pia-split-tunnel.sh launch <cmd>` handles X11 access for GUI apps.
- `iptables -t mangle` marks `novpn`'s traffic `fwmark 0x200` (DNS/53 exempted — PIA's internal DNS, `10.0.0.243`, is only reachable through the tunnel).
- `ip rule` sends `fwmark 0x200` to routing table `200` (default route via the physical gateway). **Gotcha:** you cannot win this by picking a lower priority number than wg-quick's rules — wg-quick re-adds its own rules (`not fwmark <table> lookup <table>` / `lookup main suppress_prefixlength 0`) at priority 0, the literal floor, on every VPN (re)connect, and ties at equal priority resolve by insertion order, which always favors wg-quick since it runs before our `ExecStartPost` setup. The fix is `relocate_wg_rules_if_conflicting()`: actively move wg-quick's rules to a safe, higher priority (100) instead of trying to out-priority them. This runs in `setup()` and unconditionally on every `watch()` poll, since wg-quick's rule can reappear at priority 0 even while ours is present and correct.
- `iptables -t nat POSTROUTING ... MASQUERADE` on marked traffic is required — relying on the kernel to re-pick the source address after marking (`ip_route_me_harder()`) is unreliable for some socket types (confirmed via tcpdump: a `ping` ICMP socket kept the VPN's internal tunnel IP as source even after the interface was correctly redirected, so no router could reply). MASQUERADE unconditionally rewrites the source address.
- Persistence: `pia-vpn.service`'s `ExecStartPost` calls `pia-split-tunnel.sh reapply` on every connect/reconnect (no-op if split tunneling was never configured).
- Self-healing watchdog: `pia-split-tunnel-watch.service` runs `pia-split-tunnel.sh watch`.
- **Known external bug (not fixable from this project):** tailscaled's netlink route monitor deletes custom `ip rule`s it doesn't recognize, regardless of `uidrange`/`fwmark` selector — confirmed via on/off testing (stopping `tailscaled` makes the rule stay put indefinitely; starting it, the rule is deleted within seconds, every time). `tailscale set --netfilter-mode=off` was tried and made no difference, which confirms it's the route *monitor*, not iptables/nft management. The watchdog uses `ip monitor rule` for near-instant reaction to this, plus polling for the mangle mark / MASQUERADE / killswitch pieces.
- `applet/microsoft-edge-novpn.desktop` — desktop launcher for Edge via the bypass.

## Working conventions
- When editing or creating files interactively via a terminal command, use `xed`, not `nano` (matches the project's own documented usage, e.g. `sudo xed /etc/pia-credentials` in README)
