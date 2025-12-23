#!/bin/bash
# Handle PIA VPN on suspend/resume
# Smart strategy: Validate connection after resume, only reconnect if broken

case "$1" in
  pre)
    echo "$(date): Preparing for suspend - stopping port forwarding"
    systemctl stop pia-port-forward.service 2>/dev/null || true
    echo "$(date): Port forwarding stopped, VPN connection remains active"
    ;;
    
  post)
    echo "$(date): Resuming from suspend - validating VPN connection"
    sleep 5  # Wait for network to stabilize
    
    # Check if VPN interface exists
    if ! ip link show pia &>/dev/null || ! ip addr show pia | grep -q "inet "; then
      echo "$(date): ✗ VPN interface not active, reconnecting..."
      reconnect_vpn
      exit 0
    fi
    
    echo "$(date): VPN interface is active, testing connectivity..."
    
    # Test if VPN is actually working by checking PIA DNS
    # This is the same test that pia-renew-and-connect-no-pf.sh uses
    if timeout 3 bash -c 'echo > /dev/tcp/10.0.0.243/53' 2>/dev/null; then
      echo "$(date): ✓ VPN is working properly"
      
      # VPN is fine, just refresh port forwarding
      rm -f /var/lib/pia/forwarded_port
      echo "$(date): Deleted old port file, restarting port forwarding..."
      systemctl start pia-port-forward.service 2>/dev/null || true
      
      # Wait for new port
      for i in {1..15}; do
        if [ -f /var/lib/pia/forwarded_port ]; then
          NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port)
          echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
          break
        fi
        sleep 1
      done
      
      echo "$(date): ✅ Resume complete - VPN working, port forwarding refreshed"
    else
      echo "$(date): ✗ VPN DNS test failed, connection is broken"
      echo "$(date): Reconnecting to restore VPN..."
      reconnect_vpn
    fi
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    exit 1
    ;;
esac

reconnect_vpn() {
  echo "$(date): Stopping VPN interface..."
  wg-quick down pia 2>/dev/null || true
  sleep 2
  
  echo "$(date): Restarting pia-vpn service..."
  systemctl restart pia-vpn.service
  
  echo "$(date): Waiting for new VPN connection..."
  for i in {1..30}; do
    if ip addr show pia | grep -q "inet "; then
      echo "$(date): ✓ VPN reconnected"
      
      # Delete old port file to force fresh assignment
      rm -f /var/lib/pia/forwarded_port
      
      # Start port forwarding with fresh port
      echo "$(date): Starting port forwarding with fresh port..."
      systemctl start pia-port-forward.service 2>/dev/null || true
      
      # Wait for new port to be assigned
      for j in {1..15}; do
        if [ -f /var/lib/pia/forwarded_port ]; then
          NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port)
          echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
          break
        fi
        sleep 1
      done
      
      echo "$(date): ✅ VPN and port forwarding restored"
      return 0
    fi
    sleep 1
  done
  
  echo "$(date): ✗ Failed to reconnect VPN after resume"
  echo "$(date): Manual reconnection needed: sudo systemctl restart pia-vpn.service"
  return 1
}
