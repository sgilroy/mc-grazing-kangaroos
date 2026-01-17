#!/bin/bash
# Setup Duck DNS on an existing Minecraft server VM
#
# Usage:
#   ./scripts/setup-duckdns.sh
#
# Requires DUCKDNS_TOKEN and DUCKDNS_DOMAIN in .env.local

set -e

# Load environment variables
if [ -f .env.local ]; then
    export $(grep -v '^#' .env.local | xargs)
elif [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-mc}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:?Error: DUCKDNS_TOKEN not set in .env.local}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:?Error: DUCKDNS_DOMAIN not set in .env.local}"

echo "=== Setting up Duck DNS ==="
echo "Domain: $DUCKDNS_DOMAIN.duckdns.org"
echo "Instance: $INSTANCE"
echo "Zone: $ZONE"
echo ""

# Upload DNS update script
gcloud compute scp scripts/update-dns.sh "$INSTANCE":/tmp/update-dns.sh --zone="$ZONE"
gcloud compute scp scripts/update-dns.service "$INSTANCE":/tmp/update-dns.service --zone="$ZONE"

gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "
sudo mv /tmp/update-dns.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/update-dns.sh
sudo sed -i 's|DUCKDNS_TOKEN=.*|DUCKDNS_TOKEN=\"$DUCKDNS_TOKEN\"|' /usr/local/bin/update-dns.sh
sudo sed -i 's|DUCKDNS_DOMAIN=.*|DUCKDNS_DOMAIN=\"$DUCKDNS_DOMAIN\"|' /usr/local/bin/update-dns.sh
sudo mv /tmp/update-dns.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable update-dns.service
sudo systemctl start update-dns.service
"

echo ""
echo "=== Duck DNS Setup Complete ==="
echo "Domain: $DUCKDNS_DOMAIN.duckdns.org"
echo ""
echo "The DNS will be updated each time the server starts."
echo "To test immediately: gcloud compute ssh $INSTANCE --zone=$ZONE --command 'sudo systemctl restart update-dns.service'"
