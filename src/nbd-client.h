#pragma once
#include <gio/gio.h>
gboolean majoris_nbd_client_available (void);
int majoris_nbd_negotiate (const char *path, guint64 expected_size, gboolean read_only,
                           GCancellable *token, guint64 *sector, guint64 *flags, GError **error);
