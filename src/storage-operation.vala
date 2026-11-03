namespace MajorisDisks {
    public class StorageOperationLocks : Object {
        private GenericArray<StorageBlock> active = new GenericArray<StorageBlock> ();

        public bool conflicts (StorageBlock target, StorageDependencyService graph) {
            foreach (var running in active) {
                if (running.path == target.path) return true;
                foreach (var left in graph.descendants (running))
                    foreach (var right in graph.descendants (target))
                        if (left == right) return true;
            }
            return false;
        }

        public void acquire (StorageBlock target, StorageDependencyService graph) throws Error {
            if (conflicts (target, graph))
                throw new IOError.BUSY ("Another storage operation is using this device.");
            active.add (target);
        }

        public void release (StorageBlock target) {
            active.remove (target);
        }
    }

    public class FilesystemCapabilityService {
        public static bool check_available (Variant reply, bool repair = false) throws Error {
            if (!reply.is_of_type (new VariantType ("(bs)")))
                throw new IOError.INVALID_DATA ("UDisks returned invalid filesystem capability information.");
            if (reply.get_child_value (0).get_boolean ()) return true;
            string utility = reply.get_child_value (1).get_string ();
            if (utility != "")
                throw new IOError.NOT_SUPPORTED (("The filesystem %s operation requires %s.").printf (repair ? "repair" : "check", utility));
            return false;
        }
    }
}
