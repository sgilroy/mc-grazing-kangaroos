#!/bin/bash
# Maintenance Mode Script
# Temporarily disables auto-shutdown timer for server maintenance

set -e

DEFAULT_DURATION=60  # minutes
TIMER_UNIT="mc-idle-shutdown.timer"

usage() {
    echo "Usage: $0 [on|off|status] [duration_minutes]"
    echo ""
    echo "Commands:"
    echo "  on [minutes]  - Enable maintenance mode (disable auto-shutdown)"
    echo "                  Default: ${DEFAULT_DURATION} minutes"
    echo "  off           - Disable maintenance mode (re-enable auto-shutdown)"
    echo "  status        - Show current maintenance mode status"
    echo ""
    echo "Examples:"
    echo "  $0 on         # Disable auto-shutdown for 1 hour"
    echo "  $0 on 30      # Disable auto-shutdown for 30 minutes"
    echo "  $0 on 120     # Disable auto-shutdown for 2 hours"
    echo "  $0 off        # Re-enable auto-shutdown immediately"
    echo "  $0 status     # Check if maintenance mode is active"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root (use sudo)"
        exit 1
    fi
}

get_timer_status() {
    systemctl is-active "$TIMER_UNIT" 2>/dev/null || echo "inactive"
}

cancel_scheduled_reenable() {
    # Cancel any pending re-enable timers
    local timers=$(systemctl list-timers --all | grep "maintenance-reenable" | awk '{print $NF}')
    for timer in $timers; do
        systemctl stop "$timer" 2>/dev/null || true
    done
    # Also try to stop by known name
    systemctl stop maintenance-reenable.timer 2>/dev/null || true
}

enable_maintenance() {
    local duration=${1:-$DEFAULT_DURATION}
    
    # Validate duration is a number
    if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
        echo "Error: Duration must be a positive number (minutes)"
        exit 1
    fi
    
    echo "🔧 Enabling maintenance mode for ${duration} minutes..."
    
    # Cancel any existing scheduled re-enable
    cancel_scheduled_reenable
    
    # Stop the auto-shutdown timer
    systemctl stop "$TIMER_UNIT"
    
    # Clear the idle state file so countdown resets when re-enabled
    rm -f /tmp/mc-idle-since
    
    # Schedule automatic re-enable using systemd-run (survives disconnects)
    systemd-run --on-active="${duration}m" \
        --unit=maintenance-reenable \
        --description="Re-enable Minecraft auto-shutdown after maintenance" \
        /bin/bash -c "systemctl start $TIMER_UNIT && logger 'Maintenance mode ended - auto-shutdown re-enabled'"
    
    local end_time=$(date -d "+${duration} minutes" "+%H:%M:%S" 2>/dev/null || date -v+${duration}M "+%H:%M:%S")
    
    echo "✅ Maintenance mode ENABLED"
    echo "   Auto-shutdown is disabled"
    echo "   Will automatically re-enable at: ${end_time} (in ${duration} minutes)"
    echo ""
    echo "   To re-enable sooner: sudo $0 off"
    echo "   To check status:     sudo $0 status"
}

disable_maintenance() {
    echo "🔧 Disabling maintenance mode..."
    
    # Cancel any scheduled re-enable
    cancel_scheduled_reenable
    
    # Start the auto-shutdown timer
    systemctl start "$TIMER_UNIT"
    
    # Clear idle state so fresh countdown starts
    rm -f /tmp/mc-idle-since
    
    echo "✅ Maintenance mode DISABLED"
    echo "   Auto-shutdown is now active"
    echo "   Server will shutdown after 60 seconds with no players"
}

show_status() {
    local timer_status=$(get_timer_status)
    local reenable_scheduled=$(systemctl is-active maintenance-reenable.timer 2>/dev/null || echo "inactive")
    
    echo "=== Maintenance Mode Status ==="
    echo ""
    
    # Get RCON password from server.properties
    local rcon_pass=$(grep -oP '^rcon\.password=\K.*' /opt/minecraft/server/server.properties 2>/dev/null || echo "changeme")
    
    # Get player count via RCON
    local player_output=$(mcrcon -H localhost -P 25575 -p "$rcon_pass" "list" 2>/dev/null)
    local player_count=$(echo "$player_output" | grep -oP 'There are \K[0-9]+' || echo "-1")
    
    if [ "$timer_status" = "active" ]; then
        echo "🟢 Auto-shutdown: ENABLED (normal operation)"
        echo "   Maintenance mode is OFF"
        
        # Show next trigger time and relative duration
        local timer_info=$(systemctl list-timers "$TIMER_UNIT" --no-legend 2>/dev/null)
        if [ -n "$timer_info" ]; then
            # Format: NEXT                         LEFT     LAST                         PASSED  UNIT
            # e.g.:   Sun 2026-01-18 04:00:00 UTC  30s left Sun 2026-01-18 03:59:30 UTC  30s ago mc-idle...
            local next_time=$(echo "$timer_info" | awk '{print $1, $2, $3, $4}')
            local time_left=$(echo "$timer_info" | awk '{print $5}')
            echo "   Next check: ${next_time} (in ${time_left})"
        fi
        
        # Show player count and idle status
        if [ "$player_count" = "-1" ]; then
            echo "   ⚠️  Could not query player count (server starting?)"
        elif [ "$player_count" -eq 0 ]; then
            echo "   👥 Players online: 0"
            if [ -f /tmp/mc-idle-since ]; then
                local idle_since=$(cat /tmp/mc-idle-since)
                local now=$(date +%s)
                local idle_duration=$((now - idle_since))
                echo "   ⏱️  Idle for ${idle_duration}s (shutdown at 60s)"
            else
                echo "   Idle timer not started yet"
            fi
        else
            echo "   👥 Players online: ${player_count}"
        fi
    else
        echo "🟡 Auto-shutdown: DISABLED (maintenance mode)"
        echo "   Maintenance mode is ON"
        
        if [ "$reenable_scheduled" = "active" ]; then
            local reenable_time=$(systemctl list-timers maintenance-reenable.timer --no-legend 2>/dev/null | awk '{print $1, $2}')
            echo "   ⏰ Will re-enable at: ${reenable_time}"
        else
            echo "   ⚠️  No automatic re-enable scheduled!"
            echo "      Run 'sudo $0 off' to re-enable manually"
        fi
    fi
    echo ""
}

# Main
case "${1:-status}" in
    on|enable)
        check_root
        enable_maintenance "$2"
        ;;
    off|disable)
        check_root
        disable_maintenance
        ;;
    status)
        show_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac
