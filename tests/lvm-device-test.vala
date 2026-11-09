using MajorisDisks;

private async Variant read_lvm_property (string path, string iface, string property) throws Error {
    var bus = yield Bus.get (BusType.SYSTEM);
    var reply = yield bus.call ("org.freedesktop.UDisks2", path, "org.freedesktop.DBus.Properties", "Get",
        new Variant ("(ss)", "org.freedesktop.UDisks2." + iface, property), new VariantType ("(v)"),
        DBusCallFlags.NONE, 5000);
    return reply.get_child_value (0).get_variant ();
}

private bool has_unresolved_segment (Variant value) {
    if (value.is_of_type (VariantType.VARDICT)) {
        if (value.lookup_value ("type", VariantType.STRING)?.get_string () == "error") return true;
        var segments = value.lookup_value ("segments", new VariantType ("a(tto)")) ??
            value.lookup_value ("segs", new VariantType ("a(tto)"));
        if (segments != null && segments.n_children () == 0) return true;
    }
    if (value.is_of_type (new VariantType ("(tto)")))
        return value.get_child_value (2).get_string () == "/";
    if (value.is_container ())
        for (size_t i = 0; i < value.n_children (); i++)
            if (has_unresolved_segment (value.get_child_value (i))) return true;
    return false;
}

private async void run_lvm_fixture (string[] args) throws Error {
    if (args.length < 5 || Environment.get_variable ("MAJORIS_DISKS_RUN_LVM_TESTS") != "1" ||
        Posix.getuid () != 0 || !Path.is_absolute (args[1]) || !args[2].has_prefix ("majoris_lvm_") ||
        args[3] == "")
        throw new IOError.PERMISSION_DENIED ("An explicitly enabled disposable LVM fixture is required.");
    Posix.Stat directory;
    if (Posix.lstat (args[1], out directory) != 0 || !Posix.S_ISDIR (directory.st_mode) ||
        directory.st_uid != 0 || (directory.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("The disposable fixture directory must be private and owned by root.");
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
    yield service.refresh_lvm_assessment (group.path, group.uuid);
    var paths = new HashTable<string, string> (str_hash, str_equal);
    foreach (var pv in service.snapshot.blocks.get_values ()) {
        if (pv.volume_group != group) continue;
        string backing = pv.loop?.backing_file ?? "";
        if (Path.get_dirname (backing) != args[1] || !Path.get_basename (backing).has_prefix ("pv-") ||
            !backing.has_suffix (".img"))
            throw new IOError.PERMISSION_DENIED ("A VG member is outside the disposable fixture.");
        string record = backing.substring (0, backing.length - 4);
        string expected_identity, expected_uuid;
        FileUtils.get_contents (record + ".identity", out expected_identity);
        FileUtils.get_contents (record + ".uuid", out expected_uuid);
        Posix.Stat image;
        if (Posix.lstat (backing, out image) != 0 || !Posix.S_ISREG (image.st_mode) ||
            expected_identity.strip () != @"$((uint64) image.st_dev):$((uint64) image.st_ino):$((uint64) image.st_size)" ||
            pv.uuid != expected_uuid.strip ())
            throw new IOError.PERMISSION_DENIED ("A disposable PV or its backing image changed.");
        paths.insert (pv.device, pv.path);
    }
    var anchor = service.lvm_anchor (group);
    if (anchor == null) throw new IOError.NOT_FOUND ("No identifiable disposable PV is available.");
    string identity = service.lvm_membership_identity (anchor);
    string missing = string.joinv ("\n", group.missing_pv_uuids);
    var volumes = new HashTable<string, StorageLogicalVolume> (str_hash, str_equal);
    foreach (var item in service.snapshot.advanced.get_values ()) {
        var lv = item as StorageLogicalVolume;
        if (lv != null && lv.group_path == group.path) volumes.insert (lv.name, lv);
    }
    string expected = "";
    if (args[4] == "reject" && args.length >= 7) {
        expected = args[5];
        string[] request = { args[0], args[1], args[2], args[3] };
        for (int i = 6; i < args.length; i++) request += args[i];
        yield exercise_lvm_fixture (request, service, group, anchor, identity, paths, volumes, missing, expected);
    } else {
        yield exercise_lvm_fixture (args, service, group, anchor, identity, paths, volumes, missing, expected);
    }
}

private async void exercise_lvm_fixture (string[] args, UDisksService service, StorageVolumeGroup group,
    StorageBlock anchor, string identity, HashTable<string, string> paths,
    HashTable<string, StorageLogicalVolume> volumes, string missing, string expected) throws Error {
    string action = args[4];
    try {
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
            var allocation = args[7] == "complete" ? LvmAllocation.COMPLETE : LvmAllocation.INCOMPLETE;
            bool matched = false;
            for (int attempt = 0; attempt < 30; attempt++) {
                if (lv != null && group.missing_pvs_known && string.joinv ("\n", group.missing_pv_uuids) == args[6] &&
                    lv.allocation (service.snapshot) == allocation &&
                    (service.lvm_repair_candidates (lv).length == 0 ? "blocked" : "candidate") == args[8]) {
                    matched = true;
                    break;
                }
                yield service.refresh_lvm_assessment (group.path, group.uuid);
                Timeout.add (200, exercise_lvm_fixture.callback);
                yield;
                if (lv != null) lv = service.snapshot.advanced.lookup (lv.path) as StorageLogicalVolume;
            }
            if (!matched || lv == null) throw new IOError.FAILED ("The missing-PV assessment did not match the fixture.");
            var raw_missing = yield read_lvm_property (group.path, "VolumeGroup", "MissingPhysicalVolumes");
            var raw_structure = yield read_lvm_property (lv.path, "LogicalVolume", "Structure");
            stdout.printf ("UDisks Structure: %s\n", raw_structure.print (true));
            if (!raw_missing.is_of_type (VariantType.STRING_ARRAY) ||
                string.joinv ("\n", raw_missing.dup_strv ()) != args[6] ||
                !raw_structure.is_of_type (VariantType.VARDICT) ||
                has_unresolved_segment (raw_structure) != (args[7] == "affected"))
                throw new IOError.FAILED ("The live UDisks properties did not match the fixture assessment.");
            stdout.printf ("VG %s, LV %s, layout %s, allocation %s, SyncRatio %g, missing PVs: %s\n",
                group.uuid, lv.uuid, lv.lvm_layout, args[7], lv.sync_ratio, args[6]);
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
        } else if (action == "cache-status" && (args.length == 7 || args.length == 9)) {
            var origin = volumes.lookup (args[5]);
            if (origin == null) throw new IOError.NOT_FOUND ("The origin changed.");
            var cache = yield service.inspect_lvm_cache (group.path, group.uuid, origin.name, origin.uuid);
            if (!cache.active_dm_cache () || cache.pool_name == "" || cache.pool_uuid != args[6] ||
                !cache.usage_known || (args.length == 9 && (cache.mode != args[7] ||
                args[8] != "clean" || cache.separation_block_reason != "")))
                throw new IOError.FAILED ("The active cache report did not match the fixture.");
            stdout.printf ("Cache %s (%s), mode %s, dirty blocks %s of %s\n",
                cache.pool_name, cache.pool_uuid, cache.mode, cache.dirty_blocks.to_string (), cache.total_blocks.to_string ());
        } else if ((action == "split" || action == "detach") && args.length == 6) {
            var origin = volumes.lookup (args[5]);
            if (origin == null) throw new IOError.NOT_FOUND ("The origin changed.");
            yield service.change_lvm_cache (anchor, identity, group.uuid, origin.uuid, "", action == "detach");
        } else {
            throw new IOError.INVALID_ARGUMENT ("Invalid LVM fixture request.");
        }
    } catch (Error error) {
        if (expected != "" && error.message.contains (expected) && DBusError.get_remote_error (error) == null) {
            stdout.printf ("PASS: %s rejected: %s\n", action, error.message);
            return;
        }
        throw error;
    }
    if (expected != "") throw new IOError.FAILED ("The operation unexpectedly succeeded.");
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
