using MajorisDisks;

// Invoked only by the opt-in script after verifying its disposable loop.
private async void exercise_service (string device, string backing, string mode, string path) throws Error {
    var service = new UDisksService ();
    StorageBlock? target = null;
    bool advanced = mode == "advanced";
    bool credentials = mode == "credentials";
    bool resize = mode == "resize";
    bool configuration = mode == "configuration";
    bool restore_mount = mode == "restore-mount" || mode == "refuse-bind-mount";
    bool restore = mode != "backup" && !credentials;
    for (int attempt = 0; attempt < 60; attempt++) {
        yield service.refresh ();
        foreach (var candidate in service.snapshot.blocks.get_values ()) {
            var parent = candidate.partition == null ? null :
                service.snapshot.blocks.lookup (candidate.partition.table_path);
            bool correct_backing = candidate.loop?.backing_file == backing ||
                (resize && parent?.loop?.backing_file == backing);
            var mapping = candidate.encrypted?.mapping;
            if (candidate.device == device && correct_backing &&
                (resize || restore_mount ? mapping != null && mapping.logical_sector_size > 0 &&
                    (parent == null || parent.logical_sector_size > 0) :
                    mapping == null && candidate.logical_sector_size > 0) &&
                (advanced ? UDisksService.is_luks_recovery_candidate (candidate) :
                    UDisksService.is_luks_header_candidate (candidate))) {
                target = candidate;
                break;
            }
        }
        if (target != null) break;
        Timeout.add (100, () => { exercise_service.callback (); return Source.REMOVE; });
        yield;
    }
    if (target == null) throw new IOError.NOT_FOUND ("UDisks did not publish the expected disposable loop fixture.");
    if (restore_mount) {
        if (Environment.get_variable ("MAJORIS_TEST_CRYPTTAB") != "1" ||
            !FileUtils.test ("/etc/majoris-private-crypttab", FileTest.IS_REGULAR))
            throw new IOError.PERMISSION_DENIED ("The isolated mount fixture is required.");
        var mapping = target.encrypted.mapping;
        assert (mapping.filesystem != null && mapping.filesystem.mounted);
        if (mode == "refuse-bind-mount") {
            try {
                yield service.check_filesystem (mapping);
                assert_not_reached ();
            } catch (IOError error) { assert (error is IOError.NOT_SUPPORTED); }
        } else {
            assert (yield service.check_filesystem (mapping));
            assert (mapping.filesystem.mounts.length == 1 && mapping.filesystem.mounts[0] == path);
        }
        return;
    }
    if (configuration) {
        if (Environment.get_variable ("MAJORIS_TEST_CRYPTTAB") != "1" ||
            !FileUtils.test ("/etc/majoris-private-crypttab", FileTest.IS_REGULAR))
            throw new IOError.PERMISSION_DENIED ("The isolated crypttab fixture is required.");
        string identity = service.modification_identity (target);
        string name = Path.get_basename (backing).replace (".img", "");
        string original = "majoris original disposable passphrase";
        string replacement = "majoris rotated disposable passphrase";
        try {
            yield service.configure_encryption (target, true, true, name, "luks,nofail", "incorrect credential",
                null, identity, target.uuid);
            assert_not_reached ();
        } catch (IOError error) { assert (error is IOError.INVALID_DATA); }
        assert (target.encryption_configurations.length == 0);
        stdout.printf ("Creating an automatic crypttab entry\n");
        yield service.configure_encryption (target, true, true, name, "luks,nofail", original,
            null, identity, target.uuid);
        var original_entry = target.encryption_configuration;
        assert (original_entry != null && original_entry.name == name);
        stdout.printf ("Creating a manual crypttab entry\n");
        yield service.configure_encryption (target, true, false, name + "-manual", "luks,nofail", "",
            null, identity, target.uuid);
        assert (target.encryption_configurations.length == 2);
        stdout.printf ("Rotating the automatic entry's credential\n");
        var result = yield service.configure_encryption (target, true, true, name, "luks,nofail,discard", replacement,
            original_entry.backend_item, identity, target.uuid);
        assert (result.successful && result.completed_steps.length == 3);
        assert (target.encryption_configurations.length == 2);
        try {
            yield service.configure_encryption (target, false, false, name, "", "",
                original_entry.backend_item, identity, target.uuid);
            assert_not_reached ();
        } catch (IOError error) { assert (error is IOError.NOT_FOUND); }
        try {
            yield service.configure_encryption (target, true, true, name, "luks", "",
                null, identity, target.uuid);
            assert_not_reached ();
        } catch (IOError error) { assert (error is IOError.EXISTS); }
        foreach (var saved in target.encryption_configurations)
            assert (saved.name == name ? saved.options == "luks,nofail,discard" :
                saved.name == name + "-manual" && saved.options == "luks,nofail,noauto");
        stdout.printf ("Passed: crypttab creation, multi-entry editing, rotation, stale record and collision checks\n");
        return;
    }
    if (mode == "remove-configuration") {
        if (Environment.get_variable ("MAJORIS_TEST_CRYPTTAB") != "1" ||
            !FileUtils.test ("/etc/majoris-private-crypttab", FileTest.IS_REGULAR))
            throw new IOError.PERMISSION_DENIED ("The isolated crypttab fixture is required.");
        var entries = target.encryption_configurations;
        assert (entries.length == 2);
        foreach (var saved in entries) {
            yield service.configure_encryption (target, false, false, saved.name, "", "",
                saved.backend_item, service.modification_identity (target), target.uuid);
        }
        assert (target.encryption_configurations.length == 0);
        stdout.printf ("Passed: crypttab removal and configuration readback\n");
        return;
    }
    if (resize) {
        uint64 requested;
        uint64 backing_requested = 0;
        var sizes = path.split (":", 2);
        if (!uint64.try_parse (sizes[0], out requested) ||
            (sizes.length == 2 && !uint64.try_parse (sizes[1], out backing_requested)))
            throw new IOError.INVALID_ARGUMENT ("Invalid fixture size.");
        var header = yield service.review_luks_header (target, service.modification_identity (target));
        var outcome = yield service.resize_encrypted_mapping (target, header, requested,
            "majoris original disposable passphrase", backing_requested);
        if (!outcome.successful)
            throw new IOError.FAILED (outcome.summary + " " + outcome.technical_error + " " + outcome.actual_state);
        assert (target.encrypted.mapping.size == requested);
        assert (backing_requested == 0 || target.size == backing_requested);
        stdout.printf ("Passed: %s\n", outcome.actual_state);
        return;
    }
    if (credentials) {
        string original = "majoris original disposable passphrase";
        string extra = "majoris service disposable credential";
        int first = -1;
        int second = -1;
        try {
            var review = yield service.review_luks_header (target, service.modification_identity (target),
                null, false, true);
            first = UDisksService.credential_pipe (original);
            second = UDisksService.credential_pipe (extra);
            var added = yield service.manage_luks_keyslots (target, review, "add-keyslot", -1, -1,
                first, second, "", "");
            if (!added.successful) throw new IOError.FAILED (added.summary + " " + added.technical_error);
            Posix.close (first);
            Posix.close (second);
            first = -1;
            second = -1;
            review = yield service.review_luks_header (target, service.modification_identity (target),
                null, false, true);
            assert (review.keyslots[1].has_prefix ("slot 1 active "));
            string fixture_keyfile = Path.build_filename (Path.get_dirname (backing), "old.key");
            var verified_file = yield service.manage_luks_keyslots (target, review, "identify-keyslot",
                -1, -1, -1, -1, fixture_keyfile, "");
            assert (verified_file.successful && verified_file.summary.contains ("keyslot 0"));
            first = UDisksService.credential_pipe (extra);
            var verified = yield service.manage_luks_keyslots (target, review, "identify-keyslot", -1, -1,
                first, -1, "", "");
            assert (verified.successful && verified.summary.contains ("keyslot 1"));
            Posix.close (first);
            first = -1;
            first = UDisksService.credential_pipe (extra);
            second = UDisksService.credential_pipe (original);
            var removed = yield service.manage_luks_keyslots (target, review, "remove-keyslot", 1, 0,
                first, second, "", "");
            if (!removed.successful) throw new IOError.FAILED (removed.summary + " " + removed.technical_error);
            stdout.printf ("Passed: UDisks-authorized addition, passphrase and keyfile identification, and removal\n");
        } finally {
            if (first >= 0) Posix.close (first);
            if (second >= 0) Posix.close (second);
        }
        return;
    }
    var file = File.new_for_path (path);
    string identity = service.modification_identity (target);
    try {
        yield service.review_luks_header (target, "stale confirmation", restore ? file : null, advanced);
        assert_not_reached ();
    } catch (IOError error) {
        assert (error is IOError.NOT_FOUND);
    }
    var review = yield service.review_luks_header (target, identity, restore ? file : null, advanced);
    assert (review.damaged == advanced);
    assert (review.confidence == (advanced ? "device-identity" : "readable"));
    assert (!restore || (review.header_size > 0 && review.data_offset > 0));
    var outcome = yield service.execute_luks_header (target, review, restore ? null : file);
    if (!outcome.successful) throw new IOError.FAILED (outcome.summary + " " + outcome.technical_error);
    var slots = yield service.review_luks_header (target, service.modification_identity (target), null, false, true);
    assert (slots.keyslots.length >= 8);
    stdout.printf ("Passed: UDisks service %s and keyslot discovery\n", mode);
}

private int main (string[] args) {
    if (args.length != 5 || Environment.get_variable ("MAJORIS_TEST_LUKS") != "1" ||
        !args[1].has_prefix ("/dev/loop") || !args[2].has_prefix ("/var/tmp/majoris-luks."))
        return 77;
    int status = 1;
    var loop = new MainLoop ();
    exercise_service.begin (args[1], args[2], args[3], args[4], (source, result) => {
        try { exercise_service.end (result); status = 0; }
        catch (Error error) { stderr.printf ("%s\n", error.message); }
        loop.quit ();
    });
    loop.run ();
    return status;
}
