using MajorisDisks;

private async void exercise_devices () throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-devices-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var copy = File.new_for_path (Path.build_filename (directory, "copy.img"));
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
        yield backend.create_disk_image (attached, copy, backend.modification_identity (attached));
        if (copy.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size () != 4 * 1024 * 1024)
            throw new IOError.INVALID_DATA ("The raw backup has the wrong size.");
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;

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
        uint8[] restored;
        FileUtils.get_data (target.get_path (), out restored);
        assert (restored.length == 8 * 1024 * 1024);
        for (int i = 0; i < 7; i++) assert (restored[i] == "Majoris"[i]);
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
