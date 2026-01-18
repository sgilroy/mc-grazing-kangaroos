#!/bin/bash
# Deploy scripts to the Minecraft server VM

set -e

ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-mc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "📦 Deploying scripts to ${INSTANCE} in ${ZONE}..."

# Copy scripts
echo "Copying scripts..."
gcloud compute scp \
    "$SCRIPT_DIR/mc-idle-shutdown.sh" \
    "$SCRIPT_DIR/maintenance-mode.sh" \
    "${INSTANCE}:/tmp/" --zone "$ZONE"

# Copy systemd units
echo "Copying systemd units..."
gcloud compute scp \
    "$SCRIPT_DIR/mc-idle-shutdown.timer" \
    "$SCRIPT_DIR/mc-idle-shutdown.service" \
    "${INSTANCE}:/tmp/" --zone "$ZONE"

# Install on server
echo "Installing on server..."
gcloud compute ssh "$INSTANCE" --zone "$ZONE" --command "
    sudo mv /tmp/mc-idle-shutdown.sh /tmp/maintenance-mode.sh /usr/local/bin/
    sudo chmod +x /usr/local/bin/mc-idle-shutdown.sh /usr/local/bin/maintenance-mode.sh
    sudo mv /tmp/mc-idle-shutdown.timer /tmp/mc-idle-shutdown.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl restart mc-idle-shutdown.timer
    echo 'Timer status:'
    systemctl is-active mc-idle-shutdown.timer
"

echo "✅ Deployment complete!"
