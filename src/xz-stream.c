#include "xz-stream.h"

#include <lzma.h>
#include <sys/stat.h>

gboolean
majoris_xz_decode (GInputStream *input, GOutputStream *output, guint64 limit,
                   GCancellable *cancellable, MajorisXzProgress progress, gpointer progress_data,
                   guint64 *size, char **digest, GError **error)
{
    lzma_stream decoder = LZMA_STREAM_INIT;
    g_autofree guint8 *compressed = g_malloc (65536);
    g_autofree guint8 *expanded = g_malloc (65536);
    g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
    gboolean eof = FALSE;
    gboolean success = FALSE;
    guint64 produced = 0;
    gint64 last_update = g_get_monotonic_time ();
    *size = 0;
    *digest = NULL;

    lzma_ret status = lzma_stream_decoder (&decoder, 256ULL * 1024 * 1024, LZMA_CONCATENATED);
    while (status == LZMA_OK) {
        if (g_cancellable_set_error_if_cancelled (cancellable, error))
            goto done;
        if (!eof && decoder.avail_in == 0) {
            gssize count = g_input_stream_read (input, compressed, 65536, cancellable, error);
            if (count < 0)
                goto done;
            eof = count == 0;
            decoder.next_in = compressed;
            decoder.avail_in = count;
        }
        decoder.next_out = expanded;
        decoder.avail_out = 65536;
        status = lzma_code (&decoder, eof ? LZMA_FINISH : LZMA_RUN);
        gsize count = 65536 - decoder.avail_out;
        if (status != LZMA_OK && status != LZMA_STREAM_END)
            break;
        if (count > limit - produced) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NO_SPACE,
                                 "The decompressed image exceeds the permitted size.");
            goto done;
        }
        if (output != NULL && count != 0 &&
            !g_output_stream_write_all (output, expanded, count, NULL, cancellable, error))
            goto done;
        g_checksum_update (hash, expanded, count);
        produced += count;
        gint64 now = g_get_monotonic_time ();
        if (progress != NULL && (now - last_update >= 200000 || status == LZMA_STREAM_END)) {
            progress (decoder.total_in, produced, progress_data);
            last_update = now;
        }
        if (status == LZMA_STREAM_END) {
            *size = produced;
            *digest = g_strdup (g_checksum_get_string (hash));
            success = TRUE;
            goto done;
        }
    }
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                         status == LZMA_MEMLIMIT_ERROR ? "The XZ stream exceeds the decoder memory limit." :
                         "The XZ stream is corrupt, truncated, or unsupported.");
done:
    lzma_end (&decoder);
    return success;
}

char *
majoris_image_identity (int fd)
{
    struct stat info;
    if (fstat (fd, &info) != 0)
        return NULL;
    return g_strdup_printf ("%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%" G_GINT64_FORMAT
                            ":%" G_GINT64_FORMAT ":%ld:%" G_GINT64_FORMAT ":%ld",
                            (guint64) info.st_dev, (guint64) info.st_ino, (gint64) info.st_size,
                            (gint64) info.st_mtim.tv_sec, info.st_mtim.tv_nsec,
                            (gint64) info.st_ctim.tv_sec, info.st_ctim.tv_nsec);
}
