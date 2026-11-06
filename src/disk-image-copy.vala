namespace MajorisDisks {
    [CCode (cname = "read", cheader_filename = "unistd.h")]
    private extern ssize_t read_bytes (int fd, void* bytes, size_t count);
    [CCode (cname = "write", cheader_filename = "unistd.h")]
    private extern ssize_t write_bytes (int fd, void* bytes, size_t count);

    internal enum ImageWritePhase { VALIDATING, PREPARING, WRITING, FLUSHING, VERIFYING, WRITTEN_VERIFIED, RESCANNING, COMPLETED }

    internal class ImageWriteState : Object {
        public ImageWritePhase phase;
        public bool descriptor_closed;
        public bool rescan_requested;
        public bool rescan_completed;
        public bool model_refreshed;

        public async void rescan (DBusProxy proxy, Cancellable token) throws Error {
            phase = ImageWritePhase.RESCANNING;
            rescan_requested = true;
            yield proxy.call ("Rescan", new Variant ("(@a{sv})", new Variant ("a{sv}", null)),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
            rescan_completed = true;
        }

        public void describe_failure (StorageOperationResult result, Error error) {
            string summary;
            switch (phase) {
                case ImageWritePhase.WRITING: summary = "Writing stopped. The target may be partially overwritten."; break;
                case ImageWritePhase.FLUSHING: summary = "All image bytes were written, but durability could not be confirmed."; break;
                case ImageWritePhase.VERIFYING: summary = "All image bytes were written and flushed, but verification did not complete."; break;
                case ImageWritePhase.WRITTEN_VERIFIED: summary = "The image was written and verified, but closing the target failed."; break;
                case ImageWritePhase.RESCANNING:
                    summary = rescan_completed ?
                        "The image was written and verified and the rescan completed, but the device model could not be refreshed." :
                        rescan_requested ? "The image was written and verified, but the partition rescan failed." :
                        "The image was written and verified, but a device rescan could not be requested.";
                    break;
                default: summary = "Restoration stopped before writing to the target."; break;
            }
            result.fail (summary, error);
            if (phase >= ImageWritePhase.WRITING) {
                result.status = StorageOperationStatus.NEEDS_ATTENTION;
                result.partial = phase == ImageWritePhase.WRITING;
            }
        }
    }

    [CCode (cname = "MajorisXzProgress", cheader_filename = "xz-stream.h")]
    private delegate void XzProgress (uint64 compressed, uint64 expanded);

    [CCode (cname = "majoris_xz_decode", cheader_filename = "xz-stream.h")]
    private extern bool decode_xz_native (InputStream input, OutputStream? output, uint64 limit,
        Cancellable token, XzProgress? progress, out uint64 size, out string digest) throws Error;

    [CCode (cname = "majoris_image_identity", cheader_filename = "xz-stream.h")]
    internal extern string? image_identity (int fd);

    internal class XzImage : Object {
        public uint64 size;
        public string digest = "";
    }

    internal class DiskImageCopy {
        public static async void copy (int input, int output, uint64 bytes,
            StorageJobManager jobs, StorageJob job, bool verify_output = false, ImageWriteState? state = null) throws Error {
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            new Thread<void*>.try ("disk-image", () => {
                try { copy_sync (input, output, bytes, context, jobs, job, verify_output, state); }
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

        public static async XzImage decode_xz (int input, OutputStream? output, uint64 limit,
            Cancellable token, StorageJobManager? jobs = null, StorageJob? job = null) throws Error {
            var context = MainContext.ref_thread_default ();
            var decoded = new XzImage ();
            Error? failure = null;
            new Thread<void*>.try ("xz-decode", () => {
                try {
                    var stream = new UnixInputStream (input, false);
                    int64 started = get_monotonic_time ();
                    decode_xz_native (stream, output, limit, token, (compressed, expanded) => {
                        if (jobs == null || job == null) return;
                        uint64 rate = (uint64) (expanded * 1000000.0 /
                            int64.max (1, get_monotonic_time () - started));
                        string phase = "%s · %s compressed · %s %s · %s/s".printf (
                            output == null ? "Validating XZ" : "Restoring XZ", format_size (compressed),
                            format_size (expanded), output == null ? "decoded" : "written", format_size (rate));
                        double fraction = output == null ? 0 : (double) expanded / limit;
                        var update = new IdleSource ();
                        update.set_callback (() => {
                            if (!token.is_cancelled ()) jobs.progress (job, phase, fraction, output != null);
                            return Source.REMOVE;
                        });
                        update.attach (context);
                    }, out decoded.size, out decoded.digest);
                } catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (decode_xz.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
            return decoded;
        }

        public static async uint64 expand_xz (int input, OutputStream output, uint64 capacity,
            Cancellable token) throws Error {
            var decoded = yield decode_xz (input, output, capacity, token);
            return decoded.size;
        }

        public static async void verify_streamed_write (int output, XzImage decoded, XzImage expected,
            StorageJobManager jobs, StorageJob job, ImageWriteState state) throws Error {
            if (decoded.size != expected.size)
                throw new IOError.INVALID_DATA ("The decompressed byte count changed after preflight.");
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            new Thread<void*>.try ("image-readback", () => {
                try {
                    flush_output (output, state);
                    state.phase = ImageWritePhase.VERIFYING;
                    if (decoded.digest != expected.digest)
                        throw new IOError.INVALID_DATA ("The decompressed image changed after preflight.");
                    verify_readback (output, decoded.size, decoded.digest, context, jobs, job);
                    state.phase = ImageWritePhase.WRITTEN_VERIFIED;
                } catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (verify_streamed_write.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
        }

        private static void copy_sync (int input, int output, uint64 bytes, MainContext context,
            StorageJobManager jobs, StorageJob job, bool verify_output, ImageWriteState? state) throws Error {
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
                    if (state != null) state.phase = ImageWritePhase.WRITING;
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
            flush_output (output, state);
            token.set_error_if_cancelled ();
            if (checksum == null) return;
            if (state != null) state.phase = ImageWritePhase.VERIFYING;
            verify_readback (output, bytes, checksum.get_string (), context, jobs, job);
            if (state != null) state.phase = ImageWritePhase.WRITTEN_VERIFIED;
        }

        private static void flush_output (int output, ImageWriteState? state) throws Error {
            if (state != null) state.phase = ImageWritePhase.FLUSHING;
            if (Posix.fsync (output) != 0)
                throw new IOError.FAILED ("Could not flush the image: " + Posix.strerror (Posix.errno));
            if (state != null) state.phase = ImageWritePhase.VERIFYING;
        }

        private static void verify_readback (int output, uint64 bytes, string digest,
            MainContext context, StorageJobManager jobs, StorageJob job) throws Error {
            var token = job.cancellable;
            var buffer = new uint8[1024 * 1024];
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
            int64 last_update = get_monotonic_time ();
            while (remaining > 0) {
                token.set_error_if_cancelled ();
                ssize_t got = read_bytes (output, buffer, (size_t) uint64.min (buffer.length, remaining));
                if (got < 0 && Posix.errno == Posix.EINTR) continue;
                if (got <= 0) throw new IOError.PARTIAL_INPUT ("Could not read the complete output for verification.");
                readback.update (buffer, (size_t) got);
                remaining -= got;
                int64 now = get_monotonic_time ();
                if (now - last_update >= 200000 || remaining == 0) {
                    double fraction = (double) (bytes - remaining) / bytes;
                    var update = new IdleSource ();
                    update.set_callback (() => {
                        if (!token.is_cancelled ()) jobs.progress (job, "Verifying the written data", fraction, true);
                        return Source.REMOVE;
                    });
                    update.attach (context);
                    last_update = now;
                }
            }
            if (digest != readback.get_string ())
                throw new IOError.INVALID_DATA ("Readback verification did not match the source image.");
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
