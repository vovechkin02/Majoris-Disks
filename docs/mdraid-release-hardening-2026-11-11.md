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
