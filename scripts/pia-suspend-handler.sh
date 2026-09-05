#!/bin/bash
# Handle PIA VPN on suspend/resume
# Strategy: Always restart port-forward service on resume, to reconfirm
# port forwarding after the network interruption. This reuses the same
# port if the cached signature is still fresh (intentional - see
# restart_port_forwarding() below), or gets a genuinely new port only if
# the signature has gone stale.

set -euo pipefail

# CRITICAL: Log everything to journal for debugging
exec 1> >(logger -t pia-suspend -s 2>&1)
exec 2>&1

echo "========================================="
echo "PIA Suspend Handler - $(date)"
echo "========================================="

# Metrics logging wrapper
log_metric() {
    /usr/local/bin/pia-metrics.sh "$@" 2>/dev/null || true
}

# Helper function: Wait for network to be ready
wait_for_network() {
  local max_wait=${1:-30}
  local wait_count=0
  
  echo "Waiting for network to be ready..."
  
  while [ $wait_count -lt $max_wait ]; do
    # Try multiple methods to detect network
    # Method 1: Can we reach a DNS server?
    if timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
      echo "✓ Network is ready (after ${wait_count}s)"
      return 0
    fi
    
    # Method 2: Check if any network interface (other than lo) has an IP
    if ip addr show | grep -q "inet.*scope global"; then
      echo "✓ Network interface has IP (after ${wait_count}s)"
      return 0
    fi
    
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  echo "⚠️ Network not ready after ${max_wait}s, continuing anyway..."
  return 1  # Don't fail - just continue
}

# Helper function: Wait for VPN interface to be ready with IP
wait_for_vpn_interface() {
  local max_wait=60
  local wait_count=0
  
  echo "Waiting for VPN interface to have an IP address..."
  
  while [ $wait_count -lt $max_wait ]; do
    if ip link show pia >/dev/null 2>&1; then
      echo "  Interface exists, checking for IP..."
      if ip addr show pia 2>/dev/null | grep -q "inet "; then
        local vpn_ip=$(ip addr show pia | grep "inet " | awk '{print $2}')
        echo "✓ VPN interface ready with IP: $vpn_ip (after ${wait_count}s)"
        return 0
      fi
    fi
    
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  echo "✗ VPN interface not ready after ${max_wait}s"
  return 1
}

# Helper function: Test VPN connectivity
test_vpn_connectivity() {
  echo "Testing VPN connectivity..."
  
  # Test 1: Check interface has IP
  if ! ip addr show pia 2>/dev/null | grep -q "inet "; then
    echo "✗ VPN interface has no IP address"
    return 1
  fi
  
  # Test 2: Can we reach PIA DNS server?
  echo "  Testing PIA DNS (10.0.0.243)..."
  if timeout 5 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
    echo "✓ PIA DNS server responding"
  else
    echo "✗ PIA DNS server not responding"
    return 1
  fi
  
  # Test 3: Can we reach external DNS through VPN?
  echo "  Testing external DNS (1.1.1.1)..."
  if timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
    echo "✓ External connectivity through VPN working"
  else
    echo "✗ Cannot reach external DNS"
    return 1
  fi
  
  # Test 4: Can we resolve a domain?
  echo "  Testing DNS resolution..."
  if timeout 5 nslookup google.com >/dev/null 2>&1; then
    echo "✓ DNS resolution working"
  else
    echo "⚠️ DNS resolution test failed (but connectivity OK)"
  fi
  
  # Test 5: Check public IP to verify we're on VPN
  echo "  Checking public IP..."
  local public_ip=$(timeout 5 curl -s https://api.ipify.org 2>/dev/null || echo "")
  if [ -n "$public_ip" ]; then
    echo "✓ Public IP: $public_ip (verify this is a PIA IP)"
  else
    echo "⚠️ Could not determine public IP"
  fi
  
  return 0
}

# Helper function: Restart port forwarding after resume
restart_port_forwarding() {
  echo "Restarting port forwarding after resume..."

  # Stop the service completely (kills the long-running script)
  echo "  Stopping pia-port-forward.service..."
  systemctl stop pia-port-forward.service 2>/dev/null || true
  sleep 2

  # Delete the old port file so the wait loop below can tell when
  # port_forwarding.sh has re-run, rather than reading a stale value left
  # over from before suspend. This does NOT force a new port number:
  # port_forwarding.sh reuses the cached signature (and same port) if
  # it's still fresh (<2h old) - intentional, so suspend/resume doesn't
  # need a new PIA signature every time. A genuinely new port only gets
  # assigned if the cached signature has gone stale.
  if [ -f /var/lib/pia/forwarded_port ]; then
    rm -f /var/lib/pia/forwarded_port
    echo "  Deleted old port file"
  fi

  # Start the service (will reuse the port if the signature is still
  # fresh, or get a new signature and port otherwise)
  echo "  Starting pia-port-forward.service..."
  systemctl start pia-port-forward.service 2>/dev/null || {
    echo "✗ Failed to start port forwarding service"
    return 1
  }

  # Wait for the port file to reappear (max 45 seconds)
  local port_wait=0
  echo "  Waiting for port assignment (max 45s)..."
  while [ $port_wait -lt 45 ]; do
    if [ -f /var/lib/pia/forwarded_port ]; then
      local new_port=$(awk '{print $1}' /var/lib/pia/forwarded_port 2>/dev/null || echo "")
      if [ -n "$new_port" ] && [ "$new_port" != "0" ]; then
        echo "✅ Port forwarding confirmed: $new_port"
        return 0
      fi
    fi
    sleep 1
    port_wait=$((port_wait + 1))
    
    # Show progress every 10 seconds
    if [ $((port_wait % 10)) -eq 0 ]; then
      echo "  Still waiting... (${port_wait}s)"
    fi
  done
  
  echo "⚠️ Port forwarding taking longer than expected"
  echo "   Service is running, port will arrive soon"
  return 1
}

# Helper function: Full VPN reconnection
reconnect_vpn() {
  echo "===== Starting full VPN reconnection ====="
  
  # Step 1: Disconnect current VPN
  echo "Step 1: Stopping VPN interface..."
  wg-quick down pia 2>/dev/null || {
    echo "  (VPN interface was already down)"
  }
  sleep 2
  
  # Step 2: Start the VPN service (non-blocking)
  echo "Step 2: Starting pia-vpn.service (non-blocking)..."
  systemctl start pia-vpn.service --no-block
  
  echo "✓ VPN service started in background"
  echo "  (Service will complete connection and restart port forwarding automatically)"
  return 0
}

# Main logic
case "${1:-}" in
  pre)
    echo "===== SUSPEND: Preparing for sleep ====="
    
    # Check if port forwarding is enabled
    CRED_FILE="/etc/pia-credentials"
    PIA_PF_SETTING="false"
    
    if [ -f "$CRED_FILE" ]; then
      source "$CRED_FILE"
      PIA_PF_SETTING=${PIA_PF:-"false"}
    fi
    
    if [ "$PIA_PF_SETTING" = "true" ]; then
      echo "Stopping port forwarding service before suspend..."
      systemctl stop pia-port-forward.service 2>/dev/null || true
      echo "✓ Port forwarding stopped"
    else
      echo "Port forwarding disabled, nothing to stop"
    fi
    
    echo "✓ System ready for suspend"
    log_metric log-suspend
    ;;
    
  post)
    echo "===== RESUME: Waking from sleep ====="
    
    # Wait for network to stabilize
    echo "Waiting for network..."
    wait_for_network
    
    # Give network a moment to fully stabilize
    sleep 2
    
    echo "Checking current VPN status..."
    
    # Check if VPN interface exists
    if ! ip link show pia &>/dev/null; then
      echo "✗ VPN interface doesn't exist"
      echo "  Doing full reconnect..."
      reconnect_vpn
      exit_code=$?
      echo "Reconnect result: $exit_code"
      exit $exit_code
    fi
    
    echo "✓ VPN interface exists"
    
    # Check if VPN has an IP address
    if ! ip addr show pia 2>/dev/null | grep -q "inet "; then
      echo "✗ VPN interface has no IP address"
      echo "  Doing full reconnect..."
      reconnect_vpn
      exit_code=$?
      echo "Reconnect result: $exit_code"
      exit $exit_code
    fi
    
    VPN_IP=$(ip addr show pia | grep "inet " | awk '{print $2}')
    echo "✓ VPN interface has IP: $VPN_IP"
    
    # Test VPN connectivity
    echo "Testing VPN connectivity..."
    if test_vpn_connectivity; then
      echo "✓ VPN connectivity is good"
      
      # Check if port forwarding is enabled
      CRED_FILE="/etc/pia-credentials"
      PIA_PF_SETTING="false"
      
      if [ -f "$CRED_FILE" ]; then
        source "$CRED_FILE"
        PIA_PF_SETTING=${PIA_PF:-"false"}
      fi
      
      if [ "$PIA_PF_SETTING" = "true" ]; then
        # After suspend, restart port-forward service to reconfirm port
        # forwarding is bound after the network interruption. The cached
        # signature is reused (same port) if it's still fresh - see
        # restart_port_forwarding()'s own comment - so this is not
        # guaranteed to be a new port, just a confirmed one.
        echo "Port forwarding enabled, reconfirming port after resume..."

        if restart_port_forwarding; then
          echo "✅ Resume complete - VPN healthy, port forwarding confirmed"
          NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port 2>/dev/null || echo "Unknown")
          log_metric log-resume "$NEW_PORT"
        else
          echo "⚠️ Resume complete - VPN healthy, port assignment in progress"
        fi
      else
        echo "Port forwarding disabled in config"
        echo "✅ Resume complete - VPN healthy (port forwarding disabled)"
      fi
      
      echo "========================================="
      echo "Resume completed successfully"
      echo "========================================="
      exit 0
    else
      echo "✗ VPN connectivity test failed"
      echo "  Doing full reconnect..."
      reconnect_vpn
      exit_code=$?
      echo "========================================="
      echo "Reconnect result: $exit_code"
      echo "========================================="
      exit $exit_code
    fi
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    echo "  pre  - Run before suspend"
    echo "  post - Run after resume"
    exit 1
    ;;
esac
