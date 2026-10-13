#!/bin/bash
# Update an existing PIA VPN install to the current repo version.
#
# Non-interactive, and keeps the machine's current choices: optional
# components (kill switch, watchdog, split tunneling) are only updated if
# they're already installed, the kill switch keeps its on/off state, and
# credentials are never touched. Use install.sh / install-security-features.sh
# for a first install or to add a component.
#
# Usage: git pull && sudo ./update.sh
# (git pull runs as you rather than from here, so it keeps your SSH agent
# and .git doesn't end up root-owned.)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./update.sh)"
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

if [ ! -d scripts ] || [ ! -d systemd ] || [ ! -d manual-connections ]; then
    echo "Error: run this from the pia-vpn-setup repo"
    exit 1
fi

if [ ! -f /etc/systemd/system/pia-vpn.service ]; then
    echo "PIA VPN isn't installed on this machine - run sudo ./install.sh first"
    exit 1
fi

CHANGED=()
CONNECT_CHANGED=false

# Copy src to dst only if it differs; records what changed.
update_file() {
    local src="$1" dst="$2" mode="$3"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    install -D -m "$mode" "$src" "$dst"
    CHANGED+=("$dst")
    case "$dst" in
        /usr/local/bin/manual-connections/*|*/pia-renew-and-connect-no-pf.sh|*/pia-vpn.service)
            CONNECT_CHANGED=true ;;
    esac
    echo "  updated $dst"
}

# Optional components: updated only if already installed, never added.
OPTIONAL_SCRIPTS="pia-killswitch.sh pia-watchdog.sh pia-split-tunnel.sh"
OPTIONAL_UNITS="pia-watchdog.service pia-split-tunnel-watch.service pia-killswitch-restore.service"

echo "Updating scripts..."
for src in scripts/*.sh; do
    name=$(basename "$src")
    dst="/usr/local/bin/$name"
    if [[ " $OPTIONAL_SCRIPTS " == *" $name "* ]] && [ ! -f "$dst" ]; then
        continue
    fi
    update_file "$src" "$dst" 755
done

echo "Updating manual-connections scripts..."
for src in manual-connections/*; do
    [ -f "$src" ] || continue
    mode=644
    [[ "$src" == *.sh ]] && mode=755
    update_file "$src" "/usr/local/bin/manual-connections/$(basename "$src")" "$mode"
done

echo "Updating systemd units..."
for src in systemd/*; do
    name=$(basename "$src")
    dst="/etc/systemd/system/$name"
    if [[ " $OPTIONAL_UNITS " == *" $name "* ]] && [ ! -f "$dst" ]; then
        # The boot-restore unit belongs to the kill switch, so it's added
        # wherever the kill switch is installed (it was added after some
        # machines already had the kill switch).
        if [ "$name" != "pia-killswitch-restore.service" ] || [ ! -f /usr/local/bin/pia-killswitch.sh ]; then
            continue
        fi
    fi
    update_file "$src" "$dst" 644
done

echo "Updating logrotate config..."
update_file config/pia-vpn /etc/logrotate.d/pia-vpn 644

NM_CONF=/etc/NetworkManager/conf.d/99-pia-no-connectivity-check.conf
NM_CHANGED=false
if [ -f /usr/local/bin/pia-killswitch.sh ] && [ -d /etc/NetworkManager/conf.d ]; then
    echo "Updating NetworkManager config..."
    before=${#CHANGED[@]}
    update_file config/99-pia-no-connectivity-check.conf "$NM_CONF" 644
    [ "${#CHANGED[@]}" -ne "$before" ] && NM_CHANGED=true
fi

# Sudoers: only the extended (security-features) set can be regenerated
# here - the base set lives inline in install.sh.
if grep -qs 'PIA_KILLSWITCH' /etc/sudoers.d/pia-vpn; then
    echo "Updating sudoers..."
    bash install-secure-sudoers.sh >/dev/null
    echo "  sudoers checked"
else
    echo "Base sudoers left as is (re-run install.sh to regenerate it)"
fi

APPLET_CHANGED=false
if [ -n "${SUDO_USER:-}" ]; then
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    applet_dir="$user_home/.local/share/cinnamon/applets/pia-vpn@bezowski"
    if [ -d "$applet_dir" ]; then
        echo "Updating applet..."
        before=${#CHANGED[@]}
        for f in applet.js metadata.json settings-schema.json icons/connected.png icons/disconnected.png; do
            update_file "applet/$f" "$applet_dir/$f" 644
        done
        if [ "${#CHANGED[@]}" -ne "$before" ]; then
            chown -R "$SUDO_USER:$SUDO_USER" "$applet_dir"
            APPLET_CHANGED=true
        fi
    fi
fi

echo "Reloading systemd..."
systemctl daemon-reload

if [ "$NM_CHANGED" = true ]; then
    echo "Reloading NetworkManager config..."
    systemctl reload NetworkManager || true
fi

if [ -f /etc/systemd/system/pia-killswitch-restore.service ] \
   && ! systemctl is-enabled --quiet pia-killswitch-restore.service; then
    systemctl enable pia-killswitch-restore.service
fi

# Running processes keep their old code until restarted. The VPN itself is
# not restarted (that would drop the connection) - connect-script changes
# apply on the next connect.
if [ "${#CHANGED[@]}" -gt 0 ]; then
    for svc in pia-watchdog.service pia-split-tunnel-watch.service; do
        if systemctl is-active --quiet "$svc"; then
            echo "Restarting $svc..."
            systemctl restart "$svc"
        fi
    done

    # The loaded nftables ruleset is a snapshot from the last enable, so
    # reload it if it's on (enable swaps the table atomically).
    if nft list table inet pia_killswitch &>/dev/null; then
        echo "Reloading kill switch rules..."
        /usr/local/bin/pia-killswitch.sh enable >/dev/null \
            || echo "⚠️  Kill switch reload failed - run: sudo pia-killswitch.sh enable"
    fi
fi

echo
if [ "${#CHANGED[@]}" -eq 0 ]; then
    echo "✓ Already up to date"
else
    echo "✓ Updated ${#CHANGED[@]} file(s)"
fi
if [ "$APPLET_CHANGED" = true ]; then
    echo "  Applet changed - restart Cinnamon (Alt+F2, r) to load it"
fi
if [ "$CONNECT_CHANGED" = true ]; then
    echo "  Connect scripts changed - they apply on the next VPN connect"
fi
