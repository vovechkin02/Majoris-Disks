namespace MajorisDisks {
    public class StorageOperationLocks : Object {
        private HashTable<string, HashTable<string, string>> active =
            new HashTable<string, HashTable<string, string>> (str_hash, str_equal);

        private HashTable<string, string> footprint (StorageBlock target, StorageDependencyService graph) {
            var paths = new HashTable<string, string> (str_hash, str_equal);
            foreach (var device in graph.descendants (target))
                foreach (var upstream in graph.ancestors (device))
                    paths.insert (upstream.path, upstream.path);
            return paths;
        }

        public bool conflicts (StorageBlock target, StorageDependencyService graph) {
            var requested = footprint (target, graph);
            foreach (var running in active.get_values ())
                foreach (var path in requested.get_keys ())
                    if (running.contains (path)) return true;
            return false;
        }

        public void acquire (StorageBlock target, StorageDependencyService graph) throws Error {
            if (conflicts (target, graph))
                throw new IOError.BUSY ("Another storage operation is using this device.");
            active.insert (target.path, footprint (target, graph));
        }

        public void release (StorageBlock target) {
            active.remove (target.path);
        }
    }

    [Flags]
    public enum FilesystemResizeMode {
        OFFLINE_SHRINK = 1 << 1,
        OFFLINE_GROW = 1 << 2,
        ONLINE_SHRINK = 1 << 3,
        ONLINE_GROW = 1 << 4
    }

    public class FilesystemCapabilityService {
        public static FilesystemResizeMode resize_modes (Variant reply, out string missing_utility) throws Error {
            missing_utility = "";
            if (!reply.is_of_type (new VariantType ("(bts)")))
                throw new IOError.INVALID_DATA ("UDisks returned invalid filesystem resize capability information.");
            missing_utility = reply.get_child_value (2).get_string ();
            if (!reply.get_child_value (0).get_boolean ()) return 0;
            uint64 known = FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.OFFLINE_GROW |
                FilesystemResizeMode.ONLINE_SHRINK | FilesystemResizeMode.ONLINE_GROW;
            return (FilesystemResizeMode) (reply.get_child_value (1).get_uint64 () & known);
        }

        public static bool check_available (Variant reply, bool repair = false) throws Error {
            if (!reply.is_of_type (new VariantType ("(bs)")))
                throw new IOError.INVALID_DATA ("UDisks returned invalid filesystem capability information.");
            if (reply.get_child_value (0).get_boolean ()) return true;
            string utility = reply.get_child_value (1).get_string ();
            if (utility != "")
                throw new IOError.NOT_SUPPORTED (("The filesystem %s operation requires %s.").printf (repair ? "repair" : "check", utility));
            return false;
        }
    }
}
