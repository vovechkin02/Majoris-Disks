namespace MajorisDisks {
    public enum MdRaidSyncAction {
        UNKNOWN, IDLE, RECOVER, RESYNC, CHECK, REPAIR, RESHAPE, FROZEN;

        public static MdRaidSyncAction parse (string action) {
            switch (action) {
            case "idle": return IDLE;
            case "recover": return RECOVER;
            case "resync": return RESYNC;
            case "check": return CHECK;
            case "repair": return REPAIR;
            case "reshape": return RESHAPE;
            case "frozen": return FROZEN;
            default: return UNKNOWN;
            }
        }
    }

    internal class MdRaidSuperblock : Object {
        public string uuid;
        public string member_uuid;
        public uint version;
        public int level;
        public uint layout;
        public uint expected;
        public uint slot;
        public uint features;
        public uint64 events;
        public uint64 resync_offset;
        public uint64 component_sectors;

        [CCode (cname = "majoris_mdraid_read_superblock", cheader_filename = "mdraid-superblock.h")]
        private static extern Variant? read_native (int fd);

        public static MdRaidSuperblock? inspect (int fd) {
            var data = read_native (fd);
            if (data == null) return null;
            var result = new MdRaidSuperblock ();
            data.get ("(ssuiuuuuttt)", out result.uuid, out result.member_uuid, out result.version,
                out result.level, out result.layout, out result.expected, out result.slot,
                out result.features, out result.events, out result.resync_offset, out result.component_sectors);
            return result;
        }

        public bool usable () {
            // The bitmap is the only feature supported by the clean assembly workflow.
            return active_member () && resync_offset == uint64.MAX;
        }

        public bool active_member () {
            return (features & ~1U) == 0 && slot < expected && component_sectors > 0 &&
                events > 0 && member_uuid != "00000000:00000000:00000000:00000000";
        }

        public bool same_geometry (MdRaidSuperblock other) {
            return uuid == other.uuid && version == other.version && level == other.level &&
                layout == other.layout && expected == other.expected &&
                component_sectors == other.component_sectors;
        }
    }

    public class MdRaidMember : Object {
        public string path;
        public int slot;
        public string[] states;
        public uint64 read_errors;
        public Variant properties;
        public StorageBlock? block;
        public string metadata_uuid = "";
        public string kernel_identity = "";
        public string array_uuid = "";

        public MdRaidMember (Variant entry) {
            path = entry.get_child_value (0).get_string ();
            slot = entry.get_child_value (1).get_int32 ();
            states = entry.get_child_value (2).dup_strv ();
            read_errors = entry.get_child_value (3).get_uint64 ();
            properties = entry.get_child_value (4);
        }

        public bool synchronized_member () {
            return slot >= 0 && "in_sync" in states && !("faulty" in states) &&
                !("blocked" in states) && !("spare" in states) && !("replacement" in states);
        }

        public bool known_states () {
            foreach (string state in states)
                if (!(state in new string[] { "in_sync", "faulty", "spare", "blocked",
                    "write_mostly", "writemostly", "write_error", "replacement", "want_replacement" }))
                    return false;
            return states.length > 0;
        }

        public string role () {
            if ("faulty" in states) return "Faulty";
            if ("blocked" in states) return "Blocked";
            if (!known_states ()) return "Unknown";
            if (synchronized_member ())
                return "writemostly" in states || "write_mostly" in states ? "Synchronized, write-mostly" : "Synchronized";
            if (slot >= 0) return "Rebuilding";
            if ("spare" in states) return "Spare";
            return "Unassigned";
        }
    }

    public class MdRaidTopology : Object {
        public MdRaidMember[] members = {};
        public int[] missing_slots = {};
        public uint synchronized_count;

        public static MdRaidTopology? parse (Variant? devices, uint expected) {
            if (devices == null || !devices.is_of_type (new VariantType ("a(oiasta{sv})")) ||
                expected == 0 || expected > 4096)
                return null;
            var topology = new MdRaidTopology ();
            var paths = new HashTable<string, string> (str_hash, str_equal);
            var occupied = new bool[expected];
            var synchronized_slots = new bool[expected];
            var members = new MdRaidMember[(int) devices.n_children ()];
            int[] missing_slots = {};
            for (size_t i = 0; i < devices.n_children (); i++) {
                var member = new MdRaidMember (devices.get_child_value (i));
                if (member.path == "/" || paths.contains (member.path) ||
                    member.slot < -1 || member.slot >= (int) expected)
                    return null;
                paths.insert (member.path, member.path);
                if (member.slot >= 0) {
                    if (occupied[member.slot]) return null;
                    occupied[member.slot] = true;
                    if (member.synchronized_member ()) {
                        synchronized_slots[member.slot] = true;
                        topology.synchronized_count++;
                    }
                }
                members[i] = member;
            }
            for (int slot = 0; slot < expected; slot++)
                if (!synchronized_slots[slot]) missing_slots += slot;
            topology.members = members;
            topology.missing_slots = missing_slots;
            return topology;
        }

        public bool can_reconstruct (string level, string layout, uint expected) {
            if (missing_slots.length == 0 || synchronized_count == 0 ||
                missing_slots.length + synchronized_count != expected)
                return false;
            foreach (var member in members)
                if (!member.known_states () || !member.synchronized_member ())
                    return false;
            return recoverable_slots (level, layout, expected, missing_slots);
        }

        internal bool synchronized_slots (uint expected) {
            if (expected == 0 || missing_slots.length != 0 || synchronized_count != expected)
                return false;
            foreach (var member in members)
                if (!member.known_states () || "faulty" in member.states || "blocked" in member.states ||
                    (member.slot >= 0 && !member.synchronized_member ()))
                    return false;
            return true;
        }

        // Used only to attribute an observed operation, never to authorize a write.
        internal string member_evidence () {
            var records = new GenericArray<string> ();
            var uuids = new HashTable<string, string> (str_hash, str_equal);
            var devices = new HashTable<string, string> (str_hash, str_equal);
            foreach (var member in members) {
                if (member.slot < 0 || member.metadata_uuid == "" || member.kernel_identity == "" ||
                    member.array_uuid == "" || uuids.contains (member.metadata_uuid) ||
                    devices.contains (member.kernel_identity)) return "";
                uuids.insert (member.metadata_uuid, member.metadata_uuid);
                devices.insert (member.kernel_identity, member.kernel_identity);
                records.add ("%d %s %s %s".printf (member.slot, member.array_uuid,
                    member.metadata_uuid, member.kernel_identity));
            }
            records.sort ((a, b) => strcmp (a, b));
            return string.joinv ("\n", records.data);
        }

        internal static bool recoverable_slots (string level, string layout, uint expected, int[] missing_slots) {
            if (missing_slots.length == 0 || missing_slots.length >= expected) return false;
            switch (level) {
            case "raid1": return true;
            case "raid4":
            case "raid5": return expected >= 3 && missing_slots.length == 1;
            case "raid6": return expected >= 4 && missing_slots.length <= 2;
            case "raid10":
                // Near=2, far=1 with an even number of slots has adjacent mirror pairs.
                if (layout != "258" || expected < 4 || expected % 2 != 0) return false;
                foreach (int slot in missing_slots)
                    if ((slot ^ 1) in missing_slots) return false;
                return true;
            default: return false;
            }
        }

        internal static bool dirty_degraded_disabled () {
            try {
                string contents;
                FileUtils.get_contents ("/sys/module/md_mod/parameters/start_dirty_degraded", out contents);
                return contents.strip () == "0" || contents.strip () == "N";
            } catch (FileError error) {
                return false;
            }
        }
    }

    public class MdRaidKernelState : Object {
        public string level;
        public string uuid;
        public string layout;
        public string metadata;
        public string state;
        public string action;
        public MdRaidSyncAction sync_action;
        public string bitmap;
        public string policy;
        public string mismatch_count;
        public string sync_limit;
        public uint64 component_sectors;
        public uint64 chunk_bytes;
        public uint64 completed_sectors;
        public uint64 total_sectors;
        public uint64 speed_kib;
        public double progress = -1;
        public int64 observed_at;
        public uint64 expected;
        public string degraded;
        public uint64 number;
        public string identity;
        private File directory;

        private static string read (File directory, string name) {
            try {
                string contents;
                FileUtils.get_contents (directory.resolve_relative_path (name).get_path (), out contents);
                return contents.strip ();
            } catch (FileError error) {
                return "";
            }
        }

        internal static string udev_property (StorageBlock block, string key) {
            var database = File.new_for_path ("/run/udev/data");
            string record = read (database, "b" + KernelStorageSafety.device_number (block.number));
            string prefix = "E:" + key + "=";
            foreach (string line in record.split ("\n"))
                if (line.has_prefix (prefix)) return line.substring (prefix.length);
            return "";
        }

        public bool writable () {
            return state == "clean" || state == "active" || state == "active-idle";
        }

        public bool native_metadata () {
            return metadata == "1.0" || metadata == "1.1" || metadata == "1.2";
        }

        public static string bitmap_kind (string location) {
            if (location == "none") return "none";
            if (location == "file" || location.has_prefix ("/")) return "external";
            int64 offset;
            if (location == "internal" || (int64.try_parse (location, out offset) && offset != 0))
                return "internal";
            return "unknown";
        }

        internal bool matches_uuid (string expected) {
            return same_uuid (uuid, expected);
        }

        internal static bool same_uuid (string left, string right) {
            string compact = right.down ().replace (":", "").replace ("-", "");
            return compact.length == 32 && left.down ().replace (":", "").replace ("-", "") == compact;
        }

        internal bool terminal_health (string array_uuid, string array_level, uint members) {
            return matches_uuid (array_uuid) && level == array_level && expected == members &&
                writable () && action == "idle" && degraded == "0";
        }

        internal static string physical_device (StorageBlock block, out string sector_size) {
            sector_size = "";
            if (block.number == 0) return "";
            string number = KernelStorageSafety.device_number (block.number);
            var link = File.new_for_path ("/sys/dev/block/" + number);
            try {
                var device = link.get_parent ().resolve_relative_path (FileUtils.read_link (link.get_path ()));
                if (read (device, "dev") != number) return "";
                if (read (device, "partition") != "") device = device.get_parent ();
                sector_size = read (device, "queue/logical_block_size");
                string disk = read (device, "dev");
                string sequence = read (device, "diskseq");
                return disk != "" && sequence != "" && sector_size != "" ? disk + ":" + sequence : "";
            } catch (FileError error) {
                return "";
            }
        }

        internal static string sequence_from_identity (string identity) {
            int separator = identity.last_index_of_char (':');
            return separator >= 0 ? identity.substring (separator + 1) : "";
        }

        public bool verify_members (MdRaidTopology topology, string omitted = "") {
            try {
                var children = directory.enumerate_children ("standard::name", FileQueryInfoFlags.NONE);
                var seen = new HashTable<string, string> (str_hash, str_equal);
                FileInfo? info;
                while ((info = children.next_file ()) != null) {
                    if (!info.get_name ().has_prefix ("dev-")) continue;
                    var device = directory.get_child (info.get_name ());
                    string number = read (device, "block/dev");
                    string slot = read (device, "slot");
                    string[] states = read (device, "state").split (",");
                    bool matched = false;
                    foreach (var member in topology.members) {
                        if (member.path == omitted || member.block == null || member.block.number == 0 ||
                            number != KernelStorageSafety.device_number (member.block.number))
                            continue;
                        if (seen.contains (number) || slot != (member.slot < 0 ? "none" : member.slot.to_string ()) ||
                            states.length != member.states.length)
                            return false;
                        foreach (string state in states)
                            if (!(state in member.states)) return false;
                        seen.insert (number, number);
                        matched = true;
                        break;
                    }
                    if (!matched) return false;
                }
                return seen.size () == topology.members.length - (omitted == "" ? 0 : 1);
            } catch (Error error) {
                return false;
            }
        }

        public static MdRaidKernelState? inspect (StorageBlock block) {
            if (!block.available || block.number == 0) return null;
            string number = KernelStorageSafety.device_number (block.number);
            var device = File.new_for_path ("/sys/dev/block/" + number);
            var md = device.get_child ("md");
            string level = read (md, "level");
            string sequence = read (device, "diskseq");
            if (level == "" || sequence == "" || read (device, "dev") != number) return null;
            var result = new MdRaidKernelState ();
            result.directory = md;
            result.number = block.number;
            result.identity = number + ":" + sequence;
            result.level = level;
            result.uuid = read (md, "uuid");
            result.expected = uint64.parse (read (md, "raid_disks"));
            result.degraded = read (md, "degraded");
            result.layout = read (md, "layout");
            result.metadata = read (md, "metadata_version");
            result.state = read (md, "array_state");
            result.action = read (md, "sync_action");
            result.sync_action = MdRaidSyncAction.parse (result.action);
            // The kernel publishes this attribute in KiB.
            result.component_sectors = uint64.parse (read (md, "component_size")) * 2;
            result.chunk_bytes = uint64.parse (read (md, "chunk_size"));
            result.speed_kib = uint64.parse (read (md, "sync_speed"));
            result.sync_limit = read (md, "sync_max");
            result.bitmap = read (md, "bitmap/location");
            result.policy = read (md, "consistency_policy");
            result.mismatch_count = read (md, "mismatch_cnt");
            string[] counts = read (md, "sync_completed").split ("/");
            if (counts.length == 2) {
                result.completed_sectors = uint64.parse (counts[0].strip ());
                result.total_sectors = uint64.parse (counts[1].strip ());
                if (result.total_sectors > 0 && result.completed_sectors <= result.total_sectors)
                    result.progress = (double) result.completed_sectors / result.total_sectors;
            }
            if (read (device, "diskseq") != sequence || read (device, "dev") != number) return null;
            result.observed_at = get_monotonic_time ();
            return result;
        }
    }
}
