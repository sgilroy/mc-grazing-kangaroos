#!/bin/bash
# Minecraft World Backup Restore Script
#
# Restores a Minecraft Realms or vanilla world backup to Paper server,
# handling the dimension folder structure differences.
#
# Usage:
#   ./scripts/restore-backup.sh /path/to/backup.zip [world-folder-name]
#
# The world-folder-name is optional - the script will try to auto-detect it.

set -e

# Load environment variables
if [ -f .env.local ]; then
    export $(grep -v '^#' .env.local | xargs)
elif [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-mc}"
BACKUP_FILE="$1"
WORLD_FOLDER="$2"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 /path/to/backup.zip [world-folder-name]"
    echo ""
    echo "Example:"
    echo "  $0 ~/Downloads/my-world-backup.zip"
    echo "  $0 ~/Downloads/realms-backup.zip 'Grazing Kangaroos (Fitcraft)-6'"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "=== Minecraft World Backup Restore ==="
echo "Backup: $BACKUP_FILE"
echo "Instance: $INSTANCE (zone: $ZONE)"
echo ""

# Show contents of backup
echo "=== Backup Contents ==="
unzip -l "$BACKUP_FILE" | head -30
echo ""

# Try to auto-detect world folder name if not provided
if [ -z "$WORLD_FOLDER" ]; then
    # Look for a folder containing 'level.dat'
    WORLD_FOLDER=$(unzip -l "$BACKUP_FILE" | grep "level.dat" | head -1 | awk '{print $4}' | sed 's|/level.dat||')
    if [ -z "$WORLD_FOLDER" ]; then
        echo "Error: Could not auto-detect world folder. Please specify it as the second argument."
        exit 1
    fi
    echo "Auto-detected world folder: $WORLD_FOLDER"
fi

echo ""
read -p "This will REPLACE the current world. Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

echo ""
echo "=== Step 1: Upload Backup ==="
gcloud compute scp "$BACKUP_FILE" "$INSTANCE":/tmp/backup.zip --zone="$ZONE"

echo ""
echo "=== Step 2: Stop Server ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "sudo systemctl stop minecraft && echo 'Server stopped'"

echo ""
echo "=== Step 3: Extract and Restore ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "
cd /tmp
sudo rm -rf '$WORLD_FOLDER' 2>/dev/null || true
sudo unzip -o backup.zip
echo 'Extracted backup'

# Backup current world (just in case)
sudo mv /opt/minecraft/server/world /opt/minecraft/server/world.bak.\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

# Move extracted world to server
sudo mv '$WORLD_FOLDER' /opt/minecraft/server/world
echo 'Moved world folder'

# CRITICAL: Handle Paper's dimension folder structure
# Paper stores dimensions in separate folders, not inside the main world folder

# Nether (DIM-1)
if [ -d /opt/minecraft/server/world/DIM-1 ]; then
    echo 'Moving Nether (DIM-1) to Paper structure...'
    sudo rm -rf /opt/minecraft/server/world_nether/DIM-1 2>/dev/null || true
    sudo mkdir -p /opt/minecraft/server/world_nether
    sudo mv /opt/minecraft/server/world/DIM-1 /opt/minecraft/server/world_nether/
    echo \"  Nether regions: \$(ls /opt/minecraft/server/world_nether/DIM-1/region/ 2>/dev/null | wc -l) files\"
fi

# The End (DIM1)
if [ -d /opt/minecraft/server/world/DIM1 ]; then
    echo 'Moving The End (DIM1) to Paper structure...'
    sudo rm -rf /opt/minecraft/server/world_the_end/DIM1 2>/dev/null || true
    sudo mkdir -p /opt/minecraft/server/world_the_end
    sudo mv /opt/minecraft/server/world/DIM1 /opt/minecraft/server/world_the_end/
    echo \"  End regions: \$(ls /opt/minecraft/server/world_the_end/DIM1/region/ 2>/dev/null | wc -l) files\"
fi

# Fix ownership
sudo chown -R minecraft:minecraft /opt/minecraft/server/world
sudo chown -R minecraft:minecraft /opt/minecraft/server/world_nether 2>/dev/null || true
sudo chown -R minecraft:minecraft /opt/minecraft/server/world_the_end 2>/dev/null || true

echo 'Permissions set'

# Cleanup
sudo rm /tmp/backup.zip
"

echo ""
echo "=== Step 4: Start Server ==="
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "sudo systemctl start minecraft"

echo ""
echo "=== Step 5: Verify ==="
sleep 5
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --command "
echo 'World contents:'
sudo ls -la /opt/minecraft/server/world/ | head -15
echo ''
echo 'Nether regions:'
sudo ls /opt/minecraft/server/world_nether/DIM-1/region/ 2>/dev/null | wc -l
echo 'End regions:'
sudo ls /opt/minecraft/server/world_the_end/DIM1/region/ 2>/dev/null | wc -l
"

echo ""
echo "=== Restore Complete! ==="
echo ""
echo "Wait ~60 seconds for server to fully start, then connect."
echo "Check server logs with: gcloud compute ssh $INSTANCE --zone $ZONE --command 'sudo journalctl -u minecraft -f'"
