/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <dlfcn.h>
#include <blkid/blkid.h>
#include <gio/gio.h>
#include "btrfs-inspect.h"
#include "btrfs-quota.h"
#include <fcntl.h>
#include <glib.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <linux/fs.h>
#include <errno.h>
#include <linux/openat2.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#ifndef STATX_MNT_ID_UNIQUE
#define STATX_MNT_ID_UNIQUE 0x00004000U
#endif

typedef int (*GetDefault) (int, guint64 *);
typedef int (*SetDefault) (int, guint64);
typedef int (*SubvolumePath) (int, guint64, char **);

static void
close_fd (int *fd)
{
    if (*fd >= 0)
        close (*fd);
}

static int
open_directory (const char *path)
{
    struct open_how how = { .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_NO_SYMLINKS };
    return syscall (SYS_openat2, AT_FDCWD, path, &how, sizeof how);
}

static gboolean
matches_uuid (int fd, const char *uuid)
{
    struct btrfs_ioctl_fs_info_args info = { 0 };
    if (ioctl (fd, BTRFS_IOC_FS_INFO, &info) != 0)
        return FALSE;
    const guint8 *u = info.fsid;
    g_autofree char *actual = g_strdup_printf (
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9],
        u[10], u[11], u[12], u[13], u[14], u[15]);
    return g_ascii_strcasecmp (actual, uuid) == 0;
}

static gboolean
filesystem_member (const char *uuid, dev_t device)
{
    g_autofree char *canonical_uuid = g_ascii_strdown (uuid, -1);
    g_autofree char *members = g_strdup_printf ("/sys/fs/btrfs/%s/devices", canonical_uuid);
    g_autofree char *block = g_strdup_printf ("/sys/dev/block/%u:%u", major (device), minor (device));
    struct stat expected;
    if (stat (block, &expected) != 0)
        return FALSE;
    g_autoptr(GDir) directory = g_dir_open (members, 0, NULL);
    if (directory == NULL)
        return FALSE;
    const char *entry;
    while ((entry = g_dir_read_name (directory)) != NULL) {
        g_autofree char *candidate = g_build_filename (members, entry, NULL);
        struct stat actual;
        if (stat (candidate, &actual) == 0 &&
            actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino)
            return TRUE;
    }
    return FALSE;
}

static gboolean
matches_mount (int fd, const char *path, guint64 device, const char *uuid, dev_t *source_device)
{
    struct statx opened;
    g_autofree char *mountinfo = NULL;
    if (statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID, &opened) != 0 ||
        !(opened.stx_mask & STATX_MNT_ID) ||
        !g_file_get_contents ("/proc/self/mountinfo", &mountinfo, NULL, NULL))
        return FALSE;

    g_auto(GStrv) lines = g_strsplit (mountinfo, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        g_auto(GStrv) parts = g_strsplit (lines[i], " - ", 2);
        if (parts[1] == NULL)
            continue;
        g_auto(GStrv) mount = g_strsplit (parts[0], " ", 6);
        g_auto(GStrv) source = g_strsplit (parts[1], " ", 3);
        if (g_strv_length (mount) < 6 || g_strv_length (source) < 3 ||
            g_ascii_strtoull (mount[0], NULL, 10) != opened.stx_mnt_id ||
            !g_str_equal (source[0], "btrfs"))
            continue;
        g_autofree char *actual_path = g_strcompress (mount[4]);
        g_autofree char *node = g_strcompress (source[1]);
        struct stat info;
        gboolean valid = g_str_equal (actual_path, path) && g_str_has_prefix (node, "/dev/") &&
            stat (node, &info) == 0 && S_ISBLK (info.st_mode) &&
            ((guint64) info.st_rdev == device ||
             (filesystem_member (uuid, info.st_rdev) && filesystem_member (uuid, (dev_t) device)));
        if (valid && source_device != NULL) *source_device = info.st_rdev;
        return valid;
    }
    return FALSE;
}

static gboolean
system_filesystem (const char *uuid)
{
    const char *critical[] = { "/", "/boot", "/boot/efi", "/usr", "/var", "/etc", "/efi" };
    for (guint i = 0; i < G_N_ELEMENTS (critical); i++) {
        int fd __attribute__((cleanup(close_fd))) = open (critical[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd >= 0 && matches_uuid (fd, uuid))
            return TRUE;
    }
    return FALSE;
}

static int
fail (const char *message)
{
    g_printerr ("%s\n", message);
    return 1;
}

static gboolean
replace_ioctl (int fd, struct btrfs_ioctl_dev_replace_args *request)
{
    int rc = ioctl (fd, BTRFS_IOC_DEV_REPLACE, request);
    if (rc < 0) {
        if (request->cmd == BTRFS_IOCTL_DEV_REPLACE_CMD_START && errno == ECANCELED &&
            request->result == (guint64) -ECANCELED)
            return TRUE; /* The caller still checks the resulting kernel state. */
        g_printerr ("Btrfs replacement ioctl failed: %s\n", g_strerror (errno));
        return FALSE;
    }
    if (rc == BTRFS_ERROR_DEV_EXCL_RUN_IN_PROGRESS) {
        fail ("Another exclusive Btrfs operation is already running.");
        return FALSE;
    }
    guint64 result = rc > 0 ? (guint64) rc : (guint64) request->result;
    switch (result) {
    case BTRFS_IOCTL_DEV_REPLACE_RESULT_NO_ERROR:
        return TRUE;
    case BTRFS_IOCTL_DEV_REPLACE_RESULT_NOT_STARTED:
        fail ("The kernel reports that replacement is not active.");
        break;
    case BTRFS_IOCTL_DEV_REPLACE_RESULT_ALREADY_STARTED:
        fail ("A Btrfs replacement has already started.");
        break;
    case BTRFS_IOCTL_DEV_REPLACE_RESULT_SCRUB_INPROGRESS:
        fail ("A Btrfs scrub is in progress.");
        break;
    default:
        g_printerr ("Unknown kernel replacement result: %" G_GUINT64_FORMAT "\n", result);
        break;
    }
    return FALSE;
}

static gboolean
read_replace_status (int fd, struct btrfs_ioctl_dev_replace_args *status)
{
    *status = (struct btrfs_ioctl_dev_replace_args) { .cmd = BTRFS_IOCTL_DEV_REPLACE_CMD_STATUS };
    if (!replace_ioctl (fd, status))
        return FALSE;
    if (status->status.progress_1000 > 1000) {
        fail ("The kernel returned invalid Btrfs replacement progress.");
        return FALSE;
    }
    return TRUE;
}

static void
print_replace_status (const struct btrfs_ioctl_dev_replace_args *status)
{
    const struct btrfs_ioctl_dev_replace_status_params *s = &status->status;
    guint64 fields[] = { s->replace_state, s->progress_1000, s->time_started,
        s->time_stopped, s->num_write_errors, s->num_uncorrectable_read_errors, status->result };
    for (guint i = 0; i < G_N_ELEMENTS (fields); i++)
        g_print ("%s%" G_GUINT64_FORMAT, i == 0 ? "" : " ", fields[i]);
    g_print ("\n");
}

static int
run_replace_status (int fd, const char *uuid, const char *expected_start)
{
    struct btrfs_ioctl_dev_replace_args status;
    if (!read_replace_status (fd, &status))
        return 1;
    if (expected_start != NULL) {
        guint64 started;
        struct statvfs state;
        if (!g_ascii_string_to_unsigned (expected_start, 10, 1, G_MAXUINT64, &started, NULL) ||
            status.status.time_started != started ||
            (status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_STARTED &&
             status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_SUSPENDED))
            return fail ("The reviewed Btrfs replacement is no longer active.");
        if (system_filesystem (uuid) || fstatvfs (fd, &state) != 0 || (state.f_flag & ST_RDONLY))
            return fail ("The Btrfs filesystem is protected or read-only.");
        struct btrfs_ioctl_dev_replace_args cancel = { .cmd = BTRFS_IOCTL_DEV_REPLACE_CMD_CANCEL };
        if (!replace_ioctl (fd, &cancel))
            return 1;
        for (guint attempt = 0; attempt < 50; attempt++) {
            if (!read_replace_status (fd, &status))
                return 1;
            if (status.status.time_started != started)
                break;
            if (status.status.replace_state == BTRFS_IOCTL_DEV_REPLACE_STATE_CANCELED) {
                print_replace_status (&status);
                return 0;
            }
            if (status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_STARTED &&
                status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_SUSPENDED)
                break;
            g_usleep (100000);
        }
        return fail ("The kernel did not confirm cancellation of the reviewed replacement.");
    }
    print_replace_status (&status);
    return 0;
}

static gboolean
empty_directory (const char *path)
{
    g_autoptr(GDir) directory = g_dir_open (path, 0, NULL);
    return directory != NULL && g_dir_read_name (directory) == NULL;
}

static gboolean
related_blocks (const char *target, guint64 number)
{
    g_autofree char *link = g_strdup_printf ("/sys/dev/block/%u:%u",
        major ((dev_t) number), minor ((dev_t) number));
    g_autofree char *source = realpath (link, NULL);
    if (source == NULL)
        return TRUE;
    g_autofree char *prefix = g_strconcat (target, "/", NULL);
    return g_str_equal (target, source) || g_str_has_prefix (source, prefix);
}

static gboolean
target_udisks_identity (const char *object, const char *path, guint64 number, guint64 size)
{
    if (!g_variant_is_object_path (object) || !g_str_has_prefix (object, "/org/freedesktop/UDisks2/block_devices/"))
        return FALSE;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync (G_BUS_TYPE_SYSTEM, NULL, NULL);
    if (bus == NULL)
        return FALSE;
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync (bus, "org.freedesktop.UDisks2", object,
        "org.freedesktop.DBus.Properties", "GetAll", g_variant_new ("(s)", "org.freedesktop.UDisks2.Block"),
        G_VARIANT_TYPE ("(a{sv})"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL, NULL);
    if (reply == NULL)
        return FALSE;
    g_autoptr(GVariant) props = g_variant_get_child_value (reply, 0);
    g_autoptr(GVariant) configuration = g_variant_lookup_value (props, "Configuration", G_VARIANT_TYPE ("a(sa{sv})"));
    const char *node, *usage, *type, *crypto, *raid, *raid_member;
    guint64 current_number, current_size;
    gboolean system, read_only, ignored;
    return g_variant_lookup (props, "Device", "^&ay", &node) && g_str_equal (node, path) &&
        g_variant_lookup (props, "DeviceNumber", "t", &current_number) && current_number == number &&
        g_variant_lookup (props, "Size", "t", &current_size) && current_size == size &&
        g_variant_lookup (props, "IdUsage", "&s", &usage) && usage[0] == 0 &&
        g_variant_lookup (props, "IdType", "&s", &type) && type[0] == 0 &&
        g_variant_lookup (props, "CryptoBackingDevice", "&o", &crypto) && g_str_equal (crypto, "/") &&
        g_variant_lookup (props, "MDRaid", "&o", &raid) && g_str_equal (raid, "/") &&
        g_variant_lookup (props, "MDRaidMember", "&o", &raid_member) && g_str_equal (raid_member, "/") &&
        g_variant_lookup (props, "HintSystem", "b", &system) && !system &&
        g_variant_lookup (props, "HintIgnore", "b", &ignored) && !ignored &&
        g_variant_lookup (props, "ReadOnly", "b", &read_only) && !read_only &&
        configuration != NULL && g_variant_n_children (configuration) == 0;
}

static gboolean
target_block_identity (int fd, guint64 number, guint64 sequence, guint64 size, guint32 sectorsize)
{
    struct stat node;
    guint64 actual_sequence, actual_size;
    guint32 logical;
    int read_only;
    return fstat (fd, &node) == 0 && S_ISBLK (node.st_mode) && node.st_uid == 0 &&
        (guint64) node.st_rdev == number &&
        ioctl (fd, BLKGETDISKSEQ, &actual_sequence) == 0 && actual_sequence == sequence &&
        ioctl (fd, BLKGETSIZE64, &actual_size) == 0 && actual_size == size &&
        ioctl (fd, BLKSSZGET, &logical) == 0 && logical > 0 && sectorsize % logical == 0 &&
        ioctl (fd, BLKROGET, &read_only) == 0 && !read_only;
}

static gboolean
target_is_blank (int fd)
{
    blkid_probe probe = blkid_new_probe ();
    if (probe == NULL)
        return FALSE;
    gboolean blank = blkid_probe_set_device (probe, fd, 0, 0) == 0 &&
        blkid_probe_enable_superblocks (probe, 1) == 0 &&
        blkid_probe_enable_partitions (probe, 1) == 0 &&
        blkid_do_safeprobe (probe) == 1;
    blkid_free_probe (probe);
    return blank;
}

static gboolean
whole_unused_target (const char *sys)
{
    g_autofree char *partition = g_build_filename (sys, "partition", NULL);
    g_autofree char *holders = g_build_filename (sys, "holders", NULL);
    g_autofree char *slaves = g_build_filename (sys, "slaves", NULL);
    if ((g_str_has_prefix (sys, "/sys/devices/virtual/") &&
         !g_str_has_prefix (sys, "/sys/devices/virtual/block/loop")) ||
        g_file_test (partition, G_FILE_TEST_EXISTS) || !empty_directory (holders) || !empty_directory (slaves))
        return FALSE;
    g_autoptr(GDir) directory = g_dir_open (sys, 0, NULL);
    if (directory == NULL)
        return FALSE;
    const char *entry;
    while ((entry = g_dir_read_name (directory)) != NULL) {
        g_autofree char *child = g_build_filename (sys, entry, "partition", NULL);
        if (g_file_test (child, G_FILE_TEST_EXISTS))
            return FALSE;
    }
    return TRUE;
}

static gboolean
replacement_profiles (GVariant *report, gboolean require_raid1)
{
    g_autoptr(GVariant) profiles = g_variant_get_child_value (report, 2);
    const guint64 types = BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA | BTRFS_BLOCK_GROUP_SYSTEM;
    guint64 seen = 0;
    GVariantIter iter;
    const char *label;
    guint64 total, used, flags;
    g_variant_iter_init (&iter, profiles);
    while (g_variant_iter_next (&iter, "(&sttt)", &label, &total, &used, &flags)) {
        guint64 type = flags & types;
        guint64 profile = flags & ~types;
        if (total == 0 || used > total ||
            (type != BTRFS_BLOCK_GROUP_DATA && type != BTRFS_BLOCK_GROUP_METADATA &&
             type != BTRFS_BLOCK_GROUP_SYSTEM && type != (BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA)))
            return FALSE;
        if (require_raid1 && profile != BTRFS_BLOCK_GROUP_RAID1)
            return FALSE;
        switch (profile) {
        case 0:
        case BTRFS_BLOCK_GROUP_DUP:
        case BTRFS_BLOCK_GROUP_RAID0:
        case BTRFS_BLOCK_GROUP_RAID1:
        case BTRFS_BLOCK_GROUP_RAID10:
        case BTRFS_BLOCK_GROUP_RAID1C3:
        case BTRFS_BLOCK_GROUP_RAID1C4:
            break;
        default:
            return FALSE;
        }
        seen |= type;
    }
    return seen == types;
}

static gboolean verify_maintenance_topology (int fd, const char *uuid, guint64 expected, gboolean reject_scrub);

static gboolean
read_member_errors (int fd, guint64 id, gboolean *errors)
{
    struct btrfs_ioctl_get_dev_stats stats = { .devid = id, .nr_items = BTRFS_DEV_STAT_VALUES_MAX };
    if (ioctl (fd, BTRFS_IOC_GET_DEV_STATS, &stats) != 0 || stats.nr_items != BTRFS_DEV_STAT_VALUES_MAX)
        return FALSE;
    *errors = FALSE;
    for (guint i = 0; i < BTRFS_DEV_STAT_VALUES_MAX; i++)
        *errors |= stats.values[i] != 0;
    return TRUE;
}

static gboolean
same_profile_flags (GVariant *before, GVariant *after)
{
    g_autoptr(GVariant) old = g_variant_get_child_value (before, 2);
    g_autoptr(GVariant) current = g_variant_get_child_value (after, 2);
    gsize count = g_variant_n_children (old);
    if (count != g_variant_n_children (current))
        return FALSE;
    for (gsize i = 0; i < count; i++) {
        guint64 old_flags, current_flags;
        g_autoptr(GVariant) old_row = g_variant_get_child_value (old, i);
        g_autoptr(GVariant) current_row = g_variant_get_child_value (current, i);
        g_variant_get_child (old_row, 3, "t", &old_flags);
        g_variant_get_child (current_row, 3, "t", &current_flags);
        if (old_flags != current_flags)
            return FALSE;
    }
    return TRUE;
}

static int
start_replacement (int fd, char **argv, gboolean review_only)
{
    const char *uuid = argv[3], *member_uuid = argv[7], *node = argv[10];
    guint64 count, id, source, number, size, sequence, avoid;
    if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &count, NULL) ||
        !g_ascii_string_to_unsigned (argv[6], 10, 1, G_MAXUINT64, &id, NULL) ||
        !g_uuid_string_is_valid (member_uuid) ||
        !g_ascii_string_to_unsigned (argv[8], 10, 0, G_MAXUINT64, &source, NULL) ||
        !g_ascii_string_to_unsigned (argv[9], 10, 1, G_MAXUINT64, &number, NULL) ||
        !g_str_has_prefix (node, "/dev/") || node[5] == 0 || strchr (node + 5, '/') != NULL ||
        !g_ascii_string_to_unsigned (argv[11], 10, 1, G_MAXUINT64, &size, NULL) ||
        !g_ascii_string_to_unsigned (argv[12], 10, 1, G_MAXUINT64, &sequence, NULL) ||
        !g_ascii_string_to_unsigned (argv[14], 10, 0, 1, &avoid, NULL))
        return fail ("Invalid Btrfs replacement identity.");

    struct btrfs_ioctl_fs_info_args fs = { 0 };
    struct btrfs_ioctl_dev_replace_args status;
    struct statvfs state;
    if (system_filesystem (uuid) || fstatvfs (fd, &state) != 0 || (state.f_flag & ST_RDONLY) ||
        ioctl (fd, BTRFS_IOC_FS_INFO, &fs) != 0 || fs.num_devices != count ||
        !read_replace_status (fd, &status) ||
        (status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_NEVER_STARTED &&
         status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_FINISHED &&
         status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_CANCELED))
        return fail ("Btrfs is protected, read-only, changed, or already replacing a device.");

    g_autoptr(GVariant) report = majoris_btrfs_allocation_fd (fd, uuid);
    if (report == NULL)
        return fail ("Could not verify Btrfs membership and allocation.");
    const char *operation;
    g_variant_get_child (report, 8, "&s", &operation);
    if (!g_str_equal (operation, "none") || !replacement_profiles (report, source == 0 || avoid))
        return fail ("An exclusive operation or unsupported allocation profile prevents replacement.");

    g_autofree char *syslink = g_strdup_printf ("/sys/dev/block/%u:%u", major ((dev_t) number), minor ((dev_t) number));
    g_autofree char *sys = realpath (syslink, NULL);
    if (sys == NULL || !whole_unused_target (sys) || filesystem_member (uuid, number) ||
        !target_udisks_identity (argv[13], node, number, size))
        return fail ("The target is unavailable, in use, or has an unsupported device topology.");

    g_autoptr(GVariant) members = g_variant_get_child_value (report, 3);
    if (g_variant_n_children (members) != count || (source == 0 && count < 2))
        return fail ("The Btrfs member set is incomplete.");
    GVariantIter iter;
    guint64 devid, devno, capacity, used;
    const char *identity, *member_state;
    gboolean known, errors, found = FALSE;
    g_variant_iter_init (&iter, members);
    while (g_variant_iter_next (&iter, "(tttt&s&sbb)", &devid, &devno, &capacity, &used,
                               &identity, &member_state, &known, &errors)) {
        if (!known || devid == 0 || (devno != 0 && related_blocks (sys, devno)))
            return fail ("A member identity or physical relationship could not be verified.");
        if (devid == id) {
            if (found || devno != source || g_ascii_strcasecmp (identity, member_uuid) != 0 ||
                !g_str_equal (member_state, source == 0 ? "Missing" : "Present"))
                return fail ("The reviewed Btrfs source changed.");
            if (capacity == 0 || size < capacity)
                return fail ("The replacement target is smaller than the verified source capacity.");
            found = TRUE;
        } else {
            if (devno == 0 || !g_str_equal (member_state, "Present") ||
                ((source == 0 || avoid) && (!read_member_errors (fd, devid, &errors) || errors)))
                return fail ("A surviving Btrfs member is unavailable, has unknown error counters, or reports errors.");
        }
        if (devno != 0) {
            struct btrfs_ioctl_scrub_args scrub = { .devid = devid };
            if (ioctl (fd, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
                return fail ("A Btrfs scrub is active or its state is unknown.");
        }
    }
    if (!found)
        return fail ("The reviewed Btrfs source device ID was not found.");

    int dev_directory __attribute__((cleanup(close_fd))) = open_directory ("/dev");
    struct stat dev_root;
    if (dev_directory < 0 || fstat (dev_directory, &dev_root) != 0 ||
        dev_root.st_uid != 0 || (dev_root.st_mode & (S_IWGRP | S_IWOTH)))
        return fail ("The block device directory is not trusted.");
    struct open_how how = { .flags = O_RDONLY | O_EXCL | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS };
    int target __attribute__((cleanup(close_fd))) = syscall (SYS_openat2, dev_directory, node + 5, &how, sizeof how);
    if (target < 0 || !target_block_identity (target, number, sequence, size, fs.sectorsize) ||
        !target_is_blank (target))
        return fail ("The replacement target changed, is busy, or contains a storage signature.");
    if (review_only) {
        print_replace_status (&status);
        return 0;
    }

    struct btrfs_ioctl_dev_replace_args start = { .cmd = BTRFS_IOCTL_DEV_REPLACE_CMD_START };
    start.start.srcdevid = id;
    start.start.cont_reading_from_srcdev_mode = (source == 0 || avoid) ?
        BTRFS_IOCTL_DEV_REPLACE_CONT_READING_FROM_SRCDEV_MODE_AVOID :
        BTRFS_IOCTL_DEV_REPLACE_CONT_READING_FROM_SRCDEV_MODE_ALWAYS;
    if (g_strlcpy ((char *) start.start.tgtdev_name, node, sizeof start.start.tgtdev_name) >= sizeof start.start.tgtdev_name)
        return fail ("The replacement target pathname is too long.");

    // Keep a nonexclusive reference across the ioctl. Btrfs must claim the
    // canonical node itself and retains that pathname for member discovery.
    how.flags &= ~O_EXCL;
    int pinned __attribute__((cleanup(close_fd))) = syscall (SYS_openat2, dev_directory, node + 5, &how, sizeof how);
    struct stat current_root;
    if (pinned < 0 || !target_block_identity (pinned, number, sequence, size, fs.sectorsize) ||
        !whole_unused_target (sys) || lstat ("/dev", &current_root) != 0 ||
        current_root.st_dev != dev_root.st_dev || current_root.st_ino != dev_root.st_ino ||
        !matches_mount (fd, argv[2], g_ascii_strtoull (argv[4], NULL, 10), uuid, NULL) ||
        !matches_uuid (fd, uuid))
        return fail ("The target or filesystem changed before replacement.");
    close (target);
    target = -1;
    if (!replace_ioctl (fd, &start) || !read_replace_status (fd, &status))
        return 1;
    if (status.status.replace_state != BTRFS_IOCTL_DEV_REPLACE_STATE_FINISHED) {
        print_replace_status (&status);
        return 0;
    }

    g_autoptr(GVariant) after = majoris_btrfs_allocation_fd (fd, uuid);
    if (after == NULL)
        return fail ("Replacement finished, but filesystem identity and allocation could not be verified.");
    if (!replacement_profiles (after, FALSE))
        return fail ("Replacement finished, but allocation profile verification is incomplete.");
    if (!same_profile_flags (report, after))
        g_printerr ("Allocation profiles changed during replacement. Check Btrfs Allocation for current redundancy.\n");
    if (!verify_maintenance_topology (fd, uuid, count, FALSE))
        return fail ("Replacement finished, but the kernel member count or topology could not be verified.");
    if (!target_block_identity (pinned, number, sequence, size, fs.sectorsize) ||
        (source != 0 && filesystem_member (uuid, source)))
        return fail ("Replacement finished, but the target identity or source retirement could not be verified.");
    gboolean read_only;
    g_variant_get_child (after, 7, "b", &read_only);
    g_autoptr(GVariant) current_members = g_variant_get_child_value (after, 3);
    found = FALSE;
    g_variant_iter_init (&iter, current_members);
    while (g_variant_iter_next (&iter, "(tttt&s&sbb)", &devid, &devno, &capacity, &used,
                               &identity, &member_state, &known, &errors)) {
        if (!known || !g_str_equal (member_state, "Present"))
            return fail ("Replacement finished, but the filesystem still reports unavailable members.");
        if (devid == id && devno == number && g_ascii_strcasecmp (identity, member_uuid) == 0)
            found = TRUE;
        if (!read_member_errors (fd, devid, &errors))
            return fail ("Replacement finished, but member error counters could not be verified.");
        if (errors)
            g_printerr ("Btrfs member %" G_GUINT64_FORMAT " reports device errors.\n", devid);
    }
    if (!found || read_only)
        return fail ("Replacement finished, but the target association or writable state could not be verified.");
    print_replace_status (&status);
    return 0;
}

static int
check_removable_member (int mount, const char *filesystem, dev_t target, guint64 expected, gboolean allow_allocated)
{
    struct btrfs_ioctl_fs_info_args info = { 0 };
    struct statvfs state;
    if (expected < 2 || ioctl (mount, BTRFS_IOC_FS_INFO, &info) != 0 || info.num_devices != expected ||
        fstatvfs (mount, &state) != 0 || (state.f_flag & ST_RDONLY) || system_filesystem (filesystem))
        return fail ("The Btrfs filesystem is protected, read-only, or its membership changed.");
    g_autofree char *uuid = g_ascii_strdown (filesystem, -1);
    g_autofree char *operation_file = g_strdup_printf ("/sys/fs/btrfs/%s/exclusive_operation", uuid);
    g_autofree char *operation = NULL;
    if (!g_file_get_contents (operation_file, &operation, NULL, NULL) || !g_str_equal (g_strstrip (operation), "none"))
        return fail ("Another exclusive Btrfs operation is active or its state is unknown.");

    g_autofree struct btrfs_ioctl_space_args *spaces = majoris_btrfs_query_spaces (mount);
    if (spaces == NULL)
        return fail ("Could not verify Btrfs allocation profiles.");
    for (guint64 i = 0; i < spaces->total_spaces; i++) {
        guint64 flags = spaces->spaces[i].flags;
        if (flags == BTRFS_SPACE_INFO_GLOBAL_RSV)
            continue;
        guint64 profile = flags & ~(BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_METADATA | BTRFS_BLOCK_GROUP_SYSTEM);
        if (profile != 0 && profile != BTRFS_BLOCK_GROUP_DUP)
            return fail ("Only single and DUP allocation profiles are supported for this member-removal workflow.");
    }

    g_autofree char *devinfo = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", uuid);
    g_autoptr(GDir) devices = g_dir_open (devinfo, 0, NULL);
    if (devices == NULL)
        return fail ("Could not verify the kernel Btrfs member list.");
    const char *entry;
    guint64 count = 0, allocated = 0, largest_destination = 0;
    gboolean found = FALSE;
    while ((entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (!g_ascii_string_to_unsigned (entry, 10, 1, G_MAXUINT64, &id, NULL))
            return fail ("The kernel Btrfs member list is invalid.");
        struct btrfs_ioctl_dev_info_args device = { .devid = id };
        struct stat block;
        if (ioctl (mount, BTRFS_IOC_DEV_INFO, &device) != 0 ||
            memchr (device.path, 0, sizeof device.path) == NULL ||
            stat ((const char *) device.path, &block) != 0 || !S_ISBLK (block.st_mode) ||
            !filesystem_member (uuid, block.st_rdev) || device.bytes_used > device.total_bytes)
            return fail ("A Btrfs member is missing or changed.");
        struct btrfs_ioctl_scrub_args scrub = { .devid = id };
        if (ioctl (mount, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
            return fail ("A Btrfs scrub is active or its state is unknown.");
        count++;
        if (block.st_rdev == target) {
            if (found)
                return fail ("The Btrfs device list contains a duplicate removal target.");
            allocated = device.bytes_used;
            found = TRUE;
        } else {
            largest_destination = MAX (largest_destination, device.total_bytes - device.bytes_used);
        }
    }
    if (!found || count != expected)
        return fail ("Could not verify all Btrfs members and the removal target.");
    if (allocated == 0)
        return 0;
    if (!allow_allocated)
        return fail ("The selected member still holds allocated Btrfs chunks.");
    // Single and DUP chunks can be placed on one device. Require space for the full
    // physical allocation plus headroom on one surviving member. The kernel still
    // decides whether the actual free extents can accommodate every chunk.
    const guint64 reserve = 256 * G_GUINT64_CONSTANT (1024) * 1024;
    if (largest_destination < reserve || allocated > largest_destination - reserve)
        return fail ("No surviving Btrfs member has sufficient relocation capacity and headroom.");
    return 0;
}

static gboolean
verify_maintenance_topology (int fd, const char *uuid, guint64 expected, gboolean reject_scrub)
{
    struct btrfs_ioctl_fs_info_args fs = { 0 };
    if (expected == 0 || ioctl (fd, BTRFS_IOC_FS_INFO, &fs) != 0 || fs.num_devices != expected)
        return FALSE;
    g_autofree char *canonical = g_ascii_strdown (uuid, -1);
    g_autofree char *directory = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", canonical);
    g_autoptr(GDir) devices = g_dir_open (directory, 0, NULL);
    if (devices == NULL) return FALSE;
    guint64 count = 0;
    const char *entry;
    while ((entry = g_dir_read_name (devices)) != NULL) {
        guint64 id;
        if (!g_ascii_string_to_unsigned (entry, 10, 1, G_MAXUINT64, &id, NULL)) return FALSE;
        struct btrfs_ioctl_dev_info_args device = { .devid = id };
        struct stat info;
        if (ioctl (fd, BTRFS_IOC_DEV_INFO, &device) != 0 ||
            memchr (device.path, 0, sizeof device.path) == NULL ||
            stat ((const char *) device.path, &info) != 0 || !S_ISBLK (info.st_mode) ||
            !filesystem_member (canonical, info.st_rdev))
            return FALSE;
        if (reject_scrub) {
            struct btrfs_ioctl_scrub_args scrub = { .devid = id };
            if (ioctl (fd, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
                return FALSE;
        }
        count++;
    }
    return count == expected;
}

#include "btrfs-conversion.h"

static int
balance_status (int fd, gboolean detailed)
{
    struct btrfs_ioctl_balance_args balance = { 0 };
    if (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &balance) != 0) {
        if (errno != ENOTCONN) return fail ("Could not query Btrfs balance status.");
        g_print ("%s\n", detailed ? "idle 0 0 0 - - 0" : "idle 0 0 0");
        return 0;
    }
    const char *state = balance.state & BTRFS_BALANCE_STATE_RUNNING ? "running" : "paused";
    g_print ("%s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT, state,
        (guint64) balance.stat.completed, (guint64) balance.stat.considered, (guint64) balance.stat.expected);
    if (detailed) {
        const Profile *data = find_profile (NULL, balance.data.target);
        const Profile *metadata = find_profile (NULL, balance.meta.target);
        g_print (" %s %s %" G_GUINT64_FORMAT,
            !(balance.data.flags & BTRFS_BALANCE_ARGS_CONVERT) ? "-" : data ? data->name : "unknown",
            !(balance.meta.flags & BTRFS_BALANCE_ARGS_CONVERT) ? "-" : metadata ? metadata->name : "unknown",
            (guint64) balance.state);
    }
    g_print ("\n");
    return 0;
}

static int
run_balance (int fd, const char *uuid, const char *operation, guint64 usage,
             guint64 count, char **conversion_args)
{
    if (g_str_equal (operation, "balance-status")) return balance_status (fd, FALSE);
    if (g_str_equal (operation, "balance-convert-status")) return balance_status (fd, TRUE);
    struct statvfs state;
    if (system_filesystem (uuid) || fstatvfs (fd, &state) != 0 || (state.f_flag & ST_RDONLY))
        return fail ("The filesystem is protected or read-only.");
    if (g_str_equal (operation, "balance-pause") || g_str_equal (operation, "balance-cancel")) {
        int command = g_str_equal (operation, "balance-pause") ? BTRFS_BALANCE_CTL_PAUSE : BTRFS_BALANCE_CTL_CANCEL;
        if (ioctl (fd, BTRFS_IOC_BALANCE_CTL, (unsigned long) command) != 0)
            return fail ("The kernel did not accept the balance control request.");
        return balance_status (fd, FALSE);
    }

    struct btrfs_ioctl_balance_args balance = { 0 };
    Conversion plan = { 0 };
    gboolean resume = g_str_equal (operation, "balance-resume") ||
        g_str_equal (operation, "balance-convert-resume-check");
    struct btrfs_ioctl_balance_args saved = { 0 };
    if (resume && (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &saved) != 0 || saved.state != 0))
        return fail ("There is no paused Btrfs balance to resume.");
    if (conversion_args != NULL) {
        const char *data = conversion_args[0], *metadata = conversion_args[1];
        plan.data = find_profile (data, 0);
        plan.metadata = find_profile (metadata, 0);
        if ((!plan.data && !g_str_equal (data, "-")) || (!plan.metadata && !g_str_equal (metadata, "-")) ||
            (!plan.data && !plan.metadata))
            return fail ("Invalid or unsupported conversion target.");
        g_autofree char *token = NULL;
        if (plan.data) {
            balance.flags |= BTRFS_BALANCE_DATA;
            set_conversion_filter (&balance.data, plan.data);
        }
        if (plan.metadata) {
            /* The ioctl takes a separate system filter. Use the metadata target
             * in the same request, as btrfs-progs does for a metadata balance. */
            balance.flags |= BTRFS_BALANCE_METADATA | BTRFS_BALANCE_SYSTEM;
            set_conversion_filter (&balance.meta, plan.metadata);
            balance.sys = balance.meta;
        }
        if (resume && ((saved.flags & ALLOCATION_TYPES) != balance.flags ||
            memcmp (&saved.data, &balance.data, sizeof saved.data) != 0 ||
            memcmp (&saved.meta, &balance.meta, sizeof saved.meta) != 0 ||
            memcmp (&saved.sys, &balance.sys, sizeof saved.sys) != 0))
            return fail ("The paused conversion targets or filters changed or are unsupported.");
        const char *error = assess_conversion (fd, uuid, count, resume, &plan, &token);
        if (error)
            return fail (error);
        if (resume && plan.force && !(saved.flags & BTRFS_BALANCE_FORCE))
            return fail ("The saved conversion lacks the required kernel authorization.");
        if (g_str_has_suffix (operation, "-check")) {
            g_print ("%s %s %" G_GUINT64_FORMAT "\n", token, plan.risk ? "reduce" : "standard", plan.workspace);
            return 0;
        }
        if (!g_str_equal (token, conversion_args[2]) ||
            !g_str_equal (conversion_args[3], plan.risk ? "reduce" : "standard"))
            return fail ("The conversion plan changed or the required risk was not confirmed. Reassess.");
        if (plan.force)
            balance.flags |= BTRFS_BALANCE_FORCE;
    } else if (resume) {
        if ((saved.data.flags | saved.meta.flags | saved.sys.flags) & BTRFS_BALANCE_ARGS_CONVERT)
            return fail ("Review the saved targets in Profile Conversion before resuming.");
    } else if (g_str_equal (operation, "balance-data")) {
        balance.flags = BTRFS_BALANCE_DATA;
        balance.data.flags = BTRFS_BALANCE_ARGS_USAGE;
        balance.data.usage = usage;
    } else if (g_str_equal (operation, "balance-metadata")) {
        balance.flags = BTRFS_BALANCE_METADATA;
        balance.meta.flags = BTRFS_BALANCE_ARGS_USAGE;
        balance.meta.usage = usage;
    } else {
        return fail ("Unsupported balance operation.");
    }
    if (plan.data || plan.metadata) {
        if (!verify_maintenance_topology (fd, uuid, count, TRUE))
            return fail ("The Btrfs topology or scrub state changed before dispatch.");
        if (resume) {
            struct btrfs_ioctl_balance_args current = { 0 };
            if (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &current) != 0 ||
                memcmp (&current, &saved, sizeof saved) != 0)
                return fail ("The saved balance changed before dispatch. Review it again.");
        }
    }
    if (resume)
        balance.flags = BTRFS_BALANCE_RESUME;
    int result = ioctl (fd, BTRFS_IOC_BALANCE_V2, &balance);
    if (result > 0)
        return fail ("The kernel refused the Btrfs balance. Review current topology and exclusive operation.");
    if (result < 0) {
        if (errno == ECANCELED) {
            struct btrfs_ioctl_balance_args paused = { 0 };
            if (ioctl (fd, BTRFS_IOC_BALANCE_PROGRESS, &paused) == 0) return balance_status (fd, FALSE);
            if (errno == ENOTCONN) {
                g_print ("interrupted 0 0 0\n");
                return 0;
            }
        }
        if (errno == ENOSPC)
            return fail ("The kernel ran out of relocation space. Some chunks may already have moved. Reassess allocation.");
        g_printerr ("The kernel did not complete the Btrfs balance (%s). Reassess current allocation.\n",
            g_strerror (errno));
        return 1;
    }
    gboolean verified = (!plan.data && !plan.metadata) ||
        (verify_maintenance_topology (fd, uuid, count, FALSE) && verify_conversion (fd, uuid, &plan));
    g_print ("%s %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT " %" G_GUINT64_FORMAT "\n",
        verified ? "completed" : "incomplete", (guint64) balance.stat.completed, (guint64) balance.stat.considered, (guint64) balance.stat.expected);
    return 0;
}

static const char *const quota_actions[] = {
    "quota-status", "quota-enable", "quota-enable-simple", "quota-disable", "quota-rescan-start",
    "qgroup-create", "qgroup-delete", "qgroup-assign", "qgroup-unassign",
    "qgroup-referenced-limit", "qgroup-exclusive-limit"
};

static GVariant *
read_quota_for_mount (int fd, const char *uuid, guint64 device, GError **error)
{
    struct statx identity;
    if (statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE, &identity) != 0 ||
        !(identity.stx_mask & STATX_MNT_ID_UNIQUE)) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not identify the Btrfs mount.");
        return NULL;
    }
    g_autoptr(GVariant) report = majoris_btrfs_quota_read (fd, uuid, error);
    if (!report) return NULL;
    const char *configuration;
    g_variant_get_child (report, 4, "&s", &configuration);
    g_autofree char *bound = g_strdup_printf ("%s:%s:%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT,
        uuid, configuration, device, (guint64) identity.stx_mnt_id);
    g_autofree char *token = g_compute_checksum_for_string (G_CHECKSUM_SHA256, bound, -1);
    struct statvfs state;
    gboolean writable = !system_filesystem (uuid) && fstatvfs (fd, &state) == 0 && !(state.f_flag & ST_RDONLY);
    g_auto(GVariantBuilder) result = G_VARIANT_BUILDER_INIT (G_VARIANT_TYPE (MAJORIS_QUOTA_REPORT));
    for (guint i = 0; i < 7; i++) {
        g_autoptr(GVariant) field = i == 4 ? g_variant_ref_sink (g_variant_new_string (token)) :
            g_variant_get_child_value (report, i);
        g_variant_builder_add_value (&result, field);
    }
    g_variant_builder_add (&result, "b", writable);
    return g_variant_ref_sink (g_variant_builder_end (&result));
}

static gboolean
quota_mutation_safe (int fd, const char *uuid, guint64 count)
{
    struct statvfs state;
    g_autofree char *path = g_strdup_printf ("/sys/fs/btrfs/%s/exclusive_operation", uuid);
    g_autofree char *exclusive = NULL;
    return !system_filesystem (uuid) && fstatvfs (fd, &state) == 0 && !(state.f_flag & ST_RDONLY) &&
        g_file_get_contents (path, &exclusive, NULL, NULL) && g_str_equal (g_strstrip (exclusive), "none") &&
        verify_maintenance_topology (fd, uuid, count, TRUE);
}

static gboolean
quota_mount_current (int fd, const char *path, guint64 device, const char *uuid)
{
    int current __attribute__((cleanup(close_fd))) = open_directory (path);
    struct statx first, second;
    return current >= 0 &&
        statx (fd, "", AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE, &first) == 0 &&
        statx (current, "", AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE, &second) == 0 &&
        (first.stx_mask & STATX_MNT_ID_UNIQUE) && (second.stx_mask & STATX_MNT_ID_UNIQUE) &&
        first.stx_mnt_id == second.stx_mnt_id &&
        matches_mount (fd, path, device, uuid, NULL) && matches_uuid (fd, uuid);
}

static int
run_quota (int fd, guint64 device, MajorisQuotaAction action, int argc, char **argv)
{
    alarm (action == QUOTA_READ ? 10 : 45);
    guint64 count, id = 0, value = 0;
    int arguments = action == QUOTA_READ ? 6 : action < QGROUP_CREATE ? 7 :
        action <= QGROUP_DELETE ? 8 : 9;
    if (argc != arguments || !g_ascii_string_to_unsigned (argv[5], 10, 1, 64, &count, NULL) ||
        (action >= QGROUP_CREATE && !majoris_btrfs_quota_id (argv[7], &id)) ||
        ((action == QGROUP_ASSIGN || action == QGROUP_UNASSIGN) &&
            !majoris_btrfs_quota_id (argv[8], &value)))
        return fail ("Invalid Btrfs quota request.");
    if (action >= QGROUP_REFERENCED) {
        if (g_str_equal (argv[8], "unlimited")) value = G_MAXUINT64;
        else if (!g_ascii_string_to_unsigned (argv[8], 10, 0, G_MAXUINT64 - 1, &value, NULL))
            return fail ("Invalid quota limit in bytes.");
    }

    g_autofree char *uuid = g_ascii_strdown (argv[3], -1);
    int lock __attribute__((cleanup(close_fd))) = -1;
    if (action != QUOTA_READ) {
        g_autofree char *lock_name = g_strdup_printf ("/run/majoris-btrfs-%s.lock", uuid);
        lock = open (lock_name, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lock < 0 || flock (lock, LOCK_EX | LOCK_NB) != 0 ||
            !quota_mutation_safe (fd, uuid, count))
            return fail ("Btrfs is protected, read-only, or a conflicting operation is active or unknown.");
    } else if (!verify_maintenance_topology (fd, uuid, count, FALSE)) {
        return fail ("Could not verify the Btrfs member topology or maintenance state.");
    }

    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) before = read_quota_for_mount (fd, uuid, device, &error);
    if (!before) return fail (error->message);
    if (!quota_mount_current (fd, argv[2], device, uuid))
        return fail ("The Btrfs mount or its source identity changed.");
    if (action == QUOTA_READ) {
        g_autofree char *report = g_variant_print (before, TRUE);
        g_print ("%s\n", report);
        return 0;
    }

    const char *token;
    g_variant_get_child (before, 4, "&s", &token);
    if (!g_str_equal (token, argv[6]))
        return fail ("Quota configuration changed after review. Refresh it before trying again.");
    if (!quota_mutation_safe (fd, uuid, count) || !quota_mount_current (fd, argv[2], device, uuid))
        return fail ("The Btrfs mount or maintenance state changed before the quota operation.");
    if (!majoris_btrfs_quota_apply (fd, action, before, id, value, &error)) {
        if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA)) return fail (error->message);
        g_autoptr(GVariant) observed = read_quota_for_mount (fd, uuid, device, NULL);
        const char *current_token = NULL;
        if (observed) g_variant_get_child (observed, 4, "&s", &current_token);
        if (g_strcmp0 (token, current_token) == 0 && quota_mount_current (fd, argv[2], device, uuid))
            return fail (error->message);
        g_printerr ("%s. The resulting quota state changed or could not be verified.\n", error->message);
        return 3;
    }

    g_autoptr(GVariant) after = read_quota_for_mount (fd, uuid, device, &error);
    if (!after || !quota_mount_current (fd, argv[2], device, uuid) ||
        !majoris_btrfs_quota_verified (action, before, after, id, value)) {
        g_printerr ("The kernel accepted the quota request, but Majoris could not verify the result. %s\n",
                    error ? error->message : "Refresh quota state before taking further action.");
        return 3;
    }
    g_autofree char *report = g_variant_print (after, TRUE);
    g_print ("%s\n", report);
    return 0;
}

#include "btrfs-scrub.h"

int
main (int argc, char **argv)
{
    int quota = -1;
    if (argc >= 6 && argc <= 9)
        for (guint i = 0; i < G_N_ELEMENTS (quota_actions); i++)
            if (g_str_equal (argv[1], quota_actions[i])) quota = i;
    gboolean convert_check = argc == 8 && (g_str_equal (argv[1], "balance-convert-check") ||
        g_str_equal (argv[1], "balance-convert-resume-check"));
    gboolean convert_start = argc == 10 && (g_str_equal (argv[1], "balance-convert") ||
        g_str_equal (argv[1], "balance-resume"));
    gboolean convert_status = argc == 6 && g_str_equal (argv[1], "balance-convert-status");
    gboolean replace_check = argc == 15 && g_str_equal (argv[1], "replace-check");
#ifdef MAJORIS_BTRFS_STATUS_ONLY
    if (!(argc == 6 && (g_str_equal (argv[1], "scrub-status") || g_str_equal (argv[1], "scrub-history"))) &&
        quota != QUOTA_READ && !replace_check && !convert_check && !convert_status &&
        (argc != 5 || !g_str_equal (argv[1], "replace-status")))
        return fail ("This helper accepts only read-only Btrfs inspection requests.");
    alarm (10);
#endif
    gboolean set = argc == 7 && g_str_equal (argv[1], "set-default");
    gboolean check = argc == 7 && g_str_equal (argv[1], "check-unmounted");
    gboolean allow_allocated = argc == 7 && g_str_equal (argv[1], "check-removable-member");
    gboolean check_member = allow_allocated || (argc == 7 && g_str_equal (argv[1], "check-empty-member"));
    gboolean balance = (argc == 6 || argc == 7) && g_str_has_prefix (argv[1], "balance-");
    gboolean scrub = (argc >= 6 && argc <= 8) && g_str_has_prefix (argv[1], "scrub-");
    gboolean replace_status = argc == 5 && g_str_equal (argv[1], "replace-status");
    gboolean replace_cancel = argc == 6 && g_str_equal (argv[1], "replace-cancel");
    gboolean replace_start = argc == 15 && g_str_equal (argv[1], "replace-start");
    guint64 device, expected = 0, target = 0, current;
    if (geteuid () != 0 || (!set && !check && !check_member && !balance && !scrub &&
        quota < 0 && !convert_check && !convert_start && !replace_status && !replace_cancel && !replace_start && !replace_check &&
        (argc != 5 || !g_str_equal (argv[1], "get-default"))) ||
        !g_path_is_absolute (argv[2]) || !g_uuid_string_is_valid (argv[3]) ||
        !g_ascii_string_to_unsigned (argv[4], 10, 1, G_MAXUINT64, &device, NULL) ||
        (set && (!g_ascii_string_to_unsigned (argv[5], 10, 5, G_MAXUINT64, &expected, NULL) ||
                 !g_ascii_string_to_unsigned (argv[6], 10, 5, G_MAXUINT64, &target, NULL))))
        return fail ("Invalid Btrfs helper request.");

    int mount __attribute__((cleanup(close_fd))) = open_directory (argv[2]);
    dev_t mount_source = 0;
    if (mount < 0 || !matches_mount (mount, argv[2], device, argv[3], &mount_source) || !matches_uuid (mount, argv[3]))
        return fail ("The Btrfs mount or its source identity changed.");

    if (quota >= 0)
        return run_quota (mount, device, quota, argc, argv);

    if (replace_status || replace_cancel)
        return run_replace_status (mount, argv[3], replace_cancel ? argv[5] : NULL);
    if (replace_start || replace_check)
        return start_replacement (mount, argv, replace_check);

    if (scrub)
        return run_scrub (mount, device, argc, argv);
    if (balance || convert_check || convert_start) {
        guint64 count, usage = 0;
        gboolean filtered = g_str_equal (argv[1], "balance-data") || g_str_equal (argv[1], "balance-metadata");
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &count, NULL) ||
            (!convert_check && !convert_start && (filtered ? argc != 7 || !g_ascii_string_to_unsigned (argv[6], 10, 0, 100, &usage, NULL) : argc != 6)) ||
            !verify_maintenance_topology (mount, argv[3], count, convert_check || convert_start || filtered || g_str_equal (argv[1], "balance-resume")))
            return fail ("Could not verify the Btrfs maintenance request, member topology or scrub state.");
        return run_balance (mount, argv[3], argv[1], usage, count, convert_check || convert_start ? argv + 6 : NULL);
    }

    if (check_member) {
        guint64 member, count;
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &member, NULL) || member == device || member == (guint64) mount_source ||
            !g_ascii_string_to_unsigned (argv[6], 10, 2, G_MAXUINT64, &count, NULL))
            return fail ("Invalid Btrfs removal candidate.");
        return check_removable_member (mount, argv[3], (dev_t) member, count, allow_allocated);
    }
    if (check) {
        if (!g_ascii_string_to_unsigned (argv[5], 10, 256, G_MAXUINT64, &target, NULL) ||
            argv[6][0] == 0 || strchr (argv[6], 47) != NULL ||
            g_str_equal (argv[6], ".") || g_str_equal (argv[6], ".."))
            return fail ("Invalid Btrfs subvolume identity.");
        g_autofree char *path = g_build_filename (argv[2], argv[6], NULL);
        gboolean read_only;
        g_autofree char *identity = majoris_btrfs_inspect_subvolume (path, target, argv[3], NULL, &read_only);
        if (identity == NULL)
            return fail ("The selected Btrfs subvolume changed.");
        int status = majoris_btrfs_mount_use (argv[3], target, argv[6]);
        if (status == 1)
            return fail ("The selected Btrfs subvolume is mounted.");
        if (status != 0)
            return fail ("Could not verify the selected subvolume across visible mount namespaces.");
        return 0;
    }

    void *library = dlopen ("libbtrfsutil.so.1", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL)
        return fail ("Install libbtrfsutil1 to manage the default Btrfs subvolume.");
    GetDefault get_default = (GetDefault) dlsym (library, "btrfs_util_get_default_subvolume_fd");
    SetDefault set_default = (SetDefault) dlsym (library, "btrfs_util_set_default_subvolume_fd");
    SubvolumePath subvolume_path = (SubvolumePath) dlsym (library, "btrfs_util_subvolume_path_fd");
    if (get_default == NULL || set_default == NULL || subvolume_path == NULL)
        return fail ("The installed libbtrfsutil lacks the required default-subvolume API.");

    if (set) {
        g_autofree char *uuid = g_ascii_strdown (argv[3], -1);
        g_autofree char *lock_name = g_strdup_printf ("/run/majoris-btrfs-%s.lock", uuid);
        int lock __attribute__((cleanup(close_fd))) = open (lock_name,
            O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct statvfs state;
        if (lock < 0 || flock (lock, LOCK_EX | LOCK_NB) != 0 ||
            system_filesystem (uuid) || fstatvfs (mount, &state) != 0 || (state.f_flag & ST_RDONLY))
            return fail ("The Btrfs filesystem is protected, read-only, or already being modified.");
        if (get_default (mount, &current) != 0 || current != expected)
            return fail ("The default Btrfs subvolume changed after confirmation.");
        g_autofree char *path = NULL;
        if (target != 5 && subvolume_path (mount, target, &path) != 0)
            return fail ("The requested Btrfs subvolume no longer exists.");
        if (!matches_mount (mount, argv[2], device, argv[3], NULL) || !matches_uuid (mount, uuid))
            return fail ("The Btrfs mount or source identity changed before writing.");
        if (set_default (mount, target) != 0 || get_default (mount, &current) != 0 || current != target)
            return fail ("The default Btrfs subvolume update could not be verified.");
    } else if (get_default (mount, &current) != 0) {
        return fail ("Could not read the default Btrfs subvolume.");
    }
    g_print ("%" G_GUINT64_FORMAT "\n", current);
    return 0;
}
