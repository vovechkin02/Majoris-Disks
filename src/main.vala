namespace MajorisDisks {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: "com.majoris.disks",
                flags: ApplicationFlags.HANDLES_COMMAND_LINE | ApplicationFlags.HANDLES_OPEN);
            add_main_option ("drive", 0, OptionFlags.NONE, OptionArg.STRING, "Select a drive by identity", "ID");
            var preferences = new SimpleAction ("preferences", null);
            preferences.activate.connect (() => new HealthPreferences ().present (active_window));
            add_action (preferences);
            var attach = new SimpleAction ("attach-image", null);
            attach.activate.connect (() => (active_window as DisksWindow)?.choose_attach_image ());
            add_action (attach);
            var virtual_image = new SimpleAction ("virtual-image", null);
            virtual_image.set_enabled (VirtualDisk.available ());
            virtual_image.activate.connect (() => (active_window as DisksWindow)?.choose_virtual_image ());
            add_action (virtual_image);
            var verify_image = new SimpleAction ("verify-image", null);
            verify_image.activate.connect (() => (active_window as DisksWindow)?.choose_verify_image ());
            add_action (verify_image);
            var blank = new SimpleAction ("blank-image", null);
            blank.activate.connect (() => (active_window as DisksWindow)?.choose_blank_image ());
            add_action (blank);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => active_window?.close ());
            add_action (quit);
            set_accels_for_action ("app.quit", { "<Primary>q" });
            var about = new SimpleAction ("about", null);
            about.activate.connect (() => {
                var dialog = new Adw.AboutDialog.from_appdata ("/com/majoris/disks/com.majoris.disks.metainfo.xml", "0.2.0");
                dialog.developers = { "Majoris contributors" };
                dialog.copyright = "Copyright © 2026 Majoris contributors";
                dialog.present (active_window);
            });
            add_action (about);
            set_accels_for_action ("app.about", { "F1" });
        }

        protected override int command_line (ApplicationCommandLine command) {
            var args = command.get_arguments ();
            if (args.length > 2) {
                command.printerr ("Open one disk image at a time.\n");
                return 2;
            }
            if (args.length == 2) {
                open ({ command.create_file_for_arg (args[1]) }, "");
                return 0;
            }
            activate ();
            string? identity = command.get_options_dict ().lookup_value ("drive", VariantType.STRING)?.get_string ();
            if (identity != null) (active_window as DisksWindow)?.select_drive (identity);
            return 0;
        }

        protected override void open (File[] files, string hint) {
            activate ();
            if (files.length != 1) {
                (active_window as DisksWindow)?.show_image_open_error ("Open one disk image at a time.");
                return;
            }
            (active_window as DisksWindow)?.confirm_attach_image (files[0]);
        }

        protected override void activate () {
            if (active_window != null) {
                active_window.present ();
                return;
            }
            new DisksWindow (this).present ();
        }
    }

    public static int main (string[] args) {
        return new Application ().run (args);
    }
}
