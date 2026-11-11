using MajorisDisks;

private MdRaidTopology? topology (uint expected, string rows) throws Error {
    return MdRaidTopology.parse (Variant.parse (new VariantType ("a(oiasta{sv})"), rows), expected);
}

private void test_topology () throws Error {
    var parity = topology (4, "[('/a', 0, ['in_sync'], 7, {}), ('/b', 2, ['in_sync'], 0, {})]");
    assert (parity != null && parity.members[0].read_errors == 7);
    assert (parity.missing_slots.length == 2 && parity.missing_slots[0] == 1 && parity.missing_slots[1] == 3);
    assert (parity.can_reconstruct ("raid6", "", 4));
    assert (!parity.can_reconstruct ("raid5", "", 4));
    assert (parity.can_reconstruct ("raid10", "258", 4));
    assert (!parity.can_reconstruct ("raid10", "514", 4));
    var same_pair = topology (4, "[('/a', 0, ['in_sync'], 0, {}), ('/b', 1, ['in_sync'], 0, {})]");
    assert (!same_pair.can_reconstruct ("raid10", "258", 4));
    var spare = topology (2, "[('/a', 0, ['in_sync'], 0, {}), ('/b', -1, ['spare', 'future'], 0, {})]");
    assert (spare.synchronized_count == 1 && spare.members[1].states[1] == "future");
    assert (!spare.can_reconstruct ("raid1", "", 2));
    assert (topology (2, "[('/a', 0, ['in_sync'], 0, {}), ('/b', 0, ['in_sync'], 0, {})]") == null);
    assert (topology (2, "[('/a', 0, ['in_sync'], 0, {}), ('/a', -1, ['spare'], 0, {})]") == null);
    assert (MdRaidTopology.parse (new Variant.string ("invalid"), 2) == null);
    assert (MdRaidKernelState.bitmap_kind ("+8") == "internal");
    assert (MdRaidKernelState.bitmap_kind ("file") == "external");
    assert (MdRaidKernelState.bitmap_kind ("") == "unknown");
    var complete = topology (2, "[('/a', 0, ['in_sync'], 0, {}), ('/b', 1, ['in_sync'], 0, {})]");
    assert (complete.synchronized_slots (2));
    foreach (string state in new string[] { "faulty", "blocked", "spare", "replacement", "unknown" }) {
        var incomplete = topology (2, "[('/a', 0, ['in_sync'], 0, {}), ('/b', 1, ['%s'], 0, {})]".printf (state));
        assert (!incomplete.synchronized_slots (2));
    }
    assert (!spare.synchronized_slots (2));
    assert (!complete.synchronized_slots (3));
    assert (complete.member_evidence () == "");
    foreach (var member in complete.members) {
        member.array_uuid = "array";
        member.metadata_uuid = member.path;
        member.kernel_identity = member.path + ":1";
    }
    string evidence = complete.member_evidence ();
    complete.members[0].metadata_uuid = "substituted";
    assert (complete.member_evidence () != evidence);
    var kernel = new MdRaidKernelState ();
    string uuid = "12345678:12345678:12345678:12345678";
    kernel.uuid = uuid; kernel.level = "raid1"; kernel.expected = 2;
    kernel.state = "clean"; kernel.action = "idle"; kernel.degraded = "0";
    assert (kernel.terminal_health (uuid, "raid1", 2));
    assert (!kernel.terminal_health ("87654321:12345678:12345678:12345678", "raid1", 2));
    assert (!kernel.terminal_health (uuid, "raid5", 2));
    assert (!kernel.terminal_health (uuid, "raid1", 3));
    foreach (string action in new string[] { "recover", "resync", "frozen", "unknown", "" }) {
        kernel.action = action;
        assert (!kernel.terminal_health (uuid, "raid1", 2));
    }
    kernel.action = "idle";
    foreach (string state in new string[] { "readonly", "inactive", "clear", "" }) {
        kernel.state = state;
        assert (!kernel.terminal_health (uuid, "raid1", 2));
    }
    kernel.state = "clean"; kernel.degraded = "1";
    assert (!kernel.terminal_health (uuid, "raid1", 2));
    foreach (string layout in new string[] { "259", "514", "far", "66050", "0", "", "unknown" })
        assert (!parity.can_reconstruct ("raid10", layout, 4));
    assert (!MdRaidTopology.recoverable_slots ("raid10", "258", 5, { 0 }));
    assert (!MdRaidTopology.recoverable_slots ("raid10", "258", 4, { 0, 1 }));
    assert (!MdRaidTopology.recoverable_slots ("raid4", "0", 3, { 0, 1 }));
    var metadata = new MdRaidSuperblock ();
    metadata.slot = 0; metadata.expected = 3; metadata.component_sectors = 1024;
    metadata.events = 10; metadata.member_uuid = "member"; metadata.resync_offset = uint64.MAX;
    assert (metadata.usable ());
    metadata.resync_offset = 0;
    assert (!metadata.usable ());
    metadata.resync_offset = uint64.MAX; metadata.events = 0;
    assert (!metadata.usable ());
    metadata.events = 10; metadata.features = 2;
    assert (!metadata.usable ());
    metadata.features = 0; metadata.slot = 3;
    assert (!metadata.usable ());
}

private bool owned_loop (StorageBlock block, string fixture) {
    string backing = block.loop?.backing_file ?? "";
    return backing != "" && Path.get_dirname (backing) == fixture && Path.get_basename (backing).has_suffix (".img");
}

private async void exercise (string[] args) throws Error {
    if (args.length != 7 || Posix.getuid () != 0 ||
        Environment.get_variable ("MAJORIS_DISKS_RUN_MDRAID_TESTS") != "1" ||
        Environment.get_host_name () != "majoris-mdraid-test")
        throw new IOError.PERMISSION_DENIED ("The dedicated disposable mdraid guest is required.");
    string fixture = args[2];
    Posix.Stat stat;
    int stat_result = Posix.lstat (fixture, out stat);
    if ((!fixture.has_prefix ("/tmp/majoris-mdraid.") && !fixture.has_prefix ("/var/tmp/majoris-mdraid.")) || stat_result != 0 ||
        !Posix.S_ISDIR (stat.st_mode) || stat.st_uid != 0 || (stat.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("The fixture directory must be private and owned by root.");
    var backend = new UDisksService ();
    StorageBlock? anchor = null;
    StorageBlock? target = null;
    string action = args[1];
    if (action == "start-degraded" || action == "refuse-start") {
        for (int i = 0; i < 40 && anchor == null; i++) {
            yield backend.refresh ();
            foreach (var candidate in backend.snapshot.blocks.get_values ()) {
                if (candidate.device != args[4] || !owned_loop (candidate, fixture) ||
                    candidate.logical_sector_size == 0 || candidate.raid_membership?.uuid != args[3] ||
                    !backend.can_start_degraded_raid (candidate))
                    continue;
                anchor = candidate;
            }
            if (anchor == null) {
                Timeout.add (250, exercise.callback);
                yield;
            }
        }
        if (anchor == null) {
            foreach (var candidate in backend.snapshot.blocks.get_values ())
                if (owned_loop (candidate, fixture))
                    stderr.printf ("%s member %s array %s running %s\n", candidate.device, candidate.raid_member_path,
                        candidate.raid_membership?.uuid ?? "", (candidate.raid_membership?.running ?? false).to_string ());
            throw new IOError.NOT_FOUND ("The stopped fixture array was not found.");
        }
        foreach (var member in backend.snapshot.blocks.get_values ())
            if (member.raid_membership == anchor.raid_membership && !owned_loop (member, fixture))
                throw new IOError.PERMISSION_DENIED ("The stopped array has a member outside the fixture.");
        if (action == "refuse-start") {
            bool refused = false;
            try {
                yield backend.set_raid_running (anchor, true, backend.storage_membership_identity (anchor, true), true);
            } catch (IOError.NOT_SUPPORTED error) { refused = true; }
            assert (refused);
            print ("unsafe-stopped-array-refused\n");
        } else
            yield backend.set_raid_running (anchor, true, backend.storage_membership_identity (anchor, true), true);
        return;
    }
    for (int i = 0; i < 40; i++) {
        yield backend.refresh ();
        foreach (var block in backend.snapshot.blocks.get_values ()) {
            if (block.device == args[4] && block.raid?.uuid == args[3]) anchor = block;
            if (block.device == args[5] && owned_loop (block, fixture)) target = block;
        }
        if (anchor?.raid?.kernel != null && anchor.raid.topology != null && anchor.logical_sector_size > 0 &&
            (args[5] == "-" || (target != null && target.logical_sector_size > 0)) &&
            (action == "observe-terminal" || anchor.raid.degraded.to_string () == args[6]) &&
            (action == "observe" || action == "observe-terminal" || (anchor.raid.kernel.action == "idle" && anchor.raid.state == "idle")) &&
            (action != "replace" || backend.can_replace_missing_raid_member (anchor)))
            break;
        Timeout.add (250, exercise.callback);
        yield;
    }
    if (anchor?.raid?.topology == null || anchor.raid.kernel == null ||
        (action != "observe-terminal" && anchor.raid.degraded.to_string () != args[6]) || anchor.raid.topology.members.length == 0)
        throw new IOError.NOT_FOUND ("The fixture array and its topology were not verified.");
    foreach (var row in anchor.raid.topology.members)
        if (row.block == null || !owned_loop (row.block, fixture))
            throw new IOError.PERMISSION_DENIED ("The array has a member outside the fixture.");
    if (args[5] != "-" && target == null)
        throw new IOError.NOT_FOUND ("The fixture target was not found.");
    string review = backend.raid_review_identity (anchor);
    string target_identity = target != null ? backend.modification_identity (target) : "";
    print ("%s %s: kernel=%s layout=%s policy=%s bitmap=%s degraded=%u\n", action, anchor.raid.level,
        anchor.raid.kernel.state, anchor.raid.kernel.layout, anchor.raid.kernel.policy,
        anchor.raid.kernel.bitmap, anchor.raid.degraded);
    switch (action) {
    case "expect-helper-failure":
        if (target == null) throw new IOError.INVALID_ARGUMENT ("A fixture member is required.");
        bool helper_failed = false;
        try {
            yield backend.change_raid_member_state (anchor, target, false, review, target_identity);
        } catch (Error error) {
            helper_failed = true;
            string mode = Environment.get_variable ("MAJORIS_MDRAID_HELPER_FAULT") ?? "";
            if (mode == "cancel") assert (error is IOError.CANCELLED);
            else if (mode == "deny") assert (error is IOError.PERMISSION_DENIED);
            else assert (error is IOError.FAILED);
        }
        assert (helper_failed);
        bool classified = false;
        for (uint n = 0; n < backend.jobs.jobs.get_n_items (); n++) {
            var job = backend.jobs.jobs.get_item (n) as StorageJob;
            if (job.operation != "Mark RAID member faulty") continue;
            assert (job.result != null && !job.result.successful);
            string mode = Environment.get_variable ("MAJORIS_MDRAID_HELPER_FAULT") ?? "";
            bool unknown = mode == "unknown" || mode == "after" || mode.has_prefix ("kill-");
            assert ((job.result.status == StorageOperationStatus.NEEDS_ATTENTION) == unknown);
            classified = true;
        }
        assert (classified);
        print ("helper-result-classified\n");
        break;
    case "expect-timeout":
        if (target == null) throw new IOError.INVALID_ARGUMENT ("A fixture target is required.");
        bool timed_out = false;
        try {
            yield backend.change_raid_member (anchor, target, true, backend.modification_identity (anchor),
                target_identity, true, review);
        } catch (IOError.TIMED_OUT error) { timed_out = true; }
        assert (timed_out);
        bool uncertain = false;
        for (uint n = 0; n < backend.jobs.jobs.get_n_items (); n++) {
            var job = backend.jobs.jobs.get_item (n) as StorageJob;
            if (job.operation != "Replace missing RAID member") continue;
            assert (job.result != null && !job.result.successful);
            uncertain = job.result.status == StorageOperationStatus.NEEDS_ATTENTION;
        }
        assert (uncertain);
        print ("uncertain-dispatch-not-retried\n");
        break;
    case "reject-target-disappearance":
    case "reject-target-reuse":
        if (target == null) throw new IOError.INVALID_ARGUMENT ("A fixture target is required.");
        string anchor_identity = backend.modification_identity (anchor);
        string churn_script = Environment.get_variable ("MAJORIS_MDRAID_CHURN_SCRIPT") ?? "";
        if (churn_script == "") throw new IOError.INVALID_ARGUMENT ("The fixture churn script is required.");
        var churn = new Subprocess.newv ({ "/bin/sh", churn_script, fixture, target.device, action }, SubprocessFlags.NONE);
        yield churn.wait_check_async ();
        yield backend.refresh ();
        bool rejected = false;
        try {
            yield backend.change_raid_member (anchor, target, true, anchor_identity, target_identity, true, review);
        } catch (IOError.NOT_FOUND error) { rejected = true;
        } catch (IOError.NOT_SUPPORTED error) { rejected = true;
        } catch (IOError.BUSY error) { rejected = true; }
        assert (rejected);
        print ("stale-target-rejected\n");
        break;
    case "observe-terminal":
        // Read-only rediscovery after a reboot may miss the entire active rebuild.
        for (int i = 0; i < 1200; i++) {
            yield backend.refresh ();
            foreach (var candidate in backend.snapshot.blocks.get_values ()) {
                var raid = candidate.raid;
                if (raid?.uuid != args[3] || raid.kernel == null || raid.topology == null) continue;
                if (raid.degraded == 0 && raid.state == "idle" &&
                    raid.kernel.terminal_health (raid.uuid, raid.level, raid.expected_members) &&
                    raid.topology.synchronized_slots (raid.expected_members) && raid.kernel.verify_members (raid.topology)) {
                    print ("terminal-health-verified\n");
                    return;
                }
            }
            Timeout.add (250, exercise.callback);
            yield;
        }
        throw new IOError.TIMED_OUT ("Post-reboot health was not verified.");
    case "observe":
        bool observed = false;
        for (int i = 0; i < 400; i++) {
            foreach (var candidate in backend.snapshot.blocks.get_values ()) {
                if (candidate.device != args[4] || candidate.raid?.uuid != args[3] || candidate.raid.kernel == null)
                    continue;
                var raid = candidate.raid;
                if (!observed && raid.kernel.action == "recover") {
                    for (uint n = 0; n < backend.jobs.jobs.get_n_items (); n++) {
                        var job = backend.jobs.jobs.get_item (n) as StorageJob;
                        if (job.operation == "RAID member reconstruction" && job.state == StorageJobState.RUNNING) {
                            observed = true;
                            print ("rebuild-observed\n");
                            stdout.flush ();
                            break;
                        }
                    }
                }
                if (observed && raid.kernel.action == "idle" && raid.degraded == 0 &&
                    raid.topology != null && raid.topology.missing_slots.length == 0 &&
                    raid.kernel.verify_members (raid.topology))
                    return;
            }
            Timeout.add (250, exercise.callback);
            yield;
        }
        throw new IOError.TIMED_OUT ("The reopened observer did not verify the rebuild.");
    case "replace":
    case "add-spare":
    case "remove-spare":
        if (target == null) throw new IOError.INVALID_ARGUMENT ("A fixture member is required.");
        print ("%s\n", yield backend.change_raid_member (anchor, target, action != "remove-spare",
            backend.modification_identity (anchor), backend.modification_identity (target), action == "replace", review));
        break;
    case "bitmap-enable":
    case "bitmap-disable":
        yield backend.set_raid_bitmap (anchor, action == "bitmap-enable", review);
        break;
    case "check-cancel":
    case "check":
    case "repair":
        bool repair = action == "repair";
        bool cancel = action == "check-cancel";
        bool finished = false;
        bool requested = false;
        bool cancelled = false;
        string summary = "";
        Error? failure = null;
        backend.start_raid_check.begin (anchor, repair, review, (object, result) => {
            try { summary = backend.start_raid_check.end (result); }
            catch (Error error) { failure = error; }
            finished = true;
        });
        for (int i = 0; i < 700 && !finished; i++) {
            requested |= anchor.raid?.kernel?.action == (repair ? "repair" : "check");
            if (cancel && !cancelled) {
                for (uint n = 0; n < backend.jobs.jobs.get_n_items (); n++) {
                    var job = backend.jobs.jobs.get_item (n) as StorageJob;
                    if (job.operation != "RAID consistency check" || !job.cancelable) continue;
                    yield backend.cancel_job (job);
                    cancelled = true;
                    break;
                }
            }
            Timeout.add (100, exercise.callback);
            yield;
        }
        if (!finished || !requested || (cancel && !cancelled))
            throw new IOError.FAILED ("The requested maintenance action was not observed.");
        if (cancel && (failure != null || !summary.has_suffix ("stopped")))
            throw new IOError.FAILED ("The check cancellation outcome was not verified.");
        // The independent fixture verifies the kernel's terminal state. A client
        // that missed the final progress sample may report uncertainty.
        if (!cancel && failure != null && (!(failure is IOError.FAILED) ||
            !failure.message.contains ("completed or was interrupted")))
            throw failure;
        print ("%s\n", failure?.message ?? summary);
        break;
    case "refuse":
        assert (!backend.can_replace_missing_raid_member (anchor));
        break;
    case "reject-stale-review":
        if (target == null) throw new IOError.INVALID_ARGUMENT ("A fixture target is required.");
        try {
            yield backend.change_raid_member (anchor, target, true, backend.modification_identity (anchor),
                backend.modification_identity (target), true, review + "-changed");
            assert_not_reached ();
        } catch (IOError.NOT_SUPPORTED error) {
            print ("Rejected a changed reconstruction review\n");
        }
        break;
    default:
        throw new IOError.INVALID_ARGUMENT ("Unknown fixture operation.");
    }
}

int main (string[] args) {
    try { test_topology (); }
    catch (Error error) { stderr.printf ("%s\n", error.message); return 1; }
    if (args.length == 1) return 0;
    var loop = new MainLoop ();
    int status = 0;
    exercise.begin (args, (source, result) => {
        try { exercise.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
