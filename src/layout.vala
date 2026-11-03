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
        public static void validate_resize (StorageBlock disk, StorageBlock target, uint64 size) throws Error {
            var table = disk.table;
            var part = target.partition;
            var parent = target.parent as StorageBlock;
            uint64 sector = disk.logical_sector_size;
            if (table == null || part == null || parent == null || part.table_path != disk.path ||
                sector == 0 || disk.size == 0 || target.size == 0 || part.container ||
                (table.scheme != "gpt" && table.scheme != "dos"))
                throw new IOError.NOT_SUPPORTED ("The partition geometry cannot be safely resized.");
            if (size == 0 || size % sector != 0 || part.offset % sector != 0)
                throw new IOError.INVALID_ARGUMENT ("The new size and partition start must be sector aligned.");
            uint64 limit = disk.size;
            if (part.logical) {
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
