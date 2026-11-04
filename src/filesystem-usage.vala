namespace MajorisDisks {
    public class FilesystemUsageService : Object {
        private const int CACHE_LIMIT = 32;
        private const uint REFRESH_SECONDS = 15;
        private class Usage : Object {
            public string description;
            public string path;
            public int64 recorded;
            public Usage (string path, string description) {
                this.path = path; this.description = description;
                recorded = get_monotonic_time ();
            }
        }
        private HashTable<string, Usage> values = new HashTable<string, Usage> (str_hash, str_equal);
        private string? key;
        private Cancellable? pending;
        private uint refresh_source;
        private string selected_path = "";
        public signal void updated (string description);

        public void clear () {
            pending?.cancel ();
            pending = null;
            key = null;
            selected_path = "";
            if (refresh_source != 0) {
                Source.remove (refresh_source);
                refresh_source = 0;
            }
        }

        public string show (StorageBlock block) {
            var fs = block.filesystem;
            if (fs == null || !fs.mounted) {
                clear ();
                return "Used space unavailable";
            }
            string identity = new Variant ("(ssstt@as)", block.path, block.uuid, block.type_id,
                block.number, block.size, new Variant.strv (fs.mounts)).print (false);
            if (key != identity) {
                clear ();
                selected_path = block.path;
                key = identity;
                string mount = fs.mounts[0];
                if (cached (identity) == null) refresh (identity, mount);
                refresh_source = Timeout.add_seconds (REFRESH_SECONDS, () => {
                    refresh (identity, mount);
                    return Source.CONTINUE;
                });
            } else selected_path = block.path;
            return cached (identity)?.description ?? "Used space unavailable";
        }

        private Usage? cached (string identity) {
            var usage = values.lookup (identity);
            if (usage != null && get_monotonic_time () - usage.recorded > 2 * REFRESH_SECONDS * TimeSpan.SECOND) {
                values.remove (identity);
                return null;
            }
            return usage;
        }

        private void refresh (string identity, string mount) {
            if (pending != null) return;
            pending = new Cancellable ();
            query.begin (identity, selected_path, mount, pending);
        }

        public void invalidate (string path) {
            bool selected = selected_path == path;
            foreach (var identity in values.get_keys ()) if (values.lookup (identity).path == path) values.remove (identity);
            if (selected) clear ();
        }

        private async void query (string identity, string block_path, string path, Cancellable token) {
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
                if (values.size () >= CACHE_LIMIT && !values.contains (identity)) {
                    string? oldest = null;
                    int64 recorded = int64.MAX;
                    foreach (var candidate in values.get_keys ()) {
                        var entry = values.lookup (candidate);
                        if (entry.recorded >= recorded) continue;
                        oldest = candidate;
                        recorded = entry.recorded;
                    }
                    if (oldest != null) values.remove (oldest);
                }
                values.insert (identity, new Usage (block_path, description));
                if (key == identity && !token.is_cancelled ()) updated (description);
            } catch (Error error) {
                if (!token.is_cancelled ()) debug ("Filesystem usage unavailable: %s", error.message);
            } finally {
                if (pending == token) {
                    pending = null;
                    if (key == identity && cached (identity) == null) updated ("Used space unavailable");
                }
            }
        }
    }
}
