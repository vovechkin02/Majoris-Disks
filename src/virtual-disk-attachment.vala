namespace MajorisDisks {
    internal errordomain VirtualAttachmentError { UNCERTAIN }
    internal class VirtualAttachment : Object {
        public uint index;
        public string token = "";
        public string file = "";
        public string format = "";
        public uint64 capacity;
        public uint exporter_pid;
        public string exporter_start = "";
    }

    [CCode (cname = "majoris_nbd_token", cheader_filename = "nbd-identity.h")]
    private extern string? nbd_token (uint index, uint uid);

    [CCode (cname = "flock", cheader_filename = "sys/file.h")]
    private extern int lock_file (int fd, int operation);
    [CCode (cname = "LOCK_EX", cheader_filename = "sys/file.h")]
    private extern const int EXCLUSIVE_LOCK;
    [CCode (cname = "LOCK_NB", cheader_filename = "sys/file.h")]
    private extern const int NONBLOCKING_LOCK;

    internal class VirtualDiskAttachment {
        private const string BUS = "com.majoris.disks.Nbd";
        private const string OBJECT = "/com/majoris/disks/Nbd";

        public static string? unavailable_reason () {
            if (!VirtualDisk.available () || !FileUtils.test ("/usr/bin/qemu-nbd", FileTest.IS_EXECUTABLE))
                return "Install qemu-utils and Bubblewrap to attach virtual disks.";
            if (!FileUtils.test ("/usr/bin/setsid", FileTest.IS_EXECUTABLE))
                return "Install util-linux to supervise virtual-disk exports.";
            if (!FileUtils.test ("/usr/sbin/nbd-client", FileTest.IS_EXECUTABLE)) return "Install nbd-client to attach virtual disks.";
            if (!FileUtils.test ("/sys/module/nbd", FileTest.IS_DIR))
                return "Load the Linux NBD module with partition support to attach virtual disks.";
            string partitions;
            try {
                FileUtils.get_contents ("/sys/module/nbd/parameters/max_part", out partitions);
                uint maximum;
                if (!uint.try_parse (partitions.strip (), out maximum) || maximum == 0)
                    return "The NBD module has partition discovery disabled.";
            } catch (Error error) {
                return "Could not verify partition scanning support in the loaded NBD module.";
            }
            bool helper_installed = false;
            foreach (var data in Environment.get_system_data_dirs ()) {
                if (FileUtils.test (Path.build_filename (data, "dbus-1", "system-services", BUS + ".service"),
                    FileTest.IS_REGULAR)) helper_installed = true;
            }
            if (!helper_installed) return "Install the Majoris NBD authorization helper to attach virtual disks.";
            if (Environment.get_user_runtime_dir () != "/run/user/%u".printf ((uint) Posix.getuid ()))
                return "A desktop runtime directory is required to attach virtual disks.";
            return null;
        }

        private static string root () {
            return Path.build_filename (Environment.get_user_runtime_dir (), "majoris-nbd");
        }

        private static string device_token (uint index) {
            return nbd_token (index, (uint) Posix.getuid ()) ?? "";
        }

        internal static bool parse_device (string device, out uint index) {
            index = 0;
            if (!device.has_prefix ("/dev/nbd")) return false;
            string suffix = device.substring (8);
            return uint.try_parse (suffix, out index) && suffix == index.to_string ();
        }

        public static VirtualAttachment? lookup (string device) {
            uint index;
            if (!parse_device (device, out index)) return null;
            string token = device_token (index);
            if (token == "") return null;
            var record = new VirtualAttachment () { index = index, token = token };
            var data = new KeyFile ();
            try {
                data.load_from_file (Path.build_filename (root (), token, "image.ini"), KeyFileFlags.NONE);
                record.file = data.get_string ("image", "path");
                record.format = data.get_string ("image", "format");
                record.capacity = data.get_uint64 ("image", "capacity");
                record.exporter_pid = (uint) data.get_uint64 ("image", "exporter-pid");
                record.exporter_start = data.get_string ("image", "exporter-start");
            } catch (Error error) {}
            return record;
        }

        private static string exporter_identity (uint pid) {
            if (pid == 0) return "";
            string status;
            try { FileUtils.get_contents ("/proc/%u/stat".printf (pid), out status); }
            catch (Error error) { return ""; }
            int name_end = status.last_index_of_char (')');
            if (name_end < 0) return "";
            string[] fields = status.substring (name_end + 2).split (" ");
            return fields.length > 19 ? fields[19] : "";
        }

        internal static bool exporter_running (VirtualAttachment record) {
            return record.exporter_start != "" && exporter_identity (record.exporter_pid) == record.exporter_start;
        }

        private static void remove_record (string directory) {
            string endpoint_dir = Path.build_filename (directory, "socket");
            FileUtils.unlink (Path.build_filename (endpoint_dir, "export.sock"));
            DirUtils.remove (endpoint_dir);
            FileUtils.unlink (Path.build_filename (directory, "image.ini"));
            if (DirUtils.remove (directory) != 0)
                warning ("Could not remove NBD runtime directory %s", directory);
        }

        private static string file_key (Posix.Stat info) {
            return "%s:%s".printf (((uint64) info.st_dev).to_string (), ((uint64) info.st_ino).to_string ());
        }

        private static bool same_source (string path, string key) {
            Posix.Stat info = {};
            return Posix.lstat (path, out info) == 0 && Posix.S_ISREG (info.st_mode) && file_key (info) == key;
        }

        private static bool find_token_device (string token, out uint index) throws Error {
            index = 0;
            var devices = Dir.open ("/sys/block");
            string? name;
            while ((name = devices.read_name ()) != null) {
                if (parse_device ("/dev/" + name, out index) && device_token (index) == token) return true;
            }
            return false;
        }

        private static bool already_registered (string key) throws Error {
            var entries = Dir.open (root ());
            string? name;
            while ((name = entries.read_name ()) != null) {
                if (!Uuid.string_is_valid (name)) continue;
                var data = new KeyFile ();
                string directory = Path.build_filename (root (), name);
                string path = Path.build_filename (directory, "image.ini");
                try { data.load_from_file (path, KeyFileFlags.NONE); }
                catch (Error error) { continue; }
                if (data.get_string ("image", "key") != key) continue;
                Posix.Stat info = {};
                uint index;
                if (Posix.stat (path, out info) != 0 || get_real_time () / TimeSpan.SECOND - info.st_mtime < 180 ||
                    find_token_device (name, out index)) return true;
                uint pid = 0;
                string started = "";
                try {
                    pid = (uint) data.get_uint64 ("image", "exporter-pid");
                    started = data.get_string ("image", "exporter-start");
                } catch (Error error) {}
                if (started != "" && exporter_identity (pid) == started) return true;
                remove_record (directory);
            }
            return false;
        }

        private static async void wait_tick () {
            var timer = new TimeoutSource (100);
            timer.set_callback (wait_tick.callback);
            timer.attach (MainContext.ref_thread_default ());
            yield;
        }

        private static bool reply_uncertain (Error error) {
            return error is DBusError.NO_REPLY || error is DBusError.DISCONNECTED ||
                error is IOError.TIMED_OUT || error is IOError.CLOSED;
        }

        private static Subprocess export_image (int fd, string format, string directory, string id, bool read_only) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            int image = Posix.dup (fd);
            if (image < 0) throw new IOError.FAILED ("Could not retain the virtual image descriptor.");
            launcher.take_fd (image, 3);
            // Keep the exporter independent of the GUI, but tied to a process we own during setup.
            string[] arguments = { "/usr/bin/setsid", "--fork", "--wait", "/usr/bin/bwrap",
                "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
                "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
                "--dev", "/dev", "--tmpfs", "/tmp", read_only ? "--ro-bind-fd" : "--bind-fd", "3", "/source",
                "--bind", directory, "/export", "--", "/usr/bin/qemu-nbd", "--socket=/export/export.sock",
                "--format=" + format, "--shared=2", "--export-name=" + id, "--handshake-limit=10" };
            if (read_only) arguments += "--read-only";
            arguments += "/source";
            return launcher.spawnv (arguments);
        }

        public static async VirtualAttachment attach (File image, bool read_only, Cancellable token) throws Error {
            string? unavailable = unavailable_reason ();
            if (unavailable != null) throw new IOError.NOT_SUPPORTED (unavailable);
            string? path = image.get_path ();
            if (path == null) throw new IOError.INVALID_ARGUMENT ("Choose a local virtual image.");
            if (DirUtils.create_with_parents (root (), 0700) != 0)
                throw new IOError.FAILED ("Could not create the NBD runtime directory.");
            int lock = Posix.open (Path.build_filename (root (), "lock"),
                Posix.O_CREAT | Posix.O_RDWR | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0600);
            if (lock < 0) throw new IOError.FAILED ("Could not open the virtual-image operation lock.");
            int fd = -1;
            string? directory = null;
            Subprocess? exporter = null;
            bool dispatched = false;
            bool connected = false;
            try {
                if (lock_file (lock, EXCLUSIVE_LOCK | NONBLOCKING_LOCK) != 0)
                    throw new IOError.BUSY ("Another Majoris virtual attachment is in progress.");
                Posix.Stat runtime = {};
                if (Posix.lstat (root (), out runtime) != 0 || !Posix.S_ISDIR (runtime.st_mode) ||
                    runtime.st_uid != Posix.getuid () || (runtime.st_mode & 0077) != 0)
                    throw new IOError.PERMISSION_DENIED ("The NBD runtime directory is not private.");
                fd = Posix.open (path, (read_only ? Posix.O_RDONLY : Posix.O_RDWR) |
                    Posix.O_CLOEXEC | Posix.O_NOFOLLOW | Posix.O_NONBLOCK);
                Posix.Stat info = {};
                if (fd < 0 || Posix.fstat (fd, out info) != 0 || !Posix.S_ISREG (info.st_mode))
                    throw new IOError.INVALID_ARGUMENT ("Could not open a regular image file with the requested access.");
                string key = file_key (info);
                if (already_registered (key))
                    throw new IOError.EXISTS ("This virtual image already has a managed attachment or a pending recovery record.");
                string? original = image_identity (fd);
                var inspected = yield VirtualDisk.inspect_fd (fd, token);
                if (inspected.format == "raw")
                    throw new IOError.NOT_SUPPORTED ("Attach raw images through the loop-device workflow.");
                if (inspected.has_snapshots)
                    throw new IOError.NOT_SUPPORTED ("Attach a self-contained image without internal snapshots.");
                if (!read_only && inspected.format != "qcow2")
                    throw new IOError.NOT_SUPPORTED ("Writable attachment is supported for QCOW2 images.");
                if (original == null || original != image_identity (fd))
                    throw new IOError.INVALID_DATA ("The selected image changed during inspection.");
                string id = Uuid.string_random ();
                string private_directory = Path.build_filename (root (), id);
                string socket_directory = Path.build_filename (private_directory, "socket");
                string endpoint = Path.build_filename (socket_directory, "export.sock");
                if (endpoint.length >= 108)
                    throw new IOError.NOT_SUPPORTED ("The desktop runtime path is too long for an NBD socket.");
                if (DirUtils.create (private_directory, 0700) != 0)
                    throw new IOError.FAILED ("Could not create the private NBD socket directory.");
                directory = private_directory;
                if (DirUtils.create (socket_directory, 0700) != 0)
                    throw new IOError.FAILED ("Could not create the exporter socket directory.");
                var record = new KeyFile ();
                record.set_string ("image", "key", key);
                record.set_string ("image", "path", path);
                record.set_string ("image", "format", inspected.format);
                record.set_uint64 ("image", "capacity", inspected.capacity);
                record.save_to_file (Path.build_filename (directory, "image.ini"));
                exporter = export_image (fd, inspected.format, socket_directory, id, read_only);
                uint pid;
                if (!uint.try_parse (exporter.get_identifier () ?? "", out pid))
                    throw new IOError.FAILED ("Could not identify the QEMU exporter process.");
                string start_time = exporter_identity (pid);
                if (start_time == "") throw new IOError.FAILED ("The QEMU exporter exited before it could be verified.");
                record.set_uint64 ("image", "exporter-pid", pid);
                record.set_string ("image", "exporter-start", start_time);
                record.save_to_file (Path.build_filename (directory, "image.ini"));
                for (int i = 0; i < 50 && !FileUtils.test (endpoint, FileTest.EXISTS); i++) {
                    token.set_error_if_cancelled ();
                    if (exporter_identity (pid) != start_time)
                        throw new IOError.FAILED ("The QEMU exporter exited without opening its private socket.");
                    yield wait_tick ();
                }
                Posix.Stat socket_info = {};
                if (Posix.lstat (endpoint, out socket_info) != 0 || !Posix.S_ISSOCK (socket_info.st_mode))
                    throw new IOError.TIMED_OUT ("The QEMU exporter did not create its private socket.");
                token.set_error_if_cancelled ();
                if (original != image_identity (fd) || !same_source (path, key))
                    throw new IOError.INVALID_DATA ("The image changed before the NBD export was connected.");
                var bus = yield Bus.get (BusType.SYSTEM, token);
                dispatched = true;
                // After dispatch, wait for the result even if the user closes the dialog.
                uint index = 0;
                try {
                    var reply = yield bus.call (BUS, OBJECT, BUS, "Attach",
                        new Variant ("(stb)", id, inspected.capacity, read_only),
                        new VariantType ("(u)"), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 180000, null);
                    index = reply.get_child_value (0).get_uint32 ();
                } catch (Error error) {
                    if (!reply_uncertain (error)) throw error;
                    bool observed = false;
                    for (int attempt = 0; attempt < 50; attempt++) {
                        try {
                            if (find_token_device (id, out index)) { observed = true; break; }
                        } catch (Error scan_error) { break; }
                        yield wait_tick ();
                    }
                    if (!observed) throw error;
                }
                connected = true;
                if (device_token (index) != id)
                    throw new VirtualAttachmentError.UNCERTAIN ("The kernel attachment could not be verified. Recovery information was retained.");
                var attached = new VirtualAttachment () { index = index, token = id, file = path, format = inspected.format,
                    capacity = inspected.capacity, exporter_pid = pid, exporter_start = start_time };
                if (!same_source (path, key)) {
                    try { yield detach (attached); }
                    catch (Error error) {
                        throw new VirtualAttachmentError.UNCERTAIN ("The source path changed and cleanup could not be confirmed. " + error.message);
                    }
                    throw new IOError.INVALID_DATA ("The image was replaced during authorization. Its original mapping was detached.");
                }
                return attached;
            } catch (Error error) {
                if (dispatched && !connected && (reply_uncertain (error) ||
                    DBusError.get_remote_error (error) == BUS + ".Error.Uncertain"))
                    throw new VirtualAttachmentError.UNCERTAIN ("The NBD result is uncertain. Recovery information was retained. " + error.message);
                if (!connected) dispatched = false;
                throw error;
            } finally {
                if (fd >= 0) Posix.close (fd);
                if (!dispatched) {
                    if (exporter != null) {
                        exporter.force_exit ();
                        try { yield exporter.wait_async (); } catch (Error error) {}
                    }
                    if (directory != null) remove_record (directory);
                }
                Posix.close (lock);
            }
        }

        public static async void detach (VirtualAttachment record) throws Error {
            if (device_token (record.index) != record.token)
                throw new IOError.PERMISSION_DENIED ("The NBD attachment ownership changed.");
            var bus = yield Bus.get (BusType.SYSTEM);
            Error? lost_reply = null;
            try {
                yield bus.call (BUS, OBJECT, BUS, "Detach", new Variant ("(us)", record.index, record.token),
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 180000, null);
            } catch (Error error) {
                if (!reply_uncertain (error)) throw error;
                lost_reply = error;
            }
            for (int i = 0; i < 50 && device_token (record.index) == record.token; i++) yield wait_tick ();
            if (device_token (record.index) == record.token)
                throw new IOError.TIMED_OUT ("NBD accepted the detach request, but the mapping is still present.");
            for (int i = 0; i < 50 && exporter_running (record); i++) yield wait_tick ();
            if (exporter_running (record))
                throw new IOError.FAILED ("The NBD mapping was disconnected, but the QEMU exporter did not exit. Recovery details were retained.");
            if (lost_reply != null) {
                string sysfs = "/sys/block/nbd%u".printf (record.index);
                string size;
                if (!FileUtils.get_contents (sysfs + "/size", out size) || size.strip () != "0" ||
                    FileUtils.test (sysfs + "/pid", FileTest.EXISTS))
                    throw new VirtualAttachmentError.UNCERTAIN ("The detach reply was lost and the kernel device was not verified empty.");
            }
            string directory = Path.build_filename (root (), record.token);
            if (FileUtils.test (directory, FileTest.IS_DIR)) remove_record (directory);
        }
    }
}
