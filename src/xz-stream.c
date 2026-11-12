#include "xz-stream.h"

#include <lzma.h>
#include <errno.h>
#include <linux/loop.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

static gboolean
match_loop_identity (int block, const struct stat *info, GError **error)
{
    struct loop_info64 loop;
    if (info && S_ISREG (info->st_mode) && ioctl (block, LOOP_GET_STATUS64, &loop) == 0 &&
        loop.lo_device == (guint64) info->st_dev && loop.lo_inode == (guint64) info->st_ino)
        return TRUE;
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                         "The kernel loop mapping does not match the backing file identity.");
    return FALSE;
}

gboolean
majoris_image_match_loop (int block, const char *backing, GError **error)
{
    struct stat info;
    return match_loop_identity (block, lstat (backing, &info) == 0 ? &info : NULL, error);
}

gboolean
majoris_image_match_loop_source (int block, int source, GError **error)
{
    struct stat info;
    return match_loop_identity (block, fstat (source, &info) == 0 ? &info : NULL, error);
}

static gboolean
is_container_header (const guint8 *header, gsize count)
{
    return (count >= 4 && memcmp (header, "QFI\xfb", 4) == 0) ||
           (count >= 6 && memcmp (header, "\xfd" "7zXZ\0", 6) == 0) ||
           (count >= 8 && (memcmp (header, "vhdxfile", 8) == 0 ||
                           memcmp (header, "conectix", 8) == 0));
}

gboolean
majoris_image_require_raw (int fd, guint64 size, GError **error)
{
    guint8 header[8], footer[8];
    ssize_t count;
    do {
        count = pread (fd, header, sizeof header, 0);
    } while (count < 0 && errno == EINTR);
    if (count != (ssize_t) MIN (size, sizeof header))
        goto unreadable;
    if (is_container_header (header, count))
        goto container;
    if (size >= 512) {
        do {
            count = pread (fd, footer, sizeof footer, size - 512);
        } while (count < 0 && errno == EINTR);
        if (count != sizeof footer)
            goto unreadable;
        if (memcmp (footer, "conectix", 8) == 0)
            goto container;
    }
    return TRUE;

container:
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                         "A compressed or virtual disk container cannot be used as a raw image.");
    return FALSE;
unreadable:
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not read the image format signatures.");
    return FALSE;
}

gboolean
majoris_xz_encode (GInputStream *input, GOutputStream *output, guint64 size,
                   GCancellable *cancellable, MajorisXzProgress progress, gpointer progress_data,
                   char **digest, GError **error)
{
    const gsize buffer_size = 65536;
    lzma_stream encoder = LZMA_STREAM_INIT;
    g_autofree guint8 *source = g_malloc (buffer_size);
    g_autofree guint8 *encoded = g_malloc (buffer_size);
    g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
    guint64 read_bytes = 0;
    gint64 last_update = g_get_monotonic_time ();
    gboolean success = FALSE;
    *digest = NULL;

    lzma_ret status = lzma_easy_encoder (&encoder, 3, LZMA_CHECK_CRC64);
    while (status == LZMA_OK) {
        if (g_cancellable_set_error_if_cancelled (cancellable, error))
            goto done;
        if (encoder.avail_in == 0 && read_bytes < size) {
            gssize count = g_input_stream_read (input, source, MIN (size - read_bytes, buffer_size),
                                                cancellable, error);
            if (count < 0)
                goto done;
            if (count == 0) {
                g_set_error (error, G_IO_ERROR, G_IO_ERROR_PARTIAL_INPUT,
                             "The source ended after %" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT " bytes.",
                             read_bytes, size);
                goto done;
            }
            g_checksum_update (hash, source, count);
            read_bytes += count;
            encoder.next_in = source;
            encoder.avail_in = count;
        }
        encoder.next_out = encoded;
        encoder.avail_out = buffer_size;
        status = lzma_code (&encoder, read_bytes == size ? LZMA_FINISH : LZMA_RUN);
        if (status != LZMA_OK && status != LZMA_STREAM_END)
            break;
        if (!g_output_stream_write_all (output, encoded, buffer_size - encoder.avail_out,
                                       NULL, cancellable, error))
            goto done;
        gint64 now = g_get_monotonic_time ();
        if (progress != NULL && (now - last_update >= 200000 || status == LZMA_STREAM_END)) {
            progress (encoder.total_out, read_bytes, progress_data);
            last_update = now;
        }
        if (status == LZMA_STREAM_END) {
            *digest = g_strdup (g_checksum_get_string (hash));
            success = TRUE;
            goto done;
        }
    }
    g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "XZ compression failed (liblzma error %d).", status);
done:
    lzma_end (&encoder);
    return success;
}

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
    guint8 header[8] = { 0 };
    guint8 tail[512] = { 0 };
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
        if (produced < sizeof header)
            memcpy (header + produced, expanded, MIN (sizeof header - produced, count));
        if (count >= sizeof tail)
            memcpy (tail, expanded + count - sizeof tail, sizeof tail);
        else if (count != 0) {
            memmove (tail, tail + count, sizeof tail - count);
            memcpy (tail + sizeof tail - count, expanded, count);
        }
        if (status == LZMA_STREAM_END &&
            (is_container_header (header, MIN (produced + count, sizeof header)) ||
             (produced + count >= sizeof tail && memcmp (tail, "conectix", 8) == 0))) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                                 "The XZ stream contains a nested disk container.");
            goto done;
        }
        gboolean first_write = output != NULL && produced == 0 && count != 0;
        if (output != NULL && count != 0) {
            gsize written = 0;
            if (!g_output_stream_write_all (output, expanded, count, &written, cancellable, error)) {
                *size = produced + written;
                if (progress != NULL && written != 0)
                    progress (decoder.total_in, *size, progress_data);
                goto done;
            }
            *size = produced + written;
        }
        g_checksum_update (hash, expanded, count);
        produced += count;
        gint64 now = g_get_monotonic_time ();
        if (progress != NULL && (first_write || now - last_update >= 200000 || status == LZMA_STREAM_END)) {
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
