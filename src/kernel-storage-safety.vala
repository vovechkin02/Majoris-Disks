namespace MajorisDisks {
    public class KernelStorageSafety {
        public static string device_number (uint64 number) {
            uint64 major = ((number >> 8) & 0xfff) | ((number >> 32) & 0xfffff000);
            uint64 minor = (number & 0xff) | ((number >> 12) & 0xffffff00);
            return major.to_string () + ":" + minor.to_string ();
        }

        public static async void require_idle (StorageBlock block, Cancellable token) throws Error {
            yield require_no_holders (block, token);
            string identity = device_number (block.number);
            uint8[] contents;
            yield File.new_for_path ("/proc/self/mountinfo").load_contents_async (token, out contents, null);
            if (has_mount ((string) contents, identity))
                throw new IOError.BUSY ("The kernel reports an active mount for this volume.");
        }

        public static async void require_no_holders (StorageBlock block, Cancellable token) throws Error {
            if (block.number == 0)
                throw new IOError.NOT_SUPPORTED ("The kernel device identity is unavailable.");
            string identity = device_number (block.number);
            var device = File.new_for_path ("/sys/dev/block/" + identity);
            var holders = yield device.get_child ("holders").enumerate_children_async (
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE, Priority.DEFAULT, token);
            var entries = yield holders.next_files_async (1, Priority.DEFAULT, token);
            if (entries != null)
                throw new IOError.BUSY ("Another kernel storage device depends on this volume.");
        }

        public static bool has_mount (string mountinfo, string identity) {
            foreach (var line in mountinfo.split ("\n")) {
                var fields = line.split (" ", 4);
                if (fields.length == 4 && fields[2] == identity) return true;
            }
            return false;
        }
    }
}
