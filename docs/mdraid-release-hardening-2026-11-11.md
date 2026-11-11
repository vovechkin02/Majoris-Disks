# Advanced mdraid release-hardening report — 11 November 2026

This pass modifies the existing repository. It does not replace the backend or
produce a replacement ZIP. **Release acceptance remains incomplete.** In
particular, the controlled-write bitmap re-add fixture is refused by the
existing event-counter restriction. Desktop approval, denial, cancellation and
stale-review rejection passed in the disposable GNOME guest.

## Implementation

The live device-reuse test reproduced a stale-review defect: a new same-sized
loop backing device at the same pathname and major/minor could pass a previous
review. `modification_identity()` now includes the current kernel disk sequence
and loop backing file even when dependencies are included. This shared token
protects replacement, spare selection, member transitions and other existing
consumers; the helper's independent identity validation remains intact.

Completion requires writable, UUID-matching kernel geometry, synchronized
expected slots, zero degraded count and agreement with sysfs. A replacement
additionally re-reads native member superblocks at completion and compares member
UUIDs, roles, geometry and event state. Rediscovered observations retain member
identity evidence in memory and cannot attribute completion after identity
substitution. No percentage-only completion or automatic redispatch was added.

Uncertain member calls reconcile current kernel and UDisks topology and record
needs-attention with the actual observed state. An unknown helper exit or lost
reply is not classified as definitively unstarted. Helper exit 126 remains
cancellation; 127 produces an explicit authorization-denied result. These
classifications do not weaken Polkit or allow a helper request without its
independent checks.

RAID Management finds a unique UUID after UDisks object replacement, requires
the original in-session kernel identity, binds action callbacks to its current
block, and disables writes for absent or ambiguous identities. GtkBuilder XML,
Majoris Theme and the existing composition are preserved; no styling changed.

Desktop testing exposed two UI defects. Cancellation of the restricted Polkit
prompt was mislabeled as a UDisks disconnect. Vala generated a premature free
for the nested health-label expression, corrupting the displayed status. The
rebuilt app displayed the correct cancellation, healthy and degraded labels.

Persistent fixture records contain only owned paths, backing inode/size,
machine/boot ID, array/member UUID and observation data. They are private and
root-owned, are never sourced, and contain no replayable destructive command.
Cleanup validates the complete loop set before any mutation and refuses mounted
or identity-substituted resources. Reboot verification and cleanup are separate.
The dirty fixture suppresses mdadm incremental assembly using temporary rules
scoped solely to its backing files, without changing global mdraid policy.

## Required result register

| # | Requested report item | Result |
|---|---|---|
| 1 | Files added/modified | Source: `src/mdraid.vala`, `src/udisks-service.vala`, `src/mdraid-management-view.vala`, `src/window.vala`. Build: `meson.build`. Tests: shared fixture, recovery/service/bitmap tests, new reboot, stopped-dirty, layout, target churn/identity, bitmap re-add, D-Bus timeout and helper interruption fixtures, two preload C modules, and feature-ID validator. Documentation: this report, feature matrix and manual procedures. |
| 2 | GNOME code reused/adapted | Supplied `gnome-disk-utility-main.zip` inspected for ensure-unused, object change and job lifecycle patterns. No GNOME implementation copied or adapted in this pass; no additional copyright attribution required. The separately named comparison/API specification attachments were not present. |
| 3 | Existing RAID functionality | Creation/start/stop/delete, degraded assembly, restricted replacement, spare/member/bitmap/maintenance paths retained. Existing successful live mdraid scenarios rerun. |
| 4 | Interactive Polkit approval | **Passed** with the installed application running as UID 1000 in GNOME. The restricted action prompted for authentication, `pkexec` ran the installed helper as root, the reviewed member became faulty and unassigned, slot 1 remained synchronized, and the payload checksum matched. |
| 5 | Interactive denial/cancellation | **Passed**. GNOME rejected invalid credentials and offered another attempt. A temporary denial rule scoped to the action and disposable user exercised the definitive desktop denial result. The rule was removed before approval. Cancelling the actual prompt and cancelling the in-app review left both images byte-identical. The rebuilt app correctly displayed cancellation. |
| 6 | Reauthorization/stale state | **Passed** for the exercised case. A fresh review prompted again after successful approval. The selected member was removed while the restricted prompt was open. Authentication succeeded, the helper rejected the stale identity, and both backing images matched the hashes recorded after the controlled removal. A valid noninteractive request was denied with exit 127 under the installed policy. |
| 7 | QEMU reboot implementation | Explicit prepare/reboot/verify/cleanup phases, UUID/member/inode manifest, observed recover before reboot, fresh read-only client, final slot/health/checksum verification. Prepare alone cannot pass the Meson reboot target. |
| 8 | Guest reboot execution | Phases executed manually after correcting the fixture's boot-ID check and remote-session reboot handling. Root PID 1 reboot is gated by guest identity and active reconstruction. |
| 9 | Post-reboot verification | **Passed**: fresh client verified current UUID, both member identities and slots, synchronized state, zero degraded count and payload SHA-256 after a real guest reboot. Safe RAID1 auto-read-only assembly is made writable only after ownership validation. |
| 10 | RAID4 | **Passed** disposable reconstruction with intended slot, synchronized members, zero degraded count and checksum. Insufficient-redundancy refusal covered by model. |
| 11 | Alternate RAID10 | **Passed** live refusal for n3/259, f2/513, o2/66049, and odd-count n2/258. Supported even n2/258 reconstruction passed. Unknown layout and sole-copy loss refusal covered by model, not a live sole-copy-loss fixture. |
| 12 | Stopped dirty parity | **Passed** separate RAID5 and RAID6 abrupt guest-reset fixtures: dirty native metadata, no safely running array, service refusal and byte-identical backing files around request. Clean degraded RAID1/5 positive controls passed. Live inconsistent-counter and unknown-cleanliness permutations remain not executed; native-model negatives cover missing cleanliness/unsupported metadata. |
| 13 | Device disappearance | **Passed** owned replacement target detached after review and before service dispatch; no attachment, unchanged degraded count/checksum. Other requested disappearance timings remain not executed. |
| 14 | Device-number reuse | **Passed after fix**: exact same loop pathname/major/minor with different disk sequence and backing image rejects the old review. Original fixture failed, demonstrating the defect. |
| 15 | UDisks restart | **Passed** active reconstruction observer restart and bitmap enabled/disabled rediscovery. External/unknown bitmap presentation only model/manual coverage. |
| 16 | Helper interruption | **Passed** injected pre-dispatch rejection, unknown exit, cancelled/denied authorization codes and lost result after real restricted fault marking. Additional real SIGKILL immediately before and after the helper's SET_DISK_FAULTY ioctl passed: unchanged healthy state before, actual faulty/degraded state after, both conservatively classified without retry. |
| 17 | Backend timeout | **Passed** before-dispatch timeout and lost reply after real AddDevice acceptance. One invocation recorded, no automatic retry; final slot and checksum independently checked. |
| 18 | False completion | **Passed** model negatives for spare/rebuilding/faulty/unknown state, incomplete slots, changed array/member identity, read-only, unknown action and degraded state. Native/sysfs reconciliation exercised by successful live fixtures. |
| 19 | Rebuild verification | Strengthened UUID/writable/slot checks, observation member evidence, native final metadata reads, and post-read reconciliation. |
| 20 | Attribution | In-memory identity evidence strengthened. No durable application operation journal introduced: a new session displays authoritative current state without attributing an unverified historical replacement. The requested journal was conditional; adding a new privileged persistence boundary was not justified. |
| 21 | Bitmap-assisted re-add | **Failed acceptance** for controlled degraded writes: former events 19 versus survivor 22; restricted helper returned 2 without mutation. Existing eligible no-write former-member re-add passed. New fixture records events and measures actual member write sectors if accepted; no partial-resync benefit was claimed. Event-counter validation was deliberately preserved. |
| 22 | Existing mdraid regressions | 16 live cases passed after disk-sequence fix: RAID1/4/5/6/6-double/10, clean degraded RAID1/5 starts, dirty running RAID5 refusal, reconstruction restart, target disappearance/reuse, bitmap, spare/member, maintenance and eligible re-add. Final native verification rerun is recorded in build logs. |
| 23 | Broader regressions | Default storage model, GTK templates and helper regressions passed. Live filesystem capacity, Btrfs replacement/profile/quota/scrub, LVM recovery including RAID1 repair, and LUKS resize passed. Combined-run LVM/LUKS failures were rerun successfully after refreshing UDisks and installing test helpers at their compiled paths. Full broader matrix and mount-restoration live cases were not rerun. |
| 24 | Polkit/security | Policy and helper permissions unchanged. No arbitrary mdadm execution, force assembly, external bitmap mutation, metadata rewriting, reshape or global kernel safety change. Test preload modules are never installed or linked into the app. |
| 25 | UI | UUID-based rebind and current-context callbacks. Desktop checks verified healthy and degraded labels, missing-slot and faulty-member display, reopening the dialog, UDisks restart with the dialog open, and disabled operations after array disappearance. GtkBuilder XML and Majoris Theme were preserved. |
| 26 | Documentation IDs | New mdraid STOR-16…20 definitions moved to MDRAID-01…05. Original JBOD/Btrfs STOR IDs preserved. Validator checks definition tables, allowing follow-up references. 68 unique IDs verified. |
| 27 | Build/tests | Actual Debian 13.5 Meson/Vala/GTK4/libadwaita build and default suite passed. Default suite: 12 passed, 86 skipped, zero failures/timeouts. Skips are opt-in/prerequisite outcomes, not feature evidence. |
| 28 | Skipped/not executed | Additional disappearance timings, UUID substitution during a pending prompt, live sole-copy RAID10 loss, and the complete broader integration matrix remain unexecuted. Phased tests skip without a prepared post-reboot manifest. |
| 29 | Unsupported configurations | RAID10 recovery outside even n2 layout 258; force-start dirty/degraded parity; external bitmap mutation; reshape; member-state transitions outside clean native two-member RAID1; stale event combinations rejected by existing helper. |
| 30 | Remaining release risks | Controlled-write bitmap re-add is outstanding. Some fault permutations have model or controlled-result coverage only. |

## Execution evidence and fixture corrections

Local `build/` logs retain full output (ignored build artifacts):

- `mdraid-baseline-compile.log`, `mdraid-baseline-tests.log`: baseline build,
  ten passed and 74 opt-in skips.
- `mdraid-hardening-compile.log`, `mdraid-hardening-tests.log`: current build
  and default suite.
- `mdraid-hardening-live.log`: reproduced device-reuse failure (134).
- `mdraid-hardening-live-final.log`: all 16 live scenarios passed after fix.
- `mdraid-hardening-live-native-final.log`: rerun with native completion checks.
- `mdraid-hardening-extended-rerun.log`: alternate layout passes, timeout and
  helper classification passes, controlled-write bitmap refusal (2).
- `mdraid-hardening-dirty-raid5-verified.log` and
  `mdraid-hardening-dirty-raid6-verified.log`: dirty/degraded refusal and unchanged
  hashes after real guest resets.
- `mdraid-hardening-reboot-terminal.log`: fresh client verified completed state
  after actual reboot. Earlier reboot logs are development failures, not proof.
- `mdraid-native-check.log`: all six supported replacement variants passed final
  normalized native-member UUID checks.
- `mdraid-helper-kill-check.log`: real helper SIGKILL before/after kernel dispatch
  correctly classified with independent member and checksum checks.
- `mdraid-hardening-broader.log`, `mdraid-hardening-broader-rerun.log`: seven
  representative live storage categories passed, with the initial setup/stale
  object failures retained and the fresh rerun results recorded separately.
- `mdraid-desktop-pkexec-final.log`, `mdraid-desktop-approved.log`,
  `mdraid-desktop-denial.log`, `mdraid-desktop-cancel-final.log`,
  `mdraid-desktop-noninteractive.log`, `mdraid-desktop-stale-verified.log`, and
  `mdraid-desktop-udisks-restart.log` record the graphical and kernel results.
  The desktop PNGs in `build/` capture the prompt, denial, corrected cancellation,
  the recovered dialog, and the stale request rejection.

The initial reboot fixture incorrectly used `cmp -s` against a zero-sized procfs
file and relied on negation with `set -e`. It was corrected to compare actual
boot-ID contents and explicitly exit on an unchanged ID. A verification-only
invocation before reboot was then rejected. A normal remote-session reboot
was denied by logind; the guest-only root phase now uses PID 1 reboot directly.
The post-reboot RAID1 assembly initially waited in auto-read-only mode; ownership
is validated before making that disposable assembly writable. No force assembly
or kernel safety override is involved. The initial far/offset test constants
were corrected to the actual near-one far-two/offset-two layouts.

See `tests/MANUAL-TESTING.md` for complete observable-state procedures and phased
commands. Do not use failed development runs as acceptance evidence.

## Follow-up — bitmap-assisted former-member re-addition after degraded writes

The original controlled-write run in row 21 remains the failure baseline. It
refused a former member at event 19 against a survivor at event 22 because the
helper allowed a difference of exactly one. The follow-up uses the active
array's retained bitmap history and delegates attachment to the existing
restricted `mdadm --manage <array> --re-add <member>` command.

- Linux 6.12 `super_1_validate()` applies the one-event allowance at assembly.
  On a running array, the kernel checks `events_cleared` before assigning the
  former slot and flags covered older members for bitmap synchronization.
  The native reader uses the portable version 4 layout. Its header has no
  checksum. Majoris validates the checksummed native member superblock, bitmap
  magic and array UUID, format and flags, signed location and storage extent,
  chunk size, component size, and agreement with live sysfs. It accepts a
  bitmap event count equal to the survivor's event count or one ahead, as
  documented for the header update order. The retained boundary must be
  positive and no later than the survivor. The former event must fall at or
  after that boundary. A degraded array may legitimately report
  `can_clear=false`. [Kernel validation](https://github.com/torvalds/linux/blob/v6.12/drivers/md/md.c#L1793-L1815) · [Bitmap layout and update ordering](https://github.com/torvalds/linux/blob/v6.12/drivers/md/md-bitmap.h#L25-L54) · [Bitmap sysfs attributes](https://docs.kernel.org/6.12/admin-guide/md.html)
- mdadm 4.4 `attempt_re_add()` checks native membership and requests kernel
  attachment to the original slot. The explicit re-add disposition refuses
  when that attempt fails. Majoris uses the checksummed member metadata and
  the bitmap offset encoded by metadata 1.x. [Manage.c](https://github.com/md-raid-utilities/mdadm/blob/mdadm-4.4/Manage.c#L551-L651) · [super1.c](https://github.com/md-raid-utilities/mdadm/blob/mdadm-4.4/super1.c#L2524-L2555) · [mdadm(8)](https://github.com/md-raid-utilities/mdadm/blob/mdadm-4.4/mdadm.8.in#L1265-L1274)
- The Vala service assesses both native members before presenting the
  confirmation and checks the evidence again under operation locks before
  requesting authorization. The helper repeats the assessment after Polkit
  authorization and checks the review digest against current metadata and
  survivor identity. The supported configuration is clean, idle native
  two-member RAID1 with exactly one unavailable slot. Native metadata readers
  recognize 1.0, 1.1 and 1.2. All three passed the controlled-write fixture. Bitmap formats
  3 and 5, external bitmaps and unverified history fail closed. An equal-event
  former member remains eligible when its metadata and the current
  consistency policy agree. Older uncovered members require a separate
  replacement operation.
- After acceptance, the service tracks kernel recovery of the reviewed slot.
  Completion requires both synchronized members, the original UUIDs and
  identities, native metadata checks, idle synchronization and zero degraded
  slots. Lost or ambiguous results are reconciled from kernel topology with
  no automatic retry. The confirmation and progress text use the existing
  GTK4/libadwaita composition. The Polkit action and helper privileges are
  unchanged.

The GNOME Disk Utility archive was consulted for asynchronous UDisks callbacks,
device-use checks and job presentation in `gduutils.c/.h`, `gdu-manager.c`,
`gdu-block-row.c`, `gdu-job-manager.c`, `gdulocaljob.c` and `gdu-job-row.c`.
Majoris reuses its existing UDisks, safety and job code. The RAID eligibility
rules come from mdadm and Linux.

The native implementation is in `src/mdraid-superblock.c/.h` and
`src/mdraid-helper.c`. The review and monitoring changes are in
`src/mdraid.vala`, `src/udisks-service.vala`, `src/window.vala` and
`src/mdraid-management-view.vala`. Meson registers the scenarios implemented
in `tests/mdraid-bitmap-readd-integration.sh`, `tests/mdraid-fixture.sh`,
`tests/mdraid-helper-faults.c`, `tests/mdraid-service-test.vala` and
`tests/mdraid-target-churn.sh`. Test fault hooks run only inside the disposable
fixtures.

### Controlled-write execution

**Passed** in disposable Debian 13 QEMU with mdadm 4.4-11 and UDisks
2.10.1-12.1+deb13u2. The 1 MiB write at 8 MiB was made with one member absent.
The former member was at event 19 and the survivor at 22. The version 4 bitmap
reported event 22, cleared boundary 18, a 64 MiB chunk and one dirty bit out of
two. Observed kernel recovery samples included 51,200 and 122,880 of 161,792
sectors. The returning member received 131,103 sectors of writes including
metadata, below the 161,792-sector component size. The original member UUID
and slot 0 were retained, both members ended synchronized, the degraded count
was zero, and the 16 MiB payload SHA-256 matched
`2eedaedde1ebeb52746c58712081c6eaa0fd2f2fc55033585024637b28da4256`.
The full trace is in `build/bitmap-readd-guest.log`.

The independent Meson rerun reproduced the same 131,103-sector write count
with former event 18, survivor and bitmap event 21, and cleared boundary 17.
The fresh-device control refused the old member without bitmap history and
used the supported replacement operation. It wrote 161,812 sectors to a
161,792-sector component. Both targets synchronized in slot 0 and both arrays
passed their payload checks. The rerun and control SHA-256 values were
`39aac3b8da87b928fe9c69db4d037542718f36ac673f8b23fd3cfe509a5e316d` and
`b2b7872a1f2a396ae143cd89d1b7aa298b16b946e18805c92063cacc533322af`.
The guest trace is in `build/bitmap-readd-final-mdraid-suite.log`.

Controlled-write reruns with native metadata 1.0 and 1.1 also passed. The
returning members each wrote 131,103 sectors, compared with components of
163,712 and 161,792 sectors respectively, with original slot 0 and verified
payload hashes. The variant runs are in `build/bitmap-readd-extra-checks.log`.

The phased RAID1 reboot passed with a changed boot ID and fresh-client
verification of the UUID, both member identities and slots, synchronization,
and payload. The RAID5 and RAID6 abrupt guest resets both preserved dirty
metadata and produced a safe refusal with byte-identical backing images.
The verification logs are `build/bitmap-readd-phased-reboot-verify.log` and
`build/bitmap-readd-phased-dirty-raid{5,6}-verify.log`.

### Faults and regression coverage

- **Passed** for truncated, unreadable, missing or stale bitmap history,
  invalid on-disk and sysfs offsets, version, UUID, flags, chunk size and
  counters, unknown kernel state, and conflicting UDisks/sysfs bitmap
  reports. Invalid former-member geometry, newer events, array UUID, native
  version and slot were refused. A separate case changed the member UUID in
  the privileged request and verified rejection.
- **Passed** for disappearance after review and before authorization,
  disappearance at the authorization boundary and after the helper started,
  kernel device-number reuse, return at a different path, and a change in
  bitmap evidence seen by the authorized helper. The authorization-boundary
  tests stage the change before invoking real pkexec in the headless guest.
- **Passed** for a verification timeout after a simulated successful reply,
  and real helper termination immediately before dispatch and after mdadm
  accepted the member. Failure and detachment of the returning member after
  observed attachment also passed. The first detachment attempt was too
  early and returned `EBUSY`. The rerun waited for the kernel to stop recovery
  and report the member faulty before removing the owned loop. UDisks restart
  during active re-add recovery passed with fresh-client terminal verification.
- **Passed** for all 36 applicable mdraid Meson cases across the full run and
  focused reruns. The reboot and stopped dirty parity entries required the
  separate phases above. This includes no-write re-add, bitmap settings,
  spare add/remove, fault marking, consistency maintenance, supported
  RAID1/4/5/6/10 reconstruction and RAID6 double loss, alternate RAID10 layout
  refusals, identity churn and UDisks timeout reconciliation.
- **Not executed** for physical loss of the surviving member during
  reconstruction and for a new graphical Polkit prompt on the bitmap path.
  The operation monitors the reviewed survivor and reports an uncertain
  result if its identity or synchronized state disappears. The graphical
  evidence in the original report applies to the earlier fault-marking flow.

The complete mdraid run and corrected fault rerun are recorded in
`build/bitmap-readd-final-mdraid-suite.log` and
`build/bitmap-readd-final-faults.log`. The Debian 13 Meson build succeeded.
The default suite passed 12 cases, skipped 97 opt-in or phased cases, and
reported zero failures.

### Broader storage execution

The opted-in Debian QEMU Meson run initially recorded 58 passes, 12 failures
and 39 skips. The skips included 36 mdraid integration targets executed in
their own run. The other three skipped cases required additional loop or
virtual-image prerequisites. The initial run passed Btrfs device replacement,
scrub, traditional and simple quotas, most profile conversions, filesystem
capacity, mount restoration, LVM layout, LUKS mapping restoration and
configuration, storage-model tests and GTK templates.

The detailed commands and original diagnostics are in
`build/bitmap-readd-guest-storage-suite.log`. Fresh-UDisks and helper setup
reruns passed the two failed Btrfs profile cases, LVM recovery including
RAID1 repair, LVM cache, LUKS mapping resize and LUKS partition resize.
Virtual image growth passed after installing its prerequisites. See
`build/bitmap-readd-storage-retry.log` and
`build/bitmap-readd-storage-prerequisites.log`.

The remaining storage failures were:

| Case | Result |
|---|---|
| Btrfs quota service | Failed after restart and helper setup. Both original and updated binaries failed in a second guest. The standalone traditional, simple and injected quota cases passed. |
| Raw, compressed and partition imaging (four cases) | Both revisions reproduced the same detach refusal in an independent guest. |
| GPT/MBR loop fixture | UDisks rejected the extended-partition resize from 80 MiB to 90 MiB. This fixture calls UDisks directly and reached that step after the preceding GPT and MBR operations and filesystem checks. |
| LUKS header integration | The original guest run hit an active device-mapper holder. The rerun verified LUKS1 header and keyslot cases and several LUKS2 cases, then timed out at the 300-second fixture limit during the LUKS2 keyslot sequence. |
| Virtual NBD integration | The fixture ran after installing its prerequisites and using a systemd-managed runtime directory. The virtual partition and filesystem were not discovered. See `build/bitmap-readd-nbd-runtime.log`. |

The comparison logs are `build/bitmap-readd-imaging-baseline-final.log` and
`build/bitmap-readd-extra-checks.log`. These outcomes leave broader storage
sign-off open.
