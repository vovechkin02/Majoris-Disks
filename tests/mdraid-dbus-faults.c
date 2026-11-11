/* SPDX-License-Identifier: GPL-3.0-or-later
 * Test-process-only injection. Never linked into or installed with the app. */
#include <gio/gio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void (*Call) (GDBusProxy *, const gchar *, GVariant *, GDBusCallFlags,
                      gint, GCancellable *, GAsyncReadyCallback, gpointer);
typedef GVariant *(*Finish) (GDBusProxy *, GAsyncResult *, GError **);
static char tag;

static void
accepted (GObject *source, GAsyncResult *reply, gpointer data)
{
    GTask *task = data;
    Finish finish = (Finish) dlsym (RTLD_NEXT, "g_dbus_proxy_call_finish");
    GError *error = NULL;
    GVariant *value = finish (G_DBUS_PROXY (source), reply, &error);
    if (error)
        g_task_return_error (task, error);
    else {
        g_variant_unref (value);
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                "Injected lost reply after kernel acceptance");
    }
    g_object_unref (task);
}

void
g_dbus_proxy_call (GDBusProxy *proxy, const gchar *method, GVariant *parameters,
                   GDBusCallFlags flags, gint timeout, GCancellable *cancel,
                   GAsyncReadyCallback callback, gpointer data)
{
    Call original = (Call) dlsym (RTLD_NEXT, "g_dbus_proxy_call");
    const char *mode = g_getenv ("MAJORIS_MDRAID_DBUS_FAULT");
    const char *interface = g_dbus_proxy_get_interface_name (proxy);
    gboolean image_rescan = g_getenv ("MAJORIS_IMAGE_DBUS_FAULT") != NULL &&
        g_str_equal (method, "Rescan") && g_strcmp0 (interface, "org.freedesktop.UDisks2.Block") == 0;
    gboolean raid_add = mode != NULL && g_str_equal (method, "AddDevice") &&
        g_strcmp0 (interface, "org.freedesktop.UDisks2.MDRaid") == 0;
    if (!image_rescan && !raid_add) {
        original (proxy, method, parameters, flags, timeout, cancel, callback, data);
        return;
    }
    const char *log = g_getenv (image_rescan ? "MAJORIS_IMAGE_DISPATCH_LOG" : "MAJORIS_MDRAID_DISPATCH_LOG");
    if (log) {
        FILE *file = fopen (log, "a");
        if (file) { fprintf (file, "%s\n", method); fclose (file); }
    }
    GTask *task = g_task_new (proxy, cancel, callback, data);
    g_task_set_source_tag (task, &tag);
    if (raid_add && g_str_equal (mode, "before")) {
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                "Injected timeout before dispatch");
        g_object_unref (task);
    } else
        original (proxy, method, parameters, flags, timeout, cancel, accepted, task);
}

GVariant *
g_dbus_proxy_call_finish (GDBusProxy *proxy, GAsyncResult *reply, GError **error)
{
    if (g_task_is_valid (reply, proxy) && g_task_get_source_tag (G_TASK (reply)) == &tag)
        return g_task_propagate_pointer (G_TASK (reply), error);
    Finish original = (Finish) dlsym (RTLD_NEXT, "g_dbus_proxy_call_finish");
    return original (proxy, reply, error);
}
