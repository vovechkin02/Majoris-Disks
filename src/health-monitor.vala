namespace MajorisDisks {
    internal class DriveHealth {
        public static string identity (StorageDrive drive) {
            if (drive.wwn != "") return "wwn:" + drive.wwn;
            if (drive.serial != "") return "serial:" + drive.vendor + ":" + drive.model + ":" + drive.serial;
            return "session:" + drive.path;
        }

        public static bool has_current_data (StorageDrive drive) {
            if (drive.smart_updated == 0) return false;
            return drive.nvme_state != "" ? drive.nvme_state == "live" : drive.smart && drive.smart_enabled;
        }

        public static string problem (StorageDrive drive, bool warnings, bool critical, bool selftests,
            out bool urgent) {
            urgent = false;
            if (!has_current_data (drive)) return "";
            bool nvme = drive.nvme_state != "";
            string[] problems = {};
            if (critical && (drive.smart_failing || drive.smart_attributes_failing > 0 ||
                (nvme && drive.nvme_warnings.length != 0))) {
                urgent = true;
                if (nvme) {
                    string[] reasons = drive.nvme_warnings.copy ();
                    var sorted = new GenericArray<string> ();
                    foreach (var reason in reasons) sorted.add (reason);
                    sorted.sort (strcmp);
                    for (uint i = 0; i < sorted.length; i++) reasons[i] = sorted[i];
                    problems += "NVMe critical warnings: " + string.joinv (", ", reasons);
                } else problems += "SMART reports a drive failure or a failing attribute.";
            }
            if (warnings && (drive.smart_attributes_failed_past > 0 || drive.smart_bad_sectors > 0))
                problems += "SMART reports bad sectors or previously failing attributes.";
            string state = drive.smart_selftest_status;
            if (selftests && (state.has_prefix ("error_") || state.has_prefix ("error-") ||
                state.has_prefix ("failed") || state.has_suffix ("_seg_fail") || state == "fatal_error"))
                problems += "The latest drive self-test reported a failure.";
            return string.joinv ("\n", problems);
        }
    }

    internal Settings? health_settings () {
        var source = SettingsSchemaSource.get_default ();
        var schema = source?.lookup ("com.majoris.disks.health", true);
        return schema == null ? null : new Settings.full (schema, null, null);
    }
}
