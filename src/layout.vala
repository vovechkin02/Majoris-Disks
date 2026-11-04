namespace MajorisDisks {
    public struct Extent {
        public uint64 offset;
        public uint64 size;

        public Extent (uint64 offset, uint64 size) {
            this.offset = offset;
            this.size = size;
        }
    }

    public class PartitionLayoutService {
        public enum PartitionKind { GPT, MBR_PRIMARY, MBR_EXTENDED, MBR_LOGICAL }

        public static uint64 aligned_up (uint64 value, uint64 alignment) {
            if (alignment == 0 || value % alignment == 0) return value;
            uint64 addition = alignment - value % alignment;
            return value > uint64.MAX - addition ? uint64.MAX : value + addition;
        }

        public static void validate_create (StorageBlock disk, StorageFreeSpace gap, uint64 requested_size,
            PartitionKind kind, out uint64 offset, out uint64 size) throws Error {
            var table = disk.table;
            if (table == null || (table.scheme != "gpt" && table.scheme != "dos") || disk.size == 0)
                throw new IOError.NOT_SUPPORTED ("A GPT or MBR partition table is required.");
            if (gap.parent == null || gap.size == 0 || gap.offset >= disk.size || gap.size > disk.size - gap.offset)
                throw new IOError.INVALID_DATA ("The selected free-space geometry is no longer valid.");
            uint64 sector = disk.logical_sector_size;
            if (sector == 0) throw new IOError.NOT_SUPPORTED ("The device sector size is unavailable.");
            uint64 alignment = uint64.max (sector, 1024 * 1024);
            offset = aligned_up (gap.offset, alignment);
            if (offset >= gap.end) throw new IOError.NO_SPACE ("No aligned space remains in this region.");
            uint64 available = gap.end - offset;
            size = requested_size == 0 ? 0 : requested_size - requested_size % sector;
            if (requested_size != 0 && (size == 0 || size > available))
                throw new IOError.NO_SPACE ("The requested partition does not fit in the selected region.");

            int primary = 0;
            int containers = 0;
            StorageBlock? containing = null;
            foreach (var block in table.partitions) {
                var part = block.partition;
                if (part == null || block.size == 0) throw new IOError.INVALID_DATA ("Existing partition geometry is incomplete.");
                if (part.offset < gap.end && gap.offset < part.offset + uint64.min (block.size, disk.size - uint64.min (part.offset, disk.size)) &&
                    block != gap.parent)
                    throw new IOError.INVALID_DATA ("The selected region overlaps an existing partition.");
                if (table.scheme == "dos" && !part.logical) primary++;
                if (part.container) {
                    containers++;
                    if (gap.offset >= part.offset && gap.end <= part.offset + block.size) containing = block;
                }
            }
            if (table.scheme == "gpt") {
                if (kind != PartitionKind.GPT) throw new IOError.INVALID_ARGUMENT ("MBR partition types cannot be used on GPT.");
                if (gap.parent != disk) throw new IOError.INVALID_DATA ("GPT free space must belong to the disk.");
                return;
            }
            switch (kind) {
                case PartitionKind.MBR_PRIMARY:
                    if (containing != null) throw new IOError.INVALID_ARGUMENT ("Primary partitions cannot be created inside an extended partition.");
                    if (primary >= 4) throw new IOError.NO_SPACE ("The MBR primary partition limit has been reached.");
                    break;
                case PartitionKind.MBR_EXTENDED:
                    if (containing != null) throw new IOError.INVALID_ARGUMENT ("An extended partition cannot be nested.");
                    if (containers != 0) throw new IOError.EXISTS ("This disk already has an extended partition.");
                    if (primary >= 4) throw new IOError.NO_SPACE ("The MBR primary partition limit has been reached.");
                    break;
                case PartitionKind.MBR_LOGICAL:
                    if (containing == null || gap.parent != containing)
                        throw new IOError.INVALID_ARGUMENT ("Logical partitions must be created inside the extended partition.");
                    break;
                default:
                    throw new IOError.INVALID_ARGUMENT ("GPT partitions cannot be created on MBR.");
            }
        }

        public static void validate_resize (StorageBlock disk, StorageBlock target, uint64 size) throws Error {
            var table = disk.table;
            var part = target.partition;
            var parent = target.parent as StorageBlock;
            uint64 sector = disk.logical_sector_size;
            if (table == null || part == null || parent == null || part.table_path != disk.path ||
                sector == 0 || disk.size == 0 || target.size == 0 ||
                (table.scheme != "gpt" && table.scheme != "dos"))
                throw new IOError.NOT_SUPPORTED ("The partition geometry cannot be safely resized.");
            if (size == 0 || size % sector != 0 || part.offset % sector != 0)
                throw new IOError.INVALID_ARGUMENT ("The new size and partition start must be sector aligned.");
            uint64 limit = disk.size;
            if (part.container) {
                if (table.scheme != "dos" || parent != disk)
                    throw new IOError.INVALID_DATA ("The extended partition does not belong to this MBR disk.");
            } else if (part.logical) {
                var container = parent.partition;
                if (table.scheme != "dos" || container == null || !container.container ||
                    container.offset >= limit || parent.size > limit - container.offset ||
                    part.offset <= container.offset)
                    throw new IOError.INVALID_DATA ("The extended partition boundary could not be verified.");
                limit = container.offset + parent.size;
            } else if (parent != disk) {
                throw new IOError.INVALID_DATA ("The partition does not belong to the selected disk.");
            }
            bool found = false;
            foreach (var sibling in table.partitions) {
                if (sibling == target) {
                    found = true;
                    continue;
                }
                if (sibling.parent != parent) continue;
                var other = sibling.partition;
                if (other == null || sibling.size == 0)
                    throw new IOError.INVALID_DATA ("An adjacent partition has unknown geometry.");
                if (other.offset < part.offset && sibling.size > part.offset - other.offset)
                    throw new IOError.INVALID_DATA ("The current partition overlaps an adjacent partition.");
                if (other.offset >= part.offset) limit = uint64.min (limit, other.offset);
            }
            if (!found || part.offset >= limit || target.size > limit - part.offset)
                throw new IOError.INVALID_DATA ("The current partition geometry is inconsistent.");
            if (size > limit - part.offset)
                throw new IOError.NO_SPACE ("The requested size crosses the next partition or container boundary.");
            if (size < minimum_resize (disk, target))
                throw new IOError.NO_SPACE ("The extended partition must contain every logical partition and its EBR margin.");
        }

        public static uint64 minimum_resize (StorageBlock disk, StorageBlock target) throws Error {
            var part = target.partition;
            uint64 sector = disk.logical_sector_size;
            if (part == null || sector == 0) throw new IOError.NOT_SUPPORTED ("The minimum partition boundary is unavailable.");
            if (!part.container) return sector;
            if (disk.table == null) throw new IOError.NOT_SUPPORTED ("The partition table is unavailable.");
            uint64 end = part.offset + sector;
            foreach (var child in disk.table.partitions) {
                var logical = child.partition;
                if (child.parent != target || logical == null || !logical.logical || child.size == 0) continue;
                if (logical.offset < part.offset || logical.offset > uint64.MAX - child.size)
                    throw new IOError.INVALID_DATA ("A logical partition has invalid geometry.");
                end = uint64.max (end, logical.offset + child.size);
            }
            uint64 minimum = end - part.offset;
            if (minimum % sector != 0) minimum += sector - minimum % sector;
            return minimum;
        }

        public static uint64 maximum_resize (StorageBlock disk, StorageBlock target) throws Error {
            var part = target.partition;
            var parent = target.parent as StorageBlock;
            if (disk.table == null || part == null || parent == null || part.offset >= disk.size)
                throw new IOError.NOT_SUPPORTED ("The partition resize boundary is unavailable.");
            uint64 limit = part.logical ? parent.partition.offset + parent.size : disk.size;
            foreach (var sibling in disk.table.partitions) {
                if (sibling == target || sibling.parent != parent || sibling.partition == null) continue;
                if (sibling.partition.offset > part.offset) limit = uint64.min (limit, sibling.partition.offset);
            }
            if (limit <= part.offset) throw new IOError.INVALID_DATA ("The adjacent partition geometry is invalid.");
            uint64 maximum = limit - part.offset;
            uint64 sector = disk.logical_sector_size;
            return sector == 0 ? maximum : maximum - maximum % sector;
        }

        public static Extent[] normalize (uint64 start, uint64 end, Extent[] occupied) {
            Extent[] clipped = {};
            if (start >= end) return clipped;
            foreach (var extent in occupied) {
                if (extent.offset >= end || extent.size == 0) continue;
                uint64 limit = extent.offset + uint64.min (extent.size, end - extent.offset);
                uint64 first = uint64.max (start, extent.offset);
                if (limit > first) clipped += Extent (first, limit - first);
            }
            for (int i = 1; i < clipped.length; i++) {
                Extent item = clipped[i];
                int j = i;
                while (j > 0 && clipped[j - 1].offset > item.offset) {
                    clipped[j] = clipped[j - 1];
                    j--;
                }
                clipped[j] = item;
            }
            Extent[] merged = {};
            foreach (var extent in clipped) {
                int last = merged.length - 1;
                if (last < 0 || extent.offset > merged[last].offset + merged[last].size) {
                    merged += extent;
                } else {
                    uint64 limit = uint64.max (extent.offset + extent.size,
                        merged[last].offset + merged[last].size);
                    merged[last].size = limit - merged[last].offset;
                }
            }
            return merged;
        }

        public static Extent[] gaps (uint64 start, uint64 end, Extent[] occupied) {
            Extent[] result = {};
            uint64 cursor = start;
            foreach (var extent in normalize (start, end, occupied)) {
                if (extent.offset > cursor) result += Extent (cursor, extent.offset - cursor);
                cursor = extent.offset + extent.size;
            }
            if (cursor < end) result += Extent (cursor, end - cursor);
            return result;
        }

        public static int pixel (uint64 offset, uint64 capacity, int width) {
            if (capacity == 0 || width <= 0) return 0;
            return (int) (((double) uint64.min (offset, capacity) / (double) capacity) * width);
        }
    }
}
