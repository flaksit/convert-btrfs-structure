#!/bin/bash
# Step 4.2a: Copy Everything Except /var
#
# This script copies all top-level items from /mnt/btrfs (current system data)
# to /mnt/new (@ subvolume and nested subvolumes), excluding /var directory.
#
# Uses --reflink=always for instant CoW copies.
#
# Usage: sudo ./4.2a-copy-except-var.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Verify mount points exist
if ! mountpoint -q /mnt/btrfs; then
    echo "ERROR: /mnt/btrfs is not mounted"
    echo "Please run Phase 2.2 first to mount the top-level filesystem"
    exit 1
fi

if ! mountpoint -q /mnt/new; then
    echo "ERROR: /mnt/new is not mounted"
    echo "Please run step 4.1 (prepare mount points) first"
    exit 1
fi

echo "=== Step 4.2a: Copy Everything Except /var ==="
echo ""
echo "Source: /mnt/btrfs (top-level where current data lives)"
echo "Destination: /mnt/new (@ subvolume with nested subvolume mounts)"
echo ""
echo "Using CoW reflinks (--reflink=always) for instant copy"
echo "This should complete in seconds..."
echo ""

cd /mnt/btrfs

# Count items to copy for progress indication
total_items=$(find . -maxdepth 1 -mindepth 1 ! -name var | wc -l)
echo "Copying $total_items top-level items (excluding var/)..."
echo ""

# Copy all top-level items except /var using reflinks
find . -maxdepth 1 -mindepth 1 ! -name var -print0 | \
  xargs -0 -I {} cp -ax --reflink=always {} /mnt/new/

echo ""
echo "✓ Step 4.2a completed successfully"
echo "  All top-level items (except /var) copied to @ subvolume"
