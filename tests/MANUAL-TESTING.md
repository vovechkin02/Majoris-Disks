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

## Linux mdraid recovery and maintenance

Use a disposable Debian 13 QEMU guest named `majoris-mdraid-test`. Install
`mdadm`, `udisks2`, `util-linux`, `dmsetup` and the kernel RAID personalities.
Build as a normal user. Run the opted-in tests as root inside the guest.

```sh
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 \
    meson test -C build --no-rebuild --print-errorlogs 'mdraid-*'
```

The fixture uses image-backed loops and a unique array UUID. Its udev rules
identify only its loop images and array. It verifies ownership before cleanup
and stops with the remaining paths if ownership cannot be established.
Exit 77 is a prerequisite or opt-in skip.

- **STOR-10 and STOR-12**. Start and stop a disposable array. Review a clean
  degraded assembly and confirm the reported slot loss and array UUID. Test
  stopped-array deletion separately. Verify that dirty or inconsistent parity
  metadata, excessive losses and unknown RAID10 layouts prevent automatic
  degraded assembly.
- **STOR-11 and spare management**. Add an empty spare and verify its unassigned
  slot. Remove it through RAID Management and verify the array UUID, remaining
  slots and payload. Verify that an active or rebuilding member cannot be
  removed through the inactive-member action.
- **STOR-13 and STOR-14**. Replace one missing RAID1, RAID5 or RAID6 member. For
  RAID6 with two missing members, verify the first replacement synchronizes
  while the array remains degraded. Add the second and verify final redundancy.
- **RAID10**. Use an even-sized near-two array. Compare its layout and slot
  pairing with sysfs. Test loss of members in different pairs, then repeat
  with both copies of the same pair unavailable. The latter cannot reconstruct.
- **STOR-15**. Rate-limit a disposable rebuild, close Majoris, and restart it.
  Verify that the kernel action and progress reappear. Restart UDisks during
  the rebuild and verify the operation is observed without a second mutation.
  If the original replacement cannot be verified, check that the result is
  uncertain even when the kernel later reports an idle array.
- **Fault and re-addition**. Install the Majoris helper and policy. Review an
  eligible native two-member RAID1 and test authorization denial and approval.
  Compare the array UUID, member UUID, event count and slot with mdadm. Fault
  marking requires an idle, clean array with both copies present. Re-addition
  requires a former member with an eligible role and event counter. Check
  kernel promotion and payload after a successful re-addition.
- **Bitmap**. Enable and disable the internal bitmap on an idle healthy native
  redundant array. Compare the UDisks location and kernel policy. Repeat with
  external bitmap, journal, PPL and active synchronization fixtures and verify
  that changes are unavailable.
- **Check and repair**. Compare kernel progress and mismatch sectors with
  the management view. Cancel a Majoris-initiated check or repair and verify
  that an automatic rebuild does not expose that cancellation path. Review
  repair separately and verify that a missing terminal observation produces
  an uncertain result.

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

## Btrfs allocation-profile conversion

Use a dedicated Debian 13 guest with `btrfs-progs`, `udisks2`, `udisks2-btrfs`, Polkit and the built helpers installed at the configured libexec path. Enable the Btrfs module in the guest if UDisks does not load it by default.

```sh
sudo busctl --system call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager \
  org.freedesktop.UDisks2.Manager EnableModule sb btrfs true
sudo env MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS=1 sh \
  tests/btrfs-profile-conversion-integration.sh build/btrfs-profile-conversion-test combined
```

The script creates private image-backed loop devices and verifies the fixture UUID, member paths, profile rows and payload SHA-256. Repeat with `data`, `metadata`, `raid1c3`, `raid1c4`, `raid10`, `dup`, `reduce`, `workspace`, `unsafe`, `missing`, `interrupt`, `cancel` and `monitor`. A control test may observe completion before the control can be exercised. Record that outcome separately.

- In **Btrfs Maintenance**, confirm that the existing usage-filtered data and metadata balances still work. Open **Convert Allocation Profiles…** and check the UUID, member count, per-member workspace, allocation rows and current kernel status.
- Review distinct data and metadata targets. Check that the review includes system allocation with the metadata target and shows the contiguous-workspace budget. Go back from the review, verify the local review lock is released, then start again and cancel the authorization prompt. The allocation and kernel balance state should remain unchanged.
- On a redundant disposable fixture, review a lower-copy or lower-tolerance target and check for the stronger confirmation. Confirm it and independently verify the data, metadata and system rows with `btrfs filesystem df`.
- On a sufficiently long conversion, close and reopen the dialog. Observe live chunk counts, pause and review the saved targets before resuming. In a separate run, cancel the kernel balance, record the resulting profile sets and review a fresh soft conversion for any remaining groups.
- Check that read-only, missing-member, insufficient-member and insufficient-workspace fixtures are refused. Confirm that the dialog reports uncertain allocation if the helper or UDisks stops responding during a conversion. Rediscover actual kernel state before any further write.
- Exercise replacement with verified membership, recorded errors, and incomplete UDisks reconciliation. Only the fully verified outcome should receive the unqualified success message.

The `restart` case restarts UDisks between review and dispatch inside the guest and checks that the reviewed plan is refused. The `faults` case takes the Meson-built `libbtrfs-balance-faults.so` as the fourth script argument. It injects failures into a direct instance of the installed native helper using the same disposable fixture checks. Run both cases only in the dedicated guest.
## STOR-27 Btrfs quotas, qgroups and subvolume limits

In a disposable Debian 13 QEMU guest, load the UDisks Btrfs module, install the
Majoris helpers and Polkit policy from the build, install `libbtrfsutil1t64` for
the default-subvolume regression, and run the opt-in fixtures.
The native fixtures allocate their own loop devices and verify the backing
image, mounted source and filesystem UUID. The service fixture uses the guest's
mount namespace so UDisks can discover the mount.

```sh
sudo env MAJORIS_DISKS_RUN_BTRFS_QUOTA_TESTS=1 meson test -C build --no-rebuild --print-errorlogs \
  btrfs-quota-traditional-integration btrfs-quota-simple-integration \
  btrfs-quota-service-integration btrfs-quota-faults-integration \
  btrfs-quota-observer-restart-integration
```

Use a writable, non-system disposable Btrfs filesystem for desktop testing.
Open **Manage Btrfs Quotas** under the Btrfs filesystem, or **Quota Settings**
from a selected subvolume. Review and enable traditional quotas. Watch the
rescan job and confirm that a newly opened dialog reads current kernel status.
Check that the source and snapshot show referenced and exclusive bytes, and
that a shared snapshot is represented without double-counting it as physical
allocation. Create a higher-level group, assign an eligible child and check
both ends of the relationship. If the kernel marks accounting inconsistent,
rescan before setting another limit.

Use the limit editor to enter a whole number of bytes, KiB, MiB, GiB or TiB.
Confirm the warning for a limit below current usage. Verify that existing files
remain accessible and a subsequent over-limit write returns `EDQUOT`. Choose
**Unlimited** and verify the selected limit clears. Exercise both limit types
with traditional quotas.

To switch modes, review the limits and relationships in the disable confirmation
and authorize the disable. Then separately review and authorize enabling simple
quotas. Verify the first-owner label and that exclusive limits, hierarchy changes
and rescans are absent. Cancel authorization and verify the actual state remains
visible. When creating a subvolume or snapshot, choose **Review Quota Settings
After Creation** to open its stable level-0 ID. If quota configuration fails,
the newly created object remains available.


## Btrfs scrub

Use a disposable Debian 13 QEMU guest with the Btrfs kernel module, btrfs-progs
6.14, UDisks with its Btrfs module enabled, Polkit, and the installed Majoris
Btrfs helpers and policy. Live cases require `MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS=1`.
The fixture verifies loop backing files and mounted UUIDs before modifying them.

```sh
meson compile -C build
meson test -C build --print-errorlogs
sudo env MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS=1 \
    meson test -C build --no-rebuild --print-errorlogs 'btrfs-scrub-*'
```

The data and metadata cases map the target logical extent to both verified RAID1
members and compare the bytes before corrupting a single replica offline. The
single-copy case verifies an uncorrectable result. The cancellation case checks
that an altered checkpoint is rejected and that the restored checkpoint receives
a nonzero upstream resume timestamp. The client interruption case terminates
the client process, observes the active kernel scrub from a new client, restarts
UDisks, and checks the terminal history.

For the reboot case, run the following commands as root in the same disposable
guest. Save the exact private fixture directory printed by the prepare phase and
supply it to the verify phase after the guest boots. The fixture stays mounted
between prepare and reboot. The verify phase checks the boot ID, filesystem UUID,
resumption timestamp and payload hash before cleaning up.

```sh
export MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS=1
sh tests/btrfs-scrub-reboot-integration.sh /usr/libexec/majoris-disks-btrfs-default prepare
systemctl reboot
# After reboot, set the opt-in again and substitute the printed fixture directory.
export MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS=1
sh tests/btrfs-scrub-reboot-integration.sh /usr/libexec/majoris-disks-btrfs-default verify "$fixture"
```

For interactive acceptance, open **Btrfs Maintenance → Manage Scrub** on the
disposable mount. Review both modes and scopes. Use **Back** on the start
confirmation and verify the state stays idle. Start a rate-limited scrub, close
and reopen the dialog, then verify the member rows and byte counters. Confirm
cancellation, resume from the saved session, and open the detailed history. On
a writable mount the read-only confirmation should describe internal writes.
On the repair fixture, verify that a recovered read-only copy and a corrected
repair result have different messages. Check real-drive SMART/NVMe indications
separately from the fixture's Btrfs lifetime counters.

## Advanced mdraid release acceptance (11 November 2026)

Use only an isolated Debian 13 QEMU guest named `majoris-mdraid-test`. Install
the built application, restricted helper and generated MDRaid Polkit policy at
their configured paths. Do not substitute a root or SSH session for the desktop
tests. Record **Passed**, **Failed**, **Skipped** or **Not executed** separately
for each case. An unexpected error after fixture creation is a failure.

### Desktop authorization and dialog lifecycle

Log into GNOME as an ordinary administrator with an active authentication
agent and session D-Bus. Create an owned disposable two-member RAID1 using the
opt-in fixture. Record its UUID, each member UUID and slot, event counters,
disk sequences, `mdadm --detail --export`, `mdadm --examine --export`, sysfs
`array_state`, `sync_action`, `degraded` and the known payload checksum.
Open Advanced Storage → RAID Management and review fault marking of one
eligible member. Cancel the confirmation first: no helper invocation, changed
metadata, new successful job or remaining modification lock is permitted.

Repeat the review and approve the actual Polkit dialog. Verify the action is
`com.majoris.disks.mdraid-member-state` and the configured helper is invoked.
The resulting member must be faulty at the recorded slot, exactly one other
member must remain synchronized, degraded must equal one, and payload must
remain readable. Restore a fresh fixture for every destructive case.

Repeat with denial and prompt cancellation. Compare the recorded kernel state,
superblocks, slots and checksum. No mutation or successful job is permitted.
Close and reopen the dialog; a new review must be possible without a stuck
progress window or lock. Repeat after a fresh login (the policy uses
`auth_admin`, not permanent cached authorization). Invoke the same reviewed
helper request from an unauthenticated noninteractive normal-user session;
Polkit must refuse it. Record that separately from graphical acceptance.

While authorization is pending, separately remove the selected member, change
the array identity using a fresh disposable fixture, or start another operation
on the same dependency graph. Approving the old prompt must not modify a
substituted member or array. The helper must reject the stale UUID, slot, event
or disk sequence. Verify the actual kernel outcome if dispatch may have occurred;
only a definitively blocked request may say authorization changed nothing.

With the dialog open, stop/restart UDisks, then close/reopen the dialog. Observe
the same unique array UUID and current member rows, bitmap and sync action.
A missing/ambiguous array or changed kernel identity must disable all writes.
Exercise healthy, degraded, missing-slot and unknown-member presentations.
Check each replacement review and confirmation cancellation. A partially
recovered RAID6 must retain a degraded warning, and an unverifiable outcome
must never receive an unconditional completion message.

### Live recovery, layouts and device identity

```sh
export MAJORIS_DISKS_RUN_MDRAID_TESTS=1
sudo -E meson test -C build --no-rebuild --print-errorlogs \
  'mdraid-recovery-*' mdraid-member-bitmap-readd
```

For RAID4, execute `mdraid-recovery-raid4` explicitly. Require the same UUID,
intended replacement slot, in_sync states, idle synchronization, zero degraded
count and original checksum. RAID5 coverage is not RAID4 evidence. The model
test additionally refuses RAID4 with two missing slots and RAID10 with both
copies of a near-two pair missing. Run the near3, far2, offset2 and odd-count
RAID10 fixtures; record the actual sysfs layout and ensure automated replacement
is unavailable and the original payload is intact. Unknown layout metadata is
covered by the model; never reinterpret it as layout 258.

The disappearance/reuse fixtures capture a review, detach its owned empty
target, and optionally bind a new backing image to the exact same loop number.
The disk sequence must change and the old review must fail before AddDevice.
Check that the target has no md slot, degraded remains one and checksum matches.
Repeat manually while Polkit is pending and after accepted AddDevice; for the
latter record running/degraded/unknown state rather than claiming no dispatch.
Also remove a survivor, the md block object, and an array from the dialog in
separate throwaway fixtures. No stale controls or automatic retry are allowed.

### Reboot during active reconstruction

These explicit phases run inside the designated guest. Save the exact printed
directory. Prepare alone is not a passed reboot test. The record is root-owned,
private data, never executable shell. Do not edit it or reuse a different guest.

```sh
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-reboot-integration.sh \
  build/mdraid-service-test prepare
# Substitute the printed directory for "$fixture" in each following command.
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-reboot-integration.sh \
  build/mdraid-service-test reboot "$fixture"
# Reconnect after the guest boots.
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-reboot-integration.sh \
  build/mdraid-service-test verify "$fixture"
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-reboot-integration.sh \
  build/mdraid-service-test cleanup "$fixture"
```

Prepare independently requires `sync_action=recover` and the replacement in
slot zero. Verify requires a different boot ID, identical backing inodes and
member UUIDs, safe ordinary assembly, fresh read-only Majoris rediscovery,
both expected slots synchronized, idle state, zero degraded and SHA-256 match.
It accepts a rebuild completed during startup. The observer issues no AddDevice.
An identity mismatch stops the phase and retains evidence; inspect it before
any cleanup. Verification does not automatically delete persistent resources.
Meson can run verify only when `MAJORIS_MDRAID_REBOOT_MANIFEST` names a prepared,
already-rebooted fixture; otherwise the phased test is skipped.

### Stopped dirty/degraded parity refusal

Use the dedicated throwaway QEMU overlay. The following `crash` phase triggers
an abrupt reset of that guest, so finish other fixtures first. Repeat separately
for RAID5 and RAID6. Do not use normal mdadm stop as proof of dirty metadata.

```sh
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-dirty-stopped-integration.sh \
  build/mdraid-service-test prepare raid5
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-dirty-stopped-integration.sh \
  build/mdraid-service-test crash "$fixture"
# After reconnecting:
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-dirty-stopped-integration.sh \
  build/mdraid-service-test verify "$fixture"
sudo env MAJORIS_DISKS_RUN_MDRAID_TESTS=1 sh tests/mdraid-dirty-stopped-integration.sh \
  build/mdraid-service-test cleanup "$fixture"
```

Require dirty native metadata after reboot, absence of an assembled array,
service refusal and byte-identical backing images around the refused request.
No force assembly, event rewriting or `start_dirty_degraded` change is allowed.
Use clean degraded RAID1/5 start tests as positive controls. Unknown cleanliness,
event disagreement and missing parity membership must fail closed; capture
native metadata and the reason for each separately. If the crash fixture cannot
retain dirty metadata, mark it failed or not executed with the environmental
reason; never replace its evidence with the running dirty RAID5 case.

### Timeouts, helper interruption and final-state evidence

Run `mdraid-recovery-udisks-timeout` and `mdraid-recovery-helper-interruption`.
Their preload modules run only in the fixture client and are never installed.
Timeout coverage suppresses dispatch, then loses the reply after a real accepted
AddDevice. Both must produce needs-attention, one invocation and no automatic
retry. Independently inspect the absent target in the first case and synchronized
slot, zero degraded and checksum in the second. Helper cases inject pre-dispatch
rejection, cancel, deny, unknown exit and real SIGKILL immediately before/after
the restricted fault-marking ioctl. Cancellation/denial simulation is not
desktop Polkit evidence. Repeat D-Bus disconnection in disposable fixtures;
record accepted/running/completed/degraded/unknown from kernel evidence.

Run `mdraid-recovery-false-completion` for slot, faulty-member, UUID, unknown
action, read-only and degraded-state negatives. The full native reconstruction
test must additionally reconcile sysfs and UDisks; percent complete alone is
never sufficient. Healthy current state without matching historical member
identity may be displayed but cannot attribute an interrupted operation.

Install the built mdraid helper and its matching Polkit action in the disposable
guest. With `MAJORIS_DISKS_RUN_MDRAID_TESTS=1`, run the following Meson tests.

- `mdraid-member-readd-integration` checks the existing no-write workflow.
- `mdraid-member-bitmap-readd` writes 1 MiB at 8 MiB while degraded, requires an
  event gap greater than one, and records the survivor bitmap header and kernel
  reconstruction samples. The test requires actual member writes below the
  component size, the original member UUID and slot, both members in sync, zero
  degraded slots, idle synchronization, and a matching 16 MiB payload checksum.
- `mdraid-member-full-rebuild-control` uses a fresh empty replacement after
  bitmap review refuses the former member. It checks the same terminal health
  and checksum and requires writes at least as large as the component.
- `mdraid-member-bitmap-evidence-faults` injects bad bitmap evidence into the
  client reads and checks that the former member stays absent.
- `mdraid-member-readd-review-churn`, `-authorization-churn`, `-helper-churn`,
  `-reuse`, `-moved` and `-bitmap-changed` check that an expired review cannot
  attach the former member. The bitmap test changes only the helper's view of
  the evidence. The churn tests detach or move only fixture-owned loops.
- `mdraid-member-readd-interruption` terminates the helper before dispatch and
  after mdadm succeeds. It also simulates a success reply with no attached
  member to exercise the final-verification timeout. Require conservative
  result classification and independent checks of kernel state and payload.
- `mdraid-member-readd-post-attach-loss` fails and detaches the owned former
  member after observing recovery. `mdraid-member-readd-restart` restarts
  UDisks during observed recovery and verifies terminal health from a fresh
  client.

In RAID Management, activate the former-member row to verify eligibility. With
covered degraded writes, the confirmation should explain that the bitmap may
limit reconstruction and that redundancy returns after synchronization. Check
the active reconstruction and terminal messages separately.

The ordinary bitmap fixture restarts UDisks in both enabled and disabled states;
verify the UI also rediscovers each. External/unknown bitmap states stay
inspection-only and must not be rewritten after restart.

## Disk imaging

Use an isolated Debian 13 QEMU guest with owned disposable images. Install
UDisks, QEMU tools, Bubblewrap, nbd-client, fdisk, e2fsprogs and the installed
Majoris NBD helper and policy. Check that the guest's NBD module has
`max_part` greater than zero and that the test user has a systemd-managed
runtime directory. Module settings apply to the guest.

```sh
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
sudo env MAJORIS_DISKS_RUN_IMAGING_TESTS=1 XDG_RUNTIME_DIR=/run/user/0 \
  meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
  disposable-imaging-integration disposable-xz-integration \
  disposable-partition-image-integration disposable-partition-xz-integration \
  disposable-mbr-image-restore disposable-qcow2-restore disposable-vhd-restore \
  disposable-vhdx-restore disposable-nbd-integration virtual-image-conversion \
  virtual-image-growth native-xz nbd-helper
```

- Create a RAW backup and a RAW + XZ backup of an idle fixture. Check the
  logical size and SHA-256 with **Verify Disk Image**. Check that an existing
  destination survives a rejected backup and that cancellation before
  publication leaves the selected destination untouched.
- Restore to an owned larger disk and to one of two partitions. Compare the
  restored range, sibling partition, partition table and trailing bytes with
  the saved fixture. Repeat with XZ and virtual containers. A renamed virtual
  container presented as RAW must be rejected before the target is opened.
- Attach RAW through UDisks. Inspect `G_MESSAGES_DEBUG=all` for loop device
  number, disk sequence, autoclear, dependencies and the exclusive-open check.
  Verify mounted or held descendants block detachment, then unmount normally
  and verify the old loop generation disappears from the kernel and UDisks.
- Open XZ through **Attach Disk Image**, choose a new RAW destination and
  verify it attaches read-only after extraction. Compare logical SHA-256
  across the original XZ and the extracted RAW image.
- Attach VHD, VHDX, QCOW2 and compressed QCOW2 read-only. Verify the partition
  and filesystem and read a known file. Verify writable QCOW2 separately and
  confirm its change survives detachment and read-only reattachment.
- Interrupt a backup, conversion and disposable block restore after writing
  begins. Reopen Majoris and inspect the job's recovery record in
  `${XDG_STATE_HOME:-$HOME/.local/state}/majoris-disks/imaging`. For a block
  restore, compare the target with the saved fixture before authorizing a
  new restore. Review the named private work directory and destination for
  interrupted file publication.

Classify every result as **Passed**, **Failed**, **Skipped** or **Not executed**.
An unexpected failure after a fixture starts is a failure.

### Cross-subsystem release gate reruns

Run block-device scenarios only in the disposable Debian 13 QEMU guest.
Install the configured helpers, enable the UDisks Btrfs and LVM2 modules,
and verify that Polkit, loop, device mapper, and NBD with partition support
are available. Run the destructive cases serially. The test binary and
scripts must be readable and executable by the fixture account.

```sh
meson setup build
meson compile -C build
sudo meson install -C build --no-rebuild
meson test -C build --print-errorlogs

sudo env MAJORIS_DISKS_RUN_LOOP_TESTS=1 MAJORIS_DISKS_RUN_IMAGING_TESTS=1 \
  XDG_RUNTIME_DIR=/run/user/0 meson test -C build --no-rebuild --print-errorlogs \
  --num-processes 1 disposable-loop-integration 'disposable-*-restore*' \
  'disposable-*-imaging-integration' disposable-xz-integration \
  disposable-partition-image-integration disposable-partition-xz-integration \
  'disposable-interrupted-*-backup' disposable-nbd-integration \
  'disposable-nbd-*-termination' disposable-nbd-restore-target-loss \
  image-publication-directory-sync image-partition-discovery-delay \
  interrupted-virtual-image-conversion virtual-image-conversion-crash-recovery

sudo env MAJORIS_TEST_LUKS=1 MAJORIS_TEST_LUKS_RESIZE=1 MAJORIS_TEST_LUKS_RESTORATION=1 \
  meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
  --timeout-multiplier 3 luks-header-integration luks-resize-integration \
  luks-partition-resize-integration luks-mapping-restoration-integration

sudo env MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS=1 \
  meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
  'btrfs-profile-conversion-*'
```

- For the partition baseline, preserve the original 90 MiB request and its
  80 MiB backend limit in the test record. The revised fixture checks kernel
  starts and lengths and hashes the MBR partition prefixes before and after
  supported growth. Check the planner's rejection tests in `storage-model`.
- During RAW/XZ restore cancellation, the fixture reads the backing file
  independently before cancelling and checks the original tail after the
  backend stops. The source-disappearance case moves the source path after
  the first observed write. A lost rescan reply must leave one dispatch and
  a recovery record even when written bytes match.
- In the directory-sync fault test, compare final inode contents and verify
  that an existing destination survives. In the crash test, inspect the
  printed state and work directory before cleaning the owned fixture.
- Exporter interruption pins the fixture process by PID descriptor before
  termination. The target-loss case reads the first written bytes through
  the block device before terminating the exporter. The client-termination test requires an active foreground
  client. An established netlink mapping can have an exited setup process.
- For remaining live cases, capture the kernel disk sequence, backing
  inode, UDisks owner and object paths, attachment token, mount state,
  outcome and readback before releasing owned resources. Keep resources
  and evidence when their ownership or terminal state is uncertain.
