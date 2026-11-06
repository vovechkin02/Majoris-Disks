#pragma once

#include <gio/gio.h>

typedef void (*MajorisXzProgress) (guint64 compressed, guint64 expanded, gpointer data);

gboolean majoris_xz_decode (GInputStream *input, GOutputStream *output, guint64 limit,
                            GCancellable *cancellable, MajorisXzProgress progress, gpointer progress_data,
                            guint64 *size, char **digest, GError **error);
char *majoris_image_identity (int fd);
