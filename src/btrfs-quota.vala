namespace MajorisDisks {
    internal enum BtrfsQuotaMode { UNKNOWN, DISABLED, QGROUP, SIMPLE }

    internal class BtrfsQgroup : Object {
        public uint64 id;
        public uint64 referenced;
        public uint64 exclusive;
        public uint64 flags;
        public uint64 max_referenced;
        public uint64 max_exclusive;
        public bool stale;
        public uint64[] parents = {};
        public uint64[] children = {};
        public uint64 level { get { return id >> 48; } }
        public string name { owned get { return format_id (id); } }

        public static string format_id (uint64 id) {
            return "%s/%s".printf ((id >> 48).to_string (), (id & ((1UL << 48) - 1)).to_string ());
        }

        public static bool parse_id (string text, out uint64 id) {
            id = 0;
            string[] fields = text.split ("/", 3);
            uint64 level = 0, number = 0;
            if (fields.length != 2 || !BtrfsQuotaStatus.parse_limit (fields[0], 1, out level) ||
                !BtrfsQuotaStatus.parse_limit (fields[1], 1, out number) || level > uint16.MAX ||
                number >= (1UL << 48) || format_id ((level << 48) | number) != text)
                return false;
            if (level == 0 && number != 5 && (number < 256 || number > (1UL << 48) - 256)) return false;
            id = (level << 48) | number;
            return true;
        }

        public string limit (bool exclusive_limit) {
            if ((flags & (exclusive_limit ? 2 : 1)) == 0) return "Unlimited";
            return "%s B".printf ((exclusive_limit ? max_exclusive : max_referenced).to_string ());
        }
    }

    internal class BtrfsQuotaStatus : Object {
        public string uuid;
        public BtrfsQuotaMode mode;
        public bool inconsistent;
        public bool running;
        public bool supports_simple;
        public bool writable;
        public uint64 progress;
        public string token;
        public BtrfsQgroup[] groups;
        private HashTable<uint64?, BtrfsQgroup> by_id =
            new HashTable<uint64?, BtrfsQgroup> (int64_hash, int64_equal);

        public BtrfsQuotaStatus (string uuid, string output) throws Error {
            this.uuid = uuid;
            var data = Variant.parse (new VariantType ("(sttbsa(ttttttb)a(tt)b)"), output);
            switch (data.get_child_value (0).get_string ()) {
                case "disabled": mode = BtrfsQuotaMode.DISABLED; break;
                case "qgroup": mode = BtrfsQuotaMode.QGROUP; break;
                case "simple": mode = BtrfsQuotaMode.SIMPLE; break;
                default: throw new IOError.INVALID_DATA ("Unknown Btrfs quota mode.");
            }
            uint64 flags = data.get_child_value (1).get_uint64 ();
            running = (flags & 2) != 0;
            inconsistent = (flags & 4) != 0;
            progress = data.get_child_value (2).get_uint64 ();
            supports_simple = data.get_child_value (3).get_boolean ();
            token = data.get_child_value (4).get_string ();
            var rows = data.get_child_value (5);
            var edges = data.get_child_value (6);
            writable = data.get_child_value (7).get_boolean ();
            if (rows.n_children () > 65536 || edges.n_children () > 32768 || token.length != 64 ||
                (flags & ~15UL) != 0 || ((flags & 1) == 0) != (mode == BtrfsQuotaMode.DISABLED) ||
                ((flags & 8) != 0) != (mode == BtrfsQuotaMode.SIMPLE) ||
                (running && mode != BtrfsQuotaMode.QGROUP) ||
                (mode == BtrfsQuotaMode.DISABLED && (flags != 0 || rows.n_children () != 0)))
                throw new IOError.INVALID_DATA ("Invalid Btrfs quota report.");
            groups = new BtrfsQgroup[(int) rows.n_children ()];
            for (int i = 0; i < groups.length; i++) {
                var row = rows.get_child_value (i);
                var group = new BtrfsQgroup ();
                row.get ("(ttttttb)", out group.id, out group.referenced, out group.exclusive,
                    out group.flags, out group.max_referenced, out group.max_exclusive, out group.stale);
                if (group.id == 0 || by_id.contains (group.id))
                    throw new IOError.INVALID_DATA ("Duplicate or invalid Btrfs qgroup.");
                by_id.insert (group.id, group);
                groups[i] = group;
            }
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            for (size_t i = 0; i < edges.n_children (); i++) {
                uint64 child_id, parent_id;
                edges.get_child_value (i).get ("(tt)", out child_id, out parent_id);
                var child = find (child_id);
                var parent = find (parent_id);
                if (child == null || parent == null || child.level >= parent.level ||
                    !seen.add (child.name + " " + parent.name))
                    throw new IOError.INVALID_DATA ("Invalid Btrfs qgroup relationship.");
                child.parents += parent_id;
                parent.children += child_id;
            }
        }

        public unowned BtrfsQgroup? find (uint64 id) { return by_id.lookup (id); }

        public string mode_label () {
            switch (mode) {
                case BtrfsQuotaMode.QGROUP: return "Traditional qgroups";
                case BtrfsQuotaMode.SIMPLE: return "Simple quotas";
                case BtrfsQuotaMode.DISABLED: return "Quotas disabled";
                default: return "Unknown";
            }
        }

        public string accounting_label () {
            if (running) return (progress == uint64.MAX ? "Rescan finalizing" :
                "Rescan running · kernel extent cursor %s".printf (progress.to_string ())) +
                ". Usage and enforcement may be unreliable.";
            if (inconsistent) return "Accounting inconsistent. Usage and enforcement may be unreliable. Rescan required.";
            if (mode == BtrfsQuotaMode.DISABLED) return "No quota enforcement";
            return "Accounting consistent";
        }

        public static bool parse_limit (string input, uint64 multiplier, out uint64 bytes) {
            bytes = 0;
            uint64 amount = 0;
            string digits = input.strip ();
            if (multiplier == 0 || digits == "" || digits[0] < '0' || digits[0] > '9' ||
                !uint64.try_parse (digits, out amount, null, 10) ||
                amount > (uint64.MAX - 1) / multiplier)
                return false;
            bytes = amount * multiplier;
            return true;
        }
    }
}
