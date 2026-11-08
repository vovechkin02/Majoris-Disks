/* SPDX-License-Identifier: GPL-3.0-or-later */
#define main btrfs_helper_main
#include "btrfs-default-helper.c"
#undef main
#include <glib/gstdio.h>
#include <errno.h>
#include "btrfs-inspect.h"

static void
test_mount_identity (void)
{
    g_autoptr(GError) error = NULL;
    g_autofree char *directory = g_dir_make_tmp ("majoris-btrfs-helper-XXXXXX", &error);
    g_assert_no_error (error);
    int fd __attribute__((cleanup(close_fd))) = open_directory (directory);
    g_assert_cmpint (fd, >=, 0);
    g_assert_false (matches_mount (fd, directory, 1, "00000000-0000-0000-0000-000000000000"));
    g_autofree char *link = g_build_filename (directory, "substitute", NULL);
    g_assert_cmpint (symlink ("/", link), ==, 0);
    g_assert_cmpint (open_directory (link), ==, -1);
    g_assert_cmpint (errno, ==, ELOOP);
    gboolean read_only = FALSE;
    const char *wrong_uuid = "00000000-0000-0000-0000-000000000000";
    g_assert_null (majoris_btrfs_inspect_subvolume (directory, 256, wrong_uuid, NULL, &read_only));
    g_assert_null (majoris_btrfs_inspect_subvolume (link, 256, wrong_uuid, NULL, &read_only));
    g_assert_cmpint (g_unlink (link), ==, 0);
    g_assert_cmpint (g_rmdir (directory), ==, 0);
}

int
main (int argc, char **argv)
{
    if (argc == 5 && g_str_equal (argv[1], "--allocation")) {
        guint64 expected;
        if (!g_ascii_string_to_unsigned (argv[4], 10, 1, G_MAXUINT64, &expected, NULL))
            return 2;
        g_autoptr(GVariant) report = majoris_btrfs_allocation (argv[2], argv[3]);
        if (report == NULL)
            return 1;
        guint64 logical, count;
        g_autoptr(GVariant) allocations = NULL;
        g_autoptr(GVariant) members = NULL;
        g_variant_get (report, "(tt@a(stt)@a(tttt))", &logical, &count, &allocations, &members);
        g_print ("Btrfs allocation: %zu profiles, %zu members\n",
            g_variant_n_children (allocations), g_variant_n_children (members));
        return logical > 0 && count == expected && g_variant_n_children (allocations) >= 2 &&
            g_variant_n_children (members) == expected ? 0 : 1;
    }
    if (argc == 6 && g_str_equal (argv[1], "--mount-use")) {
        guint64 id, expected;
        if (!g_uuid_string_is_valid (argv[2]) ||
            !g_ascii_string_to_unsigned (argv[3], 10, 256, G_MAXUINT64, &id, NULL) ||
            !g_ascii_string_to_unsigned (argv[5], 10, 0, 1, &expected, NULL))
            return 2;
        int result = majoris_btrfs_mount_use (argv[2], id, argv[4]);
        g_print ("Btrfs mount use: %d\n", result);
        return result == (int) expected ? 0 : 1;
    }
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/btrfs-default/mount-identity", test_mount_identity);
    return g_test_run ();
}
