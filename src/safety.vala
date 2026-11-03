namespace MajorisDisks {
    public class StorageRaid : StorageDevice {
        public string level = "";
        public string state = "";
        public uint32 degraded;
        public StorageRaid (string path) { base (path); }
    }

    public class StorageVolumeGroup : StorageDevice {
        public StorageVolumeGroup (string path) { base (path); }
    }

    public class StorageLogicalVolume : StorageDevice {
        public string group_path = "/";
        public bool active;
        public StorageLogicalVolume (string path) { base (path); }
    }

    public class StorageDependencyService : Object {
        private HashTable<StorageDevice, GenericArray<StorageDevice>> edges =
            new HashTable<StorageDevice, GenericArray<StorageDevice>> (direct_hash, direct_equal);
        private HashTable<StorageDevice, StorageDevice> unresolved =
            new HashTable<StorageDevice, StorageDevice> (direct_hash, direct_equal);

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

    public class StorageSafetyService {
        public static StorageSafetyAssessment assess (StorageDevice device, StorageDependencyService? graph = null) {
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
            if (result.system_critical) result.reasons += "Supports a running system filesystem";
            if (result.active_dependents) result.reasons += "Has active storage dependencies";
            if (result.mounted) result.reasons += "Filesystem is mounted";
            if (result.unknown_dependencies) result.reasons += "Dependencies could not be fully resolved";
            if (result.read_only) result.reasons += "Device is read-only";
            return result;
        }
    }
}
