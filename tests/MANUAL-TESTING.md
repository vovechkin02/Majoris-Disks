# Manual destructive-operation test plan

Use only disposable loop images, removable media with backups, or a virtual machine. Confirm the device path, serial and displayed capacity before every destructive action.

1. Create GPT and MBR images; exercise primary, extended and logical partition creation and empty-extended deletion.
2. Verify an extended partition cannot shrink across its last logical partition and cannot be deleted while non-empty.
3. Format ext4, FAT, exFAT, NTFS and swap where their UDisks utilities are installed. Exercise label validation and overwrite mode.
4. On ext4 and NTFS, verify the resize dialog reports a measured minimum, rejects a smaller value, and performs filesystem-before-partition shrink.
5. Exercise offline and online growth. Confirm original mounts are restored after success and after an injected backend failure.
6. Disconnect UDisks during each operation phase. The job must report failure or needs-attention, never inferred success.
7. Run simultaneous unrelated UDisks jobs with identical operation names. Confirm they remain separate.
8. Cancel a cancelable UDisks job and deny its authorization in a second run. Confirm the UI waits for the backend result.
9. Repeat check and repair on clean and deliberately damaged disposable filesystems; verify repair always requires confirmation.
10. Test narrow-window navigation, keyboard traversal, translated long strings, device hot-unplug and UDisks restart.
11. On mounted data filesystems, start Check and Repair and verify guided unmount plus restoration to the previous UDisks-selected mount location.
12. Exercise the whole-disk overwrite switch only on a disposable loop image; verify progress appears as a job and the warning does not claim secure erasure.
13. Edit common GPT and MBR partition types through their readable names, then select Other and verify a custom identifier is preserved.

## Btrfs allocation and degraded discovery

Use a dedicated Debian 13 guest with the loop driver, `btrfs-progs` and `util-linux`. Build Majoris as a normal user, then run the opt-in tests inside the guest.

    sudo env MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1 meson test -C build --no-rebuild --print-errorlogs btrfs-discovery-integration disposable-btrfs-mount-integration

- On a mounted two-member RAID 1 fixture, open **Btrfs Allocation**. Compare the member IDs and UUIDs with `btrfs filesystem show` and compare data, metadata and system profiles with `btrfs filesystem usage`. Compare logical capacity and the remaining-space estimate with `df`.
- Mount the fixture read-only and degraded after detaching one image. Verify that the missing member retains its Btrfs device ID and has no physical device path. Check that the report marks the filesystem degraded and withholds complete physical totals.
- The automated discovery test uses the native Majoris probe. Desktop rendering and UDisks discovery on a degraded mount require a separate interactive check.

Both opt-in tests passed in a Debian 13 QEMU guest with kernel 6.12.115 and btrfs-progs 6.14. The standard Debian 13 Meson run reported 9 passes, 0 failures and 18 prerequisite or opt-in skips.

## Advanced LVM2

Use a dedicated disposable Debian 13 VM with `udisks2`, `udisks2-lvm2`, `lvm2`, `e2fsprogs`, `util-linux` and a working kernel device mapper and loop driver. If UDisks has yet to load its installed LVM2 module, enable it inside that VM and verify the interface.

    sudo busctl --system call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager EnableModule sb lvm2 true
    busctl --system introspect org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager.LVM2

Build as a normal user and install in the VM so the cache and protected-configuration inspectors resolve at their configured paths. Run the three opt-in tests as root in that VM. Save the test log, including per-scenario method names, final state and marker checksums. A prerequisite skip has exit status 77. A failed setup, backend call, data comparison, result check or cleanup is a failure.

    sudo env MAJORIS_DISKS_RUN_LVM_TESTS=1 meson test -C build --no-rebuild --print-errorlogs lvm-recovery-integration lvm-cache-integration lvm-layout-integration

- In Advanced Storage, select a VG, an LV and a physical-volume row. Verify that a missing PV is shown by UUID and that only LVs with evidence of incomplete allocation show a damage warning. Reconnect the fixture PV and use **Refresh and Reassess**.
- In a two-image RAID 1 fixture, unmount the degraded mapping and verify that only a separate PV with enough free extents can be selected. Confirm repair and check synchronization and the original data before accepting the result. A linear LV with a missing allocation has no repair action.
- Open **Remove Missing Physical-Volume Records** and confirm that Cancel makes no change. A damaged or unaccounted-for LV must block removal. Verify the remaining LV UUIDs after permitted removal.
- Rename an inactive VG and check that selection follows its UUID. Exercise rejection with an active mapping, an existing VG name and a persistent reference.
- Attach an empty cache candidate, write through the cached origin, then split it. Verify the pool remains. Repeat and remove the cache pool, then verify the origin and the writes. Try a candidate with a filesystem, a mount, or raw data.
- For explicit placement, compare the selected PVs with the backend's data and metadata components. Try duplicate devices and a layout with insufficient space on a single PV even when the VG has sufficient aggregate free space.

### Desktop authorization

1. Sign in as a regular GNOME user with the system Polkit agent running. Launch Majoris normally. Test an inactive fixture VG with no persistent references while `/etc/crypttab` is root-owned and mode `0600`. Approve protected-reference inspection and any subsequent UDisks authorization. Verify the returned VG path, unchanged VG/PV/LV UUIDs and the new name in Advanced Storage.
2. In the same disposable VM, have an administrator back up crypttab with its original ownership and mode. Add a temporary `noauto,nofail` entry with a unique mapping name and the fixture LV's `/dev/mapper/` path as its source. Verify the inspector identifies crypttab as a conflict and the VG retains its original name. Restore the backup and verify its mode. Repeat with a fixture reference in fstab.
3. Repeat the rename, cache, layout and eligible repair flows with approval, denial and cancellation at each authorization prompt. After cached authorization expires or after a fresh login, verify that protected inspection prompts again. Check that denial and cancellation preserve the VG/LV identities and that no successful job or toast appears.
4. With the dialog open, change the fixture identity, occupy a selected PV, or start another job against the same VG from a separate session. Confirm the operation stops if its preconditions have changed. For an authorized request that reaches UDisks, restart UDisks or interrupt verification using only disposable storage. Compare the job state, fresh D-Bus properties and readback with the original. Check that Majoris reports an unverified or still-running outcome when appropriate and makes no automatic retry.
5. On a disposable writeback cache, observe both positive dirty-block counts and a verified zero count. When the report is unavailable or metadata health is uncertain, verify that separation stays disabled. During an empty-candidate scan, cancel from the job list and verify the origin and candidate retain their original layouts and identities.

Record each scenario as passed, failed, skipped or not executed. Leave the fixture intact if a device identity becomes uncertain.

The Debian 13.7 QEMU run passed all three opt-in Meson suites. A separate root-run fixture verified a real crypttab conflict and a successful rename with crypttab still at mode `0600`. The GNOME authorization procedure and the live interruption scenarios above remain open. [Execution register](../docs/feature-parity-completion.md#advanced-lvm2-administration)

## Btrfs device replacement

Build in a dedicated disposable Debian 13 guest with the Btrfs and loop drivers, btrfs-progs, UDisks and its Btrfs module. Use only new, isolated loop-backed fixtures.

    sudo env MAJORIS_DISKS_RUN_BTRFS_REPLACE_TESTS=1 meson test -C build --no-rebuild --print-errorlogs 'btrfs-device-replace-*'

The native fixture invokes the actual restricted helper as root. It verifies fixture ownership, filesystem UUID, source ID association and known payload checksums. The cancellation fixture reports when replacement finishes before cancellation can be confirmed.

- Open **Advanced Storage**, select the mounted Btrfs filesystem, and open **Replace Btrfs Device…**. Verify the source ID and capacity, allocation and any missing or error indicators. Confirm the reviewed target matches the fixture and inspect the profile summary before authorization.
- Exercise desktop Polkit approval and denial. Close and reopen the dialog during a long fixture replacement and restart Majoris. Verify the kernel state and progress are rediscovered and that no new replacement is started. Check that cancellation is available only for the active reviewed operation.
- Verify the finished source ID is now associated with the target, the filesystem UUID is unchanged, and independently read the original fixture payload. For a larger target, compare the block-device capacity with Btrfs member capacity before attempting a separate resize.
- Run the existing Btrfs discovery and mount regressions with MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1.

The Debian 13 guest uses a temporary udev rule scoped to its three disposable backing files because UDisks defaults loop devices to HintSystem. This leaves the installed helper's safety rules in force. The guest run covered healthy, larger-target, surviving-copy, injected failing member, missing RAID 1, nonredundant, undersized, unsafe-target and cancellation scenarios. The kernel allocated new SINGLE groups during degraded recovery. Check the warning and resulting profiles alongside the verified target association and payload checksum.
