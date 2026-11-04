namespace MajorisDisks {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: "com.majoris.disks");
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
