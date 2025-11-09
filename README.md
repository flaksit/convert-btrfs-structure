# Convert Btrfs Structure

A comprehensive guide for migrating from a simple btrfs top-level layout to a flat subvolume structure that enables snapshot-based system rollback.

## Overview

This repository contains a detailed migration plan for converting a btrfs filesystem from booting directly from the top-level subvolume to using a modern flat subvolume layout with the @ naming convention.

The target layout follows the pattern proposed in [archlinux/archinstall#781](https://github.com/archlinux/archinstall/issues/781), adapted for Ubuntu/Debian-based systems.

## Why Migrate?

The flat subvolume layout provides:
- **Atomic snapshots** for system rollback capability
- **Snapshot-based backups** using tools like Timeshift or snapper
- **Better separation of concerns** (root, home, logs, cache, VMs)
- **Improved mount option flexibility** per subvolume
- **Protection against accidental data loss** during updates

## Target Subvolume Structure

After migration, your filesystem will have:

```
Subvolume      Mount Point          Purpose
----------     -----------          -------
@              /                    Root filesystem
@home          /home                User home directories
@var_log       /var/log             System logs
@var_cache     /var/cache           APT packages and caches
@libvirt       /var/lib/libvirt     VM images and configurations
@snapshots     /.snapshots          Snapshot storage directory
```

All subvolumes exist as siblings at the top level (subvolid=5) in a flat structure, enabling snapshot-based system recovery.

## Migration Guide

See **[migration-plan.md](migration-plan.md)** for the complete step-by-step migration guide.

The guide includes:
- Pre-migration preparation and backup procedures
- Detailed migration steps for live USB environment
- Bootloader reconfiguration (GRUB)
- Comprehensive verification checks
- Troubleshooting common issues
- Post-migration snapshot management options
- Complete rollback procedures if needed

## Timeline

- **Preparation:** 30-60 minutes (backup, documentation)
- **Migration:** 2-4 hours (depending on disk speed)
- **Verification:** 1-2 weeks (monitoring before cleanup)

## Prerequisites

- Ubuntu or Debian-based system using btrfs
- GRUB bootloader (EFI or BIOS)
- External drive for backup (recommended)
- Ubuntu live USB matching your system version
- At least 150GB free space on btrfs filesystem

## Risk Level

**Medium** - Bootloader reconfiguration required. Full backup strongly recommended.

## Use Cases

This migration is ideal if you:
- Want snapshot-based system rollback capability
- Need to separate system components for better management
- Want to use tools like Timeshift or snapper for automated backups
- Are currently booting from btrfs top-level without subvolume separation
- Have VMs and want better data management for libvirt

## Background

This guide was created to address a specific migration scenario where:
- System boots from btrfs top-level (subvolid=5)
- Subvolumes @ and @home exist but are **unused**
- All data currently lives at the filesystem top level
- Goal is to reorganize into modern flat subvolume layout

## Post-Migration

After successful migration, you can:
- Create manual snapshots before system updates
- Set up automated snapshots with snapper or Timeshift
- Roll back to previous snapshots if updates cause issues
- Manage different subvolumes with different retention policies
- Benefit from improved system reliability

## Contributing

Found an issue or have suggestions? Please open an issue or submit a pull request.

## License

MIT License - See LICENSE file for details

## Acknowledgments

- Based on the btrfs layout discussion in [archlinux/archinstall#781](https://github.com/archlinux/archinstall/issues/781)
- Adapted for Ubuntu/Debian systems with practical migration steps

## Disclaimer

This migration involves bootloader changes and filesystem restructuring. While the guide includes comprehensive safety measures and rollback procedures, ensure you have a verified backup before proceeding. The authors are not responsible for data loss or system issues resulting from following this guide.
