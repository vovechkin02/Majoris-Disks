using MajorisDisks;

private void verify_fixture (File target, uint8[] expected, uint8[] trailing) throws Error {
    uint8[] actual;
    FileUtils.get_data (target.get_path (), out actual);
    if (actual.length != 8 * 1024 * 1024 ||
        new Bytes (actual[0:expected.length]).compare (new Bytes (expected)) != 0 ||
        new Bytes (actual[expected.length:actual.length]).compare (new Bytes (trailing)) != 0)
        throw new IOError.INVALID_DATA ("The restored device contents differ from the expected image.");
}

private async void exercise_devices (bool use_xz) throws Error {
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
        var trailing = new uint8[4 * 1024 * 1024];
        for (int i = 0; i < trailing.length; i++) trailing[i] = (uint8) (i % 251 + 1);
        var destination = target.open_readwrite ();
        ((Seekable) destination).seek (4 * 1024 * 1024, SeekType.SET);
        size_t tail_written;
        destination.output_stream.write_all (trailing, out tail_written);
        assert (tail_written == trailing.length);
        destination.close ();
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

        File restore_source = copy;
        if (use_xz) {
            string xz = Environment.find_program_in_path ("xz");
            var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE);
            launcher.set_stdout_file_path (compressed.get_path ());
            var compressor = launcher.spawnv ({ xz, "--compress", "--stdout" });
            yield compressor.communicate_async (new Bytes (expected), null, null, null);
            yield compressor.wait_check_async ();
            restore_source = compressed;
        }

        safe_to_remove = false;
        string target_object = yield backend.attach_disk_image (target, false);
        attached = backend.snapshot.blocks.lookup (target_object);
        if (attached == null || attached.read_only || attached.loop?.backing_file != target.get_path ())
            throw new IOError.INVALID_DATA ("Refusing to restore to an unverified disposable fixture.");
        var result = yield backend.restore_disk_image (attached, restore_source, backend.modification_identity (attached));
        if (!result.successful)
            throw new IOError.FAILED (result.summary + " " + result.technical_error);
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        verify_fixture (target, expected, trailing);
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

private const int NBD_FIXTURE_OFFSET = 32 * 1024 * 1024;

private void set_nbd_marker (File fixture, string marker) throws Error {
    var stream = fixture.open_readwrite ();
    ((Seekable) stream).seek (NBD_FIXTURE_OFFSET, SeekType.SET);
    size_t written;
    stream.output_stream.write_all (marker.data, out written);
    stream.close ();
}

private async void verify_nbd_marker (UDisksService backend, StorageBlock block, File copy, string marker) throws Error {
    try {
        yield backend.create_disk_image (block, copy, backend.modification_identity (block), true);
        var stream = copy.read ();
        ((Seekable) stream).seek (NBD_FIXTURE_OFFSET, SeekType.SET);
        uint8[] bytes = new uint8[marker.length];
        size_t count;
        stream.read_all (bytes, out count);
        stream.close ();
        if (count != marker.length || new Bytes (bytes).compare (new Bytes (marker.data)) != 0)
            throw new IOError.INVALID_DATA ("The NBD device did not return the expected fixture bytes.");
    } finally { FileUtils.unlink (copy.get_path ()); }
}

private void verify_nbd_cleanup (VirtualAttachment record) throws Error {
    string session = Path.build_filename (Environment.get_user_runtime_dir (), "majoris-nbd", record.token);
    if (VirtualDiskAttachment.lookup ("/dev/nbd%u".printf (record.index)) != null ||
        FileUtils.test (session, FileTest.EXISTS))
        throw new IOError.FAILED ("The NBD fixture still has a managed mapping or runtime record.");
}

private async void exercise_nbd_devices () throws Error {
    string directory = DirUtils.make_tmp ("majoris-nbd-tests-XXXXXX");
    var raw = File.new_for_path (Path.build_filename (directory, "source.img"));
    bool retain = false;
    try {
        yield DiskImageCopy.create_blank (raw, 64 * 1024 * 1024);
        var partitioner = new Subprocess.newv ({ "sfdisk", "--no-reread", "--no-tell-kernel", raw.get_path () },
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE);
        yield partitioner.communicate_utf8_async ("label: gpt\nstart=2048, size=32768, type=L\n", null, null, null);
        yield partitioner.wait_check_async ();
        var formatter = new Subprocess.newv ({ "mkfs.ext4", "-q", "-F", "-b", "4096",
            "-E", "offset=1048576", raw.get_path (), "4096" }, SubprocessFlags.NONE);
        yield formatter.wait_check_async ();
        var readback = File.new_for_path (Path.build_filename (directory, "readback.img"));
        set_nbd_marker (raw, "Majoris read fixture");

        foreach (var format in new string[] { "vpc", "vhdx", "qcow2" }) {
            var image = File.new_for_path (Path.build_filename (directory, format));
            yield VirtualDisk.write_image (raw, image, format, 0, new Cancellable ());
            var backend = new UDisksService ();
            yield backend.refresh ();
            StorageBlock? block = null;
            StorageBlock? mounted = null;
            retain = true;
            try {
                string path = yield backend.attach_virtual_image (image, true);
                block = backend.snapshot.blocks.lookup (path);
                if (block == null || block.virtual_attachment?.file != image.get_path () ||
                    block.virtual_attachment.format != format || !block.read_only || block.size != 64 * 1024 * 1024)
                    throw new IOError.INVALID_DATA ("The managed virtual fixture could not be verified.");
                try {
                    yield backend.attach_virtual_image (image, false);
                    assert_not_reached ();
                } catch (Error error) { assert (error is IOError.EXISTS); }

                var wrong = new VirtualAttachment () { index = block.virtual_attachment.index, token = Uuid.string_random () };
                try {
                    yield VirtualDiskAttachment.detach (wrong);
                    assert_not_reached ();
                } catch (Error error) { assert (error is IOError.PERMISSION_DENIED); }

                var reopened = new UDisksService ();
                yield reopened.refresh ();
                var recovered = reopened.snapshot.blocks.lookup (path);
                if (recovered == null || recovered.virtual_attachment?.token != block.virtual_attachment.token)
                    throw new IOError.INVALID_DATA ("The managed attachment was not recovered by a new service.");
                backend = reopened;
                block = recovered;
                var partitions = block.table?.partitions ?? new StorageBlock[0];
                if (partitions.length != 1 || partitions[0].type_id != "ext4")
                    throw new IOError.INVALID_DATA ("The virtual fixture partition and filesystem were not discovered.");
                yield verify_nbd_marker (backend, block, readback, "Majoris read fixture");
                yield backend.volume_action (partitions[0], "Mount");
                mounted = partitions[0];
                try {
                    yield backend.detach_disk_image (block);
                    assert_not_reached ();
                } catch (Error error) { assert (error is IOError.BUSY); }
                yield backend.volume_action (mounted, "Unmount");
                mounted = null;
                var record = block.virtual_attachment;
                yield backend.detach_disk_image (block);
                verify_nbd_cleanup (record);
                block = null;
                retain = false;

                if (format == "qcow2") {
                    retain = true;
                    string writable_path = yield backend.attach_virtual_image (image, false);
                    block = backend.snapshot.blocks.lookup (writable_path);
                    if (block == null || block.virtual_attachment?.file != image.get_path () || block.read_only)
                        throw new IOError.INVALID_DATA ("The writable virtual fixture could not be verified.");
                    set_nbd_marker (raw, "Majoris write test  ");
                    var restored = yield backend.restore_disk_image (block, raw, backend.modification_identity (block));
                    if (!restored.successful)
                        throw new IOError.FAILED (restored.summary + " " + restored.technical_error);
                    record = block.virtual_attachment;
                    yield backend.detach_disk_image (block);
                    verify_nbd_cleanup (record);
                    block = null;

                    string check_path = yield backend.attach_virtual_image (image, true);
                    block = backend.snapshot.blocks.lookup (check_path);
                    if (block == null || block.virtual_attachment?.file != image.get_path () || !block.read_only)
                        throw new IOError.INVALID_DATA ("Could not reopen the writable fixture read-only.");
                    yield verify_nbd_marker (backend, block, readback, "Majoris write test  ");
                    record = block.virtual_attachment;
                    yield backend.detach_disk_image (block);
                    verify_nbd_cleanup (record);
                    block = null;
                    retain = false;
                }
            } finally {
                if (mounted != null) {
                    try { yield backend.volume_action (mounted, "Unmount"); }
                    catch (Error error) { warning ("%s", error.message); }
                }
                if (block != null && block.virtual_attachment?.file == image.get_path ()) {
                    try { yield backend.detach_disk_image (block); retain = false; }
                    catch (Error error) { warning ("%s", error.message); }
                }
                if (!retain) FileUtils.unlink (image.get_path ());
            }
        }
    } finally {
        if (retain) warning ("An NBD result needs reconciliation. Retained fixtures in %s", directory);
        else {
            FileUtils.unlink (raw.get_path ());
            DirUtils.remove (directory);
        }
    }
}

public static int main (string[] args) {
    bool nbd = args.length > 1 && args[1] == "--nbd";
    bool use_xz = args.length > 1 && args[1] == "--xz";
    if (use_xz && Environment.find_program_in_path ("xz") == null) {
        stdout.printf ("SKIP: xz-utils is required to generate the compressed fixture.\n");
        return 77;
    }
    if (nbd) {
        string? missing = VirtualDiskAttachment.unavailable_reason ();
        if (Environment.get_variable ("MAJORIS_DISKS_RUN_NBD_TESTS") != "1" || missing != null ||
            Environment.find_program_in_path ("sfdisk") == null || Environment.find_program_in_path ("mkfs.ext4") == null) {
            stdout.printf ("SKIP: NBD fixture requires explicit opt-in, the installed NBD backend, sfdisk and mkfs.ext4. %s\n",
                missing ?? "");
            return 77;
        }
    } else if (Environment.get_variable ("MAJORIS_DISKS_RUN_LOOP_TESTS") != "1") {
        stdout.printf ("SKIP: set MAJORIS_DISKS_RUN_LOOP_TESTS=1 to run disposable imaging tests\n");
        return 77;
    }
    var loop = new MainLoop ();
    int status = 0;
    if (nbd) exercise_nbd_devices.begin ((object, result) => {
        try { exercise_nbd_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    else exercise_devices.begin (use_xz, (object, result) => {
        try { exercise_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
