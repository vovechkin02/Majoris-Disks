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
    block.partition = new StoragePartition (); block.partition.table_path = disk.path;
    block.partition.offset = 1024 * 1024; block.parent = disk; block.filesystem = new StorageFilesystem ();
    disk.table.partitions = { block }; backend.snapshot.blocks.insert (block.path, block);
    var gap = new StorageFreeSpace (disk, Extent (16 * 1024 * 1024, 16 * 1024 * 1024));
    var drive = new StorageDrive ("/test/drive"); drive.medium = disk; drive.name = "Test drive";
    var app = new Gtk.Application ("com.majoris.disks.TemplateTest", ApplicationFlags.NON_UNIQUE);
    app.register (null);
    var partition = block.partition;
    var job = backend.jobs.begin ("Test", block, backend.snapshot.dependencies);
    var health_report = new StorageHealthReport ();
    Object[] instances = {
        new PartitionMap (), new PartitionSegment (), new DriveView (), new DisksWindow (app),
        new SidebarGroupHeading ("Test"), new DeviceRow (drive), new VolumeRow (block),
        new DriveInformationDialog (drive), new InformationRow ("Test", "Value", false),
        new LabelDialog (block), new LvmRenameDialog ("old_lv", "/dev/testvg/old_lv"), new LvmLifecycleDialog ({}, "/"), new StorageRemovalDialog (true), new CreateLogicalVolumeDialog (new StorageVolumeGroup ("/test/group")), new CreateStorageGroupDialog (backend, true), new BtrfsSubvolumesDialog (new BtrfsSubvolumeList (), false), new OwnershipDialog (block), new PartitionMetadataDialog (block, partition, true),
        new OperationResultDialog (), new RepairConfirmationDialog (), new DeleteConfirmationDialog (),
        new FormatDiskDialog (), new FormatVolumeDialog (backend, block),
        new CreatePartitionDialog (backend, disk, gap), new ResizeVolumeDialog (backend, block),
        new JobRow (backend, job), new JobsPopover (backend), new ActiveJobsDialog (),
        new MountOptionsDialog (block, "identity"), new UnlockVolumeDialog (block),
        new LockVolumeConfirmationDialog (), new ChangePassphraseDialog (block),
        new HardwareActionConfirmationDialog (),
        new EncryptionOptionsDialog (block, "identity"), new SmartDialog (backend, drive, health_report),
        new DriveSettingsDialog (drive), new HealthPreferences (), new BenchmarkDialog (backend, drive), new DiskImageConfirmation (), new BlankDiskImageDialog (), new VirtualImageDialog ()
    };
    string[] resources = {
        "window.ui", "drive-view.ui", "partition-map.ui", "partition-segment.ui",
        "device-row.ui", "volume-row.ui", "information-row.ui", "sidebar-group-heading.ui",
        "drive-information-dialog.ui", "edit-filesystem-dialog.ui", "lvm-rename-dialog.ui", "lvm-lifecycle-dialog.ui", "storage-removal-dialog.ui", "lvm-create-dialog.ui", "create-storage-group-dialog.ui", "btrfs-subvolumes-dialog.ui", "edit-partition-dialog.ui",
        "ownership-dialog.ui", "operation-result-dialog.ui", "repair-confirmation-dialog.ui",
        "delete-confirmation-dialog.ui", "format-disk-dialog.ui", "format-volume-dialog.ui",
        "create-partition-dialog.ui", "resize-volume-dialog.ui", "job-row.ui", "jobs-popover.ui",
        "active-jobs-dialog.ui", "mount-options-dialog.ui", "unlock-volume-dialog.ui",
        "lock-volume-confirmation-dialog.ui", "change-passphrase-dialog.ui", "encryption-options-dialog.ui",
        "smart-dialog.ui", "hardware-action-confirmation-dialog.ui", "drive-settings-dialog.ui", "health-preferences.ui", "benchmark-dialog.ui", "disk-image-confirmation.ui", "create-blank-image-dialog.ui", "virtual-image-dialog.ui"
    };
    foreach (var name in resources) {
        try { resources_lookup_data ("/com/majoris/disks/ui/" + name, ResourceLookupFlags.NONE); }
        catch (Error error) { critical ("Missing resource %s: %s", name, error.message); return 1; }
    }
    assert (instances.length == resources.length);
    assert (UDisksService.valid_lvm_name ("valid-lv_1.2+data"));
    var pool_snapshot = new StorageSnapshot ();
    var pool = new StorageLogicalVolume ("/test/pool") {
        active = true, size = 1024, lvm_type = "pool",
        data_allocated_ratio = 0.25, metadata_allocated_ratio = 0.5
    };
    var provisioned = new StorageLogicalVolume ("/test/thin") { size = 256, thin_pool_path = pool.path };
    pool_snapshot.advanced.insert (provisioned.path, provisioned);
    var usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.virtual_size == 256 && usage.physical_data_remaining () == 768);
    assert (!usage.overcommits (768) && usage.overcommits (769));
    pool.metadata_allocated_ratio = 1.0;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.metadata_allocated_ratio = 0.5;
    provisioned.size = 2048;
    usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.can_provision () && usage.overcommit_ratio () == 2.0 && usage.physical_data_remaining () == 768);
    var snapshot_volume = new StorageLogicalVolume ("/test/thin-snapshot") {
        size = 2048, thin_pool_path = pool.path, origin_path = provisioned.path
    };
    pool_snapshot.advanced.insert (snapshot_volume.path, snapshot_volume);
    usage = new ThinPoolUsage (pool_snapshot, pool);
    assert (usage.virtual_size == 4096 && usage.physical_data_remaining () == 768);
    snapshot_volume.size = uint64.MAX;
    assert (!new ThinPoolUsage (pool_snapshot, pool).virtual_known);
    pool_snapshot.advanced.remove (snapshot_volume.path);
    pool.data_allocated_ratio = 0.99;
    assert (new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.data_allocated_ratio = 1.0;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    pool.data_allocated_ratio = 0.25;
    pool.metadata_allocated_ratio = -1;
    assert (!new ThinPoolUsage (pool_snapshot, pool).can_provision ());
    foreach (string invalid in new string[] { "", "-option", "..", "bad/name", "with space", "é" })
        assert (!UDisksService.valid_lvm_name (invalid));
    return 0;
}
