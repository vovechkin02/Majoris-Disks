namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-quota-dialog.ui")]
    internal class BtrfsQuotaDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ActionRow feedback;
        [GtkChild] private unowned Gtk.Button refresh_button;
        [GtkChild] private unowned Adw.ComboRow filesystem_action;
        [GtkChild] private unowned Gtk.Button review_filesystem;
        [GtkChild] private unowned Adw.ComboRow group_picker;
        [GtkChild] private unowned Adw.ActionRow usage;
        [GtkChild] private unowned Adw.ActionRow hierarchy;
        [GtkChild] private unowned Adw.ComboRow group_action;
        [GtkChild] private unowned Gtk.Button review_group;
        [GtkChild] private unowned Adw.EntryRow target;
        private UDisksService backend;
        private StorageBlock block;
        private string identity;
        private BtrfsQuotaStatus? status;
        private BtrfsSubvolumeList? subvolumes;
        private string[] filesystem_actions = {};
        private string[] group_actions = {};
        private uint64 selected_id;
        private bool busy;
        private bool done;
        private uint refresh_source;

        public BtrfsQuotaDialog (UDisksService backend, StorageBlock block, uint64 selected_id = 0) {
            this.backend = backend;
            this.block = block;
            this.selected_id = selected_id;
            identity = backend.modification_identity (block);
            refresh_button.clicked.connect (() => refresh.begin ());
            group_picker.notify["selected"].connect (() => update_group ());
            group_action.notify["selected"].connect (() => update_target ());
            target.changed.connect (() => update_target ());
            review_filesystem.clicked.connect (review_mode);
            review_group.clicked.connect (review_selected_group);
            closed.connect (() => {
                done = true;
                if (refresh_source != 0) Source.remove (refresh_source);
            });
            refresh_source = Timeout.add_seconds (3, () => {
                if (status?.running == true) refresh.begin ();
                return Source.CONTINUE;
            });
            refresh.begin ();
        }

        private async void refresh () {
            if (busy || done) return;
            busy = true;
            update_actions ();
            try {
                status = yield backend.query_btrfs_quota (block, identity);
                if (subvolumes == null) {
                    try { subvolumes = yield backend.list_btrfs_subvolumes (block, false); }
                    catch (Error error) {}
                }
            } catch (Error error) {
                status = null;
                status_row.subtitle = error.message;
            }
            busy = false;
            render ();
        }

        private void render () {
            status_row.title = status?.mode_label () ?? "Quota state unknown";
            if (status != null) {
                status_row.subtitle = "%s · %u qgroups\n%s".printf (status.uuid, status.groups.length,
                    status.accounting_label ());
                if (status.mode == BtrfsQuotaMode.SIMPLE)
                    status_row.subtitle += "\nExtents are attributed to the first allocating subvolume.";
                if (status.mode == BtrfsQuotaMode.DISABLED && !status.supports_simple)
                    status_row.subtitle += "\nThis kernel does not advertise simple quotas.";
                if (!status.writable || block.read_only || block.system_hint)
                    status_row.subtitle += "\nThis filesystem is read-only or protected.";
            }
            var labels = new Gtk.StringList (null);
            uint selected = selected_id == 0 ? 0 : Gtk.INVALID_LIST_POSITION;
            if (status != null) {
                var names = new HashTable<uint64?, string> (int64_hash, int64_equal);
                foreach (var entry in subvolumes?.entries ?? new BtrfsSubvolume[0])
                    names.insert (entry.id, entry.path + (entry.snapshot ? " (snapshot)" : ""));
                for (uint i = 0; i < status.groups.length; i++) {
                    var group = status.groups[i];
                    var name = group.id == 5 ? "Top-level subvolume" : names.lookup (group.id);
                    labels.append (group.name + (group.stale ? " · Deleted subvolume" :
                        name != null ? " · " + name : ""));
                    if (group.id == selected_id) selected = i;
                }
            }
            uint64 preferred = selected_id;
            group_picker.model = labels;
            selected_id = preferred;
            group_picker.selected = selected;
            update_actions ();
        }

        private unowned BtrfsQgroup? selected_group () {
            if (status == null || group_picker.selected >= status.groups.length) return null;
            return status.groups[group_picker.selected];
        }

        private bool writable () {
            return !busy && status != null && status.writable && !status.running && !block.read_only && !block.system_hint;
        }

        private void update_actions () {
            refresh_button.sensitive = !busy;
            var labels = new Gtk.StringList (null);
            filesystem_actions = {};
            if (writable ()) {
                if (status.mode == BtrfsQuotaMode.DISABLED) {
                    labels.append ("Enable Traditional Qgroups");
                    filesystem_actions += "quota-enable";
                    if (status.supports_simple) {
                        labels.append ("Enable Simple Quotas");
                        filesystem_actions += "quota-enable-simple";
                    }
                } else {
                    labels.append ("Disable Quotas");
                    filesystem_actions += "quota-disable";
                    if (status.mode == BtrfsQuotaMode.QGROUP) {
                        labels.append ("Start Rescan");
                        filesystem_actions += "quota-rescan-start";
                    }
                }
            }
            filesystem_action.model = labels;
            filesystem_action.visible = filesystem_actions.length > 0;
            update_group ();
        }

        private string names (uint64[] ids) {
            string[] labels = {};
            foreach (uint64 id in ids) labels += BtrfsQgroup.format_id (id);
            return labels.length == 0 ? "None" : string.joinv (", ", labels);
        }

        private void update_group () {
            var group = selected_group ();
            if (group != null) selected_id = group.id;
            bool simple = status?.mode == BtrfsQuotaMode.SIMPLE;
            usage.subtitle = group == null ? (selected_id != 0 && status != null ?
                "No qgroup found for the requested selection." : "No qgroup selected") :
                (simple ? "First-owner usage" : "Referenced") + " %s B · limit %s".printf (
                    group.referenced.to_string (), group.limit (false));
            if (group != null && !simple)
                usage.subtitle += "\nExclusive %s B · limit %s".printf (group.exclusive.to_string (), group.limit (true));
            hierarchy.subtitle = group == null ? "" : "Parents · %s\nChildren · %s".printf (
                names (group.parents), names (group.children));
            var labels = new Gtk.StringList (null);
            group_actions = {};
            if (writable () && status.mode == BtrfsQuotaMode.QGROUP) {
                labels.append ("Create Higher-Level Qgroup");
                group_actions += "qgroup-create";
                if (group != null) {
                    if (!group.stale) {
                        labels.append ("Assign to Parent");
                        group_actions += "qgroup-assign";
                    }
                    if (group.parents.length != 0) {
                        labels.append ("Remove Parent Assignment");
                        group_actions += "qgroup-unassign";
                    }
                    if (!status.inconsistent && (group.level > 0 ||
                        (group.stale && group.referenced == 0 && group.exclusive == 0)) &&
                        group.parents.length == 0 && group.children.length == 0 && (group.flags & 3) == 0) {
                        labels.append ("Delete Qgroup");
                        group_actions += "qgroup-delete";
                    }
                }
            }
            if (writable () && group != null && (!simple || group.level == 0)) {
                if ((!group.stale && !status.inconsistent) || (group.flags & 1) != 0) {
                    labels.append (simple ? "Edit First-Owner Limit" : "Edit Referenced Limit");
                    group_actions += "qgroup-referenced-limit";
                }
                if (!simple && ((!group.stale && !status.inconsistent) || (group.flags & 2) != 0)) {
                    labels.append ("Edit Exclusive Limit");
                    group_actions += "qgroup-exclusive-limit";
                }
            }
            group_action.model = labels;
            group_action.visible = group_actions.length > 0;
            update_target ();
        }

        private void update_target () {
            string action = group_action.selected < group_actions.length ? group_actions[group_action.selected] : "";
            target.visible = action == "qgroup-create" || action == "qgroup-assign" || action == "qgroup-unassign";
            target.title = action == "qgroup-create" ? "New Qgroup ID (level/id)" : "Parent Qgroup ID (level/id)";
            review_group.sensitive = action != "" && (!target.visible || eligible_target (action));
        }

        private bool eligible_target (string action) {
            uint64 id;
            if (!BtrfsQgroup.parse_id (target.text.strip (), out id)) return false;
            var parent = status?.find (id);
            if (action == "qgroup-create") return (id >> 48) > 0 && parent == null;
            var child = selected_group ();
            if (child == null || parent == null || parent.level <= child.level) return false;
            return (id in child.parents) == (action == "qgroup-unassign");
        }

        private void review_mode () {
            if (!writable () || filesystem_action.selected >= filesystem_actions.length) return;
            string action = filesystem_actions[filesystem_action.selected];
            string details;
            switch (action) {
                case "quota-enable":
                    details = "Traditional qgroups track referenced and exclusive extents. Accounting can add significant metadata work when creating or deleting snapshots.";
                    break;
                case "quota-enable-simple":
                    details = "Simple quotas attribute newly allocated extents to their first allocating subvolume. They offer lower accounting overhead and different snapshot usage semantics.";
                    break;
                case "quota-disable":
                    details = "Disabling quotas removes enforcement, limits and qgroup relationships. Switching modes requires enabling the new mode in a separate step.";
                    foreach (var group in status.groups) {
                        if ((group.flags & 3) == 0 && group.parents.length == 0) continue;
                        details += "\n%s · Referenced limit %s · Exclusive limit %s · Parents %s".printf (
                            group.name, group.limit (false), group.limit (true), names (group.parents));
                    }
                    break;
                default:
                    details = "The kernel will rebuild traditional qgroup accounting. Usage and enforcement may be unreliable until accounting is consistent.";
                    break;
            }
            confirm (status, action, details);
        }

        private void review_selected_group () {
            if (!writable () || !review_group.sensitive || group_action.selected >= group_actions.length) return;
            string action = group_actions[group_action.selected];
            var group = selected_group ();
            if (action == "qgroup-create") {
                confirm (status, action, "Create the higher-level qgroup " + target.text.strip () + "?",
                    target.text.strip ());
                return;
            }
            if (group == null) return;
            if (action.has_suffix ("-limit")) {
                var reviewed = status;
                bool exclusive_limit = action == "qgroup-exclusive-limit";
                var dialog = new BtrfsQgroupLimitDialog (reviewed, group, exclusive_limit);
                dialog.response.connect ((response) => {
                    if (response == "apply")
                        confirm (reviewed, action, dialog.review_text (), group.name, dialog.request ());
                });
                dialog.present (this);
            } else if (action == "qgroup-delete") {
                confirm (status, action, "Delete the isolated qgroup " + group.name + "?", group.name);
            } else {
                string parent = target.text.strip ();
                confirm (status, action, "%s %s → %s. A rescan may be required.".printf (
                    action == "qgroup-assign" ? "Assign" : "Remove assignment", group.name, parent), group.name, parent);
            }
        }

        private void confirm (BtrfsQuotaStatus reviewed, string action, string details, string id = "", string value = "") {
            var dialog = new Adw.AlertDialog ("Confirm Btrfs Quota Change", details);
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("apply", "Apply");
            dialog.close_response = "cancel";
            dialog.set_response_appearance ("apply", action == "quota-disable" || action == "qgroup-delete" ?
                Adw.ResponseAppearance.DESTRUCTIVE : Adw.ResponseAppearance.SUGGESTED);
            dialog.response.connect ((response) => {
                if (response == "apply" && !busy) apply.begin (reviewed, action, id, value);
            });
            dialog.present (this);
        }

        private async void apply (BtrfsQuotaStatus reviewed, string action, string id, string value) {
            busy = true;
            update_actions ();
            feedback.visible = true;
            feedback.subtitle = "Waiting for authorization and kernel verification…";
            try {
                status = yield backend.change_btrfs_quota (block, identity, reviewed, action, id, value);
                feedback.subtitle = "Kernel verified the quota change.";
            } catch (Error error) {
                status = null;
                feedback.subtitle = error.message;
            }
            busy = false;
            yield refresh ();
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/btrfs-qgroup-limit-dialog.ui")]
    internal class BtrfsQgroupLimitDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.SwitchRow unlimited;
        [GtkChild] private unowned Adw.EntryRow amount;
        [GtkChild] private unowned Adw.ComboRow unit;
        [GtkChild] private unowned Adw.ActionRow warning;
        private bool can_set;
        private uint64 usage;
        private uint64 bytes;

        public BtrfsQgroupLimitDialog (BtrfsQuotaStatus status, BtrfsQgroup group, bool exclusive_limit) {
            string type = status.mode == BtrfsQuotaMode.SIMPLE ? "First-owner" :
                exclusive_limit ? "Exclusive" : "Referenced";
            usage = exclusive_limit ? group.exclusive : group.referenced;
            body = "%s · %s\n%s usage %s B · Current limit %s".printf (group.name, status.mode_label (),
                type, usage.to_string (), group.limit (exclusive_limit));
            can_set = !status.inconsistent && !group.stale;
            unlimited.active = !can_set || (group.flags & (exclusive_limit ? 2 : 1)) == 0;
            unlimited.sensitive = can_set;
            amount.text = (exclusive_limit ? group.max_exclusive : group.max_referenced).to_string ();
            unlimited.notify["active"].connect (validate);
            unit.notify["selected"].connect (validate);
            amount.changed.connect (validate);
            validate ();
        }

        private void validate () {
            amount.sensitive = unit.sensitive = !unlimited.active;
            bool valid = unlimited.active || (unit.selected < 5 &&
                BtrfsQuotaStatus.parse_limit (amount.text, 1UL << (unit.selected * 10), out bytes));
            set_response_enabled ("apply", valid);
            warning.subtitle = !can_set ? "Only clearing the existing limit is available." :
                !valid ? "Enter a whole number within the supported byte range." :
                !unlimited.active && bytes < usage ? "The new limit is below current usage. Subsequent writes may fail. Existing data is retained." :
                unlimited.active ? "This removes the selected limit." :
                "Writes can fail when accounted usage reaches the limit. Existing data is retained.";
        }

        public string request () { return unlimited.active ? "unlimited" : bytes.to_string (); }

        public string review_text () {
            return body + (unlimited.active ? "\nClear this limit." : "\nSet the limit to %s B.".printf (bytes.to_string ())) +
                "\n" + warning.subtitle;
        }
    }
}
