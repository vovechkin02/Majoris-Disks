using MajorisDisks;

public static int main (string[] args) {
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
    Object[] instances = {
        new PartitionMap (), new PartitionSegment (), new DriveView (), new DisksWindow (app),
        new SidebarGroupHeading ("Test"), new DeviceRow (drive), new VolumeRow (block),
        new DriveInformationDialog (drive), new InformationRow ("Test", "Value", false),
        new LabelDialog (block), new OwnershipDialog (block), new PartitionMetadataDialog (block, partition, true),
        new OperationResultDialog (), new RepairConfirmationDialog (), new DeleteConfirmationDialog (),
        new FormatDiskDialog (), new FormatVolumeDialog (backend, block),
        new CreatePartitionDialog (backend, disk, gap), new ResizeVolumeDialog (backend, block),
        new JobRow (backend, job), new JobsPopover (backend), new ActiveJobsDialog (), new MountOptionsDialog (block, "identity")
    };
    string[] resources = {
        "window.ui", "drive-view.ui", "partition-map.ui", "partition-segment.ui",
        "device-row.ui", "volume-row.ui", "information-row.ui", "sidebar-group-heading.ui",
        "drive-information-dialog.ui", "edit-filesystem-dialog.ui", "edit-partition-dialog.ui",
        "ownership-dialog.ui", "operation-result-dialog.ui", "repair-confirmation-dialog.ui",
        "delete-confirmation-dialog.ui", "format-disk-dialog.ui", "format-volume-dialog.ui",
        "create-partition-dialog.ui", "resize-volume-dialog.ui", "job-row.ui", "jobs-popover.ui",
        "active-jobs-dialog.ui", "mount-options-dialog.ui"
    };
    foreach (var name in resources) {
        try { resources_lookup_data ("/com/majoris/disks/ui/" + name, ResourceLookupFlags.NONE); }
        catch (Error error) { critical ("Missing resource %s: %s", name, error.message); return 1; }
    }
    assert (instances.length == resources.length);
    return 0;
}
