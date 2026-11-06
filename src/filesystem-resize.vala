namespace MajorisDisks {
    public enum ResizeDirection { NONE, GROW, SHRINK }

    public class FilesystemResizePlan : Object {
        public ResizeDirection direction;
        public bool resize_filesystem;
        public bool mounted;
        public bool online;
        public bool requires_unmount;
        public bool requires_check;
        public bool supported;
        public uint64 minimum_size;
        public uint64 maximum_size;
        public string reason = "";
    }

    public class FilesystemMinimumSizeService : Object {
        private class CacheEntry : Object {
            public uint64 size;
            public int64 recorded = get_monotonic_time ();
        }
        private HashTable<string, CacheEntry> cache = new HashTable<string, CacheEntry> (str_hash, str_equal);

        public void invalidate (string object_path = "") {
            if (object_path == "") { cache.remove_all (); return; }
            foreach (var key in cache.get_keys ()) if (key.has_prefix (object_path + "\n")) cache.remove (key);
        }

        public async uint64 query (StorageBlock block, Cancellable token) throws Error {
            string mounts = block.filesystem == null ? "" : string.joinv ("\n", block.filesystem.mounts);
            string key = "%s\n%s\n%s\n%s\n%s\n%s\n%" + uint64.FORMAT + "\n%" + uint64.FORMAT + "\n%s";
            key = key.printf (block.path, block.preferred, block.physical_drive?.serial ?? "",
                block.physical_drive?.wwn ?? "", block.uuid, block.type_id, block.number, block.size, mounts);
            var cached = cache.lookup (key);
            if (cached != null && get_monotonic_time () - cached.recorded < 60 * TimeSpan.SECOND)
                return cached.size;
            uint64 minimum;
            switch (block.type_id.down ()) {
                case "ext2": case "ext3": case "ext4":
                    string tune = yield run ({ "tune2fs", "-l", block.preferred }, token);
                    string estimate = yield run ({ "resize2fs", "-P", block.preferred }, token);
                    uint64 block_size = parse_named_number (tune, "Block size:");
                    uint64 blocks = parse_named_number (estimate, "Estimated minimum size of the filesystem:");
                    if (block_size == 0 || blocks == 0 || blocks > uint64.MAX / block_size)
                        throw new IOError.INVALID_DATA ("The ext filesystem minimum-size estimate was invalid.");
                    minimum = validated_boundary (blocks * block_size, block, true);
                    break;
                case "ntfs":
                    minimum = validated_boundary (parse_named_number (yield run ({ "ntfsresize", "--info", "--force", block.preferred }, token), "Minsize"), block, false);
                    break;
                case "btrfs":
                    var fs = block.filesystem;
                    if (fs == null || !fs.mounted)
                        throw new IOError.NOT_SUPPORTED ("Btrfs minimum size can only be queried while mounted.");
                    string topology = yield run ({ "btrfs", "filesystem", "show", "--raw", fs.mounts[0] }, token);
                    if (!btrfs_single_device (topology, block.preferred))
                        throw new IOError.NOT_SUPPORTED ("Automatic Btrfs member shrinking is limited to verified single-device filesystems.");
                    minimum = validated_boundary (parse_first_number (yield run ({ "btrfs", "inspect-internal", "min-dev-size", fs.mounts[0] }, token)), block, false);
                    break;
                default:
                    throw new IOError.NOT_SUPPORTED ("No reliable minimum-size backend is available for this filesystem.");
            }
            if (minimum == 0 || minimum > block.size)
                throw new IOError.INVALID_DATA ("The filesystem minimum-size backend returned an unsafe value.");
            var entry = new CacheEntry (); entry.size = minimum; cache.insert (key, entry);
            return minimum;
        }

        public static bool btrfs_single_device (string output, string device) {
            int devices = 0;
            foreach (var line in output.split ("\n")) if (line.strip ().has_prefix ("devid")) devices++;
            return devices == 1 && output.contains (device);
        }

        private static uint64 validated_boundary (uint64 reported, StorageBlock block, bool estimate) throws Error {
            uint64 alignment = uint64.max (block.logical_sector_size, block.physical_sector_size);
            alignment = uint64.max (alignment, 1024 * 1024);
            uint64 margin = estimate ? uint64.max (64 * 1024 * 1024, reported / 20) : 16 * 1024 * 1024;
            if (reported > uint64.MAX - margin) throw new IOError.INVALID_DATA ("The minimum-size estimate overflowed.");
            uint64 safe = reported + margin;
            if (safe % alignment != 0) safe += alignment - safe % alignment;
            if (safe >= block.size)
                throw new IOError.NOT_SUPPORTED ("No reliably validated shrink range remains after the required safety margin.");
            return safe;
        }

        private static async string run (string[] argv, Cancellable token) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.setenv ("LC_ALL", "C", true);
            Subprocess process;
            try { process = launcher.spawnv (argv); }
            catch (Error error) { throw new IOError.NOT_SUPPORTED ("The filesystem minimum-size utility is unavailable: " + error.message); }
            string? output; string? errors;
            yield process.communicate_utf8_async (null, token, out output, out errors);
            if (!process.get_successful ())
                throw new IOError.FAILED ((errors ?? "Filesystem minimum-size query failed.").strip ());
            return output ?? "";
        }

        public static uint64 parse_named_number (string output, string name) throws Error {
            foreach (var line in output.split ("\n")) {
                int position = line.index_of (name);
                if (position < 0) continue;
                return parse_first_number (line.substring (position + name.length));
            }
            throw new IOError.INVALID_DATA ("The minimum-size utility returned unexpected output.");
        }

        public static uint64 parse_first_number (string output) throws Error {
            var digits = new StringBuilder ();
            bool started = false;
            for (int i = 0; i < output.length; i++) {
                char character = output[i];
                if (character >= '0' && character <= '9') { digits.append_c (character); started = true; }
                else if (started) break;
            }
            uint64 value = 0;
            if (digits.len == 0 || !uint64.try_parse (digits.str, out value) || value == 0)
                throw new IOError.INVALID_DATA ("The minimum-size utility did not return a valid size.");
            return value;
        }
    }

    public class FilesystemCapacityMeasurement : Object {
        public uint64 capacity;
        public uint64 allocation_unit;
        public string filesystem_type = "";
        public string filesystem_uuid = "";
        public string source = "";
    }

    public class FilesystemCapacityProbeService : Object {
        public async FilesystemCapacityMeasurement query (StorageBlock block, Cancellable token, DBusProxy? block_proxy = null) throws Error {
            string path = block.path;
            string device = block.preferred;
            string expected_type = normalize_type (block.type_id);
            string expected_uuid = block.uuid;
            uint64 number = block.number;
            uint64 size = block.size;
            string serial = block.physical_drive?.serial ?? "";
            string wwn = block.physical_drive?.wwn ?? "";
            if (device == "" || expected_type == "")
                throw new IOError.NOT_SUPPORTED ("The filesystem does not expose a probeable device and type.");

            HashTable<string, string> fields;
            bool authorized_probe = false;
            try {
                if (Posix.access (device, Posix.R_OK) != 0 &&
                    (Posix.errno == Posix.EACCES || Posix.errno == Posix.EPERM))
                    throw new IOError.PERMISSION_DENIED ("The filesystem device is not readable by this user.");
                string output = yield run ({ "blkid", "--probe", "--output", "export", device }, token);
                fields = parse_export (output);
            } catch (IOError error) {
                if (!(error is IOError.PERMISSION_DENIED) || block_proxy == null) throw error;
                fields = yield probe_authorized (block_proxy, number, token);
                authorized_probe = true;
            }
            string actual_type = normalize_type (fields.lookup ("TYPE") ?? "");
            string actual_uuid = fields.lookup ("UUID") ?? "";
            if (actual_type == "" || actual_type != expected_type)
                throw new IOError.INVALID_DATA ("The capacity probe identified a different filesystem type.");
            string source = authorized_probe ? "libblkid metadata through UDisks" : "libblkid filesystem metadata";
            uint64 block_size;
            uint64 capacity;
            if (!authorized_probe && (actual_type == "ext2" || actual_type == "ext3" || actual_type == "ext4") &&
                (!fields.contains ("FSSIZE") || (expected_uuid != "" && actual_uuid == ""))) {
                string header = yield run ({ "dumpe2fs", "-h", device }, token);
                var ext = parse_ext_header (header);
                verify_uuid (actual_uuid, ext.filesystem_uuid);
                actual_uuid = ext.filesystem_uuid;
                block_size = ext.allocation_unit;
                capacity = ext.capacity;
                source = ext.source;
            } else {
                block_size = parse_uint (fields.lookup ("FSBLOCKSIZE") ?? "", "filesystem block size", false);
                capacity = capacity_from_metadata (fields);
            }
            verify_uuid (expected_uuid, actual_uuid);

            if (block.path != path || block.preferred != device || block.number != number || block.size != size ||
                !block.available || normalize_type (block.type_id) != expected_type || block.uuid != expected_uuid ||
                (block.physical_drive?.serial ?? "") != serial || (block.physical_drive?.wwn ?? "") != wwn)
                throw new IOError.NOT_FOUND ("The filesystem device identity changed during capacity probing.");

            if (block_size == 0) block_size = uint64.max (block.logical_sector_size, block.physical_sector_size);
            if (capacity == 0 || capacity > block.size)
                throw new IOError.INVALID_DATA ("The filesystem capacity metadata is outside the containing device.");

            var measurement = new FilesystemCapacityMeasurement ();
            measurement.capacity = capacity;
            measurement.allocation_unit = block_size;
            measurement.filesystem_type = actual_type;
            measurement.filesystem_uuid = actual_uuid;
            measurement.source = source;
            return measurement;
        }

        internal static async HashTable<string, string> probe_authorized (DBusProxy proxy, uint64 device_number,
            Cancellable token) throws Error {
            UnixFDList? descriptors;
            var reply = yield proxy.call_with_unix_fd_list ("OpenDevice",
                new Variant ("(s@a{sv})", "r", new Variant ("a{sv}", null)),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null, token, out descriptors);
            if (descriptors == null || !reply.is_of_type (new VariantType ("(h)")))
                throw new IOError.INVALID_DATA ("UDisks did not return a read-only block descriptor.");
            int handle = reply.get_child_value (0).get_handle ();
            if (handle < 0 || handle >= descriptors.get_length ())
                throw new IOError.INVALID_DATA ("UDisks returned an invalid block descriptor index.");
            int fd = descriptors.get (handle);
            try {
                Posix.Stat info;
                if (Posix.fstat (fd, out info) != 0)
                    throw new IOError.INVALID_DATA ("Could not inspect the returned block descriptor.");
                int flags = Posix.fcntl (fd, Posix.F_GETFL);
                if (flags < 0 || (flags & Posix.O_ACCMODE) != Posix.O_RDONLY ||
                    !Posix.S_ISBLK (info.st_mode) ||
                    (uint64) info.st_rdev != device_number)
                    throw new IOError.INVALID_DATA ("The returned block descriptor did not match the selected device.");

                return yield probe_descriptor (fd, token);
            } finally { Posix.close (fd); }
        }

        internal static async HashTable<string, string> probe_descriptor (int fd, Cancellable token) throws Error {
            token.set_error_if_cancelled ();
            var context = MainContext.ref_thread_default ();
            var fields = new HashTable<string, string> (str_hash, str_equal);
            int status = -1;
            new Thread<void*>.try ("filesystem-capacity", () => {
                status = read_probe_fields (fd, fields);
                var resume = new IdleSource ();
                resume.set_callback (probe_descriptor.callback);
                resume.attach (context);
                return null;
            });
            yield;
            token.set_error_if_cancelled ();
            if (status != 0)
                throw new IOError.INVALID_DATA ("libblkid could not establish unambiguous filesystem metadata.");
            return fields;
        }

        private static int read_probe_fields (int fd, HashTable<string, string> fields) {
            var probe = new BlkidProbe ();
            if (probe == null || probe.set_device (fd, 0, 0) != 0 ||
                probe.set_superblocks_flags (BLKID_DEFAULT_FIELDS | BLKID_FILESYSTEM_FIELDS) != 0)
                return -1;
            int status = probe.safe_probe ();
            if (status != 0) return status;
            foreach (var key in new string[] { "TYPE", "UUID", "FSSIZE", "FSBLOCKSIZE" }) {
                unowned string value;
                if (probe.lookup_value (key, out value) == 0)
                    fields.insert (key, value.dup ());
            }
            return status;
        }

        public static FilesystemCapacityMeasurement parse_ext_header (string output) throws Error {
            var fields = new HashTable<string, string> (str_hash, str_equal);
            foreach (var line in output.split ("\n")) {
                int separator = line.index_of_char (':');
                if (separator > 0)
                    fields.insert (line.substring (0, separator), line.substring (separator + 1).strip ());
            }
            uint64 blocks = parse_uint (fields.lookup ("Block count") ?? "", "ext block count", false);
            uint64 block_size = parse_uint (fields.lookup ("Block size") ?? "", "ext block size", false);
            if (blocks == 0 || block_size == 0 || blocks > uint64.MAX / block_size)
                throw new IOError.INVALID_DATA ("The ext filesystem header did not report valid geometry.");

            var measurement = new FilesystemCapacityMeasurement ();
            measurement.capacity = blocks * block_size;
            measurement.allocation_unit = block_size;
            measurement.filesystem_uuid = fields.lookup ("Filesystem UUID") ?? "";
            measurement.source = "dumpe2fs filesystem header";
            return measurement;
        }

        public static void verify_uuid (string expected, string actual) throws Error {
            if (expected == "") return;
            if (actual == "")
                throw new IOError.NOT_SUPPORTED ("The capacity probe could not verify the filesystem UUID.");
            if (expected.ascii_casecmp (actual) != 0)
                throw new IOError.INVALID_DATA ("The capacity probe identified a different filesystem UUID.");
        }

        public static HashTable<string, string> parse_export (string output) {
            var fields = new HashTable<string, string> (str_hash, str_equal);
            foreach (var source_line in output.split ("\n")) {
                string line = source_line.strip ();
                int separator = line.index_of_char ('=');
                if (separator <= 0 || separator == line.length - 1) continue;
                fields.insert (line.substring (0, separator), line.substring (separator + 1));
            }
            return fields;
        }

        public static uint64 capacity_from_metadata (HashTable<string, string> fields) throws Error {
            uint64 capacity = parse_uint (fields.lookup ("FSSIZE") ?? "", "filesystem capacity", false);
            // libblkid probers do not give FSLASTBLOCK one portable meaning. It is intentionally
            // not converted to bytes unless a filesystem-specific implementation can establish
            // whether the value is a count or a final zero-based index.
            if (capacity == 0)
                throw new IOError.NOT_SUPPORTED ("libblkid did not report an authoritative filesystem capacity.");
            return capacity;
        }

        public static bool authoritative_match (FilesystemCapacityMeasurement measurement,
            uint64 requested_size, uint64 partition_size, uint64 logical_sector_size,
            uint64 physical_sector_size) {
            if (measurement.capacity == 0 || measurement.capacity > partition_size) return false;
            uint64 alignment = uint64.max (measurement.allocation_unit,
                uint64.max (logical_sector_size, physical_sector_size));
            if (alignment == 0) alignment = 512;
            return measurement.capacity >= requested_size || requested_size - measurement.capacity <= alignment;
        }

        private static string normalize_type (string type) {
            string normalized = type.down ();
            if (normalized == "fat" || normalized == "fat12" || normalized == "fat16" || normalized == "fat32")
                return "vfat";
            return normalized;
        }

        private static uint64 parse_uint (string text, string field, bool allow_zero) throws Error {
            uint64 value = 0;
            if (text == "") return 0;
            if (!uint64.try_parse (text, out value) || (!allow_zero && value == 0))
                throw new IOError.INVALID_DATA ("The " + field + " reported by the capacity probe was invalid.");
            return value;
        }

        private static async string run (string[] argv, Cancellable token) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.setenv ("LC_ALL", "C", true);
            Subprocess process;
            try { process = launcher.spawnv (argv); }
            catch (Error error) {
                throw new IOError.NOT_SUPPORTED ("The read-only filesystem capacity probe is unavailable: " + error.message);
            }
            string? output; string? errors;
            try { yield process.communicate_utf8_async (null, token, out output, out errors); }
            catch (IOError error) {
                if (error is IOError.CANCELLED) process.force_exit ();
                throw error;
            }
            if (!process.get_successful ()) {
                string message = (errors ?? "").strip ();
                if (message.contains ("Permission denied") || message.contains ("Operation not permitted"))
                    throw new IOError.PERMISSION_DENIED (message);
                throw new IOError.INVALID_DATA (message == "" ? "The filesystem metadata could not be read." : message);
            }
            return output ?? "";
        }
    }

    public class FilesystemResizePlanner {
        public static uint64 capacity_tolerance (string filesystem_type, uint64 logical_sector_size,
            uint64 physical_sector_size) {
            uint64 sector = uint64.max (logical_sector_size, physical_sector_size);
            switch (filesystem_type.down ()) {
                // ext filesystems can leave one final block group unused after an online grow.
                case "ext2": case "ext3": case "ext4": return uint64.max (128 * 1024 * 1024, sector);
                // These formats report total filesystem bytes and only require bounded allocation-unit alignment.
                case "ntfs": return uint64.max (8 * 1024 * 1024, sector);
                case "vfat": case "fat": case "exfat": return uint64.max (4 * 1024 * 1024, sector);
                case "btrfs": return uint64.max (1024 * 1024, sector);
                case "xfs": return uint64.max (16 * 1024 * 1024, sector);
                default: return 0;
            }
        }

        public static bool capacity_matches (string filesystem_type, uint64 capacity,
            uint64 partition_size, uint64 requested_size, uint64 logical_sector_size,
            uint64 physical_sector_size) {
            uint64 tolerance = capacity_tolerance (filesystem_type, logical_sector_size,
                physical_sector_size);
            if (tolerance == 0 || capacity == 0 || capacity > partition_size) return false;
            return capacity >= requested_size || requested_size - capacity <= tolerance;
        }

        public static FilesystemResizePlan build (StorageBlock block, uint64 requested,
            bool resize_filesystem, FilesystemCapability capability, uint64 minimum_size,
            uint64 maximum_size) {
            var plan = new FilesystemResizePlan ();
            plan.direction = requested < block.size ? ResizeDirection.SHRINK :
                requested > block.size ? ResizeDirection.GROW : ResizeDirection.NONE;
            plan.resize_filesystem = resize_filesystem;
            plan.mounted = block.filesystem?.mounted ?? false;
            plan.minimum_size = minimum_size;
            plan.maximum_size = maximum_size;
            if (plan.direction == ResizeDirection.NONE) { plan.reason = "Choose a different size."; return plan; }
            if (requested == 0 || requested > maximum_size) { plan.reason = "The requested size is outside the available partition boundary."; return plan; }
            if (requested < minimum_size) { plan.reason = "The requested size is below the verified safe minimum."; return plan; }
            if (plan.direction == ResizeDirection.SHRINK && block.filesystem != null && !resize_filesystem) {
                plan.reason = "A recognised filesystem must be shrunk together with its partition.";
                return plan;
            }
            if (plan.direction == ResizeDirection.SHRINK && block.filesystem == null &&
                (block.type_id != "" || block.usage != "" || block.encrypted != null)) {
                plan.reason = "The contents cannot be measured safely enough for partition-only shrinking.";
                return plan;
            }
            if (!resize_filesystem || block.filesystem == null) { plan.supported = true; return plan; }
            if (!capability.supported) { plan.reason = capability.reason; return plan; }
            if (plan.direction == ResizeDirection.SHRINK) {
                if (minimum_size == 0) { plan.reason = "A reliable minimum filesystem size is unavailable."; return plan; }
                plan.online = plan.mounted && capability.online_shrink;
                bool offline = capability.offline_shrink;
                if (!plan.online && !offline) { plan.reason = plan.mounted ?
                    "This filesystem cannot be safely shrunk while mounted." : "This filesystem does not support offline shrinking."; return plan; }
                plan.requires_unmount = !plan.online;
                plan.requires_check = plan.requires_unmount && requires_check (block.type_id);
            } else {
                plan.online = plan.mounted && capability.online_grow;
                bool offline = capability.offline_grow;
                if (!plan.online && !offline) { plan.reason = plan.mounted ?
                    "This filesystem cannot be safely grown while mounted." : "This filesystem does not support offline growth."; return plan; }
                plan.requires_unmount = plan.mounted && !plan.online;
                plan.requires_check = plan.requires_unmount && requires_check (block.type_id);
            }
            plan.supported = true;
            return plan;
        }

        private static bool requires_check (string type) {
            switch (type.down ()) {
                case "ext2": case "ext3": case "ext4": case "ntfs": return true;
                default: return false;
            }
        }
    }
}
