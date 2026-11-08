namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/drive-view.ui")]
    public class DriveView : Gtk.Box {
        [GtkChild] private unowned Adw.ActionRow summary;
        [GtkChild] private unowned Gtk.Image drive_icon;
        [GtkChild] private unowned Gtk.Button information;
        [GtkChild] private unowned Gtk.Button health;
        [GtkChild] private unowned Gtk.Button backup_drive;
        [GtkChild] private unowned Gtk.Button detach_image_button;
        [GtkChild] private unowned Gtk.Button restore_drive;
        [GtkChild] private unowned Gtk.Button backup_volume;
        [GtkChild] private unowned Gtk.Button restore_partition;
        [GtkChild] private unowned Gtk.Button benchmark_button;
        [GtkChild] private unowned Gtk.MenuButton drive_actions;
        [GtkChild] private unowned Gtk.Button eject_drive;
        [GtkChild] private unowned Gtk.Button power_off_drive;
        [GtkChild] private unowned Gtk.Button standby_drive;
        [GtkChild] private unowned Gtk.Button wake_drive;
        [GtkChild] private unowned Gtk.Button drive_settings;
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
        [GtkChild] private unowned Gtk.Button edit_label;
        [GtkChild] private unowned Gtk.Button rename_lvm;
        [GtkChild] private unowned Gtk.Button manage_lvm;
        [GtkChild] private unowned Gtk.Button add_lvm_member;
        [GtkChild] private unowned Gtk.Button create_lvm;
        [GtkChild] private unowned Gtk.Button raid_check;
        [GtkChild] private unowned Gtk.Button raid_add;
        [GtkChild] private unowned Gtk.Button raid_replace;
        [GtkChild] private unowned Gtk.Button raid_delete;
        [GtkChild] private unowned Gtk.Button raid_remove_spare;
        [GtkChild] private unowned Gtk.Button raid_power;
        [GtkChild] private unowned Gtk.Button raid_recover;
        [GtkChild] private unowned Gtk.Button btrfs_subvolumes;
        [GtkChild] private unowned Gtk.Button btrfs_add;
        [GtkChild] private unowned Gtk.Button btrfs_remove;
        [GtkChild] private unowned Gtk.Button btrfs_allocation;
        [GtkChild] private unowned Gtk.Button btrfs_balance;
        [GtkChild] private unowned Gtk.Button mount_options;
        [GtkChild] private unowned Gtk.Button unlock_volume;
        [GtkChild] private unowned Gtk.Button lock_volume;
        [GtkChild] private unowned Gtk.Button change_passphrase;
        [GtkChild] private unowned Gtk.Button encryption_options;
        [GtkChild] private unowned Gtk.MenuButton encryption_menu;
        [GtkChild] private unowned Gtk.Button luks_backup;
        [GtkChild] private unowned Gtk.Button luks_keyslots;
        [GtkChild] private unowned Gtk.Button luks_restore;
        [GtkChild] private unowned Gtk.Button luks_recovery;
        [GtkChild] private unowned Gtk.Button take_ownership;
        [GtkChild] private unowned Gtk.Button edit_partition;
        [GtkChild] private unowned Gtk.Button create_partition;
        [GtkChild] private unowned Gtk.Button resize_volume;
        public signal void metadata_requested (StorageBlock block);
        public signal void ownership_requested (StorageBlock block);
        public signal void label_requested (StorageBlock block);
        public signal void lvm_rename_requested (StorageBlock block);
        public signal void lvm_manage_requested (StorageBlock block);
        public signal void lvm_add_member_requested (StorageBlock block);
        public signal void lvm_create_requested (StorageBlock block);
        public signal void raid_check_requested (StorageBlock block);
        public signal void raid_member_requested (StorageBlock block, bool add);
        public signal void raid_replace_requested (StorageBlock block);
        public signal void raid_delete_requested (StorageBlock block);
        public signal void raid_power_requested (StorageBlock block, bool running);
        public signal void raid_recovery_requested (StorageBlock block);
        public signal void btrfs_subvolumes_requested (StorageBlock block);
        public signal void btrfs_add_requested (StorageBlock block);
        public signal void btrfs_remove_requested (StorageBlock block);
        public signal void btrfs_allocation_requested (StorageBlock block);
        public signal void btrfs_balance_requested (StorageBlock block);
        public signal void mount_options_requested (StorageBlock block);
        public signal void encryption_requested (StorageBlock block, bool unlock);
        public signal void passphrase_requested (StorageBlock block);
        public signal void encryption_options_requested (StorageBlock block);
        internal signal void luks_keyslots_requested (StorageBlock block);
        internal signal void luks_header_requested (StorageBlock block, bool restore, bool advanced);
        public signal void format_requested (StorageBlock block);
        public signal void partitioning_requested (StorageBlock block, bool deleting);
        public signal void create_requested (StorageBlock disk, StorageFreeSpace gap);
        public signal void resize_requested (StorageBlock block);
        private StorageBlock? selected_block;

        private void request_luks_header (bool restore, bool advanced) {
            encryption_menu.popdown ();
            if (selected_block != null) luks_header_requested (selected_block, restore, advanced);
        }
        public signal void check_requested (StorageBlock block, bool repair);
        public UDisksService? backend { private get; set; }
        private uint maintenance_generation;
        private StorageDrive? current;
        private StorageBlock? target;
        private string method = "";
        private string selected = "";
        private bool updating;
        private FilesystemUsageService usage_service = new FilesystemUsageService ();
        public signal void action_requested (StorageBlock block, string method);
        public signal void detach_image_requested (StorageBlock block);
        public signal void backup_requested (StorageBlock block);
        public signal void restore_requested (StorageBlock block);
        public signal void benchmark_requested (StorageDrive drive);
        public signal void health_requested (StorageDrive drive);
        public signal void drive_action_requested (StorageDrive drive, string action);
        public signal void drive_settings_requested (StorageDrive drive);
        public signal void open_failed ();
        public void invalidate_usage (StorageBlock block) { usage_service.invalidate (block.path); if (target == block) usage.label = usage_service.show (block); }

        static construct {
            typeof (PartitionMap).ensure ();
        }

        construct {
            usage_service.updated.connect ((description) => usage.label = description);
            information.clicked.connect (() => {
                if (current != null) new DriveInformationDialog (current, selected_block).present (this);
            });
            detach_image_button.clicked.connect (() => { if (current?.medium != null) detach_image_requested (current.medium); });
            backup_drive.clicked.connect (() => { if (current?.medium != null) backup_requested (current.medium); });
            restore_drive.clicked.connect (() => { if (current?.medium != null) restore_requested (current.medium); });
            backup_volume.clicked.connect (() => { if (selected_block != null) backup_requested (selected_block); });
            // Adapted from GNOME Disks gdu-block-row.c, restore_partition_image_cb.
            // Copyright 2023 Mohammed Sadiq <sadiq@sadiqpk.org>
            // Copyright (C) 2008-2013 Red Hat, Inc.
            // Upstream license: GPL-2.0-or-later.
            restore_partition.clicked.connect (() => {
                var block = selected_block;
                if (block?.partition != null && !block.partition.container) restore_requested (block);
            });
            benchmark_button.clicked.connect (() => { if (current != null) benchmark_requested (current); });
            health.clicked.connect (() => { if (current != null) health_requested (current); });
            eject_drive.clicked.connect (() => request_drive_action ("Eject"));
            power_off_drive.clicked.connect (() => request_drive_action ("PowerOff"));
            standby_drive.clicked.connect (() => request_drive_action ("PmStandby"));
            wake_drive.clicked.connect (() => request_drive_action ("PmWakeup"));
            drive_settings.clicked.connect (() => {
                if (current != null) drive_settings_requested (current);
                drive_actions.popover?.popdown ();
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
            edit_partition.clicked.connect (() => {
                if (selected_block != null) metadata_requested (selected_block);
            });
            create_partition.clicked.connect (() => {
                var gap = volumes.get_selected_row () as VolumeRow;
                var space = gap?.device as StorageFreeSpace;
                var disk = current?.medium;
                if (space != null && disk != null) create_requested (disk, space);
            });
            resize_volume.clicked.connect (() => {
                if (selected_block != null) resize_requested (selected_block);
            });
            take_ownership.clicked.connect (() => {
                if (target != null) ownership_requested (target);
            });
            raid_recover.clicked.connect (() => {
                if (selected_block != null) raid_recovery_requested (selected_block);
            });
            raid_power.clicked.connect (() => {
                if (selected_block != null) raid_power_requested (selected_block, selected_block.raid == null);
            });
            raid_delete.clicked.connect (() => {
                if (selected_block != null) raid_delete_requested (selected_block);
            });
            raid_replace.clicked.connect (() => {
                if (selected_block != null) raid_replace_requested (selected_block);
            });
            raid_add.clicked.connect (() => {
                if (selected_block != null) raid_member_requested (selected_block, true);
            });
            raid_remove_spare.clicked.connect (() => {
                if (selected_block != null) raid_member_requested (selected_block, false);
            });
            raid_check.clicked.connect (() => {
                if (selected_block != null) raid_check_requested (selected_block);
            });
            btrfs_balance.clicked.connect (() => {
                if (selected_block != null) btrfs_balance_requested (selected_block);
            });
            btrfs_allocation.clicked.connect (() => {
                if (selected_block != null) btrfs_allocation_requested (selected_block);
            });
            btrfs_remove.clicked.connect (() => {
                if (selected_block != null) btrfs_remove_requested (selected_block);
            });
            btrfs_add.clicked.connect (() => {
                if (selected_block != null) btrfs_add_requested (selected_block);
            });
            btrfs_subvolumes.clicked.connect (() => {
                if (selected_block != null) btrfs_subvolumes_requested (selected_block);
            });
            create_lvm.clicked.connect (() => {
                if (selected_block != null) lvm_create_requested (selected_block);
            });
            add_lvm_member.clicked.connect (() => {
                if (selected_block != null) lvm_add_member_requested (selected_block);
            });
            manage_lvm.clicked.connect (() => {
                if (selected_block != null) lvm_manage_requested (selected_block);
            });
            rename_lvm.clicked.connect (() => {
                if (selected_block != null) lvm_rename_requested (selected_block);
            });
            edit_label.clicked.connect (() => {
                if (selected_block != null) label_requested (selected_block);
            });
            mount_options.clicked.connect (() => { if (target != null) mount_options_requested (target); });
            unlock_volume.clicked.connect (() => { encryption_menu.popdown (); if (selected_block != null) encryption_requested (selected_block, true); });
            lock_volume.clicked.connect (() => { encryption_menu.popdown (); if (selected_block != null) encryption_requested (selected_block, false); });
            change_passphrase.clicked.connect (() => {
                encryption_menu.popdown ();
                if (selected_block != null) passphrase_requested (selected_block);
            });
            encryption_options.clicked.connect (() => {
                encryption_menu.popdown ();
                if (selected_block != null) encryption_options_requested (selected_block);
            });
            luks_keyslots.clicked.connect (() => {
                encryption_menu.popdown ();
                if (selected_block != null) luks_keyslots_requested (selected_block);
            });
            luks_backup.clicked.connect (() => request_luks_header (false, false));
            luks_restore.clicked.connect (() => request_luks_header (true, false));
            luks_recovery.clicked.connect (() => request_luks_header (true, true));
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

        public void select_identity (string identity) {
            selected = identity;
            if (current != null) show_drive (current);
        }

        public void show_drive (StorageDrive drive) {
            if (current != drive) selected = "";
            current = drive;
            var disk = drive.medium;
            initialize_disk.visible = disk != null && disk.available && !disk.read_only && !disk.system_hint;
            summary.title = drive.name;
            benchmark_button.visible = drive.medium != null && drive.medium.size >= 1024 * 1024;
            health.visible = drive.smart || drive.nvme_state != "";
            eject_drive.visible = drive.ejectable;
            power_off_drive.visible = drive.can_power_off;
            standby_drive.visible = drive.ata_power_management;
            wake_drive.visible = drive.ata_power_management;
            drive_settings.visible = drive.ata_apm_supported || drive.ata_aam_supported ||
                drive.ata_write_cache_supported || drive.ata_read_lookahead_supported ||
                (drive.ata_power_management && drive.rotation != 0);
            detach_image_button.visible = drive.medium?.loop != null || drive.medium?.virtual_attachment != null;
            backup_drive.visible = disk != null && disk.size > 0;
            restore_drive.visible = false;
            if (disk != null && disk.available && disk.size > 0 && backend != null) {
                var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.IMAGE_RESTORE,
                    disk, backend.snapshot.dependencies);
                restore_drive.visible = eligibility.allowed && !eligibility.unknown;
            }
            drive_actions.visible = detach_image_button.visible || backup_drive.visible || restore_drive.visible || eject_drive.visible ||
                power_off_drive.visible || standby_drive.visible || drive_settings.visible;
            drive_icon.icon_name = drive.icon;
            summary.subtitle = drive.available ? format_size (drive.size) : "No media available";
            if (disk != null) summary.subtitle += " · " + disk.preferred;
            if (disk?.loop != null) summary.subtitle += "\n" + disk.loop.backing_file +
                (disk.read_only ? " · Read-only" : " · Read/write");
            if (disk?.virtual_attachment != null) {
                var attachment = disk.virtual_attachment;
                summary.subtitle += "\n" + (attachment.file == "" ? "Managed NBD image · recovery details unavailable" :
                    attachment.file + " · " + (attachment.format == "vpc" ? "VHD" : attachment.format.up ()));
                summary.subtitle += disk.read_only ? " · Read-only" : " · Read/write";
            }
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

        private void request_drive_action (string action) {
            if (current != null) drive_action_requested (current, action);
            drive_actions.popover?.popdown ();
        }

        private void show_volume (VolumeRow? row) {
            selected = row != null ? row.device.path : "";
            map.select (selected);
            properties.visible = row != null;
            target = null;
            maintenance_generation++;
            method = "";
            operation.visible = false;
            open_files.visible = false;
            check_filesystem.visible = false;
            repair_filesystem.visible = false;
            delete_partition.visible = false;
            format_volume.visible = false;
            edit_label.visible = false;
            rename_lvm.visible = false;
            manage_lvm.visible = false;
            add_lvm_member.visible = false;
            create_lvm.visible = false;
            raid_check.visible = false;
            raid_add.visible = false;
            raid_replace.visible = false;
            raid_delete.visible = false;
            raid_remove_spare.visible = false;
            raid_power.visible = false;
            raid_recover.visible = false;
            btrfs_subvolumes.visible = false;
            btrfs_add.visible = false;
            btrfs_remove.visible = false;
            btrfs_allocation.visible = false;
            btrfs_balance.visible = false;
            mount_options.visible = false;
            take_ownership.visible = false;
            edit_partition.visible = false;
            create_partition.visible = false;
            resize_volume.visible = false;
            restore_partition.visible = false;
            encryption_menu.visible = false;
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
                var disk = current?.medium;
                create_partition.visible = disk?.table != null && disk.available && !disk.read_only &&
                    disk.logical_sector_size != 0 && gap.size >= disk.logical_sector_size;
                add_volume_field ("Allocatable space", create_partition.visible ?
                    "Validated when Create is opened" : "Unavailable");
                return;
            }
            selected_block = block;
            add_lvm_member.visible = block.available && !block.read_only && !block.system_hint && block.volume_group != null;
            manage_lvm.visible = block.available && !block.system_hint &&
                (block.volume_group != null || block.logical_volume != null);
            create_lvm.visible = block.available && !block.read_only && !block.system_hint &&
                (block.volume_group?.extent_size ?? 0) > 0;
            raid_check.visible = backend?.can_check_raid (block) == true;
            raid_add.visible = block.available && !block.system_hint && block.raid?.state == "idle" && block.raid?.degraded == 0;
            raid_replace.visible = backend?.can_replace_missing_raid_member (block) == true;
            raid_remove_spare.visible = backend?.can_remove_inactive_raid_member (block) == true;
            raid_delete.visible = backend?.can_delete_stopped_raid (block) == true;
            raid_power.visible = backend?.can_set_raid_running (block, block.raid == null) == true;
            raid_recover.visible = backend?.can_start_degraded_raid (block) == true;
            if (raid_recover.visible) raid_power.visible = false;
            raid_power.label = block.raid == null ? "Start RAID Array" : "Stop RAID Array";
            btrfs_subvolumes.visible = backend?.has_btrfs_subvolumes (block) == true;
            btrfs_add.visible = btrfs_subvolumes.visible && !block.read_only && !block.system_hint;
            btrfs_allocation.visible = btrfs_subvolumes.visible;
            btrfs_balance.visible = btrfs_subvolumes.visible;
            if (btrfs_add.visible && backend != null)
                foreach (var candidate in backend.snapshot.blocks.get_values ())
                    btrfs_remove.visible |= backend.can_select_btrfs_removal_member (block, candidate);
            if (block.raid != null && block.raid.state != "")
                add_volume_field ("RAID sync action", block.raid.state);
            rename_lvm.visible = block.logical_volume != null && block.available && !block.read_only &&
                !block.system_hint && block.filesystem?.mounted != true;
            edit_label.visible = block.available && !block.read_only && !block.system_hint &&
                FilesystemCapabilityService.supports_label (block.type_id) && block.filesystem != null && !block.filesystem.mounted;
            format_volume.visible = block.table == null && block.partition?.container != true &&
                block.available && !block.read_only && !block.system_hint && block.filesystem?.mounted != true;
            bool container_has_children = false;
            if (block.partition?.container == true && backend != null)
                foreach (var child in backend.snapshot.dependencies.children (block))
                    container_has_children |= (child as StorageBlock)?.partition?.logical == true;
            delete_partition.visible = block.partition != null && (!block.partition.container || !container_has_children) &&
                block.available && !block.read_only && !block.system_hint;
            var scheme = current?.medium?.table?.scheme;
            edit_partition.visible = delete_partition.visible && block.filesystem?.mounted != true &&
                (scheme == "gpt" || (scheme == "dos" && block.partition?.logical != true));
            resize_volume.visible = backend?.can_resize_logical_volume (block) == true ||
                block.partition != null && block.available &&
                !block.read_only && !block.system_hint && block.backing_path == "/" && block.raid_path == "/" &&
                block.logical_volume_path == "/";
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
            var logical = block.logical_volume;
            if (logical != null) {
                add_volume_field ("Logical volume", logical.name);
                if (logical.uuid != "") add_volume_field ("Logical volume UUID", logical.uuid);
                if (logical.size > 0) add_volume_field ("Logical volume capacity", format_size (logical.size));
                if (logical.data_allocated_ratio >= 0.0 && logical.data_allocated_ratio <= 1.0)
                    add_volume_field ("Logical volume allocation", "%.1f%%".printf (logical.data_allocated_ratio * 100.0));
            }
            var group = block.volume_group ?? backend?.snapshot.advanced.lookup (logical?.group_path ?? "/") as StorageVolumeGroup;
            if (group != null) {
                add_volume_field ("LVM volume group", group.name);
                if (group.size > 0) {
                    add_volume_field ("Volume group capacity", format_size (group.size));
                    add_volume_field ("Volume group free space", format_size (group.free_size));
                }
            }
            target = block.encrypted?.mapping ?? block;
            mount_options.visible = target.filesystem != null && target.uuid != "" && !target.read_only && !target.system_hint;
            take_ownership.visible = UDisksService.supports_ownership (target) &&
                !StorageSafetyService.assess (target, backend?.snapshot.dependencies).system_critical;
            if (block.encrypted != null) add_volume_field ("Encryption", target == block ? "Locked" : "Unlocked");
            backup_volume.visible = block.available && block.size > 0;
            if (block.available && block.size > 0 && block.partition != null && !block.partition.container) {
                var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.IMAGE_RESTORE,
                    block, backend?.snapshot.dependencies);
                restore_partition.visible = eligibility.allowed && !eligibility.unknown;
            }
            unlock_volume.visible = block.encrypted != null && block.encrypted.mapping == null && block.available;
            lock_volume.visible = block.encrypted?.mapping != null && block.available && !block.system_hint;
            change_passphrase.visible = block.encrypted != null && block.available && !block.read_only && !block.system_hint;
            encryption_options.visible = change_passphrase.visible && block.uuid != "";
            luks_backup.visible = UDisksService.is_luks_header_candidate (block);
            luks_restore.visible = luks_backup.visible;
            luks_recovery.visible = UDisksService.is_luks_recovery_candidate (block);
            bool header_available = UDisksService.luks_header_available ();
            luks_backup.sensitive = header_available;
            luks_keyslots.visible = luks_backup.visible && header_available;
            luks_restore.sensitive = header_available && !block.read_only && !block.system_hint &&
                block.encrypted?.mapping == null;
            luks_recovery.sensitive = header_available;
            luks_backup.tooltip_text = header_available ? null : "The libcryptsetup header worker is unavailable.";
            luks_recovery.tooltip_text = luks_backup.tooltip_text;
            luks_restore.tooltip_text = !header_available ? luks_backup.tooltip_text :
                !luks_restore.sensitive ? "Restore requires a locked, writable volume outside the running system." : null;
            encryption_menu.label = luks_recovery.visible ? "Advanced Recovery" : "Encryption";
            encryption_menu.visible = unlock_volume.visible || lock_volume.visible || change_passphrase.visible ||
                luks_backup.visible || luks_recovery.visible;
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
            } else if (capabilities.deactivate_swap) {
                method = "Stop";
                operation.label = "Deactivate Swap";
            }
            operation.visible = method != "";
            open_files.visible = fs != null && fs.mounted;
            check_filesystem.visible = fs != null && target.available && !target.ignored &&
                target.type_id != "" && target.encrypted == null;
            repair_filesystem.visible = check_filesystem.visible && !target.read_only && !target.system_hint;
            uint generation = ++maintenance_generation;
            probe_maintenance (check_filesystem, target.type_id, false, generation);
            probe_maintenance (repair_filesystem, target.type_id, true, generation);
            if (fs != null) usage.label = usage_service.show (target);
            else usage_service.clear ();
        }

        private void probe_maintenance (Gtk.Button button, string filesystem_type, bool repair, uint generation) {
            button.sensitive = false;
            button.tooltip_text = null;
            var service = backend;
            if (!button.visible || service == null) return;
            service.maintenance_available.begin (filesystem_type, repair, (object, result) => {
                try {
                    bool supported = service.maintenance_available.end (result);
                    if (generation != maintenance_generation) return;
                    button.sensitive = supported;
                    if (!supported) button.tooltip_text = "UDisks does not support this operation.";
                    else if (target.filesystem?.mounted == true)
                        button.tooltip_text = "The filesystem will be safely unmounted and restored after this offline operation.";
                } catch (Error error) {
                    if (generation == maintenance_generation) button.tooltip_text = error.message;
                }
            });
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

        public DriveInformationDialog (StorageDrive drive, StorageBlock? selected = null) {
            var disk = drive.medium;
            add_field ("Model", drive.model, true);
            add_field ("Vendor", drive.vendor);
            add_field ("Serial", drive.serial, true);
            add_field ("WWN", drive.wwn, true);
            add_field ("Firmware revision", drive.revision, true);
            add_field ("Device path", disk?.preferred ?? "", true);
            var volume = selected ?? disk;
            if (volume != null) {
                if (volume != disk) add_field ("Volume device path", volume.preferred, true);
                add_field ("Partition UUID", volume.partition?.uuid ?? "", true);
                var filesystem = volume.encrypted?.mapping ?? volume;
                if (filesystem.filesystem != null) add_field ("Filesystem UUID", filesystem.uuid, true);
            }
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
            copy_button.tooltip_text = "Copy " + title;
            copy_button.clicked.connect (() => get_clipboard ().set_text (subtitle));
        }
    }
}
