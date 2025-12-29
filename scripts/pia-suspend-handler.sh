#!/bin/bash
# Handle PIA VPN on suspend/resume
# Strategy: Always get fresh port on resume by restarting port-forward service

set -euo pipefail

# Helper function: Wait for network to be ready
wait_for_network() {
  local max_wait=30
  local wait_count=0
  
  echo "$(date): Waiting for network to be ready..."
  
  while [ $wait_count -lt $max_wait ]; do
    # Check if we can reach a DNS server
    if timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
      echo "$(date): ✓ Network is ready (after ${wait_count}s)"
      return 0
    fi
    
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  echo "$(date): ⚠️  Network not ready after ${max_wait}s, continuing anyway..."
  return 1
}

# Helper function: Wait for VPN interface to be ready with IP
wait_for_vpn_interface() {
  local max_wait=60
  local wait_count=0
  
  echo "$(date): Waiting for VPN interface to have an IP address..."
  
  while [ $wait_count -lt $max_wait ]; do
    if ip link show pia >/dev/null 2>&1 && ip addr show pia 2>/dev/null | grep -q "inet "; then
      echo "$(date): ✓ VPN interface ready with IP (after ${wait_count}s)"
      return 0
    fi
    
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  echo "$(date): ✗ VPN interface not ready after ${max_wait}s"
  return 1
}

# Helper function: Test VPN connectivity
test_vpn_connectivity() {
  echo "$(date): Testing VPN connectivity..."
  
  # Test 1: Can we reach PIA DNS server?
  if timeout 5 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
    echo "$(date): ✓ PIA DNS server responding"
    
    # Test 2: Can we reach external DNS through VPN?
    if timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
      echo "$(date): ✓ External connectivity through VPN working"
      return 0
    else
      echo "$(date): ✗ Cannot reach external DNS"
      return 1
    fi
  else
    echo "$(date): ✗ PIA DNS server not responding"
    return 1
  fi
}

# Helper function: Restart port forwarding with fresh port
restart_port_forwarding() {
  echo "$(date): Restarting port forwarding to get fresh port..."
  
  # Stop the service completely (kills the long-running script)
  systemctl stop pia-port-forward.service 2>/dev/null || true
  sleep 2
  
  # Delete old port file to force fresh assignment
  rm -f /var/lib/pia/forwarded_port
  echo "$(date): Deleted old port file"
  
  # Start the service (will get new signature and port)
  systemctl start pia-port-forward.service 2>/dev/null || true
  echo "$(date): Started pia-port-forward.service"
  
  # Wait for new port to be assigned (max 45 seconds - increased timeout)
  local port_wait=0
  while [ $port_wait -lt 45 ]; do
    if [ -f /var/lib/pia/forwarded_port ]; then
      NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port 2>/dev/null || echo "")
      if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "0" ]; then
        echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
        return 0
      fi
    fi
    sleep 1
    port_wait=$((port_wait + 1))
  done
  
  echo "$(date): ⚠️  Port forwarding taking longer than expected"
  echo "$(date): Service is running, port will arrive soon"
  return 1
}

# Helper function: Full VPN reconnection
reconnect_vpn() {
  echo "$(date): ===== Starting full VPN reconnection ====="
  
  # Step 1: Disconnect current VPN
  echo "$(date): Stopping VPN interface..."
  wg-quick down pia 2>/dev/null || true
  sleep 2
  
  # Step 2: Restart the VPN service
  echo "$(date): Restarting pia-vpn.service for fresh connection..."
  systemctl restart pia-vpn.service
  
  # Step 3: Wait for VPN to connect
  if wait_for_vpn_interface; then
    echo "$(date): ✓ VPN interface reconnected"
    
    # Step 4: Test connectivity
    if test_vpn_connectivity; then
      echo "$(date): ✓ VPN connectivity verified"
      
      # Step 5: Handle port forwarding
      CRED_FILE="/etc/pia-credentials"
      PIA_PF_SETTING="false"
      
      if [ -f "$CRED_FILE" ]; then
        source "$CRED_FILE"
        PIA_PF_SETTING=${PIA_PF:-"false"}
      fi
      
      if [ "$PIA_PF_SETTING" = "true" ]; then
        if restart_port_forwarding; then
          echo "$(date): ✅ VPN and port forwarding fully restored"
        else
          echo "$(date): ⚠️  VPN reconnected but port forwarding delayed"
        fi
      else
        echo "$(date): ✅ VPN reconnected (port forwarding disabled)"
      fi
      
      return 0
    else
      echo "$(date): ✗ VPN reconnected but connectivity test failed"
      return 1
    fi
  else
    echo "$(date): ✗ Failed to reconnect VPN after resume"
    return 1
  fi
}

# Main logic
case "$1" in
  pre)
    echo "$(date): ===== SUSPEND: Preparing for sleep ====="
    
    # Check if port forwarding is enabled
    CRED_FILE="/etc/pia-credentials"
    PIA_PF_SETTING="false"
    
    if [ -f "$CRED_FILE" ]; then
      source "$CRED_FILE"
      PIA_PF_SETTING=${PIA_PF:-"false"}
    fi
    
    if [ "$PIA_PF_SETTING" = "true" ]; then
      echo "$(date): Stopping port forwarding service before suspend"
      systemctl stop pia-port-forward.service 2>/dev/null || true
      echo "$(date): Port forwarding stopped"
    else
      echo "$(date): Port forwarding disabled, nothing to stop"
    fi
    
    echo "$(date): System ready for suspend"
    ;;
    
  post)
    echo "$(date): ===== RESUME: Waking from sleep ====="
    
    # Wait for network to stabilize
    wait_for_network
    
    echo "$(date): Checking current VPN status..."
    
    # Check if VPN interface exists
    if ! ip link show pia &>/dev/null; then
      echo "$(date): ✗ VPN interface doesn't exist, doing full reconnect"
      reconnect_vpn
      exit $?
    fi
    
    # Check if VPN has an IP address
    if ! ip addr show pia 2>/dev/null | grep -q "inet "; then
      echo "$(date): ✗ VPN interface has no IP address, doing full reconnect"
      reconnect_vpn
      exit $?
    fi
    
    echo "$(date): VPN interface exists with IP, testing connectivity..."
    
    # Test VPN connectivity
    if test_vpn_connectivity; then
      echo "$(date): ✓ VPN connectivity is good"
      
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
        echo "$(date): Port forwarding enabled, getting fresh port after resume..."
        
        if restart_port_forwarding; then
          echo "$(date): ✅ Resume complete - VPN healthy, fresh port assigned"
        else
          echo "$(date): ⚠️  Resume complete - VPN healthy, port assignment in progress"
        fi
      else
        echo "$(date): ✅ Resume complete - VPN healthy (port forwarding disabled)"
      fi
      
      exit 0
    else
      echo "$(date): ✗ VPN connectivity test failed, doing full reconnect"
      reconnect_vpn
      exit $?
    fi
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    exit 1
    ;;
esac
