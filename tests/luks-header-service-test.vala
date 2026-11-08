using MajorisDisks;

// Invoked only by the opt-in script after verifying its disposable loop.
private async void exercise_service (string device, string backing, string mode, string path) throws Error {
    var service = new UDisksService ();
    StorageBlock? target = null;
    bool advanced = mode == "advanced";
    bool restore = mode != "backup";
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
    var outcome = yield service.execute_luks_header (target, review, restore ? null : file);
    if (!outcome.successful) throw new IOError.FAILED (outcome.summary + " " + outcome.technical_error);
    stdout.printf ("Passed: UDisks service %s\n", mode);
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
