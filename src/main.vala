namespace MajorisDisks {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: "com.majoris.disks", flags: ApplicationFlags.HANDLES_COMMAND_LINE);
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
            activate ();
            string? identity = command.get_options_dict ().lookup_value ("drive", VariantType.STRING)?.get_string ();
            if (identity != null) (active_window as DisksWindow)?.select_drive (identity);
            return 0;
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
