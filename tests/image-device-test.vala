using MajorisDisks;

private void verify_fixture (File target, uint8[] expected) throws Error {
    uint8[] actual;
    FileUtils.get_data (target.get_path (), out actual);
    if (actual.length != 8 * 1024 * 1024 ||
        new Bytes (actual[0:expected.length]).compare (new Bytes (expected)) != 0)
        throw new IOError.INVALID_DATA ("The restored device contents differ from the expected image.");
}

private async void exercise_devices () throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-devices-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var copy = File.new_for_path (Path.build_filename (directory, "copy.img"));
    var compressed = File.new_for_path (Path.build_filename (directory, "second.img.xz"));
    var target = File.new_for_path (Path.build_filename (directory, "target.img"));
    var backend = new UDisksService ();
    StorageBlock? attached = null;
    bool safe_to_remove = true;
    try {
        yield backend.refresh ();
        yield DiskImageCopy.create_blank (source, 4 * 1024 * 1024);
        yield DiskImageCopy.create_blank (target, 8 * 1024 * 1024);
        int writer = Posix.open (source.get_path (), Posix.O_WRONLY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW);
        if (writer < 0) throw new IOError.FAILED ("Could not open the disposable source fixture.");
        try {
            if (Posix.write (writer, "Majoris".data, 7) != 7 || Posix.fsync (writer) != 0)
                throw new IOError.FAILED ("Could not initialize the disposable source fixture.");
        } finally { Posix.close (writer); }

        safe_to_remove = false;
        string source_object = yield backend.attach_disk_image (source, true);
        attached = backend.snapshot.blocks.lookup (source_object);
        if (attached == null || !attached.read_only || attached.loop?.backing_file != source.get_path ())
            throw new IOError.INVALID_DATA ("UDisks did not expose the expected read-only source fixture.");
        yield backend.create_disk_image (attached, copy, backend.modification_identity (attached), true);
        if (copy.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size () != 4 * 1024 * 1024)
            throw new IOError.INVALID_DATA ("The raw backup has the wrong size.");
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        uint8[] expected;
        uint8[] backup;
        FileUtils.get_data (source.get_path (), out expected);
        FileUtils.get_data (copy.get_path (), out backup);
        if (new Bytes (expected).compare (new Bytes (backup)) != 0)
            throw new IOError.INVALID_DATA ("The raw backup differs from its disposable source.");

        safe_to_remove = false;
        string target_object = yield backend.attach_disk_image (target, false);
        attached = backend.snapshot.blocks.lookup (target_object);
        if (attached == null || attached.read_only || attached.loop?.backing_file != target.get_path ())
            throw new IOError.INVALID_DATA ("Refusing to restore to an unverified disposable fixture.");
        var result = yield backend.restore_disk_image (attached, copy, backend.modification_identity (attached));
        if (!result.successful)
            throw new IOError.FAILED (result.summary + " " + result.technical_error);
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        verify_fixture (target, expected);

        // Write a different payload in the second pass so an unchanged target cannot pass.
        expected[0] = 0x7a;
        expected[expected.length - 1] = 0x39;
        string? xz = Environment.find_program_in_path ("xz");
        if (xz == null) {
            stdout.printf ("Raw imaging passed. XZ fixture creation skipped because xz-utils is unavailable.\n");
            return;
        }
        var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE);
        launcher.set_stdout_file_path (compressed.get_path ());
        var compressor = launcher.spawnv ({ xz, "--compress", "--stdout" });
        yield compressor.communicate_async (new Bytes (expected), null, null, null);
        yield compressor.wait_check_async ();

        safe_to_remove = false;
        target_object = yield backend.attach_disk_image (target, false);
        attached = backend.snapshot.blocks.lookup (target_object);
        if (attached == null || attached.read_only || attached.loop?.backing_file != target.get_path ())
            throw new IOError.INVALID_DATA ("Refusing XZ restoration to an unverified disposable fixture.");
        result = yield backend.restore_disk_image (attached, compressed, backend.modification_identity (attached));
        if (!result.successful)
            throw new IOError.FAILED (result.summary + " " + result.technical_error);
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        verify_fixture (target, expected);
    } finally {
        if (attached != null && (attached.loop?.backing_file == source.get_path () ||
            attached.loop?.backing_file == target.get_path ())) {
            try {
                yield backend.detach_disk_image (attached);
                safe_to_remove = true;
            } catch (Error error) { warning ("Could not detach the fixture: %s", error.message); }
        }
        if (safe_to_remove) {
            FileUtils.unlink (source.get_path ());
            FileUtils.unlink (copy.get_path ());
            FileUtils.unlink (target.get_path ());
            FileUtils.unlink (compressed.get_path ());
            DirUtils.remove (directory);
        } else warning ("A loop attachment could not be reconciled. Retained fixtures in %s", directory);
    }
}

public static int main (string[] args) {
    if (Environment.get_variable ("MAJORIS_DISKS_RUN_LOOP_TESTS") != "1") {
        stdout.printf ("SKIP: set MAJORIS_DISKS_RUN_LOOP_TESTS=1 to run disposable imaging tests\n");
        return 77;
    }
    var loop = new MainLoop ();
    int status = 0;
    exercise_devices.begin ((object, result) => {
        try { exercise_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
