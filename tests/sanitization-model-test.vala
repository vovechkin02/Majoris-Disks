using MajorisDisks;

private void test_ata_evidence () {
    var mode = StorageSanitizationMethod.ATA_ENHANCED_SECURITY_ERASE;
    var capability = StorageSanitizationCapability.ata (mode, new Variant.int32 (510),
        new Variant.boolean (true), true);
    assert (capability.method == mode);
    assert (capability.availability == StorageSanitizationAvailability.BLOCKED);
    assert (capability.frozen == true);
    assert (capability.duration () == "At least 508 minutes");
    assert (StorageSanitizationCapability.ata (mode, new Variant.int32 (0),
        new Variant.boolean (false), true).availability == StorageSanitizationAvailability.UNSUPPORTED);
    assert (StorageSanitizationCapability.ata (mode, null,
        new Variant.boolean (false), true).availability == StorageSanitizationAvailability.UNKNOWN);
    assert (StorageSanitizationCapability.ata (mode, new Variant.int32 (12),
        new Variant.boolean (false), false).availability == StorageSanitizationAvailability.BLOCKED);
}

private void test_erase_safety () {
    var disk = new StorageBlock ("/fixture/disk");
    var partition = new StorageBlock ("/fixture/partition");
    disk.available = partition.available = true;
    var graph = new StorageDependencyService ();
    graph.add (disk, partition);
    assert (StorageSafetyService.assess_operation (StorageOperationKind.SANITIZE_DEVICE, disk, graph).allowed);
    partition.filesystem = new StorageFilesystem ();
    partition.filesystem.mounts = { "/mnt/fixture" };
    var mounted = StorageSafetyService.assess_operation (StorageOperationKind.LOGICAL_OVERWRITE, disk, graph);
    assert (!mounted.allowed && !mounted.requires_preparation);
    partition.filesystem.mounts = { "/" };
    assert (!StorageSafetyService.assess_operation (StorageOperationKind.SANITIZE_DEVICE, disk, graph).allowed);
    assert (!StorageSafetyService.assess_operation (StorageOperationKind.SANITIZE_DEVICE, disk, null).allowed);
}

private async void test_worker (bool cancel) throws Error {
    string path;
    int fd = FileUtils.open_tmp ("majoris-overwrite-XXXXXX", out path);
    try {
        uint8[] data = new uint8[1024 * 1024 + 512];
        Memory.set (data, 0x7f, data.length);
        assert (Posix.write (fd, data, data.length) == data.length);
        var jobs = new StorageJobManager ();
        var job = jobs.begin_named ("Fixture overwrite", path, {});
        if (cancel) job.cancellable.cancel ();
        var overwrite = new LogicalOverwrite ();
        try {
            int passes = LogicalOverwrite.pass_count (StorageSanitizationMethod.LOGICAL_MULTIPASS_OVERWRITE);
            yield overwrite.run (fd, data.length, passes, jobs, job);
            assert (!cancel && overwrite.flushed_passes == 3 && overwrite.verified == data.length);
        } catch (IOError.CANCELLED error) {
            assert (cancel && overwrite.written == 0 && overwrite.flushed_passes == 0);
        }
        uint8[] actual;
        FileUtils.get_data (path, out actual);
        if (!cancel) Memory.set (data, 0, data.length);
        assert (new Bytes (data).compare (new Bytes (actual)) == 0);
    } finally {
        Posix.close (fd);
        FileUtils.unlink (path);
    }
}

private void run_worker (bool cancel) {
    var loop = new MainLoop ();
    test_worker.begin (cancel, (object, result) => {
        try { test_worker.end (result); }
        catch (Error error) { Test.fail_printf ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private async void test_fixture () throws Error {
    var root = DirUtils.make_tmp ("majoris-sanitization-XXXXXX");
    var target = File.new_for_path (Path.build_filename (root, "target.img"));
    var sibling = File.new_for_path (Path.build_filename (root, "sibling.img"));
    var backend = new UDisksService ();
    StorageBlock? block = null;
    uint8[] expected = new uint8[4 * 1024 * 1024];
    uint8[] original = new uint8[expected.length];
    Memory.set (original, 0x5a, original.length);
    try {
        yield backend.refresh ();
        FileUtils.set_data (target.get_path (), original);
        FileUtils.set_data (sibling.get_path (), original);
        string path = yield backend.attach_disk_image (target, false);
        block = backend.snapshot.blocks.lookup (path);
        if (block == null || block.loop?.backing_file != target.get_path () ||
            block.read_only || block.size != original.length)
            throw new IOError.INVALID_DATA ("Refusing to overwrite a target other than the attached fixture.");
        var review = backend.review_logical_overwrite (block, StorageSanitizationMethod.LOGICAL_ZERO_OVERWRITE);
        try {
            yield backend.overwrite_logical_blocks (block, review, "");
            assert_not_reached ();
        } catch (IOError.PERMISSION_DENIED error) {}
        uint8[] before;
        FileUtils.get_data (target.get_path (), out before);
        assert (new Bytes (before).compare (new Bytes (original)) == 0);
        var result = yield backend.overwrite_logical_blocks (block, review, review.phrase);
        if (!result.successful)
            throw new IOError.FAILED ("%s\n%s\n%s".printf (result.summary, result.technical_error, result.actual_state));
        yield backend.detach_disk_image (block);
        block = null;
        uint8[] actual, unchanged;
        FileUtils.get_data (target.get_path (), out actual);
        FileUtils.get_data (sibling.get_path (), out unchanged);
        assert (new Bytes (actual).compare (new Bytes (expected)) == 0);
        assert (new Bytes (unchanged).compare (new Bytes (original)) == 0);
        stdout.printf ("Verified all %d fixture bytes as zero and all sibling bytes unchanged.\n", actual.length);
    } finally {
        if (block != null && block.loop?.backing_file == target.get_path ()) {
            try { yield backend.detach_disk_image (block); block = null; }
            catch (Error error) { stderr.printf ("Retaining fixture %s: %s\n", root, error.message); }
        }
        if (block == null) FileUtils.unlink (target.get_path ());
        FileUtils.unlink (sibling.get_path ());
        DirUtils.remove (root);
    }
}

int main (string[] args) {
    if (args.length == 2 && args[1] == "fixture") {
        if (Environment.get_variable ("MAJORIS_DISKS_RUN_SANITIZATION_TESTS") != "1" ||
            Environment.get_host_name () != "majoris-mdraid-test" || Posix.geteuid () != 0)
            return 77;
        try {
            var vm = new Subprocess (SubprocessFlags.STDOUT_PIPE, "/usr/bin/systemd-detect-virt", "--vm");
            string? output;
            vm.communicate_utf8 (null, null, out output, null);
            if (!vm.get_successful () || output == null || output.strip () != "qemu") return 77;
        } catch (Error error) { return 77; }
        var loop = new MainLoop ();
        int status = 0;
        test_fixture.begin ((object, result) => {
            try { test_fixture.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
            loop.quit ();
        });
        loop.run ();
        return status;
    }
    Test.init (ref args);
    Test.add_func ("/sanitization/ata-evidence", test_ata_evidence);
    Test.add_func ("/sanitization/erase-safety", test_erase_safety);
    Test.add_func ("/sanitization/three-pass-worker", () => run_worker (false));
    Test.add_func ("/sanitization/cancel-before-write", () => run_worker (true));
    Test.run ();
    return 0;
}
