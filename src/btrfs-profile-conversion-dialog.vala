namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-profile-conversion-dialog.ui")]
    internal class BtrfsProfileConversionDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.ComboRow data_row;
        [GtkChild] private unowned Adw.ComboRow metadata_row;
        [GtkChild] private unowned Adw.ActionRow allocation;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ActionRow result_row;
        [GtkChild] private unowned Gtk.ProgressBar progress;
        [GtkChild] private unowned Gtk.Button review_button;
        [GtkChild] private unowned Gtk.Button pause_button;
        [GtkChild] private unowned Gtk.Button resume_button;
        [GtkChild] private unowned Gtk.Button cancel_button;

        private UDisksService backend;
        private StorageBlock block;
        private string identity;
        private BtrfsFilesystemInfo? report;
        private BtrfsConversionStatus? status;
        private BtrfsConversionPlan? pending_review;
        private BtrfsProfileType[] choices = { BtrfsProfileType.UNKNOWN };
        private bool open = true;
        private bool polling;
        private bool reviewing;
        private bool executing;
        private bool controlling;
        private uint timer;

        public BtrfsProfileConversionDialog (UDisksService backend, StorageBlock block) {
            this.backend = backend;
            this.block = block;
            identity = backend.modification_identity (block);
            data_row.notify["selected"].connect (update_controls);
            metadata_row.notify["selected"].connect (update_controls);
            review_button.clicked.connect (() => review.begin (false));
            pause_button.clicked.connect (() => control.begin ("balance-pause"));
            resume_button.clicked.connect (() => review.begin (true));
            cancel_button.clicked.connect (confirm_cancel);
            closed.connect (() => {
                open = false;
                if (pending_review != null) pending_review.release_review ();
                pending_review = null;
                if (timer != 0) Source.remove (timer);
                timer = 0;
            });
            poll.begin (true);
            timer = Timeout.add_seconds (2, () => {
                if (!polling && !controlling) poll.begin (false);
                return Source.CONTINUE;
            });
        }

        private BtrfsProfileType selected (Adw.ComboRow row) {
            return row.selected < choices.length ? choices[row.selected] : BtrfsProfileType.UNKNOWN;
        }

        private string restriction () {
            if (report == null) return "Verified allocation is unavailable.";
            if (block.system_hint) return "This filesystem supports the running system.";
            if (report.read_only || block.read_only) return "This filesystem is read-only.";
            if (report.members.length != report.member_count || report.member_count == 0)
                return "The complete member set could not be verified.";
            foreach (var member in report.members) {
                if (member.has_errors) return "A member reports errors. Review Replace Btrfs Device.";
                if (member.state != "Present" || !member.allocation_known || member.error_counters.length != 5)
                    return "A member is missing, read-only or unverified.";
            }
            foreach (var row in report.profiles)
                if (!row.profile.convertible () || row.kind == BtrfsAllocationKind.MIXED ||
                    row.kind == BtrfsAllocationKind.UNKNOWN)
                    return "Mixed, parity or unknown allocation prevents conversion.";
            return "";
        }

        private bool has_remaining_groups (BtrfsAllocationKind kind, BtrfsProfileType target) {
            if (report == null || target == BtrfsProfileType.UNKNOWN) return false;
            bool matched = false;
            bool remaining = false;
            foreach (var row in report.profiles) {
                if (row.kind != kind) continue;
                if (row.profile == target) matched = true;
                else remaining = true;
            }
            return matched && remaining;
        }

        private void update_controls () {
            bool writable = report != null && !report.read_only && !block.read_only && !block.system_hint;
            bool ready = writable && !reviewing && !executing && !controlling;
            string reason = restriction ();
            bool idle = ready && reason == "" && status?.state == "idle" && report.exclusive_operation == "none";
            review_button.tooltip_text = reason != "" ? reason :
                idle ? "Assess contiguous workspace and redundancy for these targets." :
                "Conversion review requires an idle filesystem with a verified kernel status.";
            data_row.sensitive = metadata_row.sensitive = idle;
            var data = selected (data_row);
            var metadata = selected (metadata_row);
            review_button.sensitive = idle && (data != BtrfsProfileType.UNKNOWN || metadata != BtrfsProfileType.UNKNOWN);
            review_button.label = has_remaining_groups (BtrfsAllocationKind.DATA, data) ||
                has_remaining_groups (BtrfsAllocationKind.METADATA, metadata) ||
                has_remaining_groups (BtrfsAllocationKind.SYSTEM, metadata) ?
                "Review Remaining Conversion" : "Review Conversion";
            pause_button.sensitive = writable && !controlling && status?.state == "running" &&
                (status.kernel_flags & 6) == 0;
            resume_button.sensitive = ready && status?.state == "paused";
            cancel_button.sensitive = writable && !controlling && status != null && status.state != "idle" &&
                (status.kernel_flags & 6) == 0;
        }

        private string allocation_text (BtrfsFilesystemInfo current) {
            var text = new StringBuilder ();
            uint64 physical = 0;
            foreach (var member in current.members)
                physical = member.capacity > uint64.MAX - physical ? uint64.MAX : physical + member.capacity;
            text.append_printf ("%s · %s\n%s members · %s physical capacity · %s estimated usable\n%s · Exclusive operation: %s\n",
                current.label == "" ? "Btrfs" : current.label, current.uuid, current.member_count.to_string (),
                format_size (physical), format_size (current.estimated_available),
                current.read_only ? "Read-only" : "Read-write", current.exclusive_operation);
            foreach (var row in current.profiles)
                text.append_printf ("%s · %s allocated · %s used\n", row.label,
                    format_size (row.allocated), format_size (row.used));
            foreach (var member in current.members)
                text.append_printf ("Device %s · %s · %s\n", member.id.to_string (), member.state,
                    member.allocation_known && member.capacity >= member.allocated ?
                    format_size (member.capacity - member.allocated) + " unallocated" : "Allocation unknown");
            return text.str.strip ();
        }

        private void show_allocation (BtrfsFilesystemInfo current) {
            report = current;
            allocation.subtitle = allocation_text (current);
            var data = selected (data_row);
            var metadata = selected (metadata_row);
            var labels = new Gtk.StringList ({ "Keep current profiles" });
            choices = { BtrfsProfileType.UNKNOWN };
            for (int i = (int) BtrfsProfileType.SINGLE; i <= (int) BtrfsProfileType.RAID6; i++) {
                var candidate = (BtrfsProfileType) i;
                if (candidate.convertible () && candidate.minimum_members () <= current.member_count) {
                    choices += candidate;
                    labels.append (candidate.argument ().up ());
                }
            }
            data_row.model = metadata_row.model = labels;
            data_row.selected = metadata_row.selected = 0;
            for (uint i = 1; i < choices.length; i++) {
                if (choices[i] == data) data_row.selected = i;
                if (choices[i] == metadata) metadata_row.selected = i;
            }
        }

        private async void poll (bool refresh_allocation) {
            if (polling) return;
            polling = true;
            try {
                var current = new BtrfsConversionStatus (yield backend.btrfs_maintenance (
                    block, identity, "balance-convert-status", 0));
                if (!open) return;
                bool refresh = refresh_allocation || report == null || current.state != status?.state ||
                    (current.state != "idle" && current.completed != status?.completed);
                status = current;
                string state = (current.kernel_flags & 4) != 0 ? "Cancellation requested" :
                    (current.kernel_flags & 2) != 0 ? "Pause requested" :
                    current.state == "running" ? "Balance running" :
                    current.state == "paused" ? "Balance paused" : "No active kernel balance";
                status_row.subtitle = "%s · %s moved · %s examined · %s expected\nData: %s · Metadata/system: %s".printf (
                    state, current.completed.to_string (), current.considered.to_string (),
                    current.expected.to_string (), current.data.argument (), current.metadata.argument ());
                progress.visible = current.state != "idle" && current.expected != 0;
                progress.fraction = current.expected == 0 ? 0 :
                    double.min (1, (double) current.considered / current.expected);
                if (refresh) show_allocation (yield backend.query_btrfs_allocation (block));
            } catch (Error error) {
                status = null;
                status_row.subtitle = error.message;
                progress.visible = false;
                if (refresh_allocation) {
                    try { show_allocation (yield backend.query_btrfs_allocation (block)); }
                    catch (Error inspect_error) { allocation.subtitle = inspect_error.message; }
                }
            } finally {
                polling = false;
                if (open) update_controls ();
            }
        }

        private async void review (bool resume) {
            if (reviewing || executing || report == null || status == null) return;
            var data = resume ? status.data : selected (data_row);
            var metadata = resume ? status.metadata : selected (metadata_row);
            reviewing = true;
            update_controls ();
            BtrfsConversionPlan? plan = null;
            try {
                if (!resume || data != BtrfsProfileType.UNKNOWN || metadata != BtrfsProfileType.UNKNOWN)
                    plan = yield backend.review_btrfs_conversion (block, identity, data, metadata, resume);
            } catch (Error error) {
                result_row.subtitle = error.message;
                reviewing = false;
                update_controls ();
                return;
            }
            if (!open) {
                if (plan != null) plan.release_review ();
                return;
            }
            bool reduction = plan?.reduces_redundancy == true;
            string body = resume ?
                "Resume the kernel's saved balance. The helper will reassess a saved conversion before dispatch." :
                "The balance can run for a long time and use substantial I/O. Back up important data before proceeding. " +
                "Cancellation leaves chunks already relocated in their new profiles.";
            if (plan != null) {
                body += "\n\nFilesystem %s\nData → %s\nMetadata and system → %s\n\n%s".printf (
                    plan.reviewed.uuid, data == BtrfsProfileType.UNKNOWN ? "Keep" : data.argument ().up (),
                    metadata == BtrfsProfileType.UNKNOWN ? "Keep" : metadata.argument ().up (),
                    allocation_text (plan.reviewed));
                if (data != BtrfsProfileType.UNKNOWN)
                    body += "\nData placement: " + data.redundancy ();
                if (metadata != BtrfsProfileType.UNKNOWN)
                    body += "\nMetadata/system placement: " + metadata.redundancy ();
                double delta = plan.physical_allocation_delta ();
                if (delta == 0) {
                    body += "\nEstimated physical allocation at current chunk sizes: same copy overhead.";
                } else {
                    body += "\nEstimated physical allocation at current chunk sizes: " +
                        format_size ((uint64) double.min ((double) int64.MAX, delta > 0 ? delta : -delta)) +
                        (delta > 0 ? " more." : " less.");
                }
                body += "\n\nConservative contiguous workspace budget per required member: " + format_size (plan.workspace);
            }
            if (reduction)
                body += "\n\nThis conversion reduces copy count or device failure tolerance. Confirm only after reviewing the risk of data loss.";
            var confirmation = new Adw.AlertDialog (resume ? "Resume Btrfs balance?" :
                reduction ? "Reduce Btrfs redundancy?" : "Convert Btrfs allocation profiles?", body);
            confirmation.add_response ("back", "Go Back");
            confirmation.add_response ("apply", reduction ? "Convert with Reduced Redundancy" :
                resume ? "Resume Balance" : "Convert Profiles");
            confirmation.default_response = confirmation.close_response = "back";
            confirmation.set_response_appearance ("apply", reduction ? Adw.ResponseAppearance.DESTRUCTIVE :
                Adw.ResponseAppearance.SUGGESTED);
            pending_review = plan;
            confirmation.response.connect ((response) => {
                pending_review = null;
                reviewing = false;
                if (open && response == "apply") execute.begin (resume, plan, reduction);
                else if (plan != null) plan.release_review ();
                update_controls ();
            });
            confirmation.present (this);
        }

        private async void execute (bool resume, BtrfsConversionPlan? plan, bool reduction) {
            executing = true;
            update_controls ();
            result_row.subtitle = "Waiting for authorization and the kernel balance result.";
            try {
                result_row.subtitle = yield backend.btrfs_maintenance (block, identity,
                    resume ? "balance-resume" : "balance-convert", 0, plan, reduction);
            } catch (Error error) {
                result_row.subtitle = "Conversion outcome requires review. " + error.message;
            } finally {
                if (plan != null) plan.release_review ();
                executing = false;
                if (open) poll.begin (true);
                update_controls ();
            }
        }

        private void confirm_cancel () {
            var confirmation = new Adw.AlertDialog ("Cancel Btrfs balance?",
                "Chunks already relocated keep their current profiles. Review allocation before starting another conversion.");
            confirmation.add_response ("back", "Keep Monitoring");
            confirmation.add_response ("cancel-balance", "Cancel Balance");
            confirmation.set_response_appearance ("cancel-balance", Adw.ResponseAppearance.DESTRUCTIVE);
            confirmation.close_response = confirmation.default_response = "back";
            confirmation.response.connect ((response) => {
                if (response == "cancel-balance" && open && cancel_button.sensitive)
                    control.begin ("balance-cancel");
            });
            confirmation.present (this);
        }

        private async void control (string action) {
            controlling = true;
            update_controls ();
            try {
                string observed = yield backend.btrfs_maintenance (block, identity, action, 0);
                result_row.subtitle = action == "balance-cancel" ?
                    "Kernel accepted cancellation. Some chunks may already have moved. " + observed : observed;
            } catch (Error error) {
                result_row.subtitle = "Could not confirm the kernel control request. " + error.message;
            } finally {
                controlling = false;
                if (open) poll.begin (true);
                update_controls ();
            }
        }
    }
}
