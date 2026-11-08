using MajorisDisks;

// Invoked only by the opt-in script after verifying its disposable loop.
private async void exercise_service (string device, string backing, string mode, string path) throws Error {
    var service = new UDisksService ();
    StorageBlock? target = null;
    bool advanced = mode == "advanced";
    bool credentials = mode == "credentials";
    bool restore = mode != "backup" && !credentials;
    for (int attempt = 0; attempt < 60; attempt++) {
        yield service.refresh ();
        foreach (var candidate in service.snapshot.blocks.get_values ()) {
            if (candidate.device == device && candidate.loop?.backing_file == backing &&
                candidate.logical_sector_size > 0 && candidate.encrypted?.mapping == null &&
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
