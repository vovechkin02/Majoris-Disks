using MajorisDisks;

[DBus (signature = "(bs)")]
private struct MockCapabilityResponse {
    public bool supported;
    public string utility;
}

[DBus (name = "org.test.Manager")]
private interface MockCapabilityManager : Object {
    public abstract MockCapabilityResponse can_format (string type) throws Error;
}

private class MockCapabilityService : Object, MockCapabilityManager {
    public MockCapabilityResponse can_format (string type) throws Error {
        MockCapabilityResponse response = {};
        response.supported = type == "ext4";
        response.utility = "";
        return response;
    }
}

private void test_gaps () {
    assert (PartitionLayoutService.gaps (0, 0, {}).length == 0);
    var empty = PartitionLayoutService.gaps (0, 100, {});
    assert (empty.length == 1 && empty[0].size == 100);
    var gaps = PartitionLayoutService.gaps (0, 100, {
        Extent (10, 1), Extent (20, 20), Extent (30, 30), Extent (70, 10)
    });
    assert (gaps.length == 4);
    assert (gaps[0].offset == 0 && gaps[0].size == 10);
    assert (gaps[1].offset == 11 && gaps[1].size == 9);
    assert (gaps[2].offset == 60 && gaps[2].size == 10);
    assert (gaps[3].offset == 80 && gaps[3].size == 20);
    var clipped = PartitionLayoutService.gaps (0, uint64.MAX, { Extent (uint64.MAX - 1, 500) });
    assert (clipped.length == 1 && clipped[0].size == uint64.MAX - 1);
}

private StorageBlock partition (StorageBlock disk, string path, uint64 offset, uint64 size) {
    var block = new StorageBlock (path);
    block.size = size;
    block.partition = new StoragePartition ();
    block.partition.table_path = disk.path;
    block.partition.offset = offset;
    return block;
}

private void test_hierarchy () {
    var snapshot = new StorageSnapshot ();
    var disk = new StorageBlock ("/disk");
    disk.size = 100 * 1024 * 1024;
    disk.table = new StoragePartitionTable ("dos");
    var container = partition (disk, "/extended", 1024 * 1024, 60 * 1024 * 1024);
    container.partition.container = true;
    var logical = partition (disk, "/logical", 2 * 1024 * 1024, 10 * 1024 * 1024);
    logical.partition.logical = true;
    logical.encrypted = new StorageEncryptedVolume ();
    var mapped = new StorageBlock ("/mapped");
    mapped.backing_path = logical.path;
    mapped.filesystem = new StorageFilesystem ();
    foreach (var block in new StorageBlock[] { disk, logical, container, mapped })
        snapshot.blocks.insert (block.path, block);
    StorageHierarchy.link (snapshot, new HashTable<string, StorageDrive> (str_hash, str_equal));
    assert (snapshot.devices.get_n_items () == 1);
    assert (logical.parent == container);
    assert (disk.table.partitions[0] == container);
    assert (logical.encrypted.mapping == mapped && mapped.parent == logical);
    foreach (var region in StorageHierarchy.regions (disk, disk)) assert (region != logical);
    var nested = StorageHierarchy.regions (disk, container);
    assert (nested.length == 3 && nested[1] == logical);
}

private void test_resize_geometry () {
    var disk = new StorageBlock ("/disk");
    disk.size = 32 * 1024 * 1024;
    disk.logical_sector_size = 4096;
    disk.table = new StoragePartitionTable ("gpt");
    var first = partition (disk, "/first", 1024 * 1024, 4 * 1024 * 1024);
    var next = partition (disk, "/next", 8 * 1024 * 1024, 4 * 1024 * 1024);
    first.parent = disk;
    next.parent = disk;
    disk.table.partitions = { first, next };
    try {
        PartitionLayoutService.validate_resize (disk, first, 7 * 1024 * 1024);
    } catch (Error error) {
        assert_not_reached ();
    }
    try {
        PartitionLayoutService.validate_resize (disk, first, 7 * 1024 * 1024 + 4096);
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.NO_SPACE);
    }
    try {
        PartitionLayoutService.validate_resize (disk, first, 4097);
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.INVALID_ARGUMENT);
    }
}

private void test_capabilities () {
    var block = new StorageBlock ("/block");
    block.filesystem = new StorageFilesystem ();
    assert (new StorageCapabilities (block).mount);
    block.filesystem.mounts = { "/" };
    assert (!new StorageCapabilities (block).unmount);
    block.filesystem.mounts = { "/srv/data" };
    assert (new StorageCapabilities (block).unmount);
    block.available = false;
    assert (!new StorageCapabilities (block).unmount);
}

private void test_normalization () {
    Extent[] input = {
        Extent (70, 40), Extent (20, 15), Extent (10, 10), Extent (20, 5),
        Extent (34, 10), Extent (90, 0), Extent (120, uint64.MAX)
    };
    var used = PartitionLayoutService.normalize (15, 100, input);
    assert (used.length == 2);
    assert (used[0].offset == 15 && used[0].size == 29);
    assert (used[1].offset == 70 && used[1].size == 30);
    var free = PartitionLayoutService.gaps (15, 100, input);
    assert (free.length == 1 && free[0].offset == 44 && free[0].size == 26);
    assert (used[0].size + used[1].size + free[0].size == 85);
    assert (PartitionLayoutService.pixel (uint64.MAX, uint64.MAX, 700) == 700);
    assert (PartitionLayoutService.pixel (1, uint64.MAX, 700) == 0);
}

private void test_dependency_safety () {
    var graph = new StorageDependencyService ();
    var disk = new StorageDrive ("/drive");
    var member = new StorageBlock ("/member");
    var raid = new StorageRaid ("/raid");
    var group = new StorageVolumeGroup ("/vg");
    var lv = new StorageLogicalVolume ("/lv");
    lv.active = true;
    var root = new StorageBlock ("/root");
    root.filesystem = new StorageFilesystem ();
    root.filesystem.mounts = { "/" };
    graph.add (disk, member);
    graph.add (member, raid);
    graph.add (raid, group);
    graph.add (group, lv);
    graph.add (lv, root);
    graph.add (root, disk);
    graph.add (root, null);
    assert (graph.descendants (disk).length == 6);
    var safety = StorageSafetyService.assess (disk, graph);
    assert (safety.system_critical && safety.active_dependents && safety.unknown_dependencies);
}
private void test_lvm_capacity () {
    const uint64 mib = 1048576;
    const uint64 gib = 1073741824;
    const uint64 tib = 1099511627776;
    uint64 bytes;
    assert (LvmCapacity.parse ("1.5", gib, 4 * mib, 2 * gib, out bytes) && bytes == 1536 * mib);
    assert (!LvmCapacity.parse ("12", mib, 8 * mib, 64 * mib, out bytes));
    assert (LvmCapacity.parse ("16", mib, 8 * mib, 17 * mib, out bytes) && bytes == 16 * mib);
    assert (!LvmCapacity.parse ("16", mib, 8 * mib, 15 * mib, out bytes));
    assert (LvmCapacity.parse ("3", tib, 32 * mib, 4 * tib, out bytes) && bytes == 3 * tib);
    assert (!LvmCapacity.parse ("16777216", tib, 4 * mib, uint64.MAX, out bytes));
    assert (!LvmCapacity.parse ("0.1", mib, 1, uint64.MAX, out bytes));
    assert (!LvmCapacity.parse ("1e3", mib, 4 * mib, uint64.MAX, out bytes));
}

private void test_operation_locks () {
    var graph = new StorageDependencyService ();
    var disk = new StorageBlock ("/disk");
    var partition = new StorageBlock ("/partition");
    var unrelated = new StorageBlock ("/unrelated");
    graph.add (disk, partition);
    var locks = new StorageOperationLocks ();
    try {
        locks.acquire (partition, graph);
        assert (locks.conflicts (disk, graph));
        assert (!locks.conflicts (unrelated, graph));
        var refreshed_graph = new StorageDependencyService ();
        var refreshed_disk = new StorageBlock (disk.path);
        var sibling = new StorageBlock ("/sibling");
        refreshed_graph.add (refreshed_disk, sibling);
        assert (locks.conflicts (sibling, refreshed_graph));
        locks.release (partition);
        assert (!locks.conflicts (disk, graph));
        assert (!locks.conflicts (sibling, refreshed_graph));
        locks.acquire_path (partition.path);
        try { locks.acquire (partition, graph); assert_not_reached (); }
        catch (Error error) { assert (error is IOError.BUSY); }
        locks.release_path (partition.path);
        locks.acquire (unrelated, graph);
        try { locks.acquire_members (partition, { unrelated }, graph); assert_not_reached (); }
        catch (Error error) { assert (error is IOError.BUSY); }
        assert (!locks.conflicts (partition, graph));
        locks.release (unrelated);
        locks.acquire_members (partition, { unrelated }, graph);
        assert (locks.conflicts (disk, graph));
        assert (locks.conflicts (unrelated, graph));
        locks.release (partition);
        assert (!locks.conflicts (unrelated, graph));
    } catch (Error error) {
        assert_not_reached ();
    }
}

private void test_metadata_safety_classes () {
    var graph = new StorageDependencyService ();
    var block = new StorageBlock ("/metadata");
    block.filesystem = new StorageFilesystem (); block.filesystem.mounts = { "/data" };
    var rename = StorageSafetyService.assess_operation (StorageOperationKind.EDIT_PARTITION_NAME, block, graph);
    var type = StorageSafetyService.assess_operation (StorageOperationKind.EDIT_PARTITION_TYPE, block, graph);
    var flags = StorageSafetyService.assess_operation (StorageOperationKind.EDIT_PARTITION_FLAGS, block, graph);
    assert (rename.allowed && !rename.blocked);
    assert (!type.allowed && type.blocked);
    assert (!flags.allowed && flags.blocked);
    block.filesystem.mounts = { "/" };
    rename = StorageSafetyService.assess_operation (StorageOperationKind.EDIT_PARTITION_NAME, block, graph);
    assert (rename.allowed && !rename.blocked);
}

private void test_check_capability () {
    try {
        assert (FilesystemCapabilityService.check_available (new Variant ("((bs))", true, "")));
        assert (!FilesystemCapabilityService.check_available (new Variant ("((bs))", false, "")));
    } catch (Error error) {
        assert_not_reached ();
    }
    try {
        FilesystemCapabilityService.check_available (new Variant ("((bs))", false, "e2fsck"));
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.NOT_SUPPORTED && error.message.contains ("e2fsck"));
    }
}
private void test_resize_capability () {
    try {
        string utility;
        var modes = FilesystemCapabilityService.resize_modes (
            new Variant ("((bts))", true, (uint64) 0x8000000000000012, ""), out utility);
        assert (modes == (FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.ONLINE_GROW));
        assert (utility == "");
        modes = FilesystemCapabilityService.resize_modes (
            new Variant ("((bts))", false, (uint64) 0x12, "resize2fs"), out utility);
        assert (modes == 0 && utility == "resize2fs");
    } catch (Error error) {
        assert_not_reached ();
    }
}

private void test_capability_invalid_responses () {
    Variant[] invalid = {
        new Variant ("()"),
        new Variant ("(bs)", true, ""),
        new Variant ("((bs)s)", true, "", "unexpected"),
        new Variant ("((bts))", true, (uint64) 2, "")
    };
    foreach (var reply in invalid) {
        try {
            FilesystemCapabilityService.decode (reply);
            assert_not_reached ();
        } catch (Error error) {
            assert (error is IOError.INVALID_DATA);
        }
    }
    try {
        FilesystemCapabilityService.decode (new Variant ("((bs))", true, ""), true);
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.INVALID_DATA);
    }
}

private void test_resize_capability_combinations () {
    for (uint64 bits = 0; bits < 16; bits++) {
        uint64 flags = bits << 1;
        try {
            var capability = FilesystemCapabilityService.decode (
                new Variant ("((bts))", true, flags, ""), true);
            assert (capability.supported);
            assert ((uint64) capability.modes == flags);
        } catch (Error error) {
            assert_not_reached ();
        }
    }
}

private void test_kernel_identity () {
    assert (KernelStorageSafety.device_number (0x801) == "8:1");
    assert (KernelStorageSafety.device_number (0x10000103) == "1:65539");
    string mounts = "36 25 8:10 / /srv/data rw - ext4 /dev/sda10 rw\n";
    assert (KernelStorageSafety.has_mount (mounts, "8:10"));
    assert (!KernelStorageSafety.has_mount (mounts, "8:1"));
}

private StorageBlock make_disk (string scheme) {
    var disk = new StorageBlock ("/disk-" + scheme);
    disk.size = 64 * 1024 * 1024;
    disk.logical_sector_size = 512;
    disk.table = new StoragePartitionTable (scheme);
    return disk;
}

private void test_partition_creation_geometry () {
    var gpt = make_disk ("gpt");
    var gap = new StorageFreeSpace (gpt, Extent (34 * 512, 20 * 1024 * 1024));
    try {
        uint64 offset, size;
        PartitionLayoutService.validate_create (gpt, gap, 8 * 1024 * 1024,
            PartitionLayoutService.PartitionKind.GPT, out offset, out size);
        assert (offset == 1024 * 1024 && size == 8 * 1024 * 1024);
        PartitionLayoutService.validate_create (gpt, gap, 0,
            PartitionLayoutService.PartitionKind.GPT, out offset, out size);
        assert (size == 0);
    } catch (Error error) { assert_not_reached (); }

    var dos = make_disk ("dos");
    var outer = new StorageFreeSpace (dos, Extent (1024 * 1024, 30 * 1024 * 1024));
    try {
        uint64 offset, size;
        PartitionLayoutService.validate_create (dos, outer, 4 * 1024 * 1024,
            PartitionLayoutService.PartitionKind.MBR_PRIMARY, out offset, out size);
        PartitionLayoutService.validate_create (dos, outer, 4 * 1024 * 1024,
            PartitionLayoutService.PartitionKind.MBR_EXTENDED, out offset, out size);
    } catch (Error error) { assert_not_reached (); }
    var container = partition (dos, "/extended", 1024 * 1024, 30 * 1024 * 1024);
    container.partition.container = true;
    container.parent = dos;
    dos.table.partitions = { container };
    var inner = new StorageFreeSpace (container, Extent (2 * 1024 * 1024, 10 * 1024 * 1024));
    try {
        uint64 offset, size;
        PartitionLayoutService.validate_create (dos, inner, 4 * 1024 * 1024,
            PartitionLayoutService.PartitionKind.MBR_LOGICAL, out offset, out size);
    } catch (Error error) { assert_not_reached (); }
    try {
        uint64 offset, size;
        PartitionLayoutService.validate_create (dos, inner, 4 * 1024 * 1024,
            PartitionLayoutService.PartitionKind.MBR_PRIMARY, out offset, out size);
        assert_not_reached ();
    } catch (Error error) { assert (error is IOError.INVALID_ARGUMENT); }
}

private void test_mbr_slot_limits () {
    var disk = make_disk ("dos");
    StorageBlock[] entries = {};
    for (int i = 0; i < 4; i++) {
        var item = partition (disk, "/p" + i.to_string (), (uint64) (i + 1) * 1024 * 1024, 1024 * 1024);
        item.parent = disk;
        entries += item;
    }
    disk.table.partitions = entries;
    var gap = new StorageFreeSpace (disk, Extent (8 * 1024 * 1024, 8 * 1024 * 1024));
    try {
        uint64 offset, size;
        PartitionLayoutService.validate_create (disk, gap, 1024 * 1024,
            PartitionLayoutService.PartitionKind.MBR_PRIMARY, out offset, out size);
        assert_not_reached ();
    } catch (Error error) { assert (error is IOError.NO_SPACE); }
}

private void test_resize_maximum () {
    var disk = make_disk ("gpt");
    var first = partition (disk, "/first", 1024 * 1024, 4 * 1024 * 1024);
    var second = partition (disk, "/second", 12 * 1024 * 1024, 4 * 1024 * 1024);
    first.parent = disk; second.parent = disk; disk.table.partitions = { first, second };
    try { assert (PartitionLayoutService.maximum_resize (disk, first) == 11 * 1024 * 1024); }
    catch (Error error) { assert_not_reached (); }
}

private void test_extended_resize_boundaries () {
    var disk = make_disk ("dos");
    var extended = partition (disk, "/extended", 1024 * 1024, 30 * 1024 * 1024);
    extended.partition.container = true; extended.parent = disk;
    var logical = partition (disk, "/logical", 2 * 1024 * 1024, 8 * 1024 * 1024);
    logical.partition.logical = true; logical.parent = extended;
    disk.table.partitions = { extended, logical };
    try {
        assert (PartitionLayoutService.minimum_resize (disk, extended) == 9 * 1024 * 1024);
        PartitionLayoutService.validate_resize (disk, extended, 10 * 1024 * 1024);
        try { PartitionLayoutService.validate_resize (disk, extended, 8 * 1024 * 1024); assert_not_reached (); }
        catch (Error error) { assert (error is IOError.NO_SPACE); }
    } catch (Error error) { GLib.error ("Unexpected mount-option error: %s", error.message); }
}

private void test_label_validation () {
    try {
        FilesystemCapabilityService.validate_label ("ext4", "Majoris");
        FilesystemCapabilityService.validate_label ("xfs", "DATA");
        FilesystemCapabilityService.validate_label ("vfat", "MAJORIS");
    } catch (Error error) { assert_not_reached (); }
    foreach (var pair in new string[] { "ext4:12345678901234567", "xfs:1234567890123", "vfat:lower" }) {
        var fields = pair.split (":", 2);
        try { FilesystemCapabilityService.validate_label (fields[0], fields[1]); assert_not_reached (); }
        catch (Error error) { assert (error is IOError.INVALID_ARGUMENT); }
    }
    assert (FilesystemCapabilityService.supports_label ("ntfs"));
    assert (!FilesystemCapabilityService.supports_label ("swap"));
}

private void test_job_lifecycle () {
    var manager = new StorageJobManager ();
    var block = new StorageBlock ("/job-target"); block.preferred = "/dev/test";
    var graph = new StorageDependencyService ();
    var job = manager.begin ("Resize volume", block, graph);
    assert (job.state == StorageJobState.PENDING && manager.jobs.get_n_items () == 1);
    manager.phase (job, StorageJobState.RUNNING, "Growing partition");
    assert (job.state == StorageJobState.RUNNING && !job.progress_valid);
    var outcome = new StorageOperationResult (); outcome.completed ("Partition grown");
    outcome.fail ("Filesystem growth failed");
    manager.finish (job, outcome);
    assert (job.state == StorageJobState.PARTIALLY_COMPLETED && job.result.partial);
    manager.observe ("/job/1", "format-mkfs", { "/block/1" }, 0.5, true, true, 10);
    assert (manager.jobs.get_n_items () == 2);
    var observed = manager.jobs.get_item (1) as StorageJob;
    assert (observed.progress_valid && observed.cancelable && observed.progress == 0.5);
    manager.backend_removed ("/job/1");
    assert (observed.state == StorageJobState.NEEDS_ATTENTION);
}

private void test_resize_planner_safety () {
    var block = new StorageBlock ("/resize"); block.size = 1000; block.type_id = "ext4";
    block.filesystem = new StorageFilesystem ();
    FilesystemCapability capability = {}; capability.supported = true;
    capability.modes = FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.OFFLINE_GROW;
    var safe = FilesystemResizePlanner.build (block, 800, true, capability, 700, 2000);
    assert (safe.supported && safe.direction == ResizeDirection.SHRINK && !safe.requires_unmount && safe.requires_check);
    block.filesystem.mounts = { "/mnt/test" };
    var offline = FilesystemResizePlanner.build (block, 800, true, capability, 700, 2000);
    assert (offline.supported && offline.requires_unmount && offline.requires_check);
    capability.modes |= FilesystemResizeMode.ONLINE_SHRINK;
    var online = FilesystemResizePlanner.build (block, 800, true, capability, 700, 2000);
    assert (online.supported && online.online && !online.requires_unmount && !online.requires_check);
    block.type_id = "xfs";
    assert (!FilesystemResizePlanner.build (block, 800, true, capability, 700, 2000).supported);
    block.type_id = "ext4";
    assert (!FilesystemResizePlanner.build (block, 600, true, capability, 700, 2000).supported);
    assert (!FilesystemResizePlanner.build (block, 800, false, capability, 0, 2000).supported);
    block.filesystem = null; block.type_id = ""; block.usage = "";
    assert (FilesystemResizePlanner.build (block, 800, false, capability, 0, 2000).supported);
    block.type_id = "mystery";
    assert (!FilesystemResizePlanner.build (block, 800, false, capability, 0, 2000).supported);
}

private void test_resize_capacity_verification () {
    uint64 gib = 1024 * 1024 * 1024;
    assert (FilesystemResizePlanner.capacity_tolerance ("ext4", 512, 4096) == 128 * 1024 * 1024);
    assert (FilesystemResizePlanner.capacity_tolerance ("ntfs", 512, 4096) == 8 * 1024 * 1024);
    assert (FilesystemResizePlanner.capacity_tolerance ("unknown", 512, 4096) == 0);
    assert (FilesystemResizePlanner.capacity_matches ("ext4", 10 * gib - 64 * 1024 * 1024,
        10 * gib, 10 * gib, 512, 4096));
    assert (!FilesystemResizePlanner.capacity_matches ("ext4", 10 * gib - 256 * 1024 * 1024,
        10 * gib, 10 * gib, 512, 4096));
    assert (!FilesystemResizePlanner.capacity_matches ("unknown", 10 * gib, 10 * gib,
        10 * gib, 512, 4096));
    assert (!FilesystemResizePlanner.capacity_matches ("xfs", 10 * gib + 4096, 10 * gib,
        10 * gib, 512, 4096));
}

private void test_ext_capacity_header () {
    try {
        var geometry = FilesystemCapacityProbeService.parse_ext_header (
            "Filesystem UUID: abcd\nBlock count: 65536\nBlock size: 1024\n");
        assert (geometry.capacity == 67108864 && geometry.allocation_unit == 1024);
        assert (geometry.filesystem_uuid == "abcd");
    } catch (Error error) { assert_not_reached (); }
    try {
        FilesystemCapacityProbeService.parse_ext_header ("Block count: 18446744073709551615\nBlock size: 4096\n");
        assert_not_reached ();
    } catch (Error error) { assert (error is IOError.INVALID_DATA); }
}

private void test_mount_configuration_snapshot () {
    var entry = new StoragePreparationEntry (StoragePreparationKind.MOUNT, "/test",
        { "uuid", "ext4", "/first", "/second" });
    var first = new StorageMountConfiguration ();
    first.directory = "/first";
    first.backend_item = new Variant ("(ss)", "/first", "ro");
    var second = new StorageMountConfiguration ();
    second.directory = "/second";
    second.backend_item = new Variant ("(ss)", "/second", "rw");
    entry.capture_mount_configuration ({ first, second });
    assert (entry.persistent_mount && entry.mount_configuration_matches ({ second, first }));
    assert (!entry.mount_configuration_matches ({ first }));
    second.backend_item = new Variant ("(ss)", "/second", "ro");
    assert (!entry.mount_configuration_matches ({ first, second }));
}

private void test_mount_restoration_status () {
    var entry = new StoragePreparationEntry (StoragePreparationKind.MOUNT, "/test",
        { "uuid", "ext4", "/first", "/second" });
    entry.record_mount_restoration ({ "/second", "/first" });
    assert (entry.restored && entry.mount_restoration == MountRestorationStatus.FULLY_RESTORED);
    entry.record_mount_restoration ({ "/first" });
    assert (!entry.restored && entry.mount_restoration == MountRestorationStatus.PARTIALLY_RESTORED);
    entry.record_mount_restoration ({ "/unrelated" });
    assert (!entry.restored && entry.mount_restoration == MountRestorationStatus.NOT_RESTORED);
    entry.record_mount_restoration (null);
    assert (!entry.restored && entry.mount_restoration == MountRestorationStatus.UNKNOWN);
    entry.restoration_allowed = false;
    entry.record_mount_restoration ({});
    assert (!entry.restored && entry.mount_restoration == MountRestorationStatus.UNSAFE_TO_RESTORE);
    var stacked = new StoragePreparationEntry (StoragePreparationKind.MOUNT, "/test",
        { "uuid", "ext4", "/first", "/first" });
    assert (!stacked.mount_set_matches ({ "/first", "/second" }));
    assert (stacked.mount_set_matches ({ "/first", "/first" }));
}

private void test_preparation_device_identity () {
    var block = new StorageBlock ("/swap");
    block.uuid = "swap-uuid";
    block.type_id = "swap";
    block.device = "/dev/loop1";
    block.number = 1793;
    var entry = new StoragePreparationEntry (StoragePreparationKind.SWAP, block.path,
        { block.uuid, block.type_id });
    entry.device_identity = StoragePreparationJournal.device_identity (block);
    assert (entry.matches_prepared_device (block));
    block.number = 1794;
    assert (!entry.matches_prepared_device (block));
    block.number = 1793;
    block.available = false;
    assert (!entry.matches_prepared_device (block));
}

private void test_crypttab_keyfile_scope () {
    assert (MountOptionService.manages_crypttab_keyfile ("/etc/luks-keys/volume"));
    assert (!MountOptionService.manages_crypttab_keyfile ("/root/recovery.key"));
    assert (!MountOptionService.manages_crypttab_keyfile ("/dev/disk/by-uuid/key"));
    assert (!MountOptionService.manages_crypttab_keyfile ("/etc/luks-keys/subdirectory/key"));
    assert (!MountOptionService.manages_crypttab_keyfile ("/etc/luks-keys/.."));
    assert (!MountOptionService.manages_crypttab_keyfile ("/etc/luks-keys/volume/"));
}

private void test_offline_capacity_identity () {
    try { FilesystemCapacityProbeService.verify_uuid ("abcd", "ABCD"); }
    catch (Error error) { assert_not_reached (); }
    try { FilesystemCapacityProbeService.verify_uuid ("abcd", ""); assert_not_reached (); }
    catch (Error error) { assert (error is IOError.NOT_SUPPORTED); }
    try { FilesystemCapacityProbeService.verify_uuid ("abcd", "ef01"); assert_not_reached (); }
    catch (Error error) { assert (error is IOError.INVALID_DATA); }
}

private void test_offline_capacity_metadata () {
    var fields = FilesystemCapacityProbeService.parse_export (
        "DEVNAME=/dev/loop0p1\nUUID=abcd-1234\nTYPE=ext4\nFSBLOCKSIZE=4096\nFSSIZE=1073741824\nFSLASTBLOCK=262143\n");
    assert (fields.lookup ("TYPE") == "ext4");
    assert (fields.lookup ("FSSIZE") == "1073741824");
    try { assert (FilesystemCapacityProbeService.capacity_from_metadata (fields) == 1073741824); }
    catch (Error error) { assert_not_reached (); }
    var ambiguous = FilesystemCapacityProbeService.parse_export (
        "TYPE=ext4\nFSBLOCKSIZE=4096\nFSLASTBLOCK=262143\n");
    try { FilesystemCapacityProbeService.capacity_from_metadata (ambiguous); assert_not_reached (); }
    catch (Error error) { assert (error is IOError.NOT_SUPPORTED); }
    var invalid = FilesystemCapacityProbeService.parse_export ("TYPE=ext4\nFSSIZE=not-a-number\n");
    try { FilesystemCapacityProbeService.capacity_from_metadata (invalid); assert_not_reached (); }
    catch (Error error) { assert (error is IOError.INVALID_DATA); }
    var measurement = new FilesystemCapacityMeasurement ();
    measurement.capacity = 1024 * 1024 * 1024;
    measurement.allocation_unit = 4096;
    assert (FilesystemCapacityProbeService.authoritative_match (measurement,
        measurement.capacity, measurement.capacity, 512, 4096));
    assert (FilesystemCapacityProbeService.authoritative_match (measurement,
        measurement.capacity + 4096, measurement.capacity + 4096, 512, 4096));
    assert (!FilesystemCapacityProbeService.authoritative_match (measurement,
        measurement.capacity + 8192, measurement.capacity + 8192, 512, 4096));
    assert (!FilesystemCapacityProbeService.authoritative_match (measurement,
        measurement.capacity, measurement.capacity - 1, 512, 4096));
}

private void test_minimum_size_parsers () {
    try {
        assert (FilesystemMinimumSizeService.parse_named_number (
            "Block count: 10\nBlock size: 4096\n", "Block size:") == 4096);
        assert (FilesystemMinimumSizeService.parse_named_number (
            "Estimated minimum size of the filesystem: 12345", "Estimated minimum size of the filesystem:") == 12345);
        assert (FilesystemMinimumSizeService.parse_named_number ("Minsize : 65536 bytes", "Minsize") == 65536);
    } catch (Error error) { assert_not_reached (); }
    try { FilesystemMinimumSizeService.parse_first_number ("not available"); assert_not_reached (); }
    catch (Error error) { assert (error is IOError.INVALID_DATA); }
    assert (FilesystemMinimumSizeService.single_btrfs_capacity (
        "Total devices 1 FS bytes used 123\n\tdevid    1 size 4096 used 1024 path /dev/test1", "/dev/test1") == 4096);
    assert (FilesystemMinimumSizeService.single_btrfs_capacity (
        "Total devices 1 FS bytes used 123\ndevid 1 size 4096 path /dev/test10", "/dev/test1") == 0);
    assert (FilesystemMinimumSizeService.single_btrfs_capacity (
        "Total devices 2 FS bytes used 123\ndevid 1 size 4096 path /dev/test1\n*** Some devices missing", "/dev/test1") == 0);
    assert (FilesystemMinimumSizeService.single_btrfs_capacity (
        "Total devices 1 FS bytes used 123\ndevid 1 size 4096 path /dev/test1\ndevid 2 size 4096 path /dev/test2", "/dev/test1") == 0);
}

private void test_preparation_journal () {
    var journal = new StoragePreparationJournal ();
    var mount = new StoragePreparationEntry (StoragePreparationKind.MOUNT, "/a",
        { "uuid", "ext4", "/mnt/archive" }); mount.prepared = true;
    var swap = new StoragePreparationEntry (StoragePreparationKind.SWAP, "/b", {}); swap.prepared = true;
    mount.actual_state = "unmounted";
    mount.restoration_allowed = false;
    journal.add (mount); journal.add (swap);
    var reverse = journal.restoration_order ();
    assert (reverse.length == 1 && reverse[0] == swap && !journal.fully_restored ());
    string recovery = journal.recovery_details ();
    assert (recovery.contains ("/mnt/archive") && recovery.contains ("automatic restoration was withheld"));
    var multiple = new StoragePreparationEntry (StoragePreparationKind.MOUNT, "/multi",
        { "uuid", "ext4", "/mnt/one", "/mnt/two" });
    assert (multiple.mount_set_matches ({ "/mnt/two", "/mnt/one" }));
    multiple.restored = true;
    multiple.restored = multiple.mount_set_matches ({ "/mnt/one" });
    assert (!multiple.restored);
    swap.restored = true; mount.restored = true; assert (journal.fully_restored ());
}

private void test_create_partition_safety () {
    var disk = make_disk ("gpt"); var graph = new StorageDependencyService ();
    var ordinary = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION, disk, graph);
    assert (ordinary.allowed && ordinary.changes_partition_table && !ordinary.overwrites_storage);
    disk.read_only = true;
    var readonly = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION, disk, graph);
    assert (!readonly.allowed && readonly.blocked);
    disk.read_only = false;
    graph.add (disk, null);
    var unknown = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION, disk, graph);
    assert (!unknown.allowed && unknown.unknown);
}

private void test_create_partition_active_dependency () {
    var disk = make_disk ("gpt"); var child = partition (disk, "/system", 1024 * 1024, 8 * 1024 * 1024);
    child.filesystem = new StorageFilesystem (); child.filesystem.mounts = { "/" }; child.parent = disk;
    var graph = new StorageDependencyService (); graph.add (disk, child);
    var result = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION, disk, graph);
    assert (result.allowed && result.requires_preparation && result.affects_active_dependencies);
}

private void test_operation_terminal_states () {
    var manager = new StorageJobManager (); var block = new StorageBlock ("/state"); block.preferred = "/dev/state";
    var graph = new StorageDependencyService (); var job = manager.begin ("Test", block, graph);
    var cancelled = new StorageOperationResult (); cancelled.fail ("Cancelled", new IOError.CANCELLED ("cancelled"));
    manager.finish (job, cancelled); assert (job.state == StorageJobState.CANCELLED);
    var uncertain = manager.begin ("Test", block, graph); var outcome = new StorageOperationResult ();
    outcome.status = StorageOperationStatus.NEEDS_ATTENTION; outcome.summary = "Unknown";
    manager.finish (uncertain, outcome); assert (uncertain.state == StorageJobState.NEEDS_ATTENTION);
}

private void test_job_retention () {
    var manager = new StorageJobManager (); var graph = new StorageDependencyService ();
    var block = new StorageBlock ("/retained"); block.preferred = "/dev/retained";
    for (int i = 0; i < 60; i++) {
        var job = manager.begin ("Completed", block, graph);
        var result = new StorageOperationResult (); result.successful = true; result.summary = "Completed";
        manager.finish (job, result);
    }
    assert (manager.jobs.get_n_items () == 50 && manager.active_count () == 0);
}

private void test_job_terminal_precedence () {
    var manager = new StorageJobManager ();
    manager.observe ("/job/terminal", "format", { "/block" }, 0.5, true, true, 1);
    manager.backend_completed ("/job/terminal", true, "Completed");
    var job = manager.jobs.get_item (0) as StorageJob;
    assert (job.state == StorageJobState.COMPLETED);
    manager.observe ("/job/terminal", "format", { "/block" }, 0.75, true, true, 1);
    assert (job.state == StorageJobState.COMPLETED && job.phase == "Completed");
    manager.backend_removed ("/job/terminal");
    assert (job.state == StorageJobState.COMPLETED);
}

private void test_job_progress_notifications () {
    var manager = new StorageJobManager (); var graph = new StorageDependencyService ();
    var block = new StorageBlock ("/progress"); block.preferred = "/dev/progress";
    var job = manager.begin ("Diagnostic", block, graph); int changes = 0;
    manager.changed.connect (() => changes++);
    manager.progress (job, "Running", 0.35, true);
    assert (job.state == StorageJobState.RUNNING && job.progress_valid && job.progress == 0.35 && changes == 1);
    var result = new StorageOperationResult (); result.successful = true;
    result.status = StorageOperationStatus.SUCCEEDED; result.summary = "Done"; manager.finish (job, result);
    manager.progress (job, "Stale", 0.7, true);
    assert (job.state == StorageJobState.COMPLETED && job.phase == "Done" && job.progress == 1.0);
}

private void test_mount_option_normalization () {
    try {
        assert (MountOptionService.normalize ("defaults,noauto,rw", true) == "defaults,rw");
        assert (MountOptionService.normalize ("rw,noauto", false) == "rw,noauto");
        assert (MountOptionService.normalize ("", false) == "defaults,noauto");
        assert (MountOptionService.normalize_encryption ("", true) == "");
        assert (MountOptionService.normalize_encryption ("", false) == "noauto");
        assert (MountOptionService.normalize_encryption ("luks,noauto,nofail", true) == "luks,nofail");
        foreach (var destructive in new string[] { "swap", "tmp", "tmp=ext4" }) {
            bool unsafe_option = false;
            try { MountOptionService.normalize_encryption (destructive, true); }
            catch (IOError error) { unsafe_option = true; }
            assert (unsafe_option);
        }
        assert (MountOptionService.compose ("defaults", "Archive, 2026", MountVisibility.DEFAULT) ==
            "defaults,x-gvfs-name=Archive\\054\\0402026");
        string saved = "defaults,x-gvfs-name=Archive\\054\\0402026";
        assert (MountOptionService.display_name (saved) == "Archive, 2026");
        assert (MountOptionService.visibility (saved) == MountVisibility.DEFAULT);
        assert (MountOptionService.compose (saved, "Archive, 2026", MountVisibility.DEFAULT) == saved);
        assert (MountOptionService.compose (saved, "Archive, 2026", MountVisibility.SHOW).has_suffix (",x-gvfs-show"));
        bool rejected = false;
        try { MountOptionService.parse ("rw,rw"); } catch (IOError error) { rejected = true; }
        assert (rejected); rejected = false;
        try { MountOptionService.parse ("ro,rw"); } catch (IOError error) { rejected = true; }
        assert (rejected); rejected = false;
        try { MountOptionService.parse ("x-gvfs-show,x-gvfs-hide"); } catch (IOError error) { rejected = true; }
        assert (rejected);
        MountOptionService.validate_configuration ("/mnt/archive", "btrfs", "defaults,compress=zstd");
        rejected = false;
        try { MountOptionService.validate_configuration ("/mnt/archive", "ext4", "compress=zstd"); }
        catch (IOError error) { rejected = true; }
        assert (rejected); rejected = false;
        try { MountOptionService.validate_configuration ("/mnt/../boot", "ext4", "defaults"); }
        catch (IOError error) { rejected = true; }
        assert (rejected);
    } catch (Error error) { GLib.error ("Unexpected mount-option error: %s", error.message); }
}

private void test_job_correlation () {
    var manager = new StorageJobManager (); var graph = new StorageDependencyService ();
    var block = new StorageBlock ("/target"); block.preferred = "/dev/test";
    var local = manager.begin ("Resize", block, graph); manager.phase (local, StorageJobState.RUNNING, "Resize");
    manager.expect_backend (local, "partition-modify", "/target");
    manager.observe ("/backend/unrelated", "partition-modify", { "/different" }, 0, false, false,
        0);
    assert (manager.jobs.get_n_items () == 2 && local.backend_path == "");
    manager.observe ("/backend/stale", "partition-modify", { "/target" }, 0, false, false,
        (uint64) (local.backend_dispatch_time - 1), Posix.getuid ());
    assert (manager.jobs.get_n_items () == 3 && local.backend_path == "");
    manager.observe ("/backend/other-user", "partition-modify", { "/target" }, 0, false, false,
        (uint64) local.backend_dispatch_time, (int64) Posix.getuid () + 1);
    assert (manager.jobs.get_n_items () == 4 && local.backend_path == "");
    manager.observe ("/backend/related", "partition-modify", { "/target" }, 0.25, true, true,
        (uint64) local.backend_dispatch_time, Posix.getuid ());
    assert (manager.jobs.get_n_items () == 4 && local.backend_path == "/backend/related" && local.progress == 0.25);
    manager.backend_completed ("/backend/related", true, "Done");
    assert (local.state == StorageJobState.FINALIZING);
    var result = new StorageOperationResult (); result.successful = true;
    result.status = StorageOperationStatus.SUCCEEDED; result.summary = "Verified";
    manager.finish (local, result);
    assert (local.state == StorageJobState.COMPLETED && local.phase == "Verified");
}

private void test_late_backend_job () {
    var manager = new StorageJobManager ();
    var local = manager.begin_named ("Resize", "/dev/test", { "/target" });
    manager.expect_backend (local, "partition-modify", "/target");
    manager.method_returned (local, true);

    var verified = new StorageOperationResult ();
    verified.successful = true;
    verified.summary = "Verified";
    manager.finish (local, verified);
    uint64 started = (uint64) local.backend_dispatch_time;
    manager.observe ("/backend/other", "partition-modify", { "/target" }, 0, false, false,
        (uint64) local.backend_method_return_time + 1, Posix.getuid ());
    assert (local.backend_path == "");
    manager.observe ("/backend/late", "partition-modify", { "/target" }, 0.5, true, true,
        started, Posix.getuid ());
    assert (local.backend_path == "/backend/late");
    assert (manager.jobs.get_n_items () == 2 && local.state == StorageJobState.COMPLETED);
    manager.backend_completed ("/backend/late", true, "");
    assert (local.backend_completed && local.phase == "Verified");

    var expired = manager.begin_named ("Resize", "/dev/test", { "/target" });
    manager.expect_backend (expired, "partition-modify", "/target");
    manager.method_returned (expired, true);
    expired.backend_observation_deadline = 0;
    manager.observe ("/backend/expired", "partition-modify", { "/target" }, 0, false, false,
        (uint64) expired.backend_dispatch_time, Posix.getuid ());
    assert (expired.backend_path == "" && expired.backend_expectation == BackendJobExpectation.EXPIRED);

    var disconnected = manager.begin_named ("Resize", "/dev/test", { "/target" });
    manager.expect_backend (disconnected, "partition-modify", "/target");
    manager.method_returned (disconnected, true);
    manager.backend_disconnected ();
    assert (local.backend_path == "" && disconnected.backend_expectation == BackendJobExpectation.EXPIRED);
}

private void test_job_correlation_ambiguity () {
    var manager = new StorageJobManager (); var graph = new StorageDependencyService ();
    var block = new StorageBlock ("/same-target"); block.preferred = "/dev/same";
    var first = manager.begin ("First", block, graph);
    var second = manager.begin ("Second", block, graph);
    manager.phase (first, StorageJobState.RUNNING, "First");
    manager.phase (second, StorageJobState.RUNNING, "Second");
    manager.expect_backend (first, "filesystem-resize", block.path);
    manager.expect_backend (second, "filesystem-resize", block.path);
    manager.observe ("/backend/ambiguous", "filesystem-resize", { block.path }, 0.1, true, true, (uint64) second.backend_dispatch_time, Posix.getuid ());
    assert (manager.jobs.get_n_items () == 3);
    assert (first.backend_path == "" && second.backend_path == "");
    var independent = manager.jobs.get_item (2) as StorageJob;
    assert (!independent.local && independent.backend_path == "/backend/ambiguous");
    var failed = new StorageOperationResult (); failed.fail ("First failed"); manager.finish (first, failed);
    manager.observe ("/backend/second", "filesystem-resize", { block.path }, 0.2, true, true, (uint64) second.backend_dispatch_time, Posix.getuid ());
    assert (second.backend_path == "/backend/second");
}

private void test_selftest_terminal_reconciliation () {
    assert (!StorageSelftestReconciliation.can_attribute_terminal_state (false, "success"));
    assert (!StorageSelftestReconciliation.can_attribute_terminal_state (false, "failed"));
    assert (!StorageSelftestReconciliation.can_attribute_terminal_state (true, ""));
    assert (!StorageSelftestReconciliation.can_attribute_terminal_state (true, "inprogress"));
    assert (StorageSelftestReconciliation.can_attribute_terminal_state (true, "success"));
    assert (StorageSelftestReconciliation.can_attribute_terminal_state (true, "aborted"));
}

private async void query_mock_capability () throws Error {
    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    try {
        var flags = DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
        var server = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        var client = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        uint registration = server.register_object<MockCapabilityManager> (
            "/org/test/Manager", new MockCapabilityService ());
        var proxy = yield new DBusProxy (client, DBusProxyFlags.NONE, null, server.unique_name,
            "/org/test/Manager", "org.test.Manager", null);
        var reply = yield proxy.call ("CanFormat", new Variant ("(s)", "ext4"), DBusCallFlags.NONE, -1, null);
        var capability = FilesystemCapabilityService.decode (reply);
        assert (capability.supported && capability.missing_utility == "");
        server.unregister_object (registration);
        yield client.close ();
        yield server.close ();
    } finally { bus.down (); }
}

private void test_mock_capability_query () {
    var loop = new MainLoop ();
    Error? failure = null;
    query_mock_capability.begin ((object, result) => {
        try { query_mock_capability.end (result); } catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) error ("Mock D-Bus capability query failed: %s", failure.message);
}
[CCode (cname = "majoris_register_mock_open_device", cheader_filename = "mock-open-device.h")]
private extern uint register_mock_open_device (DBusConnection connection, string path, DBusInterfaceInfo info) throws Error;

private async void run_mock_open_device () throws Error {
    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    try {
        var flags = DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
        var server = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        var client = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        string iface = "org.freedesktop.UDisks2.Block";
        var node = new DBusNodeInfo.for_xml ("<node><interface name='org.freedesktop.UDisks2.Block'>" +
            "<method name='OpenDevice'><arg type='s' direction='in'/><arg type='a{sv}' direction='in'/>" +
            "<arg type='h' direction='out'/></method></interface></node>");
        foreach (var path in new string[] { "/test/denied", "/test/missing", "/test/invalid_index", "/test/not_block" }) {
            uint registration = register_mock_open_device (server, path, node.lookup_interface (iface));
            var proxy = yield new DBusProxy (client, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES, null,
                server.unique_name, path, iface, null);
            try {
                yield FilesystemCapacityProbeService.probe_authorized (proxy, 0, new Cancellable ());
                assert_not_reached ();
            } catch (Error error) {
                if (path == "/test/denied")
                    assert (DBusError.get_remote_error (error) == "org.freedesktop.UDisks2.Error.NotAuthorized");
                else assert (error is IOError.INVALID_DATA);
            }
            server.unregister_object (registration);
        }
        yield client.close ();
        yield server.close ();
    } finally { bus.down (); }
}

private void test_mock_open_device () {
    var loop = new MainLoop ();
    run_mock_open_device.begin ((object, result) => {
        try { run_mock_open_device.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private async void probe_file_fixture () throws Error {
    string fixture = Environment.get_variable ("MAJORIS_CAPACITY_FIXTURE") ?? "";
    int fd = Posix.open (fixture, Posix.O_RDONLY | Posix.O_CLOEXEC);
    assert (fd >= 0);
    try {
        var fields = yield FilesystemCapacityProbeService.probe_descriptor (fd, new Cancellable ());
        assert (fields.lookup ("TYPE") == "ext4");
        assert (FilesystemCapacityProbeService.capacity_from_metadata (fields) == 67108864);
        assert (fields.lookup ("UUID") == Environment.get_variable ("MAJORIS_CAPACITY_UUID"));
        assert (Posix.fcntl (fd, Posix.F_GETFD) >= 0);

        var token = new Cancellable ();
        token.cancel ();
        try {
            yield FilesystemCapacityProbeService.probe_descriptor (fd, token);
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.CANCELLED); }
        assert (Posix.fcntl (fd, Posix.F_GETFD) >= 0);
    } finally { Posix.close (fd); }

    int empty = Posix.open ("/dev/null", Posix.O_RDONLY | Posix.O_CLOEXEC);
    assert (empty >= 0);
    try {
        yield FilesystemCapacityProbeService.probe_descriptor (empty, new Cancellable ());
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.INVALID_DATA);
        assert (Posix.fcntl (empty, Posix.F_GETFD) >= 0);
    } finally { Posix.close (empty); }
}

private void test_capacity_descriptor_fixture () {
    var loop = new MainLoop ();
    probe_file_fixture.begin ((object, result) => {
        try { probe_file_fixture.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private async void probe_udisks_fixture () throws Error {
    string path = Environment.get_variable ("MAJORIS_CAPACITY_LOOP") ?? "";
    Posix.Stat info;
    if (Posix.stat (path, out info) != 0 || !Posix.S_ISBLK (info.st_mode))
        throw new IOError.INVALID_DATA ("The disposable loop device is unavailable.");
    var proxy = yield new DBusProxy.for_bus (BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START,
        null, "org.freedesktop.UDisks2",
        "/org/freedesktop/UDisks2/block_devices/" + Path.get_basename (path),
        "org.freedesktop.UDisks2.Block");
    assert (proxy.get_cached_property ("ReadOnly")?.get_boolean () == true);
    var fields = yield FilesystemCapacityProbeService.probe_authorized (proxy,
        (uint64) info.st_rdev, new Cancellable ());
    assert (fields.lookup ("TYPE") == "ext4");
    assert (FilesystemCapacityProbeService.capacity_from_metadata (fields) == 67108864);
    assert (fields.lookup ("UUID") == Environment.get_variable ("MAJORIS_CAPACITY_UUID"));
    try {
        yield FilesystemCapacityProbeService.probe_authorized (proxy, (uint64) info.st_rdev + 1, new Cancellable ());
        assert_not_reached ();
    } catch (Error error) { assert (error is IOError.INVALID_DATA); }
}

private void test_capacity_udisks_fixture () {
    var loop = new MainLoop ();
    probe_udisks_fixture.begin ((object, result) => {
        try { probe_udisks_fixture.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private void test_health_problem_assessment () {
    var drive = new StorageDrive ("/example");
    drive.smart = true;
    drive.smart_enabled = true;
    drive.smart_failing = true;
    bool urgent;
    assert (DriveHealth.problem (drive, true, true, true, out urgent) == "");
    drive.smart_updated = 1;
    assert (DriveHealth.problem (drive, true, true, true, out urgent) != "" && urgent);
    drive.smart_failing = false;
    assert (DriveHealth.problem (drive, true, true, true, out urgent) == "" && !urgent);
    drive.smart_bad_sectors = 9;
    string problem = DriveHealth.problem (drive, true, true, true, out urgent);
    drive.smart_bad_sectors++;
    assert (problem != "" && problem == DriveHealth.problem (drive, true, true, true, out urgent));
    drive.smart_selftest_status = "error_read";
    assert (DriveHealth.problem (drive, false, false, true, out urgent).contains ("self-test"));
    drive.nvme_state = "live";
    drive.nvme_warnings = { "temperature", "spare" };
    assert (DriveHealth.problem (drive, false, true, false, out urgent).contains ("spare, temperature") && urgent);
    drive.wwn = "test-wwn";
    assert (DriveHealth.identity (drive) == "wwn:test-wwn");
    drive.nvme_state = "resetting";
    assert (!DriveHealth.has_current_data (drive));
    drive.nvme_state = "";
    drive.smart_enabled = false;
    assert (!DriveHealth.has_current_data (drive));
}

private async void exercise_image_workflows () throws Error {
    string directory = DirUtils.make_tmp ("majoris-image-tests-XXXXXX");
    var source = File.new_for_path (Path.build_filename (directory, "source.img"));
    var target = File.new_for_path (Path.build_filename (directory, "target.img"));
    int input = -1;
    int output = -1;
    try {
        try {
            yield DiskImageCopy.create_blank (source, 0);
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.INVALID_ARGUMENT); }
        yield DiskImageCopy.create_blank (source, 2 * 1024 * 1024);
        try {
            yield DiskImageCopy.create_blank (source, 1024);
            assert_not_reached ();
        } catch (Error error) { assert (source.query_info (FileAttribute.STANDARD_SIZE, 0).get_size () == 2097152); }
        input = Posix.open (source.get_path (), Posix.O_RDWR | Posix.O_CLOEXEC);
        output = Posix.open (target.get_path (), Posix.O_RDWR | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
        assert (input >= 0 && output >= 0);
        assert (Posix.write (input, "Majoris".data, 7) == 7);
        assert (Posix.lseek (input, 0, Posix.SEEK_SET) == 0);
        var jobs = new StorageJobManager ();
        var job = jobs.begin_named ("Copy image", "Fixture", {});
        yield DiskImageCopy.copy (input, output, 2097152, jobs, job, true);
        var bytes = new uint8[7];
        assert (Posix.lseek (output, 0, Posix.SEEK_SET) == 0 && Posix.read (output, bytes, bytes.length) == 7);
        for (int i = 0; i < bytes.length; i++) assert (bytes[i] == "Majoris"[i]);
        assert (target.query_info (FileAttribute.STANDARD_SIZE, 0).get_size () == 2097152);
        try {
            yield DiskImageCopy.copy (input, output, 1, jobs, job);
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.PARTIAL_INPUT); }

        var measured = yield DiskBenchmark.measure (input, 2097152, 512, 4, 4096, jobs, job);
        assert (measured.throughput.length == 4 && measured.latency.length == 4);
        var aligned = yield DiskBenchmark.measure (input, 2097152, 4096, 4, 4096, jobs, job);
        assert (aligned.throughput.length == 4 && aligned.latency.length == 4);
        assert (DiskBenchmark.position (2097152, 4096, 4096, 2, 4) % 4096 == 0);
        double scratch_rate = yield DiskBenchmark.scratch_write (File.new_for_path (directory), 4096, jobs);
        assert (scratch_rate > 0);
        var files = Dir.open (directory);
        string? name;
        while ((name = files.read_name ()) != null) assert (!name.has_prefix (".majoris-benchmark-"));
        assert (BenchmarkResult.average (measured.throughput) > 0);
        assert (DiskBenchmark.position (2097152, 4096, 512, 0, 4) == 0);
        assert (DiskBenchmark.position (2097152, 4096, 512, 3, 4) == 2097152 - 4096);
        assert (measured.throughput_positions.length == measured.throughput.length);
        assert (measured.latency_positions.length == measured.latency.length);
        assert (measured.throughput_positions[0] == 0);
        assert (measured.throughput_positions[3] == (2097152 - 4096) / 2097152.0);
        foreach (double position in measured.latency_positions) {
            double sector = position * (2097152 / 512);
            assert (position >= 0 && position < 1 && sector == (uint64) sector);
        }
        job.cancellable.cancel ();
        try {
            yield DiskImageCopy.copy (input, output, 1, jobs, job);
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.CANCELLED); }
    } finally {
        if (input >= 0) Posix.close (input);
        if (output >= 0) Posix.close (output);
        FileUtils.unlink (source.get_path ());
        FileUtils.unlink (target.get_path ());
        DirUtils.remove (directory);
    }
}

private async void exercise_mock_rescan () throws Error {
    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    try {
        var flags = DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
        var server = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        var client = yield new DBusConnection.for_address (bus.get_bus_address (), flags);
        string iface = "org.freedesktop.UDisks2.Block";
        var node = new DBusNodeInfo.for_xml ("<node><interface name='org.freedesktop.UDisks2.Block'>" +
            "<method name='Rescan'><arg type='a{sv}' direction='in'/></method></interface></node>");
        foreach (var path in new string[] { "/test/rescan_success", "/test/rescan_failure", "/test/missing" }) {
            uint registration = 0;
            if (path != "/test/missing")
                registration = register_mock_open_device (server, path, node.lookup_interface (iface));
            var proxy = yield new DBusProxy (client, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES, null,
                server.unique_name, path, iface, null);
            var state = new ImageWriteState () { phase = ImageWritePhase.WRITTEN_VERIFIED, descriptor_closed = true };
            try {
                yield state.rescan (proxy, new Cancellable ());
                assert (path == "/test/rescan_success" && state.rescan_completed);
            } catch (Error error) {
                assert (path != "/test/rescan_success" && !state.rescan_completed);
                var result = new StorageOperationResult ();
                state.describe_failure (result, error);
                assert (result.status == StorageOperationStatus.NEEDS_ATTENTION && !result.partial &&
                    result.summary.contains ("written and verified"));
            }
            assert (state.rescan_requested);
            if (registration != 0) server.unregister_object (registration);
        }
        yield client.close ();
        yield server.close ();
    } finally { bus.down (); }
}

private void test_mock_rescan () {
    var loop = new MainLoop ();
    exercise_mock_rescan.begin ((object, result) => {
        try { exercise_mock_rescan.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private void test_restore_failure_classification () {
    var state = new ImageWriteState ();
    var result = new StorageOperationResult ();
    var failure = new IOError.FAILED ("Fixture failure");
    state.describe_failure (result, failure);
    assert (!result.partial && result.summary.contains ("before writing"));
    state.phase = ImageWritePhase.WRITING;
    state.describe_failure (result, failure);
    assert (result.partial && result.status == StorageOperationStatus.NEEDS_ATTENTION);
    state.phase = ImageWritePhase.FLUSHING;
    state.describe_failure (result, failure);
    assert (!result.partial && result.summary.contains ("durability"));
    state.phase = ImageWritePhase.VERIFYING;
    state.describe_failure (result, failure);
    assert (!result.partial && result.summary.contains ("verification"));
    state.phase = ImageWritePhase.RESCANNING;
    state.rescan_requested = true;
    state.describe_failure (result, failure);
    assert (!result.partial && result.summary.contains ("written and verified") &&
        result.summary.contains ("rescan failed") && result.status == StorageOperationStatus.NEEDS_ATTENTION);
}

private void test_conversion_progress () {
    double fraction;
    assert (VirtualDisk.parse_progress ("    (25.50/100%)\r", out fraction) && fraction == 0.255);
    assert (VirtualDisk.parse_progress ("(100.00/100%)", out fraction) && fraction == 1);
    assert (!VirtualDisk.parse_progress ("qemu-img: conversion failed", out fraction));
    assert (!VirtualDisk.parse_progress ("(101/100%)", out fraction));
    assert (!VirtualDisk.parse_progress ("(NaN/100%)", out fraction));
}

private async void exercise_xz () throws Error {
    string? executable = Environment.find_program_in_path ("xz");
    if (executable == null) {
        Test.skip ("xz-utils is unavailable");
        return;
    }
    FileIOStream compressed;
    var file = File.new_tmp ("majoris-xz-test-XXXXXX", out compressed);
    FileIOStream expanded;
    var output = File.new_tmp ("majoris-expanded-test-XXXXXX", out expanded);
    try {
        var compressor = new Subprocess.newv ({ executable, "--stdout", "--compress" },
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
        var payload = new Bytes ("Majoris image fixture".data);
        Bytes? archive;
        yield compressor.communicate_async (payload, null, out archive, null);
        assert (compressor.get_successful () && archive != null);
        size_t written;
        compressed.output_stream.write_all (archive.get_data (), out written);
        var input = compressed.input_stream as FileDescriptorBased;
        assert (input != null && Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        string? source_identity = image_identity (input.get_fd ());
        var token = new Cancellable ();
        var preflight = yield DiskImageCopy.decode_xz (input.get_fd (), null, 1024, token);
        assert (preflight.size == payload.get_size () && image_identity (input.get_fd ()) == source_identity);
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        var written_image = yield DiskImageCopy.decode_xz (input.get_fd (), expanded.output_stream, preflight.size, token);
        uint64 size = written_image.size;
        assert (size == payload.get_size ());
        var output_fd = expanded.output_stream as FileDescriptorBased;
        assert (output_fd != null);
        var jobs = new StorageJobManager ();
        var job = jobs.begin_named ("Restore XZ", "Fixture", {});
        var write_state = new ImageWriteState ();
        yield DiskImageCopy.verify_streamed_write (output_fd.get_fd (), written_image, preflight, jobs, job, write_state);
        assert (write_state.phase == ImageWritePhase.WRITTEN_VERIFIED);
        assert (((Seekable) expanded).seek (0, SeekType.SET));
        var decoded = expanded.input_stream.read_bytes ((size_t) size);
        assert (decoded.compare (payload) == 0);
        assert (Posix.lseek (output_fd.get_fd (), 0, Posix.SEEK_SET) == 0);
        assert (Posix.write (output_fd.get_fd (), "X".data, 1) == 1);
        try {
            yield DiskImageCopy.verify_streamed_write (output_fd.get_fd (), written_image, preflight, jobs, job, write_state);
            assert_not_reached ();
        } catch (Error error) {
            assert (error is IOError.INVALID_DATA && write_state.phase == ImageWritePhase.VERIFYING);
        }
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        try {
            yield DiskImageCopy.expand_xz (input.get_fd (), expanded.output_stream, 1, new Cancellable ());
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.NO_SPACE); }
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_END) == (Posix.off_t) archive.get_size ());
        compressed.output_stream.write_all (archive.get_data (), out written);
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        var combined = yield DiskImageCopy.decode_xz (input.get_fd (), null, 1024, token);
        assert (combined.size == payload.get_size () * 2);
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        var cancelled = new Cancellable ();
        cancelled.cancel ();
        try {
            yield DiskImageCopy.decode_xz (input.get_fd (), null, 1024, cancelled);
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.CANCELLED); }
        assert (Posix.ftruncate (input.get_fd (), (Posix.off_t) (archive.get_size () - 4)) == 0);
        assert (image_identity (input.get_fd ()) != source_identity);
        assert (Posix.lseek (input.get_fd (), 0, Posix.SEEK_SET) == 0);
        try {
            yield DiskImageCopy.expand_xz (input.get_fd (), expanded.output_stream, 1024, new Cancellable ());
            assert_not_reached ();
        } catch (Error error) { assert (error is IOError.INVALID_DATA); }
    } finally {
        try { compressed.close (); file.delete (); }
        catch (Error error) { warning ("%s", error.message); }
        try { expanded.close (); output.delete (); }
        catch (Error error) { warning ("%s", error.message); }
    }
}

private void test_xz_workflow () {
    var loop = new MainLoop ();
    bool finished = false;
    exercise_xz.begin ((object, result) => {
        try { exercise_xz.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        finished = true;
        loop.quit ();
    });
    if (!finished) loop.run ();
}

private void test_image_workflows () {
    var loop = new MainLoop ();
    exercise_image_workflows.begin ((object, result) => {
        try { exercise_image_workflows.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        loop.quit ();
    });
    loop.run ();
}

private async void exercise_image_descriptor_sandbox () throws Error {
    if (!FileUtils.test ("/usr/bin/bwrap", FileTest.IS_EXECUTABLE)) {
        Test.skip ("Bubblewrap is unavailable");
        return;
    }
    var probe = new Subprocess.newv ({ "/usr/bin/bwrap", "--unshare-all", "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "/usr/bin/true" },
        SubprocessFlags.STDERR_SILENCE);
    yield probe.wait_async ();
    if (!probe.get_successful ()) {
        Test.skip ("User namespaces are unavailable");
        return;
    }
    FileIOStream stream;
    var fixture = File.new_tmp ("majoris-sandbox-XXXXXX", out stream);
    try {
        size_t written;
        stream.output_stream.write_all ("descriptor-bound image".data, out written);
        var input = stream.input_stream as FileDescriptorBased;
        assert (input != null);
        int fd = Posix.dup (input.get_fd ());
        assert (fd >= 0);
        var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        launcher.take_fd (fd, 3);
        var child = launcher.spawnv ({ "/usr/bin/bwrap", "--unshare-all", "--die-with-parent",
            "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
            "--ro-bind-fd", "3", "/source", "--", "/usr/bin/cat", "/source" });
        string? output, diagnostic;
        yield child.communicate_utf8_async (null, null, out output, out diagnostic);
        if (!child.get_successful ())
            throw new IOError.FAILED (diagnostic ?? "The sandbox descriptor probe failed.");
        assert (output == "descriptor-bound image");
    } finally {
        try { stream.close (); fixture.delete (); }
        catch (Error error) { warning ("Could not clean up the sandbox fixture: %s", error.message); }
    }
}

private void test_image_descriptor_sandbox () {
    var loop = new MainLoop ();
    bool finished = false;
    exercise_image_descriptor_sandbox.begin ((object, result) => {
        try { exercise_image_descriptor_sandbox.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        finished = true;
        loop.quit ();
    });
    if (!finished) loop.run ();
}

private async void exercise_virtual_images () throws Error {
    if (!VirtualDisk.available ()) {
        Test.skip ("qemu-utils or bubblewrap is unavailable");
        return;
    }
    var check = new Subprocess.newv ({ "/usr/bin/bwrap", "--unshare-all", "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "/usr/bin/true" },
        SubprocessFlags.STDERR_SILENCE);
    if (!(yield check.wait_async ()) || !check.get_successful ()) {
        Test.skip ("The virtual-image sandbox cannot start in this session");
        return;
    }
    string path = DirUtils.make_tmp ("majoris-virtual-tests-XXXXXX");
    var token = new Cancellable ();
    foreach (var format in new string[] { "vpc", "vhdx", "qcow2" }) {
        var virtual_image = File.new_for_path (Path.build_filename (path, format));
        var raw = File.new_for_path (Path.build_filename (path, format + ".img"));
        try {
            yield VirtualDisk.write_image (null, virtual_image, format, 64 * 1024 * 1024, token);
            var info = yield VirtualDisk.inspect (virtual_image, token);
            assert (info.format == format && info.capacity == 64 * 1024 * 1024);
            yield VirtualDisk.write_image (virtual_image, raw, "raw", 0, token);
            var converted = yield VirtualDisk.inspect (raw, token);
            assert (converted.format == "raw" && converted.capacity == info.capacity);
        } finally {
            FileUtils.unlink (raw.get_path ());
            FileUtils.unlink (virtual_image.get_path ());
        }
    }
    DirUtils.remove (path);
}

private void test_virtual_workflows () {
    var loop = new MainLoop ();
    bool finished = false;
    exercise_virtual_images.begin ((object, result) => {
        try { exercise_virtual_images.end (result); } catch (Error error) { GLib.error ("%s", error.message); }
        finished = true;
        loop.quit ();
    });
    if (!finished) loop.run ();
}

private void test_nbd_device_identity () {
    uint index;
    assert (VirtualDiskAttachment.parse_device ("/dev/nbd17", out index) && index == 17);
    assert (!VirtualDiskAttachment.parse_device ("/dev/nbd17p1", out index));
    assert (!VirtualDiskAttachment.parse_device ("/dev/nbd017", out index));
    assert (!VirtualDiskAttachment.parse_device ("/dev/nbd-1", out index));
    assert (!VirtualDiskAttachment.parse_device ("/dev/sda", out index));
}

public static int main (string[] args) {
    Test.init (ref args);
    if (Environment.get_variable ("MAJORIS_CAPACITY_LOOP") != null)
        Test.add_func ("/operations/capacity-udisks-fixture", test_capacity_udisks_fixture);
    if (Environment.get_variable ("MAJORIS_CAPACITY_FIXTURE") != null)
        Test.add_func ("/operations/capacity-descriptor-fixture", test_capacity_descriptor_fixture);
    Test.add_func ("/layout/gaps", test_gaps);
    Test.add_func ("/layout/normalization", test_normalization);
    Test.add_func ("/layout/resize-geometry", test_resize_geometry);
    Test.add_func ("/storage/dependency-safety", test_dependency_safety);
    Test.add_func ("/storage/hierarchy", test_hierarchy);
    Test.add_func ("/storage/capabilities", test_capabilities);
    Test.add_func ("/operations/locks", test_operation_locks);
    Test.add_func ("/operations/lvm-capacity", test_lvm_capacity);
    Test.add_func ("/operations/metadata-safety-classes", test_metadata_safety_classes);
    Test.add_func ("/operations/check-capability", test_check_capability);
    Test.add_func ("/operations/resize-capability", test_resize_capability);
    Test.add_func ("/operations/capability-invalid-responses", test_capability_invalid_responses);
    Test.add_func ("/operations/resize-capability-combinations", test_resize_capability_combinations);
    Test.add_func ("/operations/kernel-identity", test_kernel_identity);
    Test.add_func ("/layout/partition-creation", test_partition_creation_geometry);
    Test.add_func ("/layout/mbr-slot-limits", test_mbr_slot_limits);
    Test.add_func ("/layout/resize-maximum", test_resize_maximum);
    Test.add_func ("/layout/extended-resize-boundaries", test_extended_resize_boundaries);
    Test.add_func ("/operations/label-validation", test_label_validation);
    Test.add_func ("/operations/job-lifecycle", test_job_lifecycle);
    Test.add_func ("/operations/job-correlation", test_job_correlation);
    Test.add_func ("/operations/late-backend-job", test_late_backend_job);
    Test.add_func ("/operations/job-correlation-ambiguity", test_job_correlation_ambiguity);
    Test.add_func ("/operations/selftest-terminal-reconciliation", test_selftest_terminal_reconciliation);
    Test.add_func ("/operations/resize-planner-safety", test_resize_planner_safety);
    Test.add_func ("/operations/resize-capacity-verification", test_resize_capacity_verification);
    Test.add_func ("/operations/ext-capacity-header", test_ext_capacity_header);
    Test.add_func ("/operations/offline-capacity-identity", test_offline_capacity_identity);
    Test.add_func ("/operations/offline-capacity-metadata", test_offline_capacity_metadata);
    Test.add_func ("/operations/minimum-size-parsers", test_minimum_size_parsers);
    Test.add_func ("/operations/mount-configuration-snapshot", test_mount_configuration_snapshot);
    Test.add_func ("/operations/mount-restoration-status", test_mount_restoration_status);
    Test.add_func ("/operations/preparation-device-identity", test_preparation_device_identity);
    Test.add_func ("/operations/crypttab-keyfile-scope", test_crypttab_keyfile_scope);
    Test.add_func ("/operations/preparation-journal", test_preparation_journal);
    Test.add_func ("/operations/create-partition-safety", test_create_partition_safety);
    Test.add_func ("/operations/create-active-dependency", test_create_partition_active_dependency);
    Test.add_func ("/operations/terminal-states", test_operation_terminal_states);
    Test.add_func ("/operations/job-retention", test_job_retention);
    Test.add_func ("/operations/job-terminal-precedence", test_job_terminal_precedence);
    Test.add_func ("/operations/job-progress-notifications", test_job_progress_notifications);
    Test.add_func ("/operations/mount-option-normalization", test_mount_option_normalization);
    Test.add_func ("/operations/mock-dbus-capability", test_mock_capability_query);
    Test.add_func ("/features/drive-health", test_health_problem_assessment);
    Test.add_func ("/features/virtual-image-descriptor-sandbox", test_image_descriptor_sandbox);
    Test.add_func ("/features/nbd-device-identity", test_nbd_device_identity);
    Test.add_func ("/features/virtual-images", test_virtual_workflows);
    Test.add_func ("/features/mock-restore-rescan", test_mock_rescan);
    Test.add_func ("/features/restore-failure-classification", test_restore_failure_classification);
    Test.add_func ("/features/conversion-progress", test_conversion_progress);
    Test.add_func ("/features/xz-restore-preflight", test_xz_workflow);
    Test.add_func ("/features/raw-image-and-benchmark", test_image_workflows);
    Test.add_func ("/operations/mock-open-device", test_mock_open_device);
    return Test.run ();
}
