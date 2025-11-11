#!/bin/bash
# Phase 3: Create New Subvolume Structure
#
# This script creates all the new subvolumes for the btrfs Conversion:
# @, @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots
#
# It also sets the NOCOW (no copy-on-write) attribute on subvolumes
# that benefit from it: @var_log, @libvirt_images, and @swap.
#
# Prerequisites:
# - /mnt/btrfs must be mounted with the top-level subvolume (subvolid=5)
#   from Phase 2.2
#
# Usage: sudo ./3-create-subvolumes.sh
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Verify mount point exists
if [ ! -d /mnt/btrfs ]; then
    echo "ERROR: /mnt/btrfs does not exist"
    echo "Please complete Phase 2.2: Mount the Filesystem first"
    exit 1
fi

# Verify top-level filesystem is mounted
if ! mount | grep -q "/mnt/btrfs.*btrfs"; then
    echo "ERROR: /mnt/btrfs is not mounted with a btrfs filesystem"
    echo "Please complete Phase 2.2: Mount the Filesystem first"
    exit 1
fi

echo "=== Phase 3: Create New Subvolume Structure ==="
echo ""
echo "This script will create 7 new subvolumes:"
echo "  1. @ (root filesystem)"
echo "  2. @home (user home directories)"
echo "  3. @var_log (system logs - NOCOW)"
echo "  4. @var_cache (package cache - standard CoW)"
echo "  5. @libvirt_images (VM disk images - NOCOW)"
echo "  6. @swap (swapfile storage - NOCOW)"
echo "  7. @snapshots (snapshot storage)"
echo ""

# Check for existing subvolumes
existing_subvols=$(btrfs subvolume list /mnt/btrfs 2>/dev/null | wc -l)
if [ "$existing_subvols" -gt 0 ]; then
    echo "WARNING: Existing subvolumes detected:"
    btrfs subvolume list /mnt/btrfs
    echo ""
    echo "If these are the old unused @ and @home subvolumes from your system,"
    echo "they should have been deleted before this step per the Conversion plan."
    echo ""
    read -p "Do you want to proceed? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted"
        exit 1
    fi
    echo ""
fi

echo "Creating subvolumes..."

# Create all subvolumes
echo "  Creating @..."
btrfs subvolume create /mnt/btrfs/@

echo "  Creating @home..."
btrfs subvolume create /mnt/btrfs/@home

echo "  Creating @var_log..."
btrfs subvolume create /mnt/btrfs/@var_log

echo "  Creating @var_cache..."
btrfs subvolume create /mnt/btrfs/@var_cache

echo "  Creating @libvirt_images..."
btrfs subvolume create /mnt/btrfs/@libvirt_images

echo "  Creating @swap..."
btrfs subvolume create /mnt/btrfs/@swap

echo "  Creating @snapshots..."
btrfs subvolume create /mnt/btrfs/@snapshots

echo ""
echo "Setting NOCOW (no copy-on-write) attribute on appropriate subvolumes..."
echo "This improves performance for logs, VM images, and swap."
echo ""

# Set NOCOW attribute on subvolumes
# Files created in these subvolumes will automatically inherit NOCOW
echo "  Setting NOCOW on @var_log..."
chattr +C /mnt/btrfs/@var_log

echo "  Setting NOCOW on @libvirt_images..."
chattr +C /mnt/btrfs/@libvirt_images

echo "  Setting NOCOW on @swap..."
chattr +C /mnt/btrfs/@swap

echo ""
echo "=== Verification ==="
echo ""

# Verify all subvolumes were created
echo "Verifying subvolume creation:"
echo ""
btrfs subvolume list /mnt/btrfs

echo ""
echo "Verifying NOCOW attributes:"
echo ""

# Check NOCOW attributes
nocow_subvols=(@var_log @libvirt_images @swap)
all_nocow_ok=true

for subvol in "${nocow_subvols[@]}"; do
    attrs=$(lsattr -d "/mnt/btrfs/$subvol" 2>/dev/null | awk '{print $1}')

    # Check if the 'C' flag is set (6th position from the right)
    if [[ "$attrs" == *C* ]]; then
        echo "  ✓ $subvol: NOCOW attribute set ($attrs)"
    else
        echo "  ✗ $subvol: NOCOW attribute NOT set ($attrs) - WARNING"
        all_nocow_ok=false
    fi
done

echo ""
echo "=== Summary ==="
echo ""

# Count subvolumes
subvol_count=$(btrfs subvolume list /mnt/btrfs | wc -l)
if [ "$subvol_count" -eq 7 ]; then
    echo "✓ All 7 subvolumes created successfully"
else
    echo "✗ Expected 7 subvolumes, but found $subvol_count"
    exit 1
fi

if [ "$all_nocow_ok" = true ]; then
    echo "✓ NOCOW attributes set correctly on @var_log, @libvirt_images, @swap"
else
    echo "⚠ Some NOCOW attributes may not be set correctly (see above)"
fi

echo ""
echo "✓ Phase 3 completed successfully"
echo ""
echo "Next steps:"
echo "  1. Create a safety snapshot: Phase 2.4"
echo "  2. Mount the new subvolumes: Phase 4.1 (./4.1-prepare-mount-points.sh)"
echo "  3. Copy data: Phase 4.2a, 4.2b, 4.2c"
echo ""
