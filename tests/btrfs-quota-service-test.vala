using MajorisDisks;

private async void exercise (string[] args) throws Error {
    if ((args.length != 3 && args.length != 4) || Posix.getuid () != 0 ||
        Environment.get_variable ("MAJORIS_DISKS_RUN_BTRFS_QUOTA_TESTS") != "1" ||
        !Uuid.string_is_valid (args[2]) || !Path.is_absolute (args[1]))
        throw new IOError.PERMISSION_DENIED ("A disposable Btrfs quota fixture is required.");
    Posix.Stat stat;
    if (Posix.lstat (args[1], out stat) != 0 || !Posix.S_ISDIR (stat.st_mode) ||
        stat.st_uid != 0 || (stat.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("The quota fixture must be private and owned by root.");

    var backend = new UDisksService ();
    StorageBlock? block = null;
    for (int i = 0; i < 40 && block == null; i++) {
        yield backend.refresh ();
        foreach (var candidate in backend.snapshot.blocks.get_values ()) {
            if (candidate.uuid != args[2] || candidate.type_id != "btrfs") continue;
            if (candidate.loop?.backing_file != args[1] + "/quota.img")
                throw new IOError.PERMISSION_DENIED ("The Btrfs member is outside the test fixture.");
            if (candidate.logical_sector_size != 0 &&
                args[1] + "/mount" in (candidate.filesystem?.mounts ?? new string[0]))
                block = candidate;
        }
        if (block == null) {
            Timeout.add (250, exercise.callback);
            yield;
        }
    }
    if (block == null) throw new IOError.NOT_FOUND ("UDisks did not identify the quota fixture.");
    string identity = backend.modification_identity (block);
    var status = yield backend.query_btrfs_quota (block, identity);
    if (args.length == 4) {
        if (!(args[3] in new string[] { "watch", "observe" }))
            throw new IOError.INVALID_ARGUMENT ("Invalid observer mode.");
        while (true) {
            if (status.running) print ("rescan-running\n");
            else if (status.mode == BtrfsQuotaMode.DISABLED) print ("quotas-disabled\n");
            else if (status.mode == BtrfsQuotaMode.QGROUP && !status.inconsistent) print ("accounting-consistent\n");
            else print ("accounting-inconsistent\n");
            stdout.flush ();
            if (args[3] == "observe" && status.mode == BtrfsQuotaMode.QGROUP && !status.running) {
                if (status.inconsistent) throw new IOError.FAILED ("Rescan ended with inconsistent accounting.");
                return;
            }
            Timeout.add (25, exercise.callback);
            yield;
            status = yield backend.query_btrfs_quota (block, identity);
        }
    }
    assert (status.mode == BtrfsQuotaMode.DISABLED);
    status = yield backend.change_btrfs_quota (block, identity, status, "quota-enable");
    for (int i = 0; i < 60 && status.running; i++) {
        Timeout.add_seconds (1, exercise.callback);
        yield;
        status = yield backend.query_btrfs_quota (block, identity);
    }
    assert (status.mode == BtrfsQuotaMode.QGROUP && !status.inconsistent && !status.running);
    for (int i = 0; i < 10 && backend.jobs.active_count () != 0; i++) {
        Timeout.add_seconds (1, exercise.callback);
        yield;
    }
    uint64 id = yield backend.change_btrfs_subvolume (block, "service-created", identity);
    assert (id >= 256);
    status = yield backend.query_btrfs_quota (block, identity);
    var qgroup = status.find (id);
    assert (qgroup != null && !qgroup.stale);
    string group = qgroup.name;
    status = yield backend.change_btrfs_quota (block, identity, status,
        "qgroup-referenced-limit", group, "33554432");
    assert (status.find (id).max_referenced == 33554432);
    try {
        yield backend.change_btrfs_quota (block, identity, status, "qgroup-assign", group, "1/999");
        assert_not_reached ();
    } catch (IOError.FAILED error) {
        print ("Rejected missing quota parent: %s\n", error.message);
    }
    var list = yield backend.list_btrfs_subvolumes (block);
    BtrfsSubvolume? source = null;
    foreach (var subvolume in list.entries)
        if (subvolume.id == id && subvolume.path == "service-created") source = subvolume;
    assert (source != null);
    uint64 snapshot_id = yield backend.change_btrfs_subvolume (block, "service-snapshot", identity, source, true);
    status = yield backend.query_btrfs_quota (block, identity);
    assert (status.find (snapshot_id) != null && status.find (id).max_referenced == 33554432);
    list = yield backend.list_btrfs_subvolumes (block);
    BtrfsSubvolume? snapshot = null;
    foreach (var subvolume in list.entries)
        if (subvolume.id == snapshot_id && subvolume.snapshot) snapshot = subvolume;
    assert (snapshot != null && UDisksService.btrfs_subvolume_access (block, snapshot) == "Read-only subvolume");
    if (!list.default_known)
        throw new IOError.FAILED ("The default Btrfs subvolume could not be read: " + list.default_unavailable);
    assert (list.default_id == 5);
    yield backend.set_btrfs_default (block, (uint) id, 5, identity);
    yield backend.set_btrfs_default (block, 5, (uint) id, identity);
    yield backend.change_btrfs_subvolume (block, snapshot.path, identity, snapshot, false, true);
    list = yield backend.list_btrfs_subvolumes (block);
    foreach (var subvolume in list.entries) assert (subvolume.id != snapshot_id);
    status = yield backend.query_btrfs_quota (block, identity);
    assert (status.find (id).max_referenced == 33554432);
    status = yield backend.change_btrfs_quota (block, identity, status, "quota-disable");
    assert (status.mode == BtrfsQuotaMode.DISABLED);
    print ("Passed UDisks quota lifecycle and post-creation configuration failure\n");
}

int main (string[] args) {
    var loop = new MainLoop ();
    int result = 0;
    exercise.begin (args, (object, task) => {
        try { exercise.end (task); }
        catch (Error error) {
            stderr.printf ("%s\n", error.message);
            result = 1;
        }
        loop.quit ();
    });
    loop.run ();
    return result;
}
