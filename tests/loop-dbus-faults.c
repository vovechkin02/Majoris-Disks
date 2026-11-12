/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Loaded only by the isolated imaging integration driver. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char setup_tag, delete_tag;

static void
record_event (GDBusProxy *proxy, const char *event, const char *object)
{
    FILE *log = fopen (g_getenv ("MAJORIS_LOOP_FAULT_LOG"), "a");
    g_assert_nonnull (log);
    g_autofree char *owner = g_dbus_proxy_get_name_owner (proxy);
    fprintf (log, "%s %s %s\n", event, owner ? owner : "-", object);
    fclose (log);
}

static gboolean
same_file (const struct stat *candidate)
{
    struct stat fixture;
    const char *path = g_getenv ("MAJORIS_LOOP_FAULT_IMAGE");
    return path && g_getenv ("MAJORIS_LOOP_FAULT_LOG") && lstat (path, &fixture) == 0 &&
        S_ISREG (fixture.st_mode) && candidate->st_dev == fixture.st_dev && candidate->st_ino == fixture.st_ino;
}

static void
finish_setup (GObject *source, GAsyncResult *reply, gpointer data)
{
    GTask *task = data;
    GDBusProxy *proxy = G_DBUS_PROXY (source);
    GError *error = NULL;
    GVariant *result = g_dbus_proxy_call_with_unix_fd_list_finish (proxy, NULL, reply, &error);
    if (!result)
        g_task_return_error (task, error);
    else {
        const char *object;
        g_variant_get (result, "(&o)", &object);
        record_event (proxy, "accepted LoopSetup", object);
        const char *name = strrchr (object, '/');
        g_autofree char *diskseq_path = g_strdup_printf ("/sys/class/block/%s/diskseq", name + 1);
        g_autofree char *diskseq = NULL;
        if (!g_file_get_contents (diskseq_path, &diskseq, NULL, &error)) {
            g_task_return_error (task, error);
            g_variant_unref (result);
            g_object_unref (task);
            return;
        }
        record_event (proxy, "diskseq", g_strstrip (diskseq));
        const char *mode = g_getenv ("MAJORIS_LOOP_FAULT_MODE");
        if (g_strcmp0 (mode, "restart") == 0) {
            /* The shell driver verifies the guest before loading this module. */
            gint status;
            if (!g_spawn_command_line_sync ("/usr/bin/systemctl restart udisks2", NULL, NULL, &status, &error) ||
                !g_spawn_check_wait_status (status, &error))
                g_task_return_error (task, error);
            else
                g_task_return_pointer (task, g_variant_ref (result), (GDestroyNotify) g_variant_unref);
        } else if (g_strcmp0 (mode, "substitute") == 0) {
            const char *path = g_getenv ("MAJORIS_LOOP_FAULT_IMAGE");
            g_autofree char *original = g_strconcat (path, ".original", NULL);
            g_autofree char *replacement = g_strconcat (path, ".replacement", NULL);
            g_autoptr (GFile) source = g_file_new_for_path (path);
            g_autoptr (GFile) saved = g_file_new_for_path (original);
            g_autoptr (GFile) other = g_file_new_for_path (replacement);
            if (!g_file_move (source, saved, G_FILE_COPY_NOFOLLOW_SYMLINKS, NULL, NULL, NULL, &error) ||
                !g_file_move (other, source, G_FILE_COPY_NOFOLLOW_SYMLINKS, NULL, NULL, NULL, &error))
                g_task_return_error (task, error);
            else {
                record_event (proxy, "substituted LoopSetup", object);
                g_task_return_pointer (task, g_variant_ref (result), (GDestroyNotify) g_variant_unref);
            }
        } else {
            g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                     "Injected lost LoopSetup reply after backend acceptance");
        }
        g_variant_unref (result);
    }
    g_object_unref (task);
}

void
g_dbus_proxy_call_with_unix_fd_list (GDBusProxy *proxy, const gchar *method, GVariant *parameters,
                                    GDBusCallFlags flags, gint timeout, GUnixFDList *fds,
                                    GCancellable *cancel, GAsyncReadyCallback callback, gpointer data)
{
    __typeof__ (&g_dbus_proxy_call_with_unix_fd_list) original =
        dlsym (RTLD_NEXT, "g_dbus_proxy_call_with_unix_fd_list");
    const char *mode = g_getenv ("MAJORIS_LOOP_FAULT_MODE");
    if ((g_strcmp0 (mode, "setup") == 0 || g_strcmp0 (mode, "restart") == 0 ||
         g_strcmp0 (mode, "substitute") == 0) &&
        g_str_equal (method, "LoopSetup") && g_str_equal (g_dbus_proxy_get_interface_name (proxy),
            "org.freedesktop.UDisks2.Manager") && g_variant_is_of_type (parameters, G_VARIANT_TYPE ("(ha{sv})"))) {
        g_autoptr (GVariant) handle = g_variant_get_child_value (parameters, 0);
        int fd = g_unix_fd_list_get (fds, g_variant_get_handle (handle), NULL);
        struct stat info;
        gboolean fixture = fd >= 0 && fstat (fd, &info) == 0 && same_file (&info);
        if (fd >= 0) close (fd);
        if (fixture) {
            record_event (proxy, "dispatch LoopSetup", g_dbus_proxy_get_object_path (proxy));
            GTask *task = g_task_new (proxy, NULL, callback, data);
            g_task_set_source_tag (task, &setup_tag);
            original (proxy, method, parameters, flags, timeout, fds, cancel, finish_setup, task);
            return;
        }
    }
    original (proxy, method, parameters, flags, timeout, fds, cancel, callback, data);
}

GVariant *
g_dbus_proxy_call_with_unix_fd_list_finish (GDBusProxy *proxy, GUnixFDList **fds,
                                           GAsyncResult *reply, GError **error)
{
    if (g_task_is_valid (reply, proxy) && g_task_get_source_tag (G_TASK (reply)) == &setup_tag) {
        if (fds) *fds = NULL;
        return g_task_propagate_pointer (G_TASK (reply), error);
    }
    __typeof__ (&g_dbus_proxy_call_with_unix_fd_list_finish) original =
        dlsym (RTLD_NEXT, "g_dbus_proxy_call_with_unix_fd_list_finish");
    return original (proxy, fds, reply, error);
}

static void
finish_delete (GObject *source, GAsyncResult *reply, gpointer data)
{
    GTask *task = data;
    GDBusProxy *proxy = G_DBUS_PROXY (source);
    GError *error = NULL;
    g_autoptr (GVariant) result = g_dbus_proxy_call_finish (proxy, reply, &error);
    if (!result)
        g_task_return_error (task, error);
    else {
        record_event (proxy, "accepted Loop.Delete", g_dbus_proxy_get_object_path (proxy));
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                 "Injected lost Loop.Delete reply after backend acceptance");
    }
    g_object_unref (task);
}

void
g_dbus_proxy_call (GDBusProxy *proxy, const gchar *method, GVariant *parameters,
                   GDBusCallFlags flags, gint timeout, GCancellable *cancel,
                   GAsyncReadyCallback callback, gpointer data)
{
    __typeof__ (&g_dbus_proxy_call) original = dlsym (RTLD_NEXT, "g_dbus_proxy_call");
    if (g_strcmp0 (g_getenv ("MAJORIS_LOOP_FAULT_MODE"), "delete") == 0 && g_str_equal (method, "Delete") &&
        g_str_equal (g_dbus_proxy_get_interface_name (proxy), "org.freedesktop.UDisks2.Loop")) {
        g_autoptr (GVariant) backing = g_dbus_proxy_get_cached_property (proxy, "BackingFile");
        struct stat info;
        if (backing && lstat (g_variant_get_bytestring (backing), &info) == 0 && same_file (&info)) {
            record_event (proxy, "dispatch Loop.Delete", g_dbus_proxy_get_object_path (proxy));
            GTask *task = g_task_new (proxy, NULL, callback, data);
            g_task_set_source_tag (task, &delete_tag);
            original (proxy, method, parameters, flags, timeout, cancel, finish_delete, task);
            return;
        }
    }
    original (proxy, method, parameters, flags, timeout, cancel, callback, data);
}

GVariant *
g_dbus_proxy_call_finish (GDBusProxy *proxy, GAsyncResult *reply, GError **error)
{
    if (g_task_is_valid (reply, proxy) && g_task_get_source_tag (G_TASK (reply)) == &delete_tag)
        return g_task_propagate_pointer (G_TASK (reply), error);
    __typeof__ (&g_dbus_proxy_call_finish) original = dlsym (RTLD_NEXT, "g_dbus_proxy_call_finish");
    return original (proxy, reply, error);
}
