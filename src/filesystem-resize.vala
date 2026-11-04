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

        public async uint64 query (StorageBlock block, Cancellable token) throws Error {
            string key = "%s\n%s\n%s\n%" + uint64.FORMAT;
            key = key.printf (block.path, block.uuid, block.type_id, block.size);
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
                    minimum = blocks * block_size;
                    break;
                case "ntfs":
                    minimum = parse_named_number (yield run ({ "ntfsresize", "--info", "--force", block.preferred }, token), "Minsize");
                    break;
                case "btrfs":
                    var fs = block.filesystem;
                    if (fs == null || !fs.mounted)
                        throw new IOError.NOT_SUPPORTED ("Btrfs minimum size can only be queried while mounted.");
                    minimum = parse_first_number (yield run ({ "btrfs", "inspect-internal", "min-dev-size", fs.mounts[0] }, token));
                    break;
                default:
                    throw new IOError.NOT_SUPPORTED ("No reliable minimum-size backend is available for this filesystem.");
            }
            if (minimum == 0 || minimum > block.size)
                throw new IOError.INVALID_DATA ("The filesystem minimum-size backend returned an unsafe value.");
            var entry = new CacheEntry (); entry.size = minimum; cache.insert (key, entry);
            return minimum;
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

    public class FilesystemResizePlanner {
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
