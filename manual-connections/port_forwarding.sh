#!/usr/bin/env bash
# Enhanced port_forwarding.sh with payload/signature persistence
# Keeps same port across reboots (until signature expires after ~2 months)
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
PAYLOAD_FILE="$PERSIST_DIR/payload.txt"
SIGNATURE_FILE="$PERSIST_DIR/signature.txt"

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

# Ensure color vars are always defined
red=${red:-}
green=${green:-}
nc=${nc:-}

# Helper function to write port file atomically
write_port_file() {
  local port=$1
  local expires_at=$2
  
  # Strip nanoseconds from ISO8601 format if present
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

# Helper function to save payload and signature atomically
save_signature() {
  local payload=$1
  local signature=$2
  
  local tmp_payload tmp_signature
  tmp_payload="$(/bin/mktemp "${PAYLOAD_FILE}.XXXX")"
  tmp_signature="$(/bin/mktemp "${SIGNATURE_FILE}.XXXX")"
  
  echo "$payload" > "$tmp_payload"
  echo "$signature" > "$tmp_signature"
  
  /bin/chmod 0644 "$tmp_payload" "$tmp_signature"
  /bin/mv -f "$tmp_payload" "$PAYLOAD_FILE"
  /bin/mv -f "$tmp_signature" "$SIGNATURE_FILE"
  
  echo "✓ Payload and signature persisted to disk"
}

# Helper function to check if saved signature is still valid
check_saved_signature() {
  if [ ! -f "$PAYLOAD_FILE" ] || [ ! -f "$SIGNATURE_FILE" ]; then
    return 1  # No saved signature
  fi
  
  echo "Found saved signature, checking validity..."
  
  local saved_payload saved_signature
  saved_payload=$(cat "$PAYLOAD_FILE" 2>/dev/null || echo "")
  saved_signature=$(cat "$SIGNATURE_FILE" 2>/dev/null || echo "")
  
  if [ -z "$saved_payload" ] || [ -z "$saved_signature" ]; then
    echo "Saved files are empty"
    return 1
  fi
  
  # Decode payload to check expiry and creation time
  local decoded
  if ! decoded=$(echo "$saved_payload" | /usr/bin/base64 -d 2>/dev/null); then
    echo "Failed to decode saved payload"
    rm -f "$PAYLOAD_FILE" "$SIGNATURE_FILE"
    return 1
  fi
  
  local expires_at created_at saved_port
  expires_at=$(echo "$decoded" | /usr/bin/jq -r '.expires_at // empty' 2>/dev/null)
  created_at=$(echo "$decoded" | /usr/bin/jq -r '.created_at // empty' 2>/dev/null)
  saved_port=$(echo "$decoded" | /usr/bin/jq -r '.port // empty' 2>/dev/null)
  
  if [ -z "$expires_at" ] || [ -z "$saved_port" ]; then
    echo "Saved payload missing required fields"
    rm -f "$PAYLOAD_FILE" "$SIGNATURE_FILE"
    return 1
  fi
  
  # Check expiry (port expires after ~2 months)
  local expiry_unix current_unix
  expiry_unix=$(/bin/date -d "$expires_at" +%s 2>/dev/null || echo 0)
  current_unix=$(/bin/date +%s)
  
  if [ "$expiry_unix" -le "$current_unix" ]; then
    echo "Saved signature expired on $(/bin/date -d @$expiry_unix)"
    rm -f "$PAYLOAD_FILE" "$SIGNATURE_FILE"
    return 1
  fi
  
  # Check age of signature (PIA might reject if too old, even if not expired)
  # Be conservative: only reuse if less than 2 hours old
  if [ -n "$created_at" ]; then
    local created_unix age_seconds age_hours
    created_unix=$(/bin/date -d "$created_at" +%s 2>/dev/null || echo 0)
    
    if [ "$created_unix" -gt 0 ]; then
      age_seconds=$((current_unix - created_unix))
      age_hours=$((age_seconds / 3600))
      
      # Only reuse if signature is fresh (< 2 hours old)
      # This handles suspend/resume where time jumps forward
      if [ "$age_hours" -ge 2 ]; then
        echo "Saved signature is $age_hours hours old (too stale, getting fresh one)"
        echo "Note: Signatures older than ~2 hours may be rejected by PIA"
        rm -f "$PAYLOAD_FILE" "$SIGNATURE_FILE"
        return 1
      fi
      
      echo "Signature age: $age_hours hours (fresh enough to reuse)"
    fi
  fi
  
  # Calculate time remaining until expiry
  local time_remaining days_remaining hours_remaining
  time_remaining=$((expiry_unix - current_unix))
  days_remaining=$((time_remaining / 86400))
  hours_remaining=$(((time_remaining % 86400) / 3600))
  
  echo -e "${green}✓ Saved signature is valid${nc}"
  echo "  Port: $saved_port"
  echo "  Expires in: $days_remaining days, $hours_remaining hours"
  echo "  Expiry date: $(/bin/date -d @$expiry_unix)"
  
  # Export for use in main script
  export SAVED_PAYLOAD="$saved_payload"
  export SAVED_SIGNATURE="$saved_signature"
  export SAVED_PORT="$saved_port"
  export SAVED_EXPIRES_AT="$expires_at"
  
  return 0
}

# Try to reuse existing signature
REUSING_SIGNATURE=false

if check_saved_signature; then
  # Use saved signature
  payload="$SAVED_PAYLOAD"
  signature="$SAVED_SIGNATURE"
  port="$SAVED_PORT"
  expires_at="$SAVED_EXPIRES_AT"
  REUSING_SIGNATURE=true
  
  echo -e "\n${green}==> Reusing saved port $port${nc}\n"
else
  # Need to get new signature
  echo -e "\n==> Getting new signature from PIA...\n"
  
  # Get payload and signature from PF API
  echo -n "Requesting signature... "
  
  if ! payload_and_signature="$(retry 5 2 /usr/bin/curl -s -m 5 \
    --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
    --cacert "ca.rsa.4096.crt" \
    -G --data-urlencode "token=${PIA_TOKEN}" \
    "https://${PF_HOSTNAME}:19999/getSignature")"; then
    
    >&2 echo -e "${red}Failed to get signature after retries.${nc}"
    >&2 echo "This server may not support port forwarding."
    >&2 echo "Port forwarding is disabled on US servers and some other regions."
    exit 0
  fi
  
  export payload_and_signature
  
  if [ "$(/usr/bin/jq -r '.status' <<<"$payload_and_signature")" != "OK" ]; then
    >&2 echo -e "${red}The payload_and_signature does not contain an OK status.${nc}"
    
    ERROR_MSG=$(/usr/bin/jq -r '.message // empty' <<<"$payload_and_signature")
    if [ -n "$ERROR_MSG" ]; then
      >&2 echo "Error: $ERROR_MSG"
    fi
    
    >&2 echo "This server may not support port forwarding."
    exit 0
  fi
  
  echo -e "${green}OK!${nc}"
  
  signature=$(/usr/bin/jq -r '.signature' <<<"$payload_and_signature")
  payload=$(/usr/bin/jq -r '.payload' <<<"$payload_and_signature")
  
  # Extract port and expiry from new signature
  port=$(/bin/base64 -d <<<"$payload" | /usr/bin/jq -r '.port')
  expires_at=$(/bin/base64 -d <<<"$payload" | /usr/bin/jq -r '.expires_at')
  
  # Save the new signature for future use
  save_signature "$payload" "$signature"
  
  echo -e "\n${green}==> Got new port $port${nc}\n"
fi

# Display signature info
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

# Update firewall immediately after getting port
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
    
    # If bind fails, signature might be stale - delete saved files
    rm -f "$PAYLOAD_FILE" "$SIGNATURE_FILE"
    exit 1
  fi

  # CRITICAL: Write port file on EVERY successful bind
  write_port_file "$port" "$expires_at"

  echo -e Forwarded port'\t'"${green}$port${nc}"
  echo -e Refreshed on'\t'"${green}$(/bin/date)${nc}"
  if [ -n "${expires_at:-}" ]; then
    echo -e Expires on'\t'"${red}$(/bin/date --date="$expires_at")${nc}"
  fi
  
  if [ "$REUSING_SIGNATURE" = true ]; then
    echo -e Status'\t\t'"${green}Reusing saved signature${nc}"
  fi
  
  echo -e "\n${green}This script will need to remain active to use port forwarding, and will refresh every 15 minutes.${nc}\n"

  # sleep 15 minutes
  sleep 900
done
