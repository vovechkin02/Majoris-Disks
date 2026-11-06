namespace MajorisDisks {
    internal class VirtualDiskInfo : Object {
        public string format;
        public uint64 capacity;
        public uint64 file_size;
    }

    internal class VirtualDisk {
        public static bool available () {
            return FileUtils.test ("/usr/bin/qemu-img", FileTest.IS_EXECUTABLE) &&
                FileUtils.test ("/usr/bin/bwrap", FileTest.IS_EXECUTABLE);
        }

        private static bool supported (string format) {
            return format == "raw" || format == "vpc" || format == "vhdx" || format == "qcow2";
        }

        private static async string run (int input, string? output_directory, string[] arguments,
            Cancellable token) throws Error {
            if (!available ()) throw new IOError.NOT_SUPPORTED ("Install qemu-utils and bubblewrap for virtual images.");
            string[] argv = { "/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
                "--clearenv", "--setenv", "LC_ALL", "C", "--ro-bind", "/usr", "/usr",
                "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
                "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", "/" };
            if (input >= 0) {
                argv += "--ro-bind";
                argv += "/proc/%d/fd/%d".printf (Posix.getpid (), input);
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
            var process = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? output, diagnostic;
            try {
                yield process.communicate_utf8_async (null, token, out output, out diagnostic);
            } catch (Error error) {
                process.force_exit ();
                yield process.wait_async (null);
                throw error;
            }
            if (!process.get_successful ())
                throw new IOError.FAILED ((diagnostic ?? "The virtual image backend failed.").strip ());
            return output ?? "";
        }

        private static async VirtualDiskInfo inspect_fd (int input, Cancellable token) throws Error {
            Posix.Stat file = {};
            if (Posix.fstat (input, out file) != 0 || !Posix.S_ISREG (file.st_mode))
                throw new IOError.INVALID_DATA ("Choose a regular local image file.");
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
            string format = root.get_string_member ("format");
            int64 capacity = root.get_int_member ("virtual-size");
            if (!supported (format) || capacity <= 0)
                throw new IOError.NOT_SUPPORTED ("The image format or capacity is unsupported.");
            var result = new VirtualDiskInfo ();
            result.format = format;
            result.capacity = (uint64) capacity;
            result.file_size = (uint64) file.st_size;
            return result;
        }

        private static int open_image (File file) throws Error {
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

        public static async void write_image (File? source, File destination, string format, uint64 capacity,
            Cancellable token) throws Error {
            string? path = destination.get_path ();
            string? parent = destination.get_parent ()?.get_path ();
            if (path == null || parent == null || !supported (format))
                throw new IOError.INVALID_ARGUMENT ("Choose a local destination and a supported image format.");
            if (destination.query_exists (token))
                throw new IOError.EXISTS ("An image already exists at the selected destination.");
            string directory = Path.build_filename (parent, ".majoris-" + Uuid.string_random ());
            if (DirUtils.create (directory, 0700) != 0)
                throw new IOError.FAILED ("Could not create a private conversion directory.");
            string temporary = Path.build_filename (directory, "disk");
            int fd = -1;
            try {
                if (source == null) {
                    if (capacity == 0 || capacity > int64.MAX)
                        throw new IOError.INVALID_ARGUMENT ("Choose a valid virtual capacity.");
                    string[] create = { "create", "-f", format };
                    if (format == "vpc") { create += "-o"; create += "force_size=on"; }
                    create += "/output/disk";
                    create += capacity.to_string ();
                    yield run (-1, directory, create, token);
                } else {
                    fd = open_image (source);
                    var information = yield inspect_fd (fd, token);
                    capacity = information.capacity;
                    string[] convert = { "convert", "-f", information.format, "-O", format };
                    if (format == "vpc") { convert += "-o"; convert += "force_size=on"; }
                    convert += "/source";
                    convert += "/output/disk";
                    yield run (fd, directory, convert, token);
                }
                int output = open_image (File.new_for_path (temporary));
                try {
                    var verified = yield inspect_fd (output, token);
                    if (verified.format != format || verified.capacity != capacity)
                        throw new IOError.INVALID_DATA ("The output format or virtual capacity did not match the request.");
                } finally { Posix.close (output); }
                token.set_error_if_cancelled ();
                if (rename_without_replacement (CURRENT_DIRECTORY, temporary, CURRENT_DIRECTORY, path, NO_REPLACEMENT) != 0)
                    throw new IOError.FAILED ("Could not publish the image: " + Posix.strerror (Posix.errno));
            } finally {
                if (fd >= 0) Posix.close (fd);
                if (FileUtils.test (temporary, FileTest.EXISTS)) FileUtils.unlink (temporary);
                if (DirUtils.remove (directory) != 0) warning ("Could not remove image work directory %s", directory);
            }
        }
    }
}
