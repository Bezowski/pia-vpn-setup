#!/bin/bash
# Handle PIA VPN on suspend/resume
# Strategy: Always get fresh port on resume by restarting port-forward service

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
  local max_wait=60  # New - Increased from 30s - network can be slow after resume
  local wait_count=0
  
  echo "Waiting for network to be ready..."
  
  while [ $wait_count -lt $max_wait ]; do
    # Check if we can reach a DNS server
    if timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
      echo "✓ Network is ready (after ${wait_count}s)"
      return 0
    fi
    
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  echo "⚠️ Network not ready after ${max_wait}s, continuing anyway..."
  return 1
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

# Helper function: Restart port forwarding with fresh port
restart_port_forwarding() {
  echo "Restarting port forwarding to get fresh port..."
  
  # Stop the service completely (kills the long-running script)
  echo "  Stopping pia-port-forward.service..."
  systemctl stop pia-port-forward.service 2>/dev/null || true
  sleep 2
  
  # Delete old port file to force fresh assignment
  if [ -f /var/lib/pia/forwarded_port ]; then
    rm -f /var/lib/pia/forwarded_port
    echo "  Deleted old port file"
  fi
  
  # Start the service (will get new signature and port)
  echo "  Starting pia-port-forward.service..."
  systemctl start pia-port-forward.service 2>/dev/null || {
    echo "✗ Failed to start port forwarding service"
    return 1
  }
  
  # Wait for new port to be assigned (max 45 seconds)
  local port_wait=0
  echo "  Waiting for port assignment (max 45s)..."
  while [ $port_wait -lt 45 ]; do
    if [ -f /var/lib/pia/forwarded_port ]; then
      local new_port=$(awk '{print $1}' /var/lib/pia/forwarded_port 2>/dev/null || echo "")
      if [ -n "$new_port" ] && [ "$new_port" != "0" ]; then
        echo "✅ Got fresh forwarded port: $new_port"
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
  
  # Step 2: Restart the VPN service
  echo "Step 2: Restarting pia-vpn.service for fresh connection..."
  systemctl restart pia-vpn.service || {
    echo "✗ Failed to restart VPN service"
    return 1
  }
  
  # Step 3: Wait for VPN to connect
  echo "Step 3: Waiting for VPN connection..."
  if wait_for_vpn_interface; then
    echo "✓ VPN interface reconnected"
    
    # Step 4: Test connectivity
    echo "Step 4: Testing connectivity..."
    if test_vpn_connectivity; then
      echo "✓ VPN connectivity verified"
      
      # Step 5: Handle port forwarding
      echo "Step 5: Checking port forwarding..."
      CRED_FILE="/etc/pia-credentials"
      PIA_PF_SETTING="false"
      
      if [ -f "$CRED_FILE" ]; then
        source "$CRED_FILE"
        PIA_PF_SETTING=${PIA_PF:-"false"}
      fi
      
      if [ "$PIA_PF_SETTING" = "true" ]; then
        echo "  Port forwarding enabled, restarting service..."
        if restart_port_forwarding; then
          echo "✅ VPN and port forwarding fully restored"
        else
          echo "⚠️ VPN reconnected but port forwarding delayed"
        fi
      else
        echo "  Port forwarding disabled in config"
        echo "✅ VPN reconnected (port forwarding disabled)"
      fi
      
      return 0
    else
      echo "✗ VPN reconnected but connectivity test failed"
      return 1
    fi
  else
    echo "✗ Failed to reconnect VPN after resume"
    return 1
  fi
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
        # CRITICAL: After suspend, we MUST restart port-forward service
        # The old signature is stale, we need a fresh one
        echo "Port forwarding enabled, getting fresh port after resume..."
        
        if restart_port_forwarding; then
          echo "✅ Resume complete - VPN healthy, fresh port assigned"
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
