/* SPDX-License-Identifier: GPL-3.0-or-later */
#define main btrfs_helper_main
#include "btrfs-default-helper.c"
#undef main
#include <glib/gstdio.h>
#include <errno.h>
#include "btrfs-inspect.h"

static guint64 fixture_count;
static guint count_requests;

static int
fixture_space_info (int fd, struct btrfs_ioctl_space_args *spaces)
{
    (void) fd;
    if (spaces->space_slots == 0) {
        spaces->total_spaces = count_requests++ == 0 ? fixture_count : fixture_count + 1;
    } else {
        guint64 actual = fixture_count + 1;
        spaces->total_spaces = MIN (actual, spaces->space_slots);
        if (spaces->total_spaces == actual)
            spaces->spaces[actual - 1].flags = BTRFS_SPACE_INFO_GLOBAL_RSV;
    }
    return 0;
}

static GVariant *
profile_rows (guint64 data, guint64 meta, guint64 system)
{
    GVariantBuilder rows = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE ("a(sttt)"));
    g_variant_builder_add (&rows, "(sttt)", "Data", (guint64) (64 * MIB), (guint64) MIB, data);
    g_variant_builder_add (&rows, "(sttt)", "Metadata", (guint64) (64 * MIB), (guint64) MIB, meta);
    g_variant_builder_add (&rows, "(sttt)", "System", (guint64) (8 * MIB), (guint64) MIB, system);
    return g_variant_ref_sink (g_variant_builder_end (&rows));
}

static void
test_conversion_plan (void)
{
    const Profile *single = find_profile ("single", 0);
    const Profile *raid1 = find_profile ("raid1", 0);
    const Profile *raid1c3 = find_profile ("raid1c3", 0);
    g_assert_cmpuint (single->flag, ==, PROFILE_SINGLE);
    g_assert_cmpuint (raid1c3->members, ==, 3);
    g_assert_cmpuint (find_profile ("raid10", 0)->members, ==, 4);
    g_assert_null (find_profile ("raid5", 0));
    g_assert_null (find_profile ("17", 0));
    g_autoptr(GVariant) rows = profile_rows (1, 4 | BTRFS_BLOCK_GROUP_DUP, 2 | BTRFS_BLOCK_GROUP_DUP);
    Conversion increase = { .data = raid1, .metadata = raid1c3 };
    g_assert_null (assess_allocations (rows, MIB, &increase, NULL));
    g_assert_true (increase.changes);
    g_assert_false (increase.risk);
    g_assert_false (increase.force);
    g_assert_cmpuint (increase.workspace, ==, (256 + 64 + 64 + 8 + 1) * MIB);
    Conversion reduce_metadata = { .metadata = single };
    g_assert_null (assess_allocations (rows, 0, &reduce_metadata, NULL));
    g_assert_true (reduce_metadata.risk);
    g_assert_true (reduce_metadata.force);
    g_autoptr(GVariant) mirrored = profile_rows (1 | BTRFS_BLOCK_GROUP_RAID1, 4, 2);
    Conversion reduce_data = { .data = single };
    g_assert_null (assess_allocations (mirrored, 0, &reduce_data, NULL));
    g_assert_true (reduce_data.risk);
    g_assert_false (reduce_data.force);
    struct btrfs_balance_args filter = { 0 };
    set_conversion_filter (&filter, raid1);
    g_assert_cmpuint (filter.flags, ==, BTRFS_BALANCE_ARGS_CONVERT | BTRFS_BALANCE_ARGS_SOFT);
    g_assert_cmpuint (filter.target, ==, BTRFS_BLOCK_GROUP_RAID1);
    g_assert_cmpuint (extent_gap (0, 128 * MIB), ==, 63 * MIB);
    g_assert_cmpuint (extent_gap (64 * MIB, 66 * MIB), ==, MIB);
    for (guint i = 0; i < 3; i++) {
        const guint64 unsupported[] = { 5, 1 | (1ULL << 40), 1 | BTRFS_BLOCK_GROUP_RAID5 };
        g_autoptr(GVariant) invalid = profile_rows (unsupported[i], 4, 2);
        Conversion rejected = { .data = single };
        g_assert_nonnull (assess_allocations (invalid, 0, &rejected, NULL));
    }
}

static gpointer
fail_allocation (gsize size)
{
    g_assert_cmpuint (size, >, 0);
    return NULL;
}

static void
test_space_info (void)
{
    const guint64 counts[] = { 1, 64, 90 };
    for (guint i = 0; i < G_N_ELEMENTS (counts); i++) {
        fixture_count = counts[i] - 1;
        count_requests = 1;
        g_autofree struct btrfs_ioctl_space_args *spaces =
            majoris_btrfs_read_spaces (-1, fixture_space_info, g_try_malloc0);
        g_assert_nonnull (spaces);
        g_assert_cmpuint (spaces->total_spaces, ==, counts[i]);
        fixture_count++;
        count_requests = 0;
        g_clear_pointer (&spaces, g_free);
        spaces = majoris_btrfs_read_spaces (-1, fixture_space_info, g_try_malloc0);
        g_assert_nonnull (spaces);
        g_assert_cmpuint (spaces->total_spaces, ==, counts[i] + 1);
        g_assert_cmpuint (count_requests, ==, 2);
    }
    const guint64 invalid_counts[] = { 0, 4097, G_MAXUINT64 };
    for (guint i = 0; i < G_N_ELEMENTS (invalid_counts); i++) {
        fixture_count = invalid_counts[i];
        count_requests = 0;
        g_assert_null (majoris_btrfs_read_spaces (-1, fixture_space_info, g_try_malloc0));
    }
    fixture_count = 1;
    count_requests = 0;
    g_assert_null (majoris_btrfs_read_spaces (-1, fixture_space_info, fail_allocation));
}

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
    g_test_add_func ("/btrfs-default/space-info", test_space_info);
    g_test_add_func ("/btrfs-default/profile-conversion", test_conversion_plan);
    return g_test_run ();
}
