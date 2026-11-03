namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/drive-view.ui")]
    public class DriveView : Gtk.Box {
        [GtkChild] private unowned Adw.ActionRow summary;
        [GtkChild] private unowned Gtk.Image drive_icon;
        [GtkChild] private unowned Gtk.Button information;
        [GtkChild] private unowned PartitionMap map;
        [GtkChild] private unowned Gtk.ListBox volumes;
        [GtkChild] private unowned Adw.PreferencesGroup properties;
        private GenericArray<InformationRow> metadata = new GenericArray<InformationRow> ();
        [GtkChild] private unowned Gtk.Label usage;
        [GtkChild] private unowned Gtk.Button operation;
        [GtkChild] private unowned Gtk.Button open_files;
        [GtkChild] private unowned Gtk.Button check_filesystem;
        [GtkChild] private unowned Gtk.Button repair_filesystem;
        [GtkChild] private unowned Gtk.Button initialize_disk;
        [GtkChild] private unowned Gtk.Button delete_partition;
        [GtkChild] private unowned Gtk.Button format_volume;
        public signal void format_requested (StorageBlock block);
        public signal void partitioning_requested (StorageBlock block, bool deleting);
        private StorageBlock? selected_block;
        public signal void check_requested (StorageBlock block, bool repair);
        private StorageDrive? current;
        private StorageBlock? target;
        private string method = "";
        private string selected = "";
        private bool updating;
        private FilesystemUsageService usage_service = new FilesystemUsageService ();
        public signal void action_requested (StorageBlock block, string method);
        public signal void open_failed ();

        static construct {
            typeof (PartitionMap).ensure ();
        }

        construct {
            usage_service.updated.connect ((description) => usage.label = description);
            information.clicked.connect (() => {
                if (current != null) new DriveInformationDialog (current).present (this);
            });
            map.region_selected.connect ((identity) => {
                for (int i = 0; ; i++) {
                    var row = volumes.get_row_at_index (i) as VolumeRow;
                    if (row == null) break;
                    if (row.device.path == identity) {
                        volumes.select_row (row);
                        break;
                    }
                }
            });
            volumes.row_selected.connect ((row) => {
                if (!updating) show_volume (row as VolumeRow);
            });
            operation.clicked.connect (() => {
                if (target != null && method != "") action_requested (target, method);
            });
            check_filesystem.clicked.connect (() => {
                if (target != null) check_requested (target, false);
            });
            initialize_disk.clicked.connect (() => {
                var disk = current?.medium;
                if (disk != null) partitioning_requested (disk, false);
            });
            format_volume.clicked.connect (() => {
                if (selected_block != null) format_requested (selected_block);
            });
            delete_partition.clicked.connect (() => {
                if (selected_block != null) partitioning_requested (selected_block, true);
            });
            repair_filesystem.clicked.connect (() => {
                if (target != null) check_requested (target, true);
            });
            open_files.clicked.connect (() => {
                var fs = target?.filesystem;
                if (fs == null || !fs.mounted) return;
                try {
                    AppInfo.launch_default_for_uri (File.new_for_path (fs.mounts[0]).get_uri (), null);
                } catch (Error error) {
                    open_failed ();
                }
            });
        }

        public void clear () {
            current = null;
            show_volume (null);
        }

        public void show_drive (StorageDrive drive) {
            if (current != drive) selected = "";
            current = drive;
            var disk = drive.medium;
            initialize_disk.visible = disk != null && disk.available && !disk.read_only && !disk.system_hint;
            summary.title = drive.name;
            drive_icon.icon_name = drive.icon;
            summary.subtitle = drive.available ? format_size (drive.size) : "No media available";
            if (disk != null) summary.subtitle += " · " + disk.preferred;
            if (disk?.table != null) summary.subtitle += " · " + disk.table.scheme.up ();
            StorageDevice[] ordered = {};
            if (disk != null) {
                foreach (var region in StorageHierarchy.regions (disk, disk)) {
                    ordered += region;
                    var block = region as StorageBlock;
                    if (block?.partition?.container == true) {
                        foreach (var nested in StorageHierarchy.regions (disk, block)) ordered += nested;
                    }
                }
            }

            updating = true;
            VolumeRow? chosen = null;
            for (int i = 0; i < ordered.length; i++) {
                var row = volumes.get_row_at_index (i) as VolumeRow;
                if (row == null || row.device.path != ordered[i].path) {
                    for (int j = i + 1; ; j++) {
                        var existing = volumes.get_row_at_index (j) as VolumeRow;
                        if (existing == null) break;
                        if (existing.device.path == ordered[i].path) {
                            volumes.remove (existing);
                            break;
                        }
                    }
                    row = new VolumeRow (ordered[i]);
                    volumes.insert (row, i);
                } else row.update (ordered[i]);
                if (ordered[i].path == selected) chosen = row;
            }
            Gtk.ListBoxRow? extra;
            while ((extra = volumes.get_row_at_index (ordered.length)) != null) volumes.remove (extra);
            if (chosen == null) chosen = volumes.get_row_at_index (0) as VolumeRow;
            volumes.select_row (chosen);
            map.update (disk);
            updating = false;
            show_volume (chosen);
        }

        private void show_volume (VolumeRow? row) {
            selected = row?.device.path ?? "";
            map.select (selected);
            properties.visible = row != null;
            target = null;
            method = "";
            operation.visible = false;
            open_files.visible = false;
            check_filesystem.visible = false;
            repair_filesystem.visible = false;
            delete_partition.visible = false;
            format_volume.visible = false;
            selected_block = null;
            usage.label = "";
            foreach (var field in metadata) properties.remove (field);
            metadata = new GenericArray<InformationRow> ();
            if (row == null) {
                usage_service.clear ();
                return;
            }
            var block = row.device as StorageBlock;
            if (block == null) {
                usage_service.clear ();
                var gap = (StorageFreeSpace) row.device;
                add_volume_field ("Offset", gap.offset.to_string () + " bytes");
                add_volume_field ("Size", format_size (gap.size));
                add_volume_field ("Allocatable space", "Unconfirmed");
                return;
            }
            selected_block = block;
            format_volume.visible = block.table == null && block.partition?.container != true &&
                block.available && !block.read_only && !block.system_hint && block.filesystem?.mounted != true;
            delete_partition.visible = block.partition != null && !block.partition.container &&
                block.available && !block.read_only && !block.system_hint;
            add_volume_field ("Device", block.preferred, true);
            var part = block.partition;
            if (part != null) {
                add_volume_field ("Partition", part.number.to_string ());
                add_volume_field ("Offset", part.offset.to_string () + " bytes");
                add_volume_field ("Partition type", partition_type (part));
                add_volume_field ("Partition UUID", part.uuid, true);
                var disk = part.logical ? block.parent?.parent as StorageBlock : block.parent as StorageBlock;
                add_volume_field ("Flags", partition_flags (disk?.table?.scheme ?? "", part.flags));
            }
            add_volume_field ("Capacity", format_size (block.size));
            add_volume_field ("Read-only", block.read_only ? "Yes" : "No");
            if (block.raid != null) add_volume_field ("RAID array", block.raid.name + " · " + block.raid.level);
            if (block.raid_membership != null) add_volume_field ("RAID membership", block.raid_membership.name);
            if (block.logical_volume != null) add_volume_field ("Logical volume", block.logical_volume.name);
            if (block.volume_group != null) add_volume_field ("LVM volume group", block.volume_group.name);
            target = block.encrypted?.mapping ?? block;
            if (block.encrypted != null) add_volume_field ("Encryption", target == block ? "Locked" : "Unlocked");
            if (target != block) add_volume_field ("Mapped device", target.preferred, true);
            var fs = target.filesystem;
            if (fs != null) {
                add_volume_field ("Filesystem", target.type_id);
                add_volume_field ("Label", target.label);
                add_volume_field ("Filesystem UUID", target.uuid, true);
                add_volume_field ("Mount points", string.joinv (", ", fs.mounts));
            }
            var capabilities = new StorageCapabilities (target);
            if (capabilities.mount) {
                method = "Mount";
                operation.label = "Mount";
            } else if (capabilities.unmount) {
                method = "Unmount";
                operation.label = "Unmount";
            } else if (capabilities.activate_swap) {
                method = "Start";
                operation.label = "Activate Swap";
            }
            operation.visible = method != "";
            open_files.visible = fs != null && fs.mounted;
            check_filesystem.visible = fs != null && !fs.mounted && target.available && !target.ignored &&
                target.type_id != "" && target.encrypted == null;
            repair_filesystem.visible = check_filesystem.visible && !target.read_only && !target.system_hint;
            if (fs != null) usage.label = usage_service.show (target);
            else usage_service.clear ();
        }

        private void add_volume_field (string title, string value, bool copy = false) {
            if (value == "") return;
            var field = new InformationRow (title, value, copy);
            metadata.add (field);
            properties.add (field);
        }

        private static string partition_type (StoragePartition part) {
            if (part.container) return "Extended partition";
            switch (part.type_id.down ()) {
                case "c12a7328-f81f-11d2-ba4b-00a0c93ec93b":
                case "0xef": return "EFI System Partition";
                case "0fc63daf-8483-4772-8e79-3d69d8477de4":
                case "0x83": return "Linux filesystem";
                case "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f":
                case "0x82": return "Linux swap";
                default: return part.type_id;
            }
        }

        private static string partition_flags (string scheme, uint64 flags) {
            if (flags == 0) return "";
            string[] names = {};
            if (scheme == "dos" && (flags & 0x80) != 0) {
                names += "Bootable";
                flags &= ~((uint64) 0x80);
            }
            if (scheme == "gpt") {
                if ((flags & 1) != 0) names += "Required";
                if ((flags & 2) != 0) names += "No block I/O protocol";
                if ((flags & 4) != 0) names += "Legacy BIOS bootable";
                flags &= ~((uint64) 7);
            }
            if (flags != 0) names += "Other flags (0x%" + uint64.FORMAT_MODIFIER + "x)";
            if (flags != 0) names[names.length - 1] = names[names.length - 1].printf (flags);
            return string.joinv (", ", names);
        }

    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/drive-information-dialog.ui")]
    public class DriveInformationDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.PreferencesGroup fields;

        public DriveInformationDialog (StorageDrive drive) {
            var disk = drive.medium;
            add_field ("Model", drive.model, true);
            add_field ("Vendor", drive.vendor);
            add_field ("Serial", drive.serial, true);
            add_field ("WWN", drive.wwn, true);
            add_field ("Firmware revision", drive.revision);
            add_field ("Device path", disk?.preferred ?? "", true);
            add_field ("Connection", drive.bus);
            add_field ("Device category", drive.category);
            if (drive.optical) add_field ("Optical media", drive.media);
            add_field ("NVMe controller state", drive.nvme_state);
            if (disk != null && disk.logical_sector_size != 0)
                add_field ("Logical sector size", disk.logical_sector_size.to_string () + " bytes");
            if (disk != null && disk.physical_sector_size != 0)
                add_field ("Physical sector size", disk.physical_sector_size.to_string () + " bytes");
            add_field ("Partition scheme", disk?.table?.scheme.up () ?? "");
            if (drive.size != 0)
                add_field ("Capacity", ("%s (%" + uint64.FORMAT + " bytes)").printf (format_size (drive.size), drive.size));
            if (drive.rotation >= 0 && drive.category == "Internal")
                add_field ("Media", drive.rotation == 0 ? "Non-rotating" : "%d RPM".printf (drive.rotation));
            add_field ("Ejectable", drive.ejectable ? "Yes" : "No");
            add_field ("Removable", drive.removable ? "Yes" : "No");
            add_field ("Media available", drive.available ? "Yes" : "No");
            if (disk != null) add_field ("Read-only", disk.read_only ? "Yes" : "No");
            if (drive.smart) add_field ("SMART available", "Yes");
        }

        private void add_field (string title, string value, bool copy = false) {
            if (value == "") return;
            fields.add (new InformationRow (title, value, copy));
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/information-row.ui")]
    public class InformationRow : Adw.ActionRow {
        [GtkChild] private unowned Gtk.Button copy_button;

        public InformationRow (string title, string value, bool copy) {
            this.title = title;
            subtitle = value;
            copy_button.visible = copy;
            copy_button.label = "Copy " + title;
            copy_button.clicked.connect (() => get_clipboard ().set_text (subtitle));
        }
    }
}
