#!/bin/bash
# Phase 1.2: Document Current Configuration
# This script saves all current system configuration and state to backup files
# Run this BEFORE starting the migration (while system is running normally)

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Phase 1.2: Documenting Current Configuration ===${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Determine the backup directory
BACKUP_DIR="$HOME/btrfs-conversion-current-config-backup"
if [ -n "$SUDO_USER" ]; then
    BACKUP_DIR="/home/$SUDO_USER/btrfs-conversion-current-config-backup"
fi

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

echo "Saving documentation files to: $BACKUP_DIR"
echo ""

# 1.2.1: Save configuration files
echo -e "${YELLOW}Step 1: Saving configuration files...${NC}"
cp /etc/fstab "$BACKUP_DIR/fstab.backup"
cp /boot/grub/grub.cfg "$BACKUP_DIR/grub.cfg.backup"
cp /etc/default/grub "$BACKUP_DIR/grub.default.backup"
echo "✓ Configuration files saved"
echo ""

# 1.2.2: Document current state
echo -e "${YELLOW}Step 2: Documenting current system state...${NC}"
mount | grep btrfs > "$BACKUP_DIR/mounts.backup"
btrfs subvolume list / > "$BACKUP_DIR/subvolumes.backup" 2>/dev/null || echo "No subvolumes found" > "$BACKUP_DIR/subvolumes.backup"
df -h > "$BACKUP_DIR/disk-usage.backup"
echo "✓ System state documented"
echo ""

# 1.2.3: List what you're about to migrate
echo -e "${YELLOW}Step 3: Recording directory sizes...${NC}"
du -sh /home/* > "$BACKUP_DIR/home-sizes.backup" 2>/dev/null || echo "No home directories" > "$BACKUP_DIR/home-sizes.backup"
du -sh /var/log > "$BACKUP_DIR/log-size.backup"
du -sh /var/cache > "$BACKUP_DIR/cache-size.backup"
du -sh /var/lib/libvirt/images 2>/dev/null > "$BACKUP_DIR/libvirt-images-size.backup" || echo "No libvirt images" > "$BACKUP_DIR/libvirt-images-size.backup"
echo "✓ Directory sizes recorded"
echo ""

# 1.2.4: Verify EFI Mount Point (was Phase 1.3)
echo -e "${YELLOW}Step 4: Documenting EFI configuration...${NC}"
{
    echo "=== EFI Mount Point Information ==="
    echo ""
    echo "All EFI mounts:"
    EFI_MOUNT=$(mount | grep -i efi)
    if [ -n "$EFI_MOUNT" ]; then
        echo "$EFI_MOUNT"
        echo ""

        # Extract the mount point from the grep output, excluding efivarfs
        EFI_MOUNTPOINT=$(echo "$EFI_MOUNT" | grep -v efivarfs | awk '{print $3}' | head -1)
        if [ -n "$EFI_MOUNTPOINT" ]; then
            echo "Detected EFI mount point: $EFI_MOUNTPOINT"
            echo ""
            echo "Details for $EFI_MOUNTPOINT:"
            findmnt "$EFI_MOUNTPOINT" 2>/dev/null || echo "findmnt failed for $EFI_MOUNTPOINT"
            echo ""
            echo "EFI partition device:"
            # Get the device from findmnt and use it with blkid
            EFI_DEVICE=$(findmnt -n -o SOURCE "$EFI_MOUNTPOINT" 2>/dev/null)
            if [ -n "$EFI_DEVICE" ]; then
                blkid "$EFI_DEVICE" || echo "blkid failed for $EFI_DEVICE"
            else
                echo "Could not determine device for $EFI_MOUNTPOINT"
            fi
        else
            echo "WARNING: No EFI partition mount point found (only efivarfs detected)"
        fi
    else
        echo "No EFI mounts found"
        echo ""
        echo "WARNING: No EFI partition mounted!"
    fi
} > "$BACKUP_DIR/efi-config.backup"
cat "$BACKUP_DIR/efi-config.backup"
echo "✓ EFI configuration documented"
echo ""

# 1.2.5: Check Current Swapfile (was Phase 1.4)
echo -e "${YELLOW}Step 5: Documenting swapfile configuration...${NC}"
{
    echo "=== Swapfile Information ==="
    echo ""
    echo "Current swapfile:"
    ls -lh /swap.img 2>/dev/null || echo "No /swap.img found"
    echo ""
    echo "All swap devices:"
    swapon --show
    echo ""
    echo "Swap entry in fstab:"
    grep -i swap /etc/fstab || echo "No swap entry in fstab"
} > "$BACKUP_DIR/swapfile-config.backup"
cat "$BACKUP_DIR/swapfile-config.backup"
echo "✓ Swapfile configuration documented"
echo ""

# Show summary of created files
echo -e "${GREEN}=== Documentation Complete ===${NC}"
echo ""
echo "The following backup files have been created in $BACKUP_DIR:"
ls -lh "$BACKUP_DIR"/*.backup
echo ""

# Check if NFS backup mount exists and offer to copy files
echo -e "${YELLOW}Checking for system backup location...${NC}"
if mount | grep -q "/mnt/backup"; then
    echo -e "${GREEN}Found /mnt/backup mounted${NC}"
    echo ""
    read -p "Copy documentation files to /mnt/backup/system-backup-*/ ? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Find the most recent backup directory
        BACKUP_TARGET=$(ls -td /mnt/backup/system-backup-*/ 2>/dev/null | head -1)
        if [ -n "$BACKUP_TARGET" ]; then
            echo "Copying to: $BACKUP_TARGET"
            cp "$BACKUP_DIR"/*.backup "$BACKUP_TARGET/"
            echo -e "${GREEN}✓ Documentation files copied to backup location${NC}"
        else
            echo -e "${YELLOW}WARNING: No system-backup-* directory found in /mnt/backup${NC}"
            echo "You can manually copy the files later after creating the system backup in Phase 1.1"
        fi
    fi
else
    echo -e "${YELLOW}INFO: /mnt/backup not mounted${NC}"
    echo "Run Phase 1.1 first to create the system backup, then run this script again,"
    echo "or manually copy the *.backup files from $BACKUP_DIR to your backup location."
fi

echo ""
echo -e "${GREEN}=== Phase 1.2 Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. If you haven't already, run Phase 1.1 to create a full system backup"
echo "  2. Review the documentation files in $BACKUP_DIR"
echo "  3. Ensure *.backup files are copied to /mnt/backup/system-backup-*/"
echo "  4. Prepare a live USB (Phase 1.3)"
echo ""
