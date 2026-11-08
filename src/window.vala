namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/window.ui")]
    public class DisksWindow : Adw.ApplicationWindow {
        [GtkChild] private unowned Gtk.ListBox sidebar;
        [GtkChild] private unowned Gtk.ListBox advanced_sidebar;
        [GtkChild] private unowned Gtk.ScrolledWindow advanced_view;
        [GtkChild] private unowned Adw.PreferencesGroup advanced_summary;
        [GtkChild] private unowned Adw.PreferencesGroup advanced_members;
        [GtkChild] private unowned Adw.ActionRow advanced_details;
        [GtkChild] private unowned Adw.ActionRow advanced_jobs;
        [GtkChild] private unowned Adw.ActionRow advanced_manage;
        [GtkChild] private unowned Adw.ActionRow advanced_maintenance;
        [GtkChild] private unowned Adw.ActionRow advanced_recovery;
        private string selected_storage = "";
        private StorageBlock? advanced_context;
        private StorageDevice? advanced_device;
        private VolumeRow[] member_rows = {};
        [GtkChild] private unowned Gtk.Button refresh_button;
        [GtkChild] private unowned Adw.NavigationSplitView split;
        [GtkChild] private unowned Gtk.Stack states;
        [GtkChild] private unowned Adw.StatusPage status;
        [GtkChild] private unowned DriveView drive_view;
        [GtkChild] private unowned Adw.ToastOverlay notifications;
        [GtkChild] private unowned Gtk.MenuButton jobs_button;
        private UDisksService backend;
        private string selected = "";
        private string? requested_drive;
        private bool updating;
        private bool close_confirmed;
        private HashTable<string, StorageBlock> pending = new HashTable<string, StorageBlock> (str_hash, str_equal);

        static construct {
            typeof (DriveView).ensure ();
        }

        public DisksWindow (Gtk.Application app, UDisksService? service = null) {
            Object (application: app);
            backend = service ?? new UDisksService ();
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
                selected_storage = "";
                advanced_sidebar.unselect_all ();
                show_selection ();
                split.show_content = true;
            });
            advanced_sidebar.set_header_func ((row, before) => {
                row.set_header (before == null ? new SidebarGroupHeading ("Advanced Storage") : null);
            });
            advanced_sidebar.row_selected.connect ((row) => {
                if (updating || row == null) return;
                selected_storage = storage_key (((VolumeRow) row).device);
                sidebar.unselect_all ();
                show_selection ();
                split.show_content = true;
            });
            advanced_manage.activated.connect (() => {
                var context = advanced_context;
                if (context == null) return;
                if (advanced_device is StorageVolumeGroup) manage_logical_volumes (context);
                else if (advanced_device is StorageRaid) confirm_raid_power (context, context.raid == null);
                else list_btrfs_subvolumes (context);
            });
            advanced_maintenance.activated.connect (() => {
                var context = advanced_context;
                if (context == null) return;
                if (advanced_device is StorageRaid) start_raid_check (context);
                else show_btrfs_allocation (context);
            });
            advanced_recovery.activated.connect (() => {
                var context = advanced_context;
                if (context == null) return;
                if (advanced_device is StorageRaid) confirm_degraded_raid (context);
                else manage_btrfs_balance (context);
            });
            var create_vg = new SimpleAction ("create-vg", null);
            var create_raid = new SimpleAction ("create-raid", null);
            add_action (create_vg);
            add_action (create_raid);
            create_vg.activate.connect (() => create_storage_group (false));
            create_raid.activate.connect (() => create_storage_group (true));
            create_vg.set_enabled (backend.can_create_storage_group (false));
            create_raid.set_enabled (backend.can_create_storage_group (true));
            backend.changed.connect (() => {
                create_vg.set_enabled (backend.can_create_storage_group (false));
                create_raid.set_enabled (backend.can_create_storage_group (true));
                update_devices ();
            });
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
            drive_view.lvm_manage_requested.connect (manage_logical_volumes);
            drive_view.lvm_add_member_requested.connect (add_lvm_physical_volume);
            drive_view.lvm_create_requested.connect ((block) => create_logical_volume (block));
            drive_view.raid_check_requested.connect (start_raid_check);
            drive_view.raid_member_requested.connect ((block, add) => manage_raid_member (block, add));
            drive_view.raid_replace_requested.connect ((block) => manage_raid_member (block, true, true));
            drive_view.raid_delete_requested.connect (confirm_raid_delete);
            drive_view.raid_power_requested.connect (confirm_raid_power);
            drive_view.raid_recovery_requested.connect (confirm_degraded_raid);
            drive_view.btrfs_subvolumes_requested.connect (list_btrfs_subvolumes);
            drive_view.btrfs_add_requested.connect ((block) => change_btrfs_member (block, false));
            drive_view.btrfs_remove_requested.connect ((block) => change_btrfs_member (block, true));
            drive_view.btrfs_allocation_requested.connect (show_btrfs_allocation);
            drive_view.btrfs_balance_requested.connect (manage_btrfs_balance);
            drive_view.mount_options_requested.connect (edit_mount_options);
            drive_view.encryption_requested.connect (manage_encryption);
            drive_view.passphrase_requested.connect (change_passphrase);
            drive_view.luks_keyslots_requested.connect ((block) => manage_luks_credentials.begin (block));
            drive_view.luks_header_requested.connect ((block, restore, advanced) =>
                show_luks_header.begin (block, restore, advanced));
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
                update_advanced_jobs ();
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
        private void confirm_degraded_raid (StorageBlock member) {
            string identity = backend.storage_membership_identity (member, true);
            var dialog = new HardwareActionConfirmationDialog () {
                heading = "Start RAID 1 With One Member?",
                body = "Only %s is available. The other member is missing. The array will have no redundancy, and failure of the remaining device can cause data loss.".printf (member.preferred)
            };
            dialog.set_response_label ("continue", "Start Degraded");
            dialog.response.connect ((response) => {
                if (response != "continue" || pending.contains (member.path)) return;
                pending.insert (member.path, member);
                backend.set_raid_running.begin (member, true, identity, true, (object, result) => {
                    pending.remove (member.path);
                    try {
                        backend.set_raid_running.end (result);
                        notifications.add_toast (new Adw.Toast ("RAID 1 started with reduced redundancy"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm degraded RAID start", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void confirm_raid_power (StorageBlock block, bool running) {
            string identity = backend.modification_identity (block);
            var dialog = new HardwareActionConfirmationDialog () {
                heading = running ? "Start RAID Array?" : "Stop RAID Array?",
                body = running ? "Assemble the array using its verified member devices." :
                    "The array will become unavailable until started again. Unmount its volumes and close dependent mappings first."
            };
            dialog.response.connect ((response) => {
                if (response != "continue" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.set_raid_running.begin (block, running, identity, false, (object, result) => {
                    pending.remove (block.path);
                    try {
                        backend.set_raid_running.end (result);
                        notifications.add_toast (new Adw.Toast (running ? "RAID array started" : "RAID array stopped"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm the RAID state change", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void confirm_raid_delete (StorageBlock member) {
            var array = member.raid_membership;
            if (array == null) return;
            string identity = backend.storage_membership_identity (member, true);
            string[] names = {};
            foreach (var candidate in backend.snapshot.blocks.get_values ())
                if (candidate.raid_membership == array) names += candidate.preferred;
            var dialog = new StorageRemovalDialog (false) {
                heading = "Delete Stopped RAID Array?",
                body = "Delete %s and permanently destroy RAID metadata on these members: %s.".printf (
                    array.name, string.joinv (", ", names))
            };
            dialog.response.connect ((response) => {
                if (response != "remove" || pending.contains (member.path)) return;
                pending.insert (member.path, member);
                backend.delete_stopped_raid.begin (member, identity, (object, result) => {
                    pending.remove (member.path);
                    try {
                        backend.delete_stopped_raid.end (result);
                        notifications.add_toast (new Adw.Toast ("RAID array deleted"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm RAID deletion", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void manage_raid_member (StorageBlock block, bool add, bool replacement = false) {
            string identity = backend.modification_identity (block);
            if (add) {
                var picker = new CreateStorageGroupDialog (backend, false, true,
                    replacement ? "Replace Missing RAID 1 Member" : "Add RAID Member");
                if (replacement) picker.body = "Select an unused device at least as large as the surviving member. Its contents may be overwritten during reconstruction.";
                picker.response.connect ((choice) => {
                    if (choice != "create") return;
                    string[] identities;
                    var members = picker.selected_members (out identities);
                    if (members.length == 1) change_raid_member (block, members[0], true, identity, identities[0], replacement);
                });
                picker.present (this);
            } else {
                StorageBlock? array = null;
                foreach (var candidate in backend.snapshot.blocks.get_values ())
                    if (candidate.raid != null && candidate.raid == block.raid_membership) array = candidate;
                if (array == null) return;
                var anchor = array;
                string array_identity = backend.modification_identity (anchor);
                var confirm = new HardwareActionConfirmationDialog () {
                    heading = "Remove Inactive RAID Member?",
                    body = "Remove %s from the array. Its RAID metadata will be retained.".printf (block.preferred)
                };
                confirm.response.connect ((choice) => {
                    if (choice == "continue") change_raid_member (anchor, block, false, array_identity, identity);
                });
                confirm.present (this);
            }
        }

        private void change_raid_member (StorageBlock anchor, StorageBlock member, bool add,
            string anchor_identity, string member_identity, bool replacement = false) {
            if (pending.contains (anchor.path)) return;
            pending.insert (anchor.path, anchor);
            backend.change_raid_member.begin (anchor, member, add, anchor_identity, member_identity, replacement, (object, result) => {
                pending.remove (anchor.path);
                try {
                    backend.change_raid_member.end (result);
                    notifications.add_toast (new Adw.Toast (replacement ? "Replacement attached. Check Jobs for reconstruction progress." :
                        add ? "RAID member added" : "Inactive RAID member removed"));
                } catch (Error error) {
                    show_check_message ("Could not confirm the RAID member change", operation_error (error));
                }
            });
        }

        private void start_raid_check (StorageBlock block) {
            if (pending.contains (block.path)) return;
            pending.insert (block.path, block);
            backend.start_raid_check.begin (block, (obj, result) => {
                pending.remove (block.path);
                try {
                    notifications.add_toast (new Adw.Toast (backend.start_raid_check.end (result)));
                } catch (Error error) {
                    show_check_message ("Could not confirm the RAID consistency check", operation_error (error));
                }
            });
        }

        private void manage_btrfs_balance (StorageBlock block) {
            string identity = backend.modification_identity (block);
            var dialog = new BtrfsBalanceDialog (!block.read_only && !block.system_hint, !block.system_hint);
            dialog.response.connect ((response) => {
                if (response == "close") return;
                backend.btrfs_maintenance.begin (block, identity, response, dialog.usage_limit, (object, result) => {
                    try { show_check_message ("Btrfs Maintenance", backend.btrfs_maintenance.end (result)); }
                    catch (Error error) { show_check_message ("Could not confirm Btrfs maintenance", operation_error (error)); }
                });
            });
            dialog.present (this);
        }

        private void show_btrfs_allocation (StorageBlock block) {
            backend.query_btrfs_allocation.begin (block, (object, result) => {
                try {
                    var report = backend.query_btrfs_allocation.end (result);
                    var allocations = report.get_child_value (2);
                    var members = report.get_child_value (3);
                    uint64 total = 0, unallocated = 0;
                    bool complete = members.n_children () == report.get_child_value (1).get_uint64 ();
                    var detail = new StringBuilder ();
                    detail.append_printf ("Filesystem UUID %s\nLogical capacity reported by the kernel: %s\n\n",
                        block.uuid, format_size (report.get_child_value (0).get_uint64 ()));
                    for (size_t i = 0; i < allocations.n_children (); i++) {
                        var row = allocations.get_child_value (i);
                        detail.append_printf ("%s · %s used of %s allocated\n",
                            row.get_child_value (0).get_string (), format_size (row.get_child_value (2).get_uint64 ()),
                            format_size (row.get_child_value (1).get_uint64 ()));
                    }
                    detail.append ("\nPhysical members\n");
                    for (size_t i = 0; i < members.n_children (); i++) {
                        var row = members.get_child_value (i);
                        uint64 number = row.get_child_value (1).get_uint64 ();
                        uint64 size = row.get_child_value (2).get_uint64 ();
                        uint64 allocated = row.get_child_value (3).get_uint64 ();
                        string name = KernelStorageSafety.device_number (number);
                        foreach (var member in backend.snapshot.blocks.get_values ())
                            if (member.number == number) { name = member.preferred; break; }
                        detail.append_printf ("%s · device ID %s · %s capacity · %s allocated\n", name,
                            row.get_child_value (0).get_uint64 ().to_string (), format_size (size), format_size (allocated));
                        if (size > uint64.MAX - total) complete = false;
                        else { total += size; unallocated += size - allocated; }
                    }
                    if (complete)
                        detail.append_printf ("\nPhysical capacity %s · %s not allocated to chunks",
                            format_size (total), format_size (unallocated));
                    else
                        detail.append ("\nSome member information is unavailable. Physical totals could not be verified.");
                    show_check_message ("Btrfs Allocation", detail.str);
                } catch (Error error) {
                    show_check_message ("Could not read Btrfs allocation", operation_error (error));
                }
            });
        }

        private void change_btrfs_member (StorageBlock filesystem, bool remove) {
            string identity = backend.modification_identity (filesystem);
            StorageBlock[] choices = {};
            if (remove)
                foreach (var candidate in backend.snapshot.blocks.get_values ())
                    if (backend.can_select_btrfs_removal_member (filesystem, candidate)) choices += candidate;
            var picker = new CreateStorageGroupDialog (backend, false, true,
                remove ? "Remove Btrfs Device" : "Add Btrfs Device", remove ? choices : null);
            if (remove) picker.body = "Removal is available with single or DUP profiles. Allocated chunks must fit on a surviving device with headroom. The kernel verifies actual placement before completing removal.";
            picker.response.connect ((choice) => {
                if (choice != "create" || pending.contains (filesystem.path)) return;
                string[] identities;
                var members = picker.selected_members (out identities);
                if (members.length != 1) return;
                pending.insert (filesystem.path, filesystem);
                backend.change_btrfs_member.begin (filesystem, members[0], identity, identities[0], remove, (object, result) => {
                    pending.remove (filesystem.path);
                    try {
                        backend.change_btrfs_member.end (result);
                        notifications.add_toast (new Adw.Toast (remove ? "Btrfs member removed" : "Btrfs member added"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm the Btrfs member change", operation_error (error));
                    }
                });
            });
            picker.present (this);
        }

        private void list_btrfs_subvolumes (StorageBlock block) {
            string identity = backend.modification_identity (block);
            backend.list_btrfs_subvolumes.begin (block, (obj, result) => {
                try {
                    var entries = backend.list_btrfs_subvolumes.end (result);
                    var dialog = new BtrfsSubvolumesDialog (entries, !block.read_only && !block.system_hint);
                    dialog.response.connect ((response) => {
                        if (pending.contains (block.path)) return;
                        if (response == "delete") {
                            var selected_subvolume = dialog.snapshot_source;
                            if (selected_subvolume != null)
                                confirm_btrfs_subvolume_delete (block, identity, selected_subvolume);
                            return;
                        }
                        if (response == "create" || response == "snapshot") {
                            var source = response == "snapshot" ? dialog.snapshot_source : null;
                            if (response == "snapshot" && source == null) return;
                            pending.insert (block.path, block);
                            backend.change_btrfs_subvolume.begin (block, dialog.new_name, identity,
                                source, dialog.read_only_snapshot, false, (object, created) => {
                                pending.remove (block.path);
                                try {
                                    backend.change_btrfs_subvolume.end (created);
                                    notifications.add_toast (new Adw.Toast (source == null ? "Btrfs subvolume created" : "Btrfs snapshot created"));
                                } catch (Error error) {
                                    show_check_message ("Could not confirm Btrfs creation", operation_error (error));
                                }
                            });
                            return;
                        }
                        if (response != "apply") return;
                        pending.insert (block.path, block);
                        backend.set_btrfs_default.begin (block, dialog.selected_id, entries.default_id, identity, (object, changed) => {
                            pending.remove (block.path);
                            try {
                                backend.set_btrfs_default.end (changed);
                                notifications.add_toast (new Adw.Toast ("Default Btrfs subvolume updated"));
                            } catch (Error error) {
                                show_check_message ("Could not set the default Btrfs subvolume", operation_error (error));
                            }
                        });
                    });
                    dialog.present (this);
                } catch (Error error) {
                    show_check_message ("Could not list Btrfs subvolumes", operation_error (error));
                }
            });
        }

        private void confirm_btrfs_subvolume_delete (StorageBlock block, string identity, BtrfsSubvolume subvolume) {
            var confirm = new StorageRemovalDialog (false) {
                heading = subvolume.snapshot ? "Delete Btrfs Snapshot?" : "Delete Btrfs Subvolume?",
                body = "%s on %s will be permanently deleted. Mounted and nested subvolumes are protected.".printf (
                    subvolume.path, block.preferred)
            };
            confirm.response.connect ((response) => {
                if (response != "remove" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.change_btrfs_subvolume.begin (block, subvolume.path, identity, subvolume, false, true,
                    (object, result) => {
                        pending.remove (block.path);
                        try {
                            backend.change_btrfs_subvolume.end (result);
                            notifications.add_toast (new Adw.Toast (subvolume.snapshot ? "Btrfs snapshot deleted" : "Btrfs subvolume deleted"));
                            list_btrfs_subvolumes (block);
                        } catch (Error error) {
                            show_check_message ("Could not confirm Btrfs deletion", operation_error (error));
                        }
                    });
            });
            confirm.present (this);
        }

        private void create_storage_group (bool raid) {
            var dialog = new CreateStorageGroupDialog (backend, raid);
            dialog.response.connect ((response) => {
                if (response != "create") return;
                string[] identities;
                var members = dialog.selected_members (out identities);
                backend.create_storage_group.begin (raid, members, identities, dialog.group_name, dialog.level,
                    dialog.chunk, (object, result) => {
                    try {
                        string visible = backend.create_storage_group.end (result);
                        if (visible != "") selected = visible;
                        update_devices ();
                        notifications.add_toast (new Adw.Toast (raid ? "RAID array created" : "LVM volume group created"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm storage creation", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void create_logical_volume (StorageBlock block, StorageLogicalVolume? origin = null) {
            var group = block.volume_group;
            if (group == null) return;
            string origin_path = origin?.path ?? "/";
            string origin_uuid = origin?.uuid ?? "";
            var dialog = new CreateLogicalVolumeDialog (group, backend.snapshot, 0, false, origin);
            string identity = backend.modification_identity (block);
            dialog.response.connect ((response) => {
                if (response != "create" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                var selected_pool = dialog.selected_pool;
                backend.create_logical_volume.begin (block, dialog.volume_name, dialog.bytes, identity,
                    dialog.create_thin_pool, selected_pool?.path ?? "/", selected_pool?.uuid ?? "",
                    origin_path, origin_uuid, dialog.allow_overcommit, (object, result) => {
                    pending.remove (block.path);
                    try {
                        string created = backend.create_logical_volume.end (result);
                        if (created != "") {
                            selected = created;
                            update_devices ();
                        }
                        notifications.add_toast (new Adw.Toast (origin_path == "/" ?
                            "Logical volume created" : "Logical-volume snapshot created"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm logical-volume creation", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void add_lvm_physical_volume (StorageBlock context) {
            string identity = backend.modification_identity (context);
            var picker = new CreateStorageGroupDialog (backend, false, true, "Add Physical Volume");
            picker.response.connect ((choice) => {
                if (choice != "create" || pending.contains (context.path)) return;
                string[] identities;
                var members = picker.selected_members (out identities);
                if (members.length != 1) return;
                pending.insert (context.path, context);
                backend.add_lvm_physical_volume.begin (context, members[0], identity, identities[0], (object, result) => {
                    pending.remove (context.path);
                    try {
                        backend.add_lvm_physical_volume.end (result);
                        notifications.add_toast (new Adw.Toast ("Physical volume added"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm physical-volume addition", operation_error (error));
                    }
                });
            });
            picker.present (this);
        }

        private void manage_logical_volumes (StorageBlock context) {
            string identity = backend.modification_identity (context);
            var dialog = new LvmLifecycleDialog (backend.logical_volumes_for (context), context.logical_volume?.path ?? "/", context.volume_group != null);
            dialog.response.connect ((response) => {
                if (response == "migrate" || response == "remove-pv" || response == "delete-vg") {
                    confirm_lvm_membership (context, response);
                    return;
                }
                var volume = dialog.selection;
                if (volume == null || response == "close") return;
                if (response == "expand-pool" || (volume.lvm_type == "pool" &&
                    (response == "delete" || response == "deactivate"))) {
                    confirm_thin_pool_change (context, identity, volume, response == "delete", response == "deactivate");
                    return;
                }
                if (response == "snapshot") {
                    create_logical_volume (context, volume);
                    return;
                }
                string path = volume.path;
                string uuid = volume.uuid;
                if (response == "delete") {
                    var confirm = new HardwareActionConfirmationDialog () {
                        heading = "Delete Logical Volume?",
                        body = "All data in %s will be permanently lost.".printf (volume.name)
                    };
                    confirm.response.connect ((choice) => {
                        if (choice == "continue") change_logical_volume_state (context, path, uuid, identity, "Delete");
                    });
                    confirm.present (this);
                } else {
                    change_logical_volume_state (context, path, uuid, identity,
                        response == "activate" ? "Activate" : "Deactivate");
                }
            });
            dialog.present (this);
        }

        private void confirm_thin_pool_change (StorageBlock context, string identity, StorageLogicalVolume pool,
            bool deleting, bool deactivate) {
            var group = context.volume_group;
            if (group == null) return;
            string path = pool.path;
            string uuid = pool.uuid;
            if (!deleting && !deactivate) {
                var dialog = new CreateLogicalVolumeDialog (group, null, pool.size, false);
                dialog.heading = "Expand Thin Pool";
                dialog.response.connect ((response) => {
                    if (response == "create") change_thin_pool (context, path, uuid, identity, dialog.bytes);
                });
                dialog.present (this);
                return;
            }
            string[] dependents = {};
            foreach (var item in backend.snapshot.advanced.get_values ()) {
                var child = item as StorageLogicalVolume;
                if (child != null && (child.thin_pool_path == path || child.origin_path == path))
                    dependents += child.name;
            }
            if (dependents.length != 0) {
                show_check_message ("Thin pool still contains volumes", string.joinv (", ", dependents));
                return;
            }
            var confirm = new StorageRemovalDialog (false) {
                heading = deactivate ? "Deactivate Empty Thin Pool?" : "Delete Empty Thin Pool?",
                body = deactivate ? "Deactivate the empty pool %s.".printf (pool.name) :
                    "Delete the inactive pool %s and release its data and metadata extents to the volume group.".printf (pool.name)
            };
            if (deactivate) confirm.set_response_label ("remove", "Deactivate");
            confirm.response.connect ((response) => {
                if (response == "remove") change_thin_pool (context, path, uuid, identity, 0, deactivate);
            });
            confirm.present (this);
        }

        private void change_thin_pool (StorageBlock context, string path, string uuid, string identity, uint64 size,
            bool deactivate = false) {
            if (pending.contains (context.path)) return;
            pending.insert (context.path, context);
            backend.change_thin_pool.begin (context, path, uuid, identity, size, deactivate, (object, result) => {
                pending.remove (context.path);
                try {
                    backend.change_thin_pool.end (result);
                    notifications.add_toast (new Adw.Toast (deactivate ? "Empty thin pool deactivated" :
                        size == 0 ? "Empty thin pool deleted" : "Thin-pool data capacity expanded"));
                } catch (Error error) {
                    show_check_message ("Could not confirm the thin-pool operation", operation_error (error));
                }
            });
        }

        private void confirm_lvm_membership (StorageBlock member, string choice) {
            string identity = backend.storage_membership_identity (member, false);
            bool migrate = choice == "migrate";
            bool delete_group = choice == "delete-vg";
            string method = migrate ? "EmptyDevice" : delete_group ? "Delete" : "RemoveDevice";
            string target = delete_group ? member.volume_group?.name ?? "" : member.preferred;
            var dialog = new StorageRemovalDialog (!migrate) {
                heading = migrate ? "Migrate Physical Volume?" : delete_group ? "Delete Empty Volume Group?" : "Remove Physical Volume?",
                body = migrate ? "Move all allocated extents from %s to other members of its group.".printf (target) :
                    delete_group ? "Delete the empty volume group %s and release all its physical volumes.".printf (target) :
                    "Remove the empty physical volume %s from its group.".printf (target)
            };
            if (migrate) dialog.set_response_label ("remove", "Migrate");
            dialog.response.connect ((response) => {
                if (response != "remove" || pending.contains (member.path)) return;
                pending.insert (member.path, member);
                backend.change_lvm_membership.begin (member, identity, method, dialog.wipe_metadata, (object, result) => {
                    pending.remove (member.path);
                    try {
                        backend.change_lvm_membership.end (result);
                        notifications.add_toast (new Adw.Toast (migrate ? "Physical volume emptied" :
                            delete_group ? "Volume group deleted" : "Physical volume removed"));
                    } catch (Error error) {
                        show_check_message ("Could not confirm the LVM operation", operation_error (error));
                    }
                });
            });
            dialog.present (this);
        }

        private void change_logical_volume_state (StorageBlock context, string path, string uuid,
            string identity, string method) {
            if (pending.contains (context.path)) return;
            pending.insert (context.path, context);
            backend.change_logical_volume_state.begin (context, path, uuid, identity, method, (object, result) => {
                pending.remove (context.path);
                try {
                    string block = backend.change_logical_volume_state.end (result);
                    if (block != "") selected = block;
                    update_devices ();
                    notifications.add_toast (new Adw.Toast (method == "Activate" ? "Logical volume activated" :
                        method == "Deactivate" ? "Logical volume deactivated" : "Logical volume deleted"));
                } catch (Error error) {
                    show_check_message ("Could not confirm the logical-volume operation", operation_error (error));
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
                        string renamed = backend.rename_logical_volume.end (result);
                        selected = renamed;
                        update_devices ();
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
        private async void show_luks_header (StorageBlock block, bool restore, bool advanced) {
            if (pending.contains (block.path)) return;
            string identity = backend.modification_identity (block);
            string device = block.preferred;
            var chooser = new Gtk.FileDialog ();
            File? source = null;
            pending.insert (block.path, block);
            try {
                if (restore) {
                    chooser.title = "Select a LUKS Header Backup";
                    source = yield chooser.open (this, null);
                }
                var review = yield backend.review_luks_header (block, identity, source, advanced);
                string details = "%s · %s\n%s · %s".printf (device, format_size (block.size),
                    review.version, review.uuid);
                File? destination = null;
                if (restore) {
                    if (block.partition != null && block.partition.uuid != "")
                        details += "\nPartition UUID " + block.partition.uuid;
                    details += "\nHeader size %s · Data offset %s".printf (
                        format_size (review.header_size), format_size (review.data_offset));
                    if (review.confidence == "unestablished") {
                        show_check_message ("Source Identity Cannot Be Established", details +
                            "\n\nThe current header is unreadable. The backup has a supported structure, " +
                            "but its source cannot be established from the companion manifest. " +
                            "Use offline expert recovery.");
                        return;
                    }
                    string confirmation = advanced ? device + " " + review.uuid : device;
                    var dialog = new LuksHeaderRestoreDialog (confirmation, advanced);
                    dialog.body = details + "\n" + source.get_parse_name () + "\n\n" +
                        (review.damaged ? "Device-identity-supported recovery. The current header is unreadable. The recorded source identity matches this device. This does not establish that the backup decrypts its data." :
                            "Matching readable header. The LUKS UUID, layout and volume-key digest match.") + "\n\n" + dialog.body;
                    if (!review.checksummed)
                        dialog.body += "\n\nThis file has no saved checksum. Majoris verified its structure and layout, " +
                            "but could not independently check the keyslot bytes for corruption.";
                    string response = yield dialog.choose (this, null);
                    if (response != "restore") return;
                } else {
                    var dialog = new LuksHeaderBackupDialog ();
                    dialog.body = details + "\n\n" + dialog.body;
                    string response = yield dialog.choose (this, null);
                    if (response != "choose") return;
                    chooser.title = "Save a LUKS Header Backup";
                    chooser.initial_name = review.uuid + ".luks-header";
                    destination = yield chooser.save (this, null);
                }
                var result = yield backend.execute_luks_header (block, review, destination);
                show_check_message (result.successful ? "LUKS Header Operation Complete" : "LUKS Header Operation",
                    result.summary + (result.technical_error == "" ? "" : "\n\n" + result.technical_error));
            } catch (Error error) {
                if (!(error is Gtk.DialogError.DISMISSED) && !(error is Gtk.DialogError.CANCELLED))
                    show_check_message ("LUKS Header Operation Not Started", operation_error (error));
            } finally {
                pending.remove (block.path);
            }
        }

        private async void manage_luks_credentials (StorageBlock block) {
            if (pending.contains (block.path)) return;
            pending.insert (block.path, block);
            try {
                while (true) {
                    var review = yield backend.review_luks_header (block, backend.modification_identity (block),
                        null, false, true);
                    bool writable = true;
                    try { UDisksService.require_luks_restore_idle (block, backend.snapshot.dependencies); }
                    catch (Error error) { writable = false; }
                    var manager = new LuksKeyslotsDialog (review, writable);
                    string action = yield manager.choose (this, null);
                    if (action == "close") return;
                    var dialog = new LuksCredentialDialog (action, manager.selected_slot,
                        manager.remaining_slots (), block.encryption_configurations.length > 0, this);
                    int first = -1;
                    int second = -1;
                    try {
                        if ((yield dialog.choose (this, null)) != "apply") continue;
                        first = dialog.take_credential (true);
                        if (action != "identify") second = dialog.take_credential (false);
                        var result = yield backend.manage_luks_keyslots (block, review, action + "-keyslot",
                            action == "add" ? -1 : manager.selected_slot, dialog.retained_slot,
                            first, second, dialog.current_file, dialog.other_file);
                        var message = new Adw.AlertDialog (
                            result.successful ? (action == "identify" ? "LUKS Credential Verified" : "LUKS Credentials Updated") :
                                "LUKS Credential Operation",
                            result.summary + (result.technical_error == "" ? "" : "\n\n" + result.technical_error));
                        message.add_response ("close", "Close");
                        message.close_response = "close";
                        yield message.choose (this, null);
                    } finally {
                        dialog.clear_credentials ();
                        if (first >= 0) Posix.close (first);
                        if (second >= 0) Posix.close (second);
                    }
                }
            } catch (Error error) {
                show_check_message ("LUKS Credential Manager", operation_error (error));
            } finally {
                pending.remove (block.path);
            }
        }

        private void change_passphrase (StorageBlock block) {
            if (UDisksService.luks_header_available () && UDisksService.is_luks_header_candidate (block)) {
                manage_luks_credentials.begin (block);
                return;
            }
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
            if (block.logical_volume != null) {
                resize_lvm_volume (block);
                return;
            }
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
        private void resize_lvm_volume (StorageBlock block) {
            var group = backend.snapshot.advanced.lookup (block.logical_volume.group_path) as StorageVolumeGroup;
            if (group == null) return;
            string identity = backend.modification_identity (block);
            var pool = backend.snapshot.advanced.lookup (block.logical_volume.thin_pool_path) as StorageLogicalVolume;
            var dialog = new CreateLogicalVolumeDialog (group, backend.snapshot, block.size, block.filesystem != null, null, pool);
            dialog.response.connect ((response) => {
                if (response != "create" || pending.contains (block.path)) return;
                pending.insert (block.path, block);
                backend.resize_logical_volume.begin (block, dialog.bytes, identity, dialog.allow_overcommit, (object, async_result) => {
                    pending.remove (block.path);
                    try {
                        var result = backend.resize_logical_volume.end (async_result);
                        drive_view.invalidate_usage (block);
                        if (result.successful) notifications.add_toast (new Adw.Toast (result.summary));
                        else show_check_message (result.partial ? "Logical volume partially resized" : result.summary,
                            operation_result_details (result));
                    } catch (Error error) {
                        show_check_message ("Could not resize logical volume", operation_error (error));
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
                confirm_attach_image (file);
            });
        }

        internal void show_image_open_error (string detail) {
            show_check_message ("Could not open disk image", detail);
        }

        internal void confirm_attach_image (File file) {
            string name = (file.get_basename () ?? "").down ();
            if (file.get_path () == null) {
                show_image_open_error ("Choose a local disk image.");
                return;
            }
            if (name.has_suffix (".vhd") || name.has_suffix (".vhdx") || name.has_suffix (".qcow2")) {
                inspect_virtual_image (file);
                return;
            }
            bool optical = name.has_suffix (".iso");
            if (!optical && !name.has_suffix (".img") && !name.has_suffix (".raw")) {
                show_image_open_error ("Choose a RAW, ISO, VHD, VHDX or QCOW2 image.");
                return;
            }
            var confirmation = new DiskImageConfirmation () {
                heading = "Attach Disk Image?",
                body = optical ? file.get_parse_name () :
                    file.get_parse_name () + "\n\nRead/write access allows changes to the image file."
            };
            confirmation.set_response_label ("proceed", "Attach Read-Only");
            confirmation.set_response_appearance ("proceed", Adw.ResponseAppearance.SUGGESTED);
            if (!optical) confirmation.add_response ("writable", "Attach Read/Write");
            confirmation.response.connect ((response) => {
                if (response == "proceed" || (!optical && response == "writable"))
                    attach_image (file, response == "proceed");
            });
            confirmation.present (this);
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
                    dialog.set_response_enabled ("grow", !info.has_snapshots);
                    if (info.has_snapshots) dialog.body += "\n\nGrowing a copy is unavailable for images with internal snapshots.";
                    if (unavailable != null) dialog.body += "\n\n" + unavailable + " You can still convert to raw.";
                    dialog.response.connect ((response) => {
                        if (response == "grow") {
                            choose_grown_image (source, info);
                            return;
                        }
                        if (response == "attach-readonly" || response == "attach-writable") {
                            attach_virtual (source, response == "attach-readonly");
                            return;
                        }
                        if (response != "convert") return;
                        string format = dialog.format;
                        bool attach = dialog.attach_copy;
                        bool compress = dialog.compress_copy;
                        var save = new Gtk.FileDialog () { title = "Save Converted Image",
                            initial_name = "Converted" + image_extension (format) };
                        save.save.begin (this, null, (object, saved) => {
                            File target;
                            try { target = save.save.end (saved); } catch (Error error) { return; }
                            write_virtual_image (source, target, format, 0, attach, null, compress);
                        });
                    });
                    dialog.present (this);
                } catch (Error error) { show_check_message ("Could not inspect the image", error.message); }
            });
        }

        private static string image_extension (string format) {
            return format == "raw" ? ".img" : format == "vpc" ? ".vhd" : "." + format;
        }

        private void choose_grown_image (File source, VirtualDiskInfo info) {
            var setup = new BlankDiskImageDialog ();
            setup.configure_growth (source, info.capacity);
            setup.response.connect ((response) => {
                if (response != "create") return;
                uint64 size = setup.bytes;
                var save = new Gtk.FileDialog () { title = "Save Larger Disk Image",
                    initial_name = "Grown" + image_extension (info.format) };
                save.save.begin (this, null, (object, saved) => {
                    File target;
                    try { target = save.save.end (saved); } catch (Error error) { return; }
                    write_virtual_image (source, target, info.format, size, false, info);
                });
            });
            setup.present (this);
        }

        private void write_virtual_image (File? source, File destination, string format, uint64 size, bool attach,
            VirtualDiskInfo? grow = null, bool compress = false) {
            string operation = grow != null ? "Grow a disk image copy" :
                source == null ? "Create virtual disk" : "Convert disk image";
            var job = backend.jobs.begin_named (operation,
                destination.get_parse_name (), {});
            job.cancelable = true;
            string phase = grow != null ? "Copying and verifying the larger image" :
                compress ? "Compressing and verifying the image" :
                source == null ? "Creating image" : "Converting image";
            backend.jobs.phase (job, StorageJobState.RUNNING, phase);
            VirtualDisk.write_image.begin (source, destination, format, size, job.cancellable,
                (fraction) => backend.jobs.progress (job, phase, fraction, true), grow,
                (fd) => backend.require_detached_image (fd), compress, (object, result) => {
                var outcome = new StorageOperationResult ();
                try {
                    VirtualDisk.write_image.end (result);
                    outcome.successful = true;
                    outcome.summary = grow != null ? "Larger disk image saved and verified" :
                        source == null ? "Virtual disk created" : "Disk image converted";
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
            bool partition = block.partition != null;
            var chooser = new Gtk.FileDialog () {
                title = partition ? "Select Partition Image to Restore" : "Select Disk Image to Restore"
            };
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
                    heading = partition ? "Overwrite the selected partition?" : "Overwrite the selected device?",
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
                    selected_storage = "";
                    split.show_content = true;
                    break;
                }
            }
            if (chosen == null) chosen = sidebar.get_row_at_index (0) as DeviceRow;
            sidebar.invalidate_headers ();
            var advanced_row = update_advanced_rows ();
            sidebar.select_row (advanced_row == null ? chosen : null);
            advanced_sidebar.select_row (advanced_row);
            if (chosen != null || backend.available ()) selected = chosen != null ? chosen.drive.path : "";
            updating = false;
            show_selection ();
        }

        private static string storage_key (StorageDevice device) {
            var block = device as StorageBlock;
            return block != null && block.uuid != "" ? "btrfs:" + block.uuid : device.path;
        }

        private VolumeRow? update_advanced_rows () {
            var objects = new HashTable<string, StorageDevice> (str_hash, str_equal);
            foreach (var item in backend.snapshot.advanced.get_values ())
                if (item is StorageVolumeGroup || item is StorageRaid) objects.insert (storage_key (item), item);
            foreach (var block in backend.snapshot.blocks.get_values ()) {
                if (block.ignored || block.type_id != "btrfs") continue;
                string key = storage_key (block);
                var prior = objects.lookup (key) as StorageBlock;
                bool mounted = block.filesystem?.mounted == true;
                bool prior_mounted = prior?.filesystem?.mounted == true;
                if (prior == null || (mounted && !prior_mounted) ||
                    (mounted == prior_mounted && strcmp (block.path, prior.path) < 0))
                    objects.insert (key, block);
            }

            var items = objects.get_values ();
            items.sort ((a, b) => {
                int order = a.name.collate (b.name);
                return order != 0 ? order : strcmp (storage_key (a), storage_key (b));
            });
            VolumeRow? chosen = null;
            int index = 0;
            foreach (var item in items) {
                var row = advanced_sidebar.get_row_at_index (index++) as VolumeRow;
                if (row == null) {
                    row = new VolumeRow (item);
                    advanced_sidebar.append (row);
                } else row.update (item);
                if (item is StorageVolumeGroup) row.subtitle = "LVM Volume Group";
                else if (item is StorageRaid) row.subtitle = "RAID Array";
                else row.subtitle = "Btrfs Filesystem";
                if (storage_key (item) == selected_storage) chosen = row;
            }
            Gtk.ListBoxRow? extra;
            while ((extra = advanced_sidebar.get_row_at_index (index)) != null)
                advanced_sidebar.remove (extra);
            advanced_sidebar.visible = index != 0;
            if (chosen == null) selected_storage = "";
            return chosen;
        }

        private void update_advanced_jobs () {
            string[] phases = {};
            if (advanced_device != null) {
                var jobs = backend.jobs.jobs;
                for (uint i = 0; i < jobs.get_n_items (); i++) {
                    var job = (StorageJob) jobs.get_item (i);
                    if (StorageJobManager.terminal (job.state)) continue;
                    bool matches = advanced_device.path in job.affected;
                    foreach (var row in member_rows)
                        matches |= row.device.path in job.affected;
                    if (matches) {
                        string progress = job.progress_valid ? " (%.0f%%)".printf (job.progress * 100.0) : "";
                        phases += job.operation + " · " + job.phase + progress;
                    }
                }
            }
            advanced_jobs.subtitle = phases.length == 0 ? "None reported for this object" : string.joinv (" · ", phases);
        }

        private void show_advanced_storage (StorageDevice item) {
            advanced_device = item;
            advanced_context = null;
            advanced_summary.title = item.name != "" ? item.name : "Storage Object";
            advanced_manage.visible = advanced_maintenance.visible = advanced_recovery.visible = false;
            foreach (var row in member_rows) advanced_members.remove (row);
            member_rows = {};

            var group = item as StorageVolumeGroup;
            var array = item as StorageRaid;
            var filesystem = item as StorageBlock;
            var blocks = backend.snapshot.blocks.get_values ();
            blocks.sort ((a, b) => strcmp (a.path, b.path));
            foreach (var block in blocks) {
                bool member = group != null ? block.volume_group == group :
                    array != null ? block.raid_membership == array || block.raid == array :
                    block.type_id == "btrfs" && storage_key (block) == storage_key (item);
                if (!member) continue;
                add_advanced_member (block);
                if (block.ignored || !block.available) continue;
                if (group != null && !block.system_hint &&
                    (advanced_context == null || strcmp (block.path, advanced_context.path) < 0))
                    advanced_context = block;
                if (array != null && (advanced_context == null ||
                    (advanced_context.raid != array && (block.raid == array ||
                        (!backend.can_start_degraded_raid (advanced_context) && backend.can_start_degraded_raid (block))))))
                    advanced_context = block;
            }

            if (group != null) {
                advanced_details.title = "LVM Volume Group";
                advanced_details.subtitle = "%s available of %s".printf (format_size (group.free_size), format_size (group.size));
                var volumes = backend.snapshot.advanced.get_values ();
                volumes.sort ((a, b) => strcmp (a.path, b.path));
                foreach (var candidate in volumes) {
                    var lv = candidate as StorageLogicalVolume;
                    if (lv != null && lv.group_path == group.path) add_advanced_member (lv);
                }
                advanced_manage.title = "Manage Logical Volumes";
                advanced_manage.visible = advanced_context != null;
            } else if (array != null) {
                advanced_details.title = "RAID Array";
                advanced_details.subtitle = "%s · %s · %u missing members".printf (array.level, array.state, array.degraded);
                var context = advanced_context;
                if (context != null) {
                    bool start = context.raid == null;
                    advanced_manage.title = start ? "Start RAID Array" : "Stop RAID Array";
                    advanced_manage.visible = backend.can_set_raid_running (context, start);
                    advanced_maintenance.title = "Check RAID Array";
                    advanced_maintenance.visible = backend.can_check_raid (context);
                    advanced_recovery.title = "Start Degraded RAID Array";
                    advanced_recovery.visible = backend.can_start_degraded_raid (context);
                }
            } else if (filesystem != null) {
                advanced_context = filesystem;
                advanced_details.title = "Btrfs Filesystem";
                advanced_details.subtitle = filesystem.filesystem?.mounted == true ?
                    string.joinv (", ", filesystem.filesystem.mounts) : "Unmounted";
                advanced_manage.title = "Manage Subvolumes";
                advanced_maintenance.title = "View Allocation";
                advanced_recovery.title = "Balance and Scrub";
                advanced_manage.visible = advanced_maintenance.visible = advanced_recovery.visible =
                    backend.has_btrfs_subvolumes (filesystem);
            }
            update_advanced_jobs ();
            drive_view.clear ();
            states.visible_child = advanced_view;
        }

        private void add_advanced_member (StorageDevice device) {
            var row = new VolumeRow (device);
            var block = device as StorageBlock;
            var lv = device as StorageLogicalVolume;
            if (block != null && block.preferred != "") row.title = block.preferred;
            if (lv != null) {
                row.subtitle = "%s · %s".printf (format_size (lv.size), lv.active ? "Active" : "Inactive");
                if (lv.lvm_type == "pool") {
                    var usage = new ThinPoolUsage (backend.snapshot, lv);
                    row.subtitle = "%s data capacity · %s".printf (format_size (usage.physical_size),
                        usage.active ? "Active" : "Inactive");
                    row.subtitle += usage.virtual_known ?
                        "\n%s provisioned virtually".printf (format_size (usage.virtual_size)) :
                        "\nVirtual provisioning unavailable";
                    row.subtitle += usage.usage_known ?
                        "\nData %.1f%% used · Metadata %.1f%% used".printf (usage.data_ratio * 100.0,
                            usage.metadata_ratio * 100.0) :
                        "\nData and metadata usage unavailable";
                }
            }
            row.selectable = false;
            row.activatable = false;
            member_rows += row;
            advanced_members.add (row);
        }

        private void show_selection () {
            var advanced_row = advanced_sidebar.get_selected_row () as VolumeRow;
            if (advanced_row != null) {
                show_advanced_storage (advanced_row.device);
                return;
            }
            advanced_device = null;
            advanced_context = null;
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
        private StorageMountConfiguration[] configurations;
        public string confirmed_identity { get; private set; }
        public string confirmed_uuid { get; private set; }
        private Gtk.StringList entries = new Gtk.StringList (null);
        private Gtk.StringList visibility_choices = new Gtk.StringList ({ "Use system default", "Show", "Hide" });
        public Variant? original_item { owned get {
            return entry.selected < configurations.length ? configurations[entry.selected].backend_item : null;
        } }
        public string mount_options { owned get {
            try { return MountOptionService.compose (options.text, display_name.text,
                (MountVisibility) files_visibility.selected); }
            catch (Error error) { return options.text; }
        } }
        public MountOptionsDialog (StorageBlock block, string identity) {
            this.block = block; confirmed_identity = identity; files_visibility.model = visibility_choices;
            confirmed_uuid = block.uuid; entry.model = entries;
            configurations = block.mount_configurations;
            foreach (var item in configurations) entries.append (item.directory + " · " + item.device);
            entries.append ("New configuration");
            entry.selected = 0;
            entry.notify["selected"].connect (load_selected);
            load_selected ();
            custom.notify["active"].connect (validate); directory.changed.connect (validate);
            filesystem.changed.connect (validate); options.changed.connect (validate);
            display_name.changed.connect (validate); files_visibility.notify["selected"].connect (validate); validate ();
        }
        private void load_selected () {
            var config = entry.selected < configurations.length ? configurations[entry.selected] : null;
            custom.active = config != null; startup.active = config == null || !("," + config.options + ",").contains (",noauto,");
            directory.text = config?.directory ?? "/mnt/" + (block.label == "" ? block.uuid : block.label);
            filesystem.text = config?.filesystem ?? block.type_id; options.text = config?.options ?? "defaults";
            display_name.text = MountOptionService.display_name (options.text);
            files_visibility.selected = (uint) MountOptionService.visibility (options.text);
            identifier.subtitle = config?.device ?? "UUID=" + block.uuid;
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
        [GtkChild] private unowned Adw.SwitchRow compression;
        public string format { owned get { return disk_image_format (format_choice.selected); } }
        public bool attach_copy { get { return attach.sensitive && attach.active; } }
        public bool compress_copy { get { return compression.sensitive && compression.active; } }

        construct {
            format_choice.notify["selected"].connect (() => {
                compression.sensitive = format == "qcow2";
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
        [GtkChild] private unowned Adw.ActionRow format_row;
        public string format { owned get { return disk_image_format (format_choice.selected); } }
        public uint64 bytes { get { return (uint64) size.get_value_as_int () * (unit.selected == 0 ? 1048576 : 1073741824); } }
        public bool attach_after { get { return attach.sensitive && attach.active; } }

        public void configure_growth (File source, uint64 current_size) {
            heading = "Grow a Copy of the Disk Image";
            body = "%s · %s\n\nChoose a larger virtual capacity for the copy. Partitions and filesystems inside it keep their current sizes.".printf (
                source.get_parse_name (), format_size (current_size));
            format_row.visible = false;
            attach.visible = false;
            size.value = (double) (current_size / 1048576 + 1);
            size.value_changed.connect (() => set_response_enabled ("create", bytes > current_size));
            unit.notify["selected"].connect (() => set_response_enabled ("create", bytes > current_size));
            set_response_enabled ("create", bytes > current_size);
        }

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

    [GtkTemplate (ui = "/com/majoris/disks/ui/luks-header-backup-dialog.ui")]
    internal class LuksHeaderBackupDialog : Adw.AlertDialog {}

    [GtkTemplate (ui = "/com/majoris/disks/ui/luks-header-restore-dialog.ui")]
    internal class LuksHeaderRestoreDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.EntryRow confirmation;

        public LuksHeaderRestoreDialog (string target, bool advanced) {
            if (advanced) confirmation.title = "Type the device path, a space, and the LUKS UUID";
            set_response_enabled ("restore", false);
            confirmation.changed.connect (() => set_response_enabled ("restore", confirmation.text == target));
        }
    }

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
        private StorageEncryptionConfiguration[] configurations;
        private string default_options;
        private Gtk.StringList entries = new Gtk.StringList (null);
        public Variant? original_item { owned get {
            return entry.selected < configurations.length ? configurations[entry.selected].backend_item : null;
        } }
        public EncryptionOptionsDialog (StorageBlock block, string identity) {
            configurations = block.encryption_configurations;
            default_options = block.physical_drive?.removable == true ? "nofail,noauto" : "nofail";
            confirmed_identity = identity; confirmed_uuid = block.uuid;
            entry.model = entries;
            foreach (var configuration in configurations)
                entries.append (configuration.name + " · " + configuration.device);
            entries.append ("New configuration"); entry.selected = 0;
            entry.notify["selected"].connect (load_selected);
            custom.notify["active"].connect (validate); startup.notify["active"].connect (validate);
            mapping_name.changed.connect (validate); options.changed.connect (validate); secret.changed.connect (validate);
            load_selected ();
        }
        private void load_selected () {
            var configuration = entry.selected < configurations.length ? configurations[entry.selected] : null;
            custom.active = configuration != null;
            mapping_name.text = configuration?.name ?? "luks-" + confirmed_uuid;
            options.text = configuration?.options ?? default_options;
            startup.active = !("," + options.text + ",").contains (",noauto,");
            keyfile.subtitle = configuration == null || configuration.passphrase_path == "" ? "None" :
                configuration.passphrase_path;
            identifier.subtitle = configuration?.device ?? "UUID=" + confirmed_uuid;
            secret.text = ""; validate ();
        }
        private void validate () {
            bool fields = custom.active;
            var configuration = entry.selected < configurations.length ? configurations[entry.selected] : null;
            string key_path = configuration?.passphrase_path ?? "";
            bool device_key = key_path.has_prefix ("/dev/");
            bool external_key = key_path != "" && !device_key &&
                !MountOptionService.manages_crypttab_keyfile (key_path);
            body = external_key ? "Editing or removing this entry through UDisks could delete an externally managed key file." :
                fields && device_key ? "UDisks cannot safely edit an entry that uses a device as its key." :
                !fields && key_path != "" && !device_key ?
                    "Removing this entry also deletes its key file. Make sure you have another way to unlock the volume." : "";
            set_response_appearance ("apply", !fields && key_path != "" && !device_key ?
                Adw.ResponseAppearance.DESTRUCTIVE : Adw.ResponseAppearance.SUGGESTED);
            startup.sensitive = fields; mapping_name.sensitive = fields; options.sensitive = fields;
            secret.sensitive = fields;
            bool valid = !fields || (mapping_name.text.strip () != "" && !mapping_name.text.contains ("/") &&
                !mapping_name.text.contains (",") && !mapping_name.text.contains (" "));
            if (valid && fields && !device_key) {
                try { MountOptionService.normalize_encryption (options.text, startup.active); }
                catch (Error error) { valid = false; }
            }
            set_response_enabled ("apply", valid && !external_key && !(fields && device_key));
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
            if (standby_code == 0)
                standby.subtitle = "Never enter standby";
            else if (standby_code <= 240)
                standby.subtitle = "%d minutes %d seconds".printf ((standby_code * 5) / 60, (standby_code * 5) % 60);
            else
                standby.subtitle = "Special ATA timeout value %d".printf (standby_code);
            int apm_code = (int) apm.value;
            if (apm_code == 255)
                apm.subtitle = "APM disabled";
            else if (apm_code <= 127)
                apm.subtitle = "%d · power saving with spin-down permitted".printf (apm_code);
            else
                apm.subtitle = "%d · performance, spin-down not permitted".printf (apm_code);
            int aam_code = (int) aam.value;
            switch (aam_code) {
                case 128: aam.subtitle = "128 · quietest"; break;
                case 254: aam.subtitle = "254 · fastest"; break;
                default:
                    if (aam_code < 128) aam.subtitle = "AAM disabled";
                    else aam.subtitle = aam_code.to_string ();
                    break;
            }
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
    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-balance-dialog.ui")]
    internal class BtrfsBalanceDialog : Adw.AlertDialog {
        [GtkChild] private unowned Gtk.SpinButton usage;
        public uint usage_limit { get { return (uint) usage.get_value_as_int (); } }

        public BtrfsBalanceDialog (bool writable, bool scrubbable = true) {
            set_response_enabled ("scrub-readonly", scrubbable);
            set_response_enabled ("scrub-cancel", scrubbable);
            foreach (string action in new string[] { "balance-data", "balance-metadata", "balance-pause",
                "balance-resume", "balance-cancel" })
                set_response_enabled (action, writable);
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-subvolumes-dialog.ui")]
    internal class BtrfsSubvolumesDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow subvolumes;
        [GtkChild] private unowned Adw.EntryRow new_subvolume;
        [GtkChild] private unowned Adw.SwitchRow snapshot_read_only;
        private BtrfsSubvolume?[] sources = { null };
        public bool read_only_snapshot { get { return snapshot_read_only.active; } }
        public unowned BtrfsSubvolume? snapshot_source {
            get { return subvolumes.selected < sources.length ? sources[subvolumes.selected] : null; }
        }
        public string new_name { owned get { return new_subvolume.text; } }
        private uint64[] ids = { 5 };
        public uint selected_id { get { return (uint) ids[subvolumes.selected]; } }

        public BtrfsSubvolumesDialog (BtrfsSubvolumeList info, bool can_change) {
            var labels = new Gtk.StringList (null);
            labels.append ("Top-level subvolume · ID 5");
            uint selected = 0;
            foreach (var entry in info.entries) {
                if (entry.id == 5) continue;
                if (info.default_known && entry.id == info.default_id) selected = ids.length;
                ids += entry.id;
                sources += entry;
                labels.append ("%s · ID %s · parent %s%s".printf (entry.path, entry.id.to_string (),
                    entry.parent_id.to_string (), entry.snapshot ? " · Snapshot" : ""));
            }
            subvolumes.model = labels;
            subvolumes.selected = selected;
            body = info.default_known
                ? "Default subvolume ID %u. Changing the default affects future mounts without an explicit subvolume.".printf (info.default_id)
                : info.default_unavailable != "" ? info.default_unavailable : "The default subvolume could not be read.";
            set_response_enabled ("apply", false);
            new_subvolume.visible = can_change;
            snapshot_read_only.visible = can_change;
            set_response_enabled ("create", false);
            set_response_enabled ("snapshot", false);
            set_response_enabled ("delete", false);
            new_subvolume.changed.connect (() => update_create_responses (can_change));
            subvolumes.notify["selected"].connect (() => {
                update_create_responses (can_change);
                var chosen = snapshot_source;
                set_response_enabled ("delete", can_change && info.default_known && chosen != null &&
                    chosen.id != info.default_id && chosen.parent_id == 5 &&
                    UDisksService.valid_btrfs_leaf (chosen.path));
                uint index = subvolumes.selected;
                set_response_enabled ("apply", can_change && info.default_known && index < ids.length &&
                    ids[index] <= uint.MAX && ids[index] != info.default_id);
            });
        }

        private void update_create_responses (bool can_change) {
            bool valid = can_change && UDisksService.valid_btrfs_leaf (new_name);
            var source = snapshot_source;
            set_response_enabled ("create", valid);
            set_response_enabled ("snapshot", valid && source != null && source.parent_id == 5 &&
                UDisksService.valid_btrfs_leaf (source.path) && source.path != new_name);
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/create-storage-group-dialog.ui")]
    internal class CreateStorageGroupDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.EntryRow name_entry;
        [GtkChild] private unowned Adw.ComboRow raid_level;
        [GtkChild] private unowned Adw.ComboRow chunk_size;
        [GtkChild] private unowned Gtk.ListBox devices;
        [GtkChild] private unowned Adw.ActionRow estimate;
        [GtkChild] private unowned Adw.SwitchRow erase;
        private StorageBlock[] candidates = {};
        private string[] candidate_identities = {};
        private Gtk.CheckButton[] checks = {};
        private bool raid;
        private bool single_member;
        public string group_name { owned get { return name_entry.text; } }
        public string level { owned get {
            string[] levels = { "raid0", "raid1", "raid4", "raid5", "raid6", "raid10" };
            return raid ? levels[uint.min (raid_level.selected, 5)] : "";
        } }
        public uint64 chunk { get {
            uint64[] sizes = { 0, 65536, 131072, 262144, 524288 };
            return raid && level != "raid1" ? sizes[uint.min (chunk_size.selected, 4)] : 0;
        } }

        public CreateStorageGroupDialog (UDisksService backend, bool raid, bool single_member = false, string member_heading = "Add RAID Member",
            StorageBlock[]? member_choices = null) {
            this.raid = raid;
            this.single_member = single_member;
            heading = raid ? "Create RAID Array" : "Create LVM Volume Group";
            body = "Choose unused devices. Creation erases every selected device.";
            raid_level.visible = raid;
            if (single_member) {
                heading = member_heading;
                body = "Select one unused device. Adding it can overwrite its contents.";
                name_entry.visible = false;
                estimate.visible = false;
                set_response_label ("create", member_choices == null ? "Add" : "Remove");
                if (member_choices != null) erase.title = "Confirm removal of the selected device";
            }
            foreach (var block in backend.snapshot.blocks.get_values ()) {
                if (member_choices == null ? !backend.can_use_group_member (block) : !(block in member_choices)) continue;
                candidates += block;
                candidate_identities += backend.modification_identity (block);
                var check = new Gtk.CheckButton.with_label ("%s · %s".printf (block.preferred, format_size (block.size)));
                checks += check;
                check.toggled.connect (() => { erase.active = false; validate (); });
                devices.append (check);
            }
            name_entry.changed.connect (validate);
            raid_level.notify["selected"].connect (validate);
            erase.notify["active"].connect (validate);
            validate ();
        }

        public StorageBlock[] selected_members (out string[] identities) {
            StorageBlock[] result = {};
            string[] selected_identities = {};
            for (int i = 0; i < checks.length; i++) {
                if (!checks[i].active) continue;
                result += candidates[i];
                selected_identities += candidate_identities[i];
            }
            identities = selected_identities;
            return result;
        }

        private void validate () {
            string[] identities;
            var members = selected_members (out identities);
            uint minimum = raid ? UDisksService.raid_min_members (level) : 1;
            chunk_size.visible = raid && level != "raid1";
            uint64 smallest = uint64.MAX;
            uint64 capacity = 0;
            foreach (var block in members) {
                smallest = uint64.min (smallest, block.size);
                capacity += uint64.min (uint64.MAX - capacity, block.size);
            }
            if (raid && members.length >= minimum) {
                uint64 data_members = members.length;
                if (level == "raid1") data_members = 1;
                else if (level == "raid4" || level == "raid5") data_members--;
                else if (level == "raid6") data_members -= 2;
                else if (level == "raid10") data_members /= 2;
                capacity = uint64.min (smallest, uint64.MAX / data_members) * data_members;
            }
            estimate.subtitle = members.length >= minimum ? format_size (capacity) :
                "Select at least %u devices.".printf (minimum);
            if (single_member) {
                set_response_enabled ("create", erase.active && members.length == 1);
                return;
            }
            set_response_enabled ("create", erase.active && members.length >= minimum &&
                UDisksService.valid_lvm_name (group_name) && (!raid || group_name.length <= 32) &&
                (level != "raid10" || members.length % 2 == 0));
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/lvm-create-dialog.ui")]
    internal class CreateLogicalVolumeDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.EntryRow name_entry;
        [GtkChild] private unowned Adw.EntryRow capacity;
        [GtkChild] private unowned Adw.ComboRow unit;
        [GtkChild] private unowned Adw.ActionRow allocation;
        [GtkChild] private unowned Adw.ComboRow lv_kind;
        [GtkChild] private unowned Adw.ComboRow thin_pool;
        [GtkChild] private unowned Adw.SwitchRow overcommit;
        public bool allow_overcommit { get { return overcommit.visible && overcommit.active; } }
        private StorageSnapshot? snapshot;
        private StorageLogicalVolume? snapshot_origin;
        private StorageLogicalVolume? resize_pool;
        private StorageLogicalVolume[] pools = {};
        public bool create_thin_pool { get { return resize_from == 0 && lv_kind.selected == 1; } }
        public unowned StorageLogicalVolume? selected_pool {
            get { return resize_from == 0 && lv_kind.selected == 2 && thin_pool.selected < pools.length ?
                pools[thin_pool.selected] : null; }
        }
        private string[] used_names = {};
        private StorageVolumeGroup group;
        private uint64 resize_from;
        private bool allow_shrink;
        private uint64 maximum;
        public string volume_name { owned get { return name_entry.text; } }
        public uint64 bytes { get; private set; }

        public CreateLogicalVolumeDialog (StorageVolumeGroup group, StorageSnapshot? snapshot = null,
            uint64 resize_from = 0, bool allow_shrink = false, StorageLogicalVolume? snapshot_origin = null,
            StorageLogicalVolume? resize_pool = null) {
            this.group = group;
            this.snapshot = snapshot;
            this.snapshot_origin = snapshot_origin;
            this.resize_pool = resize_pool;
            this.resize_from = resize_from;
            this.allow_shrink = allow_shrink;
            var pool_labels = new Gtk.StringList (null);
            if (snapshot != null) {
                foreach (var item in snapshot.advanced.get_values ()) {
                    var lv = item as StorageLogicalVolume;
                    if (lv == null || lv.group_path != group.path) continue;
                    used_names += lv.name;
                    if (lv.lvm_type == "pool" && lv.uuid != "") {
                        pools += lv;
                        pool_labels.append (lv.name);
                    }
                }
            }
            thin_pool.model = pool_labels;
            uint64 usable = group.extent_size == 0 ? 0 : group.free_size - group.free_size % group.extent_size;
            maximum = resize_from + uint64.min (uint64.MAX - resize_from, usable);
            body = "%s · %s allocatable · %s per extent".printf (group.name,
                format_size (usable), format_size (group.extent_size));
            if (snapshot_origin != null) {
                heading = "Create LVM Snapshot";
                body = "Snapshot origin %s · %s free for copy-on-write data · %s per extent".printf (
                    snapshot_origin.name, format_size (usable), format_size (group.extent_size));
                if (snapshot_origin.thin_pool_path != "/") {
                    body = "Thin snapshot of %s. It shares existing blocks with the origin and uses pool space as writes diverge.".printf (snapshot_origin.name);
                    capacity.visible = false;
                    unit.visible = false;
                }
                lv_kind.visible = false;
            }
            if (resize_from != 0) {
                heading = "Resize Logical Volume";
                body = "%s · %s current capacity · %s maximum · %s per extent".printf (group.name,
                    format_size (resize_from), format_size (maximum), format_size (group.extent_size));
                if (resize_pool != null)
                    body = "%s thin pool · %s current virtual capacity · %s per extent".printf (
                        resize_pool.name, format_size (resize_from), format_size (group.extent_size));
                name_entry.visible = false;
                lv_kind.visible = false;
                set_response_label ("create", "Resize");
            }
            name_entry.changed.connect (validate);
            capacity.changed.connect (reset_overcommit);
            unit.notify["selected"].connect (reset_overcommit);
            lv_kind.notify["selected"].connect (reset_overcommit);
            thin_pool.notify["selected"].connect (reset_overcommit);
            overcommit.notify["active"].connect (validate);
            validate ();
        }

        private void reset_overcommit () {
            overcommit.active = false;
            validate ();
        }

        private void validate () {
            uint64[] units = { 1048576, 1073741824, 1099511627776 };
            bool thin_snapshot = snapshot_origin != null && snapshot_origin.thin_pool_path != "/";
            bool thin_resize = resize_from != 0 && resize_pool != null;
            bool thin = resize_from == 0 && lv_kind.selected == 2;
            var pool = thin_snapshot ? snapshot?.advanced.lookup (snapshot_origin.thin_pool_path) as StorageLogicalVolume : thin_resize ? resize_pool : selected_pool;
            thin_pool.visible = thin;
            if (thin_snapshot) {
                var snapshot_usage = pool != null && snapshot != null ? new ThinPoolUsage (snapshot, pool) : null;
                bool safe = snapshot_usage != null && snapshot_origin.size > 0 &&
                    snapshot_origin.size <= snapshot_usage.virtual_limit ();
                overcommit.visible = safe && snapshot_usage.overcommits (snapshot_origin.size);
                allocation.subtitle = safe ? "%s virtual snapshot capacity".printf (format_size (snapshot_origin.size)) :
                    "Pool capacity is unknown or exhausted.";
                set_response_enabled ("create", safe && (!overcommit.visible || overcommit.active) &&
                    UDisksService.valid_lvm_name (volume_name) && !(volume_name in used_names));
                bytes = 0;
                return;
            }
            var usage = (thin || thin_resize) && pool != null && snapshot != null ? new ThinPoolUsage (snapshot, pool) : null;
            uint64 limit = thin ? usage?.virtual_limit () ?? 0 : maximum;
            if (thin_resize)
                limit = usage != null && usage.can_provision () ? resize_from +
                    uint64.min (uint64.MAX - resize_from, usage.virtual_limit ()) :
                    usage?.can_shrink () == true ? resize_from : 0;
            if (thin) {
                if (usage == null) thin_pool.subtitle = "No thin pools are available.";
                else if (!usage.usage_known || !usage.virtual_known || !usage.active)
                    thin_pool.subtitle = "Pool is inactive or its allocation is unknown.";
                else {
                    thin_pool.subtitle = "%s total pool size · %s virtual (%.2f×) · %.1f%% data · %.1f%% metadata · estimated data space remaining %s".printf (
                        format_size (usage.physical_size), format_size (usage.virtual_size), usage.overcommit_ratio (),
                        usage.data_ratio * 100.0, usage.metadata_ratio * 100.0, format_size (usage.estimated_data_remaining ()));
                    if (usage.data_ratio >= ThinPoolUsage.WARNING_RATIO || usage.metadata_ratio >= ThinPoolUsage.WARNING_RATIO)
                        thin_pool.subtitle += " · Pool usage is at or above 90%";
                }
            }
            uint64 size;
            bool aligned = LvmCapacity.parse (capacity.text, units[uint.min (unit.selected, 2)],
                group.extent_size, limit, out size);
            bytes = aligned ? size : 0;
            uint64 additional = size > resize_from ? size - resize_from : 0;
            overcommit.visible = aligned && usage != null && additional > 0 && usage.overcommits (additional);
            string invalid_capacity = thin_resize && usage?.can_shrink () != true ?
                "An active pool with known allocation and free metadata is required." :
                thin_resize && usage?.can_provision () != true ?
                    "Growth is unavailable. Enter a smaller extent-aligned size to shrink." :
                    "Enter an exact multiple of the extent size within the available capacity.";
            allocation.subtitle = aligned
                ? (thin ? "%s virtual capacity · %s total virtual afterward".printf (format_size (size),
                    format_size (usage.virtual_size + size)) :
                    resize_from == 0 ? "%s allocated · %s free afterward".printf (format_size (size), format_size (group.free_size - size)) :
                    "%s resulting capacity".printf (format_size (size)))
                : invalid_capacity;
            bool valid_name = UDisksService.valid_lvm_name (volume_name) && !(volume_name in used_names);
            set_response_enabled ("create", aligned && (!overcommit.visible || overcommit.active) &&
                (resize_from == 0 ? valid_name :
                size != resize_from && (allow_shrink || size > resize_from)));
        }
    }
    [GtkTemplate (ui = "/com/majoris/disks/ui/storage-removal-dialog.ui")]
    internal class StorageRemovalDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.SwitchRow wipe;
        public bool wipe_metadata { get { return wipe.visible && wipe.active; } }

        public StorageRemovalDialog (bool allow_wipe) {
            wipe.visible = allow_wipe;
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/lvm-lifecycle-dialog.ui")]
    internal class LvmLifecycleDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow volumes;
        private StorageLogicalVolume[] entries;
        private bool physical_context;
        public unowned StorageLogicalVolume? selection {
            get { return volumes.selected < entries.length ? entries[volumes.selected] : null; }
        }

        public LvmLifecycleDialog (StorageLogicalVolume[] entries, string preferred, bool physical_context = false) {
            this.entries = entries;
            this.physical_context = physical_context;
            set_response_enabled ("migrate", physical_context);
            set_response_enabled ("remove-pv", physical_context);
            set_response_enabled ("delete-vg", physical_context && entries.length == 0);
            var labels = new Gtk.StringList (null);
            uint index = 0;
            foreach (var volume in entries) {
                if (volume.path == preferred) index = labels.get_n_items ();
                labels.append ("%s · %s · %s".printf (volume.name, format_size (volume.size),
                    volume.origin_path != "/" ? (volume.active ? "Active snapshot" : "Inactive snapshot") :
                        volume.active ? "Active" : "Inactive"));
            }
            volumes.model = labels;
            if (entries.length > 0) volumes.selected = index;
            else body = "No logical volumes are available in this group.";
            volumes.notify["selected"].connect (update_buttons);
            update_buttons ();
        }

        private void update_buttons () {
            var volume = selection;
            set_response_enabled ("activate", volume != null && volume.lvm_type == "block" && !volume.active);
            set_response_enabled ("deactivate", volume?.active == true &&
                (volume.lvm_type == "block" || (physical_context && volume.lvm_type == "pool")));
            set_response_enabled ("expand-pool", physical_context && volume?.lvm_type == "pool" && volume.active);
            set_response_enabled ("snapshot", physical_context && volume != null && volume.active &&
                volume.lvm_type == "block" && (volume.origin_path == "/" || volume.thin_pool_path != "/"));
            set_response_enabled ("delete", volume != null && (volume.lvm_type == "pool" ?
                physical_context && !volume.active : !volume.active ||
                (volume.origin_path != "/" && volume.thin_pool_path == "/")));
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
        private async void probe (uint generation, uint64 requested, bool with_filesystem, bool can_submit) {
            try {
                var plan = yield backend.resize_plan (block, requested, with_filesystem);
                if (generation != validation_generation) return;
                minimum_row.subtitle = plan.minimum_size == 0 ? "Unavailable" : format_size (plan.minimum_size);
                range_row.subtitle = "%s to %s".printf (
                    format_size (plan.minimum_size == 0 ? sector : plan.minimum_size), format_size (maximum));
                string direction = plan.direction == ResizeDirection.SHRINK ? "Shrink" :
                    plan.direction == ResizeDirection.GROW ? "Grow" : "No size change";
                mode_row.subtitle = plan.supported ? "%s · %s".printf (direction,
                    plan.online ? "online" : plan.requires_unmount ? "offline after unmount" :
                    plan.resize_filesystem ? "offline" : "partition only") : "Unavailable";
                if (!can_submit)
                    explanation_row.subtitle = "Choose a different size.";
                else if (!plan.supported)
                    explanation_row.subtitle = plan.reason;
                else if (plan.requires_unmount)
                    explanation_row.subtitle = plan.requires_check ?
                        "The filesystem will be unmounted, checked, resized, and remounted." :
                        "The filesystem will be unmounted for the resize and then remounted.";
                else
                    explanation_row.subtitle = plan.requires_check ?
                        "The unmounted filesystem will be checked before resizing." :
                        "The operation fits the verified partition boundary.";
                set_response_enabled ("resize", can_submit && plan.supported);
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
                probe.begin (generation, shrink_probe, filesystem_row.active, false);
                return;
            }
            explanation_row.subtitle = "Checking the current device state…";
            probe.begin (generation, new_size, filesystem_row.active, true);
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
