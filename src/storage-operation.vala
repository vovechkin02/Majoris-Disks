namespace MajorisDisks {
    public class StorageSelftestReconciliation {
        public static bool can_attribute_terminal_state (bool running_observed, string status) {
            // A terminal status can describe a previous test. SmartUpdated only dates a refresh.
            return running_observed && status != "" && status != "unknown" && status != "inprogress";
        }
    }

    public enum MountVisibility { DEFAULT, SHOW, HIDE }

    public class MountOptionService {
        internal static bool valid_crypttab_name (string name) {
            return name.length <= 127 && Regex.match_simple ("^[A-Za-z0-9_+.-]+\\z", name) &&
                name != "." && name != ".." && name != "control";
        }

        internal static bool external_crypttab_options (string input) {
            foreach (var raw in input.split (",")) {
                string option = raw.strip ();
                if (option.has_prefix ("fido2-") || option.has_prefix ("tpm2-") ||
                    option.has_prefix ("pkcs11-") || option.has_prefix ("keyscript=") ||
                    option.has_prefix ("header=") || option == "plain" || option == "tcrypt" ||
                    option == "bitlk" || option == "swap" || option == "tmp" ||
                    option.has_prefix ("tmp=") || option == "x-initrd.attach" || option == "initramfs" ||
                    option.has_prefix ("key-slot=") || option.has_prefix ("keyfile-offset=") ||
                    option.has_prefix ("keyfile-size=")) return true;
            }
            return false;
        }

        internal static bool manages_crypttab_keyfile (string path) {
            string name = Path.get_basename (path);
            return Path.get_dirname (path) == "/etc/luks-keys" && valid_crypttab_name (name) &&
                Filename.canonicalize (path) == path;
        }

        private static bool contains (string[] values, string value) {
            foreach (var candidate in values) if (candidate == value) return true;
            return false;
        }

        public static string escape_value (string value) throws Error {
            if (value.contains ("\n") || value.contains ("\r"))
                throw new IOError.INVALID_ARGUMENT ("The display name contains an invalid control character.");
            return value.replace ("\\", "\\134").replace (",", "\\054")
                .replace (" ", "\\040").replace ("\t", "\\011");
        }

        public static string unescape_value (string value) {
            return value.replace ("\\011", "\t").replace ("\\040", " ")
                .replace ("\\054", ",").replace ("\\134", "\\");
        }

        public static string[] parse (string input) throws Error {
            string[] result = {};
            foreach (var raw in input.split (",")) {
                string option = raw.strip ();
                if (option == "") throw new IOError.INVALID_ARGUMENT ("Mount options cannot contain empty entries.");
                if (option.contains ("\n") || option.contains ("\r"))
                    throw new IOError.INVALID_ARGUMENT ("A mount option contains an invalid control character.");
                if (contains (result, option))
                    throw new IOError.INVALID_ARGUMENT ("The mount option ‘%s’ is duplicated.".printf (option));
                result += option;
            }
            string[,] conflicts = { { "ro", "rw" }, { "dev", "nodev" }, { "suid", "nosuid" },
                { "exec", "noexec" }, { "auto", "noauto" }, { "user", "nouser" },
                { "x-gvfs-show", "x-gvfs-hide" } };
            for (int i = 0; i < conflicts.length[0]; i++)
                if (contains (result, conflicts[i, 0]) && contains (result, conflicts[i, 1]))
                    throw new IOError.INVALID_ARGUMENT ("Conflicting mount options ‘%s’ and ‘%s’ were specified."
                        .printf (conflicts[i, 0], conflicts[i, 1]));
            return result;
        }

        public static string normalize (string input, bool startup) throws Error {
            string[] result = {};
            foreach (var option in parse (input.strip () == "" ? "defaults" : input))
                if (option != "noauto" && option != "auto") result += option;
            if (result.length == 0) result += "defaults";
            if (!startup) result += "noauto";
            return string.joinv (",", result);
        }

        public static string normalize_encryption (string input, bool startup, string existing = "") throws Error {
            string[] result = {};
            string[] names = {};
            if (input.strip () != "") {
                foreach (var option in parse (input)) {
                    string name = option.split ("=", 2)[0];
                    bool supported = contains ({ "auto", "noauto", "luks", "nofail", "discard",
                        "readonly", "read-only", "headless", "_netdev", "try-empty-password" }, option) ||
                        Regex.match_simple ("^(x-systemd.device-timeout|keyfile-timeout|timeout)=[0-9]+(ms|s|min|h)?\\z", option) ||
                        Regex.match_simple ("^tries=[0-9]+\\z", option);
                    bool inherited = contains (existing.split (","), option);
                    if ((!supported && !inherited) || external_crypttab_options (option) ||
                        Regex.match_simple ("[[:cntrl:][:space:]]", option))
                        throw new IOError.INVALID_ARGUMENT ("The option ‘%s’ cannot be edited here.".printf (name));
                    if (contains (names, name) && !name.has_prefix ("x-parent"))
                        throw new IOError.INVALID_ARGUMENT ("The option ‘%s’ is specified more than once.".printf (name));
                    names += name;
                    if (option != "auto" && option != "noauto") result += option;
                }
            }
            if (contains (names, "readonly") && contains (names, "read-only"))
                throw new IOError.INVALID_ARGUMENT ("Specify the read-only option only once.");
            if (!startup) result += "noauto";
            return string.joinv (",", result);
        }

        public static string display_name (string input) {
            try {
                foreach (var option in parse (input))
                    if (option.has_prefix ("x-gvfs-name="))
                        return unescape_value (option.substring ("x-gvfs-name=".length));
            } catch (Error error) {}
            return "";
        }

        public static MountVisibility visibility (string input) {
            try {
                foreach (var option in parse (input)) {
                    if (option == "x-gvfs-show") return MountVisibility.SHOW;
                    if (option == "x-gvfs-hide") return MountVisibility.HIDE;
                }
            } catch (Error error) {}
            return MountVisibility.DEFAULT;
        }

        public static string compose (string input, string display_name,
            MountVisibility visibility) throws Error {
            string[] result = {};
            foreach (var option in parse (input.strip () == "" ? "defaults" : input))
                if (!option.has_prefix ("x-gvfs-name=") && option != "x-gvfs-show" && option != "x-gvfs-hide")
                    result += option;
            string name = display_name.strip ();
            if (name != "") result += "x-gvfs-name=" + escape_value (name);
            if (visibility == MountVisibility.SHOW) result += "x-gvfs-show";
            else if (visibility == MountVisibility.HIDE) result += "x-gvfs-hide";
            return string.joinv (",", result);
        }

        public static void validate_configuration (string directory, string filesystem,
            string options) throws Error {
            if (!Path.is_absolute (directory) || directory == "/" || directory.contains ("//") ||
                directory.contains ("\n") || directory.contains ("\r"))
                throw new IOError.INVALID_ARGUMENT ("Choose an absolute, non-root mount point.");
            foreach (var component in directory.split ("/"))
                if (component == "." || component == "..")
                    throw new IOError.INVALID_ARGUMENT ("The mount point cannot contain ‘.’ or ‘..’ components.");
            string[] protected_paths = { "/boot", "/usr", "/etc", "/var", "/home" };
            foreach (var protected_path in protected_paths)
                if (directory == protected_path)
                    throw new IOError.PERMISSION_DENIED ("This system-critical mount point cannot be managed here.");
            string type = filesystem.strip ().down ();
            if (type == "" || type.contains (",") || type.contains ("/") || type.contains (" "))
                throw new IOError.INVALID_ARGUMENT ("The filesystem type is invalid.");
            foreach (var option in parse (options.strip () == "" ? "defaults" : options)) {
                string name = option.split ("=")[0];
                if (name == "" || name.contains (" ") || name.contains ("/") || name.contains ("\\"))
                    throw new IOError.INVALID_ARGUMENT ("The mount option ‘%s’ is invalid.".printf (option));
                if ((name == "subvol" || name == "subvolid" || name == "compress" || name == "compress-force") &&
                    type != "btrfs")
                    throw new IOError.INVALID_ARGUMENT ("The option ‘%s’ is only valid for Btrfs.".printf (name));
                if ((name == "uid" || name == "gid" || name == "umask" || name == "dmask" || name == "fmask") &&
                    !(type == "vfat" || type == "exfat" || type == "ntfs" || type == "ntfs3" || type == "auto"))
                    throw new IOError.INVALID_ARGUMENT ("The option ‘%s’ is not compatible with %s.".printf (name, type));
            }
        }
    }

    public enum StoragePreparationKind { MOUNT, SWAP, ENCRYPTED_MAPPING, LOGICAL_VOLUME, RAID }

    public enum MountRestorationStatus { FULLY_RESTORED, PARTIALLY_RESTORED, NOT_RESTORED, UNSAFE_TO_RESTORE, UNKNOWN }

    public class StoragePreparationEntry : Object {
        private GenericArray<string> state_values = new GenericArray<string> ();
        public StoragePreparationKind kind { get; construct; }
        public string object_path { get; construct; }
        public string operation_type { get; construct; }
        public bool prepared { get; set; }
        public bool action_dispatched { get; set; }
        public bool backend_confirmed { get; set; }
        public bool expected_state_observed { get; set; }
        public string actual_state { get; set; default = "unknown"; }
        public bool destructive_change { get; set; }
        public bool restoration_allowed { get; set; default = true; }
        public bool restored { get; set; }
        public bool persistent_mount { get; set; }
        private Variant[] persistent_mount_configurations = {};
        public string device_identity = "";
        public string[] observed_mount_points = {};
        internal string mount_namespace = "";
        internal KernelMountRecord[] mount_topology = {};
        internal string encrypted_backing_path = "";
        internal string encrypted_backing_identity = "";
        internal string encrypted_backing_uuid = "";
        public MountRestorationStatus mount_restoration = MountRestorationStatus.UNKNOWN;
        public string error { get; set; default = ""; }
        public StoragePreparationEntry (StoragePreparationKind kind, string object_path, string[] state,
            string operation_type = "prepare") {
            Object (kind: kind, object_path: object_path, operation_type: operation_type);
            foreach (var item in state) state_values.add (item.dup ());
        }

        internal void capture_mount_configuration (StorageMountConfiguration[] configurations) {
            persistent_mount_configurations = {};
            persistent_mount = false;
            foreach (var configuration in configurations) {
                if (configuration.backend_item != null)
                    persistent_mount_configurations += configuration.backend_item;
                for (uint i = 0; i < mount_point_count (); i++)
                    if (mount_point_at (i) == configuration.directory) persistent_mount = true;
            }
        }

        internal bool mount_configuration_matches (StorageMountConfiguration[] configurations) {
            if (configurations.length != persistent_mount_configurations.length) return false;
            var matched = new bool[configurations.length];
            foreach (var current in configurations) {
                if (current.backend_item == null) return false;
                int found = -1;
                for (int i = 0; i < persistent_mount_configurations.length; i++) {
                    if (!matched[i] && persistent_mount_configurations[i].equal (current.backend_item)) {
                        found = i;
                        break;
                    }
                }
                if (found < 0) return false;
                matched[found] = true;
            }
            return true;
        }

        public uint state_length () { return state_values.length; }
        public string state_at (uint index) { return state_values[index]; }

        internal bool matches_prepared_device (StorageBlock block) {
            return block.available && block.path == object_path && state_length () >= 2 &&
                block.uuid == state_at (0) && block.type_id == state_at (1) &&
                device_identity == StoragePreparationJournal.device_identity (block);
        }

        public uint mount_point_count () {
            return kind == StoragePreparationKind.MOUNT && state_values.length > 2 ? state_values.length - 2 : 0;
        }
        public string mount_point_at (uint index) { return state_values[index + 2]; }
        public void record_mount_restoration (string[]? actual_mounts) {
            observed_mount_points = actual_mounts ?? new string[0];
            restored = actual_mounts != null && mount_set_matches (actual_mounts);
            if (restored) mount_restoration = MountRestorationStatus.FULLY_RESTORED;
            else if (!restoration_allowed) mount_restoration = MountRestorationStatus.UNSAFE_TO_RESTORE;
            else if (actual_mounts == null) mount_restoration = MountRestorationStatus.UNKNOWN;
            else {
                mount_restoration = MountRestorationStatus.NOT_RESTORED;
                foreach (var point in actual_mounts)
                    for (uint i = 0; i < mount_point_count (); i++)
                        if (point == mount_point_at (i)) mount_restoration = MountRestorationStatus.PARTIALLY_RESTORED;
            }
        }

        public bool mount_set_matches (string[] actual_mounts) {
            if (kind != StoragePreparationKind.MOUNT || mount_point_count () != actual_mounts.length) return false;
            var matched = new bool[actual_mounts.length];
            for (uint i = 0; i < mount_point_count (); i++) {
                bool found = false;
                for (int j = 0; j < actual_mounts.length; j++) {
                    if (!matched[j] && actual_mounts[j] == mount_point_at (i)) {
                        matched[j] = true;
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return actual_mounts.length != 0;
        }
    }

    public class StoragePreparationJournal : Object {
        private GenericArray<StoragePreparationEntry> records = new GenericArray<StoragePreparationEntry> ();
        public string original_device_identity = "";
        public string original_filesystem_identity = "";
        public string original_partition_geometry = "";
        public string[] original_mount_points = {};
        public bool original_mounted;
        public bool original_swap_active;
        public string destructive_result = "not-dispatched";
        public string restoration_eligibility = "unassessed";
        public bool operation_started;
        public bool operation_completed;
        public bool backend_invoked;
        public bool backend_returned;
        public bool storage_state_changed;
        public bool identity_changed;
        public bool original_state_valid = true;
        public bool restoration_attempted;
        public bool restoration_succeeded;

        public void add (StoragePreparationEntry entry) { records.add (entry); }
        public StoragePreparationEntry[] entries () {
            StoragePreparationEntry[] result = {};
            for (uint i = 0; i < records.length; i++) result += records[i];
            return result;
        }
        public StoragePreparationEntry[] restoration_order () {
            StoragePreparationEntry[] result = {};
            for (int i = (int) records.length - 1; i >= 0; i--)
                if (records[(uint) i].prepared && records[(uint) i].restoration_allowed) result += records[(uint) i];
            return result;
        }
        public bool fully_restored () {
            foreach (var entry in entries ()) if (entry.prepared && !entry.restored) return false;
            return true;
        }

        public string recovery_details () {
            string[] details = {};
            foreach (var entry in entries ()) {
                if (!entry.prepared || entry.restored) continue;
                string previous = entry.kind == StoragePreparationKind.SWAP ? "active swap" : "active";
                if (entry.kind == StoragePreparationKind.MOUNT) {
                    previous = "mounted";
                    if (entry.mount_point_count () != 0) {
                        previous = "mounted at " + entry.mount_point_at (0);
                        for (uint i = 1; i < entry.mount_point_count (); i++)
                            previous += ", " + entry.mount_point_at (i);
                    }
                }
                string reason = entry.error == null || entry.error == "" ?
                    (entry.restoration_allowed ? "restoration has not completed" : "automatic restoration was withheld") : entry.error;
                details += "%s was previously %s; current state: %s; %s".printf (
                    entry.object_path, previous, entry.actual_state, reason);
                if (entry.kind == StoragePreparationKind.MOUNT &&
                    (entry.mount_restoration == MountRestorationStatus.PARTIALLY_RESTORED ||
                     entry.mount_restoration == MountRestorationStatus.NOT_RESTORED)) {
                    string[] missing = {};
                    for (uint i = 0; i < entry.mount_point_count (); i++) {
                        string point = entry.mount_point_at (i);
                        if (!(point in entry.observed_mount_points)) missing += point;
                    }
                    if (missing.length != 0) details += "Missing mount locations: " + string.joinv (", ", missing);
                }
            }
            return string.joinv ("\n", details);
        }

        internal static string device_identity (StorageBlock block) {
            return new Variant ("(ssssssst)", block.path, block.device, block.preferred,
                block.physical_drive?.serial ?? "", block.physical_drive?.wwn ?? "",
                block.backing_path, block.partition?.table_path ?? "", block.number).print (false);
        }

        public void capture (StorageBlock block) {
            original_device_identity = device_identity (block);
            original_filesystem_identity = new Variant ("(sss)", block.path, block.uuid, block.type_id).print (false);
            original_partition_geometry = block.partition == null ? "" :
                new Variant ("(sttt)", block.partition.table_path, block.partition.offset,
                    block.size, block.number).print (false);
            original_mount_points = block.filesystem?.mounts ?? new string[0];
            original_mounted = block.filesystem?.mounted ?? false;
            original_swap_active = block.swap_active;
        }
    }

    internal class ThinPoolUsage : Object {
        public const double WARNING_RATIO = 0.90;
        public uint64 physical_size;
        public uint64 virtual_size;
        public bool virtual_known = true;
        public double data_ratio;
        public double metadata_ratio;
        public bool usage_known;
        public bool active;

        public ThinPoolUsage (StorageSnapshot snapshot, StorageLogicalVolume pool) {
            physical_size = pool.size;
            active = pool.active && pool.lvm_type == "pool";
            data_ratio = pool.data_allocated_ratio;
            metadata_ratio = pool.metadata_allocated_ratio;
            usage_known = physical_size > 0 && data_ratio >= 0 && data_ratio <= 1 &&
                metadata_ratio >= 0 && metadata_ratio <= 1;
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv == null || lv.thin_pool_path != pool.path) continue;
                if (lv.size == 0 || lv.size > uint64.MAX - virtual_size) {
                    virtual_known = false;
                    break;
                }
                virtual_size += lv.size;
            }
        }

        public bool can_provision () {
            return active && usage_known && virtual_known && data_ratio < 1 && metadata_ratio < 1;
        }

        public bool can_shrink () {
            return active && usage_known && metadata_ratio < 1;
        }

        public uint64 virtual_limit () {
            return can_provision () ? uint64.MAX - virtual_size : 0;
        }

        public bool overcommits (uint64 additional) {
            return !virtual_known || additional > uint64.MAX - virtual_size ||
                virtual_size + additional > physical_size;
        }

        public uint64 estimated_data_remaining () {
            if (!usage_known || data_ratio >= 1) return 0;
            if (data_ratio == 0) return physical_size;
            double remaining = (double) physical_size * (1.0 - data_ratio);
            return remaining >= (double) physical_size ? physical_size : (uint64) remaining;
        }

        public double overcommit_ratio () {
            return physical_size == 0 || !virtual_known ? -1.0 : (double) virtual_size / (double) physical_size;
        }
    }

    internal class LvmCapacity {
        public static bool parse (string input, uint64 unit, uint64 extent, uint64 free, out uint64 bytes) {
            bytes = 0;
            if (unit == 0 || extent == 0) return false;
            var parts = input.strip ().split (".", 3);
            uint64 whole = 0, fraction = 0, denominator = 1;
            if (parts.length > 2 || !decimal_digits (parts[0], out whole) || whole > uint64.MAX / unit)
                return false;
            if (parts.length == 2) {
                if (parts[1].length > 12 || !decimal_digits (parts[1], out fraction))
                    return false;
                for (int i = 0; i < parts[1].length; i++) denominator *= 10;
            }
            uint64 divisor = denominator, remainder = unit % denominator;
            while (remainder != 0) {
                uint64 next = divisor % remainder;
                divisor = remainder;
                remainder = next;
            }
            uint64 reduced_denominator = denominator / divisor;
            if (fraction % reduced_denominator != 0)
                return false;
            uint64 fractional_bytes = (fraction / reduced_denominator) * (unit / divisor);
            uint64 whole_bytes = whole * unit;
            if (fractional_bytes > uint64.MAX - whole_bytes)
                return false;
            bytes = whole_bytes + fractional_bytes;
            return bytes > 0 && bytes <= free && bytes % extent == 0;
        }

        private static bool decimal_digits (string text, out uint64 number) {
            number = 0;
            if (text == "") return false;
            for (int i = 0; i < text.length; i++) {
                if (text[i] < '0' || text[i] > '9') return false;
                uint digit = text[i] - '0';
                if (number > (uint64.MAX - digit) / 10) return false;
                number = number * 10 + digit;
            }
            return true;
        }
    }

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

        public void acquire_members (StorageBlock target, StorageBlock[] members, StorageDependencyService graph) throws Error {
            var requested = footprint (target, graph);
            foreach (var member in members) {
                var member_paths = footprint (member, graph);
                foreach (var path in member_paths.get_keys ())
                    requested.insert (path, path);
            }
            foreach (var running in active.get_values ())
                foreach (var path in requested.get_keys ())
                    if (running.contains (path))
                        throw new IOError.BUSY ("Another storage operation is using a member device.");
            active.insert (target.path, requested);
        }

        public void release (StorageBlock target) {
            active.remove (target.path);
        }

        public void acquire_path (string path) throws Error {
            foreach (var running in active.get_values ())
                if (running.contains (path))
                    throw new IOError.BUSY ("Another storage operation is using this device.");
            var footprint = new HashTable<string, string> (str_hash, str_equal);
            footprint.insert (path, path);
            active.insert (path, footprint);
        }

        public void release_path (string path) {
            active.remove (path);
        }
    }

    [Flags]
    public enum FilesystemResizeMode {
        OFFLINE_SHRINK = 1 << 1,
        OFFLINE_GROW = 1 << 2,
        ONLINE_SHRINK = 1 << 3,
        ONLINE_GROW = 1 << 4
    }

    public struct FilesystemCapability {
        public bool supported;
        public string missing_utility;
        public FilesystemResizeMode modes;
        public string reason;

        public bool online_grow { get { return (modes & FilesystemResizeMode.ONLINE_GROW) != 0; } }
        public bool offline_grow { get { return (modes & FilesystemResizeMode.OFFLINE_GROW) != 0; } }
        public bool online_shrink { get { return (modes & FilesystemResizeMode.ONLINE_SHRINK) != 0; } }
        public bool offline_shrink { get { return (modes & FilesystemResizeMode.OFFLINE_SHRINK) != 0; } }
    }

    public class FilesystemCapabilityService {
        public static FilesystemCapability decode (Variant reply, bool resize = false) throws Error {
            if (!reply.is_of_type (new VariantType (resize ? "((bts))" : "((bs))")))
                throw new IOError.INVALID_DATA ("UDisks returned invalid filesystem capability information.");

            var output = reply.get_child_value (0);
            FilesystemCapability capability = {};
            capability.supported = output.get_child_value (0).get_boolean ();
            capability.missing_utility = output.get_child_value (resize ? 2 : 1).get_string ();
            if (resize && capability.supported) {
                uint64 known = FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.OFFLINE_GROW |
                    FilesystemResizeMode.ONLINE_SHRINK | FilesystemResizeMode.ONLINE_GROW;
                capability.modes = (FilesystemResizeMode) (output.get_child_value (1).get_uint64 () & known);
            }
            if (!capability.supported)
                capability.reason = capability.missing_utility == "" ? "The UDisks backend does not support this operation." :
                    "The required utility is not installed: " + capability.missing_utility;
            else if (resize && capability.modes == 0)
                capability.reason = "The filesystem has no supported resize mode.";
            else capability.reason = "";
            return capability;
        }

        public static FilesystemResizeMode resize_modes (Variant reply, out string missing_utility) throws Error {
            var capability = decode (reply, true);
            missing_utility = capability.missing_utility;
            return capability.modes;
        }

        public static bool check_available (Variant reply, bool repair = false) throws Error {
            var capability = decode (reply);
            if (!capability.supported && capability.missing_utility != "")
                throw new IOError.NOT_SUPPORTED (("The filesystem %s operation requires %s.").printf (
                    repair ? "repair" : "check", capability.missing_utility));
            return capability.supported;
        }

        public static bool supports_label (string type) {
            switch (type.down ()) {
                case "ext2": case "ext3": case "ext4": case "btrfs": case "xfs":
                case "f2fs": case "ntfs": case "vfat": case "exfat": case "udf":
                    return true;
                default:
                    return false;
            }
        }

        public static void validate_label (string type, string label) throws Error {
            if (!label.validate () || label.contains ("\n") || label.contains ("/"))
                throw new IOError.INVALID_ARGUMENT ("The volume label contains unsupported characters.");
            int bytes = label.length;
            int characters = label.char_count ();
            switch (type.down ()) {
                case "ext2": case "ext3": case "ext4":
                    if (bytes > 16) throw new IOError.INVALID_ARGUMENT ("Ext filesystems use labels of at most 16 bytes.");
                    break;
                case "xfs":
                    if (bytes > 12) throw new IOError.INVALID_ARGUMENT ("XFS labels are limited to 12 bytes.");
                    break;
                case "btrfs":
                    if (bytes > 255) throw new IOError.INVALID_ARGUMENT ("Btrfs labels are limited to 255 bytes.");
                    break;
                case "f2fs":
                    if (characters > 512) throw new IOError.INVALID_ARGUMENT ("F2FS labels are limited to 512 characters.");
                    break;
                case "vfat":
                    if (characters > 11 || label != label.up () || label.contains ("+") || label.contains (",") ||
                        label.contains (";") || label.contains ("=") || label.contains ("[") || label.contains ("]"))
                        throw new IOError.INVALID_ARGUMENT ("FAT labels use at most 11 upper-case characters.");
                    break;
                case "exfat": case "ntfs":
                    if (characters > 32) throw new IOError.INVALID_ARGUMENT ("This filesystem uses labels of at most 32 characters.");
                    break;
                case "udf":
                    if (bytes > 126) throw new IOError.INVALID_ARGUMENT ("UDF labels are limited to 126 bytes.");
                    break;
                default:
                    if (label != "") throw new IOError.NOT_SUPPORTED ("This filesystem does not support volume labels.");
                    break;
            }
        }
    }

    public enum StorageJobState {
        PENDING, PREPARING, RUNNING, CANCELLING, FINALIZING, COMPLETED, FAILED, CANCELLED,
        PARTIALLY_COMPLETED, NEEDS_ATTENTION
    }

    public enum StorageOperationStatus { SUCCEEDED, FAILED, CANCELLED, PARTIAL, NEEDS_ATTENTION }

    public class StorageOperationResult : Object {
        public bool successful;
        public bool partial;
        public StorageOperationStatus status = StorageOperationStatus.FAILED;
        public string summary = "";
        public string technical_error = "";
        public string resulting_path = "";
        public string failed_step = "";
        public string actual_state = "";
        public bool restoration_attempted;
        public bool restoration_succeeded;
        public string[] completed_steps = {};

        public void completed (string step) {
            string[] updated = new string[completed_steps.length + 1];
            for (int i = 0; i < completed_steps.length; i++) updated[i] = completed_steps[i];
            updated[completed_steps.length] = step;
            completed_steps = updated;
        }
        public void fail (string message, Error? error = null) {
            successful = false;
            partial = completed_steps.length != 0;
            if (error != null && error is IOError.CANCELLED) status = StorageOperationStatus.CANCELLED;
            else status = partial ? StorageOperationStatus.PARTIAL : StorageOperationStatus.FAILED;
            summary = message;
            failed_step = message;
            technical_error = error?.message ?? "";
        }
    }

    internal enum BackendJobExpectation { NONE, DISPATCHED, OBSERVING, MATCHED, EXPIRED }

    public class StorageJob : Object {
        public string id { get; construct; }
        public string operation { get; construct; }
        public string target { get; construct; }
        public string[] affected { get; construct; }
        public int64 start_time { get; construct; }
        public string phase { get; set; default = "Waiting"; }
        public StorageJobState state { get; set; default = StorageJobState.PENDING; }
        public double progress { get; set; default = 0.0; }
        public bool progress_valid { get; set; default = false; }
        public bool cancelable { get; set; default = false; }
        public string backend_path { get; set; default = ""; }
        public bool local { get; set; default = false; }
        public string expected_backend_operation { get; set; default = ""; }
        public string expected_backend_object { get; set; default = ""; }
        public uint64 backend_dispatch_sequence { get; set; default = 0; }
        public int64 backend_dispatch_time { get; set; default = 0; }
        internal BackendJobExpectation backend_expectation;
        internal int64 backend_observation_deadline;
        internal int64 backend_method_return_time;
        public bool backend_completed { get; set; default = false; }
        public bool backend_successful { get; set; default = false; }
        public bool initiating_method_completed { get; set; default = false; }
        public string error_message { get; set; default = ""; }
        public StorageOperationResult? result { get; set; }
        public Cancellable cancellable { get; private set; default = new Cancellable (); }

        public StorageJob (string id, string operation, string target, string[] affected) {
            Object (id: id, operation: operation, target: target, affected: affected,
                start_time: get_real_time ());
        }
    }

    public class StorageJobManager : Object {
        private const uint RETENTION_LIMIT = 50;
        public ListStore jobs { get; private set; default = new ListStore (typeof (StorageJob)); }
        private uint64 serial;
        private uint64 dispatch_serial;
        public signal void changed ();
        public static bool terminal (StorageJobState state) {
            return state == StorageJobState.COMPLETED || state == StorageJobState.FAILED ||
                state == StorageJobState.CANCELLED || state == StorageJobState.PARTIALLY_COMPLETED ||
                state == StorageJobState.NEEDS_ATTENTION;
        }
        public uint active_count () {
            uint count = 0;
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var state = ((StorageJob) jobs.get_item (i)).state;
                if (state == StorageJobState.PENDING || state == StorageJobState.PREPARING ||
                    state == StorageJobState.RUNNING || state == StorageJobState.CANCELLING ||
                    state == StorageJobState.FINALIZING) count++;
            }
            return count;
        }

        public StorageJob begin (string operation, StorageBlock target, StorageDependencyService graph) {
            string[] affected = {};
            foreach (var node in graph.descendants (target)) affected += node.path;
            var job = new StorageJob ((++serial).to_string (), operation, target.preferred, affected);
            job.local = true;
            jobs.append (job);
            changed ();
            return job;
        }

        public StorageJob begin_named (string operation, string target, string[] affected) {
            var job = new StorageJob ((++serial).to_string (), operation, target, affected);
            job.local = true;
            jobs.append (job);
            changed ();
            return job;
        }

        public void phase (StorageJob job, StorageJobState state, string phase) {
            if (terminal (job.state)) return;
            job.state = state;
            job.phase = phase;
            changed ();
        }

        public void progress (StorageJob job, string phase, double value, bool valid) {
            if (terminal (job.state)) return;
            job.state = StorageJobState.RUNNING;
            job.phase = phase;
            job.progress = value;
            job.progress_valid = valid;
            changed ();
        }

        public void finish (StorageJob job, StorageOperationResult result) {
            if (terminal (job.state)) return;
            if (job.backend_expectation == BackendJobExpectation.DISPATCHED)
                job.backend_expectation = BackendJobExpectation.EXPIRED;
            if (job.backend_completed && !job.backend_successful && result.successful) {
                result.fail ("The backend reported that the operation failed");
                result.technical_error = job.error_message;
                result.status = StorageOperationStatus.NEEDS_ATTENTION;
            }
            job.result = result;
            job.progress = 1.0;
            job.progress_valid = result.successful;
            if (result.successful) result.status = StorageOperationStatus.SUCCEEDED;
            job.state = result.status == StorageOperationStatus.SUCCEEDED ? StorageJobState.COMPLETED :
                result.status == StorageOperationStatus.CANCELLED ? StorageJobState.CANCELLED :
                result.status == StorageOperationStatus.NEEDS_ATTENTION ? StorageJobState.NEEDS_ATTENTION :
                result.status == StorageOperationStatus.PARTIAL ? StorageJobState.PARTIALLY_COMPLETED : StorageJobState.FAILED;
            job.phase = result.summary;
            prune ();
            changed ();
        }

        public void expect_backend (StorageJob job, string operation, string expected_object = "") {
            if (!job.local || terminal (job.state) || job.backend_path != "") return;
            job.expected_backend_operation = operation;
            job.expected_backend_object = expected_object;
            job.backend_dispatch_sequence = ++dispatch_serial;
            job.backend_dispatch_time = get_real_time ();
            job.backend_expectation = BackendJobExpectation.DISPATCHED;
            job.initiating_method_completed = false;
        }

        internal void method_returned (StorageJob job, bool allow_late_observation) {
            job.initiating_method_completed = true;
            if (job.backend_expectation != BackendJobExpectation.DISPATCHED) return;
            job.backend_method_return_time = get_real_time ();
            job.backend_observation_deadline = get_monotonic_time () + 2 * TimeSpan.SECOND;
            job.backend_expectation = allow_late_observation ?
                BackendJobExpectation.OBSERVING : BackendJobExpectation.EXPIRED;
        }

        private static bool awaiting_backend_job (StorageJob job, uint64 start_time) {
            if (job.backend_expectation == BackendJobExpectation.DISPATCHED)
                return !terminal (job.state);
            if (job.backend_expectation != BackendJobExpectation.OBSERVING) return false;
            if (get_monotonic_time () >= job.backend_observation_deadline) {
                job.backend_expectation = BackendJobExpectation.EXPIRED;
                return false;
            }
            // The job may be published late, but a job started after the reply
            // is outside this dispatch window.
            return start_time <= (uint64) job.backend_method_return_time;
        }

        private static bool objects_match (StorageJob job, string[] objects) {
            if (objects.length == 0 || job.affected.length == 0) return false;
            bool overlap = false;
            foreach (var object_path in objects) {
                bool found = false;
                foreach (var affected_path in job.affected) if (object_path == affected_path) {
                    found = true; overlap = true; break;
                }
                if (!found) return false;
            }
            return overlap;
        }

        private static bool expected_object_present (StorageJob job, string[] objects) {
            if (job.expected_backend_object == "") return true;
            foreach (var object_path in objects)
                if (object_path == job.expected_backend_object) return true;
            return false;
        }

        public void observe (string path, string operation, string[] objects, double progress,
            bool valid, bool cancelable, uint64 start_time, int64 started_by_uid = -1) {
            StorageJob? match = null;
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var candidate = jobs.get_item (i) as StorageJob;
                if (candidate.backend_path == path) {
                    match = candidate;
                    break;
                }
            }
            if (match == null) {
                StorageJob? candidate_match = null;
                for (uint i = 0; i < jobs.get_n_items (); i++) {
                    var candidate = jobs.get_item (i) as StorageJob;
                    if (!candidate.local || candidate.backend_path != "" ||
                        candidate.expected_backend_operation != operation ||
                        started_by_uid != Posix.getuid () || start_time == 0 ||
                        start_time < (uint64) candidate.backend_dispatch_time ||
                        !expected_object_present (candidate, objects) || !objects_match (candidate, objects) ||
                        !awaiting_backend_job (candidate, start_time)) continue;
                    if (candidate_match != null) { candidate_match = null; break; }
                    candidate_match = candidate;
                }
                match = candidate_match;
            }
            if (match == null) {
                match = new StorageJob ("udisks:" + path, operation, objects.length == 0 ? "Storage device" : objects[0], objects);
                jobs.append (match);
            }
            match.backend_path = path;
            match.backend_expectation = BackendJobExpectation.MATCHED;
            if (terminal (match.state) || match.backend_completed) return;
            match.state = StorageJobState.RUNNING;
            match.phase = operation;
            match.progress = progress;
            match.progress_valid = valid;
            match.cancelable = cancelable;
            changed ();
        }

        public void backend_completed (string path, bool successful, string message) {
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var job = jobs.get_item (i) as StorageJob;
                if (job.backend_path != path) continue;
                job.backend_completed = true; job.backend_successful = successful;
                if (terminal (job.state)) return;
                job.error_message = successful ? "" : message;
                if (job.local) {
                    job.state = StorageJobState.FINALIZING;
                    job.phase = successful ? "Backend completed; verifying resulting storage" :
                        "Backend reported failure; reconciling resulting storage";
                    changed (); return;
                }
                job.state = successful ? StorageJobState.COMPLETED : StorageJobState.FAILED;
                job.phase = message == "" ? (successful ? "Completed" : "Failed") : message;
                job.error_message = successful ? "" : message;
                job.progress = successful ? 1.0 : job.progress;
                job.progress_valid = successful;
                prune (); changed (); return;
            }
        }

        private void prune () {
            while (jobs.get_n_items () > RETENTION_LIMIT) {
                int candidate = -1;
                for (uint i = 0; i < jobs.get_n_items (); i++) {
                    var state = ((StorageJob) jobs.get_item (i)).state;
                    bool terminal = state == StorageJobState.COMPLETED || state == StorageJobState.CANCELLED ||
                        state == StorageJobState.FAILED || state == StorageJobState.PARTIALLY_COMPLETED ||
                        state == StorageJobState.NEEDS_ATTENTION;
                    if (!terminal) continue;
                    if (candidate < 0) candidate = (int) i;
                    if (state == StorageJobState.COMPLETED) { candidate = (int) i; break; }
                }
                if (candidate < 0) return;
                jobs.remove ((uint) candidate);
            }
        }

        internal void backend_disconnected () {
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var job = (StorageJob) jobs.get_item (i);
                if (job.backend_path != "") backend_removed (job.backend_path);
                job.backend_path = "";
                job.backend_expectation = BackendJobExpectation.EXPIRED;
            }
        }

        public void backend_removed (string path) {
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var job = jobs.get_item (i) as StorageJob;
                if (job.backend_path == path && (job.state == StorageJobState.RUNNING ||
                    job.state == StorageJobState.CANCELLING || job.state == StorageJobState.FINALIZING)) {
                    if (job.local) {
                        job.phase = "Backend job disappeared; awaiting initiating method and state verification";
                        job.cancelable = false; changed (); continue;
                    }
                    job.state = StorageJobState.NEEDS_ATTENTION;
                    job.phase = "Backend job disappeared before its result was confirmed";
                    job.error_message = "Refresh the device state before attempting another destructive operation.";
                    changed ();
                }
            }
        }
    }
}
