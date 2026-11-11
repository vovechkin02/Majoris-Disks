namespace MajorisDisks {
    public class StorageRaid : StorageDevice {
        public string level = "";
        public string state = "";
        public uint32 degraded;
        public string uuid = "";
        public bool running;
        public uint expected_members;
        public string bitmap_location = "";
        public MdRaidTopology? topology;
        public MdRaidKernelState? kernel;
        public StorageRaid (string path) { base (path); }
    }

    public class StorageVolumeGroup : StorageDevice {
        public string uuid = "";
        public string[] missing_pv_uuids = {};
        public bool missing_pvs_known;
        public bool needs_polling;
        public uint64 size;
        public uint64 free_size;
        public uint64 extent_size;
        public StorageVolumeGroup (string path) { base (path); }
    }

    public class StorageLogicalVolume : StorageDevice {
        public string group_path = "/";
        public bool active;
        public uint64 size;
        public string uuid = "";
        public double data_allocated_ratio = -1;
        public double metadata_allocated_ratio = -1;
        public string lvm_type = "";
        public string thin_pool_path = "/";
        public string origin_path = "/";
        public string lvm_layout = "";
        public LvmStructure? structure;
        public double sync_ratio = -1;
        public Variant? child_configuration;
        public string block_path = "/";

        public LvmAllocation allocation (StorageSnapshot snapshot) {
            if (structure?.layout == "error") return LvmAllocation.INCOMPLETE;
            if (structure == null || structure.layout != lvm_layout || lvm_layout == "")
                return LvmAllocation.UNKNOWN;
            return structure.allocation (snapshot, group_path);
        }
        public StorageLogicalVolume (string path) { base (path); }
    }

    public class StorageDependencyService : Object {
        private HashTable<StorageDevice, GenericArray<StorageDevice>> edges =
            new HashTable<StorageDevice, GenericArray<StorageDevice>> (direct_hash, direct_equal);
        private HashTable<StorageDevice, StorageDevice> unresolved =
            new HashTable<StorageDevice, StorageDevice> (direct_hash, direct_equal);
        private HashTable<StorageDevice, GenericArray<StorageDevice>> parents =
            new HashTable<StorageDevice, GenericArray<StorageDevice>> (direct_hash, direct_equal);

        public void add (StorageDevice source, StorageDevice? dependent) {
            if (dependent == null) {
                unresolved.insert (source, source);
                return;
            }
            var list = edges.lookup (source);
            if (list == null) {
                list = new GenericArray<StorageDevice> ();
                edges.insert (source, list);
            }
            list.add (dependent);
            var upstream = parents.lookup (dependent);
            if (upstream == null) {
                upstream = new GenericArray<StorageDevice> ();
                parents.insert (dependent, upstream);
            }
            upstream.add (source);
        }

        public StorageDevice[] ancestors (StorageDevice device) {
            var seen = new HashTable<StorageDevice, StorageDevice> (direct_hash, direct_equal);
            StorageDevice[] result = { device };
            seen.insert (device, device);
            for (int i = 0; i < result.length; i++) {
                var upstream = parents.lookup (result[i]);
                if (upstream == null) continue;
                foreach (var parent in upstream) {
                    if (seen.contains (parent)) continue;
                    seen.insert (parent, parent);
                    result += parent;
                }
            }
            return result;
        }

        public StorageDevice[] children (StorageDevice source) {
            StorageDevice[] result = {};
            var list = edges.lookup (source);
            if (list != null)
                for (uint i = 0; i < list.length; i++) result += list[i];
            return result;
        }

        public StorageDevice[] descendants (StorageDevice source) {
            var seen = new HashTable<StorageDevice, StorageDevice> (direct_hash, direct_equal);
            StorageDevice[] result = { source };
            seen.insert (source, source);
            for (int i = 0; i < result.length; i++) {
                foreach (var item in children (result[i])) {
                    if (seen.contains (item)) continue;
                    seen.insert (item, item);
                    result += item;
                }
            }
            return result;
        }

        public bool unknown (StorageDevice device) {
            return unresolved.contains (device);
        }
    }

    public class StorageSafetyAssessment {
        public string identity;
        public bool mounted;
        public bool active_dependents;
        public bool system_critical;
        public bool unknown_dependencies;
        public bool read_only;
        public bool removable;
        public string[] reasons = {};

        public StorageSafetyAssessment (StorageDevice device) {
            identity = device.path;
            read_only = device.read_only;
        }
    }

    public enum StorageOperationKind {
        INITIALIZE_DISK, RESIZE_PARTITION, RESIZE_FILESYSTEM, FORMAT_VOLUME, EDIT_PARTITION,
        EDIT_PARTITION_NAME, EDIT_PARTITION_TYPE, EDIT_PARTITION_FLAGS,
        EDIT_FILESYSTEM_LABEL, CHECK_FILESYSTEM, REPAIR_FILESYSTEM,
        CREATE_PARTITION, DELETE_PARTITION, RESIZE, FORMAT, CHECK, REPAIR, TAKE_OWNERSHIP,
        ENCRYPT, UNLOCK, LOCK, MOUNT, UNMOUNT, SWAP_START, SWAP_STOP, IMAGE_RESTORE,
        POWER_OFF, EJECT, BENCHMARK_WRITE, LVM_CHANGE, RAID_CHANGE, BTRFS_CHANGE
    }

    public class StorageOperationEligibility : Object {
        public bool allowed;
        public bool requires_preparation;
        public bool blocked;
        public bool unknown;
        public string reason = "";
        public string[] affected = {};
        public string[] preparation = {};
        public bool overwrites_storage;
        public bool changes_partition_table;
        public bool modifies_filesystem;
        public bool affects_active_dependencies;
    }

    public class StorageSafetyService {
        private static bool managed_image_volume (StorageBlock volume) {
            var image = volume;
            while (image.partition != null && image.parent is StorageBlock)
                image = (StorageBlock) image.parent;
            return image.loop?.managed () == true || image.virtual_attachment != null;
        }

        public static StorageSafetyAssessment assess (StorageDevice device, StorageDependencyService? graph = null,
            bool distinguish_managed_image_hint = false) {
            var result = new StorageSafetyAssessment (device);
            var drive = device as StorageDrive;
            var block = device as StorageBlock;
            result.removable = drive?.removable ?? block?.physical_drive?.removable ?? false;
            result.mounted = block?.filesystem?.mounted ?? false;
            result.unknown_dependencies = graph == null || !device.available;
            StorageDevice[] nodes = graph == null ? new StorageDevice[] { device } : graph.descendants (device);
            foreach (var node in nodes) {
                var volume = node as StorageBlock;
                var lv = node as StorageLogicalVolume;
                if (graph != null && graph.unknown (node)) result.unknown_dependencies = true;
                if (lv?.active == true || (node != device && node is StorageRaid)) result.active_dependents = true;
                if (volume == null) continue;
                // UDisks uses HintSystem for authorization on ordinary image devices too.
                // Live system mount paths, dependencies and kernel checks still apply.
                if (volume.system_hint && (!distinguish_managed_image_hint || !managed_image_volume (volume)))
                    result.system_critical = true;
                if (volume.swap_active || volume.encrypted?.mapping != null ||
                    (volume != block && volume.filesystem?.mounted == true))
                    result.active_dependents = true;
                var fs = volume.filesystem;
                if (fs == null) continue;
                foreach (var point in fs.mounts) {
                    if (point == "/" || point == "/boot" || point.has_prefix ("/boot/") ||
                        point == "/usr" || point == "/var" || point == "/etc" || point == "/efi")
                        result.system_critical = true;
                }
            }
            string[] reasons = {};
            if (result.system_critical) reasons += "Supports a running system filesystem";
            if (result.active_dependents) reasons += "Has active storage dependencies";
            if (result.mounted) reasons += "Filesystem is mounted";
            if (result.unknown_dependencies) reasons += "Dependencies could not be fully resolved";
            if (result.read_only) reasons += "Device is read-only";
            result.reasons = reasons;
            return result;
        }

        public static StorageOperationEligibility assess_operation (StorageOperationKind operation,
            StorageDevice device, StorageDependencyService? graph) {
            var eligibility = new StorageOperationEligibility ();
            var assessment = assess (device, graph, operation == StorageOperationKind.IMAGE_RESTORE);
            StorageDevice[] nodes = graph == null ? new StorageDevice[] { device } : graph.descendants (device);
            string[] affected = {};
            foreach (var node in nodes) affected += node.path;
            eligibility.affected = affected;
            bool destructive = operation == StorageOperationKind.DELETE_PARTITION ||
                operation == StorageOperationKind.CREATE_PARTITION || operation == StorageOperationKind.INITIALIZE_DISK ||
                operation == StorageOperationKind.RESIZE_PARTITION || operation == StorageOperationKind.RESIZE_FILESYSTEM ||
                operation == StorageOperationKind.RESIZE || operation == StorageOperationKind.FORMAT || operation == StorageOperationKind.FORMAT_VOLUME ||
                operation == StorageOperationKind.ENCRYPT || operation == StorageOperationKind.IMAGE_RESTORE ||
                operation == StorageOperationKind.BENCHMARK_WRITE || operation == StorageOperationKind.LVM_CHANGE ||
                operation == StorageOperationKind.RAID_CHANGE || operation == StorageOperationKind.BTRFS_CHANGE;
            eligibility.changes_partition_table = operation == StorageOperationKind.CREATE_PARTITION ||
                operation == StorageOperationKind.INITIALIZE_DISK || operation == StorageOperationKind.DELETE_PARTITION ||
                operation == StorageOperationKind.RESIZE_PARTITION || operation == StorageOperationKind.RESIZE ||
                operation == StorageOperationKind.IMAGE_RESTORE;
            eligibility.overwrites_storage = operation == StorageOperationKind.FORMAT || operation == StorageOperationKind.FORMAT_VOLUME ||
                operation == StorageOperationKind.ENCRYPT || operation == StorageOperationKind.IMAGE_RESTORE;
            eligibility.modifies_filesystem = operation == StorageOperationKind.RESIZE || operation == StorageOperationKind.RESIZE_FILESYSTEM ||
                operation == StorageOperationKind.FORMAT || operation == StorageOperationKind.FORMAT_VOLUME ||
                operation == StorageOperationKind.REPAIR || operation == StorageOperationKind.REPAIR_FILESYSTEM ||
                operation == StorageOperationKind.TAKE_OWNERSHIP;
            eligibility.affects_active_dependencies = assessment.active_dependents || assessment.mounted;
            if (graph == null || assessment.unknown_dependencies) {
                eligibility.unknown = true; eligibility.blocked = destructive;
                eligibility.reason = "The full dependency graph is not known; destructive operations fail closed.";
            } else if (assessment.read_only && operation != StorageOperationKind.CHECK && operation != StorageOperationKind.CHECK_FILESYSTEM) {
                eligibility.blocked = true; eligibility.reason = "The selected device is read-only.";
            } else if (assessment.system_critical && destructive && operation != StorageOperationKind.CREATE_PARTITION) {
                eligibility.blocked = true; eligibility.reason = "The operation could affect the running system.";
            } else if (assessment.system_critical && ((operation == StorageOperationKind.EDIT_PARTITION ||
                operation == StorageOperationKind.EDIT_PARTITION_TYPE || operation == StorageOperationKind.EDIT_PARTITION_FLAGS) ||
                operation == StorageOperationKind.EDIT_FILESYSTEM_LABEL || operation == StorageOperationKind.TAKE_OWNERSHIP)) {
                eligibility.blocked = true; eligibility.reason = "Metadata changes are blocked on storage used by the running system.";
            } else if ((assessment.active_dependents || assessment.mounted) &&
                (operation == StorageOperationKind.EDIT_PARTITION_TYPE || operation == StorageOperationKind.EDIT_PARTITION_FLAGS)) {
                eligibility.blocked = true; eligibility.reason = "Partition type and flag changes are blocked while dependent storage is active.";
            } else if (assessment.active_dependents && destructive) {
                eligibility.requires_preparation = true;
                eligibility.preparation = { "Deactivate dependent mounts, swap, mappings, RAID, and logical volumes" };
                eligibility.reason = "Active dependents must be prepared before this operation.";
            } else if (assessment.mounted && (destructive || operation == StorageOperationKind.REPAIR ||
                operation == StorageOperationKind.REPAIR_FILESYSTEM || operation == StorageOperationKind.CHECK ||
                operation == StorageOperationKind.CHECK_FILESYSTEM || operation == StorageOperationKind.EDIT_FILESYSTEM_LABEL)) {
                eligibility.requires_preparation = true;
                eligibility.preparation = { "Unmount the filesystem and restore it afterwards" };
                eligibility.reason = "The filesystem must be prepared offline.";
            }
            eligibility.allowed = !eligibility.blocked;
            return eligibility;
        }
    }
}
