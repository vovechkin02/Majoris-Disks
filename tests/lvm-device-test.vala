using MajorisDisks;

private async void run_lvm_fixture (string[] args) throws Error {
    if (args.length < 5 || Environment.get_variable ("MAJORIS_DISKS_RUN_LVM_TESTS") != "1" ||
        Posix.getuid () != 0 || !Path.is_absolute (args[1]) || !args[2].has_prefix ("majoris_lvm_") ||
        args[3] == "")
        throw new IOError.PERMISSION_DENIED ("An explicitly enabled disposable LVM fixture is required.");
    var service = new UDisksService ();
    yield service.refresh ();
    StorageVolumeGroup? group = null;
    for (int i = 0; i < 100 && group == null; i++) {
        foreach (var item in service.snapshot.advanced.get_values ()) {
            var current = item as StorageVolumeGroup;
            if (current != null && current.uuid == args[3] && current.name == args[2]) group = current;
        }
        if (group == null) {
            Timeout.add (100, run_lvm_fixture.callback);
            yield;
            yield service.refresh ();
        }
    }
    if (group == null) throw new IOError.NOT_FOUND ("The disposable VG did not appear in UDisks.");
    var paths = new HashTable<string, string> (str_hash, str_equal);
    foreach (var pv in service.snapshot.blocks.get_values ()) {
        if (pv.volume_group != group) continue;
        string backing = pv.loop?.backing_file ?? "";
        if (Path.get_dirname (backing) != args[1] || !Path.get_basename (backing).has_prefix ("pv-") ||
            !backing.has_suffix (".img"))
            throw new IOError.PERMISSION_DENIED ("A VG member is outside the disposable fixture.");
        paths.insert (pv.device, pv.path);
    }
    var anchor = service.lvm_anchor (group);
    if (anchor == null) throw new IOError.NOT_FOUND ("No identifiable disposable PV is available.");
    string identity = service.storage_membership_identity (anchor, false);
    yield service.refresh_lvm_assessment (group.path, group.uuid);
    string missing = string.joinv ("\n", group.missing_pv_uuids);
    var volumes = new HashTable<string, StorageLogicalVolume> (str_hash, str_equal);
    foreach (var item in service.snapshot.advanced.get_values ()) {
        var lv = item as StorageLogicalVolume;
        if (lv != null && lv.group_path == group.path) volumes.insert (lv.name, lv);
    }
    string action = args[4];
    if (action == "rename" && args.length == 6 && args[5].has_prefix ("majoris_lvm_")) {
        yield service.rename_volume_group (anchor, identity, group.uuid, args[5]);
    } else if (action == "layout" && args.length >= 9) {
        uint64 bytes;
        if (!uint64.try_parse (args[7], out bytes)) throw new IOError.INVALID_ARGUMENT ("Invalid fixture size.");
        string[] selected = {};
        for (int i = 8; i < args.length; i++) {
            string? path = paths.lookup (args[i]);
            if (path == null) throw new IOError.NOT_FOUND ("The requested fixture PV is unavailable.");
            selected += path;
        }
        yield service.create_lvm_layout (anchor, identity, group.uuid, args[5], bytes, args[6], selected);
    } else if (action == "assess" && args.length == 9) {
        var lv = volumes.lookup (args[5]);
        if (!group.missing_pvs_known || missing != args[6] || lv == null ||
            (lv.allocation (service.snapshot) == LvmAllocation.COMPLETE ? "complete" : "affected") != args[7] ||
            (service.lvm_repair_candidates (lv).length == 0 ? "blocked" : "candidate") != args[8])
            throw new IOError.FAILED ("The missing-PV assessment did not match the fixture.");
    } else if (action == "repair" && args.length == 8) {
        var lv = volumes.lookup (args[5]);
        var replacement = paths.lookup (args[7]);
        if (lv == null || replacement == null || missing != args[6])
            throw new IOError.NOT_FOUND ("The repair fixture changed.");
        yield service.recover_lvm (anchor, identity, group.uuid, missing, lv.uuid, replacement);
    } else if (action == "cleanup" && args.length == 6 && missing == args[5] && missing != "") {
        yield service.recover_lvm (anchor, identity, group.uuid, missing, "", "");
    } else if (action == "attach" && args.length == 7) {
        var origin = volumes.lookup (args[5]);
        var cache = volumes.lookup (args[6]);
        if (origin == null || cache == null) throw new IOError.NOT_FOUND ("The origin or candidate changed.");
        yield service.change_lvm_cache (anchor, identity, group.uuid, origin.uuid, cache.uuid, false);
    } else if ((action == "split" || action == "detach") && args.length == 6) {
        var origin = volumes.lookup (args[5]);
        if (origin == null) throw new IOError.NOT_FOUND ("The origin changed.");
        yield service.change_lvm_cache (anchor, identity, group.uuid, origin.uuid, "", action == "detach");
    } else {
        throw new IOError.INVALID_ARGUMENT ("Invalid LVM fixture request.");
    }
    stdout.printf ("PASS: %s\n", action);
}

public static int main (string[] args) {
    var loop = new MainLoop ();
    int status = 1;
    Idle.add (() => {
        run_lvm_fixture.begin (args, (object, result) => {
            try {
                run_lvm_fixture.end (result);
                status = 0;
            } catch (Error error) {
                stderr.printf ("FAIL: %s\n", error.message);
            }
            loop.quit ();
        });
        return Source.REMOVE;
    });
    loop.run ();
    return status;
}
