/* SPDX-License-Identifier: GPL-3.0-or-later */
#define main majoris_helper_main
#include "nbd-helper.c"
#undef main

static void
test_pinned_endpoint (void)
{
    g_autoptr(GError) error = NULL;
    g_autofree char *directory = g_dir_make_tmp ("majoris-nbd-endpoint-XXXXXX", &error);
    g_assert_no_error (error);
    g_autofree char *path = g_build_filename (directory, "export.sock", NULL);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    g_assert_cmpuint (strlen (path), <, sizeof address.sun_path);
    g_strlcpy (address.sun_path, path, sizeof address.sun_path);

    int original = socket (AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    g_assert_cmpint (original, >=, 0);
    g_assert_cmpint (bind (original, (struct sockaddr *) &address, sizeof address), ==, 0);
    g_assert_cmpint (listen (original, 4), ==, 0);
    int pinned = open (path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    g_assert_cmpint (pinned, >=, 0);
    g_assert_cmpint (g_unlink (path), ==, 0);

    int replacement = socket (AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    g_assert_cmpint (replacement, >=, 0);
    g_assert_cmpint (bind (replacement, (struct sockaddr *) &address, sizeof address), ==, 0);
    g_assert_cmpint (listen (replacement, 1), ==, 0);

    const char *argv[] = { "/usr/bin/test", "-S", "/proc/self/fd/3", NULL };
    GPid client __attribute__((cleanup(reap_client))) = 0;
    g_assert_true (run_client (argv, pinned, &client, &error));
    g_assert_no_error (error);
    g_assert_cmpint (client, >, 0);
    siginfo_t exited = { 0 };
    g_assert_cmpint (waitid (P_PID, client, &exited, WEXITED | WNOHANG | WNOWAIT), ==, 0);
    g_assert_cmpint (exited.si_pid, ==, client);
    g_assert_cmpint (exited.si_code, ==, CLD_EXITED);

    // Our test process is the socket owner, but it is not the installed QEMU exporter.
    g_assert_cmpint (verify_exporter (pinned, getuid ()), ==, -1);
    int accepted = accept4 (original, NULL, NULL, SOCK_CLOEXEC);
    g_assert_cmpint (accepted, >=, 0);
    g_assert_cmpint (accept4 (replacement, NULL, NULL, SOCK_CLOEXEC), ==, -1);
    g_assert_cmpint (errno, ==, EAGAIN);
    close (accepted);
    close (pinned);
    close (original);
    close (replacement);
    g_assert_cmpint (g_unlink (path), ==, 0);
    g_assert_cmpint (g_rmdir (directory), ==, 0);
}

static void
test_private_directories (void)
{
    g_autoptr(GError) error = NULL;
    g_autofree char *directory = g_dir_make_tmp ("majoris-nbd-private-XXXXXX", &error);
    g_assert_no_error (error);
    int fd = private_directory (AT_FDCWD, directory, getuid (), 0077);
    g_assert_cmpint (fd, >=, 0);
    g_assert_cmpint (symlinkat (".", fd, "link"), ==, 0);
    g_assert_cmpint (private_directory (fd, "link", getuid (), 0077), ==, -1);
    g_assert_cmpint (private_directory (AT_FDCWD, directory, getuid () + 1, 0077), ==, -1);
    g_assert_cmpint (fchmod (fd, 0755), ==, 0);
    g_assert_cmpint (private_directory (AT_FDCWD, directory, getuid (), 0077), ==, -1);
    g_assert_cmpint (unlinkat (fd, "link", 0), ==, 0);
    close (fd);
    g_assert_cmpint (g_rmdir (directory), ==, 0);
}

static void
test_unowned_device (void)
{
    g_autoptr(GError) error = NULL;
    g_assert_false (detach_device (getuid (), G_MAXUINT, "2d8c6499-deb9-480b-ad06-62104686504f", &error));
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED);
}

typedef struct {
    GDBusConnection *helper;
    GDBusConnection *caller;
    GMainLoop *loop;
    guint checks;
} AuthFixture;

static GDBusConnection *
test_bus_connect (const char *address)
{
    g_autoptr(GError) error = NULL;
    GDBusConnection *connection = g_dbus_connection_new_for_address_sync (address,
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, NULL, &error);
    g_assert_no_error (error);
    return connection;
}

static void
check_authorization (GDBusConnection *connection, const char *sender, const char *path, const char *interface,
                     const char *method, GVariant *arguments, GDBusMethodInvocation *invocation, gpointer data)
{
    AuthFixture *fixture = data;
    g_autoptr(GVariant) subject = g_variant_get_child_value (arguments, 0);
    g_autoptr(GVariant) action = g_variant_get_child_value (arguments, 1);
    g_autoptr(GVariant) details = g_variant_get_child_value (subject, 1);
    const char *name = NULL;
    g_assert_true (g_variant_lookup (details, "name", "&s", &name));
    g_assert_cmpstr (name, ==, g_dbus_connection_get_unique_name (fixture->caller));
    g_assert_cmpstr (g_variant_get_string (action, NULL), ==, ACTION);
    guint check = fixture->checks++;
    if (check == 2) {
        g_autoptr(GError) error = NULL;
        g_assert_true (g_dbus_connection_close_sync (fixture->caller, NULL, &error));
        g_assert_no_error (error);
    }
    g_dbus_method_invocation_return_value (invocation, g_variant_new ("((bb@a{ss}))", check != 1, FALSE,
        g_variant_new_array (G_VARIANT_TYPE ("{ss}"), NULL, 0)));
}

static gboolean
finish_auth_test (gpointer data)
{
    g_main_loop_quit (data);
    return G_SOURCE_REMOVE;
}

static gpointer
exercise_authorization (gpointer data)
{
    AuthFixture *fixture = data;
    const char *caller = g_dbus_connection_get_unique_name (fixture->caller);
    g_autoptr(GError) error = NULL;
    guint uid = 0;
    g_assert_true (authorize (fixture->helper, caller, &uid, &error));
    g_assert_no_error (error);
    g_assert_cmpuint (uid, ==, getuid ());
    g_assert_false (authorize (fixture->helper, caller, &uid, &error));
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED);
    g_clear_error (&error);
    g_assert_false (authorize (fixture->helper, caller, &uid, &error));
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_idle_add (finish_auth_test, fixture->loop);
    return NULL;
}

static void
test_authorization (void)
{
    static const char xml[] =
        "<node><interface name='org.freedesktop.PolicyKit1.Authority'>"
        "<method name='CheckAuthorization'><arg type='(sa{sv})' direction='in'/>"
        "<arg type='s' direction='in'/><arg type='a{ss}' direction='in'/>"
        "<arg type='u' direction='in'/><arg type='s' direction='in'/>"
        "<arg type='(bba{ss})' direction='out'/></method></interface></node>";
    static const GDBusInterfaceVTable policy_vtable = { .method_call = check_authorization };
    g_autoptr(GTestDBus) bus = g_test_dbus_new (G_TEST_DBUS_NONE);
    g_test_dbus_up (bus);
    const char *address = g_test_dbus_get_bus_address (bus);
    g_autoptr(GDBusConnection) authority = test_bus_connect (address);
    g_autoptr(GDBusConnection) helper = test_bus_connect (address);
    g_autoptr(GDBusConnection) caller = test_bus_connect (address);
    g_autoptr(GMainLoop) loop = g_main_loop_new (NULL, FALSE);
    AuthFixture fixture = { helper, caller, loop, 0 };
    g_autoptr(GError) error = NULL;
    g_autoptr(GDBusNodeInfo) schema = g_dbus_node_info_new_for_xml (xml, &error);
    g_assert_no_error (error);
    guint registration = g_dbus_connection_register_object (authority, "/org/freedesktop/PolicyKit1/Authority",
        schema->interfaces[0], &policy_vtable, &fixture, NULL, &error);
    g_assert_no_error (error);
    g_autoptr(GVariant) result = g_dbus_connection_call_sync (authority, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        g_variant_new ("(su)", "org.freedesktop.PolicyKit1", 0u),
        G_VARIANT_TYPE ("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &error);
    g_assert_no_error (error);
    guint outcome;
    g_variant_get (result, "(u)", &outcome);
    g_assert_cmpuint (outcome, ==, 1);
    GThread *thread = g_thread_new ("mock-nbd-authorization", exercise_authorization, &fixture);
    g_main_loop_run (loop);
    g_thread_join (thread);
    g_assert_cmpuint (fixture.checks, ==, 3);
    g_dbus_connection_unregister_object (authority, registration);
    g_dbus_connection_close_sync (helper, NULL, NULL);
    g_dbus_connection_close_sync (authority, NULL, NULL);
    g_test_dbus_down (bus);
}

static char *
simulated_connection (GPid pid, gpointer data)
{
    guint *polls = data;
    return ++*polls == 3 ? g_strdup_printf ("fixture:%d", pid) : NULL;
}

static char *
no_connection (GPid pid, gpointer data)
{
    return NULL;
}

static void
test_foreground_readiness (void)
{
    const char *argv[] = { "/usr/bin/sleep", "30", NULL };
    GPid client __attribute__((cleanup(reap_client))) = 0;
    g_autoptr(GError) error = NULL;
    g_assert_true (spawn_client (argv, -1, &client, &error));
    g_assert_no_error (error);
    guint polls = 0;
    g_autofree char *identity = wait_for_connection (client, simulated_connection, &polls, G_TIME_SPAN_SECOND, &error);
    g_assert_no_error (error);
    g_assert_nonnull (identity);
    siginfo_t state = { 0 };
    g_assert_cmpint (waitid (P_PID, client, &state, WEXITED | WNOHANG | WNOWAIT), ==, 0);
    g_assert_cmpint (state.si_pid, ==, 0);
    g_assert_cmpint (kill (client, SIGTERM), ==, 0);
}

static void
test_readiness_failures (void)
{
    const char *failed[] = { "/usr/bin/false", NULL };
    const char *pending[] = { "/usr/bin/sleep", "30", NULL };
    GPid early __attribute__((cleanup(reap_client))) = 0;
    GPid slow __attribute__((cleanup(reap_client))) = 0;
    g_autoptr(GError) error = NULL;
    g_assert_true (spawn_client (failed, -1, &early, &error));
    g_assert_null (wait_for_connection (early, no_connection, NULL, G_TIME_SPAN_SECOND, &error));
    g_assert_error (error, G_SPAWN_EXIT_ERROR, 1);
    g_clear_error (&error);
    g_assert_true (spawn_client (pending, -1, &slow, &error));
    g_assert_null (wait_for_connection (slow, no_connection, NULL, 50 * G_TIME_SPAN_MILLISECOND, &error));
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
    siginfo_t state = { 0 };
    g_assert_cmpint (waitid (P_PID, slow, &state, WEXITED | WNOHANG | WNOWAIT), ==, 0);
    g_assert_cmpint (state.si_pid, ==, 0);
    g_assert_cmpint (kill (slow, SIGTERM), ==, 0);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/nbd/pinned-endpoint", test_pinned_endpoint);
    g_test_add_func ("/nbd/private-directories", test_private_directories);
    g_test_add_func ("/nbd/unowned-device", test_unowned_device);
    g_test_add_func ("/nbd/authorization", test_authorization);
    g_test_add_func ("/nbd/foreground-readiness", test_foreground_readiness);
    g_test_add_func ("/nbd/readiness-failures", test_readiness_failures);
    return g_test_run ();
}
