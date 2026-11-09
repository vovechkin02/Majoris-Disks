namespace MajorisDisks {
    internal class BtrfsReplacementStatus : Object {
        public string uuid;
        public uint64 state;
        public uint64 progress_1000;
        public uint64 started;
        public uint64 stopped;
        public uint64 write_errors;
        public uint64 read_errors;
        public uint64 result;
        public string warning = "";
        public bool active { get { return state == 1 || state == 4; } }

        public BtrfsReplacementStatus (string uuid, string output) throws Error {
            this.uuid = uuid;
            var fields = output.strip ().split (" ");
            if (fields.length != 7 || !uint64.try_parse (fields[0], out state) ||
                !uint64.try_parse (fields[1], out progress_1000) || progress_1000 > 1000 ||
                !uint64.try_parse (fields[2], out started) || !uint64.try_parse (fields[3], out stopped) ||
                !uint64.try_parse (fields[4], out write_errors) || !uint64.try_parse (fields[5], out read_errors) ||
                !uint64.try_parse (fields[6], out result) || result != 0)
                throw new IOError.INVALID_DATA ("The kernel replacement status could not be interpreted.");
        }

        public string state_label () {
            switch (state) {
            case 0: return "Never started";
            case 1: return "Replacement running";
            case 2: return "Replacement finished";
            case 3: return "Replacement cancelled";
            case 4: return "Replacement suspended";
            default: return "Unknown replacement state";
            }
        }
    }

    internal class BtrfsMemberInfo : Object {
        public uint64 id;
        public uint64 number;
        public uint64 capacity;
        public uint64 allocated;
        public string uuid;
        public string state;
        public string filesystem_uuid = "";
        public string device_path = "";
        public uint64[] error_counters = {};
        public bool allocation_known;
        public bool has_errors;

        public BtrfsMemberInfo (Variant row) {
            row.get ("(ttttssbb)", out id, out number, out capacity, out allocated,
                out uuid, out state, out allocation_known, out has_errors);
        }
    }

    internal class BtrfsAllocationProfile : Object {
        public string label;
        public uint64 allocated;
        public uint64 used;
        public uint64 flags;

        public BtrfsAllocationProfile (Variant row) {
            row.get ("(sttt)", out label, out allocated, out used, out flags);
        }
    }

    internal class BtrfsFilesystemInfo : Object {
        public string uuid;
        public string label;
        public uint64 capacity;
        public uint64 member_count;
        public BtrfsAllocationProfile[] profiles = {};
        public BtrfsMemberInfo[] members = {};
        public uint64 used;
        public uint64 estimated_available;
        public uint64 global_reserve;
        public bool read_only;
        public string exclusive_operation;
        public uint64 replication_overhead;
        public bool overhead_known;

        public string replacement_restriction (BtrfsMemberInfo source, bool avoid = false) {
            if (!Uuid.string_is_valid (uuid) || source.filesystem_uuid != uuid)
                return "The filesystem identity is unknown.";
            if (read_only || exclusive_operation != "none")
                return "The filesystem is read-only or has an exclusive operation.";
            if (member_count == 0 || members.length != member_count)
                return "The filesystem member set could not be verified.";
            if (source.id == 0 || !Uuid.string_is_valid (source.uuid) || !source.allocation_known || source.capacity == 0)
                return "Additional verification required. The source identity or capacity is unavailable.";
            bool missing = source.state == "Missing";
            if ((missing && source.number != 0) || (!missing && (source.state != "Present" || source.number == 0)))
                return "Additional verification required. The source state is uncertain.";
            if ((missing || avoid) && member_count < 2)
                return "Insufficient redundancy.";
            foreach (var member in members) {
                if (member == source) continue;
                if (member.id == 0 || !member.allocation_known || member.number == 0 ||
                    member.state != "Present" || ((missing || avoid) && member.has_errors))
                    return "Additional verification required. A surviving member is unavailable or reports errors.";
            }
            uint64 types = 0;
            foreach (var profile in profiles) {
                uint64 type = profile.flags & 7;
                uint64 layout = profile.flags & ~((uint64) 7);
                if (!(type == 1 || type == 2 || type == 4 || type == 5) ||
                    profile.allocated == 0 || profile.used > profile.allocated)
                    return "The filesystem allocation state is unknown.";
                // Linux UAPI block-group flags. Restrict parity and unknown profiles.
                if (!(layout == 0 || layout == 8 || layout == 16 || layout == 32 ||
                      layout == 64 || layout == 512 || layout == 1024))
                    return "Replacement is unsupported for this allocation profile.";
                if ((missing || avoid) && layout != 16)
                    return "Insufficient verified RAID 1 redundancy for reconstruction.";
                types |= type;
            }
            return types == 7 ? "" : "The filesystem allocation state is unknown.";
        }

        public BtrfsFilesystemInfo (string uuid, string label, Variant report) {
            this.uuid = uuid;
            this.label = label;
            capacity = report.get_child_value (0).get_uint64 ();
            member_count = report.get_child_value (1).get_uint64 ();
            var profile_rows = report.get_child_value (2);
            var member_rows = report.get_child_value (3);
            used = report.get_child_value (4).get_uint64 ();
            estimated_available = report.get_child_value (5).get_uint64 ();
            global_reserve = report.get_child_value (6).get_uint64 ();
            read_only = report.get_child_value (7).get_boolean ();
            exclusive_operation = report.get_child_value (8).get_string ();
            replication_overhead = report.get_child_value (9).get_uint64 ();
            overhead_known = report.get_child_value (10).get_boolean ();
            Variant? details = report.n_children () > 11 ? report.get_child_value (11) : null;
            for (size_t i = 0; i < profile_rows.n_children (); i++)
                profiles += new BtrfsAllocationProfile (profile_rows.get_child_value (i));
            for (size_t i = 0; i < member_rows.n_children (); i++) {
                var member = new BtrfsMemberInfo (member_rows.get_child_value (i));
                member.filesystem_uuid = uuid;
                if (details != null && i < details.n_children ()) {
                    var detail = details.get_child_value (i);
                    if (detail.get_child_value (0).get_uint64 () == member.id) {
                        member.device_path = detail.get_child_value (1).get_string ();
                        var counts = detail.get_child_value (2);
                        for (size_t j = 0; j < counts.n_children (); j++)
                            member.error_counters += counts.get_child_value (j).get_uint64 ();
                    }
                }
                members += member;
            }
        }
    }

    internal class BtrfsSubvolume : Object {
        public uint64 id;
        public uint64 parent_id;
        public string path;
        public bool snapshot;

        public BtrfsSubvolume (uint64 id, uint64 parent_id, string path) {
            this.id = id;
            this.parent_id = parent_id;
            this.path = path;
        }
    }

    internal class BtrfsSubvolumeList : Object {
        public BtrfsSubvolume[] entries = {};
        public uint default_id;
        public bool default_known;
        public string default_unavailable = "";
    }
    public enum StorageSettingIntent { UNCHANGED, SET, RESET }

    public class StorageDevice : Object {
        public string path;
        public string name = "";
        public string icon = "drive-harddisk-symbolic";
        public uint64 size;
        public bool available = true;
        public bool read_only;
        public weak StorageDevice? parent;

        public StorageDevice (string path) {
            this.path = path;
        }
    }

    public class StorageDrive : StorageDevice {
        public string vendor = "";
        public string model = "";
        public string serial = "";
        public string revision = "";
        public string wwn = "";
        public string bus = "";
        public string category = "Other";
        public int rotation;
        public bool removable;
        public bool ejectable;
        public bool can_power_off;
        public bool ata_power_management;
        public bool ata_apm_supported;
        public bool ata_aam_supported;
        public bool ata_write_cache_supported;
        public bool ata_read_lookahead_supported;
        public Variant drive_configuration = new Variant ("a{sv}", null);
        public bool smart;
        public bool optical;
        public string media = "";
        public string nvme_state = "";
        public bool smart_enabled;
        public uint64 smart_updated;
        public bool smart_failing;
        public double smart_temperature;
        public uint64 smart_power_on_seconds;
        public int smart_attributes_failing = -1;
        public int smart_attributes_failed_past = -1;
        public int64 smart_bad_sectors = -1;
        public string smart_selftest_status = "";
        public int smart_selftest_remaining = -1;
        public string[] nvme_warnings = {};
        public uint64 nvme_power_on_hours;
        public uint16 nvme_temperature;

        public StorageBlock[] blocks = {};
        public StorageBlock? medium;

        public StorageDrive (string path) {
            base (path);
        }
    }

    public class StorageHealthAttribute : Object {
        public uint id;
        public string name = "";
        public string raw = "";
        public int normalized = -1;
        public int worst = -1;
        public int threshold = -1;
        public string assessment = "Unknown";
        public string description = "";
    }

    public class StorageHealthReport : Object {
        public bool nvme;
        public string overall = "Unknown";
        public string temperature = "Unknown";
        public uint64 updated;
        public uint64 power_on_hours;
        public string selftest = "Unknown";
        public int selftest_remaining = -1;
        public string[] warnings = {};
        public uint64 media_errors;
        public uint64 unsafe_shutdowns;
        public uint64 error_log_entries;
        public int available_spare = -1;
        public int spare_threshold = -1;
        public int percentage_used = -1;
        public bool has_total_data_read;
        public uint64 total_data_read;
        public bool has_total_data_written;
        public uint64 total_data_written;
        public bool has_controller_busy_minutes;
        public uint64 controller_busy_minutes;
        public bool has_power_cycles;
        public uint64 power_cycles;
        public bool has_media_errors;
        public bool has_unsafe_shutdowns;
        public bool has_error_log_entries;
        public string temperature_sensors = "";
        public StorageHealthAttribute[] attributes = {};
    }

    public class StorageBlock : StorageDevice {
        public string device = "";
        public string preferred = "";
        public string drive_path = "/";
        public string backing_path = "/";
        public string raid_path = "/";
        public string raid_member_path = "/";
        public string logical_volume_path = "/";
        public string physical_volume_group_path = "/";
        public weak StorageDrive? physical_drive;
        public weak StorageRaid? raid;
        public weak StorageRaid? raid_membership;
        public weak StorageVolumeGroup? volume_group;
        public weak StorageLogicalVolume? logical_volume;
        public weak StorageDependencyService? dependencies;
        public bool system_hint;
        public string usage = "";
        public string type_id = "";
        public string label = "";
        public string uuid = "";
        public uint64 number;
        public uint64 logical_sector_size;
        public uint64 physical_sector_size;
        public bool ignored;
        public bool has_swap;
        public bool swap_active;
        public StoragePartition? partition;
        public StoragePartitionTable? table;
        public StorageFilesystem? filesystem;
        public StorageEncryptedVolume? encrypted;
        public StorageLoopDevice? loop;
        internal VirtualAttachment? virtual_attachment;
        public StorageMountConfiguration? mount_configuration;
        public StorageMountConfiguration[] mount_configurations = {};
        public StorageEncryptionConfiguration? encryption_configuration;
        public StorageEncryptionConfiguration[] encryption_configurations = {};

        public StorageBlock (string path) {
            base (path);
        }
    }

    public class StorageMountConfiguration : Object {
        public string device = ""; public string directory = ""; public string filesystem = "auto";
        public string options = "defaults"; public Variant? backend_item;
    }

    public class StorageEncryptionConfiguration : Object {
        public string device = "";
        public string name = "";
        public string options = "";
        public string passphrase_path = "";
        public Variant? backend_item;
    }

    public class StoragePartitionTable : Object {
        public string scheme;
        public StorageBlock[] partitions = {};

        public StoragePartitionTable (string scheme) {
            this.scheme = scheme;
        }
    }

    public class StoragePartition : Object {
        public string table_path = "/";
        public string type_id = "";
        public string name = "";
        public string uuid = "";
        public uint32 number;
        public uint64 offset;
        public uint64 flags;
        public bool container;
        public bool logical;
    }

    public class StorageFilesystem : Object {
        public string[] mounts = {};
        public uint64 size;
        public bool mounted { get { return mounts.length != 0; } }
    }

    public class StorageEncryptedVolume : Object {
        public weak StorageBlock? mapping;
    }

    public class StorageLoopDevice : Object {
        public string backing_file = "";
    }

    public class StorageFreeSpace : StorageDevice {
        public uint64 offset;
        public uint64 end { get { return offset + size; } }
        // Display gaps include areas whose allocation constraints are unknown.
        public bool allocation_confirmed { get { return false; } }

        public StorageFreeSpace (StorageBlock owner, Extent extent) {
            base (("%s:gap:%" + uint64.FORMAT).printf (owner.path, extent.offset));
            parent = owner;
            name = "Unallocated space";
            offset = extent.offset;
            size = extent.size;
        }
    }

    public class StorageSnapshot : Object {
        public HashTable<string, StorageBlock> blocks =
            new HashTable<string, StorageBlock> (str_hash, str_equal);
        public HashTable<string, StorageDrive> drives =
            new HashTable<string, StorageDrive> (str_hash, str_equal);
        public HashTable<string, StorageDevice> advanced =
            new HashTable<string, StorageDevice> (str_hash, str_equal);
        public StorageDependencyService dependencies = new StorageDependencyService ();
        public ListStore devices = new ListStore (typeof (StorageDrive));

        public void publish (StorageDrive[] ordered) {
            uint index = 0;
            foreach (var drive in ordered) {
                if (devices.get_item (index) == drive) {
                    index++;
                    continue;
                }
                for (uint old = index + 1; old < devices.get_n_items (); old++) {
                    if (devices.get_item (old) == drive) {
                        devices.remove (old);
                        break;
                    }
                }
                devices.insert (index++, drive);
            }
            while (devices.get_n_items () > index) devices.remove (index);
        }
    }
}
