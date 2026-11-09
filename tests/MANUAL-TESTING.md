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

## Advanced LVM2

Use a dedicated disposable Debian 13 VM with `udisks2`, `udisks2-lvm2`, `lvm2` and `e2fsprogs`. Check that the UDisks manager exposes `org.freedesktop.UDisks2.Manager.LVM2`. Build as a normal user and install in the VM so the cache status inspector is at its configured path. Run the three opt-in tests as root in that VM.

    sudo env MAJORIS_DISKS_RUN_LVM_TESTS=1 meson test -C build --no-rebuild --print-errorlogs lvm-recovery-integration lvm-cache-integration lvm-layout-integration

- In Advanced Storage, select a VG, an LV and a physical-volume row. Verify that a missing PV is shown by UUID and that only LVs with evidence of incomplete allocation show a damage warning. Reconnect the fixture PV and use **Refresh and Reassess**.
- In a two-image RAID 1 fixture, unmount the degraded mapping and verify that only a separate PV with enough free extents can be selected. Confirm repair and check synchronization and the original data before accepting the result. A linear LV with a missing allocation has no repair action.
- Open **Remove Missing Physical-Volume Records** and confirm that Cancel makes no change. A damaged or unaccounted-for LV must block removal. Verify the remaining LV UUIDs after permitted removal.
- Rename an inactive VG and check that selection follows its UUID. Exercise rejection with an active mapping, an existing VG name and a persistent reference.
- Attach an empty cache candidate, write through the cached origin, then split it. Verify the pool remains. Repeat and remove the cache pool, then verify the origin and the writes. Try a candidate with a filesystem, a mount, or raw data.
- For explicit placement, compare the selected PVs with the backend's data and metadata components. Try duplicate devices and a layout with insufficient space on a single PV even when the VG has sufficient aggregate free space.

Record each scenario as passed, failed, skipped or not executed. Leave the fixture intact if a device identity becomes uncertain.
