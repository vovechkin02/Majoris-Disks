/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <gio/gio.h>
#include <fcntl.h>
#include <linux/genetlink.h>
#include <linux/nbd.h>
#include <linux/nbd-netlink.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define BUS_NAME "com.majoris.disks.Nbd"
#define OBJECT_PATH "/com/majoris/disks/Nbd"
#define ACTION BUS_NAME ".manage"

typedef struct {
    struct nlmsghdr header;
    struct genlmsghdr generic;
    guint8 attributes[512];
} Request;

static struct nlattr *
append (Request *request, guint16 type, const void *value, guint16 size)
{
    struct nlattr *attribute = (void *) ((guint8 *) request + request->header.nlmsg_len);
    attribute->nla_type = type;
    attribute->nla_len = NLA_HDRLEN + size;
    if (size != 0)
        memcpy ((guint8 *) attribute + NLA_HDRLEN, value, size);
    request->header.nlmsg_len += NLA_ALIGN (attribute->nla_len);
    return attribute;
}

static gboolean
exchange (int fd, Request *request, guint16 field, void *value, gsize size, GError **error)
{
    struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
    if (sendto (fd, request, request->header.nlmsg_len, 0, (void *) &kernel, sizeof kernel) < 0)
        goto failure;

    for (;;) {
        union { struct nlmsghdr align; guint8 bytes[8192]; } buffer;
        struct sockaddr_nl sender;
        socklen_t sender_size = sizeof sender;
        ssize_t received = recvfrom (fd, buffer.bytes, sizeof buffer.bytes, 0, (void *) &sender, &sender_size);
        if (received < 0)
            goto failure;
        if (received == 0 || sender_size != sizeof sender || sender.nl_pid != 0) {
            errno = EPROTO;
            goto failure;
        }
        int remaining = received;
        for (struct nlmsghdr *message = &buffer.align; NLMSG_OK (message, remaining);
             message = NLMSG_NEXT (message, remaining)) {
            if (message->nlmsg_seq != request->header.nlmsg_seq)
                continue;
            if (message->nlmsg_type == NLMSG_ERROR && message->nlmsg_len >= NLMSG_LENGTH (sizeof (struct nlmsgerr))) {
                struct nlmsgerr *reply = NLMSG_DATA (message);
                if (reply->error) {
                    errno = -reply->error;
                    goto failure;
                }
                if (field == 0)
                    return TRUE;
                continue;
            }
            if (message->nlmsg_len < NLMSG_LENGTH (GENL_HDRLEN))
                continue;
            guint8 *cursor = (guint8 *) NLMSG_DATA (message) + GENL_HDRLEN;
            gsize left = message->nlmsg_len - NLMSG_LENGTH (GENL_HDRLEN);
            while (left >= NLA_HDRLEN) {
                struct nlattr *attribute = (void *) cursor;
                if (attribute->nla_len < NLA_HDRLEN || NLA_ALIGN (attribute->nla_len) > left)
                    break;
                if ((attribute->nla_type & NLA_TYPE_MASK) == field && attribute->nla_len == NLA_HDRLEN + size) {
                    memcpy (value, cursor + NLA_HDRLEN, size);
                    return TRUE;
                }
                left -= NLA_ALIGN (attribute->nla_len);
                cursor += NLA_ALIGN (attribute->nla_len);
            }
        }
    }
failure:
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Kernel NBD request failed: %s", g_strerror (errno));
    return FALSE;
}

static Request
request_for (guint16 family, guint8 command, guint32 sequence)
{
    Request request = { 0 };
    request.header.nlmsg_len = NLMSG_LENGTH (GENL_HDRLEN);
    request.header.nlmsg_type = family;
    request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    request.header.nlmsg_seq = sequence;
    request.generic.cmd = command;
    request.generic.version = 1;
    return request;
}

static int
open_netlink (guint16 *family, GError **error)
{
    int fd = socket (AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC);
    struct timeval timeout = { .tv_sec = 10 };
    if (fd < 0 || setsockopt (fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) != 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Cannot open NBD netlink: %s", g_strerror (errno));
        if (fd >= 0) close (fd);
        return -1;
    }
    Request query = request_for (GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 1);
    append (&query, CTRL_ATTR_FAMILY_NAME, "nbd", 4);
    if (!exchange (fd, &query, CTRL_ATTR_FAMILY_ID, family, sizeof *family, error)) {
        close (fd);
        return -1;
    }
    return fd;
}

static gboolean
connect_device (int socket_fd, guint64 capacity, guint64 sector, guint64 flags, const char *identity,
                guint32 *index, GError **error)
{
    guint16 family;
    int fd = open_netlink (&family, error);
    if (fd < 0) return FALSE;
    Request request = request_for (family, NBD_CMD_CONNECT, 2);
    guint64 timeout = 30;
    guint64 client_flags = NBD_CFLAG_DESTROY_ON_DISCONNECT;
    guint32 socket_number = socket_fd;
    append (&request, NBD_ATTR_SIZE_BYTES, &capacity, sizeof capacity);
    append (&request, NBD_ATTR_BLOCK_SIZE_BYTES, &sector, sizeof sector);
    append (&request, NBD_ATTR_SERVER_FLAGS, &flags, sizeof flags);
    append (&request, NBD_ATTR_CLIENT_FLAGS, &client_flags, sizeof client_flags);
    append (&request, NBD_ATTR_TIMEOUT, &timeout, sizeof timeout);
    append (&request, NBD_ATTR_BACKEND_IDENTIFIER, identity, strlen (identity) + 1);
    struct nlattr *sockets = append (&request, NBD_ATTR_SOCKETS | NLA_F_NESTED, NULL, 0);
    struct nlattr *item = append (&request, NBD_SOCK_ITEM | NLA_F_NESTED, NULL, 0);
    append (&request, NBD_SOCK_FD, &socket_number, sizeof socket_number);
    item->nla_len = (guint8 *) &request + request.header.nlmsg_len - (guint8 *) item;
    sockets->nla_len = (guint8 *) &request + request.header.nlmsg_len - (guint8 *) sockets;
    gboolean ok = exchange (fd, &request, NBD_ATTR_INDEX, index, sizeof *index, error);
    close (fd);
    return ok;
}

static gboolean
find_attachment (const char *identity, guint32 *index)
{
    g_autoptr(GDir) devices = g_dir_open ("/sys/block", 0, NULL);
    if (devices == NULL) return FALSE;
    const char *name;
    while ((name = g_dir_read_name (devices)) != NULL) {
        if (!g_str_has_prefix (name, "nbd")) continue;
        const char *suffix = name + 3;
        if (*suffix == 0 || strspn (suffix, "0123456789") != strlen (suffix)) continue;
        guint64 number = g_ascii_strtoull (suffix, NULL, 10);
        if (number > G_MAXUINT32) continue;
        g_autofree char *path = g_build_filename ("/sys/block", name, "backend", NULL);
        g_autofree char *actual = NULL;
        if (g_file_get_contents (path, &actual, NULL, NULL) && g_str_equal (g_strstrip (actual), identity)) {
            *index = (guint32) number;
            return TRUE;
        }
    }
    return FALSE;
}

static gboolean
owns_device (guint32 index, const char *identity, dev_t expected)
{
    g_autofree char *base = g_strdup_printf ("/sys/block/nbd%u", index);
    g_autofree char *backend = g_build_filename (base, "backend", NULL);
    g_autofree char *dev = g_build_filename (base, "dev", NULL);
    g_autofree char *stored = NULL;
    g_autofree char *number = NULL;
    g_autofree char *expected_number = g_strdup_printf ("%u:%u", major (expected), minor (expected));
    return g_file_get_contents (backend, &stored, NULL, NULL) &&
           g_file_get_contents (dev, &number, NULL, NULL) &&
           g_str_equal (g_strstrip (stored), identity) && g_str_equal (g_strstrip (number), expected_number);
}

static gboolean
disconnect_device (guint32 index, const char *identity, GError **error)
{
    g_autofree char *path = g_strdup_printf ("/dev/nbd%u", index);
    int block = open (path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_EXCL);
    if (block < 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Cannot claim the NBD device: %s", g_strerror (errno));
        return FALSE;
    }
    struct stat info;
    gboolean ok = FALSE;
    if (fstat (block, &info) != 0 || !S_ISBLK (info.st_mode) || !owns_device (index, identity, info.st_rdev)) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "NBD attachment ownership does not match.");
    } else {
        guint16 family;
        int fd = open_netlink (&family, error);
        if (fd >= 0) {
            Request request = request_for (family, NBD_CMD_DISCONNECT, 2);
            append (&request, NBD_ATTR_INDEX, &index, sizeof index);
            ok = exchange (fd, &request, 0, NULL, 0, error);
            close (fd);
        }
    }
    close (block);
    return ok;
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

static void
method_call (GDBusConnection *bus, const char *sender, const char *path, const char *interface,
             const char *method, GVariant *arguments, GDBusMethodInvocation *invocation, gpointer unused)
{
    g_autoptr(GError) error = NULL;
    g_autofree char *identity = NULL;
    guint32 uid, index;
    const char *token;
    gboolean attach = g_str_equal (method, "Attach");
    if (!attach && !g_str_equal (method, "Detach")) {
        g_dbus_method_invocation_return_error_literal (invocation, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Unknown NBD operation.");
        return;
    }
    gint32 handle = -1;
    guint64 capacity = 0, sector = 0, flags = 0;
    if (attach)
        g_variant_get (arguments, "(h&sttt)", &handle, &token, &capacity, &sector, &flags);
    else
        g_variant_get (arguments, "(u&s)", &index, &token);
    if (!g_uuid_string_is_valid (token) ||
        (attach && (sector < 512 || sector > 4096 || (sector & (sector - 1)) != 0 ||
         capacity == 0 || capacity > G_MAXINT64 || capacity % sector != 0 ||
         (flags & ~(guint64) (NBD_FLAG_HAS_FLAGS | NBD_FLAG_READ_ONLY | NBD_FLAG_SEND_FLUSH | NBD_FLAG_SEND_FUA)) != 0 ||
         (flags & NBD_FLAG_HAS_FLAGS) == 0))) {
        g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Invalid NBD attachment parameters.");
        goto done;
    }
    if (!authorize (bus, sender, &uid, &error)) goto done;
    identity = g_strdup_printf ("majoris:%u:%s", uid, token);
    if (attach) {
        if (find_attachment (identity, &index)) {
            g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_EXISTS, "This attachment token is already connected.");
            goto done;
        }
        GUnixFDList *list = g_dbus_message_get_unix_fd_list (g_dbus_method_invocation_get_message (invocation));
        int fd = list != NULL && handle >= 0 && handle < g_unix_fd_list_get_length (list) ?
                 g_unix_fd_list_get (list, handle, &error) : -1;
        if (fd < 0) {
            if (error == NULL) g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Missing NBD socket.");
            goto done;
        }
        struct sockaddr_storage peer;
        struct ucred credentials;
        int type;
        socklen_t peer_size = sizeof peer, credentials_size = sizeof credentials, type_size = sizeof type;
        if (getpeername (fd, (struct sockaddr *) &peer, &peer_size) != 0 || peer.ss_family != AF_UNIX ||
            getsockopt (fd, SOL_SOCKET, SO_TYPE, &type, &type_size) != 0 || type != SOCK_STREAM ||
            getsockopt (fd, SOL_SOCKET, SO_PEERCRED, &credentials, &credentials_size) != 0 || credentials.uid != uid) {
            g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "The NBD export must be a local socket owned by the caller.");
            close (fd);
            goto done;
        }
        gboolean ok = connect_device (fd, capacity, sector, flags, identity, &index, &error);
        close (fd);
        if (!ok) {
            if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_WOULD_BLOCK) ||
                g_error_matches (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT)) {
                if (find_attachment (identity, &index))
                    g_dbus_method_invocation_return_value (invocation, g_variant_new ("(u)", index));
                else
                    g_dbus_method_invocation_return_dbus_error (invocation, BUS_NAME ".Error.Uncertain",
                        "The kernel did not confirm the connection. Keep the attachment record for reconciliation.");
                return;
            }
            goto done;
        }
        g_dbus_method_invocation_return_value (invocation, g_variant_new ("(u)", index));
    } else {
        if (!disconnect_device (index, identity, &error)) goto done;
        g_dbus_method_invocation_return_value (invocation, NULL);
    }
    return;
done:
    g_dbus_method_invocation_return_gerror (invocation, error);
}

int
main (void)
{
    static const char xml[] = "<node><interface name='" BUS_NAME "'>"
        "<method name='Attach'><arg type='h' direction='in'/><arg type='s' direction='in'/>"
        "<arg type='t' direction='in'/><arg type='t' direction='in'/><arg type='t' direction='in'/>"
        "<arg type='u' direction='out'/></method>"
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
