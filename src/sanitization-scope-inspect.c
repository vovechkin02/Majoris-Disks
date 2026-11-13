// SPDX-License-Identifier: GPL-3.0-or-later
#include "sanitization-scope.h"

int main(int argc, char **argv)
{
    if (argc != 2 || !g_variant_is_object_path(argv[1]) ||
        !g_str_has_prefix(argv[1], "/org/freedesktop/UDisks2/drives/")) {
        g_printerr("Usage: %s UDISKS_DRIVE_OBJECT_PATH\n", argv[0]);
        return 2;
    }
    g_unsetenv("DBUS_SYSTEM_BUS_ADDRESS");
    g_autoptr(GError) error = NULL;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (!bus) {
        g_printerr("%s\n", error->message);
        return 2;
    }

    static const char *methods[] = {
        "ata-normal", "ata-enhanced", "block-erase", "crypto-erase", "overwrite"
    };
    G_STATIC_ASSERT(G_N_ELEMENTS(methods) == METHOD_COUNT);
    g_autoptr(GKeyFile) report = g_key_file_new();
    g_key_file_set_string(report, "Inspection", "drive", argv[1]);
    for (SanitizeMethod method = 0; method < METHOD_COUNT; method++) {
        SanitizeScope scope = {};
        g_autoptr(GError) refusal = NULL;
        gboolean eligible = sanitize_inspect(bus, argv[1], method, TRUE, &scope, &refusal);
        const char *group = methods[method];
        g_key_file_set_string(report, group, "protocol", method <= ATA_ENHANCED ? "ATA" : "NVMe");
        g_key_file_set_boolean(report, group, "eligible", eligible);
        g_key_file_set_boolean(report, group, "scope-complete", eligible);
        g_key_file_set_boolean(report, group, "unsupported", scope.unsupported);
        if (scope.description) g_key_file_set_string(report, group, eligible ? "scope" : "observed-scope",
            scope.description);
        if (scope.identity) g_key_file_set_string(report, group, "kernel-identity", scope.identity);
        if (scope.status) g_key_file_set_string(report, group, "hardware-status", scope.status);
        if (!eligible) g_key_file_set_string(report, group, "refusal",
            refusal ? refusal->message : "The hardware scope could not be verified.");
        sanitize_scope_clear(&scope);
    }
    g_autofree char *output = g_key_file_to_data(report, NULL, NULL);
    g_print("%s", output);
    return 0;
}
