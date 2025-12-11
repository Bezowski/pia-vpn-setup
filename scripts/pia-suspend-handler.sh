#!/bin/bash
# Handle PIA VPN on suspend/resume
# Strategy: Stop port forwarding before suspend, get a fresh port after resume
# This avoids signature/binding mismatches that occur when restarting mid-session

case "$1" in
  pre)
    echo "$(date): Preparing for suspend - stopping port forwarding"
    systemctl stop pia-port-forward.service 2>/dev/null || true
    echo "$(date): Port forwarding stopped (VPN stays connected)"
    ;;
    
  post)
    echo "$(date): Resuming from suspend - getting fresh forwarded port"
    sleep 5  # Wait for network to stabilize
    
    # Delete the old port file so we get a completely fresh port from PIA's API
    # This avoids signature mismatches that were causing connectivity issues
    rm -f /var/lib/pia/forwarded_port
    echo "$(date): Deleted old port file, requesting fresh port..."
    
    # Start port forwarding service to get a new port
    systemctl start pia-port-forward.service 2>/dev/null || true
    
    # Wait for new port to be assigned (up to 15 seconds)
    for i in {1..15}; do
      if [ -f /var/lib/pia/forwarded_port ]; then
        NEW_PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port)
        echo "$(date): ✅ Got fresh forwarded port: $NEW_PORT"
        break
      fi
      sleep 1
    done
    
    if [ ! -f /var/lib/pia/forwarded_port ]; then
      echo "$(date): ⚠️  Warning - port not assigned within 15 seconds"
      echo "$(date): Check status: systemctl status pia-port-forward.service"
    else
      # Port successfully assigned. The Nicotine+ plugin will detect the change
      # within 30 seconds and update the port automatically. No action needed.
      echo "$(date): ✅ Port forwarding resumed. Plugin will detect port change automatically."
    fi
    ;;
    
  *)
    echo "Usage: $0 {pre|post}"
    exit 1
    ;;
esac
