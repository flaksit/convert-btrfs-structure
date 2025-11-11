# Btrfs Flat Subvolume Migration Plan

## System Information
- **Current filesystem:** btrfs on `/dev/nvme0n1p5`
- **UUID:** `bae81b8a-6999-4457-827b-e30341b338ff`
- **Mount options:** `rw,relatime,ssd,discard=async,space_cache=v2`
- **Current boot method:** Booting from top-level (subvolid=5), NOT from @ subvolume
- **Existing subvolumes:** None (@, @home, etc. do not exist yet)
- **Distribution:** Ubuntu
- **Bootloader:** GRUB
- **Available space:** 671GB
- **EFI partition:** `/dev/nvme0n1p1` (UUID: `72B8-FEBD`)

## Migration Overview

Your system currently boots from the btrfs top-level subvolume (subvolid=5). Although @ and @home subvolumes exist, they are not being used - all your data lives at the top level. This migration will:

1. Delete or rename the existing unused @ and @home subvolumes
2. Create fresh subvolumes: @, @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots
3. Copy all data from top-level into appropriate subvolumes
4. Reconfigure bootloader to boot from @ subvolume
5. Enable snapshot-based rollback capability

**Timeline:** 2-4 hours depending on disk speed
**Downtime:** System will be offline during migration
**Risk level:** Medium (bootloader changes involved)

**Important:** Before starting the migration, it's recommended to have this repository checked out somewhere on your system (e.g., `/home/user/convert-btrfs-structure`). This way, when you boot into the Live USB environment and mount your filesystem at `/mnt/btrfs`, the migration scripts will be available at `/mnt/btrfs/home/user/convert-btrfs-structure/`, making it much easier to execute the migration steps without typing long commands manually.

---

## Target Subvolume Structure

After migration, your filesystem will have this layout:

```plain
Subvolume         Mount Point              Purpose
----------        -----------              -------
@                 /                        Root filesystem
@home             /home                    User home directories
@var_log          /var/log                 System logs
@var_cache        /var/cache               APT packages and caches
@libvirt_images   /var/lib/libvirt/images  VM disk images
@swap             /swap                    Swapfile storage (excluded from snapshots)
@snapshots        /.snapshots              Snapshot storage directory
```

All subvolumes exist as siblings at the top level (subvolid=5) in a flat structure. This enables:
- Atomic snapshots for system rollback
- Snapshot-based backups with tools like Timeshift or snapper
- Better separation of concerns
- Improved mount option flexibility per subvolume

**NOCOW Configuration:**
The `@var_log`, `@libvirt_images`, and `@swap` subvolumes have the NOCOW (no copy-on-write) property set directly on the subvolume. This means all files created in these subvolumes automatically inherit the NOCOW attribute, improving performance for logs, VM images, and swap regardless of mount options.

---

## Phase 1: Preparation (Before Reboot)

### 1.1 Create System Backup

Create a full system backup to Synology NAS before starting.

**Prerequisites - NFS Configuration on Synology:**
Before mounting, ensure your Synology NFS share is configured correctly:
1. Go to: Control Panel → Shared Folder → Select backup folder → Edit → NFS Permissions
2. Edit your NFS rule and verify:
   - **Squash:** Must be set to **"No mapping"**
   - **Security:** "sys" is fine
   - **Privilege:** "Read/Write"
3. This ensures file ownership and permissions are preserved correctly

**Mount NFS share and create backup:**

```bash
# Mount Synology NAS via NFS
sudo mkdir -p /mnt/backup
sudo mount -t nfs <nas-ip>:/volume1/your/backup/folder /mnt/backup

# Verify NFS mount succeeded
df -h | grep backup
mount | grep nfs

# Test that ownership preservation works
sudo touch /mnt/backup/test-root-file
sudo chown root:root /mnt/backup/test-root-file
sudo chmod 600 /mnt/backup/test-root-file
ls -la /mnt/backup/test-root-file
# Should show: -rw------- 1 root root ...
# If it shows a different user (like admin), your NFS squash setting is wrong!
sudo rm /mnt/backup/test-root-file

# Create full system backup using rsync
sudo rsync -aAXHv --info=progress2 --sparse --partial --append-verify / /mnt/backup/system-backup-$(date +%Y%m%d)/ \
  --exclude={'/dev/*','/proc/*','/sys/*','/tmp/*','/run/*','/mnt/*','/media/*','/lost+found','/swap.img'}
```

**Note:** This will take 30-60 minutes for ~134GB depending on network speed. Progress is shown by rsync.

**Verify backup integrity** before proceeding:
```bash
du -sh /mnt/backup/system-backup-*  # Should show ~134GB
ls -la /mnt/backup/system-backup-*/home  # Verify your user data is there
ls -la /mnt/backup/system-backup-*/etc  # Verify system configs present

# Verify critical file permissions were preserved
ls -la /mnt/backup/system-backup-*/etc/shadow
# Should show: -rw-r----- root shadow (NOT admin:users)

ls -la /mnt/backup/system-backup-*/etc/fstab
# Should show: -rw-r--r-- root root (NOT admin:users)
```

### 1.2 Document Current Configuration

Save copies of critical files and document your current system state. This includes configuration files, mount points, disk usage, EFI setup, and swapfile configuration.

**Script available:** You can run the automated documentation script:
```bash
sudo ./1.2-document-current-config.sh
```

This script will:
1. Save configuration files (fstab, GRUB configs)
2. Document current system state (mounts, subvolumes, disk usage)
3. Record directory sizes for migration planning
4. Document EFI mount point configuration
5. Document swapfile configuration
6. Optionally copy all documentation to your NAS backup

**Manual commands:** If you prefer to run commands manually:

#### 1.2.1 Save Configuration Files

```bash
# Create backup directory
mkdir -p ~/btrfs-conversion-current-config-backup

# Save configuration files
sudo cp /etc/fstab ~/btrfs-conversion-current-config-backup/fstab.backup
sudo cp /boot/grub/grub.cfg ~/btrfs-conversion-current-config-backup/grub.cfg.backup
sudo cp /etc/default/grub ~/btrfs-conversion-current-config-backup/grub.default.backup
```

#### 1.2.2 Document Current State

```bash
# Document current state
mount | grep btrfs > ~/btrfs-conversion-current-config-backup/mounts.backup
sudo btrfs subvolume list / > ~/btrfs-conversion-current-config-backup/subvolumes.backup
df -h > ~/btrfs-conversion-current-config-backup/disk-usage.backup
```

#### 1.2.3 List What You're About to Migrate

```bash
# List what you're about to migrate
sudo du -sh /home/* > ~/btrfs-conversion-current-config-backup/home-sizes.backup
sudo du -sh /var/log > ~/btrfs-conversion-current-config-backup/log-size.backup
sudo du -sh /var/cache > ~/btrfs-conversion-current-config-backup/cache-size.backup
sudo du -sh /var/lib/libvirt/images 2>/dev/null > ~/btrfs-conversion-current-config-backup/libvirt-images-size.backup || echo "No libvirt images" > ~/btrfs-conversion-current-config-backup/libvirt-images-size.backup
```

#### 1.2.4 Verify and Document EFI Mount Point

```bash
# Document EFI configuration
{
    echo "=== EFI Mount Point Information ==="
    echo ""
    echo "All EFI mounts:"
    EFI_MOUNT=$(mount | grep -i efi)
    echo "$EFI_MOUNT"
    echo ""

    # Extract the mount point from the grep output
    EFI_MOUNTPOINT=$(echo "$EFI_MOUNT" | awk '{print $3}' | head -1)
    if [ -n "$EFI_MOUNTPOINT" ]; then
        echo "Detected EFI mount point: $EFI_MOUNTPOINT"
        echo ""
        echo "Details for $EFI_MOUNTPOINT:"
        findmnt "$EFI_MOUNTPOINT"
    else
        echo "WARNING: No EFI partition mounted!"
    fi
} > ~/btrfs-conversion-current-config-backup/efi-config.backup

# Display the configuration
cat ~/btrfs-conversion-current-config-backup/efi-config.backup
```

**Expected:** The EFI partition should be mounted at `/boot/efi` from `/dev/nvme0n1p1` (standard for Ubuntu). If yours differs, you'll need to adjust the commands in Phase 4.5 and Phase 6.4 accordingly.

#### 1.2.5 Check and Document Current Swapfile

```bash
# Document swapfile configuration
{
    echo "=== Swapfile Information ==="
    echo ""
    echo "Current swapfile:"
    ls -lh /swap.img
    echo ""
    echo "All swap devices:"
    swapon --show
} > ~/btrfs-conversion-current-config-backup/swapfile-config.backup

# Display the configuration
cat ~/btrfs-conversion-current-config-backup/swapfile-config.backup
```

**Note:** Note the swapfile size from the output. You'll need it when recreating the swapfile in Phase 4.4.

#### 1.2.6 Copy All Documentation to Backup

After completing all documentation steps above, copy the entire directory to your NAS backup:

```bash
# Keep these files safe - copy entire directory to NAS backup
cp -a ~/btrfs-conversion-current-config-backup /mnt/backup/system-backup-$(date +%Y%m%d)/

# Verify files were copied
ls -la /mnt/backup/system-backup-$(date +%Y%m%d)/btrfs-conversion-current-config-backup/
```

### 1.3 Prepare Live USB

Download Ubuntu live USB matching your system version:

```bash
# Check your Ubuntu version
lsb_release -a

# Visit https://ubuntu.com/download/desktop
# Download matching version if possible, or latest LTS

# Create bootable USB (replace sdX with your USB device):
# sudo dd if=ubuntu-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Note:** You'll boot into this live environment for the migration.

---

## Phase 2: Live Environment Setup

### 2.1 Boot into Live USB

1. Insert USB drive
2. Reboot and select USB in boot menu (usually F12, F2, Del, or Esc during startup)
3. Select "Try Ubuntu" (don't install)
4. Open terminal (Ctrl+Alt+T)

### 2.2 Mount the Filesystem

```bash
# Mount top-level subvolume (subvolid=5) where all your current data lives
sudo mkdir -p /mnt/btrfs
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# Verify mount
ls -la /mnt/btrfs
# You should see: @, @home (unused subvolumes), plus all your actual files:
# bin, boot, etc, home, lib, opt, root, srv, usr, var, swap.img, etc.
```

### 2.3 Verify Current Structure

```bash
# List existing subvolumes
sudo btrfs subvolume list /mnt/btrfs
# Output should show no subvolumes (just verifying top-level access)

# Check disk space
sudo btrfs filesystem usage /mnt/btrfs
# Verify you have enough free space (~150GB needed temporarily)

# Verify current data is at top-level (not in @ subvolume)
ls -la /mnt/btrfs/etc/fstab  # Should exist
ls -la /mnt/btrfs/@/etc/fstab  # Should NOT exist (@ is empty)
```

---

## Phase 2.4: Create Safety Net Snapshot

Before making any destructive changes, create a snapshot of the current top-level state for fast rollback:

```bash
# Create read-only snapshot of entire top-level as safety net
sudo btrfs subvolume snapshot -r /mnt/btrfs /mnt/btrfs/backup-pre-migration

# Verify snapshot was created
sudo btrfs subvolume list /mnt/btrfs
# Should show: backup-pre-migration

# Check snapshot size (should be near-instant, metadata only)
sudo btrfs subvolume show /mnt/btrfs/backup-pre-migration
```

**Purpose:** This snapshot provides a fast rollback option on the disk itself. While you have an external NAS backup, restoring 150GB+ over network is slow. This snapshot allows near-instant recovery if migration commands fail.

**To rollback using this snapshot:** If something goes wrong during migration, you can delete failed subvolumes and the snapshot remains intact as a reference of your original state.

---

## Phase 3: Create New Subvolume Structure

No existing @ or @home subvolumes exist on your system, so you can proceed directly to creating the new subvolume layout:

```bash
# Create the new subvolumes
sudo btrfs subvolume create /mnt/btrfs/@
sudo btrfs subvolume create /mnt/btrfs/@home
sudo btrfs subvolume create /mnt/btrfs/@var_log
sudo btrfs subvolume create /mnt/btrfs/@var_cache
sudo btrfs subvolume create /mnt/btrfs/@libvirt_images
sudo btrfs subvolume create /mnt/btrfs/@swap
sudo btrfs subvolume create /mnt/btrfs/@snapshots

# Set NOCOW attribute on subvolumes that benefit from it
# Files created in these subvolumes will automatically inherit NOCOW
sudo chattr +C /mnt/btrfs/@var_log
sudo chattr +C /mnt/btrfs/@libvirt_images
sudo chattr +C /mnt/btrfs/@swap

# Verify creation
sudo btrfs subvolume list /mnt/btrfs
# Output should show 7 new subvolumes

# Verify NOCOW properties
lsattr -d /mnt/btrfs/@var_log /mnt/btrfs/@libvirt_images /mnt/btrfs/@swap
# Should show: ---------------C--- for each
```

---

## Phase 4: Migrate Data

This phase uses `cp -ax --reflink=always` for most file copies instead of `rsync`. See [why-cp-instead-of-rsync.md](why-cp-instead-of-rsync.md) for detailed reasoning.

**Flags explained:**
- `-a` (archive): Preserves permissions, ownership, timestamps, and attributes
- `-x` (one-file-system): Prevents crossing filesystem boundaries at the SOURCE, which stops cp from recursively copying mounted source directories
- `--reflink=always`: Forces copy-on-write (CoW) reflinks, making copies instant (metadata-only). If reflinks aren't possible, the command fails rather than silently doing a slow full copy.

**Important note on `cp -x` and destination mount points:**
The `-x` flag prevents cp from crossing mount boundaries in the SOURCE filesystem only. It does NOT prevent cp from writing across mount point boundaries in the DESTINATION. This is intentional in our setup:
- In step 4.1, we mount all subvolumes: @ at `/mnt/new`, @home at `/mnt/new/home`, @var/log at `/mnt/new/var/log`, etc.
- In step 4.2, the single `cp -ax` command writes across these destination mount boundaries, populating all subvolumes in one operation
- **Result:** A single copy operation efficiently populates @, @home, @var_cache, @libvirt_images, and @swap simultaneously

**Special handling for /var/log:**
The /var/log directory may contain a mix of files with different CoW attributes (most are CoW, some may be NOCOW from earlier configurations). When copying such mixed-attribute directories with `--reflink=always`, reflink attempts may fail on NOCOW source files. Therefore:
- Steps 4.2a and 4.2b copy everything except /var/log with `--reflink=always` (guarantees reflinks or fails completely)
- Step 4.2c copies /var/log separately with `--reflink=auto` (reflinks when possible, falls back to physical copy for problem files)
- This prevents hundreds of error messages while maintaining reflink safety for the bulk of the data

**Flags rationale:**
- Use `--reflink=always` for most data to detect if reflinks aren't working (fails loudly rather than silently doing slow copies)
- Use `--reflink=auto` only for /var/log to handle mixed CoW/NOCOW source files gracefully
- Combined approach ensures both safety and clean execution

### 4.1 Prepare Mount Points

**Script available:** If you have this repository checked out, you can run:
```bash
cd /mnt/btrfs/home/user/convert-btrfs-structure  # Adjust path as needed
sudo ./4.1-prepare-mount-points.sh /dev/nvme0n1p5
```

**Manual commands:**
```bash
# Create mount point for new subvolumes
sudo mkdir -p /mnt/new

# /mnt/btrfs is already mounted to top-level (from Phase 2.2)

# Mount new subvolumes
sudo mount -t btrfs -o subvol=@ /dev/nvme0n1p5 /mnt/new
sudo mkdir -p /mnt/new/{home,var/log,var/cache,var/lib/libvirt/images,swap,.snapshots}
sudo mount -t btrfs -o subvol=@home /dev/nvme0n1p5 /mnt/new/home
sudo mount -t btrfs -o subvol=@var_log /dev/nvme0n1p5 /mnt/new/var/log
sudo mount -t btrfs -o subvol=@var_cache /dev/nvme0n1p5 /mnt/new/var/cache
sudo mount -t btrfs -o subvol=@libvirt_images /dev/nvme0n1p5 /mnt/new/var/lib/libvirt/images
sudo mount -t btrfs -o subvol=@swap /dev/nvme0n1p5 /mnt/new/swap
sudo mount -t btrfs -o subvol=@snapshots /dev/nvme0n1p5 /mnt/new/.snapshots

# Verify all mounts
mount | grep nvme0n1p5
```

### 4.2 Copy Root Filesystem

Copy root filesystem from top-level to @ and other subvolumes, using multiple `cp` commands to handle /var/log separately.

#### Step 4.2a: Copy everything except /var

**Script available:** If you have this repository checked out, you can run:
```bash
cd /mnt/btrfs/home/user/convert-btrfs-structure  # Adjust path as needed
sudo ./4.2a-copy-except-var.sh
```

**Manual commands:**
```bash
# Copy all top-level items except /var using reflinks (instant)
# Source: /mnt/btrfs (top-level where current data lives)
# Destination: /mnt/new (mounted as @, with subvolumes mounted as subdirectories)

cd /mnt/btrfs
find . -maxdepth 1 -mindepth 1 ! -name var -print0 | \
  sudo xargs -0 -I {} cp -ax --reflink=always {} /mnt/new/
```

#### Step 4.2b: Copy /var except /var/log

**Script available:** If you have this repository checked out, you can run:
```bash
cd /mnt/btrfs/home/user/convert-btrfs-structure  # Adjust path as needed
sudo ./4.2b-copy-var-except-log.sh
```

**Manual commands:**
```bash
# Create /var in destination (if not already present)
sudo mkdir -p /mnt/new/var

# Copy all subdirectories of /var except /var/log
cd /mnt/btrfs/var
find . -maxdepth 1 -mindepth 1 ! -name log -print0 | \
  sudo xargs -0 -I {} cp -ax --reflink=always {} /mnt/new/var/
```

#### Step 4.2c: Copy /var/log separately (with --reflink=auto)

**Script available:** If you have this repository checked out, you can run:
```bash
cd /mnt/btrfs/home/user/convert-btrfs-structure  # Adjust path as needed
sudo ./4.2c-copy-var-log.sh
```
*Note: This script also performs the cleanup from step 4.2d.*

**Manual commands:**
```bash
# Copy /var/log with --reflink=auto to handle mixed CoW/NOCOW source files
# (most files are CoW, but some may be NOCOW from earlier configurations)
sudo cp -ax --reflink=auto /mnt/btrfs/var/log/. /mnt/new/var/log/
```

#### Step 4.2d: Cleanup

```bash
# Remove old/unused subvolume directories created in the original top-level
sudo rm -rf /mnt/new/@*  # Remove old subvolume directories (@, @home, @home-old-unused, etc.)

# Remove old swapfile (new one will be created in @swap subvolume in step 4.4)
sudo rm -f /mnt/new/swap.img

# Note: dev, proc, sys, run, tmp, mnt, media directories are preserved as copied
# They will be populated/mounted normally at boot time
# This preserves the exact filesystem structure for true migration
```

#### Explanation
- Steps 4.2a and 4.2b copy with `--reflink=always` to guarantee reflinks (no silent full copies)
- Step 4.2c copies /var/log with `--reflink=auto` because it may contain mixed CoW/NOCOW source files (see Phase 4 overview)
- cp -ax crosses destination mount boundaries, so this operation populates @, @home, @var_cache, @libvirt_images, and @swap simultaneously
- All copies complete in seconds due to CoW reflinks

### 4.3 Verify Data Migration

Before proceeding, verify that the copy operations completed successfully by comparing file counts and disk usage between source and destination.

**Script available:** If you have this repository checked out, you can run:
```bash
cd /mnt/btrfs/home/user/convert-btrfs-structure  # Adjust path as needed
sudo ./4.3-verify-data-migration.sh
```

**Manual commands:**

**Note:** Run this verification as root (or with sudo) to ensure access to all directories.

```bash
# Compare file counts for key directories
echo "=== File Count Comparison ==="
echo "Source /mnt/btrfs vs Destination /mnt/new"
echo ""

for dir in boot etc home opt root snap srv usr var; do
    if [ -d "/mnt/btrfs/$dir" ]; then
        src_count=$(find "/mnt/btrfs/$dir" -type f 2>/dev/null | wc -l)
        dst_count=$(find "/mnt/new/$dir" -type f 2>/dev/null | wc -l)
        echo "$dir: source=$src_count files, destination=$dst_count files"
    fi
done

echo ""
echo "=== Disk Usage Comparison (in KB) ==="
echo ""

for dir in boot etc home opt root snap srv usr var; do
    if [ -d "/mnt/btrfs/$dir" ]; then
        src_size=$(du -s "/mnt/btrfs/$dir" 2>/dev/null | awk '{print $1}')
        dst_size=$(du -s "/mnt/new/$dir" 2>/dev/null | awk '{print $1}')
        echo "$dir: source=$src_size KB, destination=$dst_size KB"
    fi
done
```

**Expected results:**
- File counts should match exactly for each directory
- Disk usage should be very similar (may differ slightly due to CoW metadata)
- If counts don't match, review the copy commands in Phase 4.2 before proceeding

**If differences are found:**
You can identify which specific files differ using `diff`:
```bash
# Compare a specific directory to find differing files
sudo diff -rq --no-dereference /mnt/btrfs/var /mnt/new/var
```

**Note:** The disk usage values shown by `du -s` may be small (often showing 0 or very small numbers) because CoW reflinks share the same disk blocks. This is normal and expected. The file counts are the primary verification metric.

### 4.4 Create Swapfile in @swap Subvolume

The old swapfile (`/swap.img` at top-level) was deleted in step 4.2d. Create a new swapfile in the @swap subvolume.

Check what size swapfile you had (from Phase 1.2.5 documentation).
Typical sizes: 8G, 16G, or equal to RAM size

**Option 1: Modern btrfs-native method (recommended):**

```bash
# Use btrfs filesystem mkswapfile (requires btrfs-progs 5.17+)
# This automatically sets NOCOW and creates the swapfile correctly
sudo btrfs filesystem mkswapfile --size 8G /mnt/new/swap/swap.img

# Verify NOCOW attribute was set
lsattr /mnt/new/swap/swap.img
# Should show: ---------------C---
```

**Option 2: Traditional method (works on all systems):**

```bash
# Create swapfile in @swap subvolume (separate from @ to exclude from snapshots)
# NOCOW is automatically inherited from the @swap subvolume property
sudo touch /mnt/new/swap/swap.img
sudo dd if=/dev/zero of=/mnt/new/swap/swap.img bs=1G count=8 status=progress  # Adjust count=8 to your size
sudo chmod 600 /mnt/new/swap/swap.img
sudo mkswap /mnt/new/swap/swap.img

# Verify NOCOW attribute was inherited
lsattr /mnt/new/swap/swap.img
# Should show: ---------------C---
```

**Note:** Both methods produce the same result. The btrfs-native method is simpler and ensures proper attributes, while the traditional method works on older systems.

### 4.5 Mount EFI Partition

Check your EFI partition and mount point (from Phase 1.2.4 documentation). This guide assumes `/dev/nvme0n1p1` is mounted as `/boot/efi`.

```bash
# Mount EFI partition into new @ subvolume
sudo mount /dev/nvme0n1p1 /mnt/new/boot/efi

# EFI partition should already have correct GRUB files
# Verify it's mounted
mount | grep efi
ls -la /mnt/new/boot/efi/EFI
```

---

## Phase 5: Update Configuration Files

### 5.1 Update /etc/fstab

First, verify your actual filesystem UUIDs:

```bash
# Get your btrfs filesystem UUID
sudo blkid /dev/nvme0n1p5
# Note the UUID value (should be bae81b8a-6999-4457-827b-e30341b338ff for this system)

# Get your EFI partition UUID
sudo blkid /dev/nvme0n1p1
# Note the UUID value (should be 72B8-FEBD for this system)
```

**IMPORTANT:** The UUIDs in the example below are specific to this system. Verify your actual UUIDs match before proceeding!

Edit `/mnt/new/etc/fstab` to mount from subvolumes:

```bash
sudo nano /mnt/new/etc/fstab
```

Replace ALL btrfs entries with the following (keep any non-btrfs mounts like EFI):

```fstab
# Btrfs subvolumes - flat layout
UUID=bae81b8a-6999-4457-827b-e30341b338ff /                    btrfs subvol=@,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /home                btrfs subvol=@home,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/log             btrfs subvol=@var_log,ssd,discard=async,space_cache=v2,nodatacow 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/cache           btrfs subvol=@var_cache,ssd,discard=async,space_cache=v2 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /var/lib/libvirt/images btrfs subvol=@libvirt_images,ssd,discard=async,space_cache=v2,nodatacow 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /swap                btrfs subvol=@swap,ssd,discard=async,space_cache=v2,nodatacow 0 0
UUID=bae81b8a-6999-4457-827b-e30341b338ff /.snapshots          btrfs subvol=@snapshots,ssd,discard=async,space_cache=v2 0 0

# EFI System Partition
UUID=72B8-FEBD /boot/efi vfat umask=0077 0 1

# Swapfile in @swap subvolume
/swap/swap.img none swap sw 0 0
```

**Verify your fstab after editing:**

```bash
# Double-check UUIDs match your system
sudo blkid | grep -E "(nvme0n1p5|nvme0n1p1)"
cat /mnt/new/etc/fstab | grep UUID

# The UUIDs in fstab should match the blkid output!
```

**Key points:**
- NOCOW is set as a property on `@var_log`, `@libvirt_images`, and `@swap` subvolumes (done in Phase 3)
- All files in those subvolumes automatically inherit NOCOW, regardless of mount options
- Each subvolume specified with `subvol=@name` format
- Only VM disk images are in the @libvirt_images subvolume (mounted at /var/lib/libvirt/images)
- Swapfile path changed from `/swap.img` to `/swap/swap.img` (now in separate subvolume)
- **CRITICAL:** UUIDs in fstab must match your actual system UUIDs from `blkid`

### 5.2 Update GRUB Configuration

Edit GRUB default config to add rootflags:

```bash
sudo nano /mnt/new/etc/default/grub
```

Find the `GRUB_CMDLINE_LINUX_DEFAULT` line and add `rootflags=subvol=@`:

**Before:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
```

**After:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rootflags=subvol=@"
```

If there's a `GRUB_CMDLINE_LINUX` line, update it too:
```bash
GRUB_CMDLINE_LINUX="rootflags=subvol=@"
```

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

---

## Phase 6: Chroot and Finalize Bootloader

### 6.1 Prepare Chroot Environment

```bash
# Bind mount essential filesystems for chroot
sudo mount --bind /dev /mnt/new/dev
sudo mount --bind /proc /mnt/new/proc
sudo mount --bind /sys /mnt/new/sys
sudo mount --bind /run /mnt/new/run

# Verify mounts
mount | grep /mnt/new
```

### 6.2 Chroot into New System

```bash
sudo chroot /mnt/new /bin/bash
```

You should now see a root prompt inside the new system.

### 6.3 Regenerate GRUB Configuration

Inside chroot:

```bash
# Update GRUB config to detect the new subvolume layout
grub-mkconfig -o /boot/grub/grub.cfg

# Expected output:
# Generating grub configuration file ...
# Found linux image: /boot/vmlinuz-...
# Found initrd image: /boot/initrd.img-...
# done

# Verify rootflags appears in the config
grep "rootflags=subvol=@" /boot/grub/grub.cfg
# Should show lines with: root=UUID=... rootflags=subvol=@
```

### 6.4 Reinstall GRUB to EFI

Check your EFI mount point (from Phase 1.2.4 documentation). This guide assumes `/boot/efi`.

Still inside chroot:

```bash
# Install GRUB bootloader to EFI partition
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck

# Expected output:
# Installing for x86_64-efi platform.
# Installation finished. No error reported.
```

**Note on "EFI variables cannot be set" warning:**

If you see this warning, it's **expected and harmless** when running grub-install from a chroot environment in a live USB:

```
EFI variables cannot be set on this system.
You will have to complete the GRUB setup manually.
Installation finished. No errors reported.
```

This happens because:
1. EFI variables are managed by the running kernel and stored in NVRAM
2. When chrooted from a live environment, you don't have access to modify the host system's EFI variables
3. However, **GRUB still successfully installs the bootloader files** to the EFI partition

**Verification that installation succeeded:**

```bash
# While still in chroot, verify GRUB files were installed
ls -la /boot/efi/EFI/ubuntu/
# Should show: grubx64.efi, shimx64.efi, and other GRUB files
```

**Why this is fine in most cases:**

Since your system was already booting via UEFI before the migration, the UEFI firmware already has a boot entry pointing to `/boot/efi/EFI/ubuntu/grubx64.efi`. The warning only means the chroot can't update EFI variables - but the files were written successfully, and the existing firmware entry remains valid.

**If system doesn't boot after reboot:**

In the unlikely event the system doesn't boot, you can create a UEFI boot entry manually from the live USB or after successful boot:

```bash
sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L "ubuntu" -l '\EFI\ubuntu\shimx64.efi'
```

### 6.5 Update initramfs

Still inside chroot:

```bash
# Regenerate initramfs to ensure it knows about the new subvolume layout
update-initramfs -u -k all

# This ensures the initramfs can mount @ subvolume at boot
```

### 6.6 Exit Chroot

```bash
exit
```

You're now back in the live USB environment.

---

## Phase 7: Verify Before Reboot

### 7.1 Verify New Subvolume Structure

```bash
# Check all subvolumes were created
sudo btrfs subvolume list /mnt/btrfs
# Should show: @, @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots

# Verify new @ subvolume has content
ls -la /mnt/new/etc/ | head -20
ls -la /mnt/new/boot/ | head -20
ls -la /mnt/new/usr/bin/ | head -10

# Verify subvolumes are properly populated
ls -la /mnt/new/home/  # Should show your user directories
ls -la /mnt/new/var/log/  # Should show log files
ls -la /mnt/new/var/cache/apt/  # Should show apt cache
ls -la /mnt/new/var/lib/libvirt/images/ 2>/dev/null  # Should show VM disk images if you have VMs
ls -lh /mnt/new/swap/swap.img  # Should show swapfile with correct size (e.g., 8.0G)

# Verify NOCOW properties are set correctly
lsattr -d /mnt/btrfs/@var_log /mnt/btrfs/@libvirt_images /mnt/btrfs/@swap
# Should show: ---------------C--- for each subvolume
lsattr /mnt/new/swap/swap.img
# Should show: ---------------C--- (inherited from parent)
```

### 7.2 Verify Configuration Files

```bash
# Check fstab syntax
sudo cat /mnt/new/etc/fstab
# Verify all 7 subvolume mounts are present (including @swap)

# Verify GRUB default config
sudo grep "rootflags=subvol=@" /mnt/new/etc/default/grub
# Should show the line with rootflags

# Verify GRUB config was generated correctly
sudo grep "rootflags=subvol=@" /mnt/new/boot/grub/grub.cfg
# Should show multiple lines with root=UUID=... rootflags=subvol=@

# Check swapfile exists in @swap subvolume
ls -lh /mnt/new/swap/swap.img
# Should show file with correct size (e.g., 8.0G)
```

### 7.3 Final Sanity Checks

```bash
# Verify EFI partition is accessible
ls -la /mnt/new/boot/efi/EFI/ubuntu/
# Should show grubx64.efi and other GRUB files

# Check that critical system files exist
test -f /mnt/new/etc/fstab && echo "fstab: OK" || echo "fstab: MISSING!"
test -f /mnt/new/boot/grub/grub.cfg && echo "grub.cfg: OK" || echo "grub.cfg: MISSING!"
test -f /mnt/new/etc/default/grub && echo "grub default: OK" || echo "grub default: MISSING!"
```

### 7.4 Unmount Everything

```bash
# Unmount in reverse order (most nested first)
sudo umount /mnt/new/boot/efi
sudo umount /mnt/new/.snapshots
sudo umount /mnt/new/swap
sudo umount /mnt/new/var/lib/libvirt/images
sudo umount /mnt/new/var/cache
sudo umount /mnt/new/var/log
sudo umount /mnt/new/home
sudo umount /mnt/new/dev
sudo umount /mnt/new/proc
sudo umount /mnt/new/sys
sudo umount /mnt/new/run
sudo umount /mnt/new
sudo umount /mnt/btrfs

# Verify all unmounted
mount | grep nvme0n1p5
# Should show nothing
```

---

## Phase 8: Reboot and Testing

### 8.1 Reboot into New System

```bash
sudo reboot
```

**Remove the live USB when prompted or after BIOS screen.**

### 8.2 Initial Boot Checks

After rebooting, the system should boot normally from the @ subvolume.

1. **Wait for full boot** (may take slightly longer on first boot)
2. **Open terminal** (Ctrl+Alt+T)
3. **Verify subvolume mounts:**

   ```bash
   mount | grep btrfs
   # Expected output (7 lines):
   # /dev/nvme0n1p5 on / type btrfs (subvol=@,...)
   # /dev/nvme0n1p5 on /home type btrfs (subvol=@home,...)
   # /dev/nvme0n1p5 on /var/log type btrfs (subvol=@var_log,...)
   # /dev/nvme0n1p5 on /var/cache type btrfs (subvol=@var_cache,...)
   # /dev/nvme0n1p5 on /var/lib/libvirt/images type btrfs (subvol=@libvirt_images,...)
   # /dev/nvme0n1p5 on /swap type btrfs (subvol=@swap,...)
   # /dev/nvme0n1p5 on /.snapshots type btrfs (subvol=@snapshots,...)
   ```

4. **Check disk usage:**

   ```bash
   df -h
   # Verify all mount points show up with reasonable sizes
   ```

5. **Verify you're booted from @ subvolume:**

   ```bash
   cat /proc/cmdline | grep rootflags
   # Should show: ... rootflags=subvol=@ ...

   findmnt -n -o SOURCE /
   # Should show: /dev/nvme0n1p5[/@]
   ```

### 8.3 Test Services and Applications

```bash
# Check system services
systemctl status
# Should show "running" state

# Test network
ping -c 3 google.com

# Check logs are being written
sudo journalctl -n 20
tail -f /var/log/syslog  # Press Ctrl+C to exit

# Test apt cache
apt list --installed | head -5
sudo apt update  # Should work normally
```

### 8.4 Verify VM Functionality (if applicable)

```bash
# Check if libvirtd is running (if you use VMs)
systemctl status libvirtd

# List VMs
virsh list --all

# Check VM disk images are accessible (in @libvirt_images subvolume)
ls -la /var/lib/libvirt/images/
```

### 8.5 Test User Data

```bash
# Verify your home directory
ls -la ~
# All your files should be present

# Test opening some files
cat ~/fstab.backup  # Should show your old fstab from backup
```

### 8.6 Create Initial Snapshot

After verifying everything works, create your first snapshot:

```bash
# Create read-only snapshot of root
sudo btrfs subvolume snapshot -r / /.snapshots/root-migration-success-$(date +%Y%m%d)

# Create snapshot of home (optional)
sudo btrfs subvolume snapshot -r /home /.snapshots/home-migration-success-$(date +%Y%m%d)

# List snapshots
sudo btrfs subvolume list /.snapshots
# Should show your new snapshots

# Or view them as directories
ls -la /.snapshots/
```

---

## Phase 9: Cleanup (1-2 weeks after stable operation)

**Wait at least 1-2 weeks** and verify everything is stable before cleanup.

After confirming stable operation:

### 9.1 Remove Safety Net Snapshot

```bash
# Mount top-level
sudo mkdir -p /mnt/btrfs
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# Remove the pre-migration safety snapshot
sudo btrfs subvolume delete /mnt/btrfs/backup-pre-migration

# Unmount
sudo umount /mnt/btrfs
```

### 9.2 Clean Up Old Top-Level Data

```bash
# Mount top-level to access old subvolumes
sudo mkdir -p /mnt/btrfs
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# List what's at top-level
sudo btrfs subvolume list /mnt/btrfs
ls -la /mnt/btrfs/

# Verify final subvolume list
sudo btrfs subvolume list /mnt/btrfs
# Should show only: @, @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots (and any snapshots)

# Unmount
sudo umount /mnt/btrfs
```

**If old data directories remain at top-level** (like bin, etc, usr, var, home), you can safely remove them after 2+ weeks of stable operation:

```bash
# Mount top-level
sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs

# List non-subvolume directories at top-level
ls -la /mnt/btrfs/ | grep -v "^d.*@"

# SAFETY CHECK: Verify directories are NOT subvolumes before deletion
# This helper function checks if a path is a regular directory (safe to rm -rf)
check_safe_to_delete() {
    local path="$1"
    local name=$(basename "$path")

    # Never delete @ subvolumes
    if [[ "$name" =~ ^@ ]]; then
        echo "DANGER: $name looks like a subvolume name, SKIPPING"
        return 1
    fi

    # Check if it's actually a subvolume
    if sudo btrfs subvolume show "$path" &>/dev/null; then
        echo "DANGER: $path is a subvolume, SKIPPING"
        return 1
    fi

    echo "SAFE: $path is a regular directory"
    return 0
}

# Example: Remove old directories safely (adjust list as needed)
for dir in bin boot etc home lib lib64 opt root sbin srv usr var; do
    if [ -d "/mnt/btrfs/$dir" ]; then
        if check_safe_to_delete "/mnt/btrfs/$dir"; then
            echo "Removing /mnt/btrfs/$dir"
            sudo rm -rf "/mnt/btrfs/$dir"
        fi
    fi
done

# Verify only subvolumes remain
ls -la /mnt/btrfs/
# Should only show @ directories and maybe lost+found

# Unmount
sudo umount /mnt/btrfs
```

**CRITICAL SAFETY RULES:**
- NEVER use `rm -rf` without the safety check function
- NEVER delete directories starting with `@`
- NEVER delete directories that `btrfs subvolume show` identifies as subvolumes
- Always verify with `btrfs subvolume list` after cleanup

---

## Troubleshooting

### System Won't Boot - GRUB Prompt

If you see a GRUB prompt instead of boot menu:

1. **Type these commands at grub> prompt:**
   ```bash
   ls
   # Note which partition shows (hd0,gpt5) or similar

   ls (hd0,gpt5)/@/boot/
   # Should show vmlinuz files

   set root=(hd0,gpt5)
   linux /@/boot/vmlinuz-<tab-complete> root=UUID=bae81b8a-6999-4457-827b-e30341b338ff rootflags=subvol=@ ro quiet splash
   initrd /@/boot/initrd.img-<same-version>
   boot
   ```

2. **Once booted, reinstall GRUB:**
   ```bash
   sudo grub-install /dev/nvme0n1
   sudo update-grub
   ```

### System Won't Boot - Drops to initramfs

If you see "initramfs" prompt or "can't find root device":

1. **Boot into live USB again**
2. **Mount and check fstab:**
   ```bash
   sudo mount -t btrfs -o subvol=@ /dev/nvme0n1p5 /mnt
   cat /mnt/etc/fstab
   # Verify subvol=@ is present in root mount line
   ```
3. **Chroot and fix:**
   ```bash
   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys /mnt/sys
   sudo chroot /mnt
   update-initramfs -u -k all
   update-grub
   exit
   sudo reboot
   ```

### Missing /var/log or /var/cache After Boot

If directories are empty after boot:

```bash
# Check if they're mounted
mount | grep btrfs

# If missing, check fstab
cat /etc/fstab

# Mount manually to test
sudo mount -a

# If that works, the issue was mount order - fstab should be correct
```

### VM Disks Not Accessible

If libvirt can't find VM disk images:

```bash
# Check if @libvirt_images is mounted at /var/lib/libvirt/images
mount | grep libvirt/images

# Check permissions on the images directory
ls -la /var/lib/libvirt/images/

# If mounted but empty, you may need to restart libvirtd
sudo systemctl restart libvirtd

# List VMs
virsh list --all
```

### Snapshots Not Working

If snapshot commands fail:

```bash
# Check if /.snapshots is mounted
mount | grep snapshots

# Try creating snapshot with full path
sudo btrfs subvolume snapshot -r / /.snapshots/test-$(date +%Y%m%d-%H%M%S)

# List to verify
sudo btrfs subvolume list /.snapshots
```

---

## Rollback Procedure (If Critical Issues)

If something goes seriously wrong and system is unstable:

### Option 1: Boot from Live USB and Fix

1. **Boot into live USB**
2. **Mount @ subvolume and fix the issue**
3. **Chroot and reconfigure** (see troubleshooting sections)

### Option 2: Restore from Backup

If system is completely broken:

1. **Boot into live USB**
2. **Mount filesystem:**
   ```bash
   sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p5 /mnt/btrfs
   ```

3. **Delete broken subvolumes:**
   ```bash
   sudo btrfs subvolume delete /mnt/btrfs/@
   sudo btrfs subvolume delete /mnt/btrfs/@home
   # ... delete others if needed
   ```

4. **Restore from backup:**
   ```bash
   # Mount Synology NAS via NFS (same as Phase 1.1)
   sudo mkdir -p /mnt/backup
   sudo mount -t nfs <nas-ip>:/volume1/your/backup/folder /mnt/backup

   # Verify NFS mount succeeded
   mount | grep nfs

   # Restore using rsync (reverse of Phase 1.1 backup)
   # Source: /mnt/backup/system-backup-YYYYMMDD/ (the backup you created)
   # Destination: /mnt/btrfs (the top-level filesystem)
   sudo rsync -aAXHv /mnt/backup/system-backup-*/. /mnt/btrfs/ \
     --exclude='/@*' --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
     --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' --exclude='/media/*' \
     --exclude='/lost+found' --exclude='/swap.img'
   ```

5. **Reboot** - system should boot from top-level as before migration

---

## Post-Migration: Snapshot Management

After successful migration, set up regular snapshots:

### Option 1: Manual Snapshots

```bash
# Create snapshot before system updates
sudo btrfs subvolume snapshot -r / /.snapshots/root-before-update-$(date +%Y%m%d)

# Create snapshot of home weekly
sudo btrfs subvolume snapshot -r /home /.snapshots/home-weekly-$(date +%Y%m%d)

# List all snapshots
sudo btrfs subvolume list /.snapshots

# Delete old snapshot
sudo btrfs subvolume delete /.snapshots/root-before-update-20240101
```

### Option 2: Using Snapper (Recommended)

```bash
# Install snapper
sudo apt install snapper

# Create configuration for root
sudo snapper -c root create-config /

# Edit config to adjust snapshot frequency/retention
sudo nano /etc/snapper/configs/root

# Create configuration for home
sudo snapper -c home create-config /home

# Create snapshot manually
sudo snapper -c root create --description "Before major update"

# List snapshots
sudo snapper -c root list

# Auto-cleanup old snapshots (configured in config file)
sudo snapper -c root cleanup number
```

### Option 3: Using Timeshift

```bash
# Install Timeshift
sudo apt install timeshift

# Launch GUI
sudo timeshift-gtk

# Or configure via CLI
sudo timeshift --list
sudo timeshift --create --comments "Initial snapshot"
```

**Note:** Timeshift works best with @ and @home. For snapshots of other subvolumes, use snapper or manual btrfs commands.

### Automatic Snapshots with Cron

```bash
# Create weekly snapshot script
sudo nano /usr/local/bin/weekly-snapshot.sh
```

Add:
```bash
#!/bin/bash
# Create weekly snapshot of root
btrfs subvolume snapshot -r / /.snapshots/root-weekly-$(date +%Y%m%d)

# Keep only last 4 weeks, delete older
cd /.snapshots
ls -t | grep "^root-weekly-" | tail -n +5 | xargs -I {} btrfs subvolume delete {}
```

```bash
# Make executable
sudo chmod +x /usr/local/bin/weekly-snapshot.sh

# Add to cron (run every Sunday at 2 AM)
sudo crontab -e
# Add line:
0 2 * * 0 /usr/local/bin/weekly-snapshot.sh
```

---

## Summary Checklist

- [ ] Created system backup to external drive
- [ ] Documented current configuration
- [ ] Downloaded and created live USB
- [ ] Booted into live environment
- [ ] Mounted filesystem and verified structure
- [ ] Renamed or deleted old unused @ and @home subvolumes
- [ ] Created new subvolumes (@, @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots)
- [ ] Copied root data to @ subvolume
- [ ] Copied home data to @home subvolume
- [ ] Copied logs to @var_log subvolume
- [ ] Copied cache to @var_cache subvolume
- [ ] Copied VM images to @libvirt_images subvolume (if applicable)
- [ ] Created swapfile in @swap subvolume
- [ ] Updated /etc/fstab with all subvolume mounts (including @swap)
- [ ] Updated /etc/default/grub with rootflags=subvol=@
- [ ] Chrooted into new system
- [ ] Regenerated GRUB config (grub-mkconfig)
- [ ] Reinstalled GRUB to EFI partition
- [ ] Updated initramfs
- [ ] Verified all changes before reboot
- [ ] Successfully booted into new @ layout
- [ ] Verified all 7 subvolumes mounted correctly (including @libvirt_images and @swap)
- [ ] Tested all services and applications
- [ ] Tested VM functionality with images in @libvirt_images (if applicable)
- [ ] Created initial snapshots
- [ ] Monitored system for 1-2 weeks
- [ ] Cleaned up old subvolumes and data
- [ ] Set up snapshot management (snapper/Timeshift/manual)

---

## Important Reminders

1. **DO NOT skip the backup step** - If something goes wrong, you'll need it
2. **Keep the live USB handy** for at least 2 weeks after migration
3. **The copy operations are fast** - CoW reflinks make cp -a essentially instant; entire Phase 4 should complete in seconds
4. **Verify everything before rebooting** - Use the verification checklist
5. **Monitor the system** for at least 1-2 weeks before cleanup
6. **Set up regular snapshots** to benefit from the new layout
7. **Document your EFI partition and mount point** before starting (from Phase 1.2.4)
8. **Document your swapfile size** before starting (from Phase 1.2.5)
9. **Test snapshot restoration** after migration to ensure it works
