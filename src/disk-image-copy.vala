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

    [CCode (cname = "majoris_xz_encode", cheader_filename = "xz-stream.h")]
    private extern bool encode_xz_native (InputStream input, OutputStream output, uint64 size,
        Cancellable token, XzProgress? progress, out string digest) throws Error;

    [CCode (cname = "majoris_image_identity", cheader_filename = "xz-stream.h")]
    internal extern string? image_identity (int fd);

    [CCode (cname = "majoris_image_require_raw", cheader_filename = "xz-stream.h")]
    internal extern bool require_raw_image (int fd, uint64 size) throws Error;

    [CCode (cname = "majoris_image_match_loop", cheader_filename = "xz-stream.h")]
    internal extern bool match_loop_backing (int block, string backing) throws Error;

    internal class XzImage : Object {
        public uint64 size;
        public string digest = "";
    }

    internal class ImageVerificationResult : Object {
        public string format = "";
        public string source_identity = "";
        public uint64 logical_size;
        public uint64 file_size;
        public string digest = "";
    }

    internal class ImageOperationJournal : Object {
        private string path;
        private static string directory () {
            return Path.build_filename (Environment.get_user_state_dir (), "majoris-disks", "imaging");
        }

        private static bool private_directory (string directory) {
            Posix.Stat info = {};
            return Posix.lstat (directory, out info) == 0 && Posix.S_ISDIR (info.st_mode) &&
                info.st_uid == Posix.getuid () && (info.st_mode & 0077) == 0;
        }

        private static string process_start (uint pid) {
            try {
                string status;
                FileUtils.get_contents ("/proc/%u/stat".printf (pid), out status);
                int end = status.last_index_of_char (')');
                if (end < 0 || end + 2 >= status.length) return "";
                string[] fields = status.substring (end + 2).split (" ");
                return fields.length > 19 ? fields[19] : "";
            } catch (FileError error) { return ""; }
        }

        internal ImageOperationJournal (string operation, string target, string evidence) throws Error {
            string root = directory ();
            if (DirUtils.create_with_parents (root, 0700) != 0 || !private_directory (root))
                throw new IOError.PERMISSION_DENIED ("Could not create a private imaging recovery directory.");
            uint pid = (uint) Posix.getpid ();
            var record = new KeyFile ();
            record.set_uint64 ("operation", "pid", pid);
            record.set_string ("operation", "start", process_start (pid));
            record.set_string ("operation", "name", operation);
            record.set_string ("operation", "target", target);
            record.set_string ("operation", "evidence", evidence);
            path = Path.build_filename (root, Uuid.string_random () + ".ini");
            FileUtils.set_contents_full (path, record.to_data (), -1,
                FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
        }

        internal void remove () {
            if (FileUtils.unlink (path) != 0)
                warning ("Could not remove imaging operation record %s", path);
        }

        internal static void recover (StorageJobManager jobs) {
            string root = directory ();
            if (!private_directory (root)) return;
            try {
                var files = Dir.open (root);
                string? name;
                while ((name = files.read_name ()) != null) {
                    if (!name.has_suffix (".ini") || !Uuid.string_is_valid (name.substring (0, name.length - 4)))
                        continue;
                    string path = Path.build_filename (root, name);
                    Posix.Stat info = {};
                    if (Posix.lstat (path, out info) != 0 || !Posix.S_ISREG (info.st_mode) ||
                        info.st_uid != Posix.getuid () || (info.st_mode & 0077) != 0 || info.st_size > 65536)
                        continue;
                    try {
                        var record = new KeyFile ();
                        record.load_from_file (path, KeyFileFlags.NONE);
                        uint64 pid = record.get_uint64 ("operation", "pid");
                        string start = record.get_string ("operation", "start");
                        if (pid > 0 && pid <= int.MAX && start != "" && start == process_start ((uint) pid))
                            continue;
                        var job = jobs.begin_named (record.get_string ("operation", "name"),
                            record.get_string ("operation", "target"), {});
                        var outcome = new StorageOperationResult ();
                        outcome.fail ("Interrupted imaging operation requires review");
                        outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                        outcome.actual_state = record.get_string ("operation", "evidence");
                        outcome.technical_error = "Recovery record " + path;
                        jobs.finish (job, outcome);
                    } catch (Error error) {
                        warning ("Could not read imaging recovery record %s: %s", path, error.message);
                    }
                }
            } catch (FileError error) { warning ("Could not read imaging recovery records: %s", error.message); }
        }
    }

    internal class DiskImageCopy {
        public static bool is_xz_name (string name) {
            string lower = name.down ();
            return lower.has_suffix (".img.xz") || lower.has_suffix (".raw.xz");
        }

        public static async ImageVerificationResult verify_file (File source, StorageJobManager jobs,
            StorageJob job, uint64 limit = uint64.MAX) throws Error {
            int input = VirtualDisk.open_image (source);
            int logical = -1;
            string? staging = null;
            try {
                Posix.Stat info = {};
                string? identity = image_identity (input);
                if (identity == null || Posix.fstat (input, out info) != 0 ||
                    !Posix.S_ISREG (info.st_mode) || info.st_size <= 0)
                    throw new IOError.INVALID_DATA ("Choose a nonempty regular disk image.");
                var result = new ImageVerificationResult ();
                result.source_identity = identity;
                result.file_size = (uint64) info.st_size;
                var token = job.cancellable;
                string name = (source.get_basename () ?? "").down ();
                if (is_xz_name (name)) {
                    var decoded = yield decode_xz (input, null, limit, token, jobs, job);
                    if (decoded.size == 0)
                        throw new IOError.INVALID_DATA ("The compressed stream contains no disk data.");
                    result.format = "RAW + XZ";
                    result.logical_size = decoded.size;
                    result.digest = decoded.digest;
                } else {
                    result.logical_size = result.file_size;
                    result.format = name.has_suffix (".iso") ? "ISO" : "RAW";
                    if (name.has_suffix (".qcow2") || name.has_suffix (".vhd") || name.has_suffix (".vhdx")) {
                        var image = yield VirtualDisk.inspect_fd (input, token);
                        if (image.format != (name.has_suffix (".qcow2") ? "qcow2" :
                            name.has_suffix (".vhdx") ? "vhdx" : "vpc"))
                            throw new IOError.INVALID_DATA ("The image metadata does not match its format extension.");
                        if (image.capacity > limit)
                            throw new IOError.NO_SPACE ("The image's logical capacity exceeds the selected limit.");
                        staging = DirUtils.make_tmp ("majoris-verify-XXXXXX");
                        logical = yield VirtualDisk.materialize_raw (input, image, staging, token);
                        result.format = image.format == "vpc" ? "VHD" : image.format.up ();
                        result.logical_size = image.capacity;
                    } else {
                        require_raw_image (input, result.logical_size);
                    }
                    if (result.logical_size > limit)
                        throw new IOError.NO_SPACE ("The image's logical capacity exceeds the selected limit.");
                    result.digest = yield hash_image (logical < 0 ? input : logical, result.logical_size, jobs, job);
                }
                int current = VirtualDisk.open_image (source);
                bool matches = image_identity (current) == identity && image_identity (input) == identity;
                Posix.close (current);
                if (!matches)
                    throw new IOError.INVALID_DATA ("The image changed during verification.");
                return result;
            } finally {
                Posix.close (input);
                if (logical >= 0) Posix.close (logical);
                if (staging != null) {
                    FileUtils.unlink (Path.build_filename (staging, "disk"));
                    if (DirUtils.remove (staging) != 0)
                        warning ("Could not remove the verification directory %s", staging);
                }
            }
        }

        internal static async string hash_image (int fd, uint64 size, StorageJobManager jobs,
            StorageJob job) throws Error {
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            string digest = "";
            new Thread<void*>.try ("image-sha256", () => {
                try { digest = hash_data (fd, size, context, jobs, job, "Computing logical SHA-256"); }
                catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (hash_image.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
            return digest;
        }

        public static async string write_xz (int input, int output, uint64 size,
            StorageJobManager jobs, StorageJob job) throws Error {
            var context = MainContext.ref_thread_default ();
            var token = job.cancellable;
            string digest = "";
            Error? failure = null;
            new Thread<void*>.try ("xz-encode", () => {
                try {
                    var source = new UnixInputStream (input, false);
                    var destination = new UnixOutputStream (output, false);
                    int64 started = get_monotonic_time ();
                    encode_xz_native (source, destination, size, token, (compressed, expanded) => {
                        uint64 rate = (uint64) (expanded * 1000000.0 /
                            int64.max (1, get_monotonic_time () - started));
                        string phase = "Compressing XZ · %s read · %s written · %s/s".printf (
                            format_size (expanded), format_size (compressed), format_size (rate));
                        var update = new IdleSource ();
                        update.set_callback (() => {
                            if (!token.is_cancelled ())
                                jobs.progress (job, phase, (double) expanded / size, true);
                            return Source.REMOVE;
                        });
                        update.attach (context);
                    }, out digest);
                    flush_output (output, null);
                } catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (write_xz.callback);
                resume.attach (context);
                return null;
            });
            yield;
            if (failure != null) throw failure;
            return digest;
        }

        public static async void transform_xz (File source, File destination, bool compress,
            StorageJobManager jobs, StorageJob job) throws Error {
            string? path = destination.get_path ();
            string? parent = destination.get_parent ()?.get_path ();
            string name = (destination.get_basename () ?? "").down ();
            if (path == null || parent == null || (compress ? !is_xz_name (name) :
                !(name.has_suffix (".img") || name.has_suffix (".raw"))))
                throw new IOError.INVALID_ARGUMENT ("Choose a local destination with the selected image extension.");
            var token = job.cancellable;
            if (destination.query_exists (token))
                throw new IOError.EXISTS ("An image already exists at the selected destination.");
            int input = VirtualDisk.open_image (source);
            int output = -1;
            string? work = null;
            ImageOperationJournal? recovery = null;
            try {
                Posix.Stat info = {};
                string? original = image_identity (input);
                if (original == null || Posix.fstat (input, out info) != 0 ||
                    !Posix.S_ISREG (info.st_mode) || info.st_size <= 0)
                    throw new IOError.INVALID_DATA ("Choose a nonempty regular disk image.");
                uint64 size = (uint64) info.st_size;
                XzImage? expected = null;
                if (compress) {
                    require_raw_image (input, size);
                } else {
                    expected = yield decode_xz (input, null, int64.MAX, token, jobs, job);
                    size = expected.size;
                    if (size == 0 || Posix.lseek (input, 0, Posix.SEEK_SET) < 0)
                        throw new IOError.INVALID_DATA ("The XZ stream has no usable disk data.");
                }
                var free = yield File.new_for_path (parent).query_filesystem_info_async (
                    FileAttribute.FILESYSTEM_FREE, Priority.DEFAULT, token);
                if (free.has_attribute (FileAttribute.FILESYSTEM_FREE) &&
                    free.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE) < size)
                    throw new IOError.NO_SPACE ("The destination has insufficient free space for the image.");
                string directory = Path.build_filename (parent, ".majoris-" + Uuid.string_random ());
                if (DirUtils.create (directory, 0700) != 0)
                    throw new IOError.FAILED ("Could not create a private image output directory.");
                work = directory;
                recovery = new ImageOperationJournal (compress ? "Compress RAW image" : "Extract XZ image", path,
                    "Review the destination and the private work directory " + work + ".");
                string temporary = Path.build_filename (work, "disk");
                output = Posix.open (temporary, Posix.O_RDWR | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
                if (output < 0) throw new IOError.FAILED ("Could not create the temporary disk image.");
                if (compress) {
                    string digest = yield write_xz (input, output, size, jobs, job);
                    if (Posix.lseek (output, 0, Posix.SEEK_SET) < 0)
                        throw new IOError.FAILED ("Could not rewind the compressed image.");
                    var verified = yield decode_xz (output, null, size, token, jobs, job);
                    if (verified.size != size || verified.digest != digest)
                        throw new IOError.INVALID_DATA ("The compressed image differs from its source.");
                } else {
                    var stream = new UnixOutputStream (output, false);
                    var written = yield decode_xz (input, stream, size, token, jobs, job);
                    yield verify_streamed_write (output, written, expected, jobs, job, new ImageWriteState ());
                }
                int current = VirtualDisk.open_image (source);
                bool source_matches = original == image_identity (current) && original == image_identity (input);
                Posix.close (current);
                if (!source_matches)
                    throw new IOError.INVALID_DATA ("The source changed while converting the image.");
                int closed = Posix.close (output);
                output = -1;
                if (closed != 0) throw new IOError.FAILED ("Could not close the verified image.");
                token.set_error_if_cancelled ();
                if (rename_without_replacement (CURRENT_DIRECTORY, temporary, CURRENT_DIRECTORY, path,
                    NO_REPLACEMENT) != 0)
                    throw new IOError.FAILED ("Could not publish the image: " + Posix.strerror (Posix.errno));
            } finally {
                Posix.close (input);
                if (output >= 0) Posix.close (output);
                if (work != null) {
                    FileUtils.unlink (Path.build_filename (work, "disk"));
                    if (DirUtils.remove (work) == 0) recovery?.remove ();
                    else warning ("Could not remove the private image work directory %s", work);
                }
            }
        }

        public static async void copy (int input, int output, uint64 bytes,
            StorageJobManager jobs, StorageJob job, bool verify_output = false, ImageWriteState? state = null,
            string? expected_digest = null) throws Error {
            var context = MainContext.ref_thread_default ();
            Error? failure = null;
            new Thread<void*>.try ("disk-image", () => {
                try { copy_sync (input, output, bytes, context, jobs, job, verify_output, state, expected_digest); }
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
                var descriptor = output as FileDescriptorBased;
                if (descriptor == null || Posix.fsync (descriptor.get_fd ()) != 0)
                    throw new IOError.FAILED ("Could not flush the blank image.");
                yield output.close_async (Priority.DEFAULT, token);
                var info = yield temporary.query_info_async (FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, token);
                if ((uint64) info.get_size () != bytes)
                    throw new IOError.INVALID_DATA ("The new image has an unexpected size.");
                if (token != null) token.set_error_if_cancelled ();
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
            Cancellable token, StorageJobManager? jobs = null, StorageJob? job = null,
            ImageWriteState? state = null) throws Error {
            var context = MainContext.ref_thread_default ();
            var decoded = new XzImage ();
            Error? failure = null;
            new Thread<void*>.try ("xz-decode", () => {
                try {
                    var stream = new UnixInputStream (input, false);
                    int64 started = get_monotonic_time ();
                    decode_xz_native (stream, output, limit, token, (compressed, expanded) => {
                        if (state != null && output != null && expanded > 0)
                            state.phase = ImageWritePhase.WRITING;
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
            StorageJobManager jobs, StorageJob job, bool verify_output, ImageWriteState? state,
            string? expected_digest) throws Error {
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
            if (expected_digest != null && checksum.get_string () != expected_digest)
                throw new IOError.INVALID_DATA ("The logical image data changed after preflight.");
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
            if (digest != hash_data (output, bytes, context, jobs, job, "Verifying the written data"))
                throw new IOError.INVALID_DATA ("Readback verification did not match the source image.");
        }

        private static string hash_data (int input, uint64 bytes, MainContext context,
            StorageJobManager jobs, StorageJob job, string phase) throws Error {
            var token = job.cancellable;
            var buffer = new uint8[1024 * 1024];
            var verifying = new IdleSource ();
            verifying.set_callback (() => {
                if (!token.is_cancelled ()) jobs.progress (job, phase, 0, false);
                return Source.REMOVE;
            });
            verifying.attach (context);
            if (Posix.lseek (input, 0, Posix.SEEK_SET) < 0)
                throw new IOError.FAILED ("Could not seek to the start of the image for verification.");
            var readback = new Checksum (ChecksumType.SHA256);
            uint64 remaining = bytes;
            int64 last_update = get_monotonic_time ();
            while (remaining > 0) {
                token.set_error_if_cancelled ();
                ssize_t got = read_bytes (input, buffer, (size_t) uint64.min (buffer.length, remaining));
                if (got < 0 && Posix.errno == Posix.EINTR) continue;
                if (got <= 0) throw new IOError.PARTIAL_INPUT ("Could not read the complete image for verification.");
                readback.update (buffer, (size_t) got);
                remaining -= got;
                int64 now = get_monotonic_time ();
                if (now - last_update >= 200000 || remaining == 0) {
                    double fraction = (double) (bytes - remaining) / bytes;
                    var update = new IdleSource ();
                    update.set_callback (() => {
                        if (!token.is_cancelled ()) jobs.progress (job, phase, fraction, true);
                        return Source.REMOVE;
                    });
                    update.attach (context);
                    last_update = now;
                }
            }
            return readback.get_string ();
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
