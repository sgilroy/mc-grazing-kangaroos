#!/bin/bash
# Minecraft Server on GCP - Setup Script
# 
# Usage:
#   1. Copy .env.example to .env.local and fill in your values
#   2. Run: ./scripts/setup-gcp.sh
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - A GCP project created
#   - Billing account linked to the project

set -e  # Exit on error

# Load environment variables
if [ -f .env.local ]; then
    export $(grep -v '^#' .env.local | xargs)
elif [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Required variables with defaults
PROJECT="${GCP_PROJECT:?Error: GCP_PROJECT not set}"
ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-mc}"
MACHINE_TYPE="${GCP_MACHINE_TYPE:-e2-medium}"
BOOT_DISK_SIZE="${GCP_BOOT_DISK_SIZE:-10GB}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
PAPER_BUILD="${PAPER_BUILD:-69}"
RCON_PASSWORD="${RCON_PASSWORD:?Error: RCON_PASSWORD not set}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-60}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-}"

echo "=== Minecraft Server Setup on GCP ==="
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Instance: $INSTANCE"
echo "Machine Type: $MACHINE_TYPE"
echo ""

# Confirm before proceeding
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

echo ""
echo "=== Step 1: Set GCP Project ==="
gcloud config set project "$PROJECT"

echo ""
echo "=== Step 2: Create Firewall Rule ==="
gcloud compute firewall-rules create allow-minecraft-25565 \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:25565 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=minecraft \
    2>/dev/null || echo "Firewall rule already exists"

echo ""
echo "=== Step 3: Create VM Instance ==="
gcloud compute instances create "$INSTANCE" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --tags=minecraft \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size="$BOOT_DISK_SIZE" \
    --boot-disk-type=pd-standard \
    2>/dev/null || echo "Instance already exists"

# Wait for VM to be ready
echo "Waiting for VM to be ready..."
sleep 30

echo ""
echo "=== Step 4: Install Java ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command \
    "sudo apt-get update && sudo apt-get install -y openjdk-21-jre-headless curl unzip"

echo ""
echo "=== Step 5: Create Minecraft User ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command \
    "sudo useradd -r -m -U -d /opt/minecraft minecraft 2>/dev/null || true && \
     sudo mkdir -p /opt/minecraft/server && \
     sudo chown -R minecraft:minecraft /opt/minecraft"

echo ""
echo "=== Step 6: Download Paper and Setup Server ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "sudo -u minecraft -H bash -lc '
cd /opt/minecraft/server
curl -L -o paper.jar \"https://api.papermc.io/v2/projects/paper/versions/$MINECRAFT_VERSION/builds/$PAPER_BUILD/downloads/paper-$MINECRAFT_VERSION-$PAPER_BUILD.jar\"
java -Xms1G -Xmx2G -jar paper.jar nogui || true
echo \"eula=true\" > eula.txt
'"

echo ""
echo "=== Step 7: Configure server.properties ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "sudo -u minecraft bash -c '
cat >> /opt/minecraft/server/server.properties << EOF
enable-rcon=true
rcon.port=25575
rcon.password=$RCON_PASSWORD
EOF
'"

echo ""
echo "=== Step 8: Create Systemd Service ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "sudo tee /etc/systemd/system/minecraft.service > /dev/null << 'EOF'
[Unit]
Description=Minecraft Server (Paper)
After=network.target

[Service]
User=minecraft
WorkingDirectory=/opt/minecraft/server
Restart=on-failure
RestartSec=5
ExecStart=/usr/bin/java -Xms1G -Xmx3G -jar paper.jar nogui

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable minecraft
sudo systemctl start minecraft"

echo ""
echo "=== Step 9: Install mcrcon ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command \
    "cd /tmp && curl -sL https://github.com/Tiiffi/mcrcon/releases/download/v0.7.2/mcrcon-0.7.2-linux-x86-64.tar.gz | tar xz && sudo mv mcrcon /usr/local/bin/"

echo ""
echo "=== Step 10: Setup Idle Shutdown ==="
# Upload idle shutdown script
gcloud compute scp scripts/mc-idle-shutdown.sh "$INSTANCE":/tmp/mc-idle-shutdown.sh --zone="$ZONE"
gcloud compute scp scripts/mc-idle-shutdown.timer "$INSTANCE":/tmp/mc-idle-shutdown.timer --zone="$ZONE"
gcloud compute scp scripts/mc-idle-shutdown.service "$INSTANCE":/tmp/mc-idle-shutdown.service --zone="$ZONE"

gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "
sudo mv /tmp/mc-idle-shutdown.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/mc-idle-shutdown.sh
sudo sed -i 's|RCON_PASS=.*|RCON_PASS=\"$RCON_PASSWORD\"|' /usr/local/bin/mc-idle-shutdown.sh
sudo sed -i 's|IDLE_THRESHOLD=.*|IDLE_THRESHOLD=$IDLE_TIMEOUT|' /usr/local/bin/mc-idle-shutdown.sh
sudo mv /tmp/mc-idle-shutdown.timer /etc/systemd/system/
sudo mv /tmp/mc-idle-shutdown.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mc-idle-shutdown.timer
sudo systemctl start mc-idle-shutdown.timer
"

# Step 11: Setup Duck DNS (if configured)
if [ -n "$DUCKDNS_TOKEN" ] && [ -n "$DUCKDNS_DOMAIN" ]; then
    echo ""
    echo "=== Step 11: Setup Duck DNS ==="
    
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
    echo "Duck DNS configured: $DUCKDNS_DOMAIN.duckdns.org"
else
    echo ""
    echo "=== Skipping Duck DNS (not configured) ==="
    echo "To enable: set DUCKDNS_TOKEN and DUCKDNS_DOMAIN in .env.local"
fi

echo ""
echo "=== Setup Complete! ==="
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo ""
echo "Server Address: $EXTERNAL_IP:25565"
if [ -n "$DUCKDNS_DOMAIN" ]; then
    echo "DNS Address:    $DUCKDNS_DOMAIN.duckdns.org:25565"
fi
echo ""
echo "Next steps:"
echo "1. Deploy Cloud Function: cd cloud-function && ./deploy.sh"
echo "2. Wait ~60 seconds for server to fully start"
echo "3. Connect with Minecraft $MINECRAFT_VERSION"
