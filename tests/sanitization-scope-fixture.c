// SPDX-License-Identifier: GPL-3.0-or-later
#include "sanitization-scope.h"
#include <errno.h>

void sanitize_scope_clear(SanitizeScope *s)
{
    g_free(s->owner);
    g_free(s->key);
    g_free(s->identity);
    g_free(s->description);
    g_free(s->status);
}

/* Compiled only into the isolated broker. No production topology or bus fallback. */
gboolean sanitize_inspect(GDBusConnection *bus, const char *drive, SanitizeMethod method,
                          gboolean check_use, SanitizeScope *s, GError **error)
{
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, UDISKS, drive, "com.majoris.disks.Fixture",
        "Inspect", g_variant_new("(ub)", method, check_use), G_VARIANT_TYPE("(sssssui)"),
        G_DBUS_CALL_FLAGS_NONE, 3000, NULL, error);
    if (!reply) return FALSE;
    const char *outcome;
    g_variant_get(reply, "(s&ssssui)", &s->owner, &outcome, &s->identity, &s->status, &s->description,
                  &s->command, &s->remaining);
    if (!g_str_equal(outcome, "available")) {
        s->unsupported = g_str_equal(outcome, "unsupported");
        s->unknown = g_str_equal(outcome, "unknown");
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, outcome);
        return FALSE;
    }
    s->key = g_strdup("fixture-scope");
    return TRUE;
}
