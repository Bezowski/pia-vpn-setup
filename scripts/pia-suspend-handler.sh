#!/bin/bash
# Handle PIA VPN on suspend/resume
# Keep VPN connected through suspend, just pause port forwarding

case "$1" in
  pre)
    echo "$(date): Preparing for suspend - pausing port forwarding"
    systemctl stop pia-port-forward.service 2>/dev/null || true
    echo "$(date): Port forwarding paused (VPN stays connected)"
    ;;
    
  post)
    echo "$(date): Resuming from suspend - reconnecting port forwarding"
    sleep 5  # Wait for network to stabilize
    systemctl start pia-port-forward.service 2>/dev/null || true
    echo "$(date): Port forwarding resumed with same port"
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    exit 1
    ;;
esac
