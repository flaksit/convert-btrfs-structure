## Research Notes: Why `cp -a` Over `rsync` for Btrfs Conversions

This section documents the technical reasoning behind using `cp -a` instead of `rsync` for this btrfs subvolume Conversion.

### Summary

The Conversion uses `cp -a` for all file copies, which is significantly faster and more appropriate than `rsync` for same-filesystem btrfs Conversions:

- **`cp -a` uses CoW reflinks by default** (since coreutils 9.0 on Ubuntu 24.04): Copies are metadata-only operations, essentially instantaneous regardless of file size
- **`rsync` lacks native reflink support**: Even for local copies on the same btrfs filesystem, rsync performs full data transfer (reading and writing all data blocks), making it orders of magnitude slower
- **Reflinks are transparent and safe**: The end result is identical to a full copy—files are fully independent with no sharing of extents after cleanup
- **Estimated time**: Instead of 10-30 minutes, the entire copy phase will complete in seconds


### The Problem with Rsync on Btrfs

1. **Rsync lacks native reflink/CoW support**: Even in the latest versions, rsync has no built-in support for btrfs copy-on-write operations. While attempted patches exist (notably "clone-dest.diff" and Samba bug #10170 filed in 2013), none have been merged into mainline.

2. **Local copies perform full data transfer**: When copying files between btrfs subvolumes on the same filesystem using rsync, it will:
   - Read all file data from source
   - Write all file data to destination
   - Result in completely duplicated data (no shared extents)
   - This is the same as copying to a non-btrfs filesystem

3. **Benchmark impact**: For a 134GB dataset on modern hardware:
   - `cp -a` with reflinks: ~5-10 seconds (metadata-only operation)
   - `rsync`: 20-45 minutes (full I/O bound data transfer)

### Why `cp -a` is Superior for This Conversion

1. **Automatic reflink support**: Since coreutils 9.0 (September 2021), `cp` defaults to `--reflink=auto`, which automatically uses CoW reflinks on btrfs and falls back to standard copies on other filesystems.

2. **Metadata-only operation**: When source and destination are on the same btrfs filesystem:
   - `cp` creates new metadata pointers to existing data extents
   - No actual data blocks are read or written
   - Completion is essentially instantaneous, regardless of file size

3. **Transparent to final state**: After cleanup (removing old top-level data), the final files in `@` subvolume are fully independent:
   - Extents are preserved from original locations
   - No conceptual difference from files with freshly written data
   - Standard btrfs snapshots work normally

4. **Simpler command syntax**: `cp -a /source/. /dest/` replaces complex multi-line rsync commands with exclusion flags, reducing opportunities for error.
   - **Note on hidden files**: Use `/source/.` not `/source/*` to include hidden files (those starting with a dot). The glob pattern `*` does not match hidden files, so `cp -a /source/* /dest/` would miss them. Using `/source/.` copies the directory's full contents including hidden files and directories.

### When `rsync` Would Be Better

- Transferring data over networks (delta-transfer algorithm provides compression)
- Copying to non-btrfs filesystems (CoW not available)
- Incremental/resumable backups (when destination already exists)
- Complex filtering scenarios with many inclusions/exclusions

For this same-filesystem btrfs Conversion, none of these apply.

### Alternative: `btrfs send/receive`

For btrfs-to-btrfs transfers, `btrfs send | btrfs receive` preserves all btrfs-specific features and is more efficient for incremental updates. However, for initial full-volume Conversion, `cp -a` is still faster and simpler.
