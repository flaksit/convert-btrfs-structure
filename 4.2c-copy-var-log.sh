#!/bin/bash
# Step 4.2c: Copy /var/log Separately
#
# This script copies /var/log from /mnt/btrfs to /mnt/new/var/log
# using --reflink=auto (instead of --reflink=always).
#
# The /var/log directory may contain mixed CoW/NOCOW files from earlier
# configurations. Using --reflink=auto allows reflinks when possible,
# but falls back to physical copy for files that can't be reflinked.
#
# Usage: sudo ./4.2c-copy-var-log.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Verify source directory exists
if [ ! -d /mnt/btrfs/var/log ]; then
    echo "ERROR: /mnt/btrfs/var/log does not exist"
    exit 1
fi

# Verify destination mount point exists
if ! mountpoint -q /mnt/new/var/log; then
    echo "ERROR: /mnt/new/var/log is not mounted"
    echo "Please run step 4.1 (prepare mount points) first"
    exit 1
fi

echo "=== Step 4.2c: Copy /var/log Separately ==="
echo ""
echo "Source: /mnt/btrfs/var/log"
echo "Destination: /mnt/new/var/log"
echo ""
echo "Using --reflink=auto to handle mixed CoW/NOCOW source files"
echo "(reflinks when possible, physical copy as fallback)"
echo "This should complete quickly..."
echo ""

# Copy /var/log with --reflink=auto
cp -ax --reflink=auto /mnt/btrfs/var/log/. /mnt/new/var/log/

echo ""
echo "✓ Step 4.2c completed successfully"
echo "  /var/log copied to @var_log subvolume"
echo ""
echo "=== Step 4.2d: Cleanup ==="
echo ""
echo "Removing old/unused directories and files from @ subvolume..."

# Remove old/unused subvolume directories
echo "  - Removing old @ subvolume directories..."
rm -rf /mnt/new/@* 2>/dev/null || true

# Remove old swapfile
echo "  - Removing old swapfile..."
rm -f /mnt/new/swap.img

echo ""
echo "✓ Step 4.2d cleanup completed"
echo ""
echo "✓ All of Phase 4.2 completed successfully"
echo "  All data has been migrated to the new subvolume structure"
