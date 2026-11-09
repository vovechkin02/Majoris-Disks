using MajorisDisks;

[DBus (name = "org.freedesktop.UDisks2.VolumeGroup")]
private interface PollFixture : Object {
    public abstract void poll () throws DBusError, IOError;
}

private class DelayedPollFixture : Object, PollFixture {
    public bool requested;
    public bool published;

    public void poll () throws DBusError, IOError {
        requested = true;

    }
}

private async void exercise_lvm_poll (DBusProxy proxy, DelayedPollFixture fixture) throws Error {
    yield UDisksService.require_lvm_method (proxy, "Poll", new Cancellable ());
    try {
        yield UDisksService.require_lvm_method (proxy, "RemoveMissingPhysicalVolumes", new Cancellable ());
        assert_not_reached ();
    } catch (Error error) { assert (error is IOError.NOT_SUPPORTED); }
    for (int state = 0; state < 3; state++) {
        fixture.requested = false;
        fixture.published = false;
        proxy.set_cached_property ("NeedsPolling", state == 2 ? null : new Variant.boolean (state == 1));
        yield UDisksService.poll_volume_group (proxy, new Cancellable ());
        assert (fixture.requested);
        assert (!fixture.published);
        Idle.add (() => {
            fixture.published = true;
            exercise_lvm_poll.callback ();
            return Source.REMOVE;
        });
        yield;
        assert (fixture.published);
    }
}

private void test_lvm_poll () throws Error {
    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    var flags = DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
    var server = new DBusConnection.for_address_sync (bus.get_bus_address (), flags);
    var client = new DBusConnection.for_address_sync (bus.get_bus_address (), flags);
    var fixture = new DelayedPollFixture ();
    uint registration = server.register_object<PollFixture> ("/test/vg", fixture);
    var proxy = new DBusProxy.sync (client, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES | DBusProxyFlags.DO_NOT_CONNECT_SIGNALS,
        null, server.get_unique_name (), "/test/vg", "org.freedesktop.UDisks2.VolumeGroup");
    var loop = new MainLoop ();
    Error? failure = null;
    exercise_lvm_poll.begin (proxy, fixture, (object, result) => {
        try { exercise_lvm_poll.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    server.unregister_object (registration);
    client.close_sync ();
    server.close_sync ();
    proxy = null;
    client = null;
    server = null;
    bus.down ();
    if (failure != null) throw failure;
}

private void test_luks_capabilities_and_safety () throws Error {
    string old_daemon = "<node><interface name='org.freedesktop.UDisks2.Block'><method name='OpenDevice'/></interface></node>";
    string new_daemon = "<node><interface name='org.freedesktop.UDisks2.Block'><method name='RestoreEncryptedHeader'/></interface>" +
        "<interface name='org.freedesktop.UDisks2.Encrypted'><method name='HeaderBackup'/></interface></node>";
    assert (!UDisksService.has_luks_method (old_daemon, "org.freedesktop.UDisks2.Block", "RestoreEncryptedHeader"));
    assert (!UDisksService.has_luks_method (old_daemon, "org.freedesktop.UDisks2.Encrypted", "HeaderBackup"));
    assert (UDisksService.has_luks_method (new_daemon, "org.freedesktop.UDisks2.Block", "RestoreEncryptedHeader"));
    assert (UDisksService.has_luks_method (new_daemon, "org.freedesktop.UDisks2.Encrypted", "HeaderBackup"));

    var outcome = new StorageOperationResult ();
    UDisksService.record_luks_worker_failure (outcome, 2, true, "Backup rejected");
    assert (outcome.status == StorageOperationStatus.FAILED && !outcome.partial);
    UDisksService.record_luks_worker_failure (outcome, 3, true, "Readback mismatch");
    assert (outcome.status == StorageOperationStatus.NEEDS_ATTENTION && outcome.partial);
    assert (outcome.summary == "Modification attempted but verification failed");
    UDisksService.record_luks_worker_failure (outcome, -1, true, "");
    assert (outcome.status == StorageOperationStatus.NEEDS_ATTENTION && outcome.summary == "Outcome uncertain");

    var plan = new StorageRestorationPlanDialog ();
    assert (plan.get_default_response () == "cancel");
    var reopen = new LuksCredentialDialog ("reopen", -1, {}, false, new Gtk.Window ());
    assert (!reopen.get_response_enabled ("apply"));
    assert (reopen.get_response_label ("apply") == "Unlock");
    int pipe = UDisksService.credential_pipe ("fixture passphrase");
    uint8[] buffer = new uint8[32];
    assert (Posix.read (pipe, buffer, buffer.length) == 18);
    assert (Posix.read (pipe, buffer, buffer.length) == 0);
    Posix.close (pipe);

    var block = new StorageBlock ("/test/luks");
    block.available = true;
    block.type_id = "crypto_TCRYPT";
    block.encrypted = new StorageEncryptedVolume ();
    block.uuid = Uuid.string_random ();
    assert (!UDisksService.is_luks_header_candidate (block));
    block.type_id = "crypto_LUKS";
    assert (UDisksService.is_luks_header_candidate (block));
    var graph = new StorageDependencyService ();
    UDisksService.require_luks_restore_idle (block, graph);
    var mapping = new StorageBlock ("/test/mapper");
    block.encrypted.mapping = mapping;
    try {
        UDisksService.require_luks_restore_idle (block, graph);
        assert_not_reached ();
    } catch (IOError error) { assert (error is IOError.BUSY); }
    block.encrypted.mapping = null;
    block.system_hint = true;
    try {
        UDisksService.require_luks_restore_idle (block, graph);
        assert_not_reached ();
    } catch (IOError error) { assert (error is IOError.PERMISSION_DENIED); }
}

private void test_restore_rejects_parent_image (UDisksService backend, StorageBlock disk, StorageBlock partition)
    throws Error {
    string path;
    int fd = FileUtils.open_tmp ("majoris-restore-parent-XXXXXX", out path);
    try {
        Posix.Stat source;
        assert (Posix.fstat (fd, out source) == 0);
        backend.snapshot.dependencies.add (disk, partition);
        disk.loop = new StorageLoopDevice () { backing_file = path };
        try {
            backend.check_image_filesystem (partition, source);
            assert_not_reached ();
        } catch (IOError error) {
            assert (error is IOError.INVALID_ARGUMENT);
        }
    } finally {
        disk.loop = null;
        Posix.close (fd);
        FileUtils.unlink (path);
    }
}

private void test_advanced_navigation (Gtk.Application app) {
    var backend = new UDisksService ();
    var window = new DisksWindow (app, backend);
    var drive = new StorageDrive ("/test/drive") { name = "Drive" };
    var group = new StorageVolumeGroup ("/test/group") { name = "Group" };
    var array = new StorageRaid ("/test/array") { name = "Array" };
    var first = new StorageBlock ("/test/btrfs1") { name = "Btrfs", type_id = "btrfs", uuid = "test-fsid" };
    var second = new StorageBlock ("/test/btrfs2") { name = "Btrfs", type_id = "btrfs", uuid = "test-fsid" };
    backend.snapshot.publish ({ drive });
    backend.snapshot.advanced.insert (group.path, group);
    backend.snapshot.advanced.insert (array.path, array);
    backend.snapshot.blocks.insert (first.path, first);
    backend.snapshot.blocks.insert (second.path, second);
    backend.changed ();

    var sidebar = (Gtk.ListBox) window.get_template_child (typeof (DisksWindow), "sidebar");
    var advanced = (Gtk.ListBox) window.get_template_child (typeof (DisksWindow), "advanced_sidebar");
    var states = (Gtk.Stack) window.get_template_child (typeof (DisksWindow), "states");
    var overview = (Gtk.Widget) window.get_template_child (typeof (DisksWindow), "advanced_view");
    assert (advanced.get_row_at_index (3) == null);
    assert (((VolumeRow) advanced.get_row_at_index (1)).device == first);
    var group_row = (VolumeRow) advanced.get_row_at_index (2);
    assert (group_row.device == group);
    advanced.select_row (group_row);
    assert (states.visible_child == overview && sidebar.get_selected_row () == null);
    backend.snapshot.advanced.remove (array.path);
    backend.changed ();
    assert (((VolumeRow) advanced.get_selected_row ()).device == group);
    backend.snapshot.advanced.remove (group.path);
    backend.changed ();
    assert (advanced.get_selected_row () == null && states.visible_child != overview);
    assert (sidebar.get_selected_row () != null);
    var missing = new StorageVolumeGroup ("/test/missing") { name = "Missing", uuid = "fixture-vg",
        missing_pvs_known = true, missing_pv_uuids = { "missing-pv-uuid" } };
    var volume = new StorageLogicalVolume ("/test/missing/volume") { name = "Volume", uuid = "fixture-lv",
        group_path = missing.path, lvm_layout = "linear" };
    backend.snapshot.advanced.insert (missing.path, missing);
    backend.snapshot.advanced.insert (volume.path, volume);
    backend.changed ();
    var detail = (Adw.ActionRow) window.get_template_child (typeof (DisksWindow), "advanced_details");
    for (int i = 0; ; i++) {
        var row = advanced.get_row_at_index (i) as VolumeRow;
        if (row == null) break;
        if (row.device == missing) {
            advanced.select_row (row);
            assert (detail.subtitle.contains ("missing-pv-uuid"));
        } else if (row.device == volume) {
            advanced.select_row (row);
            assert (detail.subtitle.contains ("fixture-lv") && detail.subtitle.contains ("Physical allocation unknown"));
        }
    }
    window.destroy ();
}

public static int main (string[] args) {
    string? display = Environment.get_variable ("DISPLAY");
    try { test_lvm_poll (); }
    catch (Error error) { stderr.printf ("%s\n", error.message); return 1; }
    if (display != null) Environment.set_variable ("DISPLAY", display, true);
    Gtk.init ();
    Adw.init ();
    var backend = new UDisksService ();
    var disk = new StorageBlock ("/test/disk");
    disk.preferred = "/dev/test"; disk.size = 64 * 1024 * 1024; disk.logical_sector_size = 512;
    disk.table = new StoragePartitionTable ("gpt");
    backend.snapshot.blocks.insert (disk.path, disk);
    var block = new StorageBlock ("/test/partition");
    block.preferred = "/dev/test1"; block.size = 8 * 1024 * 1024; block.type_id = "ext4";
    block.uuid = "test-filesystem-uuid";
    block.partition = new StoragePartition (); block.partition.table_path = disk.path;
    block.partition.uuid = "test-partition-uuid";
    block.partition.offset = 1024 * 1024; block.parent = disk; block.filesystem = new StorageFilesystem ();
    disk.table.partitions = { block }; backend.snapshot.blocks.insert (block.path, block);
    try { test_restore_rejects_parent_image (backend, disk, block); }
    catch (Error error) { stderr.printf ("%s\n", error.message); return 1; }
    string disk_identity = backend.modification_identity (disk);
    assert (disk_identity == backend.modification_identity (disk));
    string partition_identity = backend.modification_identity (block);
    assert (partition_identity == backend.modification_identity (block));
    block.partition.offset += 512;
    assert (partition_identity != backend.modification_identity (block));
    block.partition.offset -= 512;
    assert (partition_identity == backend.modification_identity (block));
    var gap = new StorageFreeSpace (disk, Extent (16 * 1024 * 1024, 16 * 1024 * 1024));
    var drive = new StorageDrive ("/test/drive"); drive.medium = disk; drive.name = "Test drive";
    var app = new Gtk.Application ("com.majoris.disks.TemplateTest", ApplicationFlags.NON_UNIQUE);
    app.register (null);
    try { test_luks_capabilities_and_safety (); }
    catch (Error error) { critical ("%s", error.message); return 1; }
    test_advanced_navigation (app);
    var window = new DisksWindow (app);
    var partition = block.partition;
    var job = backend.jobs.begin ("Test", block, backend.snapshot.dependencies);
    var health_report = new StorageHealthReport ();
    var resize_header = new LuksHeaderReview ("identity", "ticket", "LUKS2",
        Uuid.string_random (), "readable", 0, 4096, false, false, "");
    resize_header.encryption_sector_size = 512;
    var resize_backing = new StorageBlock ("/test/luks") { size = 16384 };
    var resize_mapping = new StorageBlock ("/test/mapping") { size = 8192 };
    EncryptedResizeDialog encrypted_resize;
    try { encrypted_resize = new EncryptedResizeDialog (resize_backing, resize_mapping, resize_header,
        FilesystemResizeMode.OFFLINE_GROW, 0); }
    catch (Error error) { critical ("%s", error.message); return 1; }
    assert (encrypted_resize.requested == 12288);
    Object[] instances = {
        new PartitionMap (), new PartitionSegment (), new DriveView (), window,
        new SidebarGroupHeading ("Test"), new DeviceRow (drive), new VolumeRow (block),
        new DriveInformationDialog (drive, block), new InformationRow ("Test", "Value", false),
        new LabelDialog (block), new LvmRenameDialog ("old_lv", "/dev/testvg/old_lv"),
        new LvmRecoveryDialog (true, "fixture", new Gtk.StringList ({ "Replacement PV" })),
        new LvmCacheDialog ("origin", false, new Gtk.StringList ({ "Cache candidate" })),
        new LvmLayoutDialog (backend, new StorageVolumeGroup ("/test/group")),
        new LvmLifecycleDialog ({}, "/"), new StorageRemovalDialog (true), new CreateLogicalVolumeDialog (new StorageVolumeGroup ("/test/group")), new CreateStorageGroupDialog (backend, true), new BtrfsSubvolumesDialog (new BtrfsSubvolumeList (), false), new BtrfsBalanceDialog (true), new OwnershipDialog (block), new PartitionMetadataDialog (block, partition, true),
        new OperationResultDialog (), new StorageRestorationPlanDialog (), new RepairConfirmationDialog (), new DeleteConfirmationDialog (),
        new FormatDiskDialog (), new FormatVolumeDialog (backend, block),
        new CreatePartitionDialog (backend, disk, gap), new ResizeVolumeDialog (backend, block), encrypted_resize,
        new JobRow (backend, job), new JobsPopover (backend), new ActiveJobsDialog (),
        new MountOptionsDialog (block, "identity"), new UnlockVolumeDialog (block),
        new LockVolumeConfirmationDialog (), new ChangePassphraseDialog (block),
        new LuksHeaderBackupDialog (), new LuksHeaderRestoreDialog ("/dev/test", true),
        new LuksKeyslotsDialog (new LuksHeaderReview ("identity", "ticket", "LUKS2",
            Uuid.string_random (), "readable", 0, 0, false, false, ""), false),
        new LuksCredentialDialog ("add", -1, {}, false, window),
        new HardwareActionConfirmationDialog (),
        new EncryptionOptionsDialog (block, "identity"), new SmartDialog (backend, drive, health_report),
        new DriveSettingsDialog (drive), new HealthPreferences (), new BenchmarkDialog (backend, drive), new DiskImageConfirmation (), new BlankDiskImageDialog (), new VirtualImageDialog ()
    };
    string[] resources = {
        "lvm-recovery-dialog.ui", "lvm-cache-dialog.ui", "lvm-layout-dialog.ui",
        "window.ui", "drive-view.ui", "partition-map.ui", "partition-segment.ui",
        "device-row.ui", "volume-row.ui", "information-row.ui", "sidebar-group-heading.ui",
        "drive-information-dialog.ui", "edit-filesystem-dialog.ui", "lvm-rename-dialog.ui", "lvm-lifecycle-dialog.ui", "storage-removal-dialog.ui", "lvm-create-dialog.ui", "create-storage-group-dialog.ui", "btrfs-subvolumes-dialog.ui", "btrfs-balance-dialog.ui", "edit-partition-dialog.ui",
        "ownership-dialog.ui", "operation-result-dialog.ui", "repair-confirmation-dialog.ui",
        "delete-confirmation-dialog.ui", "format-disk-dialog.ui", "format-volume-dialog.ui",
        "create-partition-dialog.ui", "resize-volume-dialog.ui", "encrypted-resize-dialog.ui", "job-row.ui", "jobs-popover.ui",
        "active-jobs-dialog.ui", "mount-options-dialog.ui", "unlock-volume-dialog.ui",
         "lock-volume-confirmation-dialog.ui", "change-passphrase-dialog.ui",
        "storage-restoration-plan-dialog.ui",
        "luks-header-backup-dialog.ui", "luks-header-restore-dialog.ui", "luks-keyslots-dialog.ui", "luks-credential-dialog.ui", "encryption-options-dialog.ui",
        "smart-dialog.ui", "hardware-action-confirmation-dialog.ui", "drive-settings-dialog.ui", "health-preferences.ui", "benchmark-dialog.ui", "disk-image-confirmation.ui", "create-blank-image-dialog.ui", "virtual-image-dialog.ui"
    };
    foreach (var name in resources) {
        try { resources_lookup_data ("/com/majoris/disks/ui/" + name, ResourceLookupFlags.NONE); }
        catch (Error error) { critical ("Missing resource %s: %s", name, error.message); return 1; }
    }
    assert (instances.length == resources.length);
    assert (new LvmRenameDialog ("old_vg", "old_vg", true).heading == "Rename Volume Group");
    assert (new LvmRecoveryDialog (false, "fixture", new Gtk.StringList (null)).heading ==
        "Remove Missing Physical-Volume Records");
    assert (new LvmCacheDialog ("origin", true, new Gtk.StringList (null)).heading == "Separate LVM Cache");
    var mount_item = new Variant.string ("original fstab entry");
    var crypt_item = new Variant.string ("original crypttab entry");
    block.mount_configurations = {
        new StorageMountConfiguration () { directory = "/mnt/original", backend_item = mount_item }
    };
    block.encryption_configurations = {
        new StorageEncryptionConfiguration () { name = "original-mapping", backend_item = crypt_item }
    };
    var mount_dialog = new MountOptionsDialog (block, partition_identity);
    var encryption_dialog = new EncryptionOptionsDialog (block, partition_identity);
    block.mount_configurations = {};
    block.encryption_configurations = {};
    assert (mount_dialog.original_item.equal (mount_item));
    assert (encryption_dialog.original_item.equal (crypt_item));
    assert (UDisksService.valid_lvm_name ("valid-lv_1.2+data"));
    var pool_snapshot = new StorageSnapshot ();
    var pool = new StorageLogicalVolume ("/test/pool") {
        active = true, size = 1024, lvm_type = "pool",
        data_allocated_ratio = 0.25, metadata_allocated_ratio = 0.5
    };
    var provisioned = new StorageLogicalVolume ("/test/thin") { size = 256, thin_pool_path = pool.path };
    pool_snapshot.advanced.insert (provisioned.path, provisioned);
    var usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.virtual_size == 256 && usage.estimated_data_remaining () == 768);
    assert (!usage.overcommits (768) && usage.overcommits (769));
    pool.metadata_allocated_ratio = 1.0;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.metadata_allocated_ratio = 0.5;
    provisioned.size = 2048;
    usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.can_provision () && usage.overcommit_ratio () == 2.0 && usage.estimated_data_remaining () == 768);
    var snapshot_volume = new StorageLogicalVolume ("/test/thin-snapshot") {
        size = 2048, thin_pool_path = pool.path, origin_path = provisioned.path
    };
    pool_snapshot.advanced.insert (snapshot_volume.path, snapshot_volume);
    usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.virtual_size == 4096 && usage.estimated_data_remaining () == 768);
    snapshot_volume.size = uint64.MAX;
    assert (!new ThinPoolUsage (pool_snapshot, pool).virtual_known);
    pool_snapshot.advanced.remove (snapshot_volume.path);
    pool.data_allocated_ratio = 0.99;
    assert (new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.data_allocated_ratio = 1.0;
    assert (new ThinPoolUsage (pool_snapshot, pool).can_shrink ());
    pool.metadata_allocated_ratio = 1.0;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_shrink ());
    pool.metadata_allocated_ratio = 0.5;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.data_allocated_ratio = 0.25;
    pool.metadata_allocated_ratio = -1;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    foreach (string invalid in new string[] { "", "-option", "..", "bad/name", "with space", "é" })
        assert (!UDisksService.valid_lvm_name (invalid));
    return 0;
}
