namespace MajorisDisks {
    public class KernelStorageSafety {
        public static string device_number (uint64 number) {
            uint64 major = ((number >> 8) & 0xfff) | ((number >> 32) & 0xfffff000);
            uint64 minor = (number & 0xff) | ((number >> 12) & 0xffffff00);
            return major.to_string () + ":" + minor.to_string ();
        }

        public static async void require_idle (StorageBlock block, Cancellable token) throws Error {
            yield require_no_holders (block, token);
            string identity = device_number (block.number);
            uint8[] contents;
            yield File.new_for_path ("/proc/self/mountinfo").load_contents_async (token, out contents, null);
            if (has_mount ((string) contents, identity))
                throw new IOError.BUSY ("The kernel reports an active mount for this volume.");
        }

        public static async void require_no_holders (StorageBlock block, Cancellable token) throws Error {
            if (block.number == 0)
                throw new IOError.NOT_SUPPORTED ("The kernel device identity is unavailable.");
            string identity = device_number (block.number);
            var device = File.new_for_path ("/sys/dev/block/" + identity);
            var holders = yield device.get_child ("holders").enumerate_children_async (
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE, Priority.DEFAULT, token);
            var entries = yield holders.next_files_async (1, Priority.DEFAULT, token);
            if (entries != null)
                throw new IOError.BUSY ("Another kernel storage device depends on this volume.");
        }

        internal static async void require_sole_dm_dependency (StorageBlock backing, StorageBlock mapping,
            Cancellable token) throws Error {
            string backing_number = device_number (backing.number);
            string mapping_number = device_number (mapping.number);
            yield require_single_link (backing_number, "holders", mapping_number, token);
            yield require_single_link (mapping_number, "slaves", backing_number, token);
        }

        internal static uint64 block_capacity (StorageBlock block) throws Error {
            string sectors;
            FileUtils.get_contents ("/sys/dev/block/" + device_number (block.number) + "/size", out sectors);
            uint64 count;
            if (!uint64.try_parse (sectors.strip (), out count) || count == 0 || count > uint64.MAX / 512)
                throw new IOError.INVALID_DATA ("The kernel reported an invalid storage capacity.");
            return count * 512;
        }

        private static async void require_single_link (string device, string directory, string expected,
            Cancellable token) throws Error {
            var root = File.new_for_path ("/sys/dev/block/" + device + "/" + directory);
            var links = yield root.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE,
                Priority.DEFAULT, token);
            var entries = yield links.next_files_async (1, Priority.DEFAULT, token);
            var extra = yield links.next_files_async (1, Priority.DEFAULT, token);
            if (entries == null || extra != null)
                throw new IOError.BUSY ("The kernel does not report a single backing and cleartext dependency.");
            uint8[] contents;
            yield root.get_child (entries.data.get_name ()).get_child ("dev")
                .load_contents_async (token, out contents, null);
            if (((string) contents).strip () != expected)
                throw new IOError.BUSY ("The active kernel mapping belongs to a different block device.");
        }

        public static bool has_mount (string mountinfo, string identity) {
            foreach (var line in mountinfo.split ("\n")) {
                var fields = line.split (" ", 4);
                if (fields.length == 4 && fields[2] == identity) return true;
            }
            return false;
        }

        internal static string[] mount_signatures (string mountinfo, string identity, out bool whole_filesystem) {
            string[] signatures = {};
            whole_filesystem = true;
            foreach (var line in mountinfo.split ("\n")) {
                var fields = line.split (" ");
                if (fields.length < 10 || fields[2] != identity) continue;
                int separator = 6;
                while (separator < fields.length && fields[separator] != "-") separator++;
                if (separator + 3 >= fields.length) continue;
                whole_filesystem &= fields[3] == "/";
                // Omit the mount ID, which changes on remount. Retain the parent,
                // root, target, mount options, propagation and superblock options.
                signatures += string.joinv (" ", fields[1:fields.length]);
            }
            return signatures;
        }
    }
}
