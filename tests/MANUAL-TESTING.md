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
