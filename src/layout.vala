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
