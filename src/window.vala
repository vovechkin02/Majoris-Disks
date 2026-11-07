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
        private string? requested_drive;
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
            drive_view.lvm_rename_requested.connect (rename_logical_volume);
            drive_view.raid_check_requested.connect (start_raid_check);
            drive_view.btrfs_subvolumes_requested.connect (list_btrfs_subvolumes);
            drive_view.mount_options_requested.connect (edit_mount_options);
            drive_view.encryption_requested.connect (manage_encryption);
            drive_view.passphrase_requested.connect (change_passphrase);
            drive_view.encryption_options_requested.connect (edit_encryption_options);
            drive_view.detach_image_requested.connect (detach_image);
            drive_view.backup_requested.connect (choose_backup);
            drive_view.restore_requested.connect (choose_restore);
            drive_view.benchmark_requested.connect ((drive) => new BenchmarkDialog (backend, drive).present (this));
            drive_view.health_requested.connect (show_health);
            drive_view.drive_action_requested.connect (confirm_drive_action);
            drive_view.drive_settings_requested.connect (show_drive_settings);
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
                backend.modify_partitioning.begin (block, "ownership", identity, "", dialog.recursive_change, "",
                    (obj, result) => {
                        pending.remove (block.path);
                        try {
                            var outcome = backend.modify_partitioning.end (result);
                            drive_view.invalidate_usage (block);
                            if (outcome.status == StorageOperationStatus.NEEDS_ATTENTION || outcome.partial)
                                show_check_message ("Ownership operation needs attention", operation_result_details (outcome));
                            else notifications.add_toast (new Adw.Toast ("Filesystem ownership updated"));
                        } catch (Error error) {
                            show_check_message ("Could not change ownership", operation_error (error));
                        }
                    });
            });
            dialog.present (this);
        }
        private void start_raid_check (StorageBlock block) {
            if (pending.contains (block.path)) return;
            pending.insert (block.path, block);
            backend.start_raid_check.begin (block, (obj, result) => {
                pending.remove (block.path);
                try {
                    backend.start_raid_check.end (result);
                    notifications.add_toast (new Adw.Toast ("RAID consistency check started"));
                } catch (Error error) {
                    show_check_message ("Could not confirm the RAID consistency check", operation_error (error));
                }
            });
        }

        private void list_btrfs_subvolumes (StorageBlock block) {
            backend.list_btrfs_subvolumes.begin (block, (obj, result) => {
                try {
                    string[] entries = backend.list_btrfs_subvolumes.end (result);
                    show_check_message ("Btrfs Subvolumes",
                        entries.length == 0 ? "No subvolumes were reported." : string.joinv ("\n", entries));
                } catch (Error error) {
                    show_check_message ("Could not list Btrfs subvolumes", operation_error (error));
                }
            });
        }

        private void rename_logical_volume (StorageBlock block) {
            var volume = block.logical_volume;
            if (volume == null) return;
            string identity = backend.modification_identity (block);
            var dialog = new LvmRenameDialog (volume.name, block.preferred);
            dialog.response.connect ((response) => {
                if (response != "apply" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.rename_logical_volume.begin (block, dialog.new_name, identity, (obj, result) => {
                    pending.remove (block.path);
                    try {
                        backend.rename_logical_volume.end (result);
                        notifications.add_toast (new Adw.Toast ("Logical volume renamed"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm the logical volume rename", operation_error (error));
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
                backend.modify_partitioning.begin (block, "label", identity, dialog.label_text, false, "", (obj, result) => {
                    pending.remove (block.path);
                    try {
                        var outcome = backend.modify_partitioning.end (result);
                        drive_view.invalidate_usage (block);
                        if (outcome.status == StorageOperationStatus.NEEDS_ATTENTION || outcome.partial)
                            show_check_message ("Label operation needs attention", operation_result_details (outcome));
                        else notifications.add_toast (new Adw.Toast ("Filesystem label updated"));
                    } catch (Error error) {
                        show_check_message ("Could not update the filesystem label", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }
        private void edit_mount_options (StorageBlock block) {
            var dialog = new MountOptionsDialog (block, backend.modification_identity (block));
            dialog.response.connect ((response) => {
                if (response != "apply" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.configure_mount.begin (block, dialog.enabled, dialog.startup_mount,
                    dialog.mount_point, dialog.filesystem_type, dialog.mount_options, dialog.original_item,
                    dialog.confirmed_identity, dialog.confirmed_uuid, (object, result) => {
                        pending.remove (block.path);
                        try { backend.configure_mount.end (result); notifications.add_toast (new Adw.Toast ("Mount configuration updated")); }
                        catch (Error error) { show_check_message ("Could not update mount options", operation_error (error)); }
                    });
            });
            dialog.present (this);
        }
        private void manage_encryption (StorageBlock block, bool unlock) {
            if (pending.contains (block.path)) return;
            string identity = backend.modification_identity (block);
            if (unlock) {
                var dialog = new UnlockVolumeDialog (block);
                dialog.response.connect ((response) => {
                    string passphrase = dialog.passphrase;
                    string[] keyfiles = dialog.keyfiles;
                    bool read_only = dialog.read_only;
                    dialog.clear_secret ();
                    if (response != "unlock" || pending.contains (block.path)) return;
                    pending.insert (block.path, block);
                    backend.unlock_volume.begin (block, passphrase, identity, keyfiles, 0, false, false, read_only, (object, result) => {
                        passphrase = ""; pending.remove (block.path);
                        try {
                            var outcome = backend.unlock_volume.end (result);
                            if (outcome.status == StorageOperationStatus.NEEDS_ATTENTION)
                                show_check_message ("Unlock outcome requires attention", outcome.summary);
                            else notifications.add_toast (new Adw.Toast ("Encrypted volume unlocked"));
                        } catch (Error error) {
                            show_check_message ("Could not unlock the volume", operation_error (error));
                        }
                    });
                });
                dialog.present (this);
                return;
            }
            var confirmation = new LockVolumeConfirmationDialog ();
            confirmation.response.connect ((response) => {
                if (response != "lock" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.lock_volume.begin (block, identity, (object, result) => {
                    pending.remove (block.path);
                    try {
                        var outcome = backend.lock_volume.end (result);
                        if (outcome.status == StorageOperationStatus.NEEDS_ATTENTION)
                            show_check_message ("Lock outcome requires attention", outcome.summary +
                                (outcome.technical_error == "" ? "" : "\n\n" + outcome.technical_error));
                        else notifications.add_toast (new Adw.Toast ("Encrypted volume locked"));
                    } catch (Error error) {
                        show_check_message ("Could not lock the volume", operation_error (error));
                    }
                });
            });
            confirmation.present (this);
        }
        private void change_passphrase (StorageBlock block) {
            if (pending.contains (block.path)) return;
            string identity = backend.modification_identity (block);
            var dialog = new ChangePassphraseDialog (block);
            dialog.response.connect ((response) => {
                if (response != "change" || pending.contains (block.path)) return;
                string current_secret = dialog.current_passphrase;
                string replacement = dialog.new_passphrase;
                dialog.clear_secrets ();
                pending.insert (block.path, block);
                backend.change_passphrase.begin (block, current_secret, replacement, identity, (object, result) => {
                    current_secret = ""; replacement = ""; pending.remove (block.path);
                    try {
                        backend.change_passphrase.end (result);
                        notifications.add_toast (new Adw.Toast ("Encryption passphrase changed"));
                    } catch (Error error) {
                        show_check_message ("Could not change the passphrase", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }
        private void edit_encryption_options (StorageBlock block) {
            if (pending.contains (block.path)) return;
            string identity = backend.modification_identity (block);
                var dialog = new EncryptionOptionsDialog (block, identity);
                dialog.response.connect ((response) => {
                    if (response != "apply" || pending.contains (block.path)) return;
                    string passphrase = dialog.new_passphrase;
                    dialog.clear_secret ();
                    pending.insert (block.path, block);
                    backend.configure_encryption.begin (block, dialog.enabled, dialog.unlock_at_startup,
                        dialog.mapping, dialog.crypttab_options, passphrase, dialog.original_item,
                        dialog.confirmed_identity, dialog.confirmed_uuid, (source, completed) => {
                            passphrase = ""; pending.remove (block.path);
                            try {
                                backend.configure_encryption.end (completed);
                                notifications.add_toast (new Adw.Toast ("Encryption options updated"));
                            } catch (Error error) {
                                show_check_message ("Could not update encryption options", operation_error (error));
                            }
                        });
                });
                dialog.present (this);
        }
        private void show_health (StorageDrive drive) {
            backend.query_health.begin (drive, true, (object, result) => {
                try { new SmartDialog (backend, drive, backend.query_health.end (result)).present (this); }
                catch (Error error) { show_check_message ("Could not read drive health", operation_error (error)); }
            });
        }
        private void confirm_drive_action (StorageDrive drive, string action) {
            void run () {
                backend.drive_action.begin (drive, action, (object, result) => {
                    try {
                        backend.drive_action.end (result);
                        notifications.add_toast (new Adw.Toast (action == "Eject" ? "Drive ejected" :
                            action == "PowerOff" ? "Drive powered off" : action == "PmStandby" ?
                            "Drive entered standby" : "Drive awakened"));
                    } catch (Error error) { show_check_message ("Drive action failed", operation_error (error)); }
                });
            }
            if (action != "Eject" && action != "PowerOff") { run (); return; }
            var dialog = new HardwareActionConfirmationDialog ();
            dialog.heading = action == "Eject" ? "Eject this drive?" : "Safely power off this drive?";
            dialog.body = "Active filesystems will be safely unmounted first. System-critical storage is protected.";
            dialog.response.connect ((response) => { if (response == "continue") run (); });
            dialog.present (this);
        }

        private void show_drive_settings (StorageDrive drive) {
            var dialog = new DriveSettingsDialog (drive);
            dialog.response.connect ((response) => {
                if (response != "apply") return;
                dialog.set_response_enabled ("apply", false);
                backend.set_drive_configuration.begin (drive, dialog.baseline,
                    dialog.standby_intent, dialog.standby_value,
                    dialog.apm_intent, dialog.apm_value, dialog.aam_intent, dialog.aam_value,
                    dialog.write_cache_intent, dialog.write_cache_value,
                    dialog.read_lookahead_intent, dialog.read_lookahead_value, (object, result) => {
                        try {
                            backend.set_drive_configuration.end (result);
                            notifications.add_toast (new Adw.Toast ("Drive settings saved"));
                            dialog.force_close ();
                        } catch (Error error) {
                            dialog.set_response_enabled ("apply", true);
                            var failure = new OperationResultDialog () {
                                heading = "Could not save drive settings", body = operation_error (error)
                            };
                            failure.present (this);
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
                string encryption_secret = volume ? ((FormatVolumeDialog) dialog).encryption_passphrase : "";
                if (volume) ((FormatVolumeDialog) dialog).clear_secret ();
                backend.modify_partitioning.begin (block, backend_command, identity, format_label, false, encryption_secret, (obj, result) => {
                    encryption_secret = "";
                    pending.remove (block.path);
                    try {
                        var outcome = backend.modify_partitioning.end (result);
                        drive_view.invalidate_usage (block);
                        if (outcome.status == StorageOperationStatus.NEEDS_ATTENTION || outcome.partial)
                            show_check_message ("Storage operation needs attention", operation_result_details (outcome));
                        else notifications.add_toast (new Adw.Toast (volume ? "Volume formatted" : deleting ? "Partition deleted" : "Disk initialized"));
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
                            else if (!result.successful)
                                show_check_message ("Could not resize " + block.preferred, operation_result_details (result));
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
        internal void choose_attach_image () {
            var chooser = new Gtk.FileDialog () { title = "Select a Disk Image" };
            chooser.open.begin (this, null, (object, result) => {
                File file;
                try { file = chooser.open.end (result); } catch (Error error) { return; }
                string name = (file.get_basename () ?? "").down ();
                if (name.has_suffix (".vhd") || name.has_suffix (".vhdx") || name.has_suffix (".qcow2")) {
                    inspect_virtual_image (file);
                    return;
                }
                var confirmation = new DiskImageConfirmation () {
                    heading = "Attach Disk Image?",
                    body = file.get_parse_name () + "\n\nRead/write access allows changes to the image file."
                };
                confirmation.set_response_label ("proceed", "Attach Read-Only");
                confirmation.set_response_appearance ("proceed", Adw.ResponseAppearance.SUGGESTED);
                confirmation.add_response ("writable", "Attach Read/Write");
                confirmation.response.connect ((response) => {
                    if (response == "proceed" || response == "writable") attach_image (file, response == "proceed");
                });
                confirmation.present (this);
            });
        }

        private void attach_image (File file, bool read_only, string? completed = null) {
            backend.attach_disk_image.begin (file, read_only, (object, result) => {
                try {
                    select_drive ("session:" + backend.attach_disk_image.end (result));
                    notifications.add_toast (new Adw.Toast ("Disk image attached"));
                } catch (Error error) {
                    show_check_message (completed == null ? "Could not attach disk image" :
                        completed + ", but attachment failed", error.message);
                }
            });
        }

        private void attach_virtual (File file, bool read_only, string? completed = null) {
            backend.attach_virtual_image.begin (file, read_only, (object, result) => {
                try {
                    select_drive ("session:" + backend.attach_virtual_image.end (result));
                    notifications.add_toast (new Adw.Toast ("Virtual disk attached"));
                } catch (Error error) {
                    show_check_message (completed == null ? "Could not attach virtual disk" :
                        completed + ", but attachment failed", error.message);
                }
            });
        }

        internal void choose_virtual_image () {
            var chooser = new Gtk.FileDialog () { title = "Inspect a Disk Image" };
            chooser.open.begin (this, null, (object, result) => {
                File source;
                try { source = chooser.open.end (result); } catch (Error error) { return; }
                inspect_virtual_image (source);
            });
        }

        private void inspect_virtual_image (File source) {
            VirtualDisk.inspect.begin (source, new Cancellable (), (object, inspected) => {
                try {
                    var info = VirtualDisk.inspect.end (inspected);
                    var dialog = new VirtualImageDialog () {
                        body = "%s\nFormat: %s\nVirtual capacity: %s\nFile size: %s\n\nRead/write access modifies the selected image. Mount only images you trust, even when attached read-only.".printf (
                            source.get_parse_name (), info.format, format_size (info.capacity), format_size (info.file_size))
                    };
                    string? unavailable = VirtualDiskAttachment.unavailable_reason ();
                    bool direct = info.format != "raw" && unavailable == null;
                    dialog.set_response_enabled ("attach-readonly", direct);
                    string? source_path = source.get_path ();
                    dialog.set_response_enabled ("attach-writable", direct && source_path != null &&
                        Posix.access (source_path, Posix.W_OK) == 0);
                    if (unavailable != null) dialog.body += "\n\n" + unavailable + " You can still convert to raw.";
                    dialog.response.connect ((response) => {
                        if (response == "attach-readonly" || response == "attach-writable") {
                            attach_virtual (source, response == "attach-readonly");
                            return;
                        }
                        if (response != "convert") return;
                        string format = dialog.format;
                        bool attach = dialog.attach_copy;
                        var save = new Gtk.FileDialog () { title = "Save Converted Image",
                            initial_name = "Converted" + image_extension (format) };
                        save.save.begin (this, null, (object, saved) => {
                            File target;
                            try { target = save.save.end (saved); } catch (Error error) { return; }
                            write_virtual_image (source, target, format, 0, attach);
                        });
                    });
                    dialog.present (this);
                } catch (Error error) { show_check_message ("Could not inspect the image", error.message); }
            });
        }

        private static string image_extension (string format) {
            return format == "raw" ? ".img" : format == "vpc" ? ".vhd" : "." + format;
        }

        private void write_virtual_image (File? source, File destination, string format, uint64 size, bool attach) {
            var job = backend.jobs.begin_named (source == null ? "Create virtual disk" : "Convert disk image",
                destination.get_parse_name (), {});
            job.cancelable = true;
            backend.jobs.phase (job, StorageJobState.RUNNING, source == null ? "Creating image" : "Converting image");
            VirtualDisk.write_image.begin (source, destination, format, size, job.cancellable,
                (fraction) => backend.jobs.progress (job, "Converting image", fraction, true), (object, result) => {
                var outcome = new StorageOperationResult ();
                try {
                    VirtualDisk.write_image.end (result);
                    outcome.successful = true;
                    outcome.summary = source == null ? "Virtual disk created" : "Disk image converted";
                    notifications.add_toast (new Adw.Toast (outcome.summary));
                    if (attach) {
                        if (format == "raw") attach_image (destination, true, outcome.summary);
                        else attach_virtual (destination, true, outcome.summary);
                    }
                } catch (Error error) {
                    outcome.fail ("Could not write the virtual image", error);
                    show_check_message (outcome.summary, error.message);
                }
                backend.jobs.finish (job, outcome);
            });
        }

        internal void choose_blank_image () {
            var setup = new BlankDiskImageDialog ();
            setup.response.connect ((response) => {
                if (response != "create") return;
                uint64 size = setup.bytes;
                bool attach = setup.attach_after;
                string format = setup.format;
                var chooser = new Gtk.FileDialog () { title = "Save Blank Disk Image", initial_name = "Blank" + image_extension (format) };
                chooser.save.begin (this, null, (object, result) => {
                    File file;
                    try { file = chooser.save.end (result); } catch (Error error) { return; }
                    if (format != "raw") {
                        write_virtual_image (null, file, format, size, attach);
                        return;
                    }
                    DiskImageCopy.create_blank.begin (file, size, null, (object, outcome) => {
                        try {
                            DiskImageCopy.create_blank.end (outcome);
                            notifications.add_toast (new Adw.Toast ("Blank disk image created"));
                            if (attach) attach_image (file, false, "Blank image created");
                        } catch (Error error) { show_check_message ("Could not create blank image", error.message); }
                    });
                });
            });
            setup.present (this);
        }

        private void detach_image (StorageBlock block) {
            backend.detach_disk_image.begin (block, (object, result) => {
                try {
                    backend.detach_disk_image.end (result);
                    notifications.add_toast (new Adw.Toast ("Disk image detached"));
                } catch (Error error) { show_check_message ("Could not detach image", error.message); }
            });
        }

        private void choose_backup (StorageBlock block) {
            string identity = backend.modification_identity (block);
            var chooser = new Gtk.FileDialog () {
                title = "Save Raw Disk Image",
                initial_name = Path.get_basename (block.preferred) + (block.physical_drive?.optical == true ? ".iso" : ".img")
            };
            chooser.save.begin (this, null, (object, result) => {
                File destination;
                try { destination = chooser.save.end (result); } catch (Error error) { return; }
                var confirmation = new DiskImageConfirmation () {
                    heading = "Create Disk Image?",
                    body = "%s · %s\n%s\n\nIf the source is in use, files can change while the image is copied.".printf (
                        block.preferred, format_size (block.size), destination.get_parse_name ())
                };
                confirmation.enable_backup_verification ();
                confirmation.set_response_label ("proceed", "Create Image");
                confirmation.response.connect ((response) => {
                    if (response != "proceed") return;
                    bool verify = confirmation.verify_backup;
                    backend.create_disk_image.begin (block, destination, identity, verify, (object, outcome) => {
                        try {
                            backend.create_disk_image.end (outcome);
                            notifications.add_toast (new Adw.Toast (verify ? "Disk image created and verified" : "Disk image created without readback verification"));
                        } catch (Error error) { show_check_message ("Could not create disk image", error.message); }
                    });
                });
                confirmation.present (this);
            });
        }

        private void choose_restore (StorageBlock block) {
            string identity = backend.modification_identity (block);
            var chooser = new Gtk.FileDialog () { title = "Select Disk Image to Restore" };
            chooser.open.begin (this, null, (object, result) => {
                File source;
                try { source = chooser.open.end (result); } catch (Error error) { return; }
                var details = new StringBuilder ();
                foreach (var node in backend.snapshot.dependencies.descendants (block)) {
                    var child = node as StorageBlock;
                    if (child == null || child == block) continue;
                    details.append ("\n").append (child.preferred).append (" · ").append (format_size (child.size));
                }
                var drive = block.physical_drive;
                var confirmation = new DiskImageConfirmation () {
                    heading = "Overwrite the selected device?",
                    body = "%s\n\nTarget: %s · %s · %s\nSerial: %s\nWWN: %s%s\n\nRestoring this image overwrites existing data.".printf (
                        source.get_parse_name (), block.preferred, drive?.model ?? "Storage device",
                        format_size (block.size), drive?.serial ?? "", drive?.wwn ?? "", details.str)
                };
                confirmation.set_response_label ("proceed", "Restore Image");
                confirmation.set_response_appearance ("proceed", Adw.ResponseAppearance.DESTRUCTIVE);
                confirmation.response.connect ((response) => {
                    if (response != "proceed") return;
                    backend.restore_disk_image.begin (block, source, identity, (object, outcome) => {
                        try {
                            var restored = backend.restore_disk_image.end (outcome);
                            if (restored.successful) notifications.add_toast (new Adw.Toast (restored.summary));
                            else show_check_message ("Disk image restoration", operation_result_details (restored));
                        } catch (Error error) { show_check_message ("Could not restore disk image", error.message); }
                    });
                });
                confirmation.present (this);
            });
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

        internal void select_drive (string identity) {
            requested_drive = identity;
            update_devices ();
        }

        private void update_devices () {
            updating = true;
            DeviceRow? chosen = null;
            for (int i = 0; i < backend.snapshot.devices.get_n_items (); i++) {
                var row = (DeviceRow) sidebar.get_row_at_index (i);
                row.update ();
                if (row.drive.path == selected) chosen = row;
            }
            if (requested_drive != null) {
                for (int i = 0; i < backend.snapshot.devices.get_n_items (); i++) {
                    var row = (DeviceRow) sidebar.get_row_at_index (i);
                    if (DriveHealth.identity (row.drive) != requested_drive) continue;
                    chosen = row;
                    requested_drive = null;
                    split.show_content = true;
                    break;
                }
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

    [GtkTemplate (ui = "/com/majoris/disks/ui/mount-options-dialog.ui")]
    public class MountOptionsDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow entry;
        [GtkChild] private unowned Adw.SwitchRow custom;
        [GtkChild] private unowned Adw.SwitchRow startup;
        [GtkChild] private unowned Adw.EntryRow directory;
        [GtkChild] private unowned Adw.EntryRow filesystem;
        [GtkChild] private unowned Adw.EntryRow options;
        [GtkChild] private unowned Adw.EntryRow display_name;
        [GtkChild] private unowned Adw.ComboRow files_visibility;
        [GtkChild] private unowned Adw.ActionRow identifier;
        public bool enabled { get { return custom.active; } }
        public bool startup_mount { get { return startup.active; } }
        public string mount_point { owned get { return directory.text; } }
        public string filesystem_type { owned get { return filesystem.text; } }
        private StorageBlock block;
        public string confirmed_identity { get; private set; }
        public string confirmed_uuid { get; private set; }
        private Gtk.StringList entries = new Gtk.StringList (null);
        private Gtk.StringList visibility_choices = new Gtk.StringList ({ "Use system default", "Show", "Hide" });
        public Variant? original_item { owned get {
            return entry.selected < block.mount_configurations.length ? block.mount_configurations[entry.selected].backend_item : null;
        } }
        public string mount_options { owned get {
            try { return MountOptionService.compose (options.text, display_name.text,
                (MountVisibility) files_visibility.selected); }
            catch (Error error) { return options.text; }
        } }
        public MountOptionsDialog (StorageBlock block, string identity) {
            this.block = block; confirmed_identity = identity; files_visibility.model = visibility_choices;
            confirmed_uuid = block.uuid; entry.model = entries;
            foreach (var item in block.mount_configurations) entries.append (item.directory + " · " + item.device);
            entries.append ("New configuration");
            entry.selected = 0;
            entry.notify["selected"].connect (load_selected);
            load_selected ();
            custom.notify["active"].connect (validate); directory.changed.connect (validate);
            filesystem.changed.connect (validate); options.changed.connect (validate);
            display_name.changed.connect (validate); files_visibility.notify["selected"].connect (validate); validate ();
        }
        private void load_selected () {
            var config = entry.selected < block.mount_configurations.length ? block.mount_configurations[entry.selected] : null;
            custom.active = config != null; startup.active = config == null || !("," + config.options + ",").contains (",noauto,");
            directory.text = config?.directory ?? "/mnt/" + (block.label == "" ? block.uuid : block.label);
            filesystem.text = config?.filesystem ?? block.type_id; options.text = config?.options ?? "defaults";
            display_name.text = MountOptionService.display_name (options.text);
            files_visibility.selected = (uint) MountOptionService.visibility (options.text);
            identifier.subtitle = "UUID=" + block.uuid;
            validate ();
        }
        private void validate () {
            bool fields = custom.active;
            startup.sensitive = fields; directory.sensitive = fields; filesystem.sensitive = fields; options.sensitive = fields;
            display_name.sensitive = fields; files_visibility.sensitive = fields;
            bool valid = !fields || (Path.is_absolute (directory.text) && !directory.text.contains ("\n") &&
                filesystem.text.strip () != "" && !options.text.contains ("\n"));
            if (valid && fields) {
                try { MountOptionService.compose (options.text, display_name.text,
                    (MountVisibility) files_visibility.selected); }
                catch (Error error) { valid = false; }
            }
            set_response_enabled ("apply", valid);
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/virtual-image-dialog.ui")]
    internal class VirtualImageDialog : Adw.AlertDialog {
        [GtkChild] private unowned Gtk.DropDown format_choice;
        [GtkChild] private unowned Adw.SwitchRow attach;
        public string format { owned get { return disk_image_format (format_choice.selected); } }
        public bool attach_copy { get { return attach.sensitive && attach.active; } }

        construct {
            format_choice.notify["selected"].connect (() => {
                string? unavailable = VirtualDiskAttachment.unavailable_reason ();
                attach.sensitive = format_choice.selected == 0 || unavailable == null;
                attach.subtitle = attach.sensitive ? "" : unavailable;
            });
        }
    }

    internal string disk_image_format (uint choice) {
        switch (choice) {
            case 1: return "vpc";
            case 2: return "vhdx";
            case 3: return "qcow2";
            default: return "raw";
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/create-blank-image-dialog.ui")]
    internal class BlankDiskImageDialog : Adw.AlertDialog {
        [GtkChild] private unowned Gtk.SpinButton size;
        [GtkChild] private unowned Gtk.DropDown unit;
        [GtkChild] private unowned Adw.SwitchRow attach;
        [GtkChild] private unowned Gtk.DropDown format_choice;
        public string format { owned get { return disk_image_format (format_choice.selected); } }
        public uint64 bytes { get { return (uint64) size.get_value_as_int () * (unit.selected == 0 ? 1048576 : 1073741824); } }
        public bool attach_after { get { return attach.sensitive && attach.active; } }

        construct {
            format_choice.sensitive = VirtualDisk.available ();
            format_choice.notify["selected"].connect (() => {
                string? unavailable = VirtualDiskAttachment.unavailable_reason ();
                attach.sensitive = format_choice.selected == 0 || unavailable == null;
                attach.subtitle = attach.sensitive ? "" : unavailable;
            });
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/disk-image-confirmation.ui")]
    internal class DiskImageConfirmation : Adw.AlertDialog {
        [GtkChild] private unowned Adw.SwitchRow verify;
        public bool verify_backup { get { return verify.active; } }
        public void enable_backup_verification () { verify.visible = true; }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/unlock-volume-dialog.ui")]
    public class UnlockVolumeDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.PasswordEntryRow secret;
        [GtkChild] private unowned Adw.SwitchRow use_keyfile;
        [GtkChild] private unowned Adw.SwitchRow read_only_row;
        [GtkChild] private unowned Adw.ActionRow keyfile_row;
        [GtkChild] private unowned Gtk.Button choose_keyfile;
        private string[] selected_keyfiles = {};
        private bool closed = false;

        public string passphrase { owned get { return use_keyfile.active ? "" : secret.text; } }
        public string[] keyfiles { owned get { return use_keyfile.active ? selected_keyfiles.copy () : new string[0]; } }
        public bool read_only { get { return read_only_row.active; } }

        public UnlockVolumeDialog (StorageBlock block) {
            body = "%s · %s".printf (block.preferred, format_size (block.size));
            use_keyfile.visible = block.type_id == "crypto_LUKS";
            read_only_row.active = block.read_only;
            read_only_row.sensitive = !block.read_only;
            secret.changed.connect (validate);
            use_keyfile.notify["active"].connect (() => {
                secret.text = "";
                selected_keyfiles = {};
                keyfile_row.subtitle = "None selected";
                secret.visible = !use_keyfile.active;
                keyfile_row.visible = use_keyfile.active;
                validate ();
            });
            choose_keyfile.clicked.connect (select_keyfile);
            validate ();
        }
        private void validate () {
            set_response_enabled ("unlock",
                use_keyfile.active ? selected_keyfiles.length == 1 : secret.text.length > 0);
        }
        private void select_keyfile () {
            var chooser = new Gtk.FileDialog (); chooser.title = "Select a LUKS keyfile";
            chooser.open.begin (null, null, (object, result) => {
                try {
                    var file = chooser.open.end (result); string? path = file.get_path ();
                    if (closed || !use_keyfile.active || path == null || path == "") return;
                    selected_keyfiles = { path };
                    keyfile_row.subtitle = file.get_basename ();
                    validate ();
                } catch (Error error) {}
            });
        }
        public void clear_secret () { closed = true; secret.text = ""; selected_keyfiles = {}; }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/lock-volume-confirmation-dialog.ui")]
    public class LockVolumeConfirmationDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/hardware-action-confirmation-dialog.ui")]
    public class HardwareActionConfirmationDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/change-passphrase-dialog.ui")]
    public class ChangePassphraseDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.PasswordEntryRow current_secret;
        [GtkChild] private unowned Adw.PasswordEntryRow new_secret;
        [GtkChild] private unowned Adw.PasswordEntryRow confirmation;
        public string current_passphrase { owned get { return current_secret.text; } }
        public string new_passphrase { owned get { return new_secret.text; } }
        public ChangePassphraseDialog (StorageBlock block) {
            body = "%s · %s\n\nPersistent automatic-unlock configuration may also need to be updated."
                .printf (block.preferred, format_size (block.size));
            current_secret.changed.connect (validate);
            new_secret.changed.connect (validate);
            confirmation.changed.connect (validate);
            validate ();
        }
        private void validate () {
            bool valid = current_secret.text.length > 0 && new_secret.text.length >= 8 &&
                new_secret.text == confirmation.text && new_secret.text != current_secret.text;
            set_response_enabled ("change", valid);
        }
        public void clear_secrets () {
            current_secret.text = ""; new_secret.text = ""; confirmation.text = "";
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/encryption-options-dialog.ui")]
    public class EncryptionOptionsDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow entry;
        [GtkChild] private unowned Adw.SwitchRow custom;
        [GtkChild] private unowned Adw.SwitchRow startup;
        [GtkChild] private unowned Adw.EntryRow mapping_name;
        [GtkChild] private unowned Adw.EntryRow options;
        [GtkChild] private unowned Adw.PasswordEntryRow secret;
        [GtkChild] private unowned Adw.ActionRow keyfile;
        [GtkChild] private unowned Adw.ActionRow identifier;
        public bool enabled { get { return custom.active; } }
        public bool unlock_at_startup { get { return startup.active; } }
        public string mapping { owned get { return mapping_name.text.strip (); } }
        public string crypttab_options { owned get { return options.text; } }
        public string new_passphrase { owned get { return secret.text; } }
        public string confirmed_identity { get; private set; }
        public string confirmed_uuid { get; private set; }
        private StorageBlock block;
        private Gtk.StringList entries = new Gtk.StringList (null);
        public Variant? original_item { owned get {
            return entry.selected < block.encryption_configurations.length ?
                block.encryption_configurations[entry.selected].backend_item : null;
        } }
        public EncryptionOptionsDialog (StorageBlock block, string identity) {
            this.block = block;
            confirmed_identity = identity; confirmed_uuid = block.uuid;
            entry.model = entries;
            foreach (var configuration in block.encryption_configurations)
                entries.append (configuration.name + " · " + configuration.device);
            entries.append ("New configuration"); entry.selected = 0;
            identifier.subtitle = "UUID=" + block.uuid;
            entry.notify["selected"].connect (load_selected);
            custom.notify["active"].connect (validate); startup.notify["active"].connect (validate);
            mapping_name.changed.connect (validate); options.changed.connect (validate); secret.changed.connect (validate);
            load_selected ();
        }
        private void load_selected () {
            var configuration = entry.selected < block.encryption_configurations.length ?
                block.encryption_configurations[entry.selected] : null;
            custom.active = configuration != null;
            mapping_name.text = configuration?.name ?? "luks-" + block.uuid;
            options.text = configuration?.options ?? (block.physical_drive?.removable == true ? "nofail,noauto" : "nofail");
            startup.active = !("," + options.text + ",").contains (",noauto,");
            keyfile.subtitle = configuration == null || configuration.passphrase_path == "" ? "None" :
                configuration.passphrase_path;
            secret.text = ""; validate ();
        }
        private void validate () {
            bool fields = custom.active;
            startup.sensitive = fields; mapping_name.sensitive = fields; options.sensitive = fields;
            secret.sensitive = fields;
            bool valid = !fields || (mapping_name.text.strip () != "" && !mapping_name.text.contains ("/") &&
                !mapping_name.text.contains (",") && !mapping_name.text.contains (" "));
            if (valid && fields) {
                try { MountOptionService.normalize (options.text, startup.active); }
                catch (Error error) { valid = false; }
            }
            set_response_enabled ("apply", valid);
        }
        public void clear_secret () { secret.text = ""; }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/drive-settings-dialog.ui")]
    public class DriveSettingsDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.SwitchRow standby_enabled;
        [GtkChild] private unowned Adw.SpinRow standby;
        [GtkChild] private unowned Adw.SwitchRow apm_enabled;
        [GtkChild] private unowned Adw.SpinRow apm;
        [GtkChild] private unowned Adw.SwitchRow aam_enabled;
        [GtkChild] private unowned Adw.SpinRow aam;
        [GtkChild] private unowned Adw.SwitchRow write_cache_enabled;
        [GtkChild] private unowned Adw.SwitchRow write_cache;
        [GtkChild] private unowned Adw.SwitchRow read_lookahead_enabled;
        [GtkChild] private unowned Adw.SwitchRow read_lookahead;

        public Variant baseline { get; private set; }
        public StorageSettingIntent standby_intent { get { return integer_intent ("ata-pm-standby", standby_enabled, standby, false); } }
        public int standby_value { get { return (int) standby.value; } }
        public StorageSettingIntent apm_intent { get { return integer_intent ("ata-apm-level", apm_enabled, apm, false); } }
        public int apm_value { get { return (int) apm.value; } }
        public StorageSettingIntent aam_intent { get { return integer_intent ("ata-aam-level", aam_enabled, aam, true); } }
        public int aam_value { get { return (int) aam.value; } }
        public StorageSettingIntent write_cache_intent { get { return boolean_intent ("ata-write-cache-enabled", write_cache_enabled, write_cache); } }
        public bool write_cache_value { get { return write_cache.active; } }
        public StorageSettingIntent read_lookahead_intent { get { return boolean_intent ("ata-read-lookahead-enabled", read_lookahead_enabled, read_lookahead); } }
        public bool read_lookahead_value { get { return read_lookahead.active; } }

        public DriveSettingsDialog (StorageDrive drive) {
            baseline = drive.drive_configuration;
            body = drive.name + (drive.serial == "" ? "" : " · " + drive.serial) +
                "\nSettings are stored by UDisks and may be reapplied when the drive reconnects.";
            setup_integer (drive.drive_configuration, "ata-pm-standby", standby_enabled, standby, 120);
            setup_integer (drive.drive_configuration, "ata-apm-level", apm_enabled, apm, 127);
            setup_integer (drive.drive_configuration, "ata-aam-level", aam_enabled, aam, 254);
            setup_boolean (drive.drive_configuration, "ata-write-cache-enabled", write_cache_enabled, write_cache, true);
            setup_boolean (drive.drive_configuration, "ata-read-lookahead-enabled", read_lookahead_enabled, read_lookahead, true);
            set_pair_available (standby_enabled, standby, drive.ata_power_management && drive.rotation != 0);
            set_pair_available (apm_enabled, apm, drive.ata_apm_supported);
            set_pair_available (aam_enabled, aam, drive.ata_aam_supported);
            set_pair_available (write_cache_enabled, write_cache, drive.ata_write_cache_supported);
            set_pair_available (read_lookahead_enabled, read_lookahead, drive.ata_read_lookahead_supported);
            standby.notify["value"].connect (update_state); apm.notify["value"].connect (update_state);
            aam.notify["value"].connect (update_state); write_cache.notify["active"].connect (update_state);
            read_lookahead.notify["active"].connect (update_state);
            standby_enabled.notify["active"].connect (update_state); apm_enabled.notify["active"].connect (update_state);
            aam_enabled.notify["active"].connect (update_state); write_cache_enabled.notify["active"].connect (update_state);
            read_lookahead_enabled.notify["active"].connect (update_state);
            update_state ();
        }
        private StorageSettingIntent integer_intent (string key, Adw.SwitchRow enabled,
            Adw.SpinRow row, bool encode_aam) {
            var original = baseline.lookup_value (key, VariantType.INT32);
            if (!enabled.active) return original == null ? StorageSettingIntent.UNCHANGED : StorageSettingIntent.RESET;
            int requested = (int) row.value; if (encode_aam && requested < 128) requested = 0;
            return original != null && original.get_int32 () == requested ?
                StorageSettingIntent.UNCHANGED : StorageSettingIntent.SET;
        }
        private StorageSettingIntent boolean_intent (string key, Adw.SwitchRow enabled, Adw.SwitchRow row) {
            var original = baseline.lookup_value (key, VariantType.BOOLEAN);
            if (!enabled.active) return original == null ? StorageSettingIntent.UNCHANGED : StorageSettingIntent.RESET;
            return original != null && original.get_boolean () == row.active ?
                StorageSettingIntent.UNCHANGED : StorageSettingIntent.SET;
        }
        private void update_state () {
            bool changed = standby_intent != StorageSettingIntent.UNCHANGED ||
                apm_intent != StorageSettingIntent.UNCHANGED || aam_intent != StorageSettingIntent.UNCHANGED ||
                write_cache_intent != StorageSettingIntent.UNCHANGED ||
                read_lookahead_intent != StorageSettingIntent.UNCHANGED;
            set_response_enabled ("apply", changed);
            int standby_code = (int) standby.value;
            standby.subtitle = standby_code == 0 ? "Never enter standby" : standby_code <= 240 ?
                "%d minutes %d seconds".printf ((standby_code * 5) / 60, (standby_code * 5) % 60) :
                "Special ATA timeout value %d".printf (standby_code);
            int apm_code = (int) apm.value;
            apm.subtitle = apm_code == 255 ? "APM disabled" : apm_code <= 127 ?
                "%d · power saving with spin-down permitted".printf (apm_code) :
                "%d · performance, spin-down not permitted".printf (apm_code);
            int aam_code = (int) aam.value;
            aam.subtitle = aam_code < 128 ? "AAM disabled" : aam_code == 128 ?
                "128 · quietest" : aam_code == 254 ? "254 · fastest" : aam_code.to_string ();
        }
        private void setup_integer (Variant configuration, string key, Adw.SwitchRow enabled,
            Adw.SpinRow value, int fallback) {
            var current = configuration.lookup_value (key, VariantType.INT32);
            enabled.active = current != null;
            value.value = current?.get_int32 () ?? fallback;
            enabled.notify["active"].connect (() => value.sensitive = enabled.active);
            value.sensitive = enabled.active;
        }
        private void setup_boolean (Variant configuration, string key, Adw.SwitchRow enabled,
            Adw.SwitchRow value, bool fallback) {
            var current = configuration.lookup_value (key, VariantType.BOOLEAN);
            enabled.active = current != null;
            value.active = current?.get_boolean () ?? fallback;
            enabled.notify["active"].connect (() => value.sensitive = enabled.active);
            value.sensitive = enabled.active;
        }
        private void set_pair_available (Gtk.Widget enabled, Gtk.Widget value, bool available) {
            enabled.visible = available; value.visible = available;
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/smart-dialog.ui")]
    public class SmartDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.PreferencesGroup summary_group;
        [GtkChild] private unowned Gtk.ListBox attributes;
        [GtkChild] private unowned Adw.ComboRow selftest_type;
        [GtkChild] private unowned Adw.ActionRow selftest_result;
        [GtkChild] private unowned Gtk.ProgressBar selftest_progress;
        [GtkChild] private unowned Gtk.Button start_selftest;
        [GtkChild] private unowned Gtk.Button stop_selftest;
        private Gtk.StringList test_names = new Gtk.StringList (null);
        private string[] test_types = {};
        private bool test_request_busy;
        public SmartDialog (UDisksService backend, StorageDrive drive, StorageHealthReport report) {
            heading = report.nvme ? "NVMe Health" : "SMART Data";
            body = drive.name + (drive.serial == "" ? "" : " · " + drive.serial);
            add_summary ("Overall assessment", report.overall);
            add_summary ("Temperature", report.temperature);
            add_summary ("Power-on time", report.power_on_hours == 0 ? "Unknown" :
                report.power_on_hours.to_string () + " hours");
            string updated = "Never";
            if (report.updated != 0) {
                var date = new DateTime.from_unix_local ((int64) report.updated);
                updated = date.format ("%c");
            }
            add_summary ("Last updated", updated);
            add_summary ("Self-test", report.selftest + (report.selftest_remaining >= 0 ?
                " · " + report.selftest_remaining.to_string () + "% remaining" : ""));
            update_selftest (drive);
            selftest_type.model = test_names; add_test ("short", "Short"); add_test ("extended", "Extended");
            if (!report.nvme) add_test ("conveyance", "Conveyance");
            ulong backend_handler = backend.changed.connect (() => { update_selftest (drive); });
            closed.connect (() => { backend.disconnect (backend_handler); });
            start_selftest.clicked.connect (() => {
                if (selftest_type.selected >= test_types.length) return;
                set_test_busy (true); string selected = test_types[selftest_type.selected];
                backend.run_selftest.begin (drive, selected, false, (object, result) => {
                    set_test_busy (false);
                    try { backend.run_selftest.end (result); update_selftest (drive); }
                    catch (Error error) { selftest_result.subtitle = error.message; }
                });
            });
            stop_selftest.clicked.connect (() => {
                set_test_busy (true);
                backend.run_selftest.begin (drive, "short", true, (object, result) => {
                    set_test_busy (false);
                    try { backend.run_selftest.end (result); update_selftest (drive); }
                    catch (Error error) { selftest_result.subtitle = error.message; }
                });
            });
            if (report.warnings.length != 0) add_summary ("Critical warnings", string.joinv (", ", report.warnings));
            if (report.nvme) {
                if (report.available_spare >= 0) add_attribute ("Available spare", report.available_spare.to_string () + "%");
                if (report.spare_threshold >= 0) add_attribute ("Spare threshold", report.spare_threshold.to_string () + "%");
                if (report.percentage_used >= 0) add_attribute ("Estimated endurance used", report.percentage_used.to_string () + "%");
                if (report.has_total_data_read) add_attribute ("Data read", format_size (report.total_data_read));
                if (report.has_total_data_written) add_attribute ("Data written", format_size (report.total_data_written));
                if (report.has_power_cycles) add_attribute ("Power cycles", report.power_cycles.to_string ());
                if (report.has_controller_busy_minutes)
                    add_attribute ("Controller busy time", report.controller_busy_minutes.to_string () + " minutes");
                if (report.has_media_errors) add_attribute ("Media/data integrity errors", report.media_errors.to_string ());
                if (report.has_unsafe_shutdowns) add_attribute ("Unsafe shutdowns", report.unsafe_shutdowns.to_string ());
                if (report.has_error_log_entries) add_attribute ("Error log entries", report.error_log_entries.to_string ());
                if (report.temperature_sensors != "") add_attribute ("Temperature sensors", report.temperature_sensors);
            } else foreach (var item in report.attributes) {
                string values = "Raw: %s · Normalised: %s · Worst: %s · Threshold: %s · %s\n%s".printf (
                    item.raw, item.normalized < 0 ? "Unknown" : item.normalized.to_string (),
                    item.worst < 0 ? "Unknown" : item.worst.to_string (),
                    item.threshold < 0 ? "Unknown" : item.threshold.to_string (), item.assessment, item.description);
                add_attribute ("%u · %s".printf (item.id, item.name), values);
            }
        }
        private void add_test (string type, string title) { test_types += type; test_names.append (title); }
        private void set_test_busy (bool busy) {
            test_request_busy = busy;
            start_selftest.sensitive = !busy && selftest_result.subtitle != "inprogress";
            stop_selftest.sensitive = !busy && selftest_result.subtitle == "inprogress";
        }
        private void update_selftest (StorageDrive drive) {
            string status = drive.smart_selftest_status == "" ? "Unknown" : drive.smart_selftest_status;
            selftest_result.subtitle = status;
            bool running = status == "inprogress";
            start_selftest.sensitive = !test_request_busy && !running;
            stop_selftest.sensitive = !test_request_busy && running;
            selftest_progress.visible = running && drive.smart_selftest_remaining >= 0;
            if (selftest_progress.visible) {
                int complete = 100 - drive.smart_selftest_remaining;
                selftest_progress.fraction = complete / 100.0;
                selftest_progress.text = complete.to_string () + "% complete";
            }
        }
        private void add_summary (string title, string value) {
            summary_group.add (new InformationRow (title, value, false));
        }
        private void add_attribute (string title, string value) {
            attributes.append (new InformationRow (title, value, false));
        }
    }

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
    [GtkTemplate (ui = "/com/majoris/disks/ui/lvm-rename-dialog.ui")]
    public class LvmRenameDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.EntryRow entry;
        public string new_name { owned get { return entry.text; } }

        public LvmRenameDialog (string original, string device) {
            body = "Renaming changes the device path for %s. Update any external references that use its current name.".printf (device);
            entry.text = original;
            set_response_enabled ("apply", false);
            entry.changed.connect (() => {
                set_response_enabled ("apply", entry.text != original && UDisksService.valid_lvm_name (entry.text));
            });
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
        [GtkChild] private unowned Adw.SwitchRow encryption_row;
        [GtkChild] private unowned Adw.PasswordEntryRow encryption_secret;
        [GtkChild] private unowned Adw.PasswordEntryRow encryption_confirmation;
        private Gtk.StringList formats = new Gtk.StringList (null);
        private string[] identifiers = {};
        private bool encryption_supported;
        public string filesystem_type { owned get { return identifiers.length == 0 ? "empty" : identifiers[filesystem_row.selected]; } }
        public string volume_label { owned get { return label_row.text; } }
        public bool overwrite { get { return erase_row.active; } }
        public string encryption_passphrase { owned get { return encryption_row.active ? encryption_secret.text : ""; } }

        public FormatVolumeDialog (UDisksService backend, StorageBlock block) {
            target_row.subtitle = "%s · %s · current %s".printf (block.preferred, format_size (block.size),
                block.type_id == "" ? "unformatted" : block.type_id);
            filesystem_row.model = formats;
            add_format ("empty", "Empty (no filesystem)");
            string[] candidates = { "ext4", "btrfs", "xfs", "f2fs", "ntfs", "vfat", "exfat", "udf", "swap" };
            foreach (var candidate in candidates) probe_format.begin (backend, candidate);
            probe_encryption.begin (backend);
            filesystem_row.notify["selected"].connect (validate);
            label_row.changed.connect (validate);
            encryption_row.notify["active"].connect (() => {
                encryption_secret.visible = encryption_row.active;
                encryption_confirmation.visible = encryption_row.active;
                validate ();
            });
            encryption_secret.changed.connect (validate);
            encryption_confirmation.changed.connect (validate);
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

        private async void probe_encryption (UDisksService backend) {
            try {
                var capability = FilesystemCapabilityService.decode (
                    yield backend.query_filesystem_capability ("CanFormat", "crypto_LUKS"));
                encryption_supported = capability.supported; encryption_row.sensitive = capability.supported;
                if (!capability.supported)
                    encryption_row.subtitle = capability.missing_utility == "" ?
                        "Encryption is unavailable through UDisks" : "Requires " + capability.missing_utility;
            } catch (Error error) { encryption_row.subtitle = "Encryption capability could not be detected"; }
        }

        private void validate () {
            string type = filesystem_type;
            if (type == "empty" || type == "swap") {
                encryption_row.active = false;
                encryption_row.sensitive = false;
            } else encryption_row.sensitive = encryption_supported;
            label_row.sensitive = type != "empty" && type != "swap";
            erase_row.sensitive = type != "empty";
            try {
                FilesystemCapabilityService.validate_label (type, label_row.sensitive ? label_row.text : "");
                bool encryption_valid = !encryption_row.active || (encryption_secret.text.length >= 8 &&
                    encryption_secret.text == encryption_confirmation.text);
                set_response_enabled ("format", encryption_valid);
                label_row.remove_css_class ("error");
            } catch (Error error) {
                set_response_enabled ("format", false);
                label_row.add_css_class ("error");
            }
        }
        public void clear_secret () { encryption_secret.text = ""; encryption_confirmation.text = ""; }
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
