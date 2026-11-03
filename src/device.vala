namespace MajorisDisks {
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
        public bool smart;
        public bool optical;
        public string media = "";
        public string nvme_state = "";

        public StorageBlock[] blocks = {};
        public StorageBlock? medium;

        public StorageDrive (string path) {
            base (path);
        }
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

        public StorageBlock (string path) {
            base (path);
        }
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





