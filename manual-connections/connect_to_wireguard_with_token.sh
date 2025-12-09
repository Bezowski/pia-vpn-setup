#!/usr/bin/env bash
# Copyright (C) 2020 Private Internet Access, Inc.
# [License header omitted for brevity]

check_tool() {
  cmd=$1
  pkg=$2
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd could not be found"
    echo "Please install $pkg"
    exit 1
  fi
}

check_tool wg-quick wireguard-tools
check_tool curl curl
check_tool jq jq

if [[ -t 1 ]]; then
  ncolors=$(tput colors)
  if [[ -n $ncolors && $ncolors -ge 8 ]]; then
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    nc=$(tput sgr0)
  else
    red=''
    green=''
    nc=''
  fi
fi

: "${PIA_CONNECT=true}"

DEFAULT_PIA_CONF_PATH=/etc/wireguard/pia.conf
: "${PIA_CONF_PATH:=$DEFAULT_PIA_CONF_PATH}"

if [[ -f /proc/net/if_inet6 ]] &&
  [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) -ne 1 ||
     $(sysctl -n net.ipv6.conf.default.disable_ipv6) -ne 1 ]]
then
  echo -e "${red}You should consider disabling IPv6 by running:"
  echo "sysctl -w net.ipv6.conf.all.disable_ipv6=1"
  echo -e "sysctl -w net.ipv6.conf.default.disable_ipv6=1${nc}"
fi

if [[ -z $WG_SERVER_IP ||
      -z $WG_HOSTNAME ||
      -z $PIA_TOKEN ]]; then
  echo -e "${red}This script requires 3 env vars:"
  echo "WG_SERVER_IP - IP that you want to connect to"
  echo "WG_HOSTNAME  - name of the server, required for ssl"
  echo "PIA_TOKEN    - your authentication token"
  echo
  echo "You can also specify optional env vars:"
  echo "PIA_PF                - enable port forwarding"
  echo "PAYLOAD_AND_SIGNATURE - In case you already have a port."
  echo
  echo "An easy solution is to just run get_region_and_token.sh"
  echo "as it will guide you through getting the best server and"
  echo "also a token. Detailed information can be found here:"
  echo -e "https://github.com/pia-foss/manual-connections${nc}"
  exit 1
fi

privKey=$(wg genkey)
export privKey
pubKey=$( echo "$privKey" | wg pubkey)
export pubKey

echo "Trying to connect to the PIA WireGuard API on $WG_SERVER_IP..."
if [[ -z $DIP_TOKEN ]]; then
  wireguard_json="$(curl -s -G \
    --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
    --cacert "ca.rsa.4096.crt" \
    --data-urlencode "pt=${PIA_TOKEN}" \
    --data-urlencode "pubkey=$pubKey" \
    "https://${WG_HOSTNAME}:1337/addKey" )"
else
  wireguard_json="$(curl -s -G \
    --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
    --cacert "ca.rsa.4096.crt" \
    --user "dedicated_ip_$DIP_TOKEN:$WG_SERVER_IP" \
    --data-urlencode "pubkey=$pubKey" \
    "https://$WG_HOSTNAME:1337/addKey" )"
fi
export wireguard_json

if [[ $(echo "$wireguard_json" | jq -r '.status') != "OK" ]]; then
  >&2 echo -e "${red}Server did not return OK. Stopping now.${nc}"
  exit 1
fi

if [[ $PIA_CONNECT == "true" ]]; then
  PIA_CONF_PATH=$DEFAULT_PIA_CONF_PATH
  echo
  echo "Trying to disable a PIA WG connection in case it exists..."
  wg-quick down pia && echo -e "${green}\nPIA WG connection disabled!${nc}"
  echo
fi

if [[ $PIA_DNS == "true" ]]; then
  dnsServer=$(echo "$wireguard_json" | jq -r '.dns_servers[0]')
  echo "Trying to set up DNS to $dnsServer. In case you do not have resolvconf,"
  echo "this operation will fail and you will not get a VPN. If you have issues,"
  echo "start this script without PIA_DNS."
  echo
  dnsSettingForVPN="DNS = $dnsServer"
fi

echo -n "Trying to write ${PIA_CONF_PATH}..."
mkdir -p "$(dirname "$PIA_CONF_PATH")"
echo "
[Interface]
Address = $(echo "$wireguard_json" | jq -r '.peer_ip')
PrivateKey = $privKey
$dnsSettingForVPN
[Peer]
PersistentKeepalive = 25
PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
AllowedIPs = 0.0.0.0/0
Endpoint = ${WG_SERVER_IP}:$(echo "$wireguard_json" | jq -r '.server_port')
" > ${PIA_CONF_PATH} || exit 1
echo -e "${green}OK!${nc}"

if [[ $PIA_CONNECT == "true" ]]; then
  echo
  echo "Trying to create the wireguard interface..."
  wg-quick up pia || exit 1
  echo
  echo -e "${green}The WireGuard interface got created.${nc}

  At this point, internet should work via VPN.

  To disconnect the VPN, run:

  --> ${green}wg-quick down pia${nc} <--
  "

  echo "Reload Network Manager applet to remove duplicate 'pia' entries."

  REAL_USER=$(who | awk '{print $1}' | grep -v root | head -n1)
  if [ -z "$REAL_USER" ]; then
    echo "Warning: No graphical user session found, skipping applet reload" >&2
  else
    USER_ID=$(id -u "$REAL_USER")
    DISPLAY_NUM=":0"
    
    if sudo -u "$REAL_USER" \
        DISPLAY="$DISPLAY_NUM" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        dbus-send --session --dest=org.Cinnamon.LookingGlass --type=method_call \
            /org/Cinnamon/LookingGlass org.Cinnamon.LookingGlass.ReloadExtension \
            string:'network@cinnamon.org' string:'APPLET' 2>/dev/null; then
        echo "Network Manager applet reloaded successfully"
    else
        echo "Warning: Failed to reload Network Manager applet" >&2
    fi
  fi

  # NOTE: Port forwarding is now handled by pia-port-forward.service
  # Do NOT call port_forwarding.sh here
  echo
  echo "Port forwarding is managed by the pia-port-forward.service"
  echo "Check status with: systemctl status pia-port-forward.service"
fi
