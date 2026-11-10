using MajorisDisks;

private async void fixture (string[] args) throws Error {
    if (args.length != 7 || Posix.getuid () != 0 ||
        Environment.get_variable ("MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS") != "1" ||
        !Uuid.string_is_valid (args[2]) || !Path.is_absolute (args[1]))
        throw new IOError.PERMISSION_DENIED ("A disposable Btrfs conversion fixture is required.");
    Posix.Stat stat;
    if (Posix.lstat (args[1], out stat) != 0 || !Posix.S_ISDIR (stat.st_mode) ||
        stat.st_uid != 0 || (stat.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("Fixture directory must be private and owned by root.");
    uint64 count;
    if (!uint64.try_parse (args[6], out count) || count == 0)
        throw new IOError.INVALID_ARGUMENT ("Invalid fixture member count.");
    var backend = new UDisksService ();
    StorageBlock? anchor = null;
    for (uint i = 0; i < 40 && anchor == null; i++) {
        yield backend.refresh ();
        uint64 found = 0;
        foreach (var block in backend.snapshot.blocks.get_values ()) {
            if (block.uuid != args[2] || block.type_id != "btrfs") continue;
            string backing = block.loop?.backing_file ?? "";
            if (Path.get_dirname (backing) != args[1] || !Path.get_basename (backing).has_prefix ("disk-") ||
                !backing.has_suffix (".img") || Posix.lstat (backing, out stat) != 0 ||
                !Posix.S_ISREG (stat.st_mode) || stat.st_uid != 0)
                throw new IOError.PERMISSION_DENIED ("A member is outside the disposable fixture.");
            found++;
            if (block.logical_sector_size != 0 &&
                args[1] + "/mount" in (block.filesystem?.mounts ?? new string[0]))
                anchor = block;
        }
        if (found != count) anchor = null;
        if (anchor == null) {
            Timeout.add (250, fixture.callback);
            yield;
        }
    }
    if (anchor == null) throw new IOError.NOT_FOUND ("UDisks did not identify the disposable filesystem.");
    string identity = backend.modification_identity (anchor);
    var data = BtrfsProfileType.from_argument (args[4]);
    var metadata = BtrfsProfileType.from_argument (args[5]);
    switch (args[3]) {
    case "status":
    case "monitor":
        do {
            string output = yield backend.btrfs_maintenance (anchor, identity, "balance-convert-status", 0);
            print ("%s\n", output);
            stdout.flush ();
            if (args[3] == "status") break;
            Timeout.add (100, fixture.callback);
            yield;
        } while (true);
        return;
    case "pause":
    case "cancel":
        print ("%s\n", yield backend.btrfs_maintenance (anchor, identity, "balance-" + args[3], 0));
        return;
    case "resume":
        var saved = yield backend.review_btrfs_conversion (anchor, identity, data, metadata, true);
        print ("%s\n", yield backend.btrfs_maintenance (anchor, identity, "balance-resume", 0,
            saved, saved.reduces_redundancy));
        return;
    }
    var plan = yield backend.review_btrfs_conversion (anchor, identity, data, metadata);
    if (args[3] == "review") {
        print ("%s %s\n", plan.reduces_redundancy ? "reduce" : "standard", plan.workspace.to_string ());
        return;
    }
    if (args[3] == "restart") {
        var restart = new Subprocess (SubprocessFlags.NONE, "systemctl", "restart", "udisks2.service");
        yield restart.wait_check_async ();
    }
    if (!(args[3] in new string[] { "convert", "reduce", "bad-token", "restart" }))
        throw new IOError.INVALID_ARGUMENT ("Invalid fixture action.");
    if (args[3] == "bad-token") plan.token = string.nfill (64, '0');
    print ("%s\n", yield backend.btrfs_maintenance (anchor, identity, "balance-convert", 0, plan, args[3] == "reduce"));
}

int main (string[] args) {
    var loop = new MainLoop ();
    int result = 0;
    fixture.begin (args, (object, task) => {
        try { fixture.end (task); }
        catch (Error error) {
            stderr.printf ("%s\n", error.message);
            result = 1;
        }
        loop.quit ();
    });
    loop.run ();
    return result;
}
