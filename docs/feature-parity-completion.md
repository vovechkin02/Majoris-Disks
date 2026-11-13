# Feature parity completion register


## Verified storage restoration

| Workflow | Implementation |
| --- | --- |
| Multiple mounts and bind mounts | The existing journal records ordered mount IDs, parents, source relationships, roots, targets, effective options, namespace, configuration, backend and observed outcome. UDisks handles a reproducible primary mount. The restricted helper handles eligible additional mounts and subdirectory exposures. Whole-filesystem mounts that share a superblock can be reproduced as nonrecursive clones because mountinfo does not retain how they were originally created. |
| Preparation and recovery | The helper independently checks device generation, ext4 UUID, mount IDs, target directories and covered inodes. It unmounts children before parents and verifies exclusive block access before maintenance. After a partial failure, the journal reconciles the observed state and restores steps that were removed. |
| Mount verification | Fresh kernel records verify filesystem identity, root, target, namespace, effective options, propagation and parent relationships. The journal accepts new mount IDs, detects additional mounts and reports verified and missing targets. Safely restored mounts remain available when another target fails. |
| Temporary LUKS closure | A matching readable LUKS header restore can temporarily close an active mapping. The header worker rechecks the backup and live header before preparation. The journal saves the backing identity, UUID, original cleartext object, mapper name and DM UUID, geometry, read-only state and crypttab record. Reopening requires an acknowledged Lock call and observed disappearance. The explicit Lock action retains its existing behavior. |
| Authorized reopening | The ordinary unlock action and recovery share the UDisks implementation and authorization. The parent job and storage lock cover preparation through verification. The worker checks the expected header fingerprint before reopening. A verified Majoris-managed crypttab keyfile is used through UDisks. Otherwise the GtkBuilder credential dialog accepts a passphrase or local keyfile and can be cancelled. Credentials stay out of the journal and command arguments. |
| Rebinding and reporting | The returned cleartext object must match the backing relationship, filesystem UUID and type, mapper name and DM UUID, read-only state and geometry. The journal and helper can reidentify it when its object path or device number changes. The result dialog lists the reopened mapping, verified mount locations and incomplete outcomes. |

The optional mount helper uses Debian 13 libmount to read mountinfo and Linux descriptor APIs for target resolution, detached mounts, attributes and attachment. Ordinary unmount uses a checked root-controlled path because Linux provides no descriptor-based ordinary unmount. The `com.majoris.disks.mount-restoration` Polkit action requires active administrator authorization. The client nominates a block number and primary mount ID. The helper derives and retains its own plan from kernel state and receives no client-selected source, target, filesystem type or options. It compares fstab without editing it. [Linux mount APIs](https://www.kernel.org/pub/linux/docs/man-pages/book/man-pages-6.12.pdf)

The new backend supports private, non-idmapped ext4 mounts in the verified system mount namespace. Helper-managed targets must be under root-controlled directories in `/mnt`. For multi-mount preparation, a supported UDisks primary can use its existing location below `/mnt`, `/media`, `/run/media` or `/srv`. Shared propagation, stacked mounts, unrelated child mounts, foreign namespace use, unsupported flags, unverified paths, active holders and ambiguous plans are rejected. Other filesystem types keep the existing single-mount path. Concurrent changes by other privileged services can still occur after validation. The checks reduce that window and recovery verifies actual state before reporting success.

Temporary LUKS closure supports plain, attached-header LUKS with one verified inner filesystem and the full reproducible mapping size. Unrecognized mapper names, external crypttab key handlers, nested storage stacks and detach-on-idle loops are excluded. An unverified header write leaves the mapping closed for manual recovery. A cancelled or rejected credential can leave the volume closed after a verified header restore. [UDisks encrypted-device interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Encrypted.html)

The attached GNOME Disks archive was reviewed for `gdu_utils_ensure_unused*`, fstab configuration, crypttab and passphrase authorization, and local job coordination. Majoris follows the dependency-first unmount/lock sequence and asynchronous error handling while reusing its configuration adapters and `StorageJobManager`. No additional GNOME C or UI source was copied.

On Debian 13.5 WSL with libmount 2.41.5 and the 6.18 WSL2 kernel, Meson setup, compilation and staged installation passed. The default suite passed 7 tests, skipped 15 opt-in cases and reported zero failures. The storage model covered semantic matching with new mount IDs, changed parents, namespace and filesystem identity. The GTK suite instantiated the plan dialog and checked the reopen dialog's initial response state. The native disposable suite passed ordinary, bind and combined layouts, semantic option and data checks, partial recovery after a busy unmount, symlink and propagation rejection, changed UUID, unexpected mount occupancy and targets outside the helper scope.



| Verification | Result |
| --- | --- |
| Native mount integration | Passed on disposable loop-backed ext4. The suite exercised ordinary mounts, subdirectory binds, a nested read-only bind, distinct per-mount flags, interrupted preparation, partial restoration, foreign namespace and stacked-mount rejection, propagation, UUID changes, target substitution, and unexpected target occupancy. |
| LUKS mapping integration | Passed through Majoris and private UDisks on disposable LUKS2. The suite exercised passphrase, keyfile and managed unlock, a different cleartext object path, credential cancellation, incorrect passphrase, mapper-name conflict, changed LUKS UUID and partial mount restoration. It verified data after the mapping and dependent mounts returned. |
| Existing storage regressions | The opt-in LUKS header, mapping resize, partition resize, and crypttab configuration suites passed. The crypttab suite also verified the original UDisks fstab single-mount workflow. |
| Desktop and daemon fault coverage | Pending verification on a stock Debian desktop with an interactive Polkit agent. Live authorization denial, daemon restart or timeout during unlock, and physical-device removal also remain untested. |

Added files include `src/mount-restoration-helper.c`, `src/mount-restoration-config.h.in`, `src/mount-restoration.vala`, `src/restoration-credential.vala`, `data/com.majoris.disks.MountRestoration.policy.in`, `data/ui/storage-restoration-plan-dialog.ui`, `tests/mount-restoration-integration.sh` and `tests/luks-mapping-restoration-integration.sh`.

Modified files include `meson.build`, `src/meson.build`, `data/com.majoris.disks.gresource.xml`, `src/kernel-storage-safety.vala`, `src/storage-operation.vala`, `src/udisks-service.vala`, `src/luks-header-worker.c`, `src/luks-credential-dialog.vala`, `src/drive-view.vala`, `src/window.vala`, `tests/storage-model-test.vala`, `tests/ui-template-test.vala`, `tests/luks-header-service-test.vala` and this register.

## Previous baseline for crypttab inspection and mount topology

| Area | Status | Scope |
| --- | --- | --- |
| Crypttab conflicts | Parser execution-tested | The inspector checks exact records, duplicate names, shared key references and octal-escaped aliases. The tests use an in-memory crypttab. |
| Protected configuration and keyfiles | Implemented, live authorization pending | The dedicated `com.majoris.disks.crypttab-inspect` action authenticates an active desktop requester as an administrator. The helper checks metadata with descriptor-relative `openat2` and rejects unsafe directory ownership, non-regular files, symlinks and multiple hard links. It compares a file identity stamp across checks and checks the fixed systemd implicit keyfile locations. It returns a finding and file identity metadata. UDisks handles secret reads and configuration writes. |
| Credential rotation and UI | Implemented, live verification pending | The existing keyslot verification and enrollment flow stays in place. The old slot remains active. A possible write or enrollment with an unverified outcome returns **Needs Attention** and shows details in the existing dialog. The editor explains that protected inspection may require authorization. |
| Mount topology and preparation | Parser execution-tested, restoration partial | The journal captures structured mountinfo records with mount and parent IDs, device number, root, decoded target, source, type, mount and superblock options, propagation fields, namespace, block object and matching fstab record. The common preparation path captures the dependency plan before its first mutation and rechecks the captured mount identity before unmounting. Existing single-mount UDisks restoration checks the semantic record after remount. |
| Multiple ordinary mounts and bind mounts | Unsupported | The parser recognizes these records. Automatic preparation still refuses multi-mount, bind, stacked and nested layouts. There is no privileged mount-restoration backend or supported cross-namespace path. |
| Reopening LUKS mappings during restoration | Unsupported | Existing inner-filesystem operations can restore a single eligible mount while the same verified mapping remains available. Mapping recreation, credential prompting for restoration and cleartext-object rebinding remain open. |

The helper inspects the system mount namespace for desktop requests. It cannot safely resolve unrelated crypttab key references that traverse symlinks and may therefore refuse an otherwise valid edit. Inspection and the subsequent UDisks write are separately authorized operations. The final inspection narrows the time in which another administrator can change configuration or keyfile identity. UDisks performs its own record match, but the two calls do not share a transaction. UDisks can unlink an old keyfile before recreating it during an update. The retained LUKS keyslot and the on-disk keyfile have separate failure modes. [UDisks configuration implementation](https://github.com/storaged-project/udisks/blob/udisks-2.10.1/src/udiskslinuxblock.c)

The attached GNOME source was reviewed for crypttab variant construction, protected configuration retrieval, configuration updates, passphrase changes, dependency preparation and local-job completion. This pass retains the attributed adaptation of `gdu_encryption_options_dialog_get_new_crypttab` and copies no additional GNOME source.

The opt-in private-namespace crypttab fixture now includes protected directory, shared reference, symlink, hard-link, missing file, inode replacement and unsafe directory cases. The fixture still requires a dedicated disposable VM. Ordinary-user Polkit allow and deny, live UDisks configuration and rotation, multi-mount restoration and LUKS mapping recovery were unexecuted in this follow-up.

Debian 13.5 WSL passed Meson setup, compilation and staged installation. The default suite passed seven tests, skipped 13 and reported zero failures. The passing cases included the new crypttab inspector parser, storage model, GTK templates and existing mock UDisks coverage. The staged installation verified that the inspector and its policy are packaged. It did not activate the policy or run the schema post-install hook.

Added files are `src/crypttab-inspector.c`, `src/crypttab-inspector-config.h.in`, `data/com.majoris.disks.Crypttab.policy.in` and `tests/crypttab-inspector-test.c`. Updated files are the root and source Meson definitions, `src/udisks-service.vala`, `src/kernel-storage-safety.vala`, `src/storage-operation.vala`, `src/window.vala`, `data/ui/encryption-options-dialog.ui`, `tests/storage-model-test.vala`, `tests/luks-configuration-integration.sh` and this report.


Source: Majoris Disks comparative audit, 8 November 2026. IDs follow source matrix order and are stable. This register separates source evidence from executed verification.

The baseline already provides filtered Btrfs balance, read-only scrub, restricted allocated-member removal, thin-pool expansion and eligible empty-pool deactivation/deletion, thin overcommit, ordinary and thin snapshot creation, and restricted two-member RAID1 recovery. Their lifecycle gaps are tracked below.

**Verification status:** Pending entries have no execution evidence for the corresponding acceptance case. Existing source paths are starting points for investigation.

## Encrypted storage follow-up

| Register ID | Implementation and status |
|---|---|
| SEC-01 | The editor selects an individual backend record, retains the device reference and existing options, and refreshes UDisks configuration before dispatch and after the write. Standard controls cover startup, failure handling and discard. Token, initramfs, special-device and external key entries are read-only. The service checks names and key references against system-wide crypttab and active mappings, rejects ambiguous records and validates managed paths and ownership. Ordinary desktop users can encounter a permission limit when system crypttab or existing keyfile metadata is inaccessible. |
| SEC-01, SEC-02, SEC-03 | The credential dialogs warn about automatic unlocking and link back to the configuration editor. Assisted rotation verifies the existing stored credential, adds and independently verifies a replacement in a free keyslot, then verifies the updated entry and stored credential through UDisks. Removing the previous keyslot is a separate operation. The configuration API supports text credentials. Binary keyfile round-tripping, token-managed rotation and boot-time unlocking remain outside the verified workflow. |
| FS-02, FS-03, FS-05 | The encrypted resize dialog separates backing, cleartext and filesystem capacities. The service checks the attached LUKS header, sector alignment, device-mapper identity and topology, UDisks capabilities, and each resulting capacity. It grows outside-in and shrinks ext4 offline inside-out. The optional backing stage handles primary partitions and plain active LVs. Bare mappings support growth. Nested stacks, bare shrink, unknown minima, detached headers, integrity and reencryption are excluded. |
| FS-10, SEC-06 | Partial. Preparation records a simple mount's namespace, kernel mount options, fstab records and encrypted backing identity. Restoration checks the full observed state. Multiple mounts and subdirectory bind mounts require manual preparation, and an unavailable cleartext mapping requires manual unlocking. The operation reports discrepancies and withholds automatic remount after an unverified resize. |
| Encrypted.Convert | Unsupported by the installed UDisks 2.10.1 backend. Native conversion first appears in UDisks 2.11. libcryptsetup 2.7.5 exposes conversion, but an authorised, backup-bound fallback with verified metadata compatibility and post-conversion recovery has not been demonstrated. Conversion is unavailable in the UI. [UDisks Encrypted API](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Encrypted.html) |

The crypttab variant construction adapts GNOME Disks' `gdu_encryption_options_dialog_get_new_crypttab` with its copyright attribution. The supplied `gdu_encryption_options_dialog_update`, `gdu-change-passphrase-dialog.c`, `gdu_utils_ensure_unused`, `gdu_utils_ensure_unused_list`, `gdu_utils_can_resize`, `gdu-resize-volume-dialog.c` and local-job sources were reviewed for configuration, dependency ordering, resize capability and completion patterns. The new operations use Majoris' existing planner, job manager, storage locks, preparation journal and credential worker.

Changed implementation files include `src/udisks-service.vala`, `src/storage-operation.vala`, `src/kernel-storage-safety.vala`, `src/window.vala`, `src/drive-view.vala` and `src/luks-credential-dialog.vala`. The GtkBuilder changes are in `drive-view.ui`, `encryption-options-dialog.ui`, `luks-keyslots-dialog.ui` and the new `encrypted-resize-dialog.ui`, registered in `data/com.majoris.disks.gresource.xml`. The root `meson.build` registers the new `luks-configuration-integration.sh` and `luks-resize-integration.sh` fixtures. The existing `ui-template-test.vala`, `storage-model-test.vala` and `luks-header-service-test.vala` cover the new code paths.

Debian 13.5 WSL validation used UDisks 2.10.1-12.1+deb13u2 and cryptsetup 2.7.5. Meson setup and compile passed. The default suite passed six tests with 13 opt-in skips and zero failures. The passing suite includes the storage model, GTK templates and the existing mock-backed UI cases.

The separate disposable LUKS1 and LUKS2 header regression run passed backup, restore, damaged-header recovery, keyslot lifecycle, binary-keyfile handling, descriptor authorization and injected header-write faults.

- **Execution-tested, SEC-01 and SEC-02.** The disposable LUKS2 configuration fixture ran with a private UDisks daemon, D-Bus address and configuration overlay. It verified invalid-credential refusal, automatic and manual entries on the same device, assisted rotation, stale-record and duplicate-name refusal, and removal. Both old and replacement credentials unlocked the container after rotation. Boot-time unlocking and a new crypttab-specific D-Bus mock or failure-injection matrix remain unverified.
- **Execution-tested, FS-02, FS-03 and FS-05.** A disposable ext4-on-LUKS mapping grew from 192 MiB to 240 MiB and shrank back to 192 MiB. A separate GPT fixture grew its partition from 256 MiB to 320 MiB and its cleartext mapping from 192 MiB to 272 MiB, then shrank both to their starting capacities. Both fixtures checked actual block sizes and file checksums after each resize. These fixtures exercised offline ext4 operations. The LV backing path, online growth and bare mapping growth are implemented but not execution-tested here. The test environment lacked the LVM command-line tools needed to provision a fixture.
- **Execution-tested subset, FS-10 and SEC-06.** The private daemon restored an ext4-on-LUKS fstab mount after a filesystem check. The fixture compared the actual source, target and mount options. It then verified that preparation refused an added subdirectory bind mount and left both mounts present. Replay of arbitrary multi-mount sets, reopening a closed mapping, swap restoration and cross-namespace restoration remain outside this verification.

## Persistent configuration and preparation recovery follow-up

| Register ID | Implementation | Verification | Final result |
|---|---|---|---|
| FS-08, FS-09 | `configure_mount` refreshes the snapshot under the storage operation lock before checking that the selected fstab entry still exists and the mount point is available. It retains the source reference, dump frequency and fsck pass number on edits. Verification accepts any matching entry with the requested fields. | Debian 13 build and default test suite. | Partial. Live fstab mutation, reconnection, and concurrent configuration changes from outside Disks remain unverified. |
| FS-10, SEC-06 | The journal records partially changed mount sets after an interrupted unmount, compares repeated paths by multiplicity, and revalidates stable device identity before restarting swap or restoring mounts. When UDisks remounts at a different location, the operation reports it and preserves the observed state. | `storage-model` mount restoration status and preparation device identity cases. | Passed model tests. Exact mount flags, bind mounts, multi-mount replay, and encryption mapping restoration remain open. |
| SEC-01 | The dialog and service restrict edits and removal of regular keyfiles to direct children of `/etc/luks-keys`. The service rejects keyfiles shared by multiple published crypttab entries and refreshes identity, configuration and protection checks immediately before dispatch. | `storage-model` crypttab keyfile scope case and `ui-templates`. | Passed model and template tests. Shared references absent from the UDisks snapshot, binary keyfile round-tripping, and live mapping reconciliation remain open. |

The supplied GNOME `gduutils.c` and mount options code were inspected for dependency preparation and fstab update patterns. This pass extends Majoris' existing journal and ConfigurationItem workflow. It adds no copied GNOME functions. The keyfile restriction follows the unlink behavior in [UDisks' crypttab update implementation](https://github.com/storaged-project/udisks/blob/master/src/udiskslinuxblock.c).

On Debian 13.5, `meson setup build/config-recovery`, `meson compile -C build/config-recovery`, and `meson install -C build/config-recovery --no-rebuild --destdir stage` passed. The staged install skipped the system schema post-install hook. `G_DEBUG=fatal-warnings meson test -C build/config-recovery --print-errorlogs` reported six passes, nine skips and zero failures. Passes were `storage-model`, `ui-templates` (including the existing mock UDisks LVM Poll fixture), `native-xz`, `nbd-helper`, `btrfs-default-helper`, and the file-backed `filesystem-capacity-integration`. Eight opt-in device tests and `virtual-image-growth` skipped. Live fstab and crypttab mutation, disposable-device writes, and physical hardware tests were not executed in this pass.

## 2. Feature-by-feature matrix: hardware discovery and information

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| UI-01 | Device/partition hierarchy | DisksWindow, StorageSnapshot, VolumeRow | Select advanced objects independently and retain the selection across refresh. | Majoris storage hierarchy | Linux feature | Implemented for VG, RAID and Btrfs selection | ui-templates advanced-navigation fixture | Selection, refresh, and fallback passed. Direct subvolume selection remains open. |
| UI-02 | Copy drive identifiers from information dialog | DriveInformationDialog, InformationRow | Make firmware revision and selected partition/filesystem identifiers copyable using GTK clipboard controls. | GTK clipboard API and GNOME drive information | Linux feature | Implemented in source | ui-templates, manual clipboard and narrow-layout checks | Template instantiation passed. Interactive clipboard and narrow-layout checks pending. |
## 3. Partition tables, partitions and file systems

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| FS-01 | Convert GPT↔MBR non-destructively | filesystem-resize.vala, filesystem-usage.vala, UDisksService | Windows GUI conversion requires empty disk; MBR2GPT.exe is separate | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Excluded from parity scope | Missing | Scope review | Windows GUI conversion requires empty disk; MBR2GPT.exe is separate |
| FS-02 | Resize filesystem with partition | filesystem-resize.vala, filesystem-usage.vala, UDisksService | Cross-filesystem coverage varies by OS | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Partial | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
| FS-03 | Online volume resize when possible | filesystem-resize.vala, filesystem-usage.vala, UDisksService | Majoris general partition path can consult UDisks; LVM offline ext limits | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Partial | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
| FS-04 | Move partition start physically | filesystem-resize.vala, filesystem-usage.vala, UDisksService | Not a core built-in parity obligation | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Excluded from parity scope | Missing | Scope review | Not a core built-in parity obligation |
| FS-05 | Partition-alignment and geometry safety | filesystem-resize.vala, filesystem-usage.vala, UDisksService | Actual live-device validation outstanding | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Implemented in source | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
| FS-06 | Multi-pass logical overwrite | UDisksService, StorageSanitizationReview, drive-erasure-dialog.ui | Three passes require reported rotational media | UDisks Block.OpenDevice | Linux feature | Implemented | sanitization-model, sanitization-overwrite-integration | Three-pass regular-file test passed. Rotational block-device acceptance and execution of the new cancellation-after-write fixture remain open. |
| FS-07 | ATA/NVMe hardware sanitize | UDisksService, drive-erasure-dialog.ui | Read-only capability and status inspection | UDisks Drive.Ata and NVMe.Controller | Linux feature | Partially implemented | sanitization-model | ATA inspection cross-checks direct PCI libata topology and identity. Trusted hardware execution remains open. |
| FS-08 | Configure fstab persistent mount | UDisksService, StoragePreparationJournal, mount-options-dialog.ui | Cross-platform equivalent: mount points/auto-mount | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Implemented, partial for edge cases | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
| FS-09 | Configure advanced mount flags/options | UDisksService, StoragePreparationJournal, mount-options-dialog.ui | Complete and verify the named lifecycle using the existing safety and job framework. | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Implemented with limits | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
| FS-10 | Restore multiple original mount points exactly | UDisksService, StoragePreparationJournal, mount-options-dialog.ui | Journaled restoration and reporting, but real complex cases untested | GNOME gduutils.c, gdu-resize-volume-dialog.c and UDisks Block/Filesystem | Linux feature | Partial | storage-model plus opt-in disposable filesystem fixture | Open. Acceptance case pending. |
## 4. Encryption, security and recovery

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| SEC-01 | Persistent crypttab encryption options | UDisksService, encryption-options-dialog.ui | Basic UDisks `ConfigurationItem` integration, full modes not verified | GNOME gdu-encryption-options-dialog.c, cryptsetup and UDisks Encrypted | Linux feature | Partial | Opt-in disposable encrypted-volume fixture | Open. Acceptance case pending. |
| SEC-02 | LUKS1 and LUKS2 keyslot lifecycle | Encryption menu, credential manager, UDisksService, libcryptsetup worker | List, add, change and safely remove supported credentials | GNOME passphrase workflow, UDisks Block.OpenDevice, libcryptsetup | Linux feature | Implemented for supported attached layouts | Debian 13 build, GTK templates, opt-in disposable devices | Verified on disposable LUKS1 and LUKS2 devices with live UDisks 2.10.1. |
| SEC-03 | LUKS2 token discovery | Credential manager and libcryptsetup worker | Show token types and slot associations | libcryptsetup token APIs | Linux feature | Discovery implemented | Disposable LUKS2 token fixture | Discovery and the token-bound mutation guard passed. Enrollment and token-only verification remain open. |
| SEC-04 | VeraCrypt multi-keyfile/PIM/hidden volumes | UDisksService, encryption-options-dialog.ui | Not a built-in feature of these GUIs | GNOME gdu-encryption-options-dialog.c, cryptsetup and UDisks Encrypted | Linux feature | Missing | Opt-in disposable encrypted-volume fixture | Open. Acceptance case pending. |
| SEC-05 | Encrypted disk-image creation | DiskImageCopy, UDisksService | Strong macOS image-workflow gap | GNOME gdu-encryption-options-dialog.c, cryptsetup and UDisks Encrypted | Linux analogue | Missing | Opt-in disposable encrypted-volume fixture | Open. Acceptance case pending. |
| SEC-06 | Persistent preparation/rollback reporting | StoragePreparationJournal, UDisksService | User-visible reconciliation; needs destructive integration tests | GNOME gdu-encryption-options-dialog.c, cryptsetup and UDisks Encrypted | Linux feature | Partial, sophisticated | Opt-in disposable encrypted-volume fixture | Open. Acceptance case pending. |
| SEC-07 | Data erasure warnings and target checks | UDisksService, StorageDependencyGraph, drive-erasure-dialog.ui | Typed confirmation, dependency checks, exclusive open, disk sequence and readback | UDisks Block.Format and Block.OpenDevice | Linux feature | Partially implemented | sanitization-model, sanitization-overwrite-integration | Logical overwrite distinguishes incomplete writing, failed flush or readback, and post-readback refresh or identity errors. Hardware scope and interactive authorization remain open. |
| SEC-08 | LUKS1 and LUKS2 header backup and recovery | Encryption menu, UDisksService, libcryptsetup worker | Portable raw header and manifest, locked-target restore and qualified damaged-header recovery | GNOME dependency preparation and jobs, UDisks Block.OpenDevice, libcryptsetup | Linux feature | Implemented for supported attached layouts | Debian 13 build, GTK templates, opt-in UDisks and loop fixtures | Verified on disposable LUKS1 and LUKS2 devices with live UDisks 2.10.1. |

### SEC-02, SEC-03 and SEC-08 implementation and limits

- GNOME Disks' supplied `gduutils.c` and `gdu-block-row.c` informed dependent-device preparation and encrypted-volume selection. The change-passphrase dialog informed current and replacement credential validation and its crypttab warning. The encryption options dialog and local-job sources informed configuration detection, asynchronous completion and error presentation. Majoris uses its own GtkBuilder templates, dependency graph, operation locks and jobs. The implementation adapts workflow behavior in Vala. [libcryptsetup 2.7.5 API](https://gitlab.com/cryptsetup/cryptsetup/-/raw/v2.7.5/lib/libcryptsetup.h)
- UDisks `Block.OpenDevice` supplies an authorized descriptor for the selected device. Restore and keyslot mutations require an idle volume and hold an exclusive read/write descriptor through readback. The unprivileged worker applies libcryptsetup operations to private metadata snapshots. Majoris verifies the reviewed device and header fingerprint immediately before writing. Once dispatch begins, the operation runs through readback without cancellation or automatic retries.
- The raw, mode-0600 backup remains usable with cryptsetup. Majoris publishes the raw header and its versioned `.majoris.json` companion exclusively, verifies both files and synchronizes their data and directory entries. If the raw header becomes durable before companion publication fails, Majoris reports the partial result. The manifest contains the header checksum, LUKS UUID and layout, capacity, logical sector size and a hashed source binding. The parser rejects unknown fields and schema versions. Keep both files together when moving a backup. Legacy xattr checksums and sizes remain readable. Raw backups receive structural checks and remain eligible for readable-header restoration when their critical metadata matches.
- Readable targets require matching UUID, LUKS layout, metadata extent and volume-key digest. Damaged targets require a supported layout, matching capacity and device identity, an idle storage stack and a probe that finds no conflicting signature. The dialog labels this device-identity-supported recovery and asks for typed confirmation. The manifest checksum detects accidental corruption and the device binding supports identity assessment. Neither authenticates provenance or proves the header decrypts the ciphertext. Ciphertext sampling and the legacy sample proof are no longer used. Raw and legacy backups without independently usable provenance receive an offline expert-recovery outcome for unreadable targets. Detached-header trial mapping would require additional scoped kernel authorization, so the application offers no strong damaged-header classification.
- The credential manager lists all keyslots, LUKS2 priorities and token assignments. It supports passphrases and regular binary keyfiles up to 1 MiB, including read-only credential verification that reports the keyslot opened. Passphrases are transmitted through private pipes, and the worker clears its credential buffers. Change requires a spare slot and confirms that the new credential unlocks the volume after a synchronized write before removing the original. Removal verifies the selected credential and a different usable slot, then checks the removed and retained slots on disk. Token-bound slots are managed by their own tools. The dialog warns about crypttab and historical backups.
- Detached headers, integrity, reencryption, unsupported LUKS2 layouts, protected system storage and stacked write targets remain outside scope. Token enrollment and token-only verification are outside the credential manager. Loop bindings depend on the backing file identity and byte range. Missing stable identifiers, replaced backing files or changes in the backing filesystem device number can prevent damaged-header recovery. The write phase is non-cancellable because interruption can leave partially modified metadata, especially on LUKS1.

### Verification on Debian 13

- Meson compiled the application, worker, and test targets with libcryptsetup 2.7.5. The default suite passed six tests, including the storage model and GTK templates, and skipped ten opt-in tests. GTK templates instantiated with the optional worker absent from its configured install path.
- The opt-in suite passed on disposable LUKS1 and LUKS2 loop devices with live UDisks 2.10.1. It exercised authorized backup, normal and damaged restore, unauthenticated descriptor denial, and authorized keyslot changes through credential pipes. Read-only credential identification exercised both a passphrase pipe and a keyfile. The worker cases checked changed ciphertext and ext4 data, byte-only transfer of the raw header and manifest, raw and legacy backups, wrong and stale targets, active mappings, unrelated signatures, multiple credentials, final-slot protection, binary keyfiles, and token association and mutation refusal. Fault injection covered short writes, an interrupted write, failed synchronization and a readback mismatch.
- Remaining verification includes an interactive Polkit authentication prompt, daemon loss during reconciliation, and physical-drive bindings across reboot or power loss. Both formats passed recovery after a loop reattachment with a changed kernel disk sequence and transfer through FAT32 verified to reject user xattrs. The FAT fixture uses an optional `MAJORIS_TEST_FAT_FORMATTER` executable.

### Files changed

- Native worker and build registration use `src/luks-header-worker.c`, `src/meson.build`, `meson.build`.
- Service and selected-volume UI changes are in `src/udisks-service.vala`, `src/window.vala`, `src/drive-view.vala`, `data/ui/drive-view.ui`, `data/ui/luks-header-backup-dialog.ui`, `data/ui/luks-header-restore-dialog.ui`, `data/com.majoris.disks.gresource.xml`.
- New credential dialog code and templates are in `src/luks-credential-dialog.vala`, `data/ui/luks-keyslots-dialog.ui`, `data/ui/luks-credential-dialog.ui`.
- Test changes are in `tests/luks-header-integration.sh`, `tests/luks-header-service-test.vala`, `tests/ui-template-test.vala`, and new `tests/luks-worker-faults.c`.

## 5. SMART, diagnostics, hardware controls and benchmarks

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| DIAG-01 | Optional write benchmark | DiskBenchmark, BenchmarkDialog | Majoris tests filesystem scratch writes rather than raw disk writes | GNOME gdu-benchmark-dialog.c and UDisks Drive.Ata/NVMe.Controller | Linux feature | Partial, scratch-file method | storage-model plus benchmark or hardware fixture | Open. Acceptance case pending. |
| DIAG-02 | Graph of benchmark across disk | DiskBenchmark, BenchmarkDialog.draw | Verify throughput and access-time graphs and their sample axes against the GNOME workflow. | GNOME gdu-benchmark-dialog.c | Linux feature | Partial | ui-templates plus live benchmark and visual graph check | Baseline has two GTK drawing areas and a result renderer. Live graph and comparison workflow verification pending. |
| DIAG-03 | Hardware RAID controller management | No vendor controller integration | Vendor-specific external tools | GNOME gdu-benchmark-dialog.c and UDisks Drive.Ata/NVMe.Controller | Excluded from parity scope | Not implemented | Scope review | Vendor-specific external tools |
| DIAG-04 | Discover already running self-tests on opening | UDisksService.synchronize_selftests, StorageJobManager | Reconstruct ATA and NVMe self-test jobs on restart and observe progress and completion. | GNOME gdu-ata-smart-dialog.c and UDisks Drive.Ata/NVMe.Controller | Linux feature | Implemented in source | Start a self-test, restart Disks and check the reconstructed job against a supported ATA or NVMe device. | Physical-device execution remains open. |
## 6. Disk images, backups and virtual disks

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| IMG-01 | Restore image directly to selected partition | DriveView, Window.choose_restore, UDisksService.restore_disk_image, DiskImageCopy | Restore only the reviewed partition range and verify readback and metadata refresh | GNOME restore_disk_image_dialog.rs, UDisks Block | Linux feature | Implemented and execution-tested for RAW and XZ | disposable-partition-image-integration, disposable-partition-xz-integration, disposable-mbr-image-restore | Runtime evidence below. |
| IMG-02 | Attach/detach VHD/VHDX | VirtualDisk, VirtualDiskAttachment, nbd-helper.c | Restricted, read-only NBD attachment with verified partition discovery | UDisks Block and QEMU image tools | Linux feature | Implemented and execution-tested read-only | disposable-nbd-integration | Partition, ext4 payload, busy-detach refusal and normal removal passed. |
| IMG-03 | Direct QCOW2 attachment | VirtualDisk, VirtualDiskAttachment, nbd-helper.c | Read-only default and explicit writable QCOW2 | UDisks Block and QEMU image tools | Linux feature | Implemented and execution-tested for self-contained images | disposable-nbd-integration | Read-only QCOW2, compressed QCOW2 and persistent writable QCOW2 changes passed. |
| IMG-04 | Change disk-image virtual size | VirtualDisk.write_image, UDisksService.require_detached_image, VirtualImageDialog | Grow a detached, self-contained RAW, VHD, VHDX or QCOW2 image. Verify the new capacity and copied data before publishing. | QEMU image tools and UDisks Block | Linux feature | Implemented and execution-tested as grow-to-copy | virtual-image-growth and ui-templates | The file fixture verified growth for all four formats. Interactive use and live attached-source exclusion remain open. |
| IMG-05 | Create image from folder/file selection | Separate filesystem image authoring | Populate an image from selected files | Scope review | Linux feature | Unsupported | Not executed | Open. |
| IMG-06 | Encrypted image creation | Separate encrypted image authoring | Create an encrypted image container | Scope review | Linux analogue | Unsupported | Not executed | Open. |
| IMG-07 | Sparsebundle/sparse-image workflows | DiskImageCopy.create_blank, VirtualDisk.write_image | Sparse RAW creation and conversion | GNOME gdu-create-disk-image-dialog.c and QEMU image tools | Linux analogue | Partially implemented | virtual-image-conversion, virtual-image-growth | Sparse RAW supported. Proprietary DMG and sparsebundle remain unsupported. |
| IMG-08 | Image conversion and compression | VirtualDisk.write_image, DiskImageCopy, VirtualImageDialog | Compare logical data before publication | QEMU image tools and liblzma | Linux feature | Implemented and execution-tested for supported pairs | virtual-image-conversion, virtual-image-growth, native-xz | RAW, VHD, VHDX, QCOW2, compressed QCOW2 and RAW + XZ workflows. Encrypted conversion is unsupported. |
| IMG-09 | Create/convert ISO/CD-master/hybrid | Separate optical authoring | Author ISO/CD-master/hybrid filesystems | Scope review | Linux feature | Unsupported | Not executed | Read-only inspection and attachment of existing ISO files are available. |
| IMG-10 | Filesystem-aware replication | Separate filesystem replication | Preserve files while omitting unused sectors | Scope review | Linux analogue | Unsupported | Not executed | Sector-based restore is covered under IMG-01. |
| IMG-11 | Standalone image attachment | Application.open, Window.confirm_attach_image, UDisksService | Open a local image and attach through UDisks or managed NBD | GNOME gdu-attach-disk-image-dialog.c and gdu-manager.c | Linux feature | Partially execution-tested | disposable-imaging-integration, disposable-nbd-integration, ui-templates | Backend attachment tested. Desktop launcher and optical-specific smoke testing remain open. |
## 7. Multi-disk, RAID, thin provisioning and filesystems

| ID | Feature | Existing implementation | Required behaviour | Reference | Applicability | Implementation status | Verification | Final result |
|---|---|---|---|---|---|---|---|---|
| STOR-01 | Resize plain LV | UDisksService, DriveView, StorageSnapshot | Bare growth and offline ext2/3/4 when safe | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Partial | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-02 | Thin pool expand/deactivate/delete empty | UDisksService, DriveView, StorageSnapshot | `change_thin_pool` newly in 054440 | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Implemented in current snapshot | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-03 | Thin volume create, activate, deactivate | UDisksService, DriveView, StorageSnapshot | Complete and verify the named lifecycle using the existing safety and job framework. | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Implemented restricted | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-04 | Thin volume grow/shrink/delete | UDisksService, DriveView, StorageSnapshot | Filesystem layouts and relationships restricted | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Partial | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-05 | Ordinary LVM snapshot create/delete | UDisksService, DriveView, StorageSnapshot | Complete and verify the named lifecycle using the existing safety and job framework. | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Implemented restricted | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-06 | Thin snapshot create/delete | UDisksService, DriveView, StorageSnapshot | Complete and verify the named lifecycle using the existing safety and job framework. | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Implemented restricted | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-07 | COW snapshot saturation warnings | UDisksService, DriveView, StorageSnapshot | No robust ordinary-snapshot COW lifecycle | UDisks LVM2 and the Majoris storage hierarchy | Linux feature | Partial/missing | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-08 | Missing LVM PV assessment and record removal | UDisksService, StorageVolumeGroup, LvmStructure, DisksWindow | Report missing UUIDs and allocation gaps, reassess on demand and remove records only when all retained allocations can be verified. | UDisks LVM2 | Linux feature | Restricted implementation | storage-model, GTK navigation and mock Poll, opt-in recovery fixture | Model and mock coverage. Live removal and reconnect acceptance remain open. |
| STOR-09 | LVM repair and advanced administration | UDisksService, LvmStructure, LvmLayout, DisksWindow | Repair eligible two-image RAID 1, rename inactive VGs, manage verified clean caches and create supported layouts with explicit placement. | UDisks LVM2, scoped LVM cache report | Linux feature | Restricted implementation | storage-model, GTK templates and capability mock, opt-in recovery/cache/layout fixtures | Live backend acceptance remains open. |
| STOR-10 | Start/stop/delete mdraid array | UDisksService, StorageJobManager, DriveView | Existing lifecycle and protection checks | UDisks MDRaid | Linux feature | Implemented but not execution-tested in this pass | Manual lifecycle acceptance | Covers normal assembly, stop and deletion. |
| STOR-11 | Remove inactive spare/faulty member | UDisksService, StorageJobManager, RAID Management | Verify the remaining kernel members and unchanged degraded count | UDisks RemoveDevice, md sysfs | Linux feature | Implemented and execution-tested for inactive spares | mdraid-member-integration | Faulty-member removal needs separate acceptance. |
| STOR-12 | Guided degraded RAID1 start | UDisksService, StorageJobManager, RAID Management | Read and compare native superblocks before assembly | UDisks Start, native md metadata | Linux feature | Implemented and execution-tested | mdraid-recovery-start-raid1 | Clean, consistent native metadata required. |
| STOR-13 | Replace missing RAID1 member | UDisksService, StorageJobManager, RAID Management | Verify reviewed geometry, target slot and final synchronization | UDisks AddDevice, md sysfs | Linux feature | Implemented and execution-tested | mdraid-recovery-raid1 | Loop-backed two-member RAID1 with payload checksums. |
| STOR-14 | Parity RAID5/6 degraded replacement | UDisksService, StorageJobManager, RAID Management | Verify the surviving slots and clean parity metadata. Replace one missing slot per operation. | UDisks AddDevice, md sysfs | Linux feature | Implemented and execution-tested | mdraid-recovery-raid5, mdraid-recovery-raid6, mdraid-recovery-raid6-double | One missing RAID5 member and one or two missing RAID6 members. |
| STOR-15 | Rebuild progress and restart reconciliation | UDisksService, StorageJobManager, RAID Management | Poll kernel progress and rediscover active jobs by array UUID and kernel identity | UDisks MDRaid, md sysfs | Linux feature | Implemented and execution-tested for active rebuilds | mdraid-recovery-restart-raid1 | A new client observes the kernel rebuild after client exit and a UDisks restart. The reviewed replacement plan is held in memory. |
| MDRAID-01 | RAID10 degraded replacement | UDisksService, RAID Management | Check both slots of each mirror pair | UDisks AddDevice, md sysfs | Linux feature | Implemented and execution-tested | mdraid-recovery-raid10, mdraid-model | Even-sized near-two arrays with layout 258. Other layouts are intentionally restricted. |
| MDRAID-02 | Add and remove spare | UDisksService, RAID Management | Verify an empty target, an unassigned spare role and final kernel membership | UDisks AddDevice and RemoveDevice | Linux feature | Implemented and execution-tested | mdraid-member-integration | Idle, synchronized redundant array for addition. |
| MDRAID-03 | Internal write-intent bitmap | UDisksService, RAID Management | Compare daemon and kernel state and verify array health after the change | UDisks SetBitmapLocation, md sysfs | Linux feature | Implemented and execution-tested | mdraid-bitmap-integration | External bitmap, PPL and journal settings are inspection only. |
| MDRAID-04 | Redundancy check and repair | UDisksService, StorageJobManager, RAID Management | Display mismatch sectors and confirm repair separately. Stop only a matching check or repair. | UDisks RequestSyncAction, md sysfs | Linux feature | Implemented and execution-tested | mdraid-maintenance-integration | Check cancellation, nonzero mismatches, repair and a clean follow-up check. Client results remain uncertain when terminal evidence is missing. |
| MDRAID-05 | Member fault marking and re-addition | UDisksService, restricted helper, RAID Management | Revalidate UUID, slot, disk sequence and native superblock event counters after authorization | Restricted Polkit helper, kernel fault ioctl and fixed mdadm re-addition | Linux feature | Implemented and execution-tested through the helper | mdraid-member-integration, mdraid-member-readd-integration | Idle, clean, native two-member RAID1 only. Desktop authorization needs separate acceptance. |
| STOR-16 | Concatenated JBOD disk set UI | UDisksService, StorageJobManager, DriveView | Linux analogue: MD linear or concatenated LVM | UDisks MDRaid, mdraid and LVM2 | Linux analogue | Missing explicit | storage-model plus opt-in LVM or mdraid fixture | Open. Acceptance case pending. |
| STOR-17 | Btrfs subvolume list/create/delete | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | Btrfs not equivalent to APFS volumes | Linux Btrfs ioctls and btrfs-progs | Linux feature | Implemented restricted | btrfs-default-helper plus opt-in Btrfs fixture | Open. Acceptance case pending. |
| STOR-18 | Btrfs writable/read-only snapshots | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | Complete and verify the named lifecycle using the existing safety and job framework. | Linux Btrfs ioctls and btrfs-progs | Linux feature | Implemented restricted | btrfs-default-helper plus opt-in Btrfs fixture | Open. Acceptance case pending. |
| STOR-19 | Btrfs remove allocated member | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | Limited to single/DUP and conservative capacity test | Linux Btrfs ioctls and btrfs-progs | Linux feature | Partial | btrfs-default-helper plus opt-in Btrfs fixture | Open. Acceptance case pending. |
| STOR-20 | Btrfs replace present or missing member | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | Authorized replacement of a verified source ID on an empty whole-device target. Missing-member recovery requires verified RAID 1 throughout. | Linux Btrfs ioctls and UDisks | Linux feature | See replacement validation below | Native helper, model, GTK template and opt-in loop fixtures | Physical failing-device behavior and desktop authorization require further validation. |
| STOR-21 | Btrfs balance filtered data/metadata | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | Kernel ioctl + Polkit; restricted usage filters | Linux Btrfs ioctls and btrfs-progs | Linux feature | Implemented restricted in current ZIP | btrfs-default-helper plus opt-in Btrfs fixture | Open. Acceptance case pending. |
| STOR-22 | Btrfs balance pause/resume/cancel/status | UDisksService, btrfs-default-helper.c, btrfs-inspect.c | No automatic persistent progress reconstruction | Linux Btrfs ioctls and btrfs-progs | Linux feature | Implemented in source | btrfs-default-helper plus opt-in Btrfs fixture | Open. Acceptance case pending. |
| STOR-23 | Btrfs balance profile conversion | UDisksService, btrfs-default-helper.c, Btrfs Profile Conversion | Verified online data, metadata and system conversion using typed targets, contiguous workspace checks and saved kernel balance controls | Linux Btrfs balance, space and device-tree ioctls; UDisks2; Polkit | Linux feature | Implemented with restrictions | Native, model and GTK tests plus Debian 13 disposable-device scenarios | See profile-conversion validation below. |
| STOR-24 | Btrfs read-only scrub, live status and cancellation | Btrfs Scrub, UDisksService, restricted native helper | Whole filesystem or a verified member. Per-member counters and filesystem-wide kernel cancellation. | btrfs-progs 6.14 and Linux Btrfs ioctls | Linux feature | Implemented and execution-tested | Debian 13 disposable scrub, mount and service fixtures | Independent kernel monitoring also detects external scrubs. |
| STOR-25 | Btrfs scrub repair, checkpoint resume and history | Btrfs Scrub, UDisksService, restricted native helper | Verified repair outcomes, restart recovery and bounded per-filesystem history | btrfs-progs 6.14 checkpoint and protected Majoris history | Linux feature | Implemented and execution-tested within the restrictions below | Disposable data and metadata corruption, cancellation/resume, client exit and guest reboot | See Btrfs scrub lifecycle below. |
| STOR-26 | Btrfs capacity profile-aware usable-space estimate | UDisksService, btrfs-inspect.c, Btrfs Allocation | Separates kernel logical capacity and available-space estimate from verified Btrfs member allocation | Linux Btrfs ioctls, sysfs and statvfs | Linux feature | Partially implemented | Native Btrfs discovery fixture and storage-model | Parity overhead and future chunk placement remain unknown. |
| STOR-27 | Btrfs quotas/qgroups/subvolume limits | UDisksService, Btrfs Quotas, Btrfs Subvolumes, native Btrfs helpers | Filesystem and subvolume quotas | Btrfs quota tree, quota control, rescan and qgroup ioctls | Linux analogue | Implemented and execution-tested for native quota management | Opt-in traditional and simple quota fixtures on Debian 13 QEMU | See the capability breakdown below. |
| STOR-27a | Btrfs mounted member and profile discovery | UDisksService, btrfs-inspect.c, Btrfs Allocation | Reports kernel-confirmed missing IDs separately from verified device numbers and keeps every reported profile row | Btrfs FS_INFO, DEV_INFO and SPACE_INFO ioctls and sysfs | Linux feature | Partially implemented | Healthy and read-only degraded RAID 1 discovery executed through the native probe | Desktop rendering, active replacement source identity and other degraded topologies remain open. |
| STOR-28 | Direct selectable VG/LV/RAID/Btrfs objects | DisksWindow, StorageSnapshot.advanced and StorageSnapshot.blocks, window.ui | Select VGs and LVs directly, open PV details from the member list and retain existing RAID and Btrfs navigation. | UDisks LVM2, MDRaid and Btrfs filesystem metadata | Linux feature | Implemented in source | ui-templates advanced-navigation fixture | GTK selection covers missing-PV UUIDs and inactive LV details. Live topology checks remain open. |

## GNOME source adaptation

The partition action in `DriveView` adapts the target routing in `src/disks/gdu-block-row.c:restore_partition_image_cb` from the supplied GNOME archive. The local adaptation retains the upstream copyright and GPL-2.0-or-later attribution. The GNOME Rust restore dialog was inspected for the prepare, open, write and rescan sequence. Majoris continues to use its existing restore backend and storage jobs.

The configuration fixes also reference GNOME's `gdu-mount-options-dialog.c` and `gdu-encryption-options-dialog.c`, including its use of UDisks to fetch existing protected key material. This pass adds no copied GNOME functions.

## Follow-up implementation evidence

| Register ID | Changes in this pass | Remaining acceptance |
|---|---|---|
| FS-08, FS-09 | The mount dialog retains the entries it displayed even if UDisks refreshes the device. The backend rejects a stale entry, preserves its existing device reference, dump frequency and fsck pass number, and checks those fields after UDisks updates the entry. New entries use UUIDs. | Verify add, edit, remove, multiple mount points and reconnection using a disposable UDisks fixture. |
| SEC-01 | The encryption dialog retains the selected entry across refresh. A rename looks up protected key material using the original mapping name. Removal skips the secret read and warns when UDisks also deletes the keyfile. Existing device references are retained. The dialog and service share crypttab-specific validation for startup options and reject `swap` and `tmp`, which could overwrite mapped data. | Verify with disposable LUKS mappings. UDisks updates rewrite a regular keyfile and cannot safely round-trip device-backed key references through this editor. The UI disables edits of those references. Binary/shared keyfiles and live mapping reconciliation still require separate coverage. |
| IMG-01 | Restore checks the target and its upstream devices for the source backing-file inode, including when the selected target is a partition. The service repeats the check after preflight and checks cancellation before preparing the device. | Successful RAW and XZ writes and readback on a disposable partition, and mid-write cancellation, remain open. Both opt-in tests on Debian WSL returned `NotAuthorizedCanObtain` during source loop setup. |

The follow-up build on Debian 13.5 passed, as did the staged install. The default Meson run passed six cases and skipped eight. `storage-model` includes the new crypttab option checks. `ui-templates` includes regressions for the fstab and crypttab dialog selections after a model refresh, and for rejecting a partition's parent backing file as the image source. These tests use model objects and a temporary file. They do not exercise live configuration writes or a partition restore. The two opt-in failures retained fixtures under `/tmp/majoris-image-devices-4JSNY3` and `/tmp/majoris-image-devices-F5ZNY3`.

## Release gates

- **REL-01 — Passed.** Debian 13.5 in WSL, Meson 1.7.0, Vala 0.56.18, GTK 4.18.6 and libadwaita 1.7.6. Ran `meson setup build/parity-validation`, `meson compile -C build/parity-validation`, `meson test -C build/parity-validation --print-errorlogs` and a staged `meson install`. The build emits warnings. Staging does not execute the installed schema post-install hook.
- **REL-02 — Open.** Run the outstanding feature-specific disposable-device workflows and verify data integrity.
- **REL-03 — Open.** Physical sanitisation execution and acceptance remain outstanding.

| Hardware sanitisation capability | Status | Evidence or remaining work |
| --- | --- | --- |
| ATA normal Security Erase | Partially implemented | Duration, frozen state and direct transport inspection. Dispatch is disabled. |
| ATA enhanced Security Erase | Partially implemented | Separate enhanced-duration evidence and the same transport and frozen-state checks. Dispatch is disabled. |
| NVMe Sanitize Block Erase | Unsupported | SANICAP and trusted subsystem review are pending. |
| NVMe Sanitize Crypto Erase | Unsupported | SANICAP and trusted subsystem review are pending. |
| NVMe Sanitize Overwrite | Unsupported | SANICAP, trusted subsystem review and explicit single-pass dispatch are pending. |
| NVMe complete-subsystem scope | Unsupported | Complete namespace inventory, attachment and dependency validation are pending. |
| Hardware restart reconciliation | Unsupported | The existing NVMe status is historical controller information. Per-request persistent evidence and reconciliation are pending. |
| Hardware execution authorization | Unsupported | A restricted Polkit broker and privileged post-authorization checks are pending. |
| SCSI SANITIZE and NVMe Format secure erase | Unsupported | Execution remains outside the current scope. |

### Data erasure method status

| Method | Scope and prerequisites | Dispatch, evidence and recovery | Classification |
| --- | --- | --- | --- |
| Quick format | Existing disk or volume formatting eligibility | UDisks Block.Format creates the requested layout. Existing job monitoring applies. | Preserved |
| Format with zero overwrite | Existing disk or volume formatting eligibility | UDisks Block.Format with `erase="zero"` writes accessible blocks before formatting. The format path reports UDisks completion. | Preserved |
| One-pass logical overwrite | Whole eligible disk or Majoris-managed loop, with a known and idle dependency set | UDisks-authorized exclusive, synchronous, direct-I/O descriptor. Flushes and reads the full logical range. Cancellation can leave partial writes. An interrupted operation record requires review at restart. | Implemented and execution-tested on a QEMU loop fixture |
| Three-pass logical overwrite | Whole eligible disk with a positive drive rotation rate and a rotational kernel queue | Same exclusive descriptor. Writes `0x55`, `0xAA` and zeros, flushing each pass and reading back the final pass. | Implemented but not execution-tested on rotational block media |
| ATA normal and enhanced | Requires direct ATA identification, command-specific support and verified whole-drive scope | Displays UDisks duration and frozen-state evidence where available. Privileged revalidation, dispatch and monitoring remain open. | Partially implemented |
| NVMe Sanitize block, crypto and overwrite | Requires positive action capability and a complete NVM subsystem scope | Displays the current UDisks controller status and reported progress where available. Dispatch and operation-specific reconciliation remain open. | Partially implemented |
| NVMe Format SES 1 and 2 | Requires verified FNA scope, namespace identity and unchanged LBA, metadata and protection settings | Capability discovery, scope verification and dispatch remain open. | Unsupported |
| SCSI SANITIZE block, crypto and overwrite | Requires positive service-action support and verified LUN identity and access paths | Capability discovery, dispatch and sense-based reconciliation remain open. | Unsupported |

Logical readback covers exposed LBAs. Remapped sectors, inaccessible flash, reserved space and other controller-managed regions may retain data.

#### Implementation and validation

- Added `storage-sanitization.vala` for method, scope, capability and review types and the asynchronous overwrite worker. `storage-sanitization.c` and its header compare the opened loop's kernel backing device and inode to the reviewed file. The C function only queries the descriptor.
- Extended `device.vala`, `safety.vala`, `udisks-service.vala` and `disk-image-copy.vala`. Review binds UDisks identity, capacity, kernel disk sequence and affected block devices. The service checks kernel partitions, mounts and holders, obtains the existing application lock, and revalidates after UDisks authorization while holding the exclusive descriptor. It refreshes device metadata after writing. The existing private journal mechanism stores interrupted-overwrite evidence under the sanitization state directory. Recovery presents the record for review and never replays an overwrite.
- Updated `drive-view.vala`, `window.vala`, the drive view and format disk GtkBuilder templates, and the resource manifest. The dedicated erasure dialog inherits the Majoris theme. Its operation record shows the affected devices, kernel disk sequence, times, requested and flushed passes, bytes written and bytes verified.
- Reviewed `gdu-format-disk-dialog.c`, `gduutils.c`, `gdu-job-manager.c`, `gdulocaljob.c` and `gdu-job-row.c` from the supplied GNOME source for capability evidence, duration, preparation and job presentation. The implementation uses Majoris' existing dependency and job services. The protocol references were the [UDisks ATA interface](https://storaged.org/doc/udisks2-api/2.11.0/gdbus-org.freedesktop.UDisks2.Drive.Ata.html), [UDisks NVMe controller interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.NVMe.Controller.html), [libnvme protocol types](https://github.com/linux-nvme/libnvme/blob/master/doc/rst/types.rst) and [sg3_utils SANITIZE source](https://github.com/hreinecke/sg3_utils/blob/master/src/sg_sanitize.c).
- Registered the sources and tests in Meson and extended the GtkBuilder template test. On Debian 13, `meson setup /tmp/majoris-sanitization-build .`, `meson compile -C /tmp/majoris-sanitization-build` and `meson test -C /tmp/majoris-sanitization-build --print-errorlogs` exited 0. The suite reported 18 passed, 124 skipped and zero failures, including the GtkBuilder and sanitization model test among the passes.
- In the Debian 13.7 QEMU guest, `sudo env MAJORIS_DISKS_RUN_SANITIZATION_TESTS=1 sh ./sanitization-overwrite-integration.sh ./sanitization-model-test` exited 0. Incorrect confirmation preserved the known data. The approved one-pass operation wrote and verified all 4,194,304 bytes of its backing file, and an independent file comparison found the sibling unchanged.
- The same guest passed `sudo env MAJORIS_DISKS_RUN_LOOP_TESTS=1 sh ./disposable-loop-integration.sh` and `sudo env MAJORIS_DISKS_RUN_IMAGING_TESTS=1 ./image-device-test` with and without `--xz`. This covered fixture partition, filesystem and loop operations plus RAW and XZ imaging. The other opt-in storage-stack regressions and interactive Polkit checks remain unexecuted.
- Release gaps include privileged hardware dispatch and authorization, controller/namespace/LUN scope proof, hardware progress and restart reconciliation, protocol fault injection, live three-pass and cancellation-after-write acceptance, and sacrificial-device acceptance. Read-only ATA property tests use synthetic inputs. They provide no physical erasure evidence.
- **REL-04 — Open.** End-to-end safety, interactive authorization, jobs, reconciliation and independent advanced-object navigation remain incomplete.

### Executed tests

| Result | Cases |
|---|---|
| Passed | `native-xz`, `nbd-helper`, `btrfs-default-helper`, `storage-model`, `filesystem-capacity-integration`, `ui-templates` (includes the mock UDisks LVM Poll call and deterministic restore-target identity regression). |
| Skipped on the default run | `disposable-btrfs-mount-integration`, `filesystem-capacity-udisks`, `disposable-imaging-integration`, `disposable-xz-integration`, `disposable-partition-image-integration`, `disposable-partition-xz-integration`, `disposable-nbd-integration`, `disposable-loop-integration`. |
| Failed in opt-in runs | Both partition restore variants hit `NotAuthorizedCanObtain` under the headless WSL account before attaching their source loop device. A privileged run exposed nondeterministic device identity serialization. It also exposed that WSL UDisks flagged a disposable loop source as system storage (`HintSystem=true`), so application safety refused to detach it. No partition write was reached. |
| Not executed | Successful live partition restore/readback, mid-write cancellation, manual clipboard and narrow-layout validation, and physical-device diagnostics. |

The identity fix passes scalar offset and partition number values into the GVariant tuple. With the prior nullable expressions, generated C passed boxed pointers for those fields. The rebuilt default suite passed. A successful partition restore in a suitable live UDisks environment remains outstanding. The failed privileged runs retained two read-only source fixtures under `/tmp/majoris-image-devices-ZD2MY3` and `/tmp/majoris-image-devices-ZGIZY3`.

## Benchmark and image-launcher follow-up

| Register ID | Implementation | Verification | Final result |
|---|---|---|---|
| DIAG-02 | `DiskBenchmark.measure_sync` records the normalized device offset of each throughput and latency sample. `BenchmarkDialog` plots those positions, persists them with the results, and shows sample counts, units and summary statistics. Older saved measurements retain their statistics. | `storage-model` exercises real reads from a temporary file and checks sample counts, read endpoints and sector alignment. `ui-templates` instantiates the updated dialog. | Passed those tests. Physical-device measurements, interactive chart inspection and cancellation remain open. DIAG-01 still covers scratch-file writes and the separate raw device-write request. |
| IMG-11 | The installed Disk Image Mounter desktop entry registers optical and raw image types and opens a single local file in the existing Disks process. The same confirmation is used from the picker and external launch. ISO files only offer read-only attachment, which the UDisks service wrapper also enforces. | Staged Meson install, `desktop-file-validate` and an isolated Xvfb and D-Bus CLI smoke test. | The staged desktop entry validated. A single path containing spaces launched the application. Two paths returned status 2. Live attachment through a file manager and UDisks remains open. |

The benchmark adapts repeatable seeded access sampling and position-based plotting from GNOME Disks' `gdu-benchmark-dialog.c`. The sampling adaptation retains upstream attribution. The launcher follows the file-open pattern in GNOME's `src/disk-image-mounter/application.rs` and uses Majoris' existing confirmation, UDisks authorization and verified loop setup.

This follow-up built on Debian 13.5 with `meson setup build/audit-current`, `meson compile -C build/audit-current` and `meson test -C build/audit-current --print-errorlogs`. The six default tests listed above passed again, including the existing mock UDisks and native helper checks. The same eight opt-in cases skipped. The staged install passed. The isolated graphical smoke emitted an Adwaita warning that the navigation split view requested 665 pixels at a width of 640. No physical-device or destructive disposable-device operation was run in this follow-up. Full parity and release acceptance remain open.

## Virtual image growth and compression

The **Grow a Copy…** action uses the existing Bubblewrap-isolated QEMU backend. It creates a larger image in the source format, copies guest-visible sectors, and checks that extra sectors read as zero. It reopens the output to verify format and capacity before publishing without replacing any file. The dialog explains that the partition and filesystem sizes stay the same. Shrink, backing chains, external data files and internal snapshots are excluded from the workflow. The source stays open read-only and the backend checks its identity again before publishing. The application checks for loop and Majoris-managed NBD attachments through UDisks before copying and again before publication. [QEMU image tool documentation](https://www.qemu.org/docs/master/tools/qemu-img.html)

The **Compress QCOW2 data** switch passes QEMU's compression option when converting to QCOW2 and verifies guest-visible sectors before publishing. No new GNOME functions were copied or adapted in this pass. The changes use the existing optional `qemu-utils` and Bubblewrap dependencies.

On Debian 13.5, `meson compile -C build/feature-closure` and a staged `meson install` passed. `meson test -C build/feature-closure --no-rebuild --print-errorlogs` passed seven tests and skipped eight opt-in live cases. The passing cases were `native-xz`, `btrfs-default-helper`, `nbd-helper`, `filesystem-capacity-integration`, `storage-model`, `ui-templates` and `virtual-image-growth`. QEMU 10.0.13 was available inside a temporary mount namespace for this run. The new file-based fixture grew each of the four formats from 64 MiB to 128 MiB with known payload data, verified copy and progress, rejected shrink requests and a simulated attached-source failure, and exercised external backing files, internal snapshots and compressed QCOW2 output. Live UDisks attachment exclusion, interactive dialog use, hardware testing and the other open release gates remain pending.

## Advanced imaging follow-up

The four previous RAW, XZ and partition imaging failures remain recorded in
`mdraid-release-hardening-2026-11-11.md`. A fresh Debian 13.7 QEMU guest
reproduced all four refusals. On the first failed fixture, UDisks reported
`HintSystem=true`, read-only access, no filesystem, no drive, and no crypto or
RAID dependency. The kernel still showed the expected backing inode and
autoclear off. The safety refusal occurred before `Loop.Delete`.

For verified image attachments, imaging now distinguishes the UDisks
authorization hint from evidence of running system use. Loop detachment
checks UDisks dependencies, kernel partitions, mounts, holders, the backing
inode and disk sequence. It sends `Loop.Delete` once and checks both kernel
and UDisks state before reporting success.

The earlier NBD fixture returned before UDisks had exposed the partition
and filesystem. Attachment now waits for UDisks children to match the
partition device numbers exposed by the kernel. The intermediate rerun
reached the filesystem check and then found an independent identity
problem during backup. The identity check now reads the logical sector size
from the kernel, so an asynchronous UI cache update cannot change the
reviewed identity. The NBD fixture also mounts the partition and checks a
known file before testing busy-detach refusal and normal unmount.

The supplied GNOME Disk Utility archive informed the sequencing of
`gdu-create-disk-image-dialog.c` and `restore_disk_image_dialog.rs` for
dependency checks and restricted descriptors, `gdu-manager.c` and
`gdu-attach-disk-image-dialog.c` for descriptor-based loop attachment,
and `gdu-job-manager.c` for observable work. The implementation uses
Majoris Vala and its existing job model. No GNOME source was copied.

Backup compression uses the liblzma stream encoder with CRC64 and checks
decoded size and SHA-256 before publication. Virtual restoration pins the
source descriptor, converts to private sparse RAW, compares guest-visible
data, and applies the same block-target readback verification as RAW.
QEMU runs under Bubblewrap using `info`, `check` for QCOW2, `measure`,
`create`, `convert` and `compare`. Attachment uses a private Unix socket
and the existing authorized NBD helper. Writable attachment is restricted
to QCOW2. Restore records the reviewed target and logical digest before
writing. Interrupted file operations retain a private-work-directory record
for review. Reopening the UI reports orphaned operation records in the job
list.

### Debian 13.7 QEMU execution

Kernel 6.12.115+deb13.1-amd64 reported NBD `max_part=31`. Installed packages
included UDisks 2.10.1-12.1+deb13u2, QEMU 10.0.13, nbd-client 3.26.1,
Bubblewrap 0.12.0, util-linux 2.41.5, liblzma 5.8.1, GTK 4.18.6,
libadwaita 1.7.6, GLib 2.84.4, Meson 1.7.0, Vala 0.56.18 and Polkit 126.

| Command or fixture | Result |
|---|---|
| `meson setup build --prefix=/usr`, `meson setup --reconfigure build`, `meson compile -C build -j 6`, and `meson install -C build --no-rebuild` | Passed in the guest. |
| `meson test -C build --no-rebuild --print-errorlogs` | 11 passed, 98 skipped, zero failures. The guest's default user path omitted the partition or filesystem tools needed by the conversion fixture. The root opt-in run executed it. |
| `MAJORIS_DISKS_RUN_IMAGING_TESTS=1` with the 13 focused Meson targets listed in `tests/MANUAL-TESTING.md` | 13 passed, zero skipped and zero failures. |
| Four original RAW, XZ and partition imaging cases plus the MBR case | Passed. Tests rejected stale confirmation, oversized input, destination reuse and source replacement after review. Byte comparisons covered the restored range and bytes outside it, including sibling partitions and trailing sectors. |
| QCOW2, VHD and VHDX restore and conversion | Passed. Logical comparison and SHA-256 covered conversions through all three containers, compressed QCOW2, QCOW2/VHDX cross-conversion and RAW + XZ extraction. |
| NBD attachment | Passed. VHD, VHDX, QCOW2 and compressed QCOW2 each exposed an ext4 partition with the known file. The test checked the wrong token, duplicate attachment, a fresh service instance, mounted-volume refusal, detachment and writable QCOW2 persistence. |
| Backup process killed before publication | Passed. The final destination stayed absent. The recovery record and private work directory survived. Cleanup released the fixture loop after verifying its backing path and inode. |

The default suite also passed in Debian WSL with 13 passes, 101 skips and
zero failures. A subsequent application rebuild and `ui-templates` run
passed after the capacity-label updates.

The broader guest run passed live filesystem capacity, LVM recovery,
Btrfs device replacement, scrub and traditional quotas, mdraid RAID1
recovery and bitmap-assisted re-addition, the storage model and GtkBuilder
checks. Traditional quota and bitmap re-addition passed after installing
the guest's missing `pkexec` and allowing the fixture's unprivileged test
user to traverse its build directory. The direct LUKS resize fixture
passed with both binaries after the Meson runs reported intermittent
failures in discovery and `resize2fs`.

Three broader cases still failed. The generic GPT/MBR loop fixture
again requested a 90 MiB partition where UDisks reported an 80 MiB maximum.
The LUKS header fixture reproduced the prior busy-device and dependent
storage refusal. The Btrfs profile fixture gave the same protected-member
refusal with both the pre-imaging and current binaries in this guest.
These failures are release gates for those workflows.

Remaining execution gaps include interactive desktop use,
physical media, full process and service restart permutations, deliberately
lost D-Bus replies, device disappearance during a write, and injected
partial block restores. The earlier storage release blockers remain
tracked separately.

Modified files

| Area | Files |
|---|---|
| Imaging and verification | `src/disk-image-copy.vala`, `src/xz-stream.c`, `src/xz-stream.h`, `src/virtual-disk.vala` |
| Attachment, storage jobs and safety | `src/udisks-service.vala`, `src/virtual-disk-attachment.vala`, `src/kernel-storage-safety.vala`, `src/device.vala`, `src/safety.vala`, `src/hierarchy.vala` |
| GTK4 and libadwaita | `src/main.vala`, `src/window.vala`, `data/ui/window.ui`, `data/ui/disk-image-confirmation.ui`, `data/ui/virtual-image-dialog.ui`, `data/ui/create-blank-image-dialog.ui` |
| Test registration, fixtures and documentation | `meson.build`, `tests/image-device-test.vala`, `tests/xz-stream-test.c`, `tests/MANUAL-TESTING.md`, `docs/feature-parity-completion.md` |

## Platform scope

Use mount paths and fstab for persistent volume assignment, LVM/mdraid for Linux storage sets, Btrfs/LVM snapshots for Linux snapshot workflows, and LUKS for Linux encryption. Native drive letters, LDM, BitLocker management, APFS/FileVault and proprietary DMG/sparsebundle formats are excluded.

## Partition resize and ATA settings follow-up

| Register ID | Implementation | Verification | Final result |
|---|---|---|---|
| FS-02, FS-03 | The partition resize planner rejects XFS shrink and fails closed when a filesystem minimum cannot be measured. The operation refreshes the shrink minimum after preparation and revalidates device identity, geometry and mount state. Offline shrink of an already unmounted ext or NTFS filesystem still requires a check. The dialog keeps submission disabled at the current size and distinguishes unmounted, online and partition-only work. | `storage-model` exercises the planner's online and offline paths, including XFS rejection. `ui-templates` instantiates the dialog. | Partial. Growth and shrink with live UDisks and data-integrity checks remain open, as do layered LUKS/LVM paths. |
| FS-02, FS-03, FS-05 | The online shrink path retains the holder check and resizes the filesystem before the partition. Btrfs is gated on a mounted single-device filesystem, rejects missing members and ambiguous paths, and reads raw member capacity before changing the partition boundary and again during final verification. The service requires the requested partition size to appear in UDisks before advancing. | `storage-model` covers raw member capacity, similarly named paths, missing members and multiple device rows. | Partial. Live Btrfs resize and device geometry verification remain open. |
| ATA settings | The standby, APM and AAM subtitles now pass formatted strings to GTK while those strings are still allocated. | GDB traced an invalid UTF-8 warning to an early free in the Vala-generated C. `G_DEBUG=fatal-warnings xvfb-run -a build/resize-closure/ui-template-test` passed after the fix. | UI smoke passed. Applying settings to real ATA hardware remains unverified. |

The online shrink branch adapts the sequencing of `online_resize_no_repair` from GNOME Disks' `gdu-resize-volume-dialog.c`, copyright © 2017 Kai Lüke, GPL-2.0-or-later. Btrfs reports filesystem device capacity separately from the containing block device capacity. [Btrfs filesystem manual](https://btrfs.readthedocs.io/en/stable/btrfs-filesystem.html)

Debian 13.5 WSL passed `meson setup build/resize-closure`, `meson compile -C build/resize-closure` and the staged install. The schema post-install hook was skipped under `DESTDIR`. `meson test -C build/resize-closure --print-errorlogs` passed six tests, skipped nine and reported zero failures. The six passing tests were `storage-model`, `ui-templates`, `native-xz`, `nbd-helper`, `btrfs-default-helper` and `filesystem-capacity-integration` in file-backed mode. The eight opt-in live tests and `virtual-image-growth` skipped. No physical-disk operations or live destructive resize tests ran.
## Advanced storage navigation

The sidebar now lists UDisks volume groups, RAID arrays and Btrfs filesystems independently of physical drives. The Btrfs list groups visible members by filesystem UUID and prefers a mounted representative. The overview shows members, logical volumes, state and related active jobs. Thin-pool rows separate data capacity, total virtual provisioning, data utilization and metadata utilization when UDisks reports them. Metadata size in bytes and ordinary snapshot COW saturation remain open.

Context actions reuse the existing LVM lifecycle, RAID start/stop/check/degraded-start and Btrfs subvolume/allocation/maintenance paths. Capability checks govern visibility. An inactive object remains visible when its management backend is unavailable. Other advanced actions still use the drive view. Direct subvolume selection, live topology verification and the remaining management actions are open under UI-01 and STOR-28. This pass did not add a new backend, privileged operation or copied GNOME function.

The navigation fixture covers grouping Btrfs members, selecting a VG, preserving selection after a different object disappears, and returning to a physical drive when the selected object disappears. The fixture also exposed two null dereferences on the no-media drive path. Both are fixed and exercised in the same test.

Debian WSL passed `meson compile -C build/resize-closure`, `G_DEBUG=fatal-warnings meson test -C build/resize-closure --print-errorlogs` and a staged `meson install -C build/resize-closure --no-rebuild`. Six tests passed and nine skipped. Passing cases were `native-xz`, `btrfs-default-helper`, `nbd-helper`, `filesystem-capacity-integration` (file-backed), `storage-model` and `ui-templates` (including the mock LVM Poll and navigation cases). The opt-in live tests and the QEMU virtual growth fixture skipped. The staged install did not run the schema post-install hook. Full feature parity and live-device release acceptance remain open.

## Advanced LVM2 administration

| Workflow | Implementation and limits | Verification |
|---|---|---|
| Discovery and assessment | VG UUID, missing PV UUIDs and polling state, plus LV layout, recursive data and metadata structure, synchronization, child configuration and block path. Both `segs` and Debian's `segments` key are accepted. Allocation gaps can only be associated with a particular missing UUID when the backend reports that relationship. | Implemented and execution-tested. In the guest, an unaffected linear LV remained complete, the affected LV had an empty segment list, and the original PV UUID, allocation and readback reconciled after reconnect. |
| Rename | Inactive VG only. The authorized crypttab inspector verifies the existing VG through UDisks and reports references in fstab, crypttab and the kernel command line. The service revalidates physical members and verifies the returned path, unchanged VG UUID and exact LV membership. | Implemented and execution-tested as root. An owner-only crypttab entry blocked a real rename, and the rename succeeded after the entry was cleared while mode `0600` was retained. GNOME-session Polkit acceptance remains unverified. |
| Repair | Active but idle two-image RAID 1 with a verified surviving data and metadata pair and a separate replacement PV. Polls reconstruction progress and verifies both resulting placements. | Implemented and execution-tested. The degraded survivor and repaired LV returned the same data, and the repaired LV reported healthy attributes and 100% synchronization. Repair of other RAID layouts is intentionally restricted. |
| Missing-PV record removal | Explicit destructive confirmation. Rechecks the missing UUIDs and requires complete allocation for all retained LVs. Verifies their identities and allocations after removal. | Implemented and execution-tested. Majoris rejected removal with an affected linear LV and successfully removed the record after repair left all retained allocations complete. |
| Caching | Requires a zero-content same-VG linear candidate. The fixed LVM report supplies the pool identity, mode, dirty-block count and active origin metadata health. Verification follows the candidate UUID when LVM changes the pool name. Split retains the pool UUID. Detach requires that UUID to disappear. Separation of dirty, unknown or unhealthy caches and dm-writecache is intentionally restricted. | Implemented and execution-tested for attachment, split and detach. The guest verified ext4 readback, origin UUID and capacity, writethrough mode and pool identity. Nonempty, formatted and same-origin candidates were rejected before conversion. A writeback run observed eight dirty blocks, rejected both separation methods and preserved data. Model tests cover unknown counts and reported metadata errors. |
| Layout and placement | Linear on one PV, RAID 0, RAID 1, RAID 5, RAID 6 and RAID 10. Checks advertised segment types, distinct device domains, extent alignment and estimated per-PV capacity including RAID metadata. LVM RAID6 requires at least five PVs. Verifies returned geometry, placement and synchronization. | Implemented and execution-tested. All six layouts passed on the guest with the requested size and placement, including readback after deactivation and reactivation. Negative cases covered invalid counts, duplicate PVs, insufficient capacity, unavailable PVs, unsupported layouts and invalid or existing names. |

Mutations use UDisks authorization and tracked D-Bus jobs with Majoris dependency locks and kernel checks. The workflows require inactive or idle mappings and leave mount and encryption preparation to existing user-facing controls. If postflight cannot verify the requested result, the operation requires attention.

The degraded RAID1 fixture reported `SyncRatio=1` even with missing allocation. Repair verification also checks physical membership and the placement of both data and metadata pairs. The live test independently checked LVM health, compared the bytes and recorded matching SHA-256 readback before and after repair.

The GNOME Disks archive was reviewed for dependent-device preparation, object updates and job lifecycles. The implementation uses the corresponding Majoris services and GtkBuilder XML. No GNOME source or styling was copied. The cache inspector runs a fixed `lvs` report with a sanitized environment and an administrator authorization policy. [UDisks logical volume interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.LogicalVolume.html) · [UDisks volume group interface](https://storaged.org/udisks/docs/gdbus-org.freedesktop.UDisks2.VolumeGroup.html)

Debian 13.5 WSL passed Meson setup and compilation. The default Meson run reported 9 passed, 17 skipped and 0 failed, including the fixture regression, storage model and GTK templates. The destructive LVM tests were skipped by default and executed separately against real UDisks in a disposable Debian 13.7 QEMU guest with kernel 6.12.115, UDisks 2.10.1, libblockdev 3.3.0 and LVM2 2.03.31. The owner-only configuration regression also passed in a separate root run.

Fixture regressions exercise exact prerequisite command arguments, legitimate skip reasons, failed driver invocation, and refusal to mutate when PV, loop-image or VG identity is uncertain. The live fixtures use a private directory, dynamically allocated loops, narrowly scoped temporary udev rules and explicit UDisks state waits. Teardown keeps retired images detached after successful missing-record removal. [Manual testing](../tests/MANUAL-TESTING.md)

The registered opt-in Meson run reported 3 passed, 0 failed and 0 skipped. Headless guest verification covered root authorization and storage outcomes. Interactive GNOME Polkit approval, denial, cancellation and expiration remain release acceptance items. Daemon restart or interruption during a non-rollbackable operation, stalled reconstruction, damaged cache metadata on real devices and the full ordinary-LVM lifecycle regression remain unverified.

Files changed in this pass

- Backend and UI changes are in `src/udisks-service.vala`, `src/lvm-structure.vala` and `src/window.vala`. The existing GtkBuilder templates and Majoris Theme supply the layout and styling.
- Protected inspection and packaging changes are in `src/crypttab-inspector.c`, `data/com.majoris.disks.Crypttab.policy.in`, `src/meson.build` and `meson.build`.
- `tests/lvm-fixture-test.sh` was added. The shared fixture, test driver, all three `tests/lvm-*-integration.sh` suites, `tests/crypttab-inspector-test.c` and `tests/storage-model-test.vala` were updated.
- This register and `tests/MANUAL-TESTING.md` record the execution evidence and remaining desktop acceptance steps.

## Btrfs device replacement validation

Advanced Storage exposes a dedicated replacement dialog for mounted Btrfs filesystems. The plan identifies a present or missing source by its Btrfs device ID and UUID. The kernel's member capacity is required, including for missing sources. Reconstruction and the optional preference for surviving copies require RAID 1 across every allocated data, metadata and system profile. Other members must be verified and their error counters must be readable and clear for reconstruction. Unknown layouts, parity, unknown source capacity, multiple missing members, read-only and protected filesystems are restricted.

Majoris reuses its dependency graph, UDisks block objects, kernel idle checks, storage locks and job manager. GNOME Disks' ensure-unused, object refresh and local job patterns informed the workflow. No GNOME source was copied. The empty-target workflow rejects active consumers and signatures without unmounting, disabling, or wiping them. Target selection currently covers eligible whole devices.

The root helper independently matches the UDisks object to the canonical block node and checks its device number, disk generation, capacity, sector size, topology and signatures. It probes under an exclusive block open, validates the canonical node from a trusted device directory and retains a nonexclusive device reference while the kernel runs replacement. Btrfs takes its own exclusive claim and retains the canonical pathname. The ioctl reopens that pathname, so the userspace reference and revalidation narrow the race without eliminating concurrent privileged node or device changes. Cancellation checks the reviewed start timestamp and confirms the resulting kernel state. The kernel API has no atomic cancellation token for the observed operation.

Kernel status is read independently after startup, UDisks refresh and while the replacement dialog is open. Status includes progress in thousandths, timestamps and error counts. A locally started job verifies finished state, UUID, member count, preserved source ID on the target device, source retirement, profile flags, writable state and member error counters. After reopening the application, historical completion can be displayed even when the original source and target identities are unavailable. There is no automatic destructive retry. The helper does not resize the filesystem or independently checksum user files.

The shared bounded SPACE_INFO reader requests the record count first and uses the final global reserve record to detect truncation when the allocation count changes. It preserves unknown profile flags and continues to report the reserve separately. Native tests cover one, exactly 64 and more than 64 records, growth between requests, invalid and overflowing sizes, and allocation failure.

| Scenario | Classification and evidence |
|---|---|
| Healthy source and larger target | Implemented and execution-tested. The Debian 13 guest verified the filesystem UUID, original source ID on the new block device, and fixture SHA-256. The larger target retained the source's Btrfs member size. |
| Accessible failing source | Implemented and execution-tested with a still-identifiable writable member. A disposable device-mapper source injected read errors and Btrfs recorded them. Replacement using surviving RAID 1 copies preserved the fixture SHA-256. Physical failing hardware remains untested. |
| Missing RAID 1 member | Implemented and execution-tested. The writable degraded fixture recovered by device ID, remounted without the degraded option and returned the original SHA-256. Debian's kernel allocated new SINGLE block groups during recovery. The UI warns before recovery and reports changed profiles after verifying membership. |
| Unsafe targets and nonredundant reconstruction | Implemented and execution-tested for undersized, signed and mounted targets, changed disk generation, a substituted symlink, incorrect identities, an existing member, and a RAID 0 data profile when reconstruction was requested. Broader swap, LVM and mdraid failure fixtures were not run. |
| Cancellation and monitoring | Implemented and execution-tested through separate helper processes. Cancellation reached the kernel's cancelled state and retained the source member and fixture data. Fresh processes observed an in-flight replacement. Full desktop restart, kernel suspension, target disappearance and a UDisks restart during replacement were not injected. |
| Kernel or desktop authorization failures | The read-only helper rejected a start request and the mutation helper rejected malformed or stale requests, a read-only mount and cancellation without an active replacement. The installed Polkit policy denied an unauthenticated mutation from a headless session. Interactive desktop Polkit approval and the full helper timeout and failure-injection matrix remain untested. |
| Other recovery layouts | Intentionally restricted. Parity and unknown profiles are rejected. RAID 0, SINGLE, DUP, RAID 10 and three- or four-copy RAID 1 are excluded from missing-member reconstruction. Whole-device targets with unknown dependencies or system hints are excluded. |

Debian 13.5 built the app and ran the standard Meson suite with 9 passes, 27 prerequisite or opt-in skips, and zero failures. All nine replacement scenarios and both existing Btrfs discovery and disposable mount regressions ran separately in a disposable Debian 13 QEMU guest with Linux 6.12.115, btrfs-progs 6.14 and UDisks 2.10.1. The mount regression exercised the existing subvolume, balance, scrub and member add/remove paths. The live fixtures invoke the restricted native backend and UDisks identity checks directly. The GTK template ran under Xvfb.

The implementation changed `src/btrfs-default-helper.c`, `src/btrfs-default-config.h.in`, `src/btrfs-inspect.c`, `src/btrfs-inspect.h`, `src/device.vala`, `src/udisks-service.vala` and `src/window.vala`. It added `src/btrfs-device-replace-dialog.vala` and its GtkBuilder resource. Meson, the GResource manifest and the Btrfs Polkit policy register the feature and the separate read-only helper. Tests extend the native, storage model and template suites and add the opt-in replacement fixture.

The Linux implementation confirms the kernel's count semantics, preserved source ID and UUID, and pathname-based replacement interface. [Linux 6.12 Btrfs ioctl implementation](https://github.com/torvalds/linux/blob/v6.12/fs/btrfs/ioctl.c) · [Linux 6.12 Btrfs replacement implementation](https://github.com/torvalds/linux/blob/v6.12/fs/btrfs/dev-replace.c)

## Btrfs profile-conversion validation

Open **Btrfs Maintenance → Convert Allocation Profiles…** on the selected mounted filesystem. Data and metadata targets can be chosen independently. The metadata target applies to system allocation in the same kernel request. The dialog displays all discovered allocation rows, per-member unallocated space, kernel progress and any remaining profiles after interruption. Mixed data/metadata block groups remain visible and are excluded from conversion.

The typed layouts are SINGLE, DUP, RAID0, RAID1, RAID10, RAID1C3 and RAID1C4. RAID5 and RAID6 are recognized for display and intentionally excluded as sources and targets. Unknown flags retain their raw values and prevent conversion. The helper checks the mounted filesystem identity, complete writable member set, device error counters, system protections, kernel dependencies, scrub and exclusive operation. Missing members, zoned filesystems, unresolved dependencies and layouts with unverified workspace are excluded. Known failing members are directed to device replacement.

The workspace check reads the device extent tree and reconciles allocated extent sizes against each member's kernel allocation counters. It requires enough members with a contiguous gap large enough for the full logical allocation being converted, metadata reserve and relocation headroom. DUP budgets two stripes on one member. RAID0 and RAID10 conservatively budget a full logical copy on each required member. The estimate takes no credit for chunks expected to be released. This can reject a conversion that the kernel could complete with incremental relocation. Concurrent allocation or allocator placement can still produce a kernel space error.

The read-only helper checks the plan and produces a token bound to the mount, member identities, allocation and targets. The mutation helper checks it again after Polkit authorization. A separate confirmation is required for a reduction in copy count or device-failure tolerance. The helper derives the force flag only when metadata or system allocation loses its final redundant copy. New requests use the soft filter to skip chunks that already match. A paused conversion requires a fresh review of the actual saved kernel filters and resumes through the existing kernel control path. Cancellation leaves relocated chunks in their current profiles.

Majoris verifies the resulting profile sets, unchanged member identities, clear device counters and idle kernel state before reporting success. For replacement, kernel completion and membership verification are reported separately. GNOME Disks' source was reviewed for storage preparation, asynchronous jobs and UI refresh. This implementation reuses Majoris' own safety, job, lock and reconciliation code.

The Linux ioctl receives metadata and system filters separately. The helper follows the metadata/system pairing used by btrfs-progs. [Linux 6.12 balance ioctl](https://github.com/torvalds/linux/blob/v6.12/fs/btrfs/ioctl.c) · [Linux 6.12 balance validation](https://github.com/torvalds/linux/blob/v6.12/fs/btrfs/volumes.c) · [btrfs-progs 6.14 balance command](https://github.com/kdave/btrfs-progs/blob/v6.14/cmds/balance.c)

### Implementation files

| Area | Added | Updated |
| --- | --- | --- |
| Native balance and authorization | `src/btrfs-conversion.h` | `src/btrfs-default-helper.c`, `data/com.majoris.disks.Btrfs.policy.in` |
| Service and storage models | | `src/device.vala`, `src/udisks-service.vala` |
| GTK and replacement reporting | `src/btrfs-profile-conversion-dialog.vala`, `data/ui/btrfs-profile-conversion-dialog.ui` | `src/window.vala`, `src/btrfs-device-replace-dialog.vala`, `data/ui/btrfs-balance-dialog.ui`, `data/com.majoris.disks.gresource.xml` |
| Build and tests | `tests/btrfs-profile-conversion-test.vala`, `tests/btrfs-profile-conversion-integration.sh`, `tests/btrfs-balance-faults.c` | `meson.build`, `src/meson.build`, `tests/btrfs-default-test.c`, `tests/storage-model-test.vala`, `tests/ui-template-test.vala` |
| Documentation | | `docs/feature-parity-completion.md`, `tests/MANUAL-TESTING.md` |

### Execution results

- Debian 13.5 configured, compiled and staged the application. The default Meson suite reported nine passes, 43 prerequisite or opt-in skips, and zero failures. The native profile model, storage model and GTK template passed.
- A dedicated Debian 13 QEMU guest with Linux 6.12.115, btrfs-progs 6.14 and UDisks 2.10.1 passed 16 opt-in profile scenarios. The service fixtures independently verified member paths, filesystem UUIDs, profile sets and payload hashes. They observed pause and resume, cancellation with mixed profiles followed by a soft continuation, observer restart, and refusal of a review after UDisks restarted.
- All nine existing replacement scenarios, Btrfs discovery and disposable Btrfs mount regression passed in the guest. The installed Polkit mutation action denied an unauthenticated caller.
- The guest fixtures used loop-backed storage. Interactive desktop authentication, failing physical media during conversion, and every possible profile transition remain untested.
- The native fault shim injected ENOSPC, kernel FORCE rejection, a false completion reply, allocation read failure, unknown profile flags, recorded member errors, active replacement and scrub, an unknown exclusive operation, and a helper timeout. The helper rejected unsafe requests or reported an incomplete result, and independent checks found the original profiles and payload intact.

## STOR-27 Btrfs quota management

The read-only helper obtains mode, committed usage, limits and parent/child
edges from BTRFS_IOC_TREE_SEARCH_V2, supplements consistency with sysfs where
available, and reads the running extent cursor with
BTRFS_IOC_QUOTA_RESCAN_STATUS. An unreadable or malformed tree produces an
unknown state and blocks changes. Usage is a kernel accounting sample and can
lag recent writes until transaction commit.

The mutation helper uses BTRFS_IOC_QUOTA_CTL, BTRFS_IOC_QUOTA_RESCAN,
BTRFS_IOC_QGROUP_CREATE, BTRFS_IOC_QGROUP_ASSIGN and BTRFS_IOC_QGROUP_LIMIT.
Each request uses the existing admin Polkit action, checks the filesystem UUID
and member topology, and binds the reviewed configuration to the kernel's
unique mount ID. The helper takes the filesystem lock, rejects protected or
read-only filesystems and conflicting maintenance, and verifies the requested
change on readback. UDisksService also locks the members and checks
dependencies before dispatch. A failed readback produces a partial or
uncertain outcome and triggers fresh inspection.

| Capability | Classification | Scope |
| --- | --- | --- |
| Discover traditional and simple modes, qgroups, usage, limits and hierarchy | Implemented and execution-tested | Native tree parser, model tests and live fixtures |
| Enable and disable either mode | Implemented and execution-tested | Live kernel mode verification. Switching uses two separately confirmed operations, with existing settings listed before disabling |
| Start and verify rescans and handle inconsistency | Implemented and execution-tested | Live running and terminal kernel states, shared-extent assignment that makes accounting inconsistent, and limit rejection until repaired |
| Rediscover and monitor active rescans | Implemented and execution-tested | Asynchronous storage job uses the kernel extent cursor without estimating a percentage. A fixture terminates a UDisksService observer during a live rescan and verifies consistent accounting from a new process |
| Create and delete eligible groups, assign and unassign | Implemented and execution-tested | Strictly increasing parent levels prevent cycles. Active level-0 groups and groups with limits or relationships are protected from deletion |
| Recognize and clean up isolated stale qgroups | Implemented but not execution-tested for deletion | Parser fixture covers stale identity. The live kernel removed the deleted snapshot's group automatically. Only isolated, empty, consistent traditional groups are eligible |
| Set and clear referenced, exclusive and parent limits | Implemented and execution-tested | Live referenced, exclusive and aggregate enforcement verified with EDQUOT |
| Simple-quota first-owner usage and level-0 limits | Implemented and execution-tested | Snapshot attribution and over-limit writes verified. Simple-mode exclusive limits, rescans, hierarchy mutations and stale-group deletion are intentionally restricted |
| GtkBuilder quota and limit dialogs | Implemented but not execution-tested interactively | Template tests instantiate the dialogs. Desktop confirmation, authentication and selection flows remain manual tests |
| Apply quota configuration during subvolume creation | Intentionally restricted to a two-step workflow | UDisks creates the object first. Majoris offers review of the verified level-0 group for limits or assignment. The two operations are independent |
| Unknown or unsupported configurations | Intentionally restricted | Changes require a single verified mount, a non-reusable mount ID, a known quota mode and a complete set of up to 64 members. Inspection rejects trees beyond 65,536 raw records. Automatic quota enabling and lossless mode conversion are unsupported |

GNOME Disks source was reviewed for storage preparation, capability-aware
presentation and asynchronous jobs. No GNOME source was copied. Majoris
retains its existing UDisks object manager, safety checks, job manager,
GtkBuilder XML and theme.

| Area | Added | Updated |
| --- | --- | --- |
| Native inspection and operations | `src/btrfs-quota.c`, `src/btrfs-quota.h` | `src/btrfs-default-helper.c`, `src/btrfs-inspect.c` |
| Service, storage jobs and quota models | `src/btrfs-quota.vala` | `src/udisks-service.vala` |
| Filesystem and subvolume UI | `src/btrfs-quota-dialog.vala`, `data/ui/btrfs-quota-dialog.ui`, `data/ui/btrfs-qgroup-limit-dialog.ui` | `src/window.vala`, `data/ui/window.ui`, `data/ui/btrfs-subvolumes-dialog.ui`, `data/com.majoris.disks.gresource.xml` |
| Build and authorization | | `meson.build`, `src/meson.build`, `data/com.majoris.disks.Btrfs.policy.in` |
| Test fixtures and coverage | `tests/btrfs-quota-integration.sh`, `tests/btrfs-quota-service-test.vala` | `tests/btrfs-default-test.c`, `tests/btrfs-balance-faults.c`, `tests/storage-model-test.vala`, `tests/ui-template-test.vala` |
| Documentation | | `docs/feature-parity-completion.md`, `tests/MANUAL-TESTING.md` |

### Quota execution results

- Debian 13.5 configured and compiled the project. The default Meson run
  passed nine tests, with 48 prerequisite or opt-in skips and zero failures.
  Native parser, storage model and GtkBuilder template tests passed.
- The Debian 13 QEMU guest ran Linux 6.12.115, btrfs-progs 6.14 and UDisks
  2.10.1. The traditional, simple, UDisks lifecycle, fault injection and
  observer restart scenarios passed on image-backed devices.
- The UDisks fixture verified subvolume creation, post-creation limit
  configuration, rejection of an invalid parent with the subvolume retained,
  read-only snapshot creation and deletion, and changing and restoring the
  default subvolume. The Linux 6.12 snapshot check now accepts the kernel's
  positive success return while continuing to verify the returned identity.
- Fault fixtures verified read-only helper mutation rejection, Polkit denial,
  changed mount identity, read-only mount rejection, unavailable quota state,
  helper exit, timeout, failed rescan, false limit success and failed readback
  after a real limit change.
- All nine device-replacement and all 16 profile-conversion scenarios passed
  after loading the guest's UDisks Btrfs module. Btrfs discovery and the
  disposable mount suite passed, including balance and read-only scrub.
- Interactive desktop authorization and stale-qgroup deletion remain
  unverified. The live kernel removed the deleted snapshot's group and
  rejected the attempt to create a synthetic orphan level-0 group. The
  parser's stale-group result is covered by a mock.


## Btrfs scrub lifecycle

**Backend.** Majoris uses Debian 13's btrfs-progs 6.14 as the single scrub engine. The native helper constructs a fixed argument vector for foreground `btrfs scrub start` or `resume` under a detached supervisor. It pins the verified mount or selected block device. Filesystem and member UUIDs, device IDs, block membership and mount identity are checked separately from display names. The selected block's Btrfs UUID and member UUID are also checked against its superblock. Majoris uses `BTRFS_IOC_SCRUB_PROGRESS` to discover live work and `BTRFS_IOC_SCRUB_CANCEL` to cancel it. It waits for the kernel to stop before acknowledging cancellation. External scrubs can be observed and explicitly cancelled across the filesystem. [Debian btrfs-scrub manual](https://manpages.debian.org/trixie/btrfs-progs/btrfs-scrub.8.en.html)

**Safety and authorization.** The service uses the existing storage dependency checks, kernel holder checks, member locks, backend lifetime and StorageJobManager. A review token binds the dialog selection to the unique mount and member identities. The helper rechecks it after Polkit authorization, shares the privileged Btrfs maintenance lock, and checks for conflicting kernel operations before dispatch. Inspection uses the existing read-only Polkit helper. Start, resume and cancel use the existing administrator action. Repair requires a verified writable mount and members, recognized data, metadata and system allocation profiles, and readable device health counters. A failing SMART/NVMe report or existing write/flush failures blocks repair.

**Results and health.** The dialog reports member data and metadata bytes, extents, read/checksum/metadata/superblock errors, corrected, uncorrectable and unverified counters, checksum discards, unchecksummed extents, and allocation failures. Checked sums preserve the distinction between complete and partial aggregates. Byte counts measure physical member work, including separately scanned replicas and any work repeated by the upstream resume engine. Lifetime device statistics and SMART/NVMe indications are shown separately. Read-only scrub can detect an alternate good copy, so the Linux corrected counter in read-only mode is labelled as recoverable damage. Repair and uncorrectable outcomes are distinct. The dialog shows bytes without estimating a completion percentage. [Linux 6.12 scrub implementation](https://github.com/torvalds/linux/blob/v6.12/fs/btrfs/scrub.c)

**Persistence.** btrfs-progs owns its checkpoint under `/var/lib/btrfs`. Majoris verifies its format, filesystem, scope, freshness and offsets before resuming and preserves the original mode. Majoris stores a separate versioned, checksummed GKeyFile under `/var/lib/majoris-disks-scrub/`, keyed by filesystem UUID. Each file retains up to 20 entries within a 512 KiB cap, including member identities, operation UUID, start/end timestamps where known, mode, scope, status and per-device counters. Root ownership, symlink checks, bounded parsing and atomic durable replacement protect the records. An interrupted attempt can appear with an unknown end time. Majoris keeps results with the verified member set they describe. [btrfs-progs 6.14 checkpoint and resume implementation](https://github.com/kdave/btrfs-progs/blob/v6.14/cmds/scrub.c)

**UI and reference.** Open **Btrfs Maintenance → Manage Scrub** for mode, member selection, progress, history and controls. The GtkBuilder template inherits the existing GTK4/libadwaita styling. The supplied GNOME sources were reviewed for asynchronous preparation, object removal and job progress patterns. Majoris uses its existing job manager and mounted-filesystem safety flow, with no imported GNOME source.

| Capability | Classification |
| --- | --- |
| Whole filesystem and selected-member read-only scrub, separate live counters, history, restricted authorization | Implemented and execution-tested |
| Repair of recoverable RAID1 data and metadata corruption, reporting of uncorrectable single-copy damage | Implemented and execution-tested |
| Kernel cancellation, genuine checkpoint resume, external discovery, client exit and reboot recovery | Implemented and execution-tested |
| SMART and NVMe presentation with real drives | Implemented but not execution-tested on physical drives |
| Start/resume on missing-member filesystems, repair on read-only mounts, protected filesystems, zoned or parity/unknown repair layouts | Intentionally restricted |
| External scrub adoption/resume when the original mode and scope cannot be established | Intentionally restricted |
| Independent cancellation of a single member during a filesystem-wide scrub | Unsupported by the filesystem-wide kernel cancellation interface |
| Exact remaining bytes and prior unverified counts after an abrupt interruption before Majoris saves the attempt | Unsupported by the verified btrfs-progs 6.14 checkpoint format |

The two comparison/API matrix Markdown files named in the task were absent from the supplied attachments and checkout. The scrub rows above update the repository's existing parity register.


### Execution record

| Check | Outcome |
| --- | --- |
| Debian 13 Meson setup, compile and default suite | Passed. 9 Meson tests passed, 61 opted-out or prerequisite-dependent cases skipped, 0 failed. The native helper unit test included strict checkpoint scope, timestamp and overflow parsing. The scrub GtkBuilder template loaded under Xvfb. |
| Clean, RAID1 multi-member and selected-member read-only scrubs | Passed. Finished member counts and payload bytes matched the fixtures. |
| Recoverable data corruption, uncorrectable single-copy corruption and recoverable metadata corruption | Passed. The read-only run detected a usable mirror, the repair run corrected it, and the single-copy case reported uncorrectable damage. The metadata case recorded verification errors and corrections on the targeted member. |
| Cancellation and genuine resumption | Passed. Verified kernel stop, resumable history, rejection of an altered checkpoint, upstream resume timestamp and payload integrity. |
| External activity, degraded topology, invalid inputs, injected failures and authorization | Passed. The fixtures exercised duplicate start, active balance/replacement, unknown profile, device errors, unavailable kernel status, remount identity changes, invalid UUID and member IDs, missing members, stale or overflowing checkpoint, truncated history, read-only repair denial and unauthorized Polkit dispatch. |
| Client exit and UDisks restart | Passed. A new service client rediscovered the kernel scrub after the original client exited and after UDisks restarted. The detached supervisor saved a clean terminal result. |
| Debian 13 QEMU guest reboot | Passed. The boot ID changed, the original UUID and nonzero checkpoint were recognized, and explicit resume preserved the payload SHA-256. The result reported the unavailable pre-reboot unverified count. |
| Existing discovery, mount, filtered balance, device replacement, profile conversion, quotas, subvolume and snapshot workflows | Passed in the disposable guest. The replacement suite ran 9 scenarios and profile conversion ran 16. The quota service fixture exercised subvolumes, snapshots and default-subvolume changes after its runtime was installed. |
| Interactive desktop confirmation dismissal and physical SMART/NVMe devices | Not executed. The GTK template and disposable UDisks client were exercised separately. |

The guest used Linux 6.12.115, btrfs-progs 6.14 and UDisks 2.10.1. The changed
backend lives in `btrfs-scrub.h` and `btrfs-default-helper.c`. The application
changes are in `btrfs-scrub.vala`, `btrfs-scrub-dialog.vala`,
`udisks-service.vala`, `window.vala` and the two scrub/maintenance templates.
Meson, the GResource manifest and the existing Polkit policy register the new
sources and restricted inspection. The test changes cover the native parser,
template loading, the UDisks client, the disposable scrub and reboot fixtures,
the shared fault shim and the existing disposable mount regression.

## Advanced Linux mdraid

`StorageRaid` now carries the UDisks UUID, running state, expected geometry
and a typed member topology. The reader validates the full ActiveDevices
signature, preserves kernel flags and read errors, rejects duplicate device
paths and slots, and derives unavailable slots from synchronized occupancy.
Stopped arrays list discovered members with unverified slots. Kernel readback
uses device numbers, disk sequence and UUID to associate md sysfs with the
UDisks array. Synchronization includes completed and total sectors, rate,
estimated time, current action and mismatch sectors.

The service uses UDisks `Start`, `AddDevice`, `RemoveDevice`,
`SetBitmapLocation` and `RequestSyncAction`. It uses `Block.OpenDevice` for
signature checks and direct reads of native superblocks. It compares surviving
roles, UUIDs, geometry and event counters before reconstruction. Guided degraded
assembly requires clean, matching native metadata and a verifiable slot plan.
Parity assembly also requires the kernel dirty-degraded override to be disabled.
RAID10 is limited to even-sized near-two arrays. Target checks include the
kernel identity, component capacity, surviving physical devices, logical sector
size, existing signatures and storage dependencies. After adding a target the
service verifies its slot, synchronization and the degraded count. RAID6 with
two losses reports a separate intermediate result after the first member.

The Polkit helper is limited to fault marking and re-addition on idle native
two-member RAID1. It validates array and member identity, disk sequence, slot
and event state after authorization. Fault marking uses the kernel ioctl.
Re-addition uses a fixed mdadm command and accepts only an eligible former role
and compatible event state. The service never uses a previously saved job as
authority to dispatch another mutation. On reconnect it rebinds active
observations to the same array UUID and kernel identity. A local replacement
plan remains in memory, so a later session can report current kernel health
without certifying which historical replacement caused it.

New files are `src/mdraid.vala`, `src/mdraid-superblock.[ch]`,
`src/mdraid-helper.c`, `src/mdraid-helper-config.h.in`,
`src/mdraid-management-view.vala`, `data/ui/mdraid-management-view.ui`,
`data/com.majoris.disks.MDRaid.policy.in` and the `tests/mdraid-*` fixtures.
Modified files include `src/udisks-service.vala`, `src/safety.vala`,
`src/blkid.vapi`, `src/drive-view.vala`, `src/window.vala`,
`data/ui/drive-view.ui`, `data/ui/window.ui`,
`data/com.majoris.disks.gresource.xml`, both Meson build files,
`tests/ui-template-test.vala` and `tests/MANUAL-TESTING.md`.
GNOME Disks was reviewed for preparation (`gduutils.c`), object refresh and
presentation (`gdu-manager.c`, `gdu-drive.c`, `gdu-block-row.c`) and job
lifecycle (`gdu-job-manager.c`, `gdulocaljob.c`, `gdu-job-row.c`). Majoris
uses its existing safety and job managers and incorporates no GNOME source or
styling.

The disposable Debian 13 guest used Linux 6.12.115, UDisks 2.10.1, mdadm 4.4
and util-linux 2.41.5. Replacement fixtures verified the assigned slot,
synchronization, degraded count and payload checksum on RAID1, RAID5, RAID6
and near-two RAID10. The two-loss RAID6 fixture verified each replacement
independently. Clean degraded RAID1 and RAID5 assembly and refusal of
reconstruction on a dirty running RAID5 array passed. The tests also
rejected a changed reconstruction review and a wrong member slot.

The new-client and UDisks restart fixture verified continued reconstruction
and final payload. The bitmap and member fixtures verified internal bitmap
enablement and disablement, spare attachment and removal, fault marking and
former-member re-addition. The re-add fixture verifies the slot and payload
after synchronization. The extent of bitmap-assisted synchronization was
not measured. The installed Polkit action denied the non-interactive SSH
session. Interactive desktop approval and cancellation were not executed.

The check and repair fixture cancelled an active check, detected a deliberate
mismatch on an offline fixture member, requested repair and verified that a
follow-up check found zero mismatch sectors. The payload SHA-256 remained
unchanged. Majoris reported uncertainty when it observed the array return to
idle without a terminal progress sample. The fixture verified the final state
independently through sysfs. The Debian 13 Meson suite passed 10 tests with
74 opt-in or prerequisite skips and no failures. All 13 new disposable
mdraid cases passed separately.

Representative live regressions passed for filesystem capacity, LUKS mapping
resize, Btrfs discovery, device replacement, profile conversion, traditional
quotas and scrub, and LVM missing-PV recovery, RAID1 repair, cleanup and rename.
The LUKS and LVM reruns used their configured helper paths. The isolated LUKS
rerun also cleared stale UDisks LVM objects from a reused fixture loop number.

Remaining coverage includes RAID4 and alternate RAID10 live fixtures,
excessive member loss on a live parity array, kernel refusal of a stopped
dirty parity array, a guest reboot during recovery, and the full injection
matrix for device reuse, disappearing members, backend timeouts and helper
termination. Legacy and external metadata, unsupported RAID10 layouts and
external bitmap changes are intentionally restricted.

Interface references are the [UDisks MDRaid API](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.MDRaid.html)
and the [Linux md kernel documentation](https://docs.kernel.org/admin-guide/md.html).

### Advanced mdraid release hardening — 11 November 2026

See [the detailed release-hardening report](mdraid-release-hardening-2026-11-11.md)
for the complete required result register, evidence and remaining risks.
The existing backend and restricted helper are preserved. A live device-number
reuse fixture reproduced a stale review defect; modification identities now
include disk sequence and loop backing identity. Recovery completion additionally
requires native member metadata, expected roles and final kernel health.

| Area | Current classification | Execution evidence / limitation |
|---|---|---|
| RAID4 reconstruction | Implemented and execution-tested | Owned guest fixture verified UUID, replacement slot, synchronized state, zero degraded and checksum. |
| Guest reboot reconstruction | Implemented and execution-tested in explicit phases | Real guest reboot followed by fresh-client terminal health, member/slot and checksum verification. Prepare-only and unchanged-boot verification cannot pass. |
| Stopped dirty/degraded parity refusal | Implemented and execution-tested for RAID5 and RAID6 | Separate abrupt guest resets retained dirty native metadata; requests refused with byte-identical backing files. Additional event-disagreement permutations remain unexecuted live. |
| Alternate RAID10 layouts | Intentionally restricted; execution-tested refusal | n3/259, f2/513, o2/66049 and odd n2/258 refused; supported even n2 reconstruction preserved. |
| Replacement target disappearance and device-number reuse | Implemented and execution-tested | Detached target and same-number substitute reject the previous review; no attachment or payload change. Other disappearance timings remain unexecuted. |
| Lost UDisks reply / helper result | Implemented and execution-tested with controlled injection | Real AddDevice acceptance followed by lost reply is reconciled without retry. Unknown exits and actual helper SIGKILL before/after the kernel ioctl are classified conservatively. |
| Graphical Polkit and dialog acceptance | Implemented and execution-tested for the exercised cases | Installed GNOME application approved fault marking, handled definitive denial and prompt cancellation, rejected a member removed during authorization, and rebound after UDisks restart. |
| MDRAID — Bitmap-assisted former-member re-addition after degraded writes | Implemented and execution-tested on native RAID1 metadata 1.0, 1.1 and 1.2 | In the 1.2 acceptance run, the former member was at event 19, the survivor and bitmap at 22, and the cleared boundary at 18. The member wrote 131,103 sectors for a 161,792-sector component, returned to its original slot with zero degradation, and retained the payload checksum. The [follow-up report](mdraid-release-hardening-2026-11-11.md#follow-up--bitmap-assisted-former-member-re-addition-after-degraded-writes) preserves the original refusal and records the new execution. |
| Durable historical operation attribution | Unsupported in this pass | Current kernel rediscovery and in-memory member evidence retained; no privileged journal or automatic replay added. |

The default Debian 13 suite passes with opt-in skips. The live bitmap result
applies to the tested portable version 4 internal bitmap. The mdraid definitions
use MDRAID-01 through MDRAID-05 without renumbering established STOR entries.

### Cross-subsystem release gates — 12 November 2026

The acceptance guest was a temporary snapshot of the dedicated
`majoris-mdraid-test` Debian 13.7 QEMU guest with kernel
`6.12.115+deb13.1-amd64`, UDisks 2.10.1 and btrfs-progs 6.14. UDisks and
Polkit were active. The Btrfs module needed to be enabled after boot.
The GNOME Disks archive was consulted for resize, dependency preparation,
loop setup, imaging cancellation and restore rescan. The changes use
Majoris' existing service, job, journal and helper paths.

| Area | Classification | Gate and evidence |
|---|---|---|
| GPT/MBR resize | Implemented and execution-tested | The original `disposable-loop-integration` returned 1. It asked UDisks to grow a populated MBR extended partition to 94,371,840 bytes and received an 83,886,080-byte maximum. The 128 MiB fixture used 512-byte sectors, an extended entry starting at sector 49,152 with length 163,840, and a logical child starting at 53,248. Majoris now distinguishes table length from block-device capacity, applies the populated-container cap, and verifies post-resize identity and geometry. The corrected backend fixture returned 0 for GPT ext4 growth/shrink, MBR primary growth and logical growth within the container. Starts, capacities, ext4 checks and the original MBR partition prefixes were checked. The populated-container growth restriction is intentional on the tested backend. |
| LUKS header restore and dependencies | Implemented and execution-tested | The historical failure remains recorded as a busy-device/dependent-storage refusal. An exclusive open on an intentionally busy fixture was a correct rejection. The exact historical service dependency was not captured. The new baseline reached service restore and timed out at 300 s. The fixture now checks both kernel holders and UDisks' cleartext path before service restore. The header, mapping resize, partition-backed resize and mapping restoration targets passed with the longer QEMU timeout. |
| Btrfs profile conversion | Implemented and execution-tested | The earlier protected-member refusal is preserved. A fresh baseline without the Btrfs module failed because the volume interface was missing. Enabling the module let the unmodified data test pass. The updated fixture waits for the exact filesystem UUID and non-system hint for each owned member, then verifies the resulting profiles and payload checksum. All 16 profile targets passed, including the protected-member refusal. The earlier protected-member diagnostic did not reproduce in the prepared guest, so its exact dependency cause remains unresolved. |
| Loop and NBD discovery | Implemented and execution-tested | Bounded content probing supplies expected partition numbers, starts and lengths. The app reconciles those with kernel children, UDisks parentage and device identity, independently of filesystem recognition. Live RAW, GPT, MBR, blank QCOW2 and partitioned NBD lifecycle fixtures passed. The model test exercises delayed kernel and UDisks publication, wrong parent, mismatched device number and a disappearing child. Delays and reuse during live discovery remain unverified. |
| Image publication | Implemented and execution-tested | RAW, XZ, sparse and QEMU output use the shared descriptor-based publication path. It flushes the file, verifies the source entry, uses a no-replacement rename, synchronizes the destination and work directories, and checks the final inode. Injected directory-sync failure leaves the published file in place and reports that durability requires attention. The test also verifies preservation of an existing destination. |
| Partial block restore | Implemented and execution-tested | RAW and XZ cancellation tests observed actual writes. Readback confirmed the new head and original tail, and the recovery record survived the failed operation. Moving the RAW source path after an observed target write preserved the verified bytes and produced an attention result. Killing an owned NBD exporter after independent readback of the first target bytes produced a partial restore. The lost-rescan fixture let the real rescan execute, dropped its reply, checked exactly one dispatch and read back the restored data. |
| Interrupted output and restart | Partially implemented | Live RAW and XZ backup interruption left no published output. QEMU conversion cancellation and abrupt application exit before publication were exercised. A new process recovered the conversion record. Power loss, crash after rename, and the full write/flush/verification failure matrix remain unverified. |
| Interrupted NBD and UDisks restart | Partially implemented | The verified exporter termination fixture produced a real read error and confirmed safe teardown or an empty kernel device. NBD attach/detach reply-loss paths reconcile ownership evidence without replaying requests. A live foreground-client kill needs an ioctl-mode client. UDisks daemon restart during image discovery and lost loop replies remain unverified. |

The geometry, publication and interruption cases are described in
[the manual test register](../tests/MANUAL-TESTING.md#cross-subsystem-release-gate-reruns).
Backend semantics are documented in the
[UDisks partition API](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Partition.html)
and [Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html).

The original QEMU baseline used `meson test -C build --no-rebuild
--print-errorlogs --num-processes 1 disposable-loop-integration
luks-header-integration btrfs-profile-conversion-data` with the repository's
three opt-in variables enabled. The raw original output and subsequent
diagnostics are in `build/release-gates-baseline.log`,
`build/release-gates-enabled-baseline.log`, and
`build/release-gates-original-partition.log`.

| QEMU opt-in execution | Passed | Failed | Skipped | Notes |
|---|---:|---:|---:|---|
| Partition fixture, final repeated rerun | 3 | 0 | 0 | An intermediate run lost the extended partition's UDisks object after deleting the logical child. The fixture now waits for the expected parent and partition object before the next deletion. |
| LUKS header, resize and mapping restoration | 4 | 0 | 0 | Header target took 305.95 s with a longer QEMU timeout. The previous 300 s timeout remains in the baseline record. |
| Btrfs profile conversion, replacement, traditional quota and scrub | 19 | 0 | 0 | Includes profile restart, continuation, protected members and fault injection. |
| Filesystem capacity, storage model, GtkBuilder and mdraid | 5 | 0 | 0 | Includes RAID1 reconstruction and bitmap-assisted member re-addition. |
| LVM recovery | 1 | 1 | 0 | The combined run followed the UDisks restart case and lacked the keeper LV's UDisks properties. The same fixture passed in isolation after re-enabling the LVM2 module. |
| Native QEMU imaging and partition Meson matrix | 26 | 0 | 1 | Includes a lost rescan reply, both cancelled physical restores, interruption and crash evidence, and NBD exporter faults during attachment use and after a target write. The active Debian netlink mapping had no foreground NBD client to terminate. |
| Native QEMU build and default Meson suite | 17 | 0 | 110 | Debian 13.7 with QEMU 10.0.13, GLib 2.84.4, GTK 4.18.6, libadwaita 1.7.6, Meson 1.7.0, Vala 0.56.18 and Polkit 126. The default suite leaves the destructive opt-ins disabled. |
| Final QEMU conversion and attachment rerun | 6 | 0 | 0 | Native rebuild and retest after moving conversion source identity revalidation immediately before publication. |

The tested publication and discovery gates are resolved for the exercised
paths. The historical LUKS and Btrfs diagnostics lack a complete dependency
snapshot. Remaining unexecuted gates include loss of a loop setup/delete
reply, live kernel-number reuse during discovery, daemon restart during
imaging, and crash durability after an actual guest power loss.

Production changes are in `src/blkid.vapi`, `src/device.vala`,
`src/layout.vala`, `src/filesystem-resize.vala`,
`src/udisks-service.vala`, `src/disk-image-copy.vala`,
`src/virtual-disk.vala`, `src/virtual-disk-attachment.vala` and
`src/window.vala`. Test changes are in `meson.build`,
`tests/disposable-loop-integration.sh`, `tests/luks-header-integration.sh`,
`tests/btrfs-profile-conversion-integration.sh`,
`tests/image-device-test.vala`, `tests/mdraid-dbus-faults.c` and
`tests/storage-model-test.vala`. The existing restricted helpers, Polkit
rules, GtkBuilder templates and theme continue to govern these workflows.

## UDisks module readiness and restart acceptance

The earlier combined LVM failure above was reproduced from the unchanged
baseline in a fresh Debian 13 QEMU overlay. The guest ran kernel
`6.12.115+deb13.1-amd64` and UDisks `2.10.1`. Before restart, owner `:1.34`
exported `Manager.LVM2.VolumeGroupCreate`. After restart, owner `:1.48`
returned an empty interface table from `busctl introspect`, with exit
status 0. The old fixture interpreted that status as module readiness.
LVM metadata still showed both logical volumes, while UDisks returned
neither `keeper.Active` nor `keeper.BlockDevice`. The baseline command
`MAJORIS_DISKS_RUN_LVM_TESTS=1 meson test -C build --no-rebuild
--print-errorlogs --num-processes 1 lvm-recovery-integration` failed
with exit 1.

The corrected fixture checks the actual manager method on the current
unique D-Bus owner, activates the installed module with
`EnableModule("lvm2", true)`, and waits for the specific VG and LV.
It compares their UUIDs with LVM metadata. For an active LV it also
compares the device-mapper number and the UDisks backlink. For an
inactive LV it requires `Active=false` and `BlockDevice=/`.
The application activates LVM2 on the explicit Create Volume Group
action and restores previously observed module capabilities on a new
owner. Rebuilding the snapshot invalidates old block and advanced
object references. Existing modifying requests retain their original
backend lifetime and observation records. Btrfs fixtures activate
their module independently and check filesystem and member identity
before a fresh maintenance review.

The first installed guest run passed LVM recovery, cache, layout and
the post-LV restart case. Before helper installation, a separate
post-LV attempt reached inactive VG rename and failed with
`The protected crypttab inspector is unavailable`. That setup failure
was resolved by installing the guest build. The installed guest also
passed the lost `Loop.Delete` reply case with one dispatch and one
accepted reply, and rejected a stale detach when `/dev/loop2` changed
from disk sequence 281 to 283. The ioctl-only helper pinned a real
foreground `nbd-client` (PID 24762, start 167469, disk sequence 285) and
the fixture verified disruption after termination. The production
helper still uses the client's default mode.

The first lost `LoopSetup` and RAW discovery restart runs each
recorded exactly one accepted setup. The lost reply left one mapping;
the restart changed UDisks from `:1.946` to `:1.1071` and preserved the
loop mapping. Both tests failed at cleanup because a fresh root
client lacked the original session's verified loop identity. The
fixture now independently checks backing inode, disk sequence,
holders and mounts before releasing the exact mapping. The earlier
mappings were released using their recorded identities and the guest
fixture files were retained as evidence.

All five corrected loop cases passed on the second guest. Lost setup
recovered one mapping and an attention journal in a fresh client.
Lost delete reconciled the removal after a single accepted request.
RAW discovery survived owner `:1.13` → `:1.31` with `7:0` and disk
sequence 24, and the partition's ext4 readback matched the backing
image. Reuse changed the disk sequence from 26 to 28 at `7:0` and
rejected the stale detach. The discovery substitution held the
original inode on `7:0` with disk sequence 30 and left the replacement
image unattached. Each faulted setup or delete dispatched exactly once.

The acceptance procedure and log names are in
[the manual test register](../tests/MANUAL-TESTING.md#udisks-restart-and-attachment-acceptance).
GNOME Disks' object manager, job lifecycle, unused-device preparation
and loop-mounter code informed the review. The implementation uses
Majoris' storage model, dependency checks, journals and GtkBuilder UI.
The optional module calls follow the
[UDisks 2.10.1 Manager API](https://storaged.org/doc/udisks2-api/2.10.1/gdbus-org.freedesktop.UDisks2.Manager.html).

### Abrupt power cuts

A separate Debian 13 overlay ran the four explicit power-loss checkpoints
with ext4 on `/dev/vda1`, a qcow2 virtio disk and QEMU `cache=none`.
The host verified the QEMU executable and exact overlay argument before
sending SIGKILL. Each test booted the same overlay again and required a
different guest boot ID.

| Checkpoint | Observed after reboot |
|---|---|
| Before rename | Original inode 131324 and 8 MiB checksum at `work/image`. |
| After rename, before directory synchronization | Original inode 131324 and 8 MiB checksum at `work/image`. The rename was rolled back by ext4 recovery in this run. |
| After directory synchronization | Original inode 131324 and 8 MiB checksum at `published.img`. |
| Incomplete output | Original inode 131323 and 4 MiB checksum at `work/image`. |

Each verification also checked RAW format and the protected neighboring
image, recovered the journal into an attention result in a fresh
client, and removed only the verified fixture files. The host driver
returned exit 0. These are results for the tested ext4 and QEMU cache
configuration.

### Fixture order and backend observations

The three LVM targets passed as a group alone, after the LVM daemon
restart cases, after the Btrfs group and after image discovery restart.
The four restart stages and the disabled-module case passed together.
In the post-LV stage, a persistent client rediscovered the same LV UUID
and rejected the pre-restart review. The before-review stage rejected
the old UUID both while the LV was absent and after a same-name LV
appeared.

A separate guest reproduced an LVM cleanup race before RAID1 layout.
The kernel had removed the old mapper, but UDisks could still expose
the removed active LV. The fixture now observes removal before placing
the mirror. A later LVM-to-Btrfs run reproduced another stale interface.
UDisks reported `IdType=btrfs`, the expected filesystem UUID, no
holders and `HintSystem=false` on a reused loop. The same block still
exported `PhysicalVolume.VolumeGroup` pointing to the removed fixture
VG. Majoris correctly refused to modify a member with that unresolved
dependency.

Cleanup now clears the labels of verified, unowned fixture PVs and
retires a loop index only when it is unbound and UDisks still associates
it with that fixture's removed VG. It uses the kernel's loop-control
ioctl and checks disappearance before proceeding. The LVM-to-Btrfs
rerun passed with no daemon reset between the two fixtures. The Btrfs
case then restarted UDisks, rediscovered both verified members and the
same filesystem UUID under `:1.370`, and completed a new maintenance
review.

### Serial regression and reruns

The initial combined Meson run returned exit 1 with 96 passed, four
failed, 39 skipped and no timeouts. It passed partition and filesystem
capacity, all five LUKS targets, Btrfs discovery/replacement/profile
conversion/scrub, LVM recovery/cache/layout and restart, and RAW/XZ
and virtual-image conversion. The four failures were the two Btrfs
quota service targets, writable NBD lifecycle, and stale NBD reuse.
The guest hostname also caused the existing mdraid fixtures to skip.
The full acceptance procedure now names the hostname those fixtures
require and the runtime library for the Btrfs default-subvolume fallback.

The dedicated mdraid selection returned exit 1 with 22 passed, 14
failed and two phased tests skipped. All 14 failed fixtures attempted
`mdadm --readwrite` even when the kernel had already made the array
writable. The fixture now checks the array UUID, kernel array state
and block read-only flag, and only requests a transition if needed.
All 14 reruns passed. That covers bitmap-assisted re-add, full rebuild
control, injected reply and evidence faults, churn, restart, member
re-add and consistency maintenance. The original run passed the RAID
1/4/5/6/10 and double-degraded RAID6 recovery cases.

The NBD reuse rerun reused index 3 with the same kernel disk sequence
859 and a distinct ownership token. The stale request was rejected
before the detach reached the helper. The fixture verified the
replacement payload and removed it under its own token. The NBD
restart fixture verified the original token, exporter, GPT partition
and ext4 payload through the owner change.

The writable NBD rerun exposed `read-only 1/0` with the expected capacity.
The ioctl client sets a block-device read-only flag in addition to the
driver flag. Netlink sets the driver's flag when configuring the next
connection. The ioctl test now selects a previously writable idle
index and restores only that fixture's block-device flag after verifying
its disk sequence and empty state. The installed helper continues to
verify the actual access mode and leaves inherited protection in place.
It observes readiness on the already accepted connection without
dispatching another attach.

The corrected NBD sequence returned exit 0 for the ioctl fixture
and exit 0 for the six-case netlink selection, with five passes and
one prerequisite skip. Writable QCOW2 reattachment, GPT restart,
same-index reuse, exporter termination and interrupted restore all
passed. The default netlink foreground-client test skipped because
the setup process had exited. The dedicated ioctl run observed and
terminated a live, PID-pinned foreground client.

The secondary guest also passed the explicit mdraid phases. A RAID1
reboot retained the original array and member identities, finished
reconstruction and matched the payload checksum. After actual guest
resets, dirty/degraded RAID5 and RAID6 were refused and all member
image checksums matched. The separate Btrfs scrub reboot fixture
verified the resumption marker and matched the payload checksum.
Its observer retained the `unverified readonly` result classification
for the resumed scrub.

The final native `meson setup --reconfigure build --prefix=/usr`,
`meson compile -C build -j 6` and `meson install -C build --no-rebuild`
returned exit 0. The unprivileged default run returned exit 0 with
15 passed, zero failed and 125 skipped. The native opt-in quota
service and observer passed with the installed `/usr/libexec` helpers.
An intermediate focused attempt had copied a driver compiled with a
different prefix. Its helper-path error is retained in the run logs.

### Final native matrix

The final enabled run used the verified `majoris-mdraid-test` QEMU
guest and the opt-ins in the manual register. The command
`meson test -C build --no-rebuild --print-errorlogs --num-processes 1
--timeout-multiplier 3 --logbase stability-combined-final` returned
exit 0 with **136 passed, zero failed, four skipped and zero timeouts**.
It passed all registered ordinary partition/filesystem, LUKS, LVM,
Btrfs, mdraid, imaging, loop, NBD lifecycle, storage model, feature-ID
and GtkBuilder checks. The four skips were the two phased mdraid
targets, the dedicated ioctl NBD target and the netlink foreground
client target. The mdraid phases and ioctl target passed separately.
The installed netlink configuration has no foreground process to
terminate. The native logs are under `build/stability-evidence/`.

### Remaining coverage and restrictions

| Issue | Severity and subsystem | Reproduction, expected behavior and safety | Status and next action |
|---|---|---|---|
| Identity change at each discovery boundary | High, imaging | Independently gate kernel partition publication, UDisks partition publication, filesystem properties, NBD export readiness and NBD detach observation. Substitute the fixture identity at each gate and verify refusal before any new modifying request. | Partial. Live loop source substitution, loop and NBD same-number reuse, and the model's delayed-partition cases cover part of this matrix. Add separate barriers for the remaining boundaries. |
| Delayed LV publication after successful activation | High, LVM | Hold back only the fixture LV after `Manager.LVM2` has appeared. Verify the bounded readiness diagnostic and zero modifying dispatches until the original UUID and mapping appear. | The real restart and delayed rediscovery paths ran. A deterministic hold of one LV's publication remains open. |
| Interactive authorization | Medium, desktop integration | In a GNOME session, exercise approval, denial and cancellation of the existing Polkit-protected image and storage actions. Verify uncertain status if authorization fails during observation of an already accepted setup. | The headless guests covered root authorization and unprivileged refusal. Repeat the interactive cases in a desktop guest. |
| Fresh client during other active jobs | Medium, storage jobs | Restart the application during a Btrfs operation and during an LVM repair. Verify current observation and historical attribution independently, with no operation replay. | Loop and NBD rediscovery and image journal recovery were exercised. Dedicated active Btrfs and LVM process-restart cases remain open. |

The tested NBD configuration uses partition-capable Linux NBD and the
restricted helper for self-contained local images. The default Debian
netlink client exits after configuring the mapping. The foreground
termination test uses the separate ioctl-only fixture. Existing
storage, image format and authorization restrictions apply.

### Changed files

- The service and UI changes are in `src/udisks-service.vala` and
  `src/window.vala`. The loop backing descriptor check is in
  `src/disk-image-copy.vala` and `src/xz-stream.c` and its header.
  The NBD readiness and test-only ioctl changes are in `src/nbd-helper.c`.
- New test files are `tests/btrfs-module-fixture.sh`,
  `tests/loop-dbus-faults.c`, `tests/loop-fault-integration.sh`,
  `tests/lvm-disabled-module.sh`, `tests/nbd-ioctl-integration.sh`,
  `tests/publication-power-loss.sh` and `tests/run-stability-regression.sh`.
- Updated test files are `tests/image-device-test.vala`,
  `tests/lvm-device-test.vala`, `tests/lvm-fixture-test.sh`,
  `tests/lvm-fixture.sh`, `tests/lvm-recovery-integration.sh`,
  `tests/btrfs-profile-conversion-integration.sh`,
  `tests/btrfs-quota-integration.sh`, `tests/btrfs-quota-service-test.vala`,
  `tests/btrfs-scrub-integration.sh`, `tests/mdraid-fixture.sh`,
  `tests/mdraid-bitmap-readd-integration.sh`,
  `tests/mdraid-member-integration.sh` and
  `tests/mdraid-maintenance-integration.sh`. Meson registration and
  the manual acceptance procedure are in `meson.build` and
  `tests/MANUAL-TESTING.md`.
