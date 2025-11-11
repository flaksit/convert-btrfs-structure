#!/bin/bash
# Step 4.2b: Copy /var Except /var/log
#
# This script copies all subdirectories of /var from /mnt/btrfs to /mnt/new,
# excluding /var/log (which will be handled separately in step 4.2c).
#
# Uses --reflink=always for instant CoW copies.
#
# Usage: sudo ./4.2b-copy-var-except-log.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Verify source directory exists
if [ ! -d /mnt/btrfs/var ]; then
    echo "ERROR: /mnt/btrfs/var does not exist"
    exit 1
fi

# Verify destination mount point exists
if ! mountpoint -q /mnt/new; then
    echo "ERROR: /mnt/new is not mounted"
    echo "Please run step 4.1 (prepare mount points) first"
    exit 1
fi

echo "=== Step 4.2b: Copy /var Except /var/log ==="
echo ""
echo "Source: /mnt/btrfs/var"
echo "Destination: /mnt/new/var"
echo ""
echo "Using CoW reflinks (--reflink=always) for instant copy"
echo "This should complete in seconds..."
echo ""

# Create /var in destination (if not already present)
mkdir -p /mnt/new/var

cd /mnt/btrfs/var

# Count items to copy for progress indication
total_items=$(find . -maxdepth 1 -mindepth 1 ! -name log | wc -l)
echo "Copying $total_items subdirectories of /var (excluding log/)..."
echo ""

# Copy all subdirectories of /var except /var/log
find . -maxdepth 1 -mindepth 1 ! -name log -print0 | \
  xargs -0 -I {} cp -ax --reflink=always {} /mnt/new/var/

echo ""
echo "✓ Step 4.2b completed successfully"
echo "  All /var subdirectories (except log/) copied to @ subvolume"
