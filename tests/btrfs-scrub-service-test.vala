using MajorisDisks;

private async void exercise (string[] args) throws Error {
    if (args.length != 4 || Posix.getuid () != 0 ||
        Environment.get_variable ("MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS") != "1" ||
        !Uuid.string_is_valid (args[2]) || !Path.is_absolute (args[1]))
        throw new IOError.PERMISSION_DENIED ("A disposable Btrfs scrub fixture is required.");
    Posix.Stat info;
    if (Posix.lstat (args[1], out info) != 0 || !Posix.S_ISDIR (info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("The scrub fixture must be private and root-owned.");

    var backend = new UDisksService ();
    StorageBlock? block = null;
    for (int i = 0; i < 40 && block == null; i++) {
        yield backend.refresh ();
        foreach (var candidate in backend.snapshot.blocks.get_values ()) {
            if (candidate.uuid != args[2] || candidate.type_id != "btrfs") continue;
            if (candidate.loop?.backing_file != args[1] + "/first")
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
    if (block == null) throw new IOError.NOT_FOUND ("UDisks did not identify the scrub fixture.");
    string identity = backend.modification_identity (block);
    if (args[3] == "start") {
        var report = new BtrfsScrubReport (yield backend.btrfs_scrub (block, identity, "scrub-status"));
        assert (report.state == BtrfsScrubState.NEVER_RUN && report.devices.length == 1);
        var result = new BtrfsScrubReport (yield backend.btrfs_scrub (
            block, identity, "scrub-readonly", 0, report.review));
        assert (result.state == BtrfsScrubState.CLEAN && result.devices.length == 1);
        assert (backend.jobs.active_count () == 0);
        print ("service-clean\n");
    } else if (args[3] == "watch") {
        var report = new BtrfsScrubReport (yield backend.btrfs_scrub (block, identity, "scrub-status"));
        if (report.state != BtrfsScrubState.RUNNING)
            throw new IOError.FAILED ("The restarted client did not rediscover a kernel scrub.");
        print ("service-running\n");
    } else if (args[3] == "history") {
        string history = yield backend.btrfs_scrub (block, identity, "scrub-history");
        if (history.strip () == "") throw new IOError.NOT_FOUND ("The scrub worker did not save a terminal history entry.");
        var result = new BtrfsScrubReport (history.strip ().split ("\n\n")[0]);
        assert (result.state == BtrfsScrubState.CLEAN && result.devices.length == 1);
        print ("service-history-clean\n");
    } else throw new IOError.INVALID_ARGUMENT ("Unknown fixture operation.");
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
