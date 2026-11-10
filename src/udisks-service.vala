namespace MajorisDisks {
    internal enum SelftestOperationState { REQUESTED, STARTING, START_CONFIRMED, RUNNING, STOPPING, UNCERTAIN }
    internal class SelftestOperation : Object {
        public StorageJob job;
        public string type;
        public int64 observation_deadline;
        public SelftestOperationState state;
        private StorageDrive original_drive;
        private string serial;
        private string wwn;

        public SelftestOperation (StorageJob job, string type, StorageDrive drive) {
            this.job = job; this.type = type;
            original_drive = drive;
            serial = drive.serial;
            wwn = drive.wwn;
            state = SelftestOperationState.REQUESTED;
        }

        public bool matches_drive (StorageDrive drive) {
            if (serial != "" || wwn != "") return drive.serial == serial && drive.wwn == wwn;
            return drive == original_drive;
        }

        public void await_observation () {
            state = SelftestOperationState.UNCERTAIN;
            observation_deadline = get_monotonic_time () + 30 * TimeSpan.SECOND;
        }
    }

    internal class RaidMaintenanceObservation : Object {
        public StorageJob job;
        public MdRaidKernelState kernel;
        public string action;
        public bool reached_end;
        public int64 terminal_deadline;

        public RaidMaintenanceObservation (StorageJob job, MdRaidKernelState kernel, string action) {
            this.job = job;
            this.kernel = kernel;
            this.action = action;
        }
    }

    internal class LuksHeaderReview : Object {
        public string identity { get; private set; }
        public string ticket { get; private set; }
        public string version { get; private set; }
        public string uuid { get; private set; }
        public string confidence { get; private set; }
        public bool damaged { get { return confidence != "readable"; } }
        public uint64 header_size { get; private set; }
        public uint64 data_offset { get; private set; }
        internal uint64 encryption_sector_size;
        public bool checksummed { get; private set; }
        public bool advanced { get; private set; }
        public string file_path { get; private set; }
        public string[] keyslots = {};

        internal LuksHeaderReview (string identity, string ticket, string version, string uuid,
            string confidence, uint64 header_size, uint64 data_offset, bool checksummed, bool advanced, string file_path) {
            this.identity = identity;
            this.ticket = ticket;
            this.version = version;
            this.uuid = uuid;
            this.confidence = confidence;
            this.header_size = header_size;
            this.data_offset = data_offset;
            this.checksummed = checksummed;
            this.advanced = advanced;
            this.file_path = file_path;
        }
    }

    public class UDisksService : Object {
        public const string PREFIX = "org.freedesktop.UDisks2.";
        [CCode (cname = "MAJORIS_BTRFS_DEFAULT_HELPER", cheader_filename = "btrfs-default-config.h")]
        private extern const string BTRFS_DEFAULT_HELPER;
        [CCode (cname = "MAJORIS_BTRFS_STATUS_HELPER", cheader_filename = "btrfs-default-config.h")]
        private extern const string BTRFS_STATUS_HELPER;
        [CCode (cname = "MAJORIS_MDRAID_HELPER", cheader_filename = "mdraid-helper-config.h")]
        private extern const string MDRAID_HELPER;
        private string btrfs_capability_owner = "";
        private bool btrfs_native_default;
        private DBusObjectManagerClient? manager;
        private uint refresh_source;
        private bool connecting;
        private StorageOperationLocks locks = new StorageOperationLocks ();
        private uint raid_reconcile_source;
        private HashTable<string, string> thin_pool_warnings = new HashTable<string, string> (str_hash, str_equal);
        private HashTable<string, RaidMaintenanceObservation> raid_observations =
            new HashTable<string, RaidMaintenanceObservation> (str_hash, str_equal);
        private HashTable<string, StorageJob> local_raid_checks = new HashTable<string, StorageJob> (str_hash, str_equal);
        private HashTable<string, DBusProxy> raid_checks = new HashTable<string, DBusProxy> (str_hash, str_equal);
        private HashTable<string, StorageJob> stopping_raid_checks = new HashTable<string, StorageJob> (str_hash, str_equal);
        private FilesystemMinimumSizeService minimum_sizes = new FilesystemMinimumSizeService ();
        private FilesystemCapacityProbeService capacity_probes = new FilesystemCapacityProbeService ();
        public StorageJobManager jobs { get; private set; default = new StorageJobManager (); }
        private HashTable<string, string> observed_jobs = new HashTable<string, string> (str_hash, str_equal);
        private HashTable<string, string> connected_jobs = new HashTable<string, string> (str_hash, str_equal);
        private HashTable<string, SelftestOperation> active_selftests =
            new HashTable<string, SelftestOperation> (str_hash, str_equal);
        private uint selftest_refresh_source;
        private string? owner;
        private Cancellable backend_lifetime = new Cancellable ();
        public StorageSnapshot snapshot = new StorageSnapshot ();
        public signal void changed ();
        public signal void select_requested (string object_path);

        public async void refresh () throws Error {
            if (connecting) return;
            if (manager == null) {
                connecting = true;
                try {
                    manager = yield new DBusObjectManagerClient.for_bus (
                        BusType.SYSTEM, DBusObjectManagerClientFlags.NONE,
                        "org.freedesktop.UDisks2", "/org/freedesktop/UDisks2", null, null);
                } finally {
                    connecting = false;
                }
                manager.object_added.connect (() => queue_refresh ());
                manager.object_removed.connect (() => queue_refresh ());
                manager.interface_added.connect (() => queue_refresh ());
                manager.interface_removed.connect (() => queue_refresh ());
                manager.interface_proxy_properties_changed.connect (() => queue_refresh ());
                manager.notify["name-owner"].connect (() => {
                    update_owner ();
                    queue_refresh ();
                });
                update_owner ();
            }
            synchronize ();
            foreach (var drive in snapshot.drives.get_values ()) {
                if (drive.medium != null) read_sector_sizes.begin (drive.medium, backend_lifetime);
            }
        }

        private void update_owner () {
            string? current = manager?.get_name_owner ();
            if (current == owner) return;
            backend_lifetime.cancel ();
            backend_lifetime = new Cancellable ();
            if (owner != null) {
                foreach (var operation in active_selftests.get_values ())
                    operation.await_observation ();
                jobs.backend_disconnected ();
                observed_jobs.remove_all ();
                connected_jobs.remove_all ();
            }
            owner = current;
        }
        private void queue_refresh () {
            if (refresh_source != 0) return;
            refresh_source = Idle.add (() => {
                refresh_source = 0;
                synchronize ();
                return Source.REMOVE;
            });
        }

        public bool available () {
            return manager?.get_name_owner () != null;
        }

        private static Variant? property (DBusObject object_proxy, string iface, string key) {
            var proxy = object_proxy.get_interface (PREFIX + iface) as DBusProxy;
            return proxy?.get_cached_property (key);
        }

        private static bool has (DBusObject object_proxy, string iface) {
            return object_proxy.get_interface (PREFIX + iface) != null;
        }

        private void update_drive (DBusObject object_proxy, StorageDrive drive) {
            drive.vendor = property (object_proxy, "Drive", "Vendor")?.get_string () ?? "";
            drive.model = property (object_proxy, "Drive", "Model")?.get_string () ?? "";
            drive.serial = property (object_proxy, "Drive", "Serial")?.get_string () ?? "";
            drive.revision = property (object_proxy, "Drive", "Revision")?.get_string () ?? "";
            drive.wwn = property (object_proxy, "Drive", "WWN")?.get_string () ?? "";
            drive.bus = property (object_proxy, "Drive", "ConnectionBus")?.get_string () ?? "";
            drive.size = property (object_proxy, "Drive", "Size")?.get_uint64 () ?? 0;
            drive.rotation = property (object_proxy, "Drive", "RotationRate")?.get_int32 () ?? -1;
            drive.removable = property (object_proxy, "Drive", "Removable")?.get_boolean () ?? false;
            drive.ejectable = property (object_proxy, "Drive", "Ejectable")?.get_boolean () ?? false;
            drive.can_power_off = property (object_proxy, "Drive", "CanPowerOff")?.get_boolean () ?? false;
            drive.ata_power_management = property (object_proxy, "Drive.Ata", "PmSupported")?.get_boolean () ?? false;
            drive.ata_apm_supported = property (object_proxy, "Drive.Ata", "ApmSupported")?.get_boolean () ?? false;
            drive.ata_aam_supported = property (object_proxy, "Drive.Ata", "AamSupported")?.get_boolean () ?? false;
            drive.ata_write_cache_supported = property (object_proxy, "Drive.Ata", "WriteCacheSupported")?.get_boolean () ?? false;
            drive.ata_read_lookahead_supported = property (object_proxy, "Drive.Ata", "ReadLookaheadSupported")?.get_boolean () ?? false;
            drive.drive_configuration = property (object_proxy, "Drive", "Configuration") ?? new Variant ("a{sv}", null);
            drive.available = property (object_proxy, "Drive", "MediaAvailable")?.get_boolean () ?? false;
            drive.smart = property (object_proxy, "Drive.Ata", "SmartSupported")?.get_boolean () ?? false;
            drive.smart_enabled = property (object_proxy, "Drive.Ata", "SmartEnabled")?.get_boolean () ?? false;
            drive.smart_updated = property (object_proxy, "Drive.Ata", "SmartUpdated")?.get_uint64 () ??
                property (object_proxy, "NVMe.Controller", "SmartUpdated")?.get_uint64 () ?? 0;
            drive.smart_failing = property (object_proxy, "Drive.Ata", "SmartFailing")?.get_boolean () ?? false;
            drive.smart_temperature = property (object_proxy, "Drive.Ata", "SmartTemperature")?.get_double () ?? 0.0;
            drive.smart_power_on_seconds = property (object_proxy, "Drive.Ata", "SmartPowerOnSeconds")?.get_uint64 () ?? 0;
            drive.smart_attributes_failing = property (object_proxy, "Drive.Ata", "SmartNumAttributesFailing")?.get_int32 () ?? -1;
            drive.smart_attributes_failed_past = property (object_proxy, "Drive.Ata", "SmartNumAttributesFailedInThePast")?.get_int32 () ?? -1;
            drive.smart_bad_sectors = property (object_proxy, "Drive.Ata", "SmartNumBadSectors")?.get_int64 () ?? -1;
            drive.smart_selftest_status = property (object_proxy, "Drive.Ata", "SmartSelftestStatus")?.get_string () ??
                property (object_proxy, "NVMe.Controller", "SmartSelftestStatus")?.get_string () ?? "";
            drive.smart_selftest_remaining = property (object_proxy, "Drive.Ata", "SmartSelftestPercentRemaining")?.get_int32 () ??
                property (object_proxy, "NVMe.Controller", "SmartSelftestPercentRemaining")?.get_int32 () ?? -1;
            drive.nvme_warnings = property (object_proxy, "NVMe.Controller", "SmartCriticalWarning")?.dup_strv () ?? new string[0];
            drive.nvme_power_on_hours = property (object_proxy, "NVMe.Controller", "SmartPowerOnHours")?.get_uint64 () ?? 0;
            drive.nvme_temperature = property (object_proxy, "NVMe.Controller", "SmartTemperature")?.get_uint16 () ?? 0;
            bool optical = property (object_proxy, "Drive", "Optical")?.get_boolean () ?? false;
            var media = property (object_proxy, "Drive", "MediaCompatibility");
            if (media != null) {
                foreach (var kind in media.dup_strv ()) optical |= kind.has_prefix ("optical");
            }
            drive.optical = optical;
            drive.media = property (object_proxy, "Drive", "Media")?.get_string () ?? "";
            drive.nvme_state = property (object_proxy, "NVMe.Controller", "State")?.get_string () ?? "";
            drive.category = optical ? "Optical" : drive.removable || drive.bus == "usb" ? "Removable" : "Internal";
            drive.icon = optical ? "drive-optical-symbolic" :
                drive.category == "Removable" ? "drive-removable-media-symbolic" : "drive-harddisk-symbolic";
            drive.name = drive.model == "" ? "Storage drive" : drive.model;
        }

        private void update_block (DBusObject object_proxy, StorageBlock block) {
            block.device = property (object_proxy, "Block", "Device")?.get_bytestring () ?? "";
            block.preferred = property (object_proxy, "Block", "PreferredDevice")?.get_bytestring () ?? "";
            block.drive_path = property (object_proxy, "Block", "Drive")?.get_string () ?? "/";
            block.backing_path = property (object_proxy, "Block", "CryptoBackingDevice")?.get_string () ?? "/";
            block.raid_path = property (object_proxy, "Block", "MDRaid")?.get_string () ?? "/";
            block.usage = property (object_proxy, "Block", "IdUsage")?.get_string () ?? "";
            block.type_id = property (object_proxy, "Block", "IdType")?.get_string () ?? "";
            block.label = property (object_proxy, "Block", "IdLabel")?.get_string () ?? "";
            block.uuid = property (object_proxy, "Block", "IdUUID")?.get_string () ?? "";
            block.size = property (object_proxy, "Block", "Size")?.get_uint64 () ?? 0;
            block.number = property (object_proxy, "Block", "DeviceNumber")?.get_uint64 () ?? 0;
            block.read_only = property (object_proxy, "Block", "ReadOnly")?.get_boolean () ?? false;
            block.ignored = property (object_proxy, "Block", "HintIgnore")?.get_boolean () ?? false;
            block.raid_member_path = property (object_proxy, "Block", "MDRaidMember")?.get_string () ?? "/";
            block.logical_volume_path = property (object_proxy, "Block.LVM2", "LogicalVolume")?.get_string () ?? "/";
            block.physical_volume_group_path = property (object_proxy, "PhysicalVolume", "VolumeGroup")?.get_string () ?? "/";
            block.system_hint = property (object_proxy, "Block", "HintSystem")?.get_boolean () ?? false;
            block.available = block.size != 0;
            block.name = block.label != "" ? block.label : block.preferred;
            block.has_swap = has (object_proxy, "Swapspace");
            block.swap_active = property (object_proxy, "Swapspace", "Active")?.get_boolean () ?? false;
            if (has (object_proxy, "Partition")) {
                var part = block.partition ?? new StoragePartition ();
                part.table_path = property (object_proxy, "Partition", "Table")?.get_string () ?? "/";
                part.type_id = property (object_proxy, "Partition", "Type")?.get_string () ?? "";
                part.name = property (object_proxy, "Partition", "Name")?.get_string () ?? "";
                part.uuid = property (object_proxy, "Partition", "UUID")?.get_string () ?? "";
                part.number = property (object_proxy, "Partition", "Number")?.get_uint32 () ?? 0;
                part.offset = property (object_proxy, "Partition", "Offset")?.get_uint64 () ?? 0;
                part.flags = property (object_proxy, "Partition", "Flags")?.get_uint64 () ?? 0;
                part.container = property (object_proxy, "Partition", "IsContainer")?.get_boolean () ?? false;
                part.logical = property (object_proxy, "Partition", "IsContained")?.get_boolean () ?? false;
                block.partition = part;
                if (block.label == "" && part.name != "") block.name = part.name;
            } else block.partition = null;
            var scheme = property (object_proxy, "PartitionTable", "Type");
            if (scheme == null) block.table = null;
            else {
                var table = block.table ?? new StoragePartitionTable (scheme.get_string ());
                table.scheme = scheme.get_string ();
                table.partitions = {};
                block.table = table;
            }
            if (has (object_proxy, "Filesystem")) {
                var filesystem = block.filesystem ?? new StorageFilesystem ();
                var points = property (object_proxy, "Filesystem", "MountPoints");
                filesystem.mounts = points == null ? new string[0] : points.dup_bytestring_array ();
                filesystem.size = property (object_proxy, "Filesystem", "Size")?.get_uint64 () ?? block.size;
                block.filesystem = filesystem;
            } else block.filesystem = null;
            if (has (object_proxy, "Encrypted")) {
                var encrypted = block.encrypted ?? new StorageEncryptedVolume ();
                encrypted.mapping = null;
                block.encrypted = encrypted;
            } else block.encrypted = null;
            if (has (object_proxy, "Loop")) {
                var loop = block.loop ?? new StorageLoopDevice ();
                loop.backing_file = property (object_proxy, "Loop", "BackingFile")?.get_bytestring () ?? "";
                block.loop = loop;
            } else block.loop = null;
            block.virtual_attachment = VirtualDiskAttachment.lookup (block.device);
            var config = property (object_proxy, "Block", "Configuration");
            block.mount_configuration = null;
            block.mount_configurations = {};
            block.encryption_configuration = null;
            block.encryption_configurations = {};
            if (config != null) {
                for (size_t i = 0; i < config.n_children (); i++) {
                    var entry = config.get_child_value (i);
                    string configuration_type = entry.get_child_value (0).get_string ();
                    if (configuration_type == "crypttab") {
                        var crypt_details = entry.get_child_value (1);
                        var encryption_config = new StorageEncryptionConfiguration ();
                        encryption_config.device = crypt_details.lookup_value ("device", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                        encryption_config.name = crypt_details.lookup_value ("name", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                        encryption_config.options = crypt_details.lookup_value ("options", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                        encryption_config.passphrase_path = crypt_details.lookup_value ("passphrase-path", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                        encryption_config.backend_item = entry;
                        var encryption_entries = new StorageEncryptionConfiguration[block.encryption_configurations.length + 1];
                        for (int j = 0; j < block.encryption_configurations.length; j++)
                            encryption_entries[j] = block.encryption_configurations[j];
                        encryption_entries[encryption_entries.length - 1] = encryption_config;
                        block.encryption_configurations = encryption_entries;
                        if (block.encryption_configuration == null) block.encryption_configuration = encryption_config;
                        continue;
                    }
                    if (configuration_type != "fstab") continue;
                    var details = entry.get_child_value (1);
                    var mount_config = new StorageMountConfiguration ();
                    mount_config.device = details.lookup_value ("fsname", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                    mount_config.directory = details.lookup_value ("dir", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                    mount_config.filesystem = details.lookup_value ("type", VariantType.BYTESTRING)?.get_bytestring () ?? "auto";
                    mount_config.options = details.lookup_value ("opts", VariantType.BYTESTRING)?.get_bytestring () ?? "defaults";
                    mount_config.backend_item = entry;
                    var configurations = new StorageMountConfiguration[block.mount_configurations.length + 1];
                    for (int j = 0; j < block.mount_configurations.length; j++)
                        configurations[j] = block.mount_configurations[j];
                    configurations[configurations.length - 1] = mount_config;
                    block.mount_configurations = configurations;
                    if (block.mount_configuration == null) block.mount_configuration = mount_config;
                    var opts = entry.get_child_value (1).lookup_value ("opts", VariantType.BYTESTRING);
                    if (opts == null) continue;
                    foreach (var option in opts.get_bytestring ().split (","))
                        if (option == "x-gdu.hide") block.ignored = true;
                }
            }
        }

        private async void read_sector_sizes (StorageBlock block, Cancellable token) {
            if (!block.device.has_prefix ("/dev/")) return;
            string kernel_name = Path.get_basename (block.device);
            if (kernel_name == "." || kernel_name == ".." || kernel_name == "/") return;
            var queue = File.new_for_path ("/sys/class/block/" + kernel_name + "/queue");
            uint64 logical = yield read_sector_size (queue, "logical_block_size", token);
            uint64 physical = yield read_sector_size (queue, "physical_block_size", token);
            if (token.is_cancelled () || snapshot.blocks.lookup (block.path) != block) return;
            if (logical == block.logical_sector_size && physical == block.physical_sector_size) return;
            block.logical_sector_size = logical;
            block.physical_sector_size = physical;
            changed ();
        }

        private static async uint64 read_sector_size (File queue, string name, Cancellable token) {
            try {
                uint8[] contents;
                yield queue.get_child (name).load_contents_async (token, out contents, null);
                return uint64.parse (((string) contents).strip ());
            } catch (Error error) {
                return 0;
            }
        }
        private void update_advanced (DBusObject item, string path, HashTable<string, StorageDevice> previous) {
            StorageDevice? device = null;
            if (has (item, "MDRaid")) {
                var raid = (previous.lookup (path) as StorageRaid) ?? new StorageRaid (path);
                raid.name = property (item, "MDRaid", "Name")?.get_string () ?? "";
                raid.level = property (item, "MDRaid", "Level")?.get_string () ?? "";
                raid.degraded = property (item, "MDRaid", "Degraded")?.get_uint32 () ?? 0;
                raid.state = property (item, "MDRaid", "SyncAction")?.get_string () ?? "";
                raid.uuid = property (item, "MDRaid", "UUID")?.get_string () ?? "";
                raid.running = property (item, "MDRaid", "Running")?.get_boolean () == true;
                raid.expected_members = property (item, "MDRaid", "NumDevices")?.get_uint32 () ?? 0;
                raid.size = property (item, "MDRaid", "Size")?.get_uint64 () ?? 0;
                raid.bitmap_location = LvmStructure.typed (property (item, "MDRaid", "BitmapLocation"), "ay")?.get_bytestring () ?? "";
                raid.topology = MdRaidTopology.parse (property (item, "MDRaid", "ActiveDevices"), raid.expected_members);
                raid.kernel = null;
                device = raid;
            } else if (has (item, "VolumeGroup")) {
                var group = (previous.lookup (path) as StorageVolumeGroup) ?? new StorageVolumeGroup (path);
                group.name = property (item, "VolumeGroup", "Name")?.get_string () ?? "";
                group.size = property (item, "VolumeGroup", "Size")?.get_uint64 () ?? 0;
                group.free_size = property (item, "VolumeGroup", "FreeSize")?.get_uint64 () ?? 0;
                group.extent_size = property (item, "VolumeGroup", "ExtentSize")?.get_uint64 () ?? 0;
                group.uuid = LvmStructure.typed (property (item, "VolumeGroup", "UUID"), "s")?.get_string () ?? "";
                var missing = LvmStructure.typed (property (item, "VolumeGroup", "MissingPhysicalVolumes"), "as");
                group.missing_pvs_known = missing != null;
                group.missing_pv_uuids = missing != null ? missing.dup_strv () : new string[0];
                group.needs_polling = LvmStructure.typed (property (item, "VolumeGroup", "NeedsPolling"), "b")?.get_boolean () ?? false;
                device = group;
            } else if (has (item, "LogicalVolume")) {
                var volume = (previous.lookup (path) as StorageLogicalVolume) ?? new StorageLogicalVolume (path);
                volume.name = property (item, "LogicalVolume", "Name")?.get_string () ?? "";
                volume.group_path = property (item, "LogicalVolume", "VolumeGroup")?.get_string () ?? "/";
                volume.active = property (item, "LogicalVolume", "Active")?.get_boolean () ?? false;
                volume.uuid = property (item, "LogicalVolume", "UUID")?.get_string () ?? "";
                volume.size = property (item, "LogicalVolume", "Size")?.get_uint64 () ?? 0;
                volume.data_allocated_ratio = property (item, "LogicalVolume", "DataAllocatedRatio")?.get_double () ?? -1.0;
                volume.metadata_allocated_ratio = property (item, "LogicalVolume", "MetadataAllocatedRatio")?.get_double () ?? -1.0;
                volume.lvm_type = property (item, "LogicalVolume", "Type")?.get_string () ?? "";
                volume.thin_pool_path = property (item, "LogicalVolume", "ThinPool")?.get_string () ?? "/";
                volume.origin_path = property (item, "LogicalVolume", "Origin")?.get_string () ?? "/";
                volume.lvm_layout = LvmStructure.typed (property (item, "LogicalVolume", "Layout"), "s")?.get_string () ?? "";
                volume.structure = LvmStructure.parse (property (item, "LogicalVolume", "Structure"));
                volume.sync_ratio = LvmStructure.typed (property (item, "LogicalVolume", "SyncRatio"), "d")?.get_double () ?? -1;
                volume.child_configuration = LvmStructure.typed (property (item, "LogicalVolume", "ChildConfiguration"), "a(sa{sv})");
                volume.block_path = LvmStructure.typed (property (item, "LogicalVolume", "BlockDevice"), "o")?.get_string () ?? "/";
                device = volume;
            }
            if (device != null) snapshot.advanced.insert (path, device);
        }
        private void synchronize () {
            var previous_blocks = snapshot.blocks;
            var previous_drives = snapshot.drives;
            snapshot.blocks = new HashTable<string, StorageBlock> (str_hash, str_equal);
            snapshot.drives = new HashTable<string, StorageDrive> (str_hash, str_equal);
            foreach (var item in previous_blocks.get_values ()) item.available = false;
            foreach (var item in previous_drives.get_values ()) item.available = false;

            if (available ()) {
                var old_advanced = snapshot.advanced;
                snapshot.advanced = new HashTable<string, StorageDevice> (str_hash, str_equal);
                foreach (var item in manager.get_objects ()) {
                    string path = item.get_object_path ();
                    update_advanced (item, path, old_advanced);
                    if (has (item, "Drive")) {
                        var drive = previous_drives.lookup (path) ?? new StorageDrive (path);
                        drive.blocks = {};
                        drive.medium = null;
                        update_drive (item, drive);
                        snapshot.drives.insert (path, drive);
                    }
                    if (has (item, "Block")) {
                        var block = previous_blocks.lookup (path) ?? new StorageBlock (path);
                        block.parent = null;
                        update_block (item, block);
                        snapshot.blocks.insert (path, block);
                        if (!previous_blocks.contains (path) && block.partition == null)
                            read_sector_sizes.begin (block, backend_lifetime);
                    }
                }
            }
            if (!available ()) snapshot.advanced.remove_all ();
            StorageHierarchy.link (snapshot, previous_drives);
            foreach (var block in snapshot.blocks.get_values ()) {
                if (block.raid != null && block.raid.running) {
                    var kernel = MdRaidKernelState.inspect (block);
                    if (kernel?.matches_uuid (block.raid.uuid) == true) block.raid.kernel = kernel;
                }
            }
            foreach (var entry in snapshot.advanced.get_values ()) {
                var raid = entry as StorageRaid;
                if (raid?.topology == null) continue;
                foreach (var member in raid.topology.members) {
                    var block = snapshot.blocks.lookup (member.path);
                    if (block?.raid_membership != raid) continue;
                    member.block = block;
                    member.array_uuid = raid.uuid;
                    member.metadata_uuid = MdRaidKernelState.udev_property (block, "ID_FS_UUID_SUB");
                    string sector_size;
                    member.kernel_identity = MdRaidKernelState.physical_device (block, out sector_size);
                }
            }
            foreach (var old in previous_blocks.get_values ())
                if (!snapshot.blocks.contains (old.path)) minimum_sizes.invalidate (old.path);
            synchronize_jobs ();
            synchronize_selftests ();
            synchronize_raid_maintenance ();
            synchronize_thin_pool_warnings ();
            changed ();
        }

        private void synchronize_thin_pool_warnings () {
            var previous = thin_pool_warnings;
            thin_pool_warnings = new HashTable<string, string> (str_hash, str_equal);
            foreach (var item in snapshot.advanced.get_values ()) {
                var pool = item as StorageLogicalVolume;
                if (pool == null || pool.lvm_type != "pool" || !pool.active || pool.uuid == "") continue;
                var usage = new ThinPoolUsage (snapshot, pool);
                string warning;
                if (!usage.usage_known || !usage.virtual_known)
                    warning = "Thin pool allocation is unavailable";
                else if (usage.data_ratio >= 1 || usage.metadata_ratio >= 1)
                    warning = "Thin pool data or metadata is exhausted";
                else if (usage.data_ratio >= ThinPoolUsage.WARNING_RATIO || usage.metadata_ratio >= ThinPoolUsage.WARNING_RATIO)
                    warning = "Thin pool data or metadata is at or above 90%";
                else continue;
                thin_pool_warnings.insert (pool.uuid, warning);
                if (previous.lookup (pool.uuid) == warning) continue;
                var job = jobs.begin_named ("Thin pool capacity", pool.name, { pool.path });
                var result = new StorageOperationResult ();
                result.fail (warning);
                result.status = StorageOperationStatus.NEEDS_ATTENTION;
                jobs.finish (job, result);
            }
        }

        private static string? raid_maintenance_title (string action) {
            switch (action) {
            case "check": return "RAID consistency check";
            case "repair": return "RAID consistency repair";
            case "recover": return "RAID member reconstruction";
            case "resync": return "RAID resynchronisation";
            case "reshape": return "RAID reshape";
            default: return null;
            }
        }

        private static bool verified_raid_recovery (StorageRaid? raid) {
            if (raid == null || !raid.running || raid.degraded != 0 || raid.state != "idle" ||
                raid.topology == null || raid.topology.missing_slots.length != 0 ||
                raid.kernel == null || raid.kernel.action != "idle" || raid.kernel.degraded != "0" ||
                raid.kernel.level != raid.level || raid.kernel.expected != raid.expected_members)
                return false;
            foreach (var member in raid.topology.members)
                if (!member.known_states () || "faulty" in member.states || "blocked" in member.states)
                    return false;
            return raid.kernel.verify_members (raid.topology);
        }

        private bool has_raid_backend_job (string array_path) {
            var objects = manager?.get_objects ();
            if (objects == null) return false;
            foreach (var object in objects) {
                var proxy = object.get_interface (PREFIX + "Job") as DBusProxy;
                var operation = proxy?.get_cached_property ("Operation")?.get_string () ?? "";
                var affected = proxy?.get_cached_property ("Objects");
                if (!operation.has_prefix ("md-raid-") || affected == null ||
                    !affected.is_of_type (new VariantType ("ao")))
                    continue;
                for (size_t i = 0; i < affected.n_children (); i++) {
                    string path = affected.get_child_value (i).get_string ();
                    var block = snapshot.blocks.lookup (path);
                    if (path == array_path || block?.raid_path == array_path || block?.raid_member_path == array_path)
                        return true;
                }
            }
            return false;
        }

        private bool has_backend_job_on (string path) {
            var objects = manager?.get_objects ();
            if (objects == null) return true;
            foreach (var object in objects) {
                var proxy = object.get_interface (PREFIX + "Job") as DBusProxy;
                if (proxy == null) continue;
                var affected = proxy.get_cached_property ("Objects");
                if (affected == null || !affected.is_of_type (new VariantType ("ao"))) continue;
                for (size_t i = 0; i < affected.n_children (); i++)
                    if (affected.get_child_value (i).get_string () == path) return true;
            }
            return false;
        }

        private void schedule_raid_reconciliation () {
            if (raid_reconcile_source != 0) return;
            raid_reconcile_source = Timeout.add (250, () => {
                raid_reconcile_source = 0;
                queue_refresh ();
                return Source.REMOVE;
            });
        }

        private void synchronize_raid_maintenance () {
            var running = new HashTable<string, StorageRaid> (str_hash, str_equal);
            var ambiguous = new HashTable<string, string> (str_hash, str_equal);
            foreach (var entry in snapshot.advanced.get_values ()) {
                var raid = entry as StorageRaid;
                if (raid == null || !raid.running || raid.uuid == "" || raid.kernel == null) continue;
                if (running.contains (raid.uuid)) ambiguous.insert (raid.uuid, raid.uuid);
                running.insert (raid.uuid, raid);
            }
            foreach (var uuid in ambiguous.get_keys ()) running.remove (uuid);
            foreach (var uuid in raid_observations.get_keys ()) {
                var observed = raid_observations.lookup (uuid);
                var raid = running.lookup (uuid);
                var kernel = raid?.kernel;
                string action = kernel?.action ?? "";
                bool same = kernel != null && kernel.identity == observed.kernel.identity &&
                    kernel.level == observed.kernel.level && kernel.expected == observed.kernel.expected &&
                    kernel.metadata == observed.kernel.metadata && kernel.layout == observed.kernel.layout;
                if (!available () || (available () && raid == null && !ambiguous.contains (uuid))) {
                    if (observed.terminal_deadline == 0)
                        observed.terminal_deadline = get_monotonic_time () + 15 * TimeSpan.SECOND;
                    if (get_monotonic_time () < observed.terminal_deadline) {
                        schedule_raid_reconciliation ();
                        continue;
                    }
                }
                if (same && action == observed.action) {
                    observed.terminal_deadline = 0;
                    continue;
                }
                bool recovered = observed.action == "recover" || observed.action == "resync";
                if (same && recovered && (action == "recover" || action == "resync")) {
                    observed.action = action;
                    observed.terminal_deadline = 0;
                    continue;
                }
                bool verified = same && action == "idle" &&
                    (recovered || observed.reached_end) && verified_raid_recovery (raid);
                if (same && action == "idle") {
                    if (observed.terminal_deadline == 0)
                        observed.terminal_deadline = get_monotonic_time () + 5 * TimeSpan.SECOND;
                    bool pending_backend = has_raid_backend_job (raid.path);
                    if ((!verified || pending_backend) && get_monotonic_time () < observed.terminal_deadline) {
                        if (observed.job.state != StorageJobState.FINALIZING)
                            jobs.phase (observed.job, StorageJobState.FINALIZING, "Verifying the final RAID state");
                        schedule_raid_reconciliation ();
                        continue;
                    }
                    verified &= !pending_backend;
                }
                var result = new StorageOperationResult ();
                if (verified) {
                    result.successful = true;
                    result.summary = "RAID maintenance completed";
                } else {
                    result.fail ("Could not verify the RAID maintenance outcome");
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                }
                jobs.finish (observed.job, result);
                raid_observations.remove (uuid);
            }

            foreach (var raid in running.get_values ()) {
                if (local_raid_checks.contains (raid.path)) continue;
                string action = raid.kernel.action;
                string? title = raid_maintenance_title (action);
                var proxy = manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy;
                if (title == null || proxy == null) continue;
                var observed = raid_observations.lookup (raid.uuid);
                if (observed == null) {
                    var job = jobs.begin_named (title, raid.name != "" ? raid.name : raid.uuid, { raid.path });
                    observed = new RaidMaintenanceObservation (job, raid.kernel, action);
                    raid_observations.insert (raid.uuid, observed);
                }
                double fraction = raid.kernel.progress;
                bool valid = fraction >= 0.0 && fraction <= 1.0;
                observed.reached_end |= valid && fraction == 1.0;
                uint64 rate = proxy.get_cached_property ("SyncRate")?.get_uint64 () ?? 0;
                uint64 remaining = proxy.get_cached_property ("SyncRemainingTime")?.get_uint64 () ?? 0;
                string phase = title;
                if (rate > 0) phase += " · %s/s".printf (format_size (rate));
                if (remaining > 0) phase += " · %s s remaining".printf (((remaining - 1) / TimeSpan.SECOND + 1).to_string ());
                if (observed.job.phase != phase || observed.job.progress != fraction || observed.job.progress_valid != valid)
                    jobs.progress (observed.job, phase, fraction, valid);
                schedule_raid_reconciliation ();
            }
        }

        private static bool selftest_terminal_success (string status) {
            return status == "success";
        }

        private static bool selftest_terminal_cancelled (string status) {
            return status == "aborted" || status == "interrupted" || status == "ctrl-reset" ||
                status == "ns-removed" || status == "aborted-format" || status == "ctrl_reset" ||
                status == "ns_removed" || status.has_prefix ("aborted_");
        }

        private void synchronize_selftests () {
            string[] finished = {};
            foreach (var entry in active_selftests.get_keys ()) {
                var drive = snapshot.drives.lookup (entry);
                var operation = active_selftests.lookup (entry);
                if (operation == null) continue;
                var job = operation.job;
                if (drive == null || !operation.matches_drive (drive)) {
                    if (drive == null && operation.state == SelftestOperationState.UNCERTAIN &&
                        get_monotonic_time () < operation.observation_deadline) continue;
                    var missing = new StorageOperationResult ();
                    missing.fail ("The original self-test drive is no longer available");
                    missing.status = StorageOperationStatus.NEEDS_ATTENTION;
                    jobs.finish (job, missing); finished += entry;
                    continue;
                }
                string status = drive.smart_selftest_status;
                if (status == "inprogress") {
                    operation.state = operation.state == SelftestOperationState.STOPPING ?
                        SelftestOperationState.STOPPING : SelftestOperationState.RUNNING;
                    bool valid = drive.smart_selftest_remaining >= 0;
                    jobs.progress (job, operation.state == SelftestOperationState.STOPPING ?
                        "Stopping " + operation.type + " self-test" : operation.type + " self-test in progress",
                        valid ? (100.0 - drive.smart_selftest_remaining) / 100.0 : 0.0, valid);
                    continue;
                }
                if (operation.state == SelftestOperationState.REQUESTED ||
                    operation.state == SelftestOperationState.STARTING ||
                    operation.state == SelftestOperationState.START_CONFIRMED) continue;
                if (operation.state == SelftestOperationState.UNCERTAIN) {
                    if (get_monotonic_time () >= operation.observation_deadline) {
                        var unknown = new StorageOperationResult ();
                        unknown.fail ("Self-test result is unknown");
                        unknown.status = StorageOperationStatus.NEEDS_ATTENTION;
                        unknown.technical_error = "A current running state could not be verified.";
                        jobs.finish (job, unknown); finished += entry;
                    }
                    continue;
                }
                var result = new StorageOperationResult ();
                result.actual_state = status;
                if (!StorageSelftestReconciliation.can_attribute_terminal_state (
                    operation.state == SelftestOperationState.RUNNING || operation.state == SelftestOperationState.STOPPING,
                    status)) {
                    result.fail ("Self-test result is unknown");
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                } else if (selftest_terminal_cancelled (status)) {
                    result.fail ("Drive self-test stopped"); result.status = StorageOperationStatus.CANCELLED;
                } else if (selftest_terminal_success (status)) {
                    result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                    result.summary = operation.type + " drive self-test completed";
                } else {
                    result.fail ("Drive self-test failed");
                    result.technical_error = status;
                }
                jobs.finish (job, result); finished += entry;
            }
            foreach (var entry in finished) active_selftests.remove (entry);

            foreach (var drive in snapshot.drives.get_values ()) {
                if (drive.smart_selftest_status != "inprogress" || active_selftests.contains (drive.path)) continue;
                string[] affected = { drive.path };
                if (drive.medium != null) affected += drive.medium.path;
                var job = jobs.begin_named ("Discovered drive self-test", drive.name, affected);
                var operation = new SelftestOperation (job, "Discovered", drive);
                operation.state = SelftestOperationState.RUNNING;
                active_selftests.insert (drive.path, operation);
                bool valid = drive.smart_selftest_remaining >= 0;
                jobs.progress (job, "Drive self-test in progress",
                    valid ? (100.0 - drive.smart_selftest_remaining) / 100.0 : 0.0, valid);
            }
            maintain_selftest_refresh ();
        }

        private void maintain_selftest_refresh () {
            if (active_selftests.size () == 0) {
                if (selftest_refresh_source != 0) Source.remove (selftest_refresh_source);
                selftest_refresh_source = 0; return;
            }
            if (selftest_refresh_source != 0) return;
            selftest_refresh_source = Timeout.add_seconds (5, () => {
                if (active_selftests.size () == 0) { selftest_refresh_source = 0; return Source.REMOVE; }
                synchronize ();
                return Source.CONTINUE;
            });
        }

        private void synchronize_jobs () {
            var current = new HashTable<string, string> (str_hash, str_equal);
            if (manager != null) foreach (var item in manager.get_objects ()) {
                var proxy = item.get_interface (PREFIX + "Job") as DBusProxy;
                if (proxy == null) continue;
                string path = item.get_object_path ();
                current.insert (path, path);
                string operation = proxy.get_cached_property ("Operation")?.get_string () ?? "Storage operation";
                string[] objects = proxy.get_cached_property ("Objects")?.dup_objv () ?? new string[0];
                double progress = proxy.get_cached_property ("Progress")?.get_double () ?? 0.0;
                bool valid = proxy.get_cached_property ("ProgressValid")?.get_boolean () ?? false;
                bool cancelable = proxy.get_cached_property ("Cancelable")?.get_boolean () ?? false;
                uint64 start = proxy.get_cached_property ("StartTime")?.get_uint64 () ?? 0;
                if (!connected_jobs.contains (path)) {
                    connected_jobs.insert (path, path);
                    string captured = path;
                    string? job_owner = owner;
                    proxy.g_signal.connect ((sender, signal_name, parameters) => {
                        if (job_owner != owner || signal_name != "Completed" || !parameters.is_of_type (new VariantType ("(bs)"))) return;
                        jobs.backend_completed (captured, parameters.get_child_value (0).get_boolean (),
                            parameters.get_child_value (1).get_string ());
                    });
                }
                var started_by = proxy.get_cached_property ("StartedByUID");
                jobs.observe (path, operation, objects, progress, valid, cancelable, start,
                    started_by == null ? -1 : (int64) started_by.get_uint32 ());
            }
            foreach (var path in observed_jobs.get_keys ()) if (!current.contains (path)) jobs.backend_removed (path);
            foreach (var path in connected_jobs.get_keys ()) if (!current.contains (path)) connected_jobs.remove (path);
            observed_jobs = current;
        }

        private async Variant call_tracked_method (StorageJob job, DBusProxy proxy, string method,
            Variant parameters, Cancellable token, int timeout = int.MAX) throws Error {
            bool received_reply = false;
            try {
                var reply = yield proxy.call (method, parameters, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    timeout, token);
                received_reply = true;
                return reply;
            } finally {
                jobs.method_returned (job, received_reply && !token.is_cancelled ());
                if (!token.is_cancelled ()) synchronize_jobs ();
            }
        }

        private async int open_block (StorageBlock block, string mode, int flags, Cancellable token) throws Error {
            uint64 number = block.number;
            string identity = modification_identity (block);
            var proxy = require_volume (block, "Block");
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            options.add ("{sv}", "flags", new Variant.int32 (flags));
            UnixFDList? descriptors;
            var reply = yield proxy.call_with_unix_fd_list ("OpenDevice",
                new Variant ("(s@a{sv})", mode, options.end ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, null, token, out descriptors);
            if (descriptors == null || !reply.is_of_type (new VariantType ("(h)")))
                throw new IOError.INVALID_DATA ("UDisks did not return a block descriptor.");
            int handle = reply.get_child_value (0).get_handle ();
            if (handle < 0 || handle >= descriptors.get_length ())
                throw new IOError.INVALID_DATA ("UDisks returned an invalid descriptor index.");
            int fd = descriptors.get (handle);
            try {
                Posix.Stat info = {};
                if (Posix.fstat (fd, out info) != 0 || !Posix.S_ISBLK (info.st_mode) || (uint64) info.st_rdev != number)
                    throw new IOError.INVALID_DATA ("The returned descriptor does not match the selected block device.");
                uint64 capacity;
                if (ioctl_capacity (fd, BLOCK_DEVICE_CAPACITY, out capacity) != 0 || capacity != block.size)
                    throw new IOError.INVALID_DATA ("The block device capacity changed or could not be verified.");
                int access = Posix.fcntl (fd, Posix.F_GETFL);
                int expected = mode == "r" ? Posix.O_RDONLY : Posix.O_RDWR;
                if (access < 0 || (access & Posix.O_ACCMODE) != expected)
                    throw new IOError.INVALID_DATA ("The returned descriptor has unexpected access permissions.");
                if ((flags & DIRECT_IO) != 0 && (access & DIRECT_IO) == 0)
                    throw new IOError.NOT_SUPPORTED ("UDisks did not provide a direct-I/O descriptor. Use Buffered I/O for this device.");
                synchronize ();
                if (require_volume (block, "Block") != proxy || modification_identity (block) != identity)
                    throw new IOError.NOT_FOUND ("The selected block device changed.");
                return fd;
            } catch (Error error) { Posix.close (fd); throw error; }
        }

        internal async BenchmarkResult benchmark (StorageBlock block, int samples, uint64 bytes, bool buffered = false) throws Error {
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Benchmark disk", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            int fd = -1;
            ulong disconnected = backend_lifetime.cancelled.connect (() => job.cancellable.cancel ());
            var lifetime = backend_lifetime;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Authorizing read-only device access");
                uint64 size = block.size;
                string identity = modification_identity (block);
                fd = yield open_block (block, "r", Posix.O_CLOEXEC | (buffered ? 0 : DIRECT_IO), job.cancellable);
                job.cancelable = true;
                var result = yield DiskBenchmark.measure (fd, size,
                    uint64.max (block.logical_sector_size, block.physical_sector_size), samples, bytes, jobs, job);
                synchronize ();
                if (!block.available || snapshot.blocks.lookup (block.path) != block ||
                    modification_identity (block) != identity)
                    throw new IOError.NOT_FOUND ("The device changed during measurement.");
                outcome.successful = true;
                outcome.summary = buffered ? "Buffered benchmark complete" : "Direct-I/O benchmark complete";
                jobs.finish (job, outcome);
                return result;
            } catch (Error error) {
                outcome.fail ("Benchmark stopped", error);
                jobs.finish (job, outcome);
                throw error;
            } finally {
                lifetime.disconnect (disconnected);
                if (fd >= 0) Posix.close (fd);
                locks.release (block);
            }
        }

        internal async void create_disk_image (StorageBlock block, File destination, string confirmed_identity, bool verify = false) throws Error {
            string? path = destination.get_path ();
            var directory = destination.get_parent ();
            if (path == null || directory == null || block.size == 0)
                throw new IOError.INVALID_ARGUMENT ("Choose a local destination for a source with known capacity.");
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The image source changed after confirmation.");
            string temporary = Path.build_filename (directory.get_path (), ".majoris-" + Uuid.string_random ());
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Create disk image", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            ulong disconnected = lifetime.cancelled.connect (() => job.cancellable.cancel ());
            int input = -1;
            int output = -1;
            bool temporary_created = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the destination");
                var token = job.cancellable;
                uint64 size = block.size;
                string identity = modification_identity (block);
                var space = yield directory.query_filesystem_info_async (FileAttribute.FILESYSTEM_FREE,
                    Priority.DEFAULT, token);
                if (space.has_attribute (FileAttribute.FILESYSTEM_FREE) &&
                    space.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE) < size)
                    throw new IOError.NO_SPACE ("The destination does not have enough free space for the image.");
                Posix.Stat info = {};
                if (Posix.stat (directory.get_path (), out info) != 0)
                    throw new IOError.NOT_FOUND ("Could not inspect the destination directory.");
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var dependent = node as StorageBlock;
                    if (dependent != null && dependent.number == (uint64) info.st_dev)
                        throw new IOError.INVALID_ARGUMENT ("Choose a destination outside the source device.");
                }
                if (destination.query_exists (token))
                    throw new IOError.EXISTS ("An image already exists at the selected destination.");
                output = Posix.open (temporary, (verify ? Posix.O_RDWR : Posix.O_WRONLY) | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
                if (output < 0) throw new IOError.FAILED ("Could not create a temporary image: " + Posix.strerror (Posix.errno));
                temporary_created = true;
                if (Posix.fstat (output, out info) != 0)
                    throw new IOError.FAILED ("Could not verify the output filesystem.");
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var dependent = node as StorageBlock;
                    if (dependent != null && dependent.number == (uint64) info.st_dev)
                        throw new IOError.INVALID_ARGUMENT ("The output file is stored on the source device.");
                }
                input = yield open_block (block, "r", Posix.O_CLOEXEC, token);
                job.cancelable = true;
                jobs.phase (job, StorageJobState.RUNNING, "Copying the raw image");
                var copy_state = new ImageWriteState ();
                try { yield DiskImageCopy.copy (input, output, size, jobs, job, verify, copy_state); }
                catch (Error error) {
                    if (verify && copy_state.phase == ImageWritePhase.VERIFYING && !(error is IOError.CANCELLED))
                        throw new IOError.INVALID_DATA ("The copy finished but failed readback verification. " + error.message);
                    throw error;
                }
                synchronize ();
                if (!block.available || snapshot.blocks.lookup (block.path) != block ||
                    modification_identity (block) != identity || Posix.fstat (output, out info) != 0 ||
                    (uint64) info.st_size != size)
                    throw new IOError.INVALID_DATA ("The source or resulting image size could not be verified.");
                int close_status = Posix.close (output);
                output = -1;
                if (close_status != 0) throw new IOError.FAILED ("Could not close the image.");
                if (rename_without_replacement (CURRENT_DIRECTORY, temporary, CURRENT_DIRECTORY, path, NO_REPLACEMENT) != 0)
                    throw new IOError.FAILED ("Could not publish the image: " + Posix.strerror (Posix.errno));
                temporary_created = false;
                outcome.successful = true;
                outcome.summary = verify ? "Disk image created and verified" : "Disk image created without readback verification";
                jobs.finish (job, outcome);
            } catch (Error error) {
                outcome.fail ("Disk image was not created", error);
                jobs.finish (job, outcome);
                throw error;
            } finally {
                if (input >= 0) Posix.close (input);
                if (output >= 0) Posix.close (output);
                if (temporary_created && FileUtils.unlink (temporary) != 0)
                    warning ("Could not remove incomplete image %s", temporary);
                lifetime.disconnect (disconnected);
                locks.release (block);
            }
        }

        internal void check_image_filesystem (StorageBlock block, Posix.Stat info) throws Error {
            foreach (var node in snapshot.dependencies.ancestors (block)) {
                var ancestor = node as StorageBlock;
                if (ancestor == null) continue;
                Posix.Stat backing = {};
                string? backing_path = ancestor.loop?.backing_file ?? ancestor.virtual_attachment?.file;
                if (backing_path != null && backing_path != "" && Posix.stat (backing_path, out backing) == 0 &&
                    backing.st_dev == info.st_dev && backing.st_ino == info.st_ino)
                    throw new IOError.INVALID_ARGUMENT ("The source is the backing image of the selected storage.");
            }
            foreach (var node in snapshot.dependencies.descendants (block)) {
                var dependent = node as StorageBlock;
                if (dependent != null && dependent.number == (uint64) info.st_dev)
                    throw new IOError.INVALID_ARGUMENT ("The image file must be stored outside the selected device.");
            }
        }

        internal async StorageOperationResult restore_disk_image (StorageBlock block, File source,
            string confirmed_identity) throws Error {
            string? path = source.get_path ();
            if (path == null || !(path.has_suffix (".img") || path.has_suffix (".raw") ||
                path.has_suffix (".iso") || path.has_suffix (".img.xz")))
                throw new IOError.INVALID_ARGUMENT ("Choose a local .img, .raw, .iso or .img.xz file.");
            if (block.partition?.container == true)
                throw new IOError.INVALID_ARGUMENT ("An extended partition container cannot be restored as a volume.");
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The selected device changed after confirmation.");
            var eligible = StorageSafetyService.assess_operation (StorageOperationKind.IMAGE_RESTORE, block, snapshot.dependencies);
            if (!eligible.allowed || eligible.unknown) throw new IOError.PERMISSION_DENIED (eligible.reason);
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Restore disk image", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            ulong disconnected = lifetime.cancelled.connect (() => job.cancellable.cancel ());
            StoragePreparationJournal? preparation = null;
            int input = -1;
            int target = -1;
            var state = new ImageWriteState ();
            XzImage? preflight = null;
            try {
                var token = job.cancellable;
                uint64 capacity = block.size;
                job.cancelable = true;
                jobs.phase (job, StorageJobState.PREPARING, "Validating image data");
                input = Posix.open (path, Posix.O_RDONLY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW | Posix.O_NONBLOCK);
                Posix.Stat info = {};
                if (input < 0 || Posix.fstat (input, out info) != 0)
                    throw new IOError.NOT_FOUND ("Could not open the source image.");
                if (!Posix.S_ISREG (info.st_mode) || info.st_size <= 0)
                    throw new IOError.INVALID_DATA ("The source must be a nonempty regular image file.");
                check_image_filesystem (block, info);
                uint64 bytes = (uint64) info.st_size;
                string? source_identity = image_identity (input);
                if (source_identity == null) throw new IOError.FAILED ("Could not record the source identity.");
                if (path.has_suffix (".img.xz")) {
                    jobs.phase (job, StorageJobState.RUNNING, "Validating the compressed image stream");
                    preflight = yield DiskImageCopy.decode_xz (input, null, capacity, token, jobs, job);
                    bytes = preflight.size;
                    if (source_identity != image_identity (input) || Posix.lseek (input, 0, Posix.SEEK_SET) < 0)
                        throw new IOError.INVALID_DATA ("The compressed image changed during preflight.");
                }
                if (bytes == 0 || bytes > capacity)
                    throw new IOError.NO_SPACE ("The image does not fit the selected device.");

                synchronize ();
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The selected device changed while validating the image.");
                token.set_error_if_cancelled ();
                check_image_filesystem (block, info);
                state.phase = ImageWritePhase.PREPARING;
                job.cancelable = false;
                jobs.phase (job, StorageJobState.PREPARING, "Preparing the target device");
                preparation = yield prepare_for_modification (block, lifetime, job);
                synchronize ();
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The target device changed during preparation.");
                var readiness = StorageSafetyService.assess_operation (StorageOperationKind.IMAGE_RESTORE, block, snapshot.dependencies);
                if (!readiness.allowed || readiness.unknown || readiness.requires_preparation)
                    throw new IOError.BUSY ("The target still has active or unresolved dependencies.");
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var dependent = node as StorageBlock;
                    if (dependent != null) yield KernelStorageSafety.require_idle (dependent, lifetime);
                }
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The target device changed before opening it for restore.");
                target = yield open_block (block, "rw", Posix.O_EXCL | Posix.O_CLOEXEC | Posix.O_SYNC, token);
                token.set_error_if_cancelled ();
                if (source_identity != image_identity (input))
                    throw new IOError.INVALID_DATA ("The source image changed before writing could begin.");
                preparation.backend_invoked = true;
                job.cancelable = true;
                jobs.phase (job, StorageJobState.RUNNING, "Writing the verified image");
                if (preflight != null) {
                    var output = new UnixOutputStream (target, false);
                    var decoded = yield DiskImageCopy.decode_xz (input, output, bytes, token, jobs, job, state);
                    yield DiskImageCopy.verify_streamed_write (target, decoded, preflight, jobs, job, state);
                } else {
                    yield DiskImageCopy.copy (input, target, bytes, jobs, job, true, state);
                }
                result.completed ("%s written, flushed, and verified by readback".printf (format_size (bytes)));
                int closed = Posix.close (target);
                target = -1;
                if (closed != 0) throw new IOError.FAILED ("Could not close the target device.");
                state.descriptor_closed = true;
                state.phase = ImageWritePhase.RESCANNING;
                job.cancelable = false;
                jobs.phase (job, StorageJobState.FINALIZING, "Refreshing target storage metadata");
                var proxy = require_volume (block, "Block");
                yield state.rescan (proxy, lifetime);
                synchronize ();
                require_volume (block, "Block");
                state.model_refreshed = true;
                state.phase = ImageWritePhase.COMPLETED;
                result.successful = true;
                result.summary = "Disk image restored";
            } catch (Error error) {
                if (target >= 0) { Posix.close (target); target = -1; }
                state.describe_failure (result, error);
                if (state.phase < ImageWritePhase.WRITING && preparation != null && !preparation.fully_restored ()) {
                    try { yield restore_preparation (preparation, lifetime); }
                    catch (Error restore_error) { result.technical_error += "\n" + restore_error.message; }
                }
            } finally {
                if (input >= 0) Posix.close (input);
                if (target >= 0) Posix.close (target);
                lifetime.disconnect (disconnected);
                locks.release (block);
                jobs.finish (job, result);
            }
            return result;
        }

        internal void require_detached_image (int fd) throws Error {
            if (owner == null) throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            Posix.Stat source = {};
            if (Posix.fstat (fd, out source) != 0)
                throw new IOError.FAILED ("Could not identify the selected image.");
            string path = FileUtils.read_link ("/proc/self/fd/%d".printf (fd));
            synchronize ();
            foreach (var block in snapshot.blocks.get_values ()) {
                string? backing = block.loop?.backing_file ?? block.virtual_attachment?.file;
                if (backing == null || backing == "") continue;
                Posix.Stat attached = {};
                if (backing == path || (Posix.stat (backing, out attached) == 0 &&
                    attached.st_dev == source.st_dev && attached.st_ino == source.st_ino))
                    throw new IOError.BUSY ("Detach the source image before growing a copy.");
            }
        }

        internal async string attach_disk_image (File source, bool read_only) throws Error {
            string? path = source.get_path ();
            string name = (source.get_basename () ?? "").down ();
            if (path == null || !(name.has_suffix (".img") || name.has_suffix (".iso") || name.has_suffix (".raw")))
                throw new IOError.INVALID_ARGUMENT ("Choose a local raw .img, .iso or .raw image.");
            if (!read_only && name.has_suffix (".iso"))
                throw new IOError.INVALID_ARGUMENT ("Optical images can only be attached read-only.");
            var lifetime = backend_lifetime;
            if (owner == null) throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            var job = jobs.begin_named ("Attach disk image", source.get_parse_name (), {});
            var outcome = new StorageOperationResult ();
            int fd = -1;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Opening the image");
                fd = Posix.open (path, (read_only ? Posix.O_RDONLY : Posix.O_RDWR) |
                    Posix.O_CLOEXEC | Posix.O_NOFOLLOW | Posix.O_NONBLOCK);
                Posix.Stat info = {};
                if (fd < 0 || Posix.fstat (fd, out info) != 0)
                    throw new IOError.FAILED ("Could not open the selected image.");
                if (!Posix.S_ISREG (info.st_mode) || info.st_size < 512)
                    throw new IOError.INVALID_DATA ("The selected image is not a usable regular file.");
                string backing = FileUtils.read_link ("/proc/self/fd/%d".printf (fd));
                synchronize ();
                foreach (var existing in snapshot.blocks.get_values ()) {
                    if (existing.loop == null) continue;
                    Posix.Stat existing_file = {};
                    if (existing.loop.backing_file == backing ||
                        (Posix.stat (existing.loop.backing_file, out existing_file) == 0 &&
                         existing_file.st_dev == info.st_dev && existing_file.st_ino == info.st_ino))
                        throw new IOError.EXISTS ("This image is already attached.");
                }
                var manager_proxy = yield new DBusProxy.for_bus (BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START,
                    null, owner, "/org/freedesktop/UDisks2/Manager", PREFIX + "Manager", lifetime);
                var descriptors = new UnixFDList ();
                int handle = descriptors.append (fd);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                options.add ("{sv}", "read-only", new Variant.boolean (read_only));
                jobs.phase (job, StorageJobState.RUNNING, "Attaching the image");
                UnixFDList? returned;
                var reply = yield manager_proxy.call_with_unix_fd_list ("LoopSetup",
                    new Variant ("(h@a{sv})", handle, options.end ()), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    int.MAX, descriptors, lifetime, out returned);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks did not return a loop object.");
                string attached = reply.get_child_value (0).get_string ();
                for (int attempt = 0; attempt < 50; attempt++) {
                    synchronize ();
                    var block = snapshot.blocks.lookup (attached);
                    if (block?.loop != null && block.loop.backing_file == backing && block.read_only == read_only) {
                        outcome.successful = true;
                        outcome.summary = "Disk image attached";
                        jobs.finish (job, outcome);
                        return attached;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("The image may be attached, but the loop object could not be verified. Refresh before retrying.");
            } catch (Error error) {
                outcome.fail ("Could not verify attachment", error);
                jobs.finish (job, outcome);
                throw error;
            } finally { if (fd >= 0) Posix.close (fd); }
        }

        internal async string attach_virtual_image (File source, bool read_only) throws Error {
            var job = jobs.begin_named ("Attach virtual disk", source.get_parse_name (), {});
            var outcome = new StorageOperationResult ();
            VirtualAttachment? record = null;
            try {
                job.cancelable = true;
                jobs.phase (job, StorageJobState.RUNNING, "Inspecting and authorizing the virtual disk");
                record = yield VirtualDiskAttachment.attach (source, read_only, job.cancellable);
                job.cancelable = false;
                jobs.phase (job, StorageJobState.FINALIZING, "Waiting for UDisks discovery");
                string path = "/org/freedesktop/UDisks2/block_devices/nbd%u".printf (record.index);
                for (int attempt = 0; attempt < 75; attempt++) {
                    synchronize ();
                    var block = snapshot.blocks.lookup (path);
                    if (block?.virtual_attachment?.token == record.token && block.read_only == read_only &&
                        block.available && block.size == record.capacity) {
                        Posix.Stat device_info = {};
                        if (Posix.stat (block.device, out device_info) != 0 || !Posix.S_ISBLK (device_info.st_mode) ||
                            (uint64) device_info.st_rdev != block.number)
                            throw new IOError.INVALID_DATA ("The UDisks object does not match the connected NBD device.");
                        outcome.successful = true;
                        outcome.summary = "Virtual disk attached";
                        jobs.finish (job, outcome);
                        return path;
                    }
                    yield settle_delay (backend_lifetime);
                }
                throw new IOError.TIMED_OUT ("The kernel mapping was created but UDisks did not verify it. Refresh before retrying.");
            } catch (Error error) {
                outcome.fail ("Virtual attachment did not complete", error);
                if (record != null || error is VirtualAttachmentError.UNCERTAIN)
                    outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                jobs.finish (job, outcome);
                throw error;
            }
        }

        private async void detach_virtual_image (StorageBlock block, VirtualAttachment record) throws Error {
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Detach virtual disk", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            bool disconnect_started = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking virtual-disk dependencies");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.unknown_dependencies || safety.active_dependents || safety.mounted)
                    throw new IOError.BUSY ("Unmount virtual volumes and close their unlocked mappings before detaching.");
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var dependent = node as StorageBlock;
                    if (dependent != null) yield KernelStorageSafety.require_idle (dependent, backend_lifetime);
                }
                synchronize ();
                if (snapshot.blocks.lookup (block.path) != block || block.virtual_attachment?.token != record.token)
                    throw new IOError.NOT_FOUND ("The selected virtual attachment changed.");
                jobs.phase (job, StorageJobState.RUNNING, "Disconnecting the managed NBD device");
                disconnect_started = true;
                yield VirtualDiskAttachment.detach (record);
                synchronize ();
                outcome.successful = true;
                outcome.summary = "Virtual disk detached";
            } catch (Error error) {
                outcome.fail (disconnect_started ? "Virtual disk detach requires attention" : "Virtual disk was not detached", error);
                if (disconnect_started) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                synchronize ();
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        internal async void detach_disk_image (StorageBlock block) throws Error {
            var virtual_image = block.virtual_attachment;
            if (virtual_image != null) {
                yield detach_virtual_image (block, virtual_image);
                return;
            }
            if (block.loop == null)
                throw new IOError.NOT_SUPPORTED ("The selected device is not an attached raw image.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Detach disk image", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            string backing = block.loop.backing_file;
            var lifetime = backend_lifetime;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking active image volumes");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || safety.mounted)
                    throw new IOError.BUSY ("Unmount image volumes and close unlocked mappings before detaching.");
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var dependent = node as StorageBlock;
                    if (dependent != null) yield KernelStorageSafety.require_idle (dependent, lifetime);
                }
                synchronize ();
                if (block.loop?.backing_file != backing)
                    throw new IOError.NOT_FOUND ("The backing image changed.");
                var proxy = require_volume (block, "Loop");
                jobs.phase (job, StorageJobState.RUNNING, "Detaching the image");
                yield proxy.call ("Delete", new Variant ("(@a{sv})", new Variant ("a{sv}", null)),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                for (int attempt = 0; attempt < 50; attempt++) {
                    synchronize ();
                    if (snapshot.blocks.lookup (block.path) != block || block.loop == null || block.loop.backing_file == "") {
                        outcome.successful = true;
                        outcome.summary = "Disk image detached";
                        jobs.finish (job, outcome);
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("The loop object is still present. Refresh before retrying.");
            } catch (Error error) {
                outcome.fail ("Could not detach the image", error);
                jobs.finish (job, outcome);
                throw error;
            } finally { locks.release (block); }
        }

        internal bool has_btrfs_subvolumes (StorageBlock block) {
            return block.type_id == "btrfs" && block.filesystem?.mounted == true &&
                manager?.get_interface (block.path, PREFIX + "Filesystem.BTRFS") != null;
        }

        private async Variant read_btrfs_subvolumes (DBusProxy proxy, bool snapshots_only, Cancellable token) throws Error {
            var reply = yield proxy.call ("GetSubvolumes", new Variant ("(b@a{sv})", snapshots_only,
                new Variant ("a{sv}", null)), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000, token);
            if (!reply.is_of_type (new VariantType ("(a(tts)i)")))
                throw new IOError.INVALID_DATA ("UDisks returned an invalid Btrfs subvolume list.");
            return reply.get_child_value (0);
        }

        private async bool has_native_btrfs_default (DBusProxy proxy, Cancellable token) throws Error {
            string owner = proxy.get_name_owner () ?? "";
            if (owner == "")
                throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            if (btrfs_capability_owner == owner)
                return btrfs_native_default;
            var reply = yield proxy.get_connection ().call (owner, proxy.get_object_path (),
                "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType ("(s)"),
                DBusCallFlags.NONE, 5000, token);
            var node = new DBusNodeInfo.for_xml (reply.get_child_value (0).get_string ());
            var iface = node.lookup_interface (PREFIX + "Filesystem.BTRFS");
            if (proxy.get_name_owner () != owner)
                throw new IOError.NOT_CONNECTED ("UDisks changed during Btrfs capability discovery.");
            btrfs_native_default = iface?.lookup_method ("GetDefaultSubvolumeID") != null &&
                iface?.lookup_method ("SetDefaultSubvolumeID") != null;
            btrfs_capability_owner = owner;
            return btrfs_native_default;
        }

        private async uint run_btrfs_default_helper (StorageBlock block, DBusProxy proxy,
            bool set, uint previous, uint target, Cancellable token) throws Error {
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (mounts.length == 0 || !Uuid.string_is_valid (uuid) || block.number == 0)
                throw new IOError.NOT_SUPPORTED ("A mounted Btrfs filesystem with a verified source is required.");
            if (!FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (BTRFS_DEFAULT_HELPER, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("Install pkexec and the Majoris Btrfs default-subvolume helper.");
            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", BTRFS_DEFAULT_HELPER,
                set ? "set-default" : "get-default", mounts[0], uuid, block.number.to_string () };
            if (set) {
                argv += previous.to_string ();
                argv += target.to_string ();
            }
            token.set_error_if_cancelled ();
            var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? output, diagnostic;
            // After authorization a write may already have occurred. Wait for its verified outcome.
            yield helper.communicate_utf8_async (null, set ? null : token, out output, out diagnostic);
            if (!helper.get_successful ())
                throw new IOError.FAILED (diagnostic?.strip () ?? "The Btrfs helper failed.");
            uint id = 0;
            if (output == null || !uint.try_parse (output.strip (), out id) || id < 5)
                throw new IOError.INVALID_DATA ("The Btrfs helper returned an invalid default subvolume ID.");
            return id;
        }

        private async uint read_btrfs_default (StorageBlock block, DBusProxy proxy, bool native, Cancellable token) throws Error {
            if (!native)
                return yield run_btrfs_default_helper (block, proxy, false, 0, 0, token);
            var reply = yield proxy.call ("GetDefaultSubvolumeID", new Variant ("(@a{sv})", new Variant ("a{sv}", null)),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000, token);
            if (!reply.is_of_type (new VariantType ("(u)")))
                throw new IOError.INVALID_DATA ("UDisks returned an invalid Btrfs default subvolume ID.");
            return reply.get_child_value (0).get_uint32 ();
        }
        internal async BtrfsSubvolumeList list_btrfs_subvolumes (StorageBlock block, bool include_default = true) throws Error {
            var proxy = require_volume (block, "Filesystem.BTRFS");
            if (!has_btrfs_subvolumes (block))
                throw new IOError.NOT_SUPPORTED ("Mount this Btrfs filesystem to list its subvolumes.");
            string identity = modification_identity (block);
            var lifetime = backend_lifetime;
            var rows = yield read_btrfs_subvolumes (proxy, false, lifetime);
            var snapshots = yield read_btrfs_subvolumes (proxy, true, lifetime);
            var snapshot_ids = new HashTable<string, string> (str_hash, str_equal);
            for (size_t i = 0; i < snapshots.n_children (); i++) {
                string id = snapshots.get_child_value (i).get_child_value (0).get_uint64 ().to_string ();
                snapshot_ids.insert (id, id);
            }
            var result = new BtrfsSubvolumeList ();
            result.entries = new BtrfsSubvolume[(int) rows.n_children ()];
            for (int i = 0; i < result.entries.length; i++) {
                var row = rows.get_child_value (i);
                var entry = new BtrfsSubvolume (row.get_child_value (0).get_uint64 (),
                    row.get_child_value (1).get_uint64 (), row.get_child_value (2).get_string ());
                entry.snapshot = snapshot_ids.contains (entry.id.to_string ());
                result.entries[i] = entry;
            }
            if (include_default) {
                try {
                    bool native = yield has_native_btrfs_default (proxy, lifetime);
                    result.default_id = yield read_btrfs_default (block, proxy, native, lifetime);
                    result.default_known = true;
                } catch (Error error) {
                    lifetime.set_error_if_cancelled ();
                    result.default_unavailable = error.message;
                }
            }
            synchronize ();
            if (require_volume (block, "Filesystem.BTRFS") != proxy || modification_identity (block) != identity)
                throw new IOError.NOT_FOUND ("The selected Btrfs filesystem changed.");
            return result;
        }

        internal static bool valid_btrfs_leaf (string name) {
            if (name.length == 0 || name.length > 255 || name == "." || name == ".." ||
                name.contains ("/") || name != name.strip () || !name.validate ())
                return false;
            for (int i = 0; i < name.length; i++)
                if (name[i] >= 0 && (name[i] < 32 || name[i] == 127)) return false;
            return true;
        }

        [CCode (cname = "g_strcompress", cheader_filename = "glib.h")]
        private extern static string unescape_mount_field (string field);

        private async void require_btrfs_top_level (StorageBlock block, Cancellable token) throws Error {
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (mounts.length != 1)
                throw new IOError.NOT_SUPPORTED ("Mount the Btrfs top-level subvolume at exactly one location.");
            uint8[] contents;
            yield File.new_for_path ("/proc/self/mountinfo").load_contents_async (token, out contents, null);
            int matching = 0;
            foreach (var line in ((string) contents).split ("\n")) {
                var fields = line.split (" ", 6);
                if (fields.length == 6 && fields[3] == "/" && unescape_mount_field (fields[4]) == mounts[0] &&
                    fields[5].contains ("- btrfs "))
                    matching++;
            }
            if (matching != 1)
                throw new IOError.NOT_SUPPORTED ("The selected mount could not be verified as the Btrfs top level.");
        }

        private async void require_unmounted_btrfs_leaf (StorageBlock block, BtrfsSubvolume subvolume,
            string uuid, Cancellable token) throws Error {
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (mounts.length != 1 || !FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (BTRFS_DEFAULT_HELPER, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("The authorized Btrfs mount-namespace check is unavailable.");
            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", BTRFS_DEFAULT_HELPER,
                "check-unmounted", mounts[0], uuid, block.number.to_string (), subvolume.id.to_string (), subvolume.path };
            var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
            string? diagnostic;
            yield helper.communicate_utf8_async (null, token, null, out diagnostic);
            if (!helper.get_successful ())
                throw new IOError.BUSY (diagnostic?.strip () ?? "Btrfs mount usage could not be verified.");
        }
        [CCode (cname = "majoris_btrfs_inspect_subvolume", cheader_filename = "btrfs-inspect.h")]
        private extern static string? inspect_btrfs_subvolume (string path, uint64 id, string filesystem,
            string? origin, out bool read_only);

        internal static string btrfs_subvolume_access (StorageBlock block, BtrfsSubvolume? entry) {
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            bool read_only = false;
            if (mounts.length != 1 || !Uuid.string_is_valid (block.uuid) ||
                inspect_btrfs_subvolume (Path.build_filename (mounts[0], entry?.path ?? ""),
                    entry?.id ?? 5, block.uuid, null, out read_only) == null)
                return "Could not verify the selected subvolume’s read-only flag";
            return read_only ? "Read-only subvolume" : "Writable subvolume";
        }

        internal async uint64 change_btrfs_subvolume (StorageBlock block, string name, string identity,
            BtrfsSubvolume? source = null, bool read_only = false, bool remove = false) throws Error {
            if (!valid_btrfs_leaf (name) || (remove && (source == null || name != source.path)) ||
                (source != null && (source.parent_id != 5 || !valid_btrfs_leaf (source.path))))
                throw new IOError.INVALID_ARGUMENT ("Select a top-level subvolume and enter a valid new name.");
            var proxy = require_volume (block, "Filesystem.BTRFS");
            if (!has_btrfs_subvolumes (block))
                throw new IOError.NOT_SUPPORTED ("Mount the Btrfs filesystem before creating a subvolume.");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 count = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            StorageBlock[] members = {};
            foreach (var candidate in snapshot.blocks.get_values ())
                if (candidate.type_id == "btrfs" && candidate.uuid == uuid && candidate.available)
                    members += candidate;
            if (!Uuid.string_is_valid (uuid) || count == 0 || members.length != count)
                throw new IOError.NOT_SUPPORTED ("UDisks could not identify all Btrfs members.");
            locks.acquire_members (block, members, snapshot.dependencies);
            var job = jobs.begin (remove ? "Delete Btrfs subvolume" :
                source == null ? "Create Btrfs subvolume" : "Create Btrfs snapshot", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                string[] member_identities = {};
                foreach (var member in members) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || member.read_only)
                        throw new IOError.BUSY ("A Btrfs member is protected or in use.");
                    member_identities += modification_identity (member);
                }
                jobs.phase (job, StorageJobState.PREPARING, "Checking the mount and existing subvolumes");
                if (remove) {
                    bool native = yield has_native_btrfs_default (proxy, lifetime);
                    if ((yield read_btrfs_default (block, proxy, native, lifetime)) == source.id)
                        throw new IOError.BUSY ("Select and verify a different default subvolume before deleting this one.");

                }
                var rows = yield read_btrfs_subvolumes (proxy, false, lifetime);
                bool found = false;
                for (size_t i = 0; i < rows.n_children (); i++) {
                    var row = rows.get_child_value (i);
                    string path = row.get_child_value (2).get_string ();
                    if (!remove && path == name)
                        throw new IOError.EXISTS ("A top-level subvolume already has that name.");
                    if (!remove) continue;
                    if (row.get_child_value (1).get_uint64 () == source.id || path.has_prefix (name + "/"))
                        throw new IOError.BUSY ("Remove nested subvolumes individually before deleting their parent.");
                    found |= path == name && row.get_child_value (0).get_uint64 () == source.id &&
                        row.get_child_value (1).get_uint64 () == 5;
                }
                if (remove && !found)
                    throw new IOError.NOT_FOUND ("The selected Btrfs subvolume changed.");
                yield require_btrfs_top_level (block, lifetime);
                synchronize ();
                if (modification_identity (block) != identity || require_volume (block, "Filesystem.BTRFS") != proxy ||
                    proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                    proxy.get_cached_property ("num_devices")?.get_uint64 () != count)
                    throw new IOError.NOT_FOUND ("The selected Btrfs filesystem changed.");
                for (int i = 0; i < members.length; i++) {
                    require_volume (members[i], "Block");
                    if (modification_identity (members[i]) != member_identities[i])
                        throw new IOError.NOT_FOUND ("A Btrfs member changed after confirmation.");
                }
                string? origin = null;
                string mount = block.filesystem.mounts[0];
                if (remove) {
                    yield require_unmounted_btrfs_leaf (block, source, uuid, lifetime);
                    synchronize ();
                    if (creation_identity_changed (block, identity) || require_volume (block, "Filesystem.BTRFS") != proxy ||
                        proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                        proxy.get_cached_property ("num_devices")?.get_uint64 () != count ||
                        block.filesystem?.mounts.length != 1 || block.filesystem.mounts[0] != mount)
                        throw new IOError.NOT_FOUND ("The filesystem changed while checking its mount usage.");
                    Posix.Stat parent = {};
                    if (Posix.stat (mount, out parent) != 0 || parent.st_uid != 0 || (parent.st_mode & 0022) != 0)
                        throw new IOError.NOT_SUPPORTED ("Deletion requires a root-owned top-level mount directory protected from other writers.");
                }
                if (source != null) {
                    bool source_read_only;
                    origin = inspect_btrfs_subvolume (Path.build_filename (mount, source.path), source.id, uuid,
                        null, out source_read_only);
                    if (origin == null)
                        throw new IOError.NOT_FOUND ("Could not verify the selected Btrfs subvolume.");
                }
                jobs.phase (job, StorageJobState.RUNNING, remove ? "Deleting the Btrfs subvolume" :
                    source == null ? "Creating the Btrfs subvolume" : "Creating the Btrfs snapshot");
                dispatched = true;
                var options = new Variant ("a{sv}", null);
                yield call_tracked_method (job, proxy, remove ? "RemoveSubvolume" :
                    source == null ? "CreateSubvolume" : "CreateSnapshot",
                    remove || source == null ? new Variant ("(s@a{sv})", name, options) :
                    new Variant ("(ssb@a{sv})", source.path, name, read_only, options), lifetime);
                rows = yield read_btrfs_subvolumes (proxy, !remove && source != null, lifetime);
                if (remove) {
                    if (require_volume (block, "Filesystem.BTRFS") != proxy ||
                        proxy.get_cached_property ("uuid")?.get_string () != uuid)
                        throw new IOError.NOT_FOUND ("The filesystem changed during subvolume deletion.");
                    for (size_t i = 0; i < rows.n_children (); i++) {
                        var row = rows.get_child_value (i);
                        if (row.get_child_value (0).get_uint64 () == source.id || row.get_child_value (2).get_string () == name)
                            throw new IOError.FAILED ("UDisks still reports the selected subvolume or its path.");
                    }
                    outcome.successful = true;
                    outcome.summary = "Btrfs subvolume deleted";
                    return 0;
                }
                for (size_t i = 0; i < rows.n_children (); i++) {
                    var row = rows.get_child_value (i);
                    if (row.get_child_value (1).get_uint64 () == 5 && row.get_child_value (2).get_string () == name) {
                        if (source != null) {
                            bool actual_read_only;
                            if (inspect_btrfs_subvolume (Path.build_filename (mount, name),
                                row.get_child_value (0).get_uint64 (), uuid, origin, out actual_read_only) == null ||
                                actual_read_only != read_only)
                                break;
                        }
                        outcome.successful = true;
                        outcome.summary = source == null ? "Btrfs subvolume created" : "Btrfs snapshot created";
                        return row.get_child_value (0).get_uint64 ();
                    }
                }
                throw new IOError.FAILED ("UDisks did not confirm the new top-level subvolume.");
            } catch (Error error) {
                outcome.fail (remove ? "Could not confirm Btrfs subvolume deletion" : "Could not confirm Btrfs subvolume creation", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        [CCode (cname = "majoris_btrfs_allocation", cheader_filename = "btrfs-inspect.h")]
        private extern static Variant? read_btrfs_allocation (string path, string uuid);

        internal async BtrfsFilesystemInfo query_btrfs_allocation (StorageBlock block) throws Error {
            var proxy = require_volume (block, "Filesystem.BTRFS");
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            if (mounts.length == 0 || !Uuid.string_is_valid (uuid))
                throw new IOError.NOT_SUPPORTED ("Mount a verified Btrfs filesystem to inspect its allocation.");
            string mount = mounts[0];
            string identity = modification_identity (block);
            var context = MainContext.ref_thread_default ();
            var lifetime = backend_lifetime;
            Variant? report = null;
            new Thread<void*>.try ("btrfs-allocation", () => {
                report = read_btrfs_allocation (mount, uuid);
                var resume = new IdleSource ();
                resume.set_callback (query_btrfs_allocation.callback);
                resume.attach (context);
                return null;
            });
            yield;
            lifetime.set_error_if_cancelled ();
            synchronize ();
            if (creation_identity_changed (block, identity) || require_volume (block, "Filesystem.BTRFS") != proxy ||
                proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                !(mount in (block.filesystem?.mounts ?? new string[0])))
                throw new IOError.NOT_FOUND ("The Btrfs filesystem or mount changed during inspection.");
            if (report == null)
                throw new IOError.FAILED ("The kernel did not return verified Btrfs allocation data.");
            return new BtrfsFilesystemInfo (uuid, block.label, report);
        }

        internal bool has_btrfs_replacement_helper () {
            return FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) &&
                FileUtils.test (BTRFS_DEFAULT_HELPER, FileTest.IS_EXECUTABLE) &&
                FileUtils.test (BTRFS_STATUS_HELPER, FileTest.IS_EXECUTABLE);
        }

        internal uint64 btrfs_target_sequence (StorageBlock target) {
            string number = KernelStorageSafety.device_number (target.number);
            try {
                string sequence, link = FileUtils.read_link ("/sys/dev/block/" + number);
                if (link.contains ("/virtual/") && !link.contains ("/virtual/block/loop")) return 0;
                FileUtils.get_contents ("/sys/dev/block/" + number + "/diskseq", out sequence);
                uint64 value;
                if (uint64.try_parse (sequence.strip (), out value)) return value;
            } catch (Error error) {}
            return 0;
        }

        internal bool can_target_btrfs_replacement (BtrfsFilesystemInfo report, BtrfsMemberInfo source, StorageBlock target) {
            if (target.partition != null || target.size < source.capacity || !can_use_group_member (target) ||
                btrfs_target_sequence (target) == 0)
                return false;
            foreach (var row in report.members) {
                if (row.number == target.number) return false;
                foreach (var member in snapshot.blocks.get_values ())
                    if (row.number != 0 && member.number == row.number && member.drive_path != "/" &&
                        member.drive_path == target.drive_path)
                        return false;
            }
            return true;
        }

        private async BtrfsReplacementStatus invoke_btrfs_replace (StorageBlock block, string uuid,
            string operation, string[] arguments, Cancellable? token) throws Error {
            var proxy = require_volume (block, "Filesystem.BTRFS");
            var mounts = block.filesystem?.mounts ?? new string[0];
            if (proxy.get_cached_property ("uuid")?.get_string () != uuid || !Uuid.string_is_valid (uuid) ||
                mounts.length != 1 || block.number == 0 || !has_btrfs_replacement_helper ())
                throw new IOError.NOT_SUPPORTED ("A verified mount and the authorized Btrfs helper are required.");
            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent",
                operation == "replace-status" || operation == "replace-check" ? BTRFS_STATUS_HELPER : BTRFS_DEFAULT_HELPER,
                operation, mounts[0], uuid, block.number.to_string () };
            foreach (var argument in arguments) argv += argument;
            var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? output, diagnostic;
            yield helper.communicate_utf8_async (null, token, out output, out diagnostic);
            if (!helper.get_successful ())
                throw new IOError.FAILED (diagnostic != null && diagnostic.strip () != "" ? diagnostic.strip () :
                    "The Btrfs helper did not confirm the request. Check the kernel replacement status.");
            var status = new BtrfsReplacementStatus (uuid, output ?? "");
            status.warning = diagnostic?.strip () ?? "";
            return status;
        }

        private HashTable<string, StorageJob> replacement_jobs = new HashTable<string, StorageJob> (str_hash, str_equal);

        private static string[] btrfs_replacement_arguments (BtrfsFilesystemInfo report, BtrfsMemberInfo source,
            StorageBlock target, uint64 sequence, bool avoid) {
            return { report.member_count.to_string (), source.id.to_string (), source.uuid, source.number.to_string (),
                target.number.to_string (), target.device, target.size.to_string (), sequence.to_string (),
                target.path, avoid ? "1" : "0" };
        }

        internal async uint64 check_btrfs_replacement_target (StorageBlock anchor, BtrfsFilesystemInfo report,
            BtrfsMemberInfo source, StorageBlock target, bool avoid) throws Error {
            var token = backend_lifetime;
            string identity = modification_identity (target);
            uint64 sequence = btrfs_target_sequence (target);
            yield KernelStorageSafety.require_idle (target, token);
            yield invoke_btrfs_replace (anchor, report.uuid, "replace-check",
                btrfs_replacement_arguments (report, source, target, sequence, avoid), token);
            synchronize ();
            if (creation_identity_changed (target, identity) || sequence != btrfs_target_sequence (target))
                throw new IOError.NOT_FOUND ("The target changed during verification.");
            return sequence;
        }

        internal async BtrfsReplacementStatus btrfs_replacement_status (string uuid, uint64 cancel_started = 0) throws Error {
            synchronize ();
            foreach (var block in snapshot.blocks.get_values ()) {
                if (block.uuid != uuid || block.type_id != "btrfs" || block.filesystem?.mounted != true)
                    continue;
                if (cancel_started != 0 && (block.read_only || block.system_hint))
                    throw new IOError.PERMISSION_DENIED ("This filesystem is protected or read-only.");
                var status = yield invoke_btrfs_replace (block, uuid,
                    cancel_started == 0 ? "replace-status" : "replace-cancel",
                    cancel_started == 0 ? new string[0] : new string[] { cancel_started.to_string () }, backend_lifetime);
                var job = replacement_jobs.lookup (uuid);
                if (job != null)
                    jobs.progress (job, status.state_label (), status.progress_1000 / 1000.0, status.active);
                return status;
            }
            throw new IOError.NOT_FOUND ("The mounted Btrfs filesystem is unavailable.");
        }

        internal async BtrfsReplacementStatus replace_btrfs_device (StorageBlock block, string block_identity,
            BtrfsFilesystemInfo review, BtrfsMemberInfo source, StorageBlock target, string target_identity,
            uint64 target_sequence, bool avoid) throws Error {
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents ||
                block.read_only || target_sequence == 0)
                throw new IOError.PERMISSION_DENIED ("The filesystem is protected or the target identity is unavailable.");
            var current = yield query_btrfs_allocation (block);
            BtrfsMemberInfo? selected = null;
            foreach (var member in current.members)
                if (member.id == source.id && member.uuid == source.uuid && member.number == source.number &&
                    member.capacity == source.capacity) selected = member;
            if (current.uuid != review.uuid || current.member_count != review.member_count ||
                selected == null || current.replacement_restriction (selected, avoid) != "" ||
                !can_target_btrfs_replacement (current, selected, target))
                throw new IOError.BUSY ("The reviewed filesystem or replacement eligibility changed.");
            StorageBlock[] members = { target };
            foreach (var row in current.members) {
                if (row.number == 0 || row.number == block.number) continue;
                StorageBlock? member = null;
                foreach (var candidate in snapshot.blocks.get_values ())
                    if (candidate.number == row.number && candidate.uuid == current.uuid && candidate.type_id == "btrfs")
                        member = candidate;
                if (member == null)
                    throw new IOError.NOT_FOUND ("UDisks could not verify a Btrfs member.");
                var member_safety = StorageSafetyService.assess (member, snapshot.dependencies);
                if (member_safety.system_critical || member_safety.unknown_dependencies || member_safety.active_dependents)
                    throw new IOError.BUSY ("A Btrfs member is protected or has unresolved dependencies.");
                members += member;
            }
            locks.acquire_members (block, members, snapshot.dependencies);
            var job = jobs.begin ("Replace Btrfs Device", block, snapshot.dependencies);
            replacement_jobs.insert (current.uuid, job);
            var outcome = new StorageOperationResult ();
            bool dispatched = false;
            try {
                yield KernelStorageSafety.require_idle (target, backend_lifetime);
                synchronize ();
                require_volume (target, "Block");
                if (creation_identity_changed (block, block_identity) || creation_identity_changed (target, target_identity) ||
                    !can_target_btrfs_replacement (current, selected, target) || btrfs_target_sequence (target) != target_sequence)
                    throw new IOError.BUSY ("The filesystem or target changed after confirmation.");
                jobs.phase (job, StorageJobState.RUNNING, "Waiting for authorization and kernel replacement");
                dispatched = true;
                var status = yield invoke_btrfs_replace (block, current.uuid, "replace-start",
                    btrfs_replacement_arguments (current, source, target, target_sequence, avoid), null);
                if (status.state == 2) {
                    try {
                        var target_proxy = require_volume (target, "Block");
                        if (target_proxy.get_cached_property ("DeviceNumber")?.get_uint64 () == target.number)
                            yield target_proxy.call ("Rescan", new Variant ("(@a{sv})", new Variant ("a{sv}", null)),
                                DBusCallFlags.NONE, 5000, backend_lifetime);
                    } catch (Error error) {}
                }
                yield refresh ();
                var refreshed_target = snapshot.blocks.lookup (target.path);
                status.membership_verified = status.state == 2 && refreshed_target != null &&
                    refreshed_target.number == target.number && refreshed_target.type_id == "btrfs" &&
                    refreshed_target.uuid == current.uuid;
                if (status.state == 2 && !status.membership_verified)
                    status.warning = (status.warning + "\nUDisks has yet to confirm the refreshed target membership.").strip ();
                outcome.successful = status.verified_completion;
                outcome.summary = outcome.successful ? "Btrfs replacement completed and membership verified" :
                    status.state == 2 ? "Btrfs replacement finished and needs attention" : status.state_label ();
                if (!outcome.successful) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                return status;
            } catch (Error error) {
                outcome.fail ("Could not confirm the Btrfs replacement outcome", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                replacement_jobs.remove (current.uuid);
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        internal async BtrfsConversionPlan review_btrfs_conversion (StorageBlock block, string identity,
            BtrfsProfileType data, BtrfsProfileType metadata, bool resume = false) throws Error {
            if ((data == BtrfsProfileType.UNKNOWN && metadata == BtrfsProfileType.UNKNOWN) ||
                (data != BtrfsProfileType.UNKNOWN && !data.convertible ()) ||
                (metadata != BtrfsProfileType.UNKNOWN && !metadata.convertible ()))
                throw new IOError.INVALID_ARGUMENT ("Select at least one supported target profile.");
            var current = yield query_btrfs_allocation (block);
            var plan = new BtrfsConversionPlan (current, data, metadata);
            string output = yield btrfs_maintenance (block, identity,
                resume ? "balance-convert-resume-check" : "balance-convert-check", 0, plan);
            var after = yield query_btrfs_allocation (block);
            var fields = output.split (" ");
            uint64 workspace = 0;
            if (fields.length != 3 || fields[0].length != 64 ||
                !(fields[1] == "standard" || fields[1] == "reduce") ||
                !uint64.try_parse (fields[2], out workspace) || workspace == 0)
                throw new IOError.INVALID_DATA ("The helper returned an invalid conversion assessment.");
            if (!current.same_members (after) || !current.same_allocations (after))
                throw new IOError.BUSY ("Allocation or membership changed during review. Reassess the conversion.");
            plan.token = fields[0];
            plan.reduces_redundancy = fields[1] == "reduce";
            plan.workspace = workspace;
            return plan;
        }

        private HashTable<string, bool> quota_monitors = new HashTable<string, bool> (str_hash, str_equal);

        internal async BtrfsQuotaStatus query_btrfs_quota (StorageBlock block, string identity) throws Error {
            var observed = yield btrfs_quota_request (block, identity, "quota-status");
            if (observed.running && quota_monitors.add (observed.uuid))
                monitor_btrfs_quota.begin (block, identity, observed);
            return observed;
        }

        private async void monitor_btrfs_quota (StorageBlock block, string identity, BtrfsQuotaStatus observed) {
            string uuid = observed.uuid;
            var job = jobs.begin ("Btrfs quota rescan", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            bool locked = false;
            try {
                while (observed.running) {
                    if (!locked) {
                        StorageBlock[] members = {};
                        foreach (var member in snapshot.blocks.get_values ())
                            if (member.type_id == "btrfs" && member.uuid == uuid && member.available)
                                members += member;
                        try {
                            locks.acquire_members (block, members, snapshot.dependencies);
                            locked = true;
                        } catch (IOError.BUSY error) {
                            // Keep observing a kernel rescan while another job owns the lock.
                        }
                    }
                    jobs.phase (job, StorageJobState.RUNNING, observed.accounting_label ());
                    Timeout.add_seconds (2, () => {
                        monitor_btrfs_quota.callback ();
                        return Source.REMOVE;
                    });
                    yield;
                    observed = yield btrfs_quota_request (block, identity, "quota-status");
                }
                outcome.successful = observed.mode == BtrfsQuotaMode.QGROUP && !observed.inconsistent;
                outcome.summary = outcome.successful ? "Quota rescan completed. Accounting is consistent." :
                    "Quota rescan stopped without verified consistent accounting.";
            } catch (Error error) {
                outcome.fail ("Quota rescan state is unknown", error);
                outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
            } finally {
                if (locked) locks.release (block);
                quota_monitors.remove (uuid);
                jobs.finish (job, outcome);
            }
        }

        internal async BtrfsQuotaStatus change_btrfs_quota (StorageBlock block, string identity,
            BtrfsQuotaStatus reviewed, string action, string id = "", string value = "") throws Error {
            if (!(action in new string[] { "quota-enable", "quota-enable-simple", "quota-disable",
                "quota-rescan-start", "qgroup-create", "qgroup-delete", "qgroup-assign", "qgroup-unassign",
                "qgroup-referenced-limit", "qgroup-exclusive-limit" }))
                throw new IOError.INVALID_ARGUMENT ("Invalid quota action.");
            var observed = yield btrfs_quota_request (block, identity, action, reviewed, id, value);
            if (observed.running && quota_monitors.add (observed.uuid))
                monitor_btrfs_quota.begin (block, identity, observed);
            return observed;
        }

        private async BtrfsQuotaStatus btrfs_quota_request (StorageBlock block, string identity,
            string action, BtrfsQuotaStatus? reviewed = null, string id = "", string value = "") throws Error {
            bool write = reviewed != null;
            synchronize ();
            var proxy = require_volume (block, "Filesystem.BTRFS");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 count = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (creation_identity_changed (block, identity) || mounts.length != 1 ||
                !Uuid.string_is_valid (uuid) || count == 0 || count > 64 || block.number == 0 ||
                (write && reviewed.uuid != uuid))
                throw new IOError.NOT_FOUND ("A stable Btrfs filesystem, mount and member set are required.");
            string path = write ? BTRFS_DEFAULT_HELPER : BTRFS_STATUS_HELPER;
            if (!FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (path, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("Install the authorized Btrfs quota helpers.");

            StorageBlock[] members = {};
            string[] member_identities = {};
            foreach (var member in snapshot.blocks.get_values ()) {
                if (member.type_id != "btrfs" || member.uuid != uuid || !member.available) continue;
                if (write) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    if (member.read_only || safety.system_critical || safety.unknown_dependencies || safety.active_dependents)
                        throw new IOError.BUSY ("A Btrfs member is protected or has unresolved dependencies.");
                }
                members += member;
                if (write) member_identities += modification_identity (member);
            }
            if (members.length != count)
                throw new IOError.NOT_SUPPORTED ("The complete Btrfs member set is required.");

            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", path, action,
                mounts[0], uuid, block.number.to_string (), count.to_string () };
            StorageJob? job = null;
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            if (write) {
                argv += reviewed.token;
                if (id != "") argv += id;
                if (value != "") argv += value;
                locks.acquire_members (block, members, snapshot.dependencies);
                job = jobs.begin ("Btrfs quota configuration", block, snapshot.dependencies);
            }
            bool dispatched = false;
            try {
                if (write) {
                    foreach (var member in members)
                        yield KernelStorageSafety.require_no_holders (member, lifetime);
                    jobs.phase (job, StorageJobState.RUNNING, "Authorizing and verifying the quota change");
                }
                lifetime.set_error_if_cancelled ();
                synchronize ();
                if (creation_identity_changed (block, identity) ||
                    !(mounts[0] in (block.filesystem?.mounts ?? new string[0])))
                    throw new IOError.NOT_FOUND ("The Btrfs filesystem or mount changed before authorization.");
                for (int i = 0; i < member_identities.length; i++) {
                    require_volume (members[i], "Block");
                    if (modification_identity (members[i]) != member_identities[i])
                        throw new IOError.NOT_FOUND ("A Btrfs member changed before authorization.");
                }

                var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                dispatched = true;
                string? output, diagnostic;
                yield helper.communicate_utf8_async (null, write ? null : lifetime, out output, out diagnostic);
                if (!helper.get_successful ()) {
                    int code = helper.get_if_exited () ? helper.get_exit_status () : -1;
                    if (code == 126) {
                        dispatched = false;
                        throw new IOError.CANCELLED ("Btrfs authorization was cancelled.");
                    }
                    if (code == 127) {
                        dispatched = false;
                        throw new IOError.PERMISSION_DENIED ("Btrfs authorization was denied.");
                    }
                    if (code == 3) outcome.completed ("Quota request dispatched");
                    if (code == 1) dispatched = false;
                    string detail = diagnostic?.strip () ?? "";
                    throw new IOError.FAILED (detail != "" ? detail : "Could not confirm Btrfs quota state.");
                }
                if (write) outcome.completed ("Kernel verified quota request");
                synchronize ();
                lifetime.set_error_if_cancelled ();
                if (creation_identity_changed (block, identity) || require_volume (block, "Filesystem.BTRFS") != proxy ||
                    proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                    proxy.get_cached_property ("num_devices")?.get_uint64 () != count)
                    throw new IOError.NOT_FOUND ("The Btrfs filesystem changed during quota inspection.");
                var observed = new BtrfsQuotaStatus (uuid, output ?? "");
                outcome.successful = true;
                outcome.summary = observed.mode_label () + " · " + observed.accounting_label ();
                outcome.actual_state = outcome.summary;
                return observed;
            } catch (Error error) {
                outcome.fail ("Could not confirm Btrfs quota operation", error);
                if (dispatched && write) {
                    if (!outcome.partial) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                    try {
                        var observed = yield query_btrfs_quota (block, identity);
                        outcome.actual_state = observed.mode_label () + " · " + observed.accounting_label ();
                    } catch (Error read_error) {
                        outcome.actual_state = "Quota state unknown · " + read_error.message;
                    }
                }
                throw error;
            } finally {
                if (job != null) {
                    jobs.finish (job, outcome);
                    locks.release (block);
                }
            }
        }

        internal async string btrfs_scrub (StorageBlock block, string identity, string action,
                                          uint64 scope = 0, string review = "") throws Error {
            bool inspect = action == "scrub-status" || action == "scrub-history";
            bool cancel = action == "scrub-cancel";
            bool repair = action == "scrub-repair";
            bool start = repair || action == "scrub-readonly";
            bool resume = action == "scrub-resume";
            if (!inspect && !cancel && !start && !resume)
                throw new IOError.INVALID_ARGUMENT ("Invalid Btrfs scrub request.");
            synchronize ();
            var proxy = require_volume (block, "Filesystem.BTRFS");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 count = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (creation_identity_changed (block, identity) || mounts.length != 1 ||
                !Uuid.string_is_valid (uuid) || count == 0 || block.number == 0)
                throw new IOError.NOT_FOUND ("A stable Btrfs mount and device identity are required.");

            string helper = inspect ? BTRFS_STATUS_HELPER : BTRFS_DEFAULT_HELPER;
            if (!FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (helper, FileTest.IS_EXECUTABLE) ||
                (!inspect && !cancel && !FileUtils.test ("/usr/bin/btrfs", FileTest.IS_EXECUTABLE)))
                throw new IOError.NOT_SUPPORTED ("The authorized Btrfs scrub backend is unavailable.");

            var lifetime = backend_lifetime;
            StorageBlock[] members = {};
            foreach (var member in snapshot.blocks.get_values ()) {
                if (member.type_id != "btrfs" || member.uuid != uuid || !member.available) continue;
                if (!inspect) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    var drive = member.physical_drive;
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents ||
                        ((repair || resume) && drive != null && (drive.smart_failing || drive.nvme_warnings.length > 0)))
                        throw new IOError.BUSY ("A Btrfs member is protected, failing or has unresolved dependencies.");
                }
                members += member;
            }
            if (members.length != count)
                throw new IOError.NOT_SUPPORTED ("The complete Btrfs member set is required.");

            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", helper,
                action, mounts[0], uuid, block.number.to_string (), count.to_string () };
            if (start) argv += scope.to_string ();
            if (!inspect) {
                if (review.length != 64)
                    throw new IOError.INVALID_DATA ("Refresh the verified Btrfs scrub review before continuing.");
                argv += review;
            }
            StorageJob? job = null;
            var result = new StorageOperationResult ();
            bool dispatched = false;
            uint progress_timer = 0;
            bool polling = false;
            if (start || resume) {
                locks.acquire_members (block, members, snapshot.dependencies);
                job = jobs.begin ("Btrfs scrub", block, snapshot.dependencies);
            }
            try {
                if (job != null) {
                    foreach (var member in members)
                        yield KernelStorageSafety.require_no_holders (member, lifetime);
                    jobs.phase (job, StorageJobState.RUNNING, "Waiting for scrub and verifying the result");
                }
                lifetime.set_error_if_cancelled ();
                if (creation_identity_changed (block, identity) || !(mounts[0] in (block.filesystem?.mounts ?? new string[0])))
                    throw new IOError.BUSY ("The Btrfs mount changed before scrub dispatch.");
                var process = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                dispatched = true;
                if (job != null) {
                    progress_timer = Timeout.add_seconds (2, () => {
                        if (!polling) {
                            polling = true;
                            btrfs_scrub.begin (block, identity, "scrub-status", 0, "", (object, task) => {
                                polling = false;
                                try {
                                    var report = new BtrfsScrubReport (btrfs_scrub.end (task));
                                    if (progress_timer != 0 && report.state == BtrfsScrubState.RUNNING)
                                        jobs.progress (job, report.progress_label (), 0, false);
                                } catch (Error error) {
                                    // The worker still supplies the independently verified terminal result.
                                }
                            });
                        }
                        return Source.CONTINUE;
                    });
                }
                string? output, diagnostic;
                yield process.communicate_utf8_async (null, inspect ? lifetime : null, out output, out diagnostic);
                if (!process.get_successful ()) {
                    if (process.get_if_exited () && (process.get_exit_status () == 126 || process.get_exit_status () == 127)) {
                        dispatched = false;
                        throw new IOError.PERMISSION_DENIED ("Btrfs authorization was cancelled or denied.");
                    }
                    throw new IOError.FAILED (diagnostic?.strip () ?? "The scrub backend did not return a result.");
                }
                synchronize ();
                lifetime.set_error_if_cancelled ();
                if (creation_identity_changed (block, identity) ||
                    require_volume (block, "Filesystem.BTRFS") != proxy ||
                    proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                    proxy.get_cached_property ("num_devices")?.get_uint64 () != count)
                    throw new IOError.NOT_FOUND ("The Btrfs identity changed during scrub.");
                if (job != null) {
                    var report = new BtrfsScrubReport (output ?? "");
                    result.summary = report.summary ();
                    result.successful = report.state == BtrfsScrubState.CLEAN || report.state == BtrfsScrubState.CORRECTED;
                    if (report.state == BtrfsScrubState.CANCELLED) result.status = StorageOperationStatus.CANCELLED;
                    else if (!result.successful) result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    yield refresh ();
                }
                return output ?? "";
            } catch (Error error) {
                result.fail ("Could not confirm Btrfs scrub", error);
                if (dispatched) result.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                if (progress_timer != 0) {
                    Source.remove (progress_timer);
                    progress_timer = 0;
                }
                if (job != null) {
                    jobs.finish (job, result);
                    locks.release (block);
                }
            }
        }

        internal async string btrfs_maintenance (StorageBlock block, string identity, string action, uint usage,
            BtrfsConversionPlan? plan = null, bool confirm_reduction = false) throws Error {
            bool convert = action == "balance-convert" || (action == "balance-resume" && plan != null);
            bool review = action == "balance-convert-check" || action == "balance-convert-resume-check";
            bool conversion_status = action == "balance-convert-status";
            if ((convert || review) && (plan == null || (convert &&
                (plan.token == "" || plan.reduces_redundancy != confirm_reduction))))
                throw new IOError.INVALID_ARGUMENT ("A reviewed and confirmed conversion plan is required.");
            bool start = action == "balance-data" || action == "balance-metadata";
            bool long_running = start || convert || action == "balance-resume";
            bool status = action == "balance-status" || conversion_status;
            if ((!long_running && !status && !review && action != "balance-pause" && action != "balance-cancel") || usage > 100)
                throw new IOError.INVALID_ARGUMENT ("Invalid Btrfs maintenance operation.");
            synchronize ();
            var proxy = require_volume (block, "Filesystem.BTRFS");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 count = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            string[] mounts = block.filesystem?.mounts ?? new string[0];
            if (creation_identity_changed (block, identity) || mounts.length != 1 ||
                !Uuid.string_is_valid (uuid) || count == 0 || block.number == 0)
                throw new IOError.NOT_FOUND ("A stable Btrfs mount and device identity are required.");
            if (!FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (BTRFS_DEFAULT_HELPER, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("Install the authorized Btrfs helper to manage Btrfs maintenance.");
            StorageBlock[] members = {};
            foreach (var member in snapshot.blocks.get_values ()) {
                if (member.type_id != "btrfs" || member.uuid != uuid || !member.available) continue;
                if ((convert || review) && member.physical_drive?.smart_failing == true)
                    throw new IOError.FAILED ("A member reports failing SMART health. Review Replace Btrfs Device.");
                if (!status) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    if (member.read_only || safety.system_critical || safety.unknown_dependencies || safety.active_dependents)
                        throw new IOError.BUSY ("A Btrfs member is protected or has unresolved dependencies.");
                }
                members += member;
            }
            if (members.length != count)
                throw new IOError.NOT_SUPPORTED ("The complete Btrfs member set is required.");

            string helper_path = review || conversion_status ? BTRFS_STATUS_HELPER : BTRFS_DEFAULT_HELPER;
            if (!FileUtils.test (helper_path, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("Install the Btrfs status helper to assess profile conversion.");
            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", helper_path,
                action, mounts[0], uuid, block.number.to_string (), count.to_string () };
            if (start) argv += usage.to_string ();
            if (convert || review) {
                if (plan.reviewed.uuid != uuid || plan.reviewed.member_count != count)
                    throw new IOError.BUSY ("The reviewed filesystem identity changed.");
                foreach (var member in members) {
                    bool matched = false;
                    foreach (var reviewed in plan.reviewed.members)
                        if (reviewed.number == member.number && member.number != 0) matched = true;
                    if (!matched)
                        throw new IOError.BUSY ("UDisks reports a changed Btrfs member set.");
                }
                argv += plan.data.argument ();
                argv += plan.metadata.argument ();
                if (convert) {
                    argv += plan.token;
                    argv += confirm_reduction ? "reduce" : "standard";
                }
            }
            var lifetime = backend_lifetime;
            StorageJob? job = null;
            if (review) plan.hold_review (locks, block, members, snapshot.dependencies, lifetime);
            if (long_running) {
                if (convert) {
                    if (!plan.take_review (locks, block))
                        throw new IOError.BUSY ("The conversion review expired. Review the current filesystem again.");
                } else {
                    locks.acquire_members (block, members, snapshot.dependencies);
                }
                job = jobs.begin (convert ? "Btrfs profile conversion" : "Btrfs balance", block, snapshot.dependencies);
                jobs.phase (job, StorageJobState.RUNNING, convert ? "Converting Btrfs allocation profiles" :
                    "Waiting for the Btrfs kernel operation");
            }
            var outcome = new StorageOperationResult ();
            bool dispatched = false;
            try {
                if (convert || review) {
                    foreach (var member in members)
                        yield KernelStorageSafety.require_no_holders (member, lifetime);
                    var current = yield query_btrfs_allocation (block);
                    if (!plan.reviewed.same_members (current) || !plan.reviewed.same_allocations (current) ||
                        !(mounts[0] in (block.filesystem?.mounts ?? new string[0])))
                        throw new IOError.BUSY ("The reviewed Btrfs mount, membership or allocation changed.");
                }
                lifetime.set_error_if_cancelled ();
                var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                dispatched = true;
                string? output, diagnostic;
                yield helper.communicate_utf8_async (null, status || review ? lifetime : null, out output, out diagnostic);
                if (!helper.get_successful ()) {
                    if (helper.get_if_exited () && (helper.get_exit_status () == 126 || helper.get_exit_status () == 127)) {
                        dispatched = false;
                        throw new IOError.PERMISSION_DENIED ("Btrfs authorization was cancelled or denied.");
                    }
                    string detail = diagnostic?.strip () ?? "";
                    throw new IOError.FAILED (detail != "" ? detail : "Btrfs maintenance did not complete.");
                }
                if (review || conversion_status) return (output ?? "").strip ();
                var fields = (output ?? "").strip ().split (" ");
                uint64 completed = 0, considered = 0, expected = 0;
                if (fields.length != 4 || !(fields[0] in new string[] { "idle", "running", "paused", "completed", "interrupted", "incomplete" }) ||
                    !uint64.try_parse (fields[1], out completed) || !uint64.try_parse (fields[2], out considered) ||
                    !uint64.try_parse (fields[3], out expected))
                    throw new IOError.INVALID_DATA ("The Btrfs helper returned invalid maintenance status.");
                synchronize ();
                lifetime.set_error_if_cancelled ();
                if (creation_identity_changed (block, identity) || require_volume (block, "Filesystem.BTRFS") != proxy ||
                    proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                    proxy.get_cached_property ("num_devices")?.get_uint64 () != count)
                    throw new IOError.NOT_FOUND ("The Btrfs filesystem changed during maintenance.");
                outcome.summary = "Balance %s · %s completed · %s examined · %s expected chunks".printf (
                    fields[0], completed.to_string (), considered.to_string (), expected.to_string ());
                outcome.successful = fields[0] == "completed";
                if (plan != null && long_running) {
                    yield refresh ();
                    var observed = yield query_btrfs_allocation (block);
                    var terminal = new BtrfsConversionStatus (yield btrfs_maintenance (
                        block, identity, "balance-convert-status", 0));
                    outcome.successful = fields[0] == "completed" && terminal.state == "idle" &&
                        plan.verified (observed);
                    outcome.summary = outcome.successful ? "Profile conversion completed and allocation verified." :
                        fields[0] == "paused" ? "Conversion paused. Review current allocation before resuming." :
                        fields[0] == "interrupted" ? "Conversion interrupted. Some chunks may already have moved." :
                        "Conversion ended with an unverified or incomplete allocation. Reassess before continuing.";
                    if (!outcome.successful && plan.reviewed.same_members (observed)) {
                        outcome.summary += "\nData: %s · Metadata: %s · System: %s".printf (
                            plan.category_verified (observed, BtrfsAllocationKind.DATA) ? "matches review" : "needs review",
                            plan.category_verified (observed, BtrfsAllocationKind.METADATA) ? "matches review" : "needs review",
                            plan.category_verified (observed, BtrfsAllocationKind.SYSTEM) ? "matches review" : "needs review");
                    }
                }
                if (long_running && !outcome.successful) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                return outcome.summary;
            } catch (Error error) {
                if (review) plan.release_review ();
                outcome.fail ("Could not confirm the Btrfs maintenance outcome", error);
                if (dispatched && long_running) {
                    outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                    if (convert) {
                        try { yield refresh (); }
                        catch (Error refresh_error) {}
                    }
                }
                throw error;
            } finally {
                if (job != null) {
                    jobs.finish (job, outcome);
                    locks.release (block);
                }
            }
        }

        internal bool can_select_btrfs_removal_member (StorageBlock filesystem, StorageBlock member) {
            return filesystem != member && filesystem.uuid != "" && filesystem.uuid == member.uuid &&
                filesystem.number != member.number && member.number != 0 && member.type_id == "btrfs" &&
                member.available && !member.read_only && !member.system_hint && member.filesystem?.mounted != true &&
                member.mount_configurations.length == 0 && member.encryption_configurations.length == 0;
        }

        private async void check_removable_btrfs_member (StorageBlock filesystem, StorageBlock member,
            string uuid, uint64 count, Cancellable token) throws Error {
            string[] mounts = filesystem.filesystem?.mounts ?? new string[0];
            if (mounts.length != 1 || !FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (BTRFS_DEFAULT_HELPER, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("An authorized Btrfs allocation check and one verified mount are required.");
            string[] argv = { "/usr/bin/pkexec", "--disable-internal-agent", BTRFS_DEFAULT_HELPER,
                "check-removable-member", mounts[0], uuid, filesystem.number.to_string (), member.number.to_string (), count.to_string () };
            var helper = new Subprocess.newv (argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
            string? diagnostic;
            yield helper.communicate_utf8_async (null, token, null, out diagnostic);
            if (!helper.get_successful ())
                throw new IOError.NOT_SUPPORTED (diagnostic?.strip () ?? "Could not verify safe Btrfs member removal.");
        }
        internal async void change_btrfs_member (StorageBlock filesystem, StorageBlock member,
            string filesystem_identity, string member_identity, bool remove = false) throws Error {
            synchronize ();
            var proxy = require_volume (filesystem, "Filesystem.BTRFS");
            require_volume (member, "Block");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 count = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            if (!has_btrfs_subvolumes (filesystem) || !Uuid.string_is_valid (uuid) || count == 0 ||
                count == uint64.MAX || (remove ? !can_select_btrfs_removal_member (filesystem, member) || count < 2 :
                    !can_use_group_member (member)))
                throw new IOError.NOT_SUPPORTED ("A verified mounted Btrfs filesystem and unused member are required.");
            StorageBlock[] members = {};
            string[] identities = {};
            uint64[] numbers = {};
            foreach (var candidate in snapshot.blocks.get_values ()) {
                if (!candidate.available || candidate.type_id != "btrfs" || candidate.uuid != uuid) continue;
                members += candidate;
                identities += modification_identity (candidate);
                numbers += candidate.number;
            }
            if (members.length != count)
                throw new IOError.BUSY ("UDisks could not identify every member of this Btrfs filesystem.");
            uint64 new_number = member.number;
            StorageBlock[] locked = members;
            locked += member;
            locks.acquire_members (filesystem, locked, snapshot.dependencies);
            var job = jobs.begin (remove ? "Remove Btrfs member" : "Add Btrfs member", filesystem, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the Btrfs filesystem and selected device");
                foreach (var existing in members) {
                    var safety = StorageSafetyService.assess (existing, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || existing.read_only)
                        throw new IOError.BUSY ("A Btrfs member is protected or has unresolved dependencies.");
                }
                yield KernelStorageSafety.require_idle (member, lifetime);
                if (remove) yield check_removable_btrfs_member (filesystem, member, uuid, count, lifetime);
                synchronize ();
                if (creation_identity_changed (filesystem, filesystem_identity) ||
                    creation_identity_changed (member, member_identity) ||
                    (remove ? !can_select_btrfs_removal_member (filesystem, member) : !can_use_group_member (member)) ||
                    require_volume (filesystem, "Filesystem.BTRFS") != proxy || !has_btrfs_subvolumes (filesystem) ||
                    proxy.get_cached_property ("uuid")?.get_string () != uuid ||
                    proxy.get_cached_property ("num_devices")?.get_uint64 () != count)
                    throw new IOError.NOT_FOUND ("The Btrfs filesystem or candidate device changed.");
                for (int i = 0; i < members.length; i++)
                    if (creation_identity_changed (members[i], identities[i]))
                        throw new IOError.NOT_FOUND ("A Btrfs member changed after confirmation.");
                jobs.phase (job, StorageJobState.RUNNING, remove ? "Relocating chunks and removing the Btrfs member" : "Adding the unused device to Btrfs");
                dispatched = true;
                yield call_tracked_method (job, proxy, remove ? "RemoveDevice" : "AddDevice",
                    new Variant ("(o@a{sv})", member.path, new Variant ("a{sv}", null)), lifetime);
                for (int attempt = 0; attempt < 100; attempt++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    var current = snapshot.blocks.lookup (member.path);
                    bool verified = proxy.get_cached_property ("uuid")?.get_string () == uuid &&
                        proxy.get_cached_property ("num_devices")?.get_uint64 () == (remove ? count - 1 : count + 1) &&
                        current != null && current.available && current.number == new_number &&
                        (remove ? current.uuid != uuid : current.type_id == "btrfs" && current.uuid == uuid);
                    for (int i = 0; i < members.length; i++) {
                        if (remove && members[i] == member) continue;
                        var existing = snapshot.blocks.lookup (members[i].path);
                        verified &= existing != null && existing.available && existing.number == numbers[i] &&
                            existing.type_id == "btrfs" && existing.uuid == uuid;
                    }
                    if (verified) {
                        outcome.successful = true;
                        outcome.summary = remove ? "Btrfs member removed" : "Btrfs member added";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the Btrfs member change.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the Btrfs member change", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (filesystem);
            }
        }

        internal async void set_btrfs_default (StorageBlock block, uint id, uint confirmed_default,
            string confirmed_identity) throws Error {
            var proxy = require_volume (block, "Filesystem.BTRFS");
            if (!has_btrfs_subvolumes (block))
                throw new IOError.NOT_SUPPORTED ("Changing the default requires a mounted Btrfs filesystem.");
            string uuid = proxy.get_cached_property ("uuid")?.get_string () ?? "";
            uint64 expected_members = proxy.get_cached_property ("num_devices")?.get_uint64 () ?? 0;
            StorageBlock[] members = {};
            foreach (var candidate in snapshot.blocks.get_values ())
                if (candidate.type_id == "btrfs" && candidate.uuid == uuid && candidate.available)
                    members += candidate;
            if (!Uuid.string_is_valid (uuid) || expected_members == 0 || members.length != expected_members)
                throw new IOError.NOT_SUPPORTED ("UDisks could not identify all members of this Btrfs filesystem.");
            locks.acquire_members (block, members, snapshot.dependencies);
            var job = jobs.begin ("Set Btrfs default subvolume", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the filesystem and subvolume");
                string[] member_identities = {};
                foreach (var member in members) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || member.read_only)
                        throw new IOError.BUSY ("A filesystem member or its dependencies prevent changing the default subvolume.");
                    member_identities += modification_identity (member);
                }
                bool native = yield has_native_btrfs_default (proxy, lifetime);
                uint current = native ? yield read_btrfs_default (block, proxy, true, lifetime) : confirmed_default;
                var rows = yield read_btrfs_subvolumes (proxy, false, lifetime);
                bool found = id == 5;
                for (size_t i = 0; i < rows.n_children (); i++)
                    found |= rows.get_child_value (i).get_child_value (0).get_uint64 () == id;
                synchronize ();
                if (!found || current != confirmed_default || modification_identity (block) != confirmed_identity ||
                    require_volume (block, "Filesystem.BTRFS") != proxy || !has_btrfs_subvolumes (block))
                    throw new IOError.NOT_FOUND ("The filesystem or subvolume selection changed.");
                if (proxy.get_cached_property ("num_devices")?.get_uint64 () != expected_members)
                    throw new IOError.NOT_FOUND ("The Btrfs member count changed after confirmation.");
                for (int i = 0; i < members.length; i++) {
                    require_volume (members[i], "Block");
                    if (modification_identity (members[i]) != member_identities[i])
                        throw new IOError.NOT_FOUND ("A Btrfs member changed after confirmation.");
                }
                jobs.phase (job, StorageJobState.RUNNING, "Updating the default Btrfs subvolume");
                dispatched = true;
                uint actual;
                if (native) {
                    yield call_tracked_method (job, proxy, "SetDefaultSubvolumeID",
                        new Variant ("(u@a{sv})", id, new Variant ("a{sv}", null)), lifetime);
                    actual = yield read_btrfs_default (block, proxy, true, lifetime);
                } else {
                    actual = yield run_btrfs_default_helper (block, proxy, true, confirmed_default, id, lifetime);
                }
                if (actual != id)
                    throw new IOError.FAILED ("UDisks did not confirm the requested default subvolume.");
                synchronize ();
                outcome.successful = true;
                outcome.summary = "Default Btrfs subvolume updated";
            } catch (Error error) {
                outcome.fail ("Could not confirm the Btrfs default subvolume", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }
        internal bool can_set_raid_running (StorageBlock block, bool running) {
            var raid = running ? block.raid_membership : block.raid;
            var proxy = raid != null ? manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy : null;
            if (!block.available || block.system_hint || proxy == null ||
                proxy.get_cached_property ("Running")?.get_boolean () != !running)
                return false;
            if (!running) return true;
            uint expected = proxy.get_cached_property ("NumDevices")?.get_uint32 () ?? 0;
            int known = 0;
            foreach (var candidate in snapshot.blocks.get_values ())
                if (candidate.available && candidate.raid_membership == raid) known++;
            return raid.degraded == 0 && expected > 0 && known >= expected;
        }
        internal bool can_start_degraded_raid (StorageBlock member) {
            var array = member.raid_membership;
            var proxy = array != null ? manager?.get_interface (array.path, PREFIX + "MDRaid") as DBusProxy : null;
            if (!member.available || member.system_hint || member.read_only || member.type_id != "linux_raid_member" ||
                member.number == 0 || array == null || array.uuid == "" || proxy == null ||
                proxy.get_cached_property ("Running")?.get_boolean () != false)
                return false;
            int found = 0;
            foreach (var candidate in snapshot.blocks.get_values ()) {
                if (candidate.raid_path == array.path) return false;
                if (candidate.raid_membership == array) found++;
            }
            uint expected = array.expected_members;
            if (expected > 4096 || found == 0 || found >= expected) return false;
            switch (array.level) {
            case "raid1": return expected >= 2;
            case "raid4":
            case "raid5": return expected >= 3 && expected - found == 1;
            case "raid6": return expected >= 4 && expected - found <= 2;
            case "raid10": return expected >= 4;
            default: return false;
            }
        }

        private async MdRaidSuperblock[] inspect_degraded_assembly (StorageRaid raid,
            StorageBlock[] members, uint expected, Cancellable token) throws Error {
            string level = raid.level;
            string uuid = raid.uuid;
            MdRaidSuperblock[] records = {};
            var slots = new bool[expected];
            var member_uuids = new HashTable<string, string> (str_hash, str_equal);
            int level_number = int.parse (level.substring (4));
            foreach (var member in members) {
                var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                if (member.system_hint || member.read_only || member.type_id != "linux_raid_member" ||
                    safety.mounted || safety.system_critical || safety.unknown_dependencies)
                    throw new IOError.BUSY ("A surviving member is protected or cannot be verified.");
                yield KernelStorageSafety.require_idle (member, token);
                int fd = yield open_block (member, "r", DIRECT_IO, token);
                MdRaidSuperblock? metadata;
                try { metadata = MdRaidSuperblock.inspect (fd); }
                finally { Posix.close (fd); }
                if (metadata == null || !metadata.usable () || metadata.uuid != uuid ||
                    metadata.level != level_number || metadata.expected != expected ||
                    slots[metadata.slot] || member_uuids.contains (metadata.member_uuid) ||
                    (records.length > 0 && (!metadata.same_geometry (records[0]) || metadata.events != records[0].events)))
                    throw new IOError.NOT_SUPPORTED ("The surviving RAID superblocks do not establish clean, consistent array geometry and event counters.");
                slots[metadata.slot] = true;
                member_uuids.insert (metadata.member_uuid, metadata.member_uuid);
                records += metadata;
            }
            int[] missing = {};
            for (int slot = 0; slot < expected; slot++)
                if (!slots[slot]) missing += slot;
            if (!MdRaidTopology.recoverable_slots (level, records[0].layout.to_string (), expected, missing))
                throw new IOError.NOT_SUPPORTED ("The surviving slots do not cover every required data region for this RAID layout.");
            return records;
        }

        internal async void set_raid_running (StorageBlock block, bool running, string identity,
            bool degraded = false) throws Error {
            synchronize ();
            require_volume (block, "Block");
            if (degraded ? !running || !can_start_degraded_raid (block) : !can_set_raid_running (block, running))
                throw new IOError.NOT_SUPPORTED ("This RAID array is unavailable or in a different state.");
            var raid = running ? block.raid_membership : block.raid;
            var proxy = manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (uuid == "" || proxy == null)
                throw new IOError.NOT_SUPPORTED ("The RAID array identity is unavailable.");

            StorageBlock[] members = {};
            string[] member_identities = {};
            foreach (var member in snapshot.blocks.get_values ()) {
                if (member.raid_membership != raid) continue;
                members += member;
                member_identities += modification_identity (member);
            }
            uint count = proxy.get_cached_property ("NumDevices")?.get_uint32 () ?? 0;
            if (count == 0 || (!degraded && members.length < count))
                throw new IOError.BUSY ("The RAID member set could not be verified.");
            locks.acquire_members (block, members, snapshot.dependencies);
            var job = jobs.begin (degraded ? "Start degraded RAID array" : running ? "Start RAID array" : "Stop RAID array",
                block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the array and its members");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || safety.mounted ||
                    (!running && safety.active_dependents))
                    throw new IOError.BUSY ("The RAID array is in use or supports the running system.");
                MdRaidSuperblock[] reviewed_metadata = {};
                if (degraded)
                    reviewed_metadata = yield inspect_degraded_assembly (raid, members, count, lifetime);
                if (!running) {
                    if (proxy.get_cached_property ("SyncAction")?.get_string () != "idle" &&
                        (proxy.get_cached_property ("SyncAction")?.get_string () ?? "") != "")
                        throw new IOError.BUSY ("Wait for the RAID maintenance operation to finish before stopping the array.");
                    foreach (var dependent in snapshot.dependencies.descendants (block)) {
                        var volume = dependent as StorageBlock;
                        if (volume != null) yield KernelStorageSafety.require_idle (volume, lifetime);
                    }
                }
                synchronize ();
                for (int i = 0; i < members.length; i++) {
                    require_volume (members[i], "Block");
                    if (members[i].system_hint || members[i].raid_membership != raid ||
                        modification_identity (members[i]) != member_identities[i])
                        throw new IOError.BUSY ("A RAID member changed or is protected.");
                }
                int current_members = 0;
                foreach (var candidate in snapshot.blocks.get_values ())
                    if (candidate.raid_membership == raid) current_members++;
                if (current_members != members.length || proxy.get_cached_property ("NumDevices")?.get_uint32 () != count ||
                    (degraded ? !can_start_degraded_raid (block) || identity == "" ||
                        storage_membership_identity (block, true) != identity :
                        !can_set_raid_running (block, running) || modification_identity (block) != identity) ||
                    manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy || raid.uuid != uuid ||
                    (degraded && reviewed_metadata[0].level != int.parse (raid.level.substring (4))))
                    throw new IOError.NOT_FOUND ("The selected RAID array changed after confirmation.");
                if (degraded && (raid.level == "raid4" || raid.level == "raid5" || raid.level == "raid6") &&
                    !MdRaidTopology.dirty_degraded_disabled ())
                    throw new IOError.NOT_SUPPORTED ("Kernel policy for dirty degraded parity assembly could not be verified as disabled.");
                jobs.phase (job, StorageJobState.RUNNING, running ? "Starting the array" : "Stopping the array");
                dispatched = true;
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (degraded) options.add ("{sv}", "start-degraded", new Variant.boolean (true));
                yield call_tracked_method (job, proxy, running ? "Start" : "Stop",
                    new Variant ("(@a{sv})", options.end ()), lifetime);
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    if (proxy.get_cached_property ("UUID")?.get_string () != uuid ||
                        manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy)
                        break;
                    bool exposed = false;
                    foreach (var candidate in snapshot.blocks.get_values ())
                        exposed |= candidate.available && candidate.raid_path == raid.path;
                    bool recovered = !degraded;
                    if (degraded && raid.kernel != null && raid.topology != null) {
                        var metadata = reviewed_metadata[0];
                        recovered = raid.kernel.level == raid.level && raid.kernel.expected == count &&
                            raid.kernel.layout == metadata.layout.to_string () &&
                            raid.kernel.metadata == "1.%u".printf (metadata.version) &&
                            raid.degraded == count - members.length &&
                            raid.kernel.degraded == raid.degraded.to_string () &&
                            raid.topology.members.length == members.length && raid.kernel.verify_members (raid.topology);
                        for (int n = 0; recovered && n < members.length; n++) {
                            bool verified = false;
                            foreach (var row in raid.topology.members)
                                if (row.block == members[n] && row.slot == reviewed_metadata[n].slot &&
                                    row.synchronized_member () && row.known_states ())
                                    verified = true;
                            recovered = verified;
                        }
                    }
                    if (proxy.get_cached_property ("Running")?.get_boolean () == running && exposed == running && recovered) {
                        outcome.successful = true;
                        outcome.summary = degraded ? "RAID array started with reduced redundancy" :
                            running ? "RAID array started" : "RAID array stopped";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the requested RAID state.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the RAID state change", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        internal string storage_membership_identity (StorageBlock member, bool raid, bool include_dependents = true) {
            StorageDevice? group = raid ? (StorageDevice?) member.raid_membership : member.volume_group;
            if (group == null) return "";
            var proxy = manager?.get_interface (group.path, PREFIX + (raid ? "MDRaid" : "VolumeGroup")) as DBusProxy;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (uuid == "") return "";
            var records = new GenericArray<string> ();
            foreach (var candidate in snapshot.blocks.get_values ()) {
                if ((raid && candidate.raid_membership == group) || (!raid && candidate.volume_group == group))
                    records.add (modification_identity (candidate, include_dependents));
            }
            records.sort ((a, b) => strcmp (a, b));
            var result = new StringBuilder (uuid);
            foreach (var record in records) result.append_c ('\n').append (record);
            return result.str;
        }

        internal bool can_delete_stopped_raid (StorageBlock member) {
            var array = member.raid_membership;
            var proxy = array != null ? manager?.get_interface (array.path, PREFIX + "MDRaid") as DBusProxy : null;
            return member.available && !member.read_only && !member.system_hint &&
                proxy?.get_cached_property ("Running")?.get_boolean () == false;
        }

        internal async void delete_stopped_raid (StorageBlock member, string identity) throws Error {
            synchronize ();
            require_volume (member, "Block");
            var array = member.raid_membership;
            var proxy = array != null ? manager?.get_interface (array.path, PREFIX + "MDRaid") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            uint expected = proxy?.get_cached_property ("NumDevices")?.get_uint32 () ?? 0;
            if (array == null || proxy == null || uuid == "" || expected == 0 || !can_delete_stopped_raid (member))
                throw new IOError.NOT_SUPPORTED ("Stop the array before deleting its RAID metadata.");
            StorageBlock[] members = {};
            string[] identities = {};
            uint64[] numbers = {};
            foreach (var block in snapshot.blocks.get_values ()) {
                if (block.raid_membership != array) continue;
                members += block;
                identities += modification_identity (block);
                numbers += block.number;
            }
            if (members.length < expected)
                throw new IOError.BUSY ("One or more RAID members are missing.");
            locks.acquire_members (member, members, snapshot.dependencies);
            var job = jobs.begin ("Delete RAID array", member, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking RAID members and persistent configuration");
                foreach (var block in members) {
                    var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.mounted ||
                        block.read_only || block.mount_configurations.length != 0 || block.encryption_configurations.length != 0)
                        throw new IOError.BUSY ("A RAID member is protected, mounted or configured for another use.");
                    yield KernelStorageSafety.require_idle (block, lifetime);
                }
                synchronize ();
                int live_members = 0;
                foreach (var block in snapshot.blocks.get_values ()) {
                    if (block.raid_path == array.path)
                        throw new IOError.BUSY ("The array still exposes an active block device.");
                    if (block.raid_membership == array) live_members++;
                }
                if (identity == "" || storage_membership_identity (member, true) != identity ||
                    live_members != members.length ||
                    manager?.get_interface (array.path, PREFIX + "MDRaid") != proxy ||
                    proxy.get_cached_property ("UUID")?.get_string () != uuid ||
                    proxy.get_cached_property ("ChildConfiguration")?.n_children () != 0 ||
                    proxy.get_cached_property ("NumDevices")?.get_uint32 () != expected ||
                    !can_delete_stopped_raid (member))
                    throw new IOError.BUSY ("The stopped array changed or has persistent configuration.");
                for (int i = 0; i < members.length; i++)
                    if (creation_identity_changed (members[i], identities[i]) || members[i].raid_membership != array)
                        throw new IOError.NOT_FOUND ("A RAID member changed after confirmation.");
                jobs.phase (job, StorageJobState.RUNNING, "Deleting RAID metadata from the verified members");
                dispatched = true;
                yield call_tracked_method (job, proxy, "Delete",
                    new Variant ("(@a{sv})", new Variant ("a{sv}", null)), lifetime);
                for (int attempt = 0; attempt < 100; attempt++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    bool verified = available () && !snapshot.advanced.contains (array.path);
                    foreach (var item in snapshot.advanced.get_values ()) {
                        if (!(item is StorageRaid)) continue;
                        var live = manager?.get_interface (item.path, PREFIX + "MDRaid") as DBusProxy;
                        if (live?.get_cached_property ("UUID")?.get_string () == uuid) verified = false;
                    }
                    for (int i = 0; i < members.length; i++) {
                        var current = snapshot.blocks.lookup (members[i].path);
                        verified &= current != null && current.available && current.number == numbers[i] &&
                            current.raid_member_path == "/" && current.type_id != "linux_raid_member";
                    }
                    if (verified) {
                        outcome.successful = true;
                        outcome.summary = "RAID array deleted";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm that the array and member metadata were removed.");
            } catch (Error error) {
                outcome.fail ("Could not confirm RAID deletion", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (member);
            }
        }

        private static Variant? find_raid_member (DBusProxy proxy, string path) {
            var members = proxy.get_cached_property ("ActiveDevices");
            if (members == null || !members.is_of_type (new VariantType ("a(oiasta{sv})")))
                return null;
            for (size_t i = 0; i < members.n_children (); i++) {
                var row = members.get_child_value (i);
                if (row.get_child_value (0).get_string () == path) return row;
            }
            return null;
        }

        internal bool can_remove_inactive_raid_member (StorageBlock block) {
            var array = block.raid_membership;
            if (array == null || array.kernel?.action != "idle" || array.kernel?.writable () != true ||
                array.topology == null || !array.kernel.verify_members (array.topology)) return false;
            var proxy = manager?.get_interface (array.path, PREFIX + "MDRaid") as DBusProxy;
            if (proxy == null || proxy.get_cached_property ("Running")?.get_boolean () != true ||
                proxy.get_cached_property ("SyncAction")?.get_string () != "idle")
                return false;
            var member = find_raid_member (proxy, block.path);
            if (member == null || member.get_child_value (1).get_int32 () != -1) return false;
            var states = member.get_child_value (2).get_strv ();
            return !("in_sync" in states) && ("spare" in states || "faulty" in states);
        }

        internal bool can_add_raid_spare (StorageBlock block) {
            return block.available && !block.system_hint && !block.read_only &&
                block.raid?.kernel?.writable () == true && verified_raid_recovery (block.raid);
        }

        internal bool can_replace_missing_raid_member (StorageBlock anchor) {
            var array = anchor.raid;
            if (array == null || array.uuid == "" || !array.running || array.state != "idle" ||
                anchor.system_hint || anchor.read_only || array.topology == null ||
                array.degraded != array.topology.missing_slots.length ||
                array.kernel == null || array.kernel.action != "idle" || !array.kernel.writable () ||
                !array.kernel.native_metadata () || array.kernel.level != array.level ||
                array.kernel.expected != array.expected_members || array.kernel.degraded != array.degraded.to_string () ||
                array.kernel.component_sectors == 0)
                return false;
            if ((array.level == "raid4" || array.level == "raid5" || array.level == "raid6") &&
                array.kernel.state != "clean")
                return false;
            return array.topology.can_reconstruct (array.level, array.kernel.layout, array.expected_members) &&
                array.kernel.verify_members (array.topology);
        }

        private static bool eligible_raid_replacement (StorageRaid raid, StorageBlock target, string target_disk) {
            string target_sector;
            string observed_disk = MdRaidKernelState.physical_device (target, out target_sector);
            if (target_disk == "" || observed_disk != target_disk ||
                raid.kernel == null || raid.topology == null ||
                target.size / 512 < raid.kernel.component_sectors)
                return false;
            foreach (var member in raid.topology.members) {
                string sector;
                if (member.block == null || member.block.size == 0 || target.size < member.block.size)
                    return false;
                string disk = MdRaidKernelState.physical_device (member.block, out sector);
                if (disk == "" || disk == target_disk || sector != target_sector) return false;
            }
            return true;
        }

        internal bool can_select_raid_member (StorageBlock anchor, StorageBlock target, bool replacement) {
            if (!(replacement ? can_replace_missing_raid_member (anchor) : can_add_raid_spare (anchor)) ||
                !can_use_group_member (target) || has_backend_job_on (target.path))
                return false;
            string sector;
            string physical = MdRaidKernelState.physical_device (target, out sector);
            return eligible_raid_replacement (anchor.raid, target, physical);
        }

        private async void verify_reconstruction_metadata (string uuid, MdRaidKernelState kernel,
            MdRaidTopology topology, Cancellable token) throws Error {
            MdRaidSuperblock? baseline = null;
            var member_uuids = new HashTable<string, string> (str_hash, str_equal);
            foreach (var row in topology.members) {
                if (row.block == null)
                    throw new IOError.NOT_FOUND ("A surviving RAID member is unavailable.");
                int fd = yield open_block (row.block, "r", DIRECT_IO, token);
                MdRaidSuperblock? metadata;
                try { metadata = MdRaidSuperblock.inspect (fd); }
                finally { Posix.close (fd); }
                bool parity = kernel.level == "raid4" || kernel.level == "raid5" || kernel.level == "raid6";
                if (metadata == null || !metadata.active_member () || (parity && !metadata.usable ()) ||
                    metadata.uuid != uuid || metadata.slot != row.slot || metadata.expected != kernel.expected ||
                    metadata.level != int.parse (kernel.level.substring (4)) ||
                    metadata.layout.to_string () != kernel.layout || kernel.metadata != "1.%u".printf (metadata.version) ||
                    member_uuids.contains (metadata.member_uuid) ||
                    (baseline != null && (!metadata.same_geometry (baseline) || metadata.events != baseline.events))) {
                    string detail = metadata == null ? "metadata unreadable or invalid" :
                        "slot %u, metadata 1.%u, level %d, layout %u, members %u, events %s, features %u, clean %s".printf (
                            metadata.slot, metadata.version, metadata.level, metadata.layout, metadata.expected,
                            metadata.events.to_string (), metadata.features, (metadata.resync_offset == uint64.MAX).to_string ());
                    throw new IOError.NOT_SUPPORTED ("%s does not agree with the reviewed RAID geometry or event state (%s).".printf (
                        row.block.preferred, detail));
                }
                member_uuids.insert (metadata.member_uuid, metadata.member_uuid);
                baseline = metadata;
            }
        }

        internal async string change_raid_member (StorageBlock anchor, StorageBlock member, bool add,
            string anchor_identity, string member_identity, bool replacement = false, string review = "") throws Error {
            synchronize ();
            require_volume (anchor, "Block");
            require_volume (member, "Block");
            var array = add ? anchor.raid : member.raid_membership;
            var proxy = array != null ? manager?.get_interface (array.path, PREFIX + "MDRaid") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (array == null || anchor.raid != array || proxy == null || uuid == "" ||
                proxy.get_cached_property ("Running")?.get_boolean () != true ||
                proxy.get_cached_property ("SyncAction")?.get_string () != "idle")
                throw new IOError.NOT_SUPPORTED ("A running RAID array without active maintenance is required.");
            var live = proxy.get_cached_property ("ActiveDevices");
            if (live == null || !live.is_of_type (new VariantType ("a(oiasta{sv})")))
                throw new IOError.NOT_SUPPORTED ("UDisks did not publish the active member set.");
            if (replacement && (!add || review == "" || raid_review_identity (anchor) != review ||
                !can_replace_missing_raid_member (anchor)))
                throw new IOError.NOT_SUPPORTED ("The running array has no verified reconstruction plan.");
            if (add && !replacement && !can_add_raid_spare (anchor))
                throw new IOError.NOT_SUPPORTED ("A verified synchronized array is required to add a spare.");
            uint64 replacement_number = member.number;
            var reviewed_kernel = array.kernel;
            var reviewed_topology = array.topology;
            uint reviewed_degraded = array.degraded;
            string unused_sector;
            string target_disk = add ? MdRaidKernelState.physical_device (member, out unused_sector) : "";
            StorageBlock[] locked = { member };
            for (size_t i = 0; i < live.n_children (); i++) {
                var block = snapshot.blocks.lookup (live.get_child_value (i).get_child_value (0).get_string ());
                if (block == null || !block.available || block.system_hint ||
                    (replacement && (block.size == 0 || member.size < block.size)))
                    throw new IOError.BUSY ("A RAID member could not be identified or is protected.");
                locked += block;
            }
            locks.acquire_members (anchor, locked, snapshot.dependencies);
            var job = jobs.begin (replacement ? "Replace missing RAID member" :
                add ? "Add RAID member" : "Remove inactive RAID member", anchor, snapshot.dependencies);
            if (replacement) local_raid_checks.insert (array.path, job);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Verifying the RAID member and array");
                var safety = StorageSafetyService.assess (anchor, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || member.system_hint ||
                    (add ? !can_use_group_member (member) : !can_remove_inactive_raid_member (member)))
                    throw new IOError.BUSY ("The selected member or array cannot be safely changed.");
                if (add && !eligible_raid_replacement (array, member, target_disk))
                    throw new IOError.NOT_SUPPORTED ("The replacement does not meet the component size, sector size or physical device requirements.");
                if (add) {
                    yield KernelStorageSafety.require_idle (member, lifetime);
                    int fd = yield open_block (member, "r", 0, lifetime);
                    try {
                        var probe = new BlkidProbe ();
                        if (probe.set_device (fd, 0, 0) != 0 || probe.enable_superblocks (1) != 0 ||
                            probe.enable_partitions (1) != 0 || probe.safe_probe () != 1)
                            throw new IOError.NOT_SUPPORTED ("The target has storage signatures or could not be verified empty.");
                    } finally {
                        Posix.close (fd);
                    }
                    if (replacement)
                        yield verify_reconstruction_metadata (uuid, reviewed_kernel, reviewed_topology, lifetime);
                    yield KernelStorageSafety.require_idle (member, lifetime);
                }
                synchronize ();
                if (creation_identity_changed (anchor, anchor_identity) || creation_identity_changed (member, member_identity) ||
                    manager?.get_interface (array.path, PREFIX + "MDRaid") != proxy ||
                    proxy.get_cached_property ("SyncAction")?.get_string () != "idle" ||
                    has_raid_backend_job (array.path) || has_backend_job_on (member.path) ||
                    proxy.get_cached_property ("ActiveDevices")?.equal (live) != true ||
                    (replacement && (!can_replace_missing_raid_member (anchor) ||
                        raid_review_identity (anchor) != review ||
                        array.kernel.identity != reviewed_kernel.identity || array.kernel.layout != reviewed_kernel.layout ||
                        array.kernel.metadata != reviewed_kernel.metadata || array.kernel.level != reviewed_kernel.level ||
                        array.kernel.expected != reviewed_kernel.expected ||
                        !eligible_raid_replacement (array, member, target_disk))) ||
                    (add && (!eligible_raid_replacement (array, member, target_disk) ||
                        (!replacement && !can_add_raid_spare (anchor)))) ||
                    (add ? !can_use_group_member (member) : !can_remove_inactive_raid_member (member)))
                    throw new IOError.BUSY ("The array or member changed after confirmation.");
                jobs.phase (job, StorageJobState.RUNNING, add ? "Adding the device" : "Removing the inactive member");
                dispatched = true;
                yield call_tracked_method (job, proxy, add ? "AddDevice" : "RemoveDevice",
                    new Variant ("(o@a{sv})", member.path, new Variant ("a{sv}", null)), lifetime);
                int64 attach_deadline = get_monotonic_time () + 30 * TimeSpan.SECOND;
                bool recovering = false;
                while (replacement || get_monotonic_time () < attach_deadline) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    if (manager?.get_interface (array.path, PREFIX + "MDRaid") != proxy ||
                        proxy.get_cached_property ("UUID")?.get_string () != uuid)
                        break;
                    var observed = proxy.get_cached_property ("ActiveDevices");
                    var current = snapshot.blocks.lookup (member.path);
                    if (replacement) {
                        var kernel = array.kernel;
                        var topology = array.topology;
                        if (kernel == null || kernel.identity != reviewed_kernel.identity ||
                            kernel.level != reviewed_kernel.level || kernel.layout != reviewed_kernel.layout ||
                            kernel.metadata != reviewed_kernel.metadata || kernel.expected != reviewed_kernel.expected ||
                            !kernel.writable () || current == null || current.number != replacement_number ||
                            MdRaidKernelState.physical_device (current, out unused_sector) != target_disk ||
                            array.degraded > reviewed_degraded)
                            break;
                        if (kernel.sync_action == MdRaidSyncAction.RECOVER || kernel.sync_action == MdRaidSyncAction.RESYNC) {
                            recovering = true;
                            jobs.progress (job, "Reconstructing RAID redundancy", kernel.progress, kernel.progress >= 0);
                        } else if (kernel.action != "idle") {
                            break;
                        }
                        if (kernel.action == "idle" && array.state == "idle" && topology != null &&
                            array.degraded + 1 == reviewed_degraded &&
                            kernel.degraded == array.degraded.to_string () && kernel.verify_members (topology)) {
                            bool verified_target = false;
                            bool unexpected = false;
                            foreach (var row in topology.members) {
                                if (row.path == current.path) {
                                    verified_target = row.synchronized_member () && row.known_states () &&
                                        row.slot in reviewed_topology.missing_slots;
                                    continue;
                                }
                                bool verified_survivor = false;
                                foreach (var survivor in reviewed_topology.members)
                                    if (row.path == survivor.path && row.slot == survivor.slot &&
                                        row.block == survivor.block && row.kernel_identity != "" &&
                                        row.kernel_identity == survivor.kernel_identity &&
                                        row.metadata_uuid == survivor.metadata_uuid &&
                                        row.synchronized_member () && row.known_states ())
                                        verified_survivor = true;
                                unexpected |= !verified_survivor;
                            }
                            if (verified_target && !unexpected &&
                                topology.synchronized_count == reviewed_topology.synchronized_count + 1 &&
                                (array.degraded != 0 || verified_raid_recovery (array))) {
                                outcome.successful = array.degraded == 0;
                                outcome.summary = outcome.successful ? "RAID reconstruction verified" :
                                    "Replacement synchronized. The array still has missing members.";
                                if (!outcome.successful) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                                return outcome.summary;
                            }
                        }
                        if (kernel.action == "idle" && recovering) {
                            recovering = false;
                            attach_deadline = get_monotonic_time () + 30 * TimeSpan.SECOND;
                        }
                        if (kernel.action == "idle" && get_monotonic_time () >= attach_deadline) break;
                        yield settle_delay (lifetime);
                        continue;
                    }
                    bool changed = false;
                    if (array.kernel?.identity == reviewed_kernel?.identity && array.kernel != null &&
                        array.kernel.action == "idle" && array.kernel.degraded == reviewed_degraded.to_string ()) {
                        if (add && observed != null && array.topology != null && array.kernel.verify_members (array.topology)) {
                            var attached = find_raid_member (proxy, member.path);
                            changed = attached != null && attached.get_child_value (1).get_int32 () == -1 &&
                                "spare" in attached.get_child_value (2).get_strv ();
                        } else if (!add && reviewed_topology != null) {
                            changed = array.kernel.verify_members (reviewed_topology, member.path);
                        }
                    }
                    if (changed && current != null && current.number == replacement_number) {
                        outcome.successful = true;
                        outcome.summary = add ? "RAID member added" : "Inactive RAID member removed";
                        return outcome.summary;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the RAID member change.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the RAID member change", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                if (replacement) local_raid_checks.remove (array.path);
                jobs.finish (job, outcome);
                locks.release (anchor);
            }
        }

        private bool creation_identity_changed (StorageBlock block, string identity) {
            return snapshot.blocks.lookup (block.path) != block || !block.available ||
                modification_identity (block) != identity;
        }

        internal bool can_change_raid_member_state (StorageBlock anchor, StorageBlock member, bool readd) {
            var raid = anchor.raid;
            if (raid == null || raid != member.raid_membership || raid.level != "raid1" ||
                raid.expected_members != 2 || raid.kernel?.state != "clean" || raid.kernel.action != "idle" ||
                !raid.kernel.native_metadata () || raid.topology == null || !raid.running ||
                anchor.system_hint || member.system_hint || anchor.read_only || member.read_only ||
                !member.available || member.type_id != "linux_raid_member" ||
                !FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE) ||
                !FileUtils.test (MDRAID_HELPER, FileTest.IS_EXECUTABLE))
                return false;
            bool active = false;
            foreach (var row in raid.topology.members)
                active |= row.block == member && row.synchronized_member ();
            return readd ? !active && raid.degraded == 1 && can_replace_missing_raid_member (anchor) &&
                FileUtils.test ("/usr/sbin/mdadm", FileTest.IS_EXECUTABLE) :
                active && raid.topology.members.length == 2 && verified_raid_recovery (raid);
        }

        internal async string change_raid_member_state (StorageBlock anchor, StorageBlock member, bool readd,
            string review, string member_identity) throws Error {
            synchronize ();
            if (review == "" || raid_review_identity (anchor) != review ||
                creation_identity_changed (member, member_identity) || !can_change_raid_member_state (anchor, member, readd))
                throw new IOError.NOT_SUPPORTED ("The reviewed RAID1 member transition is unavailable.");
            var raid = anchor.raid;
            var original = raid.kernel;
            string uuid = raid.uuid;
            uint64 member_number = member.number;
            string sector;
            string physical = MdRaidKernelState.physical_device (member, out sector);
            string member_seq = MdRaidKernelState.sequence_from_identity (physical);
            StorageBlock[] locked = { member };
            foreach (var row in raid.topology.members)
                if (row.block != null && row.block != member) locked += row.block;
            locks.acquire_members (anchor, locked, snapshot.dependencies);
            var job = jobs.begin (readd ? "Re-add former RAID member" : "Mark RAID member faulty",
                anchor, snapshot.dependencies);
            local_raid_checks.insert (raid.path, job);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                var safety = StorageSafetyService.assess (anchor, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || safety.mounted || safety.active_dependents)
                    throw new IOError.BUSY ("The array is protected or has active storage consumers.");
                yield KernelStorageSafety.require_idle (anchor, lifetime);
                if (readd) yield KernelStorageSafety.require_idle (member, lifetime);
                int fd = yield open_block (member, "r", DIRECT_IO, lifetime);
                MdRaidSuperblock? metadata;
                try { metadata = MdRaidSuperblock.inspect (fd); }
                finally { Posix.close (fd); }
                if (metadata == null || !metadata.usable () || metadata.uuid != uuid || member_seq == "" ||
                    (readd && !((int) metadata.slot in raid.topology.missing_slots)))
                    throw new IOError.NOT_SUPPORTED ("The former member’s superblock and slot could not be verified.");
                synchronize ();
                if (raid_review_identity (anchor) != review || creation_identity_changed (member, member_identity) ||
                    MdRaidKernelState.physical_device (member, out sector) != physical ||
                    !can_change_raid_member_state (anchor, member, readd))
                    throw new IOError.BUSY ("The array or member changed after confirmation.");
                string[] args = { "/usr/bin/pkexec", "--disable-internal-agent", MDRAID_HELPER,
                    readd ? "re-add-member" : "mark-faulty", KernelStorageSafety.device_number (anchor.number),
                    MdRaidKernelState.sequence_from_identity (original.identity), KernelStorageSafety.device_number (member_number),
                    member_seq, uuid, metadata.member_uuid, metadata.slot.to_string (), metadata.events.to_string () };
                jobs.phase (job, StorageJobState.RUNNING, "Waiting for authorization and kernel validation");
                var helper = new Subprocess.newv (args, SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_SILENCE);
                dispatched = true;
                string? diagnostic;
                yield helper.communicate_utf8_async (null, lifetime, null, out diagnostic);
                if (!helper.get_successful ()) {
                    if (helper.get_if_exited ()) {
                        int code = helper.get_exit_status ();
                        dispatched = code != 2 && code != 126 && code != 127;
                        if (code == 126) throw new IOError.CANCELLED ("Authorization was cancelled.");
                    }
                    throw new IOError.FAILED (diagnostic?.strip () ?? "The member-state helper failed.");
                }
                int64 deadline = get_monotonic_time () + 30 * TimeSpan.SECOND;
                bool rebuilding = false;
                while (true) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    var kernel = raid.kernel;
                    var topology = raid.topology;
                    if (anchor.raid != raid || raid.uuid != uuid || kernel?.identity != original.identity ||
                        kernel.layout != original.layout || kernel.metadata != original.metadata ||
                        member.number != member_number || MdRaidKernelState.physical_device (member, out sector) != physical)
                        break;
                    if (topology != null && kernel.verify_members (topology)) {
                        foreach (var row in topology.members) {
                            if (row.block != member) continue;
                            bool verified = readd ? row.slot == metadata.slot && row.synchronized_member () &&
                                verified_raid_recovery (raid) :
                                raid.degraded == 1 && kernel.degraded == "1" && kernel.action == "idle" &&
                                topology.synchronized_count == 1 && "faulty" in row.states;
                            if (verified) {
                                outcome.successful = true;
                                outcome.summary = readd ? "Former RAID member synchronized" :
                                    "Member marked faulty. The array is now degraded.";
                                return outcome.summary;
                            }
                        }
                    }
                    if (readd && (kernel.action == "recover" || kernel.action == "resync")) {
                        rebuilding = true;
                        jobs.progress (job, "Synchronizing the former RAID member", kernel.progress, kernel.progress >= 0);
                    } else if (kernel.action == "idle") {
                        if (rebuilding) deadline = get_monotonic_time () + 30 * TimeSpan.SECOND;
                        rebuilding = false;
                        if (get_monotonic_time () >= deadline) break;
                    } else break;
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("The final RAID member state could not be verified.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the RAID member transition", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                local_raid_checks.remove (raid.path);
                jobs.finish (job, outcome);
                locks.release (anchor);
            }
        }

        internal bool can_check_raid (StorageBlock block) {
            var raid = block.raid;
            var proxy = raid != null ? manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy : null;
            return block.available && raid != null && raid.degraded == 0 && proxy != null &&
                proxy.get_cached_property ("Running")?.get_boolean () == true &&
                proxy.get_cached_property ("SyncAction")?.get_string () == "idle" &&
                (raid.level == "raid1" || raid.level == "raid4" || raid.level == "raid5" ||
                 raid.level == "raid6" || raid.level == "raid10");
        }

        internal bool can_change_raid_bitmap (StorageBlock block) {
            var raid = block.raid;
            if (!can_check_raid (block) || block.read_only || block.system_hint || raid?.kernel == null ||
                !raid.kernel.writable () || !raid.kernel.native_metadata () || !verified_raid_recovery (raid))
                return false;
            string kind = MdRaidKernelState.bitmap_kind (raid.kernel.bitmap);
            return kind == MdRaidKernelState.bitmap_kind (raid.bitmap_location) &&
                ((kind == "none" && raid.kernel.policy == "resync") ||
                 (kind == "internal" && raid.kernel.policy == "bitmap"));
        }

        internal string raid_review_identity (StorageBlock block) {
            var raid = block.raid;
            var kernel = raid?.kernel;
            var proxy = raid != null ? manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy : null;
            if (raid == null || raid.uuid == "" || kernel == null || proxy == null) return "";
            string[] members = {};
            if (raid.topology != null) {
                foreach (var member in raid.topology.members)
                    members += member.path + " " + member.kernel_identity + " " + member.metadata_uuid;
            }
            return string.joinv ("\n", { modification_identity (block), raid.uuid, raid.level, kernel.identity,
                kernel.layout, kernel.metadata, kernel.bitmap, kernel.policy, raid.expected_members.to_string (),
                raid.degraded.to_string (), proxy.get_cached_property ("ActiveDevices")?.print (true) ?? "",
                string.joinv ("\n", members) });
        }

        internal async void set_raid_bitmap (StorageBlock block, bool enable, string review) throws Error {
            synchronize ();
            require_volume (block, "Block");
            if (review == "" || raid_review_identity (block) != review || !can_change_raid_bitmap (block))
                throw new IOError.NOT_SUPPORTED ("The RAID bitmap settings are unavailable or changed since review.");
            var raid = block.raid;
            var proxy = manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy;
            var original = raid.kernel;
            string uuid = raid.uuid;
            string wanted = enable ? "internal" : "none";
            if (MdRaidKernelState.bitmap_kind (original.bitmap) == wanted)
                throw new IOError.INVALID_ARGUMENT ("The requested bitmap setting is already active.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Change RAID write-intent bitmap", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                yield require_udisks_method (proxy, "SetBitmapLocation", lifetime);
                synchronize ();
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies ||
                    manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy ||
                    has_raid_backend_job (raid.path) ||
                    raid_review_identity (block) != review || !can_change_raid_bitmap (block))
                    throw new IOError.BUSY ("The array cannot safely change its bitmap.");
                jobs.phase (job, StorageJobState.RUNNING, "Changing the internal RAID bitmap");
                dispatched = true;
                yield call_tracked_method (job, proxy, "SetBitmapLocation",
                    new Variant ("(@ay@a{sv})", new Variant.bytestring (wanted), new Variant ("a{sv}", null)), lifetime);
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    var kernel = raid.kernel;
                    if (block.raid != raid || raid.uuid != uuid || kernel == null || kernel.identity != original.identity ||
                        kernel.metadata != original.metadata || kernel.layout != original.layout ||
                        kernel.expected != original.expected || kernel.level != original.level ||
                        manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy)
                        break;
                    if (MdRaidKernelState.bitmap_kind (kernel.bitmap) == wanted &&
                        MdRaidKernelState.bitmap_kind (raid.bitmap_location) == wanted &&
                        kernel.policy == (enable ? "bitmap" : "resync") && verified_raid_recovery (raid)) {
                        outcome.successful = true;
                        outcome.summary = enable ? "Internal RAID bitmap enabled" : "Internal RAID bitmap disabled";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("The final RAID bitmap and member state could not be verified.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the RAID bitmap change", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        internal bool can_repair_raid (StorageBlock block) {
            if (!can_check_raid (block) || block.read_only || block.system_hint ||
                block.raid?.kernel?.writable () != true || !verified_raid_recovery (block.raid))
                return false;
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            return !safety.system_critical && !safety.unknown_dependencies && !safety.mounted && !safety.active_dependents;
        }

        internal async string start_raid_check (StorageBlock block, bool repair = false, string review = "") throws Error {
            synchronize ();
            require_volume (block, "Block");
            if (!can_check_raid (block))
                throw new IOError.NOT_SUPPORTED ("An idle, running, non-degraded redundant array is required.");
            var raid = block.raid;
            if (repair && (review == "" || raid_review_identity (block) != review || !can_repair_raid (block)))
                throw new IOError.NOT_SUPPORTED ("RAID repair requires a verified healthy, writable array.");
            string requested_action = repair ? "repair" : "check";
            string label = repair ? "RAID consistency repair" : "RAID consistency check";
            string uuid = raid.uuid;
            string kernel_identity = raid.kernel?.identity ?? "";
            var proxy = manager?.get_interface (raid.path, PREFIX + "MDRaid") as DBusProxy;
            if (proxy == null)
                throw new IOError.NOT_FOUND ("The RAID array is no longer available.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (label, block, snapshot.dependencies);
            local_raid_checks.insert (raid.path, job);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool requested = false;
            try {
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies)
                    throw new IOError.BUSY ("The RAID array supports the running system or its dependencies are unknown.");
                if (repair) {
                    yield KernelStorageSafety.require_idle (block, lifetime);
                    synchronize ();
                    if (raid_review_identity (block) != review || !can_repair_raid (block) ||
                        manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy)
                        throw new IOError.BUSY ("The array or its storage consumers changed after repair was reviewed.");
                }
                jobs.phase (job, StorageJobState.RUNNING, "Requesting " + label);
                requested = true;
                yield call_tracked_method (job, proxy, "RequestSyncAction",
                    new Variant ("(s@a{sv})", requested_action, new Variant ("a{sv}", null)), lifetime);
                int64 start_deadline = get_monotonic_time () + 10 * TimeSpan.SECOND;
                bool observed = false;
                bool reached_end = false;
                int64 stop_deadline = 0;
                while (true) {
                    lifetime.set_error_if_cancelled ();
                    if (block.raid != raid || raid.uuid != uuid ||
                        (kernel_identity != "" && raid.kernel?.identity != kernel_identity) ||
                        manager?.get_interface (raid.path, PREFIX + "MDRaid") != proxy ||
                        proxy.get_cached_property ("Running")?.get_boolean () != true)
                        throw new IOError.NOT_FOUND ("The RAID array changed while its check was being monitored.");
                    string action = proxy.get_cached_property ("SyncAction")?.get_string () ?? "";
                    if (action == requested_action) {
                        if (!observed) {
                            observed = true;
                            raid_checks.insert (job.id, proxy);
                            job.cancelable = true;
                        }
                        var completed = proxy.get_cached_property ("SyncCompleted");
                        double fraction = raid.kernel?.progress ?? -1.0;
                        if (fraction < 0) fraction = completed?.get_double () ?? -1.0;
                        bool progress_valid = fraction >= 0.0 && fraction <= 1.0;
                        reached_end |= progress_valid && fraction == 1.0;
                        uint64 rate = proxy.get_cached_property ("SyncRate")?.get_uint64 () ?? 0;
                        uint64 remaining = proxy.get_cached_property ("SyncRemainingTime")?.get_uint64 () ?? 0;
                        string phase = label;
                        if (rate > 0) phase += " · %s/s".printf (format_size (rate));
                        if (remaining > 0) phase += " · %s s remaining".printf (((remaining - 1) / TimeSpan.SECOND + 1).to_string ());
                        if (stopping_raid_checks.contains (job.id) && job.state != StorageJobState.CANCELLING) {
                            if (stop_deadline == 0)
                                stop_deadline = get_monotonic_time () + 10 * TimeSpan.SECOND;
                            if (get_monotonic_time () >= stop_deadline) {
                                stopping_raid_checks.remove (job.id);
                                job.cancelable = true;
                                job.error_message = "UDisks did not confirm that the RAID check stopped.";
                            }
                        } else stop_deadline = 0;
                        if (!stopping_raid_checks.contains (job.id))
                            jobs.progress (job, phase, fraction, progress_valid);
                    } else if (observed && action == "idle") {
                        // Wait for a concurrent Stop request to return before interpreting idle.
                        if (stopping_raid_checks.contains (job.id) && job.state == StorageJobState.CANCELLING) {
                            yield settle_delay (lifetime);
                            continue;
                        }
                        if (stopping_raid_checks.contains (job.id)) {
                            outcome.status = StorageOperationStatus.CANCELLED;
                            outcome.summary = label + " stopped";
                            return outcome.summary;
                        }
                        if (reached_end && verified_raid_recovery (raid)) {
                            outcome.successful = true;
                            outcome.summary = label + " completed";
                            if (raid.kernel.mismatch_count != "")
                                outcome.summary += " · Mismatch sectors: " + raid.kernel.mismatch_count;
                            return outcome.summary;
                        }
                        throw new IOError.FAILED ("%s is now idle. UDisks did not report whether it completed or was interrupted.".printf (label));
                    } else if (observed || get_monotonic_time () >= start_deadline) {
                        throw new IOError.FAILED ("UDisks did not confirm that the requested RAID maintenance was running.");
                    }
                    yield settle_delay (lifetime);
                }
            } catch (Error error) {
                outcome.fail ("Could not confirm the outcome of " + label, error);
                if (requested) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                local_raid_checks.remove (raid.path);
                raid_checks.remove (job.id);
                stopping_raid_checks.remove (job.id);
                job.cancelable = false;
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }
        internal static bool valid_lvm_name (string name) {
            if (name.length == 0 || name.length > 127 || name.has_prefix ("-") || name == "." || name == "..")
                return false;
            for (int i = 0; i < name.length; i++) {
                char c = name[i];
                if (!c.isalnum () && c != '+' && c != '_' && c != '.' && c != '-')
                    return false;
            }
            return true;
        }

        private DBusProxy? creation_manager (bool raid) {
            return manager?.get_interface ("/org/freedesktop/UDisks2/Manager",
                PREFIX + (raid ? "Manager" : "Manager.LVM2")) as DBusProxy;
        }

        internal bool can_create_storage_group (bool raid) {
            return creation_manager (raid) != null;
        }

        internal bool can_use_group_member (StorageBlock block) {
            if (!block.available || block.read_only || block.ignored || block.system_hint || block.number == 0 ||
                block.size == 0 || block.table != null || block.partition?.container == true ||
                block.usage != "" || block.type_id != "" || block.uuid != "" ||
                block.filesystem != null || block.encrypted != null || block.has_swap ||
                block.raid_path != "/" || block.raid_member_path != "/" ||
                block.logical_volume_path != "/" || block.physical_volume_group_path != "/" ||
                block.backing_path != "/" || block.virtual_attachment != null ||
                block.mount_configurations.length != 0 || block.encryption_configurations.length != 0)
                return false;
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            return !safety.system_critical && !safety.unknown_dependencies && !safety.active_dependents &&
                !safety.mounted && snapshot.dependencies.children (block).length == 0;
        }

        internal static uint raid_min_members (string level) {
            switch (level) {
            case "raid0": case "raid1": return 2;
            case "raid4": case "raid5": return 3;
            case "raid6": case "raid10": return 4;
            default: return 0;
            }
        }

        internal async string create_storage_group (bool raid, StorageBlock[] members, string[] identities,
            string name, string level, uint64 chunk) throws Error {
            var proxy = creation_manager (raid);
            if (proxy == null)
                throw new IOError.NOT_SUPPORTED ("The required UDisks manager interface is unavailable.");
            uint minimum = raid ? raid_min_members (level) : 1;
            if (minimum == 0 || members.length < minimum || identities.length != members.length ||
                !valid_lvm_name (name) || (raid && (name.length > 32 || name.contains (":") ||
                (level == "raid10" && members.length % 2 != 0) ||
                (level == "raid1" ? chunk != 0 :
                    (chunk != 0 && chunk != 65536 && chunk != 131072 && chunk != 262144 && chunk != 524288)))))
                throw new IOError.INVALID_ARGUMENT ("The selected members or creation options are invalid.");

            synchronize ();
            var paths = new VariantBuilder (new VariantType ("ao"));
            var numbers = new HashTable<string, string> (str_hash, str_equal);
            uint64[] original_numbers = {};
            foreach (var member in members) {
                require_volume (member, "Block");
                string number = member.number.to_string ();
                if (!can_use_group_member (member) || numbers.contains (number))
                    throw new IOError.BUSY ("Each selected member must be a distinct, unused block device.");
                numbers.insert (number, number);
                original_numbers += member.number;
                paths.add ("o", member.path);
            }
            locks.acquire_members (members[0], members, snapshot.dependencies);
            var job = jobs.begin (raid ? "Create RAID array" : "Create LVM volume group",
                members[0], snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Verifying the selected block devices");
                foreach (var member in members)
                    yield KernelStorageSafety.require_idle (member, lifetime);
                synchronize ();
                if (creation_manager (raid) != proxy)
                    throw new IOError.NOT_CONNECTED ("The UDisks manager changed.");
                for (int i = 0; i < members.length; i++) {
                    require_volume (members[i], "Block");
                    if (!can_use_group_member (members[i]) || modification_identity (members[i]) != identities[i])
                        throw new IOError.BUSY ("A selected member changed after confirmation.");
                }
                if (!raid)
                    foreach (var item in snapshot.advanced.get_values ())
                        if (item is StorageVolumeGroup && item.name == name)
                            throw new IOError.EXISTS ("A volume group already has that name.");
                jobs.phase (job, StorageJobState.RUNNING, raid ? "Creating the array" : "Creating the volume group");
                dispatched = true;
                var options = new Variant ("a{sv}", null);
                var parameters = raid ? new Variant ("(@aosst@a{sv})", paths.end (), level, name, chunk, options) :
                    new Variant ("(s@ao@a{sv})", name, paths.end (), options);
                var reply = yield call_tracked_method (job, proxy, raid ? "MDRaidCreate" : "VolumeGroupCreate",
                    parameters, lifetime);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid storage object path.");
                string path = reply.get_child_value (0).get_string ();
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    var result = manager?.get_interface (path, PREFIX + (raid ? "MDRaid" : "VolumeGroup")) as DBusProxy;
                    string uuid = result?.get_cached_property ("UUID")?.get_string () ?? "";
                    bool verified = uuid != "" && (raid
                        ? result?.get_cached_property ("Level")?.get_string () == level
                        : result?.get_cached_property ("Name")?.get_string () == name);
                    for (int member_index = 0; member_index < members.length; member_index++) {
                        var current = snapshot.blocks.lookup (members[member_index].path);
                        verified &= current != null && current.number == original_numbers[member_index] &&
                            (raid ? current.raid_member_path == path : current.physical_volume_group_path == path);
                    }
                    if (verified) {
                        string visible = "";
                        if (raid)
                            foreach (var block in snapshot.blocks.get_values ())
                                if (block.available && block.raid_path == path) visible = block.path;
                        if (!raid || visible != "") {
                            outcome.successful = true;
                            outcome.summary = raid ? "RAID array created" : "LVM volume group created";
                            return visible;
                        }
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the new storage object and its members.");
            } catch (Error error) {
                outcome.fail ("Could not confirm storage creation", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (members[0]);
            }
        }

        internal async string create_logical_volume (StorageBlock member, string name, uint64 size,
            string confirmed_identity, bool thin_pool = false, string pool_path = "/", string pool_uuid = "",
            string origin_path = "/", string origin_uuid = "", bool confirm_overcommit = false) throws Error {
            bool thin_volume = pool_path != "/";
            bool snapshot_volume = origin_path != "/";
            if (!valid_lvm_name (name) || (!snapshot_volume && size == 0) || (thin_pool && thin_volume) ||
                (snapshot_volume && (thin_pool || thin_volume)))
                throw new IOError.INVALID_ARGUMENT ("Enter a valid LVM name and nonzero capacity.");
            synchronize ();
            require_volume (member, "Block");
            var group = member.volume_group;
            var proxy = group != null ? manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (group == null || proxy == null || uuid == "")
                throw new IOError.NOT_SUPPORTED ("The selected device does not belong to an identifiable volume group.");
            var origin = snapshot_volume ? snapshot.advanced.lookup (origin_path) as StorageLogicalVolume : null;
            bool thin_snapshot = snapshot_volume && origin != null && origin.thin_pool_path != "/";
            string snapshot_pool_path = thin_snapshot ? origin.thin_pool_path : "/";
            string snapshot_pool_uuid = thin_snapshot ? require_thin_pool (origin).uuid : "";
            uint64 expected_size = thin_snapshot ? origin.size : size;
            var origin_proxy = origin != null ? manager?.get_interface (origin.path, PREFIX + "LogicalVolume") as DBusProxy : null;
            string origin_block_path = origin_proxy?.get_cached_property ("BlockDevice")?.get_string () ?? "/";
            var origin_block = snapshot.blocks.lookup (origin_block_path);
            if (snapshot_volume && (origin == null || origin_uuid == "" || origin.uuid != origin_uuid ||
                origin.group_path != group.path || origin.lvm_type != "block" ||
                (thin_snapshot ? size != 0 || expected_size == 0 : size == 0 || origin.origin_path != "/") ||
                !origin.active || origin_proxy == null || origin_block == null ||
                origin_block.logical_volume != origin))
                throw new IOError.NOT_SUPPORTED ("Choose an active, supported logical volume in this group as the snapshot origin.");
            string origin_identity = origin_block != null ? modification_identity (origin_block) : "";
            StorageBlock[] affected = origin_block != null ? new StorageBlock[] { origin_block } : new StorageBlock[0];
            locks.acquire_members (member, affected, snapshot.dependencies);
            var job = jobs.begin (snapshot_volume ? "Create LVM snapshot" : thin_pool ? "Create LVM thin pool" : thin_volume ?
                "Create LVM thin volume" : "Create logical volume", member, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking volume-group members and free extents");
                var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || member.read_only)
                    throw new IOError.BUSY ("The volume group supports the running system or its dependencies are unknown.");
                foreach (var parent in snapshot.dependencies.ancestors (group)) {
                    var pv = parent as StorageBlock;
                    if (pv == null || pv.volume_group != group) continue;
                    if (!pv.available || pv.read_only || pv.system_hint)
                        throw new IOError.BUSY ("A physical volume is unavailable, protected, or read-only.");
                }
                if (snapshot_volume) {
                    var origin_safety = StorageSafetyService.assess (origin_block, snapshot.dependencies);
                    if (origin_safety.system_critical || origin_safety.unknown_dependencies ||
                        origin_safety.active_dependents || origin_safety.mounted || origin_block.read_only)
                        throw new IOError.BUSY ("Unmount the snapshot origin and close its dependent devices first.");
                    yield KernelStorageSafety.require_idle (origin_block, lifetime);
                    synchronize ();
                    if (creation_identity_changed (origin_block, origin_identity) || origin_block.logical_volume != origin ||
                        manager?.get_interface (origin_path, PREFIX + "LogicalVolume") != origin_proxy ||
                        origin.uuid != origin_uuid || origin.group_path != group.path || !origin.active)
                        throw new IOError.NOT_FOUND ("The snapshot origin changed.");
                }
                if (volume_group_has_backend_job (group, { member }))
                    throw new IOError.BUSY ("Another UDisks job is using this volume group.");
                uint64 extent = proxy.get_cached_property ("ExtentSize")?.get_uint64 () ?? 0;
                uint64 free = proxy.get_cached_property ("FreeSize")?.get_uint64 () ?? 0;
                var missing = proxy.get_cached_property ("MissingPhysicalVolumes");
                var pool = thin_volume ? snapshot.advanced.lookup (pool_path) as StorageLogicalVolume : null;
                if (thin_snapshot) {
                    var live_pool = require_thin_pool (origin);
                    if (origin.thin_pool_path != snapshot_pool_path || live_pool.uuid != snapshot_pool_uuid ||
                        origin.size != expected_size)
                        throw new IOError.NOT_FOUND ("The snapshot origin or its thin pool changed.");
                    var usage = new ThinPoolUsage (snapshot, live_pool);
                    if (expected_size > usage.virtual_limit ())
                        throw new IOError.NO_SPACE ("The thin pool is exhausted or its allocation cannot be verified.");
                    if (usage.overcommits (expected_size) && !confirm_overcommit)
                        throw new IOError.PERMISSION_DENIED ("Confirm that this thin snapshot increases provisioned virtual capacity above physical capacity.");
                }
                if (thin_volume) {
                    if (pool == null || pool_uuid == "" || pool.uuid != pool_uuid || pool.group_path != group.path)
                        throw new IOError.NOT_FOUND ("The selected thin pool changed.");
                    var usage = new ThinPoolUsage (snapshot, pool);
                    if (size > usage.virtual_limit ())
                        throw new IOError.NO_SPACE ("The thin pool is unavailable, exhausted, or its capacity cannot be verified.");
                    if (usage.overcommits (size) && !confirm_overcommit)
                        throw new IOError.PERMISSION_DENIED ("Explicitly confirm virtual capacity above the physical thin-pool capacity.");
                }
                if ((missing != null && missing.n_children () != 0) || extent == 0 ||
                    (!thin_volume && size > free) || size % extent != 0)
                    throw new IOError.INVALID_ARGUMENT ("Choose a capacity that fits the free space and is a multiple of the LVM extent size.");
                foreach (var item in snapshot.advanced.get_values ()) {
                    var existing = item as StorageLogicalVolume;
                    if (existing != null && existing.group_path == group.path && existing.name == name)
                        throw new IOError.EXISTS ("This volume group already has a logical volume with that name.");
                }
                if (member.volume_group != group || modification_identity (member) != confirmed_identity ||
                    manager?.get_interface (group.path, PREFIX + "VolumeGroup") != proxy)
                    throw new IOError.NOT_FOUND ("The volume group changed after confirmation.");

                jobs.phase (job, StorageJobState.RUNNING, "Allocating logical-volume extents");
                dispatched = true;
                var options = new Variant ("a{sv}", null);
                var reply = yield call_tracked_method (job, snapshot_volume ? origin_proxy : proxy,
                    snapshot_volume ? "CreateSnapshot" : thin_pool ? "CreateThinPoolVolume" :
                        thin_volume ? "CreateThinVolume" : "CreatePlainVolume",
                    thin_volume ? new Variant ("(sto@a{sv})", name, size, pool_path, options) :
                        new Variant ("(st@a{sv})", name, size, options), lifetime);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid logical volume path.");
                string path = reply.get_child_value (0).get_string ();
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    var created = snapshot.advanced.lookup (path) as StorageLogicalVolume;
                    if (created != null && created.group_path == group.path && created.name == name &&
                        created.uuid != "" && created.size == expected_size && created.origin_path == origin_path &&
                        (thin_pool ? created.lvm_type == "pool" :
                            created.lvm_type == "block" && created.thin_pool_path == (thin_snapshot ? snapshot_pool_path : pool_path)) &&
                        proxy.get_cached_property ("UUID")?.get_string () == uuid) {
                        var volume_proxy = manager?.get_interface (path, PREFIX + "LogicalVolume") as DBusProxy;
                        string block_path = volume_proxy?.get_cached_property ("BlockDevice")?.get_string () ?? "/";
                        var block = snapshot.blocks.lookup (block_path);
                        if (thin_pool || !created.active || (block != null && block.available && block.logical_volume_path == path)) {
                            outcome.successful = true;
                            outcome.summary = snapshot_volume ? "Logical-volume snapshot created" :
                                thin_pool ? "Thin pool created" : thin_volume ? "Thin volume created" : "Logical volume created";
                            return block?.path ?? "";
                        }
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not publish the logical volume with the requested geometry.");
            } catch (Error error) {
                outcome.fail ("Could not confirm logical-volume creation", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (member);
            }
        }

        private bool volume_group_has_backend_job (StorageVolumeGroup group, StorageBlock[] members) {
            var watched = new HashTable<string, string> (str_hash, str_equal);
            watched.insert (group.path, group.path);
            foreach (var device in snapshot.dependencies.descendants (group))
                watched.insert (device.path, device.path);
            foreach (var member in members)
                foreach (var device in snapshot.dependencies.descendants (member))
                    watched.insert (device.path, device.path);
            var objects = manager?.get_objects ();
            if (objects == null) return false;
            foreach (var object in objects) {
                var backend_job = object.get_interface (PREFIX + "Job") as DBusProxy;
                var affected = backend_job?.get_cached_property ("Objects");
                if (affected == null || !affected.is_of_type (new VariantType ("ao"))) continue;
                for (size_t i = 0; i < affected.n_children (); i++)
                    if (watched.contains (affected.get_child_value (i).get_string ())) return true;
            }
            return false;
        }

        private StorageBlock[] lvm_members (StorageVolumeGroup group) {
            StorageBlock[] members = {};
            foreach (var block in snapshot.blocks.get_values ())
                if (block.volume_group == group) members += block;
            return members;
        }

        internal string lvm_membership_identity (StorageBlock anchor) {
            return storage_membership_identity (anchor, false, false);
        }

        private DBusProxy require_lvm_context (StorageBlock anchor, string identity, string uuid,
            bool recovery, out StorageVolumeGroup group) throws Error {
            require_volume (anchor, "PhysicalVolume");
            var current = anchor.volume_group;
            var proxy = current != null ? manager?.get_interface (current.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            if (current == null || proxy == null || uuid == "" || current.uuid != uuid ||
                identity == "" || lvm_membership_identity (anchor) != identity)
                throw new IOError.NOT_FOUND ("The volume group or its physical members changed.");
            if (!current.missing_pvs_known || (!recovery && current.missing_pv_uuids.length != 0))
                throw new IOError.BUSY ("Physical-volume membership is incomplete or unknown.");
            if (volume_group_has_backend_job (current, lvm_members (current)))
                throw new IOError.BUSY ("Another UDisks job is using this volume group.");
            group = current;
            return proxy;
        }

        private void fail_lvm_operation (StorageJob job, StorageOperationResult result, string operation,
            bool dispatched, Error error) {
            string remote = DBusError.get_remote_error (error) ?? "";
            bool rejected = remote.has_prefix ("org.freedesktop.UDisks2.Error.NotAuthorized") ||
                remote == "org.freedesktop.UDisks2.Error.NotSupported" ||
                remote == "org.freedesktop.DBus.Error.UnknownMethod" ||
                remote == "org.freedesktop.DBus.Error.InvalidArgs";
            if (dispatched && !rejected) {
                string state = job.backend_completed && !job.backend_successful ? " failed in UDisks" :
                    job.backend_path != "" && !job.backend_completed ? " is still being tracked by UDisks" :
                    " has an unverified outcome";
                result.fail (operation + state, error);
                result.status = StorageOperationStatus.NEEDS_ATTENTION;
            } else {
                result.fail (operation + (rejected ? " was rejected" : " was not started"), error);
            }
        }

        private void require_lvm_job_succeeded (StorageJob job) throws Error {
            if (job.backend_completed && !job.backend_successful)
                throw new IOError.FAILED ("The backend job reported a failure: " + job.error_message);
        }

        private void require_lvm_idle (StorageVolumeGroup group, StorageBlock[] members,
            StorageLogicalVolume? active_target = null, StorageLogicalVolume? active_candidate = null) throws Error {
            foreach (var member in members) {
                var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || (active_target == null && safety.active_dependents) ||
                    safety.mounted || !member.available || member.read_only ||
                    member.mount_configurations.length != 0 || member.encryption_configurations.length != 0)
                    throw new IOError.BUSY ("Cannot modify physical volume %s. %s".printf (member.preferred,
                        safety.reasons.length > 0 ? string.joinv (". ", safety.reasons) :
                        "The device is unavailable or has persistent configuration."));
            }
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv == null || lv.group_path != group.path) continue;
                if (lv != active_target && lv != active_candidate && (lv.active || lv.block_path != "/"))
                    throw new IOError.BUSY ("Deactivate logical volume %s before continuing.".printf (lv.name));
                if (lv.child_configuration == null || lv.child_configuration.n_children () != 0)
                    throw new IOError.BUSY ("Persistent configuration for logical volume %s is present or unverified.".printf (lv.name));
            }
        }

        internal StorageBlock? lvm_anchor (StorageVolumeGroup group) {
            foreach (var block in lvm_members (group))
                if (block.available && !block.ignored && !block.read_only && !block.system_hint) return block;
            return null;
        }

        private StorageBlock require_lvm_offline_mapping (StorageLogicalVolume lv) throws Error {
            var block = snapshot.blocks.lookup (lv.block_path);
            if (!lv.active || block == null || block.logical_volume != lv || block.read_only ||
                lv.child_configuration == null || lv.child_configuration.n_children () != 0)
                throw new IOError.BUSY ("An active, identifiable logical-volume mapping with no persistent configuration is required.");
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || safety.mounted ||
                block.swap_active || block.mount_configurations.length != 0 || block.encryption_configurations.length != 0)
                throw new IOError.BUSY ("Unmount the logical volume and close its dependent devices first.");
            foreach (var item in snapshot.advanced.get_values ()) {
                var dependent = item as StorageLogicalVolume;
                if (dependent != null && (dependent.origin_path == lv.path || dependent.thin_pool_path == lv.path))
                    throw new IOError.BUSY ("The logical volume has dependent snapshots or thin volumes.");
            }
            return block;
        }

        private bool lvm_cache_plain (StorageLogicalVolume volume) {
            return volume.uuid != "" && volume.lvm_type == "block" && volume.lvm_layout == "linear" &&
                volume.origin_path == "/" && volume.thin_pool_path == "/" &&
                volume.allocation (snapshot) == LvmAllocation.COMPLETE;
        }

        internal StorageLogicalVolume[] lvm_cache_candidates (StorageLogicalVolume volume) {
            StorageLogicalVolume[] choices = {};
            if (!lvm_cache_plain (volume) || !volume.active) return choices;
            foreach (var item in snapshot.advanced.get_values ()) {
                var candidate = item as StorageLogicalVolume;
                if (candidate == null || candidate == volume || candidate.group_path != volume.group_path ||
                    !lvm_cache_plain (candidate) || !candidate.active) continue;
                var block = snapshot.blocks.lookup (candidate.block_path);
                if (block != null && block.usage == "" && block.type_id == "" && block.table == null)
                    choices += candidate;
            }
            return choices;
        }

        private async void require_zero_cache_candidate (StorageBlock block, StorageJob job, Cancellable token) throws Error {
            int fd = yield open_block (block, "r", Posix.O_EXCL, token);
            var input = new UnixInputStream (fd, true);
            uint64 remaining = block.size;
            uint8[] buffer = new uint8[1024 * 1024];
            try {
                if (remaining == 0 || KernelStorageSafety.block_capacity (block) != remaining)
                    throw new IOError.INVALID_DATA ("The cache candidate's capacity could not be verified.");
                while (remaining > 0) {
                    int count = (int) uint64.min (remaining, buffer.length);
                    ssize_t bytes = yield input.read_async (buffer[0:count], Priority.DEFAULT, token);
                    if (bytes <= 0) throw new IOError.INVALID_DATA ("Could not read the entire cache candidate.");
                    for (int i = 0; i < bytes; i++)
                        if (buffer[i] != 0) throw new IOError.NOT_SUPPORTED ("The cache candidate contains data.");
                    remaining -= bytes;
                    jobs.progress (job, "Checking that the cache candidate is empty", 1.0 - (double) remaining / block.size, true);
                }
            } finally {
                try { input.close (); }
                catch (Error error) { debug ("Closing the cache inspection descriptor: %s", error.message); }
            }
        }

        [CCode (cname = "MAJORIS_LVM_CACHE_INSPECTOR", cheader_filename = "lvm-cache-inspector-config.h")]
        private extern const string LVM_CACHE_INSPECTOR;

        private async LvmCacheStatus[] read_lvm_cache_report (StorageVolumeGroup group, Cancellable token) throws Error {
            if (!FileUtils.test (LVM_CACHE_INSPECTOR, FileTest.IS_EXECUTABLE) ||
                !FileUtils.test ("/usr/sbin/lvs", FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("Install the LVM cache inspector and LVM2 tools to verify cache state.");
            if (!valid_lvm_name (group.name) || group.uuid == "")
                throw new IOError.INVALID_ARGUMENT ("The volume group cannot be identified.");
            string name = group.name;
            string uuid = group.uuid;
            string[] argv = { LVM_CACHE_INSPECTOR, name };
            if (Posix.geteuid () != 0)
                argv = { "/usr/bin/pkexec", "--disable-internal-agent", LVM_CACHE_INSPECTOR, name };
            var process = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? output;
            yield process.communicate_utf8_async (null, token, out output, null);
            if (process.get_if_exited () && (process.get_exit_status () == 126 || process.get_exit_status () == 127))
                throw new IOError.PERMISSION_DENIED ("Authorization to inspect the LVM cache was denied or cancelled.");
            if (!process.get_successful () || output == null)
                throw new IOError.FAILED ("The cache inspector could not read a verified LVM report.");
            synchronize ();
            if (group.uuid != uuid || group.name != name || snapshot.advanced.lookup (group.path) != group)
                throw new IOError.NOT_FOUND ("The volume group changed during cache inspection.");
            return LvmCacheStatus.parse_report (output, uuid);
        }

        internal async LvmCacheStatus inspect_lvm_cache (string group_path, string group_uuid, string name, string uuid) throws Error {
            synchronize ();
            var group = snapshot.advanced.lookup (group_path) as StorageVolumeGroup;
            if (group == null || group.uuid != group_uuid || lvm_volume_by_uuid (group, uuid)?.name != name)
                throw new IOError.NOT_FOUND ("The cache volume changed.");
            var report = yield read_lvm_cache_report (group, backend_lifetime);
            var status = LvmCacheStatus.find (report, name);
            if (status == null || status.uuid != uuid || lvm_volume_by_uuid (group, uuid)?.name != name)
                throw new IOError.NOT_FOUND ("The cache identity could not be verified.");
            status.separation_block_reason = status.separation_block (LvmCacheStatus.find (report, status.pool_name));
            return status;
        }

        internal async void change_lvm_cache (StorageBlock anchor, string identity, string group_uuid,
            string origin_uuid, string candidate_uuid, bool detach) throws Error {
            synchronize ();
            StorageVolumeGroup group;
            var vg = require_lvm_context (anchor, identity, group_uuid, false, out group);
            var members = lvm_members (group);
            var origin = lvm_volume_by_uuid (group, origin_uuid);
            if (origin == null) throw new IOError.NOT_FOUND ("The origin logical volume changed.");
            var proxy = manager?.get_interface (origin.path, PREFIX + "LogicalVolume") as DBusProxy;
            if (proxy == null) throw new IOError.NOT_SUPPORTED ("UDisks does not expose the origin logical volume.");
            bool attach = candidate_uuid != "";
            string method = attach ? "CacheAttach" : detach ? "CacheDetach" : "CacheSplit";
            string title = attach ? "Attach LVM cache" : detach ? "Remove LVM cache" : "Split LVM cache";
            locks.acquire_members (anchor, members, snapshot.dependencies);
            var job = jobs.begin (title, anchor, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var token = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the origin and cache allocation");
                yield require_lvm_method (proxy, method, token);
                var origin_block = require_lvm_offline_mapping (origin);
                string origin_identity = modification_identity (origin_block);
                string origin_name = origin.name;
                var candidate = lvm_volume_by_uuid (group, candidate_uuid);
                string cache_name;
                string pool_uuid = "";
                var options = new Variant ("a{sv}", null);
                Variant parameters;
                StorageBlock? candidate_block = null;
                string candidate_identity = "";
                var before = yield read_lvm_cache_report (group, token);
                var original = LvmCacheStatus.find (before, origin_name);
                if (original == null || original.uuid != origin_uuid || original.layout != origin.lvm_layout)
                    throw new IOError.BUSY ("The cache origin changed during inspection.");
                if (attach) {
                    if (candidate == null || !(candidate in lvm_cache_candidates (origin)))
                        throw new IOError.NOT_SUPPORTED ("Choose an unused, active linear logical volume in the same group.");
                    candidate_block = require_lvm_offline_mapping (candidate);
                    candidate_identity = modification_identity (candidate_block);
                    cache_name = candidate.name;
                    var resource = LvmCacheStatus.find (before, cache_name);
                    if (resource == null || resource.uuid != candidate_uuid || resource.layout != "linear")
                        throw new IOError.BUSY ("The cache candidate changed during inspection.");
                    parameters = new Variant ("(s@a{sv})", cache_name, options);
                } else {
                    cache_name = original.pool_name;
                    var pool = LvmCacheStatus.find (before, cache_name);
                    string reason = original.separation_block (pool);
                    if (reason != "") throw new IOError.NOT_SUPPORTED (reason);
                    if (origin.allocation (snapshot) == LvmAllocation.INCOMPLETE)
                        throw new IOError.NOT_SUPPORTED ("The origin has incomplete physical allocation.");
                    pool_uuid = original.pool_uuid;
                    parameters = new Variant ("(@a{sv})", options);
                }
                require_lvm_idle (group, members, origin, candidate);
                yield KernelStorageSafety.require_idle (origin_block, token);
                if (candidate_block != null) {
                    yield KernelStorageSafety.require_idle (candidate_block, token);
                    ulong cancelled = token.cancelled.connect (() => job.cancellable.cancel ());
                    job.cancelable = true;
                    jobs.progress (job, "Checking that the cache candidate is empty", 0, true);
                    try {
                        token.set_error_if_cancelled ();
                        yield require_zero_cache_candidate (candidate_block, job, job.cancellable);
                        job.cancellable.set_error_if_cancelled ();
                    } finally {
                        SignalHandler.disconnect (token, cancelled);
                        job.cancelable = false;
                    }
                }
                if (!attach) {
                    var refreshed = yield read_lvm_cache_report (group, token);
                    var observed = LvmCacheStatus.find (refreshed, origin_name);
                    var pool = LvmCacheStatus.find (refreshed, cache_name);
                    if (observed == null || observed.uuid != origin_uuid || observed.pool_name != cache_name ||
                        observed.pool_uuid != pool_uuid ||
                        observed.separation_block (pool) != "")
                        throw new IOError.BUSY ("The cache relationship or pending-write state changed.");
                }
                synchronize ();
                if (require_lvm_context (anchor, identity, group_uuid, false, out group) != vg ||
                    lvm_volume_by_uuid (group, origin_uuid) != origin || origin.name != origin_name ||
                    manager?.get_interface (origin.path, PREFIX + "LogicalVolume") != proxy ||
                    require_lvm_offline_mapping (origin) != origin_block ||
                    modification_identity (origin_block) != origin_identity)
                    throw new IOError.BUSY ("The cache origin or volume group changed.");
                require_lvm_idle (group, members, origin, candidate);
                if (attach) {
                    if (candidate == null || candidate_block == null || candidate.name != cache_name ||
                        lvm_volume_by_uuid (group, candidate_uuid) != candidate ||
                        !(candidate in lvm_cache_candidates (origin)) || require_lvm_offline_mapping (candidate) != candidate_block ||
                        modification_identity (candidate_block) != candidate_identity)
                        throw new IOError.BUSY ("The cache candidate changed.");
                } else if (origin.lvm_layout != "cache" || origin.allocation (snapshot) == LvmAllocation.INCOMPLETE) {
                    throw new IOError.BUSY ("The cache relationship changed.");
                }
                uint64 size = origin_block.size;
                string content_uuid = origin_block.uuid;
                string content_type = origin_block.type_id;
                jobs.phase (job, StorageJobState.RUNNING, attach ? "Converting the empty cache candidate" : "Waiting for LVM to flush and separate the cache");
                jobs.expect_backend (job, attach ? "lvm-lv-make-cache" : "lvm-lv-split-cache", origin.path);
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, method, parameters, token);
                if (!reply.is_of_type (new VariantType ("()")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid cache reply.");
                string pending = "The volume group or origin layout has not been confirmed.";
                for (int i = 0; i < 100; i++) {
                    if (i % 10 == 0) yield poll_volume_group (vg, token);
                    yield settle_delay (token);
                    synchronize ();
                    var current = lvm_volume_by_uuid (group, origin_uuid);
                    pending = "The volume group or origin layout has not been confirmed.";
                    if (group.uuid != group_uuid || lvm_membership_identity (anchor) != identity ||
                        current == null || current.name != origin_name ||
                        current.lvm_layout != (attach ? "cache" : "linear") ||
                        current.allocation (snapshot) == LvmAllocation.INCOMPLETE ||
                        volume_group_has_backend_job (group, members)) continue;
                    var mapping = snapshot.blocks.lookup (current.block_path);
                    pending = "The origin mapping, size or content signature has not been confirmed.";
                    if (mapping == null || mapping.logical_volume != current || mapping.size != size ||
                        mapping.uuid != content_uuid || mapping.type_id != content_type) continue;
                    var report = yield read_lvm_cache_report (group, token);
                    var observed = LvmCacheStatus.find (report, origin_name);
                    var pool = LvmCacheStatus.find_uuid (report, attach ? candidate_uuid : pool_uuid);
                    pending = "The cache pool relationship or health has not been confirmed.";
                    if (observed == null || observed.uuid != origin_uuid || observed.layout != current.lvm_layout) continue;
                    if (attach) {
                        if (pool == null || pool.uuid != observed.pool_uuid || pool.name != observed.pool_name ||
                            pool.layout != "cache-pool" || !pool.no_health_flags () || !observed.active_dm_cache () ||
                            !observed.usage_known) continue;
                    } else {
                        if (observed.pool_name != "" ||
                            (detach ? pool != null : pool == null || pool.layout != "cache-pool")) continue;
                    }
                    require_lvm_job_succeeded (job);
                    result.successful = true;
                    result.summary = attach ? "LVM cache relationship verified" : "LVM cache separated and origin mapping verified";
                    return;
                }
                throw new IOError.TIMED_OUT (pending + " Reassess the volume before further changes.");
            } catch (Error error) {
                fail_lvm_operation (job, result, "Cache operation", dispatched, error);
                throw error;
            } finally {
                jobs.finish (job, result);
                locks.release (anchor);
            }
        }

        internal async void refresh_lvm_assessment (string path, string uuid) throws Error {
            synchronize ();
            var group = snapshot.advanced.lookup (path) as StorageVolumeGroup;
            var proxy = manager?.get_interface (path, PREFIX + "VolumeGroup") as DBusProxy;
            if (group == null || proxy == null || uuid == "" || group.uuid != uuid)
                throw new IOError.NOT_FOUND ("The selected volume group changed.");
            yield poll_volume_group (proxy, backend_lifetime);
            yield settle_delay (backend_lifetime);
            synchronize ();
            changed ();
        }

        internal uint64 lvm_pv_free (StorageBlock block) {
            var pv = manager?.get_interface (block.path, PREFIX + "PhysicalVolume") as DBusProxy;
            return LvmStructure.typed (pv?.get_cached_property ("FreeSize"), "t")?.get_uint64 () ?? 0;
        }

        internal string lvm_pv_domain (StorageBlock block) {
            foreach (var device in snapshot.dependencies.ancestors (block)) {
                var parent = device as StorageBlock;
                if (parent?.loop != null && parent.loop.backing_file != "")
                    return "loop:" + parent.loop.backing_file;
            }
            return block.drive_path != "/" ? "drive:" + block.drive_path : "";
        }

        internal StorageBlock[] lvm_placement_candidates (StorageVolumeGroup group) {
            StorageBlock[] result = {};
            foreach (var member in lvm_members (group)) {
                if (member.available && !member.read_only && !member.system_hint && member.uuid != "" &&
                    member.number != 0 && lvm_pv_domain (member) != "" && lvm_pv_free (member) > 0)
                    result += member;
            }
            return result;
        }

        internal async string[] available_lvm_layouts (string path, string uuid) throws Error {
            var group = snapshot.advanced.lookup (path) as StorageVolumeGroup;
            var proxy = manager?.get_interface (path, PREFIX + "VolumeGroup") as DBusProxy;
            if (group == null || group.uuid != uuid || proxy == null)
                throw new IOError.NOT_FOUND ("The volume group changed.");
            var token = backend_lifetime;
            yield require_lvm_method (proxy, "CreatePlainVolumeWithLayout", token);
            if (!FileUtils.test ("/usr/sbin/lvm", FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("The installed LVM2 layout capabilities are unavailable.");
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            launcher.setenv ("LVM_SYSTEM_DIR", "", true);
            launcher.setenv ("LC_ALL", "C", true);
            var process = launcher.spawnv ({ "/usr/sbin/lvm", "segtypes" });
            string? output;
            yield process.communicate_utf8_async (null, token, out output, null);
            if (!process.get_successful () || output == null)
                throw new IOError.NOT_SUPPORTED ("LVM2 did not report its available layouts.");
            string[] layouts = {};
            foreach (var entry in output.split ("\n")) {
                string layout = entry.strip ();
                if (layout != "") layouts += layout;
            }
            return layouts;
        }

        private void require_lvm_placement (StorageVolumeGroup group, string name, uint64 size,
            string layout, string[] paths) throws Error {
            if (!valid_lvm_name (name) || name == "snapshot" || name == "pvmove")
                throw new IOError.INVALID_ARGUMENT ("Enter a valid logical-volume name.");
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv != null && lv.group_path == group.path && lv.name == name)
                    throw new IOError.EXISTS ("A logical volume in this group already has this name.");
            }
            uint64 per_pv = LvmLayout.required_per_pv (layout, paths.length, size, group.extent_size);
            if (per_pv == 0)
                throw new IOError.INVALID_ARGUMENT ("The physical-volume count or extent alignment is invalid for this layout.");
            if (per_pv > group.free_size / paths.length)
                throw new IOError.NO_SPACE ("The group has too few free extents for this layout.");
            string[] domains = {};
            var candidates = lvm_placement_candidates (group);
            foreach (var path in paths) {
                var pv = snapshot.blocks.lookup (path);
                if (pv == null || !(pv in candidates))
                    throw new IOError.NOT_FOUND ("A selected physical volume is unavailable.");
                string domain = lvm_pv_domain (pv);
                if (domain == "" || domain in domains)
                    throw new IOError.INVALID_ARGUMENT ("Select distinct physical devices for the layout.");
                domains += domain;
                if (lvm_pv_free (pv) < per_pv)
                    throw new IOError.NO_SPACE ("A selected physical volume has too few free extents.");
            }
        }

        internal async void create_lvm_layout (StorageBlock anchor, string identity, string uuid, string name,
            uint64 size, string layout, string[] paths) throws Error {
            synchronize ();
            StorageVolumeGroup group;
            var proxy = require_lvm_context (anchor, identity, uuid, false, out group);
            var members = lvm_members (group);
            locks.acquire_members (anchor, members, snapshot.dependencies);
            var job = jobs.begin ("Create logical volume with placement", anchor, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var token = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking physical placement and free extents");
                var supported = yield available_lvm_layouts (group.path, group.uuid);
                if (!(layout in supported)) throw new IOError.NOT_SUPPORTED ("The installed LVM2 backend does not advertise this layout.");
                require_lvm_idle (group, members);
                foreach (var member in members) yield KernelStorageSafety.require_idle (member, token);
                yield poll_volume_group (proxy, token);
                yield settle_delay (token);
                synchronize ();
                if (require_lvm_context (anchor, identity, uuid, false, out group) != proxy)
                    throw new IOError.NOT_FOUND ("The volume-group object changed.");
                require_lvm_idle (group, members);
                require_lvm_placement (group, name, size, layout, paths);
                jobs.phase (job, StorageJobState.RUNNING, "Allocating the requested layout");
                jobs.expect_backend (job, "lvm-vg-create-volume", group.path);
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, "CreatePlainVolumeWithLayout",
                    new Variant ("(sts@ao@a{sv})", name, size, layout, new Variant.objv (paths),
                        new Variant ("a{sv}", null)), token);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid logical-volume path.");
                string path = reply.get_child_value (0).get_string ();
                string created_uuid = "";
                bool redundant = layout != "linear" && layout != "raid0";
                double last_progress = -1;
                int64 deadline = get_monotonic_time () + (redundant ? 180 : 10) * TimeSpan.SECOND;
                int64 max_deadline = get_monotonic_time () + 30 * TimeSpan.MINUTE;
                for (int i = 0; get_monotonic_time () < int64.min (deadline, max_deadline); i++) {
                    if (i % 10 == 0) yield poll_volume_group (proxy, token);
                    yield settle_delay (token);
                    synchronize ();
                    var created = snapshot.advanced.lookup (path) as StorageLogicalVolume;
                    if (created == null || created.group_path != group.path || group.uuid != uuid ||
                        created.uuid == "" || created.name != name) continue;
                    if (created_uuid != "" && created_uuid != created.uuid)
                        throw new IOError.NOT_FOUND ("The created logical volume changed identity.");
                    created_uuid = created.uuid;
                    if (redundant) {
                        bool known = created.sync_ratio >= 0 && created.sync_ratio <= 1;
                        if (known && created.sync_ratio > last_progress) {
                            last_progress = created.sync_ratio;
                            deadline = get_monotonic_time () + 180 * TimeSpan.SECOND;
                        }
                        jobs.progress (job, "Waiting for initial synchronization", created.sync_ratio,
                            known);
                    }
                    if (lvm_membership_identity (anchor) != identity || !group.missing_pvs_known ||
                        group.missing_pv_uuids.length != 0 || created.size != size || created.lvm_layout != layout ||
                        created.allocation (snapshot) != LvmAllocation.COMPLETE ||
                        created.structure?.verifies_placement (paths) != true ||
                        (redundant && created.sync_ratio != 1) || volume_group_has_backend_job (group, members)) continue;
                    require_lvm_job_succeeded (job);
                    result.successful = true;
                    result.summary = "Logical-volume layout and physical placement verified";
                    return;
                }
                throw new IOError.TIMED_OUT ("The backend did not confirm the requested layout, placement and synchronization.");
            } catch (Error error) {
                fail_lvm_operation (job, result, "Layout creation", dispatched, error);
                throw error;
            } finally {
                jobs.finish (job, result);
                locks.release (anchor);
            }
        }

        internal StorageBlock[] lvm_repair_candidates (StorageLogicalVolume lv) {
            var group = snapshot.advanced.lookup (lv.group_path) as StorageVolumeGroup;
            var tree = lv.structure;
            if (group == null || !group.missing_pvs_known || group.missing_pv_uuids.length == 0 ||
                tree == null || lv.lvm_layout != "raid1" || lv.uuid == "" || !lv.active ||
                lv.sync_ratio != 1 || lv.origin_path != "/" || lv.thin_pool_path != "/") return {};
            uint64 needed = tree.raid1_replacement_bytes (snapshot, group.path);
            if (needed == 0 || group.extent_size == 0 || needed % group.extent_size != 0 ||
                tree.raid1_surviving_pv (snapshot, group.path) == "/") return {};
            StorageBlock[] eligible = {};
            foreach (var member in lvm_members (group)) {
                if (!member.available || member.read_only || member.system_hint || member.uuid == "" ||
                    member.number == 0 || tree.uses_pv (member.path) || lvm_pv_free (member) < needed) continue;
                string domain = lvm_pv_domain (member);
                bool shared = domain == "";
                foreach (var existing in lvm_members (group))
                    if (tree.uses_pv (existing.path) && (lvm_pv_domain (existing) == "" ||
                        lvm_pv_domain (existing) == domain || member.number == existing.number)) shared = true;
                if (!shared) eligible += member;
            }
            return eligible;
        }

        private StorageLogicalVolume? lvm_volume_by_uuid (StorageVolumeGroup group, string uuid) {
            if (uuid == "") return null;
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv != null && lv.group_path == group.path && lv.uuid == uuid) return lv;
            }
            return null;
        }

        private string[] lvm_cleanup_volumes (StorageVolumeGroup group) throws Error {
            string[] volumes = {};
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv == null || lv.group_path != group.path) continue;
                if (lv.uuid == "" || lv.allocation (snapshot) != LvmAllocation.COMPLETE)
                    throw new IOError.NOT_SUPPORTED ("A logical volume has incomplete or unresolved allocation. Reconnect the missing devices or assess repair first.");
                volumes += lv.uuid;
            }
            return volumes;
        }

        internal async void recover_lvm (StorageBlock anchor, string identity, string uuid,
            string missing, string repair_uuid, string replacement_path) throws Error {
            synchronize ();
            StorageVolumeGroup group;
            var vg = require_lvm_context (anchor, identity, uuid, true, out group);
            var members = lvm_members (group);
            bool repairing = repair_uuid != "";
            string method = repairing ? "Repair" : "RemoveMissingPhysicalVolumes";
            string title = repairing ? "Repair LVM RAID 1" : "Remove missing physical-volume records";
            locks.acquire_members (anchor, members, snapshot.dependencies);
            var job = jobs.begin (title, anchor, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var token = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking allocation, identities and dependencies");
                var lv = lvm_volume_by_uuid (group, repair_uuid);
                var proxy = repairing && lv != null ? manager?.get_interface (lv.path, PREFIX + "LogicalVolume") as DBusProxy : vg;
                if (proxy == null || (repairing && lv == null))
                    throw new IOError.NOT_FOUND ("The logical volume changed.");
                yield require_lvm_method (proxy, method, token);
                yield poll_volume_group (vg, token);
                yield settle_delay (token);
                synchronize ();
                require_lvm_idle (group, members, lv);
                var active_block = lv != null ? snapshot.blocks.lookup (lv.block_path) : null;
                string block_identity = active_block != null ? modification_identity (active_block) : "";
                if (repairing) {
                    if (active_block == null || active_block.logical_volume != lv || active_block.read_only)
                        throw new IOError.NOT_SUPPORTED ("The active RAID mapping could not be identified.");
                    var safety = StorageSafetyService.assess (active_block, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || safety.mounted ||
                        active_block.mount_configurations.length != 0 ||
                        active_block.encryption_configurations.length != 0 || active_block.swap_active)
                        throw new IOError.BUSY ("Unmount the RAID volume and close its dependent devices first.");
                    yield KernelStorageSafety.require_idle (active_block, token);
                    var replacement = snapshot.blocks.lookup (replacement_path);
                    if (replacement == null || !(replacement in lvm_repair_candidates (lv)))
                        throw new IOError.BUSY ("The replacement volume is unavailable or has insufficient space.");
                    yield KernelStorageSafety.require_idle (replacement, token);
                } else {
                    foreach (var member in members) yield KernelStorageSafety.require_idle (member, token);
                }
                synchronize ();
                if (require_lvm_context (anchor, identity, uuid, true, out group) != vg ||
                    group.missing_pv_uuids.length == 0 || string.joinv ("\n", group.missing_pv_uuids) != missing)
                    throw new IOError.BUSY ("The missing physical-volume list changed after confirmation.");
                require_lvm_idle (group, members, lv);
                string[] volumes = {};
                uint64 size = 0;
                string survivor = "/";
                var options = new Variant ("a{sv}", null);
                Variant parameters;
                if (repairing) {
                    var replacement = snapshot.blocks.lookup (replacement_path);
                    if (lv == null || active_block == null || modification_identity (active_block) != block_identity ||
                        require_lvm_offline_mapping (lv) != active_block || lvm_volume_by_uuid (group, repair_uuid) != lv ||
                        manager?.get_interface (lv.path, PREFIX + "LogicalVolume") != proxy ||
                        !(replacement in lvm_repair_candidates (lv)))
                        throw new IOError.BUSY ("The RAID layout or replacement capacity changed.");
                    size = lv.size;
                    survivor = lv.structure.raid1_surviving_pv (snapshot, group.path);
                    parameters = new Variant ("(@ao@a{sv})", new Variant.objv ({ replacement_path }), options);
                } else {
                    volumes = lvm_cleanup_volumes (group);
                    parameters = new Variant ("(@a{sv})", options);
                }
                jobs.phase (job, StorageJobState.RUNNING, title);
                jobs.expect_backend (job, repairing ? "lvm-lvol-repair" : "lvm-vg-rem-device",
                    repairing ? lv.path : group.path);
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, method, parameters, token);
                if (!reply.is_of_type (new VariantType ("()")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid recovery reply.");
                double last_progress = -1;
                int64 deadline = get_monotonic_time () + (repairing ? 180 : 10) * TimeSpan.SECOND;
                int64 max_deadline = get_monotonic_time () + 30 * TimeSpan.MINUTE;
                for (int i = 0; get_monotonic_time () < int64.min (deadline, max_deadline); i++) {
                    if (i % 10 == 0) yield poll_volume_group (vg, token);
                    yield settle_delay (token);
                    synchronize ();
                    if (group.uuid != uuid || snapshot.advanced.lookup (group.path) != group)
                        throw new IOError.NOT_FOUND ("The volume group disappeared during verification.");
                    if (repairing) {
                        var repaired = lvm_volume_by_uuid (group, repair_uuid);
                        if (repaired == null) continue;
                        double progress = repaired.sync_ratio;
                        bool known = progress >= 0 && progress <= 1;
                        if (known && progress > last_progress) {
                            last_progress = progress;
                            deadline = get_monotonic_time () + 180 * TimeSpan.SECOND;
                        }
                        jobs.progress (job, "Waiting for RAID reconstruction", progress, known);
                        if (lvm_membership_identity (anchor) != identity ||
                            repaired.size != size || repaired.lvm_layout != "raid1" || progress != 1 ||
                            repaired.allocation (snapshot) != LvmAllocation.COMPLETE ||
                            repaired.structure?.verifies_placement ({ survivor, replacement_path }) != true) continue;
                    } else {
                        if (!group.missing_pvs_known || group.missing_pv_uuids.length != 0) continue;
                        foreach (var id in volumes) {
                            var remaining = lvm_volume_by_uuid (group, id);
                            if (remaining == null || remaining.allocation (snapshot) != LvmAllocation.COMPLETE)
                                throw new IOError.FAILED ("A previously verified logical volume is absent or its allocation is unresolved.");
                        }
                    }
                    if (volume_group_has_backend_job (group, members)) continue;
                    require_lvm_job_succeeded (job);
                    result.successful = true;
                    result.summary = repairing ? "RAID reconstruction and replacement allocation verified" :
                        "Missing records removed and remaining allocations verified";
                    return;
                }
                throw new IOError.TIMED_OUT ("UDisks has yet to confirm the requested recovery outcome. Reassess the group before making further changes.");
            } catch (Error error) {
                fail_lvm_operation (job, result, "Recovery", dispatched, error);
                throw error;
            } finally {
                jobs.finish (job, result);
                locks.release (anchor);
            }
        }

        internal static async void require_lvm_method (DBusProxy proxy, string method, Cancellable token) throws Error {
            yield require_udisks_method (proxy, method, token);
        }

        private static async void require_udisks_method (DBusProxy proxy, string method, Cancellable token) throws Error {
            var reply = yield proxy.get_connection ().call (proxy.get_name_owner (), proxy.get_object_path (),
                "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType ("(s)"),
                DBusCallFlags.NONE, 5000, token);
            if (!has_luks_method (reply.get_child_value (0).get_string (), proxy.get_interface_name (), method))
                throw new IOError.NOT_SUPPORTED ("The installed UDisks interface does not advertise " + method + ".");
        }

        private void require_lvm_rename_name (StorageVolumeGroup group, string name) throws Error {
            if (!valid_lvm_name (name) || name == group.name)
                throw new IOError.INVALID_ARGUMENT ("Enter a different valid LVM volume-group name.");
            foreach (var item in snapshot.advanced.get_values ())
                if (item is StorageVolumeGroup && item.name == name)
                    throw new IOError.EXISTS ("A volume group already has this name.");
        }

        private async void require_no_vg_references (StorageVolumeGroup group, Cancellable token) throws Error {
            string[] args = { "--vg-references", group.path, group.name, group.uuid };
            var process = start_crypttab_inspector (args);
            string? output;
            yield process.communicate_utf8_async (null, token, out output, null);
            if (!process.get_if_exited ())
                throw new IOError.FAILED ("Persistent-reference inspection did not complete.");
            switch (process.get_exit_status ()) {
            case 0: break;
            case 126: case 127:
                throw new IOError.PERMISSION_DENIED ("Authorization to check persistent volume-group references was denied or cancelled.");
            case 14:
                throw new IOError.NOT_FOUND ("The volume group or persistent configuration changed during inspection.");
            default:
                throw new IOError.FAILED ("Boot or storage configuration could not be safely inspected.");
            }
            string report = output?.strip () ?? "";
            if (!Regex.match_simple ("^vg-references:[0-7]$", report))
                throw new IOError.INVALID_DATA ("The persistent-reference inspector returned an invalid result.");
            int flags = report[report.length - 1] - '0';
            if (flags != 0) {
                string[] sources = {};
                if ((flags & 1) != 0) sources += "/proc/cmdline";
                if ((flags & 2) != 0) sources += "/etc/fstab";
                if ((flags & 4) != 0) sources += "/etc/crypttab";
                throw new IOError.BUSY ("Persistent references to this volume group were found in " +
                    string.joinv (", ", sources) + ".");
            }
        }

        internal async void rename_volume_group (StorageBlock anchor, string identity, string uuid, string name) throws Error {
            synchronize ();
            StorageVolumeGroup group;
            var proxy = require_lvm_context (anchor, identity, uuid, false, out group);
            var members = lvm_members (group);
            locks.acquire_members (anchor, members, snapshot.dependencies);
            var job = jobs.begin ("Rename volume group", anchor, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var token = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking persistent references and inactive storage");
                yield require_lvm_method (proxy, "Rename", token);
                require_lvm_rename_name (group, name);
                require_lvm_idle (group, members);
                foreach (var member in members) yield KernelStorageSafety.require_idle (member, token);
                string old_name = group.name;
                yield require_no_vg_references (group, token);
                synchronize ();
                if (require_lvm_context (anchor, identity, uuid, false, out group) != proxy || group.name != old_name)
                    throw new IOError.NOT_FOUND ("The volume-group object changed.");
                require_lvm_idle (group, members);
                require_lvm_rename_name (group, name);
                foreach (var member in members) yield KernelStorageSafety.require_idle (member, token);
                synchronize ();
                if (require_lvm_context (anchor, identity, uuid, false, out group) != proxy || group.name != old_name)
                    throw new IOError.NOT_FOUND ("The volume-group object changed.");
                require_lvm_idle (group, members);
                require_lvm_rename_name (group, name);
                string[] volumes = {};
                foreach (var item in snapshot.advanced.get_values ()) {
                    var lv = item as StorageLogicalVolume;
                    if (lv != null && lv.group_path == group.path) {
                        if (lv.uuid == "") throw new IOError.NOT_SUPPORTED ("A logical volume has no stable identity.");
                        volumes += lv.uuid;
                    }
                }
                jobs.phase (job, StorageJobState.RUNNING, "Renaming the volume group");
                jobs.expect_backend (job, "lvm-vg-rename", group.path);
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, "Rename",
                    new Variant ("(s@a{sv})", name, new Variant ("a{sv}", null)), token);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid volume-group path.");
                string path = reply.get_child_value (0).get_string ();
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    var changed = snapshot.advanced.lookup (path) as StorageVolumeGroup;
                    if (changed != null && changed.uuid == uuid && changed.name == name &&
                        anchor.volume_group == changed && lvm_membership_identity (anchor) == identity) {
                        int found = 0;
                        int total = 0;
                        foreach (var item in snapshot.advanced.get_values ()) {
                            var lv = item as StorageLogicalVolume;
                            if (lv != null && lv.group_path == path) {
                                total++;
                                if (lv.uuid in volumes) found++;
                            }
                        }
                        if (total == volumes.length && found == volumes.length &&
                            changed.missing_pvs_known && changed.missing_pv_uuids.length == 0 &&
                            !volume_group_has_backend_job (changed, members)) {
                            require_lvm_job_succeeded (job);
                            outcome.successful = true;
                            outcome.summary = "Volume group renamed and membership verified";
                            return;
                        }
                    }
                    yield settle_delay (token);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the renamed volume group and its members.");
            } catch (Error error) {
                fail_lvm_operation (job, outcome, "Volume-group rename", dispatched, error);
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (anchor);
            }
        }

        internal static async void poll_volume_group (DBusProxy proxy, Cancellable token) throws Error {
            var reply = yield proxy.call ("Poll", null, DBusCallFlags.NONE, 3000, token);
            if (!reply.is_of_type (new VariantType ("()")))
                throw new IOError.INVALID_DATA ("UDisks returned an invalid LVM poll result.");
        }

        internal async void change_lvm_membership (StorageBlock member, string identity, string method,
            bool wipe = false) throws Error {
            bool migrate = method == "EmptyDevice";
            bool delete_group = method == "Delete";
            if (!migrate && !delete_group && method != "RemoveDevice")
                throw new IOError.INVALID_ARGUMENT ("Unsupported LVM membership operation.");
            synchronize ();
            require_volume (member, "Block");
            var group = member.volume_group;
            var proxy = group != null ? manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (group == null || proxy == null || uuid == "")
                throw new IOError.NOT_SUPPORTED ("The selected volume group could not be identified.");
            StorageBlock[] members = {};
            string[] identities = {};
            uint64[] numbers = {};
            foreach (var candidate in snapshot.blocks.get_values ()) {
                if (candidate.volume_group != group) continue;
                members += candidate;
                identities += modification_identity (candidate);
                numbers += candidate.number;
            }
            if (members.length == 0 || (!delete_group && members.length < 2))
                throw new IOError.NOT_SUPPORTED ("At least one other physical volume is required.");
            locks.acquire_members (member, members, snapshot.dependencies);
            string title = migrate ? "Migrate LVM physical volume" : delete_group ? "Delete LVM volume group" : "Remove LVM physical volume";
            var job = jobs.begin (title, member, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking physical volumes and allocated extents");
                for (int i = 0; i < members.length; i++) {
                    var pv = members[i];
                    var safety = StorageSafetyService.assess (pv, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.mounted ||
                        pv.read_only || pv.mount_configurations.length != 0 || pv.encryption_configurations.length != 0)
                        throw new IOError.BUSY ("A physical volume is protected or its dependencies are unknown.");
                    if (delete_group || (!migrate && pv == member))
                        yield KernelStorageSafety.require_idle (pv, lifetime);
                }
                if (proxy.get_cached_property ("NeedsPolling")?.get_boolean () == true)
                    yield poll_volume_group (proxy, lifetime);
                synchronize ();
                if (identity == "" || storage_membership_identity (member, false) != identity ||
                    manager?.get_interface (group.path, PREFIX + "VolumeGroup") != proxy ||
                    proxy.get_cached_property ("UUID")?.get_string () != uuid ||
                    (proxy.get_cached_property ("MissingPhysicalVolumes")?.n_children () ?? 1) != 0 ||
                    volume_group_has_backend_job (group, members))
                    throw new IOError.BUSY ("The volume group changed, has missing members, or is already being modified.");

                uint64 allocated = 0, available_elsewhere = 0;
                int live_count = 0;
                foreach (var candidate in snapshot.blocks.get_values ())
                    if (candidate.volume_group == group) live_count++;
                if (live_count != members.length)
                    throw new IOError.NOT_FOUND ("The volume-group member set changed.");
                for (int i = 0; i < members.length; i++) {
                    var pv = members[i];
                    if (creation_identity_changed (pv, identities[i]) || pv.volume_group != group)
                        throw new IOError.NOT_FOUND ("A physical-volume identity changed.");
                    var physical = require_volume (pv, "PhysicalVolume");
                    uint64 size = physical.get_cached_property ("Size")?.get_uint64 () ?? 0;
                    uint64 free = physical.get_cached_property ("FreeSize")?.get_uint64 () ?? uint64.MAX;
                    if (size == 0 || free > size)
                        throw new IOError.INVALID_DATA ("UDisks did not report valid physical-volume extents.");
                    if (pv == member) allocated = size - free;
                    else available_elsewhere += uint64.min (free, uint64.MAX - available_elsewhere);
                    if (delete_group && free != size)
                        throw new IOError.BUSY ("Only an empty volume group can be deleted.");
                }
                if (delete_group) {
                    foreach (var item in snapshot.advanced.get_values ()) {
                        var volume = item as StorageLogicalVolume;
                        if (volume != null && volume.group_path == group.path)
                            throw new IOError.BUSY ("Delete all logical volumes before deleting the group.");
                    }
                } else if (migrate) {
                    if (allocated == 0) {
                        outcome.successful = true;
                        outcome.summary = "The physical volume is already empty";
                        return;
                    }
                    if (allocated > available_elsewhere)
                        throw new IOError.NO_SPACE ("The remaining physical volumes do not have enough free extents.");
                } else if (allocated != 0) {
                    throw new IOError.BUSY ("Migrate the allocated extents before removing this physical volume.");
                }
                var options = new Variant ("a{sv}", null);
                Variant parameters;
                if (migrate) parameters = new Variant ("(o@a{sv})", member.path, options);
                else if (delete_group) parameters = new Variant ("(b@a{sv})", wipe, options);
                else parameters = new Variant ("(ob@a{sv})", member.path, wipe, options);
                jobs.phase (job, StorageJobState.RUNNING, title);
                dispatched = true;
                if (migrate) jobs.expect_backend (job, "lvm-vg-empty-device", group.path);
                yield call_tracked_method (job, proxy, method, parameters, lifetime);
                int64 deadline = get_monotonic_time () + 15 * TimeSpan.SECOND;
                int64 next_poll = 0;
                while (get_monotonic_time () < deadline) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    if (job.backend_completed && !job.backend_successful)
                        throw new IOError.FAILED (job.error_message != "" ? job.error_message : "The UDisks LVM job failed.");
                    var live_group = manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy;
                    bool same_group = live_group == proxy && proxy.get_cached_property ("UUID")?.get_string () == uuid;
                    if (!delete_group && !same_group)
                        throw new IOError.NOT_FOUND ("The volume group changed while verifying the operation.");
                    if (!delete_group && get_monotonic_time () >= next_poll) {
                        yield poll_volume_group (proxy, lifetime);
                        next_poll = get_monotonic_time () + TimeSpan.SECOND;
                        synchronize ();
                        lifetime.set_error_if_cancelled ();
                        if (manager?.get_interface (group.path, PREFIX + "VolumeGroup") != proxy ||
                            proxy.get_cached_property ("UUID")?.get_string () != uuid)
                            throw new IOError.NOT_FOUND ("The volume group changed during polling.");
                    }
                    bool verified = false;
                    if (migrate && manager?.get_interface (group.path, PREFIX + "VolumeGroup") == proxy &&
                        proxy.get_cached_property ("UUID")?.get_string () == uuid &&
                        !volume_group_has_backend_job (group, members) &&
                        snapshot.blocks.lookup (member.path) == member && member.volume_group == group) {
                        var physical = manager?.get_interface (member.path, PREFIX + "PhysicalVolume") as DBusProxy;
                        uint64 size = physical?.get_cached_property ("Size")?.get_uint64 () ?? 0;
                        verified = size > 0 && physical?.get_cached_property ("FreeSize")?.get_uint64 () == size;
                    } else if (!migrate) {
                        verified = delete_group ? available () && !snapshot.advanced.contains (group.path) : same_group;
                        foreach (var item in snapshot.advanced.get_values ()) {
                            if (delete_group && item is StorageLogicalVolume &&
                                ((StorageLogicalVolume) item).group_path == group.path)
                                verified = false;
                        }
                        for (int i = 0; i < members.length; i++) {
                            if (!delete_group && members[i] != member) continue;
                            var current = snapshot.blocks.lookup (members[i].path);
                            verified &= current != null && current.available && current.number == numbers[i] &&
                                current.physical_volume_group_path == "/" &&
                                (wipe ? current.type_id != "LVM2_member" : current.type_id == "LVM2_member");
                        }
                    }
                    if (verified) {
                        outcome.successful = true;
                        outcome.summary = migrate ? "Physical volume emptied" : delete_group ? "Volume group deleted" : "Physical volume removed";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the requested LVM membership change.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the LVM membership change", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (member);
            }
        }

        internal async void add_lvm_physical_volume (StorageBlock anchor, StorageBlock member,
            string anchor_identity, string member_identity) throws Error {
            synchronize ();
            require_volume (anchor, "Block");
            require_volume (member, "Block");
            var group = anchor.volume_group;
            var proxy = group != null ? manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (group == null || proxy == null || uuid == "" || !can_use_group_member (member))
                throw new IOError.NOT_SUPPORTED ("A verified volume group and unused member are required.");
            locks.acquire_members (anchor, { member }, snapshot.dependencies);
            var job = jobs.begin ("Add LVM physical volume", anchor, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            uint64 number = member.number;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Verifying the volume group and unused member");
                var safety = StorageSafetyService.assess (anchor, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || anchor.read_only)
                    throw new IOError.BUSY ("The volume group is protected or its dependencies are unknown.");
                yield KernelStorageSafety.require_idle (member, lifetime);
                synchronize ();
                if (creation_identity_changed (anchor, anchor_identity) || creation_identity_changed (member, member_identity) ||
                    anchor.volume_group != group || manager?.get_interface (group.path, PREFIX + "VolumeGroup") != proxy ||
                    proxy.get_cached_property ("UUID")?.get_string () != uuid || !can_use_group_member (member))
                    throw new IOError.NOT_FOUND ("The volume group or member changed after confirmation.");
                jobs.phase (job, StorageJobState.RUNNING, "Adding the physical volume");
                dispatched = true;
                yield call_tracked_method (job, proxy, "AddDevice",
                    new Variant ("(o@a{sv})", member.path, new Variant ("a{sv}", null)), lifetime);
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    var current = snapshot.blocks.lookup (member.path);
                    if (manager?.get_interface (group.path, PREFIX + "VolumeGroup") != proxy ||
                        proxy.get_cached_property ("UUID")?.get_string () != uuid)
                        break;
                    if (current != null && current.available && current.number == number &&
                        current.physical_volume_group_path == group.path) {
                        outcome.successful = true;
                        outcome.summary = "Physical volume added";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the new physical-volume membership.");
            } catch (Error error) {
                outcome.fail ("Could not confirm physical-volume addition", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (anchor);
            }
        }

        internal StorageLogicalVolume[] logical_volumes_for (StorageBlock context) {
            string group = context.volume_group?.path ?? context.logical_volume?.group_path ?? "/";
            StorageLogicalVolume[] volumes = {};
            foreach (var item in snapshot.advanced.get_values ()) {
                var lv = item as StorageLogicalVolume;
                if (lv != null && group != "/" && lv.group_path == group && lv.uuid != "")
                    volumes += lv;
            }
            return volumes;
        }

        private void require_independent_lv (DBusProxy proxy, StorageLogicalVolume volume,
            bool allow_snapshot = false, bool allow_thin = false) throws Error {
            string origin = proxy.get_cached_property ("Origin")?.get_string () ?? "";
            string pool = proxy.get_cached_property ("ThinPool")?.get_string () ?? "";
            bool thin = allow_thin && volume.thin_pool_path != "/";
            if (proxy.get_cached_property ("Type")?.get_string () != "block" || origin != volume.origin_path ||
                (!allow_snapshot && !thin && origin != "/") ||
                pool != (thin ? volume.thin_pool_path : "/"))
                throw new IOError.NOT_SUPPORTED ("The logical volume has an unsupported pool or origin relationship.");
            if (thin) require_thin_pool (volume);
            foreach (var item in snapshot.advanced.get_values ()) {
                var candidate = item as StorageLogicalVolume;
                if (candidate == null || candidate.group_path != volume.group_path || candidate == volume) continue;
                var related = manager?.get_interface (candidate.path, PREFIX + "LogicalVolume") as DBusProxy;
                if (related == null || related.get_cached_property ("Origin")?.get_string () == volume.path ||
                    related.get_cached_property ("ThinPool")?.get_string () == volume.path)
                    throw new IOError.BUSY ("A snapshot or thin volume depends on this logical volume.");
            }
        }

        private StorageLogicalVolume require_thin_pool (StorageLogicalVolume volume) throws Error {
            var pool = snapshot.advanced.lookup (volume.thin_pool_path) as StorageLogicalVolume;
            if (pool == null || pool.uuid == "" || pool.lvm_type != "pool" || pool.group_path != volume.group_path)
                throw new IOError.NOT_FOUND ("The thin pool identity could not be verified.");
            return pool;
        }

        internal async void change_thin_pool (StorageBlock context, string path, string uuid,
            string identity, uint64 new_size, bool deactivate = false) throws Error {
            synchronize ();
            require_volume (context, "Block");
            var group = context.volume_group;
            var pool = snapshot.advanced.lookup (path) as StorageLogicalVolume;
            var proxy = manager?.get_interface (path, PREFIX + "LogicalVolume") as DBusProxy;
            var vg = group != null ? manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            string vg_uuid = vg?.get_cached_property ("UUID")?.get_string () ?? "";
            if (group == null || pool == null || pool.lvm_type != "pool" || pool.group_path != group.path ||
                uuid == "" || pool.uuid != uuid || proxy == null || vg == null || vg_uuid == "" ||
                creation_identity_changed (context, identity))
                throw new IOError.NOT_FOUND ("The selected thin pool or volume group changed.");
            bool deleting = new_size == 0 && !deactivate;
            uint64 previous_size = pool.size;
            StorageBlock[] members = {};
            string[] identities = {};
            foreach (var block in snapshot.blocks.get_values ()) {
                if (block.volume_group != group) continue;
                members += block;
                identities += modification_identity (block);
            }
            locks.acquire_members (context, members, snapshot.dependencies);
            var job = jobs.begin (deactivate ? "Deactivate empty thin pool" :
                deleting ? "Delete thin pool" : "Expand thin pool", context, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Verifying pool dependencies and physical extents");
                foreach (var member in members) {
                    var safety = StorageSafetyService.assess (member, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || member.read_only)
                        throw new IOError.BUSY ("The volume group contains protected or unresolved storage.");
                    if (deleting) yield KernelStorageSafety.require_idle (member, lifetime);
                }
                synchronize ();
                if (manager?.get_interface (path, PREFIX + "LogicalVolume") != proxy ||
                    manager?.get_interface (group.path, PREFIX + "VolumeGroup") != vg ||
                    snapshot.advanced.lookup (path) != pool || pool.uuid != uuid ||
                    vg.get_cached_property ("UUID")?.get_string () != vg_uuid ||
                    pool.size != previous_size || creation_identity_changed (context, identity) ||
                    (vg.get_cached_property ("MissingPhysicalVolumes")?.n_children () ?? 1) != 0 ||
                    volume_group_has_backend_job (group, members))
                    throw new IOError.BUSY ("The pool or volume group changed, is incomplete, or is busy.");
                int live_members = 0;
                foreach (var member in snapshot.blocks.get_values ())
                    if (member.volume_group == group) live_members++;
                if (live_members != members.length)
                    throw new IOError.NOT_FOUND ("The physical member set changed.");
                for (int i = 0; i < members.length; i++)
                    if (creation_identity_changed (members[i], identities[i]) || members[i].volume_group != group)
                        throw new IOError.NOT_FOUND ("A physical member changed.");
                var children = new HashTable<string, string> (str_hash, str_equal);
                foreach (var item in snapshot.advanced.get_values ()) {
                    var lv = item as StorageLogicalVolume;
                    if (lv == null || (lv.thin_pool_path != path && lv.origin_path != path)) continue;
                    if (lv.uuid == "")
                        throw new IOError.NOT_FOUND ("A dependent volume cannot be identified.");
                    children.insert (lv.path, lv.uuid);
                }
                var usage = new ThinPoolUsage (snapshot, pool);
                uint64 free_before = vg.get_cached_property ("FreeSize")?.get_uint64 () ?? uint64.MAX;
                uint64 extent = vg.get_cached_property ("ExtentSize")?.get_uint64 () ?? 0;
                if (free_before == uint64.MAX || extent == 0 || previous_size == 0)
                    throw new IOError.INVALID_DATA ("The volume group did not report valid extent geometry.");
                if (deleting || deactivate) {
                    if (children.size () != 0 || pool.active != deactivate ||
                        (proxy.get_cached_property ("ChildConfiguration")?.n_children () ?? 1) != 0 ||
                        proxy.get_cached_property ("BlockDevice")?.get_string () != "/")
                        throw new IOError.BUSY ("The pool must be empty, in the expected active state, and have no persistent configuration.");
                } else if (new_size <= previous_size || new_size % extent != 0 ||
                    new_size - previous_size > free_before || !usage.active || !usage.usage_known) {
                    throw new IOError.NOT_SUPPORTED ("Choose an extent-aligned growth size that fits the VG. The pool must be active with known usage.");
                }
                jobs.phase (job, StorageJobState.RUNNING, deactivate ? "Deactivating the empty thin pool" :
                    deleting ? "Deleting the empty thin pool" : "Expanding thin-pool data capacity");
                dispatched = true;
                var options = new Variant ("a{sv}", null);
                yield call_tracked_method (job, proxy, deactivate ? "Deactivate" : deleting ? "Delete" : "Resize",
                    deleting || deactivate ? new Variant ("(@a{sv})", options) :
                        new Variant ("(t@a{sv})", new_size, options), lifetime);
                yield poll_volume_group (vg, lifetime);
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    if (manager?.get_interface (group.path, PREFIX + "VolumeGroup") != vg ||
                        vg.get_cached_property ("UUID")?.get_string () != vg_uuid)
                        break;
                    var current = snapshot.advanced.lookup (path) as StorageLogicalVolume;
                    uint64 free = vg.get_cached_property ("FreeSize")?.get_uint64 () ?? uint64.MAX;
                    bool verified = deleting ? current == null && free != uint64.MAX && free > free_before :
                        deactivate ? current?.uuid == uuid && !current.active && current.size == previous_size &&
                            proxy.get_cached_property ("BlockDevice")?.get_string () == "/" :
                        current?.uuid == uuid && current.size == new_size &&
                        new ThinPoolUsage (snapshot, current).usage_known && free != uint64.MAX && free < free_before;
                    foreach (var child_path in children.get_keys ()) {
                        var child = snapshot.advanced.lookup (child_path) as StorageLogicalVolume;
                        verified &= child?.uuid == children.lookup (child_path) && child.thin_pool_path == path;
                    }
                    if (verified) {
                        result.successful = true;
                        result.summary = deactivate ? "Empty thin pool deactivated" :
                            deleting ? "Empty thin pool deleted" : "Thin-pool data capacity expanded";
                        return;
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the thin-pool result.");
            } catch (Error error) {
                result.fail ("Could not confirm the thin-pool operation", error);
                if (dispatched) result.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, result);
                locks.release (context);
            }
        }

        internal async string change_logical_volume_state (StorageBlock context, string path, string uuid,
            string context_identity, string method) throws Error {
            if (method != "Activate" && method != "Deactivate" && method != "Delete")
                throw new IOError.INVALID_ARGUMENT ("Unsupported logical-volume operation.");
            synchronize ();
            require_volume (context, "Block");
            var volume = snapshot.advanced.lookup (path) as StorageLogicalVolume;
            var proxy = manager?.get_interface (path, PREFIX + "LogicalVolume") as DBusProxy;
            string group = context.volume_group?.path ?? context.logical_volume?.group_path ?? "/";
            if (volume == null || proxy == null || uuid == "" || volume.uuid != uuid || volume.group_path != group ||
                modification_identity (context) != context_identity)
                throw new IOError.NOT_FOUND ("The selected logical volume or group changed.");
            bool activate = method == "Activate";
            bool deleting = method == "Delete";
            bool was_active = volume.active;
            bool snapshot_deletion = deleting && volume.origin_path != "/";
            bool thin = volume.thin_pool_path != "/";
            string pool_path = volume.thin_pool_path;
            string pool_uuid = thin ? require_thin_pool (volume).uuid : "";
            if (deleting ? was_active && (!snapshot_deletion || thin) : activate == was_active)
                throw new IOError.BUSY (deleting ? "Deactivate the logical volume before deleting it." :
                    "The logical volume is already in a different state.");
            string origin_path = volume.origin_path;
            var snapshot_origin = snapshot_deletion ? snapshot.advanced.lookup (origin_path) as StorageLogicalVolume : null;
            string origin_uuid = snapshot_origin?.uuid ?? "";
            if (snapshot_deletion && origin_uuid == "")
                throw new IOError.NOT_FOUND ("Could not verify the snapshot origin.");
            require_independent_lv (proxy, volume, deleting, true);
            string previous_block = proxy.get_cached_property ("BlockDevice")?.get_string () ?? "/";
            var active_block = snapshot.blocks.lookup (previous_block);
            if (!volume.active && previous_block != "/")
                throw new IOError.BUSY ("The inactive logical volume still exposes a block device.");
            if (volume.active && (active_block == null || active_block.logical_volume != volume))
                throw new IOError.NOT_FOUND ("The active logical-volume block device could not be verified.");

            StorageBlock[] locked = active_block == null ? new StorageBlock[0] : new StorageBlock[] { active_block };
            locks.acquire_members (context, locked, snapshot.dependencies);
            var job = jobs.begin_named (method + " logical volume", volume.name, { context.path, path });
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the logical volume and its dependencies");
                var context_safety = StorageSafetyService.assess (context, snapshot.dependencies);
                if (context_safety.system_critical || context_safety.unknown_dependencies || context.read_only)
                    throw new IOError.BUSY ("The volume group is protected or its dependencies are unknown.");
                if (deleting && (proxy.get_cached_property ("ChildConfiguration")?.n_children () ?? 1) != 0)
                    throw new IOError.BUSY ("Remove the logical volume’s persistent configuration before deleting it.");
                if (active_block != null) {
                    var safety = StorageSafetyService.assess (active_block, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents ||
                        safety.mounted || active_block.swap_active || active_block.encrypted?.mapping != null)
                        throw new IOError.BUSY ("Unmount filesystems, disable swap and close dependent mappings before deactivation.");
                    yield KernelStorageSafety.require_idle (active_block, lifetime);
                }
                synchronize ();
                if (modification_identity (context) != context_identity || snapshot.advanced.lookup (path) != volume ||
                    volume.uuid != uuid || manager?.get_interface (path, PREFIX + "LogicalVolume") != proxy ||
                    volume.active != was_active || volume.origin_path != origin_path ||
                    (proxy.get_cached_property ("BlockDevice")?.get_string () ?? "/") != previous_block)
                    throw new IOError.NOT_FOUND ("The logical-volume identity or active state changed.");
                require_independent_lv (proxy, volume, deleting, true);
                if (deleting && (proxy.get_cached_property ("ChildConfiguration")?.n_children () ?? 1) != 0)
                    throw new IOError.BUSY ("The logical volume gained persistent configuration.");
                if (thin) {
                    var pool = require_thin_pool (volume);
                    if (volume.thin_pool_path != pool_path || pool.uuid != pool_uuid)
                        throw new IOError.NOT_FOUND ("The thin pool changed after confirmation.");
                    if (activate && !new ThinPoolUsage (snapshot, pool).can_provision ())
                        throw new IOError.BUSY ("The thin pool must be active with verified free data and metadata space.");
                }
                jobs.phase (job, StorageJobState.RUNNING, method + " logical volume");
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, method,
                    new Variant ("(@a{sv})", new Variant ("a{sv}", null)), lifetime);
                if (!reply.is_of_type (new VariantType (activate ? "(o)" : "()")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid logical-volume result.");
                string block_path = activate ? reply.get_child_value (0).get_string () : previous_block;
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    lifetime.set_error_if_cancelled ();
                    var current = snapshot.advanced.lookup (path) as StorageLogicalVolume;
                    var current_block = snapshot.blocks.lookup (block_path);
                    bool still_present = current != null;
                    if (deleting)
                        foreach (var item in snapshot.advanced.get_values ()) {
                            var remaining = item as StorageLogicalVolume;
                            still_present |= remaining != null && remaining.uuid == uuid;
                        }
                    var current_origin = snapshot_deletion ? snapshot.advanced.lookup (origin_path) as StorageLogicalVolume : null;
                    bool verified = deleting ? !still_present && (!snapshot_deletion || current_origin?.uuid == origin_uuid) :
                        current != null && current.uuid == uuid && current.active == activate &&
                        (activate ? current_block != null && current_block.available && current_block.logical_volume == current :
                            current_block == null || current_block.logical_volume != current);
                    if (thin) {
                        var live_pool = snapshot.advanced.lookup (pool_path) as StorageLogicalVolume;
                        verified &= live_pool?.uuid == pool_uuid && (deleting || current?.thin_pool_path == pool_path);
                    }
                    if (verified) {
                        outcome.successful = true;
                        outcome.summary = activate ? "Logical volume activated" :
                            deleting ? "Logical volume deleted" : "Logical volume deactivated";
                        return activate ? block_path : "";
                    }
                    yield settle_delay (lifetime);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the new logical-volume state.");
            } catch (Error error) {
                outcome.fail ("Could not confirm the logical-volume operation", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                jobs.finish (job, outcome);
                locks.release (context);
            }
        }

        internal bool can_resize_logical_volume (StorageBlock block) {
            bool bare = block.type_id == "" && block.usage == "" && block.filesystem == null;
            bool ext = block.filesystem != null && !block.filesystem.mounted &&
                (block.type_id == "ext2" || block.type_id == "ext3" || block.type_id == "ext4");
            return block.available && block.logical_volume?.active == true && !block.system_hint && !block.read_only &&
                block.table == null && block.partition == null && block.encrypted == null && !block.has_swap &&
                (bare || ext);
        }

        private async void verify_lv_filesystem_size (StorageBlock block, DBusProxy device, uint64 size,
            Cancellable token) throws Error {
            var measurement = yield capacity_probes.query (block, token, device);
            FilesystemCapacityProbeService.verify_uuid (block.uuid, measurement.filesystem_uuid);
            if (measurement.capacity > size || !FilesystemCapacityProbeService.authoritative_match (measurement, size, block.size,
                block.logical_sector_size, block.physical_sector_size))
                throw new IOError.FAILED ("The verified filesystem capacity does not match the requested size.");
        }

        private void verify_thin_resize (StorageLogicalVolume volume, string pool_path, string pool_uuid,
            uint64 old_size, uint64 new_size, bool confirm_overcommit) throws Error {
            var pool = require_thin_pool (volume);
            if (pool.path != pool_path || pool.uuid != pool_uuid)
                throw new IOError.NOT_FOUND ("The thin pool changed.");
            var usage = new ThinPoolUsage (snapshot, pool);
            uint64 growth = new_size > old_size ? new_size - old_size : 0;
            if (new_size < old_size) {
                if (!usage.can_shrink ())
                    throw new IOError.NO_SPACE ("Shrinking requires an active thin pool with known usage and available metadata space.");
                return;
            }
            if (!usage.can_provision () || growth > usage.virtual_limit ())
                throw new IOError.NO_SPACE ("Thin-pool provisioning is unavailable or exhausted.");
            if (growth > 0 && usage.overcommits (growth) && !confirm_overcommit)
                throw new IOError.PERMISSION_DENIED ("Confirm virtual capacity above the physical pool capacity.");
        }

        internal async StorageOperationResult resize_logical_volume (StorageBlock block, uint64 size,
            string confirmed_identity, bool confirm_overcommit = false) throws Error {
            synchronize ();
            var device = require_volume (block, "Block");
            var volume = block.logical_volume;
            if (volume == null || !can_resize_logical_volume (block) || volume.uuid == "" || volume.size != block.size)
                throw new IOError.NOT_SUPPORTED ("Resize requires an active, unmounted plain logical volume with a supported layout.");
            var proxy = manager?.get_interface (volume.path, PREFIX + "LogicalVolume") as DBusProxy;
            var group = snapshot.advanced.lookup (volume.group_path) as StorageVolumeGroup;
            var group_proxy = group != null ? manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy : null;
            if (proxy == null || group == null || group_proxy == null)
                throw new IOError.NOT_FOUND ("The logical volume or its volume group is unavailable.");
            string pool_path = volume.thin_pool_path;
            bool thin = pool_path != "/";
            if (volume.origin_path != "/")
                throw new IOError.NOT_SUPPORTED ("Resize the origin rather than a snapshot.");
            string pool_uuid = thin ? require_thin_pool (volume).uuid : "";
            require_independent_lv (proxy, volume, false, true);
            uint64 original_size = block.size;
            uint64 number = block.number;
            string uuid = volume.uuid;
            string filesystem_uuid = block.uuid;
            string type = block.type_id;
            var filesystem = block.filesystem != null ? require_volume (block, "Filesystem") : null;
            bool shrink = size < original_size;
            if (size == 0 || size == original_size || (shrink && filesystem == null))
                throw new IOError.INVALID_ARGUMENT ("Choose a different capacity. Shrinking requires a verifiable filesystem.");

            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Resize logical volume", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking volume geometry and filesystem capabilities");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents || safety.mounted)
                    throw new IOError.BUSY ("The logical volume is protected or has active dependencies.");
                yield KernelStorageSafety.require_idle (block, lifetime);
                if (filesystem != null) {
                    string missing;
                    var modes = yield filesystem_resize_modes (type, out missing);
                    var needed = shrink ? FilesystemResizeMode.OFFLINE_SHRINK : FilesystemResizeMode.OFFLINE_GROW;
                    if ((modes & needed) == 0)
                        throw new IOError.NOT_SUPPORTED ("UDisks does not support this offline filesystem resize. " + missing);
                    if (shrink && size <= (yield minimum_sizes.query (block, lifetime)))
                        throw new IOError.NO_SPACE ("The requested size must exceed the verified filesystem minimum.");
                }
                synchronize ();
                if (creation_identity_changed (block, confirmed_identity) || block.logical_volume != volume ||
                    volume.uuid != uuid || require_volume (block, "Block") != device ||
                    manager?.get_interface (volume.path, PREFIX + "LogicalVolume") != proxy ||
                    manager?.get_interface (group.path, PREFIX + "VolumeGroup") != group_proxy)
                    throw new IOError.NOT_FOUND ("The logical volume changed after confirmation.");
                require_independent_lv (proxy, volume, false, true);
                uint64 extent = group_proxy.get_cached_property ("ExtentSize")?.get_uint64 () ?? 0;
                uint64 free = group_proxy.get_cached_property ("FreeSize")?.get_uint64 () ?? 0;
                if (extent == 0 || size % extent != 0 || (!thin && !shrink && size - original_size > free) ||
                    (group_proxy.get_cached_property ("MissingPhysicalVolumes")?.n_children () ?? 1) != 0 ||
                    volume_group_has_backend_job (group, { block }))
                    throw new IOError.BUSY ("The requested size is unaligned, exceeds free extents, or the volume group is busy.");

                if (thin) verify_thin_resize (volume, pool_path, pool_uuid, original_size, size, confirm_overcommit);

                if (shrink) {
                    if (!(yield maintenance_available (type, false)))
                        throw new IOError.NOT_SUPPORTED ("An offline filesystem check is required before shrinking.");
                    var checked = yield filesystem.call ("Check", new Variant ("(@a{sv})", new Variant ("a{sv}", null)),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                    if (!checked.is_of_type (new VariantType ("(b)")) || !checked.get_child_value (0).get_boolean ())
                        throw new IOError.INVALID_DATA ("Repair filesystem inconsistencies before shrinking.");
                    yield KernelStorageSafety.require_idle (block, lifetime);
                    synchronize ();
                    if (creation_identity_changed (block, confirmed_identity) || require_volume (block, "Filesystem") != filesystem)
                        throw new IOError.NOT_FOUND ("The filesystem changed before shrinking.");
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking and verifying the filesystem");
                    dispatched = true;
                    yield call_tracked_method (job, filesystem, "Resize",
                        new Variant ("(t@a{sv})", size, new Variant ("a{sv}", null)), lifetime);
                    result.completed ("Filesystem resize returned");
                    yield verify_lv_filesystem_size (block, device, size, lifetime);
                    result.completed ("Filesystem shrink verified");
                }
                yield KernelStorageSafety.require_idle (block, lifetime);
                synchronize ();
                if (creation_identity_changed (block, confirmed_identity) || block.logical_volume != volume ||
                    volume.uuid != uuid || volume.size != original_size ||
                    manager?.get_interface (volume.path, PREFIX + "LogicalVolume") != proxy)
                    throw new IOError.NOT_FOUND ("The logical volume changed before resizing.");
                require_independent_lv (proxy, volume, false, true);
                if (thin) verify_thin_resize (volume, pool_path, pool_uuid, original_size, size, confirm_overcommit);
                jobs.phase (job, StorageJobState.RUNNING, shrink ? "Shrinking the logical volume" : "Growing the logical volume");
                dispatched = true;
                yield call_tracked_method (job, proxy, "Resize",
                    new Variant ("(t@a{sv})", size, new Variant ("a{sv}", null)), lifetime);
                result.completed ("Logical-volume resize returned");
                for (int i = 0; i < 100 && (block.size != size || volume.size != size); i++) {
                    yield settle_delay (lifetime);
                    synchronize ();
                }
                if (snapshot.blocks.lookup (block.path) != block || block.number != number ||
                    block.logical_volume != volume || volume.uuid != uuid || block.size != size || volume.size != size ||
                    require_volume (block, "Block") != device || block.uuid != filesystem_uuid)
                    throw new IOError.FAILED ("UDisks did not confirm the new capacity on the same logical volume.");
                if (thin && (volume.thin_pool_path != pool_path || require_thin_pool (volume).uuid != pool_uuid))
                    throw new IOError.NOT_FOUND ("The thin pool changed during resizing.");
                result.completed ("Logical-volume capacity verified");
                if (filesystem != null) {
                    if (!shrink) {
                        yield KernelStorageSafety.require_idle (block, lifetime);
                        synchronize ();
                        if (require_volume (block, "Filesystem") != filesystem || block.size != size ||
                            block.logical_volume != volume || block.uuid != filesystem_uuid)
                            throw new IOError.NOT_FOUND ("The filesystem changed before growth.");
                        jobs.phase (job, StorageJobState.RUNNING, "Growing the filesystem into the new capacity");
                        yield call_tracked_method (job, filesystem, "Resize",
                            new Variant ("(t@a{sv})", (uint64) 0, new Variant ("a{sv}", null)), lifetime);
                        result.completed ("Filesystem resize returned");
                    }
                    yield verify_lv_filesystem_size (block, device, size, lifetime);
                    result.completed ("Filesystem capacity verified");
                }
                result.successful = true;
                result.summary = "Logical volume resized";
            } catch (Error error) {
                result.fail ("Could not confirm the complete logical-volume resize", error);
                if (dispatched && !result.partial) result.status = StorageOperationStatus.NEEDS_ATTENTION;
            } finally {
                synchronize ();
                jobs.finish (job, result);
                locks.release (block);
            }
            return result;
        }

        internal async string rename_logical_volume (StorageBlock block, string name, string confirmed_identity) throws Error {
            if (!valid_lvm_name (name))
                throw new IOError.INVALID_ARGUMENT ("Enter a valid LVM logical volume name.");
            synchronize ();
            require_volume (block, "Block");
            var volume = block.logical_volume;
            var proxy = volume != null ? manager?.get_interface (volume.path, PREFIX + "LogicalVolume") as DBusProxy : null;
            string uuid = proxy?.get_cached_property ("UUID")?.get_string () ?? "";
            if (volume == null || proxy == null || uuid == "")
                throw new IOError.NOT_SUPPORTED ("UDisks does not expose an identifiable logical volume.");
            if (volume.name == name)
                return block.path;

            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Rename logical volume", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            bool dispatched = false;
            ulong disconnected = backend_lifetime.cancelled.connect (() => job.cancellable.cancel ());
            var lifetime = backend_lifetime;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Checking the logical volume and its dependencies");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents ||
                    safety.mounted || block.read_only || block.mount_configurations.length != 0 ||
                    block.encryption_configurations.length != 0)
                    throw new IOError.BUSY ("The logical volume or its configuration prevents a safe rename.");
                yield KernelStorageSafety.require_idle (block, job.cancellable);
                synchronize ();
                if (modification_identity (block) != confirmed_identity || block.logical_volume != volume ||
                    manager?.get_interface (volume.path, PREFIX + "LogicalVolume") != proxy)
                    throw new IOError.NOT_FOUND ("The logical volume changed after confirmation.");

                jobs.phase (job, StorageJobState.RUNNING, "Renaming the logical volume");
                dispatched = true;
                var reply = yield call_tracked_method (job, proxy, "Rename",
                    new Variant ("(s@a{sv})", name, new Variant ("a{sv}", null)), job.cancellable);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid logical volume path.");
                string result_path = reply.get_child_value (0).get_string ();
                for (int i = 0; i < 100; i++) {
                    synchronize ();
                    var changed = manager?.get_interface (result_path, PREFIX + "LogicalVolume") as DBusProxy;
                    if (changed?.get_cached_property ("UUID")?.get_string () == uuid &&
                        changed?.get_cached_property ("Name")?.get_string () == name) {
                        string block_path = changed.get_cached_property ("BlockDevice")?.get_string () ?? "/";
                        var renamed = snapshot.blocks.lookup (block_path);
                        if (renamed != null && renamed.available && renamed.logical_volume_path == result_path) {
                            outcome.successful = true;
                            outcome.summary = "Logical volume renamed";
                            return renamed.path;
                        }
                    }
                    yield settle_delay (job.cancellable);
                }
                throw new IOError.TIMED_OUT ("UDisks did not confirm the new logical volume name.");
            } catch (Error error) {
                outcome.fail (dispatched ? "Logical volume rename requires attention" : "Logical volume was not renamed", error);
                if (dispatched) outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                throw error;
            } finally {
                lifetime.disconnect (disconnected);
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        private DBusProxy require_volume (StorageBlock block, string iface) throws Error {
            if (!available ()) throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            if (snapshot.blocks.lookup (block.path) != block || !block.available)
                throw new IOError.NOT_FOUND ("The volume is no longer available.");
            var proxy = manager?.get_interface (block.path, PREFIX + iface) as DBusProxy;
            if (proxy == null)
                throw new IOError.NOT_SUPPORTED ("UDisks does not expose the required interface for this volume.");
            return proxy;
        }

        private DBusProxy require_drive (StorageDrive drive, string iface) throws Error {
            if (!available ()) throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            if (snapshot.drives.lookup (drive.path) != drive || !drive.available)
                throw new IOError.NOT_FOUND ("The drive is no longer available.");
            var proxy = manager?.get_interface (drive.path, PREFIX + iface) as DBusProxy;
            if (proxy == null) throw new IOError.NOT_SUPPORTED ("UDisks does not expose this health interface.");
            return proxy;
        }

        private static string smart_pretty (int64 value, int unit) {
            switch (unit) {
                case 1: return value.to_string ();
                case 2: return "%.3f s".printf ((double) value / 1000.0);
                case 3: return value.to_string () + " sectors";
                case 4: return "%.1f °C".printf ((double) value / 1000.0 - 273.15);
                default: return "Unknown";
            }
        }

        public async StorageHealthReport query_health (StorageDrive drive, bool refresh_data = true) throws Error {
            bool nvme = drive.nvme_state != "";
            var proxy = require_drive (drive, nvme ? "NVMe.Controller" : "Drive.Ata");
            if (!nvme && !drive.smart) throw new IOError.NOT_SUPPORTED ("This drive does not report ATA SMART data.");
            if (refresh_data) {
                var update_options = new VariantBuilder (new VariantType ("a{sv}"));
                if (!nvme) update_options.add ("{sv}", "nowakeup", new Variant.boolean (true));
                try { yield proxy.call ("SmartUpdate", new Variant.tuple ({ update_options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime); }
                catch (Error error) {
                    string? remote = DBusError.get_remote_error (error);
                    if (remote == null || !remote.has_suffix (".WouldWakeup")) throw error;
                }
                synchronize ();
            }
            var report = new StorageHealthReport (); report.nvme = nvme;
            report.updated = drive.smart_updated;
            report.selftest = drive.smart_selftest_status == "" ? "Unknown" : drive.smart_selftest_status;
            report.selftest_remaining = drive.smart_selftest_remaining;
            if (nvme) {
                report.warnings = drive.nvme_warnings; report.power_on_hours = drive.nvme_power_on_hours;
                report.temperature = drive.nvme_temperature == 0 ? "Unknown" :
                    "%.1f °C".printf ((double) drive.nvme_temperature - 273.15);
                report.overall = report.updated == 0 ? "Unknown" :
                    report.warnings.length == 0 ? "Healthy" : "Warning";
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                var reply = yield proxy.call ("SmartGetAttributes", new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                var attributes = reply.get_child_value (0);
                var byte_value = attributes.lookup_value ("avail_spare", VariantType.BYTE);
                if (byte_value != null) report.available_spare = byte_value.get_byte ();
                byte_value = attributes.lookup_value ("spare_thresh", VariantType.BYTE);
                if (byte_value != null) report.spare_threshold = byte_value.get_byte ();
                byte_value = attributes.lookup_value ("percent_used", VariantType.BYTE);
                if (byte_value != null) report.percentage_used = byte_value.get_byte ();
                var uint_value = attributes.lookup_value ("total_data_read", VariantType.UINT64);
                if (uint_value != null) { report.has_total_data_read = true; report.total_data_read = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("total_data_written", VariantType.UINT64);
                if (uint_value != null) { report.has_total_data_written = true; report.total_data_written = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("ctrl_busy_time", VariantType.UINT64);
                if (uint_value != null) { report.has_controller_busy_minutes = true; report.controller_busy_minutes = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("power_cycles", VariantType.UINT64);
                if (uint_value != null) { report.has_power_cycles = true; report.power_cycles = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("media_errors", VariantType.UINT64);
                if (uint_value != null) { report.has_media_errors = true; report.media_errors = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("unsafe_shutdowns", VariantType.UINT64);
                if (uint_value != null) { report.has_unsafe_shutdowns = true; report.unsafe_shutdowns = uint_value.get_uint64 (); }
                uint_value = attributes.lookup_value ("num_err_log_entries", VariantType.UINT64);
                if (uint_value != null) { report.has_error_log_entries = true; report.error_log_entries = uint_value.get_uint64 (); }
                var sensors = attributes.lookup_value ("temp_sensors", new VariantType ("aq"));
                if (sensors != null) {
                    for (size_t index = 0; index < sensors.n_children (); index++) {
                        uint16 kelvin = sensors.get_child_value (index).get_uint16 ();
                        if (kelvin == 0) continue;
                        if (report.temperature_sensors != "") report.temperature_sensors += ", ";
                        report.temperature_sensors += "Sensor %u: %.1f °C".printf ((uint) index + 1,
                            (double) kelvin - 273.15);
                    }
                }
                return report;
            }
            report.power_on_hours = drive.smart_power_on_seconds / 3600;
            report.temperature = drive.smart_temperature <= 0 ? "Unknown" :
                "%.1f °C".printf (drive.smart_temperature - 273.15);
            report.overall = report.updated == 0 ? "Unknown" : drive.smart_failing ? "Failing" :
                drive.smart_attributes_failing > 0 ? "Failing" :
                drive.smart_attributes_failed_past > 0 || drive.smart_bad_sectors > 0 ? "Warning" : "Healthy";
            var get_options = new VariantBuilder (new VariantType ("a{sv}"));
            get_options.add ("{sv}", "nowakeup", new Variant.boolean (true));
            var attribute_reply = yield proxy.call ("SmartGetAttributes", new Variant.tuple ({ get_options.end () }),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
            var attribute_array = attribute_reply.get_child_value (0);
            StorageHealthAttribute[] parsed_attributes = {};
            for (size_t i = 0; i < attribute_array.n_children (); i++) {
                var tuple = attribute_array.get_child_value (i); var item = new StorageHealthAttribute ();
                item.id = tuple.get_child_value (0).get_byte (); item.name = tuple.get_child_value (1).get_string ();
                uint16 flags = tuple.get_child_value (2).get_uint16 ();
                item.normalized = tuple.get_child_value (3).get_int32 (); item.worst = tuple.get_child_value (4).get_int32 ();
                item.threshold = tuple.get_child_value (5).get_int32 ();
                item.raw = smart_pretty (tuple.get_child_value (6).get_int64 (), tuple.get_child_value (7).get_int32 ());
                item.assessment = item.normalized < 0 || item.threshold < 0 ? "Unknown" :
                    item.normalized <= item.threshold ? "Failing" : "OK";
                item.description = ((flags & 1) != 0 ? "Pre-failure" : "Old-age") +
                    ((flags & 2) != 0 ? ", updated online" : ", updated offline");
                parsed_attributes += item;
            }
            report.attributes = parsed_attributes;
            return report;
        }

        public async void run_selftest (StorageDrive drive, string type, bool stop = false) throws Error {
            bool nvme = drive.nvme_state != "";
            if ((!nvme && !drive.smart) || (type != "short" && type != "extended" &&
                !(!nvme && type == "conveyance")))
                throw new IOError.NOT_SUPPORTED ("This self-test type is not supported for the selected drive.");
            var target = drive.medium;
            if (target == null) throw new IOError.NOT_FOUND ("The drive has no available media.");
            var proxy = require_drive (drive, nvme ? "NVMe.Controller" : "Drive.Ata");
            locks.acquire (target, snapshot.dependencies);
            try {
                var existing = active_selftests.lookup (drive.path);
                if (!stop && existing != null) throw new IOError.BUSY ("A self-test is already active for this drive.");
                if (stop && (existing == null || drive.smart_selftest_status != "inprogress"))
                    throw new IOError.NOT_FOUND ("No tracked self-test is running for this drive.");
                var job = stop ? existing.job : jobs.begin (
                    stop ? "Stop drive self-test" : "Drive self-test", target, snapshot.dependencies);
                var result = new StorageOperationResult ();
                SelftestOperation operation;
                if (stop) operation = existing;
                else {
                    operation = new SelftestOperation (job, type, drive);
                    active_selftests.insert (drive.path, operation);
                }
                try {
                operation.state = stop ? SelftestOperationState.STOPPING : SelftestOperationState.STARTING;
                jobs.phase (job, StorageJobState.RUNNING, stop ? "Stopping " + operation.type + " self-test" :
                    "Starting " + type + " self-test");
                if (!stop) jobs.expect_backend (job, nvme ? "nvme-selftest" : "ata-smart-selftest", drive.path);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (stop) yield call_tracked_method (job, proxy, "SmartSelftestAbort",
                    new Variant.tuple ({ options.end () }), backend_lifetime);
                else yield call_tracked_method (job, proxy, "SmartSelftestStart",
                    new Variant.tuple ({ new Variant.string (type), options.end () }), backend_lifetime);
                if (!active_selftests.contains (drive.path)) return;
                if (!stop && operation.state == SelftestOperationState.STARTING)
                    operation.state = SelftestOperationState.START_CONFIRMED;
                bool observed = false;
                for (int attempt = 0; attempt < 20 && !observed; attempt++) {
                    synchronize ();
                    if (!active_selftests.contains (drive.path)) return;
                    observed = stop ? drive.smart_selftest_status != "inprogress" :
                        drive.smart_selftest_status == "inprogress";
                    if (!observed) yield settle_delay (backend_lifetime);
                }
                if (!observed)
                    throw new IOError.TIMED_OUT ("UDisks accepted the self-test request, but its resulting state was not observed.");
                if (stop) {
                    if (active_selftests.contains (drive.path)) {
                        result.fail ("Drive self-test stopped"); result.status = StorageOperationStatus.CANCELLED;
                        result.actual_state = drive.smart_selftest_status; jobs.finish (job, result);
                        active_selftests.remove (drive.path);
                    }
                } else {
                    operation.state = SelftestOperationState.RUNNING;
                    bool valid = drive.smart_selftest_remaining >= 0;
                    jobs.progress (job, type + " self-test in progress",
                        valid ? (100.0 - drive.smart_selftest_remaining) / 100.0 : 0.0, valid);
                }
                maintain_selftest_refresh ();
                } catch (Error error) {
                    synchronize ();
                    if (active_selftests.lookup (drive.path) != operation) throw error;
                    bool uncertain = error is IOError.TIMED_OUT || error is IOError.CANCELLED ||
                        error is IOError.CLOSED || error is DBusError.NO_REPLY || error is DBusError.DISCONNECTED;
                    if (drive.smart_selftest_status == "inprogress" && (stop || uncertain)) {
                        operation.state = SelftestOperationState.RUNNING;
                        jobs.progress (job, operation.type + " self-test in progress",
                            drive.smart_selftest_remaining >= 0 ? (100.0 - drive.smart_selftest_remaining) / 100.0 : 0.0,
                            drive.smart_selftest_remaining >= 0);
                    } else if (uncertain) {
                        operation.await_observation ();
                        jobs.phase (job, StorageJobState.FINALIZING, "Waiting to verify the self-test outcome");
                    } else {
                        active_selftests.remove (drive.path);
                        result.fail (stop ? "The self-test could not be stopped" :
                            "The self-test could not be started", error);
                        jobs.finish (job, result);
                    }
                    maintain_selftest_refresh ();
                    throw error;
                }
            } finally { locks.release (target); }
        }

        public async void drive_action (StorageDrive drive, string action) throws Error {
            var target = drive.medium;
            bool eject = action == "Eject"; bool power_off = action == "PowerOff";
            bool standby = action == "PmStandby"; bool wake = action == "PmWakeup";
            if ((!eject && !power_off && !standby && !wake) || (eject && !drive.ejectable) ||
                (power_off && !drive.can_power_off) || ((standby || wake) && !drive.ata_power_management))
                throw new IOError.NOT_SUPPORTED ("The selected drive does not support this hardware action.");
            if (target == null && !eject) throw new IOError.NOT_FOUND ("The drive has no available media.");
            if (target != null) {
                var safety = StorageSafetyService.assess (target, snapshot.dependencies);
                if ((eject || power_off) && (safety.system_critical || safety.unknown_dependencies))
                    throw new IOError.PERMISSION_DENIED ("System-critical or unresolved storage cannot be removed or powered off.");
            }
            string serial = drive.serial; string wwn = drive.wwn;
            if (target != null) locks.acquire (target, snapshot.dependencies);
            string operation = eject ? "Eject drive" : power_off ? "Power off drive" :
                standby ? "Standby drive" : "Wake drive";
            var job = target != null ? jobs.begin (operation, target, snapshot.dependencies) :
                jobs.begin_named (operation, drive.name, { drive.path });
            var result = new StorageOperationResult (); StoragePreparationJournal? preparation = null;
            try {
                if ((eject || power_off) && target != null) {
                    jobs.phase (job, StorageJobState.PREPARING, "Preparing active storage");
                    preparation = yield prepare_for_modification (target, backend_lifetime, job);
                }
                if (snapshot.drives.lookup (drive.path) != drive || drive.serial != serial || drive.wwn != wwn)
                    throw new IOError.NOT_FOUND ("The drive identity changed before the hardware action.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                jobs.phase (job, StorageJobState.RUNNING, job.operation);
                if (eject) jobs.expect_backend (job, "drive-eject", drive.path);
                else if (power_off) jobs.expect_backend (job, "drive-power-off", drive.path);
                var proxy = require_drive (drive, standby || wake ? "Drive.Ata" : "Drive");
                yield call_tracked_method (job, proxy, action, new Variant.tuple ({ options.end () }), backend_lifetime);
                bool verified = false;
                if (standby || wake) {
                    var state_options = new VariantBuilder (new VariantType ("a{sv}"));
                    var state_reply = yield proxy.call ("PmGetState", new Variant.tuple ({ state_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                    uint8 state = state_reply.get_child_value (0).get_byte ();
                    verified = standby ? state == 0 : state != 0;
                } else if (eject && target == null) {
                    verified = true;
                    result.actual_state = "The empty optical drive accepted the eject request.";
                } else {
                    for (int attempt = 0; attempt < 30 && !verified; attempt++) {
                        synchronize (); verified = snapshot.drives.lookup (drive.path) != drive || !drive.available;
                        if (!verified) yield settle_delay (backend_lifetime);
                    }
                }
                if (!verified) throw new IOError.TIMED_OUT ("The hardware action returned, but the resulting drive state was not verified.");
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = job.operation + " completed"; jobs.finish (job, result);
            } catch (Error error) {
                synchronize ();
                string restoration_error = "";
                if (preparation != null && snapshot.drives.lookup (drive.path) == drive && drive.available &&
                    !preparation.fully_restored ()) {
                    result.restoration_attempted = true;
                    try { yield restore_preparation (preparation, backend_lifetime); result.restoration_succeeded = true; }
                    catch (Error restore_error) { result.restoration_succeeded = false; restoration_error = restore_error.message; }
                }
                result.fail (job.operation + " failed", error);
                if (result.restoration_attempted && !result.restoration_succeeded) {
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.technical_error += "\nRestoration also failed: " + restoration_error;
                }
                jobs.finish (job, result); throw error;
            } finally { if (target != null) locks.release (target); }
        }

        private static bool same_configuration_value (Variant left, Variant right, string key, VariantType type) {
            var left_value = left.lookup_value (key, type);
            var right_value = right.lookup_value (key, type);
            return left_value == null ? right_value == null : right_value != null && left_value.equal (right_value);
        }

        private static bool configuration_matches_intent (Variant actual, string key, VariantType type,
            StorageSettingIntent intent, Variant? expected) {
            var value = actual.lookup_value (key, type);
            if (intent == StorageSettingIntent.RESET) return value == null;
            if (intent == StorageSettingIntent.UNCHANGED) return true;
            return value != null && expected != null && value.equal (expected);
        }

        public async void set_drive_configuration (StorageDrive drive, Variant baseline,
            StorageSettingIntent standby_intent, int standby,
            StorageSettingIntent apm_intent, int apm, StorageSettingIntent aam_intent, int aam,
            StorageSettingIntent write_cache_intent, bool write_cache,
            StorageSettingIntent read_lookahead_intent, bool read_lookahead) throws Error {
            if (drive.nvme_state != "") throw new IOError.NOT_SUPPORTED ("ATA settings are not available for NVMe drives.");
            if ((standby_intent == StorageSettingIntent.SET && (!drive.ata_power_management || drive.rotation == 0)) ||
                (apm_intent == StorageSettingIntent.SET && !drive.ata_apm_supported) ||
                (aam_intent == StorageSettingIntent.SET && !drive.ata_aam_supported) ||
                (write_cache_intent == StorageSettingIntent.SET && !drive.ata_write_cache_supported) ||
                (read_lookahead_intent == StorageSettingIntent.SET && !drive.ata_read_lookahead_supported))
                throw new IOError.NOT_SUPPORTED ("The drive does not support one or more selected settings.");
            if (standby < 0 || standby > 255 || apm < 1 || apm > 255 || aam < 0 || aam > 254)
                throw new IOError.INVALID_ARGUMENT ("A drive setting is outside its supported range.");

            string serial = drive.serial; string wwn = drive.wwn; string path = drive.path;
            locks.acquire_path (path);
            StorageJob? job = null; var result = new StorageOperationResult ();
            bool request_dispatched = false; bool request_returned = false;
            try {
                synchronize ();
                if (snapshot.drives.lookup (path) != drive || drive.serial != serial || drive.wwn != wwn)
                    throw new IOError.NOT_FOUND ("The drive identity changed before applying settings.");
                Variant current = drive.drive_configuration;
                if ((standby_intent != StorageSettingIntent.UNCHANGED && !same_configuration_value (baseline, current, "ata-pm-standby", VariantType.INT32)) ||
                    (apm_intent != StorageSettingIntent.UNCHANGED && !same_configuration_value (baseline, current, "ata-apm-level", VariantType.INT32)) ||
                    (aam_intent != StorageSettingIntent.UNCHANGED && !same_configuration_value (baseline, current, "ata-aam-level", VariantType.INT32)) ||
                    (write_cache_intent != StorageSettingIntent.UNCHANGED && !same_configuration_value (baseline, current, "ata-write-cache-enabled", VariantType.BOOLEAN)) ||
                    (read_lookahead_intent != StorageSettingIntent.UNCHANGED && !same_configuration_value (baseline, current, "ata-read-lookahead-enabled", VariantType.BOOLEAN)))
                    throw new IOError.BUSY ("A selected drive setting changed outside Majoris Disks. Reopen the dialog and review the newer value.");

                var builder = new VariantBuilder (new VariantType ("a{sv}"));
                VariantIter iterator = current.iterator (); string key; Variant value;
                while (iterator.next ("{sv}", out key, out value)) {
                    bool reset = (key == "ata-pm-standby" && standby_intent != StorageSettingIntent.UNCHANGED) ||
                        (key == "ata-apm-level" && apm_intent != StorageSettingIntent.UNCHANGED) ||
                        (key == "ata-aam-level" && aam_intent != StorageSettingIntent.UNCHANGED) ||
                        (key == "ata-write-cache-enabled" && write_cache_intent != StorageSettingIntent.UNCHANGED) ||
                        (key == "ata-read-lookahead-enabled" && read_lookahead_intent != StorageSettingIntent.UNCHANGED);
                    if (!reset) builder.add ("{sv}", key, value);
                }
                Variant? standby_expected = standby_intent == StorageSettingIntent.SET ? new Variant.int32 (standby) : null;
                Variant? apm_expected = apm_intent == StorageSettingIntent.SET ? new Variant.int32 (apm) : null;
                Variant? aam_expected = aam_intent == StorageSettingIntent.SET ? new Variant.int32 (aam < 128 ? 0 : aam) : null;
                Variant? write_expected = write_cache_intent == StorageSettingIntent.SET ? new Variant.boolean (write_cache) : null;
                Variant? read_expected = read_lookahead_intent == StorageSettingIntent.SET ? new Variant.boolean (read_lookahead) : null;
                if (standby_expected != null) builder.add ("{sv}", "ata-pm-standby", standby_expected);
                if (apm_expected != null) builder.add ("{sv}", "ata-apm-level", apm_expected);
                if (aam_expected != null) builder.add ("{sv}", "ata-aam-level", aam_expected);
                if (write_expected != null) builder.add ("{sv}", "ata-write-cache-enabled", write_expected);
                if (read_expected != null) builder.add ("{sv}", "ata-read-lookahead-enabled", read_expected);
                var configuration = builder.end ();
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                var proxy = require_drive (drive, "Drive");
                job = jobs.begin_named ("Configure drive", drive.name, { path });
                jobs.phase (job, StorageJobState.RUNNING, "Applying drive settings");
                request_dispatched = true;
                yield proxy.call ("SetConfiguration", new Variant.tuple ({ configuration, options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                request_returned = true;
                bool verified = false; Variant actual = current;
                for (int attempt = 0; attempt < 20 && !verified; attempt++) {
                    synchronize ();
                    if (snapshot.drives.lookup (path) != drive || drive.serial != serial || drive.wwn != wwn)
                        throw new IOError.NOT_FOUND ("The drive identity changed while applying settings.");
                    actual = drive.drive_configuration;
                    verified = configuration_matches_intent (actual, "ata-pm-standby", VariantType.INT32, standby_intent, standby_expected) &&
                        configuration_matches_intent (actual, "ata-apm-level", VariantType.INT32, apm_intent, apm_expected) &&
                        configuration_matches_intent (actual, "ata-aam-level", VariantType.INT32, aam_intent, aam_expected) &&
                        configuration_matches_intent (actual, "ata-write-cache-enabled", VariantType.BOOLEAN, write_cache_intent, write_expected) &&
                        configuration_matches_intent (actual, "ata-read-lookahead-enabled", VariantType.BOOLEAN, read_lookahead_intent, read_expected);
                    if (!verified) yield settle_delay (backend_lifetime);
                }
                if (!verified) throw new IOError.TIMED_OUT (
                    "UDisks accepted the settings, but their persisted readback could not be verified.");
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Drive settings saved"; jobs.finish (job, result);
            } catch (Error error) {
                result.fail ("Drive settings were not saved", error);
                string? remote = DBusError.get_remote_error (error);
                bool confirmed_rejection = remote != null && (remote.contains ("NotAuthorized") ||
                    remote.has_suffix (".AccessDenied") || remote.has_suffix (".NotSupported"));
                if (request_dispatched && (request_returned || !confirmed_rejection)) {
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary = request_returned ? "Drive settings were accepted but readback is uncertain" :
                        "The drive-settings outcome is uncertain";
                }
                if (job != null) jobs.finish (job, result); throw error;
            } finally { locks.release_path (path); }
        }

        public string modification_identity (StorageBlock block, bool include_dependents = true) {
            var records = new GenericArray<string> ();
            StorageDevice[] nodes = include_dependents ? snapshot.dependencies.descendants (block) : new StorageDevice[] { block };
            foreach (var node in nodes) {
                var child = node as StorageBlock;
                if (child == null) continue;
                var partition = child.partition;
                var drive = child.physical_drive;
                uint64 partition_offset = partition != null ? partition.offset : 0;
                uint partition_number = partition != null ? partition.number : 0;
                records.add (new Variant ("(ssssssssssttttu)", child.path, child.device,
                    child.parent?.path ?? "", child.drive_path, drive?.serial ?? "", drive?.wwn ?? "",
                    child.uuid, partition?.uuid ?? "", partition?.table_path ?? "",
                    child.table?.scheme ?? "", child.number, child.size, partition_offset,
                    child.logical_sector_size, partition_number).print (false));
                if (!include_dependents && child.loop != null)
                    records.add (new Variant.string (child.loop.backing_file).print (true));
            }
            records.sort ((left, right) => strcmp (left, right));
            var identity = new StringBuilder ();
            foreach (var record in records) identity.append (record).append_c ('\n');
            return identity.str;
        }

        private void validate_modification (StorageBlock block, bool deleting, bool volume = false,
            bool allow_mounted = false, bool allow_active = false, bool allow_system = false) throws Error {
            if (block.partition?.container == true) {
                foreach (var child in snapshot.dependencies.children (block))
                    if ((child as StorageBlock)?.partition?.logical == true)
                        throw new IOError.NOT_SUPPORTED ("Remove logical partitions separately before deleting an extended partition.");
            }
            if ((!volume && (block.partition != null) != deleting) || (volume && block.table != null) ||
                block.backing_path != "/" ||
                block.raid_path != "/" || block.logical_volume_path != "/")
                throw new IOError.NOT_SUPPORTED ("This operation requires a plain disk or partition.");
            foreach (var node in snapshot.dependencies.descendants (block)) {
                var child = node as StorageBlock;
                if (child == null || !child.available || (!allow_system && child.system_hint) || child.ignored || child.read_only ||
                    child.raid_member_path != "/" || child.physical_volume_group_path != "/" ||
                    child.usage == "raid" || child.usage == "crypto")
                    throw new IOError.PERMISSION_DENIED ("The target includes protected or unsupported storage.");
                var safety = StorageSafetyService.assess (child, snapshot.dependencies);
                if ((!allow_mounted && safety.mounted) || (!allow_active && safety.active_dependents) ||
                    (!allow_system && safety.system_critical) || safety.unknown_dependencies)
                    throw new IOError.BUSY ("The target has active mounts or unresolved dependencies.");
            }
        }

        public static bool supports_ownership (StorageBlock block) {
            if (!block.available || block.read_only || block.system_hint ||
                block.filesystem == null || !block.filesystem.mounted || block.type_id == "") return false;
            string type = block.type_id.down ();
            return type != "ntfs" && type != "vfat" && type != "exfat" && type != "udf" && type != "iso9660";
        }
        public async StorageOperationResult modify_partitioning (StorageBlock block, string command, string confirmed_identity,
            string label = "", bool recursive = false, string encryption_passphrase = "") throws Error {
            bool deleting = command == "delete";
            bool rename = command == "label";
            bool ownership = command == "ownership";
            bool metadata = command == "name" || command == "bootable" || command == "type" || command == "flags";
            bool metadata_name = command == "name";
            bool partition_operation = deleting || metadata;
            bool formatting = command.has_prefix ("format:") || command.has_prefix ("format-zero:");
            bool encrypting = formatting && encryption_passphrase != "";
            bool disk_overwrite = command.has_suffix ("-zero") && !formatting;
            bool overwrite = command.has_prefix ("format-zero:") || disk_overwrite;
            bool volume = ownership || rename || formatting;
            string format = formatting ? command.substring (command.has_prefix ("format-zero:") ? 12 : 7) :
                disk_overwrite ? command.substring (0, command.length - 5) : command;
            bool destructive = deleting || formatting || format == "gpt" || format == "dos" || format == "empty";
            if (!volume && !partition_operation && format != "gpt" && format != "dos" && format != "empty")
                throw new IOError.INVALID_ARGUMENT ("Unknown partitioning operation.");
            if (rename) FilesystemCapabilityService.validate_label (block.type_id, label);
            StorageOperationKind operation_kind = deleting ? StorageOperationKind.DELETE_PARTITION :
                formatting ? StorageOperationKind.FORMAT_VOLUME : ownership ? StorageOperationKind.TAKE_OWNERSHIP :
                rename ? StorageOperationKind.EDIT_FILESYSTEM_LABEL : metadata_name ? StorageOperationKind.EDIT_PARTITION_NAME :
                command == "type" ? StorageOperationKind.EDIT_PARTITION_TYPE : metadata ? StorageOperationKind.EDIT_PARTITION_FLAGS :
                StorageOperationKind.INITIALIZE_DISK;
            var eligibility = StorageSafetyService.assess_operation (operation_kind, block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown)
                throw new IOError.PERMISSION_DENIED (eligibility.reason);
            string iface = rename || ownership ? "Filesystem" : partition_operation ? "Partition" : "Block";
            var proxy = require_volume (block, iface);
            var lifetime = backend_lifetime;
            validate_modification (block, partition_operation, volume, destructive || ownership || metadata_name,
                destructive || metadata_name, metadata_name);
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The target changed after confirmation.");
            locks.acquire (block, snapshot.dependencies);
            string job_name = deleting ? "Delete partition" : ownership ? "Take ownership" : rename ?
                "Edit filesystem label" : formatting ? "Format volume" : metadata ? "Edit partition" : "Initialize disk";
            var job = jobs.begin (job_name, block, snapshot.dependencies);
            var operation_result = new StorageOperationResult ();
            var preparation = new StoragePreparationJournal ();
            string original_uuid = block.uuid; string original_type = block.type_id;
            uint64 original_size = block.size; string original_table = block.table?.scheme ?? "";
            string original_graph = modification_identity (block);
            preparation.capture (block);
            try {
                if (destructive) {
                    jobs.phase (job, StorageJobState.PREPARING, "Preparing affected storage");
                    preparation = yield prepare_for_modification (block, lifetime, job);
                    validate_modification (block, partition_operation, volume, ownership, false);
                }
                if (volume && !rename && !ownership && format != "empty") {
                    var reply = yield query_filesystem_capability ("CanFormat", format);
                    var capability = FilesystemCapabilityService.decode (reply);
                    if (!capability.supported) {
                        string utility = capability.missing_utility;
                        throw new IOError.NOT_SUPPORTED (utility == "" ? "This filesystem cannot be formatted." :
                            "Formatting requires " + utility + ".");
                    }
                }
                if (encrypting) {
                    if (encryption_passphrase.length < 8)
                        throw new IOError.INVALID_ARGUMENT ("The encryption passphrase must contain at least eight characters.");
                    var encryption_capability = FilesystemCapabilityService.decode (
                        yield query_filesystem_capability ("CanFormat", "crypto_LUKS"));
                    if (!encryption_capability.supported)
                        throw new IOError.NOT_SUPPORTED (encryption_capability.missing_utility == "" ?
                            "LUKS encryption is unavailable through UDisks." :
                            "LUKS encryption requires " + encryption_capability.missing_utility + ".");
                }
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var child = node as StorageBlock;
                    if (child != null) {
                        if (ownership) yield KernelStorageSafety.require_no_holders (child, lifetime);
                        else if (!metadata_name) yield KernelStorageSafety.require_idle (child, lifetime);
                    }
                }
                if (lifetime.is_cancelled () || require_volume (block, iface) != proxy ||
                    modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The target changed before the operation started.");
                validate_modification (block, partition_operation, volume, ownership, false);
                if (rename && !FilesystemCapabilityService.supports_label (block.type_id))
                    throw new IOError.NOT_FOUND ("The filesystem changed before the label could be applied.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (formatting && label != "") {
                    FilesystemCapabilityService.validate_label (format, label);
                    options.add ("{sv}", "label", new Variant.string (label));
                }
                if (formatting) options.add ("{sv}", "update-partition-type", new Variant.boolean (true));
                if (encrypting) {
                    options.add ("{sv}", "encrypt.passphrase", new Variant.string (encryption_passphrase));
                    options.add ("{sv}", "encrypt.type", new Variant.string ("luks2"));
                }
                if (overwrite) options.add ("{sv}", "erase", new Variant.string ("zero"));
                if (ownership) {
                    if (!supports_ownership (block))
                        throw new IOError.NOT_SUPPORTED ("Ownership changes are unavailable for this filesystem.");
                    options.add ("{sv}", "recursive", new Variant.boolean (recursive));
                }
                if (metadata) {
                    var part = block.partition;
                    var disk = part == null ? null : snapshot.blocks.lookup (part.table_path);
                    string scheme = disk?.table?.scheme ?? "";
                    if (part == null || (command == "name" && (scheme != "gpt" || !label.validate () ||
                        label.char_count () > 36 || label.contains ("\n"))) ||
                        ((command == "bootable" || command == "flags") && (scheme != "dos" || part.logical)) ||
                        (command == "type" && label.strip () == ""))
                        throw new IOError.INVALID_ARGUMENT ("The requested metadata is invalid for this partition table.");
                    Variant value;
                    if (command == "name") value = new Variant.string (label);
                    else if (command == "type") value = new Variant.string (label);
                    else value = new Variant.uint64 (command == "bootable" ?
                        (recursive ? part.flags | 0x80 : part.flags & ~((uint64) 0x80)) : uint64.parse (label));
                    jobs.phase (job, StorageJobState.RUNNING, "Updating partition metadata");
                    yield proxy.call (command == "name" ? "SetName" : command == "type" ? "SetType" : "SetFlags",
                        new Variant.tuple ({ value, options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                    synchronize ();
                    operation_result.completed ("Partition metadata updated");
                    operation_result.successful = true; operation_result.summary = "Partition metadata updated";
                    jobs.finish (job, operation_result);
                    return operation_result;
                }
                var parameters = deleting || ownership ? new Variant.tuple ({ options.end () }) :
                    new Variant.tuple ({ new Variant.string (rename ? label : format), options.end () });
                jobs.phase (job, StorageJobState.RUNNING, job_name);
                if (deleting) jobs.expect_backend (job, "partition-delete", block.path);
                else if (formatting || format == "gpt" || format == "dos" || format == "empty")
                    jobs.expect_backend (job, overwrite ? "format-erase" : "format-mkfs", block.path);
                preparation.operation_started = true;
                preparation.backend_invoked = true;
                preparation.destructive_result = "dispatched-result-unknown";
                yield call_tracked_method (job, proxy,
                    ownership ? "TakeOwnership" : rename ? "SetLabel" : deleting ? "Delete" : "Format",
                    parameters, lifetime);
                preparation.backend_returned = true;
                preparation.destructive_result = "backend-returned-success";
                synchronize ();
                if (encrypting) {
                    for (int attempt = 0; attempt < 50 && (block.encrypted == null ||
                        block.encrypted.mapping?.filesystem == null); attempt++) {
                        yield settle_delay (lifetime); synchronize ();
                    }
                    if (block.encrypted == null)
                        throw new IOError.FAILED ("UDisks completed formatting, but the resulting LUKS container could not be verified.");
                    operation_result.completed ("LUKS2 container created");
                    if (block.encrypted.mapping == null)
                        throw new IOError.FAILED ("The LUKS2 container was created, but its clear-text mapping was not discovered.");
                    if (block.encrypted.mapping.filesystem == null || block.encrypted.mapping.type_id != format)
                        throw new IOError.FAILED ("The LUKS2 container was created and unlocked, but the requested inner filesystem was not verified.");
                    operation_result.completed ("Encrypted filesystem verified");
                }
                preparation.storage_state_changed = deleting || formatting || format == "gpt" || format == "dos" || format == "empty";
                preparation.operation_completed = true;
                minimum_sizes.invalidate (block.path);
                operation_result.completed (job_name);
                operation_result.successful = true; operation_result.summary = job_name + " completed";
                jobs.finish (job, operation_result);
                return operation_result;
            } catch (Error error) {
                string restore_error = "";
                synchronize ();
                reconcile_preparation (preparation);
                var current = snapshot.blocks.lookup (block.path);
                preparation.identity_changed = current != block || !block.available || block.size != original_size ||
                    block.uuid != original_uuid || block.type_id != original_type || (block.table?.scheme ?? "") != original_table;
                bool graph_unchanged = !preparation.identity_changed && modification_identity (block) == original_graph;
                preparation.storage_state_changed = preparation.storage_state_changed || !graph_unchanged;
                // Once a destructive request was dispatched, matching identifiers, geometry, topology,
                // or a successful consistency check cannot prove the original bytes survived.
                preparation.original_state_valid = !preparation.backend_invoked && graph_unchanged;
                preparation.restoration_eligibility = preparation.original_state_valid ?
                    "verified-safe-before-dispatch" : preparation.backend_invoked ?
                    "ineligible-dispatched-outcome-uncertain" : "ineligible-identity-changed";
                foreach (var entry in preparation.entries ())
                    entry.restoration_allowed = preparation.original_state_valid;
                if (preparation.original_state_valid && !preparation.fully_restored ()) {
                    preparation.restoration_attempted = true;
                    preparation.restoration_eligibility = "restoration-attempted";
                    try { yield restore_preparation (preparation, backend_lifetime); }
                    catch (Error restoration) { restore_error = restoration.message; }
                    preparation.restoration_succeeded = restore_error == "";
                }
                operation_result.fail (job_name + " failed", error);
                if (preparation.backend_invoked && !preparation.original_state_valid) {
                    operation_result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    operation_result.technical_error += "\nThe original storage state could not be verified; automatic restoration was not attempted.";
                }
                if (restore_error != "") {
                    operation_result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    operation_result.technical_error += "\nRestore: " + restore_error;
                }
                string recovery = preparation.recovery_details ();
                if (recovery != "") {
                    operation_result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    operation_result.technical_error += "\nAffected storage still requiring attention:\n" + recovery;
                }
                jobs.finish (job, operation_result);
                if (operation_result.status == StorageOperationStatus.NEEDS_ATTENTION || operation_result.partial)
                    return operation_result;
                if (restore_error != "")
                    throw new IOError.FAILED (error.message + " Restoration failed: " + restore_error);
                throw error;
            } finally {
                locks.release (block);
            }
        }
        private void validate_check (StorageBlock block, bool allow_mounted = false) throws Error {
            if (block.filesystem == null || block.type_id == "")
                throw new IOError.NOT_SUPPORTED ("The selected volume has no recognized filesystem.");
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.mounted && !allow_mounted)
                throw new IOError.BUSY ("Unmount the filesystem before checking it.");
            if (safety.system_critical || safety.active_dependents || safety.unknown_dependencies ||
                block.ignored || block.encrypted != null)
                throw new IOError.BUSY ("The volume has active or unresolved storage dependencies.");
        }

        public async Variant query_filesystem_capability (string method, string filesystem_type) throws Error {
            var daemon = manager?.get_interface ("/org/freedesktop/UDisks2/Manager", PREFIX + "Manager") as DBusProxy;
            if (daemon == null) throw new IOError.NOT_CONNECTED ("The UDisks manager is unavailable.");
            return yield daemon.call (method,
                new Variant ("(s)", filesystem_type), DBusCallFlags.NONE, -1, backend_lifetime);
        }

        public async FilesystemResizeMode filesystem_resize_modes (string filesystem_type,
            out string missing_utility) throws Error {
            var capability = yield query_filesystem_capability ("CanResize", filesystem_type);
            return FilesystemCapabilityService.resize_modes (capability, out missing_utility);
        }

        public async FilesystemResizePlan resize_plan (StorageBlock block, uint64 requested,
            bool resize_filesystem, bool refresh_minimum = false) throws Error {
            var part = block.partition;
            var disk = part == null ? null : snapshot.blocks.lookup (part.table_path);
            if (disk == null) throw new IOError.NOT_SUPPORTED ("Only a partition can be resized.");
            uint64 maximum = PartitionLayoutService.maximum_resize (disk, block);
            FilesystemCapability capability = {};
            capability.supported = true;
            uint64 minimum = PartitionLayoutService.minimum_resize (disk, block);
            Error? minimum_error = null;
            if (resize_filesystem && block.filesystem != null) {
                capability = FilesystemCapabilityService.decode (
                    yield query_filesystem_capability ("CanResize", block.type_id), true);
                if (capability.supported && block.type_id.down () == "btrfs")
                    yield FilesystemMinimumSizeService.query_single_btrfs_capacity (block, backend_lifetime);
                if (requested < block.size && capability.supported &&
                    (capability.offline_shrink || capability.online_shrink)) {
                    try {
                        minimum = uint64.max (minimum, yield minimum_sizes.query (block, backend_lifetime, refresh_minimum));
                    } catch (Error error) {
                        minimum = 0;
                        minimum_error = error;
                    }
                } else minimum = block.size;
            }
            var plan = FilesystemResizePlanner.build (block, requested, resize_filesystem,
                capability, minimum, maximum);
            if (!plan.supported && plan.direction == ResizeDirection.SHRINK && minimum_error != null)
                plan.reason = minimum_error.message;
            return plan;
        }

        public async bool maintenance_available (string filesystem_type, bool repair) throws Error {
            var capability = yield query_filesystem_capability (repair ? "CanRepair" : "CanCheck", filesystem_type);
            return FilesystemCapabilityService.check_available (capability, repair);
        }

        private async void settle_delay (Cancellable token) throws Error {
            var source = new TimeoutSource (100);
            source.set_callback (settle_delay.callback);
            source.attach (MainContext.get_thread_default ());
            yield;
            source.destroy ();
            token.set_error_if_cancelled ();
        }

        private async StorageBlock wait_for_block (string path, Cancellable token) throws Error {
            for (int attempt = 0; attempt < 100; attempt++) {
                synchronize ();
                var block = snapshot.blocks.lookup (path);
                if (block != null && block.available) return block;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("UDisks did not publish the new partition in time.");
        }

        private async void wait_for_size (StorageBlock block, uint64 expected,
            Cancellable token) throws Error {
            for (int attempt = 0; attempt < 100; attempt++) {
                synchronize ();
                if (snapshot.blocks.lookup (block.path) == block && block.size == expected) return;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("The updated block-device geometry was not published in time.");
        }

        private async bool prepare_unmounted (StorageBlock block, Cancellable token) throws Error {
            var filesystem = block.filesystem;
            bool mounted = filesystem?.mounted ?? false;
            if (!mounted) return false;
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.active_dependents || safety.unknown_dependencies)
                throw new IOError.BUSY ("The filesystem cannot be safely unmounted because it has active dependencies.");
            var proxy = require_volume (block, "Filesystem");
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            yield proxy.call ("Unmount", new Variant.tuple ({ options.end () }),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 90000, token);
            for (int attempt = 0; attempt < 50; attempt++) {
                synchronize ();
                if (block.filesystem != null && !block.filesystem.mounted) return true;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("The filesystem did not become unmounted.");
        }

        private async StoragePreparationJournal prepare_for_modification (StorageBlock target, Cancellable token,
            StorageJob job) throws Error {
            var journal = new StoragePreparationJournal ();
            journal.capture (target);
            var nodes = snapshot.dependencies.descendants (target);
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Capturing mount topology and validating restoration");
                for (int index = nodes.length - 1; index >= 0; index--) {
                    var block = nodes[index] as StorageBlock;
                    if (block == null) continue;
                    var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies)
                        throw new IOError.BUSY ("Protected or unresolved storage cannot be prepared automatically.");
                    if (block.filesystem != null && (block.number != 0 || block.filesystem.mounted)) {
                        var entry = yield plan_mount_preparation (block, token);
                        if (entry != null) journal.add (entry);
                    }
                    if (block.swap_active) {
                        var entry = new StoragePreparationEntry (StoragePreparationKind.SWAP, block.path,
                            { block.uuid, block.type_id }, "deactivate swap");
                        entry.device_identity = StoragePreparationJournal.device_identity (block);
                        journal.add (entry);
                    }
                }
                jobs.phase (job, StorageJobState.PREPARING, "Preparing verified storage dependencies");
                foreach (var entry in journal.entries ()) {
                    synchronize ();
                    token.set_error_if_cancelled ();
                    var block = snapshot.blocks.lookup (entry.object_path);
                    if (block == null || !entry.matches_prepared_device (block))
                        throw new IOError.NOT_FOUND ("A storage dependency changed after preparation was planned.");
                    if (entry.kind == StoragePreparationKind.MOUNT) {
                        yield prepare_mount_entry (block, entry, token);
                    }
                    if (entry.kind == StoragePreparationKind.SWAP) {
                        if (!block.swap_active)
                            throw new IOError.BUSY ("Swap state changed after preparation was planned.");
                        entry.action_dispatched = true;
                        var swap = require_volume (block, "Swapspace");
                        var options = new VariantBuilder (new VariantType ("a{sv}"));
                        Error? stop_error = null;
                        try {
                            yield swap.call ("Stop", new Variant.tuple ({ options.end () }),
                                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                            entry.backend_confirmed = true;
                        } catch (Error error) {
                            stop_error = error;
                        }
                        for (int attempt = 0; attempt < 50 && block.swap_active; attempt++) {
                            synchronize (); if (block.swap_active) yield settle_delay (backend_lifetime);
                        }
                        if (block.swap_active) {
                            synchronize ();
                            entry.prepared = !block.swap_active;
                            entry.actual_state = entry.prepared ? "inactive" : "active or unavailable";
                            if (stop_error != null) throw stop_error;
                            throw new IOError.TIMED_OUT ("Swap remained active after UDisks returned.");
                        }
                        entry.prepared = true; entry.expected_state_observed = true; entry.actual_state = "inactive";
                        if (stop_error != null) entry.error = "The response was lost after swap became inactive: " + stop_error.message;
                    }
                }
                return journal;
            } catch (Error error) {
                try { yield restore_preparation (journal, backend_lifetime); }
                catch (Error restore_error) { throw new IOError.FAILED (error.message + " Restoration also failed: " + restore_error.message); }
                throw error;
            }
        }

        private static KernelMountRecord[] read_mount_topology (StorageBlock block, out string namespace_id) throws Error {
            if (block.number == 0)
                throw new IOError.NOT_SUPPORTED ("The kernel mount source could not be identified.");
            namespace_id = FileUtils.read_link ("/proc/self/ns/mnt");
            string mountinfo;
            FileUtils.get_contents ("/proc/self/mountinfo", out mountinfo);
            var all_mounts = KernelStorageSafety.parse_mountinfo (mountinfo, namespace_id);
            string device = KernelStorageSafety.device_number (block.number);
            KernelMountRecord[] selected = {};
            foreach (var record in all_mounts) {
                if (record.device != device) continue;
                record.block_path = block.path;
                foreach (var configuration in block.mount_configurations)
                    if (configuration.directory == record.target)
                        record.fstab = configuration.backend_item;
                selected += record;
            }
            foreach (var mount in selected) {
                foreach (var other in all_mounts) {
                    if (other.id == mount.id) continue;
                    if (other.target == mount.target ||
                        (other.parent_id == mount.id && other.device != device))
                        throw new IOError.NOT_SUPPORTED ("Stacked mounts or unrelated child mounts at %s require manual preparation.".printf (mount.target));
                }
            }
            return selected;
        }

        internal string[] restoration_mount_targets (StorageBlock block) throws Error {
            string namespace_id;
            string[] targets = {};
            foreach (var mount in read_mount_topology (block, out namespace_id)) targets += mount.target;
            return targets;
        }

        private async StoragePreparationEntry? plan_mount_preparation (StorageBlock block,
            Cancellable token) throws Error {
            string namespace_id;
            var topology = read_mount_topology (block, out namespace_id);
            if (topology.length == 0 && block.filesystem?.mounted != true) return null;
            if (topology.length == 0)
                throw new IOError.NOT_SUPPORTED ("The reported mounts are unavailable in this mount namespace.");
            string[] state = { block.uuid, block.type_id };
            foreach (var record in topology) state += record.target;
            var entry = new StoragePreparationEntry (StoragePreparationKind.MOUNT, block.path, state, "unmount");
            entry.device_identity = StoragePreparationJournal.device_identity (block);
            entry.capture_mount_configuration (block.mount_configurations);
            entry.mount_topology = topology;
            entry.mount_namespace = namespace_id;
            foreach (var target in block.filesystem?.mounts ?? new string[0])
                if (KernelMountRecord.at_target (topology, target) == null)
                    throw new IOError.NOT_SUPPORTED ("UDisks reports mounts outside the verified mount namespace.");

            uint candidate = 0;
            uint candidates = 0;
            string user = Environment.get_user_name ();
            foreach (var record in topology) {
                if (record.root != "/") continue;
                string parent = Path.get_dirname (record.target);
                if (record.fstab != null || parent == "/media/" + user || parent == "/run/media/" + user) {
                    candidate = record.id;
                    candidates++;
                }
            }
            if (candidates == 1) {
                foreach (var record in topology)
                    if (record.id == candidate && block.filesystem != null &&
                        record.target in block.filesystem.mounts)
                        entry.primary_mount_id = candidate;
            }
            if (topology.length == 1 && entry.primary_mount_id == 0)
                throw new IOError.NOT_SUPPORTED ("Unmount this filesystem manually. Its original mount location is managed outside UDisks.");
            if (block.backing_path != "/") {
                var backing = snapshot.blocks.lookup (block.backing_path);
                if (backing == null || backing.encrypted?.mapping != block || backing.uuid == "")
                    throw new IOError.NOT_SUPPORTED ("The mount's encrypted backing device could not be verified.");
                entry.encrypted_backing_path = backing.path;
                entry.encrypted_backing_identity = StoragePreparationJournal.device_identity (backing);
                entry.encrypted_backing_uuid = backing.uuid;
            }
            uint anchor = entry.primary_mount_id;
            if (topology.length > 1) {
                entry.mount_session = new MountRestorationSession (
                    KernelStorageSafety.device_number (block.number), entry.primary_mount_id);
                var reply = yield entry.mount_session.exchange (null, token, 120);
                var fields = reply.split (" ");
                if (fields.length != topology.length + 1 || fields[0] != "ready")
                    throw new IOError.BUSY ("The authorized mount plan differs from the captured topology.");
                KernelMountRecord[] ordered = {};
                for (int i = 1; i < fields.length; i++) {
                    uint id;
                    if (!uint.try_parse (fields[i], out id))
                        throw new IOError.INVALID_DATA ("The authorized mount plan returned an invalid mount ID.");
                    foreach (var mount in topology)
                        if (mount.id == id && !(mount in ordered)) ordered += mount;
                }
                if (ordered.length != topology.length)
                    throw new IOError.BUSY ("A mount changed while authorizing the plan.");
                entry.mount_topology = ordered;
                anchor = ordered[0].id;
            }
            foreach (var mount in entry.mount_topology) {
                mount.role = mount.id == anchor ? KernelMountRole.PRIMARY : mount.root == "/" ?
                    KernelMountRole.WHOLE_FILESYSTEM_EXPOSURE : KernelMountRole.SUBDIRECTORY_EXPOSURE;
                mount.source_mount_id = mount.id == anchor ? 0 : anchor;
                mount.uses_udisks = mount.id == entry.primary_mount_id;
            }
            return entry;
        }

        private async bool prepare_mount_entry (StorageBlock block, StoragePreparationEntry entry,
            Cancellable token) throws Error {
            string namespace_id;
            var current = read_mount_topology (block, out namespace_id);
            if (!entry.matches_prepared_device (block) ||
                !entry.mount_configuration_matches (block.mount_configurations) ||
                current.length != entry.mount_topology.length)
                throw new IOError.BUSY ("The filesystem or mount topology changed after preparation was planned.");
            foreach (var expected in entry.mount_topology) {
                var actual = KernelMountRecord.at_target (current, expected.target);
                if (actual == null || actual.id != expected.id || !expected.same_mount (actual))
                    throw new IOError.BUSY ("A mount changed after preparation was planned.");
            }
            token.set_error_if_cancelled ();
            entry.action_dispatched = true;
            // A lost response can follow a successful unmount. Always reconcile.
            entry.prepared = true;
            try {
                if (entry.mount_session != null &&
                    (yield entry.mount_session.exchange ("prepare\n", backend_lifetime)) != "prepared")
                    throw new IOError.BUSY ("An eligible mount could not be prepared. Check for active users.");
                if (entry.primary_mount_id != 0) {
                    synchronize ();
                    current = read_mount_topology (block, out namespace_id);
                    if (current.length != 1 || current[0].id != entry.primary_mount_id)
                        throw new IOError.BUSY ("Unexpected mounts remain before the primary unmount.");
                    // Once dispatched, wait for the unmount before honoring job cancellation.
                    yield prepare_unmounted (block, backend_lifetime);
                }
                yield KernelStorageSafety.require_idle (block, token);
                if (entry.mount_session != null &&
                    (yield entry.mount_session.exchange ("idle\n", backend_lifetime)) != "idle")
                    throw new IOError.BUSY ("The kernel could not verify exclusive access to the prepared filesystem.");
                for (int attempt = 0; attempt < 30; attempt++) {
                    synchronize ();
                    if (block.filesystem?.mounted != true) break;
                    yield settle_delay (token);
                }
                if (block.filesystem?.mounted == true)
                    throw new IOError.TIMED_OUT ("UDisks still reports an active mount.");
                entry.backend_confirmed = true;
                entry.expected_state_observed = true;
                foreach (var step in entry.mount_topology) step.preparation_removed = true;
                entry.actual_state = "unmounted";
                return true;
            } catch (Error error) {
                synchronize ();
                try {
                    current = read_mount_topology (block, out namespace_id);
                    foreach (var step in entry.mount_topology)
                        step.preparation_removed = KernelMountRecord.at_target (current, step.target) == null;
                    entry.verify_mount_topology (current, namespace_id);
                } catch (Error read_error) {
                    entry.record_mount_restoration (null);
                }
                throw error;
            }
        }

        private void reconcile_preparation (StoragePreparationJournal journal) {
            foreach (var entry in journal.entries ()) {
                if (!entry.prepared || entry.kind == StoragePreparationKind.ENCRYPTED_MAPPING) continue;
                var block = snapshot.blocks.lookup (entry.resolved_path);
                if (block == null || !block.available) {
                    entry.actual_state = entry.encrypted_backing_path != "" ?
                        "original cleartext mapping unavailable" : "device unavailable";
                    entry.restored = false;
                    if (entry.kind == StoragePreparationKind.MOUNT) entry.record_mount_restoration (null);
                    continue;
                }
                if (entry.encrypted_backing_path != "") {
                    var backing = snapshot.blocks.lookup (entry.encrypted_backing_path);
                    if (backing == null || backing.encrypted?.mapping != block ||
                        backing.uuid != entry.encrypted_backing_uuid ||
                        StoragePreparationJournal.device_identity (backing) != entry.encrypted_backing_identity) {
                        entry.restoration_allowed = false;
                        entry.actual_state = "encrypted backing identity changed";
                        entry.record_mount_restoration (null);
                        continue;
                    }
                }
                if (!entry.matches_prepared_device (block) ||
                    (entry.kind == StoragePreparationKind.MOUNT && block.filesystem == null)) {
                    entry.restoration_allowed = false;
                    entry.restored = false;
                    entry.actual_state = "device or filesystem identity changed";
                    if (entry.kind == StoragePreparationKind.MOUNT) entry.record_mount_restoration (null);
                    continue;
                }
                if (entry.kind == StoragePreparationKind.MOUNT) {
                    try {
                        string namespace_id;
                        var current = read_mount_topology (block, out namespace_id);
                        string[] targets = {};
                        foreach (var mount in current) targets += mount.target;
                        entry.actual_state = targets.length == 0 ? "unmounted" :
                            "mounted at " + string.joinv (", ", targets);
                        entry.verify_mount_topology (current, namespace_id);
                    } catch (Error error) {
                        entry.record_mount_restoration (null);
                        entry.actual_state = error.message;
                    }
                } else if (entry.kind == StoragePreparationKind.SWAP) {
                    entry.actual_state = block.swap_active ? "active" : "inactive";
                    entry.restored = block.swap_active;
                }
            }
        }

        private async string restore_mount (StorageBlock block, Cancellable token) throws Error {
            var proxy = require_volume (block, "Filesystem");
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            var reply = yield proxy.call ("Mount", new Variant.tuple ({ options.end () }),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 90000, token);
            synchronize ();
            return reply.is_of_type (new VariantType ("(s)")) ? reply.get_child_value (0).get_string () : "";
        }

        private async void restore_preparation (StoragePreparationJournal journal, Cancellable token) throws Error {
            string[] failures = {};
            synchronize ();
            reconcile_preparation (journal);
            foreach (var entry in journal.restoration_order ()) {
                if (entry.restored) continue;
                // Earlier restoration calls can yield while UDisks changes the graph.
                synchronize ();
                reconcile_preparation (journal);
                if (entry.restored || !entry.restoration_allowed) continue;
                if (entry.kind == StoragePreparationKind.ENCRYPTED_MAPPING) continue;
                var block = snapshot.blocks.lookup (entry.resolved_path);
                if (block == null || !entry.matches_prepared_device (block)) {
                    entry.error = "The prepared device or filesystem identity changed."; failures += entry.error; continue;
                }
                try {
                    if (entry.kind == StoragePreparationKind.MOUNT) {
                        yield refresh_block_configuration (require_volume (block, "Block"), token);
                        if (!entry.matches_prepared_device (block) ||
                            !entry.mount_configuration_matches (block.mount_configurations)) {
                            entry.restoration_allowed = false;
                            throw new IOError.FAILED ("The saved mount configuration changed.");
                        }
                        if (entry.restoration_dispatched)
                            throw new IOError.FAILED ("Restoration was already requested. Review the observed mount state.");
                        string namespace_id;
                        var current = read_mount_topology (block, out namespace_id);
                        if (namespace_id != entry.mount_namespace)
                            throw new IOError.FAILED ("The original mount namespace is unavailable.");
                        entry.restoration_dispatched = true;
                        if (entry.primary_mount_id != 0) {
                            KernelMountRecord? primary = null;
                            foreach (var expected in entry.mount_topology)
                                if (expected.id == entry.primary_mount_id) primary = expected;
                            var existing = KernelMountRecord.at_target (current, primary.target);
                            if (existing == null) {
                                if (current.length != 0)
                                    throw new IOError.BUSY ("The primary mount is missing, but other mounts are active.");
                                string actual = yield restore_mount (block, token);
                                if (primary.target != actual)
                                    throw new IOError.FAILED ("UDisks mounted the filesystem at %s instead of %s.".printf (actual, primary.target));
                            } else if (!primary.same_mount (existing)) {
                                throw new IOError.BUSY ("The primary mount's identity or options changed.");
                            }
                        }
                        if (entry.mount_session != null &&
                            (yield entry.mount_session.exchange ("restore\n", token)) != "restored") {
                            reconcile_preparation (journal);
                            if (!entry.restored)
                                throw new IOError.FAILED ("Some mounts could not be restored. " + journal.recovery_details ());
                        }
                        for (int attempt = 0; attempt < 30; attempt++) {
                            synchronize ();
                            reconcile_preparation (journal);
                            if (entry.restored || !entry.restoration_allowed) break;
                            yield settle_delay (token);
                        }
                        if (!entry.restored)
                            throw new IOError.FAILED ("The original mount location and options could not be verified.");
                    } else if (entry.kind == StoragePreparationKind.SWAP) {
                        var options = new VariantBuilder (new VariantType ("a{sv}"));
                        yield require_volume (block, "Swapspace").call ("Start", new Variant.tuple ({ options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        synchronize ();
                        if (!block.swap_active) throw new IOError.FAILED ("Swap did not become active.");
                    }
                    entry.restored = true;
                    entry.actual_state = entry.kind == StoragePreparationKind.MOUNT ? "mounted" : "active";
                } catch (Error error) { entry.error = error.message; failures += error.message; }
            }
            synchronize ();
            reconcile_preparation (journal);
            foreach (var entry in journal.entries ()) {
                if (!entry.prepared || entry.restored || entry.error != "") continue;
                entry.error = entry.actual_state == "original cleartext mapping unavailable" ?
                    "The original encrypted mapping is unavailable. Verify and unlock the original volume before mounting it." :
                    !entry.restoration_allowed ? "Automatic restoration was withheld because the original identity or configuration could not be verified." :
                    entry.kind == StoragePreparationKind.MOUNT ?
                    "Not every original mount point was restored." : "The original active state was not restored.";
                failures += entry.object_path + ": " + entry.error;
            }
            if (failures.length != 0) throw new IOError.FAILED (string.joinv ("; ", failures));
        }

        public async StorageOperationResult create_partition (StorageBlock disk, StorageFreeSpace gap,
            uint64 requested_size, PartitionLayoutService.PartitionKind kind, string partition_type,
            string partition_name, string filesystem_type, string filesystem_label,
            string confirmed_identity) throws Error {
            var result = new StorageOperationResult ();
            uint64 offset, size;
            PartitionLayoutService.validate_create (disk, gap, requested_size, kind, out offset, out size);
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION,
                disk, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.requires_preparation || disk.read_only)
                throw new IOError.PERMISSION_DENIED (eligibility.reason == "" ? "The disk is read-only." : eligibility.reason);
            if (modification_identity (disk) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The disk changed after confirmation.");
            locks.acquire (disk, snapshot.dependencies);
            var job = jobs.begin ("Create partition", disk, snapshot.dependencies);
            var token = job.cancellable;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Validating partition geometry");
                var table = require_volume (disk, "PartitionTable");
                PartitionLayoutService.validate_create (disk, gap, requested_size, kind, out offset, out size);
                if (filesystem_type != "" && filesystem_type != "empty") {
                    var capability = FilesystemCapabilityService.decode (
                        yield query_filesystem_capability ("CanFormat", filesystem_type));
                    if (!capability.supported) throw new IOError.NOT_SUPPORTED (capability.reason);
                    FilesystemCapabilityService.validate_label (filesystem_type, filesystem_label);
                }
                validate_create_target (disk, gap, requested_size, kind, confirmed_identity, out offset, out size);
                if (require_volume (disk, "PartitionTable") != table)
                    throw new IOError.NOT_FOUND ("The partition table changed before creation started.");
                yield KernelStorageSafety.require_no_holders (disk, token);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (kind == PartitionLayoutService.PartitionKind.MBR_PRIMARY)
                    options.add ("{sv}", "partition-type", new Variant.string ("primary"));
                else if (kind == PartitionLayoutService.PartitionKind.MBR_EXTENDED)
                    options.add ("{sv}", "partition-type", new Variant.string ("extended"));
                else if (kind == PartitionLayoutService.PartitionKind.MBR_LOGICAL)
                    options.add ("{sv}", "partition-type", new Variant.string ("logical"));
                string type = kind == PartitionLayoutService.PartitionKind.MBR_EXTENDED ? "0x05" : partition_type;
                jobs.phase (job, StorageJobState.RUNNING, "Creating partition");
                var reply = yield table.call ("CreatePartition", new Variant.tuple ({
                    new Variant.uint64 (offset), new Variant.uint64 (size), new Variant.string (type),
                    new Variant.string (partition_name), options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid partition object path.");
                string path = reply.get_child_value (0).get_string ();
                result.resulting_path = path;
                result.completed ("Partition created");
                var created = yield wait_for_block (path, token);
                if (created.partition == null) throw new IOError.INVALID_DATA ("The new object is not a partition.");
                if (filesystem_type != "" && filesystem_type != "empty" && kind != PartitionLayoutService.PartitionKind.MBR_EXTENDED) {
                    jobs.phase (job, StorageJobState.RUNNING, "Formatting partition");
                    var block_proxy = require_volume (created, "Block");
                    var format_options = new VariantBuilder (new VariantType ("a{sv}"));
                    if (filesystem_label != "") format_options.add ("{sv}", "label", new Variant.string (filesystem_label));
                    format_options.add ("{sv}", "update-partition-type", new Variant.boolean (true));
                    try {
                        yield block_proxy.call ("Format", new Variant.tuple ({ new Variant.string (filesystem_type),
                            format_options.end () }), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        result.completed ("Filesystem formatted");
                    } catch (Error error) {
                        result.fail ("The partition was created, but formatting failed. It remains available and unformatted.", error);
                        synchronize ();
                        jobs.finish (job, result);
                        select_requested (path);
                        return result;
                    }
                }
                synchronize ();
                result.successful = true;
                result.summary = kind == PartitionLayoutService.PartitionKind.MBR_EXTENDED ? "Extended partition created" :
                    filesystem_type == "" || filesystem_type == "empty" ? "Partition created" : "Partition created and formatted";
                jobs.finish (job, result);
                select_requested (path);
                return result;
            } catch (Error error) {
                result.fail (result.completed_steps.length == 0 ? "Partition creation failed." :
                    "Partition creation was only partially completed.", error);
                jobs.finish (job, result);
                if (result.partial) return result;
                throw error;
            } finally {
                locks.release (disk);
            }
        }

        private void validate_create_target (StorageBlock disk, StorageFreeSpace gap, uint64 requested_size,
            PartitionLayoutService.PartitionKind kind, string confirmed_identity,
            out uint64 offset, out uint64 size) throws Error {
            if (snapshot.blocks.lookup (disk.path) != disk || !disk.available || disk.read_only ||
                disk.table == null || gap.parent == null ||
                (gap.parent != disk && gap.parent.parent != disk) || modification_identity (disk) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The disk, partition table, or free-space geometry changed.");
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.CREATE_PARTITION,
                disk, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown || eligibility.requires_preparation)
                throw new IOError.PERMISSION_DENIED (eligibility.reason);
            PartitionLayoutService.validate_create (disk, gap, requested_size, kind, out offset, out size);
        }

        internal bool can_resize_encrypted_mapping (StorageBlock block) {
            var mapping = block.encrypted?.mapping;
            if (mapping == null || !luks_header_available () || !is_luks_header_candidate (block) ||
                block.read_only || block.backing_path != "/" || block.raid_path != "/" ||
                block.raid_member_path != "/" || mapping.read_only || !mapping.available || mapping.backing_path != block.path ||
                mapping.table != null || mapping.has_swap || mapping.encrypted != null ||
                mapping.logical_sector_size == 0 ||
                snapshot.dependencies.descendants (block).length != 2)
                return false;
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies) return false;
            return mapping.filesystem == null ? mapping.type_id == "" && mapping.usage == "" :
                mapping.type_id == "ext4" && mapping.uuid != "";
        }

        private void validate_encrypted_resize (StorageBlock block, StorageBlock mapping, string identity,
            string mapping_identity, uint64 expected_size, string backing_identity, uint64 backing_size,
            string backing_uuid) throws Error {
            synchronize ();
            if (snapshot.blocks.lookup (block.path) != block || snapshot.blocks.lookup (mapping.path) != mapping ||
                block.encrypted?.mapping != mapping ||
                (identity != "" && modification_identity (block) != identity) ||
                encrypted_backing_identity (block) != backing_identity ||
                block.size != backing_size || block.uuid != backing_uuid ||
                StoragePreparationJournal.device_identity (mapping) != mapping_identity || mapping.size != expected_size)
                throw new IOError.NOT_FOUND ("The encrypted backing device or cleartext mapping changed.");
            if (!can_resize_encrypted_mapping (block))
                throw new IOError.NOT_SUPPORTED ("The encrypted stack is no longer eligible for resizing.");
            if (KernelStorageSafety.block_capacity (block) != backing_size ||
                KernelStorageSafety.block_capacity (mapping) != expected_size)
                throw new IOError.FAILED ("Kernel capacities differ from the UDisks geometry.");
        }

        internal async bool has_encrypted_resize (StorageBlock block) throws Error {
            var proxy = require_volume (block, "Encrypted");
            var reply = yield proxy.get_connection ().call (proxy.get_name_owner (), proxy.get_object_path (),
                "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType ("(s)"),
                DBusCallFlags.NONE, 5000, backend_lifetime);
            return has_luks_method (reply.get_child_value (0).get_string (), PREFIX + "Encrypted", "Resize");
        }

        internal async uint64 encrypted_resize_minimum (StorageBlock mapping) throws Error {
            return yield minimum_sizes.query (mapping, backend_lifetime, true);
        }

        private string encrypted_backing_identity (StorageBlock block) {
            var partition = block.partition;
            uint64 offset = partition != null ? partition.offset : 0;
            return new Variant ("(ssstss)", StoragePreparationJournal.device_identity (block),
                partition?.uuid ?? "", block.logical_volume?.uuid ?? "", offset,
                block.logical_volume?.group_path ?? "", block.logical_volume_path).print (false);
        }

        private DBusProxy require_encrypted_backing_resize (StorageBlock block, uint64 requested) throws Error {
            if (block.partition != null) {
                var disk = snapshot.blocks.lookup (block.partition.table_path);
                if (disk == null || disk.read_only || disk.system_hint || disk.backing_path != "/" || disk.raid_path != "/" ||
                    block.partition.uuid == "" || block.partition.container || block.partition.logical)
                    throw new IOError.NOT_SUPPORTED ("Only an identified primary partition on a plain disk can be resized here.");
                PartitionLayoutService.validate_resize (disk, block, requested);
                return require_volume (block, "Partition");
            }
            var volume = block.logical_volume;
            var proxy = volume == null ? null : manager?.get_interface (volume.path, PREFIX + "LogicalVolume") as DBusProxy;
            var group = volume == null ? null : snapshot.advanced.lookup (volume.group_path) as StorageVolumeGroup;
            var vg = group == null ? null : manager?.get_interface (group.path, PREFIX + "VolumeGroup") as DBusProxy;
            if (proxy == null || volume == null || vg == null || group == null ||
                !volume.active || volume.uuid == "" || volume.size != block.size)
                throw new IOError.NOT_SUPPORTED ("Only an identified active plain logical volume can be resized here.");
            require_independent_lv (proxy, volume);
            if (group.extent_size == 0 || requested % group.extent_size != 0 ||
                (requested > block.size && requested - block.size > group.free_size) ||
                (vg.get_cached_property ("MissingPhysicalVolumes")?.n_children () ?? 1) != 0 ||
                volume_group_has_backend_job (group, { block }))
                throw new IOError.BUSY ("The logical-volume size is unaligned, exceeds free extents, or the group is busy.");
            return proxy;
        }

        internal uint64 encrypted_backing_maximum (StorageBlock block, out uint64 alignment) throws Error {
            var partition = block.partition;
            if (partition != null) {
                require_encrypted_backing_resize (block, block.size);
                var disk = snapshot.blocks.lookup (partition.table_path);
                alignment = disk.logical_sector_size;
                return PartitionLayoutService.maximum_resize (disk, block);
            }
            if (block.logical_volume != null) {
                require_encrypted_backing_resize (block, block.size);
                var group = snapshot.advanced.lookup (block.logical_volume.group_path) as StorageVolumeGroup;
                alignment = group.extent_size;
                if (group.free_size > uint64.MAX - block.size)
                    throw new IOError.INVALID_DATA ("Volume-group free capacity is invalid.");
                return block.size + group.free_size;
            }
            alignment = 0;
            return block.size;
        }

        internal async StorageOperationResult resize_encrypted_mapping (StorageBlock block,
            LuksHeaderReview header, uint64 requested, string passphrase, uint64 backing_requested = 0) throws Error {
            var mapping = block.encrypted?.mapping;
            if (mapping == null || !can_resize_encrypted_mapping (block))
                throw new IOError.NOT_SUPPORTED ("Resize requires an unlocked, supported LUKS stack.");
            uint64 old_size = mapping.size;
            uint64 alignment = uint64.max (header.encryption_sector_size, mapping.logical_sector_size);
            if (header.encryption_sector_size < 512 ||
                (header.encryption_sector_size & (header.encryption_sector_size - 1)) != 0 ||
                (alignment & (alignment - 1)) != 0 || header.data_offset >= block.size ||
                header.uuid != block.uuid || old_size > block.size - header.data_offset)
                throw new IOError.INVALID_DATA ("The LUKS payload geometry could not be verified.");
            uint64 final_backing = backing_requested == 0 ? block.size : backing_requested;
            if (final_backing <= header.data_offset)
                throw new IOError.INVALID_ARGUMENT ("The backing capacity must contain the LUKS header and payload.");
            uint64 maximum = final_backing - header.data_offset;
            maximum -= maximum % alignment;
            if (requested == 0 || requested > maximum || requested % alignment != 0 || requested == old_size)
                throw new IOError.INVALID_ARGUMENT ("Choose a different, sector-aligned size within the LUKS payload.");
            bool shrink = requested < old_size;
            bool resize_backing = final_backing != block.size;
            if (resize_backing && (final_backing < block.size) != shrink)
                throw new IOError.INVALID_ARGUMENT ("The backing device and cleartext mapping must resize in the same direction.");
            bool filesystem = mapping.filesystem != null;
            if (shrink && !filesystem)
                throw new IOError.NOT_SUPPORTED ("A bare mapping cannot be shrunk without a verified content boundary.");
            string mapping_identity = StoragePreparationJournal.device_identity (mapping);
            string backing_identity = encrypted_backing_identity (block);
            uint64 backing_size = block.size;
            string mapping_uuid = mapping.uuid;
            string mapping_type = mapping.type_id;
            var result = new StorageOperationResult ();
            StoragePreparationJournal? journal = null;
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Resize encrypted volume", block, snapshot.dependencies);
            var token = backend_lifetime;
            bool dispatched = false;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Validating LUKS geometry and resize support");
                if (!(yield has_encrypted_resize (block)))
                    throw new IOError.NOT_SUPPORTED ("UDisks does not expose Encrypted.Resize.");
                validate_encrypted_resize (block, mapping, header.identity, mapping_identity, old_size,
                    backing_identity, backing_size, header.uuid);
                string dm_uuid;
                FileUtils.get_contents ("/sys/dev/block/" + KernelStorageSafety.device_number (mapping.number) +
                    "/dm/uuid", out dm_uuid);
                if (!dm_uuid.has_prefix ("CRYPT-" + header.version + "-" + header.uuid.replace ("-", "") + "-"))
                    throw new IOError.NOT_SUPPORTED ("The active device-mapper UUID does not match the verified LUKS header.");
                var encrypted = require_volume (block, "Encrypted");
                if (resize_backing) require_encrypted_backing_resize (block, final_backing);
                DBusProxy? fs_proxy = filesystem ? require_volume (mapping, "Filesystem") : null;
                if (filesystem) {
                    var capability = FilesystemCapabilityService.decode (
                        yield query_filesystem_capability ("CanResize", mapping_type), true);
                    uint64 minimum = shrink ? yield minimum_sizes.query (mapping, token, true) : old_size;
                    var plan = FilesystemResizePlanner.build (mapping, requested, true, capability, minimum, maximum);
                    if (!plan.supported || (shrink && plan.online))
                        throw new IOError.NOT_SUPPORTED (plan.reason != "" ? plan.reason : "Encrypted shrinking requires an offline filesystem.");
                    if (plan.requires_unmount) {
                        validate_encrypted_resize (block, mapping, header.identity, mapping_identity, old_size,
                            backing_identity, backing_size, header.uuid);
                        journal = yield prepare_for_modification (mapping, token, job);
                    }
                    if (shrink) {
                        yield KernelStorageSafety.require_idle (mapping, token);
                        yield KernelStorageSafety.require_sole_dm_dependency (block, mapping, token);
                        if (!(yield maintenance_available (mapping_type, false)))
                            throw new IOError.NOT_SUPPORTED ("The required filesystem check is unavailable.");
                        validate_encrypted_resize (block, mapping, header.identity, mapping_identity, old_size,
                            backing_identity, backing_size, header.uuid);
                        yield check_encrypted_resize_filesystem (fs_proxy, token);
                        validate_encrypted_resize (block, mapping, header.identity, mapping_identity, old_size,
                            backing_identity, backing_size, header.uuid);
                        if (mapping.filesystem?.mounted != false || mapping.uuid != mapping_uuid || mapping.type_id != mapping_type)
                            throw new IOError.BUSY ("The filesystem changed before shrinking.");
                        jobs.phase (job, StorageJobState.RUNNING, "Shrinking the inner filesystem");
                        dispatched = true;
                        yield resize_storage_layer (fs_proxy, requested, token);
                        result.completed ("Inner filesystem shrunk");
                        yield check_encrypted_resize_filesystem (fs_proxy, token);
                        yield verify_lv_filesystem_size (mapping, require_volume (mapping, "Block"), requested, token);
                        result.completed ("Shrunk filesystem geometry verified");
                    }
                }
                if (shrink) yield KernelStorageSafety.require_idle (mapping, token);
                else yield KernelStorageSafety.require_no_holders (mapping, token);
                yield KernelStorageSafety.require_sole_dm_dependency (block, mapping, token);
                validate_encrypted_resize (block, mapping, header.identity, mapping_identity, old_size,
                    backing_identity, backing_size, header.uuid);
                if (mapping.uuid != mapping_uuid || mapping.type_id != mapping_type)
                    throw new IOError.NOT_FOUND ("The cleartext filesystem identity changed.");
                if (resize_backing && !shrink) {
                    var outer = require_encrypted_backing_resize (block, final_backing);
                    jobs.phase (job, StorageJobState.RUNNING, "Growing the encrypted backing device");
                    dispatched = true;
                    yield resize_storage_layer (outer, final_backing, token);
                    yield wait_for_size (block, final_backing, token);
                    backing_size = final_backing;
                    validate_encrypted_resize (block, mapping, "", mapping_identity, old_size,
                        backing_identity, backing_size, header.uuid);
                    if (block.logical_volume != null && block.logical_volume.size != final_backing)
                        throw new IOError.FAILED ("The logical volume capacity could not be verified.");
                    result.completed ("Backing device growth verified");
                }
                jobs.phase (job, StorageJobState.RUNNING, "Resizing the LUKS mapping");
                dispatched = true;
                var resize_options = new VariantBuilder (new VariantType ("a{sv}"));
                if (passphrase != "") resize_options.add ("{sv}", "passphrase", new Variant.string (passphrase));
                jobs.expect_backend (job, "encrypted-resize", block.path);
                yield call_tracked_method (job, encrypted, "Resize",
                    new Variant ("(t@a{sv})", requested, resize_options.end ()), token);
                passphrase = "";
                yield wait_for_size (mapping, requested, token);
                validate_encrypted_resize (block, mapping, "", mapping_identity, requested,
                    backing_identity, backing_size, header.uuid);
                result.completed ("LUKS mapping capacity verified");
                if (filesystem && !shrink) {
                    if (mapping.uuid != mapping_uuid || mapping.type_id != mapping_type)
                        throw new IOError.NOT_FOUND ("The cleartext filesystem identity changed.");
                    jobs.phase (job, StorageJobState.RUNNING, "Growing the inner filesystem");
                    yield resize_storage_layer (fs_proxy, 0, token);
                    result.completed ("Inner filesystem grown");
                    yield verify_lv_filesystem_size (mapping, require_volume (mapping, "Block"), requested, token);
                    result.completed ("Grown filesystem geometry verified");
                }
                if (resize_backing && shrink) {
                    yield KernelStorageSafety.require_idle (mapping, token);
                    yield KernelStorageSafety.require_sole_dm_dependency (block, mapping, token);
                    validate_encrypted_resize (block, mapping, "", mapping_identity, requested,
                        backing_identity, backing_size, header.uuid);
                    if (mapping.uuid != mapping_uuid || mapping.type_id != mapping_type)
                        throw new IOError.NOT_FOUND ("The verified inner filesystem changed.");
                    var outer = require_encrypted_backing_resize (block, final_backing);
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking the encrypted backing device");
                    yield resize_storage_layer (outer, final_backing, token);
                    yield wait_for_size (block, final_backing, token);
                    backing_size = final_backing;
                    if (block.logical_volume != null && block.logical_volume.size != final_backing)
                        throw new IOError.FAILED ("The logical volume capacity could not be verified.");
                    result.completed ("Backing device shrink verified");
                }
                validate_encrypted_resize (block, mapping, "", mapping_identity, requested,
                    backing_identity, backing_size, header.uuid);
                minimum_sizes.invalidate (mapping.path);
                result.successful = true;
                result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Encrypted volume resized";
            } catch (Error error) {
                result.fail (dispatched ? "Encrypted resize needs attention" : "Encrypted resize did not start", error);
                if (dispatched) {
                    result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                }
            } finally {
                if (journal != null && !journal.fully_restored ()) {
                    result.restoration_attempted = true;
                    if (result.successful || !dispatched) {
                        jobs.phase (job, StorageJobState.FINALIZING, "Restoring the original mount");
                        try {
                            yield restore_preparation (journal, token);
                            result.restoration_succeeded = true;
                        } catch (Error error) {
                            result.fail ("The original mount could not be restored", error);
                            result.status = StorageOperationStatus.NEEDS_ATTENTION;
                        }
                    } else {
                        result.technical_error += "\nThe original mount was withheld after an unverified resize.";
                    }
                }
                synchronize ();
                string actual_backing = "unavailable";
                string actual_mapping = "unavailable";
                if (snapshot.blocks.lookup (block.path) == block && block.available)
                    actual_backing = format_size (block.size);
                if (block.encrypted?.mapping == mapping && mapping.available)
                    actual_mapping = format_size (mapping.size);
                result.actual_state = "Backing device: " + actual_backing + "; cleartext mapping: " + actual_mapping + ".";
                if (block.encrypted?.mapping == mapping && mapping.filesystem != null && mapping.filesystem.size != 0)
                    result.actual_state += " UDisks filesystem capacity: " + format_size (mapping.filesystem.size) + ".";
                jobs.finish (job, result);
                locks.release (block);
            }
            return result;
        }

        private static async void resize_storage_layer (DBusProxy proxy, uint64 size,
            Cancellable token) throws Error {
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            yield proxy.call ("Resize", new Variant ("(t@a{sv})", size, options.end ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
        }

        private static async void check_encrypted_resize_filesystem (DBusProxy proxy, Cancellable token) throws Error {
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            var reply = yield proxy.call ("Check", new Variant.tuple ({ options.end () }),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
            if (!reply.is_of_type (new VariantType ("(b)")) || !reply.get_child_value (0).get_boolean ())
                throw new IOError.FAILED ("The filesystem did not pass its consistency check.");
        }

        public async StorageOperationResult resize_volume (StorageBlock block, uint64 new_size,
            bool resize_filesystem, string confirmed_identity) throws Error {
            var part = block.partition;
            var disk = part == null ? null : snapshot.blocks.lookup (part.table_path);
            if (disk == null) throw new IOError.NOT_SUPPORTED ("Only partitions can be resized.");
            PartitionLayoutService.validate_resize (disk, block, new_size);
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.RESIZE,
                block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.requires_preparation &&
                StorageSafetyService.assess (block, snapshot.dependencies).active_dependents)
                throw new IOError.BUSY (eligibility.reason);
            bool shrinking = new_size < block.size;
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The volume changed after confirmation.");
            var result = new StorageOperationResult ();
            var journal = new StoragePreparationJournal ();
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Resize volume", block, snapshot.dependencies);
            var token = job.cancellable;
            bool remount = false;
            try {
                var partition = require_volume (block, "Partition");
                string partition_uuid = part.uuid;
                uint64 partition_offset = part.offset;
                uint64 device_number = block.number;
                DBusProxy? filesystem = null;
                FilesystemCapacityMeasurement? offline_measurement = null;
                Error? offline_measurement_error = null;
                var plan = yield resize_plan (block, new_size, resize_filesystem);
                if (!plan.supported) throw new IOError.NOT_SUPPORTED (plan.reason);
                synchronize ();
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The volume changed after confirmation.");
                validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                if (resize_filesystem) {
                    filesystem = require_volume (block, "Filesystem");
                    if (plan.requires_unmount) {
                        jobs.phase (job, StorageJobState.PREPARING, "Unmounting filesystem");
                        var mount_record = yield plan_mount_preparation (block, token);
                        if (mount_record != null) {
                            journal.add (mount_record);
                            try {
                                remount = yield prepare_mount_entry (block, mount_record, token);
                            } catch (Error error) {
                                remount = mount_record.prepared;
                                throw error;
                            }
                        }
                    }
                }
                journal.operation_started = true;
                validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                plan = yield resize_plan (block, new_size, resize_filesystem, true);
                if (!plan.supported) throw new IOError.NOT_SUPPORTED (plan.reason);
                synchronize ();
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The volume changed while preparing the resize.");
                validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                PartitionLayoutService.validate_resize (disk, block, new_size);
                if (resize_filesystem && (block.filesystem?.mounted ?? false) != plan.online)
                    throw new IOError.BUSY ("The filesystem mount state changed while preparing the resize.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                bool btrfs = resize_filesystem && block.type_id.down () == "btrfs";
                if (shrinking && resize_filesystem) {
                    if (plan.requires_check) {
                        if (!(yield maintenance_available (block.type_id, false)))
                            throw new IOError.NOT_SUPPORTED ("A required pre-shrink filesystem check is unavailable.");
                        jobs.phase (job, StorageJobState.RUNNING, "Checking filesystem");
                        var checked_reply = yield filesystem.call ("Check", new Variant.tuple ({ options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        if (!checked_reply.is_of_type (new VariantType ("(b)")) || !checked_reply.get_child_value (0).get_boolean ())
                            throw new IOError.FAILED ("Filesystem inconsistencies must be repaired before shrinking.");
                        result.completed ("Filesystem checked");
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                    }
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                    else yield KernelStorageSafety.require_idle (block, token);
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking filesystem");
                    journal.backend_invoked = true;
                    yield filesystem.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Filesystem shrunk");
                    if (btrfs) {
                        uint64 capacity = yield FilesystemMinimumSizeService.query_single_btrfs_capacity (block, token);
                        if (capacity > new_size)
                            throw new IOError.FAILED ("The Btrfs filesystem still exceeds the requested size; the partition was left unchanged.");
                        synchronize ();
                    }
                    if (plan.requires_check) {
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                        var verified = yield filesystem.call ("Check", new Variant.tuple ({ options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        if (!verified.is_of_type (new VariantType ("(b)")) || !verified.get_child_value (0).get_boolean ())
                            throw new IOError.FAILED ("The resized filesystem did not pass its post-resize verification; the partition was left unchanged.");
                        result.completed ("Resized filesystem verified");
                    }
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    PartitionLayoutService.validate_resize (disk, block, new_size);
                    // Adapted from GNOME Disks online_resize_no_repair (GPL-2.0-or-later).
                    // Copyright (C) 2017 Kai Lüke
                    if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                    else yield KernelStorageSafety.require_idle (block, token);
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking partition");
                    journal.backend_invoked = true;
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition shrunk");
                    yield wait_for_size (block, new_size, token);
                } else {
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                    else yield KernelStorageSafety.require_idle (block, token);
                    jobs.phase (job, StorageJobState.RUNNING, shrinking ? "Shrinking partition" : "Growing partition");
                    journal.backend_invoked = true;
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed (shrinking ? "Partition shrunk" : "Partition grown");
                    yield wait_for_size (block, new_size, token);
                    if (resize_filesystem) {
                        validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                        if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                        else yield KernelStorageSafety.require_idle (block, token);
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                        jobs.phase (job, StorageJobState.RUNNING, "Growing filesystem");
                        journal.backend_invoked = true;
                        yield filesystem.call ("Resize", new Variant.tuple ({ new Variant.uint64 (0), options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        result.completed ("Filesystem grown");
                    }
                }
                if (resize_filesystem && !plan.online) {
                    synchronize ();
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    jobs.phase (job, StorageJobState.FINALIZING, "Verifying filesystem metadata");
                    try {
                        var probe_lifetime = backend_lifetime;
                        var probe_target = require_volume (block, "Block");
                        uint64 probe_size = block.size;
                        string probe_type = block.type_id;
                        var measurement = yield capacity_probes.query (block, probe_lifetime, probe_target);
                        synchronize ();
                        probe_lifetime.set_error_if_cancelled ();
                        validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                        if (probe_target != require_volume (block, "Block") ||
                            block.size != probe_size || block.type_id != probe_type)
                            throw new IOError.NOT_FOUND ("The filesystem changed during capacity verification.");
                        FilesystemCapacityProbeService.verify_uuid (block.uuid, measurement.filesystem_uuid);
                        offline_measurement = measurement;
                    } catch (Error probe_error) {
                        offline_measurement_error = probe_error;
                    }
                }
                if (remount) {
                    jobs.phase (job, StorageJobState.FINALIZING, "Restoring mount");
                    result.restoration_attempted = true;
                    try {
                        yield restore_preparation (journal, backend_lifetime); result.completed ("Original mount restored");
                        result.restoration_succeeded = true;
                    }
                    catch (Error error) {
                        result.fail ("The resize completed, but the previous mount could not be restored.", error);
                        result.status = StorageOperationStatus.NEEDS_ATTENTION;
                        result.technical_error += "\nAffected storage still requiring attention:\n" + journal.recovery_details ();
                        jobs.finish (job, result);
                        return result;
                    }
                }
                synchronize ();
                bool filesystem_verified = !resize_filesystem;
                if (resize_filesystem) {
                    if (offline_measurement != null) {
                        if (!FilesystemCapacityProbeService.authoritative_match (offline_measurement,
                            new_size, block.size, block.logical_sector_size, block.physical_sector_size))
                            throw new IOError.FAILED ("The filesystem metadata capacity does not match the requested resize result.");
                        filesystem_verified = true;
                        result.actual_state = "Verified offline filesystem capacity from " + offline_measurement.source +
                            ": " + format_size (offline_measurement.capacity) + "; partition capacity: " +
                            format_size (block.size) + ".";
                        result.completed ("Offline filesystem capacity verified");
                    } else {
                        uint64 capacity;
                        if (btrfs) {
                            capacity = yield FilesystemMinimumSizeService.query_single_btrfs_capacity (block, backend_lifetime);
                            synchronize ();
                            validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                            if (block.size != new_size)
                                throw new IOError.FAILED ("The partition geometry changed during filesystem capacity verification.");
                        } else {
                            capacity = yield mounted_filesystem_capacity (block, backend_lifetime);
                        }
                        if (capacity == 0) {
                            string detail = offline_measurement_error == null ?
                                "the filesystem was not mounted" : offline_measurement_error.message;
                            result.actual_state = "UDisks confirmed the resize, but filesystem capacity could not be independently verified: " +
                                detail + ".";
                        } else {
                            uint64 tolerance = FilesystemResizePlanner.capacity_tolerance (block.type_id,
                                block.logical_sector_size, block.physical_sector_size);
                            if (tolerance == 0) {
                                result.actual_state = "UDisks confirmed the resize, but no authoritative capacity rule is available for " +
                                    (block.type_id == "" ? "this filesystem" : block.type_id) + ".";
                            } else if (!FilesystemResizePlanner.capacity_matches (block.type_id, capacity,
                                block.size, new_size, block.logical_sector_size, block.physical_sector_size)) {
                                throw new IOError.FAILED ("The filesystem capacity reported after resizing does not match the requested partition capacity.");
                            } else {
                                filesystem_verified = true;
                                result.actual_state = "Verified mounted filesystem capacity: " + format_size (capacity) +
                                    "; partition capacity: " + format_size (block.size) +
                                    "; maximum format-specific difference: " + format_size (tolerance) + ".";
                                result.completed ("Filesystem capacity verified");
                            }
                        }
                    }
                }
                minimum_sizes.invalidate (block.path);
                journal.operation_completed = true;
                result.successful = filesystem_verified;
                result.partial = !filesystem_verified;
                result.status = filesystem_verified ? StorageOperationStatus.SUCCEEDED :
                    StorageOperationStatus.PARTIAL;
                result.summary = filesystem_verified ? "Volume resized" :
                    "Volume resized, but filesystem capacity could not be independently verified";
                jobs.finish (job, result);
                select_requested (block.path);
                return result;
            } catch (Error error) {
                string restoration_error = "";
                synchronize ();
                reconcile_preparation (journal);
                bool withheld_restoration = !journal.fully_restored () && journal.backend_invoked;
                if (withheld_restoration) {
                    foreach (var entry in journal.entries ())
                        entry.restoration_allowed = false;
                    reconcile_preparation (journal);
                } else if (!journal.fully_restored ()) {
                    result.restoration_attempted = true;
                    try {
                        yield restore_preparation (journal, backend_lifetime);
                        result.restoration_succeeded = true;
                    } catch (Error restore_error) { restoration_error = restore_error.message; }
                }
                result.fail (result.completed_steps.length == 0 ? (journal.backend_invoked ?
                    "The resize outcome could not be verified." : "The volume was not resized.") :
                    "The resize was partially completed. The displayed geometry has been refreshed.", error);
                if (restoration_error != "") {
                    result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary += " The previous mount could not be restored.";
                    result.technical_error += "\nRestore: " + restoration_error;
                }
                if (journal.backend_invoked) result.status = StorageOperationStatus.NEEDS_ATTENTION;
                if (withheld_restoration) {
                    result.technical_error += "\nAutomatic remount was withheld because a resize request was dispatched. Verify the filesystem and partition before remounting or retrying.";
                }
                string recovery = journal.recovery_details ();
                if (recovery != "")
                    result.technical_error += "\nAffected storage still requiring attention:\n" + recovery;
                result.actual_state = "%s · %s reported by UDisks".printf (block.preferred, format_size (block.size));
                jobs.finish (job, result);
                return result;
            } finally {
                locks.release (block);
            }
        }

        private async uint64 mounted_filesystem_capacity (StorageBlock block, Cancellable token) {
            synchronize ();
            var mounts = block.filesystem?.mounts ?? new string[0];
            if (mounts.length == 0) return 0;
            try {
                var info = yield File.new_for_path (mounts[0]).query_filesystem_info_async (
                    FileAttribute.FILESYSTEM_SIZE, Priority.DEFAULT, token);
                return info.has_attribute (FileAttribute.FILESYSTEM_SIZE) ?
                    info.get_attribute_uint64 (FileAttribute.FILESYSTEM_SIZE) : 0;
            } catch (Error error) { return 0; }
        }

        private void validate_resize_target (StorageBlock block, StorageBlock disk, string partition_uuid,
            uint64 partition_offset, uint64 device_number) throws Error {
            var current = snapshot.blocks.lookup (block.path);
            var part = block.partition;
            if (current != block || !block.available || block.read_only || part == null ||
                snapshot.blocks.lookup (part.table_path) != disk || disk.table == null ||
                part.uuid != partition_uuid || part.offset != partition_offset || block.number != device_number)
                throw new IOError.NOT_FOUND ("The partition identity or parent table changed during resizing.");
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies || safety.active_dependents)
                throw new IOError.BUSY ("The dependency or kernel-use state changed during resizing.");
        }

        public async StorageOperationResult update_partition_metadata (StorageBlock block, string type,
            string name, uint64 flags, string confirmed_identity) throws Error {
            var part = block.partition;
            var disk = part == null ? null : snapshot.blocks.lookup (part.table_path);
            string scheme = disk?.table?.scheme ?? "";
            if (part == null || (scheme != "gpt" && scheme != "dos") || type.strip () == "" || !type.validate () ||
                (scheme == "gpt" && (!name.validate () || name.char_count () > 36 || name.contains ("\n"))) ||
                (scheme == "dos" && part.logical && flags != part.flags))
                throw new IOError.INVALID_ARGUMENT ("The requested partition metadata is invalid.");
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The partition changed after confirmation.");
            locks.acquire (block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            var job = jobs.begin ("Edit partition", block, snapshot.dependencies);
            var token = job.cancellable;
            string partition_uuid = part.uuid; uint64 partition_offset = part.offset;
            uint64 device_number = block.number; string expected_type = part.type_id;
            string expected_name = part.name; uint64 expected_flags = part.flags;
            try {
                var proxy = require_volume (block, "Partition");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                jobs.phase (job, StorageJobState.RUNNING, "Updating partition metadata");
                if (type != part.type_id) {
                    yield KernelStorageSafety.require_idle (block, token);
                    validate_metadata_target (StorageOperationKind.EDIT_PARTITION_TYPE, block, disk, partition_uuid, partition_offset, device_number,
                        expected_type, expected_name, expected_flags);
                    yield proxy.call ("SetType", new Variant.tuple ({ new Variant.string (type), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition type updated");
                    expected_type = type;
                    yield wait_for_metadata (block, expected_type, expected_name, expected_flags, token);
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                }
                if (scheme == "gpt" && name != part.name) {
                    validate_metadata_target (StorageOperationKind.EDIT_PARTITION_NAME, block, disk, partition_uuid, partition_offset, device_number,
                        expected_type, expected_name, expected_flags);
                    yield proxy.call ("SetName", new Variant.tuple ({ new Variant.string (name), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition name updated");
                    expected_name = name;
                    yield wait_for_metadata (block, expected_type, expected_name, expected_flags, token);
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                }
                if (flags != part.flags) {
                    yield KernelStorageSafety.require_idle (block, token);
                    validate_metadata_target (StorageOperationKind.EDIT_PARTITION_FLAGS, block, disk, partition_uuid, partition_offset, device_number,
                        expected_type, expected_name, expected_flags);
                    yield proxy.call ("SetFlags", new Variant.tuple ({ new Variant.uint64 (flags), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition flags updated");
                    expected_flags = flags;
                    yield wait_for_metadata (block, expected_type, expected_name, expected_flags, token);
                }
                synchronize ();
                result.successful = true;
                result.summary = "Partition metadata updated";
                jobs.finish (job, result);
                return result;
            } catch (Error error) {
                result.fail (result.completed_steps.length == 0 ? "Partition metadata was not changed." :
                    "Some partition metadata was updated before a later step failed.", error);
                synchronize ();
                jobs.finish (job, result);
                if (result.partial) return result;
                throw error;
            } finally {
                locks.release (block);
            }
        }

        private void validate_metadata_target (StorageOperationKind operation, StorageBlock block, StorageBlock disk, string uuid,
            uint64 offset, uint64 number, string expected_type, string expected_name, uint64 expected_flags) throws Error {
            var part = block.partition;
            var eligibility = StorageSafetyService.assess_operation (operation,
                block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown || eligibility.requires_preparation ||
                snapshot.blocks.lookup (block.path) != block || !block.available || block.read_only ||
                part == null || snapshot.blocks.lookup (part.table_path) != disk || part.uuid != uuid ||
                part.offset != offset || block.number != number || part.type_id != expected_type ||
                part.name != expected_name || part.flags != expected_flags)
                throw new IOError.NOT_FOUND (eligibility.reason == "" ?
                    "The partition identity, geometry, or metadata changed unexpectedly." : eligibility.reason);
        }

        private async void wait_for_metadata (StorageBlock block, string type, string name, uint64 flags,
            Cancellable token) throws Error {
            for (int attempt = 0; attempt < 50; attempt++) {
                synchronize ();
                var part = block.partition;
                if (part != null && part.type_id == type && part.name == name && part.flags == flags) return;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("UDisks did not publish the updated partition metadata.");
        }

        public async void cancel_job (StorageJob job) throws Error {
            var raid = raid_checks.lookup (job.id);
            if (raid != null) {
                string action = job.operation == "RAID consistency repair" ? "repair" : "check";
                var array = snapshot.advanced.lookup (raid.get_object_path ()) as StorageRaid;
                if (!job.cancelable || manager?.get_interface (raid.get_object_path (), PREFIX + "MDRaid") != raid ||
                    raid.get_cached_property ("SyncAction")?.get_string () != action || array?.kernel?.action != action)
                    throw new IOError.NOT_SUPPORTED ("The observed RAID consistency operation is no longer running.");
                stopping_raid_checks.insert (job.id, job);
                job.cancelable = false;
                jobs.phase (job, StorageJobState.CANCELLING, "Requesting that the RAID check stop");
                try {
                    yield raid.call ("RequestSyncAction",
                        new Variant ("(s@a{sv})", "idle", new Variant ("a{sv}", null)),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000, backend_lifetime);
                    jobs.phase (job, StorageJobState.RUNNING, "Waiting for the RAID check to stop");
                } catch (Error error) {
                    stopping_raid_checks.remove (job.id);
                    job.cancelable = !StorageJobManager.terminal (job.state);
                    jobs.phase (job, StorageJobState.RUNNING, "Cancellation was not confirmed");
                    throw error;
                }
                return;
            }
            if (job.local && job.cancelable && job.backend_path == "" && !StorageJobManager.terminal (job.state)) {
                job.cancelable = false;
                jobs.phase (job, StorageJobState.CANCELLING, "Cancelling");
                job.cancellable.cancel ();
                return;
            }
            if (!job.cancelable || job.backend_path == "")
                throw new IOError.NOT_SUPPORTED ("This operation cannot be cancelled by UDisks.");
            var proxy = manager?.get_interface (job.backend_path, PREFIX + "Job") as DBusProxy;
            if (proxy == null) throw new IOError.NOT_FOUND ("The UDisks job is no longer available.");
            jobs.phase (job, StorageJobState.CANCELLING, "Requesting cancellation");
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            try {
                yield proxy.call ("Cancel", new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
            } catch (Error error) {
                jobs.phase (job, StorageJobState.RUNNING, "Cancellation was not accepted");
                job.error_message = error.message;
                throw error;
            }
            synchronize ();
        }

        public async bool check_filesystem (StorageBlock block, bool repair = false) throws Error {
            var filesystem = require_volume (block, "Filesystem");
            var eligibility = StorageSafetyService.assess_operation (repair ? StorageOperationKind.REPAIR_FILESYSTEM :
                StorageOperationKind.CHECK_FILESYSTEM, block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown)
                throw new IOError.PERMISSION_DENIED (eligibility.reason);
            validate_check (block, true);
            if (repair && (block.read_only || block.system_hint))
                throw new IOError.PERMISSION_DENIED ("Repair is unavailable on protected or read-only storage.");
            string filesystem_type = block.type_id;
            string target_identity = modification_identity (block);
            var lifetime = backend_lifetime;
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (repair ? "Repair filesystem" : "Check filesystem", block, snapshot.dependencies);
            var operation_result = new StorageOperationResult ();
            var preparation = new StoragePreparationJournal ();
            try {
                if (!(yield maintenance_available (filesystem_type, repair)))
                    throw new IOError.NOT_SUPPORTED (repair ? "UDisks does not support repairing this filesystem." :
                        "UDisks does not support checking this filesystem.");
                jobs.phase (job, StorageJobState.PREPARING, "Preparing filesystem");
                job.cancelable = true;
                preparation = yield prepare_for_modification (block, job.cancellable, job);
                yield KernelStorageSafety.require_idle (block, job.cancellable);
                job.cancellable.set_error_if_cancelled ();
                job.cancelable = false;
                if (lifetime.is_cancelled () || require_volume (block, "Filesystem") != filesystem ||
                    block.type_id != filesystem_type || modification_identity (block) != target_identity)
                    throw new IOError.NOT_FOUND ("The selected volume changed before the check could start.");
                validate_check (block);
                if (repair && (block.read_only || block.system_hint))
                    throw new IOError.PERMISSION_DENIED ("The volume is now protected or read-only.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                jobs.phase (job, StorageJobState.RUNNING, repair ? "Repairing filesystem" : "Checking filesystem");
                var result = yield filesystem.call (repair ? "Repair" : "Check", new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                require_volume (block, "Filesystem");
                if (!result.is_of_type (new VariantType ("(b)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid filesystem check result.");
                bool successful = result.get_child_value (0).get_boolean ();
                operation_result.completed (repair ? "Filesystem repair completed" : "Filesystem check completed");
                if (preparation.entries ().length != 0) {
                    jobs.phase (job, StorageJobState.FINALIZING, "Restoring mount");
                    yield restore_preparation (preparation, lifetime); operation_result.completed ("Original state restored");
                }
                minimum_sizes.invalidate (block.path);
                operation_result.successful = successful;
                operation_result.summary = successful ? (repair ? "Filesystem repaired" : "Filesystem is consistent") :
                    (repair ? "Filesystem could not be repaired" : "Filesystem inconsistencies detected");
                if (!successful) operation_result.status = StorageOperationStatus.FAILED;
                jobs.finish (job, operation_result);
                return successful;
            } catch (Error error) {
                if (operation_result.completed_steps.length > 0 && !preparation.fully_restored ()) {
                    string summary = repair ? "Filesystem repair returned, but storage restoration is incomplete." :
                        "Filesystem check returned, but storage restoration is incomplete.";
                    operation_result.fail (summary, error);
                    operation_result.partial = true;
                    operation_result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    jobs.finish (job, operation_result);
                    throw new StorageRestorationError.INCOMPLETE (summary + "\n" + error.message);
                }
                if (!preparation.fully_restored ()) {
                    try { yield restore_preparation (preparation, lifetime); }
                    catch (Error mount_error) {
                        operation_result.fail ((repair ? "Repair" : "Check") + " failed and the previous mount could not be restored", error);
                        operation_result.status = StorageOperationStatus.NEEDS_ATTENTION;
                        operation_result.technical_error += "\nRestore: " + mount_error.message;
                        jobs.finish (job, operation_result);
                        throw new IOError.FAILED ("%s The previous mount also could not be restored: %s".printf (
                            error.message, mount_error.message));
                    }
                }
                operation_result.fail ((repair ? "Filesystem repair" : "Filesystem check") + " failed", error);
                jobs.finish (job, operation_result);
                throw error;
            } finally {
                locks.release (block);
            }
        }
        public async void configure_mount (StorageBlock block, bool enabled, bool startup,
            string directory, string filesystem, string mount_options, Variant? original_item,
            string confirmed_identity, string confirmed_uuid) throws Error {
            if (block.filesystem == null || block.uuid == "" || block.read_only || block.system_hint)
                throw new IOError.NOT_SUPPORTED ("Persistent mount configuration is unavailable for this volume.");
            if (enabled && (!Path.is_absolute (directory) || directory.contains ("\n") || directory.contains ("\r") ||
                filesystem.contains ("\n") || filesystem.contains ("\r") || mount_options.contains ("\n") ||
                mount_options.contains ("\r")))
                throw new IOError.INVALID_ARGUMENT ("The mount path or options are invalid.");
            if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                throw new IOError.NOT_FOUND ("The volume changed after the mount configuration dialog was opened.");
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.MOUNT, block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown || StorageSafetyService.assess (block, snapshot.dependencies).system_critical)
                throw new IOError.PERMISSION_DENIED (eligibility.reason == "" ? "This system-critical mount cannot be changed here." : eligibility.reason);
            string options_text = MountOptionService.normalize (mount_options, startup);
            if (enabled) MountOptionService.validate_configuration (directory, filesystem, options_text);
            int32 frequency = 0; int32 pass_number = 0;
            string device = "UUID=" + block.uuid;
            if (original_item != null) {
                var old_details = original_item.get_child_value (1);
                device = old_details.lookup_value ("fsname", VariantType.BYTESTRING)?.get_bytestring () ?? device;
                frequency = old_details.lookup_value ("freq", VariantType.INT32)?.get_int32 () ?? 0;
                pass_number = old_details.lookup_value ("passno", VariantType.INT32)?.get_int32 () ?? 0;
            }
            var details = new VariantBuilder (new VariantType ("a{sv}"));
            details.add ("{sv}", "fsname", new Variant.bytestring (device));
            details.add ("{sv}", "dir", new Variant.bytestring (directory));
            details.add ("{sv}", "type", new Variant.bytestring (filesystem.strip () == "" ? "auto" : filesystem.strip ()));
            details.add ("{sv}", "opts", new Variant.bytestring (options_text));
            details.add ("{sv}", "freq", new Variant.int32 (frequency));
            details.add ("{sv}", "passno", new Variant.int32 (pass_number));
            var item = new Variant.tuple ({ new Variant.string ("fstab"), details.end () });
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            var proxy = require_volume (block, "Block");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (enabled ? "Configure mount" : "Restore mount defaults", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            try {
                jobs.phase (job, StorageJobState.RUNNING, "Updating persistent mount configuration");
                var existing = original_item;
                synchronize ();
                if (snapshot.blocks.lookup (block.path) != block ||
                    modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                    throw new IOError.NOT_FOUND ("The volume changed immediately before the configuration write.");
                if (StorageSafetyService.assess (block, snapshot.dependencies).system_critical)
                    throw new IOError.PERMISSION_DENIED ("This system-critical mount cannot be changed here.");
                bool current_entry = existing == null;
                foreach (var candidate in snapshot.blocks.get_values ()) {
                    foreach (var saved in candidate.mount_configurations) {
                        bool selected_entry = candidate == block && existing != null &&
                            saved.backend_item != null && saved.backend_item.equal (existing);
                        current_entry |= selected_entry;
                        if (enabled && !selected_entry && saved.directory == directory)
                            throw new IOError.EXISTS ("Another persistent configuration already uses this mount point.");
                    }
                }
                if (!current_entry)
                    throw new IOError.NOT_FOUND ("The selected fstab entry changed while the dialog was open.");
                if (!enabled && existing != null)
                    yield proxy.call ("RemoveConfigurationItem", new Variant.tuple ({ existing, options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled && existing != null)
                    yield proxy.call ("UpdateConfigurationItem", new Variant.tuple ({ existing, item, options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled)
                    yield proxy.call ("AddConfigurationItem", new Variant.tuple ({ item, options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                bool verified = false;
                for (int attempt = 0; attempt < 50 && !verified; attempt++) {
                    synchronize (); verified = !enabled;
                    foreach (var saved in block.mount_configurations) {
                        if (!enabled && saved.backend_item != null && existing != null && saved.backend_item.equal (existing)) verified = false;
                        if (enabled && saved.directory == directory && saved.options == options_text &&
                            saved.filesystem == (filesystem.strip () == "" ? "auto" : filesystem.strip ()) &&
                            saved.device == device && saved.backend_item != null) {
                            var saved_details = saved.backend_item.get_child_value (1);
                            verified |= saved_details.lookup_value ("freq", VariantType.INT32)?.get_int32 () == frequency &&
                                saved_details.lookup_value ("passno", VariantType.INT32)?.get_int32 () == pass_number;
                        }
                    }
                    if (!verified) yield settle_delay (backend_lifetime);
                }
                if (!verified) throw new IOError.FAILED ("UDisks did not publish the requested persistent mount configuration.");
                result.successful = true; result.summary = "Mount configuration updated"; jobs.finish (job, result);
            } catch (Error error) { result.fail ("Mount configuration was not updated", error); jobs.finish (job, result); throw error; }
            finally { locks.release (block); }
        }
        public async StorageOperationResult unlock_volume (StorageBlock block, string passphrase,
            string confirmed_identity, string[] keyfile_paths = {}, uint32 pim = 0,
            bool hidden = false, bool system = false, bool read_only = false) throws Error {
            if (block.encrypted == null)
                throw new IOError.NOT_SUPPORTED ("The selected volume is not exposed as encrypted storage by UDisks.");
            if (block.encrypted.mapping != null)
                throw new IOError.EXISTS ("The encrypted volume is already unlocked.");
            if (passphrase != "" && keyfile_paths.length != 0)
                throw new IOError.INVALID_ARGUMENT ("Choose either a passphrase or a single keyfile.");
            if (passphrase == "" && keyfile_paths.length == 0)
                throw new IOError.INVALID_ARGUMENT ("Enter a passphrase or select a supported keyfile.");
            bool luks = block.type_id == "crypto_LUKS";
            if (pim != 0 || hidden || system || keyfile_paths.length > 1)
                throw new IOError.NOT_SUPPORTED ("Advanced VeraCrypt credentials require a cryptsetup backend.");
            if (!luks && keyfile_paths.length != 0)
                throw new IOError.NOT_SUPPORTED ("Keyfile unlocking through UDisks is available for LUKS.");

            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The encrypted volume changed before it could be unlocked.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Unlock encrypted volume", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            try {
                var credential = new RestorationCredential (passphrase, keyfile_paths.length == 1 ? keyfile_paths[0] : "");
                passphrase = "";
                string cleartext_path;
                var mapping = yield unlock_in_job (block, credential, confirmed_identity, read_only,
                    job, backend_lifetime, int.MAX, out cleartext_path);
                if (mapping == null) {
                    result.completed ("UDisks accepted the credential and returned " + cleartext_path);
                    result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary = "The encrypted volume may be unlocked. Refresh to verify the resulting mapping.";
                    result.resulting_path = cleartext_path;
                    result.actual_state = "unlock outcome requires reconciliation";
                } else {
                    result.successful = true;
                    result.status = StorageOperationStatus.SUCCEEDED;
                    result.summary = "Encrypted volume unlocked";
                    result.resulting_path = mapping.path;
                    result.actual_state = mapping.preferred;
                }
                jobs.finish (job, result);
                return result;
            } catch (Error error) {
                result.fail ("The encrypted volume could not be unlocked", error);
                jobs.finish (job, result);
                throw error;
            } finally {
                locks.release (block);
            }
        }

        private async StorageBlock? unlock_in_job (StorageBlock block, RestorationCredential credential,
            string confirmed_identity, bool read_only, StorageJob job, Cancellable lifetime,
            int timeout, out string cleartext_path) throws Error {
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.MOUNT,
                block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown)
                throw new IOError.PERMISSION_DENIED (eligibility.reason);
            uint8[] keyfile_contents = {};
            size_t keyfile_size = 0;
            cleartext_path = "";
            try {
                if (!credential.managed && credential.passphrase == "" && credential.keyfile == "")
                    throw new IOError.INVALID_ARGUMENT ("An unlocking credential is required.");
                if (credential.keyfile != "") {
                    string keyfile_path = credential.keyfile;
                    if (!Path.is_absolute (keyfile_path))
                        throw new IOError.INVALID_ARGUMENT ("The keyfile must be an absolute local path.");
                    const int max_keyfile_size = 8 * 1024 * 1024;
                    int fd = Posix.open (keyfile_path, Posix.O_RDONLY | Posix.O_CLOEXEC |
                        Posix.O_NOFOLLOW | Posix.O_NONBLOCK);
                    if (fd < 0)
                        throw new IOError.FAILED ("Could not open the keyfile: " + Posix.strerror (Posix.errno));
                    var stream = new UnixInputStream (fd, true);
                    try {
                        Posix.Stat info = {};
                        if (Posix.fstat (fd, out info) != 0 || !Posix.S_ISREG (info.st_mode) ||
                            info.st_size <= 0 || info.st_size > max_keyfile_size)
                            throw new IOError.INVALID_ARGUMENT ("Choose a nonempty regular keyfile no larger than 8 MiB.");
                        keyfile_contents = new uint8[(int) info.st_size + 1];
                        yield stream.read_all_async (keyfile_contents, Priority.DEFAULT, lifetime, out keyfile_size);
                        if (keyfile_size != info.st_size)
                            throw new IOError.INVALID_DATA ("The keyfile size changed while it was being read.");
                    } finally { stream = null; }
                }
                lifetime.set_error_if_cancelled ();
                synchronize ();
                jobs.phase (job, StorageJobState.RUNNING, "Authorizing and unlocking encrypted storage");
                if (modification_identity (block) != confirmed_identity || block.encrypted?.mapping != null)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed before the unlock request was sent.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (read_only || block.read_only)
                    options.add ("{sv}", "read-only", new Variant.boolean (true));
                if (keyfile_contents.length != 0)
                    options.add ("{sv}", "keyfile_contents", new Variant.from_bytes (
                        new VariantType ("ay"), new Bytes (keyfile_contents[0:(int) keyfile_size]), true));
                var encrypted = require_volume (block, "Encrypted");
                jobs.expect_backend (job, "encrypted-unlock", block.path);
                var reply = yield call_tracked_method (job, encrypted, "Unlock",
                    new Variant ("(s@a{sv})", credential.passphrase, options.end ()), lifetime, timeout);
                credential.passphrase = "";
                if (keyfile_contents.length != 0)
                    Memory.set (keyfile_contents, 0, keyfile_contents.length);
                if (!reply.is_of_type (new VariantType ("(o)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid cleartext object path.");
                cleartext_path = reply.get_child_value (0).get_string ();
                StorageBlock? mapping = null;
                for (int attempt = 0; attempt < 50 && mapping == null; attempt++) {
                    synchronize ();
                    mapping = snapshot.blocks.lookup (cleartext_path);
                    if (mapping == null) yield settle_delay (backend_lifetime);
                }
                if (mapping == null || mapping.backing_path != block.path ||
                    ((read_only || block.read_only) && !mapping.read_only))
                    return null;
                return mapping;
            } finally {
                credential.passphrase = "";
                if (keyfile_contents.length != 0)
                    Memory.set (keyfile_contents, 0, keyfile_contents.length);
            }
        }

        public async StorageOperationResult lock_volume (StorageBlock block, string confirmed_identity) throws Error {
            var mapping = block.encrypted?.mapping;
            if (block.encrypted == null || mapping == null)
                throw new IOError.NOT_SUPPORTED ("The encrypted volume is not unlocked.");
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The encrypted volume changed before it could be locked.");
            var safety = StorageSafetyService.assess (mapping, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies)
                throw new IOError.PERMISSION_DENIED ("System-critical or unresolved encrypted storage cannot be locked.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Lock encrypted volume", block, snapshot.dependencies);
            var result = new StorageOperationResult (); StoragePreparationJournal? preparation = null;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Preparing the clear-text mapping");
                preparation = yield prepare_for_modification (mapping, backend_lifetime, job);
                if (modification_identity (block) != confirmed_identity || block.encrypted?.mapping != mapping)
                    throw new IOError.NOT_FOUND ("The encrypted mapping changed during preparation.");
                jobs.phase (job, StorageJobState.RUNNING, "Locking encrypted storage");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                yield require_volume (block, "Encrypted").call ("Lock",
                    new Variant ("(@a{sv})", options.end ()), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    int.MAX, backend_lifetime);
                bool locked = false;
                for (int attempt = 0; attempt < 50 && !locked; attempt++) {
                    synchronize (); locked = block.encrypted?.mapping == null;
                    if (!locked) yield settle_delay (backend_lifetime);
                }
                if (!locked) {
                    result.completed ("UDisks accepted the lock request"); result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary = "The lock request completed, but the clear-text mapping is still visible. Its previous mount state will be restored.";
                    result.actual_state = "mapping still visible";
                    if (preparation != null && !preparation.fully_restored ()) {
                        result.restoration_attempted = true;
                        try { yield restore_preparation (preparation, backend_lifetime); result.restoration_succeeded = true; }
                        catch (Error restore_error) {
                            result.restoration_succeeded = false; result.technical_error = restore_error.message;
                            result.status = StorageOperationStatus.NEEDS_ATTENTION;
                        }
                    }
                    jobs.finish (job, result); return result;
                }
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Encrypted volume locked"; result.actual_state = "locked"; jobs.finish (job, result);
                return result;
            } catch (Error error) {
                synchronize ();
                if (block.encrypted?.mapping == null) {
                    result.completed ("The clear-text mapping was removed"); result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary = "The volume is locked, although UDisks reported an error while completing the request.";
                    result.actual_state = "locked"; result.technical_error = error.message;
                    jobs.finish (job, result); return result;
                }
                if (preparation != null && block.encrypted?.mapping == mapping && !preparation.fully_restored ()) {
                    try { yield restore_preparation (preparation, backend_lifetime); }
                    catch (Error restore_error) {
                        result.completed ("Clear-text mapping remains available");
                        result.technical_error = restore_error.message;
                    }
                }
                result.fail ("The encrypted volume could not be locked", error); jobs.finish (job, result); throw error;
            } finally { locks.release (block); }
        }
        [CCode (cname = "LUKS_HEADER_WORKER", cheader_filename = "luks-header-config.h")]
        private extern const string LUKS_HEADER_WORKER;
        [CCode (cname = "F_DUPFD_CLOEXEC", cheader_filename = "fcntl.h")]
        private extern const int DUPFD_CLOEXEC;

        public static bool luks_header_available () {
            return FileUtils.test (LUKS_HEADER_WORKER, FileTest.IS_EXECUTABLE);
        }

        public static bool is_luks_header_candidate (StorageBlock block) {
            return block.available && !block.ignored && block.encrypted != null &&
                block.type_id == "crypto_LUKS" && Uuid.string_is_valid (block.uuid);
        }

        public static bool is_luks_recovery_candidate (StorageBlock block) {
            return block.available && !block.ignored && !block.read_only && !block.system_hint &&
                block.type_id == "" && block.usage == "" && block.encrypted == null &&
                block.filesystem == null && block.table == null && !block.has_swap;
        }

        internal static bool has_luks_method (string xml, string interface_name, string method) throws Error {
            var node = new DBusNodeInfo.for_xml (xml);
            return node.lookup_interface (interface_name)?.lookup_method (method) != null;
        }

        private async void detect_luks_methods (DBusProxy proxy, Cancellable token) throws Error {
            var reply = yield proxy.get_connection ().call (proxy.get_name_owner (), proxy.get_object_path (),
                "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType ("(s)"),
                DBusCallFlags.NONE, 5000, token);
            string xml = reply.get_child_value (0).get_string ();
            // UDisks 2.11's methods take paths and cannot bind a restore to the
            // checked exclusive FD. HeaderBackup in 2.11 also lacks a Polkit
            // check. Use the authorized FD transport even when these exist.
            if (has_luks_method (xml, "org.freedesktop.UDisks2.Encrypted", "HeaderBackup") ||
                has_luks_method (xml, "org.freedesktop.UDisks2.Block", "RestoreEncryptedHeader"))
                debug ("UDisks advertises path-based LUKS header methods; using authorized device descriptors.");
            if (!has_luks_method (xml, "org.freedesktop.UDisks2.Block", "OpenDevice"))
                throw new IOError.NOT_SUPPORTED ("UDisks does not expose authorized device descriptors.");
        }

        private string luks_source_binding (StorageBlock block) {
            var drive = block.physical_drive;
            var partition = block.partition;
            if (drive != null && (drive.wwn != "" || drive.serial != "")) {
                if (partition != null && partition.uuid == "") return "";
                return Checksum.compute_for_string (ChecksumType.SHA256,
                    new Variant ("(ssstt)", drive.wwn, drive.serial, partition?.uuid ?? "",
                        partition?.offset ?? 0, block.size).print (false));
            }
            if (block.loop != null && block.loop.backing_file != "")
                return "loop:" + Checksum.compute_for_string (ChecksumType.SHA256, block.loop.backing_file);
            return "";
        }

        private void validate_luks_target (StorageBlock block, string identity, bool restore, bool advanced,
            bool review_active = false)
            throws Error {
            synchronize ();
            if (!luks_header_available ())
                throw new IOError.NOT_SUPPORTED ("Install Majoris Disks with the libcryptsetup header worker.");
            if (!block.available || snapshot.blocks.lookup (block.path) != block ||
                modification_identity (block) != identity)
                throw new IOError.NOT_FOUND ("The selected device changed after it was confirmed.");
            if (!(advanced ? is_luks_recovery_candidate (block) : is_luks_header_candidate (block)))
                throw new IOError.NOT_SUPPORTED ("The selected volume does not support this header operation.");
            if (restore) {
                if (review_active && !advanced && block.encrypted?.mapping != null)
                    require_luks_restorable_mapping (block);
                else require_luks_restore_idle (block, snapshot.dependencies);
            }
        }

        private StorageBlock require_luks_restorable_mapping (StorageBlock block) throws Error {
            var mapping = block.encrypted?.mapping;
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (mapping == null || !mapping.available || mapping.filesystem == null || mapping.uuid == "" ||
                safety.system_critical || safety.unknown_dependencies || block.read_only ||
                block.table != null || block.partition?.container == true || block.backing_path != "/" ||
                block.raid_path != "/" || block.raid_member_path != "/" || block.logical_volume_path != "/" ||
                block.physical_volume_group_path != "/" || snapshot.dependencies.descendants (block).length != 2 ||
                snapshot.dependencies.descendants (mapping).length != 1 || mapping.swap_active)
                throw new IOError.NOT_SUPPORTED ("Temporary closure requires a non-system LUKS device with a single supported filesystem.");
            var physical_backing = block.partition == null ? block :
                snapshot.blocks.lookup (block.partition.table_path);
            if (physical_backing?.loop != null) {
                string autoclear;
                FileUtils.get_contents ("/sys/dev/block/" + KernelStorageSafety.device_number (physical_backing.number) +
                    "/loop/autoclear", out autoclear);
                if (autoclear.strip () != "0")
                    throw new IOError.NOT_SUPPORTED ("The loop backing device is configured to detach when idle.");
            }
            return mapping;
        }

        private static string dm_property (StorageBlock mapping, string property) throws Error {
            string value;
            FileUtils.get_contents ("/sys/dev/block/" + KernelStorageSafety.device_number (mapping.number) +
                "/dm/" + property, out value);
            return value.strip ();
        }

        private StoragePreparationEntry capture_luks_mapping (StorageBlock block, StorageBlock mapping,
            LuksHeaderReview review) throws Error {
            if (review.confidence != "readable" || review.uuid != block.uuid || review.data_offset >= block.size ||
                review.encryption_sector_size == 0 || block.encryption_configurations.length > 1)
                throw new IOError.NOT_SUPPORTED ("The original LUKS header, geometry or crypttab entry is ambiguous.");
            uint64 payload = block.size - review.data_offset;
            payload -= payload % review.encryption_sector_size;
            var entry = new StoragePreparationEntry (StoragePreparationKind.ENCRYPTED_MAPPING, block.path,
                { mapping.uuid, mapping.type_id, mapping.path }, "close LUKS mapping for header restore");
            entry.device_identity = StoragePreparationJournal.device_identity (block);
            entry.encrypted_backing_uuid = block.uuid;
            entry.mapper_name = dm_property (mapping, "name");
            entry.mapper_uuid = dm_property (mapping, "uuid");
            entry.mapping_size = mapping.size;
            entry.backing_size = block.size;
            entry.mapping_read_only = mapping.read_only;
            var config = block.encryption_configuration;
            entry.crypttab = config?.backend_item;
            string expected_name = config != null && config.name != "" ? config.name : "luks-" + block.uuid;
            if (!MountOptionService.valid_crypttab_name (entry.mapper_name) || entry.mapper_name != expected_name ||
                (config != null && (entry.crypttab == null || MountOptionService.external_crypttab_options (config.options) ||
                    (config.passphrase_path != "" && !MountOptionService.manages_crypttab_keyfile (config.passphrase_path)))) ||
                mapping.size != payload || KernelStorageSafety.block_capacity (mapping) != payload ||
                !entry.mapper_uuid.has_prefix ("CRYPT-" + review.version + "-" + block.uuid.replace ("-", "") + "-"))
                throw new IOError.NOT_SUPPORTED ("UDisks cannot safely reproduce the original mapper name, options or payload geometry.");
            return entry;
        }

        private async void close_luks_for_maintenance (StorageBlock block, StorageBlock mapping,
            StoragePreparationEntry entry, string identity, StorageJob job) throws Error {
            yield KernelStorageSafety.require_idle (mapping, job.cancellable);
            yield KernelStorageSafety.require_sole_dm_dependency (block, mapping, job.cancellable);
            synchronize ();
            if (modification_identity (block) != identity || block.encrypted?.mapping != mapping ||
                dm_property (mapping, "uuid") != entry.mapper_uuid || dm_property (mapping, "name") != entry.mapper_name)
                throw new IOError.NOT_FOUND ("The original LUKS mapping changed before closure.");
            job.cancellable.set_error_if_cancelled ();
            jobs.phase (job, StorageJobState.PREPARING, "Closing the encrypted mapping for header maintenance");
            var encrypted = require_volume (block, "Encrypted");
            jobs.expect_backend (job, "encrypted-lock", block.path);
            entry.action_dispatched = true;
            try {
                yield call_tracked_method (job, encrypted, "Lock", new Variant ("(@a{sv})",
                    new VariantBuilder (VariantType.VARDICT).end ()), backend_lifetime, 60000);
                entry.backend_confirmed = true;
                for (int attempt = 0; attempt < 50; attempt++) {
                    synchronize ();
                    if (snapshot.blocks.lookup (block.path) == block && block.encrypted != null &&
                        block.encrypted.mapping == null && snapshot.blocks.lookup (mapping.path) == null) {
                        entry.prepared = true;
                        entry.expected_state_observed = true;
                        entry.actual_state = "closed by Majoris";
                        return;
                    }
                    yield settle_delay (backend_lifetime);
                }
                throw new IOError.TIMED_OUT ("The original mapping did not disappear after closure.");
            } catch (Error error) {
                synchronize ();
                entry.actual_state = block.encrypted?.mapping == mapping ? "original mapping remains active" :
                    "closure outcome uncertain. Automatic reopening withheld";
                throw new IOError.FAILED (error.message + " " + entry.actual_state);
            }
        }

        private void verify_luks_reopen_target (StorageBlock block, StoragePreparationEntry entry) throws Error {
            synchronize ();
            var configuration = block.encryption_configuration?.backend_item;
            if (snapshot.blocks.lookup (block.path) != block || !is_luks_header_candidate (block) ||
                block.uuid != entry.encrypted_backing_uuid || block.size != entry.backing_size ||
                StoragePreparationJournal.device_identity (block) != entry.device_identity ||
                KernelStorageSafety.block_capacity (block) != entry.backing_size ||
                block.encryption_configurations.length > 1 ||
                (entry.crypttab == null ? configuration != null : configuration == null || !entry.crypttab.equal (configuration)))
                throw new IOError.NOT_FOUND ("The original LUKS device, geometry or crypttab configuration changed.");
            if (block.encrypted.mapping != null || FileUtils.test ("/dev/mapper/" + entry.mapper_name, FileTest.EXISTS))
                throw new IOError.EXISTS ("The encrypted device or its original mapper name is already active.");
        }

        private async void restore_luks_mapping (StorageBlock block, StoragePreparationEntry entry,
            StoragePreparationJournal journal, RestorationCredentialProvider provider, StorageJob job,
            string header_fingerprint) throws Error {
            if (!entry.prepared || !entry.backend_confirmed || entry.restoration_dispatched)
                throw new IOError.BUSY ("Majoris could not establish that it closed the mapping.");
            yield refresh_block_configuration (require_volume (block, "Block"), backend_lifetime);
            verify_luks_reopen_target (block, entry);
            if (header_fingerprint == "")
                throw new IOError.INVALID_DATA ("A verified header fingerprint is required for reopening.");
            var config = block.encryption_configuration;
            RestorationCredential credential;
            if (config != null && MountOptionService.manages_crypttab_keyfile (config.passphrase_path)) {
                yield inspect_crypttab (config.name, config.name, config.device, config.options,
                    config.passphrase_path, config.passphrase_path, entry.managed_key_identity);
                credential = new RestorationCredential ("", "", true);
            } else {
                entry.actual_state = "closed and awaiting an unlocking credential";
                try {
                    credential = yield provider.request (block.preferred);
                } catch (Error error) {
                    entry.actual_state = (error is IOError.CANCELLED) ?
                        "closed after credential cancellation" : "closed with no available credential";
                    throw error;
                }
            }
            try {
                verify_luks_reopen_target (block, entry);
                int fd = yield open_block (block, "r", Posix.O_CLOEXEC, backend_lifetime);
                try {
                    string output, detail;
                    int status = yield run_luks_worker (fd, "inspect", "", luks_source_binding (block),
                        "", block.uuid, false, job, -1, -1, "", "", out output, out detail);
                    var lines = output.split ("\n");
                    if (status != 0 || lines.length != 2 || lines[1] != header_fingerprint)
                        throw new IOError.INVALID_DATA ("The LUKS header changed after it was verified.");
                } finally { Posix.close (fd); }
                yield refresh_block_configuration (require_volume (block, "Block"), backend_lifetime);
                verify_luks_reopen_target (block, entry);
                entry.restoration_dispatched = true;
                entry.actual_state = "unlock requested with an unverified outcome";
                string actual_path;
                StorageBlock? mapping;
                try {
                    mapping = yield unlock_in_job (block, credential, modification_identity (block),
                        entry.mapping_read_only, job, backend_lifetime, 90000, out actual_path);
                } catch (Error error) {
                    synchronize ();
                    string remote = DBusError.get_remote_error (error) ?? "";
                    if (remote.has_prefix ("org.freedesktop.UDisks2.Error.NotAuthorized") ||
                        error is DBusError.ACCESS_DENIED) {
                        entry.actual_state = "unlock authorization denied";
                    } else if (snapshot.blocks.lookup (block.path) == block && block.encrypted?.mapping == null &&
                        remote == "org.freedesktop.UDisks2.Error.Failed") {
                        entry.actual_state = "closed after UDisks reported unlock failure";
                    }
                    throw error;
                }
                if (mapping != null) {
                    for (int attempt = 0; attempt < 50; attempt++) {
                        synchronize ();
                        if (block.encrypted?.mapping == mapping && mapping.filesystem != null && mapping.uuid != "")
                            break;
                        yield settle_delay (backend_lifetime);
                    }
                }
                if (mapping == null || block.encrypted?.mapping != mapping ||
                    mapping.filesystem == null || mapping.uuid != entry.state_at (0) ||
                    mapping.type_id != entry.state_at (1) || mapping.size != entry.mapping_size ||
                    mapping.read_only != entry.mapping_read_only || block.uuid != entry.encrypted_backing_uuid ||
                    snapshot.blocks.lookup (block.path) != block || block.size != entry.backing_size ||
                    StoragePreparationJournal.device_identity (block) != entry.device_identity ||
                    KernelStorageSafety.block_capacity (mapping) != entry.mapping_size ||
                    dm_property (mapping, "name") != entry.mapper_name || dm_property (mapping, "uuid") != entry.mapper_uuid)
                    throw new IOError.INVALID_DATA ("UDisks returned a mapping whose original identity or geometry could not be verified.");
                yield KernelStorageSafety.require_sole_dm_dependency (block, mapping, backend_lifetime);
                entry.rebound_path = mapping.path;
                entry.actual_state = "verified mapping reopened at " + mapping.path;
                entry.restored = true;
                foreach (var dependent in journal.entries ()) {
                    if (dependent.kind != StoragePreparationKind.MOUNT || dependent.object_path != entry.state_at (2))
                        continue;
                    dependent.rebound_path = mapping.path;
                    dependent.device_identity = StoragePreparationJournal.device_identity (mapping);
                    foreach (var record in dependent.mount_topology)
                        record.device = KernelStorageSafety.device_number (mapping.number);
                }
            } finally {
                credential.passphrase = "";
            }
        }

        internal static void require_luks_restore_idle (StorageBlock block, StorageDependencyService graph)
            throws Error {
            // GNOME Disks' ensure-unused flow walks dependent objects before
            // dispatch. Recovery requires an already idle stack because
            // closing mappings would change the confirmed dependency graph.
            var safety = StorageSafetyService.assess (block, graph);
            if (safety.system_critical || block.ignored || block.read_only)
                throw new IOError.PERMISSION_DENIED ("Use offline recovery for protected or system storage.");
            if (safety.mounted || safety.active_dependents || block.swap_active ||
                block.encrypted?.mapping != null)
                throw new IOError.BUSY ("Unmount filesystems, deactivate swap and lock the volume before restoring.");
            if (safety.unknown_dependencies || block.table != null || block.partition?.container == true ||
                block.backing_path != "/" || block.raid_path != "/" || block.raid_member_path != "/" ||
                block.logical_volume_path != "/" || block.physical_volume_group_path != "/" ||
                graph.descendants (block).length != 1)
                throw new IOError.NOT_SUPPORTED ("Recovery requires a plain block device with no dependent storage.");
        }

        private async int run_luks_worker (int fd, string operation, string path, string binding,
            string expected, string uuid, bool advanced, StorageJob job,
            int first, int second, string first_file, string second_file,
            out string output, out string detail) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            int duplicate = Posix.fcntl (fd, DUPFD_CLOEXEC, 6);
            output = "";
            detail = "";
            if (duplicate < 0) {
                detail = "Could not pass the verified device descriptor.";
                return 2;
            }
            launcher.take_fd (duplicate, 3);
            string[] argv = { LUKS_HEADER_WORKER, operation, path, binding, expected, uuid,
                advanced ? "advanced" : "normal" };
            if (operation.has_suffix ("-keyslot")) {
                if (!pass_luks_credential (launcher, first, 4) || !pass_luks_credential (launcher, second, 5)) {
                    launcher.close ();
                    detail = "Could not pass the credential descriptors.";
                    return 2;
                }
                argv += first_file;
                argv += second_file;
            }
            Subprocess? process = null;
            try { process = launcher.spawnv (argv); }
            catch (Error error) { detail = error.message; return 2; }
            finally { launcher.close (); }
            var messages = new DataInputStream (process.get_stdout_pipe ());
            var diagnostics = new DataInputStream (process.get_stderr_pipe ());
            var result = new StringBuilder ();
            bool staged = false;
            bool writing = false;
            bool verifying = false;
            string? line;
            while ((line = yield messages.read_line_async ()) != null) {
                switch (line) {
                    case "phase:verify-backup":
                        jobs.phase (job, StorageJobState.FINALIZING, "Verifying the backup");
                        break;
                    case "phase:staged":
                        staged = true;
                        jobs.phase (job, StorageJobState.RUNNING, "Staged and verified metadata");
                        break;
                    case "phase:write-header":
                        writing = true;
                        verifying = false;
                        jobs.phase (job, StorageJobState.RUNNING, "Restoring header and keyslots");
                        break;
                    case "phase:write-keyslots":
                        writing = true;
                        verifying = false;
                        jobs.phase (job, StorageJobState.RUNNING, "Writing keyslot metadata");
                        break;
                    case "phase:verify-keyslots":
                        verifying = true;
                        jobs.phase (job, StorageJobState.FINALIZING, "Verifying keyslots and credential on disk");
                        break;
                    case "phase:verify-restore":
                        verifying = true;
                        jobs.phase (job, StorageJobState.FINALIZING, "Reading back the restored header");
                        break;
                    default:
                        result.append (line).append_c ('\n');
                        break;
                }
            }
            detail = (yield diagnostics.read_line_async ()) ?? "";
            yield process.wait_async ();
            output = result.str.strip ();
            if (process.get_if_exited ()) return process.get_exit_status ();
            if (writing) {
                detail = verifying ? "The write was synchronized. The worker stopped during readback verification." :
                    "The worker stopped after announcing a device write. The header may be partially modified.";
                return -1;
            }
            if (operation == "restore" || operation.has_suffix ("-keyslot")) {
                detail = staged ? "The worker stopped after staging and before starting a device write." :
                    "The worker stopped before starting a device write.";
                return 2;
            }
            return -1;
        }

        private static bool pass_luks_credential (SubprocessLauncher launcher, int fd, int target) {
            if (fd < 0) return true; // The worker will read a selected keyfile.
            int duplicate = Posix.fcntl (fd, DUPFD_CLOEXEC, 6);
            if (duplicate < 0) return false;
            launcher.take_fd (duplicate, target);
            return true;
        }

        [CCode (cname = "pipe2", cheader_filename = "unistd.h")]
        private static extern int credential_pipe_open ([CCode (array_length = false)] int[] fds, int flags);

        internal static int credential_pipe (string text) throws Error {
            int[] fds = new int[2];
            if (text.length == 0 || text.length > 4096)
                throw new IOError.INVALID_ARGUMENT ("A passphrase must contain 1–4096 bytes.");
            if (credential_pipe_open (fds, Posix.O_CLOEXEC | Posix.O_NONBLOCK) < 0)
                throw new IOError.FAILED ("Could not prepare a private credential pipe.");
            ssize_t written = Posix.write (fds[1], text.data, text.length);
            Posix.close (fds[1]);
            if (written != text.length) {
                Posix.close (fds[0]);
                throw new IOError.FAILED ("Could not transfer the complete credential.");
            }
            return fds[0];
        }

        internal async LuksHeaderReview review_luks_header (StorageBlock block, string identity,
            File? backup_file = null, bool advanced = false, bool list_keyslots = false) throws Error {
            bool restore = backup_file != null;
            string? path = restore ? backup_file.get_path () : "";
            if (path == null) throw new IOError.INVALID_ARGUMENT ("Choose a local backup file.");
            validate_luks_target (block, identity, restore, advanced, true);
            locks.acquire (block, snapshot.dependencies);
            var lifetime = backend_lifetime;
            var job = jobs.begin (list_keyslots ? "List LUKS keyslots" : "Validate LUKS header", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            ulong disconnected = lifetime.cancelled.connect (() => job.cancellable.cancel ());
            int fd = -1;
            try {
                job.cancelable = true;
                jobs.phase (job, StorageJobState.PREPARING, "Checking the device and available backend");
                if (restore && block.encrypted?.mapping == null) yield KernelStorageSafety.require_idle (block, job.cancellable);
                yield detect_luks_methods (require_volume (block, "Block"), job.cancellable);
                jobs.phase (job, StorageJobState.PREPARING, "Authorizing read-only device access");
                fd = yield open_block (block, "r", Posix.O_CLOEXEC, job.cancellable);
                validate_luks_target (block, identity, restore, advanced, true);
                job.cancellable.set_error_if_cancelled ();
                job.cancelable = false;
                jobs.phase (job, StorageJobState.RUNNING, "Reading and validating LUKS metadata");
                string output, detail;
                int status = yield run_luks_worker (fd, list_keyslots ? "list-keyslots" : restore ? "preview" : "inspect", path,
                    luks_source_binding (block), "", block.uuid, advanced, job, -1, -1, "", "", out output, out detail);
                if (status != 0) throw new IOError.INVALID_DATA (detail != "" ? detail : "The header could not be verified.");
                validate_luks_target (block, identity, restore, advanced, true);
                var lines = output.split ("\n");
                var fields = lines[0].split (" ");
                if ((list_keyslots ? lines.length < 3 : lines.length != (restore ? 5 : 2)) || fields.length != 8)
                    throw new IOError.INVALID_DATA ("The header verifier returned an invalid response.");
                outcome.successful = true;
                outcome.summary = "LUKS header validation complete";
                var review = new LuksHeaderReview (identity, lines[1], fields[0], fields[1],
                    restore ? lines[2] : "readable", restore ? uint64.parse (lines[4]) : 0,
                    uint64.parse (fields[2]), restore && lines[3] == "checksummed", advanced, path);
                review.encryption_sector_size = uint64.parse (fields[4]);
                if (list_keyslots) review.keyslots = lines[2:lines.length];
                return review;
            } catch (Error error) {
                outcome.fail ("Header operation not started", error);
                throw error;
            } finally {
                if (fd >= 0) Posix.close (fd);
                lifetime.disconnect (disconnected);
                jobs.finish (job, outcome);
                locks.release (block);
            }
        }

        internal static void record_luks_worker_failure (StorageOperationResult outcome, int status,
            bool restore, string detail) {
            outcome.fail (status == 2 ? "Failed before modification" :
                status == 3 ? (restore ? "Modification attempted but verification failed" :
                    "Backup published with uncertain durability") : "Outcome uncertain");
            outcome.technical_error = detail;
            if (status != 2) {
                outcome.partial = true;
                outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
            }
        }

        internal async StorageOperationResult execute_luks_header (StorageBlock block,
            LuksHeaderReview review, File? destination = null,
            RestorationCredentialProvider? credential_provider = null) throws Error {
            bool restore = destination == null;
            if (restore && review.confidence == "unestablished")
                throw new IOError.NOT_SUPPORTED ("The backup cannot be linked to this unreadable target. Use offline expert recovery.");
            string? path = restore ? review.file_path : destination.get_path ();
            if (path == null || path == "" || (restore == (review.file_path == "")))
                throw new IOError.INVALID_ARGUMENT ("Choose a local header backup file.");
            bool close_mapping = restore && block.encrypted?.mapping != null && credential_provider != null;
            validate_luks_target (block, review.identity, restore, review.advanced, close_mapping);
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (restore ? "Restore LUKS header" : "Back up LUKS header", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            ulong disconnected = lifetime.cancelled.connect (() => job.cancellable.cancel ());
            int fd = -1;
            bool dispatched = false;
            bool header_verified = false;
            string header_fingerprint = "";
            StoragePreparationJournal? journal = null;
            StoragePreparationEntry? mapping_entry = null;
            string locked_identity = review.identity;
            try {
                job.cancelable = true;
                jobs.phase (job, StorageJobState.PREPARING, "Checking the selected volume and its dependencies");
                if (close_mapping) {
                    var ticket_fields = review.ticket.split (":", 4);
                    if (ticket_fields.length != 4)
                        throw new IOError.INVALID_DATA ("The original header fingerprint is unavailable.");
                    header_fingerprint = string.joinv (":", ticket_fields[0:3]);
                    yield refresh_block_configuration (require_volume (block, "Block"), job.cancellable);
                    var mapping = require_luks_restorable_mapping (block);
                    int preview_fd = yield open_block (block, "r", Posix.O_CLOEXEC, job.cancellable);
                    try {
                        string preview, detail;
                        int verified = yield run_luks_worker (preview_fd, "preview", path, luks_source_binding (block),
                            "", block.uuid, false, job, -1, -1, "", "", out preview, out detail);
                        var lines = preview.split ("\n");
                        if (verified != 0 || lines.length != 5 || lines[1] != review.ticket)
                            throw new IOError.INVALID_DATA ("The LUKS header or backup changed before preparation.");
                    } finally { Posix.close (preview_fd); }
                    validate_luks_target (block, review.identity, true, false, true);
                    mapping_entry = capture_luks_mapping (block, mapping, review);
                    var config = block.encryption_configuration;
                    if (config != null && MountOptionService.manages_crypttab_keyfile (config.passphrase_path))
                        mapping_entry.managed_key_identity = yield inspect_crypttab (config.name, config.name,
                            config.device, config.options, config.passphrase_path, config.passphrase_path);
                    jobs.phase (job, StorageJobState.PREPARING, "Capturing and preparing dependent mounts");
                    journal = yield prepare_for_modification (mapping, job.cancellable, job);
                    journal.add (mapping_entry);
                    yield close_luks_for_maintenance (block, mapping, mapping_entry, review.identity, job);
                    locked_identity = modification_identity (block);
                }
                if (restore) yield KernelStorageSafety.require_idle (block, job.cancellable);
                jobs.phase (job, StorageJobState.PREPARING, "Authorizing device access");
                fd = yield open_block (block, restore ? "rw" : "r",
                    Posix.O_CLOEXEC | (restore ? Posix.O_EXCL : 0), job.cancellable);
                if (restore) yield KernelStorageSafety.require_idle (block, job.cancellable);
                validate_luks_target (block, locked_identity, restore, review.advanced);
                job.cancellable.set_error_if_cancelled ();
                job.cancelable = false;
                jobs.phase (job, StorageJobState.RUNNING, restore ?
                    "Validating, restoring and reading back the header" : "Creating and verifying the backup");
                dispatched = true;
                string output, detail;
                int status = yield run_luks_worker (fd, restore ? "restore" : "backup", path,
                    luks_source_binding (block), review.ticket, block.uuid, review.advanced, job, -1, -1, "", "", out output, out detail);
                Posix.close (fd);
                fd = -1;
                header_verified = status == 0 || status == 2;
                if (restore && status == 0) header_fingerprint = output;
                if (status != 0) {
                    record_luks_worker_failure (outcome, status, restore, detail);
                } else {
                    outcome.successful = true;
                    outcome.summary = restore ? "Header restored and verified. Use credentials from the restored header." :
                        "Verified LUKS header saved to " + path;
                    if (!restore) {
                        outcome.summary += "\nCompanion manifest saved to " + path + ".majoris.json";
                        if (output == "header-only")
                            outcome.summary += "\nA stable source identity could not be recorded.";
                    }
                }
                if (restore && status != 2) {
                    jobs.phase (job, StorageJobState.FINALIZING, "Refreshing the UDisks device snapshot");
                    try {
                        var proxy = require_volume (block, "Block");
                        yield proxy.call ("Rescan", new Variant ("(@a{sv})", new VariantBuilder (VariantType.VARDICT).end ()),
                            DBusCallFlags.NONE, 10000, lifetime);
                        for (int attempt = 0; attempt < 30; attempt++) {
                            synchronize ();
                            if (snapshot.blocks.lookup (block.path) == block && is_luks_header_candidate (block) &&
                                block.uuid.down () == review.uuid.down ()) break;
                            Timeout.add (100, () => { execute_luks_header.callback (); return Source.REMOVE; });
                            yield;
                        }
                        if (outcome.successful && (snapshot.blocks.lookup (block.path) != block ||
                            !is_luks_header_candidate (block) || block.uuid.down () != review.uuid.down ()))
                            throw new IOError.FAILED ("UDisks has not published the verified header.");
                    } catch (Error error) {
                        if (outcome.successful) {
                            outcome.fail ("Header verified on disk, but the device snapshot could not be reconciled", error);
                            outcome.partial = true;
                            outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                        }
                    }
                }
            } catch (Error error) {
                outcome.fail (dispatched ? "Outcome uncertain" : "Header operation not started", error);
                if (dispatched) {
                    outcome.partial = true;
                    outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                }
            } finally {
                if (fd >= 0) Posix.close (fd);
                if (journal != null && mapping_entry != null) {
                    outcome.restoration_attempted = true;
                    try {
                        if (mapping_entry.prepared) {
                            if (dispatched && !header_verified)
                                throw new IOError.FAILED ("The mapping remains closed because the header write could not be verified.");
                            yield restore_luks_mapping (block, mapping_entry, journal, credential_provider, job,
                                header_fingerprint);
                            outcome.completed ("Verified encrypted mapping reopened");
                            outcome.actual_state = mapping_entry.actual_state;
                            outcome.resulting_path = mapping_entry.rebound_path;
                        }
                        jobs.phase (job, StorageJobState.FINALIZING, "Restoring and verifying original mount locations");
                        yield restore_preparation (journal, lifetime);
                        outcome.restoration_succeeded = true;
                        foreach (var entry in journal.entries ())
                            if (entry.kind == StoragePreparationKind.MOUNT && entry.restored)
                                outcome.completed ("Verified mounts restored at " + string.joinv (", ", entry.observed_mount_points));
                    } catch (Error error) {
                        if (outcome.successful)
                            outcome.summary = "Header restored and verified. Storage restoration needs attention.";
                        outcome.successful = false;
                        outcome.partial = true;
                        outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                        outcome.technical_error += (outcome.technical_error == "" ? "" : "\n") +
                            error.message + "\n" + journal.recovery_details ();
                    }
                }
                lifetime.disconnect (disconnected);
                jobs.finish (job, outcome);
                locks.release (block);
            }
            return outcome;
        }


        internal async StorageOperationResult manage_luks_keyslots (StorageBlock block,
            LuksHeaderReview review, string operation, int slot, int retained,
            int first, int second, string first_file, string second_file) throws Error {
            bool write = operation != "identify-keyslot";
            if (write && !(operation == "add-keyslot" || operation == "change-keyslot" || operation == "remove-keyslot"))
                throw new IOError.INVALID_ARGUMENT ("Unsupported LUKS credential operation.");
            if (review.keyslots.length == 0)
                throw new IOError.INVALID_ARGUMENT ("Review the keyslots before making changes.");
            validate_luks_target (block, review.identity, write, false);
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (write ? "Manage LUKS credentials" : "Verify LUKS credential", block, snapshot.dependencies);
            var outcome = new StorageOperationResult ();
            var lifetime = backend_lifetime;
            ulong disconnected = lifetime.cancelled.connect (() => job.cancellable.cancel ());
            int fd = -1;
            bool dispatched = false;
            try {
                job.cancelable = true;
                jobs.phase (job, StorageJobState.PREPARING, "Checking storage dependencies and authorizing device access");
                if (write) yield KernelStorageSafety.require_idle (block, job.cancellable);
                fd = yield open_block (block, write ? "rw" : "r",
                    Posix.O_CLOEXEC | (write ? Posix.O_EXCL : 0), job.cancellable);
                if (write) yield KernelStorageSafety.require_idle (block, job.cancellable);
                validate_luks_target (block, review.identity, write, false);
                job.cancellable.set_error_if_cancelled ();
                job.cancelable = false;
                jobs.phase (job, StorageJobState.RUNNING, write ? "Checking credentials and staging keyslots" : "Checking the credential");
                dispatched = true;
                string output, detail;
                int status = yield run_luks_worker (fd, operation, "%d:%d".printf (slot, retained), "",
                    review.ticket, review.uuid, false, job, first, second, first_file, second_file,
                    out output, out detail);
                if (status == 0) {
                    outcome.successful = true;
                    outcome.summary = output;
                } else if (write) {
                    record_luks_worker_failure (outcome, status, true, detail);
                } else {
                    outcome.fail ("Credential verification failed");
                    outcome.technical_error = detail;
                }
            } catch (Error error) {
                outcome.fail (dispatched && write ? "Keyslot outcome uncertain" : "Keyslot operation not started", error);
                if (dispatched && write) {
                    outcome.partial = true;
                    outcome.status = StorageOperationStatus.NEEDS_ATTENTION;
                }
            } finally {
                if (fd >= 0) Posix.close (fd);
                lifetime.disconnect (disconnected);
                jobs.finish (job, outcome);
                locks.release (block);
            }
            return outcome;
        }

        public async void change_passphrase (StorageBlock block, string current_passphrase,
            string new_passphrase, string confirmed_identity) throws Error {
            if (block.encrypted == null || block.read_only || block.system_hint)
                throw new IOError.NOT_SUPPORTED ("The encryption passphrase cannot be changed for this volume.");
            if (current_passphrase == "" || new_passphrase.length < 8 || current_passphrase == new_passphrase)
                throw new IOError.INVALID_ARGUMENT ("Provide the current passphrase and a distinct new passphrase of at least eight characters.");
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The encrypted volume changed before its passphrase could be updated.");
            var safety = StorageSafetyService.assess (block, snapshot.dependencies);
            if (safety.system_critical || safety.unknown_dependencies)
                throw new IOError.PERMISSION_DENIED ("The passphrase of system-critical or unresolved storage cannot be changed here.");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Change encryption passphrase", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            try {
                jobs.phase (job, StorageJobState.RUNNING, "Authorizing passphrase change");
                if (modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed immediately before the passphrase request.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                yield require_volume (block, "Encrypted").call ("ChangePassphrase",
                    new Variant ("(ss@a{sv})", current_passphrase, new_passphrase, options.end ()),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                synchronize ();
                if (snapshot.blocks.lookup (block.path) != block || modification_identity (block) != confirmed_identity)
                    throw new IOError.FAILED ("The passphrase request completed, but the encrypted device identity changed.");
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Encryption passphrase changed"; result.actual_state = "encrypted volume remains available";
                jobs.finish (job, result);
            } catch (Error error) {
                result.fail ("The encryption passphrase was not changed", error); jobs.finish (job, result); throw error;
            } finally { locks.release (block); }
        }
        private static StorageEncryptionConfiguration? encryption_configuration_from (Variant configuration,
            string desired_name = "") {
            for (size_t i = 0; i < configuration.n_children (); i++) {
                var entry = configuration.get_child_value (i);
                if (entry.get_child_value (0).get_string () != "crypttab") continue;
                var details = entry.get_child_value (1);
                var result = new StorageEncryptionConfiguration ();
                result.device = details.lookup_value ("device", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                result.name = details.lookup_value ("name", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                result.options = details.lookup_value ("options", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                result.passphrase_path = details.lookup_value ("passphrase-path", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                result.backend_item = entry;
                if (desired_name == "" || result.name == desired_name) return result;
            }
            return null;
        }

        private async StorageEncryptionConfiguration? secret_encryption_configuration (StorageBlock block,
            string desired_name = "") throws Error {
            if (block.encrypted == null || block.uuid == "")
                throw new IOError.NOT_SUPPORTED ("Persistent encryption configuration is unavailable.");
            var selected = desired_name == "" ? block.encryption_configuration :
                find_encryption_configuration (block, desired_name);
            if (selected == null || selected.passphrase_path == "" || selected.passphrase_path.has_prefix ("/dev/"))
                return selected;
            // GetSecretConfiguration reads every key referenced by this block.
            foreach (var sibling in block.encryption_configurations) {
                if (sibling.passphrase_path == "" || sibling.passphrase_path.has_prefix ("/dev/")) continue;
                if (!MountOptionService.manages_crypttab_keyfile (sibling.passphrase_path))
                    throw new IOError.NOT_SUPPORTED ("Another entry for this device has an external key source.");
                yield inspect_crypttab (sibling.name, sibling.name, sibling.device,
                    sibling.options, sibling.passphrase_path, sibling.passphrase_path);
            }
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            var reply = yield require_volume (block, "Block").call ("GetSecretConfiguration",
                new Variant.tuple ({ options.end () }), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                int.MAX, backend_lifetime);
            return encryption_configuration_from (reply.get_child_value (0), desired_name);
        }

        private static StorageEncryptionConfiguration? find_encryption_configuration (StorageBlock block, string name) {
            foreach (var item in block.encryption_configurations) if (item.name == name) return item;
            return null;
        }

        private bool crypttab_write_pending;

        private async void refresh_block_configuration (DBusProxy proxy, Cancellable token) throws Error {
            // Read from the daemon even if the proxy missed PropertiesChanged.
            var reply = yield proxy.get_connection ().call (proxy.get_name_owner (), proxy.get_object_path (),
                "org.freedesktop.DBus.Properties", "Get", new Variant ("(ss)", PREFIX + "Block", "Configuration"),
                new VariantType ("(v)"), DBusCallFlags.NONE, 5000, token);
            var configuration = reply.get_child_value (0).get_variant ();
            if (!configuration.is_of_type (new VariantType ("a(sa{sv})")))
                throw new IOError.INVALID_DATA ("UDisks returned an invalid configuration record.");
            proxy.set_cached_property ("Configuration", configuration);
            synchronize ();
        }

        [CCode (cname = "MAJORIS_CRYPTTAB_INSPECTOR", cheader_filename = "crypttab-inspector-config.h")]
        private extern const string CRYPTTAB_INSPECTOR;

        private Subprocess start_crypttab_inspector (string[] args) throws Error {
            string[] argv = { CRYPTTAB_INSPECTOR };
            if (Posix.geteuid () != 0) {
                if (!FileUtils.test ("/usr/bin/pkexec", FileTest.IS_EXECUTABLE))
                    throw new IOError.NOT_SUPPORTED ("Install pkexec to authorize inspection of protected storage configuration.");
                argv = { "/usr/bin/pkexec", "--disable-internal-agent", CRYPTTAB_INSPECTOR };
            }
            if (!FileUtils.test (CRYPTTAB_INSPECTOR, FileTest.IS_EXECUTABLE))
                throw new IOError.NOT_SUPPORTED ("The protected crypttab inspector is unavailable.");
            foreach (string arg in args) argv += arg;
            return new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
        }

        private async string inspect_crypttab (string name, string old_name, string device,
            string options, string old_path, string new_path, string? expected = null) throws Error {
            var process = start_crypttab_inspector ({ name, old_name, device, options, old_path, new_path });
            string? output;
            yield process.communicate_utf8_async (null, backend_lifetime, out output, null);
            if (!process.get_if_exited ())
                throw new IOError.FAILED ("Protected configuration inspection did not complete.");
            switch (process.get_exit_status ()) {
            case 0: break;
            case 126: case 127:
                throw new IOError.PERMISSION_DENIED ("Authorization to inspect protected configuration was denied or cancelled.");
            case 11:
                throw new IOError.INVALID_DATA ("The crypttab or managed keyfile could not be verified as safe.");
            case 12:
                throw new IOError.EXISTS ("A conflicting mapping name exists or the original record changed.");
            case 13:
                throw new IOError.BUSY ("Another crypttab entry references this keyfile.");
            case 14:
                throw new IOError.NOT_FOUND ("The selected crypttab record or keyfile changed.");
            case 15:
                throw new IOError.NOT_SUPPORTED ("This mapping uses an implicit systemd keyfile.");
            case 16:
                throw new IOError.NOT_SUPPORTED ("The selected keyfile is externally managed.");
            default:
                throw new IOError.FAILED ("Protected crypttab or keyfile metadata could not be inspected.");
            }
            string identity = output?.strip () ?? "";
            if (!Regex.match_simple ("^[0-9]+:[0-9]+:-?[0-9]+:[0-9]+$", identity))
                throw new IOError.INVALID_DATA ("The protected configuration inspector returned an invalid result.");
            if (expected != null && identity != expected)
                throw new IOError.NOT_FOUND ("The managed keyfile changed after inspection.");
            return identity;
        }

        private async string crypttab_credential_ticket (StorageBlock block, int fd, StorageJob job) throws Error {
            string output, detail;
            int status = yield run_luks_worker (fd, "inspect", "", "", "", block.uuid, false,
                job, -1, -1, "", "", out output, out detail);
            var lines = output.split ("\n");
            if (status != 0 || lines.length != 2)
                throw new IOError.INVALID_DATA ("The selected LUKS header could not be verified.");
            return lines[1];
        }

        private async void verify_crypttab_credential (StorageBlock block, int fd, string ticket,
            Variant credential, StorageJob job) throws Error {
            int pipe = credential_pipe (credential.get_bytestring ());
            try {
                string output, detail;
                int status = yield run_luks_worker (fd, "identify-keyslot", "-1:-1", "", ticket,
                    block.uuid, false, job, pipe, -1, "", "", out output, out detail);
                if (status != 0)
                    throw new IOError.INVALID_DATA ("The configured credential did not unlock a usable LUKS keyslot.");
            } finally { Posix.close (pipe); }
        }

        private async string enroll_crypttab_credential (StorageBlock block, int fd, string ticket,
            Variant current, Variant replacement, StorageJob job) throws Error {
            int first = credential_pipe (current.get_bytestring ());
            int second = -1;
            try {
                second = credential_pipe (replacement.get_bytestring ());
                string output, detail;
                int status = yield run_luks_worker (fd, "add-keyslot", "-1:-1", "", ticket,
                    block.uuid, false, job, first, second, "", "", out output, out detail);
                if (status != 0)
                    throw new IOError.FAILED ("The new keyslot could not be verified. Refresh keyslots before retrying. " + detail);
                return output;
            } finally {
                Posix.close (first);
                if (second >= 0) Posix.close (second);
            }
        }

        private static void verify_crypttab_mapping_name (StorageBlock block, string name) throws Error {
            Posix.Stat mapper;
            string path = "/dev/mapper/" + name;
            if (Posix.stat (path, out mapper) == 0) {
                if (!Posix.S_ISBLK (mapper.st_mode) || block.encrypted?.mapping == null ||
                    (uint64) mapper.st_rdev != block.encrypted.mapping.number)
                    throw new IOError.EXISTS ("An unrelated active mapping already uses this name.");
            } else if (Posix.errno != Posix.ENOENT || Posix.lstat (path, out mapper) == 0 ||
                Posix.errno != Posix.ENOENT) {
                throw new IOError.FAILED ("The proposed active mapping name could not be verified.");
            }
        }

        public async StorageOperationResult configure_encryption (StorageBlock block, bool enabled, bool startup,
            string mapping_name, string crypt_options, string new_passphrase, Variant? original_item,
            string confirmed_identity, string confirmed_uuid) throws Error {
            if (block.encrypted == null || block.uuid == "" || block.read_only || block.system_hint)
                throw new IOError.NOT_SUPPORTED ("Persistent encryption configuration is unavailable for this volume.");
            if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                throw new IOError.NOT_FOUND ("The encrypted volume changed after the dialog was opened.");
            if (crypttab_write_pending)
                throw new IOError.BUSY ("Another encryption configuration change is in progress.");
            string name = mapping_name;
            if (enabled && !MountOptionService.valid_crypttab_name (name))
                throw new IOError.INVALID_ARGUMENT ("The mapping name is invalid.");
            string device = "UUID=" + block.uuid;
            string old_name = ""; string old_path = ""; string old_options = "";
            if (original_item != null) {
                if (!original_item.is_of_type (new VariantType ("(sa{sv})")) ||
                    original_item.get_child_value (0).get_string () != "crypttab")
                    throw new IOError.INVALID_ARGUMENT ("The selected configuration record is not a crypttab entry.");
                var old_details = original_item.get_child_value (1);
                device = old_details.lookup_value ("device", VariantType.BYTESTRING)?.get_bytestring () ?? device;
                old_name = old_details.lookup_value ("name", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                old_path = old_details.lookup_value ("passphrase-path", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                old_options = old_details.lookup_value ("options", VariantType.BYTESTRING)?.get_bytestring () ?? "";
            }
            if (!enabled && original_item == null)
                throw new IOError.INVALID_ARGUMENT ("Select an existing configuration to remove.");
            if (MountOptionService.external_crypttab_options (old_options))
                throw new IOError.NOT_SUPPORTED ("This entry uses externally managed unlocking options.");
            string normalized = enabled ?
                MountOptionService.normalize_encryption (crypt_options, startup, old_options) : "";
            // UDisks unlinks the old keyfile when removing or replacing a crypttab entry.
            // Only let this editor manage regular keyfiles in UDisks' dedicated directory.
            if (old_path != "" && !MountOptionService.manages_crypttab_keyfile (old_path))
                throw new IOError.NOT_SUPPORTED ("The editor cannot change an externally managed key reference.");
            string secret_path = "";
            if (enabled) {
                if (old_path != "") secret_path = old_path;
                else if (new_passphrase != "") secret_path = "/etc/luks-keys/" + name;
            }
            var call_options = new VariantBuilder (new VariantType ("a{sv}"));
            var proxy = require_volume (block, "Block");
            locks.acquire (block, snapshot.dependencies);
            crypttab_write_pending = true;
            var job = jobs.begin (enabled ? "Configure automatic unlocking" : "Remove automatic unlocking", block,
                snapshot.dependencies);
            var result = new StorageOperationResult ();
            bool dispatched = false;
            bool credential_dispatched = false;
            int credential_device = -1;
            try {
                jobs.phase (job, StorageJobState.PREPARING, "Validating encryption configuration");
                yield refresh_block_configuration (proxy, backend_lifetime);
                if (snapshot.blocks.lookup (block.path) != block ||
                    modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed immediately before the configuration write.");
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies)
                    throw new IOError.PERMISSION_DENIED ("The encryption configuration of system-critical or unresolved storage cannot be changed here.");
                foreach (var consumer in snapshot.dependencies.descendants (block)) {
                    var volume = consumer as StorageBlock;
                    if (consumer is StorageRaid || (consumer as StorageLogicalVolume)?.active == true ||
                        volume?.swap_active == true)
                        throw new IOError.BUSY ("An active swap, RAID or logical-volume dependency prevents this change.");
                }
                if (original_item != null) {
                    var current = find_encryption_configuration (block, old_name);
                    if (current == null || current.backend_item == null || !current.backend_item.equal (original_item))
                        throw new IOError.NOT_FOUND ("The selected crypttab entry changed while the dialog was open.");
                }
                if (enabled && original_item != null && name == old_name && normalized == old_options &&
                    new_passphrase == "") {
                    result.successful = true;
                    result.status = StorageOperationStatus.SUCCEEDED;
                    result.summary = "Encryption configuration already matches";
                    return result;
                }
                int key_references = 0;
                foreach (var candidate in snapshot.blocks.get_values ()) {
                    foreach (var saved in candidate.encryption_configurations) {
                        bool selected = candidate == block && original_item != null &&
                            saved.backend_item != null && saved.backend_item.equal (original_item);
                        if (enabled && !selected && saved.name == name)
                            throw new IOError.EXISTS ("Another crypttab entry already uses this mapping name.");
                        if (old_path != "" && !old_path.has_prefix ("/dev/") && saved.passphrase_path != "" &&
                            Filename.canonicalize (saved.passphrase_path) == old_path)
                            key_references++;
                    }
                }
                if (key_references > 1)
                    throw new IOError.BUSY ("UDisks reports that multiple crypttab entries share this keyfile. Changing the entry could delete the shared keyfile.");
                string key_identity = yield inspect_crypttab (enabled ? name : "", old_name, device,
                    old_options, old_path, secret_path);
                if (enabled) verify_crypttab_mapping_name (block, name);
                bool supplied_credential = new_passphrase != "";
                Variant secret = new Variant.bytestring (new_passphrase);
                new_passphrase = "";
                Variant? old_credential = null;
                if (enabled && old_path != "") {
                    var protected_entry = yield secret_encryption_configuration (block, old_name);
                    var protected_details = protected_entry?.backend_item?.get_child_value (1);
                    var contents = protected_details?.lookup_value ("passphrase-contents", VariantType.BYTESTRING);
                    if (protected_entry == null || protected_entry.device != device ||
                        protected_entry.passphrase_path != old_path || protected_entry.options != old_options ||
                        contents == null || contents.get_size () <= 1 ||
                        contents.get_bytestring ().length != contents.get_size () - 1)
                        throw new IOError.NOT_SUPPORTED ("The backend did not return a supported existing keyfile.");
                    old_credential = contents;
                    if (!supplied_credential) secret = contents;
                    yield refresh_block_configuration (proxy, backend_lifetime);
                    if (snapshot.blocks.lookup (block.path) != block || block.uuid != confirmed_uuid ||
                        modification_identity (block) != confirmed_identity ||
                        find_encryption_configuration (block, old_name)?.backend_item?.equal (original_item) != true)
                        throw new IOError.NOT_FOUND ("The encrypted volume or entry changed during authorization.");
                    yield inspect_crypttab (name, old_name, device, old_options, old_path, secret_path, key_identity);
                }
                bool rotate = old_credential != null && supplied_credential;
                if (enabled && secret_path != "") {
                    if (!luks_header_available ())
                        throw new IOError.NOT_SUPPORTED ("The LUKS credential verifier is required for stored keyfile changes.");
                    if (rotate && old_credential.equal (secret))
                        throw new IOError.INVALID_ARGUMENT ("Choose a different replacement credential.");
                    if (rotate) {
                        require_luks_restore_idle (block, snapshot.dependencies);
                        yield KernelStorageSafety.require_idle (block, backend_lifetime);
                    }
                    jobs.phase (job, StorageJobState.RUNNING, "Verifying the LUKS unlocking credential");
                    credential_device = yield open_block (block, rotate ? "rw" : "r",
                        Posix.O_CLOEXEC | (rotate ? Posix.O_EXCL : 0), backend_lifetime);
                    string ticket = yield crypttab_credential_ticket (block, credential_device, job);
                    yield verify_crypttab_credential (block, credential_device, ticket, old_credential ?? secret, job);
                    if (rotate) {
                        require_luks_restore_idle (block, snapshot.dependencies);
                        yield KernelStorageSafety.require_idle (block, backend_lifetime);
                        yield inspect_crypttab (name, old_name, device, old_options, old_path, secret_path, key_identity);
                        if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                            throw new IOError.NOT_FOUND ("The encrypted device changed before adding the replacement credential.");
                        credential_dispatched = true;
                        string enrolled = yield enroll_crypttab_credential (block, credential_device, ticket,
                            old_credential, secret, job);
                        result.completed (enrolled);
                        ticket = yield crypttab_credential_ticket (block, credential_device, job);
                        yield verify_crypttab_credential (block, credential_device, ticket, secret, job);
                    }
                    yield refresh_block_configuration (proxy, backend_lifetime);
                    if (snapshot.blocks.lookup (block.path) != block || block.uuid != confirmed_uuid ||
                        modification_identity (block) != confirmed_identity)
                        throw new IOError.NOT_FOUND ("The encrypted volume changed before the crypttab write.");
                }
                // Adapted from GNOME Disks gdu_encryption_options_dialog_get_new_crypttab.
                // Copyright (C) 2008-2013 Red Hat, Inc.; Copyright (C) 2023 Purism SPC.
                // SPDX-License-Identifier: GPL-2.0-or-later
                var details = new VariantBuilder (new VariantType ("a{sv}"));
                details.add ("{sv}", "name", new Variant.bytestring (name));
                details.add ("{sv}", "device", new Variant.bytestring (device));
                details.add ("{sv}", "options", new Variant.bytestring (normalized));
                if (old_path != "")
                    details.add ("{sv}", "passphrase-path", new Variant.bytestring (secret_path));
                details.add ("{sv}", "passphrase-contents", secret);
                var item = new Variant.tuple ({ new Variant.string ("crypttab"), details.end () });
                jobs.phase (job, StorageJobState.RUNNING, "Authorizing and applying the crypttab change");
                yield inspect_crypttab (enabled ? name : "", old_name, device, old_options,
                    old_path, secret_path, key_identity);
                if (snapshot.blocks.lookup (block.path) != block || block.uuid != confirmed_uuid ||
                    modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed before the crypttab write.");
                if (enabled) verify_crypttab_mapping_name (block, name);
                dispatched = true;
                if (!enabled && original_item != null)
                    yield proxy.call ("RemoveConfigurationItem", new Variant.tuple ({ original_item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled && original_item != null)
                    yield proxy.call ("UpdateConfigurationItem", new Variant.tuple ({ original_item, item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled)
                    yield proxy.call ("AddConfigurationItem", new Variant.tuple ({ item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                result.completed ("UDisks accepted the crypttab change");
                jobs.phase (job, StorageJobState.RUNNING, "Verifying the resulting crypttab entry");
                bool verified = false;
                for (int attempt = 0; attempt < 50 && !verified; attempt++) {
                    yield refresh_block_configuration (proxy, backend_lifetime);
                    if (snapshot.blocks.lookup (block.path) != block || block.uuid != confirmed_uuid ||
                        modification_identity (block) != confirmed_identity)
                        throw new IOError.NOT_FOUND ("The encrypted device changed after the configuration request.");
                    uint requested_records = 0;
                    uint replaced_records = 0;
                    foreach (var saved in block.encryption_configurations) {
                        if (original_item != null && saved.backend_item?.equal (original_item) == true)
                            replaced_records++;
                        if (enabled && saved.device == device && saved.name == name &&
                            saved.options == normalized && saved.passphrase_path == secret_path) requested_records++;
                    }
                    bool same_record = name == old_name && normalized == old_options && secret_path == old_path;
                    verified = enabled ? requested_records == 1 && replaced_records == (same_record ? 1 : 0) :
                        replaced_records == 0;
                    if (!verified) yield settle_delay (backend_lifetime);
                }
                if (!verified) throw new IOError.FAILED ("UDisks did not publish the requested crypttab configuration.");
                if (enabled)
                    yield inspect_crypttab (name, name, device, normalized, secret_path, secret_path);
                if (secret_path != "") {
                    var saved = yield secret_encryption_configuration (block, name);
                    var written = saved?.backend_item?.get_child_value (1)?.lookup_value ("passphrase-contents", VariantType.BYTESTRING);
                    if (saved == null || saved.device != device || saved.options != normalized ||
                        saved.passphrase_path != secret_path || written == null || !written.equal (secret))
                        throw new IOError.FAILED ("The stored unlocking credential did not match the verified credential.");
                    result.completed ("Stored credential verified against a working LUKS keyslot");
                }
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = rotate ? "Automatic unlocking credential rotated. The previous keyslot remains active. Boot-time unlocking was not tested." :
                    "Encryption configuration updated";
                return result;
            } catch (Error error) {
                string? remote_error = DBusError.get_remote_error (error);
                bool denied = error is DBusError.ACCESS_DENIED ||
                    (remote_error != null && remote_error.has_prefix ("org.freedesktop.UDisks2.Error.NotAuthorized"));
                bool uncertain = (dispatched && !denied) || credential_dispatched;
                result.fail (uncertain ? "The encryption configuration could not be verified" :
                    "Encryption configuration change was not applied", error);
                if (uncertain) {
                    result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    string outcome = result.completed_steps.length == 0 ? "" :
                        string.joinv (" ", result.completed_steps) + " ";
                    if (credential_dispatched) outcome += "The previous keyslot was retained. Review keyslots and crypttab before retrying. ";
                    else outcome += "The configuration may have changed. Review the entry before retrying. ";
                    result.technical_error = outcome + error.message;
                    return result;
                }
                throw error;
            } finally {
                jobs.finish (job, result);
                if (credential_device >= 0) Posix.close (credential_device);
                crypttab_write_pending = false;
                locks.release (block);
            }
        }
        public async void volume_action (StorageBlock block, string method) throws Error {
            if (!available ()) throw new IOError.NOT_CONNECTED ("UDisks is unavailable.");
            if (snapshot.blocks.lookup (block.path) != block || !block.available)
                throw new IOError.NOT_FOUND ("The volume is no longer available.");
            var capabilities = new StorageCapabilities (block);
            string iface;
            switch (method) {
                case "Mount":
                    if (!capabilities.mount) throw new IOError.NOT_SUPPORTED ("The volume cannot be mounted.");
                    iface = "Filesystem";
                    break;
                case "Unmount":
                    if (!capabilities.unmount) throw new IOError.BUSY ("The volume is in use or cannot be unmounted.");
                    iface = "Filesystem";
                    break;
                case "Start":
                    if (!capabilities.activate_swap) throw new IOError.NOT_SUPPORTED ("Swap cannot be activated.");
                    iface = "Swapspace";
                    break;
                case "Stop":
                    if (!capabilities.deactivate_swap) throw new IOError.NOT_SUPPORTED ("Swap is not active.");
                    iface = "Swapspace";
                    break;
                default:
                    throw new IOError.NOT_SUPPORTED ("Unsupported storage operation.");
            }
            var proxy = require_volume (block, iface);
            locks.acquire (block, snapshot.dependencies);
            string job_name = method == "Start" ? "Activate swap" : method == "Stop" ? "Deactivate swap" : method + " filesystem";
            var job = jobs.begin (job_name, block, snapshot.dependencies);
            var operation_result = new StorageOperationResult ();
            try {
                jobs.phase (job, StorageJobState.RUNNING, job_name);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                yield proxy.call (method, new Variant.tuple ({ options.end () }),
                                  DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, backend_lifetime);
                synchronize ();
                minimum_sizes.invalidate (block.path);
                operation_result.completed (job_name); operation_result.successful = true;
                operation_result.summary = job_name + " completed"; jobs.finish (job, operation_result);
            } catch (Error error) {
                operation_result.fail (job_name + " failed", error); jobs.finish (job, operation_result);
                throw error;
            } finally {
                locks.release (block);
            }
            if (snapshot.blocks.lookup (block.path) != block)
                throw new IOError.NOT_FOUND ("The volume was removed during the operation.");
        }
    }
}
