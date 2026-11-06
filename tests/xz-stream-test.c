#include "xz-stream.h"

#include <lzma.h>
#include <string.h>

static GBytes *
fixture (const guint8 *data, gsize size)
{
    gsize capacity = lzma_stream_buffer_bound (size);
    gsize length = 0;
    guint8 *buffer = g_malloc (capacity);
    g_assert_cmpint (lzma_easy_buffer_encode (1, LZMA_CHECK_CRC64, NULL, data, size,
                                             buffer, &length, capacity), ==, LZMA_OK);
    return g_bytes_new_take (buffer, length);
}

static void
test_valid (void)
{
    g_autofree guint8 *payload = g_malloc0 (262144);
    payload[0] = 0x21;
    payload[262143] = 0x7f;
    g_autoptr(GBytes) compressed = fixture (payload, 262144);
    g_autoptr(GInputStream) input = g_memory_input_stream_new_from_bytes (compressed);
    g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
    g_autoptr(GError) error = NULL;
    g_autofree char *digest = NULL;
    guint64 count = 0;
    g_assert_true (majoris_xz_decode (input, output, 262144, NULL, NULL, NULL, &count, &digest, &error));
    g_assert_no_error (error);
    g_assert_cmpuint (count, ==, 262144);
    g_autofree char *expected = g_compute_checksum_for_data (G_CHECKSUM_SHA256, payload, 262144);
    g_assert_cmpstr (digest, ==, expected);
    g_assert_cmpmem (g_memory_output_stream_get_data (G_MEMORY_OUTPUT_STREAM (output)),
                     g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), payload, 262144);
}

static void
assert_decode_error (GBytes *compressed, GOutputStream *output, guint64 limit,
                     GCancellable *token, GIOErrorEnum code)
{
    g_autoptr(GInputStream) input = g_memory_input_stream_new_from_bytes (compressed);
    g_autoptr(GError) error = NULL;
    g_autofree char *digest = NULL;
    guint64 count = 0;
    g_assert_false (majoris_xz_decode (input, output, limit, token, NULL, NULL, &count, &digest, &error));
    g_assert_error (error, G_IO_ERROR, code);
    g_assert_null (digest);
    g_assert_cmpuint (count, ==, output == NULL ? 0 : 1);
}

static void
test_errors (void)
{
    g_autoptr(GBytes) compressed = fixture ((const guint8 *) "Majoris", 7);
    g_autoptr(GBytes) empty = g_bytes_new_static ("", 0);
    assert_decode_error (empty, NULL, 7, NULL, G_IO_ERROR_INVALID_DATA);
    assert_decode_error (compressed, NULL, 6, NULL, G_IO_ERROR_NO_SPACE);
    g_autoptr(GBytes) truncated = g_bytes_new_from_bytes (compressed, 0, g_bytes_get_size (compressed) - 1);
    assert_decode_error (truncated, NULL, 7, NULL, G_IO_ERROR_INVALID_DATA);
    gsize length;
    const guint8 *data = g_bytes_get_data (compressed, &length);
    guint8 *altered = g_memdup2 (data, length);
    altered[0] ^= 0xff;
    g_autoptr(GBytes) corrupt = g_bytes_new_take (altered, length);
    assert_decode_error (corrupt, NULL, 7, NULL, G_IO_ERROR_INVALID_DATA);
    guint8 small[1];
    g_autoptr(GOutputStream) output = g_memory_output_stream_new (small, sizeof small, NULL, NULL);
    assert_decode_error (compressed, output, 7, NULL, G_IO_ERROR_NO_SPACE);
    g_autoptr(GCancellable) cancelled = g_cancellable_new ();
    g_cancellable_cancel (cancelled);
    assert_decode_error (compressed, NULL, 7, cancelled, G_IO_ERROR_CANCELLED);
}

static void
cancel_after_write (guint64 compressed, guint64 expanded, gpointer data)
{
    g_assert_cmpuint (expanded, >, 0);
    g_cancellable_cancel (G_CANCELLABLE (data));
}

static void
test_cancel_after_write (void)
{
    g_autofree guint8 *payload = g_malloc0 (262144);
    g_autoptr(GBytes) compressed = fixture (payload, 262144);
    g_autoptr(GInputStream) input = g_memory_input_stream_new_from_bytes (compressed);
    g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
    g_autoptr(GCancellable) token = g_cancellable_new ();
    g_autoptr(GError) error = NULL;
    g_autofree char *digest = NULL;
    guint64 count = 0;
    g_assert_false (majoris_xz_decode (input, output, 262144, token, cancel_after_write, token,
                                      &count, &digest, &error));
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_assert_cmpuint (count, >, 0);
    g_assert_cmpuint (count, <, 262144);
    g_assert_cmpuint (count, ==,
        g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)));
    g_assert_null (digest);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/native-xz/valid", test_valid);
    g_test_add_func ("/native-xz/errors", test_errors);
    g_test_add_func ("/native-xz/cancel-after-write", test_cancel_after_write);
    return g_test_run ();
}
