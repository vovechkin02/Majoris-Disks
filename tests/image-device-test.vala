using MajorisDisks;

private void verify_fixture (File target, uint8[] expected, uint8[] before, int offset) throws Error {
    uint8[] actual;
    FileUtils.get_data (target.get_path (), out actual);
    int end = offset + expected.length;
    if (actual.length != before.length ||
        new Bytes (actual[0:offset]).compare (new Bytes (before[0:offset])) != 0 ||
        new Bytes (actual[offset:end]).compare (new Bytes (expected)) != 0 ||
        new Bytes (actual[end:actual.length]).compare (new Bytes (before[end:before.length])) != 0)
        throw new IOError.INVALID_DATA ("The restored device contents differ from the expected image.");
}

private async void exercise_devices (bool use_xz, bool partition, bool mbr, string? virtual_format) throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-devices-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var copy = File.new_for_path (Path.build_filename (directory, "copy.img"));
    var compressed = File.new_for_path (Path.build_filename (directory, partition ? "second.raw.xz" : "second.img.xz"));
    string extension = virtual_format == "vpc" ? "vhd" : virtual_format ?? "unused";
    var container = File.new_for_path (Path.build_filename (directory, "container." + extension));
    var oversized = File.new_for_path (Path.build_filename (directory, "oversized.raw"));
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
        if (partition) {
            var partitioner = new Subprocess.newv ({ "sfdisk", "--no-reread", "--no-tell-kernel", target.get_path () },
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE);
            yield partitioner.communicate_utf8_async (
                "label: %s\nstart=2048, size=8192, type=L\nstart=12288, size=2048, type=L\n".printf (mbr ? "dos" : "gpt"),
                null, null, null);
            yield partitioner.wait_check_async ();
        }
        uint8[] before;
        FileUtils.get_data (target.get_path (), out before);
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
        if (use_xz)
            yield backend.create_disk_image (attached, compressed, backend.modification_identity (attached), true);
        try {
            yield backend.create_disk_image (attached, copy, backend.modification_identity (attached), true);
            assert_not_reached ();
        } catch (IOError.EXISTS error) {}
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        uint8[] expected;
        uint8[] backup;
        FileUtils.get_data (source.get_path (), out expected);
        FileUtils.get_data (copy.get_path (), out backup);
        if (new Bytes (expected).compare (new Bytes (backup)) != 0)
            throw new IOError.INVALID_DATA ("The raw backup differs from its disposable source.");

        File restore_source = use_xz ? compressed : copy;
        if (virtual_format != null) {
            yield VirtualDisk.write_image (copy, container, virtual_format, 0, new Cancellable ());
            restore_source = container;
        }

        safe_to_remove = false;
        string target_object = yield backend.attach_disk_image (target, false);
        attached = backend.snapshot.blocks.lookup (target_object);
        if (attached == null || attached.read_only || attached.loop?.backing_file != target.get_path ())
            throw new IOError.INVALID_DATA ("Refusing to restore to an unverified disposable fixture.");
        StorageBlock restore_target = attached;
        int offset = 0;
        if (partition) {
            var partitions = attached.table?.partitions ?? new StorageBlock[0];
            offset = 1024 * 1024;
            if (partitions.length != 2 || partitions[0].partition?.offset != offset ||
                partitions[0].partition?.table_path != attached.path || partitions[0].size != 4 * 1024 * 1024)
                throw new IOError.INVALID_DATA ("Could not verify the disposable target partition.");
            restore_target = partitions[0];
            try {
                yield backend.restore_disk_image (restore_target, restore_source, "stale confirmation");
                assert_not_reached ();
            } catch (Error error) { assert (error is IOError.NOT_FOUND); }
            yield DiskImageCopy.create_blank (oversized, restore_target.size + 512);
            var rejected = yield backend.restore_disk_image (restore_target, oversized,
                backend.modification_identity (restore_target));
            assert (!rejected.successful);
            verify_fixture (target, before[offset:offset + expected.length], before, offset);
        }
        var review_job = backend.jobs.begin_named ("Review fixture image", restore_source.get_parse_name (), {});
        var reviewed = yield DiskImageCopy.verify_file (restore_source, backend.jobs, review_job, restore_target.size);
        string replaced = restore_source.get_path () + ".old";
        if (FileUtils.rename (restore_source.get_path (), replaced) != 0)
            throw new IOError.FAILED ("Could not stage source replacement fixture.");
        bool original_returned = false;
        try {
            FileUtils.set_contents (restore_source.get_path (), "replacement source");
            var rejected = yield backend.restore_disk_image (restore_target, restore_source,
                backend.modification_identity (restore_target), reviewed);
            assert (!rejected.successful && !rejected.partial);
            verify_fixture (target, before[offset:offset + expected.length], before, offset);
        } finally {
            original_returned = FileUtils.rename (replaced, restore_source.get_path ()) == 0;
        }
        if (!original_returned)
            throw new IOError.FAILED ("Could not return the original fixture source.");
        var result = yield backend.restore_disk_image (restore_target, restore_source,
            backend.modification_identity (restore_target));
        if (!result.successful)
            throw new IOError.FAILED (result.summary + " " + result.technical_error);
        yield backend.detach_disk_image (attached);
        attached = null;
        safe_to_remove = true;
        verify_fixture (target, expected, before, offset);
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
            FileUtils.unlink (container.get_path ());
            FileUtils.unlink (oversized.get_path ());
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

private string nbd_journal (VirtualAttachment record) {
    return "/run/majoris-disks-nbd/nbd%u".printf (record.index);
}

private void verify_nbd_journal (VirtualAttachment record) throws Error {
    var journal = new KeyFile ();
    journal.load_from_file (nbd_journal (record), KeyFileFlags.NONE);
    if (journal.get_string ("attachment", "token") != record.token ||
        journal.get_string ("attachment", "state") != "attached-verified")
        throw new IOError.INVALID_DATA ("The NBD fixture did not publish a verified attachment journal.");
}

private void verify_nbd_cleanup (VirtualAttachment record) throws Error {
    string session = Path.build_filename (Environment.get_user_runtime_dir (), "majoris-nbd", record.token);
    if (VirtualDiskAttachment.lookup ("/dev/nbd%u".printf (record.index)) != null ||
        FileUtils.test (session, FileTest.EXISTS) || FileUtils.test (nbd_journal (record), FileTest.EXISTS))
        throw new IOError.FAILED ("The NBD fixture still has a managed mapping or runtime record.");
}

private async void exercise_nbd_devices () throws Error {
    string directory = DirUtils.make_tmp ("majoris-nbd-tests-XXXXXX");
    var raw = File.new_for_path (Path.build_filename (directory, "source.img"));
    string payload_dir = Path.build_filename (directory, "payload");
    string payload_file = Path.build_filename (payload_dir, "known.txt");
    bool retain = false;
    try {
        if (DirUtils.create (payload_dir, 0700) != 0)
            throw new IOError.FAILED ("Could not create the NBD filesystem payload directory.");
        FileUtils.set_contents (payload_file, "Majoris filesystem payload\n");
        yield DiskImageCopy.create_blank (raw, 64 * 1024 * 1024);
        var partitioner = new Subprocess.newv ({ "sfdisk", "--no-reread", "--no-tell-kernel", raw.get_path () },
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE);
        yield partitioner.communicate_utf8_async ("label: gpt\nstart=2048, size=32768, type=L\n", null, null, null);
        yield partitioner.wait_check_async ();
        var formatter = new Subprocess.newv ({ "mkfs.ext4", "-q", "-F", "-b", "4096", "-d", payload_dir,
            "-E", "offset=1048576", raw.get_path (), "4096" }, SubprocessFlags.NONE);
        yield formatter.wait_check_async ();
        var readback = File.new_for_path (Path.build_filename (directory, "readback.img"));
        foreach (var fixture in new string[] { "vpc", "vhdx", "qcow2", "compressed-qcow2" }) {
            set_nbd_marker (raw, "Majoris read fixture");
            bool compress = fixture == "compressed-qcow2";
            string format = compress ? "qcow2" : fixture;
            var image = File.new_for_path (Path.build_filename (directory, fixture));
            yield VirtualDisk.write_image (raw, image, format, 0, new Cancellable (), null, null, null, compress);
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
                verify_nbd_journal (block.virtual_attachment);
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
                string[] points = mounted.filesystem?.mounts ?? new string[0];
                if (points.length != 1)
                    throw new IOError.INVALID_DATA ("UDisks did not publish the mounted fixture path.");
                string payload;
                FileUtils.get_contents (Path.build_filename (points[0], "known.txt"), out payload);
                if (payload != "Majoris filesystem payload\n")
                    throw new IOError.INVALID_DATA ("The NBD partition filesystem returned unexpected contents.");
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

                if (fixture == "qcow2") {
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
            FileUtils.unlink (payload_file);
            DirUtils.remove (payload_dir);
            DirUtils.remove (directory);
        }
    }
}

private async void exercise_image_growth () throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-growth-XXXXXX");
    var raw = File.new_for_path (Path.build_filename (directory, "fixture.img"));
    var source = File.new_for_path (Path.build_filename (directory, "source"));
    var grown = File.new_for_path (Path.build_filename (directory, "grown"));
    var token = new Cancellable ();
    uint64 initial = 64 * 1024 * 1024;
    try {
        yield DiskImageCopy.create_blank (raw, initial);
        set_nbd_marker (raw, "Majoris image growth fixture");
        foreach (string format in new string[] { "raw", "vpc", "vhdx", "qcow2" }) {
            yield VirtualDisk.write_image (raw, source, format, 0, token);
            var info = yield VirtualDisk.inspect (source, token);
            try {
                yield VirtualDisk.write_image (source, grown, format, initial - 1048576, token, null, info);
                throw new IOError.FAILED ("Image shrinking should have been rejected.");
            } catch (IOError.INVALID_ARGUMENT expected) {}
            try {
                yield VirtualDisk.write_image (source, grown, format, initial * 2, token, null, info,
                    (fd) => { throw new IOError.BUSY ("Simulated attached source"); });
                throw new IOError.FAILED ("An attached source should have been rejected.");
            } catch (IOError.BUSY expected) {}
            double last_progress = 0;
            bool regressed = false;
            yield VirtualDisk.write_image (source, grown, format, initial * 2, token, (fraction) => {
                if (fraction < last_progress) regressed = true;
                last_progress = fraction;
            }, info);
            var result = yield VirtualDisk.inspect (grown, token);
            var original = yield VirtualDisk.inspect (source, token);
            if (result.format != format || result.capacity != initial * 2 || original.identity != info.identity ||
                regressed || last_progress != 1)
                throw new IOError.INVALID_DATA ("Unexpected growth result for " + format);
            FileUtils.unlink (source.get_path ());
            FileUtils.unlink (grown.get_path ());
        }
        var backing = new Subprocess.newv ({ "/usr/bin/qemu-img", "create", "-f", "qcow2",
            "-F", "raw", "-b", raw.get_path (), source.get_path () }, SubprocessFlags.STDOUT_SILENCE);
        yield backing.wait_check_async (token);
        try {
            yield VirtualDisk.inspect (source, token);
            throw new IOError.FAILED ("An external backing file should have been rejected.");
        } catch (IOError.NOT_SUPPORTED expected) {}
        FileUtils.unlink (source.get_path ());
        yield VirtualDisk.write_image (raw, source, "qcow2", 0, token);
        var snapshot = new Subprocess.newv ({ "/usr/bin/qemu-img", "snapshot", "-c", "fixture",
            source.get_path () }, SubprocessFlags.NONE);
        yield snapshot.wait_check_async (token);
        var snapshotted = yield VirtualDisk.inspect (source, token);
        if (!snapshotted.has_snapshots) throw new IOError.INVALID_DATA ("The internal snapshot was not detected.");
        try {
            yield VirtualDisk.write_image (source, grown, "qcow2", initial * 2, token, null, snapshotted);
            throw new IOError.FAILED ("An internal snapshot should have blocked growth.");
        } catch (IOError.INVALID_DATA expected) {}
        yield VirtualDisk.write_image (raw, grown, "qcow2", 0, token, null, null, null, true);
        var compressed = yield VirtualDisk.inspect (grown, token);
        if (compressed.format != "qcow2" || compressed.capacity != initial)
            throw new IOError.INVALID_DATA ("The compressed image has the wrong format or capacity.");
    } finally {
        FileUtils.unlink (source.get_path ());
        FileUtils.unlink (grown.get_path ());
        FileUtils.unlink (raw.get_path ());
        DirUtils.remove (directory);
    }
}

private async void exercise_image_conversions () throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-conversions-XXXXXX");
    File[] files = {};
    var token = new Cancellable ();
    var jobs = new StorageJobManager ();
    var job = jobs.begin_named ("Verify conversion fixtures", directory, {});
    try {
        var raw = File.new_for_path (Path.build_filename (directory, "source.img"));
        files += raw;
        yield DiskImageCopy.create_blank (raw, 64 * 1024 * 1024);
        var partitioner = new Subprocess.newv ({ "sfdisk", "--no-reread", "--no-tell-kernel", raw.get_path () },
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE);
        yield partitioner.communicate_utf8_async ("label: gpt\nstart=2048, size=32768, type=L\n", null, null, null);
        yield partitioner.wait_check_async ();
        var formatter = new Subprocess.newv ({ "mkfs.ext4", "-q", "-F", "-b", "4096",
            "-E", "offset=1048576", raw.get_path (), "4096" }, SubprocessFlags.NONE);
        yield formatter.wait_check_async ();
        set_nbd_marker (raw, "Verified logical image content");
        var original = yield DiskImageCopy.verify_file (raw, jobs, job);
        File[] containers = {};
        foreach (var format in new string[] { "qcow2", "vpc", "vhdx", "qcow2" }) {
            string extension = format == "vpc" ? "vhd" : format;
            var container = File.new_for_path (Path.build_filename (directory, "%u.%s".printf (files.length, extension)));
            var roundtrip = File.new_for_path (Path.build_filename (directory, "%u.img".printf (files.length)));
            files += container;
            files += roundtrip;
            yield VirtualDisk.write_image (raw, container, format, 0, token, null, null, null, containers.length == 3);
            yield VirtualDisk.write_image (container, roundtrip, "raw", 0, token);
            containers += container;
            var converted = yield DiskImageCopy.verify_file (container, jobs, job);
            var decoded = yield DiskImageCopy.verify_file (roundtrip, jobs, job);
            assert (converted.format == extension.up () && converted.logical_size == original.logical_size);
            assert (converted.digest == original.digest && decoded.digest == original.digest);
        }
        foreach (var format in new string[] { "vhdx", "qcow2" }) {
            var cross = File.new_for_path (Path.build_filename (directory, "cross." + format));
            files += cross;
            yield VirtualDisk.write_image (containers[format == "vhdx" ? 0 : 2], cross, format, 0, token);
            var logical = yield DiskImageCopy.verify_file (cross, jobs, job);
            assert (logical.digest == original.digest && logical.logical_size == original.logical_size);
        }
        var compressed = File.new_for_path (Path.build_filename (directory, "source.raw.xz"));
        var extracted = File.new_for_path (Path.build_filename (directory, "extracted.img"));
        files += compressed;
        files += extracted;
        yield DiskImageCopy.transform_xz (raw, compressed, true, jobs, job);
        yield DiskImageCopy.transform_xz (compressed, extracted, false, jobs, job);
        var verified = yield DiskImageCopy.verify_file (extracted, jobs, job);
        assert (verified.digest == original.digest && verified.logical_size == original.logical_size);
        assert ((yield DiskImageCopy.verify_file (raw, jobs, job)).digest == original.digest);
    } finally {
        foreach (var file in files) FileUtils.unlink (file.get_path ());
        DirUtils.remove (directory);
    }
}

public static int main (string[] args) {
    if ("--convert" in args) {
        if (!VirtualDisk.available () || Environment.find_program_in_path ("sfdisk") == null ||
            Environment.find_program_in_path ("mkfs.ext4") == null)
            return 77;
        var conversion_loop = new MainLoop ();
        int conversion_status = 0;
        exercise_image_conversions.begin ((object, result) => {
            try { exercise_image_conversions.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); conversion_status = 1; }
            conversion_loop.quit ();
        });
        conversion_loop.run ();
        return conversion_status;
    }
    if ("--grow" in args) {
        if (!VirtualDisk.available ()) {
            stdout.printf ("SKIP: image growth requires qemu-utils and Bubblewrap.\n");
            return 77;
        }
        var growth_loop = new MainLoop ();
        int growth_status = 0;
        exercise_image_growth.begin ((object, result) => {
            try { exercise_image_growth.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); growth_status = 1; }
            growth_loop.quit ();
        });
        growth_loop.run ();
        return growth_status;
    }
    bool nbd = args.length > 1 && args[1] == "--nbd";
    bool imaging_enabled = Environment.get_variable ("MAJORIS_DISKS_RUN_IMAGING_TESTS") == "1";
    bool use_xz = "--xz" in args;
    bool partition = "--partition" in args;
    string? virtual_format = "--qcow2" in args ? "qcow2" : "--vhd" in args ? "vpc" :
        "--vhdx" in args ? "vhdx" : null;
    if (virtual_format != null && !VirtualDisk.available ()) return 77;
    if (partition && Environment.find_program_in_path ("sfdisk") == null) {
        stdout.printf ("SKIP: sfdisk is required to create the partition fixture.\n");
        return 77;
    }
    if (nbd) {
        string? missing = VirtualDiskAttachment.unavailable_reason ();
        if ((!imaging_enabled && Environment.get_variable ("MAJORIS_DISKS_RUN_NBD_TESTS") != "1") || missing != null ||
            Environment.find_program_in_path ("sfdisk") == null || Environment.find_program_in_path ("mkfs.ext4") == null) {
            stdout.printf ("SKIP: NBD fixture requires explicit opt-in, the installed NBD backend, sfdisk and mkfs.ext4. %s\n",
                missing ?? "");
            return 77;
        }
    } else if (!imaging_enabled && Environment.get_variable ("MAJORIS_DISKS_RUN_LOOP_TESTS") != "1") {
        stdout.printf ("SKIP: set MAJORIS_DISKS_RUN_IMAGING_TESTS=1 to run disposable imaging tests\n");
        return 77;
    }
    var loop = new MainLoop ();
    int status = 0;
    if (nbd) exercise_nbd_devices.begin ((object, result) => {
        try { exercise_nbd_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    else exercise_devices.begin (use_xz, partition, "--mbr" in args, virtual_format, (object, result) => {
        try { exercise_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
