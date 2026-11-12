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

private async void exercise_devices (bool use_xz, bool partition, bool mbr, string? virtual_format,
    bool lost_rescan_reply) throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-devices-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var copy = File.new_for_path (Path.build_filename (directory, "copy.img"));
    var compressed = File.new_for_path (Path.build_filename (directory, partition ? "second.raw.xz" : "second.img.xz"));
    string extension = virtual_format == "vpc" ? "vhd" : virtual_format ?? "unused";
    var container = File.new_for_path (Path.build_filename (directory, "container." + extension));
    var oversized = File.new_for_path (Path.build_filename (directory, "oversized.raw"));
    var target = File.new_for_path (Path.build_filename (directory, "target.img"));
    string dispatches = Path.build_filename (directory, "dispatches");
    if (lost_rescan_reply) {
        Environment.set_variable ("MAJORIS_IMAGE_DISPATCH_LOG", dispatches, true);
        Environment.set_variable ("XDG_STATE_HOME", Path.build_filename (directory, "state"), true);
    }
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
        if (lost_rescan_reply) {
            string calls;
            FileUtils.get_contents (dispatches, out calls);
            if (result.successful || result.partial || result.status != StorageOperationStatus.NEEDS_ATTENTION ||
                !result.technical_error.contains ("Injected lost reply") || calls != "Rescan\n")
                throw new IOError.FAILED ("A lost rescan reply was not recorded as one uncertain operation.");
        } else if (!result.successful)
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
            FileUtils.unlink (dispatches);
            if (lost_rescan_reply) stdout.printf ("Recovery evidence directory: %s\n", directory);
            else DirUtils.remove (directory);
        } else warning ("A loop attachment could not be reconciled. Retained fixtures in %s", directory);
    }
}

private async void exercise_partial_restore (bool compressed, bool disappear = false) throws Error {
    const int CAPACITY = 128 * 1024 * 1024;
    string directory = DirUtils.make_tmp ("majoris-partial-restore-XXXXXX");
    Environment.set_variable ("XDG_STATE_HOME", Path.build_filename (directory, "state"), true);
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var packed = File.new_for_path (Path.build_filename (directory, "source.img.xz"));
    var target = File.new_for_path (Path.build_filename (directory, "target.img"));
    string moved = Path.build_filename (directory, "source-moved.img");
    var backend = new UDisksService ();
    StorageBlock? attached = null;
    bool interrupted = false;
    bool attachment_attempted = false;
    try {
        yield DiskImageCopy.create_blank (source, CAPACITY);
        yield DiskImageCopy.create_blank (target, CAPACITY);
        foreach (var file in new File[] { source, target }) {
            var stream = file.open_readwrite ();
            uint8[] marker = file == source ? "new".data : "old".data;
            size_t count;
            stream.output_stream.write_all (marker, out count);
            ((Seekable) stream).seek (CAPACITY - marker.length, SeekType.SET);
            stream.output_stream.write_all (marker, out count);
            stream.close ();
        }
        if (compressed) {
            var job = backend.jobs.begin_named ("Prepare compressed fixture", source.get_parse_name (), {});
            yield DiskImageCopy.transform_xz (source, packed, true, backend.jobs, job);
        }
        yield backend.refresh ();
        attachment_attempted = true;
        string path = yield backend.attach_disk_image (target, false);
        attached = backend.snapshot.blocks.lookup (path);
        if (attached?.loop?.backing_file != target.get_path () || attached.read_only || attached.size != CAPACITY)
            throw new IOError.INVALID_DATA ("Could not identify the disposable restore target.");
        var reader = target.read ();
        var poll = new TimeoutSource (1);
        poll.set_callback (() => {
            try {
                ((Seekable) reader).seek (0, SeekType.SET);
                var marker = reader.read_bytes (3);
                if (marker.compare (new Bytes ("new".data)) != 0) return Source.CONTINUE;
                for (uint i = 0; i < backend.jobs.jobs.get_n_items (); i++) {
                    var job = (StorageJob) backend.jobs.jobs.get_item (i);
                    if (job.operation == "Restore disk image" && job.cancelable) {
                        if (disappear) interrupted = FileUtils.rename (source.get_path (), moved) == 0;
                        else {
                            interrupted = true;
                            job.cancellable.cancel ();
                        }
                        return Source.REMOVE;
                    }
                }
            } catch (Error error) { warning ("%s", error.message); return Source.REMOVE; }
            return Source.CONTINUE;
        });
        poll.attach (MainContext.ref_thread_default ());
        StorageOperationResult? result = null;
        try {
            result = yield backend.restore_disk_image (attached, compressed ? packed : source,
                backend.modification_identity (attached));
        } finally { poll.destroy (); }
        if (!interrupted || result.successful || result.partial == disappear ||
            result.status != StorageOperationStatus.NEEDS_ATTENTION)
            throw new IOError.FAILED ("Unexpected result after an observed target write: " + result.summary);
        ((Seekable) reader).seek (0, SeekType.SET);
        assert (reader.read_bytes (3).compare (new Bytes ("new".data)) == 0);
        ((Seekable) reader).seek (CAPACITY - 3, SeekType.SET);
        assert (reader.read_bytes (3).compare (new Bytes (disappear ? "new".data : "old".data)) == 0);
        reader.close ();
        var journal = Dir.open (Path.build_filename (directory, "state", "majoris-disks", "imaging"));
        assert (journal.read_name () != null);
        stdout.printf (disappear ?
            "Verified the writes and retained a recovery record after the original source path disappeared.\n" :
            "Observed new data at the head, original data at the tail, and a retained recovery record.\n");
    } finally {
        if (attached != null && attached.loop?.backing_file == target.get_path ()) {
            try {
                yield backend.detach_disk_image (attached);
                attachment_attempted = false;
            } catch (Error error) { warning ("Could not detach the restore fixture: %s", error.message); }
        }
        if (!attachment_attempted) {
            FileUtils.unlink (target.get_path ());
            FileUtils.unlink (source.get_path ());
            FileUtils.unlink (packed.get_path ());
            FileUtils.unlink (moved);
        }
        stdout.printf ("Fixture evidence directory: %s\n", directory);
    }
}

private async void exercise_interrupted_output (bool compressed, bool convert) throws Error {
    string directory = DirUtils.make_tmp ("majoris-interrupted-output-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var destination = File.new_for_path (Path.build_filename (directory,
        convert ? "output.qcow2" : compressed ? "output.img.xz" : "output.img"));
    var backend = new UDisksService ();
    StorageBlock? attached = null;
    bool keep = false;
    bool observed_output = false;
    try {
        yield DiskImageCopy.create_blank (source, 128 * 1024 * 1024);
        var random = File.new_for_path ("/dev/urandom").read ();
        var writer = source.open_readwrite ();
        uint8[] buffer = new uint8[2 * 1024 * 1024];
        size_t count;
        random.read_all (buffer, out count);
        assert (count == buffer.length);
        writer.output_stream.write_all (buffer, out count);
        assert (count == buffer.length);
        writer.close ();
        random.close ();
        if (convert) {
            var token = new Cancellable ();
            try {
                yield VirtualDisk.write_image (source, destination, "qcow2", 0, token, (fraction) => {
                    if (fraction > 0) {
                        observed_output = true;
                        token.cancel ();
                    }
                });
            } catch (IOError.CANCELLED error) {}
        } else {
            yield backend.refresh ();
            keep = true;
            string path = yield backend.attach_disk_image (source, true);
            attached = backend.snapshot.blocks.lookup (path);
            if (attached?.loop?.backing_file != source.get_path () || !attached.read_only)
                throw new IOError.INVALID_DATA ("Could not verify the disposable backup source.");
            var poll = new TimeoutSource (1);
            poll.set_callback (() => {
                try {
                    var entries = Dir.open (directory);
                    string? entry;
                    while ((entry = entries.read_name ()) != null) {
                        Posix.Stat output = {};
                        if (!entry.has_prefix (".majoris-") ||
                            Posix.lstat (Path.build_filename (directory, entry, "disk"), out output) != 0 ||
                            output.st_size == 0)
                            continue;
                        for (uint i = 0; i < backend.jobs.jobs.get_n_items (); i++) {
                            var job = (StorageJob) backend.jobs.jobs.get_item (i);
                            if (job.operation == "Create disk image" && job.cancelable) {
                                observed_output = true;
                                job.cancellable.cancel ();
                                return Source.REMOVE;
                            }
                        }
                    }
                } catch (FileError error) { warning ("%s", error.message); return Source.REMOVE; }
                return Source.CONTINUE;
            });
            poll.attach (MainContext.ref_thread_default ());
            try {
                yield backend.create_disk_image (attached, destination, backend.modification_identity (attached), true);
            } catch (IOError.CANCELLED error) {}
            finally { poll.destroy (); }
        }
        if (!observed_output || destination.query_exists ())
            throw new IOError.FAILED ("Cancellation did not stop publication after output began.");
        var remaining = Dir.open (directory);
        string? entry;
        while ((entry = remaining.read_name ()) != null) {
            if (entry.has_prefix (".majoris-"))
                throw new IOError.FAILED ("Private output was left behind after cancellation.");
        }
    } finally {
        if (attached?.loop?.backing_file == source.get_path ()) {
            try { yield backend.detach_disk_image (attached); keep = false; }
            catch (Error error) { warning ("Could not detach the backup fixture: %s", error.message); }
        }
        if (!keep) {
            FileUtils.unlink (source.get_path ());
            FileUtils.unlink (destination.get_path ());
        }
        if (keep || DirUtils.remove (directory) != 0)
            stdout.printf ("Retained interruption fixture: %s\n", directory);
    }
}

private async void crash_conversion_worker (string directory) throws Error {
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var destination = File.new_for_path (Path.build_filename (directory, "output.qcow2"));
    yield VirtualDisk.write_image (source, destination, "qcow2", 0, new Cancellable (), (fraction) => {
        if (fraction > 0) Posix._exit (95);
    });
    throw new IOError.FAILED ("The conversion worker returned without the simulated crash.");
}

private async void exercise_conversion_crash () throws Error {
    string directory = DirUtils.make_tmp ("majoris-conversion-crash-XXXXXX");
    Environment.set_variable ("XDG_STATE_HOME", Path.build_filename (directory, "state"), true);
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    yield DiskImageCopy.create_blank (source, 128 * 1024 * 1024);
    string executable = FileUtils.read_link ("/proc/self/exe");
    var child = new Subprocess.newv ({ executable, "--crash-conversion-worker", directory }, SubprocessFlags.NONE);
    yield child.wait_async ();
    if (!child.get_if_exited () || child.get_exit_status () != 95 ||
        FileUtils.test (Path.build_filename (directory, "output.qcow2"), FileTest.EXISTS))
        throw new IOError.FAILED ("The conversion crash did not leave an unpublished result.");
    var jobs = new StorageJobManager ();
    ImageOperationJournal.recover (jobs);
    var recovered = jobs.jobs.get_item (0) as StorageJob;
    if (jobs.jobs.get_n_items () != 1 || recovered?.result?.status != StorageOperationStatus.NEEDS_ATTENTION)
        throw new IOError.FAILED ("A new process did not recover the interrupted conversion record.");
    stdout.printf ("Recovered interrupted conversion evidence in %s.\n", directory);
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

[CCode (cname = "pidfd_open", cheader_filename = "sys/pidfd.h")]
private extern int fixture_pidfd_open (int pid, uint flags);
[CCode (cname = "pidfd_send_signal", cheader_filename = "sys/pidfd.h")]
private extern int fixture_pidfd_signal (int fd, int signal, void* info, uint flags);

private string fixture_process_start (uint pid) throws Error {
    string stat;
    FileUtils.get_contents ("/proc/%u/stat".printf (pid), out stat);
    int end = stat.last_index_of (") ");
    if (end < 0) throw new IOError.INVALID_DATA ("The process start identity is unavailable.");
    string[] fields = stat.substring (end + 2).split (" ");
    if (fields.length < 20 || fields[0] == "Z" || fields[0] == "X")
        throw new IOError.INVALID_DATA ("The fixture process is no longer active.");
    return fields[19];
}

private uint find_fixture_exporter (uint pid, string token, int depth = 0) throws Error {
    if (pid == 0 || depth > 8) return 0;
    string process = "/proc/%u".printf (pid);
    if (Path.get_basename (FileUtils.read_link (process + "/exe")) == "qemu-nbd") {
        uint8[] cmdline;
        FileUtils.get_data (process + "/cmdline", out cmdline);
        for (int i = 0; i < cmdline.length; i++) {
            if (cmdline[i] == 0) cmdline[i] = (uint8) ' ';
        }
        string arguments = (string) cmdline;
        if ((" " + arguments).contains (" --export-name=" + token + " ")) return pid;
        return 0;
    }
    string children;
    FileUtils.get_contents (process + "/task/%u/children".printf (pid), out children);
    foreach (var child in children.strip ().split (" ")) {
        uint candidate;
        if (!uint.try_parse (child, out candidate)) continue;
        uint exporter = find_fixture_exporter (candidate, token, depth + 1);
        if (exporter != 0) return exporter;
    }
    return 0;
}

private async bool exercise_nbd_interruption (bool client, bool during_restore) throws Error {
    string directory = DirUtils.make_tmp ("majoris-nbd-interruption-XXXXXX");
    var image = File.new_for_path (Path.build_filename (directory, "blank.qcow2"));
    var copy = File.new_for_path (Path.build_filename (directory, "readback.img"));
    var source = File.new_for_path (Path.build_filename (directory, "restore.img"));
    var backend = new UDisksService ();
    bool retain = false;
    try {
        uint64 capacity = (during_restore ? 256 : 64) * 1024 * 1024;
        yield VirtualDisk.write_image (null, image, "qcow2", capacity, new Cancellable ());
        if (during_restore) {
            yield DiskImageCopy.create_blank (source, capacity);
            var fixture = source.open_readwrite ();
            size_t written;
            fixture.output_stream.write_all ("new".data, out written);
            assert (written == 3);
            fixture.close ();
        }
        yield backend.refresh ();
        retain = true;
        string path = yield backend.attach_virtual_image (image, !during_restore);
        var block = backend.snapshot.blocks.lookup (path);
        var record = block?.virtual_attachment;
        if (record == null || record.file != image.get_path () || block.table != null)
            throw new IOError.INVALID_DATA ("The unpartitioned QCOW2 fixture was not verified.");
        verify_nbd_journal (record);
        string sysfs = "/sys/block/nbd%u".printf (record.index);
        uint pid;
        string client_start = "";
        string disk_sequence;
        FileUtils.get_contents (sysfs + "/diskseq", out disk_sequence);
        if (client) {
            string pid_text;
            FileUtils.get_contents (sysfs + "/pid", out pid_text);
            var journal = new KeyFile ();
            journal.load_from_file (nbd_journal (record), KeyFileFlags.NONE);
            if (!uint.try_parse (pid_text.strip (), out pid) || pid == 0 ||
                journal.get_uint64 ("attachment", "client-pid") != pid)
                throw new IOError.INVALID_DATA ("The NBD client could not be identified.");
            if (!FileUtils.test ("/proc/%u/exe".printf (pid), FileTest.EXISTS)) {
                yield backend.detach_disk_image (block);
                verify_nbd_cleanup (record);
                retain = false;
                stdout.printf ("SKIP: the active netlink mapping has no foreground NBD client process.\n");
                return false;
            }
            if (Path.get_basename (FileUtils.read_link ("/proc/%u/exe".printf (pid))) != "nbd-client")
                throw new IOError.INVALID_DATA ("The recorded client process no longer owns the mapping.");
            client_start = journal.get_string ("attachment", "client-start");
        } else pid = find_fixture_exporter (record.exporter_pid, record.token);
        int pidfd = pid > 0 && pid <= int.MAX ? fixture_pidfd_open ((int) pid, 0) : -1;
        if (pidfd < 0) throw new IOError.NOT_FOUND ("The fixture process could not be pinned.");
        try {
            if (client) {
                string current_sequence;
                FileUtils.get_contents (sysfs + "/diskseq", out current_sequence);
                if (disk_sequence.strip () == "" || current_sequence != disk_sequence ||
                    fixture_process_start (pid) != client_start || !VirtualDiskAttachment.exporter_running (record))
                    throw new IOError.INVALID_DATA ("The foreground client, exporter, or NBD mapping changed.");
                stdout.printf ("Pinned NBD client %u, start %s, diskseq %s, exporter %u, token %s, index %u\n",
                    pid, client_start, disk_sequence.strip (), record.exporter_pid, record.token, record.index);
            }
            if (during_restore) {
                bool stopped = false;
                ulong update = backend.jobs.changed.connect (() => {
                    if (stopped) return;
                    for (uint i = 0; i < backend.jobs.jobs.get_n_items (); i++) {
                        var job = (StorageJob) backend.jobs.jobs.get_item (i);
                        if (job.operation != "Restore disk image" || !job.progress_valid ||
                            job.progress <= 0 || job.progress >= 1 || !job.phase.has_suffix (" s remaining"))
                            continue;
                        int device = Posix.open (block.device, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
                        if (device < 0) return;
                        uint8[] observed = new uint8[3];
                        ssize_t count = Posix.read (device, observed, observed.length);
                        Posix.close (device);
                        if (count == 3 && new Bytes (observed).compare (new Bytes ("new".data)) == 0 &&
                            VirtualDiskAttachment.lookup (block.device)?.token == record.token)
                            stopped = fixture_pidfd_signal (pidfd, Posix.Signal.KILL, null, 0) == 0;
                        return;
                    }
                });
                StorageOperationResult? result = null;
                try { result = yield backend.restore_disk_image (block, source, backend.modification_identity (block)); }
                finally { backend.jobs.disconnect (update); }
                if (!stopped || result.successful || !result.partial ||
                    result.status != StorageOperationStatus.NEEDS_ATTENTION)
                    throw new IOError.FAILED ("NBD target loss did not produce a verified partial restore: " + result.summary);
                stdout.printf ("NBD target became unavailable after an independently observed write.\n");
            } else if (VirtualDiskAttachment.lookup (block.device)?.token != record.token ||
                fixture_pidfd_signal (pidfd, Posix.Signal.KILL, null, 0) != 0)
                throw new IOError.FAILED ("Could not terminate the verified NBD fixture process.");
        } finally { Posix.close (pidfd); }

        if (!during_restore) {
            bool read_failed = false;
            try { yield backend.create_disk_image (block, copy, backend.modification_identity (block), true); }
            catch (Error error) { read_failed = true; stdout.printf ("Interrupted NBD read: %s\n", error.message); }
            if (!read_failed || copy.query_exists ())
                throw new IOError.FAILED ("The interrupted attachment was reported as a successful backup.");
        }
        yield backend.refresh ();
        var current = backend.snapshot.blocks.lookup (path);
        if (current?.virtual_attachment?.token == record.token) {
            yield backend.detach_disk_image (current);
            verify_nbd_cleanup (record);
        } else {
            string size;
            FileUtils.get_contents (sysfs + "/size", out size);
            if (size.strip () != "0" || FileUtils.test (sysfs + "/pid", FileTest.EXISTS))
                throw new IOError.FAILED ("The mapping is no longer owned by the fixture and was retained for review.");
        }
        retain = FileUtils.test (nbd_journal (record), FileTest.EXISTS);
        return true;
    } finally {
        if (retain) stdout.printf ("Retained NBD fixture evidence: %s\n", directory);
        else {
            FileUtils.unlink (copy.get_path ());
            FileUtils.unlink (image.get_path ());
            FileUtils.unlink (source.get_path ());
            DirUtils.remove (directory);
        }
    }
}

private string fixture_udisks_owner () throws Error {
    var bus = Bus.get_sync (BusType.SYSTEM);
    var reply = bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetNameOwner", new Variant ("(s)", "org.freedesktop.UDisks2"),
        new VariantType ("(s)"), DBusCallFlags.NONE, 5000);
    return reply.get_child_value (0).get_string ();
}

private VirtualAttachment fixture_nbd_record (File image) throws Error {
    var blocks = Dir.open ("/sys/class/block");
    string? name;
    while ((name = blocks.read_name ()) != null) {
        if (!Regex.match_simple ("^nbd[0-9]+$", name)) continue;
        var record = VirtualDiskAttachment.lookup ("/dev/" + name);
        if (record?.file == image.get_path ()) return record;
    }
    throw new IOError.NOT_FOUND ("The accepted NBD mapping could not be identified at the restart barrier.");
}

private async void exercise_nbd_devices (bool restart, bool reuse) throws Error {
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
        string[] formats = restart || reuse ? new string[] { "qcow2" } :
            new string[] { "vpc", "vhdx", "qcow2", "compressed-qcow2" };
        foreach (var fixture in formats) {
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
                VirtualAttachment? before = null;
                string sequence = "";
                Error? restart_error = null;
                ulong barrier = 0;
                if (restart) barrier = backend.jobs.changed.connect (() => {
                    if (before != null || restart_error != null) return;
                    for (uint i = 0; i < backend.jobs.jobs.get_n_items (); i++) {
                        var job = backend.jobs.jobs.get_item (i) as StorageJob;
                        if (job?.phase != "Waiting for UDisks discovery") continue;
                        try {
                            before = fixture_nbd_record (image);
                            verify_nbd_journal (before);
                            FileUtils.get_contents ("/sys/block/nbd%u/diskseq".printf (before.index), out sequence);
                            string previous = fixture_udisks_owner ();
                            var systemctl = new Subprocess.newv ({ "systemctl", "restart", "udisks2" }, SubprocessFlags.NONE);
                            systemctl.wait_check ();
                            string current = fixture_udisks_owner ();
                            if (current == previous) throw new IOError.FAILED ("UDisks did not acquire a new owner.");
                            stdout.printf ("NBD token %s, index %u, diskseq %s, exporter %u, UDisks %s -> %s\n",
                                before.token, before.index, sequence.strip (), before.exporter_pid, previous, current);
                        } catch (Error error) { restart_error = error; }
                        return;
                    }
                });
                stdout.printf ("Attaching NBD fixture %s read-only\n", fixture);
                string path = "";
                try { path = yield backend.attach_virtual_image (image, true); }
                finally { if (barrier != 0) backend.jobs.disconnect (barrier); }
                block = backend.snapshot.blocks.lookup (path);
                if (block == null || block.virtual_attachment?.file != image.get_path () ||
                    block.virtual_attachment.format != format || !block.read_only || block.size != 64 * 1024 * 1024)
                    throw new IOError.INVALID_DATA ("The managed virtual fixture could not be verified.");
                verify_nbd_journal (block.virtual_attachment);
                if (restart) {
                    if (restart_error != null) throw restart_error;
                    string current_sequence;
                    var after = block.virtual_attachment;
                    FileUtils.get_contents ("/sys/block/nbd%u/diskseq".printf (after.index), out current_sequence);
                    if (before == null || before.token != after.token || before.index != after.index ||
                        before.exporter_pid != after.exporter_pid || before.exporter_start != after.exporter_start ||
                        sequence.strip () == "" || current_sequence != sequence)
                        throw new IOError.INVALID_DATA ("The NBD mapping changed across the UDisks restart.");
                }
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
                var stale = block;
                uint64 old_number = block.number;
                string old_sequence = "";
                if (reuse) FileUtils.get_contents ("/sys/block/nbd%u/diskseq".printf (record.index), out old_sequence);
                yield backend.detach_disk_image (block);
                verify_nbd_cleanup (record);
                block = null;
                retain = false;

                if (reuse) {
                    var replacement = File.new_for_path (Path.build_filename (directory, "replacement.qcow2"));
                    yield VirtualDisk.write_image (raw, replacement, "qcow2", 0, new Cancellable ());
                    retain = true;
                    string replacement_path = yield backend.attach_virtual_image (replacement, true);
                    var current = backend.snapshot.blocks.lookup (replacement_path);
                    var next = current?.virtual_attachment;
                    if (next == null || next.file != replacement.get_path () || next.token == record.token)
                        throw new IOError.INVALID_DATA ("The replacement NBD fixture identity was not established.");
                    verify_nbd_journal (next);
                    string next_sequence;
                    FileUtils.get_contents ("/sys/block/nbd%u/diskseq".printf (next.index), out next_sequence);
                    if (old_sequence.strip () == "" || next_sequence.strip () == "")
                        throw new IOError.INVALID_DATA ("The NBD disk sequence could not be verified.");
                    stdout.printf ("NBD %u -> %u, diskseq %s -> %s, tokens %s -> %s\n",
                        record.index, next.index, old_sequence.strip (), next_sequence.strip (), record.token, next.token);
                    bool reused_number = old_number == current.number && record.index == next.index;
                    try {
                        yield backend.detach_disk_image (stale);
                        throw new IOError.FAILED ("A stale NBD reference was accepted.");
                    } catch (IOError.NOT_FOUND error) {
                        if (VirtualDiskAttachment.lookup (current.device)?.token != next.token)
                            throw new IOError.FAILED ("The stale detach affected the replacement NBD mapping.");
                    }
                    yield verify_nbd_marker (backend, current, readback, "Majoris read fixture");
                    yield backend.detach_disk_image (current);
                    verify_nbd_cleanup (next);
                    replacement.delete (null);
                    retain = false;
                    if (!reused_number)
                        throw new IOError.NOT_SUPPORTED ("The fixture did not obtain the same NBD device number.");
                }
                if (fixture == "qcow2" && !restart && !reuse) {
                    retain = true;
                    stdout.printf ("Reattaching NBD fixture %s writable\n", fixture);
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

private void exercise_publication () throws Error {
    string directory = DirUtils.make_tmp ("majoris-publication-test-XXXXXX");
    string temporary = Path.build_filename (directory, "private");
    string destination = Path.build_filename (directory, "published.img");
    try {
        FileUtils.set_contents (temporary, "verified fixture");
        var publication = new ImagePublication (destination);
        int fd = VirtualDisk.open_image (File.new_for_path (temporary));
        Posix.Stat verified = {};
        try { verified = ImagePublication.flush (fd); }
        finally { Posix.close (fd); }
        FileUtils.set_contents (destination, "existing fixture");
        try {
            publication.publish (temporary, verified);
            assert_not_reached ();
        } catch (IOError error) {}
        string contents;
        FileUtils.get_contents (destination, out contents);
        assert (contents == "existing fixture");
        assert (FileUtils.unlink (destination) == 0);
        try {
            publication.publish (temporary, verified, (fd) => -1);
            assert_not_reached ();
        } catch (ImagePublicationError.DURABILITY_UNVERIFIED error) {
            var result = new StorageOperationResult ();
            ImagePublication.describe_failure (result, "Failed", error);
            assert (!result.successful && result.status == StorageOperationStatus.NEEDS_ATTENTION);
        }
        assert (!FileUtils.test (temporary, FileTest.EXISTS));
        FileUtils.get_contents (destination, out contents);
        assert (contents == "verified fixture");
    } finally {
        FileUtils.unlink (temporary);
        FileUtils.unlink (destination);
        DirUtils.remove (directory);
    }
}

private void publication_power_loss_worker (string fixture, string checkpoint) throws Error {
    string temporary = Path.build_filename (fixture, "work", "image");
    string destination = Path.build_filename (fixture, "published.img");
    var recovery = new ImageOperationJournal ("Power-loss image fixture", destination, checkpoint);
    var publication = new ImagePublication (destination);
    int fd = VirtualDisk.open_image (File.new_for_path (temporary));
    Posix.Stat verified = {};
    try { verified = ImagePublication.flush (fd); }
    finally { Posix.close (fd); }
    if (checkpoint == "incomplete-output") publication_power_loss_barrier (checkpoint, verified);
    if (checkpoint == "before-rename") publication_power_loss_barrier (checkpoint, verified);
    publication.publish (temporary, verified, (directory) => {
        if (checkpoint == "before-directory-sync") publication_power_loss_barrier (checkpoint, verified);
        return Posix.fsync (directory);
    });
    if (checkpoint == "after-directory-sync") publication_power_loss_barrier (checkpoint, verified);
    recovery.remove ();
    throw new IOError.INVALID_ARGUMENT ("Unknown publication checkpoint.");
}

private void publication_power_loss_barrier (string checkpoint, Posix.Stat verified) {
    stdout.printf ("POWER-LOSS READY %s inode %s size %s\n", checkpoint,
        ((uint64) verified.st_ino).to_string (), ((uint64) verified.st_size).to_string ());
    stdout.flush ();
    while (true) Posix.pause ();
}

private void exercise_discovery_race () {
    var disk = new StorageBlock ("/fixture");
    var blank = new ImagePartitionLayout ();
    assert (blank.matches_discovery (disk, {}));
    var layout = new ImagePartitionLayout () { has_table = true, scheme = "gpt" };
    layout.partitions = { ImagePartitionGeometry () { number = 1, offset = 1048576, size = 16777216 } };
    assert (!layout.matches_discovery (disk, {}));
    assert (!layout.matches_discovery (disk, { "7:1" }));
    disk.table = new StoragePartitionTable ("gpt");
    var part = new StorageBlock ("/fixture/part1") {
        available = true, number = 0x701, size = 16777216,
        partition = new StoragePartition () {
            number = 1, offset = 1048576, table_path = disk.path, table_size = 16777216
        }
    };
    disk.table.partitions = { part };
    assert (!layout.matches_discovery (disk, {}));
    assert (!layout.matches_discovery (disk, { "7:2" }));
    part.partition.table_path = "/other";
    assert (!layout.matches_discovery (disk, { "7:1" }));
    part.partition.table_path = disk.path;
    assert (layout.matches_discovery (disk, { "7:1" }));
    assert (part.type_id == "");
    disk.table.partitions = {};
    assert (!layout.matches_discovery (disk, { "7:1" }));
}

private async void exercise_loop_fault (string[] args) throws Error {
    string directory = Path.get_dirname (args[3]);
    Posix.Stat fixture = {};
    if (!directory.has_prefix ("/var/tmp/majoris-loop-fault.") || Path.get_basename (args[3]) != "fixture.img" ||
        Posix.lstat (directory, out fixture) != 0 || !Posix.S_ISDIR (fixture.st_mode) ||
        fixture.st_uid != 0 || (fixture.st_mode & 077) != 0)
        throw new IOError.PERMISSION_DENIED ("The loop fault test requires a private fixture directory.");
    var backend = new UDisksService ();
    yield backend.refresh ();
    var image = File.new_for_path (args[3]);
    string mode = args[2];
    if (mode == "recover-setup") {
        ImageOperationJournal.recover (backend.jobs);
        var job = backend.jobs.jobs.get_item (0) as StorageJob;
        if (backend.jobs.jobs.get_n_items () != 1 || job?.target != args[3] ||
            job.result?.status != StorageOperationStatus.NEEDS_ATTENTION)
            throw new IOError.FAILED ("A fresh client did not recover the uncertain LoopSetup record.");
        int mappings = 0;
        foreach (var current in backend.snapshot.blocks.get_values ()) {
            if (current.loop?.backing_file == args[3] && current.loop.sequence != "") mappings++;
        }
        if (mappings != 1) throw new IOError.INVALID_DATA ("A fresh client did not rediscover exactly one fixture mapping.");
        return;
    }
    string path = "";
    try {
        path = yield backend.attach_disk_image (image, true);
    } catch (RawAttachmentError.UNCERTAIN error) {
        if (!(mode == "setup" && error.message.contains ("Injected lost LoopSetup")) &&
            !(mode == "substitute" && (error.message.contains ("image changed") ||
                error.message.contains ("discovery is incomplete")))) throw error;
        var job = backend.jobs.jobs.get_item (0) as StorageJob;
        if (job?.result?.status != StorageOperationStatus.NEEDS_ATTENTION)
            throw new IOError.FAILED ("An accepted LoopSetup with a lost reply was not classified as uncertain.");
        return;
    }
    if (mode == "setup" || mode == "substitute")
        throw new IOError.FAILED ("Expected the LoopSetup result to require observation.");
    var block = backend.snapshot.blocks.lookup (path);
    if (block?.loop?.backing_file != args[3] || block.loop.sequence == "")
        throw new IOError.INVALID_DATA ("The fixture loop identity could not be verified.");
    stdout.printf ("Loop %s device %s diskseq %s backing %s\n", path, block.number.to_string (),
        block.loop.sequence, block.loop.backing_file);
    if (mode == "restart") {
        if (block.table?.partitions.length != 1)
            throw new IOError.INVALID_DATA ("The replacement UDisks owner did not publish the fixture partition.");
        return;
    }
    if (mode == "reuse") {
        string old_sequence = block.loop.sequence;
        string device = block.device;
        uint64 number = block.number;
        yield backend.detach_disk_image (block);
        var replacement = new Subprocess.newv ({ "losetup", "--read-only", "--partscan", device, args[3] + ".replacement" },
            SubprocessFlags.NONE);
        yield replacement.wait_check_async ();
        string sysfs = "/sys/dev/block/" + KernelStorageSafety.device_number (number);
        string sequence;
        FileUtils.get_contents (sysfs + "/diskseq", out sequence);
        if (sequence.strip () == "" || sequence.strip () == old_sequence)
            throw new IOError.INVALID_DATA ("The fixture could not establish a new loop disk sequence.");
        var trigger = new Subprocess.newv ({ "udevadm", "trigger", "--action=change", "--settle", device }, SubprocessFlags.NONE);
        yield trigger.wait_check_async ();
        yield backend.refresh ();
        try {
            yield backend.detach_disk_image (block);
            throw new IOError.FAILED ("A stale loop reference was accepted.");
        } catch (IOError.NOT_FOUND error) {
            stdout.printf ("Stale loop detach rejected on %s, diskseq %s -> %s\n", device, old_sequence, sequence.strip ());
        }
        string current_sequence;
        FileUtils.get_contents (sysfs + "/diskseq", out current_sequence);
        int probe = Posix.open (device, Posix.O_RDONLY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW);
        if (probe < 0 || current_sequence != sequence)
            throw new IOError.INVALID_DATA ("Could not verify the replacement loop device for cleanup.");
        try { match_loop_backing (probe, args[3] + ".replacement"); }
        finally { Posix.close (probe); }
        var cleanup = new Subprocess.newv ({ "losetup", "-d", device }, SubprocessFlags.NONE);
        yield cleanup.wait_check_async ();
        return;
    }
    yield backend.detach_disk_image (block);
}

private bool fixture_is_debian_qemu () {
    if (Posix.getuid () != 0) return false;
    try {
        var guest = new Subprocess.newv ({ "systemd-detect-virt", "--vm" }, SubprocessFlags.STDOUT_PIPE);
        string virtualization;
        guest.communicate_utf8 (null, null, out virtualization, null);
        string release;
        FileUtils.get_contents ("/etc/os-release", out release);
        return guest.get_successful () && virtualization.strip () == "qemu" &&
            "\nID=debian\n" in release && "\nVERSION_ID=\"13\"\n" in release;
    } catch (Error error) { return false; }
}

public static int main (string[] args) {
    if ("--publication-power-loss-recover" in args) {
        if (Environment.get_variable ("MAJORIS_DISKS_RUN_POWER_LOSS_TESTS") != "1" || !fixture_is_debian_qemu ())
            return 77;
        var jobs = new StorageJobManager ();
        ImageOperationJournal.recover (jobs);
        var recovered = jobs.jobs.get_item (0) as StorageJob;
        return jobs.jobs.get_n_items () == 1 && recovered?.operation == "Power-loss image fixture" &&
            recovered.result?.status == StorageOperationStatus.NEEDS_ATTENTION ? 0 : 1;
    }
    if (args.length == 4 && args[1] == "--publication-power-loss-worker") {
        if (Environment.get_variable ("MAJORIS_DISKS_RUN_POWER_LOSS_TESTS") != "1" || !fixture_is_debian_qemu ())
            return 77;
        try { publication_power_loss_worker (args[2], args[3]); }
        catch (Error error) { stderr.printf ("%s\n", error.message); return 1; }
    }
    if (args.length >= 4 && args[1] == "--loop-fault") {
        if (Environment.get_variable ("MAJORIS_DISKS_RUN_LOOP_TESTS") != "1" || !fixture_is_debian_qemu ()) return 77;
        var fixture_loop = new MainLoop ();
        int fixture_status = 0;
        exercise_loop_fault.begin (args, (object, result) => {
            try { exercise_loop_fault.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); fixture_status = 1; }
            fixture_loop.quit ();
        });
        fixture_loop.run ();
        return fixture_status;
    }
    if ("--discovery-race" in args) {
        exercise_discovery_race ();
        return 0;
    }
    if ("--conversion-crash" in args || (args.length == 3 && args[1] == "--crash-conversion-worker")) {
        if (!VirtualDisk.available ()) return 77;
        var crash_loop = new MainLoop ();
        int crash_status = 0;
        if (args.length == 3) crash_conversion_worker.begin (args[2], (object, result) => {
            try { crash_conversion_worker.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); crash_status = 1; }
            crash_loop.quit ();
        });
        else exercise_conversion_crash.begin ((object, result) => {
            try { exercise_conversion_crash.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); crash_status = 1; }
            crash_loop.quit ();
        });
        crash_loop.run ();
        return crash_status;
    }
    if ("--publication" in args) {
        try { exercise_publication (); return 0; }
        catch (Error error) { stderr.printf ("%s\n", error.message); return 1; }
    }
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
    bool restart_nbd = "--restart-udisks" in args;
    bool reuse_nbd = "--reuse-device" in args;
    if (restart_nbd && Environment.get_variable ("MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS") != "1") return 77;
    if ((restart_nbd || reuse_nbd) && !fixture_is_debian_qemu ()) return 77;
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
    bool interrupted_conversion = "--interrupt-conversion" in args;
    if (interrupted_conversion && !VirtualDisk.available ()) return 77;
    if (nbd) {
        string? missing = VirtualDiskAttachment.unavailable_reason ();
        if ((!imaging_enabled && Environment.get_variable ("MAJORIS_DISKS_RUN_NBD_TESTS") != "1") || missing != null ||
            Environment.find_program_in_path ("sfdisk") == null || Environment.find_program_in_path ("mkfs.ext4") == null) {
            stdout.printf ("SKIP: NBD fixture requires explicit opt-in, the installed NBD backend, sfdisk and mkfs.ext4. %s\n",
                missing ?? "");
            return 77;
        }
    } else if (!interrupted_conversion && !imaging_enabled &&
        Environment.get_variable ("MAJORIS_DISKS_RUN_LOOP_TESTS") != "1") {
        stdout.printf ("SKIP: set MAJORIS_DISKS_RUN_IMAGING_TESTS=1 to run disposable imaging tests\n");
        return 77;
    }
    var loop = new MainLoop ();
    int status = 0;
    if (nbd && ("--kill-exporter" in args || "--kill-client" in args || "--lose-target" in args))
        exercise_nbd_interruption.begin ("--kill-client" in args, "--lose-target" in args, (object, result) => {
            try { if (!exercise_nbd_interruption.end (result)) status = 77; }
            catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
            loop.quit ();
        });
    else if (nbd) exercise_nbd_devices.begin (restart_nbd, reuse_nbd, (object, result) => {
        try { exercise_nbd_devices.end (result); }
        catch (IOError.NOT_SUPPORTED error) {
            stderr.printf ("%s\n", error.message);
            status = reuse_nbd && error.message == "The fixture did not obtain the same NBD device number." ? 77 : 1;
        }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    else if ("--interrupt-backup" in args || interrupted_conversion)
        exercise_interrupted_output.begin (use_xz, interrupted_conversion, (object, result) => {
            try { exercise_interrupted_output.end (result); }
            catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
            loop.quit ();
        });
    else if ("--partial" in args) exercise_partial_restore.begin (use_xz, "--disappear-source" in args,
        (object, result) => {
        try { exercise_partial_restore.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    else exercise_devices.begin (use_xz, partition, "--mbr" in args, virtual_format, "--lost-rescan" in args,
        (object, result) => {
        try { exercise_devices.end (result); }
        catch (Error error) { stderr.printf ("%s\n", error.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
