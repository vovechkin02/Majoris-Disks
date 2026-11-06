/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nbd-client.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <linux/nbd.h>
#include <stdbool.h>
#include <stdint.h>

struct nbd_handle;

gboolean
majoris_nbd_client_available (void)
{
    void *library = dlopen ("libnbd.so.0", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) return FALSE;
    dlclose (library);
    return TRUE;
}

int
majoris_nbd_negotiate (const char *path, guint64 expected_size, gboolean read_only,
                       GCancellable *token, guint64 *sector, guint64 *flags, GError **error)
{
    int result = -1;
    void *library = dlopen ("libnbd.so.0", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Install the libnbd runtime to attach virtual images.");
        return -1;
    }
    struct nbd_handle *(*create)(void) = dlsym (library, "nbd_create");
    void (*close_handle)(struct nbd_handle *) = dlsym (library, "nbd_close");
    int (*structured)(struct nbd_handle *, bool) = dlsym (library, "nbd_set_request_structured_replies");
    int (*extended)(struct nbd_handle *, bool) = dlsym (library, "nbd_set_request_extended_headers");
    int (*connect_unix)(struct nbd_handle *, const char *) = dlsym (library, "nbd_aio_connect_unix");
    int (*poll_handle)(struct nbd_handle *, int) = dlsym (library, "nbd_poll");
    int (*ready)(struct nbd_handle *) = dlsym (library, "nbd_aio_is_ready");
    int (*connecting)(struct nbd_handle *) = dlsym (library, "nbd_aio_is_connecting");
    int64_t (*get_size)(struct nbd_handle *) = dlsym (library, "nbd_get_size");
    int64_t (*block_size)(struct nbd_handle *, int) = dlsym (library, "nbd_get_block_size");
    int (*is_read_only)(struct nbd_handle *) = dlsym (library, "nbd_is_read_only");
    int (*can_flush)(struct nbd_handle *) = dlsym (library, "nbd_can_flush");
    int (*can_fua)(struct nbd_handle *) = dlsym (library, "nbd_can_fua");
    int (*get_fd)(struct nbd_handle *) = dlsym (library, "nbd_aio_get_fd");
    const char *(*get_error)(void) = dlsym (library, "nbd_get_error");
    if (!create || !close_handle || !structured || !connect_unix || !poll_handle || !ready ||
        !connecting || !get_size || !block_size || !is_read_only || !can_flush || !can_fua || !get_fd || !get_error) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "The installed libnbd runtime lacks required APIs.");
        goto unload;
    }

    struct nbd_handle *client = create ();
    if (client == NULL) goto protocol_error;
    if (structured (client, false) == -1 || (extended != NULL && extended (client, false) == -1) ||
        connect_unix (client, path) == -1)
        goto protocol_error;
    gint64 deadline = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;
    while (!ready (client)) {
        if (g_cancellable_set_error_if_cancelled (token, error)) goto close;
        if (!connecting (client) || poll_handle (client, 100) == -1) goto protocol_error;
        if (g_get_monotonic_time () >= deadline) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "The QEMU export handshake timed out.");
            goto close;
        }
    }
    int64_t size = get_size (client);
    int ro = is_read_only (client);
    int64_t minimum = block_size (client, 0); /* LIBNBD_SIZE_MINIMUM */
    *sector = MAX (512, minimum);
    *flags = NBD_FLAG_HAS_FLAGS | (read_only ? NBD_FLAG_READ_ONLY : 0);
    int flush = can_flush (client);
    if (!read_only && flush != 1) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "The export cannot safely flush writable data.");
        goto close;
    }
    if (flush == 1) *flags |= NBD_FLAG_SEND_FLUSH;
    if (can_fua (client) == 1) *flags |= NBD_FLAG_SEND_FUA;
    if (size <= 0 || (guint64) size != expected_size || ro != (int) read_only || minimum < 0 || *sector > 4096) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The NBD export geometry or access mode did not match the selected image.");
        goto close;
    }
    result = fcntl (get_fd (client), F_DUPFD_CLOEXEC, 3);
    if (result < 0)
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not retain the negotiated NBD socket.");
    goto close;

protocol_error:
    g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "NBD negotiation failed: %s", get_error ());
close:
    if (client != NULL) close_handle (client);
unload:
    dlclose (library);
    return result;
}
