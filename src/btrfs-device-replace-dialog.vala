namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-device-replace-dialog.ui")]
    internal class BtrfsDeviceReplaceDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.PreferencesGroup selection;
        [GtkChild] private unowned Adw.ComboRow source_row;
        [GtkChild] private unowned Adw.ComboRow target_row;
        [GtkChild] private unowned Adw.SwitchRow avoid_row;
        [GtkChild] private unowned Adw.ActionRow eligibility;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ActionRow outcome;
        [GtkChild] private unowned Gtk.ProgressBar progress;
        [GtkChild] private unowned Gtk.Button review_button;
        [GtkChild] private unowned Gtk.Button cancel_button;

        private UDisksService backend;
        private StorageBlock anchor;
        private string uuid;
        private BtrfsFilesystemInfo? report;
        private BtrfsReplacementStatus? status;
        private StorageBlock[] targets = {};
        private uint64[] target_sequences = {};
        private uint target_generation;
        private bool checking_targets;
        private uint timer;
        private bool open = true;
        private bool checking;
        private bool starting;
        private bool cancelling;
        private bool dispatched;
        private bool populating;

        public BtrfsDeviceReplaceDialog (UDisksService backend, StorageBlock anchor) {
            this.backend = backend;
            this.anchor = anchor;
            uuid = anchor.uuid;
            source_row.notify["selected"].connect (update_targets);
            target_row.notify["selected"].connect (update_controls);
            avoid_row.notify["active"].connect (update_targets);
            review_button.clicked.connect (review);
            cancel_button.clicked.connect (review_cancellation);
            closed.connect (() => {
                open = false;
                if (timer != 0) Source.remove (timer);
                timer = 0;
            });
            inspect.begin ();
            poll.begin ();
            timer = Timeout.add_seconds (2, () => {
                if (!checking && !cancelling) poll.begin ();
                return Source.CONTINUE;
            });
        }

        private string member_name (BtrfsMemberInfo member) {
            foreach (var block in backend.snapshot.blocks.get_values ())
                if (member.number != 0 && block.number == member.number)
                    return "Device ID %s · %s".printf (member.id.to_string (), block.preferred);
            if (member.device_path != "")
                return "Device ID %s · %s".printf (member.id.to_string (), member.device_path);
            return "Device ID %s · %s".printf (member.id.to_string (), member.state);
        }

        private async void inspect () {
            try {
                report = yield backend.query_btrfs_allocation (anchor);
                var labels = new Gtk.StringList (null);
                foreach (var member in report.members)
                    labels.append ("%s · %s · %s capacity · %s allocated%s".printf (member_name (member),
                        member.state, member.allocation_known ? format_size (member.capacity) : "Unknown",
                        member.allocation_known ? format_size (member.allocated) : "Unknown",
                        member.has_errors ? " · Recorded device errors" : ""));
                source_row.model = labels;
                update_targets ();
            } catch (Error error) {
                eligibility.subtitle = error.message;
            }
        }

        private BtrfsMemberInfo? selected_source () {
            return report != null && source_row.selected < report.members.length ?
                report.members[source_row.selected] : null;
        }

        private void update_targets () {
            if (populating) return;
            populating = true;
            target_generation++;
            var source = selected_source ();
            avoid_row.sensitive = source != null && source.number != 0 && report.replacement_restriction (source, true) == "";
            if (!avoid_row.sensitive) avoid_row.active = false;
            targets = {};
            target_sequences = {};
            target_row.model = null;
            checking_targets = source != null && report.replacement_restriction (source, avoid_row.active) == "" &&
                !anchor.system_hint && !anchor.read_only;
            populating = false;
            update_controls ();
            if (checking_targets)
                inspect_targets.begin (report, source, avoid_row.active, target_generation);
        }

        private async void inspect_targets (BtrfsFilesystemInfo current, BtrfsMemberInfo source,
                                            bool avoid, uint generation) {
            StorageBlock[] candidates = {};
            foreach (var candidate in backend.snapshot.blocks.get_values ())
                if (backend.can_target_btrfs_replacement (current, source, candidate)) candidates += candidate;
            var labels = new Gtk.StringList (null);
            foreach (var candidate in candidates) {
                if (!open || target_generation != generation) return;
                try {
                    var sequence = yield backend.check_btrfs_replacement_target (anchor, current, source, candidate, avoid);
                    if (!open || target_generation != generation) return;
                    labels.append ("%s · %s · Whole device · No storage signatures detected".printf (
                        candidate.preferred, format_size (candidate.size)));
                    targets += candidate;
                    target_sequences += sequence;
                } catch (Error error) {}
            }
            if (!open || target_generation != generation) return;
            checking_targets = false;
            target_row.model = labels;
            update_controls ();
        }

        private void update_controls () {
            var source = selected_source ();
            selection.sensitive = !starting && !dispatched && status != null && !status.active && status.state <= 4;
            var restriction = source == null ? "Select a Btrfs source member." :
                report.replacement_restriction (source, avoid_row.active);
            if (anchor.system_hint || anchor.read_only)
                restriction = "This filesystem is protected or read-only.";
            review_button.sensitive = selection.sensitive && restriction == "" && target_row.selected < targets.length;
            if (source != null)
                eligibility.subtitle = restriction != "" ? restriction : checking_targets ?
                    "Checking unused devices and storage signatures." : targets.length == 0 ?
                    "No whole-device target passed the capacity and safety checks." :
                    "Eligible for review. The helper checks the target again before writing.";
            cancel_button.sensitive = !cancelling && status != null && status.active && status.started != 0 &&
                !anchor.system_hint && !anchor.read_only;
        }

        private void show_status (BtrfsReplacementStatus current) {
            bool was_active = status?.active == true;
            status = current;
            status_row.title = current.state_label ();
            var duration = current.started == 0 ? 0 :
                int64.max (0, (current.stopped != 0 ? (int64) current.stopped :
                    new DateTime.now_utc ().to_unix ()) - (int64) current.started);
            status_row.subtitle = current.state == 0 ? "No replacement has been recorded for this filesystem." :
                "%s seconds · %s uncorrectable read errors · %s write errors".printf (
                    duration.to_string (), current.read_errors.to_string (), current.write_errors.to_string ());
            progress.visible = current.active;
            progress.fraction = current.progress_1000 / 1000.0;
            progress.text = "%.1f%%".printf (current.progress_1000 / 10.0);
            if (!dispatched && current.state == 2) {
                outcome.visible = true;
                outcome.subtitle = current.completion_message ();
            }
            update_controls ();
            if (was_active && !current.active && !dispatched)
                inspect.begin ();
        }

        private async void poll () {
            checking = true;
            try {
                var current = yield backend.btrfs_replacement_status (uuid);
                if (open) show_status (current);
            } catch (Error error) {
                if (open) {
                    status = null;
                    status_row.title = "Replacement status unavailable";
                    status_row.subtitle = error.message;
                    progress.visible = false;
                    update_controls ();
                }
            } finally {
                checking = false;
            }
        }

        private void review () {
            var source = selected_source ();
            if (!review_button.sensitive || source == null || target_row.selected >= targets.length) return;
            var target = targets[target_row.selected];
            bool avoid = avoid_row.active;
            string anchor_identity = backend.modification_identity (anchor);
            string identity = backend.modification_identity (target);
            uint64 sequence = target_sequences[target_row.selected];
            var profiles = new StringBuilder ();
            foreach (var profile in report.profiles) profiles.append (profile.label + "\n");
            string body = "Filesystem %s · %s\nSource %s · %s\nTarget %s · %s\n\n%s\n%s\n\nThe replacement overwrites the target. Existing storage signatures prevent replacement. Larger targets may require a separate Btrfs resize.".printf (
                uuid, report.label, member_name (source), format_size (source.capacity), target.preferred,
                format_size (target.size), profiles.str, source.number == 0 ?
                "The kernel will reconstruct the missing member from surviving RAID 1 copies. While degraded, the kernel may allocate new chunks with fewer copies. Review the resulting profiles." : avoid ?
                "The kernel will prefer surviving RAID 1 copies where possible." : "The kernel will read from the selected source.");
            var confirmation = new Adw.AlertDialog ("Replace this Btrfs member?", body);
            confirmation.add_response ("back", "Go Back");
            confirmation.add_response ("replace", "Replace Device");
            confirmation.set_response_appearance ("replace", Adw.ResponseAppearance.DESTRUCTIVE);
            confirmation.default_response = "back";
            confirmation.close_response = "back";
            confirmation.response.connect ((response) => {
                if (response == "replace" && open && !starting && !dispatched)
                    run.begin (source, target, anchor_identity, identity, sequence, avoid);
            });
            confirmation.present (this);
        }

        private async void run (BtrfsMemberInfo source, StorageBlock target, string anchor_identity,
                                string identity, uint64 sequence, bool avoid) {
            starting = dispatched = true;
            outcome.visible = true;
            outcome.subtitle = "%s → %s · Awaiting authorization and kernel result".printf (member_name (source), target.preferred);
            update_controls ();
            try {
                var current = yield backend.replace_btrfs_device (anchor, anchor_identity, report, source,
                    target, identity, sequence, avoid);
                show_status (current);
                outcome.subtitle = current.completion_message ();
            } catch (Error error) {
                outcome.subtitle = "Completion could not be verified. " + error.message;
            } finally {
                starting = false;
                update_controls ();
            }
        }

        private void review_cancellation () {
            if (!cancel_button.sensitive || status == null) return;
            uint64 started = status.started;
            var confirmation = new Adw.AlertDialog ("Cancel Btrfs replacement?",
                "Majoris will request cancellation of the operation shown here and check the resulting kernel state.");
            confirmation.add_response ("keep", "Keep Monitoring");
            confirmation.add_response ("cancel-replacement", "Cancel Replacement");
            confirmation.set_response_appearance ("cancel-replacement", Adw.ResponseAppearance.DESTRUCTIVE);
            confirmation.close_response = "keep";
            confirmation.default_response = "keep";
            confirmation.response.connect ((response) => {
                if (response == "cancel-replacement" && !cancelling) cancel.begin (started);
            });
            confirmation.present (this);
        }

        private async void cancel (uint64 started) {
            cancelling = true;
            update_controls ();
            try {
                show_status (yield backend.btrfs_replacement_status (uuid, started));
            } catch (Error error) {
                outcome.visible = true;
                outcome.subtitle = "Cancellation could not be confirmed. " + error.message;
            } finally {
                cancelling = false;
                update_controls ();
            }
        }
    }
}
