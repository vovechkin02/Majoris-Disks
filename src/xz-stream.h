#pragma once

#include <gio/gio.h>

typedef void (*MajorisXzProgress) (guint64 compressed, guint64 expanded, gpointer data);

gboolean majoris_xz_decode (GInputStream *input, GOutputStream *output, guint64 limit,
                            GCancellable *cancellable, MajorisXzProgress progress, gpointer progress_data,
                            guint64 *size, char **digest, GError **error);
gboolean majoris_xz_encode (GInputStream *input, GOutputStream *output, guint64 size,
                            GCancellable *cancellable, MajorisXzProgress progress, gpointer progress_data,
                            char **digest, GError **error);
char *majoris_image_identity (int fd);
gboolean majoris_image_require_raw (int fd, guint64 size, GError **error);
gboolean majoris_image_match_loop (int block, const char *backing, GError **error);
