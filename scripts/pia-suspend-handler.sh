#!/bin/bash
# Handle PIA VPN on suspend/resume
# Strategy: Always do a full reconnect on resume to guarantee working connection

# Define reconnect function FIRST (before it's used)
reconnect_vpn() {
  echo "$(date): Stopping VPN interface..."
  wg-quick down pia 2>/dev/null || true
  sleep 2
  
  echo "$(date): Restarting pia-vpn service for fresh connection..."
  systemctl restart pia-vpn.service
  
  echo "$(date): Waiting for new VPN connection..."
  for i in {1..60}; do
    if ip addr show pia 2>/dev/null | grep -q "inet "; then
      echo "$(date): ✓ VPN reconnected"
      sleep 2
      
      # Delete old port file to force fresh assignment
      rm -f /var/lib/pia/forwarded_port
      
      # Start port forwarding with fresh port
      echo "$(date): Starting port forwarding with fresh port..."
      systemctl start pia-port-forward.service 2>/dev/null || true
      
      # Wait for new port to be assigned
      for j in {1..30}; do
        if [ -f /var/lib/pia/forwarded_port ]; then
          NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port)
          echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
          echo "$(date): ✅ VPN and port forwarding restored"
          return 0
        fi
        sleep 1
      done
      
      echo "$(date): ⚠️  VPN reconnected but port forwarding delayed"
      return 0
    fi
    sleep 1
  done
  
  echo "$(date): ✗ Failed to reconnect VPN after resume (timeout after 60s)"
  return 1
}

# Main logic
case "$1" in
  pre)
    echo "$(date): ===== SUSPEND: Preparing for sleep ====="
    echo "$(date): Stopping port forwarding (VPN connection will be maintained)"
    systemctl stop pia-port-forward.service 2>/dev/null || true
    echo "$(date): Port forwarding stopped"
    ;;
    
  post)
    echo "$(date): ===== RESUME: Waking from sleep ====="
    sleep 3  # Wait for network to stabilize
    
    echo "$(date): Checking current VPN status..."
    
    # Check if VPN interface exists
    if ! ip link show pia &>/dev/null; then
      echo "$(date): ✗ VPN interface doesn't exist, doing full reconnect"
      reconnect_vpn
      exit $?
    fi
    
    if ! ip addr show pia 2>/dev/null | grep -q "inet "; then
      echo "$(date): ✗ VPN interface has no IP address, doing full reconnect"
      reconnect_vpn
      exit $?
    fi
    
    echo "$(date): VPN interface exists with IP, testing connectivity..."
    
    # Test DNS connectivity (PIA DNS server)
    if timeout 5 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
      echo "$(date): ✓ VPN DNS is responding"
      
      # VPN seems fine, but after long suspend it might be stale
      # Do a quick connectivity test to external DNS
      if timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/53' 2>/dev/null; then
        echo "$(date): ✓ External DNS also responding, VPN is good"
        
        # Just refresh port forwarding
        echo "$(date): Refreshing port forwarding..."
        rm -f /var/lib/pia/forwarded_port
        systemctl start pia-port-forward.service 2>/dev/null || true
        
        # Wait for port (increased timeout to 30 seconds)
        for i in {1..30}; do
          if [ -f /var/lib/pia/forwarded_port ]; then
            NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port)
            echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
            echo "$(date): ✅ Resume complete - VPN healthy, port refreshed"
            exit 0
          fi
          sleep 1
        done
        echo "$(date): ⚠️  Port forwarding taking longer than expected, but service is running"
        exit 0
      fi
    fi
    
    echo "$(date): ✗ VPN connectivity test failed, doing full reconnect"
    reconnect_vpn
    exit $?
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    exit 1
    ;;
esac
