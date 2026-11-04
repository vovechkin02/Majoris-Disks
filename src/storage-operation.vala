namespace MajorisDisks {
    public enum StoragePreparationKind { MOUNT, SWAP, ENCRYPTED_MAPPING, LOGICAL_VOLUME, RAID }

    public class StoragePreparationEntry : Object {
        public StoragePreparationKind kind { get; construct; }
        public string object_path { get; construct; }
        public string[] state { get; construct; }
        public string operation_type { get; construct; }
        public bool prepared { get; set; }
        public bool restoration_allowed { get; set; default = true; }
        public bool restored { get; set; }
        public string error { get; set; default = ""; }
        public StoragePreparationEntry (StoragePreparationKind kind, string object_path, string[] state,
            string operation_type = "prepare") {
            Object (kind: kind, object_path: object_path, state: state, operation_type: operation_type);
        }
    }

    public class StoragePreparationJournal : Object {
        private GenericArray<StoragePreparationEntry> records = new GenericArray<StoragePreparationEntry> ();
        public bool operation_started;
        public bool operation_completed;

        public void add (StoragePreparationEntry entry) { records.add (entry); }
        public StoragePreparationEntry[] entries () {
            StoragePreparationEntry[] result = {};
            for (uint i = 0; i < records.length; i++) result += records[i];
            return result;
        }
        public StoragePreparationEntry[] restoration_order () {
            StoragePreparationEntry[] result = {};
            for (int i = (int) records.length - 1; i >= 0; i--)
                if (records[(uint) i].prepared && records[(uint) i].restoration_allowed) result += records[(uint) i];
            return result;
        }
        public bool fully_restored () {
            foreach (var entry in entries ()) if (entry.prepared && !entry.restored) return false;
            return true;
        }
    }

    public class StorageOperationLocks : Object {
        private HashTable<string, HashTable<string, string>> active =
            new HashTable<string, HashTable<string, string>> (str_hash, str_equal);

        private HashTable<string, string> footprint (StorageBlock target, StorageDependencyService graph) {
            var paths = new HashTable<string, string> (str_hash, str_equal);
            foreach (var device in graph.descendants (target))
                foreach (var upstream in graph.ancestors (device))
                    paths.insert (upstream.path, upstream.path);
            return paths;
        }

        public bool conflicts (StorageBlock target, StorageDependencyService graph) {
            var requested = footprint (target, graph);
            foreach (var running in active.get_values ())
                foreach (var path in requested.get_keys ())
                    if (running.contains (path)) return true;
            return false;
        }

        public void acquire (StorageBlock target, StorageDependencyService graph) throws Error {
            if (conflicts (target, graph))
                throw new IOError.BUSY ("Another storage operation is using this device.");
            active.insert (target.path, footprint (target, graph));
        }

        public void release (StorageBlock target) {
            active.remove (target.path);
        }
    }

    [Flags]
    public enum FilesystemResizeMode {
        OFFLINE_SHRINK = 1 << 1,
        OFFLINE_GROW = 1 << 2,
        ONLINE_SHRINK = 1 << 3,
        ONLINE_GROW = 1 << 4
    }

    public struct FilesystemCapability {
        public bool supported;
        public string missing_utility;
        public FilesystemResizeMode modes;
        public string reason;

        public bool online_grow { get { return (modes & FilesystemResizeMode.ONLINE_GROW) != 0; } }
        public bool offline_grow { get { return (modes & FilesystemResizeMode.OFFLINE_GROW) != 0; } }
        public bool online_shrink { get { return (modes & FilesystemResizeMode.ONLINE_SHRINK) != 0; } }
        public bool offline_shrink { get { return (modes & FilesystemResizeMode.OFFLINE_SHRINK) != 0; } }
    }

    public class FilesystemCapabilityService {
        public static FilesystemCapability decode (Variant reply, bool resize = false) throws Error {
            if (!reply.is_of_type (new VariantType (resize ? "((bts))" : "((bs))")))
                throw new IOError.INVALID_DATA ("UDisks returned invalid filesystem capability information.");

            var output = reply.get_child_value (0);
            FilesystemCapability capability = {};
            capability.supported = output.get_child_value (0).get_boolean ();
            capability.missing_utility = output.get_child_value (resize ? 2 : 1).get_string ();
            if (resize && capability.supported) {
                uint64 known = FilesystemResizeMode.OFFLINE_SHRINK | FilesystemResizeMode.OFFLINE_GROW |
                    FilesystemResizeMode.ONLINE_SHRINK | FilesystemResizeMode.ONLINE_GROW;
                capability.modes = (FilesystemResizeMode) (output.get_child_value (1).get_uint64 () & known);
            }
            if (!capability.supported)
                capability.reason = capability.missing_utility == "" ? "The UDisks backend does not support this operation." :
                    "The required utility is not installed: " + capability.missing_utility;
            else if (resize && capability.modes == 0)
                capability.reason = "The filesystem has no supported resize mode.";
            else capability.reason = "";
            return capability;
        }

        public static FilesystemResizeMode resize_modes (Variant reply, out string missing_utility) throws Error {
            var capability = decode (reply, true);
            missing_utility = capability.missing_utility;
            return capability.modes;
        }

        public static bool check_available (Variant reply, bool repair = false) throws Error {
            var capability = decode (reply);
            if (!capability.supported && capability.missing_utility != "")
                throw new IOError.NOT_SUPPORTED (("The filesystem %s operation requires %s.").printf (
                    repair ? "repair" : "check", capability.missing_utility));
            return capability.supported;
        }

        public static bool supports_label (string type) {
            switch (type.down ()) {
                case "ext2": case "ext3": case "ext4": case "btrfs": case "xfs":
                case "f2fs": case "ntfs": case "vfat": case "exfat": case "udf":
                    return true;
                default:
                    return false;
            }
        }

        public static void validate_label (string type, string label) throws Error {
            if (!label.validate () || label.contains ("\n") || label.contains ("/"))
                throw new IOError.INVALID_ARGUMENT ("The volume label contains unsupported characters.");
            int bytes = label.length;
            int characters = label.char_count ();
            switch (type.down ()) {
                case "ext2": case "ext3": case "ext4":
                    if (bytes > 16) throw new IOError.INVALID_ARGUMENT ("Ext filesystems use labels of at most 16 bytes.");
                    break;
                case "xfs":
                    if (bytes > 12) throw new IOError.INVALID_ARGUMENT ("XFS labels are limited to 12 bytes.");
                    break;
                case "btrfs":
                    if (bytes > 255) throw new IOError.INVALID_ARGUMENT ("Btrfs labels are limited to 255 bytes.");
                    break;
                case "f2fs":
                    if (characters > 512) throw new IOError.INVALID_ARGUMENT ("F2FS labels are limited to 512 characters.");
                    break;
                case "vfat":
                    if (characters > 11 || label != label.up () || label.contains ("+") || label.contains (",") ||
                        label.contains (";") || label.contains ("=") || label.contains ("[") || label.contains ("]"))
                        throw new IOError.INVALID_ARGUMENT ("FAT labels use at most 11 upper-case characters.");
                    break;
                case "exfat": case "ntfs":
                    if (characters > 32) throw new IOError.INVALID_ARGUMENT ("This filesystem uses labels of at most 32 characters.");
                    break;
                case "udf":
                    if (bytes > 126) throw new IOError.INVALID_ARGUMENT ("UDF labels are limited to 126 bytes.");
                    break;
                default:
                    if (label != "") throw new IOError.NOT_SUPPORTED ("This filesystem does not support volume labels.");
                    break;
            }
        }
    }

    public enum StorageJobState {
        PENDING, PREPARING, RUNNING, CANCELLING, FINALIZING, COMPLETED, FAILED, CANCELLED,
        PARTIALLY_COMPLETED, NEEDS_ATTENTION
    }

    public enum StorageOperationStatus { SUCCEEDED, FAILED, CANCELLED, PARTIAL, NEEDS_ATTENTION }

    public class StorageOperationResult : Object {
        public bool successful;
        public bool partial;
        public StorageOperationStatus status = StorageOperationStatus.FAILED;
        public string summary = "";
        public string technical_error = "";
        public string resulting_path = "";
        public string failed_step = "";
        public string actual_state = "";
        public bool restoration_attempted;
        public bool restoration_succeeded;
        public string[] completed_steps = {};

        public void completed (string step) {
            string[] updated = new string[completed_steps.length + 1];
            for (int i = 0; i < completed_steps.length; i++) updated[i] = completed_steps[i];
            updated[completed_steps.length] = step;
            completed_steps = updated;
        }
        public void fail (string message, Error? error = null) {
            successful = false;
            partial = completed_steps.length != 0;
            if (error != null && error is IOError.CANCELLED) status = StorageOperationStatus.CANCELLED;
            else status = partial ? StorageOperationStatus.PARTIAL : StorageOperationStatus.FAILED;
            summary = message;
            failed_step = message;
            technical_error = error?.message ?? "";
        }
    }

    public class StorageJob : Object {
        public string id { get; construct; }
        public string operation { get; construct; }
        public string target { get; construct; }
        public string[] affected { get; construct; }
        public int64 start_time { get; construct; }
        public string phase { get; set; default = "Waiting"; }
        public StorageJobState state { get; set; default = StorageJobState.PENDING; }
        public double progress { get; set; default = 0.0; }
        public bool progress_valid { get; set; default = false; }
        public bool cancelable { get; set; default = false; }
        public string backend_path { get; set; default = ""; }
        public string error_message { get; set; default = ""; }
        public StorageOperationResult? result { get; set; }
        public Cancellable cancellable { get; private set; default = new Cancellable (); }

        public StorageJob (string id, string operation, string target, string[] affected) {
            Object (id: id, operation: operation, target: target, affected: affected,
                start_time: get_real_time ());
        }
    }

    public class StorageJobManager : Object {
        public ListStore jobs { get; private set; default = new ListStore (typeof (StorageJob)); }
        private uint64 serial;
        public signal void changed ();

        public StorageJob begin (string operation, StorageBlock target, StorageDependencyService graph) {
            string[] affected = {};
            foreach (var node in graph.descendants (target)) affected += node.path;
            var job = new StorageJob ((++serial).to_string (), operation, target.preferred, affected);
            jobs.append (job);
            changed ();
            return job;
        }

        public void phase (StorageJob job, StorageJobState state, string phase) {
            job.state = state;
            job.phase = phase;
            changed ();
        }

        public void finish (StorageJob job, StorageOperationResult result) {
            job.result = result;
            job.progress = 1.0;
            job.progress_valid = result.successful;
            if (result.successful) result.status = StorageOperationStatus.SUCCEEDED;
            job.state = result.status == StorageOperationStatus.SUCCEEDED ? StorageJobState.COMPLETED :
                result.status == StorageOperationStatus.CANCELLED ? StorageJobState.CANCELLED :
                result.status == StorageOperationStatus.NEEDS_ATTENTION ? StorageJobState.NEEDS_ATTENTION :
                result.status == StorageOperationStatus.PARTIAL ? StorageJobState.PARTIALLY_COMPLETED : StorageJobState.FAILED;
            job.phase = result.summary;
            changed ();
        }

        public void observe (string path, string operation, string[] objects, double progress,
            bool valid, bool cancelable, uint64 start_time) {
            StorageJob? match = null;
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var candidate = jobs.get_item (i) as StorageJob;
                if (candidate.backend_path == path) {
                    match = candidate;
                    break;
                }
            }
            if (match == null) {
                match = new StorageJob ("udisks:" + path, operation, objects.length == 0 ? "Storage device" : objects[0], objects);
                jobs.append (match);
            }
            match.backend_path = path;
            match.state = StorageJobState.RUNNING;
            match.phase = operation;
            match.progress = progress;
            match.progress_valid = valid;
            match.cancelable = cancelable;
            changed ();
        }

        public void backend_removed (string path) {
            for (uint i = 0; i < jobs.get_n_items (); i++) {
                var job = jobs.get_item (i) as StorageJob;
                if (job.backend_path == path && (job.state == StorageJobState.RUNNING ||
                    job.state == StorageJobState.CANCELLING)) {
                    job.state = StorageJobState.NEEDS_ATTENTION;
                    job.phase = "Backend job disappeared before its result was confirmed";
                    job.error_message = "Refresh the device state before attempting another destructive operation.";
                    changed ();
                }
            }
        }
    }
}
