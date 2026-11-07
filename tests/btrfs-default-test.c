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
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/btrfs-default/mount-identity", test_mount_identity);
    return g_test_run ();
}
