#!/bin/bash
# Minecraft Idle Shutdown Script
# Shuts down VM if no players connected for IDLE_THRESHOLD seconds

RCON_HOST="localhost"
RCON_PORT="25575"
RCON_PASS="${RCON_PASSWORD:-changeme}"  # Set via environment or update on server
IDLE_THRESHOLD=60  # seconds
STATE_FILE="/tmp/mc-idle-since"

# Get player count using RCON 'list' command
PLAYER_OUTPUT=$(mcrcon -H $RCON_HOST -P $RCON_PORT -p $RCON_PASS "list" 2>/dev/null)

# Extract player count (format: "There are X of Y max players online:")
PLAYER_COUNT=$(echo "$PLAYER_OUTPUT" | grep -oP 'There are \K[0-9]+' || echo "-1")

if [ "$PLAYER_COUNT" = "-1" ]; then
    echo "[$(date)] Could not get player count - server may be starting"
    exit 0
fi

echo "[$(date)] Players online: $PLAYER_COUNT"

if [ "$PLAYER_COUNT" -eq 0 ]; then
    if [ ! -f "$STATE_FILE" ]; then
        # Start tracking idle time
        date +%s > "$STATE_FILE"
        echo "[$(date)] Server idle - starting countdown"
    else
        IDLE_SINCE=$(cat "$STATE_FILE")
        NOW=$(date +%s)
        IDLE_DURATION=$((NOW - IDLE_SINCE))
        echo "[$(date)] Idle for ${IDLE_DURATION}s (threshold: ${IDLE_THRESHOLD}s)"
        
        if [ "$IDLE_DURATION" -ge "$IDLE_THRESHOLD" ]; then
            echo "[$(date)] Idle threshold reached - shutting down VM"
            # Notify any watching logs
            logger "Minecraft idle shutdown: No players for ${IDLE_DURATION}s"
            # Graceful shutdown
            sudo shutdown -h now
        fi
    fi
else
    # Players online - reset idle timer
    if [ -f "$STATE_FILE" ]; then
        echo "[$(date)] Players joined - resetting idle timer"
        rm -f "$STATE_FILE"
    fi
fi
