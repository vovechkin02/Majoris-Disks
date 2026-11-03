namespace MajorisDisks {
    public class StorageHierarchy {
        public static void link (StorageSnapshot snapshot, HashTable<string, StorageDrive> previous) {
            StorageDrive[] devices = {};
            foreach (var drive in snapshot.drives.get_values ()) devices += drive;
            foreach (var block in snapshot.blocks.get_values ()) {
                if (block.backing_path != "/") {
                    var backing = snapshot.blocks.lookup (block.backing_path);
                    if (backing != null && backing.encrypted != null) {
                        backing.encrypted.mapping = block;
                        block.parent = backing;
                    }
                }
                var part = block.partition;
                if (part != null) {
                    var disk = snapshot.blocks.lookup (part.table_path);
                    if (disk != null && disk.table != null) {
                        disk.table.partitions += block;
                        block.parent = disk;
                    }
                }
                var physical = snapshot.drives.lookup (block.drive_path);
                block.physical_drive = physical;
                if (physical != null) physical.blocks += block;
                if (block.partition != null || block.backing_path != "/" || block.ignored ||
                    block.device.has_prefix ("/dev/ram") || block.device.has_prefix ("/dev/zram") ||
                    (block.loop != null && block.loop.backing_file == "")) continue;
                var drive = physical;
                if (drive == null) {
                    drive = previous.lookup (block.path) ?? new StorageDrive (block.path);
                    drive.blocks = { block };
                    drive.name = block.loop != null ? Path.get_basename (block.loop.backing_file) : block.name;
                    drive.category = block.loop != null ? "Disk Images" : "Other";
                    drive.size = block.size;
                    drive.available = block.available;
                    snapshot.drives.insert (drive.path, drive);
                    devices += drive;
                }
                if (physical == null || drive.medium == null ||
                    (block.table != null && drive.medium.table == null) ||
                    ((block.table != null) == (drive.medium.table != null) &&
                     strcmp (block.path, drive.medium.path) < 0))
                    drive.medium = block;
                block.parent = drive;
            }
            foreach (var block in snapshot.blocks.get_values ()) {
                var table = block.table;
                if (table == null) continue;
                var parts = table.partitions;
                for (int i = 1; i < parts.length; i++) {
                    var item = parts[i];
                    int position = i;
                    while (position > 0 && parts[position - 1].partition.offset > item.partition.offset) {
                        parts[position] = parts[position - 1];
                        position--;
                    }
                    parts[position] = item;
                }
                foreach (var logical in parts) {
                    if (table.scheme != "dos" || !logical.partition.logical || logical.partition.container) continue;
                    foreach (var container in parts) {
                        if (!container.partition.container || container.partition.logical ||
                            logical.partition.offset < container.partition.offset) continue;
                        uint64 relative = logical.partition.offset - container.partition.offset;
                        if (relative < container.size && logical.size <= container.size - relative) {
                            logical.parent = container;
                            break;
                        }
                    }
                }
            }
            for (int i = 1; i < devices.length; i++) {
                var item = devices[i];
                int position = i;
                while (position > 0 && compare (devices[position - 1], item) > 0) {
                    devices[position] = devices[position - 1];
                    position--;
                }
                devices[position] = item;
            }
            StorageDrive[] visible = {};
            foreach (var drive in devices) {
                if (drive.medium == null && drive.blocks.length != 0) continue;
                drive.read_only = drive.medium != null && drive.medium.read_only;
                visible += drive;
            }
            link_dependencies (snapshot);
            snapshot.publish (visible);
        }

        private static void link_dependencies (StorageSnapshot snapshot) {
            var graph = new StorageDependencyService ();
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv == null) continue;
                var group = snapshot.advanced.lookup (lv.group_path) as StorageVolumeGroup;
                if (group != null) graph.add (group, lv);
                else graph.add (lv, null);
            }
            foreach (var block in snapshot.blocks.get_values ()) {
                block.dependencies = graph;
                if (block.parent != null) graph.add (block.parent, block);
                if (block.physical_drive != null && block.parent == null)
                    graph.add (block.physical_drive, block);
                block.raid = snapshot.advanced.lookup (block.raid_path) as StorageRaid;
                block.raid_membership = snapshot.advanced.lookup (block.raid_member_path) as StorageRaid;
                block.volume_group = snapshot.advanced.lookup (block.physical_volume_group_path) as StorageVolumeGroup;
                block.logical_volume = snapshot.advanced.lookup (block.logical_volume_path) as StorageLogicalVolume;
                if (block.raid != null) graph.add (block.raid, block);
                if (block.raid_member_path != "/") graph.add (block, block.raid_membership);
                if (block.physical_volume_group_path != "/") graph.add (block, block.volume_group);
                if (block.logical_volume != null) graph.add (block.logical_volume, block);
                if ((block.backing_path != "/" && block.parent == null) ||
                    (block.raid_path != "/" && block.raid == null) ||
                    (block.logical_volume_path != "/" && block.logical_volume == null) ||
                    (block.device.has_prefix ("/dev/dm-") && block.backing_path == "/" && block.logical_volume == null))
                    graph.add (block, null);
            }
            snapshot.dependencies = graph;
        }
        private static int compare (StorageDrive a, StorageDrive b) {
            int group = strcmp (a.category, b.category);
            return group != 0 ? group : strcmp (a.path, b.path);
        }

        public static StorageDevice[] regions (StorageBlock disk, StorageBlock owner) {
            StorageDevice[] result = {};
            if (disk.table == null) {
                if (disk == owner && disk.size != 0) result += disk;
                return result;
            }
            uint64 start = owner.partition == null ? 0 : owner.partition.offset;
            if (start >= disk.size) return result;
            uint64 end = start + uint64.min (owner.size, disk.size - start);
            Extent[] occupied = {};
            foreach (var part in disk.table.partitions) {
                if (part.parent != owner || part.partition.offset >= end || part.size == 0) continue;
                if (!part.partition.logical || owner != disk) result += part;
                occupied += Extent (part.partition.offset, part.size);
            }
            foreach (var gap in PartitionLayoutService.gaps (start, end, occupied))
                result += new StorageFreeSpace (owner, gap);
            for (int i = 1; i < result.length; i++) {
                var item = result[i];
                int position = i;
                while (position > 0 && offset (result[position - 1]) > offset (item)) {
                    result[position] = result[position - 1];
                    position--;
                }
                result[position] = item;
            }
            return result;
        }

        private static uint64 offset (StorageDevice device) {
            var gap = device as StorageFreeSpace;
            var block = device as StorageBlock;
            return gap != null ? gap.offset : block?.partition?.offset ?? 0;
        }
    }

    public class StorageCapabilities {
        public bool mount;
        public bool unmount;
        public bool activate_swap;

        public StorageCapabilities (StorageBlock block) {
            if (!block.available || block.ignored) return;
            var fs = block.filesystem;
            mount = fs != null && !fs.mounted;
            var safety = StorageSafetyService.assess (block, block.dependencies);
            unmount = fs != null && fs.mounted && !safety.system_critical && !safety.active_dependents;
            activate_swap = block.has_swap && !block.swap_active && !block.read_only;
        }
    }
}



