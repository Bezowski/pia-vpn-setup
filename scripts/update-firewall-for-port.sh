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

# Get list of all current UFW rules with Samba/Nicotine ports
# We want to remove old PIA port rules but keep Samba (139, 445, 137, 138) and Nicotine base ports (2240, 2242)
CURRENT_RULES=$(ufw status numbered | grep -E "2240,2242,[0-9]+" | grep ALLOW)

# Extract old port numbers from rules (anything that's not 2240 or 2242)
while IFS= read -r rule; do
    # Extract the port range from the rule
    if [[ $rule =~ 2240,2242,([0-9]+) ]]; then
        OLD_PORT="${BASH_REMATCH[1]}"
        # Only delete if it's not the current port
        if [ "$OLD_PORT" != "$PORT" ]; then
            echo "Removing old port rule: 2240,2242,$OLD_PORT"
            ufw delete allow 2240,2242,$OLD_PORT/tcp 2>/dev/null || true
        fi
    fi
done <<< "$CURRENT_RULES"

# Check if current port rule already exists
if ufw status | grep -q "2240,2242,$PORT/tcp"; then
    echo "Firewall rule for port $PORT already exists"
else
    # Add new rule with current port
    echo "Adding firewall rule for port $PORT"
    ufw allow 2240,2242,$PORT/tcp
    echo "✓ Firewall updated: ports 2240, 2242, $PORT are now allowed"
fi

# Add a comment to identify PIA rules (for manual inspection)
echo ""
echo "Current PIA VPN port: $PORT"
echo "To view all firewall rules: sudo ufw status numbered"
