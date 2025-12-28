#!/usr/bin/env bash
# Patched port_forwarding.sh with graceful handling for non-PF servers
# FIXED: Port file now written on every bind cycle, not just once
set -euo pipefail

# Simple tool checks
check_tool() {
  cmd=$1
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd could not be found"
    echo "Please install $2"
    exit 1
  fi
}
check_tool /usr/bin/curl curl
check_tool /usr/bin/jq jq
check_tool /bin/mkdir coreutils
check_tool /bin/mv coreutils
check_tool /bin/awk gawk
check_tool /bin/grep grep
check_tool /bin/cut coreutils
check_tool /bin/date coreutils

# Retry helper: retry <max_retries> <base_sleep_seconds> <cmd...>
retry() {
  local max_retries=$1; shift
  local base_sleep=$1; shift
  local n=0
  local rc=0
  while true; do
    if "$@"; then
      return 0
    else
      rc=$?
      n=$((n+1))
      if [ "$n" -ge "$max_retries" ]; then
        return $rc
      fi
      sleep $((base_sleep * n))
    fi
  done
}

# Persistence
PERSIST_DIR=/var/lib/pia
mkdir -p "$PERSIST_DIR"
TOKEN_FILE="$PERSIST_DIR/token.txt"
PORT_FILE="$PERSIST_DIR/forwarded_port"

# Reuse persisted token if present
if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  PIA_TOKEN="$(/bin/awk 'NR==1{print; exit}' "$TOKEN_FILE")"
  export PIA_TOKEN
fi

# Validate required env vars
if [ -z "${PF_GATEWAY:-}" ] || [ -z "${PIA_TOKEN:-}" ] || [ -z "${PF_HOSTNAME:-}" ]; then
  >&2 echo "This script requires 3 env vars:"
  >&2 echo "PF_GATEWAY  - the IP of your gateway"
  >&2 echo "PF_HOSTNAME - name of the host used for SSL/TLS certificate verification"
  >&2 echo "PIA_TOKEN   - the token you use to connect to the vpn services"
  >&2 echo
  >&2 echo "An easy solution is to just run get_region_and_token.sh"
  >&2 echo "as it will guide you through getting the best server and"
  >&2 echo "also a token. Detailed information can be found here:"
  >&2 echo "https://github.com/pia-foss/manual-connections"
  exit 1
fi

# Terminal colors (if supported)
red=''; green=''; nc=''
if [[ -t 1 ]]; then
  ncolors=$(/usr/bin/tput colors 2>/dev/null || echo 0)
  if [[ -n $ncolors && $ncolors -ge 8 ]]; then
    red=$(/usr/bin/tput setaf 1)
    green=$(/usr/bin/tput setaf 2)
    nc=$(/usr/bin/tput sgr0)
  fi
fi

# Ensure color vars are always defined (avoid unbound variable with set -u)
red=${red:-}
green=${green:-}
nc=${nc:-}

# Helper function to write port file atomically
write_port_file() {
  local port=$1
  local expires_at=$2
  
  # Strip nanoseconds from ISO8601 format if present
  # Input: "2026-02-25T18:02:41.37845301Z"
  # Output: "2026-02-25T18:02:41Z"
  local expires_at_clean="${expires_at%.*}Z"
  
  local EXPIRY_UNIX
  if EXPIRY_UNIX=$(/bin/date -d "$expires_at_clean" +%s 2>/dev/null); then
    :
  else
    # Fallback: port expires in ~60 days (2 months)
    EXPIRY_UNIX=$(($(date +%s) + 5184000))
  fi
  
  local tmp
  tmp="$(/bin/mktemp "${PERSIST_DIR}/forwarded_port.XXXX")"
  printf '%s %s\n' "$port" "$EXPIRY_UNIX" > "$tmp"
  /bin/chmod 0644 "$tmp"
  /bin/mv -f "$tmp" "$PORT_FILE"
  
  echo "✓ Port file written: $PORT_FILE (port=$port, expiry=$(/bin/date -d @"$EXPIRY_UNIX" --iso-8601=seconds))"
}

# If a saved port exists and is still valid, prefer reusing it.
if [ -f "$PORT_FILE" ]; then
  read SAVED_PORT SAVED_EXPIRY < "$PORT_FILE" || true
  if [ -n "$SAVED_PORT" ] && [ -n "$SAVED_EXPIRY" ] && [ "$SAVED_EXPIRY" -gt "$(/bin/date +%s)" ]; then
    port="$SAVED_PORT"
    echo -e "Reusing saved forwarded port ${green}$port${nc} (expires $(/bin/date -d @"$SAVED_EXPIRY" --iso-8601=seconds))"
    # We'll still request payload/signature below to ensure validity.
  fi
fi

# Get payload and signature from PF API (or use PAYLOAD_AND_SIGNATURE env var).
if [ -z "${PAYLOAD_AND_SIGNATURE:-}" ]; then
  echo
  echo -n "Getting new signature... "
  
  # Try to get signature, but handle non-PF servers gracefully
  if ! payload_and_signature="$(retry 5 2 /usr/bin/curl -s -m 5 \
    --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
    --cacert "ca.rsa.4096.crt" \
    -G --data-urlencode "token=${PIA_TOKEN}" \
    "https://${PF_HOSTNAME}:19999/getSignature")"; then
    
    # Connection failed - likely non-PF server
    >&2 echo -e "${red}Failed to get signature after retries.${nc}"
    >&2 echo "This server may not support port forwarding."
    >&2 echo "Port forwarding is disabled on US servers and some other regions."
    exit 0  # Exit cleanly (0) instead of failing (1) so service doesn't restart
  fi
else
  payload_and_signature=$PAYLOAD_AND_SIGNATURE
  echo -n "Checking the payload_and_signature from the env var... "
fi
export payload_and_signature

if [ "$(/usr/bin/jq -r '.status' <<<"$payload_and_signature")" != "OK" ]; then
  >&2 echo -e "${red}The payload_and_signature variable does not contain an OK status.${nc}"
  
  # Check if this is a non-PF server error
  ERROR_MSG=$(/usr/bin/jq -r '.message // empty' <<<"$payload_and_signature")
  if [ -n "$ERROR_MSG" ]; then
    >&2 echo "Error: $ERROR_MSG"
  fi
  
  >&2 echo "This server may not support port forwarding."
  exit 0  # Exit cleanly (0) so service doesn't restart endlessly
fi
echo -e "${green}OK!${nc}"

signature=$(/usr/bin/jq -r '.signature' <<<"$payload_and_signature")
payload=$(/usr/bin/jq -r '.payload' <<<"$payload_and_signature")
# extract port and expiry
new_port=$(/bin/base64 -d <<<"$payload" | /usr/bin/jq -r '.port')
expires_at=$(/bin/base64 -d <<<"$payload" | /usr/bin/jq -r '.expires_at')

# Prefer port from saved state if present (over new_port) so we keep a stable port.
if [ -n "${port:-}" ]; then
  :
else
  port="$new_port"
fi

echo -ne "
Signature ${green}$signature${nc}
Payload   ${green}$payload${nc}

--> The port is ${green}$port${nc} and it will expire on ${red}$expires_at${nc}. <--

"

# Persist token atomically
if [ -n "${PIA_TOKEN:-}" ]; then
  tmp="$(/bin/mktemp "${PERSIST_DIR}/token.txt.XXXX")"
  printf '%s\n' "$PIA_TOKEN" > "$tmp"
  /bin/chmod 0644 "$tmp"
  /bin/mv -f "$tmp" "$TOKEN_FILE"
fi

# Write the port file for the FIRST time (before entering loop)
write_port_file "$port" "$expires_at"

# Update firewall immediately after getting new port
/usr/local/bin/pia-firewall-update-wrapper.sh || true

# Bind and keepalive loop
while true; do
  echo "Trying to bind port $port..."
  
  if ! bind_port_response="$(retry 5 2 /usr/bin/curl -Gs -m 5 \
    --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
    --cacert "ca.rsa.4096.crt" \
    --data-urlencode "payload=${payload}" \
    --data-urlencode "signature=${signature}" \
    "https://${PF_HOSTNAME}:19999/bindPort")"; then
    echo -e "${red}Failed to contact bind endpoint after retries; retrying in 15s...${nc}"
    sleep 15
    continue
  fi
  echo -e "${green}OK!${nc}"

  if [ "$(/usr/bin/jq -r '.status' <<<"$bind_port_response")" != "OK" ]; then
    >&2 echo -e "${red}The API did not return OK when trying to bind port... Exiting.${nc}"
    >&2 echo "Response: $bind_port_response"
    exit 1
  fi

  # CRITICAL FIX: Write port file on EVERY successful bind
  # This ensures the file always exists and is up-to-date
  write_port_file "$port" "$expires_at"

  echo -e Forwarded port'\t'"${green}$port${nc}"
  echo -e Refreshed on'\t'"${green}$(/bin/date)${nc}"
  if [ -n "${expires_at:-}" ]; then
    echo -e Expires on'\t'"${red}$(/bin/date --date="$expires_at")${nc}"
  fi
  echo -e "\n${green}This script will need to remain active to use port forwarding, and will refresh every 15 minutes.${nc}\n"

  # sleep 15 minutes
  sleep 900
done
