namespace MajorisDisks {
    public class UDisksService : Object {
        public const string PREFIX = "org.freedesktop.UDisks2.";
        private DBusObjectManagerClient? manager;
        private uint refresh_source;
        private bool connecting;
        private StorageOperationLocks locks = new StorageOperationLocks ();
        private FilesystemMinimumSizeService minimum_sizes = new FilesystemMinimumSizeService ();
        public StorageJobManager jobs { get; private set; default = new StorageJobManager (); }
        private HashTable<string, string> observed_jobs = new HashTable<string, string> (str_hash, str_equal);
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
            drive.available = property (object_proxy, "Drive", "MediaAvailable")?.get_boolean () ?? false;
            drive.smart = property (object_proxy, "Drive.Ata", "SmartSupported")?.get_boolean () ?? false;
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
            if (config != null) {
                for (size_t i = 0; i < config.n_children (); i++) {
                    var entry = config.get_child_value (i);
                    if (entry.get_child_value (0).get_string () != "fstab") continue;
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
            synchronize_jobs ();
            changed ();
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
                jobs.observe (path, operation, objects, progress, valid, cancelable, start);
            }
            foreach (var path in observed_jobs.get_keys ()) if (!current.contains (path)) jobs.backend_removed (path);
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
            bool allow_mounted = false, bool allow_active = false) throws Error {
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
                if (child == null || !child.available || child.system_hint || child.ignored || child.read_only ||
                    child.raid_member_path != "/" || child.physical_volume_group_path != "/" ||
                    child.usage == "raid" || child.usage == "crypto")
                    throw new IOError.PERMISSION_DENIED ("The target includes protected or unsupported storage.");
                var safety = StorageSafetyService.assess (child, snapshot.dependencies);
                if ((!allow_mounted && safety.mounted) || (!allow_active && safety.active_dependents) ||
                    safety.system_critical || safety.unknown_dependencies)
                    throw new IOError.BUSY ("The target has active mounts or unresolved dependencies.");
            }
        }

        public static bool supports_ownership (StorageBlock block) {
            if (!block.available || block.read_only || block.system_hint ||
                block.filesystem == null || block.filesystem.mounted) return false;
            return block.type_id == "ext4" || block.type_id == "xfs" ||
                   block.type_id == "btrfs" || block.type_id == "f2fs";
        }
        public async void modify_partitioning (StorageBlock block, string command, string confirmed_identity, string label = "", bool recursive = false) throws Error {
            bool deleting = command == "delete";
            bool rename = command == "label";
            bool ownership = command == "ownership";
            bool metadata = command == "name" || command == "bootable" || command == "type" || command == "flags";
            bool partition_operation = deleting || metadata;
            bool formatting = command.has_prefix ("format:") || command.has_prefix ("format-zero:");
            bool overwrite = command.has_prefix ("format-zero:");
            bool volume = ownership || rename || formatting;
            string format = formatting ? command.substring (overwrite ? 12 : 7) : command;
            bool destructive = deleting || formatting || command == "gpt" || command == "dos" || command == "empty";
            if (!volume && !partition_operation && command != "gpt" && command != "dos" && command != "empty")
                throw new IOError.INVALID_ARGUMENT ("Unknown partitioning operation.");
            if (rename) FilesystemCapabilityService.validate_label (block.type_id, label);
            string iface = rename || ownership ? "Filesystem" : partition_operation ? "Partition" : "Block";
            var proxy = require_volume (block, iface);
            var lifetime = backend_lifetime;
            validate_modification (block, partition_operation, volume, destructive, destructive);
            if (modification_identity (block) != confirmed_identity)
                throw new IOError.NOT_FOUND ("The target changed after confirmation.");
            locks.acquire (block, snapshot.dependencies);
            try {
                if (destructive) {
                    yield prepare_for_modification (block, lifetime);
                    validate_modification (block, partition_operation, volume);
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
                foreach (var node in snapshot.dependencies.descendants (block)) {
                    var child = node as StorageBlock;
                    if (child != null) yield KernelStorageSafety.require_idle (child, lifetime);
                }
                if (lifetime.is_cancelled () || require_volume (block, iface) != proxy ||
                    modification_identity (block) != confirmed_identity)
                    throw new IOError.NOT_FOUND ("The target changed before the operation started.");
                validate_modification (block, partition_operation, volume);
                if (rename && !FilesystemCapabilityService.supports_label (block.type_id))
                    throw new IOError.NOT_FOUND ("The filesystem changed before the label could be applied.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                if (formatting && label != "") {
                    FilesystemCapabilityService.validate_label (format, label);
                    options.add ("{sv}", "label", new Variant.string (label));
                }
                if (formatting) options.add ("{sv}", "update-partition-type", new Variant.boolean (true));
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
                    yield proxy.call (command == "name" ? "SetName" : command == "type" ? "SetType" : "SetFlags",
                        new Variant.tuple ({ value, options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                    synchronize ();
                    return;
                }
                var parameters = deleting || ownership ? new Variant.tuple ({ options.end () }) :
                    new Variant.tuple ({ new Variant.string (rename ? label : format), options.end () });
                yield proxy.call (ownership ? "TakeOwnership" : rename ? "SetLabel" : deleting ? "Delete" : "Format", parameters,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                synchronize ();
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

        private async void prepare_for_modification (StorageBlock target, Cancellable token) throws Error {
            var nodes = snapshot.dependencies.descendants (target);
            for (int index = nodes.length - 1; index >= 0; index--) {
                var block = nodes[index] as StorageBlock;
                if (block == null) continue;
                var safety = StorageSafetyService.assess (block, snapshot.dependencies);
                if (safety.system_critical || safety.unknown_dependencies)
                    throw new IOError.BUSY ("Protected or unresolved storage cannot be prepared automatically.");
                if (block.filesystem?.mounted == true) yield prepare_unmounted (block, token);
                if (block.swap_active) {
                    var swap = require_volume (block, "Swapspace");
                    var options = new VariantBuilder (new VariantType ("a{sv}"));
                    yield swap.call ("Stop", new Variant.tuple ({ options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    synchronize ();
                }
            }
        }

        private async void restore_mount (StorageBlock block, Cancellable token) throws Error {
            var proxy = require_volume (block, "Filesystem");
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            yield proxy.call ("Mount", new Variant.tuple ({ options.end () }),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
            synchronize ();
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
            if (!eligibility.allowed || disk.read_only)
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
                result.summary = filesystem_type == "" || filesystem_type == "empty" ? "Partition created" : "Partition created and formatted";
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
                var plan = yield resize_plan (block, new_size, resize_filesystem);
                if (!plan.supported) throw new IOError.NOT_SUPPORTED (plan.reason);
                if (resize_filesystem) {
                    filesystem = require_volume (block, "Filesystem");
                    if (plan.requires_unmount) {
                        jobs.phase (job, StorageJobState.PREPARING, "Unmounting filesystem");
                        var mount_record = new StoragePreparationEntry (StoragePreparationKind.MOUNT,
                            block.path, block.filesystem?.mounts ?? new string[0]);
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
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking filesystem");
                    yield filesystem.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Filesystem shrunk");
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                    jobs.phase (job, StorageJobState.RUNNING, "Shrinking partition");
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition shrunk");
                    yield wait_for_size (block, new_size, false, token);
                } else {
                    validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                    jobs.phase (job, StorageJobState.RUNNING, shrinking ? "Shrinking partition" : "Growing partition");
                    yield partition.call ("Resize", new Variant.tuple ({ new Variant.uint64 (new_size), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed (shrinking ? "Partition shrunk" : "Partition grown");
                    yield wait_for_size (block, new_size, !shrinking, token);
                    if (resize_filesystem) {
                        validate_resize_target (block, disk, partition_uuid, partition_offset, device_number);
                        options = new VariantBuilder (new VariantType ("a{sv}"));
                        jobs.phase (job, StorageJobState.RUNNING, "Growing filesystem");
                        yield filesystem.call ("Resize", new Variant.tuple ({ new Variant.uint64 (0), options.end () }),
                            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                        result.completed ("Filesystem grown");
                    }
                }
                if (remount) {
                    jobs.phase (job, StorageJobState.FINALIZING, "Restoring mount");
                    try {
                        yield restore_mount (block, backend_lifetime); result.completed ("Mount restored");
                        foreach (var record in journal.entries ()) if (record.kind == StoragePreparationKind.MOUNT) record.restored = true;
                    }
                    catch (Error error) {
                        result.fail ("The resize completed, but the previous mount could not be restored.", error);
                        jobs.finish (job, result);
                        return result;
                    }
                }
                synchronize ();
                journal.operation_completed = true;
                result.successful = true;
                result.summary = "Volume resized";
                jobs.finish (job, result);
                select_requested (block.path);
                return result;
            } catch (Error error) {
                string restoration_error = "";
                if (remount && !journal.fully_restored ()) {
                    try {
                        yield restore_mount (block, backend_lifetime);
                        foreach (var record in journal.entries ()) if (record.kind == StoragePreparationKind.MOUNT) record.restored = true;
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
                jobs.finish (job, result);
                if (result.partial) return result;
                throw error;
            } finally {
                locks.release (block);
            }
        }

        private void validate_resize_target (StorageBlock block, StorageBlock disk, string partition_uuid,
            uint64 partition_offset, uint64 device_number) throws Error {
            var current = snapshot.blocks.lookup (block.path);
            var part = block.partition;
            if (current != block || !block.available || block.read_only || part == null ||
                snapshot.blocks.lookup (part.table_path) != disk || disk.table == null ||
                part.uuid != partition_uuid || part.offset != partition_offset || block.number != device_number)
                throw new IOError.NOT_FOUND ("The partition identity or parent table changed during resizing.");
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
            try {
                var proxy = require_volume (block, "Partition");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                jobs.phase (job, StorageJobState.RUNNING, "Updating partition metadata");
                if (type != part.type_id) {
                    yield proxy.call ("SetType", new Variant.tuple ({ new Variant.string (type), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition type updated");
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                }
                if (scheme == "gpt" && name != part.name) {
                    yield proxy.call ("SetName", new Variant.tuple ({ new Variant.string (name), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition name updated");
                    options = new VariantBuilder (new VariantType ("a{sv}"));
                }
                if (flags != part.flags) {
                    yield proxy.call ("SetFlags", new Variant.tuple ({ new Variant.uint64 (flags), options.end () }),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, token);
                    result.completed ("Partition flags updated");
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
            validate_check (block, true);
            if (repair && (block.read_only || block.system_hint))
                throw new IOError.PERMISSION_DENIED ("Repair is unavailable on protected or read-only storage.");
            string filesystem_type = block.type_id;
            string target_identity = modification_identity (block);
            var lifetime = backend_lifetime;
            locks.acquire (block, snapshot.dependencies);
            bool remount = false;
            try {
                if (!(yield maintenance_available (filesystem_type, repair)))
                    throw new IOError.NOT_SUPPORTED (repair ? "UDisks does not support repairing this filesystem." :
                        "UDisks does not support checking this filesystem.");
                remount = yield prepare_unmounted (block, lifetime);
                yield KernelStorageSafety.require_idle (block, lifetime);
                if (lifetime.is_cancelled () || require_volume (block, "Filesystem") != filesystem ||
                    block.type_id != filesystem_type || modification_identity (block) != target_identity)
                    throw new IOError.NOT_FOUND ("The selected volume changed before the check could start.");
                validate_check (block);
                if (repair && (block.read_only || block.system_hint))
                    throw new IOError.PERMISSION_DENIED ("The volume is now protected or read-only.");
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                var result = yield filesystem.call (repair ? "Repair" : "Check", new Variant.tuple ({ options.end () }),
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, lifetime);
                require_volume (block, "Filesystem");
                if (!result.is_of_type (new VariantType ("(b)")))
                    throw new IOError.INVALID_DATA ("UDisks returned an invalid filesystem check result.");
                bool successful = result.get_child_value (0).get_boolean ();
                if (remount) yield restore_mount (block, lifetime);
                return successful;
            } catch (Error error) {
                if (remount && block.filesystem != null && !block.filesystem.mounted) {
                    try { yield restore_mount (block, lifetime); }
                    catch (Error mount_error) {
                        throw new IOError.FAILED ("%s The previous mount also could not be restored: %s".printf (
                            error.message, mount_error.message));
                    }
                }
                throw error;
            } finally {
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
            try {
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                yield proxy.call (method, new Variant.tuple ({ options.end () }),
                                  DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, backend_lifetime);
            } finally {
                locks.release (block);
            }
            if (snapshot.blocks.lookup (block.path) != block)
                throw new IOError.NOT_FOUND ("The volume was removed during the operation.");
        }
    }
}
