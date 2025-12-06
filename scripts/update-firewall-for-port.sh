#!/bin/bash
# Wait for port to be available
for i in {1..30}; do
    PORT=$(awk '{print $1}' /var/lib/pia/forwarded_port 2>/dev/null)
    [ -n "$PORT" ] && break
    sleep 1
done

if [ -z "$PORT" ]; then
    echo "Error: No forwarded port found after 30 seconds"
    exit 1
fi

echo "Updating firewall for port $PORT"

# Remove old Soulseek port rules (keep Samba ports)
ufw delete allow 2240,2242,50703/tcp 2>/dev/null
ufw delete allow 2240,2242,35427/tcp 2>/dev/null
ufw delete allow 2240,2242,35510/tcp 2>/dev/null
ufw delete allow 2240,2242,56855/tcp 2>/dev/null

# Add new rule with current port
ufw allow 2240,2242,$PORT/tcp

echo "Firewall updated: port $PORT is now allowed"
