namespace MajorisDisks {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: "com.majoris.disks");
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => active_window?.close ());
            add_action (quit);
            set_accels_for_action ("app.quit", { "<Primary>q" });
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
