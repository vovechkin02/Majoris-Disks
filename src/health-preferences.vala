namespace MajorisDisks {
    [GtkTemplate (ui = "/com/majoris/disks/ui/health-preferences.ui")]
    internal class HealthPreferences : Adw.PreferencesDialog {
        [GtkChild] private unowned Adw.SwitchRow warnings;
        [GtkChild] private unowned Adw.SwitchRow critical;
        [GtkChild] private unowned Adw.SwitchRow self_tests;

        construct {
            var settings = health_settings ();
            if (settings == null) {
                warnings.sensitive = critical.sensitive = self_tests.sensitive = false;
            } else {
                settings.bind ("warnings", warnings, "active", SettingsBindFlags.DEFAULT);
                settings.bind ("critical", critical, "active", SettingsBindFlags.DEFAULT);
                settings.bind ("self-tests", self_tests, "active", SettingsBindFlags.DEFAULT);
            }
        }
    }
}
