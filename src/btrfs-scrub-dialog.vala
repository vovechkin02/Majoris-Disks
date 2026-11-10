namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-scrub-dialog.ui")]
    internal class BtrfsScrubDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.ComboRow mode_row;
        [GtkChild] private unowned Adw.ComboRow scope_row;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ActionRow allocation_row;
        [GtkChild] private unowned Adw.PreferencesGroup devices_group;
        [GtkChild] private unowned Adw.PreferencesGroup history_group;
        [GtkChild] private unowned Gtk.Button start_button;
        [GtkChild] private unowned Gtk.Button cancel_button;
        [GtkChild] private unowned Gtk.Button resume_button;
        [GtkChild] private unowned Gtk.Button refresh_button;

        private UDisksService backend;
        private StorageBlock block;
        private string identity;
        private BtrfsScrubReport? current;
        private Gtk.Widget[] device_rows = {};
        private Gtk.Widget[] history_rows = {};
        private uint64[] scopes = {};
        private bool polling;
        private bool repair_health_ok;
        private bool dispatching;
        private bool cancelling;
        private bool open = true;
        private uint timer;
        private string operation_message = "";

        public BtrfsScrubDialog (UDisksService backend, StorageBlock block) {
            this.backend = backend;
            this.block = block;
            identity = backend.modification_identity (block);
            status_row.title = block.uuid;
            mode_row.notify["selected"].connect (controls);
            scope_row.notify["selected"].connect (controls);
            start_button.clicked.connect (() => confirm (mode_row.selected == 1 ? "scrub-repair" : "scrub-readonly"));
            cancel_button.clicked.connect (() => confirm ("scrub-cancel"));
            resume_button.clicked.connect (() => confirm ("scrub-resume"));
            refresh_button.clicked.connect (() => poll.begin (true));
            closed.connect (() => {
                open = false;
                if (timer != 0) Source.remove (timer);
                timer = 0;
            });
            poll.begin (true);
            timer = Timeout.add_seconds (2, () => {
                poll.begin (false);
                return Source.CONTINUE;
            });
        }

        private void controls () {
            bool idle = current != null && !current.active () && !dispatching && !cancelling && !block.system_hint;
            idle = idle && current.review.length == 64;
            mode_row.sensitive = scope_row.sensitive = idle;
            bool repair_ready = current != null && current.repair_available && repair_health_ok;
            start_button.sensitive = idle && current.start_available && scope_row.selected < scopes.length &&
                (mode_row.selected == 0 || repair_ready);
            start_button.tooltip_text = mode_row.selected == 1 && !repair_ready ?
                "Repair requires a verified writable mount, supported profiles and eligible member health." : null;
            cancel_button.sensitive = !block.system_hint && !cancelling && current?.state == BtrfsScrubState.RUNNING && current.review.length == 64;
            resume_button.sensitive = idle && current.resumable &&
                (current.mode != BtrfsScrubMode.REPAIR_ENABLED || repair_health_ok);
        }

        private void show_current (BtrfsScrubReport report) {
            var options = new Gtk.StringList ({ "Entire filesystem" });
            uint64 previous = scope_row.selected < scopes.length ? scopes[scope_row.selected] : 0;
            scopes = { 0 };
            uint selection = 0;
            foreach (var row in device_rows) devices_group.remove (row);
            device_rows = {};
            repair_health_ok = true;
            foreach (var member in report.devices) {
                string title = "Device ID %s · %s".printf (member.id.to_string (), member.path);
                options.append (title);
                if (previous == member.id) selection = scopes.length;
                scopes += member.id;
                string health = "SMART/NVMe health unavailable";
                foreach (var candidate in backend.snapshot.blocks.get_values ()) {
                    if (candidate.uuid != block.uuid || candidate.device != member.path || !candidate.available) continue;
                    var drive = candidate.physical_drive;
                    if (drive?.smart_failing == true) {
                        health = "SMART reports failing health";
                        repair_health_ok = false;
                    } else if (drive != null && drive.nvme_warnings.length > 0) {
                        health = "NVMe warnings · " + string.joinv (", ", drive.nvme_warnings);
                        repair_health_ok = false;
                    } else if (drive != null && drive.smart_updated > 0) {
                        health = "SMART reports no failing status";
                    }
                    break;
                }
                var row = new Adw.ActionRow () { use_markup = false, title = title,
                    subtitle = member.description (report.mode) + "\n" + health };
                devices_group.add (row);
                device_rows += row;
            }
            scope_row.model = options;
            scope_row.selected = selection;
            string session = report.session_label ();
            string aggregate = report.aggregate ();
            string summary = report.summary ();
            if (report.ended > 0 && !report.active ())
                summary = "Latest recorded result · " + summary;
            status_row.subtitle = summary + (session == "" ? "" : "\n" + session) +
                (report.start_available ? "" : "\nStarting a scrub is unavailable for this filesystem or backend.") +
                (aggregate == "" ? "" : "\nAggregate member counters\n" + aggregate) +
                (operation_message == "" ? "" : "\n" + operation_message);
        }

        private async void poll (bool full) {
            if (polling || !open) return;
            polling = true;
            try {
                var report = new BtrfsScrubReport (yield backend.btrfs_scrub (block, identity, "scrub-status"));
                if (!open) return;
                bool terminal = current?.active () == true && !report.active ();
                current = report;
                show_current (report);
                if (full || terminal) {
                    string history = yield backend.btrfs_scrub (block, identity, "scrub-history");
                    if (!open) return;
                    foreach (var row in history_rows) history_group.remove (row);
                    history_rows = {};
                    foreach (string entry in history.strip ().split ("\n\n")) {
                        if (entry == "") continue;
                        var saved = new BtrfsScrubReport (entry);
                        var row = new Adw.ExpanderRow () { use_markup = false, title = saved.summary (),
                            subtitle = saved.session_label () };
                        foreach (var member in saved.devices) {
                            if (saved.scope != 0 && saved.scope != member.id) continue;
                            row.add_row (new Adw.ActionRow () { use_markup = false,
                                title = "Device ID " + member.id.to_string (), subtitle = member.description (saved.mode) });
                        }
                        history_group.add (row);
                        history_rows += row;
                    }
                    history_group.description = history_rows.length == 0 ? "No previous scrub results available." :
                        "Saved outcomes for this verified member set.";
                    var allocation = yield backend.query_btrfs_allocation (block);
                    if (!open) return;
                    var profiles = new StringBuilder ();
                    foreach (var row in allocation.profiles) profiles.append (row.label + "\n");
                    allocation_row.subtitle = (allocation.label == "" ? "Btrfs" : allocation.label) +
                        "\n" + profiles.str.strip ();
                }
            } catch (Error error) {
                if (open) {
                    current = null;
                    status_row.subtitle = error.message;
                }
            } finally {
                polling = false;
                if (open) controls ();
            }
        }

        private void confirm (string action) {
            if (current == null || scope_row.selected >= scopes.length) return;
            uint64 scope = scopes[scope_row.selected];
            string review = current.review;
            bool cancel = action == "scrub-cancel";
            bool resume = action == "scrub-resume";
            bool repair = action == "scrub-repair" || (resume && current.mode == BtrfsScrubMode.REPAIR_ENABLED);
            string body = cancel ? "Cancel the active scrub across this filesystem, including any members started outside Majoris." :
                repair ? "Scrub may write corrected data or metadata when a verified good copy exists. Unchecksummed file data may be unverifiable." :
                "Scrub repair is disabled. A writable Btrfs mount can still perform internal writes.";
            if (resume) body += "\nResume the saved mode and scope from the verified checkpoint.";
            else if (!cancel) body += scope == 0 ? "\nScope: Entire filesystem." : "\nScope: Device ID " + scope.to_string () + ".";
            var dialog = new Adw.AlertDialog (cancel ? "Cancel Btrfs Scrub?" : resume ? "Resume Btrfs Scrub?" : "Start Btrfs Scrub?", body);
            dialog.add_response ("close", "Back");
            dialog.add_response ("apply", cancel ? "Cancel Scrub" : resume ? "Resume" : "Start");
            dialog.set_response_appearance ("apply", cancel || repair ? Adw.ResponseAppearance.DESTRUCTIVE :
                Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "close";
            dialog.response.connect ((response) => { if (response == "apply" && open) run.begin (action, scope, review); });
            dialog.present (this);
        }

        private async void run (string action, uint64 scope, string review) {
            bool cancel = action == "scrub-cancel";
            if (cancel ? cancelling : dispatching) return;
            if (cancel) cancelling = true;
            else dispatching = true;
            operation_message = cancel ? "Cancellation requested. Waiting for kernel acknowledgement." :
                "Preparing the scrub request.";
            if (current != null) show_current (current);
            controls ();
            try {
                var result = new BtrfsScrubReport (yield backend.btrfs_scrub (block, identity, action, scope, review));
                operation_message = result.summary ();
            } catch (Error error) {
                operation_message = error.message;
            } finally {
                if (cancel) cancelling = false;
                else dispatching = false;
                if (open) poll.begin (true);
            }
        }
    }
}
