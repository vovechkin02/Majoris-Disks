namespace MajorisDisks {
    internal class VirtualDiskInfo : Object {
        public string format;
        public uint64 capacity;
        public uint64 file_size;
        public uint64 allocated_size;
        public string identity = "";
        public bool has_snapshots;
    }

    internal delegate void ConversionProgress (double fraction);
    internal delegate void ImageSourceCheck (int fd) throws Error;

    internal class VirtualDisk {
        public static bool available () {
            return FileUtils.test ("/usr/bin/qemu-img", FileTest.IS_EXECUTABLE) &&
                FileUtils.test ("/usr/bin/bwrap", FileTest.IS_EXECUTABLE);
        }

        private static bool supported (string format) {
            return format == "raw" || format == "vpc" || format == "vhdx" || format == "qcow2";
        }

        private static async string run (int input, string? output_directory, string[] arguments,
            Cancellable token, ConversionProgress? progress = null) throws Error {
            if (!available ()) throw new IOError.NOT_SUPPORTED ("Install qemu-utils and bubblewrap for virtual images.");
            string[] argv = { "/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
                "--clearenv", "--setenv", "LC_ALL", "C", "--ro-bind", "/usr", "/usr",
                "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
                "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", "/" };
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE |
                (progress == null ? SubprocessFlags.STDERR_PIPE : SubprocessFlags.STDERR_MERGE));
            if (input >= 0) {
                int descriptor = Posix.dup (input);
                if (descriptor < 0) throw new IOError.FAILED ("Could not duplicate the selected image descriptor.");
                launcher.take_fd (descriptor, 3);
                argv += "--ro-bind-fd";
                argv += "3";
                argv += "/source";
            }
            if (output_directory != null) {
                argv += "--bind";
                argv += output_directory;
                argv += "/output";
            }
            argv += "--";
            argv += "/usr/bin/qemu-img";
            foreach (var argument in arguments) argv += argument;
            var process = launcher.spawnv (argv);
            string? output, diagnostic;
            try {
                if (progress == null)
                    yield process.communicate_utf8_async (null, token, out output, out diagnostic);
                else {
                    output = null;
                    diagnostic = null;
                    var stream = new DataInputStream (process.get_stdout_pipe ());
                    stream.set_newline_type (DataStreamNewlineType.ANY);
                    double last = -1;
                    string? line;
                    while ((line = yield stream.read_line_async (Priority.DEFAULT, token)) != null) {
                        double fraction;
                        if (parse_progress (line, out fraction)) {
                            if (fraction > last) {
                                last = fraction;
                                progress (fraction);
                            }
                        } else if (line.strip () != "") diagnostic = line;
                    }
                    yield process.wait_async (token);
                }
            } catch (Error error) {
                process.force_exit ();
                yield process.wait_async (null);
                throw error;
            }
            if (!process.get_successful ())
                throw new IOError.FAILED ((diagnostic ?? "The virtual image backend failed.").strip ());
            return output ?? "";
        }

        internal static bool parse_progress (string line, out double fraction) {
            fraction = 0;
            string text = line.strip ();
            if (!text.has_prefix ("(") || !text.has_suffix ("/100%)")) return false;
            string number = text.substring (1, text.length - 7);
            double percent;
            if (!double.try_parse (number, out percent) || !percent.is_finite () || percent < 0 || percent > 100)
                return false;
            fraction = percent / 100;
            return true;
        }

        internal static async VirtualDiskInfo inspect_fd (int input, Cancellable token) throws Error {
            Posix.Stat file = {};
            if (Posix.fstat (input, out file) != 0 || !Posix.S_ISREG (file.st_mode))
                throw new IOError.INVALID_DATA ("Choose a regular local image file.");
            string? identity = image_identity (input);
            if (identity == null) throw new IOError.INVALID_DATA ("Could not identify the image.");
            var parser = new Json.Parser ();
            parser.load_from_data (yield run (input, null, { "info", "--output=json", "/source" }, token));
            var root = parser.get_root ()?.get_object ();
            if (root == null || !root.has_member ("format") || !root.has_member ("virtual-size"))
                throw new IOError.INVALID_DATA ("QEMU did not report an image format and virtual capacity.");
            var format_specific = root.has_member ("format-specific") ? root.get_object_member ("format-specific") : null;
            var details = format_specific != null && format_specific.has_member ("data") ?
                format_specific.get_object_member ("data") : null;
            if (root.has_member ("backing-filename") || root.has_member ("full-backing-filename") ||
                (details != null && (details.has_member ("data-file") || details.has_member ("backing-file"))))
                throw new IOError.NOT_SUPPORTED ("Images with external backing or data files are unsupported.");
            if ((root.has_member ("encrypted") && root.get_boolean_member ("encrypted")) ||
                details?.has_member ("encrypt") == true)
                throw new IOError.NOT_SUPPORTED ("Encrypted virtual disk containers are unsupported.");
            string format = root.get_string_member ("format");
            int64 capacity = root.get_int_member ("virtual-size");
            if (!supported (format) || capacity <= 0)
                throw new IOError.NOT_SUPPORTED ("The image format or capacity is unsupported.");
            var result = new VirtualDiskInfo ();
            result.format = format;
            result.capacity = (uint64) capacity;
            result.file_size = (uint64) file.st_size;
            result.allocated_size = (uint64) file.st_blocks * 512;
            result.identity = identity;
            result.has_snapshots = root.has_member ("snapshots") &&
                root.get_array_member ("snapshots").get_length () > 0;
            if (format == "qcow2")
                yield run (input, null, { "check", "-f", format, "/source" }, token);
            if (identity != image_identity (input))
                throw new IOError.INVALID_DATA ("The image changed during inspection.");
            return result;
        }

        private static async void check_conversion_space (int fd, string source_format, string target_format,
            File destination, Cancellable token) throws Error {
            // QEMU's measurement support depends on the output driver.
            if (target_format != "raw" && target_format != "qcow2") return;
            var parser = new Json.Parser ();
            parser.load_from_data (yield run (fd, null, { "measure", "--output=json", "-f", source_format,
                "-O", target_format, "/source" }, token));
            var result = parser.get_root ()?.get_object ();
            if (result == null || !result.has_member ("required")) return;
            int64 required = result.get_int_member ("required");
            if (required <= 0) return;
            var parent = destination.get_parent ();
            if (parent == null) return;
            var info = yield parent.query_filesystem_info_async (FileAttribute.FILESYSTEM_FREE, Priority.DEFAULT, token);
            if (info.has_attribute (FileAttribute.FILESYSTEM_FREE) &&
                info.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE) < (uint64) required)
                throw new IOError.NO_SPACE ("QEMU estimates that the converted image needs more free space than is available.");
        }

        internal static int open_image (File file) throws Error {
            string? path = file.get_path ();
            if (path == null) throw new IOError.INVALID_ARGUMENT ("Choose a local disk image.");
            int fd = Posix.open (path, Posix.O_RDONLY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW | Posix.O_NONBLOCK);
            if (fd < 0) throw new IOError.FAILED ("Could not open the selected image.");
            return fd;
        }

        public static async VirtualDiskInfo inspect (File file, Cancellable token) throws Error {
            int fd = open_image (file);
            try { return yield inspect_fd (fd, token); }
            finally { Posix.close (fd); }
        }

        internal static async int materialize_raw (int source, VirtualDiskInfo info, string directory,
            Cancellable token, ConversionProgress? progress = null) throws Error {
            if (info.has_snapshots || info.format == "raw")
                throw new IOError.NOT_SUPPORTED ("Choose a self-contained virtual disk without internal snapshots.");
            var output = File.new_for_path (Path.build_filename (directory, "disk"));
            yield check_conversion_space (source, info.format, "raw", output, token);
            yield run (source, directory, { "convert", "-p", "-f", info.format, "-O", "raw",
                "/source", "/output/disk" }, token, progress);
            yield run (source, directory, { "compare", "-f", info.format, "-F", "raw",
                "/source", "/output/disk" }, token);
            int fd = open_image (output);
            Posix.Stat stat = {};
            if (image_identity (source) != info.identity || Posix.fstat (fd, out stat) != 0 ||
                !Posix.S_ISREG (stat.st_mode) || (uint64) stat.st_size != info.capacity) {
                Posix.close (fd);
                throw new IOError.INVALID_DATA ("The source identity or staged logical image size changed.");
            }
            return fd;
        }

        public static async void write_image (File? source, File destination, string format, uint64 capacity,
            Cancellable token, ConversionProgress? progress = null, VirtualDiskInfo? grow = null,
            ImageSourceCheck? check_source = null, bool compress = false) throws Error {
            string? path = destination.get_path ();
            string? parent = destination.get_parent ()?.get_path ();
            if (path == null || parent == null || !supported (format))
                throw new IOError.INVALID_ARGUMENT ("Choose a local destination and a supported image format.");
            if (compress && (source == null || format != "qcow2" || grow != null))
                throw new IOError.INVALID_ARGUMENT ("Compression requires converting an existing image to QCOW2.");
            if (destination.query_exists (token))
                throw new IOError.EXISTS ("An image already exists at the selected destination.");
            var publication = new ImagePublication (path);
            string directory = Path.build_filename (parent, ".majoris-" + Uuid.string_random ());
            if (DirUtils.create (directory, 0700) != 0)
                throw new IOError.FAILED ("Could not create a private conversion directory.");
            string temporary = Path.build_filename (directory, "disk");
            int fd = -1;
            string? original = null;
            ImageOperationJournal? recovery = null;
            bool published_uncertain = false;
            try {
                recovery = new ImageOperationJournal (grow != null ? "Grow disk image copy" : "Write disk image", path,
                    "Review the destination and the private work directory " + directory + ".");
                if (grow != null && (source == null || format != grow.format || capacity <= grow.capacity))
                    throw new IOError.INVALID_ARGUMENT ("Choose a larger capacity in the same image format.");
                if (source == null || grow != null) {
                    if (capacity == 0 || capacity > int64.MAX)
                        throw new IOError.INVALID_ARGUMENT ("Choose a valid virtual capacity.");
                    string[] create = { "create", "-f", format };
                    if (format == "vpc") { create += "-o"; create += "force_size=on"; }
                    create += "/output/disk";
                    create += capacity.to_string ();
                    yield run (-1, directory, create, token);
                }
                if (source != null) {
                    fd = open_image (source);
                    original = image_identity (fd);
                    if (original == null) throw new IOError.INVALID_DATA ("Could not identify the selected source image.");
                    var information = yield inspect_fd (fd, token);
                    if (grow == null) capacity = information.capacity;
                    else {
                        if (original != grow.identity || information.format != grow.format ||
                            information.capacity != grow.capacity || information.has_snapshots)
                            throw new IOError.INVALID_DATA ("The source changed or contains internal snapshots.");
                        if (check_source != null) check_source (fd);
                    }
                    // The VHD drivers do not implement measurement. For growth, use the
                    // raw size as a conservative estimate for the copied payload.
                    string measure_format = grow != null && (format == "vpc" || format == "vhdx") ?
                        "raw" : format;
                    yield check_conversion_space (fd, information.format, measure_format, destination, token);
                    if (original != image_identity (fd))
                        throw new IOError.INVALID_DATA ("The image changed before conversion.");
                    string[] convert = { "convert", "-p", "-f", information.format, "-O", format };
                    if (grow != null) convert += "-n";
                    else if (format == "vpc") { convert += "-o"; convert += "force_size=on"; }
                    if (compress) convert += "-c";
                    if (format == "raw") { convert += "-S"; convert += "4k"; }
                    convert += "/source";
                    convert += "/output/disk";
                    ConversionProgress? copy_progress = null;
                    if (progress != null) {
                        copy_progress = (fraction) => progress (fraction * 0.8);
                    }
                    yield run (fd, directory, convert, token, copy_progress);
                    // Non-strict comparison accepts extra sectors only if they read back as zero.
                    ConversionProgress? verify_progress = null;
                    if (progress != null) verify_progress = (fraction) => progress (0.8 + fraction * 0.2);
                    yield run (fd, directory, { "compare", "-p", "-f", information.format, "-F", format,
                        "/source", "/output/disk" }, token, verify_progress);
                }
                int output = open_image (File.new_for_path (temporary));
                Posix.Stat verified_output = {};
                try {
                    var verified = yield inspect_fd (output, token);
                    if (verified.format != format || verified.capacity != capacity)
                        throw new IOError.INVALID_DATA ("The output format or virtual capacity did not match the request.");
                    if (Posix.fchmod (output, 0600) != 0)
                        throw new IOError.FAILED ("Could not set private permissions on the verified image.");
                    verified_output = ImagePublication.flush (output);
                } catch (Error error) {
                    Posix.close (output);
                    throw error;
                }
                if (Posix.close (output) != 0) throw new IOError.FAILED ("Could not close the verified image.");
                if (source != null) {
                    if (grow != null && check_source != null) check_source (fd);
                    int current_source = open_image (source);
                    bool unchanged = original == image_identity (current_source) && original == image_identity (fd);
                    Posix.close (current_source);
                    if (!unchanged)
                        throw new IOError.INVALID_DATA ("The source image changed before publication.");
                }
                token.set_error_if_cancelled ();
                publication.publish (temporary, verified_output);
            } catch (Error error) {
                published_uncertain = ImagePublication.was_published (error);
                if (published_uncertain) recovery?.retain_publication (error);
                throw error;
            } finally {
                if (fd >= 0) Posix.close (fd);
                if (!published_uncertain && FileUtils.test (temporary, FileTest.EXISTS)) FileUtils.unlink (temporary);
                if (DirUtils.remove (directory) == 0) {
                    if (!published_uncertain) recovery?.remove ();
                }
                else warning ("Could not remove image work directory %s", directory);
            }
        }
    }
}
