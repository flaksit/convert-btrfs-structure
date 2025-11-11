#!/bin/bash
# Step 4.1: Prepare Mount Points for Btrfs Conversion
#
# This script mounts all the new subvolumes created in Phase 3
# at appropriate mount points for data Conversion.
#
# Usage: sudo ./4.1-prepare-mount-points.sh <device>
#   Example: sudo ./4.1-prepare-mount-points.sh /dev/nvme0n1p5

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Check if device argument provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <device>"
    echo "  Example: $0 /dev/nvme0n1p5"
    exit 1
fi

DEVICE="$1"

# Validate device exists
if [ ! -b "$DEVICE" ]; then
    echo "ERROR: Device $DEVICE does not exist or is not a block device"
    exit 1
fi

# Verify it's a btrfs filesystem
if ! blkid "$DEVICE" | grep -q "TYPE=\"btrfs\""; then
    echo "ERROR: Device $DEVICE is not a btrfs filesystem"
    blkid "$DEVICE"
    exit 1
fi

echo "=== Step 4.1: Prepare Mount Points ==="
echo "Device: $DEVICE"
echo ""

# Create mount point for new subvolumes
echo "Creating mount point directory..."
mkdir -p /mnt/new

echo "/mnt/btrfs is already mounted to top-level (from Phase 2.2)"
echo ""

# Mount new subvolumes
echo "Mounting @ subvolume at /mnt/new..."
mount -t btrfs -o subvol=@ "$DEVICE" /mnt/new

echo "Creating directory structure in @..."
mkdir -p /mnt/new/{home,var/log,var/cache,var/lib/libvirt/images,swap,.snapshots}

echo "Mounting subvolumes at their target locations..."
mount -t btrfs -o subvol=@home "$DEVICE" /mnt/new/home
mount -t btrfs -o subvol=@var_log "$DEVICE" /mnt/new/var/log
mount -t btrfs -o subvol=@var_cache "$DEVICE" /mnt/new/var/cache
mount -t btrfs -o subvol=@libvirt_images "$DEVICE" /mnt/new/var/lib/libvirt/images
mount -t btrfs -o subvol=@swap "$DEVICE" /mnt/new/swap
mount -t btrfs -o subvol=@snapshots "$DEVICE" /mnt/new/.snapshots

echo ""
echo "=== Mount verification ==="
mount | grep "$(basename "$DEVICE")"

echo ""
echo "✓ Step 4.1 completed successfully"
echo "  All subvolumes are now mounted and ready for data Conversion"
