namespace MajorisDisks {
    internal class HealthMonitor : GLib.Application {
        private UDisksService backend = new UDisksService ();
        private Settings? preferences;
        private KeyFile previous = new KeyFile ();
        private HashTable<string, string> transient = new HashTable<string, string> (str_hash, str_equal);
        private string state_path = Path.build_filename (Environment.get_user_state_dir (), "majoris-disks", "health.ini");

        public HealthMonitor () {
            Object (application_id: "com.majoris.disks.HealthMonitor");
            var open = new SimpleAction ("open-drive", VariantType.STRING);
            open.activate.connect ((value) => {
                try {
                    string binary = Path.build_filename (Path.get_dirname (FileUtils.read_link ("/proc/self/exe")), "majoris-disks");
                    new Subprocess.newv ({ binary, "--drive=" + value.get_string () }, SubprocessFlags.NONE);
                } catch (Error error) { warning ("Could not open Disks: %s", error.message); }
            });
            add_action (open);
        }

        protected override void startup () {
            base.startup ();
            hold ();
            preferences = health_settings ();
            if (preferences != null) preferences.changed.connect (() => evaluate ());
            try { previous.load_from_file (state_path, KeyFileFlags.NONE); }
            catch (Error error) {
                if (!(error is FileError.NOENT)) warning ("Could not load health history: %s", error.message);
            }
            backend.changed.connect (evaluate);
            refresh ();
            Timeout.add_seconds (300, () => { refresh (); return Source.CONTINUE; });
        }

        protected override void activate () {}

        private void refresh () {
            backend.refresh.begin ((object, result) => {
                try { backend.refresh.end (result); }
                catch (Error error) { debug ("Storage health refresh unavailable: %s", error.message); }
            });
        }

        private void evaluate () {
            if (!backend.available ()) return;
            var present = new HashTable<string, string> (str_hash, str_equal);
            bool dirty = false;
            foreach (var drive in backend.snapshot.drives.get_values ()) {
                string identity = DriveHealth.identity (drive);
                bool stable = !identity.has_prefix ("session:");
                string id = Checksum.compute_for_string (ChecksumType.SHA256, identity);
                present.insert (id, id);
                if (!DriveHealth.has_current_data (drive)) continue;
                bool urgent;
                string problem = DriveHealth.problem (drive, preferences?.get_boolean ("warnings") ?? true,
                    preferences?.get_boolean ("critical") ?? true, preferences?.get_boolean ("self-tests") ?? true,
                    out urgent);
                string last = transient.lookup (id) ?? "";
                if (stable) {
                    try { last = previous.get_string ("warnings", id); } catch (Error error) {}
                }
                if (problem == last) continue;
                if (problem == "") withdraw_notification (id);
                else {
                    var notification = new Notification (drive.name + " · Drive health");
                    notification.set_body (problem);
                    notification.set_icon (new ThemedIcon ("drive-harddisk-symbolic"));
                    notification.set_priority (urgent ? NotificationPriority.URGENT : NotificationPriority.HIGH);
                    notification.set_default_action_and_target_value ("app.open-drive", new Variant.string (identity));
                    notification.add_button_with_target_value ("Open Disks", "app.open-drive", new Variant.string (identity));
                    send_notification (id, notification);
                }
                if (stable) {
                    previous.set_string ("warnings", id, problem);
                    dirty = true;
                } else transient.insert (id, problem);
            }
            foreach (var id in transient.get_keys ()) {
                if (present.contains (id)) continue;
                withdraw_notification (id);
                transient.remove (id);
            }
            try {
                foreach (var id in previous.get_keys ("warnings")) {
                    if (present.contains (id)) continue;
                    withdraw_notification (id);
                    previous.remove_key ("warnings", id);
                    dirty = true;
                }
            } catch (KeyFileError error) {}
            if (dirty && DirUtils.create_with_parents (Path.get_dirname (state_path), 0700) == 0) {
                try { previous.save_to_file (state_path); }
                catch (Error error) { warning ("Could not save health history: %s", error.message); }
            }
        }
    }

    public static int main (string[] args) {
        return new HealthMonitor ().run (args);
    }
}
