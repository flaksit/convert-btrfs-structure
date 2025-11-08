# Btrfs Flat Subvolume Migration Plan

## System Information
- **Current filesystem:** btrfs on `/dev/nvme0n1p5`
- **UUID:** `bae81b8a-6999-4457-827b-e30341b338ff`
- **Mount options:** `rw,relatime,ssd,discard=async,space_cache=v2`
- **Current subvolumes:** @ (ID 256), @home (ID 257)
- **Distribution:** Ubuntu
- **Bootloader:** GRUB
- **Available space:** 671GB
- **EFI partition:** `/dev/nvme0n1p1` (UUID: `72B8-FEBD`)

## Migration Overview

This plan migrates your btrfs filesystem from a simple top-level layout to a flat subvolume structure that supports snapshot-based rollback. The migration requires booting into a live Ubuntu environment and restructuring your filesystem while preserving all data.

**Timeline:** 2-4 hours depending on disk speed
**Downtime:** System will be offline during migration
**Risk level:** Medium (bootloader changes involved)

---

## Target Subvolume Structure

After migration, your filesystem will have this layout:

```
Subvolume    Mount Point          Purpose
---------    -----------          -------
@            /                    Root filesystem
@home        /home                User home directories
@var_log     /var/log             System logs
@var_cache   /var/cache           APT packages and caches
@libvirt     /var/lib/libvirt     VM images and configurations
@snapshots   /.snapshots          Snapshot storage directory
```

All subvolumes exist as siblings at the top level (subvolid=5) in a flat structure. This enables:
- Atomic snapshots for system rollback
- Snapshot-based backups with tools like Timeshift or snapper
- Better separation of concerns
- Improved mount option flexibility per subvolume

---

## Phase 1: Preparation (Before Reboot)

### 1.1 Create System Backup

Create a full system backup to an external drive before starting:

```bash
# Option A: Using btrfs send/receive (recommended, preserves metadata)
mkdir -p /mnt/backup
mount /dev/your-external-drive /mnt/backup
btrfs send -p /mnt/btrfs/ext2_saved /mnt/btrfs / | btrfs receive /mnt/backup/

# Option B: Using rsync (faster but doesn't preserve all metadata)
mkdir -p /mnt/backup
mount /dev/your-external-drive /mnt/backup
rsync -aAXHv / /mnt/backup/system-backup/ \
  --exclude={'/dev','/proc','/sys','/tmp','/run','/mnt','/media','/lost+found'}
```

**Verify backup integrity** before proceeding:
```bash
ls -lh /mnt/backup  # Check backup size matches source (~134GB)
```

### 1.2 Document Current Configuration

Save copies of critical files:

```bash
# In current system (before shutdown)
cp /etc/fstab ~/fstab.backup
cp /boot/grub/grub.cfg ~/grub.cfg.backup
mount | grep btrfs > ~/mounts.backup
btrfs subvolume list / > ~/subvolumes.backup
```

### 1.3 Prepare Live USB

Download Ubuntu live USB matching your system:
```bash
# Visit https://ubuntu.com/download/desktop
# Create bootable USB: sudo dd if=ubuntu-*.iso of=/dev/sdX bs=4M status=progress
```

**Note:** You'll boot into this live environment for the migration.

---

## Phase 2: Live Environment Setup

### 2.1 Boot into Live USB

1. Insert USB drive
2. Reboot and select USB in boot menu (usually F12, Del, or Esc during startup)
3. Select "Try Ubuntu" (don't install)
4. Open terminal

### 2.2 Mount the Filesystem

```bash
# Mount top-level subvolume to access all data
sudo mkdir -p /mnt/btrfs
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# Verify mount
ls -la /mnt/btrfs
# You should see: @, @home, ext2_saved, and other filesystem contents
```

### 2.3 Verify Current Structure

```bash
# List existing subvolumes
sudo btrfs subvolume list /mnt/btrfs

# Check disk space
sudo btrfs filesystem usage /mnt/btrfs

# Verify no existing @ subvolume
ls /mnt/btrfs/ | grep "^@"
```

---

## Phase 3: Create New Subvolumes

### 3.1 Create Subvolume Structure

```bash
# Create the new subvolumes
sudo btrfs subvolume create /mnt/btrfs/@
sudo btrfs subvolume create /mnt/btrfs/@home
sudo btrfs subvolume create /mnt/btrfs/@log
sudo btrfs subvolume create /mnt/btrfs/@cache
sudo btrfs subvolume create /mnt/btrfs/@libvirt
sudo btrfs subvolume create /mnt/btrfs/@snapshots

# Verify creation
sudo btrfs subvolume list /mnt/btrfs
# Output should show 6 new subvolumes with sequential IDs
```

---

## Phase 4: Migrate Data

### 4.1 Prepare Mount Points

```bash
# Create mount points in live environment
sudo mkdir -p /mnt/old
sudo mkdir -p /mnt/new
sudo mkdir -p /mnt/new/{home,var/log,var/cache,var/lib,,.snapshots}

# Mount old filesystem (top-level where current data lives)
# Note: Your current @ and @home are mounted to /
# We'll mount the top-level to access both
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/old

# Mount new @ as root
sudo mount -t btrfs -o subvol=@ /dev/nvme0n1p5 /mnt/new

# Mount other subvolumes
sudo mount -t btrfs -o subvol=@home /dev/nvme0n1p5 /mnt/new/home
sudo mount -t btrfs -o subvol=@log /dev/nvme0n1p5 /mnt/new/var/log
sudo mount -t btrfs -o subvol=@cache /dev/nvme0n1p5 /mnt/new/var/cache
sudo mount -t btrfs -o subvol=@libvirt /dev/nvme0n1p5 /mnt/new/var/lib/libvirt
sudo mount -t btrfs -o subvol=@snapshots /dev/nvme0n1p5 /mnt/new/.snapshots
```

### 4.2 Copy Root Filesystem

Copy root filesystem, excluding directories that go to separate subvolumes:

```bash
# Copy root contents to @, excluding what goes elsewhere
sudo rsync -aAXHv /mnt/old/ /mnt/new/ \
  --exclude='/home' \
  --exclude='/var/log' \
  --exclude='/var/cache' \
  --exclude='/var/lib/libvirt' \
  --exclude='/.snapshots' \
  --exclude='/dev' \
  --exclude='/proc' \
  --exclude='/sys' \
  --exclude='/run' \
  --exclude='/tmp' \
  --exclude='/mnt' \
  --exclude='/media' \
  --exclude='/lost+found' \
  --exclude='/boot/efi'
```

**Note:** This will take 10-30 minutes depending on your disk speed. Progress is shown with rsync output.

### 4.3 Copy /home

```bash
sudo rsync -aAXHv /mnt/old/home/ /mnt/new/home/
```

### 4.4 Copy /var/log

```bash
sudo rsync -aAXHv /mnt/old/var/log/ /mnt/new/var/log/
```

### 4.5 Copy /var/cache

```bash
sudo rsync -aAXHv /mnt/old/var/cache/ /mnt/new/var/cache/
```

### 4.6 Copy /var/lib/libvirt

```bash
sudo rsync -aAXHv /mnt/old/var/lib/libvirt/ /mnt/new/var/lib/libvirt/
```

### 4.7 Copy Boot (including EFI)

```bash
# Copy /boot
sudo rsync -aAXHv /mnt/old/boot/ /mnt/new/boot/ \
  --exclude='/boot/efi'

# Mount EFI partition
sudo mkdir -p /mnt/new/boot/efi
sudo mount /dev/nvme0n1p1 /mnt/new/boot/efi

# Copy EFI contents
sudo rsync -aAXHv /mnt/old/boot/efi/ /mnt/new/boot/efi/
```

### 4.8 Handle Swapfile

```bash
# Check if swapfile exists
ls -lh /mnt/old/swap.img

# If it exists, recreate it (btrfs swapfile requires special handling)
# First, disable nodatacow check:
sudo chattr +C /mnt/new/swap.img  # Set nodatacow

# Create swapfile
sudo dd if=/dev/zero of=/mnt/new/swap.img bs=1G count=8  # Adjust size as needed
sudo chmod 600 /mnt/new/swap.img
sudo mkswap /mnt/new/swap.img
```

---

## Phase 5: Update Configuration Files

### 5.1 Update /etc/fstab

Edit `/mnt/new/etc/fstab` and update mount entries:

```bash
sudo nano /mnt/new/etc/fstab
```

Replace the existing entries with:

```fstab
# Btrfs filesystem
UUID=bae81b8a-6999-4457-827b-e30341b338ff /               btrfs subvol=@,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /home           btrfs subvol=@home,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/log        btrfs subvol=@log,ssd,discard=async,space_cache=v2,nodatacow 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/cache      btrfs subvol=@cache,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/lib/libvirt btrfs subvol=@libvirt,ssd,discard=async,space_cache=v2,nodatacow 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /.snapshots     btrfs subvol=@snapshots,ssd,discard=async,space_cache=v2 0 0

# EFI partition
UUID=72B8-FEBD /boot/efi vfat umask=0077 0 1

# Swapfile (if created)
/swap.img none swap sw 0 0
```

**Key points:**
- Replace `UUID=...` with your actual UUIDs if they differ
- `nodatacow` for `@log` and `@libvirt` improves performance for logs/VMs
- Each subvolume specified with `subvol=@name`

### 5.2 Update GRUB Configuration

Edit GRUB config to boot from @ subvolume:

```bash
sudo nano /mnt/new/etc/default/grub
```

Find the `GRUB_CMDLINE_LINUX_DEFAULT` line and add `rootflags=subvol=@`:

```bash
# Before:
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"

# After:
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rootflags=subvol=@"
```

Also check `GRUB_CMDLINE_LINUX` and update if present:

```bash
GRUB_CMDLINE_LINUX="rootflags=subvol=@"
```

---

## Phase 6: Chroot and Finalize

### 6.1 Prepare Chroot Environment

```bash
# Bind mount essential filesystems
sudo mount --bind /dev /mnt/new/dev
sudo mount --bind /proc /mnt/new/proc
sudo mount --bind /sys /mnt/new/sys
sudo mount --bind /run /mnt/new/run
```

### 6.2 Chroot into New System

```bash
sudo chroot /mnt/new /bin/bash
```

### 6.3 Regenerate GRUB Configuration

Inside chroot:

```bash
# Update GRUB config from the new kernel/initramfs
grub-mkconfig -o /boot/grub/grub.cfg

# Verify output shows correct root device
# Should show: Found linux image: /boot/vmlinuz-...
# And: Found initrd image: /boot/initrd.img-...
```

### 6.4 Reinstall GRUB to EFI

Still inside chroot:

```bash
# Install GRUB to EFI partition
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck

# Output should end with: Installation finished. No errors reported.
```

### 6.5 Exit Chroot

```bash
exit
```

---

## Phase 7: Verify Before Reboot

### 7.1 Verify New Structure

```bash
# Check all subvolumes created
sudo btrfs subvolume list /mnt/btrfs

# Verify new @ subvolume has content
ls /mnt/new/ | head -20

# Check fstab syntax
sudo cat /mnt/new/etc/fstab

# Verify GRUB config updated
sudo grep "rootflags=subvol=@" /mnt/new/etc/default/grub
```

### 7.2 Verify Data Integrity

```bash
# Sample checks of critical directories
ls -la /mnt/new/etc/          # System configs present
ls -la /mnt/new/home/         # User home directories present
ls -la /mnt/new/var/log/      # Logs in separate subvolume
ls -la /mnt/new/var/cache/    # Cache in separate subvolume
ls -la /mnt/new/var/lib/libvirt/ # VMs in separate subvolume
```

### 7.3 Unmount Everything

```bash
# Unmount in reverse order
sudo umount /mnt/new/boot/efi
sudo umount /mnt/new/.snapshots
sudo umount /mnt/new/var/lib/libvirt
sudo umount /mnt/new/var/cache
sudo umount /mnt/new/var/log
sudo umount /mnt/new/home
sudo umount /mnt/new
sudo umount /mnt/old
sudo umount /mnt/btrfs
```

---

## Phase 8: Reboot and Testing

### 8.1 Reboot

```bash
sudo reboot
```

Remove the live USB when prompted.

### 8.2 Initial Boot Checks

After rebooting, the system should boot normally:

1. Wait for full boot (may take slightly longer due to new structure)
2. Open terminal
3. Verify mounts:
   ```bash
   mount | grep btrfs
   # Should show all 6 subvolumes mounted correctly
   ```

4. Check disk usage:
   ```bash
   df -h
   # Verify all mount points present and sized correctly
   ```

### 8.3 Test Services

```bash
# Verify key services running
systemctl status networking
systemctl status ssh  # if installed
systemctl status libvirtd  # if VMs installed

# Check logs accessible
tail -f /var/log/syslog

# Test apt cache
apt list --installed | head -5
```

### 8.4 Verify VM Functionality (if applicable)

```bash
# List VMs
virsh list --all

# Verify VM images accessible
ls -la /var/lib/libvirt/images/
```

### 8.5 Create Initial Snapshot

After verifying everything works:

```bash
sudo btrfs subvolume snapshot /@ /@snapshots/migration-backup-$(date +%Y%m%d)

# Verify snapshot created
sudo btrfs subvolume list /.snapshots
```

---

## Phase 9: Cleanup (1-2 weeks after stable operation)

After verifying stable operation for 1-2 weeks, remove old data:

```bash
# Mount top-level again
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# Remove old subvolumes (if they still exist)
sudo btrfs subvolume delete /mnt/btrfs/@  # old @
sudo btrfs subvolume delete /mnt/btrfs/@home  # old @home
sudo btrfs subvolume delete /mnt/btrfs/ext2_saved

# Remove any stray directories at top-level
sudo rm -rf /mnt/btrfs/home /mnt/btrfs/var /mnt/btrfs/etc  # if they exist as directories

# Verify cleanup
sudo btrfs subvolume list /mnt/btrfs
# Should only show: @, @home, @log, @cache, @libvirt, @snapshots
```

---

## Troubleshooting

### System Won't Boot

1. **Boot into live USB again**
2. **Mount filesystem:**
   ```bash
   sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs
   ```
3. **Check GRUB config:**
   ```bash
   sudo cat /mnt/btrfs/@/etc/default/grub | grep rootflags
   ```
4. **Verify /etc/fstab:**
   ```bash
   sudo cat /mnt/btrfs/@/etc/fstab
   ```
5. **Check GRUB installation:**
   ```bash
   sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi \
     --boot-directory=/mnt/btrfs/@/boot --root-directory=/mnt/btrfs/@ \
     --bootloader-id=ubuntu --recheck
   ```

### Missing Subvolumes

If a subvolume wasn't created, create it and copy data:

```bash
# Create missing subvolume
sudo btrfs subvolume create /mnt/btrfs/@missing

# Mount and restore data
sudo mount -t btrfs -o subvol=@missing /dev/nvme0n1p5 /mnt/restore
sudo rsync -aAXHv /path/to/backup/data/ /mnt/restore/
```

### Disk Space Issues

If you run out of space during copy:

1. Check what's using space: `sudo btrfs filesystem usage /mnt/btrfs`
2. Delete less critical old subvolumes
3. Free up external backup drive space
4. Retry copy operations

### GRUB Bootloader Issues

If GRUB doesn't recognize new layout:

1. Boot into live USB
2. Chroot into system again (see section 6.1-6.2)
3. Reinstall GRUB (see section 6.4)
4. Regenerate config (see section 6.3)

---

## Rollback Procedure (If Critical Issues)

If something goes seriously wrong:

1. **Boot into live USB**
2. **Mount old filesystem:**
   ```bash
   sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs
   ```
3. **Restore from backup** (if created):
   ```bash
   # Using btrfs send/receive
   btrfs send /mnt/backup/your-backup-snapshot | \
     btrfs receive /mnt/btrfs/
   ```
4. **Rename old @ back:**
   ```bash
   sudo mv /mnt/btrfs/@ /mnt/btrfs/@-failed
   sudo btrfs subvolume delete /mnt/btrfs/@-failed
   ```
5. **Or restore from external backup** using rsync if btrfs backup unavailable

---

## Post-Migration: Snapshot Management

After successful migration, consider setting up automated snapshots:

### Option 1: Manual Snapshots (Current Plan)

```bash
# Create snapshot
sudo btrfs subvolume snapshot -r /@ /@snapshots/manual-$(date +%Y%m%d-%H%M%S)

# List snapshots
sudo btrfs subvolume list /@snapshots

# Delete old snapshot
sudo btrfs subvolume delete /@snapshots/manual-20240101-000000
```

### Option 2: Using snapper (Recommended)

```bash
# Install snapper
sudo apt install snapper

# Configure for @ subvolume
sudo snapper -c root create-config /

# Edit configuration if needed
sudo nano /etc/snapper/configs/root

# Create snapshots manually or set up cron job
sudo snapper -c root create --description "Weekly backup"
```

### Option 3: Using Timeshift

```bash
# Install Timeshift
sudo apt install timeshift

# Launch GUI or configure via:
timeshift --help
```

Note: Timeshift traditionally only monitors @ and @home. Verify its capabilities with your snapper setup.

---

## Summary Checklist

- [ ] Created system backup (external drive)
- [ ] Documented current configuration
- [ ] Downloaded and created live USB
- [ ] Booted into live environment
- [ ] Mounted filesystem and verified structure
- [ ] Created new subvolumes
- [ ] Copied all data to new subvolumes
- [ ] Updated /etc/fstab
- [ ] Updated GRUB configuration
- [ ] Chrooted and regenerated GRUB
- [ ] Verified all changes before reboot
- [ ] Successfully booted into new layout
- [ ] Verified all mounts and services
- [ ] Created initial snapshot
- [ ] Tested VM functionality
- [ ] Monitored for 1-2 weeks
- [ ] Cleaned up old data

---

## Important Notes

1. **Keep the live USB handy** for at least 1 week after migration in case you need to troubleshoot
2. **Verify backup integrity** regularly before starting migration
3. **Don't rush the copy phase** - rsync shows progress; let it complete
4. **Test recovery** after migration to ensure snapshots work as expected
5. **Keep documentation** of this migration for future reference

Good luck with your migration!
