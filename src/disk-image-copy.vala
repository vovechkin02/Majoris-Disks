namespace MajorisDisks {
    [CCode (cname = "read", cheader_filename = "unistd.h")]
    private extern ssize_t read_bytes (int fd, void* bytes, size_t count);
    [CCode (cname = "write", cheader_filename = "unistd.h")]
    private extern ssize_t write_bytes (int fd, void* bytes, size_t count);

    internal enum ImageWritePhase {
        VALIDATING, PREPARING, WRITING, FLUSHING, VERIFYING, WRITTEN_VERIFIED, RECONCILING, RESCANNING, COMPLETED
    }

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
                case ImageWritePhase.WRITING:
                    summary = "Restoration stopped after writing began. The target may contain incomplete data."; break;
                case ImageWritePhase.FLUSHING: summary = "All image bytes were written, but durability could not be confirmed."; break;
                case ImageWritePhase.VERIFYING: summary = "All image bytes were written and flushed, but verification did not complete."; break;
                case ImageWritePhase.WRITTEN_VERIFIED: summary = "The image was written and verified, but closing the target failed."; break;
                case ImageWritePhase.RECONCILING:
                    summary = "The image was written and verified, but the current source or target could not be confirmed."; break;
                case ImageWritePhase.RESCANNING:
                    bool reply_uncertain = error is DBusError.NO_REPLY || error is DBusError.DISCONNECTED ||
                        error is IOError.TIMED_OUT || error is IOError.CLOSED || error is IOError.CANCELLED;
                    summary = rescan_completed ?
                        "The image was written and verified and the rescan completed, but the device model could not be refreshed." :
                        rescan_requested && reply_uncertain ?
                            "The image was written and verified, but the rescan outcome could not be confirmed." :
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

        internal void retain_publication (Error error) {
            try {
                var record = new KeyFile ();
                record.load_from_file (path, KeyFileFlags.NONE);
                record.set_string ("operation", "evidence", error.message);
                FileUtils.set_contents_full (path, record.to_data (), -1,
                    FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
            } catch (Error journal_error) {
                warning ("Could not update image publication evidence: %s", journal_error.message);
            }
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

    internal errordomain ImagePublicationError {
        DURABILITY_UNVERIFIED,
        IDENTITY_UNVERIFIED
    }

    internal delegate int ImageDirectorySync (int fd);

    internal class ImagePublication : Object {
        private int directory = -1;
        private string parent;
        private string name;

        public ImagePublication (string path) throws Error {
            parent = Path.get_dirname (path);
            name = Path.get_basename (path);
            directory = Posix.open (parent, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW);
            if (directory < 0)
                throw new IOError.FAILED ("Could not open the destination directory: " + Posix.strerror (Posix.errno));
        }

        ~ImagePublication () {
            if (directory >= 0) Posix.close (directory);
        }

        private static bool matches (Posix.Stat expected, Posix.Stat actual) {
            return expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino &&
                expected.st_size == actual.st_size && Posix.S_ISREG (actual.st_mode);
        }

        public static Posix.Stat flush (int fd) throws Error {
            Posix.Stat verified = {};
            if (Posix.fsync (fd) != 0 || Posix.fstat (fd, out verified) != 0 || !Posix.S_ISREG (verified.st_mode))
                throw new IOError.FAILED ("Could not flush and identify the verified image.");
            return verified;
        }

        private bool parent_matches () {
            Posix.Stat pinned = {}, current = {};
            return Posix.fstat (directory, out pinned) == 0 && Posix.lstat (parent, out current) == 0 &&
                pinned.st_dev == current.st_dev && pinned.st_ino == current.st_ino && Posix.S_ISDIR (current.st_mode);
        }

        public void publish (string temporary, Posix.Stat verified, ImageDirectorySync sync_directory = Posix.fsync)
            throws Error {
            int work = Posix.open (Path.get_dirname (temporary),
                Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW);
            if (work < 0) throw new IOError.FAILED ("Could not open the verified image's private directory.");
            try {
                string leaf = Path.get_basename (temporary);
                Posix.Stat current = {};
                if (!parent_matches () || Posix.lstat ("/proc/self/fd/%d/%s".printf (work, leaf), out current) != 0 ||
                    !matches (verified, current))
                    throw new IOError.INVALID_DATA ("The destination directory or verified output changed before publication.");
                if (rename_without_replacement (work, leaf, directory, name, NO_REPLACEMENT) != 0)
                    throw new IOError.FAILED ("Could not publish the image: " + Posix.strerror (Posix.errno));
                int destination_sync = sync_directory (directory);
                int work_sync = sync_directory (work);
                if (!parent_matches () ||
                    Posix.lstat ("/proc/self/fd/%d/%s".printf (directory, name), out current) != 0 ||
                    !matches (verified, current))
                    throw new ImagePublicationError.IDENTITY_UNVERIFIED (
                        "The image was published, but its final identity could not be verified. Review the destination.");
                if (destination_sync != 0 || work_sync != 0)
                    throw new ImagePublicationError.DURABILITY_UNVERIFIED (
                        "The image was published, but its crash durability could not be verified.");
            } finally { Posix.close (work); }
        }

        public static bool was_published (Error error) {
            return error is ImagePublicationError.DURABILITY_UNVERIFIED ||
                error is ImagePublicationError.IDENTITY_UNVERIFIED;
        }

        public static void describe_failure (StorageOperationResult result, string before_publication, Error error) {
            bool published = was_published (error);
            result.fail (published ? "Image publication requires attention" : before_publication, error);
            if (published) {
                result.status = StorageOperationStatus.NEEDS_ATTENTION;
                result.actual_state = error.message;
            }
        }
    }

    internal struct ImagePartitionGeometry {
        public uint number;
        public uint64 offset;
        public uint64 size;
        public bool container;
    }

    internal class ImagePartitionLayout : Object {
        public ImagePartitionGeometry[] partitions = {};
        public bool has_table;
        public string scheme = "";

        public bool matches_discovery (StorageBlock disk, string[] kernel) {
            var model = disk.table?.partitions ?? new StorageBlock[0];
            if (kernel.length != partitions.length || model.length != partitions.length ||
                (disk.table != null) != has_table || (disk.table?.scheme ?? "") != scheme) return false;
            foreach (var expected in partitions) {
                bool matched = false;
                foreach (var part in model) {
                    var partition = part.partition;
                    if (part.available && partition != null && partition.number == expected.number &&
                        partition.table_path == disk.path && partition.offset == expected.offset &&
                        partition.container == expected.container && partition.table_size == expected.size &&
                        (expected.container || part.size == expected.size) &&
                        KernelStorageSafety.device_number (part.number) in kernel) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) return false;
            }
            return true;
        }

        public static async ImagePartitionLayout inspect_async (int fd, uint64 size, Cancellable token) throws Error {
            var context = MainContext.ref_thread_default ();
            ImagePartitionLayout? layout = null;
            Error? failure = null;
            new Thread<void*>.try ("image-partitions", () => {
                try { layout = inspect (fd, size); }
                catch (Error error) { failure = error; }
                var resume = new IdleSource ();
                resume.set_callback (inspect_async.callback);
                resume.attach (context);
                return null;
            });
            yield;
            token.set_error_if_cancelled ();
            if (failure != null) throw failure;
            return layout;
        }

        public static ImagePartitionLayout inspect (int fd, uint64 size) throws Error {
            if (size < 512 || size > int64.MAX)
                throw new IOError.INVALID_DATA ("The image capacity cannot be probed.");
            var probe = new BlkidProbe ();
            if (probe.set_device (fd, 0, (int64) size) != 0 || probe.enable_superblocks (0) != 0 ||
                probe.enable_partitions (1) != 0)
                throw new IOError.FAILED ("Could not prepare the image partition probe.");
            var layout = new ImagePartitionLayout ();
            int status = probe.safe_probe ();
            if (status == 1) return layout;
            if (status != 0) throw new IOError.INVALID_DATA ("The image partition table could not be identified.");
            layout.has_table = true;
            unowned string table_type;
            if (probe.lookup_value ("PTTYPE", out table_type) != 0)
                throw new IOError.INVALID_DATA ("The image partition table type could not be identified.");
            layout.scheme = table_type;
            unowned var list = probe.get_partitions ();
            if (list == null || list.count () < 0 || list.count () > 4096)
                throw new IOError.INVALID_DATA ("The image partition list could not be read.");
            for (int i = 0; i < list.count (); i++) {
                unowned var part = list.get_partition (i);
                if (part == null || part.number () <= 0 || part.start () <= 0 || part.size () <= 0 ||
                    (uint64) part.start () >= size / 512 ||
                    (uint64) part.size () > size / 512 - (uint64) part.start ())
                    throw new IOError.INVALID_DATA ("The image contains invalid partition geometry.");
                layout.partitions += ImagePartitionGeometry () {
                    number = (uint) part.number (), offset = (uint64) part.start () * 512,
                    size = (uint64) part.size () * 512, container = part.is_extended () != 0
                };
            }
            return layout;
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
            bool published_uncertain = false;
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
                var publication = new ImagePublication (path);
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
                var verified_output = ImagePublication.flush (output);
                int closed = Posix.close (output);
                output = -1;
                if (closed != 0) throw new IOError.FAILED ("Could not close the verified image.");
                token.set_error_if_cancelled ();
                publication.publish (temporary, verified_output);
            } catch (Error error) {
                published_uncertain = ImagePublication.was_published (error);
                if (published_uncertain) recovery?.retain_publication (error);
                throw error;
            } finally {
                Posix.close (input);
                if (output >= 0) Posix.close (output);
                if (work != null) {
                    if (!published_uncertain) FileUtils.unlink (Path.build_filename (work, "disk"));
                    if (DirUtils.remove (work) == 0) {
                        if (!published_uncertain) recovery?.remove ();
                    }
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
            var publication = new ImagePublication (path);
            var temporary = parent.get_child (".majoris-" + Uuid.string_random ());
            var output = yield temporary.create_async (FileCreateFlags.PRIVATE, Priority.DEFAULT, token);
            bool published = false;
            bool uncertain = false;
            ImageOperationJournal? recovery = null;
            try {
                recovery = new ImageOperationJournal ("Create blank disk image", path,
                    "Review the final path and private output " + temporary.get_parse_name () + ".");
                var seekable = output as Seekable;
                if (seekable == null || !seekable.can_truncate ())
                    throw new IOError.NOT_SUPPORTED ("The destination does not support sizing image files.");
                seekable.truncate ((int64) bytes, token);
                var descriptor = output as FileDescriptorBased;
                if (descriptor == null) throw new IOError.FAILED ("Could not identify the blank image.");
                var verified = ImagePublication.flush (descriptor.get_fd ());
                if ((uint64) verified.st_size != bytes)
                    throw new IOError.INVALID_DATA ("The new image has an unexpected size.");
                yield output.close_async (Priority.DEFAULT, token);
                if (token != null) token.set_error_if_cancelled ();
                publication.publish (temporary.get_path (), verified);
                published = true;
            } catch (Error error) {
                uncertain = ImagePublication.was_published (error);
                published = uncertain;
                if (uncertain) recovery?.retain_publication (error);
                throw error;
            } finally {
                bool cleaned = published;
                if (!published) {
                    if (!output.is_closed ()) {
                        try { yield output.close_async (Priority.DEFAULT, null); }
                        catch (Error error) { warning ("Could not close incomplete image: %s", error.message); }
                    }
                    try {
                        yield temporary.delete_async (Priority.DEFAULT, null);
                        cleaned = true;
                    }
                    catch (Error error) { warning ("Could not delete incomplete image: %s", error.message); }
                }
                if (cleaned && !uncertain) recovery?.remove ();
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

}
