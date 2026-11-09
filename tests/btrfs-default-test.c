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
    g_assert_false (matches_mount (fd, directory, 1, "00000000-0000-0000-0000-000000000000", NULL));
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
    if ((argc == 5 || argc == 6) && g_str_equal (argv[1], "--allocation")) {
        guint64 expected, missing_id = 0;
        if (!g_ascii_string_to_unsigned (argv[4], 10, 1, G_MAXUINT64, &expected, NULL) ||
            (argc == 6 && !g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &missing_id, NULL)))
            return 2;
        g_autoptr(GVariant) report = majoris_btrfs_allocation (argv[2], argv[3]);
        if (report == NULL)
            return 1;
        guint64 logical, count;
        g_autoptr(GVariant) allocations = NULL;
        g_autoptr(GVariant) members = NULL;
        g_variant_get_child (report, 0, "t", &logical);
        g_variant_get_child (report, 1, "t", &count);
        allocations = g_variant_get_child_value (report, 2);
        members = g_variant_get_child_value (report, 3);
        g_print ("Btrfs allocation: %zu profiles, %zu members\n",
            g_variant_n_children (allocations), g_variant_n_children (members));
        for (gsize i = 0; i < g_variant_n_children (allocations); i++) {
            g_autoptr(GVariant) row = g_variant_get_child_value (allocations, i);
            const char *label;
            g_variant_get_child (row, 0, "&s", &label);
            g_print ("%s\n", label);
        }
        gboolean found_missing = FALSE;
        for (gsize i = 0; i < g_variant_n_children (members); i++) {
            g_autoptr(GVariant) member = g_variant_get_child_value (members, i);
            guint64 id, number;
            const char *state;
            gboolean known;
            g_variant_get_child (member, 0, "t", &id);
            g_variant_get_child (member, 1, "t", &number);
            g_variant_get_child (member, 5, "&s", &state);
            g_variant_get_child (member, 6, "b", &known);
            if (id == missing_id && missing_id != 0) {
                if (number != 0 || !g_str_equal (state, "Missing"))
                    return 1;
                found_missing = TRUE;
                continue;
            }
            if (number == 0 || !known)
                return 1;
        }
        return logical > 0 && count == expected && g_variant_n_children (allocations) >= 2 &&
            g_variant_n_children (members) == expected && found_missing == (missing_id != 0) ? 0 : 1;
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
