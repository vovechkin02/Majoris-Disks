namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/window.ui")]
    public class DisksWindow : Adw.ApplicationWindow {
        [GtkChild] private unowned Gtk.ListBox sidebar;
        [GtkChild] private unowned Gtk.Button refresh_button;
        [GtkChild] private unowned Adw.NavigationSplitView split;
        [GtkChild] private unowned Gtk.Stack states;
        [GtkChild] private unowned Adw.StatusPage status;
        [GtkChild] private unowned DriveView drive_view;
        [GtkChild] private unowned Adw.ToastOverlay notifications;
        [GtkChild] private unowned Gtk.MenuButton jobs_button;
        private UDisksService backend = new UDisksService ();
        private string selected = "";
        private bool updating;
        private bool close_confirmed;
        private HashTable<string, StorageBlock> pending = new HashTable<string, StorageBlock> (str_hash, str_equal);

        static construct {
            typeof (DriveView).ensure ();
        }

        public DisksWindow (Gtk.Application app) {
            Object (application: app);
            sidebar.bind_model (backend.snapshot.devices, (item) => new DeviceRow ((StorageDrive) item));
            sidebar.set_header_func ((row, before) => {
                var current = (DeviceRow) row;
                var previous = before as DeviceRow;
                if (previous == null || current.drive.category != previous.drive.category) {
                    row.set_header (new SidebarGroupHeading (current.drive.category));
                } else row.set_header (null);
            });
            sidebar.row_selected.connect ((row) => {
                if (updating || row == null) return;
                selected = ((DeviceRow) row).drive.path;
                show_selection ();
                split.show_content = true;
            });
            backend.changed.connect (update_devices);
            drive_view.backend = backend;
            drive_view.action_requested.connect ((block, method) => {
                if (pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.volume_action.begin (block, method, (obj, result) => {
                    pending.remove (block.path);
                    try {
                        backend.volume_action.end (result);
                        drive_view.invalidate_usage (block);
                        notifications.add_toast (new Adw.Toast (method == "Mount" ? "Volume mounted" :
                            method == "Unmount" ? "Volume unmounted" : method == "Start" ? "Swap activated" : "Swap deactivated"));
                    } catch (Error error) {
                        var dialog = new OperationResultDialog () { heading = method == "Mount" ? "Could not mount the volume" :
                            method == "Unmount" ? "Could not unmount the volume" : method == "Start" ? "Could not activate swap" : "Could not deactivate swap",
                            body = operation_error (error) };
                        dialog.present (this);
                    }
                });
            });
            drive_view.partitioning_requested.connect ((block, deleting) => confirm_partitioning (block, deleting));
            drive_view.create_requested.connect (create_partition);
            drive_view.resize_requested.connect (resize_volume);
            drive_view.metadata_requested.connect (edit_partition_metadata);
            drive_view.ownership_requested.connect (confirm_ownership);
            drive_view.label_requested.connect (edit_filesystem_label);
            drive_view.format_requested.connect ((block) => confirm_partitioning (block, false, true));
            var jobs_popover = new JobsPopover (backend);
            jobs_button.popover = jobs_popover;
            backend.jobs.changed.connect (() => {
                jobs_popover.update ();
                jobs_button.visible = backend.jobs.jobs.get_n_items () != 0;
            });
            backend.select_requested.connect ((path) => drive_view.select_identity (path));
            drive_view.check_requested.connect ((block, repair) => {
                if (!repair) {
                    run_maintenance (block, false);
                    return;
                }
                string device = block.preferred;
                string uuid = block.uuid;
                string filesystem = block.type_id;
                uint64 number = block.number;
                uint64 size = block.size;
                var dialog = new RepairConfirmationDialog () {
                    heading = "Repair filesystem?",
                    body = "%s · %s · %s\n\nRepair modifies filesystem structures and may remove damaged files.".printf (
                        device, filesystem, format_size (size))
                };
                dialog.response.connect ((response) => {
                    if (response != "repair") return;
                    if (backend.snapshot.blocks.lookup (block.path) != block || block.preferred != device ||
                        block.uuid != uuid || block.type_id != filesystem || block.number != number || block.size != size) {
                        show_check_message ("Volume changed", "Select the volume again before attempting repair.");
                        return;
                    }
                    run_maintenance (block, true);
                });
                dialog.present (this);
            });
            drive_view.open_failed.connect (() => notifications.add_toast (new Adw.Toast ("Could not open the mount point")));
            refresh_button.clicked.connect (refresh);
            close_request.connect (() => {
                if (close_confirmed || backend.jobs.active_count () == 0) return false;
                var warning = new ActiveJobsDialog ();
                warning.response.connect ((response) => {
                    if (response == "close") { close_confirmed = true; close (); }
                });
                warning.present (this);
                return true;
            });
            refresh ();
        }

        private void edit_partition_metadata (StorageBlock block) {
            var part = block.partition;
            if (part == null) return;
            var disk = backend.snapshot.blocks.lookup (part.table_path);
            string scheme = disk?.table?.scheme ?? "";
            if (scheme != "gpt" && scheme != "dos") return;
            bool gpt = scheme == "gpt";
            string identity = backend.modification_identity (block);
            var dialog = new PartitionMetadataDialog (block, part, gpt);
            dialog.response.connect ((response) => {
                if (response != "apply" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.update_partition_metadata.begin (block, dialog.partition_type, dialog.partition_name,
                    dialog.partition_flags, identity, (obj, result) => {
                        pending.remove (block.path);
                        try {
                            var outcome = backend.update_partition_metadata.end (result);
                            if (outcome.partial) show_check_message ("Partition metadata partially updated",
                                outcome.summary + (outcome.technical_error == "" ? "" : "\n\n" + outcome.technical_error));
                            else notifications.add_toast (new Adw.Toast ("Partition metadata updated"));
                        } catch (Error error) {
                            show_check_message ("Could not update partition metadata", operation_error (error));
                        }
                    });
            });
            dialog.present (this);
        }
        private void confirm_ownership (StorageBlock block) {
            string identity = backend.modification_identity (block);
            var dialog = new OwnershipDialog (block);
            dialog.response.connect ((response) => {
                if (response != "apply" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.modify_partitioning.begin (block, "ownership", identity, "", dialog.recursive_change,
                    (obj, result) => {
                        pending.remove (block.path);
                        try {
                            backend.modify_partitioning.end (result);
                            drive_view.invalidate_usage (block);
                            notifications.add_toast (new Adw.Toast ("Filesystem ownership updated"));
                        } catch (Error error) {
                            show_check_message ("Could not change ownership", operation_error (error));
                        }
                    });
            });
            dialog.present (this);
        }
        private void edit_filesystem_label (StorageBlock block) {
            string identity = backend.modification_identity (block);
            var dialog = new LabelDialog (block);
            dialog.response.connect ((response) => {
                if (response != "apply" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.modify_partitioning.begin (block, "label", identity, dialog.label_text, false, (obj, result) => {
                    pending.remove (block.path);
                    try {
                        backend.modify_partitioning.end (result);
                        drive_view.invalidate_usage (block);
                        notifications.add_toast (new Adw.Toast ("Filesystem label updated"));
                    } catch (Error error) {
                        show_check_message ("Could not update the filesystem label", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }
        private void confirm_partitioning (StorageBlock block, bool deleting, bool volume = false) {
            string identity = backend.modification_identity (block);
            string device = block.preferred;
            var body = new StringBuilder ();
            body.append_printf ("%s · %s · %s", block.physical_drive?.name ?? block.name,
                                format_size (block.size), device);
            var serial = block.physical_drive?.serial ?? "";
            if (serial != "") body.append ("\nSerial " + serial);
            if (block.type_id != "") body.append ("\nCurrent filesystem " + block.type_id);
            if (block.table != null) body.append ("\nCurrent partition table " + block.table.scheme.up ());
            body.append (volume ? "\n\nFormatting will destroy data on this volume." : deleting ? "\n\nDeleting this partition will make its contents inaccessible." :
                "\n\nAll partitions and data on this disk may be lost. GPT is recommended for modern systems. MBR supports older systems. Empty removes the partition table.");
            Adw.AlertDialog dialog;
            if (volume) dialog = new FormatVolumeDialog (backend, block);
            else if (deleting) dialog = new DeleteConfirmationDialog ();
            else dialog = new FormatDiskDialog ();
            dialog.heading = volume ? "Format volume?" : deleting ? "Delete partition?" : "Initialize entire disk?";
            dialog.body = body.str;
            dialog.response.connect ((command) => {
                if (command == "cancel" || pending.contains (block.path)) return;
                string backend_command = command;
                string format_label = "";
                if (!volume && !deleting && ((FormatDiskDialog) dialog).overwrite)
                    backend_command += "-zero";
                if (volume) {
                    var format_dialog = (FormatVolumeDialog) dialog;
                    if (command != "format") return;
                    backend_command = (format_dialog.overwrite ? "format-zero:" : "format:") + format_dialog.filesystem_type;
                    format_label = format_dialog.volume_label;
                }
                pending.insert (block.path, block);
                backend.modify_partitioning.begin (block, backend_command, identity, format_label, false, (obj, result) => {
                    pending.remove (block.path);
                    try {
                        backend.modify_partitioning.end (result);
                        drive_view.invalidate_usage (block);
                        notifications.add_toast (new Adw.Toast (volume ? "Volume formatted" : deleting ? "Partition deleted" : "Disk initialized"));
                    } catch (Error error) {
                        show_check_message ("Could not modify " + device, operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void create_partition (StorageBlock disk, StorageFreeSpace gap) {
            string identity = backend.modification_identity (disk);
            var dialog = new CreatePartitionDialog (backend, disk, gap);
            dialog.response.connect ((response) => {
                if (response != "create" || pending.contains (disk.path)) return;
                pending.insert (disk.path, disk);
                backend.create_partition.begin (disk, gap, dialog.requested_size, dialog.partition_kind,
                    dialog.partition_type, dialog.partition_name, dialog.filesystem_type, dialog.volume_label,
                    identity, (object, async_result) => {
                        pending.remove (disk.path);
                        try {
                            var result = backend.create_partition.end (async_result);
                            if (result.partial || result.status == StorageOperationStatus.NEEDS_ATTENTION)
                                show_check_message (result.status == StorageOperationStatus.NEEDS_ATTENTION ?
                                    "Partition needs attention" : "Partition partially created", operation_result_details (result));
                            else notifications.add_toast (new Adw.Toast (result.summary));
                        } catch (Error error) {
                            show_check_message ("Could not create partition", operation_error (error));
                        }
                    });
            });
            dialog.present (this);
        }

        private void resize_volume (StorageBlock block) {
            string identity = backend.modification_identity (block);
            ResizeVolumeDialog dialog;
            try { dialog = new ResizeVolumeDialog (backend, block); }
            catch (Error error) { show_check_message ("Volume cannot be resized", error.message); return; }
            dialog.response.connect ((response) => {
                if (response != "resize" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.resize_volume.begin (block, dialog.new_size, dialog.resize_filesystem, identity,
                    (object, async_result) => {
                        pending.remove (block.path);
                        try {
                            var result = backend.resize_volume.end (async_result);
                            drive_view.invalidate_usage (block);
                            if (result.partial || result.status == StorageOperationStatus.NEEDS_ATTENTION)
                                show_check_message (result.status == StorageOperationStatus.NEEDS_ATTENTION ?
                                    "Volume needs attention" : "Volume partially resized", operation_result_details (result));
                            else notifications.add_toast (new Adw.Toast (result.summary));
                        } catch (Error error) {
                            show_check_message ("Could not resize volume", operation_error (error));
                        }
                    });
            });
            dialog.present (this);
        }
        private void run_maintenance (StorageBlock block, bool repair) {
            if (pending.contains (block.path)) return;
            pending.insert (block.path, block);
            string device = block.preferred;
            backend.check_filesystem.begin (block, repair, (obj, result) => {
                pending.remove (block.path);
                try {
                    if (backend.check_filesystem.end (result)) {
                        drive_view.invalidate_usage (block);
                        var message = repair ? "Repaired %s." : "%s appears consistent.";
                        notifications.add_toast (new Adw.Toast (message.printf (device)));
                    } else {
                        show_check_message (repair ? "Filesystem repair was unsuccessful" :
                            "Filesystem inconsistencies detected", device);
                    }
                } catch (Error error) {
                    show_check_message ((repair ? "Could not repair " : "Could not check ") + device,
                        operation_error (error));
                }
            });
        }
        private void show_check_message (string title, string body) {
            var dialog = new OperationResultDialog () { heading = title, body = body };
            dialog.present (this);
        }
        private static string operation_result_details (StorageOperationResult result) {
            var details = new StringBuilder (result.summary);
            if (result.completed_steps.length != 0)
                details.append ("\n\nCompleted: ").append (string.joinv (", ", result.completed_steps));
            if (result.actual_state != "") details.append ("\n\nActual state: ").append (result.actual_state);
            if (result.technical_error != "") details.append ("\n\n").append (result.technical_error);
            return details.str;
        }
        private static string operation_error (Error error) {
            string? remote = DBusError.get_remote_error (error);
            if (error is IOError.CANCELLED) return "The storage service disconnected during the operation.";
            if (remote == null) return error.message;
            if (remote.contains ("NotAuthorized") || remote.has_suffix (".AccessDenied"))
                return "Authorization was denied or cancelled.";
            if (remote.has_suffix (".DeviceBusy")) return "The volume is busy. Close files or applications using it.";
            if (remote.has_suffix (".NotSupported") || remote.has_suffix (".OptionNotPermitted"))
                return "The storage backend does not support this operation.";
            if (remote.has_suffix (".UnknownObject")) return "The volume is no longer available.";
            DBusError.strip_remote_error (error);
            return "UDisks could not complete the operation. " + error.message;
        }
        private void refresh () {
            refresh_button.sensitive = false;
            backend.refresh.begin ((obj, result) => {
                refresh_button.sensitive = true;
                try {
                    backend.refresh.end (result);
                } catch (Error error) {
                    update_devices ();
                    notifications.add_toast (new Adw.Toast ("Could not connect to UDisks"));
                }
            });
        }

        private void update_devices () {
            updating = true;
            DeviceRow? chosen = null;
            for (int i = 0; i < backend.snapshot.devices.get_n_items (); i++) {
                var row = (DeviceRow) sidebar.get_row_at_index (i);
                row.update ();
                if (row.drive.path == selected) chosen = row;
            }
            if (chosen == null) chosen = sidebar.get_row_at_index (0) as DeviceRow;
            sidebar.invalidate_headers ();
            sidebar.select_row (chosen);
            if (chosen != null || backend.available ()) selected = chosen?.drive.path ?? "";
            updating = false;
            show_selection ();
        }

        private void show_selection () {
            var row = sidebar.get_selected_row () as DeviceRow;
            if (row == null) {
                drive_view.clear ();
                status.title = backend.available () ? "No storage devices found" : "UDisks is unavailable";
                states.visible_child = status;
                return;
            }
            drive_view.show_drive (row.drive);
            states.visible_child = drive_view;
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/active-jobs-dialog.ui")]
    public class ActiveJobsDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/sidebar-group-heading.ui")]
    public class SidebarGroupHeading : Gtk.Box {
        [GtkChild] private unowned Gtk.Label caption;

        public SidebarGroupHeading (string name) {
            caption.label = name;
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/device-row.ui")]
    public class DeviceRow : Adw.ActionRow {
        [GtkChild] private unowned Gtk.Image icon;
        public StorageDrive drive;

        public DeviceRow (StorageDrive drive) {
            this.drive = drive;
            update ();
        }

        public void update () {
            title = drive.name;
            subtitle = drive.available ? format_size (drive.size) :
                drive.category == "Optical" ? "No media" : "Unavailable";
            icon.icon_name = drive.icon;
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/volume-row.ui")]
    public class VolumeRow : Adw.ActionRow {
        public StorageDevice device;

        public VolumeRow (StorageDevice device) {
            update (device);
        }

        public void update (StorageDevice device) {
            this.device = device;
            title = device.name;
            subtitle = describe (device);
        }

        public static string describe (StorageDevice device) {
            var block = device as StorageBlock;
            var summary = format_size (device.size);
            if (block == null) return summary;
            if (block.partition?.container == true) summary += " · Extended partition";
            if (block.partition?.logical == true) summary += " · Logical partition";
            if (block.type_id != "") summary += " · " + block.type_id;
            if (block.read_only) summary += " · Read-only";
            if (block.encrypted != null) summary += block.encrypted.mapping == null ? " · Locked" : " · Unlocked";
            if (block.has_swap) summary += block.swap_active ? " · Swap active" : " · Swap inactive";
            var fs = block.encrypted?.mapping?.filesystem ?? block.filesystem;
            if (fs != null) summary += fs.mounted ? " · " + string.joinv (", ", fs.mounts) : " · Unmounted";
            return summary;
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/edit-filesystem-dialog.ui")]
    public class LabelDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.EntryRow entry;
        public string label_text { owned get { return entry.text; } }

        public LabelDialog (StorageBlock block) {
            body = block.preferred + " · " + block.type_id;
            entry.text = block.label;
            set_response_enabled ("apply", false);
            string original = block.label;
            entry.changed.connect (() => {
                try {
                    FilesystemCapabilityService.validate_label (block.type_id, entry.text);
                    set_response_enabled ("apply", entry.text != original);
                } catch (Error error) { set_response_enabled ("apply", false); }
            });
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/ownership-dialog.ui")]
    public class OwnershipDialog : Adw.AlertDialog {
        [GtkChild] private unowned Gtk.CheckButton recursive;
        public bool recursive_change { get { return recursive.active; } }

        public OwnershipDialog (StorageBlock block) {
            body = "%s · %s\n\nThe filesystem root directory will belong to you. A recursive change can affect files owned by other users or services.".printf (
                block.preferred, block.type_id);
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/edit-partition-dialog.ui")]
    public class PartitionMetadataDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow type_row;
        [GtkChild] private unowned Adw.EntryRow type_entry;
        [GtkChild] private unowned Adw.EntryRow name_entry;
        [GtkChild] private unowned Gtk.CheckButton bootable;
        [GtkChild] private unowned Gtk.CheckButton required;
        [GtkChild] private unowned Gtk.CheckButton no_block_io;
        [GtkChild] private unowned Gtk.CheckButton legacy_boot;
        private uint64 original_flags;
        private string original_name;
        private string original_type;
        private Gtk.StringList type_names = new Gtk.StringList (null);
        private string[] type_ids = {};
        public string partition_name { owned get { return name_entry.text; } }
        public string partition_type { owned get {
            return type_row.selected < type_ids.length ? type_ids[type_row.selected] : type_entry.text;
        } }
        public bool is_bootable { get { return bootable.active; } }
        public uint64 partition_flags { get {
            uint64 known = required.visible ? (uint64) 7 : (uint64) 0x80;
            uint64 flags = original_flags & ~known;
            if (required.active) flags |= 1;
            if (no_block_io.active) flags |= 2;
            if (legacy_boot.active) flags |= 4;
            if (bootable.active) flags |= 0x80;
            return flags;
        } }

        public PartitionMetadataDialog (StorageBlock block, StoragePartition part, bool gpt) {
            body = block.preferred + (gpt ? " · GPT" : " · MBR\n\nChanging the bootable flag can affect system startup.");
            name_entry.visible = gpt;
            bootable.visible = !gpt;
            required.visible = gpt;
            no_block_io.visible = gpt;
            legacy_boot.visible = gpt;
            original_type = part.type_id;
            type_row.model = type_names;
            if (gpt) {
                add_type ("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "EFI System");
                add_type ("0fc63daf-8483-4772-8e79-3d69d8477de4", "Linux filesystem");
                add_type ("0657fd6d-a4ab-43c4-84e5-0933c84b4f4f", "Linux swap");
                add_type ("e6d6d379-f507-44c2-a23c-238f2a3df928", "Linux LVM");
                add_type ("a19d880f-05fc-4d3b-a006-743f0f84911e", "Linux RAID");
                add_type ("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", "Microsoft basic data");
            } else {
                add_type ("0x83", "Linux filesystem"); add_type ("0x82", "Linux swap");
                add_type ("0x8e", "Linux LVM"); add_type ("0xfd", "Linux RAID autodetect");
                add_type ("0x07", "NTFS / exFAT"); add_type ("0x0c", "FAT32 (LBA)");
            }
            add_type ("", "Other…");
            uint selected_type = (uint) (type_ids.length - 1);
            for (uint i = 0; i + 1 < type_ids.length; i++) if (type_ids[i].down () == original_type.down ()) selected_type = i;
            type_row.selected = selected_type;
            type_entry.text = original_type;
            type_entry.visible = selected_type + 1 == type_ids.length;
            original_name = part.name;
            original_flags = part.flags;
            bool original_bootable = (original_flags & 0x80) != 0;
            name_entry.text = original_name;
            bootable.active = original_bootable;
            required.active = (original_flags & 1) != 0;
            no_block_io.active = (original_flags & 2) != 0;
            legacy_boot.active = (original_flags & 4) != 0;
            set_response_enabled ("apply", false);
            type_entry.changed.connect (update_enabled);
            type_row.notify["selected"].connect (() => { type_entry.visible = type_row.selected + 1 == type_ids.length; update_enabled (); });
            name_entry.changed.connect (update_enabled);
            bootable.toggled.connect (update_enabled);
            required.toggled.connect (update_enabled);
            no_block_io.toggled.connect (update_enabled);
            legacy_boot.toggled.connect (update_enabled);
        }
        private void add_type (string id, string title) { type_ids += id; type_names.append (title); }
        private void update_enabled () {
            string selected_type = partition_type;
            bool valid = selected_type.strip () != "" && selected_type.validate () &&
                (!name_entry.visible || (name_entry.text.validate () && name_entry.text.char_count () <= 36 && !name_entry.text.contains ("\n")));
            set_response_enabled ("apply", valid && (partition_flags != original_flags ||
                name_entry.text != original_name || selected_type != original_type));
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/operation-result-dialog.ui")]
    public class OperationResultDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/repair-confirmation-dialog.ui")]
    public class RepairConfirmationDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/delete-confirmation-dialog.ui")]
    public class DeleteConfirmationDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/format-disk-dialog.ui")]
    public class FormatDiskDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.SwitchRow overwrite_row;
        public bool overwrite { get { return overwrite_row.active; } }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/format-volume-dialog.ui")]
    public class FormatVolumeDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ActionRow target_row;
        [GtkChild] private unowned Adw.ComboRow filesystem_row;
        [GtkChild] private unowned Adw.EntryRow label_row;
        [GtkChild] private unowned Adw.SwitchRow erase_row;
        private Gtk.StringList formats = new Gtk.StringList (null);
        private string[] identifiers = {};
        public string filesystem_type { owned get { return identifiers.length == 0 ? "empty" : identifiers[filesystem_row.selected]; } }
        public string volume_label { owned get { return label_row.text; } }
        public bool overwrite { get { return erase_row.active; } }

        public FormatVolumeDialog (UDisksService backend, StorageBlock block) {
            target_row.subtitle = "%s · %s · current %s".printf (block.preferred, format_size (block.size),
                block.type_id == "" ? "unformatted" : block.type_id);
            filesystem_row.model = formats;
            add_format ("empty", "Empty (no filesystem)");
            string[] candidates = { "ext4", "btrfs", "xfs", "f2fs", "ntfs", "vfat", "exfat", "udf", "swap" };
            foreach (var candidate in candidates) probe_format.begin (backend, candidate);
            filesystem_row.notify["selected"].connect (validate);
            label_row.changed.connect (validate);
            validate ();
        }

        private void add_format (string id, string title) {
            identifiers += id;
            formats.append (title);
        }

        private async void probe_format (UDisksService backend, string type) {
            try {
                var capability = FilesystemCapabilityService.decode (
                    yield backend.query_filesystem_capability ("CanFormat", type));
                if (capability.supported) add_format (type, type == "vfat" ? "FAT/FAT32" : type);
            } catch (Error error) { debug ("Format capability unavailable for %s: %s", type, error.message); }
        }

        private void validate () {
            string type = filesystem_type;
            label_row.sensitive = type != "empty" && type != "swap";
            erase_row.sensitive = type != "empty";
            try {
                FilesystemCapabilityService.validate_label (type, label_row.sensitive ? label_row.text : "");
                set_response_enabled ("format", true);
                label_row.remove_css_class ("error");
            } catch (Error error) {
                set_response_enabled ("format", false);
                label_row.add_css_class ("error");
            }
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/create-partition-dialog.ui")]
    public class CreatePartitionDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ActionRow available_row;
        [GtkChild] private unowned Adw.SpinRow size_row;
        [GtkChild] private unowned Adw.ActionRow remaining_row;
        [GtkChild] private unowned Adw.ComboRow kind_row;
        [GtkChild] private unowned Adw.ComboRow type_row;
        [GtkChild] private unowned Adw.EntryRow custom_type_row;
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.ComboRow filesystem_row;
        [GtkChild] private unowned Adw.EntryRow label_row;
        private StorageBlock disk;
        private StorageFreeSpace gap;
        private Gtk.StringList kinds = new Gtk.StringList (null);
        private PartitionLayoutService.PartitionKind[] kind_ids = {};
        private Gtk.StringList formats = new Gtk.StringList (null);
        private string[] format_ids = {};
        private Gtk.StringList type_names = new Gtk.StringList (null);
        private string[] type_ids = {};
        private const uint64 MIB = 1024 * 1024;

        public uint64 requested_size { get {
            uint64 value = (uint64) size_row.value * MIB;
            return gap.size - uint64.min (gap.size, value) < uint64.max (disk.logical_sector_size, MIB) ? 0 : value;
        } }
        public PartitionLayoutService.PartitionKind partition_kind { get { return kind_ids[kind_row.selected]; } }
        public string partition_type { owned get {
            if (partition_kind == PartitionLayoutService.PartitionKind.MBR_EXTENDED) return "0x05";
            return type_row.selected < type_ids.length ? type_ids[type_row.selected] : custom_type_row.text;
        } }
        public string partition_name { owned get { return name_entry_allowed () ? name_row.text : ""; } }
        public string filesystem_type { owned get { return format_ids[filesystem_row.selected]; } }
        public string volume_label { owned get { return label_row.text; } }

        public CreatePartitionDialog (UDisksService backend, StorageBlock disk, StorageFreeSpace gap) {
            this.disk = disk;
            this.gap = gap;
            kind_row.model = kinds;
            filesystem_row.model = formats;
            type_row.model = type_names;
            available_row.subtitle = "%s at byte offset %s".printf (format_size (gap.size), gap.offset.to_string ());
            double maximum = double.max (1, (double) gap.size / MIB);
            size_row.adjustment.upper = maximum;
            size_row.value = maximum;
            if (disk.table?.scheme == "gpt") add_kind (PartitionLayoutService.PartitionKind.GPT, "GPT partition");
            else if (gap.parent is StorageBlock && ((StorageBlock) gap.parent).partition?.container == true)
                add_kind (PartitionLayoutService.PartitionKind.MBR_LOGICAL, "Logical partition");
            else {
                add_kind (PartitionLayoutService.PartitionKind.MBR_PRIMARY, "Primary partition");
                bool extended = false;
                foreach (var existing in disk.table.partitions) extended |= existing.partition?.container == true;
                if (!extended) add_kind (PartitionLayoutService.PartitionKind.MBR_EXTENDED, "Extended partition");
            }
            if (disk.table?.scheme == "gpt") {
                add_type ("0fc63daf-8483-4772-8e79-3d69d8477de4", "Linux filesystem");
                add_type ("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "EFI System");
                add_type ("0657fd6d-a4ab-43c4-84e5-0933c84b4f4f", "Linux swap");
                add_type ("e6d6d379-f507-44c2-a23c-238f2a3df928", "Linux LVM");
                add_type ("a19d880f-05fc-4d3b-a006-743f0f84911e", "Linux RAID");
                add_type ("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", "Microsoft basic data");
            } else {
                add_type ("0x83", "Linux filesystem"); add_type ("0x82", "Linux swap");
                add_type ("0x8e", "Linux LVM"); add_type ("0xfd", "Linux RAID autodetect");
                add_type ("0x07", "NTFS / exFAT"); add_type ("0x0c", "FAT32 (LBA)");
            }
            add_type ("", "Other…");
            add_format ("empty", "Unformatted");
            string[] candidates = { "ext4", "btrfs", "xfs", "f2fs", "ntfs", "vfat", "exfat", "udf", "swap" };
            foreach (var candidate in candidates) probe_format.begin (backend, candidate);
            kind_row.notify["selected"].connect (validate);
            filesystem_row.notify["selected"].connect (validate);
            size_row.notify["value"].connect (validate);
            name_row.changed.connect (validate);
            label_row.changed.connect (validate);
            type_row.notify["selected"].connect (validate);
            custom_type_row.changed.connect (validate);
            validate ();
        }

        private void add_kind (PartitionLayoutService.PartitionKind id, string title) { kind_ids += id; kinds.append (title); }
        private void add_format (string id, string title) { format_ids += id; formats.append (title); }
        private void add_type (string id, string title) { type_ids += id; type_names.append (title); }
        private bool name_entry_allowed () { return partition_kind == PartitionLayoutService.PartitionKind.GPT; }
        private async void probe_format (UDisksService backend, string type) {
            try {
                var capability = FilesystemCapabilityService.decode (yield backend.query_filesystem_capability ("CanFormat", type));
                if (capability.supported) add_format (type, type == "vfat" ? "FAT/FAT32" : type);
            } catch (Error error) { debug ("Format capability unavailable for %s: %s", type, error.message); }
        }
        private void validate () {
            if (kind_ids.length == 0 || format_ids.length == 0) { set_response_enabled ("create", false); return; }
            name_row.visible = name_entry_allowed ();
            bool extended = partition_kind == PartitionLayoutService.PartitionKind.MBR_EXTENDED;
            filesystem_row.sensitive = !extended;
            type_row.sensitive = !extended;
            custom_type_row.visible = !extended && type_row.selected + 1 == type_ids.length;
            label_row.sensitive = !extended && filesystem_type != "empty" && filesystem_type != "swap";
            remaining_row.subtitle = format_size (gap.size - uint64.min (gap.size, (uint64) size_row.value * MIB));
            try {
                uint64 offset, size;
                PartitionLayoutService.validate_create (disk, gap, requested_size, partition_kind, out offset, out size);
                if (name_entry_allowed () && (name_row.text.char_count () > 36 || !name_row.text.validate ()))
                    throw new IOError.INVALID_ARGUMENT ("The GPT name is invalid.");
                FilesystemCapabilityService.validate_label (filesystem_type, label_row.sensitive ? label_row.text : "");
                if (partition_type.strip () == "" || !partition_type.validate ())
                    throw new IOError.INVALID_ARGUMENT ("The partition type identifier is invalid.");
                set_response_enabled ("create", true);
            } catch (Error error) { set_response_enabled ("create", false); }
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/resize-volume-dialog.ui")]
    public class ResizeVolumeDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ActionRow current_row;
        [GtkChild] private unowned Adw.ActionRow filesystem_type_row;
        [GtkChild] private unowned Adw.ActionRow minimum_row;
        [GtkChild] private unowned Adw.ActionRow maximum_row;
        [GtkChild] private unowned Adw.ActionRow range_row;
        [GtkChild] private unowned Adw.SpinRow size_row;
        [GtkChild] private unowned Adw.SwitchRow filesystem_row;
        [GtkChild] private unowned Adw.ActionRow mode_row;
        [GtkChild] private unowned Adw.ActionRow explanation_row;
        private UDisksService backend;
        private StorageBlock block;
        private uint64 maximum;
        private uint64 sector;
        private uint validation_generation;
        private const uint64 MIB = 1024 * 1024;
        public uint64 new_size { get { return (uint64) size_row.value * MIB; } }
        public bool resize_filesystem { get { return filesystem_row.active; } }

        public ResizeVolumeDialog (UDisksService backend, StorageBlock block) throws Error {
            this.backend = backend; this.block = block;
            var part = block.partition;
            var disk = part == null ? null : backend.snapshot.blocks.lookup (part.table_path);
            if (disk == null) throw new IOError.NOT_SUPPORTED ("The parent partition table is unavailable.");
            maximum = PartitionLayoutService.maximum_resize (disk, block);
            sector = disk.logical_sector_size;
            current_row.subtitle = format_size (block.size);
            bool container = block.partition?.container == true;
            heading = container ? "Resize Extended Partition" : "Resize Volume";
            filesystem_type_row.title = container ? "Contents" : "Filesystem";
            filesystem_type_row.subtitle = container ? "Logical-partition container (not a filesystem)" : block.filesystem == null ?
                (block.type_id == "" ? "Unformatted" : block.type_id) : block.type_id;
            maximum_row.subtitle = format_size (maximum);
            range_row.subtitle = "Awaiting filesystem safety information";
            size_row.adjustment.lower = double.max (1, (double) disk.logical_sector_size / MIB);
            size_row.adjustment.upper = double.max (size_row.adjustment.lower, (double) maximum / MIB);
            size_row.value = (double) block.size / MIB;
            filesystem_row.visible = block.filesystem != null && !container;
            filesystem_row.active = block.filesystem != null;
            size_row.notify["value"].connect (validate);
            filesystem_row.notify["active"].connect (validate);
            ulong changed_handler = backend.changed.connect (() => { validation_generation++; validate (); });
            closed.connect (() => backend.disconnect (changed_handler));
            validate ();
        }
        private async void probe (uint generation, uint64 requested, bool with_filesystem) {
            try {
                var plan = yield backend.resize_plan (block, requested, with_filesystem);
                if (generation != validation_generation) return;
                minimum_row.subtitle = plan.minimum_size == 0 ? "Unavailable" : format_size (plan.minimum_size);
                range_row.subtitle = "%s to %s".printf (
                    format_size (plan.minimum_size == 0 ? sector : plan.minimum_size), format_size (maximum));
                string direction = plan.direction == ResizeDirection.SHRINK ? "Shrink" :
                    plan.direction == ResizeDirection.GROW ? "Grow" : "No size change";
                mode_row.subtitle = plan.supported ? "%s · %s".printf (direction,
                    plan.online ? "online" : plan.requires_unmount ? "offline after unmount" : "partition only") : "Unavailable";
                explanation_row.subtitle = plan.supported ? (plan.requires_check ?
                    "The filesystem will be unmounted, checked, resized, and restored." :
                    plan.online ? "The mounted filesystem supports this operation online." :
                    "The operation fits the verified partition boundary.") : plan.reason;
                set_response_enabled ("resize", plan.supported);
            } catch (Error error) {
                if (generation != validation_generation) return;
                minimum_row.subtitle = "Unavailable";
                mode_row.subtitle = "Unavailable";
                explanation_row.subtitle = error.message;
                set_response_enabled ("resize", false);
            }
        }
        private void validate () {
            bool changed = new_size != block.size && new_size > 0 && new_size <= maximum;
            set_response_enabled ("resize", false);
            uint generation = ++validation_generation;
            if (!changed) {
                explanation_row.subtitle = "Choose a different size.";
                uint64 shrink_probe = block.size > sector ? block.size - sector : block.size;
                probe.begin (generation, shrink_probe, filesystem_row.active);
                return;
            }
            explanation_row.subtitle = "Checking the current device state…";
            probe.begin (generation, new_size, filesystem_row.active);
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/job-row.ui")]
    public class JobRow : Adw.ActionRow {
        [GtkChild] private unowned Gtk.ProgressBar progress;
        [GtkChild] private unowned Gtk.Button cancel;
        private UDisksService backend;
        public StorageJob job;
        public JobRow (UDisksService backend, StorageJob job) {
            this.backend = backend; this.job = job;
            cancel.clicked.connect (() => request_cancel.begin ());
            update ();
        }
        private async void request_cancel () {
            cancel.sensitive = false;
            try { yield backend.cancel_job (job); }
            catch (Error error) { job.error_message = error.message; cancel.tooltip_text = error.message; }
            update ();
        }
        public void update () {
            title = job.operation;
            subtitle = job.target + " · " + job.phase;
            progress.fraction = job.progress_valid ? job.progress : 0.0;
            progress.pulse_step = job.progress_valid ? 0.0 : 0.1;
            if (!job.progress_valid && job.state == StorageJobState.RUNNING) progress.pulse ();
            cancel.visible = job.cancelable && (job.state == StorageJobState.RUNNING || job.state == StorageJobState.CANCELLING);
            cancel.sensitive = job.state == StorageJobState.RUNNING;
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/jobs-popover.ui")]
    public class JobsPopover : Gtk.Popover {
        [GtkChild] private unowned Gtk.ListBox rows;
        [GtkChild] private unowned Gtk.Label empty;
        private UDisksService backend;
        public JobsPopover (UDisksService backend) { this.backend = backend; }
        public void update () {
            uint count = backend.jobs.jobs.get_n_items ();
            empty.visible = count == 0; rows.visible = count != 0;
            for (uint i = 0; i < count; i++) {
                var job = backend.jobs.jobs.get_item (i) as StorageJob;
                var row = rows.get_row_at_index ((int) i) as JobRow;
                if (row == null || row.job != job) { if (row != null) rows.remove (row); row = new JobRow (backend, job); rows.insert (row, (int) i); }
                else row.update ();
            }
            Gtk.ListBoxRow? extra;
            while ((extra = rows.get_row_at_index ((int) count)) != null) rows.remove (extra);
        }
    }

}
