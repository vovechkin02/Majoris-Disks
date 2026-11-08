/* SPDX-License-Identifier: GPL-3.0-or-later */
namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/luks-keyslots-dialog.ui")]
    internal class LuksKeyslotsDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.PreferencesGroup slot_group;
        [GtkChild] private unowned Gtk.ListBox slot_list;
        private string[] slots = {};
        private bool writable;
        private int free_slots;
        private int active_slots;
        public int selected_slot { get; private set; default = -1; }

        internal LuksKeyslotsDialog (LuksHeaderReview review, bool writable) {
            this.writable = writable;
            var text = new StringBuilder ("%s · %s".printf (review.version, review.uuid));
            if (!writable) text.append ("\nCredential changes require a locked, writable volume with no active dependents.");
            foreach (string line in review.keyslots) {
                var fields = line.split (" ");
                if (fields.length >= 5 && fields[0] == "slot") {
                    slots += line;
                    if (fields[2] == "active") active_slots++;
                    if (fields[2] == "inactive") free_slots++;
                    var row = new Adw.ActionRow ();
                    row.use_markup = false;
                    row.title = "Keyslot " + fields[1];
                    row.subtitle = fields[2] + (fields[3] != "unavailable" ? " · Priority " + fields[3] : "") +
                        (fields[4] == "1" ? " · Token associated" : "");
                    slot_list.append (row);
                } else if (fields.length >= 4 && fields[0] == "token") {
                    text.append ("\nToken %s · %s · %s, managed externally".printf (fields[1], fields[2], fields[3]));
                    text.append (fields.length == 4 ? " · No slots assigned" :
                        " · Slots " + string.joinv (", ", fields[4:fields.length]));
                }
            }
            if (writable && free_slots == 0)
                text.append ("\nAdding or changing credentials requires a free keyslot.");
            body = text.str;
            slot_group.description = "%d active, %d available. Slots can contain passphrase or keyfile credentials.".printf (
                active_slots, free_slots);
            slot_list.row_selected.connect (update_selection);
            update_selection (slot_list.get_selected_row ());
        }

        internal int[] remaining_slots () {
            int[] candidates = {};
            foreach (string line in slots) {
                var fields = line.split (" ");
                int slot = int.parse (fields[1]);
                if (slot != selected_slot && fields[2] == "active" && fields[3] != "ignore")
                    candidates += slot;
            }
            return candidates;
        }

        private void update_selection (Gtk.ListBoxRow? row) {
            selected_slot = -1;
            bool eligible = false;
            if (row != null) {
                var fields = slots[row.get_index ()].split (" ");
                selected_slot = int.parse (fields[1]);
                eligible = fields[2] == "active" && fields[4] == "0";
            }
            set_response_enabled ("identify", active_slots > 0);
            set_response_enabled ("add", writable && free_slots > 0 && active_slots > 0);
            set_response_enabled ("change", writable && eligible && free_slots > 0);
            set_response_enabled ("remove", writable && eligible && remaining_slots ().length > 0);
        }
    }

    [GtkTemplate (ui = "/com/majoris/disks/ui/luks-credential-dialog.ui")]
    internal class LuksCredentialDialog : Adw.AlertDialog {
        [GtkChild] private unowned Adw.ComboRow remaining_slot;
        [GtkChild] private unowned Adw.PasswordEntryRow current;
        [GtkChild] private unowned Adw.PasswordEntryRow other;
        [GtkChild] private unowned Adw.PasswordEntryRow confirmation;
        [GtkChild] private unowned Gtk.Button current_file_button;
        [GtkChild] private unowned Gtk.Button other_file_button;
        [GtkChild] private unowned Adw.ActionRow other_file_row;
        private int[] candidates;
        private bool remove;
        private bool identify;
        private bool choosing;
        public string current_file { get; private set; default = ""; }
        public string other_file { get; private set; default = ""; }
        public int retained_slot { get { return remove ? candidates[remaining_slot.selected] : -1; } }

        internal LuksCredentialDialog (string action, int slot, int[] candidates, bool configured, Gtk.Window parent) {
            this.candidates = candidates;
            remove = action == "remove";
            identify = action == "identify";
            switch (action) {
                case "identify":
                    heading = "Verify Unlocking Credential";
                    body = "Enter a passphrase or choose a keyfile to find an active keyslot it unlocks.";
                    set_response_label ("apply", "Verify Credential");
                    break;
                case "add":
                    heading = "Add Unlocking Credential";
                    body = "Supply a working credential and choose a new passphrase or keyfile.";
                    set_response_label ("apply", "Add Credential");
                    break;
                case "remove":
                    heading = "Remove Keyslot %d?".printf (slot);
                    body = "Verify the credential being removed and a credential that unlocks the slot you will keep. " +
                        "Removing a keyslot can permanently prevent access. Older header backups may still unlock " +
                        "with the removed credential.";
                    set_response_label ("apply", "Remove Keyslot");
                    break;
                default:
                    heading = "Change Keyslot %d?".printf (slot);
                    body = "Majoris verifies the replacement in a free slot before removing the original. " +
                        "Older header backups may still unlock with the original credential.";
                    set_response_label ("apply", "Change Credential");
                    break;
            }
            if (configured && !identify && action != "add")
                body += "\n\nThis volume has crypttab configuration. Changing its credentials may interrupt automatic unlocking.";
            if (remove) set_response_appearance ("apply", Adw.ResponseAppearance.DESTRUCTIVE);
            remaining_slot.visible = remove;
            string[] labels = {};
            foreach (int candidate in candidates) labels += "Keyslot %d".printf (candidate);
            remaining_slot.model = new Gtk.StringList (labels);
            other.title = remove ? "Passphrase for the slot to keep" : "New passphrase";
            other_file_row.title = remove ? "Keyfile for the slot to keep" : "New keyfile";
            other.visible = !identify;
            other_file_row.visible = !identify;
            confirmation.visible = !remove && !identify;
            current.changed.connect (update_response);
            other.changed.connect (update_response);
            confirmation.changed.connect (update_response);
            current_file_button.clicked.connect (() => choose_keyfile.begin (parent, true));
            other_file_button.clicked.connect (() => choose_keyfile.begin (parent, false));
            update_response ();
        }

        private async void choose_keyfile (Gtk.Window parent, bool first) {
            if (choosing) return;
            var button = first ? current_file_button : other_file_button;
            if ((first ? current_file : other_file) != "") {
                if (first) current_file = "";
                else other_file = "";
                button.label = "Choose…";
            } else {
                choosing = true;
                update_response ();
                var chooser = new Gtk.FileDialog ();
                chooser.title = "Select a Local Keyfile";
                try {
                    var file = yield chooser.open (parent, null);
                    string? path = file.get_path ();
                    if (path == null) throw new IOError.INVALID_ARGUMENT ("Choose a local keyfile.");
                    if (first) {
                        current_file = path;
                        current.text = "";
                    } else {
                        other_file = path;
                        other.text = "";
                        confirmation.text = "";
                    }
                    button.label = "Clear Selection";
                    button.tooltip_text = file.get_basename ();
                } catch (Error error) {
                    if (!(error is Gtk.DialogError.DISMISSED) && !(error is Gtk.DialogError.CANCELLED))
                        button.tooltip_text = error.message;
                }
                choosing = false;
            }
            current.sensitive = current_file == "";
            other.sensitive = other_file == "";
            confirmation.sensitive = other_file == "";
            update_response ();
        }

        // Match the current/new/confirmation validation used in GNOME Disks'
        // passphrase dialog before enabling the destructive response.
        private void update_response () {
            set_response_enabled ("apply", !choosing &&
                (current_file != "" || current.text.length > 0) &&
                (identify || other_file != "" || (other.text.length > 0 && (remove ||
                    (other.text == confirmation.text && (current_file != "" || current.text != other.text))))));
        }

        internal int take_credential (bool first) throws Error {
            var entry = first ? current : other;
            try {
                return (first ? current_file : other_file) != "" ? -1 : UDisksService.credential_pipe (entry.text);
            } finally {
                entry.text = "";
                confirmation.text = "";
            }
        }

        internal void clear_credentials () {
            current.text = "";
            other.text = "";
            confirmation.text = "";
        }
    }
}
