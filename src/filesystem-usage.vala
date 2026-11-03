namespace MajorisDisks {
    public class FilesystemUsageService : Object {
        private HashTable<string, string> values = new HashTable<string, string> (str_hash, str_equal);
        private string? key;
        private Cancellable? pending;
        public signal void updated (string description);

        public void clear () {
            pending?.cancel ();
            pending = null;
            key = null;
            values.remove_all ();
        }

        public string show (StorageBlock block) {
            var fs = block.filesystem;
            if (fs == null || !fs.mounted) {
                clear ();
                return "Used space unavailable";
            }
            string identity = block.path + "\n" + block.uuid + "\n" + string.joinv ("\n", fs.mounts);
            if (key != identity) {
                clear ();
                key = identity;
                pending = new Cancellable ();
                query.begin (identity, fs.mounts[0], pending);
            }
            return values.lookup (identity) ?? "Used space unavailable";
        }

        private async void query (string identity, string path, Cancellable token) {
            try {
                var info = yield File.new_for_path (path).query_filesystem_info_async (
                    "filesystem::size,filesystem::used,filesystem::free", Priority.DEFAULT, token);
                if (token.is_cancelled () || key != identity) return;
                if (!info.has_attribute (FileAttribute.FILESYSTEM_SIZE) ||
                    !info.has_attribute (FileAttribute.FILESYSTEM_USED) ||
                    !info.has_attribute (FileAttribute.FILESYSTEM_FREE)) return;
                uint64 total = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_SIZE);
                uint64 used = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_USED);
                uint64 free = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE);
                if (total == 0 || used > total || free > total) return;
                string description = "%s total · %s used (%.0f%%) · %s available".printf (
                    format_size (total), format_size (used), 100.0 * used / total, format_size (free));
                values.insert (identity, description);
                updated (description);
            } catch (Error error) {
                if (!token.is_cancelled ()) debug ("Filesystem usage unavailable: %s", error.message);
            }
        }
    }
}
