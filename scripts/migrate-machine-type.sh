#!/bin/bash
# Migrate VM to a different machine type
# Usage: ./migrate-machine-type.sh [machine-type]
# Example: ./migrate-machine-type.sh e2-standard-4

set -e

# Load environment variables if available
if [ -f "$(dirname "$0")/../.env.local" ]; then
    source "$(dirname "$0")/../.env.local"
fi

# Defaults
ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE_NAME="${GCP_INSTANCE:-mc}"
NEW_MACHINE_TYPE="${1:-}"

# Available machine types for reference
show_machine_types() {
    echo "Recommended machine types for Minecraft servers:"
    echo ""
    echo "  Budget (shared vCPU) - Good for small servers:"
    echo "    e2-medium      - 2 vCPU (shared), 4GB RAM   (~\$24/mo)  [current default]"
    echo "    e2-standard-2  - 2 vCPU (shared), 8GB RAM   (~\$49/mo)  Double RAM"
    echo ""
    echo "  Best Value - Recommended for most servers:"
    echo "    e2-highmem-2   - 2 vCPU (shared), 16GB RAM  (~\$66/mo)  ⭐ Best RAM/cost ratio"
    echo "    n2d-highmem-2  - 2 vCPU (dedicated), 16GB   (~\$83/mo)  AMD, not shared"
    echo ""
    echo "  Performance - For mods/plugins or many players:"
    echo "    e2-standard-4  - 4 vCPU (shared), 16GB RAM  (~\$98/mo)  More CPU"
    echo "    n2d-standard-4 - 4 vCPU (dedicated), 16GB   (~\$123/mo) Dedicated AMD"
    echo ""
    echo "  Heavy Workloads - Modpacks, large worlds, 20+ players:"
    echo "    e2-highmem-4   - 4 vCPU (shared), 32GB RAM  (~\$132/mo)"
    echo "    n2d-highmem-4  - 4 vCPU (dedicated), 32GB   (~\$166/mo) Best performance"
    echo ""
    echo "  Note: Minecraft benefits more from RAM than CPU. e2-highmem-2 is usually sufficient."
    echo ""
}

if [ -z "$NEW_MACHINE_TYPE" ]; then
    echo "Usage: $0 <machine-type>"
    echo ""
    show_machine_types
    echo "Current VM status:"
    gcloud compute instances describe "$INSTANCE_NAME" --zone "$ZONE" \
        --format='table(name, status, machineType.basename())' 2>/dev/null || echo "  Could not fetch VM info"
    exit 1
fi

echo "=== Minecraft Server Machine Type Migration ==="
echo ""
echo "Instance:    $INSTANCE_NAME"
echo "Zone:        $ZONE"
echo "New type:    $NEW_MACHINE_TYPE"
echo ""

# Get current status and machine type
CURRENT_STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone "$ZONE" \
    --format='get(status)' 2>/dev/null)
CURRENT_TYPE=$(gcloud compute instances describe "$INSTANCE_NAME" --zone "$ZONE" \
    --format='get(machineType)' 2>/dev/null | xargs basename)

echo "Current type: $CURRENT_TYPE"
echo "Current status: $CURRENT_STATUS"
echo ""

if [ "$CURRENT_TYPE" == "$NEW_MACHINE_TYPE" ]; then
    echo "VM is already using $NEW_MACHINE_TYPE. Nothing to do."
    exit 0
fi

read -p "Migrate from $CURRENT_TYPE to $NEW_MACHINE_TYPE? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Stop VM if running
if [ "$CURRENT_STATUS" == "RUNNING" ]; then
    echo ""
    echo "Stopping VM..."
    gcloud compute instances stop "$INSTANCE_NAME" --zone "$ZONE"
    echo "Waiting for VM to stop..."
    
    # Wait for VM to fully stop
    while [ "$(gcloud compute instances describe "$INSTANCE_NAME" --zone "$ZONE" --format='get(status)')" != "TERMINATED" ]; do
        sleep 2
    done
    echo "VM stopped."
fi

# Change machine type
echo ""
echo "Changing machine type to $NEW_MACHINE_TYPE..."
gcloud compute instances set-machine-type "$INSTANCE_NAME" --zone "$ZONE" \
    --machine-type "$NEW_MACHINE_TYPE"

echo "Machine type changed successfully!"
echo ""

# Ask if user wants to start the VM
read -p "Start the VM now? (Y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "Starting VM..."
    gcloud compute instances start "$INSTANCE_NAME" --zone "$ZONE"
    echo ""
    echo "VM started with new machine type: $NEW_MACHINE_TYPE"
    echo "The server should be accessible shortly."
else
    echo "VM left stopped. Start manually with:"
    echo "  gcloud compute instances start $INSTANCE_NAME --zone $ZONE"
fi
