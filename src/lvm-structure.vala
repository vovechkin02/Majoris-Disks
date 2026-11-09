namespace MajorisDisks {
    internal class LvmCacheStatus : Object {
        public string name = "";
        public string uuid = "";
        public string layout = "";
        public string pool_name = "";
        public string pool_uuid = "";
        public string mode = "";
        public string attributes = "";
        public string health = "";
        public string metadata_check = "unknown";
        public uint64 dirty_blocks;
        public uint64 total_blocks;
        public bool usage_known;

        public bool clean () {
            return layout == "cache" && attributes.length == 10 && attributes[4] == 'a' &&
                attributes[8] == '-' && health == "" &&
                (metadata_check == "" || metadata_check == "0" || metadata_check == "no") &&
                usage_known && dirty_blocks == 0 &&
                (mode == "writethrough" || mode == "writeback" || mode == "passthrough");
        }

        private static string? string_field (Json.Object row, string key) {
            var value = row.get_member (key);
            return value != null && value.get_value_type () == typeof (string) ? value.get_string () : null;
        }

        private static unowned Json.Object? object_node (Json.Node? node) {
            return node != null && node.get_node_type () == Json.NodeType.OBJECT ? node.get_object () : null;
        }

        private static unowned Json.Array? array_node (Json.Node? node) {
            return node != null && node.get_node_type () == Json.NodeType.ARRAY ? node.get_array () : null;
        }

        internal static LvmCacheStatus[] parse_report (string report, string vg_uuid) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (report);
            unowned var root = object_node (parser.get_root ());
            unowned var reports = array_node (root?.get_member ("report"));
            var rows = reports != null && reports.get_length () == 1 ?
                array_node (object_node (reports.get_element (0))?.get_member ("lv")) : null;
            if (rows == null || rows.get_length () > 16384)
                throw new IOError.INVALID_DATA ("LVM returned an invalid cache report.");
            var names = new HashTable<string, string> (str_hash, str_equal);
            var volumes = new LvmCacheStatus[rows.get_length ()];
            for (uint i = 0; i < rows.get_length (); i++) {
                unowned var row = object_node (rows.get_element (i));
                if (row == null || string_field (row, "vg_uuid") != vg_uuid)
                    throw new IOError.INVALID_DATA ("The LVM cache report belongs to another volume group.");
                var volume = new LvmCacheStatus ();
                volume.name = (string_field (row, "lv_name") ?? "").delimit ("[]", ' ').strip ();
                volume.uuid = string_field (row, "lv_uuid") ?? "";
                volume.layout = string_field (row, "segtype") ?? "";
                volume.pool_name = (string_field (row, "pool_lv") ?? "").delimit ("[]", ' ').strip ();
                volume.pool_uuid = string_field (row, "pool_lv_uuid") ?? "";
                volume.mode = string_field (row, "cache_mode") ?? "";
                volume.attributes = string_field (row, "lv_attr") ?? "";
                volume.health = string_field (row, "lv_health_status") ?? "unknown";
                volume.metadata_check = string_field (row, "lv_check_needed") ?? "unknown";
                string dirty = string_field (row, "cache_dirty_blocks") ?? "";
                string total = string_field (row, "cache_total_blocks") ?? "";
                volume.usage_known = dirty != "" && total != "" &&
                    uint64.try_parse (dirty, out volume.dirty_blocks) && uint64.try_parse (total, out volume.total_blocks) &&
                    volume.total_blocks != 0 && volume.dirty_blocks <= volume.total_blocks;
                if (volume.name == "" || volume.uuid == "" || names.contains (volume.name))
                    throw new IOError.INVALID_DATA ("LVM returned ambiguous logical-volume identities.");
                names.insert (volume.name, volume.uuid);
                volumes[i] = volume;
            }
            return volumes;
        }

        internal static LvmCacheStatus? find (LvmCacheStatus[] report, string name) {
            foreach (var volume in report)
                if (volume.name == name) return volume;
            return null;
        }
    }

    public class LvmLayout {
        public static uint64 required_per_pv (string layout, uint count, uint64 bytes, uint64 extent) {
            if (extent == 0 || bytes == 0 || bytes % extent != 0 || count > 16) return 0;
            uint stripes;
            bool metadata = true;
            switch (layout) {
            case "linear":
                if (count != 1) return 0;
                return bytes;
            case "raid0":
                if (count < 2) return 0;
                stripes = count;
                metadata = false;
                break;
            case "raid1":
                if (count < 2) return 0;
                stripes = 1;
                break;
            case "raid5":
                if (count < 3) return 0;
                stripes = count - 1;
                break;
            case "raid6":
                if (count < 4) return 0;
                stripes = count - 2;
                break;
            case "raid10":
                if (count < 4 || count % 2 != 0) return 0;
                stripes = count / 2;
                break;
            default:
                return 0;
            }
            if ((bytes / extent) % stripes != 0) return 0;
            uint64 data = bytes / stripes;
            return !metadata ? data : data <= uint64.MAX - extent ? data + extent : 0;
        }
    }

    public enum LvmAllocation {
        UNKNOWN, COMPLETE, INCOMPLETE
    }

    public class LvmPhysicalSegment : Object {
        public uint64 offset { get; private set; }
        public uint64 size { get; private set; }
        public string pv_path { get; private set; }

        internal LvmPhysicalSegment (uint64 offset, uint64 size, string pv_path) {
            this.offset = offset;
            this.size = size;
            this.pv_path = pv_path;
        }
    }

    public class LvmStructure : Object {
        public string name { get; private set; }
        public string layout { get; private set; }
        public uint64 size { get; private set; }
        public LvmPhysicalSegment[] segments = {};
        public LvmStructure[] data = {};
        public LvmStructure[] metadata = {};
        public bool directly_allocated { get; private set; }

        internal static Variant? typed (Variant? value, string signature) {
            return value != null && value.is_of_type (new VariantType (signature)) ? value : null;
        }

        public static LvmStructure? parse (Variant? value) {
            uint budget = 16384;
            return parse_node (value, 0, ref budget);
        }

        private static LvmStructure? parse_node (Variant? value, uint depth, ref uint budget) {
            if (depth >= 32 || budget == 0 || typed (value, "a{sv}") == null) return null;
            budget--;
            var name = value.lookup_value ("name", VariantType.STRING);
            var layout = value.lookup_value ("type", VariantType.STRING);
            var size = value.lookup_value ("size", VariantType.UINT64);
            if (name == null || layout == null || size == null) return null;
            var node = new LvmStructure ();
            node.name = name.get_string ();
            node.layout = layout.get_string ();
            node.size = size.get_uint64 ();
            var segments = value.lookup_value ("segs", null);
            var backend_segments = value.lookup_value ("segments", null);
            if (segments != null && backend_segments != null) return null;
            if (segments == null) segments = backend_segments;
            if (segments != null) {
                if (typed (segments, "a(tto)") == null || segments.n_children () > budget) return null;
                node.directly_allocated = true;
                node.segments = new LvmPhysicalSegment[segments.n_children ()];
                for (size_t i = 0; i < segments.n_children (); i++) {
                    var segment = segments.get_child_value (i);
                    uint64 offset = segment.get_child_value (0).get_uint64 ();
                    uint64 length = segment.get_child_value (1).get_uint64 ();
                    if (length == 0 || length > uint64.MAX - offset) return null;
                    node.segments[i] = new LvmPhysicalSegment (offset, length, segment.get_child_value (2).get_string ());
                    budget--;
                }
            }
            foreach (string field in new string[] { "data", "metadata" }) {
                var children = value.lookup_value (field, null);
                if (children == null) continue;
                if (segments != null || typed (children, "aa{sv}") == null || children.n_children () > budget) return null;
                var components = new LvmStructure[children.n_children ()];
                for (size_t i = 0; i < children.n_children (); i++) {
                    var child = parse_node (children.get_child_value (i), depth + 1, ref budget);
                    if (child == null) return null;
                    components[i] = child;
                }
                if (field == "data") node.data = (owned) components;
                else node.metadata = (owned) components;
            }
            return node;
        }

        public LvmAllocation allocation (StorageSnapshot snapshot, string group_path) {
            if (layout == "error") return LvmAllocation.INCOMPLETE;
            if (directly_allocated) {
                uint64 bytes = 0;
                bool unresolved = false;
                foreach (var segment in segments) {
                    if (segment.size > uint64.MAX - bytes) return LvmAllocation.UNKNOWN;
                    bytes += segment.size;
                    if (segment.pv_path == "/") return LvmAllocation.INCOMPLETE;
                    var pv = snapshot.blocks.lookup (segment.pv_path);
                    if (pv == null || !pv.available || pv.physical_volume_group_path != group_path) unresolved = true;
                }
                if (bytes < size) return LvmAllocation.INCOMPLETE;
                return bytes == size && size > 0 && !unresolved ? LvmAllocation.COMPLETE : LvmAllocation.UNKNOWN;
            }
            bool unknown = data.length == 0;
            foreach (var child in data) {
                var state = child.allocation (snapshot, group_path);
                if (state == LvmAllocation.INCOMPLETE) return state;
                if (state == LvmAllocation.UNKNOWN) unknown = true;
            }
            foreach (var child in metadata) {
                var state = child.allocation (snapshot, group_path);
                if (state == LvmAllocation.INCOMPLETE) return state;
                if (state == LvmAllocation.UNKNOWN) unknown = true;
            }
            if (layout.has_prefix ("raid") && (data.length < 2 ||
                (layout == "raid0" ? metadata.length != 0 : data.length != metadata.length))) unknown = true;
            return unknown ? LvmAllocation.UNKNOWN : LvmAllocation.COMPLETE;
        }

        public bool uses_pv (string path) {
            foreach (var segment in segments)
                if (segment.pv_path == path) return true;
            foreach (var child in data)
                if (child.uses_pv (path)) return true;
            foreach (var child in metadata)
                if (child.uses_pv (path)) return true;
            return false;
        }

        private bool only_on_pv (string path) {
            if (!directly_allocated || segments.length == 0) return false;
            foreach (var segment in segments)
                if (segment.pv_path != path) return false;
            return true;
        }

        public bool verifies_placement (string[] paths) {
            if (layout == "linear") return paths.length == 1 && only_on_pv (paths[0]);
            if (layout == "raid0" && directly_allocated) {
                foreach (var segment in segments)
                    if (!(segment.pv_path in paths)) return false;
                foreach (var path in paths)
                    if (!uses_pv (path)) return false;
                return true;
            }
            bool raid0 = layout == "raid0";
            if (paths.length != data.length || (raid0 ? metadata.length != 0 : metadata.length != data.length))
                return false;
            foreach (var path in paths) {
                int matches = 0;
                for (int i = 0; i < data.length; i++)
                    if (data[i].only_on_pv (path) && (raid0 || metadata[i].only_on_pv (path))) matches++;
                if (matches != 1) return false;
            }
            return true;
        }

        public LvmStructure? cache_pool () {
            if (layout != "cache") return null;
            LvmStructure? pool = null;
            foreach (var child in data) {
                if (child.layout != "cache-pool") continue;
                if (pool != null) return null;
                pool = child;
            }
            return pool;
        }

        public uint64 raid1_replacement_bytes (StorageSnapshot snapshot, string group_path) {
            if (layout != "raid1" || data.length != 2 || metadata.length != 2) return 0;
            int broken = 0;
            uint64 bytes = 0;
            for (int i = 0; i < 2; i++) {
                var image = data[i];
                var meta = metadata[i];
                if (!image.directly_allocated || !meta.directly_allocated || image.size != size ||
                    meta.size == 0 || image.size > uint64.MAX - meta.size) return 0;
                var image_state = image.allocation (snapshot, group_path);
                var meta_state = meta.allocation (snapshot, group_path);
                if (image_state == LvmAllocation.UNKNOWN || meta_state == LvmAllocation.UNKNOWN) return 0;
                if (image_state == LvmAllocation.INCOMPLETE || meta_state == LvmAllocation.INCOMPLETE) {
                    broken++;
                    bytes = image.size + meta.size;
                }
            }
            return broken == 1 ? bytes : 0;
        }

        public string raid1_surviving_pv (StorageSnapshot snapshot, string group_path) {
            if (raid1_replacement_bytes (snapshot, group_path) == 0) return "/";
            for (int i = 0; i < data.length; i++) {
                var image = data[i];
                var meta = metadata[i];
                if (image.allocation (snapshot, group_path) != LvmAllocation.COMPLETE ||
                    meta.allocation (snapshot, group_path) != LvmAllocation.COMPLETE ||
                    image.segments.length == 0) continue;
                string path = image.segments[0].pv_path;
                if (image.only_on_pv (path) && meta.only_on_pv (path)) return path;
            }
            return "/";
        }
    }
}
