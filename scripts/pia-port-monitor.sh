#!/bin/bash
# Monitor PIA port and automatically reset if test fails
# Run as: sudo ./pia-port-monitor.sh
# Or as a systemd service/timer

set -euo pipefail

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
nc='\033[0m'

log() {
  echo -e "${green}[$(date '+%Y-%m-%d %H:%M:%S')]${nc} $*"
  logger -t pia-port-monitor "$*"
}

error() {
  echo -e "${red}[ERROR]${nc} $*" >&2
  logger -t pia-port-monitor "ERROR: $*"
}

warn() {
  echo -e "${yellow}[WARNING]${nc} $*"
  logger -t pia-port-monitor "WARNING: $*"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  error "Please run as root (sudo $0)"
  exit 1
fi

# Configuration
PERSIST_DIR=/var/lib/pia
PORT_FILE="$PERSIST_DIR/forwarded_port"
TEST_URL="https://www.slsknet.org/porttest.php"
MAX_RETRIES=3
RETRY_DELAY=30

# Lock file to prevent concurrent runs
LOCK_FILE="/var/run/pia-port-monitor.lock"

# Acquire lock
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    warn "Another instance is running (PID $LOCK_PID), exiting"
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# Check if port forwarding is enabled
if [ ! -f "$PORT_FILE" ]; then
  error "No forwarded port file found. Is port forwarding active?"
  exit 1
fi

PORT=$(awk '{print $1}' "$PORT_FILE")
log "Monitoring port: $PORT"

# Test port connectivity
test_port() {
  local port=$1
  local attempt=$2
  
  echo -n "Testing port $port (attempt $attempt/$MAX_RETRIES)... "
  
  # First check: verify port is listening somewhere
  if ! netstat -tlnp 2>/dev/null | grep -q ":$port " && ! ss -tlnp 2>/dev/null | grep -q ":$port "; then
    echo "❌ Port not listening"
    return 1
  fi
  
  echo -n "✅ listening, "
  
  # Second check: external test via slsknet (the real test)
  RESULT=$(timeout 10 curl -s "${TEST_URL}?port=${port}" 2>/dev/null || echo "0")
  
  if [ "$RESULT" = "1" ]; then
    echo "✅ external"
    return 0
  else
    echo "❌ external"
    return 1
  fi
}

# Reset port by deleting port file and restarting service
reset_port() {
  log "🔄 Resetting forwarded port..."
  
  systemctl stop pia-port-forward.service
  rm -f "$PORT_FILE"
  
  log "Waiting for new port assignment..."
  
  systemctl start pia-port-forward.service
  
  # Wait for port file to be created
  for i in {1..30}; do
    if [ -f "$PORT_FILE" ]; then
      NEW_PORT=$(awk '{print $1}' "$PORT_FILE")
      log "✅ Got new port: $NEW_PORT"
      return 0
    fi
    sleep 1
  done
  
  error "Failed to get new port within 30 seconds"
  return 1
}

# Main test loop
log "Starting port monitoring..."

FAILURE_COUNT=0
for i in $(seq 1 $MAX_RETRIES); do
  if test_port "$PORT" "$i"; then
    log "✅ Port test PASSED"
    FAILURE_COUNT=0
    exit 0
  else
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    
    if [ $i -lt $MAX_RETRIES ]; then
      warn "Port test failed, retrying in ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
    fi
  fi
done

# All retries failed
error "Port test failed after $MAX_RETRIES attempts"
log "Attempting automatic port reset..."

if reset_port; then
  # Get new port and test it
  NEW_PORT=$(awk '{print $1}' "$PORT_FILE")
  log "Testing new port: $NEW_PORT"
  
  sleep 3
  
  if test_port "$NEW_PORT" 1; then
    log "✅ New port is working!"
    exit 0
  else
    error "New port test also failed, manual intervention may be needed"
    exit 1
  fi
else
  error "Port reset failed"
  exit 1
fi
