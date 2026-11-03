namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/partition-map.ui")]
    public class PartitionMap : Gtk.Box {
        [GtkChild] private unowned Gtk.Box tracks;
        private HashTable<string, PartitionSegment> buttons =
            new HashTable<string, PartitionSegment> (str_hash, str_equal);
        private string geometry = "";
        public signal void region_selected (string identity);

        public void update (StorageBlock? disk) {
            var state = new StringBuilder (disk?.path ?? "");
            if (disk != null) {
                append_geometry (state, disk, disk);
                if (disk.table != null)
                    foreach (var block in disk.table.partitions)
                        if (block.partition?.container == true) append_geometry (state, disk, block);
            }
            bool rebuild = geometry != state.str;
            if (rebuild) {
                geometry = state.str;
                Gtk.Widget? child;
                while ((child = tracks.get_first_child ()) != null) tracks.remove (child);
                buttons.remove_all ();
            }
            if (disk == null) return;
            update_track (disk, disk, rebuild);
            if (disk.table != null)
                foreach (var block in disk.table.partitions)
                    if (block.partition?.container == true) update_track (disk, block, rebuild);
        }

        private static uint64 offset (StorageDevice region) {
            var gap = region as StorageFreeSpace;
            var block = region as StorageBlock;
            return gap != null ? gap.offset : block?.partition?.offset ?? 0;
        }

        private static void append_geometry (StringBuilder state, StorageBlock disk, StorageBlock owner) {
            state.append_printf ("|%s:%" + uint64.FORMAT + ":%" + uint64.FORMAT,
                owner.path, offset (owner), owner.size);
            foreach (var region in StorageHierarchy.regions (disk, owner))
                state.append_printf ("|%s:%" + uint64.FORMAT + ":%" + uint64.FORMAT,
                    region.path, offset (region), region.size);
        }

        private void update_track (StorageBlock disk, StorageBlock owner, bool rebuild) {
            uint64 start = offset (owner);
            if (start >= disk.size) return;
            uint64 capacity = uint64.min (owner.size, disk.size - start);
            if (capacity == 0) return;
            var track = rebuild ? new PartitionTrack (capacity) : null;
            uint64 cursor = 0;
            foreach (var region in StorageHierarchy.regions (disk, owner)) {
                uint64 first = offset (region) - start;
                uint64 end = first + uint64.min (region.size, capacity - first);
                first = uint64.max (first, cursor);
                if (end <= first) continue;
                cursor = end;
                var button = buttons.lookup (region.path);
                if (track != null) {
                    button = new PartitionSegment ();
                    button.start = first;
                    button.end = end;
                    string identity = region.path;
                    button.clicked.connect (() => {
                        region_selected (identity);
                        select (identity);
                    });
                    buttons.insert (identity, button);
                    button.set_parent (track);
                }
                button?.describe (region);
            }
            if (track != null) tracks.append (track);
        }

        public void select (string identity) {
            buttons.foreach ((key, button) => { button.active = key == identity; });
        }
    }

    public class PartitionTrack : Gtk.Widget {
        private uint64 capacity;

        public PartitionTrack (uint64 capacity) {
            this.capacity = capacity;
            overflow = Gtk.Overflow.HIDDEN;
        }

        protected override void dispose () {
            Gtk.Widget? child;
            while ((child = get_first_child ()) != null) child.unparent ();
            base.dispose ();
        }

        public override void measure (Gtk.Orientation orientation, int for_size, out int minimum,
                                      out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum = natural = 0;
            minimum_baseline = natural_baseline = -1;
            if (orientation == Gtk.Orientation.HORIZONTAL) return;
            for (var child = get_first_child (); child != null; child = child.get_next_sibling ()) {
                int child_minimum, child_natural;
                child.measure (orientation, -1, out child_minimum, out child_natural, null, null);
                minimum = int.max (minimum, child_minimum);
                natural = int.max (natural, child_natural);
            }
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            for (var child = get_first_child (); child != null; child = child.get_next_sibling ())
                if (child.child_visible) snapshot_child (child, snapshot);
        }
        public override void size_allocate (int width, int height, int baseline) {
            for (var child = get_first_child (); child != null; child = child.get_next_sibling ()) {
                var segment = (PartitionSegment) child;
                int start = PartitionLayoutService.pixel (segment.start, capacity, width);
                int end = PartitionLayoutService.pixel (segment.end, capacity, width);
                segment.child_visible = end > start;
                if (end <= start) continue;
                Gtk.Allocation allocation = { start, 0, end - start, height };
                segment.size_allocate (allocation, -1);
            }
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/partition-segment.ui")]
    public class PartitionSegment : Gtk.ToggleButton {
        [GtkChild] private unowned Gtk.Label caption;
        public uint64 start;
        public uint64 end;

        public void describe (StorageDevice region) {
            caption.label = region is StorageFreeSpace ? "Free" : region.name;
            tooltip_text = region.name + " · " + VolumeRow.describe (region);
            update_property (Gtk.AccessibleProperty.LABEL, region.name,
                             Gtk.AccessibleProperty.DESCRIPTION, VolumeRow.describe (region), -1);
        }
    }
}
