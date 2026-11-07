/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nbd-identity.h"
#include <gio/gio.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define BUS_NAME "com.majoris.disks.Nbd"
#define OBJECT_PATH "/com/majoris/disks/Nbd"
#define ACTION BUS_NAME ".manage"

static void
close_fd (int *fd)
{
    if (*fd >= 0)
        close (*fd);
}

static int
private_directory (int parent, const char *name, uid_t owner, mode_t forbidden)
{
    int fd = openat (parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd >= 0 && (fstat (fd, &info) != 0 || info.st_uid != owner || (info.st_mode & forbidden))) {
        close (fd);
        return -1;
    }
    return fd;
}

static int
export_socket (guint uid, const char *token)
{
    g_autofree char *username = g_strdup_printf ("%u", uid);
    int run __attribute__((cleanup(close_fd))) = private_directory (AT_FDCWD, "/run", 0, 0022);
    if (run < 0) return -1;
    int users __attribute__((cleanup(close_fd))) = private_directory (run, "user", 0, 0022);
    if (users < 0) return -1;
    int runtime __attribute__((cleanup(close_fd))) = private_directory (users, username, uid, 0077);
    if (runtime < 0) return -1;
    int app __attribute__((cleanup(close_fd))) = private_directory (runtime, "majoris-nbd", uid, 0077);
    if (app < 0) return -1;
    int session __attribute__((cleanup(close_fd))) = private_directory (app, token, uid, 0077);
    if (session < 0) return -1;
    int endpoint __attribute__((cleanup(close_fd))) = private_directory (session, "socket", uid, 0077);
    if (endpoint < 0) return -1;

    int fd = openat (endpoint, "export.sock", O_PATH | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd >= 0 && (fstat (fd, &info) != 0 || !S_ISSOCK (info.st_mode) || info.st_uid != uid)) {
        close (fd);
        return -1;
    }
    return fd;
}

static int
verify_exporter (int endpoint, guint uid)
{
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    g_snprintf (address.sun_path, sizeof address.sun_path, "/proc/self/fd/%d", endpoint);
    int probe __attribute__((cleanup(close_fd))) = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    struct ucred peer;
    socklen_t length = sizeof peer;
    if (probe < 0 || connect (probe, (struct sockaddr *) &address, sizeof address) != 0 ||
        getsockopt (probe, SOL_SOCKET, SO_PEERCRED, &peer, &length) != 0 ||
        length != sizeof peer || peer.uid != uid || peer.pid <= 0)
        return -1;
    g_autofree char *exe = g_strdup_printf ("/proc/%d/exe", peer.pid);
    struct stat actual, installed;
    if (stat (exe, &actual) != 0 || stat ("/usr/bin/qemu-nbd", &installed) != 0 ||
        actual.st_dev != installed.st_dev || actual.st_ino != installed.st_ino)
        return -1;
    int verified = probe;
    probe = -1;
    return verified;
}

static gboolean
read_number (guint index, const char *attribute, guint64 *number)
{
    g_autofree char *path = g_strdup_printf ("/sys/block/nbd%u/%s", index, attribute);
    g_autofree char *value = NULL;
    return g_file_get_contents (path, &value, NULL, NULL) &&
           g_ascii_string_to_unsigned (g_strstrip (value), 10, 0, G_MAXUINT64, number, NULL);
}

static gboolean
has_client (guint index)
{
    g_autofree char *path = g_strdup_printf ("/sys/block/nbd%u/pid", index);
    struct stat info;
    return lstat (path, &info) == 0 || errno != ENOENT;
}

static int
claim_device (guint index)
{
    g_autofree char *path = g_strdup_printf ("/dev/nbd%u", index);
    g_autofree char *sysfs = g_strdup_printf ("/sys/block/nbd%u/dev", index);
    g_autofree char *number = NULL;
    int fd = open (path, O_RDONLY | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat info;
    if (fd < 0)
        return -1;
    if (fstat (fd, &info) == 0 && S_ISBLK (info.st_mode) &&
        g_file_get_contents (sysfs, &number, NULL, NULL)) {
        g_autofree char *expected = g_strdup_printf ("%u:%u", major (info.st_rdev), minor (info.st_rdev));
        if (g_str_equal (g_strstrip (number), expected))
            return fd;
    }
    close (fd);
    return -1;
}

static int
allocate_device (guint *index, GError **error)
{
    g_autoptr(GDir) devices = g_dir_open ("/sys/block", 0, error);
    if (devices == NULL)
        return -1;
    const char *name;
    while ((name = g_dir_read_name (devices)) != NULL) {
        guint64 candidate, size;
        if (!g_str_has_prefix (name, "nbd") ||
            !g_ascii_string_to_unsigned (name + 3, 10, 0, G_MAXUINT, &candidate, NULL) ||
            has_client (candidate))
            continue;
        int fd = claim_device (candidate);
        if (fd < 0)
            continue;
        if (!has_client (candidate) && read_number (candidate, "size", &size) && size == 0) {
            *index = (guint) candidate;
            return fd;
        }
        close (fd);
    }
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY,
        "No available NBD device. Load the NBD module with partition support or release an unused device.");
    return -1;
}

static gboolean
run_client (const char *const *argv, int endpoint, GPid *pid, GError **error)
{
    const int socket_fd = 3;
    if (!g_spawn_async_with_pipes_and_fds (NULL, argv, NULL,
        G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL,
        NULL, NULL, -1, -1, -1, &endpoint, &socket_fd, endpoint >= 0 ? 1 : 0,
        pid, NULL, NULL, NULL, error))
        return FALSE;

    gint64 deadline = g_get_monotonic_time () + 20 * G_TIME_SPAN_SECOND;
    int status;
    do {
        pid_t child = waitpid (*pid, &status, WNOHANG);
        if (child == *pid)
            return g_spawn_check_wait_status (status, error);
        if (child < 0 && errno != EINTR) {
            g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Could not wait for nbd-client: %s", g_strerror (errno));
            return FALSE;
        }
        g_usleep (10000);
    } while (g_get_monotonic_time () < deadline);

    // The child remains ours until it is reaped, so its PID cannot have been reused.
    kill (*pid, SIGKILL);
    while (waitpid (*pid, &status, 0) < 0 && errno == EINTR) {}
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "nbd-client did not finish in time.");
    return FALSE;
}
static gboolean
disconnect_client (guint index, int *block, const char *identity, GError **error)
{
    g_autofree char *live = majoris_nbd_identity (index, NULL);
    if (live == NULL || g_strcmp0 (live, identity) != 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "NBD ownership changed.");
        return FALSE;
    }
    g_autofree char *path = g_strdup_printf ("/dev/nbd%u", index);
    const char *argv[] = { MAJORIS_NBD_CLIENT, "-d", path, NULL };
    GPid pid = 0;
    g_autoptr(GError) client_error = NULL;
    run_client (argv, -1, &pid, &client_error);
    // The open block device pins the old kernel configuration until the disconnect request returns.
    close_fd (block);
    *block = -1;
    for (guint i = 0; i < 50; i++) {
        guint64 size;
        if (!has_client (index) && read_number (index, "size", &size) && size == 0)
            return TRUE;
        g_usleep (100000);
    }
    if (client_error != NULL)
        g_propagate_error (error, g_steal_pointer (&client_error));
    else
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "The kernel has not released the NBD device.");
    return FALSE;
}

static gboolean
write_record (guint index, guint uid, const char *token, const char *identity, GError **error)
{
    g_autoptr(GKeyFile) record = g_key_file_new ();
    g_key_file_set_uint64 (record, "attachment", "uid", uid);
    g_key_file_set_string (record, "attachment", "token", token);
    g_key_file_set_string (record, "attachment", "identity", identity);
    gsize length;
    g_autofree char *data = g_key_file_to_data (record, &length, NULL);
    g_autofree char *path = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", index);
    return g_file_set_contents_full (path, data, length, G_FILE_SET_CONTENTS_CONSISTENT, 0644, error);
}

static gboolean
attach_device (guint uid, const char *token, guint64 capacity, gboolean read_only,
               guint *index, gboolean *uncertain, GError **error)
{
    int endpoint __attribute__((cleanup(close_fd))) = export_socket (uid, token);
    if (endpoint < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "The private NBD socket could not be verified.");
        return FALSE;
    }
    int block __attribute__((cleanup(close_fd))) = allocate_device (index, error);
    if (block < 0)
        return FALSE;
    // Opening an idle NBD node creates a kernel configuration. Release it before connecting.
    close_fd (&block);
    block = -1;
    int probe __attribute__((cleanup(close_fd))) = verify_exporter (endpoint, uid);
    if (probe < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "The NBD socket peer is not the caller's QEMU exporter.");
        return FALSE;
    }
    g_autofree char *path = g_strdup_printf ("/dev/nbd%u", *index);
    const char *argv[] = { MAJORIS_NBD_CLIENT, "-unix", "/proc/self/fd/3", path, "-name", token,
        "-timeout", "30", read_only ? "-readonly" : NULL, NULL };
    // The client resolves the pinned socket inode, even if its original pathname changes.
    GPid spawned = 0;
    g_autoptr(GError) client_error = NULL;
    gboolean success = run_client (argv, endpoint, &spawned, &client_error);
    guint kernel_pid = 0;
    g_autofree char *identity = majoris_nbd_identity (*index, &kernel_pid);
    if (identity == NULL || kernel_pid != (guint) spawned) {
        *uncertain = success || (spawned > 0 && identity == NULL && has_client (*index));
        if (client_error != NULL)
            g_propagate_prefixed_error (error, g_steal_pointer (&client_error), "nbd-client could not connect: ");
        else
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "The kernel did not confirm this NBD client.");
        return FALSE;
    }

    guint64 sectors, readonly;
    gboolean recorded = write_record (*index, uid, token, identity, error);
    gboolean valid = success && read_number (*index, "size", &sectors) && sectors == capacity / 512 &&
                     read_number (*index, "ro", &readonly) && readonly == (guint64) read_only;
    if (valid && recorded) {
        g_autofree char *verified = majoris_nbd_token (*index, uid);
        if (g_strcmp0 (verified, token) == 0)
            return TRUE;
    }

    g_autoptr(GError) rollback = NULL;
    block = claim_device (*index);
    if (block < 0 || !disconnect_client (*index, &block, identity, &rollback)) {
        *uncertain = TRUE;
        if (error != NULL && *error == NULL)
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not roll back the NBD mapping.");
        return FALSE;
    }
    g_autofree char *record = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", *index);
    if (recorded)
        g_unlink (record);
    if (error != NULL && *error == NULL)
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The attached NBD capacity or access mode could not be verified.");
    return FALSE;
}

static gboolean
authorize (GDBusConnection *bus, const char *sender, guint32 *uid, GError **error)
{
    g_autoptr(GVariant) user = g_dbus_connection_call_sync (bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixUser",
        g_variant_new ("(s)", sender), G_VARIANT_TYPE ("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, error);
    if (user == NULL) return FALSE;
    g_variant_get (user, "(u)", uid);
    GVariantBuilder subject;
    g_variant_builder_init (&subject, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add (&subject, "{sv}", "name", g_variant_new_string (sender));
    g_autoptr(GVariant) result = g_dbus_connection_call_sync (bus, "org.freedesktop.PolicyKit1",
        "/org/freedesktop/PolicyKit1/Authority", "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization",
        g_variant_new ("((sa{sv})s@a{ss}us)", "system-bus-name", &subject, ACTION,
            g_variant_new_array (G_VARIANT_TYPE ("{ss}"), NULL, 0), 1u, ""),
        G_VARIANT_TYPE ("((bba{ss}))"), G_DBUS_CALL_FLAGS_NONE, 120000, NULL, error);
    if (result == NULL) return FALSE;
    g_autoptr(GVariant) decision = g_variant_get_child_value (result, 0);
    g_autoptr(GVariant) granted = g_variant_get_child_value (decision, 0);
    if (g_variant_get_boolean (granted)) {
        g_autoptr(GVariant) still_connected = g_dbus_connection_call_sync (bus, "org.freedesktop.DBus",
            "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", g_variant_new ("(s)", sender),
            G_VARIANT_TYPE ("(b)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, error);
        gboolean present = FALSE;
        if (still_connected == NULL) return FALSE;
        g_variant_get (still_connected, "(b)", &present);
        if (present) return TRUE;
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_CANCELLED, "The requesting application disconnected.");
        return FALSE;
    }
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "NBD authorization was denied.");
    return FALSE;
}

static int
lock_state (GError **error)
{
    struct stat info;
    if (g_mkdir (MAJORIS_NBD_STATE, 0755) != 0 && errno != EEXIST)
        goto failed;
    if (lstat (MAJORIS_NBD_STATE, &info) != 0 || !S_ISDIR (info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 0022) != 0)
        goto failed;
    int fd = open (MAJORIS_NBD_STATE "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0 && flock (fd, LOCK_EX | LOCK_NB) == 0)
        return fd;
    if (fd >= 0)
        close (fd);
failed:
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY, "The system NBD allocation lock is unavailable.");
    return -1;
}

static gboolean
token_in_use (guint uid, const char *token)
{
    g_autoptr(GDir) records = g_dir_open (MAJORIS_NBD_STATE, 0, NULL);
    if (records == NULL)
        return TRUE;
    const char *name;
    while ((name = g_dir_read_name (records)) != NULL) {
        guint64 index;
        if (!g_str_has_prefix (name, "nbd") ||
            !g_ascii_string_to_unsigned (name + 3, 10, 0, G_MAXUINT, &index, NULL))
            continue;
        g_autofree char *current = majoris_nbd_token (index, uid);
        if (g_strcmp0 (current, token) == 0)
            return TRUE;
        guint64 size;
        if (!has_client (index) && read_number (index, "size", &size) && size == 0) {
            g_autofree char *stale = g_build_filename (MAJORIS_NBD_STATE, name, NULL);
            g_unlink (stale);
        }
    }
    return FALSE;
}

static gboolean
detach_device (guint uid, guint index, const char *token, GError **error)
{
    int block __attribute__((cleanup(close_fd))) = claim_device (index);
    g_autofree char *identity = majoris_nbd_identity (index, NULL);
    g_autofree char *owner = majoris_nbd_token (index, uid);
    if (identity == NULL || g_strcmp0 (owner, token) != 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "NBD attachment ownership could not be verified.");
        return FALSE;
    }
    if (block < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY, "The NBD device or one of its partitions is in use.");
        return FALSE;
    }
    if (!disconnect_client (index, &block, identity, error))
        return FALSE;
    g_autofree char *path = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", index);
    if (g_unlink (path) != 0 && errno != ENOENT)
        g_warning ("Could not remove inactive NBD record: %s", g_strerror (errno));
    return TRUE;
}

static void
method_call (GDBusConnection *bus, const char *sender, const char *path, const char *interface,
             const char *method, GVariant *arguments, GDBusMethodInvocation *invocation, gpointer unused)
{
    g_autoptr(GError) error = NULL;
    guint32 uid, index = 0;
    const char *token;
    guint64 capacity = 0;
    gboolean read_only = TRUE;
    gboolean attach = g_str_equal (method, "Attach");
    if (attach)
        g_variant_get (arguments, "(&stb)", &token, &capacity, &read_only);
    else
        g_variant_get (arguments, "(u&s)", &index, &token);
    if (!g_uuid_string_is_valid (token) ||
        (attach && (capacity == 0 || capacity > G_MAXINT64 || capacity % 512 != 0))) {
        g_dbus_method_invocation_return_error_literal (invocation, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
            "Invalid NBD attachment parameters.");
        return;
    }
    if (!authorize (bus, sender, &uid, &error)) {
        g_dbus_method_invocation_return_gerror (invocation, error);
        return;
    }
    int lock __attribute__((cleanup(close_fd))) = lock_state (&error);
    if (lock >= 0) {
        if (!attach && detach_device (uid, index, token, &error)) {
            g_dbus_method_invocation_return_value (invocation, NULL);
            return;
        }
        if (attach && token_in_use (uid, token))
            g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_EXISTS, "This NBD token is already attached.");
        else if (attach) {
            gboolean uncertain = FALSE;
            if (attach_device (uid, token, capacity, read_only, &index, &uncertain, &error)) {
                g_dbus_method_invocation_return_value (invocation, g_variant_new ("(u)", index));
                return;
            }
            if (uncertain) {
                g_dbus_method_invocation_return_dbus_error (invocation, BUS_NAME ".Error.Uncertain", error->message);
                return;
            }
        }
    }
    g_dbus_method_invocation_return_gerror (invocation, error);
}

int
main (void)
{
    static const char xml[] = "<node><interface name='" BUS_NAME "'>"
        "<method name='Attach'><arg type='s' direction='in'/><arg type='t' direction='in'/>"
        "<arg type='b' direction='in'/><arg type='u' direction='out'/></method>"
        "<method name='Detach'><arg type='u' direction='in'/><arg type='s' direction='in'/></method>"
        "</interface></node>";
    static const GDBusInterfaceVTable vtable = { .method_call = method_call };
    if (geteuid () != 0) return 1;
    g_autoptr(GError) error = NULL;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync (G_BUS_TYPE_SYSTEM, NULL, &error);
    g_autoptr(GDBusNodeInfo) schema = g_dbus_node_info_new_for_xml (xml, NULL);
    if (bus == NULL || g_dbus_connection_register_object (bus, OBJECT_PATH, schema->interfaces[0],
        &vtable, NULL, NULL, &error) == 0) {
        g_printerr ("%s\n", error->message);
        return 1;
    }
    g_autoptr(GMainLoop) loop = g_main_loop_new (NULL, FALSE);
    guint owner = g_bus_own_name_on_connection (bus, BUS_NAME, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
    g_main_loop_run (loop);
    g_bus_unown_name (owner);
    return 0;
}
