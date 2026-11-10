namespace MajorisDisks {
    internal enum BtrfsScrubMode { UNKNOWN, READ_ONLY, REPAIR_ENABLED }

    internal enum BtrfsScrubState {
        NEVER_RUN, STARTING, RUNNING, CANCELLED, INTERRUPTED, RESUMABLE,
        CLEAN, CORRECTED, RECOVERABLE, UNCORRECTABLE, UNVERIFIED, FAILED, UNKNOWN
    }

    internal class BtrfsScrubDeviceStatus : Object {
        public uint64 id;
        public string path;
        public string state;
        public uint64 duration;
        public string[] counters = {};
        public string[] health = {};

        public BtrfsScrubDeviceStatus (string line) throws IOError {
            var fields = line.split (" ");
            if (fields.length != 24 || fields[0] != "device" ||
                !uint64.try_parse (fields[1], out id) || id == 0 ||
                !uint64.try_parse (fields[4], out duration))
                throw new IOError.INVALID_DATA ("Invalid Btrfs scrub member report.");
            path = Uri.unescape_string (fields[2]) ?? "";
            state = fields[3];
            for (int i = 5; i < fields.length; i++) {
                uint64 parsed;
                if (fields[i] != "-" && !uint64.try_parse (fields[i], out parsed))
                    throw new IOError.INVALID_DATA ("Invalid Btrfs scrub counter.");
                if (i < 19) counters += fields[i];
                else health += fields[i];
            }
        }

        public static string counter_label (int index, BtrfsScrubMode mode) {
            if (index == 12 && mode != BtrfsScrubMode.REPAIR_ENABLED)
                return mode == BtrfsScrubMode.READ_ONLY ? "Recoverable errors" : "Kernel corrected counter (mode unknown)";
            return new string[] { "Data extents", "Metadata extents", "Data bytes", "Metadata bytes",
                "Read errors", "Checksum errors", "Metadata verification errors", "Extents without checksums",
                "Checksum discards", "Superblock errors", "Allocation failures", "Uncorrectable errors",
                "Corrected errors", "Unverified errors" }[index];
        }

        public string description (BtrfsScrubMode mode) {
            var result = new StringBuilder ();
            if (state == "unavailable") result.append ("No scrub counters for this member.");
            else result.append_printf ("%s · %s s", state, duration.to_string ());
            for (int i = 0; i < counters.length; i++)
                result.append_printf ("\n%s  %s", counter_label (i, mode), counters[i] == "-" ? "Unavailable" : counters[i]);
            result.append_printf ("\nLifetime Btrfs device counters\nWrites %s · Reads %s · Flushes %s · Corruption %s · Generation %s",
                health[0], health[1], health[2], health[3], health[4]);
            return result.str;
        }
    }

    internal class BtrfsScrubReport : Object {
        public BtrfsScrubState state;
        public BtrfsScrubMode mode;
        public string review = "";
        public uint64 started;
        public uint64 ended;
        public string filesystem = "";
        public string session = "";
        public uint64 scope;
        public bool resumable;
        public bool start_available;
        public bool repair_available;
        public BtrfsScrubDeviceStatus[] devices = {};

        public BtrfsScrubReport (string report) throws IOError {
            var lines = report.strip ().split ("\n");
            var fields = lines[0].split (" ");
            if (fields.length != 6 || !uint64.try_parse (fields[2], out started) ||
                !uint64.try_parse (fields[3], out scope) || !(fields[4] in new string[] { "0", "1" }) ||
                !(fields[5] in new string[] { "0", "1" }))
                throw new IOError.INVALID_DATA ("Invalid Btrfs scrub status.");
            switch (fields[0]) {
            case "never-run": state = BtrfsScrubState.NEVER_RUN; break;
            case "starting": state = BtrfsScrubState.STARTING; break;
            case "running": state = BtrfsScrubState.RUNNING; break;
            case "cancelled": state = BtrfsScrubState.CANCELLED; break;
            case "interrupted": state = BtrfsScrubState.INTERRUPTED; break;
            case "resumable": state = BtrfsScrubState.RESUMABLE; break;
            case "clean": state = BtrfsScrubState.CLEAN; break;
            case "corrected": state = BtrfsScrubState.CORRECTED; break;
            case "recoverable": state = BtrfsScrubState.RECOVERABLE; break;
            case "uncorrectable": state = BtrfsScrubState.UNCORRECTABLE; break;
            case "unverified": state = BtrfsScrubState.UNVERIFIED; break;
            case "failed": state = BtrfsScrubState.FAILED; break;
            case "unknown": state = BtrfsScrubState.UNKNOWN; break;
            default: throw new IOError.INVALID_DATA ("Unknown Btrfs scrub state.");
            }
            mode = fields[1] == "readonly" ? BtrfsScrubMode.READ_ONLY :
                fields[1] == "repair" ? BtrfsScrubMode.REPAIR_ENABLED : BtrfsScrubMode.UNKNOWN;
            resumable = fields[4] == "1";
            repair_available = fields[5] == "1";
            for (int i = 1; i < lines.length; i++) {
                if (lines[i].has_prefix ("review ")) {
                    var review_fields = lines[i].split (" ");
                    if (review_fields.length != 3 || !(review_fields[2] in new string[] { "0", "1" }))
                        throw new IOError.INVALID_DATA ("Invalid Btrfs scrub review.");
                    review = review_fields[1];
                    start_available = review_fields[2] == "1";
                    continue;
                }
                if (lines[i].has_prefix ("record ")) {
                    var record = lines[i].split (" ");
                    if (record.length != 4 || !Uuid.string_is_valid (record[1]) ||
                        !Uuid.string_is_valid (record[2]) || !uint64.try_parse (record[3], out ended) ||
                        ended < started)
                        throw new IOError.INVALID_DATA ("Invalid scrub history metadata.");
                    filesystem = record[1];
                    session = record[2];
                    continue;
                }
                var device = new BtrfsScrubDeviceStatus (lines[i]);
                foreach (var current in devices)
                    if (current.id == device.id) throw new IOError.INVALID_DATA ("Duplicate Btrfs scrub member.");
                devices += device;
            }
        }

        public bool active () { return state == BtrfsScrubState.RUNNING || state == BtrfsScrubState.STARTING; }

        public string summary () {
            switch (state) {
            case BtrfsScrubState.NEVER_RUN: return "No verified Majoris scrub has been recorded.";
            case BtrfsScrubState.STARTING: return "Starting or finalizing scrub.";
            case BtrfsScrubState.RUNNING: return "The kernel reports an active scrub.";
            case BtrfsScrubState.CANCELLED: return "The kernel accepted cancellation and the scrub stopped.";
            case BtrfsScrubState.INTERRUPTED: return "The scrub stopped before completing.";
            case BtrfsScrubState.RESUMABLE: return "An interrupted scrub can be resumed.";
            case BtrfsScrubState.CLEAN: return "Scrub completed. No errors were detected.";
            case BtrfsScrubState.CORRECTED: return "Scrub completed. Some errors were corrected using valid redundant copies.";
            case BtrfsScrubState.RECOVERABLE: return "Read-only scrub found damaged copies with usable alternate copies.";
            case BtrfsScrubState.UNCORRECTABLE:
                return "Scrub completed with uncorrectable errors. Some data or metadata could not be repaired.";
            case BtrfsScrubState.UNVERIFIED: return "Scrub completed with errors or unavailable verification counters.";
            case BtrfsScrubState.FAILED: return "The scrub backend reported a failure.";
            default: return "The scrub result could not be verified.";
            }
        }

        public string session_label () {
            if (started == 0 || started > get_real_time () / TimeSpan.SECOND) return "";
            var time = new DateTime.from_unix_local ((int64) started);
            string target = scope == 0 ? "Entire filesystem" : "Device ID %s".printf (scope.to_string ());
            string type = mode == BtrfsScrubMode.REPAIR_ENABLED ? "Repair-enabled" :
                mode == BtrfsScrubMode.READ_ONLY ? "Read-only" : "Unknown mode";
            string label = "%s · %s · %s".printf (time.format ("%c"), type, target);
            if (ended >= started) label += " · %s s elapsed".printf ((ended - started).to_string ());
            else if (active ()) label += " · %s s elapsed".printf (
                ((uint64) (get_real_time () / TimeSpan.SECOND) - started).to_string ());
            return label;
        }

        public string progress_label () {
            uint64 bytes = 0;
            bool observed = false;
            foreach (var member in devices) {
                if (member.state != "running") continue;
                for (int i = 2; i <= 3; i++) {
                    uint64 value;
                    if (!uint64.try_parse (member.counters[i], out value) || value > uint64.MAX - bytes)
                        return "Scrubbing Btrfs members";
                    bytes += value;
                    observed = true;
                }
            }
            return observed ? "%s processed on active members".printf (format_size (bytes)) : "Scrubbing Btrfs members";
        }

        public string aggregate () {
            var text = new StringBuilder ();
            for (int i = 0; i < 14; i++) {
                uint64 total = 0;
                bool known = false;
                bool partial = false;
                foreach (var device in devices) {
                    if (scope != 0 && device.id != scope) continue;
                    uint64 value;
                    if (!uint64.try_parse (device.counters[i], out value)) { partial = true; continue; }
                    known = true;
                    if (value > uint64.MAX - total) { known = false; break; }
                    total += value;
                }
                if (known) text.append_printf ("%s  %s%s\n", BtrfsScrubDeviceStatus.counter_label (i, mode),
                    total.to_string (), partial ? " (partial)" : "");
            }
            return text.str.strip ();
        }
    }
}
