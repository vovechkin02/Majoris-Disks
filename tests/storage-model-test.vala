using MajorisDisks;

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
    } catch (Error error) {
        assert_not_reached ();
    }
}

private void test_check_capability () {
    try {
        assert (FilesystemCapabilityService.check_available (new Variant ("(bs)", true, "")));
        assert (!FilesystemCapabilityService.check_available (new Variant ("(bs)", false, "")));
    } catch (Error error) {
        assert_not_reached ();
    }
    try {
        FilesystemCapabilityService.check_available (new Variant ("(bs)", false, "e2fsck"));
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.NOT_SUPPORTED && error.message.contains ("e2fsck"));
    }
}
private void test_resize_capability () {
    try {
        string utility;
        var modes = FilesystemCapabilityService.resize_modes (
            new Variant ("(bts)", true, (uint64) 0x8000000000000012, ""), out utility);
        assert (modes == (FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.ONLINE_GROW));
        assert (utility == "");
        modes = FilesystemCapabilityService.resize_modes (
            new Variant ("(bts)", false, (uint64) 0x12, "resize2fs"), out utility);
        assert (modes == 0 && utility == "resize2fs");
    } catch (Error error) {
        assert_not_reached ();
    }
}

private void test_kernel_identity () {
    assert (KernelStorageSafety.device_number (0x801) == "8:1");
    assert (KernelStorageSafety.device_number (0x10000103) == "1:65539");
    string mounts = "36 25 8:10 / /srv/data rw - ext4 /dev/sda10 rw\n";
    assert (KernelStorageSafety.has_mount (mounts, "8:10"));
    assert (!KernelStorageSafety.has_mount (mounts, "8:1"));
}
public static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/layout/gaps", test_gaps);
    Test.add_func ("/layout/normalization", test_normalization);
    Test.add_func ("/layout/resize-geometry", test_resize_geometry);
    Test.add_func ("/storage/dependency-safety", test_dependency_safety);
    Test.add_func ("/storage/hierarchy", test_hierarchy);
    Test.add_func ("/storage/capabilities", test_capabilities);
    Test.add_func ("/operations/locks", test_operation_locks);
    Test.add_func ("/operations/check-capability", test_check_capability);
    Test.add_func ("/operations/resize-capability", test_resize_capability);
    Test.add_func ("/operations/kernel-identity", test_kernel_identity);
    return Test.run ();
}
