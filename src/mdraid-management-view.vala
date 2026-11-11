namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/mdraid-management-view.ui")]
    internal class MdRaidManagementView : Adw.Dialog {
        [GtkChild] private unowned Adw.ActionRow health;
        [GtkChild] private unowned Adw.ActionRow geometry;
        [GtkChild] private unowned Adw.ActionRow synchronization;
        [GtkChild] private unowned Adw.ActionRow bitmap;
        [GtkChild] private unowned Adw.ActionRow replacement;
        [GtkChild] private unowned Adw.ActionRow spare;
        [GtkChild] private unowned Adw.ActionRow check;
        [GtkChild] private unowned Adw.ActionRow repair;
        [GtkChild] private unowned Adw.ActionRow bitmap_change;
        [GtkChild] private unowned Adw.PreferencesGroup members;
        private Adw.ActionRow[] member_rows = {};
        private UDisksService backend;
        private StorageBlock context;
        private string uuid;
        private string kernel_identity;
        public StorageBlock current_context { get { return context; } }
        private ulong observer;

        public signal void replace_requested ();
        public signal void spare_requested ();
        public signal void remove_requested (StorageBlock block);
        public signal void member_state_requested (StorageBlock block, bool readd);
        public signal void check_requested ();
        public signal void repair_requested ();
        public signal void bitmap_requested (bool enable);

        public MdRaidManagementView (UDisksService backend, StorageBlock context, StorageRaid array) {
            this.backend = backend;
            this.context = context;
            uuid = array.uuid;
            kernel_identity = array.kernel?.identity ?? "";
            replacement.activated.connect (() => replace_requested ());
            spare.activated.connect (() => spare_requested ());
            check.activated.connect (() => check_requested ());
            repair.activated.connect (() => repair_requested ());
            bitmap_change.activated.connect (() => {
                var current = context.raid?.kernel;
                if (current != null) bitmap_requested (MdRaidKernelState.bitmap_kind (current.bitmap) == "none");
            });
            observer = backend.changed.connect (refresh);
            closed.connect (() => {
                backend.disconnect (observer);
                observer = 0;
            });
            refresh ();
        }

        private void refresh () {
            StorageRaid? array = null;
            int matches = 0;
            foreach (var entry in backend.snapshot.advanced.get_values ()) {
                var candidate = entry as StorageRaid;
                if (candidate?.uuid != uuid) continue;
                matches++;
                array = candidate;
            }
            if (uuid == "" || matches != 1 || (kernel_identity != "" && array?.running == true &&
                array.kernel?.identity != kernel_identity)) array = null;
            bool live = false;
            if (array != null) {
                foreach (var block in backend.snapshot.blocks.get_values ()) {
                    if (!block.available || block.raid != array) continue;
                    context = block;
                    live = true;
                    break;
                }
            }
            foreach (var row in member_rows) members.remove (row);
            member_rows = {};
            if (array == null || array.uuid != uuid) {
                health.subtitle = "Array identity unavailable";
                geometry.subtitle = synchronization.subtitle = bitmap.subtitle = "";
                replacement.sensitive = spare.sensitive = check.sensitive = repair.sensitive = bitmap_change.sensitive = false;
                return;
            }
            var kernel = array.kernel;
            var topology = array.topology;
            // Keep formatted text in its own branch: Vala can free the owned
            // string early when a nested conditional mixes it with literals.
            string condition;
            if (!array.running) condition = "Stopped";
            else if (kernel == null) condition = "Kernel state unavailable";
            else if (kernel.state == "readonly" || kernel.state == "read-auto") condition = "Read-only";
            else if (topology == null || kernel.degraded != array.degraded.to_string () ||
                !kernel.verify_members (topology)) condition = "Health unverified";
            else if (array.degraded > 0) condition = "%u unavailable slots".printf (array.degraded);
            else condition = topology.synchronized_slots (array.expected_members) ?
                "All required slots synchronized" : "Health unverified";
            health.subtitle = array.uuid + "\n" + condition;
            geometry.subtitle = "%s · %u slots · %s".printf (array.level, array.expected_members, format_size (array.size));
            if (kernel != null)
                geometry.subtitle += "\nMetadata %s · Layout %s · Component %s · Chunk %s".printf (
                    kernel.metadata, kernel.layout != "" ? kernel.layout : "unavailable",
                    format_size (kernel.component_sectors * 512), format_size (kernel.chunk_bytes));
            synchronization.subtitle = kernel != null && kernel.action != "" ? kernel.action :
                array.state != "" ? array.state : "Unknown";
            if (kernel != null && kernel.progress >= 0)
                synchronization.subtitle += " · %.1f%% (%s / %s sectors)".printf (
                    kernel.progress * 100, kernel.completed_sectors.to_string (), kernel.total_sectors.to_string ());
            if (kernel != null && kernel.speed_kib > 0 && kernel.action != "idle")
                synchronization.subtitle += " · %s/s".printf (format_size (kernel.speed_kib * 1024));
            if (kernel != null && kernel.progress >= 0 && kernel.speed_kib > 0 &&
                kernel.completed_sectors < kernel.total_sectors)
                synchronization.subtitle += " · About %s s remaining".printf (
                    ((kernel.total_sectors - kernel.completed_sectors) / 2 / kernel.speed_kib).to_string ());
            if (kernel != null && kernel.mismatch_count != "")
                synchronization.subtitle += "\nMismatch sectors: " + kernel.mismatch_count;
            string kind = MdRaidKernelState.bitmap_kind (kernel?.bitmap ?? array.bitmap_location);
            bitmap.subtitle = "%s · Policy: %s".printf (kind, kernel?.policy ?? "unknown");
            replacement.sensitive = live && backend.can_replace_missing_raid_member (context);
            replacement.subtitle = replacement.sensitive ? "Select a device and review the reconstruction plan" :
                "No verified reconstruction plan for this array state";
            spare.sensitive = live && backend.can_add_raid_spare (context);
            check.sensitive = live && backend.can_check_raid (context);
            repair.sensitive = live && backend.can_repair_raid (context);
            bitmap_change.sensitive = live && backend.can_change_raid_bitmap (context);
            bitmap_change.title = kind == "internal" ? "Disable Internal Bitmap" : "Enable Internal Bitmap";
            if (!array.running) {
                foreach (var block in backend.snapshot.blocks.get_values ()) {
                    if (block.raid_membership != array) continue;
                    var row = new Adw.ActionRow () {
                        title = block.preferred,
                        subtitle = "Discovered member · Slot unverified while stopped",
                        use_markup = false
                    };
                    members.add (row);
                    member_rows += row;
                }
                return;
            }
            if (topology == null) return;
            foreach (var member in topology.members) {
                var block = member.block;
                string slot = member.slot < 0 ? "Unassigned" : "Slot %d".printf (member.slot);
                var row = new Adw.ActionRow () {
                    title = block?.preferred ?? member.path,
                    subtitle = "%s · %s · %s read errors".printf (slot, member.role (), member.read_errors.to_string ()),
                    use_markup = false
                };
                if (!member.known_states ()) row.subtitle += "\nKernel flags " + string.joinv (", ", member.states);
                if (member.metadata_uuid != "") row.subtitle += "\nMember UUID " + member.metadata_uuid;
                if (live && block != null && backend.can_remove_inactive_raid_member (block)) {
                    row.activatable = true;
                    row.subtitle += " · Activate to review removal";
                    row.activated.connect (() => remove_requested (block));
                } else if (live && block != null && backend.can_change_raid_member_state (context, block, false)) {
                    row.activatable = true;
                    row.subtitle += " · Activate to review fault marking";
                    row.activated.connect (() => member_state_requested (block, false));
                }
                members.add (row);
                member_rows += row;
            }
            foreach (var block in backend.snapshot.blocks.get_values ()) {
                if (!live || !backend.can_change_raid_member_state (context, block, true)) continue;
                var row = new Adw.ActionRow () {
                    title = block.preferred,
                    subtitle = "Former member · Activate to review re-addition",
                    use_markup = false,
                    activatable = true
                };
                row.activated.connect (() => member_state_requested (block, true));
                members.add (row);
                member_rows += row;
            }
            foreach (int slot in topology.missing_slots) {
                var row = new Adw.ActionRow () {
                    title = "Slot %d".printf (slot),
                    subtitle = "No verified synchronized member"
                };
                members.add (row);
                member_rows += row;
            }
        }
    }
}
