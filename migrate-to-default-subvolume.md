# Migrating to btrfs Default Subvolume Mounting

This guide helps you convert an already-converted system from explicit `subvol=@` mounting to using `btrfs subvolume set-default`.

This guide is intended for systems that have already been converted to use btrfs with multiple subvolumes (like @, @home, @var_log, etc.) but are still using explicit `subvol=@` in `/etc/fstab` and `rootflags=subvol=@` in GRUB for the root filesystem, as the conversion-plan.md described up to commit b28710b6.

## Current State

Your system currently:
- Has `subvol=@` in `/etc/fstab` for the root mount
- Has `rootflags=subvol=@` in GRUB kernel command line
- Explicitly specifies which subvolume to mount as root

## Desired State

After migration:
- `/etc/fstab` root mount has NO `subvol=` option
- GRUB kernel command line has NO `rootflags=subvol=@`
- The default subvolume (set via `btrfs subvolume set-default`) is mounted as root
- Other subvolumes (@home, @var_log, etc.) still use explicit `subvol=` options

## Migration Steps

### Step 1: Set @ as the Default Subvolume

```bash
# Set @ as the default subvolume
sudo btrfs subvolume set-default /

# Verify it was set correctly
sudo btrfs subvolume get-default /
# Should show: ID <subvol_id> gen <gen_num> top level <level> path @
```

### Step 2: Update /etc/fstab

Edit `/etc/fstab` and remove `subvol=@` from the root entry only:

```bash
sudo nano /etc/fstab
```

**Find the root mount line (for `/`):**

**Before:**
```fstab
UUID=bae81b8a-6999-4457-827b-e30341b338ff /                    btrfs subvol=@,ssd,discard=async,space_cache=v2 0 0
```

**After:**
```fstab
UUID=bae81b8a-6999-4457-827b-e30341b338ff /                    btrfs ssd,discard=async,space_cache=v2 0 0
```

**Important:** Keep all other subvolume mounts (like @home, @var_log, etc.) with their explicit `subvol=` options.

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

### Step 3: Update GRUB Configuration

Edit GRUB default config:

```bash
sudo nano /etc/default/grub
```

**Find the `GRUB_CMDLINE_LINUX_DEFAULT` line and remove `rootflags=subvol=@`:**

**Before:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rootflags=subvol=@"
```

**After:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
```

If there's a `GRUB_CMDLINE_LINUX` line with `rootflags=subvol=@`, remove it too.

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

### Step 4: Patch GRUB Script to Disable Automatic Subvolume Detection

Ubuntu's GRUB script (`/etc/grub.d/10_linux`) automatically detects btrfs subvolumes and adds `rootflags=subvol=@` to the kernel command line. This conflicts with using `btrfs set-default`, so we need to disable this behavior.

**Edit the script:**

```bash
sudo nano /etc/grub.d/10_linux
```

**Find lines 130-136** (the btrfs case statement):

```bash
case x"$GRUB_FS" in
    xbtrfs)
    rootsubvol="`make_system_path_relative_to_its_root /`"
    rootsubvol="${rootsubvol#/}"
    if [ "x${rootsubvol}" != x ]; then
        GRUB_CMDLINE_LINUX="rootflags=subvol=${rootsubvol} ${GRUB_CMDLINE_LINUX}"
    fi;;
```

**Comment it out:**

```bash
case x"$GRUB_FS" in
    xbtrfs)
    # Disabled: using btrfs set-default instead of explicit rootflags
    # rootsubvol="`make_system_path_relative_to_its_root /`"
    # rootsubvol="${rootsubvol#/}"
    # if [ "x${rootsubvol}" != x ]; then
    #     GRUB_CMDLINE_LINUX="rootflags=subvol=${rootsubvol} ${GRUB_CMDLINE_LINUX}"
    # fi
    ;;
```

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

### Step 5: Regenerate GRUB Configuration

```bash
sudo update-grub
```

Expected output:
```plain
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-...
Found initrd image: /boot/initrd.img-...
done
```

**Verify that rootflags is NOT in the output:**

```bash
grep rootflags /boot/grub/grub.cfg
# Should return nothing (no rootflags=subvol=@ in the generated config)
```

### Step 6: Update Initramfs

The initramfs needs to know that root will be mounted as the default subvolume:

```bash
sudo update-initramfs -u -k all
```

### Step 7: Verify Changes

Before rebooting, verify the changes:

```bash
# Check fstab
echo "=== /etc/fstab root entry ==="
grep "^UUID.*/$" /etc/fstab
# Should NOT contain "subvol=@"

# Check GRUB default config
echo ""
echo "=== /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT ==="
grep "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub
# Should NOT contain "rootflags=subvol=@"

# Check default subvolume is set
echo ""
echo "=== Default subvolume ==="
sudo btrfs subvolume get-default /
# Should show: ID <id> gen <num> top level <level> path @

# Check other subvolumes still have explicit subvol= in fstab
echo ""
echo "=== Other subvolume entries (should have subvol=) ==="
grep "subvol=@" /etc/fstab | grep -v "^UUID.*/$"
# Should show entries for @home, @var_log, @var_cache, @libvirt_images, @swap, @snapshots
```

### Step 8: Reboot

```bash
sudo reboot
```

### Step 9: Post-Boot Verification

After rebooting, verify the system booted correctly:

```bash
# Verify you're still booting from @ subvolume
echo "=== Root mount source ==="
mount | grep "on / type btrfs"
# Should show something like: /dev/nvme0n1p5 on / type btrfs (...)

# Verify default subvolume
echo ""
echo "=== Default subvolume ==="
sudo btrfs subvolume get-default /
# Should show: ID <id> gen <num> top level <level> path @

# Check that other subvolumes are still mounted correctly
echo ""
echo "=== All btrfs mounts ==="
mount | grep btrfs
# Should show all 7 subvolumes mounted correctly
```

## How to Use This for Snapshots

Once migrated, you can easily switch between the main root and snapshots:

### Create a Writable Snapshot

```bash
# Create writable snapshot from a read-only snapshot
sudo btrfs subvolume snapshot /.snapshots/root-before-update-20240101 /root-snapshot-backup
```

### Switch to Snapshot as Root

```bash
# Get the snapshot's subvolume ID
snap_id=$(sudo btrfs subvolume list / | grep "root-snapshot-backup$" | awk '{print $2}')

# Set it as default
sudo btrfs subvolume set-default $snap_id /

# Reboot
sudo reboot
```

### Switch Back

```bash
# Set @ as default again (same as Step 1)
subvol_id=$(sudo btrfs subvolume list / | grep " @$" | awk '{print $2}')
sudo btrfs subvolume set-default $subvol_id /

# Reboot
sudo reboot
```

## Troubleshooting

### System Won't Boot

If the system doesn't boot and drops to an initramfs prompt:

1. Boot into live USB
2. Mount the filesystem: `sudo mount -t btrfs /dev/nvme0n1p5 /mnt`
3. Chroot in:
   ```bash
   for dir in dev proc sys run; do
       sudo mount --bind /$dir /mnt/$dir
   done
   sudo chroot /mnt /bin/bash
   ```
4. Regenerate initramfs: `update-initramfs -u -k all`
5. Exit chroot: `exit`
6. Unmount and reboot

### Default Subvolume Not Set

If after migration the system still boots from @ but you want to verify the default is set:

```bash
# Get the subvolume ID of @ (it's always at a fixed ID)
sudo btrfs subvolume show / | grep "Subvolume ID"

# Verify it matches get-default
sudo btrfs subvolume get-default /
```

If they don't match, run Step 1 again to set the default.
