namespace MajorisDisks {
    internal enum SelftestOperationState { REQUESTED, STARTING, START_CONFIRMED, RUNNING, STOPPING, UNCERTAIN }
    internal class SelftestOperation : Object {
        public StorageJob job;
        public string type;
        public string baseline_status;
        public uint64 baseline_updated;
        public SelftestOperationState state;
        public SelftestOperation (StorageJob job, string type, string baseline_status, uint64 baseline_updated = 0) {
            this.job = job; this.type = type; this.baseline_status = baseline_status;
            this.baseline_updated = baseline_updated;
            state = SelftestOperationState.REQUESTED;
        }
        public bool terminal_state_is_new (string status, uint64 updated) {
            return StorageSelftestReconciliation.terminal_state_is_new (
                baseline_status, baseline_updated, status, updated);
        }
    }

    public class UDisksService : Object {
        public const string PREFIX = "org.freedesktop.UDisks2.";
        private DBusObjectManagerClient? manager;
        private uint refresh_source;
        private bool connecting;
        private StorageOperationLocks locks = new StorageOperationLocks ();
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
                device = raid;
            } else if (has (item, "VolumeGroup")) {
                var group = (previous.lookup (path) as StorageVolumeGroup) ?? new StorageVolumeGroup (path);
                group.name = property (item, "VolumeGroup", "Name")?.get_string () ?? "";
                device = group;
            } else if (has (item, "LogicalVolume")) {
                var volume = (previous.lookup (path) as StorageLogicalVolume) ?? new StorageLogicalVolume (path);
                volume.name = property (item, "LogicalVolume", "Name")?.get_string () ?? "";
                volume.group_path = property (item, "LogicalVolume", "VolumeGroup")?.get_string () ?? "/";
                volume.active = property (item, "LogicalVolume", "Active")?.get_boolean () ?? false;
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
            foreach (var old in previous_blocks.get_values ())
                if (!snapshot.blocks.contains (old.path)) minimum_sizes.invalidate (old.path);
            synchronize_jobs ();
            synchronize_selftests ();
            changed ();
        }

        private static bool selftest_terminal_success (string status) {
            return status == "success";
        }

        private static bool selftest_terminal_cancelled (string status) {
            return status == "aborted" || status == "interrupted" || status == "ctrl-reset" ||
                status == "ns-removed" || status == "aborted-format";
        }

        private void synchronize_selftests () {
            string[] finished = {};
            foreach (var entry in active_selftests.get_keys ()) {
                var drive = snapshot.drives.lookup (entry);
                var operation = active_selftests.lookup (entry);
                if (operation == null) continue;
                var job = operation.job;
                if (drive == null) {
                    var missing = new StorageOperationResult ();
                    missing.fail ("Self-test drive disappeared");
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
                if (operation.state == SelftestOperationState.UNCERTAIN &&
                    !operation.terminal_state_is_new (status, drive.smart_updated)) {
                    jobs.phase (job, StorageJobState.FINALIZING,
                        "Self-test request accepted; waiting for a new diagnostic status");
                    continue;
                }
                var result = new StorageOperationResult ();
                result.actual_state = status;
                if (operation.state == SelftestOperationState.STOPPING || selftest_terminal_cancelled (status)) {
                    result.fail ("Drive self-test stopped"); result.status = StorageOperationStatus.CANCELLED;
                } else if (selftest_terminal_success (status)) {
                    result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                    result.summary = operation.type + " drive self-test completed";
                } else {
                    result.fail ("Drive self-test failed");
                    result.technical_error = status == "" ? "The backend reported no final self-test state." : status;
                }
                jobs.finish (job, result); finished += entry;
            }
            foreach (var entry in finished) active_selftests.remove (entry);

            foreach (var drive in snapshot.drives.get_values ()) {
                if (drive.smart_selftest_status != "inprogress" || active_selftests.contains (drive.path)) continue;
                string[] affected = { drive.path };
                if (drive.medium != null) affected += drive.medium.path;
                var job = jobs.begin_named ("Drive self-test", drive.name, affected);
                var operation = new SelftestOperation (job, "Running", "");
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
                    proxy.g_signal.connect ((sender, signal_name, parameters) => {
                        if (signal_name != "Completed" || !parameters.is_of_type (new VariantType ("(bs)"))) return;
                        jobs.backend_completed (captured, parameters.get_child_value (0).get_boolean (),
                            parameters.get_child_value (1).get_string ());
                    });
                }
                jobs.observe (path, operation, objects, progress, valid, cancelable, start);
            }
            foreach (var path in observed_jobs.get_keys ()) if (!current.contains (path)) jobs.backend_removed (path);
            foreach (var path in connected_jobs.get_keys ()) if (!current.contains (path)) connected_jobs.remove (path);
            observed_jobs = current;
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
                if (stop && existing == null) throw new IOError.NOT_FOUND ("No tracked self-test is running for this drive.");
                var job = stop ? existing.job : jobs.begin (
                    stop ? "Stop drive self-test" : "Drive self-test", target, snapshot.dependencies);
                var result = new StorageOperationResult ();
                SelftestOperation operation;
                if (stop) operation = existing;
                else {
                    operation = new SelftestOperation (job, type, drive.smart_selftest_status, drive.smart_updated);
                    active_selftests.insert (drive.path, operation);
                }
                try {
                operation.state = stop ? SelftestOperationState.STOPPING : SelftestOperationState.STARTING;
                jobs.phase (job, StorageJobState.RUNNING, stop ? "Stopping " + operation.type + " self-test" :
                    "Starting " + type + " self-test");
                jobs.expect_backend (job, "ata-smart-selftest", drive.path);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (stop) yield proxy.call ("SmartSelftestAbort", new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else yield proxy.call ("SmartSelftestStart", new Variant.tuple ({
                    new Variant.string (type), options.end () }), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    int.MAX, backend_lifetime);
                if (!stop) operation.state = SelftestOperationState.START_CONFIRMED;
                bool observed = false;
                for (int attempt = 0; attempt < 20 && !observed; attempt++) {
                    synchronize ();
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
                if (stop && drive.smart_selftest_status == "inprogress") {
                    operation.state = SelftestOperationState.RUNNING;
                    jobs.progress (job, operation.type + " self-test in progress",
                        drive.smart_selftest_remaining >= 0 ? (100.0 - drive.smart_selftest_remaining) / 100.0 : 0.0,
                        drive.smart_selftest_remaining >= 0);
                } else {
                    bool timed_out = error.matches (IOError.quark (), IOError.TIMED_OUT);
                    if (timed_out && !stop) {
                        operation.state = SelftestOperationState.UNCERTAIN;
                        jobs.phase (job, StorageJobState.FINALIZING,
                            "Self-test request accepted; status observation is delayed");
                        maintain_selftest_refresh ();
                        throw error;
                    }
                    active_selftests.remove (drive.path);
                    string failure = stop ? "The self-test could not be stopped" :
                        (timed_out ? "Self-test result is unknown" : "The self-test could not be started");
                    result.fail (failure, error);
                    if (timed_out) result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    jobs.finish (job, result);
                }
                maintain_selftest_refresh (); throw error;
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
                    preparation = yield prepare_for_modification (target, backend_lifetime);
                }
                if (snapshot.drives.lookup (drive.path) != drive || drive.serial != serial || drive.wwn != wwn)
                    throw new IOError.NOT_FOUND ("The drive identity changed before the hardware action.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                jobs.phase (job, StorageJobState.RUNNING, job.operation);
                if (eject) jobs.expect_backend (job, "drive-eject", drive.path);
                else if (power_off) jobs.expect_backend (job, "drive-power-off", drive.path);
                var proxy = require_drive (drive, standby || wake ? "Drive.Ata" : "Drive");
                yield proxy.call (action, new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
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

        public string modification_identity (StorageBlock block) {
            var records = new GenericArray<string> ();
            foreach (var node in snapshot.dependencies.descendants (block)) {
                var child = node as StorageBlock;
                if (child == null) continue;
                var partition = child.partition;
                var drive = child.physical_drive;
                records.add (new Variant ("(ssssssssssttttu)", child.path, child.device,
                    child.parent?.path ?? "", child.drive_path, drive?.serial ?? "", drive?.wwn ?? "",
                    child.uuid, partition?.uuid ?? "", partition?.table_path ?? "",
                    child.table?.scheme ?? "", child.number, child.size, partition?.offset ?? 0,
                    child.logical_sector_size, partition?.number ?? 0).print (false));
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
                    preparation = yield prepare_for_modification (block, lifetime);
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
                yield proxy.call (ownership ? "TakeOwnership" : rename ? "SetLabel" : deleting ? "Delete" : "Format", parameters,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
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
            bool resize_filesystem) throws Error {
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
                if (requested < block.size && capability.supported &&
                    (capability.offline_shrink || capability.online_shrink)) {
                    try { minimum = uint64.max (minimum, yield minimum_sizes.query (block, backend_lifetime)); }
                    catch (Error error) { minimum_error = error; }
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

        private async void wait_for_size (StorageBlock block, uint64 expected, bool at_least,
            Cancellable token) throws Error {
            for (int attempt = 0; attempt < 100; attempt++) {
                synchronize ();
                if (snapshot.blocks.lookup (block.path) == block &&
                    (at_least ? block.size >= expected : block.size <= expected)) return;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("The updated partition geometry was not published in time.");
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
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
            for (int attempt = 0; attempt < 50; attempt++) {
                synchronize ();
                if (block.filesystem != null && !block.filesystem.mounted) return true;
                yield settle_delay (token);
            }
            throw new IOError.TIMED_OUT ("The filesystem did not become unmounted.");
        }

        private async StoragePreparationJournal prepare_for_modification (StorageBlock target, Cancellable token) throws Error {
            var journal = new StoragePreparationJournal ();
            journal.capture (target);
            var nodes = snapshot.dependencies.descendants (target);
            try {
                for (int index = nodes.length - 1; index >= 0; index--) {
                    var block = nodes[index] as StorageBlock;
                    if (block == null) continue;
                    var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                    if (safety.system_critical || safety.unknown_dependencies)
                        throw new IOError.BUSY ("Protected or unresolved storage cannot be prepared automatically.");
                    if (block.filesystem?.mounted == true) {
                        string[] state = { block.uuid, block.type_id };
                        foreach (var mount in block.filesystem.mounts) state += mount;
                        var entry = new StoragePreparationEntry (StoragePreparationKind.MOUNT, block.path, state, "unmount");
                        capture_mount_state (block, entry);
                        journal.add (entry);
                        entry.action_dispatched = true;
                        try {
                            entry.prepared = yield prepare_unmounted (block, token);
                            entry.backend_confirmed = true; entry.expected_state_observed = entry.prepared;
                            entry.actual_state = entry.prepared ? "unmounted" : "unchanged";
                        }
                        catch (Error error) {
                            synchronize ();
                            entry.prepared = block.filesystem != null && !block.filesystem.mounted;
                            entry.expected_state_observed = entry.prepared;
                            entry.actual_state = entry.prepared ? "unmounted" : "mounted or unavailable";
                            throw error;
                        }
                    }
                    if (block.swap_active) {
                        var entry = new StoragePreparationEntry (StoragePreparationKind.SWAP, block.path,
                            { block.uuid, block.type_id }, "deactivate swap");
                        journal.add (entry);
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

        private void capture_mount_state (StorageBlock block, StoragePreparationEntry entry) {
            foreach (var configuration in block.mount_configurations) {
                for (uint i = 0; i < entry.mount_point_count (); i++) {
                    string mount = entry.mount_point_at (i);
                    if (configuration.directory != mount) continue;
                    entry.persistent_mount = true;
                    entry.persistent_mount_options = configuration.options;
                    return;
                }
            }
        }

        private void reconcile_preparation (StoragePreparationJournal journal) {
            foreach (var entry in journal.entries ()) {
                if (!entry.prepared) continue;
                var block = snapshot.blocks.lookup (entry.object_path);
                if (block == null || !block.available) {
                    entry.actual_state = "device unavailable";
                    continue;
                }
                if (entry.kind == StoragePreparationKind.MOUNT) {
                    string[] actual_mounts = block.filesystem?.mounts ?? new string[0];
                    entry.actual_state = actual_mounts.length == 0 ? "unmounted" :
                        "mounted at " + string.joinv (", ", actual_mounts);
                    entry.restored = entry.mount_set_matches (actual_mounts);
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
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
            synchronize ();
            return reply.is_of_type (new VariantType ("(s)")) ? reply.get_child_value (0).get_string () : "";
        }

        private async void restore_preparation (StoragePreparationJournal journal, Cancellable token) throws Error {
            string[] failures = {};
            foreach (var entry in journal.restoration_order ()) {
                var block = snapshot.blocks.lookup (entry.object_path);
                if (block == null || !block.available || entry.state_length () < 2 ||
                    block.uuid != entry.state_at (0) || block.type_id != entry.state_at (1)) {
                    entry.error = "The prepared device or filesystem identity changed."; failures += entry.error; continue;
                }
                try {
                    if (entry.kind == StoragePreparationKind.MOUNT) {
                        string actual = yield restore_mount (block, token);
                        bool exact = entry.mount_point_count () == 0;
                        for (uint i = 0; i < entry.mount_point_count (); i++)
                            exact |= entry.mount_point_at (i) == actual;
                        if (!exact) {
                            var cleanup_options = new VariantBuilder (new VariantType ("a{sv}"));
                            try {
                                yield require_volume (block, "Filesystem").call ("Unmount",
                                    new Variant.tuple ({ cleanup_options.end () }),
                                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                                synchronize ();
                            } catch (Error cleanup_error) {
                                throw new IOError.FAILED ("UDisks mounted the filesystem at %s instead of its previous location, and cleanup failed: %s".printf (
                                    actual, cleanup_error.message));
                            }
                            throw new IOError.FAILED (entry.persistent_mount ?
                                "The persistent mount was restored at %s instead of its configured location.".printf (actual) :
                                "The temporary mount could not be restored at its exact previous location; the unrelated mount was removed.");
                        }
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
                if (!entry.prepared || !entry.restoration_allowed || entry.restored || entry.error != "") continue;
                entry.error = entry.kind == StoragePreparationKind.MOUNT ?
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
                if (resize_filesystem) {
                    filesystem = require_volume (block, "Filesystem");
                    if (plan.requires_unmount) {
                        jobs.phase (job, StorageJobState.PREPARING, "Unmounting filesystem");
                        string[] mount_state = { block.uuid, block.type_id };
                        foreach (var mount in block.filesystem?.mounts ?? new string[0]) mount_state += mount;
                        var mount_record = new StoragePreparationEntry (StoragePreparationKind.MOUNT,
                            block.path, mount_state, "unmount");
                        capture_mount_state (block, mount_record);
                        journal.add (mount_record);
                        remount = yield prepare_unmounted (block, token);
                        mount_record.prepared = remount;
                    }
                }
                journal.operation_started = true;
                validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                plan = yield resize_plan (block, new_size, resize_filesystem);
                if (!plan.supported) throw new IOError.NOT_SUPPORTED (plan.reason);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
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
                    yield filesystem.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Filesystem shrunk");
                    if (plan.requires_check) {
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                        var verified = yield filesystem.call ("Check", new Variant.tuple ({ options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        if (!verified.is_of_type (new VariantType ("(b)")) || !verified.get_child_value (0).get_boolean ())
                            throw new IOError.FAILED ("The resized filesystem did not pass its post-resize verification; the partition was left unchanged.");
                        result.completed ("Resized filesystem verified");
                    }
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    yield KernelStorageSafety.require_idle (block, token);
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking partition");
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition shrunk");
                    yield wait_for_size (block, new_size, false, token);
                } else {
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                    else yield KernelStorageSafety.require_idle (block, token);
                    jobs.phase (job, StorageJobState.RUNNING, shrinking ? "Shrinking partition" : "Growing partition");
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed (shrinking ? "Partition shrunk" : "Partition grown");
                    yield wait_for_size (block, new_size, !shrinking, token);
                    if (resize_filesystem) {
                        validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                        if (plan.online) yield KernelStorageSafety.require_no_holders (block, token);
                        else yield KernelStorageSafety.require_idle (block, token);
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                        jobs.phase (job, StorageJobState.RUNNING, "Growing filesystem");
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
                        offline_measurement = yield capacity_probes.query (block, backend_lifetime);
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
                        uint64 capacity = yield mounted_filesystem_capacity (block, backend_lifetime);
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
                if (remount && !journal.fully_restored ()) {
                    result.restoration_attempted = true;
                    try {
                        yield restore_preparation (journal, backend_lifetime);
                        result.restoration_succeeded = true;
                    } catch (Error restore_error) { restoration_error = restore_error.message; }
                }
                result.fail (result.completed_steps.length == 0 ? "The volume was not resized." :
                    "The resize was partially completed. The displayed geometry has been refreshed.", error);
                if (restoration_error != "") {
                    result.partial = true;
                    result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary += " The previous mount could not be restored.";
                    result.technical_error += "\nRestore: " + restoration_error;
                }
                synchronize ();
                result.actual_state = "Partition geometry and filesystem state were refreshed from UDisks.";
                jobs.finish (job, result);
                if (result.partial) return result;
                throw error;
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
                preparation = yield prepare_for_modification (block, lifetime);
                yield KernelStorageSafety.require_idle (block, lifetime);
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
            if (enabled) {
                MountOptionService.validate_configuration (directory, filesystem, options_text);
                foreach (var candidate in snapshot.blocks.get_values ()) {
                    foreach (var saved in candidate.mount_configurations) {
                        bool selected_entry = original_item != null && saved.backend_item != null &&
                            saved.backend_item.equal (original_item);
                        if (!selected_entry && saved.directory == directory)
                            throw new IOError.EXISTS ("Another persistent configuration already uses this mount point.");
                        if (!selected_entry && candidate == block && saved.device == "UUID=" + block.uuid &&
                            saved.directory == directory && saved.filesystem == filesystem.strip ())
                            throw new IOError.EXISTS ("An equivalent persistent configuration already exists.");
                    }
                }
            }
            int32 frequency = 0; int32 pass_number = 0;
            if (original_item != null) {
                var old_details = original_item.get_child_value (1);
                frequency = old_details.lookup_value ("freq", VariantType.INT32)?.get_int32 () ?? 0;
                pass_number = old_details.lookup_value ("passno", VariantType.INT32)?.get_int32 () ?? 0;
            }
            var details = new VariantBuilder (new VariantType ("a{sv}"));
            details.add ("{sv}", "fsname", new Variant.bytestring ("UUID=" + block.uuid));
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
                if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                    throw new IOError.NOT_FOUND ("The volume changed immediately before the configuration write.");
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
                        if (enabled && saved.directory == directory && saved.filesystem == (filesystem.strip () == "" ? "auto" : filesystem.strip ()) &&
                            saved.options == options_text && saved.device == "UUID=" + block.uuid) verified = true;
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
            bool hidden = false, bool system = false) throws Error {
            if (block.encrypted == null)
                throw new IOError.NOT_SUPPORTED ("The selected volume is not exposed as encrypted storage by UDisks.");
            if (block.encrypted.mapping != null)
                throw new IOError.EXISTS ("The encrypted volume is already unlocked.");
            bool veracrypt = block.type_id == "crypto_TCRYPT" || block.type_id == "crypto_unknown";
            if (passphrase == "" && keyfile_paths.length == 0)
                throw new IOError.INVALID_ARGUMENT ("Enter a passphrase or select a supported keyfile.");
            if (!veracrypt && (keyfile_paths.length != 0 || pim != 0 || hidden || system))
                throw new IOError.NOT_SUPPORTED ("VeraCrypt options are not supported for this encrypted volume.");
            if (pim != 0 || hidden || system || keyfile_paths.length > 1)
                throw new IOError.NOT_SUPPORTED (
                    "The installed UDisks backend supports password or one keyfile, but not advanced VeraCrypt modes.");
            var unique_keyfiles = new HashTable<string, string> (str_hash, str_equal);
            int64 total_keyfile_size = 0;
            uint8[] keyfile_contents = {};
            foreach (var keyfile_path in keyfile_paths) {
                if (keyfile_path == "" || unique_keyfiles.contains (keyfile_path))
                    throw new IOError.INVALID_ARGUMENT ("Every VeraCrypt keyfile must be a unique local file.");
                unique_keyfiles.insert (keyfile_path, keyfile_path);
                var keyfile = File.new_for_path (keyfile_path);
                var info = yield keyfile.query_info_async (FileAttribute.STANDARD_TYPE + "," +
                    FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                    Priority.DEFAULT, backend_lifetime);
                if (info.get_file_type () != FileType.REGULAR || info.get_size () <= 0 || info.get_size () > 8 * 1024 * 1024)
                    throw new IOError.INVALID_ARGUMENT ("The keyfile must be a readable regular file no larger than 8 MiB.");
                total_keyfile_size += info.get_size ();
                if (total_keyfile_size > 64 * 1024 * 1024)
                    throw new IOError.INVALID_ARGUMENT ("The selected VeraCrypt keyfiles exceed the 64 MiB safety limit.");
                string? etag;
                yield keyfile.load_contents_async (backend_lifetime, out keyfile_contents, out etag);
                if (keyfile_contents.length == 0 || keyfile_contents.length > 8 * 1024 * 1024)
                    throw new IOError.INVALID_ARGUMENT ("The keyfile is empty or too large.");
            }
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The encrypted volume changed before it could be unlocked.");
            var eligibility = StorageSafetyService.assess_operation (StorageOperationKind.MOUNT,
                block, snapshot.dependencies);
            if (!eligibility.allowed || eligibility.unknown)
                throw new IOError.PERMISSION_DENIED (eligibility.reason);
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin ("Unlock encrypted volume", block, snapshot.dependencies);
            var result = new StorageOperationResult ();
            try {
                jobs.phase (job, StorageJobState.RUNNING, "Authorizing and unlocking encrypted storage");
                if (modification_identity (block) != confirmed_identity || block.encrypted?.mapping != null)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed before the unlock request was sent.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (keyfile_contents.length != 0)
                    options.add ("{sv}", "keyfile_contents", new Variant.from_bytes (
                        new VariantType ("ay"), new Bytes (keyfile_contents), true));
                var reply = yield require_volume (block, "Encrypted").call ("Unlock",
                    new Variant ("(s@a{sv})", passphrase, options.end ()),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                string cleartext_path = reply.get_child_value (0).get_string ();
                StorageBlock? mapping = null;
                for (int attempt = 0; attempt < 50 && mapping == null; attempt++) {
                    synchronize ();
                    mapping = snapshot.blocks.lookup (cleartext_path);
                    if (mapping == null) yield settle_delay (backend_lifetime);
                }
                if (mapping == null || mapping.backing_path != block.path) {
                    result.completed ("UDisks accepted the passphrase and returned " + cleartext_path);
                    result.partial = true; result.status = StorageOperationStatus.NEEDS_ATTENTION;
                    result.summary = "The encrypted volume may be unlocked, but the clear-text mapping was not published in time. Refresh before trying again.";
                    result.resulting_path = cleartext_path; result.actual_state = "unlock outcome requires reconciliation";
                    jobs.finish (job, result); return result;
                }
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Encrypted volume unlocked"; result.resulting_path = mapping.path;
                result.actual_state = mapping.preferred; jobs.finish (job, result);
                return result;
            } catch (Error error) {
                result.fail ("The encrypted volume could not be unlocked", error); jobs.finish (job, result); throw error;
            } finally { locks.release (block); }
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
                preparation = yield prepare_for_modification (mapping, backend_lifetime);
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

        public async StorageEncryptionConfiguration? secret_encryption_configuration (StorageBlock block,
            string desired_name = "") throws Error {
            if (block.encrypted == null || block.uuid == "")
                throw new IOError.NOT_SUPPORTED ("Persistent encryption configuration is unavailable.");
            if (block.encryption_configuration == null || block.encryption_configuration.passphrase_path == "" ||
                block.encryption_configuration.passphrase_path.has_prefix ("/dev/"))
                return desired_name == "" ? block.encryption_configuration : find_encryption_configuration (block, desired_name);
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

        public async void configure_encryption (StorageBlock block, bool enabled, bool startup,
            string mapping_name, string crypt_options, string new_passphrase, Variant? original_item,
            string confirmed_identity, string confirmed_uuid) throws Error {
            if (block.encrypted == null || block.uuid == "" || block.read_only || block.system_hint)
                throw new IOError.NOT_SUPPORTED ("Persistent encryption configuration is unavailable for this volume.");
            if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                throw new IOError.NOT_FOUND ("The encrypted volume changed after the dialog was opened.");
            string name = mapping_name.strip ();
            if (enabled && (name == "" || name.contains ("/") || name.contains (",") ||
                name.contains (" ") || name.contains ("\n") || name.contains ("\r")))
                throw new IOError.INVALID_ARGUMENT ("The mapping name is invalid.");
            string normalized = MountOptionService.normalize (crypt_options, startup);
            foreach (var option in MountOptionService.parse (normalized))
                if (option.has_prefix ("x-gvfs-") || option.has_prefix ("subvol") || option.has_prefix ("compress"))
                    throw new IOError.INVALID_ARGUMENT ("The option ‘%s’ is not valid in crypttab.".printf (option));
            foreach (var candidate in snapshot.blocks.get_values ()) {
                if (!enabled) continue;
                foreach (var saved in candidate.encryption_configurations) {
                    bool selected = original_item != null && saved.backend_item != null && saved.backend_item.equal (original_item);
                    if (!selected && saved.name == name)
                        throw new IOError.EXISTS ("Another encrypted volume already uses this mapping name.");
                }
            }
            var details = new VariantBuilder (new VariantType ("a{sv}"));
            details.add ("{sv}", "device", new Variant.bytestring ("UUID=" + block.uuid));
            details.add ("{sv}", "name", new Variant.bytestring (name));
            details.add ("{sv}", "options", new Variant.bytestring (normalized));
            string old_path = ""; string old_secret = "";
            if (original_item != null) {
                var old_details = original_item.get_child_value (1);
                old_path = old_details.lookup_value ("passphrase-path", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                old_secret = old_details.lookup_value ("passphrase-contents", VariantType.BYTESTRING)?.get_bytestring () ?? "";
            }
            if (original_item != null && new_passphrase == "" && old_path != "" &&
                !old_path.has_prefix ("/dev/") && old_secret == "") {
                var secret_config = yield secret_encryption_configuration (block, name);
                if (secret_config != null && secret_config.name == name && secret_config.backend_item != null) {
                    var secret_details = secret_config.backend_item.get_child_value (1);
                    old_secret = secret_details.lookup_value ("passphrase-contents", VariantType.BYTESTRING)?.get_bytestring () ?? "";
                } else throw new IOError.FAILED ("The existing protected key material could not be read safely.");
            }
            string secret_value = new_passphrase == "" ? old_secret : new_passphrase;
            string secret_path = secret_value == "" ? "" : old_path == "" ? "/etc/luks-keys/" + name : old_path;
            details.add ("{sv}", "passphrase-path", new Variant.bytestring (secret_path));
            details.add ("{sv}", "passphrase-contents", new Variant.bytestring (secret_value));
            var item = new Variant.tuple ({ new Variant.string ("crypttab"), details.end () });
            var call_options = new VariantBuilder (new VariantType ("a{sv}"));
            var proxy = require_volume (block, "Block");
            locks.acquire (block, snapshot.dependencies);
            var job = jobs.begin (enabled ? "Configure automatic unlocking" : "Remove automatic unlocking", block,
                snapshot.dependencies);
            var result = new StorageOperationResult ();
            try {
                jobs.phase (job, StorageJobState.RUNNING, "Updating protected encryption configuration");
                if (modification_identity (block) != confirmed_identity || block.uuid != confirmed_uuid)
                    throw new IOError.NOT_FOUND ("The encrypted volume changed immediately before the configuration write.");
                if (!enabled && original_item != null)
                    yield proxy.call ("RemoveConfigurationItem", new Variant.tuple ({ original_item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled && original_item != null)
                    yield proxy.call ("UpdateConfigurationItem", new Variant.tuple ({ original_item, item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                else if (enabled)
                    yield proxy.call ("AddConfigurationItem", new Variant.tuple ({ item, call_options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, backend_lifetime);
                bool verified = false;
                for (int attempt = 0; attempt < 50 && !verified; attempt++) {
                    synchronize (); verified = !enabled;
                    foreach (var saved in block.encryption_configurations) {
                        if (!enabled && original_item != null && saved.backend_item != null && saved.backend_item.equal (original_item))
                            verified = false;
                        if (enabled && saved.device == "UUID=" + block.uuid && saved.name == name &&
                            saved.options == normalized && saved.passphrase_path == secret_path) verified = true;
                    }
                    if (!verified) yield settle_delay (backend_lifetime);
                }
                if (!verified) throw new IOError.FAILED ("UDisks did not publish the requested crypttab configuration.");
                result.successful = true; result.status = StorageOperationStatus.SUCCEEDED;
                result.summary = "Encryption configuration updated"; jobs.finish (job, result);
            } catch (Error error) {
                result.fail ("Encryption configuration was not updated", error); jobs.finish (job, result); throw error;
            } finally { locks.release (block); }
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
