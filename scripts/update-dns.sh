#!/bin/bash
# Update Duck DNS with current external IP
# This script runs on VM startup to update the dynamic DNS record
#
# Setup:
# 1. Go to https://www.duckdns.org/ and sign in with GitHub/Google
# 2. Create a subdomain (e.g., "mc-kangaroos" -> mc-kangaroos.duckdns.org)
# 3. Copy your token from the Duck DNS dashboard
# 4. Set DUCKDNS_TOKEN and DUCKDNS_DOMAIN in your .env.local

# Configuration (replaced during setup)
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-__DUCKDNS_TOKEN__}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-__DUCKDNS_DOMAIN__}"

# Get current external IP from GCP metadata server
EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

if [ -z "$EXTERNAL_IP" ]; then
    echo "ERROR: Could not get external IP"
    exit 1
fi

echo "Updating Duck DNS: $DUCKDNS_DOMAIN.duckdns.org -> $EXTERNAL_IP"

# Update Duck DNS
RESULT=$(curl -s "https://www.duckdns.org/update?domains=$DUCKDNS_DOMAIN&token=$DUCKDNS_TOKEN&ip=$EXTERNAL_IP")

if [ "$RESULT" = "OK" ]; then
    echo "SUCCESS: DNS updated to $EXTERNAL_IP"
else
    echo "ERROR: DNS update failed. Response: $RESULT"
    exit 1
fi
