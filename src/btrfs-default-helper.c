/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <dlfcn.h>
#include "btrfs-inspect.h"
#include <fcntl.h>
#include <glib.h>
#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <errno.h>
#include <linux/openat2.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

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
matches_mount (int fd, const char *path, guint64 device, const char *uuid)
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
        return g_str_equal (actual_path, path) && g_str_has_prefix (node, "/dev/") &&
               stat (node, &info) == 0 && S_ISBLK (info.st_mode) &&
               ((guint64) info.st_rdev == device ||
                (filesystem_member (uuid, info.st_rdev) && filesystem_member (uuid, (dev_t) device)));
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

static int
check_empty_member (int mount, const char *filesystem, dev_t target, guint64 expected)
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

    const guint slots = 64;
    g_autofree struct btrfs_ioctl_space_args *spaces =
        g_malloc0 (sizeof *spaces + slots * sizeof (struct btrfs_ioctl_space_info));
    spaces->space_slots = slots;
    if (ioctl (mount, BTRFS_IOC_SPACE_INFO, spaces) != 0 || spaces->total_spaces == 0 || spaces->total_spaces >= slots)
        return fail ("Could not verify Btrfs allocation profiles.");
    for (guint64 i = 0; i < spaces->total_spaces; i++) {
        guint64 profile = spaces->spaces[i].flags & BTRFS_BLOCK_GROUP_PROFILE_MASK;
        if (profile != 0 && profile != BTRFS_BLOCK_GROUP_DUP)
            return fail ("Only single and DUP allocation profiles are supported for empty-member removal.");
    }

    g_autofree char *devinfo = g_strdup_printf ("/sys/fs/btrfs/%s/devinfo", uuid);
    g_autoptr(GDir) devices = g_dir_open (devinfo, 0, NULL);
    if (devices == NULL)
        return fail ("Could not verify the kernel Btrfs member list.");
    const char *entry;
    guint64 count = 0;
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
            !filesystem_member (uuid, block.st_rdev))
            return fail ("A Btrfs member is missing or changed.");
        struct btrfs_ioctl_scrub_args scrub = { .devid = id };
        if (ioctl (mount, BTRFS_IOC_SCRUB_PROGRESS, &scrub) == 0 || errno != ENOTCONN)
            return fail ("A Btrfs scrub is active or its state is unknown.");
        count++;
        if (block.st_rdev == target) {
            if (found || device.bytes_used != 0)
                return fail ("The selected member still holds allocated Btrfs chunks.");
            found = TRUE;
        }
    }
    if (!found || count != expected)
        return fail ("Could not verify all Btrfs members and the removal target.");
    return 0;
}

int
main (int argc, char **argv)
{
    gboolean set = argc == 7 && g_str_equal (argv[1], "set-default");
    gboolean check = argc == 7 && g_str_equal (argv[1], "check-unmounted");
    gboolean check_member = argc == 7 && g_str_equal (argv[1], "check-empty-member");
    guint64 device, expected = 0, target = 0, current;
    if (geteuid () != 0 || (!set && !check && !check_member && (argc != 5 || !g_str_equal (argv[1], "get-default"))) ||
        !g_path_is_absolute (argv[2]) || !g_uuid_string_is_valid (argv[3]) ||
        !g_ascii_string_to_unsigned (argv[4], 10, 1, G_MAXUINT64, &device, NULL) ||
        (set && (!g_ascii_string_to_unsigned (argv[5], 10, 5, G_MAXUINT64, &expected, NULL) ||
                 !g_ascii_string_to_unsigned (argv[6], 10, 5, G_MAXUINT64, &target, NULL))))
        return fail ("Invalid Btrfs default-subvolume request.");

    int mount __attribute__((cleanup(close_fd))) = open_directory (argv[2]);
    if (mount < 0 || !matches_mount (mount, argv[2], device, argv[3]) || !matches_uuid (mount, argv[3]))
        return fail ("The Btrfs mount or its source identity changed.");

    if (check_member) {
        guint64 member, count;
        if (!g_ascii_string_to_unsigned (argv[5], 10, 1, G_MAXUINT64, &member, NULL) || member == device ||
            !g_ascii_string_to_unsigned (argv[6], 10, 2, G_MAXUINT64, &count, NULL))
            return fail ("Invalid Btrfs removal candidate.");
        return check_empty_member (mount, argv[3], (dev_t) member, count);
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
        if (!matches_mount (mount, argv[2], device, argv[3]) || !matches_uuid (mount, uuid))
            return fail ("The Btrfs mount or source identity changed before writing.");
        if (set_default (mount, target) != 0 || get_default (mount, &current) != 0 || current != target)
            return fail ("The default Btrfs subvolume update could not be verified.");
    } else if (get_default (mount, &current) != 0) {
        return fail ("Could not read the default Btrfs subvolume.");
    }
    g_print ("%" G_GUINT64_FORMAT "\n", current);
    return 0;
}
