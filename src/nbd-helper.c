/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nbd-identity.h"
#include <gio/gio.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <stdio.h>
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
#ifdef MAJORIS_TEST_NBD_IOCTL
        guint64 readonly;
        if (!read_number (candidate, "ro", &readonly) || readonly != 0) {
            close (fd);
            continue;
        }
#endif
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

static void
reap_client (GPid *pid)
{
    if (*pid <= 0)
        return;
    while (waitpid (*pid, NULL, 0) < 0 && errno == EINTR) {}
}

static gboolean
spawn_client (const char *const *argv, int endpoint, GPid *pid, GError **error)
{
    const int socket_fd = 3;
    return g_spawn_async_with_pipes_and_fds (NULL, argv, NULL,
        G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL,
        NULL, NULL, -1, -1, -1, &endpoint, &socket_fd, endpoint >= 0 ? 1 : 0,
        pid, NULL, NULL, NULL, error);
}

static gboolean
run_client (const char *const *argv, int endpoint, GPid *pid, GError **error)
{
    if (!spawn_client (argv, endpoint, pid, error))
        return FALSE;
    gint64 deadline = g_get_monotonic_time () + 20 * G_TIME_SPAN_SECOND;
    do {
        siginfo_t info = { 0 };
        // Reserve the PID through kernel identification and publication of the ownership record.
        if (waitid (P_PID, *pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0) {
            if (info.si_pid == *pid) {
                int status = info.si_code == CLD_EXITED ? info.si_status << 8 : info.si_status;
                return g_spawn_check_wait_status (status, error);
            }
        } else if (errno != EINTR) {
            g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Could not wait for nbd-client: %s", g_strerror (errno));
            return FALSE;
        }
        g_usleep (10000);
    } while (g_get_monotonic_time () < deadline);

    kill (*pid, SIGKILL);
    siginfo_t info;
    while (waitid (P_PID, *pid, &info, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
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
    const char *argv[] = { MAJORIS_NBD_CLIENT,
#ifdef MAJORIS_TEST_NBD_IOCTL
        "-nonetlink",
#endif
        "-d", path, NULL };
    GPid pid __attribute__((cleanup(reap_client))) = 0;
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

static char *
client_start_time (GPid pid, gboolean *running)
{
    g_autofree char *path = g_strdup_printf ("/proc/%d/stat", pid);
    g_autofree char *status = NULL;
    if (!g_file_get_contents (path, &status, NULL, NULL))
        return NULL;
    const char *name_end = strrchr (status, ')');
    if (name_end == NULL || !g_str_has_prefix (name_end, ") "))
        return NULL;
    g_auto(GStrv) fields = g_strsplit (name_end + 2, " ", 21);
    if (g_strv_length (fields) < 20)
        return NULL;
    if (running != NULL)
        *running = !g_str_equal (fields[0], "Z") && !g_str_equal (fields[0], "X");
    return g_strdup (fields[19]);
}

static gboolean
write_record (guint index, guint uid, const char *token, const char *identity, const char *phase, GPid client, GError **error)
{
    g_autofree char *path = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", index);
    g_autoptr(GKeyFile) record = g_key_file_new ();
    if (!g_str_equal (phase, "connecting")) {
        g_key_file_load_from_file (record, path, G_KEY_FILE_NONE, NULL);
        g_autofree char *previous = g_key_file_get_string (record, "attachment", "token", NULL);
        if (g_strcmp0 (previous, token) != 0 || g_key_file_get_uint64 (record, "attachment", "uid", NULL) != uid)
            g_clear_pointer (&record, g_key_file_unref);
        if (record == NULL)
            record = g_key_file_new ();
    }
    if (client > 0) {
        g_autofree char *start = client_start_time (client, NULL);
        if (start == NULL) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not establish the NBD client start identity.");
            return FALSE;
        }
        g_key_file_set_uint64 (record, "attachment", "client-pid", client);
        g_key_file_set_string (record, "attachment", "client-start", start);
    }
    g_key_file_set_uint64 (record, "attachment", "uid", uid);
    g_key_file_set_string (record, "attachment", "token", token);
    if (identity != NULL)
        g_key_file_set_string (record, "attachment", "identity", identity);
    g_key_file_set_string (record, "attachment", "state", phase);
    gsize length;
    g_autofree char *data = g_key_file_to_data (record, &length, NULL);
    return g_file_set_contents_full (path, data, length, G_FILE_SET_CONTENTS_CONSISTENT, 0644, error);
}

typedef char *(*ConnectionProbe) (GPid pid, gpointer data);

static char *
wait_for_connection (GPid pid, ConnectionProbe probe, gpointer data, gint64 timeout, GError **error)
{
    gint64 deadline = g_get_monotonic_time () + timeout;
    do {
        char *identity = probe (pid, data);
        if (identity != NULL)
            return identity;

        siginfo_t info = { 0 };
        if (waitid (P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
            if (errno == EINTR)
                continue;
            g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Could not check nbd-client: %s", g_strerror (errno));
            return NULL;
        }
        // Netlink clients normally exit successfully after handing the connection to the kernel.
        if (info.si_pid == pid && (info.si_code != CLD_EXITED || info.si_status != 0)) {
            // A client can fail after the kernel accepted its request.
            identity = probe (pid, data);
            if (identity != NULL)
                return identity;
            int status = info.si_code == CLD_EXITED ? info.si_status << 8 : info.si_status;
            g_spawn_check_wait_status (status, error);
            return NULL;
        }
        g_usleep (10000);
    } while (g_get_monotonic_time () < deadline);

    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "The kernel did not confirm the NBD connection in time.");
    return NULL;
}

static char *
probe_attachment (GPid pid, gpointer data)
{
    guint index = GPOINTER_TO_UINT (data), kernel_pid = 0;
    guint64 size;
    g_autofree char *identity = majoris_nbd_identity (index, &kernel_pid);
    // Debian netlink installs the configuration in the calling process. The foreground ioctl
    // path publishes the NBD_DO_IT caller, while its partition-probing child does not own it.
    if (kernel_pid != (guint) pid || !read_number (index, "size", &size) || size == 0)
        return NULL;
    return g_steal_pointer (&identity);
}

static gboolean
await_launch (int fd)
{
    char permit;
    ssize_t bytes;
    do {
        bytes = read (fd, &permit, 1);
    } while (bytes < 0 && errno == EINTR);
    close (fd);
    return bytes == 1 && permit == '1';
}

static int
connect_client (char **argv)
{
    guint64 index;
    if (!g_ascii_string_to_unsigned (argv[2], 10, 0, G_MAXINT, &index, NULL) ||
        !g_uuid_string_is_valid (argv[3]) ||
        (!g_str_equal (argv[4], "0") && !g_str_equal (argv[4], "1")) ||
        !await_launch (4))
        return 1;
    g_autofree char *path = g_strdup_printf ("/dev/nbd%u", (guint) index);
    const char *client[] = { MAJORIS_NBD_CLIENT,
#ifdef MAJORIS_TEST_NBD_IOCTL
        "-nonetlink",
#endif
        "-unix", "/proc/self/fd/3", path, "-name", argv[3],
        "-nofork", "-timeout", "30", g_str_equal (argv[4], "1") ? "-readonly" : NULL, NULL };
    execv (MAJORIS_NBD_CLIENT, (char *const *) client);
    return 1;
}

static gboolean
attach_device (guint uid, const char *token, guint64 capacity, gboolean read_only,
               guint *index, GPid *client, gboolean *uncertain, GError **error)
{
    int endpoint __attribute__((cleanup(close_fd))) = export_socket (uid, token);
    if (endpoint < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "The private NBD socket could not be verified.");
        return FALSE;
    }
    int block __attribute__((cleanup(close_fd))) = allocate_device (index, error);
    if (block < 0)
        return FALSE;
    int probe __attribute__((cleanup(close_fd))) = verify_exporter (endpoint, uid);
    if (probe < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "The NBD socket peer is not the caller's QEMU exporter.");
        return FALSE;
    }
    g_autofree char *device = g_strdup_printf ("%u", *index);
    const char *argv[] = { "/proc/self/exe", "--connect-client", device, token, read_only ? "1" : "0", NULL };
    g_autofree char *journal = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", *index);
    if (!write_record (*index, uid, token, NULL, "connecting", 0, error))
        return FALSE;

    guint64 idle_size;
    if (has_client (*index) || !read_number (*index, "size", &idle_size) || idle_size != 0) {
        g_unlink (journal);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY, "The selected NBD device became busy.");
        return FALSE;
    }
    int gate[2];
    if (socketpair (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, gate) != 0) {
        g_unlink (journal);
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Could not create the NBD launch gate: %s", g_strerror (errno));
        return FALSE;
    }
    int permit __attribute__((cleanup(close_fd))) = gate[0];
    const int sources[] = { endpoint, gate[1] };
    const int targets[] = { 3, 4 };
    gboolean spawned = g_spawn_async_with_pipes_and_fds (NULL, argv, NULL,
        G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL, NULL, NULL,
        -1, -1, -1, sources, targets, G_N_ELEMENTS (sources), client, NULL, NULL, NULL, error);
    close (gate[1]);
    if (!spawned) {
        g_unlink (journal);
        return FALSE;
    }

    // A missing journal cannot leave a live mapping. The child exits on EOF unless explicitly released.
    if (!write_record (*index, uid, token, NULL, "client-launched", *client, error)) {
        g_unlink (journal);
        return FALSE;
    }
    if (has_client (*index) || !read_number (*index, "size", &idle_size) || idle_size != 0) {
        g_unlink (journal);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY, "The selected NBD device became busy.");
        return FALSE;
    }
    // The kernel will only accept a netlink connection once this temporary configuration closes.
    close_fd (&block);
    block = -1;
    ssize_t sent;
    do {
        sent = send (permit, "1", 1, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent != 1) {
        g_unlink (journal);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "The NBD client exited before launch was permitted.");
        return FALSE;
    }

    g_autoptr(GError) readiness_error = NULL;
    g_autofree char *identity = wait_for_connection (*client, probe_attachment, GUINT_TO_POINTER (*index),
        20 * G_TIME_SPAN_SECOND, &readiness_error);
    guint observed_pid = 0;
    g_autofree char *observed = identity == NULL ? majoris_nbd_identity (*index, &observed_pid) : NULL;
    if (identity == NULL && (!has_client (*index) || (observed != NULL && observed_pid != (guint) *client))) {
        // Cancel only our still-reserved child. A connection racing the timeout can still
        // survive in the kernel, so wait for the child and inspect ownership again.
        kill (*client, SIGKILL);
        siginfo_t stopped;
        while (waitid (P_PID, *client, &stopped, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
    }
    if (identity == NULL) {
        guint kernel_pid = 0;
        identity = majoris_nbd_identity (*index, &kernel_pid);
        if (kernel_pid != (guint) *client) {
            *uncertain = identity == NULL && has_client (*index);
            if (!*uncertain)
                g_unlink (journal);
            g_propagate_error (error, g_steal_pointer (&readiness_error));
            return FALSE;
        }
    }

    gboolean recorded = write_record (*index, uid, token, identity, "connected-unverified", *client, error);
    gboolean valid = FALSE;
    guint64 sectors = 0, readonly = G_MAXUINT64;
    ssize_t received = -1;
    int read_error = 0;
    // Observe the single accepted connection until its block properties are
    // published. A netlink reply alone does not establish block readiness.
    gint64 deadline = g_get_monotonic_time () + 2 * G_TIME_SPAN_SECOND;
    do {
        g_autofree char *current = majoris_nbd_identity (*index, NULL);
        if (g_strcmp0 (current, identity) != 0)
            break;
        if (block < 0)
            block = claim_device (*index);
        g_autofree char *claimed = block >= 0 ? majoris_nbd_identity (*index, NULL) : NULL;
        if (block >= 0 && g_strcmp0 (claimed, identity) != 0) {
            close_fd (&block);
            block = -1;
            break;
        }
        if (readiness_error == NULL && recorded && block >= 0 &&
            read_number (*index, "size", &sectors) && sectors == capacity / 512 &&
            read_number (*index, "ro", &readonly) && readonly == (guint64) read_only) {
            char sector[512];
            do {
                received = pread (block, sector, sizeof sector, 0);
            } while (received < 0 && errno == EINTR);
            read_error = received < 0 ? errno : 0;
            g_autofree char *after = majoris_nbd_identity (*index, NULL);
            if (g_strcmp0 (after, identity) != 0)
                break;
            if (received == sizeof sector) {
                valid = TRUE;
                break;
            }
        }
        if (readiness_error != NULL || !recorded)
            break;
        g_usleep (20000);
    } while (g_get_monotonic_time () < deadline);
    if (valid && write_record (*index, uid, token, identity, "attached-verified", *client, error))
        return TRUE;

    g_autoptr(GError) rollback = NULL;
    if (block < 0 || !disconnect_client (*index, &block, identity, &rollback)) {
        *uncertain = TRUE;
        if (error != NULL && *error == NULL)
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not roll back the NBD mapping.");
        return FALSE;
    }
    g_unlink (journal);
    if (error != NULL && *error == NULL)
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
            "The attached NBD mapping could not be verified (sectors %" G_GUINT64_FORMAT
            "/%" G_GUINT64_FORMAT ", read-only %" G_GUINT64_FORMAT "/%d, read %zd, errno %d).",
            sectors, capacity / 512, readonly, read_only, received, read_error);
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
    g_autoptr(GError) journal_error = NULL;
    if (!write_record (index, uid, token, identity, "disconnecting", 0, &journal_error))
        g_warning ("Could not update the NBD journal before detaching: %s", journal_error->message);
    if (!disconnect_client (index, &block, identity, error))
        return FALSE;
    g_autofree char *path = g_strdup_printf (MAJORIS_NBD_STATE "/nbd%u", index);
    g_autoptr(GKeyFile) record = g_key_file_new ();
    if (g_key_file_load_from_file (record, path, G_KEY_FILE_NONE, NULL)) {
        guint64 pid = g_key_file_get_uint64 (record, "attachment", "client-pid", NULL);
        g_autofree char *expected = g_key_file_get_string (record, "attachment", "client-start", NULL);
        if (pid > 0 && pid <= G_MAXINT && expected != NULL) {
            for (guint i = 0; ; i++) {
                gboolean running = FALSE;
                g_autofree char *start = client_start_time ((GPid) pid, &running);
                if (!running || g_strcmp0 (start, expected) != 0)
                    break;
                if (i == 50) {
                    write_record (index, uid, token, identity, "client-cleanup-pending", 0, NULL);
                    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                        "The kernel disconnected the NBD device, but the foreground client is still running.");
                    return FALSE;
                }
                g_usleep (100000);
            }
        }
    }
    if (g_unlink (path) != 0 && errno != ENOENT)
        g_warning ("Could not remove inactive NBD record: %s", g_strerror (errno));
    return TRUE;
}

static int
attach_worker (char **argv)
{
    guint64 uid, capacity;
    const char *token = argv[3];
    if (!g_ascii_string_to_unsigned (argv[2], 10, 0, G_MAXUINT, &uid, NULL) ||
        !g_uuid_string_is_valid (token) ||
        !g_ascii_string_to_unsigned (argv[4], 10, 512, G_MAXINT64, &capacity, NULL) ||
        capacity % 512 != 0 || (!g_str_equal (argv[5], "0") && !g_str_equal (argv[5], "1")))
        return 1;

    // The D-Bus helper passes its locked open file description. Keep it until the transaction ends.
    struct stat inherited, state;
    if (fstat (3, &inherited) != 0 || lstat (MAJORIS_NBD_STATE "/lock", &state) != 0 ||
        !S_ISREG (state.st_mode) || state.st_uid != 0 || (state.st_mode & 0022) != 0 ||
        inherited.st_dev != state.st_dev || inherited.st_ino != state.st_ino ||
        flock (3, LOCK_EX | LOCK_NB) != 0 || fcntl (3, F_SETFD, FD_CLOEXEC) != 0)
        return 1;

    guint index = 0;
    gboolean uncertain = FALSE;
    g_autoptr(GError) error = NULL;
    GPid client __attribute__((cleanup(reap_client))) = 0;
    gboolean success = attach_device (uid, token, capacity, g_str_equal (argv[5], "1"),
        &index, &client, &uncertain, &error);
    int code = error != NULL && error->domain == G_IO_ERROR ? error->code : G_IO_ERROR_FAILED;
    g_autoptr(GVariant) result = g_variant_ref_sink (g_variant_new ("(buibs)", success, index, code,
        uncertain, error != NULL ? error->message : ""));
    g_autofree char *serialized = g_variant_print (result, FALSE);
    close (3);
    // Continue supervising the client after the result channel closes. A lost caller must
    // not prevent reaping the child or accidentally signal a reused PID.
    signal (SIGPIPE, SIG_IGN);
    g_print ("%s\n", serialized);
    fflush (stdout);
    close (STDOUT_FILENO);
    return 0;
}

static gboolean
supervise_attachment (int lock, guint uid, const char *token, guint64 capacity, gboolean read_only,
                      guint *index, gboolean *uncertain, GError **error)
{
    int worker_lock = fcntl (lock, F_DUPFD_CLOEXEC, 4);
    if (worker_lock < 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not retain the system NBD allocation lock.");
        return FALSE;
    }

    g_autofree char *user = g_strdup_printf ("%u", uid);
    g_autofree char *bytes = g_strdup_printf ("%" G_GUINT64_FORMAT, capacity);
    const char *argv[] = { "/proc/self/exe", "--attach-worker", user, token, bytes, read_only ? "1" : "0", NULL };
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDOUT_PIPE);
    g_subprocess_launcher_take_fd (launcher, worker_lock, 3);
    g_autoptr(GSubprocess) worker = g_subprocess_launcher_spawnv (launcher, argv, error);
    if (worker == NULL)
        return FALSE;

    g_autofree char *output = NULL;
    *uncertain = TRUE;
    g_autoptr(GDataInputStream) results = g_data_input_stream_new (g_subprocess_get_stdout_pipe (worker));
    output = g_data_input_stream_read_line_utf8 (results, NULL, NULL, error);
    if (output == NULL) {
        if (error != NULL && *error == NULL)
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "The NBD worker exited before reporting a result.");
        return FALSE;
    }
    g_autoptr(GVariant) result = g_variant_parse (G_VARIANT_TYPE ("(buibs)"), output, NULL, NULL, error);
    if (result == NULL)
        return FALSE;

    gboolean success;
    gint code;
    const char *message;
    g_variant_get (result, "(buib&s)", &success, index, &code, uncertain, &message);
    if (!success)
        g_set_error_literal (error, G_IO_ERROR, code, message);
    return success;
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
            if (supervise_attachment (lock, uid, token, capacity, read_only, &index, &uncertain, &error)) {
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
main (int argc, char **argv)
{
    static const char xml[] = "<node><interface name='" BUS_NAME "'>"
        "<method name='Attach'><arg type='s' direction='in'/><arg type='t' direction='in'/>"
        "<arg type='b' direction='in'/><arg type='u' direction='out'/></method>"
        "<method name='Detach'><arg type='u' direction='in'/><arg type='s' direction='in'/></method>"
        "</interface></node>";
    static const GDBusInterfaceVTable vtable = { .method_call = method_call };
    if (geteuid () != 0) return 1;
    if (argc == 5 && g_str_equal (argv[1], "--connect-client"))
        return connect_client (argv);
    if (argc == 6 && g_str_equal (argv[1], "--attach-worker"))
        return attach_worker (argv);
    if (argc != 1) return 1;
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
