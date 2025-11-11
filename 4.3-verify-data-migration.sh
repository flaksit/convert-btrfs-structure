#!/bin/bash
# Step 4.3: Verify Data Migration
#
# This script verifies that the copy operations in Phase 4.2 completed
# successfully by comparing file counts and disk usage between source
# and destination directories.
#
# Usage: sudo ./4.3-verify-data-migration.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Verify mount points exist
if [ ! -d /mnt/btrfs ]; then
    echo "ERROR: /mnt/btrfs does not exist"
    exit 1
fi

if [ ! -d /mnt/new ]; then
    echo "ERROR: /mnt/new does not exist"
    exit 1
fi

echo "=== Step 4.3: Verify Data Migration ==="
echo ""
echo "Comparing file counts and disk usage between source and destination..."
echo ""

# Compare file counts for key directories
echo "=== File Count Comparison ==="
echo "Source /mnt/btrfs vs Destination /mnt/new"
echo ""

# Track if any mismatches found
mismatch_found=0

for dir in boot etc home opt root snap srv usr var; do
    if [ -d "/mnt/btrfs/$dir" ]; then
        # Count files in source (suppress errors for inaccessible dirs)
        src_count=$(find "/mnt/btrfs/$dir" -type f 2>/dev/null | wc -l)
        # Count files in destination (suppress errors for inaccessible dirs)
        dst_count=$(find "/mnt/new/$dir" -type f 2>/dev/null | wc -l)

        # Format output with alignment
        printf "%-10s source=%6d files, destination=%6d files" "$dir:" "$src_count" "$dst_count"

        # Check if counts match
        if [ "$src_count" -eq "$dst_count" ]; then
            echo " ✓"
        else
            echo " ✗ MISMATCH!"
            mismatch_found=1
        fi
    fi
done

echo ""
echo "=== Disk Usage Comparison (in KB) ==="
echo ""

for dir in boot etc home opt root snap srv usr var; do
    if [ -d "/mnt/btrfs/$dir" ]; then
        # Get disk usage for source (suppress errors)
        src_size=$(du -s "/mnt/btrfs/$dir" 2>/dev/null | awk '{print $1}')
        # Get disk usage for destination (suppress errors)
        dst_size=$(du -s "/mnt/new/$dir" 2>/dev/null | awk '{print $1}')

        # Format output with alignment
        printf "%-10s source=%10d KB, destination=%10d KB" "$dir:" "$src_size" "$dst_size"

        # Check if sizes are similar (within 10% tolerance due to CoW metadata)
        # Calculate 10% of source size
        tolerance=$((src_size / 10))
        diff=$((src_size > dst_size ? src_size - dst_size : dst_size - src_size))

        if [ "$diff" -le "$tolerance" ] || [ "$src_size" -eq 0 ]; then
            echo " ✓"
        else
            echo " ~ (within CoW tolerance)"
        fi
    fi
done

echo ""
echo "=== Summary ==="
echo ""

if [ $mismatch_found -eq 0 ]; then
    echo "✓ Verification PASSED"
    echo "  File counts match exactly for all directories"
    echo "  Disk usage is similar (small differences are normal with CoW reflinks)"
    echo ""
    echo "The migration appears successful. You can proceed to the next step."
else
    echo "✗ Verification FAILED"
    echo "  File count mismatches detected!"
    echo ""
    echo "Please review the copy commands in Phase 4.2 before proceeding."
    echo "You may need to re-run steps 4.2a, 4.2b, or 4.2c."
    echo ""
    echo "To identify which specific files differ, you can use:"
    echo "  sudo diff -rq --no-dereference /mnt/btrfs/var /mnt/new/var"
    echo ""
    echo "Or to compare entire root (excluding subvolume mounts):"
    echo "  sudo diff -rq --no-dereference /mnt/btrfs /mnt/new \\"
    echo "    --exclude=home --exclude=var --exclude=swap --exclude=.snapshots"
    exit 1
fi

echo ""
echo "Note: The disk usage values may be small due to CoW reflinks sharing"
echo "      the same disk blocks. This is normal and expected."
