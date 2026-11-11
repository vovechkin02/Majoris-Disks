namespace MajorisDisks {
    internal enum KernelMountRole { PRIMARY, WHOLE_FILESYSTEM_EXPOSURE, SUBDIRECTORY_EXPOSURE }

    internal class KernelMountRecord : Object {
        public uint id;
        public uint parent_id;
        public string device;
        public string root;
        public string target;
        public string filesystem;
        public string source;
        public string mount_options;
        public string super_options;
        public string[] propagation;
        public string namespace_id;
        public string block_path = "";
        public Variant? fstab;
        internal KernelMountRole role;
        internal uint source_mount_id;
        internal bool uses_udisks;
        internal bool preparation_removed;
        internal bool restoration_verified;

        public bool same_mount (KernelMountRecord current, uint expected_parent = 0) {
            return (expected_parent == 0 ? parent_id : expected_parent) == current.parent_id &&
                device == current.device && root == current.root && target == current.target &&
                filesystem == current.filesystem && same_options (mount_options, current.mount_options) &&
                same_options (super_options, current.super_options) && namespace_id == current.namespace_id &&
                string.joinv (" ", propagation) == string.joinv (" ", current.propagation);
        }

        private static bool same_options (string expected, string actual) {
            var wanted = expected.split (",");
            var found = actual.split (",");
            if (wanted.length != found.length) return false;
            foreach (var option in wanted)
                if (!(option in found)) return false;
            return true;
        }

        internal static KernelMountRecord? at_target (KernelMountRecord[] topology, string target) {
            foreach (var record in topology)
                if (record.target == target) return record;
            return null;
        }

    }

    public class KernelStorageSafety {
        public static string device_number (uint64 number) {
            uint64 major = ((number >> 8) & 0xfff) | ((number >> 32) & 0xfffff000);
            uint64 minor = (number & 0xff) | ((number >> 12) & 0xffffff00);
            return major.to_string () + ":" + minor.to_string ();
        }

        public static async void require_idle (StorageBlock block, Cancellable token) throws Error {
            if (block.number == 0)
                throw new IOError.NOT_SUPPORTED ("The kernel device identity is unavailable.");
            yield require_idle_number (device_number (block.number), token);
        }

        internal static async void require_idle_number (string identity, Cancellable token) throws Error {
            yield require_no_holders_number (identity, token);
            uint8[] contents;
            yield File.new_for_path ("/proc/self/mountinfo").load_contents_async (token, out contents, null);
            if (has_mount ((string) contents, identity))
                throw new IOError.BUSY ("The kernel reports an active mount for %s.".printf (identity));
        }

        public static async void require_no_holders (StorageBlock block, Cancellable token) throws Error {
            if (block.number == 0)
                throw new IOError.NOT_SUPPORTED ("The kernel device identity is unavailable.");
            yield require_no_holders_number (device_number (block.number), token);
        }

        private static async void require_no_holders_number (string identity, Cancellable token) throws Error {
            var device = File.new_for_path ("/sys/dev/block/" + identity);
            var holders = yield device.get_child ("holders").enumerate_children_async (
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE, Priority.DEFAULT, token);
            var entries = yield holders.next_files_async (1, Priority.DEFAULT, token);
            if (entries != null)
                throw new IOError.BUSY ("Kernel holder %s depends on %s.".printf (entries.data.get_name (), identity));
        }

        internal static string[] partition_numbers (string identity) throws Error {
            string root = "/sys/dev/block/" + identity;
            var children = Dir.open (root);
            string[] numbers = {};
            string? name;
            while ((name = children.read_name ()) != null) {
                string child = Path.build_filename (root, name);
                if (!FileUtils.test (Path.build_filename (child, "partition"), FileTest.IS_REGULAR))
                    continue;
                string number;
                FileUtils.get_contents (Path.build_filename (child, "dev"), out number);
                number = number.strip ();
                if (!Regex.match_simple ("^[0-9]+:[0-9]+$", number))
                    throw new IOError.INVALID_DATA ("A kernel partition has an invalid device number.");
                numbers += number;
            }
            return numbers;
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

        internal static void require_partition_geometry (StorageBlock block, StorageBlock parent) throws Error {
            var partition = block.partition;
            if (partition == null)
                throw new IOError.INVALID_ARGUMENT ("Expected a partition target.");
            string path = "/sys/dev/block/" + device_number (block.number);
            string parent_device, start, number;
            FileUtils.get_contents (path + "/../dev", out parent_device);
            FileUtils.get_contents (path + "/start", out start);
            FileUtils.get_contents (path + "/partition", out number);
            uint64 first_sector = 0;
            uint partition_number = 0;
            if (parent_device.strip () != device_number (parent.number) ||
                !uint64.try_parse (start.strip (), out first_sector) || first_sector > uint64.MAX / 512 ||
                !uint.try_parse (number.strip (), out partition_number) || partition_number != partition.number ||
                first_sector * 512 != partition.offset || block_capacity (block) != block.size)
                throw new IOError.INVALID_DATA ("The kernel partition geometry differs from the reviewed target.");
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

        private static string decode_mount_field (string field) throws Error {
            var decoded = new StringBuilder ();
            for (int i = 0; i < field.length; i++) {
                if (field[i] != '\\') {
                    decoded.append_c (field[i]);
                    continue;
                }
                if (field.length - i < 4)
                    throw new IOError.INVALID_DATA ("Incomplete kernel mount path escape.");
                switch (field.substring (i + 1, 3)) {
                case "040": decoded.append_c (' '); break;
                case "011": decoded.append_c ('\t'); break;
                case "012": decoded.append_c ('\n'); break;
                case "134": decoded.append_c ('\\'); break;
                default: throw new IOError.INVALID_DATA ("Invalid kernel mount path escape.");
                }
                i += 3;
            }
            return decoded.str;
        }

        internal static KernelMountRecord[] parse_mountinfo (string mountinfo, string namespace_id) throws Error {
            var seen = new HashTable<uint, bool> (direct_hash, direct_equal);
            var records = new GenericArray<KernelMountRecord> ();
            foreach (var line in mountinfo.split ("\n")) {
                if (line == "") continue;
                var fields = line.split (" ");
                int separator = 6;
                while (separator < fields.length && fields[separator] != "-") separator++;
                var record = new KernelMountRecord ();
                if (separator + 4 != fields.length || fields.length < 10 ||
                    !uint.try_parse (fields[0], out record.id) || record.id == 0 ||
                    !uint.try_parse (fields[1], out record.parent_id) || record.parent_id == 0 ||
                    seen.contains (record.id) || !Regex.match_simple ("^[0-9]+:[0-9]+$", fields[2]) ||
                    fields[5] == "" || fields[separator + 1] == "" ||
                    fields[separator + 2] == "" || fields[separator + 3] == "")
                    throw new IOError.INVALID_DATA ("Invalid or ambiguous kernel mount record.");
                record.device = fields[2];
                record.root = decode_mount_field (fields[3]);
                record.target = decode_mount_field (fields[4]);
                if (!Path.is_absolute (record.root) || !Path.is_absolute (record.target))
                    throw new IOError.INVALID_DATA ("Kernel mount roots and targets must be absolute.");
                record.mount_options = fields[5];
                record.propagation = fields[6:separator];
                foreach (var tag in record.propagation)
                    if (tag == "") throw new IOError.INVALID_DATA ("Empty kernel mount propagation field.");
                record.filesystem = fields[separator + 1];
                record.source = decode_mount_field (fields[separator + 2]);
                record.super_options = fields[separator + 3];
                record.namespace_id = namespace_id;
                seen.insert (record.id, true);
                records.add (record);
            }
            if (records.length == 0)
                throw new IOError.INVALID_DATA ("The kernel mount table is empty.");
            var result = new KernelMountRecord[records.length];
            for (uint i = 0; i < records.length; i++) result[i] = records[i];
            return result;
        }
    }
}
