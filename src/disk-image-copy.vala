namespace MajorisDisks {
    [CCode (cname = "read", cheader_filename = "unistd.h")]
    private extern ssize_t read_bytes (int fd, void* bytes, size_t count);
    [CCode (cname = "write", cheader_filename = "unistd.h")]
    private extern ssize_t write_bytes (int fd, void* bytes, size_t count);

    internal class DiskImageCopy {
        public static async void copy (int input, int output, uint64 bytes,
            StorageJobManager jobs, StorageJob job, bool verify_output = false) throws Error {
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            new Thread<void*>.try ("disk-image", () => {
                try { copy_sync (input, output, bytes, context, jobs, job, verify_output); }
                catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (copy.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
        }

        public static async void create_blank (File destination, uint64 bytes, Cancellable? token = null) throws Error {
            var parent = destination.get_parent ();
            string? path = destination.get_path ();
            if (path == null || parent == null || bytes < 512 || bytes > int64.MAX)
                throw new IOError.INVALID_ARGUMENT ("Choose a local file and a valid image capacity.");
            var temporary = parent.get_child (".majoris-" + Uuid.string_random ());
            var output = yield temporary.create_async (FileCreateFlags.PRIVATE, Priority.DEFAULT, token);
            bool published = false;
            try {
                var seekable = output as Seekable;
                if (seekable == null || !seekable.can_truncate ())
                    throw new IOError.NOT_SUPPORTED ("The destination does not support sizing image files.");
                seekable.truncate ((int64) bytes, token);
                yield output.close_async (Priority.DEFAULT, token);
                var info = yield temporary.query_info_async (FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, token);
                if ((uint64) info.get_size () != bytes)
                    throw new IOError.INVALID_DATA ("The new image has an unexpected size.");
                if (rename_without_replacement (CURRENT_DIRECTORY, temporary.get_path (), CURRENT_DIRECTORY,
                    path, NO_REPLACEMENT) != 0)
                    throw new IOError.FAILED ("Could not publish the blank image: " + Posix.strerror (Posix.errno));
                published = true;
            } finally {
                if (!published) {
                    try { yield temporary.delete_async (Priority.DEFAULT, null); }
                    catch (Error error) { warning ("Could not delete incomplete image: %s", error.message); }
                }
            }
        }

        public static async uint64 expand_xz (int input, OutputStream output, uint64 capacity,
            Cancellable token) throws Error {
            string? executable = Environment.find_program_in_path ("xz");
            if (executable == null) throw new IOError.NOT_SUPPORTED ("Install xz-utils to restore compressed images.");
            int copy = Posix.dup (input);
            if (copy < 0) throw new IOError.FAILED ("Could not duplicate the image descriptor.");
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            launcher.take_stdin_fd (copy);
            var decoder = launcher.spawnv ({ executable, "--format=xz", "--decompress", "--stdout",
                "--memlimit-decompress=256MiB" });
            var stream = decoder.get_stdout_pipe ();
            var buffer = new uint8[1024 * 1024];
            uint64 bytes = 0;
            bool complete = false;
            try {
                while (true) {
                    ssize_t got = yield stream.read_async (buffer, Priority.DEFAULT, token);
                    if (got == 0) break;
                    if ((uint64) got > capacity - bytes)
                        throw new IOError.NO_SPACE ("The decompressed image is larger than the target.");
                    size_t written;
                    yield output.write_all_async (buffer[0:(int) got], Priority.DEFAULT, token, out written);
                    bytes += written;
                }
                try { yield decoder.wait_check_async (token); }
                catch (Error error) {
                    if (error is IOError.CANCELLED) throw error;
                    throw new IOError.INVALID_DATA ("XZ rejected the image or the compressed stream was truncated.");
                }
                complete = true;
                return bytes;
            } finally {
                if (!complete) decoder.force_exit ();
            }
        }

        private static void copy_sync (int input, int output, uint64 bytes, MainContext context,
            StorageJobManager jobs, StorageJob job, bool verify_output) throws Error {
            var token = job.cancellable;
            var buffer = new uint8[1024 * 1024];
            uint64 copied = 0;
            Checksum? checksum = null;
            if (verify_output) checksum = new Checksum (ChecksumType.SHA256);
            int64 started = get_monotonic_time ();
            int64 last = started;
            while (copied < bytes) {
                token.set_error_if_cancelled ();
                ssize_t count = read_bytes (input, buffer, (size_t) uint64.min (buffer.length, bytes - copied));
                if (count < 0 && Posix.errno == Posix.EINTR) continue;
                if (count < 0) throw new IOError.FAILED ("Read failed at byte %s: %s".printf (
                    copied.to_string (), Posix.strerror (Posix.errno)));
                if (count == 0) throw new IOError.PARTIAL_INPUT ("The source ended before the expected image size.");
                if (checksum != null) checksum.update (buffer, (size_t) count);
                ssize_t written = 0;
                while (written < count) {
                    token.set_error_if_cancelled ();
                    ssize_t step = write_bytes (output, (uint8*) buffer + written, (size_t) (count - written));
                    if (step < 0 && Posix.errno == Posix.EINTR) continue;
                    if (step <= 0) throw new IOError.FAILED ("Image write failed: " + Posix.strerror (Posix.errno));
                    written += step;
                }
                copied += count;
                int64 now = get_monotonic_time ();
                if (now - last >= 200000 || copied == bytes) {
                    double fraction = (double) copied / bytes;
                    uint64 rate = (uint64) (copied * 1000000.0 / int64.max (1, now - started));
                    string phase = "%s of %s · %s/s · %s s remaining".printf (format_size (copied),
                        format_size (bytes), format_size (rate), ((bytes - copied) / uint64.max (1, rate)).to_string ());
                    var update = new IdleSource ();
                    update.set_callback (() => {
                        if (!token.is_cancelled ()) jobs.progress (job, phase, fraction, true);
                        return Source.REMOVE;
                    });
                    update.attach (context);
                    last = now;
                }
            }
            if (Posix.fsync (output) != 0)
                throw new IOError.FAILED ("Could not flush the image: " + Posix.strerror (Posix.errno));
            token.set_error_if_cancelled ();
            if (checksum == null) return;

            var verifying = new IdleSource ();
            verifying.set_callback (() => {
                if (!token.is_cancelled ()) jobs.progress (job, "Verifying the written data", 0, false);
                return Source.REMOVE;
            });
            verifying.attach (context);
            if (Posix.lseek (output, 0, Posix.SEEK_SET) < 0)
                throw new IOError.FAILED ("Could not seek to the start of the output for verification.");
            var readback = new Checksum (ChecksumType.SHA256);
            uint64 remaining = bytes;
            while (remaining > 0) {
                token.set_error_if_cancelled ();
                ssize_t got = read_bytes (output, buffer, (size_t) uint64.min (buffer.length, remaining));
                if (got < 0 && Posix.errno == Posix.EINTR) continue;
                if (got <= 0) throw new IOError.PARTIAL_INPUT ("Could not read the complete output for verification.");
                readback.update (buffer, (size_t) got);
                remaining -= got;
            }
            if (checksum.get_string () != readback.get_string ())
                throw new IOError.INVALID_DATA ("Readback verification did not match the source image.");
            token.set_error_if_cancelled ();
        }
    }

    [CCode (cname = "ioctl", cheader_filename = "sys/ioctl.h")]
    internal extern int ioctl_capacity (int fd, ulong request, out uint64 capacity);
    [CCode (cname = "BLKGETSIZE64", cheader_filename = "linux/fs.h")]
    internal extern const ulong BLOCK_DEVICE_CAPACITY;

    [CCode (cname = "renameat2", cheader_filename = "stdio.h")]
    internal extern int rename_without_replacement (int old_dir, string old_path, int new_dir, string new_path, uint flags);

    [CCode (cname = "RENAME_NOREPLACE", cheader_filename = "stdio.h")]
    internal extern const uint NO_REPLACEMENT;

    [CCode (cname = "AT_FDCWD", cheader_filename = "fcntl.h")]
    internal extern const int CURRENT_DIRECTORY;
}
