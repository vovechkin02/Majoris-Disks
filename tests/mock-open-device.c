#include "mock-open-device.h"

#include <fcntl.h>
#include <unistd.h>

static void
mock_open_device (GDBusConnection *connection, const char *sender, const char *path,
                  const char *interface, const char *method, GVariant *parameters,
                  GDBusMethodInvocation *invocation, gpointer user_data)
{
    const char *mode;
    g_autoptr(GVariant) options = NULL;
    g_assert_cmpstr (method, ==, "OpenDevice");
    g_assert_true (g_variant_is_of_type (parameters, G_VARIANT_TYPE ("(sa{sv})")));
    g_variant_get (parameters, "(&s@a{sv})", &mode, &options);
    g_assert_cmpstr (mode, ==, "r");
    g_assert_cmpuint (g_variant_n_children (options), ==, 0);

    if (g_str_equal (path, "/test/denied")) {
        g_dbus_method_invocation_return_dbus_error (invocation,
            "org.freedesktop.UDisks2.Error.NotAuthorized", "Authorization denied");
        return;
    }
    if (g_str_equal (path, "/test/missing")) {
        g_dbus_method_invocation_return_value (invocation, g_variant_new ("(h)", 0));
        return;
    }
    int fd = open ("/dev/null", O_RDONLY | O_CLOEXEC);
    g_assert_cmpint (fd, >=, 0);
    g_autoptr(GUnixFDList) descriptors = g_unix_fd_list_new ();
    g_autoptr(GError) error = NULL;
    int handle = g_unix_fd_list_append (descriptors, fd, &error);
    close (fd);
    g_assert_no_error (error);
    g_dbus_method_invocation_return_value_with_unix_fd_list (invocation,
        g_variant_new ("(h)", handle), descriptors);
}

guint
majoris_register_mock_open_device (GDBusConnection *connection, const char *path,
                                  GDBusInterfaceInfo *info, GError **error)
{
    static const GDBusInterfaceVTable vtable = { .method_call = mock_open_device };
    return g_dbus_connection_register_object (connection, path, info, &vtable, NULL, NULL, error);
}
