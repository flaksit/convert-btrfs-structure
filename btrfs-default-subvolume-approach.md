# Using btrfs set-default Instead of Explicit subvol= for /

## Decision

Instead of specifying `subvol=@` in fstab and `rootflags=subvol=@` in GRUB for the root filesystem, we rely on `btrfs subvolume set-default` to control which subvolume is mounted as root.

## How It Works

- Without `subvol=` or `subvolid=` in fstab/GRUB, btrfs mounts the **default subvolume**
- `btrfs subvolume set-default <subvolume_folder>` or `btrfs subvolume set-default <subvolid> /` changes which subvolume is the default
- Reboot → new root, no config file changes needed

## Why This Approach

**Easier snapshot switching:** To boot into a (writable copy of a) snapshot:
1. Create writable snapshot from existing snapshot
2. `btrfs subvolume set-default <new-subvol-id> /`
3. Reboot

No need to edit fstab or GRUB configuration.

This is the same approach used by openSUSE with snapper for rollbacks.

## Important Notes

1. **Other subvolumes** (`@home`, `@var_log`, etc.) should **still use explicit** `subvol=` options in fstab, otherwise they would also follow the default (which you don't want)

2. **Recovery:** If something goes wrong, you can:
   - Boot from live USB and reset the default subvolume
   - Pass `rootflags=subvol=@` as a one-time GRUB edit at boot

3. **Less explicit:** You can't tell from fstab alone which subvolume is mounted as root — you need to check `btrfs subvolume show /` or `btrfs subvolume get-default /`
